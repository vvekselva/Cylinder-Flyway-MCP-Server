-- =============================================================================
-- V88__DirectDelivery_From_SupplierPickup.sql
-- =============================================================================
--
-- CONTEXT — Cylinder Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────
-- The standard delivery path for a refilled cylinder is:
--
--   FULL_PICKED_FROM_SUPPLIER
--       → (tbl_yard_entries)           → FULL
--       → (tbl_vehicle_load_line)      → FULL_PICKED_UP_FOR_DELIVERY
--       → (tbl_order_line)             → DELIVERED_FOR_CONSUMPTION
--
-- In practice, cylinders collected from a supplier on a vehicle that also
-- runs a delivery route can be handed directly to a customer WITHOUT returning
-- to yard first. The vehicle already holds the cylinder in
-- FULL_PICKED_FROM_SUPPLIER state; the driver delivers it on the same trip.
--
-- =============================================================================
-- PROBLEMS FIXED IN THIS MIGRATION
-- =============================================================================
--
-- FIX 1 — fn_check_cylinder_is_picked_up  (BEFORE INSERT on tbl_order_line)
--   Only accepts FULL_PICKED_UP_FOR_DELIVERY. A FULL_PICKED_FROM_SUPPLIER
--   cylinder raises a validation exception even though it is physically on the
--   vehicle and ready to be delivered.
--   → Accept EITHER FULL_PICKED_UP_FOR_DELIVERY or FULL_PICKED_FROM_SUPPLIER.
--
-- FIX 2 — fn_audit_cylinder_delivery_after  (AFTER INSERT on tbl_order_line)
--   Two bugs:
--   a) Uses fk_current_customer (non-existent column — V56 bug, fixed in V66,
--      re-introduced in V81 and V82). Correct column is fk_current_holder_customer
--      (defined in V41).
--   b) Hardcodes FULL_PICKED_UP_FOR_DELIVERY as fk_previous_state in the audit
--      insert, so a direct-delivery cylinder gets a false audit trail.
--   → Resolve the actual previous state from tbl_cylinder_current_status at
--     runtime. Use fk_current_holder_customer. Clear fk_last_supplier_trip
--     on the direct-delivery path (cylinder leaving supplier custody).
--
-- FIX 3 — fn_audit_empty_pickup_line_after  (AFTER INSERT on tbl_empty_pickup_line)
--   Uses fk_current_customer (same V81 regression as FIX 2a).
--   Correct column is fk_current_holder_customer.
--   → Replace with fk_current_holder_customer. All other logic preserved.
--
-- COLUMN NAME HISTORY
-- ─────────────────────────────────────────────────────────────────────────────
--   V41  defines tbl_cylinder_current_status with fk_current_holder_customer
--   V56  introduced fk_current_customer (typo/bug) in trigger bodies
--   V66  fixed V56: renamed to fk_current_holder_customer
--   V81  re-introduced fk_current_customer in fn_audit_cylinder_delivery_after
--        and fn_audit_empty_pickup_line_after (V66 fix was lost)
--   V82  re-introduced fk_current_customer in fn_audit_cylinder_delivery_after
--   V88  fixes all three functions; uses fk_current_holder_customer throughout
--
-- TRIGGER BINDINGS UNCHANGED
-- ─────────────────────────────────────────────────────────────────────────────
--   All three functions use CREATE OR REPLACE. Existing trigger bindings
--   (trg_01_check_picked_up_before_order, trg_02_audit_delivery_after_order,
--    trg_01_audit_empty_pickup_line_after) continue to fire without recreation.
--
-- STATE TRANSITIONS AFTER V88
-- ─────────────────────────────────────────────────────────────────────────────
--  Event               Table              From State                    → To State
--  ─────────────────── ────────────────── ────────────────────────────  ─────────────────────────────
--  Standard delivery   tbl_order_line     FULL_PICKED_UP_FOR_DELIVERY   → DELIVERED_FOR_CONSUMPTION
--  Direct delivery     tbl_order_line     FULL_PICKED_FROM_SUPPLIER     → DELIVERED_FOR_CONSUMPTION
--  Empty pickup        tbl_empty_pickup_line DELIVERED_FOR_CONSUMPTION  → EMPTY_IN_TRANSIT_TO_YARD
-- =============================================================================


-- =============================================================================
-- FIX 1 — fn_check_cylinder_is_picked_up
--          BEFORE INSERT on tbl_order_line
--          Accept: FULL_PICKED_UP_FOR_DELIVERY  OR  FULL_PICKED_FROM_SUPPLIER
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_check_cylinder_is_picked_up()
RETURNS TRIGGER AS $$
DECLARE
    v_delivery_state_id        int8;
    v_direct_delivery_state_id int8;
    v_current_state_id         int8;
    v_current_state_name       varchar(100);
