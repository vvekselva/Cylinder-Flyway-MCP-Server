-- =============================================================================
-- V95__Fix_SupplierDropoff_Trigger_And_YardGate_EmptyReturn.sql
-- =============================================================================
--
-- ROOT CAUSE ANALYSIS
-- ─────────────────────────────────────────────────────────────────────────────
--
-- BUG 1 — Supplier stop drop-off does NOT populate reconciliation header / lines
-- ─────────────────────────────────────────────────────────────────────────────
-- fn_audit_supplier_dropoff_stop_completed() was written in V63, then replaced
-- in V90 and again in V91.  Each version says "Fires AFTER UPDATE OF stop_status
-- on tbl_vehicle_trip_stop when a SUPPLIER_DROPOFF stop transitions to COMPLETED."
--
-- HOWEVER: NO trigger was ever bound to that function across all migrations.
-- V63 / V65 only create trg_01_audit_supplier_trip_line_insert on
-- tbl_supplier_trip_line.  There is no CREATE TRIGGER … ON tbl_vehicle_trip_stop
-- anywhere in the migration history.
--
-- Effect: a SUPPLIER_DROPOFF stop can be completed via application code, the
-- cylinder state loop inside the function never runs, the reconciliation header
-- is never opened, and no checkpoint lines are ever inserted.
--
-- Fix: create the missing trigger so that completing any tbl_vehicle_trip_stop
-- row fires fn_audit_supplier_dropoff_stop_completed().  The function already
-- guards internally with:
--   IF v_stop_type_name <> 'SUPPLIER_DROPOFF' THEN RETURN NEW; END IF;
-- so it is safe to fire on every stop_status transition — it is a no-op for
-- CUSTOMER_DELIVERY and other stop types.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- BUG 2 — Empty cylinders returned to yard without supplier drop-off remain
--          stranded because the yard gate still rejects them
-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle of EMPTY_FOR_SUPPLIER cylinders on a trip:
--   1. Yard load       → EMPTY → EMPTY_PICKED_FOR_REFILL  (fn_audit_cylinder_load_after)
--   2a. Normal path    → SUPPLIER_DROPOFF stop COMPLETED
--                     → EMPTY_PICKED_FOR_REFILL → EMPTY_DELIVERED_FOR_REFILL
--   2b. Aborted path   → trip halts WITHOUT a supplier stop
--                     → cylinder remains EMPTY_PICKED_FOR_REFILL
--                     → driver brings it back to yard
--                     → yard gate REJECTS it ← BUG
--
-- V78 attempted to fix this:
--   • Created fn_validate_yard_entry_state (accepts EMPTY_PICKED_FOR_REFILL)
--   • Created fn_audit_yard_entry_after (handles EMPTY_PICKED_FOR_REFILL → EMPTY)
--
-- BUT V78 wrote new functions with new names while commenting
-- "trigger bindings remain (trg_01_validate_yard_entry_state)".
-- That trigger does NOT exist.  The actual live trigger is:
--   trg_01_check_cylinder_before_yard_entry → fn_check_cylinder_before_yard_entry  (V65)
--   trg_02_audit_cylinder_yard_entry_after  → fn_audit_cylinder_yard_entry_after   (V65)
--
-- fn_check_cylinder_before_yard_entry (V65) only accepts FULL_PICKED_FROM_SUPPLIER.
-- It was NEVER updated after V65.  V78's new functions are dead code — no trigger
-- calls them.
--
-- Fix A: Replace fn_check_cylinder_before_yard_entry in-place (same name, same
--        trigger binding) to accept all four valid source states.
-- Fix B: Replace fn_audit_cylinder_yard_entry_after in-place to handle the
--        EMPTY_PICKED_FOR_REFILL → EMPTY transition that V78 intended.
--
-- Additionally: EMPTY_FOR_SUPPLIER cylinders are completely invisible to the
-- TRIP_LOAD reconciliation header (fn_trip_status_after_update only creates
-- PENDING lines for FULL_FOR_DELIVERY + FULL_FOR_BUFFER).  When such a cylinder
-- returns to yard on the aborted path there is no checkpoint line to resolve.
-- Fix C: Extend the LOADED branch of fn_trip_status_after_update to also create
--        PENDING checkpoint lines for EMPTY_FOR_SUPPLIER cylinders, with a new
--        accountability_bucket 'EMPTY_RETURNED_NO_DROPOFF'.  At Halt, extend
--        fn_trip_status_after_update to resolve those lines via the cylinder's
--        current state: EMPTY_DELIVERED_FOR_REFILL → 'SUPPLIER_DROPOFF',
--        EMPTY or EMPTY_PICKED_FOR_REFILL-returned-to-yard → 'EMPTY_RETURNED_NO_DROPOFF'.
--
-- DEPENDENCIES
--   V54  fn_audit_cylinder_load_after  (EMPTY_FOR_SUPPLIER purpose, state transition)
--   V65  fn_check_cylinder_before_yard_entry  (REPLACED HERE)
--   V65  fn_audit_cylinder_yard_entry_after   (REPLACED HERE)
--   V78  fn_validate_yard_entry_state, fn_audit_yard_entry_after  (orphaned — left in place)
--   V91  fn_audit_supplier_dropoff_stop_completed  (TRIGGER ADDED HERE)
--   V91  fn_trip_status_after_update  (REPLACED HERE — LOADED + HALT branches extended)
-- =============================================================================


