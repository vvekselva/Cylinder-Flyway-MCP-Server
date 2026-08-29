-- =============================================================================
-- V79__PartyCustody_ExactChecks_And_Dashboard.sql
-- =============================================================================
--
-- FIXES:
--   1. UNIQUE partial index on tbl_cylinder_party_custody — one ACTIVE record
--      per cylinder at a time, enforced at the DB level.
--
--   2. BEFORE INSERT on tbl_empty_pickup_line — validate via party custody that
--      the cylinder being collected was actually delivered to THIS customer.
--      Replaces/extends the existing state-only check.
--
--   3. fn_custody_after_empty_pickup_line — strengthen UPDATE to match
--      fk_customer so it cannot close another customer's custody record.
--
--   4. BEFORE INSERT on tbl_supplier_refill_collection_line — validate via
--      party custody that the cylinder was dropped at THIS supplier.
--      Replaces/extends the existing state-only check.
--
--   5. fn_custody_after_refill_collection_line — strengthen UPDATE to match
--      fk_supplier.
--
--   DASHBOARD VIEWS:
--   6. vw_cylinders_at_customers   — live per-cylinder per-customer holdings
--   7. vw_cylinders_at_suppliers   — live per-cylinder per-supplier holdings
--   8. vw_party_cylinder_dashboard — unified party dashboard (counts + serials)
--   9. vw_cylinder_party_history   — full in/out ledger per cylinder
-- =============================================================================


-- =============================================================================
-- FIX 1 — One ACTIVE custody record per cylinder at a time
-- =============================================================================

CREATE UNIQUE INDEX idx_custody_one_active_per_cylinder
    ON public.tbl_cylinder_party_custody(fk_cylinder)
    WHERE custody_status = 'ACTIVE';

COMMENT ON INDEX public.idx_custody_one_active_per_cylinder IS
    'A cylinder can only be at one party at a time. '
    'Prevents duplicate ACTIVE custody rows from bugs or retries.';


-- =============================================================================
-- FIX 2 — BEFORE INSERT on tbl_empty_pickup_line
--          Validate cylinder was delivered to THIS customer via party custody
-- =============================================================================
-- Replaces the existing fn_check_cylinder_is_delivered (state-only check).
-- The state check (DELIVERED_FOR_CONSUMPTION) is preserved AND extended with
-- the party custody check (cylinder must be ACTIVE at this exact customer).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_check_empty_pickup_line()
RETURNS TRIGGER AS $$
DECLARE
    v_delivered_state_id int8;
    v_current_state_id   int8;
    v_pickup_customer_id int8;
    v_custody_customer   int8;
    v_cylinder_serial    varchar(100);
    v_customer_name      varchar(200);
