-- ============================================================================
-- V117__Ownership_Model_Dashboard_Views.sql
--
-- Purpose:
-- Read-only dashboard views for the new ownership model.
-- This does NOT use tbl_cylinder_current_status as a functional decision table.
--
-- Ownership sources:
-- 1. Yard      : tbl_yard_inventory_line where is_active = true
-- 2. Customer  : tbl_cylinder_party_custody where party_type='CUSTOMER' and custody_status='ACTIVE'
-- 3. Supplier  : tbl_cylinder_party_custody where party_type='SUPPLIER' and custody_status='ACTIVE'
-- 4. Logistics : tbl_cylinder_logistics_execution_line where is_active = true
-- ============================================================================

DROP VIEW IF EXISTS public.vw_ownership_current_cylinder_location;
DROP VIEW IF EXISTS public.vw_ownership_summary_by_location;
DROP VIEW IF EXISTS public.vw_ownership_yard_cylinder_detail;
DROP VIEW IF EXISTS public.vw_ownership_party_cylinder_detail;
DROP VIEW IF EXISTS public.vw_ownership_logistics_cylinder_detail;
DROP VIEW IF EXISTS public.vw_party_cylinder_dashboard_ownership;

-- ----------------------------------------------------------------------------
-- Yard detail
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.vw_ownership_yard_cylinder_detail AS
SELECT
    yil.pk_yard_inventory_line_id AS ownership_record_id,
    'YARD'::text AS ownership_location,
    yi.pk_yard_inventory_id AS yard_id,
    yi.yard_code,
    yi.yard_name,
    c.pk_cylinder_id AS cylinder_id,
    c.cylinder_serial,
    p.pk_product_id AS product_id,
    p.product_name,
    cs.pk_cylinder_state_id AS cylinder_state_id,
    cs.cylinder_state,
    yist.source_type_code AS source_type,
    yil.entry_date AS entered_at,
    yil.remarks
FROM public.tbl_yard_inventory_line yil
JOIN public.tbl_yard_inventory yi
    ON yi.pk_yard_inventory_id = yil.fk_yard_inventory
JOIN public.tbl_cylinder c
    ON c.pk_cylinder_id = yil.fk_cylinder
LEFT JOIN public.tbl_product p
    ON p.pk_product_id = c.fk_product
JOIN public.tbl_cylinder_states cs
    ON cs.pk_cylinder_state_id = yil.fk_cylinder_state
JOIN public.tbl_yard_inventory_source_type yist
    ON yist.pk_yard_inventory_source_type_id = yil.fk_yard_inventory_source_type
WHERE yil.is_active = TRUE;

-- ----------------------------------------------------------------------------
-- Customer/Supplier detail using party custody table
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.vw_ownership_party_cylinder_detail AS
SELECT
    cpc.pk_custody_id AS ownership_record_id,
    cpc.party_type::text AS ownership_location,
    cpc.fk_customer AS customer_id,
    cust.customer_name,
    cpc.fk_supplier AS supplier_id,
    supp.supplier_name,
    cpc.fk_customer_address AS customer_address_id,
    c.pk_cylinder_id AS cylinder_id,
    c.cylinder_serial,
    p.pk_product_id AS product_id,
    p.product_name,
    cpc.entry_event_type,
    cpc.entered_at,
    cpc.remarks
FROM public.tbl_cylinder_party_custody cpc
JOIN public.tbl_cylinder c
    ON c.pk_cylinder_id = cpc.fk_cylinder
LEFT JOIN public.tbl_product p
    ON p.pk_product_id = c.fk_product
LEFT JOIN public.tbl_customer cust
    ON cust.pk_customer_id = cpc.fk_customer
LEFT JOIN public.tbl_supplier supp
    ON supp.pk_supplier_id = cpc.fk_supplier
WHERE cpc.custody_status = 'ACTIVE';

-- ----------------------------------------------------------------------------
-- Logistics / in-transit detail
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.vw_ownership_logistics_cylinder_detail AS
SELECT
    clel.pk_cylinder_logistics_execution_line_id AS ownership_record_id,
    'LOGISTICS'::text AS ownership_location,
    cle.pk_cylinder_logistics_execution_id AS logistics_execution_id,
    cle.fk_vehicle_trip AS vehicle_trip_id,
    cle.fk_vehicle_load AS vehicle_load_id,
    c.pk_cylinder_id AS cylinder_id,
    c.cylinder_serial,
    p.pk_product_id AS product_id,
    p.product_name,
    cs.pk_cylinder_state_id AS cylinder_state_id,
    cs.cylinder_state,
    clel.created_at AS entered_at,
    clel.remarks
FROM public.tbl_cylinder_logistics_execution_line clel
JOIN public.tbl_cylinder_logistics_execution cle
    ON cle.pk_cylinder_logistics_execution_id = clel.fk_cylinder_logistics_execution
JOIN public.tbl_cylinder c
    ON c.pk_cylinder_id = clel.fk_cylinder
LEFT JOIN public.tbl_product p
    ON p.pk_product_id = c.fk_product
JOIN public.tbl_cylinder_states cs
    ON cs.pk_cylinder_state_id = clel.fk_cylinder_state
WHERE clel.is_active = TRUE;

