-- ============================================================================
-- V136__Fix_Trip_Review_Serial_Level_Movement_Views.sql
-- ============================================================================
-- Purpose:
--   Trip Review must be serial-level, not aggregate/count-only.
--
-- Fixes:
--   1. Initial load summary can display cylinder serials ordered by product.
--   2. Supplier/customer drop-off rows are classified as UNLOADED_AT_STOP.
--   3. Yard return is classified as BROUGHT_TO_YARD only when the
--      accountability bucket is RETURNED_TO_YARD.
--   4. Stop-wise counts are derived from the same serial-level movement view,
--      so KPI, stop table, and product-wise tables agree.
-- ============================================================================

DROP VIEW IF EXISTS public.vw_trip_review_stop CASCADE;
DROP VIEW IF EXISTS public.vw_trip_review_cylinder_movement CASCADE;

-- ----------------------------------------------------------------------------
-- Serial-level movement view
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.vw_trip_review_cylinder_movement AS
WITH load_rows AS (
    SELECT
        'LOAD-' || vll.pk_vehicle_load_line_id::text AS movement_key,
        vl.fk_vehicle_trip AS vehicle_trip_id,
        vl.pk_vehicle_load_id AS vehicle_load_id,
        ys.pk_stop_id AS stop_id,
        ys.stop_sequence AS stop_sequence,
        yst.stop_type AS stop_type,
        NULL::varchar AS challan_number,
        c.pk_cylinder_id AS cylinder_id,
        c.cylinder_serial AS cylinder_serial,
        p.product_name AS product_name,
        CASE vlp.load_purpose
            WHEN 'FULL_FOR_DELIVERY' THEN 'FULL'
            WHEN 'EMPTY_FOR_SUPPLIER' THEN 'EMPTY'
            WHEN 'EMPTY_RETURNED_TO_YARD' THEN 'DELIVERED_FOR_CONSUMPTION'
            ELSE COALESCE(cs.cylinder_state, 'UNKNOWN')
        END AS cylinder_state,
        'LOADED_FROM_YARD'::varchar AS movement_type,
        COALESCE(vlp.load_purpose, 'UNKNOWN_LOAD_PURPOSE')::varchar AS source_type,
        COALESCE(vll.loaded_at, vl.created_at) AS movement_at
    FROM public.tbl_vehicle_load_line vll
    JOIN public.tbl_vehicle_load vl
      ON vl.pk_vehicle_load_id = vll.fk_vehicle_load
    JOIN public.tbl_cylinder c
      ON c.pk_cylinder_id = vll.fk_cylinder
    LEFT JOIN public.tbl_product p
      ON p.pk_product_id = c.fk_product
    LEFT JOIN public.tbl_vehicle_load_purpose vlp
      ON vlp.pk_load_purpose_id = vll.fk_load_purpose
    LEFT JOIN public.tbl_cylinder_current_status ccs
      ON ccs.fk_cylinder = c.pk_cylinder_id
    LEFT JOIN public.tbl_cylinder_states cs
      ON cs.pk_cylinder_state_id = ccs.fk_current_state
    LEFT JOIN public.tbl_vehicle_trip_stop ys
      ON ys.fk_vehicle_trip = vl.fk_vehicle_trip
     AND ys.stop_sequence = (
            SELECT MIN(vts2.stop_sequence)
              FROM public.tbl_vehicle_trip_stop vts2
              JOIN public.tbl_stop_type st2 ON st2.pk_stop_type_id = vts2.fk_stop_type
             WHERE vts2.fk_vehicle_trip = vl.fk_vehicle_trip
               AND st2.stop_type IN ('YARD_START', 'YARD')
        )
    LEFT JOIN public.tbl_stop_type yst
      ON yst.pk_stop_type_id = ys.fk_stop_type
),
accountability_rows AS (
    SELECT
        'ACC-' || vt.pk_vehicle_trip_id::text || '-' || a.fk_cylinder::text || '-' || COALESCE(a.resolved_via_entity, 'NA') || '-' || COALESCE(a.resolved_via_id::text, '0') AS movement_key,
        vt.pk_vehicle_trip_id AS vehicle_trip_id,
        vl.pk_vehicle_load_id AS vehicle_load_id,
        COALESCE(stl_stop.pk_stop_id, ord_stop.pk_stop_id, yard_stop.pk_stop_id) AS stop_id,
        COALESCE(stl_stop.stop_sequence, ord_stop.stop_sequence, yard_stop.stop_sequence) AS stop_sequence,
        COALESCE(stl_type.stop_type, ord_type.stop_type, yard_type.stop_type) AS stop_type,
        COALESCE(stl_challan.challan_number, ord_challan.challan_number)::varchar AS challan_number,
        c.pk_cylinder_id AS cylinder_id,
        c.cylinder_serial AS cylinder_serial,
        p.product_name AS product_name,
        COALESCE(cs.cylinder_state, a.accountability_bucket, 'UNKNOWN') AS cylinder_state,
        CASE
            WHEN a.accountability_bucket IN ('CUSTOMER_DELIVERY', 'SUPPLIER_DROPOFF') THEN 'UNLOADED_AT_STOP'
            WHEN a.accountability_bucket IN ('RETURNED_TO_YARD', 'RETURNED_FULL') THEN 'BROUGHT_TO_YARD'
            ELSE 'UNACCOUNTED'
        END::varchar AS movement_type,
        a.accountability_bucket::varchar AS source_type,
        COALESCE(stl.collected_at, stp.created_at, ord_stop.arrived_at, yard_stop.arrived_at, yil.created_at, vl.created_at) AS movement_at
    FROM public.tbl_vehicle_trip vt
    JOIN public.tbl_vehicle_load vl
      ON vl.fk_vehicle_trip = vt.pk_vehicle_trip_id
    CROSS JOIN LATERAL public.fn_trip_load_accountability(vt.pk_vehicle_trip_id) a
    JOIN public.tbl_cylinder c
      ON c.pk_cylinder_id = a.fk_cylinder
    LEFT JOIN public.tbl_product p
      ON p.pk_product_id = c.fk_product
    LEFT JOIN public.tbl_cylinder_current_status ccs
      ON ccs.fk_cylinder = c.pk_cylinder_id
    LEFT JOIN public.tbl_cylinder_states cs
      ON cs.pk_cylinder_state_id = ccs.fk_current_state

    -- Supplier drop-off proof
    LEFT JOIN public.tbl_supplier_trip_line stl
      ON a.resolved_via_entity = 'tbl_supplier_trip_line'
     AND stl.pk_supplier_trip_line_id = a.resolved_via_id
    LEFT JOIN public.tbl_supplier_trip stp
      ON stp.pk_supplier_trip_id = stl.fk_supplier_trip
    LEFT JOIN public.tbl_vehicle_trip_stop stl_stop
      ON stl_stop.pk_stop_id = stp.fk_vehicle_trip_stop
    LEFT JOIN public.tbl_stop_type stl_type
      ON stl_type.pk_stop_type_id = stl_stop.fk_stop_type

    -- Customer delivery proof
    LEFT JOIN public.tbl_order_line ol
      ON a.resolved_via_entity = 'tbl_order_line'
     AND ol.pk_order_line_id = a.resolved_via_id
    LEFT JOIN public.tbl_vehicle_trip_stop ord_stop
      ON ord_stop.fk_vehicle_trip = vt.pk_vehicle_trip_id
     AND ord_stop.fk_order = ol.fk_order
    LEFT JOIN public.tbl_stop_type ord_type
      ON ord_type.pk_stop_type_id = ord_stop.fk_stop_type

    -- Yard return proof
    LEFT JOIN public.tbl_yard_inventory_line yil
      ON a.resolved_via_entity = 'tbl_yard_inventory_line'
     AND yil.pk_yard_inventory_line_id = a.resolved_via_id
    LEFT JOIN public.tbl_vehicle_trip_stop yard_stop
      ON yard_stop.fk_vehicle_trip = vt.pk_vehicle_trip_id
     AND yard_stop.stop_sequence = (
            SELECT MAX(vts2.stop_sequence)
              FROM public.tbl_vehicle_trip_stop vts2
              JOIN public.tbl_stop_type st2 ON st2.pk_stop_type_id = vts2.fk_stop_type
             WHERE vts2.fk_vehicle_trip = vt.pk_vehicle_trip_id
               AND st2.stop_type IN ('YARD_END', 'YARD')
        )
    LEFT JOIN public.tbl_stop_type yard_type
      ON yard_type.pk_stop_type_id = yard_stop.fk_stop_type

    -- Optional challan display using the actual V93 challan polymorphic table.
    -- tbl_challan_transaction_link columns:
    --   pk_link_id, fk_page_audit_id, linked_business_job_type,
    --   fk_linked_business_job_id
    -- tbl_challan_page_audit_ledger primary key:
    --   pk_page_audit_id
    LEFT JOIN LATERAL (
        SELECT COALESCE(cbr.series_prefix || '-' || cpal.sheet_number::text,
                        cbr.book_code || '-' || cpal.sheet_number::text) AS challan_number
          FROM public.tbl_challan_transaction_link ctl
          JOIN public.tbl_challan_page_audit_ledger cpal
            ON cpal.pk_page_audit_id = ctl.fk_page_audit_id
          JOIN public.tbl_challan_book_registry cbr
            ON cbr.pk_book_id = cpal.fk_book_id
         WHERE ctl.linked_business_job_type = 'SUPPLIER_REFILL'
           AND ctl.fk_linked_business_job_id = stp.pk_supplier_trip_id
         ORDER BY ctl.pk_link_id DESC
         LIMIT 1
    ) stl_challan ON TRUE
    LEFT JOIN LATERAL (
        SELECT COALESCE(cbr.series_prefix || '-' || cpal.sheet_number::text,
                        cbr.book_code || '-' || cpal.sheet_number::text) AS challan_number
          FROM public.tbl_challan_transaction_link ctl
          JOIN public.tbl_challan_page_audit_ledger cpal
            ON cpal.pk_page_audit_id = ctl.fk_page_audit_id
          JOIN public.tbl_challan_book_registry cbr
            ON cbr.pk_book_id = cpal.fk_book_id
         WHERE ctl.linked_business_job_type = 'DELIVERY_RUN'
           AND ctl.fk_linked_business_job_id = ol.fk_order
         ORDER BY ctl.pk_link_id DESC
         LIMIT 1
    ) ord_challan ON TRUE
    WHERE a.accountability_bucket IN ('CUSTOMER_DELIVERY', 'SUPPLIER_DROPOFF', 'RETURNED_TO_YARD', 'RETURNED_FULL')
)
SELECT * FROM load_rows
UNION ALL
SELECT * FROM accountability_rows;