BEGIN
    -- ── Layer 1: state machine check (preserved from existing trigger) ───────
    SELECT pk_cylinder_state_id INTO v_delivered_state_id
      FROM public.tbl_cylinder_states
     WHERE cylinder_state = 'DELIVERED_FOR_CONSUMPTION';

    SELECT fk_current_state INTO v_current_state_id
      FROM public.tbl_cylinder_current_status
     WHERE fk_cylinder = NEW.fk_cylinder;

    IF v_current_state_id IS DISTINCT FROM v_delivered_state_id THEN
        SELECT cylinder_serial INTO v_cylinder_serial
          FROM public.tbl_cylinder WHERE pk_cylinder_id = NEW.fk_cylinder;
        RAISE EXCEPTION
            'Validation Failed: Cylinder % (%) must be in DELIVERED_FOR_CONSUMPTION '
            'state before it can be collected as empty.',
            v_cylinder_serial, NEW.fk_cylinder;
    END IF;

    -- ── Layer 2: party custody check — exact customer match ──────────────────
    SELECT ep.fk_customer INTO v_pickup_customer_id
      FROM public.tbl_empty_pickup ep
     WHERE ep.pk_pickup_id = NEW.fk_empty_pickup;

    SELECT cpc.fk_customer INTO v_custody_customer
      FROM public.tbl_cylinder_party_custody cpc
     WHERE cpc.fk_cylinder    = NEW.fk_cylinder
       AND cpc.custody_status = 'ACTIVE'
       AND cpc.party_type     = 'CUSTOMER';

    IF NOT FOUND THEN
        SELECT cylinder_serial INTO v_cylinder_serial
          FROM public.tbl_cylinder WHERE pk_cylinder_id = NEW.fk_cylinder;
        RAISE EXCEPTION
            'Validation Failed: Cylinder % (%) has no active customer custody record. '
            'It was never recorded as delivered to any customer, or it was '
            'already collected.',
            v_cylinder_serial, NEW.fk_cylinder;
    END IF;

    IF v_custody_customer IS DISTINCT FROM v_pickup_customer_id THEN
        SELECT cylinder_serial INTO v_cylinder_serial
          FROM public.tbl_cylinder WHERE pk_cylinder_id = NEW.fk_cylinder;
        SELECT customer_name   INTO v_customer_name
          FROM public.tbl_customer WHERE pk_customer_id = v_custody_customer;
        RAISE EXCEPTION
            'Validation Failed: Cylinder % (%) is currently at customer "%" (id: %), '
            'not at the customer on this empty pickup (id: %). '
            'You cannot collect a cylinder from a customer who does not hold it.',
            v_cylinder_serial, NEW.fk_cylinder,
            v_customer_name, v_custody_customer,
            v_pickup_customer_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Replace the existing state-only BEFORE INSERT trigger
DROP TRIGGER IF EXISTS trg_01_check_delivered_before_pickup
    ON public.tbl_empty_pickup_line;

CREATE TRIGGER trg_01_check_empty_pickup_line
BEFORE INSERT ON public.tbl_empty_pickup_line
FOR EACH ROW EXECUTE FUNCTION public.fn_check_empty_pickup_line();

COMMENT ON FUNCTION public.fn_check_empty_pickup_line() IS
    'BEFORE INSERT on tbl_empty_pickup_line. Two-layer guard: '
    '(1) Cylinder must be in DELIVERED_FOR_CONSUMPTION state (state machine). '
    '(2) Cylinder must have an ACTIVE CUSTOMER custody record at the EXACT '
    'customer on this empty pickup (party custody check). '
    'Prevents collecting a cylinder from a customer who never received it.';


-- =============================================================================
-- FIX 3 — fn_custody_after_empty_pickup_line: close the RIGHT customer record
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_custody_after_empty_pickup_line()
RETURNS TRIGGER AS $$
DECLARE
    v_pickup_customer_id int8;
    v_rows_updated       int4;
BEGIN
    SELECT fk_customer INTO v_pickup_customer_id
      FROM public.tbl_empty_pickup
     WHERE pk_pickup_id = NEW.fk_empty_pickup;

    UPDATE public.tbl_cylinder_party_custody
       SET exit_event_type      = 'EMPTY_PICKUP',
           fk_exit_empty_pickup = NEW.fk_empty_pickup,
           exited_at            = now(),
           custody_status       = 'CLOSED'
     WHERE fk_cylinder    = NEW.fk_cylinder
       AND custody_status = 'ACTIVE'
       AND party_type     = 'CUSTOMER'
       AND fk_customer    = v_pickup_customer_id;  -- exact customer match

    GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

    -- The BEFORE INSERT trigger already validated existence,
    -- so 0 rows here means a concurrency issue
    IF v_rows_updated = 0 THEN
        RAISE EXCEPTION
            'Custody closure failed: no ACTIVE CUSTOMER custody row found for '
            'cylinder % at customer %. This should not happen — check for '
            'concurrent modifications.',
            NEW.fk_cylinder, v_pickup_customer_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- =============================================================================
