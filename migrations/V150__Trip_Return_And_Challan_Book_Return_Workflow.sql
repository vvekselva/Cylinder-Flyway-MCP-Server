-- =====================================================================
-- V150__Trip_Return_And_Challan_Book_Return_Workflow.sql
-- =====================================================================
-- Purpose:
--   Split physical trip return from final trip closure.
--
-- Business meaning:
--   Proceeding -> Returned : vehicle/book physically returned to office.
--                            Challan leaf review can be captured and books
--                            can be released back to IN_OFFICE.
--   Returned   -> Halt     : challan entries completed; trip is finally closed
--                            and no further trip challan entry is allowed.
--
-- Existing challan tables already had:
--   book_location_enum : IN_OFFICE, IN_VEHICLE_TRANSIT, EXHAUSTED_ARCHIVED
--   page_status_enum   : UNUSED, USED_CONFIRMED, CANCELLED_SPOILED,
--                        FLAGGED_MISSING
--
-- New leaf status:
--   PHYSICALLY_USED_PENDING_ENTRY : leaf was physically consumed before the
--   first unused/next available number during return, but office challan entry
--   is still pending. The existing challan consumption lookup is widened to
--   allow both UNUSED and PHYSICALLY_USED_PENDING_ENTRY.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Add new challan leaf status for the office-entry gap
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM pg_enum e
          JOIN pg_type t ON t.oid = e.enumtypid
         WHERE t.typname = 'page_status_enum'
           AND e.enumlabel = 'PHYSICALLY_USED_PENDING_ENTRY'
    ) THEN
        ALTER TYPE public.page_status_enum ADD VALUE 'PHYSICALLY_USED_PENDING_ENTRY';
    END IF;
END $$;

-- ---------------------------------------------------------------------
-- 2. Add Returned trip status between Proceeding and Halt
-- ---------------------------------------------------------------------
ALTER TABLE public.tbl_trip_status
    DROP CONSTRAINT IF EXISTS tbl_trip_status_name_chk;

ALTER TABLE public.tbl_trip_status
    ADD CONSTRAINT tbl_trip_status_name_chk
    CHECK (status_name IN ('Started','Loaded','Proceeding','Returned','Halt'));

INSERT INTO public.tbl_trip_status (status_name, display_order, is_terminal, description)
VALUES ('Returned', 4, false,
        'Vehicle and physical challan books returned to office; challan entry is pending.')
ON CONFLICT (status_name) DO UPDATE
SET display_order = EXCLUDED.display_order,
    is_terminal = EXCLUDED.is_terminal,
    description = EXCLUDED.description;

UPDATE public.tbl_trip_status
   SET display_order = 5,
       is_terminal = true,
       description = 'Challan entry completed and trip closed. No more trip challan edits are allowed.'
 WHERE status_name = 'Halt';

-- ---------------------------------------------------------------------
-- 3. Recreate transition validator: Started -> Loaded -> Proceeding -> Returned -> Halt
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_validate_trip_status_transition()
RETURNS TRIGGER AS $$
DECLARE
    v_old_order         int4;
    v_new_order         int4;
    v_old_name          varchar(50);
    v_new_name          varchar(50);
    v_load_id           int8;
    v_yard_start_exists boolean;
    v_yard_end_completed  boolean;
    v_intransit_count     int4 := 0;
    v_intransit_serials   text := '';
