-- ============================================================================
-- V129__Trip_Review_Dashboard_Views.sql
-- Read-only views for Trip Review screen.
-- Uses the existing tbl_vehicle_review_status and tbl_vehicle_trip.fk_review_status.
-- ============================================================================

DROP VIEW IF EXISTS public.vw_trip_review_cylinder_movement;
DROP VIEW IF EXISTS public.vw_trip_review_stop;
DROP VIEW IF EXISTS public.vw_trip_review_load_summary;
DROP VIEW IF EXISTS public.vw_trip_review_header;

CREATE OR REPLACE VIEW public.vw_trip_review_header AS
SELECT
    vt.pk_vehicle_trip_id AS vehicle_trip_id,
    vl.pk_vehicle_load_id AS vehicle_load_id,
    v.vehicle_number,
    d.driver_name,
    ts.status_name AS trip_status,
    ts.is_terminal AS trip_is_terminal,
    vrs.review_status,
    vt.trip_started_at,
    vt.trip_loaded_at,
    vt.trip_departed_at,
    vl.total_cylinders_loaded,
    COUNT(DISTINCT s.pk_stop_id) AS stop_count,
    COUNT(DISTINCT CASE WHEN s.stop_status = 'COMPLETED' THEN s.pk_stop_id END) AS completed_stop_count
FROM public.tbl_vehicle_trip vt
JOIN public.tbl_vehicle v ON v.pk_vehicle_id = vt.fk_vehicle
JOIN public.tbl_driver d ON d.pk_driver_id = vt.fk_driver
JOIN public.tbl_trip_status ts ON ts.pk_trip_status_id = vt.fk_trip_status
JOIN public.tbl_vehicle_review_status vrs ON vrs.pk_vehicle_review_status_id = vt.fk_review_status
LEFT JOIN public.tbl_vehicle_load vl ON vl.fk_vehicle_trip = vt.pk_vehicle_trip_id
LEFT JOIN public.tbl_vehicle_trip_stop s ON s.fk_vehicle_trip = vt.pk_vehicle_trip_id
GROUP BY vt.pk_vehicle_trip_id, vl.pk_vehicle_load_id, v.vehicle_number, d.driver_name,
         ts.status_name, ts.is_terminal, vrs.review_status, vt.trip_started_at,
         vt.trip_loaded_at, vt.trip_departed_at, vl.total_cylinders_loaded;

CREATE OR REPLACE VIEW public.vw_trip_review_load_summary AS
SELECT
    vl.fk_vehicle_trip || '-' || COALESCE(p.pk_product_id, 0) || '-' || COALESCE(cs.cylinder_state, 'UNKNOWN') || '-' || COALESCE(vlp.load_purpose, 'UNSPECIFIED') AS review_load_summary_key,
    vl.fk_vehicle_trip AS vehicle_trip_id,
    vl.pk_vehicle_load_id AS vehicle_load_id,
    p.pk_product_id AS product_id,
    p.product_name,
    COALESCE(cs.cylinder_state, 'UNKNOWN') AS cylinder_state,
    COALESCE(vlp.load_purpose, 'UNSPECIFIED') AS load_purpose,
    COUNT(1) AS cylinder_count
FROM public.tbl_vehicle_load vl
JOIN public.tbl_vehicle_load_line vll ON vll.fk_vehicle_load = vl.pk_vehicle_load_id
JOIN public.tbl_cylinder c ON c.pk_cylinder_id = vll.fk_cylinder
LEFT JOIN public.tbl_product p ON p.pk_product_id = c.fk_product
LEFT JOIN public.tbl_vehicle_load_purpose vlp ON vlp.pk_load_purpose_id = vll.fk_load_purpose
LEFT JOIN public.tbl_cylinder_logistics_execution cle ON cle.fk_vehicle_load = vl.pk_vehicle_load_id
LEFT JOIN public.tbl_cylinder_logistics_execution_line clel
       ON clel.fk_cylinder_logistics_execution = cle.pk_cylinder_logistics_execution_id
      AND clel.fk_cylinder = c.pk_cylinder_id
LEFT JOIN public.tbl_cylinder_states cs ON cs.pk_cylinder_state_id = clel.fk_cylinder_state
GROUP BY vl.fk_vehicle_trip, vl.pk_vehicle_load_id, p.pk_product_id, p.product_name,
         COALESCE(cs.cylinder_state, 'UNKNOWN'), COALESCE(vlp.load_purpose, 'UNSPECIFIED');