-- FIX 4 — BEFORE INSERT on tbl_supplier_refill_collection_line
--          Validate cylinder was dropped at THIS supplier via party custody
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_check_refill_collection_line()
RETURNS TRIGGER AS $$
DECLARE
    v_required_state_id  int8;
    v_current_state_id   int8;
    v_collection_supplier int8;
    v_custody_supplier   int8;
    v_cylinder_serial    varchar(100);
    v_supplier_name      varchar(200);
BEGIN
    -- ── Layer 1: state check (preserved from existing trigger) ───────────────
    SELECT pk_cylinder_state_id INTO v_required_state_id
      FROM public.tbl_cylinder_states
     WHERE cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL';

    SELECT fk_current_state INTO v_current_state_id
      FROM public.tbl_cylinder_current_status
     WHERE fk_cylinder = NEW.fk_cylinder;

    IF v_current_state_id IS DISTINCT FROM v_required_state_id THEN
        SELECT cylinder_serial INTO v_cylinder_serial
          FROM public.tbl_cylinder WHERE pk_cylinder_id = NEW.fk_cylinder;
        RAISE EXCEPTION
            'Validation Failed: Cylinder % (%) must be in EMPTY_DELIVERED_FOR_REFILL '
            'state before it can be collected from the supplier.',
            v_cylinder_serial, NEW.fk_cylinder;
    END IF;

    -- ── Layer 2: party custody check — exact supplier match ──────────────────
    SELECT src.fk_supplier INTO v_collection_supplier
      FROM public.tbl_supplier_refill_collection src
     WHERE src.pk_collection_id = NEW.fk_collection;

    SELECT cpc.fk_supplier INTO v_custody_supplier
      FROM public.tbl_cylinder_party_custody cpc
     WHERE cpc.fk_cylinder    = NEW.fk_cylinder
       AND cpc.custody_status = 'ACTIVE'
       AND cpc.party_type     = 'SUPPLIER';

    IF NOT FOUND THEN
        SELECT cylinder_serial INTO v_cylinder_serial
          FROM public.tbl_cylinder WHERE pk_cylinder_id = NEW.fk_cylinder;
        RAISE EXCEPTION
            'Validation Failed: Cylinder % (%) has no active supplier custody record. '
            'It was never recorded as handed to any supplier, or it was '
            'already collected.',
            v_cylinder_serial, NEW.fk_cylinder;
    END IF;

    IF v_custody_supplier IS DISTINCT FROM v_collection_supplier THEN
        SELECT cylinder_serial INTO v_cylinder_serial
          FROM public.tbl_cylinder WHERE pk_cylinder_id = NEW.fk_cylinder;
        SELECT supplier_name   INTO v_supplier_name
          FROM public.tbl_supplier WHERE pk_supplier_id = v_custody_supplier;
        RAISE EXCEPTION
            'Validation Failed: Cylinder % (%) is currently at supplier "%" (id: %), '
            'not at the supplier on this collection (id: %). '
            'You cannot collect a cylinder from a supplier who does not hold it.',
            v_cylinder_serial, NEW.fk_cylinder,
            v_supplier_name, v_custody_supplier,
            v_collection_supplier;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Replace the existing state-only BEFORE INSERT trigger
DROP TRIGGER IF EXISTS trg_01_check_cylinder_before_refill_collection
    ON public.tbl_supplier_refill_collection_line;

CREATE TRIGGER trg_01_check_refill_collection_line
BEFORE INSERT ON public.tbl_supplier_refill_collection_line
FOR EACH ROW EXECUTE FUNCTION public.fn_check_refill_collection_line();


-- =============================================================================
-- FIX 5 — fn_custody_after_refill_collection_line: close the RIGHT supplier
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_custody_after_refill_collection_line()
RETURNS TRIGGER AS $$
DECLARE
    v_collection_supplier int8;
    v_rows_updated        int4;
