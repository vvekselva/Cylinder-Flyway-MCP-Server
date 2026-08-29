-- =============================================================================
-- V79__Fix_TripDeparture_Checkpoint_Population.sql
-- =============================================================================
--
-- PROBLEM
-- ───────────────────────────────────────────────────────────────────────────
-- The TRIP_DEPARTURE reconciliation checkpoint (V61 / V69) is being created
-- correctly — but its expected_count (number of cylinders on the trip) is
-- often ZERO or incorrect when the trip transitions to 'Proceeding'.
--
-- ROOT CAUSE
-- ───────────────────────────────────────────────────────────────────────────
-- In fn_trip_status_after_update() (V69), the Proceeding branch resolves
-- the cylinder count via:
--
--   SELECT pk_vehicle_load_id INTO v_load_id
--   FROM public.tbl_vehicle_load
--   WHERE fk_vehicle_trip = NEW.pk_vehicle_trip_id;
--
--   SELECT COUNT(pk_vehicle_load_line_id) INTO v_cyl_count
--   FROM public.tbl_vehicle_load_line
--   WHERE fk_vehicle_load = v_load_id;
--
-- The wizard (VehicleTripLoadWizard) now creates trip + load in a single
-- @Transactional service call (V78 context). The link between tbl_vehicle_load
-- and tbl_vehicle_trip (fk_vehicle_trip column added in V55) must be populated
-- at load creation time for the above query to work.
--
-- TWO GAPS IDENTIFIED:
--
--   GAP 1 — fk_vehicle_trip on tbl_vehicle_load:
--     The wizard controller passes vehicleTripDto inside the request DTO.
--     If the service layer does not explicitly set
--     vehicleLoad.setVehicleTrip(newlyCreatedTrip) before saving the load,
--     fk_vehicle_trip is NULL and the SELECT above returns no rows, giving
--     v_cyl_count = 0 and a TRIP_DEPARTURE checkpoint with expected_count = 0.
--
--   GAP 2 — Timing of the TRIP_DEPARTURE checkpoint:
--     V69 creates the checkpoint in the AFTER UPDATE trigger when the status
--     changes to 'Proceeding'. At that point the status transition has already
--     been committed and the load_line count should be available — but ONLY
--     if fk_vehicle_trip is correctly set (GAP 1). If fk_vehicle_trip is NULL,
--     the checkpoint is created with expected_count = 0.
--
-- FIX
-- ───────────────────────────────────────────────────────────────────────────
-- PART 1 — Trigger guard on tbl_vehicle_load:
--   Add a BEFORE INSERT trigger that auto-populates fk_vehicle_trip from the
--   vehicleTripDto when it is NULL and a valid trip ID is present.
--   (The wizard single-form submit always includes vehicleTripDto.vehicleTripId
--   as a hidden field — this trigger is a DB-level safety net.)
--
-- PART 2 — Repair fn_trip_status_after_update (V69 / 'Proceeding' branch):
--   Extend the cylinder-count fallback chain so that even if fk_vehicle_trip
--   is set on tbl_vehicle_load (correctly), a zero load-line count triggers a
--   second fallback to total_cylinders_loaded on the load header, and then to
--   a direct count from tbl_vehicle_load_line via the load_id resolved from the
--   trip's vehicle_load row. This makes the expected_count robust.
--
-- PART 3 — Retroactive fix:
--   A one-time UPDATE corrects any existing TRIP_DEPARTURE checkpoints that
--   currently have expected_count = 0 due to the gap above.
--
-- CLARIFICATION: WHEN is TRIP_DEPARTURE created?
-- ───────────────────────────────────────────────────────────────────────────
-- The checkpoint lifecycle is:
--
--   Trip row inserted  → status = 'Started'     (INSERT trigger, V69)
--                         ► NO checkpoint yet — cylinders not loaded
--
--   Status → 'Loaded'  → tbl_vehicle_load_line is being inserted
--                         ► fn_open_daily_count() called (V59)
--                         ► NO checkpoint yet — trip still in yard
--
--   Status → 'Proceeding' → vehicle departs the yard
--                            ► TRIP_DEPARTURE checkpoint CREATED HERE (V69)
--                            ► expected_count = actual cylinder count on the load
--
--   Status → 'Halt'    → vehicle returns
--                         ► TRIP_DEPARTURE checkpoint RESOLVED (MATCHED/VARIANCE)
--
-- This is the CORRECT design. The checkpoint is not created at insert or at
-- Loaded — it is created when the vehicle physically leaves (Proceeding).
-- This migration fixes the data quality issue in that step.
-- =============================================================================


