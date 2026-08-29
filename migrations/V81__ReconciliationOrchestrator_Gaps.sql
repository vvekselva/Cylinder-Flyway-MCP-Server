-- =============================================================================
-- V77__ReconciliationOrchestrator_StopCheckpoints.sql
-- =============================================================================
-- Wires TRIP_STOP_DELIVERY and TRIP_STOP_EMPTY_PICKUP checkpoints into the
-- reconciliation orchestrator via DB-layer triggers.
--
-- TRIGGER MAP:
--   tbl_vehicle_trip_stop  AFTER UPDATE (fk_order populated)
--       → CREATE TRIP_STOP_DELIVERY checkpoint (expected_count = 0 placeholder)
--
--   tbl_order_line         AFTER INSERT (each row, extends existing trigger)
--       → UPDATE expected_count on the PENDING TRIP_STOP_DELIVERY checkpoint
--         to the current line count for this order
--
--   tbl_empty_pickup       AFTER INSERT
--       → CREATE TRIP_STOP_EMPTY_PICKUP (expected_count = total_empty_cylinders)
--
--   tbl_empty_pickup_line  AFTER INSERT (each row, extends existing trigger)
--       → UPDATE expected_count on the PENDING TRIP_STOP_EMPTY_PICKUP checkpoint
--
--   tbl_vehicle_trip       AFTER UPDATE → Halt  (replaces fn_trip_status_after_update)
--       → Resolves all PENDING TRIP_STOP_DELIVERY and TRIP_STOP_EMPTY_PICKUP
--         for this trip alongside the existing TRIP_DEPARTURE resolution
-- =============================================================================


-- =============================================================================
-- PART 1 — tbl_vehicle_trip_stop: create TRIP_STOP_DELIVERY when fk_order is set
-- =============================================================================
-- The office links a delivery challan (tbl_order) to a trip stop by setting
-- tbl_vehicle_trip_stop.fk_order. This UPDATE is the reliable signal that a
-- challan entry is in progress for that stop. expected_count starts at 0 and
-- grows with each order_line INSERT (PART 2).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_trip_stop_order_linked()
RETURNS TRIGGER AS $$
DECLARE
    v_load_id   int8;
BEGIN
    -- Only fire when fk_order transitions from NULL → a real order
    IF OLD.fk_order IS NOT NULL OR NEW.fk_order IS NULL THEN
        RETURN NEW;
    END IF;

    -- Resolve the load for this trip (1:1 guarantee from V55)
    SELECT pk_vehicle_load_id INTO v_load_id
      FROM public.tbl_vehicle_load
     WHERE fk_vehicle_trip = NEW.fk_vehicle_trip;

    BEGIN
        PERFORM public.fn_create_checkpoint(
            'TRIP_STOP_DELIVERY',
            'tbl_order',
            NEW.fk_order,
            0,          -- placeholder: actual count built by order_line trigger
            4,          -- 4-hour escalation window per stop
            'Delivery challan linked — trip ' || NEW.fk_vehicle_trip
                || ' stop ' || NEW.stop_sequence
                || ' (order ' || NEW.fk_order || ')',
            CURRENT_DATE,
            NEW.fk_vehicle_trip,
            v_load_id,
            NEW.stop_sequence
        );
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'fn_trip_stop_order_linked [create_checkpoint]: %', SQLERRM;
    END;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trip_stop_order_linked
AFTER UPDATE OF fk_order ON public.tbl_vehicle_trip_stop
FOR EACH ROW EXECUTE FUNCTION public.fn_trip_stop_order_linked();


-- =============================================================================
-- PART 2 — tbl_order_line: grow expected_count on TRIP_STOP_DELIVERY
-- =============================================================================
-- Replaces fn_audit_cylinder_delivery_after (V21, extended in V56).
-- Preserves ALL existing logic (state audit, current_status, customer address).
-- Adds: after each line INSERT, count total lines for this order and update
-- the PENDING TRIP_STOP_DELIVERY checkpoint's expected_count to match.
-- The checkpoint stays PENDING — it is resolved in bulk at trip Halt (PART 5).
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_audit_cylinder_delivery_after()
RETURNS TRIGGER AS $$
DECLARE
    v_picked_up_state_id     int8;
    v_delivered_state_id     int8;
    v_customer_id            int8;
    v_delivery_address_id    int8;
    v_line_count             int4;