BEGIN
    SELECT fk_supplier INTO v_collection_supplier
      FROM public.tbl_supplier_refill_collection
     WHERE pk_collection_id = NEW.fk_collection;

    UPDATE public.tbl_cylinder_party_custody
       SET exit_event_type                    = 'REFILL_COLLECTION',
           fk_exit_supplier_refill_collection = NEW.fk_collection,
           exited_at                          = COALESCE(NEW.collected_at, now()),
           custody_status                     = 'CLOSED'
     WHERE fk_cylinder    = NEW.fk_cylinder
       AND custody_status = 'ACTIVE'
       AND party_type     = 'SUPPLIER'
       AND fk_supplier    = v_collection_supplier;  -- exact supplier match

    GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

    IF v_rows_updated = 0 THEN
        RAISE EXCEPTION
            'Custody closure failed: no ACTIVE SUPPLIER custody row found for '
            'cylinder % at supplier %. This should not happen — check for '
            'concurrent modifications.',
            NEW.fk_cylinder, v_collection_supplier;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- =============================================================================
-- DASHBOARD VIEWS
-- =============================================================================

-- =============================================================================
-- VIEW 6 — vw_cylinders_at_customers
-- Live: every cylinder currently at a customer, with delivery age
-- =============================================================================

CREATE OR REPLACE VIEW public.vw_cylinders_at_customers AS
SELECT
    cust.customer_name,
    -- tbl_customer_address is a link table (fk_customer, fk_address, fk_address_type).
    -- The address text lives in tbl_address; join via tbl_customer_address.fk_address.
    -- Column name in tbl_address is address_line_1 (with underscore).
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
    END                                                 AS aging_flag
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
    'aging_flag = OVERDUE (>30 days), FOLLOW_UP (>14 days), OK. '
    'Source of truth: tbl_cylinder_party_custody WHERE custody_status = ACTIVE.';


-- =============================================================================
-- VIEW 7 — vw_cylinders_at_suppliers
-- Live: every empty cylinder currently at a supplier awaiting refill
-- =============================================================================

CREATE OR REPLACE VIEW public.vw_cylinders_at_suppliers AS
SELECT
    s.supplier_name,
    c.cylinder_serial,
    p.product_name,
    cs.cylinder_state                                   AS current_state,
    cpc.entered_at                                      AS dropped_at,
    st.dropoff_date                                        AS dropoff_trip_date,
    EXTRACT(DAY FROM now() - cpc.entered_at)::int       AS days_at_supplier,
    CASE
        WHEN EXTRACT(DAY FROM now() - cpc.entered_at) > 7  THEN 'OVERDUE'
        WHEN EXTRACT(DAY FROM now() - cpc.entered_at) > 3  THEN 'FOLLOW_UP'
        ELSE 'OK'
    END                                                 AS aging_flag
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
    'Live view: every cylinder currently at a supplier awaiting refill. '
    'aging_flag = OVERDUE (>7 days), FOLLOW_UP (>3 days), OK. '
    'Source of truth: tbl_cylinder_party_custody WHERE custody_status = ACTIVE.';


-- =============================================================================
-- VIEW 8 — vw_party_cylinder_dashboard
-- Aggregate counts per party — the main operations screen widget
-- =============================================================================

CREATE OR REPLACE VIEW public.vw_party_cylinder_dashboard AS
SELECT
    party_type,
    CASE party_type
        WHEN 'CUSTOMER' THEN cust.customer_name
        WHEN 'SUPPLIER' THEN s.supplier_name
    END                                                 AS party_name,
    CASE party_type
        WHEN 'CUSTOMER' THEN cpc.fk_customer::text
        WHEN 'SUPPLIER' THEN cpc.fk_supplier::text
    END                                                 AS party_id,
    COUNT(*)                                            AS cylinders_held,
    COUNT(*) FILTER (
        WHERE EXTRACT(DAY FROM now() - cpc.entered_at) > 14
          AND party_type = 'CUSTOMER'
    )                                                   AS overdue_at_customer,
    COUNT(*) FILTER (
        WHERE EXTRACT(DAY FROM now() - cpc.entered_at) > 3
          AND party_type = 'SUPPLIER'
    )                                                   AS overdue_at_supplier,
    MIN(cpc.entered_at)                                 AS oldest_cylinder_since,
    MAX(cpc.entered_at)                                 AS newest_cylinder_since
