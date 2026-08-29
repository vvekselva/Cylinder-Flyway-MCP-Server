-- =====================================================================
-- V152__Trip_Status_Returned_Before_Proceeding.sql
-- =====================================================================
-- Purpose:
--   Correct the trip lifecycle to match the real physical/logical process.
--
-- Correct sequence:
--   Started -> Loaded -> Returned -> Proceeding -> Halt
--
-- Business meaning:
--   Loaded     : vehicle loaded and physical books assigned.
--   Returned   : vehicle/physical challan books are back in office.
--   Proceeding : office challan entry has started/been recorded from returned books.
--   Halt       : final cylinder/yard accounting is complete; no further edits.
-- =====================================================================

ALTER TABLE public.tbl_trip_status
    DROP CONSTRAINT IF EXISTS tbl_trip_status_name_chk;

ALTER TABLE public.tbl_trip_status
    ADD CONSTRAINT tbl_trip_status_name_chk
    CHECK (status_name IN ('Started','Loaded','Returned','Proceeding','Halt'));

INSERT INTO public.tbl_trip_status (status_name, display_order, is_terminal, description)
VALUES ('Returned', 3, false,
        'Vehicle and physical challan books returned to office; office challan entry is pending.')
ON CONFLICT (status_name) DO UPDATE
SET display_order = EXCLUDED.display_order,
    is_terminal = EXCLUDED.is_terminal,
    description = EXCLUDED.description;

UPDATE public.tbl_trip_status
   SET display_order = 1,
       is_terminal = false,
       description = COALESCE(description, 'Trip started.')
 WHERE status_name = 'Started';

UPDATE public.tbl_trip_status
   SET display_order = 2,
       is_terminal = false,
       description = COALESCE(description, 'Vehicle loaded and challan books assigned.')
 WHERE status_name = 'Loaded';

UPDATE public.tbl_trip_status
   SET display_order = 4,
       is_terminal = false,
       description = 'Office challan entry is being recorded from the returned physical books.'
 WHERE status_name = 'Proceeding';

UPDATE public.tbl_trip_status
   SET display_order = 5,
       is_terminal = true,
       description = 'Final cylinder/yard accounting completed and trip closed. No more trip challan edits are allowed.'
 WHERE status_name = 'Halt';

CREATE OR REPLACE FUNCTION public.fn_validate_trip_status_transition()
RETURNS TRIGGER AS $$
DECLARE
    v_old_order           int4;
    v_new_order           int4;
    v_old_name            varchar(50);
    v_new_name            varchar(50);
    v_load_id             int8;
    v_yard_start_exists   boolean;
    v_yard_end_completed  boolean;
    v_intransit_count     int4 := 0;
    v_intransit_serials   text := '';
BEGIN
    IF NEW.fk_trip_status = OLD.fk_trip_status THEN
        RETURN NEW;
    END IF;

    SELECT status_name, display_order
      INTO v_old_name, v_old_order
      FROM public.tbl_trip_status
     WHERE pk_trip_status_id = OLD.fk_trip_status;

    SELECT status_name, display_order
      INTO v_new_name, v_new_order
      FROM public.tbl_trip_status
     WHERE pk_trip_status_id = NEW.fk_trip_status;

    IF v_new_order <> v_old_order + 1 THEN
        RAISE EXCEPTION
            'Invalid trip status transition: % -> %. Valid sequence: Started -> Loaded -> Returned -> Proceeding -> Halt.',
            v_old_name, v_new_name;
    END IF;

    CASE v_new_name
        WHEN 'Loaded' THEN
            NEW.trip_loaded_at := now();
        WHEN 'Proceeding' THEN
            NEW.trip_departed_at := now();
        WHEN 'Halt' THEN
            NEW.trip_closed_at := now();
        ELSE
            NULL;
    END CASE;

    SELECT pk_vehicle_load_id
      INTO v_load_id
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

    -- Gate B: Loaded -> Returned is only the physical return/book handover gate.
    -- Challan/cylinder accounting is intentionally NOT required here, because
    -- office challan entry happens after the books are returned.
    IF v_new_name = 'Returned' AND v_load_id IS NULL THEN
        RAISE EXCEPTION
            'Trip % cannot be marked Returned: no vehicle load exists for this trip.',
            NEW.pk_vehicle_trip_id;
    END IF;

    -- Gate C: Proceeding -> Halt is final closure. By this time the challans
    -- have been entered and active vehicle/logistics lines must already be
    -- settled back to yard by the CompleteTrip service.
    IF v_new_name = 'Halt' THEN
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
                    'Trip % cannot be marked Halt: no YARD_END stop has been recorded.',
                    NEW.pk_vehicle_trip_id;
            ELSE
                RAISE EXCEPTION
                    'Trip % cannot be marked Halt: YARD_END exists but is not COMPLETED.',
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
                'Trip % cannot be marked Halt: % cylinder(s) are still INTRANSIT. Serial(s): [%]',
                NEW.pk_vehicle_trip_id, v_intransit_count, v_intransit_serials;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_validate_trip_status_transition() IS
    'V152 — Correct sequence to Started→Loaded→Returned→Proceeding→Halt. Returned is book return; Proceeding is office challan entry; Halt is final yard settlement.';

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
ORDER BY ts.display_order, vt.trip_started_at DESC;

COMMENT ON VIEW public.vw_active_trips IS
    'Active/non-terminal trips. V152 sequence: Started→Loaded→Returned→Proceeding→Halt.';