CREATE OR REPLACE VIEW public.vw_trip_review_cylinder_movement AS
WITH load_rows AS (
    SELECT
        'LOAD-' || vll.pk_vehicle_load_line_id::text AS movement_key,
        vl.fk_vehicle_trip AS vehicle_trip_id,
        vl.pk_vehicle_load_id AS vehicle_load_id,
        NULL::bigint AS stop_id,
        NULL::int4 AS stop_sequence,
        'YARD_START'::varchar AS stop_type,
        NULL::text AS challan_number,
        c.pk_cylinder_id AS cylinder_id,
        c.cylinder_serial,
        p.product_name,
        COALESCE(cs.cylinder_state, 'UNKNOWN') AS cylinder_state,
        'LOADED_FROM_YARD'::text AS movement_type,
        'YARD'::text AS source_type,
        vll.loaded_at AS movement_at
    FROM public.tbl_vehicle_load vl
    JOIN public.tbl_vehicle_load_line vll ON vll.fk_vehicle_load = vl.pk_vehicle_load_id
    JOIN public.tbl_cylinder c ON c.pk_cylinder_id = vll.fk_cylinder
    LEFT JOIN public.tbl_product p ON p.pk_product_id = c.fk_product
    LEFT JOIN public.tbl_cylinder_logistics_execution cle ON cle.fk_vehicle_load = vl.pk_vehicle_load_id
    LEFT JOIN public.tbl_cylinder_logistics_execution_line clel
           ON clel.fk_cylinder_logistics_execution = cle.pk_cylinder_logistics_execution_id
          AND clel.fk_cylinder = c.pk_cylinder_id
    LEFT JOIN public.tbl_cylinder_states cs ON cs.pk_cylinder_state_id = clel.fk_cylinder_state
), stop_rows AS (
    SELECT
        'STOP-' || s.pk_stop_id::text || '-' || c.pk_cylinder_id::text AS movement_key,
        s.fk_vehicle_trip AS vehicle_trip_id,
        vl.pk_vehicle_load_id AS vehicle_load_id,
        s.pk_stop_id AS stop_id,
        s.stop_sequence,
        st.stop_type,
        COALESCE(cbr.series_prefix || '-' || cpal.sheet_number::text, cbr.book_code || '-' || cpal.sheet_number::text, s.supplier_reference) AS challan_number,
        c.pk_cylinder_id AS cylinder_id,
        c.cylinder_serial,
        p.product_name,
        COALESCE(own.cylinder_state, 'UNKNOWN') AS cylinder_state,
        'UNLOADED_AT_STOP'::text AS movement_type,
        CASE
            WHEN st.stop_type = 'SUPPLIER_DROPOFF' THEN 'YARD_TO_SUPPLIER'
            WHEN st.stop_type = 'CUSTOMER_DELIVERY' THEN 'YARD_TO_CUSTOMER'
            WHEN st.stop_type = 'EMPTY_PICKUP' THEN 'CUSTOMER_TO_VEHICLE'
            ELSE st.stop_type
        END AS source_type,
        COALESCE(s.departed_at, s.arrived_at) AS movement_at
    FROM public.tbl_vehicle_trip_stop s
    JOIN public.tbl_stop_type st ON st.pk_stop_type_id = s.fk_stop_type
    JOIN public.tbl_vehicle_load vl ON vl.fk_vehicle_trip = s.fk_vehicle_trip
    LEFT JOIN public.tbl_challan_transaction_link ctl
      ON (ctl.linked_business_job_type = 'DELIVERY_RUN' AND ctl.fk_linked_business_job_id = s.fk_order)
      OR (ctl.linked_business_job_type = 'SUPPLIER_REFILL' AND ctl.fk_linked_business_job_id = s.fk_supplier_trip)
      OR (ctl.linked_business_job_type = 'EMPTY_COLLECTION' AND ctl.fk_linked_business_job_id = s.fk_empty_pickup)
    LEFT JOIN public.tbl_challan_page_audit_ledger cpal ON cpal.pk_page_audit_id = ctl.fk_page_audit_id
    LEFT JOIN public.tbl_challan_book_registry cbr ON cbr.pk_book_id = cpal.fk_book_id
    JOIN public.tbl_cylinder_logistics_execution cle ON cle.fk_vehicle_trip = s.fk_vehicle_trip
    JOIN public.tbl_cylinder_logistics_execution_line clel ON clel.fk_cylinder_logistics_execution = cle.pk_cylinder_logistics_execution_id
    JOIN public.tbl_cylinder c ON c.pk_cylinder_id = clel.fk_cylinder
    LEFT JOIN public.tbl_product p ON p.pk_product_id = c.fk_product
    LEFT JOIN public.vw_ownership_current_cylinder_location own ON own.cylinder_id = c.pk_cylinder_id
    WHERE s.stop_status IN ('TALLY_PENDING', 'VARIANCE_PENDING', 'COMPLETED')
      AND st.stop_type NOT IN ('YARD_START', 'YARD_END')
), yard_return_rows AS (
    SELECT
        'YARDRETURN-' || clel.pk_cylinder_logistics_execution_line_id::text AS movement_key,
        cle.fk_vehicle_trip AS vehicle_trip_id,
        cle.fk_vehicle_load AS vehicle_load_id,
        NULL::bigint AS stop_id,
        NULL::int4 AS stop_sequence,
        'YARD_END'::varchar AS stop_type,
        NULL::text AS challan_number,
        c.pk_cylinder_id AS cylinder_id,
        c.cylinder_serial,
        p.product_name,
        cs.cylinder_state,
        'BROUGHT_TO_YARD'::text AS movement_type,
        'TRIP_RETURN_TO_YARD'::text AS source_type,
        COALESCE(clel.completed_at, cle.closed_at, clel.updated_at) AS movement_at
    FROM public.tbl_cylinder_logistics_execution cle
    JOIN public.tbl_cylinder_logistics_execution_line clel
      ON clel.fk_cylinder_logistics_execution = cle.pk_cylinder_logistics_execution_id
    JOIN public.tbl_cylinder c ON c.pk_cylinder_id = clel.fk_cylinder
    LEFT JOIN public.tbl_product p ON p.pk_product_id = c.fk_product
    LEFT JOIN public.tbl_cylinder_states cs ON cs.pk_cylinder_state_id = clel.fk_cylinder_state
    WHERE clel.is_completed = TRUE
      AND cle.execution_status IN ('COMPLETED', 'CANCELLED')
)
SELECT * FROM load_rows
UNION ALL
SELECT * FROM stop_rows
UNION ALL
SELECT * FROM yard_return_rows;