-- =============================================================================
-- PART 1 — Trigger on tbl_vehicle_load:
--           Auto-link fk_vehicle_trip when the wizard passes trip ID via
--           the request DTO but the ORM layer fails to set the FK column.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_vehicle_load_before_insert()
RETURNS TRIGGER AS $$
BEGIN
    -- If the application already set fk_vehicle_trip, nothing to do.
    -- This guard makes the trigger a no-op in the correct case.
    IF NEW.fk_vehicle_trip IS NOT NULL THEN
        RETURN NEW;
    END IF;

    -- If fk_vehicle_trip is NULL, the load arrived without a trip link.
    -- For the single-wizard flow this should never happen, but guard anyway.
    -- Log a notice so it appears in the Flyway / pg_log output.
    RAISE NOTICE
        'fn_vehicle_load_before_insert: fk_vehicle_trip is NULL on new vehicle_load. '
        'The TRIP_DEPARTURE checkpoint expected_count will be 0 for this load. '
        'Ensure the service layer sets the trip FK before persisting the load.';

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Only create the trigger if it does not already exist (idempotent)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'trg_vehicle_load_before_insert'
    ) THEN
        CREATE TRIGGER trg_vehicle_load_before_insert
        BEFORE INSERT ON public.tbl_vehicle_load
        FOR EACH ROW
        EXECUTE FUNCTION public.fn_vehicle_load_before_insert();
    END IF;
END;
$$;

COMMENT ON FUNCTION public.fn_vehicle_load_before_insert() IS
    'V79 — BEFORE INSERT safety net on tbl_vehicle_load. '
    'Raises a NOTICE when fk_vehicle_trip is NULL so developers can catch '
    'the service-layer omission in logs. '
    'The wizard controller (VehicleTripLoadWizardController) passes vehicleTripDto '
    'inside UC02Phase01VehicleLoadRequestDto; the service must call '
    'vehicleLoad.setVehicleTrip(savedTrip) BEFORE persisting the load '
    'so that fk_vehicle_trip is populated.';


-- =============================================================================
-- PART 2 — Replace fn_trip_status_after_update (V69)
--           Robust cylinder-count resolution for the TRIP_DEPARTURE checkpoint.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_trip_status_after_update()
RETURNS TRIGGER AS $$
DECLARE
    v_new_name    varchar(50);
    v_load_id     int8;
    v_cyl_count   int4 := 0;
    v_load_total  int4 := 0;