BEGIN
    IF NEW.fk_trip_status = OLD.fk_trip_status THEN RETURN NEW; END IF;

    SELECT status_name, display_order INTO v_old_name, v_old_order
      FROM public.tbl_trip_status WHERE pk_trip_status_id = OLD.fk_trip_status;

    SELECT status_name, display_order INTO v_new_name, v_new_order
      FROM public.tbl_trip_status WHERE pk_trip_status_id = NEW.fk_trip_status;

    IF v_new_order <> v_old_order + 1 THEN
        RAISE EXCEPTION
            'Invalid trip status transition: % -> %. Valid sequence: Started -> Loaded -> Proceeding -> Returned -> Halt.',
            v_old_name, v_new_name;
    END IF;

    CASE v_new_name
        WHEN 'Loaded'     THEN NEW.trip_loaded_at   := now();
        WHEN 'Proceeding' THEN NEW.trip_departed_at := now();
        WHEN 'Halt'       THEN NEW.trip_closed_at   := now();
        ELSE NULL;
    END CASE;

    SELECT pk_vehicle_load_id INTO v_load_id
      FROM public.tbl_vehicle_load
     WHERE fk_vehicle_trip = NEW.pk_vehicle_trip_id
     ORDER BY pk_vehicle_load_id DESC
     LIMIT 1;

    -- Gate A: Started -> Loaded requires a load and YARD_START stop.
    IF v_new_name = 'Loaded' THEN
        IF v_load_id IS NULL THEN
            RAISE EXCEPTION
                'Trip % cannot advance to Loaded: no vehicle load exists for this trip.',
                NEW.pk_vehicle_trip_id;
        END IF;

        SELECT EXISTS (
            SELECT 1
              FROM public.tbl_vehicle_trip_stop vts
              JOIN public.tbl_stop_type st ON st.pk_stop_type_id = vts.fk_stop_type
             WHERE vts.fk_vehicle_trip = NEW.pk_vehicle_trip_id
               AND st.stop_type = 'YARD_START'
        ) INTO v_yard_start_exists;

        IF NOT v_yard_start_exists THEN
            RAISE EXCEPTION
                'Trip % cannot advance to Loaded: a YARD_START stop must be recorded first.',
                NEW.pk_vehicle_trip_id;
        END IF;
    END IF;

    -- Gate B: Proceeding -> Returned means the vehicle physically came back.
    -- Keep the former Halt physical-return checks here.
    IF v_new_name = 'Returned' THEN
        SELECT EXISTS (
            SELECT 1
              FROM public.tbl_vehicle_trip_stop vts
              JOIN public.tbl_stop_type st ON st.pk_stop_type_id = vts.fk_stop_type
             WHERE vts.fk_vehicle_trip = NEW.pk_vehicle_trip_id
               AND st.stop_type = 'YARD_END'
               AND vts.stop_status = 'COMPLETED'
        ) INTO v_yard_end_completed;

        IF NOT v_yard_end_completed THEN
            IF NOT EXISTS (
                SELECT 1
                  FROM public.tbl_vehicle_trip_stop vts
                  JOIN public.tbl_stop_type st ON st.pk_stop_type_id = vts.fk_stop_type
                 WHERE vts.fk_vehicle_trip = NEW.pk_vehicle_trip_id
                   AND st.stop_type = 'YARD_END'
            ) THEN
                RAISE EXCEPTION
                    'Trip % cannot be marked Returned: no YARD_END stop has been recorded.',
                    NEW.pk_vehicle_trip_id;
            ELSE
                RAISE EXCEPTION
                    'Trip % cannot be marked Returned: YARD_END exists but is not COMPLETED.',
                    NEW.pk_vehicle_trip_id;
            END IF;
        END IF;

        SELECT COUNT(*),
               string_agg(c.cylinder_serial || ' [' || cs.cylinder_state || ']', ', ' ORDER BY c.cylinder_serial)
          INTO v_intransit_count, v_intransit_serials
          FROM public.tbl_cylinder_current_status ccs
          JOIN public.tbl_cylinder_states cs ON cs.pk_cylinder_state_id = ccs.fk_current_state
          JOIN public.tbl_cylinder c ON c.pk_cylinder_id = ccs.fk_cylinder
         WHERE (ccs.fk_current_vehicle_load = v_load_id OR ccs.fk_current_vehicle_trip = NEW.pk_vehicle_trip_id)
           AND cs.location = 'In Transit'
         LIMIT 10;

        IF v_intransit_count > 0 THEN
            RAISE EXCEPTION
                'Trip % cannot be marked Returned: % cylinder(s) are still INTRANSIT. Serial(s): [%]',
                NEW.pk_vehicle_trip_id, v_intransit_count, v_intransit_serials;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_validate_trip_status_transition() IS
    'V150 — Adds Returned between Proceeding and Halt. Physical return gates moved to Returned; Halt is final challan-entry closure.';