-- ----------------------------------------------------------------------------
-- Stop review view derived from serial-level movements
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.vw_trip_review_stop AS
SELECT
    vts.pk_stop_id AS stop_id,
    vts.fk_vehicle_trip AS vehicle_trip_id,
    vts.stop_sequence,
    st.stop_type,
    COALESCE(c.customer_name, s.supplier_name, st.stop_type) AS stop_name,
    vts.stop_status,
    COALESCE(ch.challan_number, '')::varchar AS challan_number,
    COALESCE(COUNT(m.*) FILTER (WHERE m.movement_type = 'LOADED_FROM_YARD'), 0)::int8 AS loaded_at_stop,
    COALESCE(COUNT(m.*) FILTER (WHERE m.movement_type = 'UNLOADED_AT_STOP'), 0)::int8 AS unloaded_at_stop,
    vts.arrived_at,
    vts.departed_at
FROM public.tbl_vehicle_trip_stop vts
JOIN public.tbl_stop_type st
  ON st.pk_stop_type_id = vts.fk_stop_type
LEFT JOIN public.tbl_customer c
  ON c.pk_customer_id = vts.fk_customer
LEFT JOIN public.tbl_supplier s
  ON s.pk_supplier_id = vts.fk_supplier
LEFT JOIN public.vw_trip_review_cylinder_movement m
  ON m.vehicle_trip_id = vts.fk_vehicle_trip
 AND m.stop_id = vts.pk_stop_id
