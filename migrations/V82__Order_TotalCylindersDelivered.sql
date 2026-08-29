-- =============================================================================
-- V78__Order_TotalCylindersDelivered.sql
-- =============================================================================
-- PURPOSE:
--   Add total_cylinders_delivered to tbl_order to achieve symmetric design
--   with tbl_empty_pickup.total_empty_cylinders.
--
-- IMPACT ON TRIGGER ARCHITECTURE (V77):
--   WITH this column, tbl_order now mirrors tbl_empty_pickup exactly:
--     • tbl_order        AFTER INSERT → create TRIP_STOP_DELIVERY checkpoint
--                                       expected_count = total_cylinders_delivered
--     • tbl_order_line   AFTER INSERT → update expected_count (running line count)
--
--   The tbl_vehicle_trip_stop UPDATE trigger (trg_trip_stop_order_linked, V77
--   PART 1) is NO LONGER NEEDED and is dropped here. The checkpoint now fires
--   at tbl_order INSERT, not at the stop→order linking UPDATE.
--
-- SYMMETRIC PATTERN (both headers follow identical structure):
--
--   tbl_empty_pickup  INSERT  → TRIP_STOP_EMPTY_PICKUP  (expected = total_empty_cylinders)
--   tbl_order         INSERT  → TRIP_STOP_DELIVERY       (expected = total_cylinders_delivered)
--
--   tbl_empty_pickup_line INSERT → update running actual count
--   tbl_order_line        INSERT → update running actual count
--
--   Trip → Halt → resolve all PENDING stop checkpoints for the trip
--
-- VALIDATION:
--   A BEFORE INSERT trigger on tbl_order_line enforces that the number of
--   lines does not exceed total_cylinders_delivered, preventing over-entry.
-- =============================================================================


-- =============================================================================
-- PART 1 — Add total_cylinders_delivered to tbl_order
-- =============================================================================

ALTER TABLE public.tbl_order
    ADD COLUMN total_cylinders_delivered int4 NOT NULL DEFAULT 0;

-- Backfill from existing order_line counts for rows already in the system
UPDATE public.tbl_order o
   SET total_cylinders_delivered = (
       SELECT COUNT(*)
         FROM public.tbl_order_line ol
        WHERE ol.fk_order = o.pk_order_id
   );

-- Constraint: must be >= 0 and should be declared before lines are entered
ALTER TABLE public.tbl_order
    ADD CONSTRAINT tbl_order_total_cylinders_chk
    CHECK (total_cylinders_delivered >= 0);

COMMENT ON COLUMN public.tbl_order.total_cylinders_delivered IS
    'Number of cylinders on this delivery challan as declared by the office '
    'when entering the header. Mirrors tbl_empty_pickup.total_empty_cylinders. '
    'Used as expected_count on the TRIP_STOP_DELIVERY reconciliation checkpoint. '
    'A BEFORE INSERT trigger on tbl_order_line prevents line count exceeding this value. '
    'Set at order header INSERT; matches COUNT(tbl_order_line) when fully entered.';


-- =============================================================================
-- PART 2 — Drop the tbl_vehicle_trip_stop UPDATE trigger (V77 PART 1)
--           It is replaced by the tbl_order AFTER INSERT trigger below.
-- =============================================================================

DROP TRIGGER IF EXISTS trg_trip_stop_order_linked ON public.tbl_vehicle_trip_stop;
DROP FUNCTION IF EXISTS public.fn_trip_stop_order_linked();


-- =============================================================================
-- PART 3 — tbl_order AFTER INSERT: create TRIP_STOP_DELIVERY checkpoint
-- =============================================================================
-- Mirrors fn_empty_pickup_checkpoint exactly.
-- expected_count = total_cylinders_delivered (declared on the challan header).
-- The checkpoint fires the moment the office starts entering a challan —
-- before any lines exist — using the declared count as the expected value.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_order_delivery_checkpoint()
RETURNS TRIGGER AS $$
DECLARE
    v_stop_sequence int4;
BEGIN
    -- Only create checkpoint when this order belongs to a trip
    IF NEW.fk_vehicle_trip IS NULL THEN
        RETURN NEW;
    END IF;

    -- Resolve stop sequence from the direct FK (V73)
    SELECT stop_sequence INTO v_stop_sequence
      FROM public.tbl_vehicle_trip_stop
     WHERE pk_stop_id = NEW.fk_vehicle_trip_stop;

    BEGIN
        PERFORM public.fn_create_checkpoint(
            'TRIP_STOP_DELIVERY',
            'tbl_order',
            NEW.pk_order_id,
            NEW.total_cylinders_delivered,   -- declared count, same as empty_pickup pattern
            4,
            'Delivery challan ' || NEW.challan_number
                || ' — trip ' || NEW.fk_vehicle_trip
                || ' stop ' || COALESCE(v_stop_sequence::text, '?')
                || ' (' || NEW.total_cylinders_delivered || ' cylinders declared)',
            CURRENT_DATE,
            NEW.fk_vehicle_trip,
            NEW.fk_vehicle_load,
            v_stop_sequence
        );
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'fn_order_delivery_checkpoint [create_checkpoint]: %', SQLERRM;
    END;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_order_delivery_checkpoint
