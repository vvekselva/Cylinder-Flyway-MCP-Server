-- =============================================================================
-- V66__Fix_Delivery_And_EmptyPickup_Triggers.sql
-- =============================================================================
--
-- FIXES THREE PROBLEMS IN THE DELIVERY → EMPTY PICKUP CYCLE:
--
-- ─────────────────────────────────────────────────────────────────────────────
-- PROBLEM 1 — fn_audit_cylinder_delivery_after (V21, updated V56) — RUNTIME BUG
-- ─────────────────────────────────────────────────────────────────────────────
-- V56 Part 6 rewrote this function and added a direct UPDATE to
-- tbl_cylinder_current_status. However it references a column that does not
-- exist: `fk_current_customer`. The actual column (defined in V41) is
-- `fk_current_holder_customer`.
--
-- PostgreSQL validates PL/pgSQL column references at RUNTIME, not at
-- CREATE FUNCTION time, so V56 applied silently. Every tbl_order_line INSERT
-- then fails at runtime with:
--   ERROR: column "fk_current_customer" of relation "tbl_cylinder_current_status"
--          does not exist
--
-- Fix: rename both usages to fk_current_holder_customer.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- PROBLEM 2 — fn_check_cylinder_is_picked_up (V21 BEFORE trigger) — STALE READ
-- ─────────────────────────────────────────────────────────────────────────────
-- This BEFORE trigger on tbl_order_line validates that the cylinder is in
-- FULL_PICKED_UP_FOR_DELIVERY before allowing delivery. It reads exclusively
-- from tbl_cylinder_state_audit (ORDER BY changed_at DESC LIMIT 1).
--
-- Since V41, tbl_cylinder_current_status is the authoritative fast lookup for
-- the current state. Using the audit log alone:
--   a) is slower (full index scan per cylinder vs single-row PK lookup)
--   b) can return a stale result if the audit is behind (edge case)
--
-- Fix: use tbl_cylinder_current_status as the primary source with audit
-- fallback — consistent with all post-V41 trigger functions.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- PROBLEM 3 — tbl_empty_pickup_line — NO BEFORE validation trigger (MISSING)
-- ─────────────────────────────────────────────────────────────────────────────
-- Every other line-level table that drives a state transition has a BEFORE
-- INSERT trigger that validates the cylinder is in the required state before
-- the insert is allowed:
--   tbl_vehicle_load_line              → fn_check_cylinder_before_vehicle_load  (V42)
--   tbl_supplier_trip_line             → fn_audit_supplier_trip_line_insert      (V65)
--   tbl_supplier_refill_collection_line → fn_check_cylinder_before_refill_collection (V56)
--   tbl_yard_entries                   → fn_check_cylinder_before_yard_entry     (V65)
--
-- tbl_empty_pickup_line has NO BEFORE trigger. Any cylinder — regardless of
-- state — can be added to an empty pickup, silently corrupting the audit trail.
--
-- Fix: add BEFORE INSERT trigger validating cylinder is DELIVERED_FOR_CONSUMPTION.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- PROBLEM 4 — fn_audit_empty_pickup_line_after (V44, updated V56) — RUNTIME BUG
-- ─────────────────────────────────────────────────────────────────────────────
-- Same column name bug as Problem 1. V56 Part 7a updated this function and
-- also references `fk_current_customer` instead of `fk_current_holder_customer`.
-- Every tbl_empty_pickup_line INSERT fails at runtime.
--
-- Fix: rename to fk_current_holder_customer.
-- =============================================================================


-- =============================================================================
-- FIX 1 — fn_check_cylinder_is_picked_up (BEFORE INSERT on tbl_order_line)
--          Use tbl_cylinder_current_status with audit fallback (post-V41 style)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_check_cylinder_is_picked_up()
RETURNS TRIGGER AS $$
DECLARE
    v_picked_up_state_id int8;
    v_current_state_id   int8;
    v_current_state_name varchar(100);
BEGIN
    SELECT pk_cylinder_state_id INTO v_picked_up_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'FULL_PICKED_UP_FOR_DELIVERY';

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

    IF v_current_state_id IS DISTINCT FROM v_picked_up_state_id THEN
        RAISE EXCEPTION
            'Validation Failed: Cylinder % must be in FULL_PICKED_UP_FOR_DELIVERY state '
            'before it can be added to an order line. '
            'Ensure the cylinder was loaded onto a delivery vehicle first (tbl_vehicle_load_line). '
            'Current state: [%].',
            NEW.fk_cylinder,
            COALESCE(v_current_state_name, 'UNKNOWN — no state record found');
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger already exists from V21 — CREATE OR REPLACE replaces the function body.
-- The trigger binding (trg_01_check_picked_up_before_order) is unchanged.

COMMENT ON FUNCTION public.fn_check_cylinder_is_picked_up() IS
    'Fires BEFORE INSERT on tbl_order_line. '
    'Validates: cylinder must be in FULL_PICKED_UP_FOR_DELIVERY state. '
    'V66 update: now reads from tbl_cylinder_current_status (fast, authoritative) '
    'with audit log fallback — consistent with all post-V41 trigger functions. '
    'V21 original read only from the audit log.';