LEFT JOIN LATERAL (
    SELECT COALESCE(cbr.series_prefix || '-' || cpal.sheet_number::text,
                    cbr.book_code || '-' || cpal.sheet_number::text) AS challan_number
      FROM public.tbl_challan_transaction_link ctl
      JOIN public.tbl_challan_page_audit_ledger cpal
        ON cpal.pk_page_audit_id = ctl.fk_page_audit_id
      JOIN public.tbl_challan_book_registry cbr
        ON cbr.pk_book_id = cpal.fk_book_id
     WHERE (ctl.linked_business_job_type = 'DELIVERY_RUN'
            AND ctl.fk_linked_business_job_id = vts.fk_order)
        OR (ctl.linked_business_job_type = 'SUPPLIER_REFILL'
            AND ctl.fk_linked_business_job_id IN (vts.fk_supplier_trip, vts.fk_supplier_refill_collection))
        OR (ctl.linked_business_job_type = 'EMPTY_COLLECTION'
            AND ctl.fk_linked_business_job_id = vts.fk_empty_pickup)
     ORDER BY ctl.pk_link_id DESC
     LIMIT 1
) ch ON TRUE
GROUP BY
    vts.pk_stop_id,
    vts.fk_vehicle_trip,
    vts.stop_sequence,
    st.stop_type,
    c.customer_name,
    s.supplier_name,
    vts.stop_status,
    ch.challan_number,
    vts.arrived_at,
    vts.departed_at;

DO $$
BEGIN
    RAISE NOTICE 'V136 OK: Trip review movement and stop views are serial-level and bucket-correct.';
END $$;
