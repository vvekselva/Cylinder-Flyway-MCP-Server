-- ============================================================================
-- V139__Global_Cylinder_Search_Ownership_View.sql
--
-- Purpose:
-- Global cylinder search read model for /search/cylinder/{searchText}.
--
-- This replaces the old read dependency:
--   tbl_cylinder + tbl_cylinder_current_status
--
-- with ownership-model sources:
--   tbl_yard_inventory_line
--   tbl_cylinder_logistics_execution_line
--   tbl_cylinder_logistics_execution
--   tbl_cylinder_party_custody
--
-- Important:
-- This is a READ MODEL only.
-- It must not be used for ownership transitions.
-- ============================================================================

DROP VIEW IF EXISTS public.vw_cylinder_global_search;

CREATE OR REPLACE VIEW public.vw_cylinder_global_search AS
WITH ownership_rows AS (

    -- ========================================================================
    -- 1. Active Yard ownership
    -- ========================================================================
    SELECT
        c.pk_cylinder_id AS cylinder_id,
        c.cylinder_serial,
        c.description,
        c.total_quantity,
        p.pk_product_id AS product_id,
        p.product_name,

        cs.pk_cylinder_state_id AS cylinder_state_id,
        cs.cylinder_state,

        'YARD'::varchar AS ownership_location,
        yil.pk_yard_inventory_line_id AS ownership_record_id,

        NULL::bigint AS customer_id,
        NULL::varchar AS customer_name,

        NULL::bigint AS supplier_id,
        NULL::varchar AS supplier_name,

        NULL::bigint AS vehicle_trip_id,
        NULL::bigint AS vehicle_load_id,

        yi.pk_yard_inventory_id AS yard_id,
        yi.yard_code,
        yi.yard_name,

        yil.entry_date AS entered_at

    FROM public.tbl_yard_inventory_line yil
    JOIN public.tbl_yard_inventory yi
        ON yi.pk_yard_inventory_id = yil.fk_yard_inventory
    JOIN public.tbl_cylinder c
        ON c.pk_cylinder_id = yil.fk_cylinder
    LEFT JOIN public.tbl_product p
        ON p.pk_product_id = c.fk_product
    JOIN public.tbl_cylinder_states cs
        ON cs.pk_cylinder_state_id = yil.fk_cylinder_state
    WHERE yil.is_active = TRUE


    UNION ALL


    -- ========================================================================
    -- 2. Active Logistics / Vehicle ownership
    -- ========================================================================
    SELECT
        c.pk_cylinder_id AS cylinder_id,
        c.cylinder_serial,
        c.description,
        c.total_quantity,
        p.pk_product_id AS product_id,
        p.product_name,

        cs.pk_cylinder_state_id AS cylinder_state_id,
        cs.cylinder_state,

        'LOGISTICS'::varchar AS ownership_location,
        clel.pk_cylinder_logistics_execution_line_id AS ownership_record_id,

        NULL::bigint AS customer_id,
        NULL::varchar AS customer_name,

        NULL::bigint AS supplier_id,
        NULL::varchar AS supplier_name,

        cle.fk_vehicle_trip AS vehicle_trip_id,
        cle.fk_vehicle_load AS vehicle_load_id,

        NULL::bigint AS yard_id,
        NULL::varchar AS yard_code,
        NULL::varchar AS yard_name,

        clel.created_at AS entered_at

    FROM public.tbl_cylinder_logistics_execution_line clel
    JOIN public.tbl_cylinder_logistics_execution cle
        ON cle.pk_cylinder_logistics_execution_id =
           clel.fk_cylinder_logistics_execution
    JOIN public.tbl_cylinder c
        ON c.pk_cylinder_id = clel.fk_cylinder
    LEFT JOIN public.tbl_product p
        ON p.pk_product_id = c.fk_product
    JOIN public.tbl_cylinder_states cs
        ON cs.pk_cylinder_state_id = clel.fk_cylinder_state
    WHERE clel.is_active = TRUE
      AND cle.execution_status = 'OPEN'


    UNION ALL


    -- ========================================================================
    -- 3. Active Customer custody
    -- ========================================================================
    SELECT
        c.pk_cylinder_id AS cylinder_id,
        c.cylinder_serial,
        c.description,
        c.total_quantity,
        p.pk_product_id AS product_id,
        p.product_name,

        cs.pk_cylinder_state_id AS cylinder_state_id,
        cs.cylinder_state,

        'CUSTOMER'::varchar AS ownership_location,
        cpc.pk_custody_id AS ownership_record_id,

        cust.pk_customer_id AS customer_id,
        cust.customer_name,

        NULL::bigint AS supplier_id,
        NULL::varchar AS supplier_name,

        cpc.fk_entry_trip AS vehicle_trip_id,
        cpc.fk_entry_load AS vehicle_load_id,

        NULL::bigint AS yard_id,
        NULL::varchar AS yard_code,
        NULL::varchar AS yard_name,

        cpc.entered_at AS entered_at

    FROM public.tbl_cylinder_party_custody cpc
    JOIN public.tbl_cylinder c
        ON c.pk_cylinder_id = cpc.fk_cylinder
    LEFT JOIN public.tbl_product p
        ON p.pk_product_id = c.fk_product
    LEFT JOIN public.tbl_customer cust
        ON cust.pk_customer_id = cpc.fk_customer
    JOIN public.tbl_cylinder_states cs
        ON cs.cylinder_state = 'DELIVERED_FOR_CONSUMPTION'
    WHERE cpc.custody_status = 'ACTIVE'
      AND cpc.party_type = 'CUSTOMER'


    UNION ALL


    -- ========================================================================
    -- 4. Active Supplier custody
    -- ========================================================================
    SELECT
        c.pk_cylinder_id AS cylinder_id,
        c.cylinder_serial,
        c.description,
        c.total_quantity,
        p.pk_product_id AS product_id,
        p.product_name,

        cs.pk_cylinder_state_id AS cylinder_state_id,
        cs.cylinder_state,

        'SUPPLIER'::varchar AS ownership_location,
        cpc.pk_custody_id AS ownership_record_id,

        NULL::bigint AS customer_id,
        NULL::varchar AS customer_name,

        supp.pk_supplier_id AS supplier_id,
        supp.supplier_name,

        cpc.fk_entry_trip AS vehicle_trip_id,
        cpc.fk_entry_load AS vehicle_load_id,

        NULL::bigint AS yard_id,
        NULL::varchar AS yard_code,
        NULL::varchar AS yard_name,

        cpc.entered_at AS entered_at

    FROM public.tbl_cylinder_party_custody cpc
    JOIN public.tbl_cylinder c
        ON c.pk_cylinder_id = cpc.fk_cylinder
    LEFT JOIN public.tbl_product p
        ON p.pk_product_id = c.fk_product
    LEFT JOIN public.tbl_supplier supp
        ON supp.pk_supplier_id = cpc.fk_supplier
    JOIN public.tbl_cylinder_states cs
        ON cs.cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL'
    WHERE cpc.custody_status = 'ACTIVE'
      AND cpc.party_type = 'SUPPLIER'
),