FROM   public.tbl_cylinder_party_custody cpc
LEFT   JOIN public.tbl_customer cust ON cust.pk_customer_id = cpc.fk_customer
LEFT   JOIN public.tbl_supplier s    ON s.pk_supplier_id    = cpc.fk_supplier
WHERE  cpc.custody_status = 'ACTIVE'
GROUP  BY party_type, party_name, party_id
ORDER  BY party_type, cylinders_held DESC;

COMMENT ON VIEW public.vw_party_cylinder_dashboard IS
    'Per-party aggregate for the operations dashboard. '
    'Shows how many cylinders each customer and supplier currently holds, '
    'oldest and newest cylinder, and overdue counts.';


-- =============================================================================
-- VIEW 9 — vw_cylinder_party_history
-- Full in/out ledger for any cylinder — the per-serial audit trail
-- =============================================================================

CREATE OR REPLACE VIEW public.vw_cylinder_party_history AS
SELECT
    c.cylinder_serial,
    p.product_name,
    cpc.party_type,
    CASE cpc.party_type
        WHEN 'CUSTOMER' THEN cust.customer_name
        WHEN 'SUPPLIER' THEN s.supplier_name
    END                                                 AS party_name,
    a.address_line_1                                    AS customer_location,
    cpc.entry_event_type,
    o.challan_number                                    AS entry_challan,
    st.dropoff_date                                        AS entry_trip_date,
    cpc.entered_at,
    cpc.exit_event_type,
    ep.pickup_number                                    AS exit_pickup_number,
    src.collection_number                               AS exit_collection_number,
    cpc.exited_at,
    cpc.custody_status,
    CASE
        WHEN cpc.exited_at IS NOT NULL
        THEN EXTRACT(DAY FROM cpc.exited_at - cpc.entered_at)::int
        ELSE EXTRACT(DAY FROM now()          - cpc.entered_at)::int
    END                                                 AS days_held,
    cpc.remarks
FROM   public.tbl_cylinder_party_custody            cpc
JOIN   public.tbl_cylinder                          c
       ON c.pk_cylinder_id      = cpc.fk_cylinder
JOIN   public.tbl_product                           p
       ON p.pk_product_id       = c.fk_product
LEFT   JOIN public.tbl_customer                     cust
       ON cust.pk_customer_id   = cpc.fk_customer
LEFT   JOIN public.tbl_customer_address             ca
       ON ca.pk_customer_address_id = cpc.fk_customer_address
LEFT   JOIN public.tbl_address                      a
       ON a.pk_address_id       = ca.fk_address
LEFT   JOIN public.tbl_supplier                     s
       ON s.pk_supplier_id      = cpc.fk_supplier
LEFT   JOIN public.tbl_order                        o
       ON o.pk_order_id         = cpc.fk_entry_order
LEFT   JOIN public.tbl_supplier_trip                st
       ON st.pk_supplier_trip_id = cpc.fk_entry_supplier_trip
LEFT   JOIN public.tbl_empty_pickup                 ep
       ON ep.pk_pickup_id       = cpc.fk_exit_empty_pickup
LEFT   JOIN public.tbl_supplier_refill_collection   src
       ON src.pk_collection_id  = cpc.fk_exit_supplier_refill_collection
ORDER  BY cpc.fk_cylinder, cpc.entered_at DESC;

COMMENT ON VIEW public.vw_cylinder_party_history IS
    'Full custody ledger for every cylinder — every customer visit and supplier '
    'dropoff in chronological order. '
    'Filter by cylinder_serial for per-serial audit trail. '
    'custody_status = ACTIVE means the cylinder is still at that party now.';