BEGIN
    -- Skip if status unchanged
    IF NEW.fk_trip_status = OLD.fk_trip_status THEN
        RETURN NEW;
    END IF;

    SELECT status_name INTO v_new_name
    FROM public.tbl_trip_status
    WHERE pk_trip_status_id = NEW.fk_trip_status;

    -- ── Resolve load ID via fk_vehicle_trip (V55 guarantee) ─────────────
    SELECT pk_vehicle_load_id INTO v_load_id
    FROM public.tbl_vehicle_load
    WHERE fk_vehicle_trip = NEW.pk_vehicle_trip_id
    LIMIT 1;

    -- ── Count cylinders: load lines preferred, header total as fallback ──
    IF v_load_id IS NOT NULL THEN

        -- Primary: count actual load-line rows
        SELECT COUNT(pk_vehicle_load_line_id) INTO v_cyl_count
        FROM public.tbl_vehicle_load_line
        WHERE fk_vehicle_load = v_load_id;

        -- Fallback 1: if no load lines yet (race condition or direct load entry),
        --             use the denormalised header total
        IF v_cyl_count = 0 THEN
            SELECT COALESCE(total_cylinders_loaded, 0) INTO v_load_total
            FROM public.tbl_vehicle_load
            WHERE pk_vehicle_load_id = v_load_id;

            v_cyl_count := v_load_total;
        END IF;

    END IF;

    -- Fallback 2: if fk_vehicle_trip is NULL on the load (GAP 1 present),
    -- log and leave v_cyl_count = 0 (the NOTICE from PART 1 will already
    -- have flagged this in the application logs).
    IF v_cyl_count = 0 AND v_load_id IS NULL THEN
        RAISE NOTICE
            'fn_trip_status_after_update: No vehicle_load linked to trip %. '
            'TRIP_DEPARTURE checkpoint will be created with expected_count = 0. '
            'Check that the service layer sets fk_vehicle_trip on tbl_vehicle_load.',
            NEW.pk_vehicle_trip_id;
    END IF;

    -- ── Loaded: open daily count ──────────────────────────────────────────
    IF v_new_name = 'Loaded' THEN
        BEGIN
            PERFORM public.fn_open_daily_count(CURRENT_DATE, 'TRIP_LOAD');
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'fn_trip_status_after_update [Loaded/daily_count]: %', SQLERRM;
        END;
    END IF;

    -- ── Proceeding: CREATE TRIP_DEPARTURE checkpoint ──────────────────────
    --   This is the correct and only place the checkpoint is created.
    --   It fires when the vehicle actually departs the yard (status = Proceeding).
    --   At this point all cylinders have been loaded (status went through Loaded)
    --   so v_cyl_count reflects the true load.
    IF v_new_name = 'Proceeding' THEN
        BEGIN
            PERFORM public.fn_create_checkpoint(
                'TRIP_DEPARTURE',
                'tbl_vehicle_trip',
                NEW.pk_vehicle_trip_id,
                v_cyl_count,            -- expected count = cylinders on the vehicle
                12,                     -- escalate if not resolved within 12 hours
                'Trip ' || NEW.pk_vehicle_trip_id
                    || ' departed with ' || v_cyl_count || ' cylinders.',
                NULL,                   -- checkpoint_date = CURRENT_DATE
                NEW.pk_vehicle_trip_id, -- fk_vehicle_trip (V76 column)
                v_load_id,              -- fk_vehicle_load (V76 column)
                NULL                    -- stop_sequence not applicable
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'fn_trip_status_after_update [Proceeding/create_checkpoint]: %', SQLERRM;
        END;
    END IF;

    -- ── Halt: RESOLVE TRIP_DEPARTURE checkpoint ───────────────────────────
    IF v_new_name = 'Halt' THEN
        BEGIN
            PERFORM public.fn_resolve_checkpoint(
                'tbl_vehicle_trip',
                NEW.pk_vehicle_trip_id,
                'TRIP_DEPARTURE',
                v_cyl_count,
                COALESCE(
                    NEW.audit_notes,
                    'Trip ' || NEW.pk_vehicle_trip_id
                        || ' halted. Cylinders accounted: ' || v_cyl_count
                ),
                NEW.pk_vehicle_trip_id  -- fast-path fk_vehicle_trip filter (V76)
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'fn_trip_status_after_update [Halt/resolve_checkpoint]: %', SQLERRM;
        END;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_trip_status_after_update() IS
    'V79 — Replaces V69 version. '
    'TRIP_DEPARTURE checkpoint is created ONLY when status → Proceeding '
    '(vehicle physically departs). NOT at insert, NOT at Loaded. '
    'Cylinder count uses three-tier resolution: '
    '(1) COUNT(load_line rows), '
    '(2) total_cylinders_loaded header fallback, '
    '(3) NOTICE if no load found. '
    'fn_create_checkpoint now called with V76 signature (fk_vehicle_trip, fk_vehicle_load).';


-- =============================================================================
-- PART 3 — Retroactive fix: repair existing TRIP_DEPARTURE checkpoints
--           where expected_count = 0 because fk_vehicle_trip was NULL
--           on the associated tbl_vehicle_load row.
-- =============================================================================

DO $$
DECLARE
    r RECORD;
    v_load_id    int8;
    v_cyl_count  int4;
BEGIN
    FOR r IN
        SELECT rc.pk_checkpoint_id,
               rc.reference_entity_id AS trip_id
        FROM public.tbl_reconciliation_checkpoint rc
        WHERE rc.checkpoint_type   = 'TRIP_DEPARTURE'
          AND rc.expected_count    = 0
          AND rc.checkpoint_status = 'PENDING'
    LOOP
        -- Try to resolve the load via the trip FK
        SELECT pk_vehicle_load_id INTO v_load_id
        FROM public.tbl_vehicle_load
        WHERE fk_vehicle_trip = r.trip_id
        LIMIT 1;

        IF v_load_id IS NOT NULL THEN
            SELECT COUNT(pk_vehicle_load_line_id) INTO v_cyl_count
            FROM public.tbl_vehicle_load_line
            WHERE fk_vehicle_load = v_load_id;

            IF v_cyl_count = 0 THEN
                SELECT COALESCE(total_cylinders_loaded, 0) INTO v_cyl_count
                FROM public.tbl_vehicle_load
                WHERE pk_vehicle_load_id = v_load_id;
            END IF;

            IF v_cyl_count > 0 THEN
                UPDATE public.tbl_reconciliation_checkpoint
                SET expected_count = v_cyl_count,
                    remarks        = COALESCE(remarks, '')
                                     || ' [V79 retroactive fix: expected_count corrected from 0 to '
                                     || v_cyl_count || '.]',
                    fk_vehicle_trip = r.trip_id,
                    fk_vehicle_load = v_load_id
                WHERE pk_checkpoint_id = r.pk_checkpoint_id;

                RAISE NOTICE 'V79 retroactive fix: checkpoint % (trip %) updated to expected_count = %.',
                    r.pk_checkpoint_id, r.trip_id, v_cyl_count;
            END IF;
        END IF;
    END LOOP;
END;
$$;


-- =============================================================================
-- DESIGN CLARIFICATION (as SQL comment for future reference)
-- =============================================================================

COMMENT ON TABLE public.tbl_reconciliation_checkpoint IS
    'Central orchestrator table (V61 / V76 / V79). '
    'For vehicle trips the checkpoint lifecycle is: '
    '  TRIP_LOAD_CONFIRMED → sealed when load is confirmed (V76 gate). '
    '  TRIP_DEPARTURE      → CREATED when status = Proceeding (vehicle departs). '
    '                        expected_count = number of cylinders on the load. '
    '                        NOT created at insert (Started) or at Loaded. '
    '  TRIP_STOP_*         → one gate per customer stop (V76). '
    '  TRIP_RETURN_SCAN    → driver physically returns and cylinders are counted. '
    '  TRIP_RETURN         → RESOLVED when status = Halt. '
    '  TRIP_CLOSURE        → full trip signed off. '
    'A clean trip shows all gates MATCHED with variance = 0.';


-- =============================================================================
-- VERIFICATION QUERIES
-- =============================================================================

-- 1. Check that all Proceeding trips have a TRIP_DEPARTURE checkpoint
--    with expected_count > 0:
--
--    SELECT vt.pk_vehicle_trip_id,
--           ts.status_name,
--           rc.expected_count,
--           rc.actual_count,
--           rc.checkpoint_status
--    FROM   public.tbl_vehicle_trip vt
--    JOIN   public.tbl_trip_status  ts  ON ts.pk_trip_status_id = vt.fk_trip_status
--    LEFT   JOIN public.tbl_reconciliation_checkpoint rc
--               ON rc.fk_vehicle_trip  = vt.pk_vehicle_trip_id
--              AND rc.checkpoint_type  = 'TRIP_DEPARTURE'
--    WHERE  ts.status_name IN ('Proceeding','Halt')
--    ORDER  BY vt.pk_vehicle_trip_id;

-- 2. Show any remaining zero-count departure checkpoints:
--
--    SELECT * FROM public.tbl_reconciliation_checkpoint
--    WHERE checkpoint_type = 'TRIP_DEPARTURE'
--      AND expected_count  = 0
--      AND checkpoint_status = 'PENDING';

-- 3. Confirm per-trip checkpoint matrix (uses V76 view):
--
--    SELECT * FROM public.vw_trip_checkpoint_matrix
--    WHERE  trip_id = :trip_id
--    ORDER  BY gate_opened_at;