CREATE OR REPLACE VIEW public.vw_trip_review_stop AS
WITH challan_for_stop AS (
    SELECT
        s.pk_stop_id,
        COALESCE(cbr.series_prefix || '-' || cpal.sheet_number::text,
                 cbr.book_code || '-' || cpal.sheet_number::text,
                 s.supplier_reference) AS challan_number
    FROM public.tbl_vehicle_trip_stop s
    LEFT JOIN public.tbl_challan_transaction_link ctl
      ON (ctl.linked_business_job_type = 'DELIVERY_RUN' AND ctl.fk_linked_business_job_id = s.fk_order)
      OR (ctl.linked_business_job_type = 'SUPPLIER_REFILL' AND ctl.fk_linked_business_job_id = s.fk_supplier_trip)
      OR (ctl.linked_business_job_type = 'EMPTY_COLLECTION' AND ctl.fk_linked_business_job_id = s.fk_empty_pickup)
    LEFT JOIN public.tbl_challan_page_audit_ledger cpal ON cpal.pk_page_audit_id = ctl.fk_page_audit_id
    LEFT JOIN public.tbl_challan_book_registry cbr ON cbr.pk_book_id = cpal.fk_book_id
), movement_counts AS (
    SELECT stop_id,
           SUM(CASE WHEN movement_type = 'LOADED_FROM_YARD' THEN 1 ELSE 0 END) AS loaded_at_stop,
           SUM(CASE WHEN movement_type = 'UNLOADED_AT_STOP' THEN 1 ELSE 0 END) AS unloaded_at_stop
    FROM public.vw_trip_review_cylinder_movement
    GROUP BY stop_id
)
SELECT
    s.pk_stop_id AS stop_id,
    s.fk_vehicle_trip AS vehicle_trip_id,
    s.stop_sequence,
    st.stop_type,
    COALESCE(c.customer_name, sup.supplier_name, st.stop_type) AS stop_name,
    s.stop_status,
    cfs.challan_number,
    COALESCE(mc.loaded_at_stop, 0) AS loaded_at_stop,
    COALESCE(mc.unloaded_at_stop, 0) AS unloaded_at_stop,
    s.arrived_at,
    s.departed_at
FROM public.tbl_vehicle_trip_stop s
JOIN public.tbl_stop_type st ON st.pk_stop_type_id = s.fk_stop_type
LEFT JOIN public.tbl_customer c ON c.pk_customer_id = s.fk_customer
LEFT JOIN public.tbl_supplier sup ON sup.pk_supplier_id = s.fk_supplier
LEFT JOIN challan_for_stop cfs ON cfs.pk_stop_id = s.pk_stop_id
LEFT JOIN movement_counts mc ON mc.stop_id = s.pk_stop_id;

ALTER VIEW public.vw_trip_review_header OWNER TO postgres;
ALTER VIEW public.vw_trip_review_load_summary OWNER TO postgres;
ALTER VIEW public.vw_trip_review_stop OWNER TO postgres;
ALTER VIEW public.vw_trip_review_cylinder_movement OWNER TO postgres;
GRANT ALL ON TABLE public.vw_trip_review_header TO postgres;
GRANT ALL ON TABLE public.vw_trip_review_load_summary TO postgres;
GRANT ALL ON TABLE public.vw_trip_review_stop TO postgres;
GRANT ALL ON TABLE public.vw_trip_review_cylinder_movement TO postgres;