BEGIN
    SELECT pk_cylinder_state_id INTO v_picked_up_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL_PICKED_UP_FOR_DELIVERY';

    SELECT pk_cylinder_state_id INTO v_delivered_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'DELIVERED_FOR_CONSUMPTION';

    -- Resolve customer and delivery address (line-level override → header fallback)
    SELECT o.fk_customer,
           COALESCE(NEW.fk_delivery_address, o.fk_delivery_address)
      INTO v_customer_id, v_delivery_address_id
      FROM public.tbl_order o
     WHERE o.pk_order_id = NEW.fk_order;

    -- ── Existing: cylinder state audit ──────────────────────────────────────
    INSERT INTO public.tbl_cylinder_state_audit (
        pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
        fk_order, changed_at, remarks
    ) VALUES (
        nextval('public.pk_cylinder_state_id_serial'),
        NEW.fk_cylinder, v_picked_up_state_id, v_delivered_state_id,
        NEW.fk_order, now(),
        'Cylinder delivered to customer. State updated by Order Line Trigger.'
    );

    -- ── Existing: current status (V56 — includes customer address) ──────────
    UPDATE public.tbl_cylinder_current_status
       SET fk_current_state            = v_delivered_state_id,
           fk_current_customer         = v_customer_id,
           fk_current_customer_address = v_delivery_address_id,
           fk_current_vehicle_trip     = NULL,
           fk_current_vehicle_load     = NULL,
           updated_at                  = now()
     WHERE fk_cylinder = NEW.fk_cylinder;

    -- ── NEW: grow expected_count on the PENDING TRIP_STOP_DELIVERY checkpoint ──
    -- Count all lines for this order now (including the one just inserted).
    SELECT COUNT(*) INTO v_line_count
      FROM public.tbl_order_line
     WHERE fk_order = NEW.fk_order;

    UPDATE public.tbl_reconciliation_checkpoint
       SET expected_count = v_line_count
     WHERE reference_entity_type = 'tbl_order'
       AND reference_entity_id   = NEW.fk_order
       AND checkpoint_type       = 'TRIP_STOP_DELIVERY'
       AND checkpoint_status     = 'PENDING';
    -- No EXCEPTION block: if the stop checkpoint doesn't exist yet
    -- (challan entered before the stop was linked) the UPDATE is a no-op.

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger already exists from V21/V56 — replacing the function is sufficient.
-- Recreate defensively in case it was dropped:
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger WHERE tgname = 'trg_02_audit_delivery_after_order'
    ) THEN
        CREATE TRIGGER trg_02_audit_delivery_after_order
        AFTER INSERT ON public.tbl_order_line
        FOR EACH ROW EXECUTE FUNCTION fn_audit_cylinder_delivery_after();
    END IF;
END $$;


-- =============================================================================
-- PART 3 — tbl_empty_pickup: create TRIP_STOP_EMPTY_PICKUP on header INSERT
-- =============================================================================
-- tbl_empty_pickup has total_empty_cylinders on the header and fk_vehicle_trip
-- (V55). Both are available at INSERT time, so the checkpoint is created
-- immediately with the correct expected_count — no placeholder needed.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_empty_pickup_checkpoint()
RETURNS TRIGGER AS $$
DECLARE
    v_load_id       int8;
    v_stop_sequence int4;