-- =============================================================================
-- PART 1 — BUG 1 FIX
--           Create the missing trigger that binds stop completion to the
--           supplier dropoff reconciliation function.
-- =============================================================================

DROP TRIGGER IF EXISTS trg_audit_supplier_dropoff_stop_completed
    ON public.tbl_vehicle_trip_stop;

CREATE TRIGGER trg_audit_supplier_dropoff_stop_completed
AFTER UPDATE OF stop_status
ON public.tbl_vehicle_trip_stop
FOR EACH ROW
EXECUTE FUNCTION public.fn_audit_supplier_dropoff_stop_completed();

COMMENT ON TRIGGER trg_audit_supplier_dropoff_stop_completed
    ON public.tbl_vehicle_trip_stop IS
    'V95 — MISSING TRIGGER added. Calls fn_audit_supplier_dropoff_stop_completed() '
    'after every stop_status change. The function guards internally: only acts when '
    'stop_status transitions to COMPLETED AND stop_type = SUPPLIER_DROPOFF. '
    'Function was present since V63 (updated V90, V91) but was never bound to a trigger.';


-- =============================================================================
-- PART 2A — BUG 2 FIX: Gate function
--            Replace fn_check_cylinder_before_yard_entry (V65) in-place.
--            The existing trigger trg_01_check_cylinder_before_yard_entry already
--            calls this function — replacing the body is sufficient.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_check_cylinder_before_yard_entry()
RETURNS TRIGGER AS $$
DECLARE
    v_current_state_id   int8;
    v_current_state_name varchar(100);

    -- All states that permit a yard entry
    v_full_picked_from_supplier_id    int8;
    v_full_picked_up_for_delivery_id  int8;
    v_empty_in_transit_id             int8;
    v_empty_picked_for_refill_id      int8;   -- V95: added (was missing from V65)
BEGIN
    SELECT pk_cylinder_state_id INTO v_full_picked_from_supplier_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL_PICKED_FROM_SUPPLIER';

    SELECT pk_cylinder_state_id INTO v_full_picked_up_for_delivery_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL_PICKED_UP_FOR_DELIVERY';

    SELECT pk_cylinder_state_id INTO v_empty_in_transit_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_IN_TRANSIT_TO_YARD';

    SELECT pk_cylinder_state_id INTO v_empty_picked_for_refill_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_PICKED_FOR_REFILL';

    -- ── Resolve current state ─────────────────────────────────────────────
    SELECT ccs.fk_current_state, cs.cylinder_state
      INTO v_current_state_id, v_current_state_name
      FROM public.tbl_cylinder_current_status ccs
      JOIN public.tbl_cylinder_states         cs
           ON cs.pk_cylinder_state_id = ccs.fk_current_state
     WHERE ccs.fk_cylinder = NEW.fk_cylinder;

    -- Fallback: audit trail
    IF NOT FOUND THEN
        SELECT fk_new_state INTO v_current_state_id
          FROM public.tbl_cylinder_state_audit
         WHERE fk_cylinder = NEW.fk_cylinder
         ORDER BY changed_at DESC, pk_audit_id DESC
         LIMIT 1;

        SELECT cylinder_state INTO v_current_state_name
          FROM public.tbl_cylinder_states
         WHERE pk_cylinder_state_id = v_current_state_id;
    END IF;

    -- ── Gate: must be one of the four accepted states ─────────────────────
    IF v_current_state_id NOT IN (
        v_full_picked_from_supplier_id,
        v_full_picked_up_for_delivery_id,
        v_empty_in_transit_id,
        v_empty_picked_for_refill_id       -- V95: aborted-trip empty return
    ) THEN
        RAISE EXCEPTION
            'Yard Entry Validation Failed: Cylinder % cannot enter the yard from '
            'state [%]. '
            'Accepted states: '
            'FULL_PICKED_FROM_SUPPLIER (post-refill collection), '
            'FULL_PICKED_UP_FOR_DELIVERY (full cylinder returned un-delivered), '
            'EMPTY_IN_TRANSIT_TO_YARD (empty collected from customer), '
            'EMPTY_PICKED_FOR_REFILL (empty returned without supplier dropoff). '
            'Yard entry row: %.',
            NEW.fk_cylinder,
            COALESCE(v_current_state_name, 'UNKNOWN — no state record'),
            NEW.pk_yard_entry_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_check_cylinder_before_yard_entry() IS
    'V95 — Replaces V65. '
    'Accepts four source states for a yard entry: '
    'FULL_PICKED_FROM_SUPPLIER (refill return), '
    'FULL_PICKED_UP_FOR_DELIVERY (undelivered full returned), '
    'EMPTY_IN_TRANSIT_TO_YARD (customer empty collected mid-trip), '
    'EMPTY_PICKED_FOR_REFILL (empty brought back without supplier stop — V95 fix). '
    'V65 only accepted FULL_PICKED_FROM_SUPPLIER. '
    'V78 created fn_validate_yard_entry_state with the correct logic but under a '
    'different function name, so the live trigger trg_01_check_cylinder_before_yard_entry '
    'continued calling this (V65) function. V95 corrects this by replacing the body '
    'in-place under the original name so no trigger re-binding is needed.';


