-- =============================================================================
-- V96__TripGate_YardStop_EmptySupplierAccountability_And_ReconciliationFixes.sql
-- =============================================================================
--
-- ISSUES ADDRESSED
-- ────────────────────────────────────────────────────────────────────────────
--
-- ISSUE 1 & 5c — Halt transition allowed without a YARD_END stop
--   The Proceeding → Halt transition in fn_validate_trip_status_transition
--   (V69) only enforced ordering (Started→Loaded→Proceeding→Halt).  A trip
--   could reach Halt without ever recording a YARD_END stop, leaving no
--   physical evidence the vehicle returned to yard.  Trip 2 in the live data
--   demonstrates this: tbl_vehicle_trip_stop has zero rows for fk_vehicle_trip=2
--   yet the trip is in Halt status.
--   Fix: gate Proceeding → Halt on a COMPLETED YARD_END stop in
--   tbl_vehicle_trip_stop for the trip's vehicle load.
--
-- ISSUE 4 — Trip Loaded without a YARD_START stop
--   The service could mark a trip as Loaded (cylinder loading complete)
--   without first recording the YARD_START stop that anchors the load to a
--   physical yard event.  Without YARD_START the stop sequence is meaningless.
--   Fix: gate Started → Loaded on (a) a vehicle load existing for the trip
--   AND (b) a YARD_START stop existing for that load.
--
-- ISSUE 5b — INTRANSIT cylinders stranded at Halt
--   Cylinders still associated with the vehicle load (fk_current_vehicle_load
--   set) and in any 'In Transit' state (FULL_PICKED_UP_FOR_DELIVERY,
--   EMPTY_PICKED_FOR_REFILL, EMPTY_IN_TRANSIT_TO_YARD, etc.) indicate that
--   the state-machine was not completed for those cylinders.  The trip must
--   not be allowed to close while any cylinder is in this condition; manually
--   editing IDs to bypass the state machine would otherwise produce silent
--   data corruption.
--   Fix: gate Proceeding → Halt on zero INTRANSIT cylinders on the load.
--
-- ISSUE 3 — tbl_supplier_refill_collection_line_trip_line_unique is too strict
--   The UNIQUE (fk_supplier_trip_line) constraint on
--   tbl_supplier_refill_collection_line prevents a supplier trip line from
--   ever being re-collected, even after a voided collection or a correction
--   workflow.  The (fk_collection, fk_cylinder) UNIQUE already prevents
--   double-counting within a single collection event.  The per-trip-line
--   global uniqueness is an unnecessary additional restriction.
--   Fix: drop the constraint.
--
-- ISSUE 5a — EMPTY_FOR_SUPPLIER cylinders not tracked at serial level
--   V90/V91 introduced ID-level accountability for FULL_FOR_DELIVERY and
--   FULL_FOR_BUFFER cylinders via fn_trip_load_accountability.  EMPTY_FOR_
--   SUPPLIER cylinders (empties carried from yard to supplier) were only
--   counted in the aggregate actual_qty_empty_dropped_at_supplier column on
--   tbl_vehicle_load — no per-cylinder PENDING line was created, so a missing
--   cylinder would go undetected at Halt.
--   Fix: at Loaded, create one PENDING checkpoint line per EMPTY_FOR_SUPPLIER
--   cylinder inside the TRIP_LOAD header.  At Halt, resolve each line via ID
--   lookup against tbl_supplier_trip_line (joined to this trip's SUPPLIER_
--   DROPOFF stops).  Unresolved lines become VARIANCE.
--
-- ISSUE 6 — Delivered cylinder not marked RECOVERED when empty is picked up
--   When Trip A delivers cylinder X to a customer the TRIP_LOAD reconciliation
--   line for that cylinder is marked ACCOUNTED / DELIVERED at Trip A's Halt.
--   When Trip B later picks up the empty cylinder X, fn_empty_pickup_line_
--   reconcile (V91) added a line to Trip B's header but never reached back to
--   Trip A's line to record the physical recovery.  Without this cross-trip
--   update there is no single place showing "cylinder X was at customer Y,
--   delivered by Trip A, recovered empty by Trip B."
--   Fix: after registering the empty pickup on Trip B's header, update the
--   most recent DELIVERED ACCOUNTED line for that cylinder (in any other
--   trip's TRIP_LOAD header) to accountability_bucket = 'DELIVERED_RECOVERED'
--   with a cross-reference remark.  The lookup is by fk_cylinder (ID check,
--   not count).
--
-- DEPENDENCIES
--   V42  fn_audit_cylinder_load_after — sets fk_current_vehicle_load
--   V48  tbl_stop_type (YARD_START, YARD_END)
--   V50  tbl_vehicle_trip_stop
--   V55  tbl_vehicle_trip_stop.fk_vehicle_trip; tbl_vehicle_load.fk_vehicle_trip
--   V56  tbl_supplier_refill_collection_line, fk_vehicle_trip_stop on supplier_trip_line
--   V69  fn_validate_trip_status_transition (REPLACED — PART 2)
--        fn_trip_status_after_update        (REPLACED — PARTS 3 & 4)
--   V91  fn_empty_pickup_line_reconcile     (REPLACED — PART 5)
--        fn_add_reconciliation_line, fn_resolve_reconciliation_line,
--        fn_close_reconciliation_header, fn_open_reconciliation_header
-- =============================================================================


-- =============================================================================
-- PART 1 — Drop tbl_supplier_refill_collection_line_trip_line_unique
-- =============================================================================
-- The UNIQUE (fk_supplier_trip_line) constraint is overly strict:
--   • The FK itself (tbl_refill_collection_line_supplier_trip_line_fk) already
--     enforces referential integrity.
--   • The (fk_collection, fk_cylinder) UNIQUE prevents double-collection within
--     a single collection event.
--   • The global uniqueness blocks legitimate re-collection after voiding or
--     data correction, and prevents partial-return workflows.
-- The constraint is dropped here; the FK is retained.
-- =============================================================================

ALTER TABLE public.tbl_supplier_refill_collection_line
    DROP CONSTRAINT IF EXISTS tbl_supplier_refill_collection_line_trip_line_unique;

COMMENT ON TABLE public.tbl_supplier_refill_collection_line IS
    'One row per cylinder collected from the supplier after refilling. '
    'Unique per (fk_collection, fk_cylinder). The global per-trip-line '
    'uniqueness constraint (tbl_supplier_refill_collection_line_trip_line_unique) '
    'was dropped in V96 to allow correction / re-collection workflows. '
    'Referential integrity is preserved via the FK to tbl_supplier_trip_line.';


-- =============================================================================
-- PART 2 — Replace fn_validate_trip_status_transition  (BEFORE UPDATE, V69)
--
--   Original (V69): only enforced forward ordering Started→Loaded→Proceeding→Halt.
--
--   V96 additions:
--     Gate A (Started → Loaded):
--       • A vehicle load must exist for this trip (tbl_vehicle_load.fk_vehicle_trip).
--       • A YARD_START stop must exist in tbl_vehicle_trip_stop for that load.
--         Without this, the load has no physical anchor at the yard.
--
--     Gate B (Proceeding → Halt):
--       • A YARD_END stop must exist for the load AND its stop_status must be
--         'COMPLETED'.  The driver must have recorded the return-to-yard event
--         before the trip can be closed.
--       • Zero cylinders on this load may be in any 'In Transit' state
--         (fk_current_vehicle_load = this load AND location = 'In Transit' in
--         tbl_cylinder_states).  INTRANSIT cylinders indicate an incomplete
--         state-machine: the driver either forgot to scan a cylinder, or IDs
--         were edited manually bypassing the triggers.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_validate_trip_status_transition()
RETURNS TRIGGER AS $$
DECLARE
    v_old_order         int4;
    v_new_order         int4;
    v_old_name          varchar(50);
    v_new_name          varchar(50);

    -- Gate A
    v_load_id           int8;
    v_yard_start_exists boolean;

    -- Gate B
    v_yard_end_completed boolean;
    v_intransit_count   int4 := 0;
    v_intransit_serials text := '';
BEGIN
    -- ── No-op if status unchanged ────────────────────────────────────────────
    IF NEW.fk_trip_status = OLD.fk_trip_status THEN RETURN NEW; END IF;

    -- ── Resolve status names and display orders ──────────────────────────────
    SELECT status_name, display_order INTO v_old_name, v_old_order
      FROM public.tbl_trip_status WHERE pk_trip_status_id = OLD.fk_trip_status;

    SELECT status_name, display_order INTO v_new_name, v_new_order
      FROM public.tbl_trip_status WHERE pk_trip_status_id = NEW.fk_trip_status;

    -- ── Forward-only ordering guard (unchanged from V69) ────────────────────
    IF v_new_order <> v_old_order + 1 THEN
        RAISE EXCEPTION
            'Invalid trip status transition: % → %. '
            'Valid sequence: Started → Loaded → Proceeding → Halt.',
            v_old_name, v_new_name;
    END IF;

    -- ── Stamp transition timestamps (unchanged from V69) ────────────────────
    CASE v_new_name
        WHEN 'Loaded'     THEN NEW.trip_loaded_at   := now();
        WHEN 'Proceeding' THEN NEW.trip_departed_at := now();
        WHEN 'Halt'       THEN NEW.trip_closed_at   := now();
        ELSE NULL;
    END CASE;

    -- =========================================================================
    -- GATE A  —  Started → Loaded
    -- =========================================================================
    -- Require: (1) vehicle load exists, (2) YARD_START stop recorded.
    IF v_new_name = 'Loaded' THEN

        -- (1) Vehicle load must exist for this trip
        SELECT pk_vehicle_load_id INTO v_load_id
          FROM public.tbl_vehicle_load
         WHERE fk_vehicle_trip = NEW.pk_vehicle_trip_id
         LIMIT 1;

        IF v_load_id IS NULL THEN
            RAISE EXCEPTION
                'Trip % cannot advance to Loaded: no vehicle load (tbl_vehicle_load) '
                'exists for this trip. Create the vehicle load record before marking '
                'the trip as Loaded.',
                NEW.pk_vehicle_trip_id;
        END IF;

        -- (2) YARD_START stop must exist for that load
        SELECT EXISTS (
            SELECT 1
              FROM public.tbl_vehicle_trip_stop vts
              JOIN public.tbl_stop_type         st  ON st.pk_stop_type_id = vts.fk_stop_type
             WHERE vts.fk_vehicle_trip = NEW.pk_vehicle_trip_id
               AND st.stop_type        = 'YARD_START'
        ) INTO v_yard_start_exists;

        IF NOT v_yard_start_exists THEN
            RAISE EXCEPTION
                'Trip % cannot advance to Loaded: a YARD_START stop (sequence 1) '
                'must be recorded in tbl_vehicle_trip_stop before the trip is '
                'marked as Loaded. Record the yard departure stop first.',
                NEW.pk_vehicle_trip_id;
        END IF;

    END IF; -- END GATE A


    -- =========================================================================
    -- GATE B  —  Proceeding → Halt
    -- =========================================================================
    -- Require: (1) COMPLETED YARD_END stop, (2) zero INTRANSIT cylinders.
    IF v_new_name = 'Halt' THEN

        -- Resolve the vehicle load (needed for both sub-checks)
        SELECT pk_vehicle_load_id INTO v_load_id
          FROM public.tbl_vehicle_load
         WHERE fk_vehicle_trip = NEW.pk_vehicle_trip_id
         LIMIT 1;

        -- Sub-check 1: YARD_END stop exists and is COMPLETED
        SELECT EXISTS (
            SELECT 1
              FROM public.tbl_vehicle_trip_stop vts
              JOIN public.tbl_stop_type         st  ON st.pk_stop_type_id = vts.fk_stop_type
             WHERE vts.fk_vehicle_trip = NEW.pk_vehicle_trip_id
               AND st.stop_type        = 'YARD_END'
               AND vts.stop_status     = 'COMPLETED'
        ) INTO v_yard_end_completed;

        IF NOT v_yard_end_completed THEN
            -- Distinguish: no YARD_END stop at all vs exists but not completed
            IF NOT EXISTS (
                SELECT 1
                  FROM public.tbl_vehicle_trip_stop vts
                  JOIN public.tbl_stop_type         st ON st.pk_stop_type_id = vts.fk_stop_type
                 WHERE vts.fk_vehicle_trip = NEW.pk_vehicle_trip_id
                   AND st.stop_type        = 'YARD_END'
            ) THEN
                RAISE EXCEPTION
                    'Trip % cannot be Halted: no YARD_END stop has been recorded. '
                    'The driver must record the return-to-yard stop before the trip '
                    'can be closed.',
                    NEW.pk_vehicle_trip_id;
            ELSE
                RAISE EXCEPTION
                    'Trip % cannot be Halted: the YARD_END stop exists but its '
                    'stop_status is not COMPLETED. Complete the yard return tally '
                    'before closing the trip.',
                    NEW.pk_vehicle_trip_id;
            END IF;
        END IF;

        -- Sub-check 2: No cylinders still INTRANSIT on this load
        -- A cylinder in 'In Transit' location with fk_current_vehicle_load pointing
        -- to this trip's load means its state-machine is incomplete.
        -- Collect up to 10 offending serial numbers for the error message.
        IF v_load_id IS NOT NULL THEN
            SELECT COUNT(*),
                   string_agg(c.cylinder_serial || ' [' || cs.cylinder_state || ']',
                               ', ' ORDER BY c.cylinder_serial)
              INTO v_intransit_count, v_intransit_serials
              FROM public.tbl_cylinder_current_status  ccs
              JOIN public.tbl_cylinder_states           cs  ON cs.pk_cylinder_state_id = ccs.fk_current_state
              JOIN public.tbl_cylinder                  c   ON c.pk_cylinder_id        = ccs.fk_cylinder
             WHERE ccs.fk_current_vehicle_load = v_load_id
               AND cs.location                 = 'In Transit'
             LIMIT 10;

            IF v_intransit_count > 0 THEN
                RAISE EXCEPTION
                    'Trip % cannot be Halted: % cylinder(s) are still in an '
                    'INTRANSIT state on this vehicle load. '
                    'Each cylinder must reach a terminal state (DELIVERED_FOR_CONSUMPTION, '
                    'EMPTY_DELIVERED_FOR_REFILL, FULL, EMPTY, etc.) before the trip '
                    'can close. Manually editing IDs to bypass the state machine will '
                    'not resolve this check. '
                    'INTRANSIT cylinders (up to 10 shown): [%]',
                    NEW.pk_vehicle_trip_id, v_intransit_count, v_intransit_serials;
            END IF;
        END IF;

    END IF; -- END GATE B

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_validate_trip_status_transition() IS
    'V96 — Replaces V69. '
    'Enforces forward-only status ordering (Started→Loaded→Proceeding→Halt). '
    'Gate A (→Loaded): vehicle load must exist AND a YARD_START stop must be '
    'recorded for the load. '
    'Gate B (→Halt): a COMPLETED YARD_END stop must exist; zero cylinders may '
    'be in any In-Transit state on this vehicle load.';

-- Trigger already wired (V69); replacing the function body is sufficient.


-- =============================================================================
-- PART 3 — Helper: fn_resolve_empty_supplier_lines(p_trip_id, p_header_id)
--
--   Called from fn_trip_status_after_update at Halt.
--   For each EMPTY_FOR_SUPPLIER cylinder on this trip's load, looks up
--   tbl_supplier_trip_line (joined through the trip's SUPPLIER_DROPOFF stops)
--   to determine whether the cylinder was actually handed to the supplier.
--     Found   → resolve the PENDING line as ACCOUNTED / SUPPLIER_DROPOFF
--     Missing → leave PENDING; fn_close_reconciliation_header marks it VARIANCE
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_resolve_empty_supplier_lines(
    p_trip_id   int8,
    p_header_id int8
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_rec           RECORD;
    v_supplier_id   int8;
BEGIN
    FOR v_rec IN
        SELECT vll.fk_cylinder,
               c.cylinder_serial
          FROM public.tbl_vehicle_load_line      vll
          JOIN public.tbl_vehicle_load            vl   ON vl.pk_vehicle_load_id    = vll.fk_vehicle_load
          JOIN public.tbl_cylinder                c    ON c.pk_cylinder_id          = vll.fk_cylinder
          JOIN public.tbl_vehicle_load_purpose    vlp  ON vlp.pk_load_purpose_id    = vll.fk_load_purpose
         WHERE vl.fk_vehicle_trip  = p_trip_id
           AND vlp.load_purpose    = 'EMPTY_FOR_SUPPLIER'
    LOOP
        -- Check: does a supplier trip line exist for this cylinder at a
        -- SUPPLIER_DROPOFF stop belonging to this trip?
        SELECT stl.pk_supplier_trip_line_id INTO v_supplier_id
          FROM public.tbl_supplier_trip_line  stl
          JOIN public.tbl_vehicle_trip_stop   vts ON vts.pk_stop_id    = stl.fk_vehicle_trip_stop
          JOIN public.tbl_stop_type           st  ON st.pk_stop_type_id = vts.fk_stop_type
         WHERE stl.fk_cylinder       = v_rec.fk_cylinder
           AND vts.fk_vehicle_trip   = p_trip_id
           AND st.stop_type          = 'SUPPLIER_DROPOFF'
         LIMIT 1;

        IF FOUND THEN
            -- Cylinder was handed to supplier — resolve the line
            PERFORM public.fn_resolve_reconciliation_line(
                p_header_id,
                v_rec.fk_cylinder,
                'ACCOUNTED',
                'SUPPLIER_DROPOFF',
                'Empty cylinder ' || v_rec.cylinder_serial
                    || ' confirmed at SUPPLIER_DROPOFF stop (supplier_trip_line id='
                    || v_supplier_id || ').'
            );
        END IF;
        -- If NOT FOUND: PENDING line remains → becomes VARIANCE when header closes.
    END LOOP;
END;
$$;

COMMENT ON FUNCTION public.fn_resolve_empty_supplier_lines(int8, int8) IS
    'V96 — Resolves PENDING EMPTY_FOR_SUPPLIER checkpoint lines under a TRIP_LOAD '
    'header at Halt time. Joins tbl_supplier_trip_line → tbl_vehicle_trip_stop to '
    'confirm by cylinder ID (not count) whether each empty was actually handed to '
    'the supplier. Unresolved lines stay PENDING and become VARIANCE at header close.';


-- =============================================================================
-- PART 4 — Replace fn_trip_status_after_update  (AFTER UPDATE, V91)
--
--   Changes from V91:
--
--   LOADED branch (new):
--     In addition to the existing INSERT of PENDING lines for FULL_FOR_DELIVERY
--     and FULL_FOR_BUFFER cylinders, also insert one PENDING line per
--     EMPTY_FOR_SUPPLIER cylinder.  This gives serial-level accountability for
--     all cylinders on the load — not just the full ones.
--
--   HALT branch (new):
--     After the existing TRIP_LOAD header resolution (Steps 1–4), add:
--     Step 5: call fn_resolve_empty_supplier_lines to settle the EMPTY_FOR_SUPPLIER
--             PENDING lines by ID before fn_close_reconciliation_header runs.
--             Unresolved EMPTY_FOR_SUPPLIER lines (cylinder not found at any
--             SUPPLIER_DROPOFF stop) will be marked VARIANCE by the header close.
--
--   All other branches (Loaded, Proceeding) and all other Halt steps are
--   reproduced verbatim from V91 — only the additions are commented NEW.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_trip_status_after_update()
RETURNS TRIGGER AS $$
DECLARE
    v_new_name              varchar(50);

    -- Load resolution
    v_load_id               int8;
    v_cyl_count             int4 := 0;
    v_header_id             int8;

    -- Halt: stop checkpoint resolution
    v_stop_rec              RECORD;
    v_actual_lines          int4;
    v_delivered_count       int4 := 0;
    v_pickup_count          int4 := 0;

    -- Halt: TRIP_LOAD serial-level accountability (FULL cylinders)
    v_acc_rec               RECORD;
    v_accounted_count       int4 := 0;
    v_unaccounted_count     int4 := 0;
    v_unaccounted_serials   text := '';
    v_load_remarks          text := '';
BEGIN
    IF NEW.fk_trip_status = OLD.fk_trip_status THEN RETURN NEW; END IF;

    SELECT status_name INTO v_new_name
      FROM public.tbl_trip_status WHERE pk_trip_status_id = NEW.fk_trip_status;

    -- Resolve vehicle load (1:1 guarantee — V55)
    SELECT pk_vehicle_load_id INTO v_load_id
      FROM public.tbl_vehicle_load WHERE fk_vehicle_trip = NEW.pk_vehicle_trip_id;

    -- Cylinder count (load lines; fallback to header total)
    IF v_load_id IS NOT NULL THEN
        SELECT COUNT(pk_vehicle_load_line_id) INTO v_cyl_count
          FROM public.tbl_vehicle_load_line WHERE fk_vehicle_load = v_load_id;

        IF v_cyl_count = 0 THEN
            SELECT COALESCE(total_cylinders_loaded, 0) INTO v_cyl_count
              FROM public.tbl_vehicle_load WHERE pk_vehicle_load_id = v_load_id;
        END IF;
    END IF;

    -- =========================================================================
    -- LOADED — open TRIP_LOAD header + per-cylinder PENDING lines + TRIP_DEPARTURE
    -- =========================================================================
    IF v_new_name = 'Loaded' THEN

        BEGIN
            PERFORM public.fn_open_daily_count(CURRENT_DATE, 'TRIP_LOAD');
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[Loaded/daily_count]: %', SQLERRM;
        END;

        -- Open TRIP_LOAD header (unchanged from V91)
        BEGIN
            v_header_id := public.fn_open_reconciliation_header(
                'TRIP_LOAD',
                'tbl_vehicle_load',
                v_load_id,
                v_cyl_count,
                12,
                NEW.pk_vehicle_trip_id,
                v_load_id,
                NULL, NULL, NULL,
                'Trip ' || NEW.pk_vehicle_trip_id
                    || ' loaded: ' || v_cyl_count || ' cylinders sealed for departure.'
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[Loaded/TRIP_LOAD header]: %', SQLERRM;
        END;

        IF v_header_id IS NOT NULL AND v_load_id IS NOT NULL THEN
            BEGIN
                -- ── EXISTING (V91): PENDING lines for FULL_FOR_DELIVERY / FULL_FOR_BUFFER ──
                INSERT INTO public.tbl_reconciliation_checkpoint (
                    checkpoint_date, checkpoint_type, checkpoint_status,
                    reference_entity_type, reference_entity_id,
                    fk_vehicle_trip, fk_vehicle_load,
                    expected_count, actual_count, escalation_threshold_hours,
                    remarks, fk_header, fk_cylinder, line_status, accountability_bucket
                )
                SELECT
                    CURRENT_DATE,
                    'TRIP_LOAD_CONFIRMED',
                    'PENDING',
                    'tbl_vehicle_load_line',
                    vll.pk_vehicle_load_line_id,
                    NEW.pk_vehicle_trip_id,
                    v_load_id,
                    1, NULL, NULL,
                    'Load line: cylinder ' || c.cylinder_serial
                        || ' (' || vlp.load_purpose || ') — awaiting Halt accountability.',
                    v_header_id,
                    vll.fk_cylinder,
                    'PENDING',
                    'UNACCOUNTED'
                FROM   public.tbl_vehicle_load_line   vll
                JOIN   public.tbl_cylinder             c   ON c.pk_cylinder_id    = vll.fk_cylinder
                JOIN   public.tbl_vehicle_load_purpose vlp ON vlp.pk_load_purpose_id = vll.fk_load_purpose
                WHERE  vll.fk_vehicle_load = v_load_id
                  AND  vlp.load_purpose    IN ('FULL_FOR_DELIVERY', 'FULL_FOR_BUFFER');

                -- ── NEW (V96): PENDING lines for EMPTY_FOR_SUPPLIER cylinders ──────────
                -- Each empty cylinder carried to the supplier gets its own PENDING line.
                -- Resolved at Halt via fn_resolve_empty_supplier_lines (checks by ID
                -- whether the cylinder appears in tbl_supplier_trip_line at a
                -- SUPPLIER_DROPOFF stop of this trip).
                INSERT INTO public.tbl_reconciliation_checkpoint (
                    checkpoint_date, checkpoint_type, checkpoint_status,
                    reference_entity_type, reference_entity_id,
                    fk_vehicle_trip, fk_vehicle_load,
                    expected_count, actual_count, escalation_threshold_hours,
                    remarks, fk_header, fk_cylinder, line_status, accountability_bucket
                )
                SELECT
                    CURRENT_DATE,
                    'TRIP_LOAD_CONFIRMED',
                    'PENDING',
                    'tbl_vehicle_load_line',
                    vll.pk_vehicle_load_line_id,
                    NEW.pk_vehicle_trip_id,
                    v_load_id,
                    1, NULL, NULL,
                    'Empty cylinder ' || c.cylinder_serial
                        || ' (EMPTY_FOR_SUPPLIER) — awaiting SUPPLIER_DROPOFF confirmation.',
                    v_header_id,
                    vll.fk_cylinder,
                    'PENDING',
                    'UNACCOUNTED'
                FROM   public.tbl_vehicle_load_line   vll
                JOIN   public.tbl_cylinder             c   ON c.pk_cylinder_id    = vll.fk_cylinder
                JOIN   public.tbl_vehicle_load_purpose vlp ON vlp.pk_load_purpose_id = vll.fk_load_purpose
                WHERE  vll.fk_vehicle_load = v_load_id
                  AND  vlp.load_purpose    = 'EMPTY_FOR_SUPPLIER';

            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE '[Loaded/TRIP_LOAD lines]: %', SQLERRM;
            END;
        END IF;

        -- TRIP_DEPARTURE aggregate checkpoint (unchanged from V91)
        BEGIN
            PERFORM public.fn_create_checkpoint(
                'TRIP_DEPARTURE',
                'tbl_vehicle_trip',
                NEW.pk_vehicle_trip_id,
                v_cyl_count,
                12,
                'Trip ' || NEW.pk_vehicle_trip_id
                    || ' departed with ' || v_cyl_count || ' cylinders.',
                CURRENT_DATE,
                NEW.pk_vehicle_trip_id,
                v_load_id,
                NULL
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[Loaded/TRIP_DEPARTURE]: %', SQLERRM;
        END;

    END IF; -- END LOADED


    -- =========================================================================
    -- HALT — resolve all open checkpoints and the TRIP_LOAD header
    -- =========================================================================
    IF v_new_name = 'Halt' THEN

        -- ── Step 1: Resolve each TRIP_STOP_DELIVERY (aggregate rows) ─────────
        FOR v_stop_rec IN
            SELECT pk_checkpoint_id, reference_entity_id AS order_id, expected_count
              FROM public.tbl_reconciliation_checkpoint
             WHERE fk_vehicle_trip   = NEW.pk_vehicle_trip_id
               AND checkpoint_type   = 'TRIP_STOP_DELIVERY'
               AND checkpoint_status = 'PENDING'
               AND fk_header IS NULL
        LOOP
            SELECT COUNT(*) INTO v_actual_lines
              FROM public.tbl_order_line WHERE fk_order = v_stop_rec.order_id;

            v_delivered_count := v_delivered_count + v_actual_lines;

            BEGIN
                PERFORM public.fn_resolve_checkpoint(
                    'tbl_order', v_stop_rec.order_id, 'TRIP_STOP_DELIVERY',
                    v_actual_lines,
                    'Resolved at Halt. Lines entered: ' || v_actual_lines
                        || ' / Declared: ' || v_stop_rec.expected_count,
                    NEW.pk_vehicle_trip_id
                );
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE '[Halt/TRIP_STOP_DELIVERY order=%]: %',
                    v_stop_rec.order_id, SQLERRM;
            END;
        END LOOP;

        -- ── Step 2: Resolve each TRIP_STOP_EMPTY_PICKUP (aggregate rows) ─────
        FOR v_stop_rec IN
            SELECT pk_checkpoint_id, reference_entity_id AS pickup_id, expected_count
              FROM public.tbl_reconciliation_checkpoint
             WHERE fk_vehicle_trip   = NEW.pk_vehicle_trip_id
               AND checkpoint_type   = 'TRIP_STOP_EMPTY_PICKUP'
               AND checkpoint_status = 'PENDING'
               AND fk_header IS NULL
        LOOP
            SELECT COUNT(*) INTO v_actual_lines
              FROM public.tbl_empty_pickup_line WHERE fk_empty_pickup = v_stop_rec.pickup_id;

            v_pickup_count := v_pickup_count + v_actual_lines;

            BEGIN
                PERFORM public.fn_resolve_checkpoint(
                    'tbl_empty_pickup', v_stop_rec.pickup_id, 'TRIP_STOP_EMPTY_PICKUP',
                    v_actual_lines,
                    'Resolved at Halt. Scanned: ' || v_actual_lines
                        || ' / Declared: ' || v_stop_rec.expected_count,
                    NEW.pk_vehicle_trip_id
                );
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE '[Halt/TRIP_STOP_EMPTY_PICKUP pickup=%]: %',
                    v_stop_rec.pickup_id, SQLERRM;
            END;
        END LOOP;

        -- ── Step 3: Resolve TRIP_DEPARTURE aggregate checkpoint ───────────────
        BEGIN
            PERFORM public.fn_resolve_checkpoint(
                'tbl_vehicle_trip', NEW.pk_vehicle_trip_id, 'TRIP_DEPARTURE',
                v_delivered_count + v_pickup_count,
                COALESCE(
                    NEW.audit_notes,
                    'Halt — Delivered: ' || v_delivered_count
                        || ', Empties collected: ' || v_pickup_count
                        || ', Loaded: ' || v_cyl_count
                ),
                NEW.pk_vehicle_trip_id
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[Halt/TRIP_DEPARTURE]: %', SQLERRM;
        END;

        -- ── Steps 4 & 5: Resolve TRIP_LOAD header (serial-level) ─────────────
        BEGIN
            SELECT pk_header_id INTO v_header_id
              FROM public.tbl_reconciliation_header
             WHERE fk_vehicle_trip = NEW.pk_vehicle_trip_id
               AND header_type     = 'TRIP_LOAD'
               AND header_status   = 'OPEN'
             ORDER BY opened_at DESC
             LIMIT 1;

            IF v_header_id IS NULL THEN
                RAISE NOTICE '[Halt/TRIP_LOAD]: No open TRIP_LOAD header for trip %. '
                             'Header may predate V91 or was already closed.',
                    NEW.pk_vehicle_trip_id;
            ELSE

                -- ── Step 4 (V91): Resolve FULL_FOR_DELIVERY / FULL_FOR_BUFFER lines ──
                FOR v_acc_rec IN
                    SELECT fk_cylinder, cylinder_serial,
                           load_purpose_name, accountability_bucket
                      FROM public.fn_trip_load_accountability(NEW.pk_vehicle_trip_id)
                LOOP
                    IF v_acc_rec.accountability_bucket = 'UNACCOUNTED' THEN
                        v_unaccounted_count := v_unaccounted_count + 1;
                        IF v_unaccounted_count <= 20 THEN
                            v_unaccounted_serials := v_unaccounted_serials
                                || v_acc_rec.cylinder_serial || ' ('
                                || v_acc_rec.load_purpose_name || '), ';
                        END IF;
                    ELSE
                        v_accounted_count := v_accounted_count + 1;
                        PERFORM public.fn_resolve_reconciliation_line(
                            v_header_id,
                            v_acc_rec.fk_cylinder,
                            'ACCOUNTED',
                            v_acc_rec.accountability_bucket,
                            'Halt: ' || v_acc_rec.accountability_bucket
                                || ' — serial ' || v_acc_rec.cylinder_serial
                        );
                    END IF;
                END LOOP;

                -- ── Step 5 (NEW V96): Resolve EMPTY_FOR_SUPPLIER lines by ID ─────────
                -- fn_resolve_empty_supplier_lines checks each EMPTY_FOR_SUPPLIER
                -- cylinder against tbl_supplier_trip_line at the trip's SUPPLIER_DROPOFF
                -- stops.  Unresolved lines (not found at any supplier stop) stay PENDING
                -- and become VARIANCE when fn_close_reconciliation_header runs below.
                BEGIN
                    PERFORM public.fn_resolve_empty_supplier_lines(
                        NEW.pk_vehicle_trip_id,
                        v_header_id
                    );
                EXCEPTION WHEN OTHERS THEN
                    RAISE NOTICE '[Halt/EMPTY_SUPPLIER_lines]: %', SQLERRM;
                END;

                -- Build closing remarks
                IF v_unaccounted_count = 0 THEN
                    v_load_remarks :=
                        'All cylinders accounted at Halt. '
                        || 'Accounted: ' || v_accounted_count || '.';
                ELSE
                    v_load_remarks :=
                        'VARIANCE — ' || v_unaccounted_count
                        || ' FULL cylinder(s) UNACCOUNTED. Serials: '
                        || rtrim(v_unaccounted_serials, ', ')
                        || CASE WHEN v_unaccounted_count > 20
                                THEN ' … (' || (v_unaccounted_count - 20) || ' more)'
                                ELSE '' END;
                END IF;

                -- Close the header: all remaining PENDING lines → VARIANCE
                PERFORM public.fn_close_reconciliation_header(v_header_id, v_load_remarks);

            END IF;

        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[Halt/TRIP_LOAD header]: %', SQLERRM;
        END;

    END IF; -- END HALT

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger already wired (V69 AFTER UPDATE trg_trip_status_after_update);
-- replacing the function body is sufficient.

COMMENT ON FUNCTION public.fn_trip_status_after_update() IS
    'V96 — Replaces V91. '
    'Loaded: opens TRIP_LOAD reconciliation header + PENDING lines for ALL '
    'cylinders on the load — FULL_FOR_DELIVERY, FULL_FOR_BUFFER (existing), '
    'and EMPTY_FOR_SUPPLIER (NEW V96). '
    'Halt Step 4: resolves FULL cylinder lines via fn_trip_load_accountability (ID-level). '
    'Halt Step 5 (NEW V96): resolves EMPTY_FOR_SUPPLIER lines via '
    'fn_resolve_empty_supplier_lines (ID-level, by supplier trip line lookup). '
    'Unresolved lines of any type become VARIANCE at header close.';


-- =============================================================================
-- PART 5 — Replace fn_empty_pickup_line_reconcile  (AFTER INSERT, V91)
--
--   V91 behaviour (retained):
--     Creates one ACCOUNTED checkpoint line (EMPTY_PICKUP bucket) under the
--     CURRENT trip's TRIP_LOAD header.
--
--   V96 addition — cross-trip delivery recovery:
--     After registering the empty pickup on the current trip, also look up the
--     most recent DELIVERED / ACCOUNTED checkpoint line for this cylinder in
--     any OTHER trip's TRIP_LOAD header.  When found, update its
--     accountability_bucket to 'DELIVERED_RECOVERED' and append a remark
--     cross-referencing the recovery trip and date.
--
--     The lookup is by fk_cylinder (cylinder ID), not by count.
--     Only the most recent such line is updated (a cylinder could theoretically
--     have been delivered and recovered by multiple trips historically; we only
--     want the most recent open cycle).
--
--     This closes the accountability loop:
--       Trip A delivers cylinder X → DELIVERED (ACCOUNTED)
--       Trip B picks it up empty  → DELIVERED_RECOVERED (ACCOUNTED) on Trip A's line
--                                   + EMPTY_PICKUP (ACCOUNTED) on Trip B's line
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_empty_pickup_line_reconcile()
RETURNS TRIGGER AS $$
DECLARE
    v_header_id         int8;
    v_trip_id           int8;
    v_cyl_serial        varchar(100);
    v_rows_updated      int4;
BEGIN
    -- Resolve the vehicle trip from the empty pickup header (unchanged from V91)
    SELECT vl.fk_vehicle_trip INTO v_trip_id
      FROM public.tbl_empty_pickup   ep
      JOIN public.tbl_vehicle_load   vl  ON vl.pk_vehicle_load_id = ep.fk_vehicle_load
     WHERE ep.pk_pickup_id = NEW.fk_empty_pickup;

    IF v_trip_id IS NULL THEN
        -- Empty pickup not linked to a trip (e.g. walk-in yard collection)
        RETURN NEW;
    END IF;

    -- Find the open TRIP_LOAD header for the current trip (unchanged from V91)
    SELECT pk_header_id INTO v_header_id
      FROM public.tbl_reconciliation_header
     WHERE fk_vehicle_trip = v_trip_id
       AND header_type     = 'TRIP_LOAD'
       AND header_status   NOT IN ('CLOSED', 'VARIANCE')
     ORDER BY opened_at DESC
     LIMIT 1;

    SELECT cylinder_serial INTO v_cyl_serial
      FROM public.tbl_cylinder WHERE pk_cylinder_id = NEW.fk_cylinder;

    -- ── EXISTING (V91): Add EMPTY_PICKUP line to current trip's header ────────
    IF v_header_id IS NOT NULL THEN
        BEGIN
            PERFORM public.fn_add_reconciliation_line(
                v_header_id,
                NEW.fk_cylinder,
                'TRIP_STOP_EMPTY_PICKUP',
                'ACCOUNTED',
                'EMPTY_PICKUP',
                'tbl_empty_pickup_line',
                NEW.pk_pickup_line_id,
                v_trip_id,
                NULL,
                'Empty cylinder ' || COALESCE(v_cyl_serial, '#' || NEW.fk_cylinder)
                    || ' collected from customer. Condition: '
                    || NEW.cylinder_condition
                    || CASE WHEN NEW.damage_description IS NOT NULL
                            THEN ' (' || NEW.damage_description || ')' ELSE '' END
            );

            UPDATE public.tbl_reconciliation_header
               SET expected_count  = expected_count  + 1,
                   accounted_count = accounted_count + 1,
                   updated_at      = now()
             WHERE pk_header_id = v_header_id;

        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[EMPTY_PICKUP/line cylinder=%]: %', NEW.fk_cylinder, SQLERRM;
        END;
    END IF;

    -- ── NEW (V96): Cross-trip delivery recovery — mark original delivery line ──
    --
    -- Find the most recent DELIVERED / ACCOUNTED checkpoint line for this
    -- cylinder in any OTHER trip's TRIP_LOAD header and mark it
    -- DELIVERED_RECOVERED so the original delivery trip's accountability record
    -- shows the physical closure of the cylinder custody cycle.
    --
    -- Only the latest line is updated (most recent line_resolved_at).
    -- The lookup is by fk_cylinder (ID), never by count.
    BEGIN
        WITH latest_delivery AS (
            SELECT rc.pk_checkpoint_id
              FROM public.tbl_reconciliation_checkpoint rc
              JOIN public.tbl_reconciliation_header      rh ON rh.pk_header_id = rc.fk_header
             WHERE rc.fk_cylinder              = NEW.fk_cylinder
               AND rc.accountability_bucket    = 'DELIVERED'
               AND rc.line_status              = 'ACCOUNTED'
               AND rh.header_type              = 'TRIP_LOAD'
               AND rh.fk_vehicle_trip          IS DISTINCT FROM v_trip_id
             ORDER BY rc.line_resolved_at DESC NULLS LAST
             LIMIT 1
        )
        UPDATE public.tbl_reconciliation_checkpoint rc
           SET accountability_bucket = 'DELIVERED_RECOVERED',
               remarks               = COALESCE(rc.remarks, '')
                                       || ' | RECOVERED as empty by trip '
                                       || v_trip_id::text
                                       || ' on ' || CURRENT_DATE::text || '.'
                                       || CASE WHEN v_cyl_serial IS NOT NULL
                                               THEN ' Serial: ' || v_cyl_serial
                                               ELSE '' END,
               line_resolved_at      = now()
          FROM latest_delivery ld
         WHERE rc.pk_checkpoint_id = ld.pk_checkpoint_id;

        GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

        IF v_rows_updated > 0 THEN
            RAISE NOTICE '[EMPTY_PICKUP/cross-trip recovery]: cylinder % (serial %) '
                         'delivery line marked DELIVERED_RECOVERED by trip %.',
                NEW.fk_cylinder, v_cyl_serial, v_trip_id;
        END IF;

    EXCEPTION WHEN OTHERS THEN
        -- Cross-trip update failing must never block the pickup itself
        RAISE NOTICE '[EMPTY_PICKUP/cross-trip recovery cylinder=%]: %',
            NEW.fk_cylinder, SQLERRM;
    END;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_empty_pickup_line_reconcile
    ON public.tbl_empty_pickup_line;

CREATE TRIGGER trg_empty_pickup_line_reconcile
AFTER INSERT ON public.tbl_empty_pickup_line
FOR EACH ROW EXECUTE FUNCTION public.fn_empty_pickup_line_reconcile();

COMMENT ON FUNCTION public.fn_empty_pickup_line_reconcile() IS
    'V96 — Replaces V91. '
    'EXISTING: Fires AFTER INSERT on tbl_empty_pickup_line. Creates one ACCOUNTED '
    'checkpoint line (EMPTY_PICKUP bucket) under the current trip''s TRIP_LOAD header. '
    'NEW V96: Also finds the most recent DELIVERED/ACCOUNTED checkpoint line for '
    'this cylinder in any other trip''s TRIP_LOAD header (lookup by fk_cylinder, '
    'not count) and marks it DELIVERED_RECOVERED with a cross-reference remark. '
    'This closes the delivery → empty-recovery accountability cycle across trips.';


-- =============================================================================
-- SUMMARY OF ACCOUNTABILITY_BUCKET VALUES AFTER V96
-- (for reference — tbl_reconciliation_checkpoint.accountability_bucket is varchar)
-- =============================================================================
--
--   DELIVERED            Full cylinder reached a customer via challan (existing V91)
--   DELIVERED_RECOVERED  Same cylinder picked up as empty by another trip (NEW V96)
--   SUPPLIER_DROPOFF     Full cylinder dropped at supplier (existing V91)
--                        Empty cylinder confirmed handed to supplier (NEW V96)
--   RETURNED_FULL        Cylinder returned to yard unused (existing V91)
--   EMPTY_PICKUP         Empty cylinder collected from customer on this trip (existing V91)
--   YARD_PRESENT         Cylinder found in yard stock scan (existing V91)
--   YARD_MISSING         Cylinder expected in yard but absent from scan (existing V91)
--   YARD_UNEXPECTED      Cylinder found in scan but system shows it elsewhere (existing V91)
--   UNACCOUNTED          None of the above — physical location unknown (existing V91)
--
-- =============================================================================
