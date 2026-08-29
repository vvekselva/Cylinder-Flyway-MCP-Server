-- =============================================================================
-- V109__Add_Review_Status_To_Vehicle_Trip.sql
-- =============================================================================
--------------------------------------------------------------------------------

-- PURPOSE
-- ─────────────────────────────────────────────────────────────────────────────
-- Adds fk_review_status to tbl_vehicle_trip.
---------------------------------------------

-- Default:
--   NOT_REVIEWED
-----------------

-- REFERENCES
-- ─────────────────────────────────────────────────────────────────────────────
-- tbl_vehicle_review_status
--   NOT_REVIEWED
--   REVIEWED
-------------

-- DEPENDENCIES
-- ─────────────────────────────────────────────────────────────────────────────
-- V46   tbl_vehicle_trip
-- V108  tbl_vehicle_review_status
-- =============================================================================

-- =============================================================================
-- STEP 1 — Resolve NOT_REVIEWED status id
-- =============================================================================

DO $$
DECLARE
    v_not_reviewed_id int8;
BEGIN
    SELECT pk_vehicle_review_status_id
      INTO v_not_reviewed_id
      FROM public.tbl_vehicle_review_status
     WHERE review_status = 'NOT_REVIEWED';

    IF v_not_reviewed_id IS NULL THEN
        RAISE EXCEPTION
            'V109 FAILED: NOT_REVIEWED not found in tbl_vehicle_review_status';
    END IF;

    ALTER TABLE public.tbl_vehicle_trip
        ADD COLUMN IF NOT EXISTS fk_review_status int8;

    UPDATE public.tbl_vehicle_trip
       SET fk_review_status = v_not_reviewed_id
     WHERE fk_review_status IS NULL;

    EXECUTE format(
        'ALTER TABLE public.tbl_vehicle_trip ALTER COLUMN fk_review_status SET DEFAULT %s',
        v_not_reviewed_id
    );

    ALTER TABLE public.tbl_vehicle_trip
        ALTER COLUMN fk_review_status SET NOT NULL;

    RAISE NOTICE
        'V109 OK: fk_review_status added/defaulted to NOT_REVIEWED id=%',
        v_not_reviewed_id;
END;
$$;


ALTER TABLE public.tbl_vehicle_trip
DROP CONSTRAINT IF EXISTS fk_vehicle_trip_review_status;

ALTER TABLE public.tbl_vehicle_trip
ADD CONSTRAINT fk_vehicle_trip_review_status
FOREIGN KEY (fk_review_status)
REFERENCES public.tbl_vehicle_review_status(pk_vehicle_review_status_id);


CREATE OR REPLACE VIEW public.vw_not_reviewed_trips
AS
SELECT
    vt.pk_vehicle_trip_id,
    ts.status_name AS trip_status,
    ts.display_order AS status_order,
    v.vehicle_number,
    d.driver_name,
    vt.trip_started_at,
    vt.trip_loaded_at,
    vt.trip_departed_at,
    CASE
        WHEN vt.trip_departed_at IS NOT NULL
        THEN EXTRACT(hour FROM now() - vt.trip_departed_at::timestamp with time zone)::integer
        ELSE NULL::integer
    END AS hours_since_departure,
    vt.audit_notes,
    vrs.review_status
FROM public.tbl_vehicle_trip vt
JOIN public.tbl_trip_status ts
    ON ts.pk_trip_status_id = vt.fk_trip_status
JOIN public.tbl_vehicle v
    ON v.pk_vehicle_id = vt.fk_vehicle
JOIN public.tbl_driver d
    ON d.pk_driver_id = vt.fk_driver
JOIN public.tbl_vehicle_review_status vrs
    ON vrs.pk_vehicle_review_status_id = vt.fk_review_status
WHERE vrs.review_status = 'NOT_REVIEWED'
ORDER BY vt.trip_started_at DESC;


ALTER VIEW public.vw_not_reviewed_trips OWNER TO postgres;
GRANT ALL ON TABLE public.vw_not_reviewed_trips TO postgres;


DO $$
DECLARE
    v_column_exists boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1
          FROM information_schema.columns
         WHERE table_schema = 'public'
           AND table_name = 'tbl_vehicle_trip'
           AND column_name = 'fk_review_status'
    )
    INTO v_column_exists;

    IF NOT v_column_exists THEN
        RAISE WARNING 'V109 VERIFY FAILED: fk_review_status column missing.';
    ELSE
        RAISE NOTICE 'V109 VERIFY OK: fk_review_status column exists.';
    END IF;
END;
$$;