-- =============================================================================
-- PART 2B — BUG 2 FIX: Yard entry audit function
--            Replace fn_audit_cylinder_yard_entry_after (V65) in-place.
--            Same rationale as 2A — trg_02_audit_cylinder_yard_entry_after already
--            calls this function name.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_audit_cylinder_yard_entry_after()
RETURNS TRIGGER AS $$
DECLARE
    v_full_picked_from_supplier_id    int8;
    v_full_picked_up_for_delivery_id  int8;
    v_empty_in_transit_id             int8;
    v_empty_picked_for_refill_id      int8;

    v_full_state_id   int8;
    v_empty_state_id  int8;

    v_current_state_id   int8;
    v_previous_state_id  int8;
    v_new_state_id       int8;
    v_remarks_text       varchar(500);
BEGIN
    -- ── Resolve all state IDs ─────────────────────────────────────────────
    SELECT pk_cylinder_state_id INTO v_full_picked_from_supplier_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL_PICKED_FROM_SUPPLIER';

    SELECT pk_cylinder_state_id INTO v_full_picked_up_for_delivery_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL_PICKED_UP_FOR_DELIVERY';

    SELECT pk_cylinder_state_id INTO v_empty_in_transit_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_IN_TRANSIT_TO_YARD';

    SELECT pk_cylinder_state_id INTO v_empty_picked_for_refill_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_PICKED_FOR_REFILL';

    SELECT pk_cylinder_state_id INTO v_full_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL';

    SELECT pk_cylinder_state_id INTO v_empty_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY';

    -- ── Get current state ─────────────────────────────────────────────────
    SELECT fk_current_state INTO v_current_state_id
      FROM public.tbl_cylinder_current_status
     WHERE fk_cylinder = NEW.fk_cylinder;

    IF NOT FOUND THEN
        SELECT fk_new_state INTO v_current_state_id
          FROM public.tbl_cylinder_state_audit
         WHERE fk_cylinder = NEW.fk_cylinder
         ORDER BY changed_at DESC, pk_audit_id DESC
         LIMIT 1;
    END IF;

    -- ── Route: map source state → target state ────────────────────────────
    --
    --  Source state                       Target state
    --  ─────────────────────────────────────────────────
    --  FULL_PICKED_FROM_SUPPLIER        → FULL   (refill collected, returned to yard)
    --  FULL_PICKED_UP_FOR_DELIVERY      → FULL   (full cylinder not delivered, returned)
    --  EMPTY_IN_TRANSIT_TO_YARD         → EMPTY  (customer empty collected mid-trip)
    --  EMPTY_PICKED_FOR_REFILL  ← V95  → EMPTY  (empty returned without supplier stop)
    --
    IF v_current_state_id = v_full_picked_from_supplier_id THEN
        v_previous_state_id := v_full_picked_from_supplier_id;
        v_new_state_id      := v_full_state_id;
        v_remarks_text :=
            'Cylinder arrived at yard after supplier refill. '
            'State: FULL_PICKED_FROM_SUPPLIER → FULL. '
            'Yard entry: ' || NEW.pk_yard_entry_id || '.';

    ELSIF v_current_state_id = v_full_picked_up_for_delivery_id THEN
        v_previous_state_id := v_full_picked_up_for_delivery_id;
        v_new_state_id      := v_full_state_id;
        v_remarks_text :=
            'Full cylinder returned to yard without delivery. '
            'State: FULL_PICKED_UP_FOR_DELIVERY → FULL. '
            'Yard entry: ' || NEW.pk_yard_entry_id || '.';

    ELSIF v_current_state_id = v_empty_in_transit_id THEN
        v_previous_state_id := v_empty_in_transit_id;
        v_new_state_id      := v_empty_state_id;
        v_remarks_text :=
            'Empty cylinder arrived at yard from customer pickup. '
            'State: EMPTY_IN_TRANSIT_TO_YARD → EMPTY. '
            'Yard entry: ' || NEW.pk_yard_entry_id || '.';

    -- ── V95: aborted-trip empty return ───────────────────────────────────
    ELSIF v_current_state_id = v_empty_picked_for_refill_id THEN
        v_previous_state_id := v_empty_picked_for_refill_id;
        v_new_state_id      := v_empty_state_id;
        v_remarks_text :=
            'Empty cylinder returned to yard without supplier dropoff (aborted trip). '
            'State: EMPTY_PICKED_FOR_REFILL → EMPTY. '
            'Yard entry: ' || NEW.pk_yard_entry_id || '. '
            'Cylinder is available for the next scheduled refill run.';

    ELSE
        RAISE EXCEPTION
            'fn_audit_cylinder_yard_entry_after: Unexpected cylinder state (id=%) '
            'for cylinder %. BEFORE trigger should have prevented this yard entry.',
            v_current_state_id, NEW.fk_cylinder;
    END IF;

    -- ── 1. Write state audit row ──────────────────────────────────────────
    INSERT INTO public.tbl_cylinder_state_audit (
        pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
        fk_order, changed_at, remarks
    ) VALUES (
        nextval('public.pk_cylinder_state_id_serial'),
        NEW.fk_cylinder,
        v_previous_state_id,
        v_new_state_id,
        NULL,
        now(),
        v_remarks_text
    );

    -- ── 2. Update tbl_cylinder_current_status ────────────────────────────
    INSERT INTO public.tbl_cylinder_current_status (
        fk_cylinder,
        fk_current_state,
        fk_current_holder_customer,
        fk_current_vehicle_load,
        fk_last_supplier_trip,
        fk_last_order,
        updated_at
    )
    VALUES (
        NEW.fk_cylinder,
        v_new_state_id,
        NULL,
        NULL,    -- no longer on any vehicle
        NULL,    -- no supplier trip completed (aborted path)
        NULL,
        now()
    )
    ON CONFLICT (fk_cylinder) DO UPDATE
        SET fk_current_state           = EXCLUDED.fk_current_state,
            fk_current_holder_customer = NULL,
            fk_current_vehicle_load    = NULL,
            fk_last_supplier_trip      = NULL,
            updated_at                 = EXCLUDED.updated_at;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_audit_cylinder_yard_entry_after() IS
    'V95 — Replaces V65. '
    'Handles four yard-entry transitions: '
    'FULL_PICKED_FROM_SUPPLIER → FULL, '
    'FULL_PICKED_UP_FOR_DELIVERY → FULL, '
    'EMPTY_IN_TRANSIT_TO_YARD → EMPTY, '
    'EMPTY_PICKED_FOR_REFILL → EMPTY (V95 — aborted trip empty return). '
    'V65 only handled FULL_PICKED_FROM_SUPPLIER. '
    'V78 created fn_audit_yard_entry_after under a different name so the live trigger '
    'trg_02_audit_cylinder_yard_entry_after kept calling this (V65) function. '
    'V95 corrects in-place.';