BEGIN
    -- Only create checkpoint when this pickup belongs to a trip
    IF NEW.fk_vehicle_trip IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT pk_vehicle_load_id INTO v_load_id
      FROM public.tbl_vehicle_load
     WHERE fk_vehicle_trip = NEW.fk_vehicle_trip;

    -- Find the trip stop sequence for this pickup (via fk_stop added in V55)
    SELECT stop_sequence INTO v_stop_sequence
      FROM public.tbl_vehicle_trip_stop
     WHERE fk_vehicle_trip = NEW.fk_vehicle_trip
       AND pk_stop_id = NEW.fk_stop;

    BEGIN
        PERFORM public.fn_create_checkpoint(
            'TRIP_STOP_EMPTY_PICKUP',
            'tbl_empty_pickup',
            NEW.pk_pickup_id,
            NEW.total_empty_cylinders,  -- known at header INSERT
            4,
            'Empty pickup from customer ' || NEW.fk_customer
                || ' — trip ' || NEW.fk_vehicle_trip
                || ' stop ' || COALESCE(v_stop_sequence::text, '?')
                || ' (' || NEW.total_empty_cylinders || ' cylinders expected)',
            CURRENT_DATE,
            NEW.fk_vehicle_trip,
            v_load_id,
            v_stop_sequence
        );
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'fn_empty_pickup_checkpoint [create_checkpoint]: %', SQLERRM;
    END;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_empty_pickup_checkpoint
AFTER INSERT ON public.tbl_empty_pickup
FOR EACH ROW EXECUTE FUNCTION public.fn_empty_pickup_checkpoint();


-- =============================================================================
-- PART 4 — tbl_empty_pickup_line: update expected_count as lines are entered
-- =============================================================================
-- Replaces fn_audit_empty_pickup_line_after (V44, extended in V56).
-- Preserves ALL existing logic (state audit, current_status, clear customer).
-- Adds: after each line INSERT, count lines and update the PENDING
-- TRIP_STOP_EMPTY_PICKUP checkpoint's expected_count.
--
-- Why update expected_count when it was already set from total_empty_cylinders?
-- The header value is what the driver declared. Line count is what was actually
-- scanned. If they differ, the variance surfaces at Halt resolution (PART 5).
-- Keeping expected = header declaration and actual = line count is the comparison.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_audit_empty_pickup_line_after()
RETURNS TRIGGER AS $$
DECLARE
    v_delivered_state_id        int8;
    v_empty_in_transit_state_id int8;
    v_line_count                int4;
BEGIN
    SELECT pk_cylinder_state_id INTO v_delivered_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'DELIVERED_FOR_CONSUMPTION';

    SELECT pk_cylinder_state_id INTO v_empty_in_transit_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_IN_TRANSIT_TO_YARD';

    -- ── Existing: cylinder state audit ──────────────────────────────────────
    INSERT INTO public.tbl_cylinder_state_audit (
        pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
        fk_order, changed_at, remarks
    ) VALUES (
        nextval('public.pk_cylinder_state_id_serial'),
        NEW.fk_cylinder,
        v_delivered_state_id,
        v_empty_in_transit_state_id,
        (SELECT fk_order FROM public.tbl_empty_pickup WHERE pk_pickup_id = NEW.fk_empty_pickup),
        now(),
        'Empty cylinder picked up from customer. In transit to yard.'
    );

    -- ── Existing: current status (V56 — clears customer and address) ────────
    UPDATE public.tbl_cylinder_current_status
       SET fk_current_state            = v_empty_in_transit_state_id,
           fk_current_customer         = NULL,
           fk_current_customer_address = NULL,
           updated_at                  = now()
     WHERE fk_cylinder = NEW.fk_cylinder;

    -- ── NEW: track actual scanned line count against the header declaration ──
    -- expected_count was set from total_empty_cylinders at header INSERT.
    -- We track actual scanned lines separately — the Halt trigger compares them.
    -- Here we update expected_count only to reflect what was declared;
    -- actual_count is set at resolution time from the true line count.
    SELECT COUNT(*) INTO v_line_count
      FROM public.tbl_empty_pickup_line
     WHERE fk_empty_pickup = NEW.fk_empty_pickup;

    -- Store running scan count in remarks for visibility (optional — audit trail)
    UPDATE public.tbl_reconciliation_checkpoint
       SET remarks = remarks || ' | Scanned: ' || v_line_count
     WHERE reference_entity_type = 'tbl_empty_pickup'
       AND reference_entity_id   = NEW.fk_empty_pickup
       AND checkpoint_type       = 'TRIP_STOP_EMPTY_PICKUP'
       AND checkpoint_status     = 'PENDING';

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger already exists from V44/V56 — function replacement is sufficient.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger WHERE tgname = 'trg_01_audit_empty_pickup_line_after'
    ) THEN
        CREATE TRIGGER trg_01_audit_empty_pickup_line_after
        AFTER INSERT ON public.tbl_empty_pickup_line
        FOR EACH ROW EXECUTE FUNCTION fn_audit_empty_pickup_line_after();
    END IF;