BEGIN
    SELECT pk_cylinder_state_id INTO v_delivery_state_id
      FROM public.tbl_cylinder_states
     WHERE cylinder_state = 'FULL_PICKED_UP_FOR_DELIVERY';

    SELECT pk_cylinder_state_id INTO v_direct_delivery_state_id
      FROM public.tbl_cylinder_states
     WHERE cylinder_state = 'FULL_PICKED_FROM_SUPPLIER';

    -- Fast path: tbl_cylinder_current_status (V41)
    SELECT ccs.fk_current_state, cs.cylinder_state
      INTO v_current_state_id, v_current_state_name
      FROM public.tbl_cylinder_current_status ccs
      JOIN public.tbl_cylinder_states cs
           ON cs.pk_cylinder_state_id = ccs.fk_current_state
     WHERE ccs.fk_cylinder = NEW.fk_cylinder;

    -- Fallback: audit log (for cylinders without a current_status record)
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

    -- Accept FULL_PICKED_UP_FOR_DELIVERY (standard path) or
    -- FULL_PICKED_FROM_SUPPLIER (direct delivery from supplier vehicle, V88)
    IF v_current_state_id IS DISTINCT FROM v_delivery_state_id
   AND v_current_state_id IS DISTINCT FROM v_direct_delivery_state_id THEN
        RAISE EXCEPTION
            'Validation Failed: Cylinder % must be in FULL_PICKED_UP_FOR_DELIVERY '
            '(standard delivery) or FULL_PICKED_FROM_SUPPLIER (direct delivery from '
            'supplier vehicle) before it can be added to an order line. '
            'Current state: [%].',
            NEW.fk_cylinder,
            COALESCE(v_current_state_name, 'UNKNOWN — no state record found');
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_check_cylinder_is_picked_up() IS
    'Fires BEFORE INSERT on tbl_order_line. '
    'Valid source states: '
    '  FULL_PICKED_UP_FOR_DELIVERY  — standard delivery (loaded from yard). '
    '  FULL_PICKED_FROM_SUPPLIER    — direct delivery (V88): cylinder on vehicle '
    '    after supplier collection, delivered without returning to yard first. '
    'Reads from tbl_cylinder_current_status (V41) with audit log fallback. '
    'History: V21 → V66 (current_status lookup) → V88 (dual accepted state).';


-- =============================================================================
-- FIX 2 — fn_audit_cylinder_delivery_after
--          AFTER INSERT on tbl_order_line
--          a) fk_current_customer → fk_current_holder_customer  (column name fix)
--          b) Resolve actual previous state at runtime (not hardcoded)
--          c) Clear fk_last_supplier_trip on direct-delivery path
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_audit_cylinder_delivery_after()
RETURNS TRIGGER AS $$
DECLARE
    v_previous_state_id        int8;
    v_delivered_state_id       int8;
    v_direct_delivery_state_id int8;
    v_customer_id              int8;
    v_delivery_address_id      int8;
    v_line_count               int4;
    v_is_direct_delivery       boolean := false;
BEGIN
    SELECT pk_cylinder_state_id INTO v_delivered_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'DELIVERED_FOR_CONSUMPTION';

    SELECT pk_cylinder_state_id INTO v_direct_delivery_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL_PICKED_FROM_SUPPLIER';

    -- ── Resolve the ACTUAL previous state at runtime ──────────────────────────
    -- The BEFORE trigger already validated the cylinder is in one of the two
    -- accepted states, so this lookup is guaranteed to return a valid row.
    SELECT ccs.fk_current_state
      INTO v_previous_state_id
      FROM public.tbl_cylinder_current_status ccs
     WHERE ccs.fk_cylinder = NEW.fk_cylinder;

    -- Fallback to audit log if no current_status row exists
    IF NOT FOUND THEN
        SELECT fk_new_state INTO v_previous_state_id
          FROM public.tbl_cylinder_state_audit
         WHERE fk_cylinder = NEW.fk_cylinder
         ORDER BY changed_at DESC, pk_audit_id DESC
         LIMIT 1;
    END IF;

    v_is_direct_delivery := (v_previous_state_id = v_direct_delivery_state_id);

    -- ── Resolve customer and delivery address ─────────────────────────────────
    -- Line-level fk_delivery_address (V56) takes priority over header address.
    SELECT o.fk_customer,
           COALESCE(NEW.fk_delivery_address, o.fk_delivery_address)
      INTO v_customer_id, v_delivery_address_id
      FROM public.tbl_order o
     WHERE o.pk_order_id = NEW.fk_order;

    -- ── 1. Write state audit row ──────────────────────────────────────────────
    INSERT INTO public.tbl_cylinder_state_audit (
        pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
        fk_order, changed_at, remarks
    ) VALUES (
        nextval('public.pk_cylinder_state_id_serial'),
        NEW.fk_cylinder,
        v_previous_state_id,        -- actual previous state, not hardcoded
        v_delivered_state_id,
        NEW.fk_order,
        now(),
        CASE
            WHEN v_is_direct_delivery THEN
                'Cylinder delivered to customer via direct delivery from supplier vehicle. '
                || 'State: FULL_PICKED_FROM_SUPPLIER → DELIVERED_FOR_CONSUMPTION. '
                || 'No yard entry created (V88 direct-delivery path).'
            ELSE
                'Cylinder delivered to customer. '
                || 'State: FULL_PICKED_UP_FOR_DELIVERY → DELIVERED_FOR_CONSUMPTION.'
        END
    );

    -- ── 2. Update current status ──────────────────────────────────────────────
    -- fk_current_holder_customer is the correct V41 column name.
    -- V81 and V82 used fk_current_customer (non-existent — V56 bug, V66 fixed,
    -- re-introduced in V81/V82). Fixed here.
    UPDATE public.tbl_cylinder_current_status
       SET fk_current_state            = v_delivered_state_id,
           fk_current_holder_customer  = v_customer_id,
           fk_current_customer_address = v_delivery_address_id,
           fk_current_vehicle_trip     = NULL,
           fk_current_vehicle_load     = NULL,
           -- Direct-delivery path: cylinder is leaving supplier custody,
           -- so fk_last_supplier_trip must also be cleared.
           fk_last_supplier_trip       = CASE
                                             WHEN v_is_direct_delivery THEN NULL
                                             ELSE fk_last_supplier_trip
                                         END,
           updated_at                  = now()
     WHERE fk_cylinder = NEW.fk_cylinder;

    -- ── 3. Update TRIP_STOP_DELIVERY checkpoint remarks (dashboard) ───────────
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