-- =============================================================================
-- PART 3 — BUG 2 FIX (reconciliation gap)
--           Extend fn_trip_status_after_update:
--
--   LOADED branch — also create PENDING TRIP_LOAD checkpoint lines for
--     EMPTY_FOR_SUPPLIER cylinders so the header tracks their fate.
--
--   HALT branch  — resolve those lines:
--     • Cylinder in EMPTY_DELIVERED_FOR_REFILL → bucket SUPPLIER_DROPOFF
--       (stop was completed; Bug 1 trigger handles the SUPPLIER_DROPOFF header)
--     • Cylinder in EMPTY_PICKED_FOR_REFILL or EMPTY (returned to yard) →
--       bucket EMPTY_RETURNED_NO_DROPOFF  (aborted trip; yard gate now accepts it)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_trip_status_after_update()
RETURNS TRIGGER AS $$
DECLARE
    v_new_name      varchar(100);
    v_load_id       int8;
    v_cyl_count     int4 := 0;
    v_header_id     int8;

    -- Halt: aggregate checkpoint resolution (legacy rows)
    v_stop_rec      RECORD;
    v_actual_lines  int4 := 0;
    v_delivered_count int4 := 0;
    v_pickup_count    int4 := 0;

    -- Halt: TRIP_LOAD serial-level accountability
    v_acc_rec               RECORD;
    v_accounted_count       int4 := 0;
    v_unaccounted_count     int4 := 0;
    v_unaccounted_serials   text := '';
    v_load_remarks          text;

    -- V95: empty cylinder resolution at Halt
    v_empty_rec             RECORD;
    v_empty_delivered_state_id  int8;
    v_empty_state_id            int8;
    v_empty_picked_state_id     int8;