AFTER INSERT ON public.tbl_order
FOR EACH ROW EXECUTE FUNCTION public.fn_order_delivery_checkpoint();

COMMENT ON FUNCTION public.fn_order_delivery_checkpoint() IS
    'Fires AFTER INSERT on tbl_order. Creates a PENDING TRIP_STOP_DELIVERY '
    'reconciliation checkpoint with expected_count = total_cylinders_delivered. '
    'Mirrors fn_empty_pickup_checkpoint. The checkpoint is resolved at trip Halt '
    'by fn_trip_status_after_update with actual_count = COUNT(tbl_order_line).';


-- =============================================================================
-- PART 4 — BEFORE INSERT on tbl_order_line: enforce line count ceiling
-- =============================================================================
-- Mirrors the semantic validation on tbl_vehicle_load_line (must be FULL)
-- and tbl_supplier_refill_collection_line (must be EMPTY_DELIVERED).
-- Prevents the office from entering more cylinder lines than the declared
-- total_cylinders_delivered on the challan header.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_check_order_line_count()
RETURNS TRIGGER AS $$
DECLARE
    v_declared   int4;
    v_current    int4;
BEGIN
    SELECT total_cylinders_delivered INTO v_declared
      FROM public.tbl_order
     WHERE pk_order_id = NEW.fk_order;

    -- If header was not declared (legacy rows with 0), skip the check
    IF v_declared = 0 THEN
        RETURN NEW;
    END IF;

    SELECT COUNT(*) INTO v_current
      FROM public.tbl_order_line
     WHERE fk_order = NEW.fk_order;

    -- current is BEFORE this insert, so current + 1 = new total
    IF (v_current + 1) > v_declared THEN
        RAISE EXCEPTION
            'Validation Failed: Challan % declares % cylinders but % lines already exist. '
            'Update total_cylinders_delivered on the order header before adding more lines.',
            NEW.fk_order, v_declared, v_current;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Insert as trg_00 so it fires before the existing FULL_PICKED_UP validation
-- (trg_01_check_picked_up_before_order) and the delivery audit (trg_02_*)
CREATE TRIGGER trg_00_check_order_line_count
BEFORE INSERT ON public.tbl_order_line
FOR EACH ROW EXECUTE FUNCTION public.fn_check_order_line_count();

COMMENT ON FUNCTION public.fn_check_order_line_count() IS
    'Guards tbl_order_line INSERT. Prevents more cylinder lines being entered '
    'than the declared total_cylinders_delivered on the challan header. '
    'Fires as trg_00 — before the FULL_PICKED_UP validation (trg_01) and '
    'the delivery audit trigger (trg_02). '
    'Skips validation for legacy rows where total_cylinders_delivered = 0.';


-- =============================================================================
-- PART 5 — Update fn_audit_cylinder_delivery_after: keep expected_count in sync
-- =============================================================================
-- The checkpoint is now created at tbl_order INSERT with total_cylinders_delivered
-- as expected_count. The order_line trigger's only job for the checkpoint is to
-- track the running actual line count via expected_count update — so the office
-- can see progress in real time on the dashboard before the trip halts.
--
-- NOTE: expected_count on the checkpoint always stays = total_cylinders_delivered
-- (the header declaration). The running actual line count is visible via remarks.
-- The true actual_count is set only at Halt resolution by fn_trip_status_after_update.
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

    -- ── Existing: current status (V56) ──────────────────────────────────────
    UPDATE public.tbl_cylinder_current_status
       SET fk_current_state            = v_delivered_state_id,
           fk_current_customer         = v_customer_id,
           fk_current_customer_address = v_delivery_address_id,
           fk_current_vehicle_trip     = NULL,
           fk_current_vehicle_load     = NULL,
           updated_at                  = now()
     WHERE fk_cylinder = NEW.fk_cylinder;

    -- ── NEW: update remarks with running line count for dashboard visibility ─
    -- expected_count stays = total_cylinders_delivered (the declaration).
    -- We show progress in remarks: "Entered: 3 / Declared: 5"
    SELECT COUNT(*) INTO v_line_count
      FROM public.tbl_order_line
     WHERE fk_order = NEW.fk_order;

    UPDATE public.tbl_reconciliation_checkpoint
       SET remarks = 'Challan ' || NEW.fk_order
                  || ' — Entered: ' || v_line_count
                  || ' / Declared: '
                  || (SELECT total_cylinders_delivered
                        FROM public.tbl_order
                       WHERE pk_order_id = NEW.fk_order)
     WHERE reference_entity_type = 'tbl_order'
       AND reference_entity_id   = NEW.fk_order
       AND checkpoint_type       = 'TRIP_STOP_DELIVERY'
       AND checkpoint_status     = 'PENDING';

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;