COMMENT ON FUNCTION public.fn_audit_cylinder_delivery_after() IS
    'Fires AFTER INSERT on tbl_order_line. '
    'Transitions cylinder → DELIVERED_FOR_CONSUMPTION from either: '
    '  FULL_PICKED_UP_FOR_DELIVERY (standard path) or '
    '  FULL_PICKED_FROM_SUPPLIER   (direct delivery from supplier vehicle, V88). '
    'Previous state resolved from tbl_cylinder_current_status at runtime — '
    'not hardcoded — so the audit trail is correct for both paths. '
    'Column fix: fk_current_holder_customer (correct V41 name). '
    'V81 and V82 used fk_current_customer (non-existent column — V56 bug '
    'that V66 fixed and V81/V82 re-introduced). '
    'History: V21 → V56 → V66 (fix) → V81 (regression) → V82 (regression) → V88 (fixed).';


-- =============================================================================
-- FIX 3 — fn_audit_empty_pickup_line_after
--          AFTER INSERT on tbl_empty_pickup_line
--          fk_current_customer → fk_current_holder_customer  (column name fix)
--          All other logic (audit row, checkpoint remarks) preserved from V81.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_audit_empty_pickup_line_after()
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

    -- ── 1. Write state audit row ──────────────────────────────────────────────
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

    -- ── 2. Update current status ──────────────────────────────────────────────
    -- fk_current_holder_customer is the correct V41 column name.
    -- V81 used fk_current_customer (non-existent — same regression as FIX 2).
    UPDATE public.tbl_cylinder_current_status
       SET fk_current_state            = v_empty_in_transit_state_id,
           fk_current_holder_customer  = NULL,
           fk_current_customer_address = NULL,
           updated_at                  = now()
     WHERE fk_cylinder = NEW.fk_cylinder;

    -- ── 3. Update TRIP_STOP_EMPTY_PICKUP checkpoint remarks (dashboard) ───────
    SELECT COUNT(*) INTO v_line_count
      FROM public.tbl_empty_pickup_line
     WHERE fk_empty_pickup = NEW.fk_empty_pickup;

    UPDATE public.tbl_reconciliation_checkpoint
       SET remarks = remarks || ' | Scanned: ' || v_line_count
     WHERE reference_entity_type = 'tbl_empty_pickup'
       AND reference_entity_id   = NEW.fk_empty_pickup
       AND checkpoint_type       = 'TRIP_STOP_EMPTY_PICKUP'
       AND checkpoint_status     = 'PENDING';

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_audit_empty_pickup_line_after() IS
    'Fires AFTER INSERT on tbl_empty_pickup_line. '
    'Transitions cylinder: DELIVERED_FOR_CONSUMPTION → EMPTY_IN_TRANSIT_TO_YARD. '
    'Column fix: fk_current_holder_customer (correct V41 name). '
    'V81 used fk_current_customer (non-existent column — same V56/V81 regression '
    'fixed in FIX 2 of this migration). '
    'All other logic preserved from V81 (audit row, checkpoint remarks). '
    'History: V44 → V56 → V66 (fix) → V81 (regression) → V88 (fixed).';