-- =============================================================================
-- FIX 2 — fn_audit_cylinder_delivery_after (AFTER INSERT on tbl_order_line)
--          Fix column name: fk_current_customer → fk_current_holder_customer
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_audit_cylinder_delivery_after()
RETURNS TRIGGER AS $$
DECLARE
    v_picked_up_state_id     int8;
    v_delivered_state_id     int8;
    v_customer_id            int8;
    v_delivery_address_id    int8;
BEGIN
    SELECT pk_cylinder_state_id INTO v_picked_up_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'FULL_PICKED_UP_FOR_DELIVERY';

    SELECT pk_cylinder_state_id INTO v_delivered_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'DELIVERED_FOR_CONSUMPTION';

    -- Resolve customer and delivery address.
    -- Line-level fk_delivery_address (added in V56) takes priority over the
    -- challan header address (multi-location delivery support).
    SELECT
        o.fk_customer,
        COALESCE(NEW.fk_delivery_address, o.fk_delivery_address)
    INTO v_customer_id, v_delivery_address_id
    FROM public.tbl_order o
    WHERE o.pk_order_id = NEW.fk_order;

    -- 1. Write audit row: FULL_PICKED_UP_FOR_DELIVERY → DELIVERED_FOR_CONSUMPTION
    INSERT INTO public.tbl_cylinder_state_audit (
        pk_audit_id,
        fk_cylinder,
        fk_previous_state,
        fk_new_state,
        fk_order,
        changed_at,
        remarks
    ) VALUES (
        nextval('public.pk_cylinder_state_id_serial'),
        NEW.fk_cylinder,
        v_picked_up_state_id,
        v_delivered_state_id,
        NEW.fk_order,
        now(),
        'Cylinder delivered to customer. State updated by order line trigger.'
    );

    -- 2. Update current status directly.
    --    fk_current_holder_customer is the correct column name (V41).
    --    V56 Part 6 incorrectly used fk_current_customer — fixed here.
    UPDATE public.tbl_cylinder_current_status
    SET fk_current_state            = v_delivered_state_id,
        fk_current_holder_customer  = v_customer_id,          -- ← correct column name (was fk_current_customer in V56)
        fk_current_customer_address = v_delivery_address_id,
        fk_current_vehicle_trip     = NULL,
        fk_current_vehicle_load     = NULL,
        updated_at                  = now()
    WHERE fk_cylinder = NEW.fk_cylinder;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger binding already exists from V21 (trg_02_audit_delivery_after_order).
-- CREATE OR REPLACE updates the function body in place.

COMMENT ON FUNCTION public.fn_audit_cylinder_delivery_after() IS
    'Fires AFTER INSERT on tbl_order_line. '
    'Transitions cylinder: FULL_PICKED_UP_FOR_DELIVERY → DELIVERED_FOR_CONSUMPTION. '
    'Sets fk_current_holder_customer and fk_current_customer_address on current status. '
    'V66 fix: V56 Part 6 used non-existent column fk_current_customer — '
    'renamed to fk_current_holder_customer (the actual column from V41). '
    'Supports per-line delivery address (fk_delivery_address on tbl_order_line, V56 Part 7).';


-- =============================================================================
-- FIX 3 — Add BEFORE INSERT trigger on tbl_empty_pickup_line (MISSING)
--          Validate cylinder is in DELIVERED_FOR_CONSUMPTION before pickup
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_check_cylinder_before_empty_pickup()
RETURNS TRIGGER AS $$
DECLARE
    v_required_state_id  int8;
    v_current_state_id   int8;
    v_current_state_name varchar(100);
BEGIN
    SELECT pk_cylinder_state_id INTO v_required_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'DELIVERED_FOR_CONSUMPTION';

    -- Fast path: tbl_cylinder_current_status
    SELECT ccs.fk_current_state, cs.cylinder_state
    INTO v_current_state_id, v_current_state_name
    FROM public.tbl_cylinder_current_status ccs
    JOIN public.tbl_cylinder_states cs
        ON cs.pk_cylinder_state_id = ccs.fk_current_state
    WHERE ccs.fk_cylinder = NEW.fk_cylinder;

    -- Fallback: audit log
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

    IF v_current_state_id IS DISTINCT FROM v_required_state_id THEN
        RAISE EXCEPTION
            'Validation Failed: Cylinder % must be in DELIVERED_FOR_CONSUMPTION state '
            'before it can be collected as an empty pickup. '
            'Only cylinders actively at a customer location can be picked up. '
            'Current state: [%]. Empty pickup: %.',
            NEW.fk_cylinder,
            COALESCE(v_current_state_name, 'UNKNOWN — no state record found'),
            NEW.fk_empty_pickup;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_01_check_cylinder_before_empty_pickup
BEFORE INSERT ON public.tbl_empty_pickup_line
FOR EACH ROW
EXECUTE FUNCTION public.fn_check_cylinder_before_empty_pickup();