-- ----------------------------------------------------------------------------
-- Unified current ownership view.
-- Expected healthy model: one row per cylinder.
-- If duplicates appear, reconciliation/harmonizer must flag it.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.vw_ownership_current_cylinder_location AS
SELECT
    'YARD-' || ownership_record_id::text AS ownership_key,
    ownership_location,
    ownership_record_id,
    cylinder_id,
    cylinder_serial,
    product_id,
    product_name,
    cylinder_state_id,
    cylinder_state,
    NULL::bigint AS customer_id,
    NULL::varchar AS customer_name,
    NULL::bigint AS supplier_id,
    NULL::varchar AS supplier_name,
    NULL::bigint AS vehicle_trip_id,
    NULL::bigint AS vehicle_load_id,
    yard_id,
    yard_code,
    yard_name,
    entered_at,
    remarks
FROM public.vw_ownership_yard_cylinder_detail

UNION ALL

SELECT
    party_type_prefix || '-' || ownership_record_id::text AS ownership_key,
    ownership_location,
    ownership_record_id,
    cylinder_id,
    cylinder_serial,
    product_id,
    product_name,
    NULL::bigint AS cylinder_state_id,
    ownership_location::text AS cylinder_state,
    customer_id,
    customer_name,
    supplier_id,
    supplier_name,
    NULL::bigint AS vehicle_trip_id,
    NULL::bigint AS vehicle_load_id,
    NULL::bigint AS yard_id,
    NULL::varchar AS yard_code,
    NULL::varchar AS yard_name,
    entered_at,
    remarks
FROM (
    SELECT
        CASE ownership_location WHEN 'CUSTOMER' THEN 'CUSTOMER' ELSE 'SUPPLIER' END AS party_type_prefix,
        *
    FROM public.vw_ownership_party_cylinder_detail
) party_rows

UNION ALL

SELECT
    'LOGISTICS-' || ownership_record_id::text AS ownership_key,
    ownership_location,
    ownership_record_id,
    cylinder_id,
    cylinder_serial,
    product_id,
    product_name,
    cylinder_state_id,
    cylinder_state,
    NULL::bigint AS customer_id,
    NULL::varchar AS customer_name,
    NULL::bigint AS supplier_id,
    NULL::varchar AS supplier_name,
    vehicle_trip_id,
    vehicle_load_id,
    NULL::bigint AS yard_id,
    NULL::varchar AS yard_code,
    NULL::varchar AS yard_name,
    entered_at,
    remarks
FROM public.vw_ownership_logistics_cylinder_detail;

-- ----------------------------------------------------------------------------
-- Summary by location/product/state.
-- ownership_key makes the view easy to map as a JPA read-only entity.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.vw_ownership_summary_by_location AS
SELECT
    ownership_location || '-' || COALESCE(product_id::text, 'NA') || '-' || COALESCE(cylinder_state, 'NA') AS ownership_key,
    ownership_location,
    product_id,
    product_name,
    cylinder_state,
    COUNT(*) AS cylinder_count,
    MIN(entered_at) AS oldest_since,
    MAX(entered_at) AS newest_since
FROM public.vw_ownership_current_cylinder_location
GROUP BY
    ownership_location,
    product_id,
    product_name,
    cylinder_state;

-- ----------------------------------------------------------------------------
-- Replacement/parallel party dashboard using ownership table instead of current status.
-- Kept separate to avoid breaking existing dashboard consumers.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.vw_party_cylinder_dashboard_ownership AS
SELECT
    cpc.party_type,
    CASE cpc.party_type
        WHEN 'CUSTOMER' THEN cust.customer_name
        WHEN 'SUPPLIER' THEN supp.supplier_name
        ELSE NULL
    END AS party_name,
    CASE cpc.party_type
        WHEN 'CUSTOMER' THEN cpc.fk_customer::text
        WHEN 'SUPPLIER' THEN cpc.fk_supplier::text
        ELSE NULL
    END AS party_id,
    COUNT(*) AS cylinders_held,
    COUNT(*) FILTER (
        WHERE EXTRACT(day FROM now() - cpc.entered_at::timestamp with time zone) > 14
          AND cpc.party_type = 'CUSTOMER'
    ) AS overdue_at_customer,
    COUNT(*) FILTER (
        WHERE EXTRACT(day FROM now() - cpc.entered_at::timestamp with time zone) > 3
          AND cpc.party_type = 'SUPPLIER'
    ) AS overdue_at_supplier,
    MIN(cpc.entered_at) AS oldest_cylinder_since,
    MAX(cpc.entered_at) AS newest_cylinder_since
FROM public.tbl_cylinder_party_custody cpc
LEFT JOIN public.tbl_customer cust
    ON cust.pk_customer_id = cpc.fk_customer
LEFT JOIN public.tbl_supplier supp
    ON supp.pk_supplier_id = cpc.fk_supplier
WHERE cpc.custody_status = 'ACTIVE'
GROUP BY
    cpc.party_type,
    CASE cpc.party_type
        WHEN 'CUSTOMER' THEN cust.customer_name
        WHEN 'SUPPLIER' THEN supp.supplier_name
        ELSE NULL
    END,
    CASE cpc.party_type
        WHEN 'CUSTOMER' THEN cpc.fk_customer::text
        WHEN 'SUPPLIER' THEN cpc.fk_supplier::text
        ELSE NULL
    END
ORDER BY cpc.party_type, COUNT(*) DESC;