END $$;


-- =============================================================================
-- PART 5 — fn_trip_status_after_update: resolve all stop checkpoints at Halt
-- =============================================================================
-- Extends the Halt block to resolve every PENDING TRIP_STOP_DELIVERY and
-- TRIP_STOP_EMPTY_PICKUP for this trip. Each is resolved with the true line
-- count queried from the source tables — if any stop's line count differs from
-- its declared expected_count, that checkpoint becomes VARIANCE.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_trip_status_after_update()
RETURNS TRIGGER AS $$
DECLARE
    v_new_name      varchar(50);
    v_load_id       int8;
    v_cyl_count     int4 := 0;
    -- Halt resolution
    v_stop_rec      RECORD;
    v_actual_lines  int4;
    v_delivered_count int4 := 0;
    v_pickup_count    int4 := 0;
BEGIN
    IF NEW.fk_trip_status = OLD.fk_trip_status THEN RETURN NEW; END IF;

    SELECT status_name INTO v_new_name
      FROM public.tbl_trip_status WHERE pk_trip_status_id = NEW.fk_trip_status;

    SELECT pk_vehicle_load_id INTO v_load_id
      FROM public.tbl_vehicle_load WHERE fk_vehicle_trip = NEW.pk_vehicle_trip_id;

    IF v_load_id IS NOT NULL THEN
        SELECT COUNT(pk_vehicle_load_line_id) INTO v_cyl_count
          FROM public.tbl_vehicle_load_line WHERE fk_vehicle_load = v_load_id;
        IF v_cyl_count = 0 THEN
            SELECT COALESCE(total_cylinders_loaded, 0) INTO v_cyl_count
              FROM public.tbl_vehicle_load WHERE pk_vehicle_load_id = v_load_id;
        END IF;
    END IF;

    -- ── Loaded: daily opening + TRIP_LOAD_CONFIRMED + TRIP_DEPARTURE ─────────
    IF v_new_name = 'Loaded' THEN
        BEGIN PERFORM public.fn_open_daily_count(CURRENT_DATE, 'TRIP_LOAD');
        EXCEPTION WHEN OTHERS THEN RAISE NOTICE '[Loaded/daily_count]: %', SQLERRM; END;

        BEGIN
            PERFORM public.fn_create_checkpoint(
                'TRIP_LOAD_CONFIRMED', 'tbl_vehicle_load', v_load_id,
                v_cyl_count, 2,
                'Load sealed — trip ' || NEW.pk_vehicle_trip_id
                    || ', ' || v_cyl_count || ' cylinders locked.',
                CURRENT_DATE, NEW.pk_vehicle_trip_id, v_load_id, NULL
            );
        EXCEPTION WHEN OTHERS THEN RAISE NOTICE '[Loaded/LOAD_CONFIRMED]: %', SQLERRM; END;

        BEGIN
            PERFORM public.fn_create_checkpoint(
                'TRIP_DEPARTURE', 'tbl_vehicle_trip', NEW.pk_vehicle_trip_id,
                v_cyl_count, 12,
                'Trip ' || NEW.pk_vehicle_trip_id || ' departed with '
                    || v_cyl_count || ' cylinders.',
                CURRENT_DATE, NEW.pk_vehicle_trip_id, v_load_id, NULL
            );
        EXCEPTION WHEN OTHERS THEN RAISE NOTICE '[Loaded/DEPARTURE]: %', SQLERRM; END;
    END IF;

    -- ── Proceeding: retrospective challan-entry event — no checkpoint ─────────

    -- ── Halt: resolve TRIP_DEPARTURE + all per-stop checkpoints ─────────────
    IF v_new_name = 'Halt' THEN

        -- ── 1. Resolve each TRIP_STOP_DELIVERY with true line count ──────────
        FOR v_stop_rec IN
            SELECT pk_checkpoint_id,
                   reference_entity_id AS order_id,
                   expected_count
              FROM public.tbl_reconciliation_checkpoint
             WHERE fk_vehicle_trip  = NEW.pk_vehicle_trip_id
               AND checkpoint_type  = 'TRIP_STOP_DELIVERY'
               AND checkpoint_status = 'PENDING'
        LOOP
            SELECT COUNT(*) INTO v_actual_lines
              FROM public.tbl_order_line
             WHERE fk_order = v_stop_rec.order_id;

            v_delivered_count := v_delivered_count + v_actual_lines;

            BEGIN
                PERFORM public.fn_resolve_checkpoint(
                    'tbl_order', v_stop_rec.order_id,
                    'TRIP_STOP_DELIVERY', v_actual_lines,
                    'Resolved at trip Halt. Lines entered: ' || v_actual_lines
                        || ' / Declared: ' || v_stop_rec.expected_count,
                    NEW.pk_vehicle_trip_id
                );
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE '[Halt/TRIP_STOP_DELIVERY order=%]: %',
                    v_stop_rec.order_id, SQLERRM;
            END;
        END LOOP;

        -- ── 2. Resolve each TRIP_STOP_EMPTY_PICKUP with true scanned count ───
        -- expected_count = header declaration (total_empty_cylinders)
        -- actual_count   = lines actually scanned into tbl_empty_pickup_line
        FOR v_stop_rec IN
            SELECT pk_checkpoint_id,
                   reference_entity_id AS pickup_id,
                   expected_count
              FROM public.tbl_reconciliation_checkpoint
             WHERE fk_vehicle_trip  = NEW.pk_vehicle_trip_id
               AND checkpoint_type  = 'TRIP_STOP_EMPTY_PICKUP'
               AND checkpoint_status = 'PENDING'
        LOOP
            SELECT COUNT(*) INTO v_actual_lines
              FROM public.tbl_empty_pickup_line
             WHERE fk_empty_pickup = v_stop_rec.pickup_id;

            v_pickup_count := v_pickup_count + v_actual_lines;

            BEGIN
                PERFORM public.fn_resolve_checkpoint(
                    'tbl_empty_pickup', v_stop_rec.pickup_id,
                    'TRIP_STOP_EMPTY_PICKUP', v_actual_lines,
                    'Resolved at trip Halt. Scanned: ' || v_actual_lines
                        || ' / Driver declared: ' || v_stop_rec.expected_count,
                    NEW.pk_vehicle_trip_id
                );
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE '[Halt/TRIP_STOP_EMPTY_PICKUP pickup=%]: %',
                    v_stop_rec.pickup_id, SQLERRM;
            END;
        END LOOP;

        -- ── 3. Resolve TRIP_DEPARTURE with true accounted count ───────────────
        -- Accounted = cylinders that have a challan entry (delivered) +
        --             cylinders collected as empties.
        -- Any cylinder still in FULL_PICKED_UP_FOR_DELIVERY state (no challan yet)
        -- contributes to a VARIANCE — it left the yard but has no challan record.
        BEGIN
            PERFORM public.fn_resolve_checkpoint(
                'tbl_vehicle_trip', NEW.pk_vehicle_trip_id,
                'TRIP_DEPARTURE',
                v_delivered_count + v_pickup_count,
                COALESCE(NEW.audit_notes,
                    'Halt resolution — Delivered: ' || v_delivered_count
                        || ', Empties collected: ' || v_pickup_count
                        || ', Loaded: ' || v_cyl_count),
                NEW.pk_vehicle_trip_id
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[Halt/TRIP_DEPARTURE]: %', SQLERRM;
        END;

    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
-- Trigger already exists from V69 — function replacement is sufficient.