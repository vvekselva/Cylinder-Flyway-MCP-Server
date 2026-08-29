-- ================================================================
-- MIGRATION V99: Add party_id to vw_cylinders_at_customers
--                and vw_cylinders_at_suppliers
-- ================================================================
--
-- WHY THIS IS NEEDED
-- ──────────────────────────────────────────────────────────────
-- The Java DO classes (CylinderCustomerCustodyDo,
-- CylinderSupplierCustodyDo) map a 'supplierId' / 'customerId'
-- field via @Column(name = "party_id") so that JPQL queries can
-- directly filter the view by party:
--
--   SELECT v FROM CylinderCustomerCustodyDo v
--    WHERE v.customerId = :customerId
--
-- Without the party_id column in the view, Hibernate has no column
-- to bind against, causing the SQLGrammarException seen in the logs.
--
-- WHY THE PREVIOUS V99 FAILED (SQL State 42P16)
-- ──────────────────────────────────────────────────────────────
-- CREATE OR REPLACE VIEW matches columns by position.  V83 created
-- vw_cylinders_at_customers with customer_name as column 1.
-- The previous V99 placed party_id as column 1, so PostgreSQL
-- interpreted this as renaming customer_name → party_id and
-- raised:
--   "cannot change name of view column customer_name to party_id"
--
-- THE FIX
-- ──────────────────────────────────────────────────────────────
-- PostgreSQL allows CREATE OR REPLACE VIEW to APPEND new columns
-- at the end — it cannot reorder or rename existing ones.
-- party_id is added as the LAST column in both views, after all
-- existing V83 columns, preserving their positions exactly.
-- The DO's @Column(name = "party_id") only requires the column
-- to EXIST in the view — position is irrelevant.
-- ================================================================


-- ────────────────────────────────────────────────────────────────
-- VIEW 1 — vw_cylinders_at_customers
-- V83 column order (preserved):
--   1. customer_name
--   2. delivery_location
--   3. cylinder_serial
--   4. product_name
--   5. current_state
--   6. delivered_at
--   7. delivery_challan
--   8. days_at_customer
--   9. aging_flag
--  10. party_id   ← NEW (appended at end)
-- ────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.vw_cylinders_at_customers AS
SELECT
    cust.customer_name,
    a.address_line_1                                    AS delivery_location,
    c.cylinder_serial,
    p.product_name,
    cs.cylinder_state                                   AS current_state,
    cpc.entered_at                                      AS delivered_at,
    o.challan_number                                    AS delivery_challan,
    EXTRACT(DAY FROM now() - cpc.entered_at)::int       AS days_at_customer,
    CASE
        WHEN EXTRACT(DAY FROM now() - cpc.entered_at) > 30 THEN 'OVERDUE'
        WHEN EXTRACT(DAY FROM now() - cpc.entered_at) > 14 THEN 'FOLLOW_UP'
        ELSE 'OK'
    END                                                 AS aging_flag,
    cpc.fk_customer                                     AS party_id   -- NEW col 10
FROM   public.tbl_cylinder_party_custody cpc
JOIN   public.tbl_cylinder               c    ON c.pk_cylinder_id      = cpc.fk_cylinder
JOIN   public.tbl_product                p    ON p.pk_product_id       = c.fk_product
JOIN   public.tbl_customer               cust ON cust.pk_customer_id   = cpc.fk_customer
LEFT   JOIN public.tbl_customer_address  ca   ON ca.pk_customer_address_id
                                                     = cpc.fk_customer_address
LEFT   JOIN public.tbl_address           a    ON a.pk_address_id       = ca.fk_address
LEFT   JOIN public.tbl_order             o    ON o.pk_order_id         = cpc.fk_entry_order
LEFT   JOIN public.tbl_cylinder_current_status ccs
           ON ccs.fk_cylinder = cpc.fk_cylinder
LEFT   JOIN public.tbl_cylinder_states   cs
           ON cs.pk_cylinder_state_id = ccs.fk_current_state
WHERE  cpc.custody_status = 'ACTIVE'
  AND  cpc.party_type     = 'CUSTOMER'
ORDER  BY days_at_customer DESC, cust.customer_name, c.cylinder_serial;

COMMENT ON VIEW public.vw_cylinders_at_customers IS
    'Live view: every cylinder currently at a customer. '
    'party_id = fk_customer (col 10, appended by V99 for JPA @Column mapping). '
    'aging_flag = OVERDUE (>30 days), FOLLOW_UP (>14 days), OK. '
    'Source of truth: tbl_cylinder_party_custody WHERE custody_status = ACTIVE.';


-- ────────────────────────────────────────────────────────────────
-- VIEW 2 — vw_cylinders_at_suppliers
-- V83 column order (preserved):
--   1. supplier_name
--   2. cylinder_serial
--   3. product_name
--   4. current_state
--   5. dropped_at
--   6. dropoff_trip_date
--   7. days_at_supplier
--   8. aging_flag
--   9. party_id   ← NEW (appended at end)
-- ────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.vw_cylinders_at_suppliers AS
SELECT
    s.supplier_name,
    c.cylinder_serial,
    p.product_name,
    cs.cylinder_state                                   AS current_state,
    cpc.entered_at                                      AS dropped_at,
    st.dropoff_date                                     AS dropoff_trip_date,
    EXTRACT(DAY FROM now() - cpc.entered_at)::int       AS days_at_supplier,
    CASE
        WHEN EXTRACT(DAY FROM now() - cpc.entered_at) > 7  THEN 'OVERDUE'
        WHEN EXTRACT(DAY FROM now() - cpc.entered_at) > 3  THEN 'FOLLOW_UP'
        ELSE 'OK'
    END                                                 AS aging_flag,
    cpc.fk_supplier                                     AS party_id   -- NEW col 9
FROM   public.tbl_cylinder_party_custody cpc
JOIN   public.tbl_cylinder               c    ON c.pk_cylinder_id    = cpc.fk_cylinder
JOIN   public.tbl_product                p    ON p.pk_product_id     = c.fk_product
JOIN   public.tbl_supplier               s    ON s.pk_supplier_id    = cpc.fk_supplier
LEFT   JOIN public.tbl_supplier_trip     st   ON st.pk_supplier_trip_id
                                                     = cpc.fk_entry_supplier_trip
LEFT   JOIN public.tbl_cylinder_current_status ccs
           ON ccs.fk_cylinder = cpc.fk_cylinder
LEFT   JOIN public.tbl_cylinder_states   cs
           ON cs.pk_cylinder_state_id = ccs.fk_current_state
WHERE  cpc.custody_status = 'ACTIVE'
  AND  cpc.party_type     = 'SUPPLIER'
ORDER  BY days_at_supplier DESC, s.supplier_name, c.cylinder_serial;

COMMENT ON VIEW public.vw_cylinders_at_suppliers IS
    'Live view: every empty cylinder currently at a supplier awaiting refill. '
    'party_id = fk_supplier (col 9, appended by V99 for JPA @Column mapping). '
    'aging_flag = OVERDUE (>7 days), FOLLOW_UP (>3 days), OK. '
    'Source of truth: tbl_cylinder_party_custody WHERE custody_status = ACTIVE.';