COMMENT ON FUNCTION public.fn_check_cylinder_before_empty_pickup() IS
    'Fires BEFORE INSERT on tbl_empty_pickup_line. '
    'Validates: cylinder must be in DELIVERED_FOR_CONSUMPTION state. '
    'Prevents cylinders in transit, at yard, or at supplier from being '
    'incorrectly logged as customer empty pickups. '
    'Added in V66 — this validation was missing entirely from V38/V44.';


-- =============================================================================
-- FIX 4 — fn_audit_empty_pickup_line_after (AFTER INSERT on tbl_empty_pickup_line)
--          Fix column name: fk_current_customer → fk_current_holder_customer
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_audit_empty_pickup_line_after()
RETURNS TRIGGER AS $$
DECLARE
    v_delivered_state_id        int8;
    v_empty_in_transit_state_id int8;
BEGIN
    SELECT pk_cylinder_state_id INTO v_delivered_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'DELIVERED_FOR_CONSUMPTION';

    SELECT pk_cylinder_state_id INTO v_empty_in_transit_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'EMPTY_IN_TRANSIT_TO_YARD';

    -- 1. Write audit row: DELIVERED_FOR_CONSUMPTION → EMPTY_IN_TRANSIT_TO_YARD
    INSERT INTO public.tbl_cylinder_state_audit (
        pk_audit_id,
        fk_cylinder,
        fk_previous_state,
        fk_new_state,
        fk_order,
        changed_at,
        remarks
    ) VALUES (
        nextval('public.pk_cylinder_state_id_serial'),
        NEW.fk_cylinder,
        v_delivered_state_id,
        v_empty_in_transit_state_id,
        (SELECT fk_order FROM public.tbl_empty_pickup WHERE pk_pickup_id = NEW.fk_empty_pickup),
        now(),
        'Empty cylinder picked up from customer. In transit to yard. '
            || 'Condition: ' || NEW.cylinder_condition || '.'
            || CASE WHEN NEW.damage_description IS NOT NULL
                    THEN ' Damage noted: ' || NEW.damage_description
                    ELSE '' END
    );

    -- 2. Update current status.
    --    fk_current_holder_customer is the correct column name (V41).
    --    V56 Part 7a incorrectly used fk_current_customer — fixed here.
    UPDATE public.tbl_cylinder_current_status
    SET fk_current_state            = v_empty_in_transit_state_id,
        fk_current_holder_customer  = NULL,    -- ← correct column name (was fk_current_customer in V56)
        fk_current_customer_address = NULL,    -- cleared: no longer at customer address
        updated_at                  = now()
    WHERE fk_cylinder = NEW.fk_cylinder;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger binding already exists from V44 (trg_01_audit_empty_pickup_line_after).
-- CREATE OR REPLACE updates the function body in place.

COMMENT ON FUNCTION public.fn_audit_empty_pickup_line_after() IS
    'Fires AFTER INSERT on tbl_empty_pickup_line. '
    'Transitions cylinder: DELIVERED_FOR_CONSUMPTION → EMPTY_IN_TRANSIT_TO_YARD. '
    'Clears fk_current_holder_customer and fk_current_customer_address on current status. '
    'V66 fix: V56 Part 7a used non-existent column fk_current_customer — '
    'renamed to fk_current_holder_customer (the actual column from V41). '
    'Also enriches the audit remarks with cylinder_condition and damage_description.';


-- =============================================================================
-- SUMMARY — Customer Delivery Cycle trigger chain (complete, post-V66)
-- =============================================================================
--
--  EVENT                            TABLE                         FROM STATE                      → TO STATE
--  ───────────────────────────────  ────────────────────────────  ──────────────────────────────  ────────────────────────────
--  Loaded on delivery vehicle       tbl_vehicle_load_line         FULL                            → FULL_PICKED_UP_FOR_DELIVERY
--  (purpose: FULL_FOR_DELIVERY)     (BEFORE: validates FULL)                                        (V42)
--                                   (AFTER:  writes audit + patches vehicle load)
--
--  Delivered to customer            tbl_order_line                FULL_PICKED_UP_FOR_DELIVERY     → DELIVERED_FOR_CONSUMPTION
--  (delivery challan line)          (BEFORE: fn_check_cylinder_is_picked_up — V66 fix)              (V21, V56, V66 fix)
--                                   (AFTER:  fn_audit_cylinder_delivery_after — V66 fix)
--                                            Sets fk_current_holder_customer + fk_current_customer_address
--
--  Empty picked up from customer    tbl_empty_pickup_line         DELIVERED_FOR_CONSUMPTION       → EMPTY_IN_TRANSIT_TO_YARD
--  (driver collects empty on route) (BEFORE: fn_check_cylinder_before_empty_pickup — V66 NEW)       (V44, V56, V66 fix)
--                                   (AFTER:  fn_audit_empty_pickup_line_after — V66 fix)
--                                            Clears fk_current_holder_customer + fk_current_customer_address
-- =============================================================================