-- ---------------------------------------------------------------------
-- 4. Recreate active trip view so Returned is shown as non-terminal.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.vw_active_trips AS
SELECT
    vt.pk_vehicle_trip_id,
    ts.status_name AS trip_status,
    ts.display_order AS status_order,
    v.vehicle_number,
    d.driver_name,
    vt.trip_started_at,
    vt.trip_loaded_at,
    vt.trip_departed_at,
    CASE WHEN vt.trip_departed_at IS NOT NULL
         THEN EXTRACT(HOUR FROM now() - vt.trip_departed_at)::int
    END AS hours_since_departure,
    vt.audit_notes
FROM public.tbl_vehicle_trip vt
JOIN public.tbl_trip_status ts ON ts.pk_trip_status_id = vt.fk_trip_status
JOIN public.tbl_vehicle v ON v.pk_vehicle_id = vt.fk_vehicle
JOIN public.tbl_driver d ON d.pk_driver_id = vt.fk_driver
WHERE ts.is_terminal = false
ORDER BY vt.trip_started_at DESC;

COMMENT ON VIEW public.vw_active_trips IS
    'Active/non-terminal trips. V150 includes Returned trips so office challan entry can continue until final Halt.';

-- ---------------------------------------------------------------------
-- 5. Recreate trip-assignment view with pending-entry leaf count.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS public.vw_trip_challan_book_assignments;

CREATE VIEW public.vw_trip_challan_book_assignments AS
SELECT
    a.pk_trip_challan_book_assignment_id AS assignment_id,
    a.fk_vehicle_trip,
    a.fk_vehicle_load,
    a.fk_challan_book AS book_id,
    b.book_code,
    b.book_type::text AS book_type,
    b.series_prefix,
    b.start_sheet_number,
    b.end_sheet_number,
    b.current_location::text AS current_location,
    b.fk_assigned_vehicle,
    (a.returned_at IS NULL) AS active_assignment,
    a.assigned_at,
    a.assigned_by,
    a.returned_at,
    a.return_verified_by,
    a.remarks,
    COUNT(p.pk_page_audit_id) FILTER (WHERE p.page_status::text = 'UNUSED') AS unused_count,
    COUNT(p.pk_page_audit_id) FILTER (WHERE p.page_status::text = 'USED_CONFIRMED') AS used_count,
    COUNT(p.pk_page_audit_id) FILTER (WHERE p.page_status::text = 'PHYSICALLY_USED_PENDING_ENTRY') AS pending_entry_count,
    COUNT(p.pk_page_audit_id) FILTER (WHERE p.page_status::text = 'CANCELLED_SPOILED') AS spoiled_count,
    COUNT(p.pk_page_audit_id) FILTER (WHERE p.page_status::text = 'FLAGGED_MISSING') AS missing_count,
    MIN(p.sheet_number) FILTER (WHERE p.page_status::text IN ('UNUSED','PHYSICALLY_USED_PENDING_ENTRY')) AS next_available_sheet_number
FROM public.tbl_trip_challan_book_assignment a
JOIN public.tbl_challan_book_registry b ON b.pk_book_id = a.fk_challan_book
LEFT JOIN public.tbl_challan_page_audit_ledger p ON p.fk_book_id = b.pk_book_id
GROUP BY
    a.pk_trip_challan_book_assignment_id,
    a.fk_vehicle_trip,
    a.fk_vehicle_load,
    a.fk_challan_book,
    b.book_code,
    b.book_type,
    b.series_prefix,
    b.start_sheet_number,
    b.end_sheet_number,
    b.current_location,
    b.fk_assigned_vehicle,
    a.assigned_at,
    a.assigned_by,
    a.returned_at,
    a.return_verified_by,
    a.remarks;

COMMENT ON VIEW public.vw_trip_challan_book_assignments IS
    'Trip/load-level challan book assignments with unused, pending-entry, used, spoiled and missing counts.';