BEGIN
    IF NEW.fk_trip_status = OLD.fk_trip_status THEN RETURN NEW; END IF;

    SELECT status_name INTO v_new_name
      FROM public.tbl_trip_status
     WHERE pk_trip_status_id = NEW.fk_trip_status;

    SELECT pk_vehicle_load_id INTO v_load_id
      FROM public.tbl_vehicle_load
     WHERE fk_vehicle_trip = NEW.pk_vehicle_trip_id;

    IF v_load_id IS NOT NULL THEN
        SELECT COUNT(pk_vehicle_load_line_id) INTO v_cyl_count
          FROM public.tbl_vehicle_load_line
         WHERE fk_vehicle_load = v_load_id;

        IF v_cyl_count = 0 THEN
            SELECT COALESCE(total_cylinders_loaded, 0) INTO v_cyl_count
              FROM public.tbl_vehicle_load
             WHERE pk_vehicle_load_id = v_load_id;
        END IF;
    END IF;

    -- =========================================================================
    -- LOADED — open TRIP_LOAD header + create per-cylinder lines + TRIP_DEPARTURE
    -- =========================================================================
    IF v_new_name = 'Loaded' THEN

        BEGIN
            PERFORM public.fn_open_daily_count(CURRENT_DATE, 'TRIP_LOAD');
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[Loaded/daily_count]: %', SQLERRM;
        END;

        -- ── Open TRIP_LOAD header ─────────────────────────────────────────────
        BEGIN
            v_header_id := public.fn_open_reconciliation_header(
                'TRIP_LOAD',
                'tbl_vehicle_load',
                v_load_id,
                v_cyl_count,
                12,                              -- 12 h escalation window
                NEW.pk_vehicle_trip_id,
                v_load_id,
                NULL, NULL, NULL,
                'Trip ' || NEW.pk_vehicle_trip_id
                    || ' loaded: ' || v_cyl_count || ' cylinders sealed for departure.'
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[Loaded/TRIP_LOAD header]: %', SQLERRM;
        END;

        -- ── Create one checkpoint LINE per cylinder ───────────────────────────
        --   V91: FULL_FOR_DELIVERY + FULL_FOR_BUFFER only.
        --   V95: also includes EMPTY_FOR_SUPPLIER cylinders.
        IF v_header_id IS NOT NULL AND v_load_id IS NOT NULL THEN
            BEGIN
                INSERT INTO public.tbl_reconciliation_checkpoint (
                    checkpoint_date,
                    checkpoint_type,
                    checkpoint_status,
                    reference_entity_type,
                    reference_entity_id,
                    fk_vehicle_trip,
                    fk_vehicle_load,
                    expected_count,
                    actual_count,
                    escalation_threshold_hours,
                    remarks,
                    fk_header,
                    fk_cylinder,
                    line_status,
                    accountability_bucket
                )
                SELECT
                    CURRENT_DATE,
                    'TRIP_LOAD_CONFIRMED',
                    'PENDING',
                    'tbl_vehicle_load_line',
                    vll.pk_vehicle_load_line_id,
                    NEW.pk_vehicle_trip_id,
                    v_load_id,
                    1,
                    NULL,
                    NULL,
                    'Load line: cylinder ' || c.cylinder_serial
                        || ' (' || vlp.load_purpose || ') — awaiting Halt accountability.',
                    v_header_id,
                    vll.fk_cylinder,
                    'PENDING',
                    'UNACCOUNTED'               -- resolved at Halt
                FROM   public.tbl_vehicle_load_line   vll
                JOIN   public.tbl_cylinder             c    ON c.pk_cylinder_id       = vll.fk_cylinder
                JOIN   public.tbl_vehicle_load_purpose vlp  ON vlp.pk_load_purpose_id = vll.fk_load_purpose
                WHERE  vll.fk_vehicle_load = v_load_id
                  AND  vlp.load_purpose    IN (
                      'FULL_FOR_DELIVERY',
                      'FULL_FOR_BUFFER',
                      'EMPTY_FOR_SUPPLIER'     -- V95: added so empties are tracked
                  );
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE '[Loaded/TRIP_LOAD lines]: %', SQLERRM;
            END;
        END IF;

        -- ── TRIP_DEPARTURE aggregate checkpoint (unchanged) ───────────────────
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

    END IF;

    -- =========================================================================
    -- HALT — resolve all open checkpoints and the TRIP_LOAD header
    -- =========================================================================
    IF v_new_name = 'Halt' THEN

        -- ── Step 1: Resolve each TRIP_STOP_DELIVERY (legacy aggregate) ────────
        FOR v_stop_rec IN
            SELECT pk_checkpoint_id,
                   reference_entity_id AS order_id,
                   expected_count
              FROM public.tbl_reconciliation_checkpoint
             WHERE fk_vehicle_trip   = NEW.pk_vehicle_trip_id
               AND checkpoint_type   = 'TRIP_STOP_DELIVERY'
               AND checkpoint_status = 'PENDING'
               AND fk_header IS NULL
        LOOP
            SELECT COUNT(*) INTO v_actual_lines
              FROM public.tbl_order_line
             WHERE fk_order = v_stop_rec.order_id;

            v_delivered_count := v_delivered_count + v_actual_lines;

            BEGIN
                PERFORM public.fn_resolve_checkpoint(
                    'tbl_order',
                    v_stop_rec.order_id,
                    'TRIP_STOP_DELIVERY',
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

        -- ── Step 2: Resolve each TRIP_STOP_EMPTY_PICKUP (legacy aggregate) ────
        FOR v_stop_rec IN
            SELECT pk_checkpoint_id,
                   reference_entity_id AS pickup_id,
                   expected_count
              FROM public.tbl_reconciliation_checkpoint
             WHERE fk_vehicle_trip   = NEW.pk_vehicle_trip_id
               AND checkpoint_type   = 'TRIP_STOP_EMPTY_PICKUP'
               AND checkpoint_status = 'PENDING'
               AND fk_header IS NULL
        LOOP
            SELECT COUNT(*) INTO v_actual_lines
              FROM public.tbl_empty_pickup_line
             WHERE fk_empty_pickup = v_stop_rec.pickup_id;

            v_pickup_count := v_pickup_count + v_actual_lines;

            BEGIN
                PERFORM public.fn_resolve_checkpoint(
                    'tbl_empty_pickup',
                    v_stop_rec.pickup_id,
                    'TRIP_STOP_EMPTY_PICKUP',
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
                'tbl_vehicle_trip',
                NEW.pk_vehicle_trip_id,
                'TRIP_DEPARTURE',
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

        -- ── Step 4: Resolve TRIP_LOAD header — FULL cylinder lines ───────────
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
                             'Header may have been created before V91 or was already closed.',
                    NEW.pk_vehicle_trip_id;
            ELSE
                -- ── 4a: Resolve FULL cylinder lines via fn_trip_load_accountability ──
                FOR v_acc_rec IN
                    SELECT fk_cylinder,
                           cylinder_serial,
                           load_purpose_name,
                           accountability_bucket
                      FROM public.fn_trip_load_accountability(NEW.pk_vehicle_trip_id)
                LOOP
                    IF v_acc_rec.accountability_bucket = 'UNACCOUNTED' THEN
                        v_unaccounted_count := v_unaccounted_count + 1;
                        IF v_unaccounted_count <= 20 THEN
                            v_unaccounted_serials := v_unaccounted_serials
                                || v_acc_rec.cylinder_serial || ' ('
                                || v_acc_rec.load_purpose_name || '), ';
                        END IF;
                        -- PENDING line stays PENDING — closed as VARIANCE below
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

                -- ── 4b: V95 — Resolve EMPTY_FOR_SUPPLIER cylinder lines ──────────
                --
                --   fn_trip_load_accountability only covers FULL cylinders.
                --   For EMPTY_FOR_SUPPLIER lines, resolve by current cylinder state:
                --
                --   EMPTY_DELIVERED_FOR_REFILL  → supplier stop was completed
                --       bucket = SUPPLIER_DROPOFF (the SUPPLIER_DROPOFF header
                --       was opened by fn_audit_supplier_dropoff_stop_completed)
                --
                --   EMPTY / EMPTY_PICKED_FOR_REFILL → cylinder came back to yard
                --       without visiting a supplier stop (aborted trip)
                --       bucket = EMPTY_RETURNED_NO_DROPOFF
                --
                SELECT pk_cylinder_state_id INTO v_empty_delivered_state_id
                  FROM public.tbl_cylinder_states
                 WHERE cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL';

                SELECT pk_cylinder_state_id INTO v_empty_state_id
                  FROM public.tbl_cylinder_states
                 WHERE cylinder_state = 'EMPTY';

                SELECT pk_cylinder_state_id INTO v_empty_picked_state_id
                  FROM public.tbl_cylinder_states
                 WHERE cylinder_state = 'EMPTY_PICKED_FOR_REFILL';

                FOR v_empty_rec IN
                    SELECT
                        cp.fk_cylinder,
                        c.cylinder_serial,
                        ccs.fk_current_state
                      FROM public.tbl_reconciliation_checkpoint cp
                      JOIN public.tbl_cylinder                  c
                           ON c.pk_cylinder_id = cp.fk_cylinder
                      JOIN public.tbl_cylinder_current_status   ccs
                           ON ccs.fk_cylinder = cp.fk_cylinder
                      JOIN public.tbl_vehicle_load_line         vll
                           ON vll.pk_vehicle_load_line_id = cp.reference_entity_id
                      JOIN public.tbl_vehicle_load_purpose      vlp
                           ON vlp.pk_load_purpose_id = vll.fk_load_purpose
                     WHERE cp.fk_header     = v_header_id
                       AND cp.line_status   = 'PENDING'
                       AND cp.fk_cylinder   IS NOT NULL
                       AND vlp.load_purpose = 'EMPTY_FOR_SUPPLIER'
                LOOP
                    IF v_empty_rec.fk_current_state = v_empty_delivered_state_id THEN
                        -- Cylinder was dropped at supplier: ACCOUNTED as SUPPLIER_DROPOFF
                        v_accounted_count := v_accounted_count + 1;
                        PERFORM public.fn_resolve_reconciliation_line(
                            v_header_id,
                            v_empty_rec.fk_cylinder,
                            'ACCOUNTED',
                            'SUPPLIER_DROPOFF',
                            'Halt: empty cylinder ' || v_empty_rec.cylinder_serial
                                || ' confirmed delivered to supplier (EMPTY_DELIVERED_FOR_REFILL).'
                        );

                    ELSIF v_empty_rec.fk_current_state IN (
                              v_empty_state_id,
                              v_empty_picked_state_id
                          )
                    THEN
                        -- Cylinder returned to yard without supplier visit
                        v_accounted_count := v_accounted_count + 1;
                        PERFORM public.fn_resolve_reconciliation_line(
                            v_header_id,
                            v_empty_rec.fk_cylinder,
                            'ACCOUNTED',
                            'EMPTY_RETURNED_NO_DROPOFF',
                            'Halt: empty cylinder ' || v_empty_rec.cylinder_serial
                                || ' returned to yard without supplier dropoff '
                                || '(aborted trip — state: '
                                || v_empty_rec.fk_current_state || ').'
                        );

                    ELSE
                        -- State is unexpected at Halt — leave PENDING, will become VARIANCE
                        v_unaccounted_count := v_unaccounted_count + 1;
                        v_unaccounted_serials := v_unaccounted_serials
                            || v_empty_rec.cylinder_serial || ' (EMPTY_FOR_SUPPLIER/unknown), ';
                    END IF;
                END LOOP;

                -- ── 4c: Build closing remarks and close the header ────────────────
                IF v_unaccounted_count = 0 THEN
                    v_load_remarks :=
                        'All cylinders accounted at Halt. '
                        || 'Accounted: ' || v_accounted_count || '.';
                ELSE
                    v_load_remarks :=
                        'VARIANCE — ' || v_unaccounted_count || ' cylinder(s) UNACCOUNTED. '
                        || 'Serials: ' || rtrim(v_unaccounted_serials, ', ')
                        || CASE WHEN v_unaccounted_count > 20
                                THEN ' … (' || (v_unaccounted_count - 20) || ' more)'
                                ELSE '' END;
                END IF;

                PERFORM public.fn_close_reconciliation_header(v_header_id, v_load_remarks);

            END IF;

        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[Halt/TRIP_LOAD header]: %', SQLERRM;
        END;

    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger already exists from V69 — replacing the function body is sufficient.

COMMENT ON FUNCTION public.fn_trip_status_after_update() IS
    'V95 — Replaces V91. '
    'Loaded: opens TRIP_LOAD reconciliation header + one checkpoint line per cylinder '
    '(now includes EMPTY_FOR_SUPPLIER lines — V95 addition). '
    'Halt: resolves FULL cylinder lines via fn_trip_load_accountability (unchanged), '
    'then resolves EMPTY_FOR_SUPPLIER lines by checking current cylinder state: '
    'EMPTY_DELIVERED_FOR_REFILL → ACCOUNTED/SUPPLIER_DROPOFF; '
    'EMPTY / EMPTY_PICKED_FOR_REFILL → ACCOUNTED/EMPTY_RETURNED_NO_DROPOFF (aborted trip). '
    'Remaining PENDING lines (any purpose) are closed as VARIANCE by fn_close_reconciliation_header.';


-- =============================================================================
-- PART 4 — Back-fill: resolve any EMPTY_FOR_SUPPLIER lines that already exist
--           on CLOSED TRIP_LOAD headers where the line was left PENDING because
--           the HALT branch could not resolve them (they weren't created yet in V91).
--           This is a one-time idempotent fix for historical data.
-- =============================================================================

DO $$
DECLARE
    v_empty_delivered_state_id  int8;
    v_empty_state_id            int8;
    v_empty_picked_state_id     int8;
    v_rec                       RECORD;
BEGIN
    SELECT pk_cylinder_state_id INTO v_empty_delivered_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL';

    SELECT pk_cylinder_state_id INTO v_empty_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY';

    SELECT pk_cylinder_state_id INTO v_empty_picked_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_PICKED_FOR_REFILL';

    FOR v_rec IN
        SELECT
            cp.pk_checkpoint_id,
            cp.fk_header,
            cp.fk_cylinder,
            c.cylinder_serial,
            ccs.fk_current_state
          FROM public.tbl_reconciliation_checkpoint cp
          JOIN public.tbl_cylinder                  c
               ON c.pk_cylinder_id = cp.fk_cylinder
          JOIN public.tbl_cylinder_current_status   ccs
               ON ccs.fk_cylinder = cp.fk_cylinder
          JOIN public.tbl_vehicle_load_line         vll
               ON vll.pk_vehicle_load_line_id = cp.reference_entity_id
          JOIN public.tbl_vehicle_load_purpose      vlp
               ON vlp.pk_load_purpose_id = vll.fk_load_purpose
         WHERE cp.line_status    = 'PENDING'
           AND cp.fk_header      IS NOT NULL
           AND cp.fk_cylinder    IS NOT NULL
           AND vlp.load_purpose  = 'EMPTY_FOR_SUPPLIER'
    LOOP
        IF v_rec.fk_current_state = v_empty_delivered_state_id THEN
            PERFORM public.fn_resolve_reconciliation_line(
                v_rec.fk_header,
                v_rec.fk_cylinder,
                'ACCOUNTED',
                'SUPPLIER_DROPOFF',
                'V95 back-fill: empty cylinder ' || v_rec.cylinder_serial
                    || ' confirmed at supplier (EMPTY_DELIVERED_FOR_REFILL).'
            );

        ELSIF v_rec.fk_current_state IN (v_empty_state_id, v_empty_picked_state_id) THEN
            PERFORM public.fn_resolve_reconciliation_line(
                v_rec.fk_header,
                v_rec.fk_cylinder,
                'ACCOUNTED',
                'EMPTY_RETURNED_NO_DROPOFF',
                'V95 back-fill: empty cylinder ' || v_rec.cylinder_serial
                    || ' returned to yard without supplier dropoff.'
            );
        END IF;
    END LOOP;
END;
$$;


-- =============================================================================
-- PART 5 — Register the new accountability_bucket value in any relevant
--           constraints or documentation.
--           tbl_reconciliation_checkpoint.accountability_bucket has no CHECK
--           constraint (free-text column) so no DDL change is needed.
--           Document via comment.
-- =============================================================================

COMMENT ON COLUMN public.tbl_reconciliation_checkpoint.accountability_bucket IS
    'How the cylinder was accounted for. '
    'FULL-cylinder values: DELIVERED | SUPPLIER_DROPOFF | RETURNED_FULL | UNACCOUNTED. '
    'EMPTY-cylinder values (V95): '
    '  SUPPLIER_DROPOFF          — empty was confirmed delivered to a supplier stop. '
    '  EMPTY_RETURNED_NO_DROPOFF — empty returned to yard without visiting a supplier stop '
    '                              (aborted / short trip). '
    'YARD-check values: YARD_PRESENT | YARD_MISSING | YARD_UNEXPECTED.';