ownership_count AS (
    SELECT
        cylinder_id,
        COUNT(*) AS active_ownership_count
    FROM ownership_rows
    GROUP BY cylinder_id
),

normal_or_unknown_rows AS (
    SELECT
        COALESCE(
            o.ownership_location || '-' || o.ownership_record_id::text,
            'UNKNOWN-' || c.pk_cylinder_id::text
        ) AS search_key,

        c.pk_cylinder_id AS cylinder_id,
        c.cylinder_serial,
        c.description,
        c.total_quantity,

        COALESCE(o.product_id, p.pk_product_id) AS product_id,
        COALESCE(o.product_name, p.product_name) AS product_name,

        o.cylinder_state_id,

        CASE
            WHEN oc.active_ownership_count IS NULL THEN 'OWNERSHIP_UNKNOWN'
            ELSE o.cylinder_state
        END AS cylinder_state,

        CASE
            WHEN oc.active_ownership_count IS NULL THEN 'UNKNOWN'
            ELSE o.ownership_location
        END AS ownership_location,

        o.ownership_record_id,

        o.customer_id,
        o.customer_name,

        o.supplier_id,
        o.supplier_name,

        o.vehicle_trip_id,
        o.vehicle_load_id,

        o.yard_id,
        o.yard_code,
        o.yard_name,

        o.entered_at,

        COALESCE(oc.active_ownership_count, 0) AS active_ownership_count,

        CASE
            WHEN oc.active_ownership_count IS NULL THEN 'UNKNOWN'
            ELSE 'OK'
        END AS ownership_status

    FROM public.tbl_cylinder c
    LEFT JOIN public.tbl_product p
        ON p.pk_product_id = c.fk_product
    LEFT JOIN ownership_count oc
        ON oc.cylinder_id = c.pk_cylinder_id
    LEFT JOIN ownership_rows o
        ON o.cylinder_id = c.pk_cylinder_id
    WHERE COALESCE(oc.active_ownership_count, 0) <= 1
),

conflict_rows AS (
    SELECT
        'CONFLICT-' || c.pk_cylinder_id::text AS search_key,

        c.pk_cylinder_id AS cylinder_id,
        c.cylinder_serial,
        c.description,
        c.total_quantity,

        p.pk_product_id AS product_id,
        p.product_name,

        NULL::bigint AS cylinder_state_id,
        'OWNERSHIP_CONFLICT'::varchar AS cylinder_state,
        'CONFLICT'::varchar AS ownership_location,

        NULL::bigint AS ownership_record_id,

        NULL::bigint AS customer_id,
        NULL::varchar AS customer_name,

        NULL::bigint AS supplier_id,
        NULL::varchar AS supplier_name,

        NULL::bigint AS vehicle_trip_id,
        NULL::bigint AS vehicle_load_id,

        NULL::bigint AS yard_id,
        NULL::varchar AS yard_code,
        NULL::varchar AS yard_name,

        NULL::timestamp AS entered_at,

        oc.active_ownership_count,

        'CONFLICT'::varchar AS ownership_status

    FROM public.tbl_cylinder c
    LEFT JOIN public.tbl_product p
        ON p.pk_product_id = c.fk_product
    JOIN ownership_count oc
        ON oc.cylinder_id = c.pk_cylinder_id
    WHERE oc.active_ownership_count > 1
)

SELECT * FROM normal_or_unknown_rows
UNION ALL
SELECT * FROM conflict_rows;


-- ============================================================================
-- Supporting index for global serial search.
-- Note:
-- For LIKE '%text%', PostgreSQL may still scan unless pg_trgm is used.
-- This index is still useful for exact / prefix / lower-case comparisons.
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_tbl_cylinder_lower_serial
ON public.tbl_cylinder (LOWER(cylinder_serial));


COMMENT ON VIEW public.vw_cylinder_global_search IS
'Global cylinder search read model for /search/cylinder/{searchText}. 
Combines active Yard, Logistics, Customer custody, Supplier custody and UNKNOWN fallback from tbl_cylinder. 
This is read-only and must not be used for ownership transitions.';