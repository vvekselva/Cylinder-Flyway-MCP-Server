-- =============================================================================
-- V68__Fix_SupplierCollection_VehicleLoad.sql
-- =============================================================================
--
-- BUG
-- ───
-- fn_audit_cylinder_refill_collection_after() (originally V56, last revised V63)
-- fires AFTER INSERT on tbl_supplier_refill_collection_line.
-- It correctly sets fk_current_vehicle_trip on tbl_cylinder_current_status
-- for the cylinder that is now in transit back to the yard, but it never sets
-- fk_current_vehicle_load.
--
-- The backend service uses fk_current_vehicle_load as the canonical
-- "cylinder is currently on a vehicle" signal — consistent with every other
-- in-transit state transition in the system (V42 fn_audit_cylinder_load_after,
-- V66 delivery/empty-pickup triggers, etc.). Because fk_current_vehicle_load
-- is left NULL (or stale from a prior load), the service cannot see the cylinder
-- as loaded, so the downstream flow stalls until the column is patched manually.
--
-- ROOT CAUSE
-- ──────────
-- tbl_supplier_refill_collection only records fk_vehicle_trip (the collection
-- trip). The trigger fetches this trip ID but never resolves the corresponding
-- tbl_vehicle_load row. V55 established a strict 1:1 between tbl_vehicle_load
-- and tbl_vehicle_trip (UNIQUE constraint on tbl_vehicle_load.fk_vehicle_trip),
-- so the vehicle load for a given trip is always a single-row lookup.
--
-- FIX
-- ───
-- CREATE OR REPLACE fn_audit_cylinder_refill_collection_after() to:
--   1. Resolve pk_vehicle_load_id from tbl_vehicle_load WHERE
--      fk_vehicle_trip = v_collection_trip_id  (uses the V55 1:1 guarantee).
--   2. Include fk_current_vehicle_load = v_collection_vehicle_load_id in the
--      UPDATE on tbl_cylinder_current_status alongside the existing
--      fk_current_vehicle_trip assignment.
--
-- DATA FIX (BACKFILL)
-- ───────────────────
-- Any cylinder already in FULL_PICKED_FROM_SUPPLIER state whose
-- fk_current_vehicle_load is NULL is corrected by the backfill UPDATE at the
-- bottom of this migration.  This is safe and idempotent: the UNIQUE constraint
-- on tbl_vehicle_load.fk_vehicle_trip guarantees at most one match per trip.
--
-- NO TRIGGER CHANGES — the trigger binding
-- (trg_02_audit_cylinder_refill_collection_after) still points to this function
-- via CREATE OR REPLACE — no DROP/CREATE on the trigger is needed.
-- =============================================================================


-- =============================================================================
-- PART 1  Replace fn_audit_cylinder_refill_collection_after
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_audit_cylinder_refill_collection_after()
RETURNS TRIGGER AS $$
DECLARE
    v_empty_delivered_state_id    int8;
    v_full_picked_state_id        int8;
    v_collection_trip_id          int8;
    v_collection_vehicle_load_id  int8;  -- NEW: the load that owns the trip
BEGIN
    -- ── Resolve state IDs ───────────────────────────────────────────────────
    SELECT pk_cylinder_state_id INTO v_empty_delivered_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL';

    SELECT pk_cylinder_state_id INTO v_full_picked_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'FULL_PICKED_FROM_SUPPLIER';

    -- ── Resolve collection trip and its vehicle load ─────────────────────────
    -- The collection header carries fk_vehicle_trip (the trip that came to
    -- collect the refilled cylinders from the supplier).
    SELECT fk_vehicle_trip
    INTO   v_collection_trip_id
    FROM   public.tbl_supplier_refill_collection
    WHERE  pk_collection_id = NEW.fk_collection;

    -- V55 guarantees a 1:1 between tbl_vehicle_load and tbl_vehicle_trip via
    -- UNIQUE (fk_vehicle_trip) on tbl_vehicle_load.  This lookup is therefore
    -- always zero or one row — never ambiguous.
    --
    -- NULL is tolerated: if the load has not been created yet (edge case during
    -- testing or partial data), fk_current_vehicle_load is set to NULL rather
    -- than raising an exception.  The vehicle trip column is still set so the
    -- backend can fall back to trip-level tracking.
    SELECT pk_vehicle_load_id
    INTO   v_collection_vehicle_load_id
    FROM   public.tbl_vehicle_load
    WHERE  fk_vehicle_trip = v_collection_trip_id;

    -- ── 1. State audit: EMPTY_DELIVERED_FOR_REFILL → FULL_PICKED_FROM_SUPPLIER
    INSERT INTO public.tbl_cylinder_state_audit (
        pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
        fk_order, changed_at, remarks
    ) VALUES (
        nextval('public.pk_cylinder_state_id_serial'),
        NEW.fk_cylinder,
        v_empty_delivered_state_id,
        v_full_picked_state_id,
        NULL,
        COALESCE(NEW.collected_at, now()),
        'Cylinder collected from supplier after refilling. In transit to yard. '
            || 'Collection line ID: ' || NEW.pk_collection_line_id
    );

    -- ── 2. Update current status ─────────────────────────────────────────────
    -- Cylinder is now full, on the collection vehicle, heading back to yard.
    --   fk_current_vehicle_load  ← FIXED: was never set; set to the load that
    --                              owns the collection trip (V55 1:1 guarantee).
    --   fk_current_vehicle_trip  ← set to the collection trip (unchanged).
    --   fk_current_supplier      ← cleared: cylinder is leaving the supplier.
    --   fk_current_holder_customer ← cleared: not at a customer.
    UPDATE public.tbl_cylinder_current_status
    SET fk_current_state           = v_full_picked_state_id,
        fk_current_vehicle_trip    = v_collection_trip_id,
        fk_current_vehicle_load    = v_collection_vehicle_load_id,  -- ← THE FIX
        fk_current_supplier        = NULL,
        fk_current_holder_customer = NULL,
        updated_at                 = now()
    WHERE fk_cylinder = NEW.fk_cylinder;

    -- ── 3. Mark the original supplier trip line as collected ─────────────────
    UPDATE public.tbl_supplier_trip_line
    SET collected    = TRUE,
        collected_at = COALESCE(NEW.collected_at, now())
    WHERE pk_supplier_trip_line_id = NEW.fk_supplier_trip_line;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_audit_cylinder_refill_collection_after() IS
    'Fires AFTER INSERT on tbl_supplier_refill_collection_line. '
    'Transitions cylinder: EMPTY_DELIVERED_FOR_REFILL → FULL_PICKED_FROM_SUPPLIER. '
    'Clears fk_current_supplier (cylinder no longer at supplier). '
    'Sets fk_current_vehicle_trip to the collection trip (in transit to yard). '
    'V68 FIX: also sets fk_current_vehicle_load by resolving the tbl_vehicle_load '
    'row whose fk_vehicle_trip matches the collection trip (V55 1:1 guarantee). '
    'Marks tbl_supplier_trip_line.collected = TRUE.';


-- =============================================================================
-- PART 2  Backfill — fix cylinders already stuck with NULL fk_current_vehicle_load
-- =============================================================================
-- Targets any cylinder that:
--   a) is currently in FULL_PICKED_FROM_SUPPLIER state, AND
--   b) has fk_current_vehicle_load = NULL (the symptom of the bug), AND
--   c) has a fk_current_vehicle_trip that can be resolved to a vehicle load.
--
-- This is safe to run multiple times (idempotent): a cylinder already corrected
-- will simply match no rows on the second run.
--
--UPDATE public.tbl_cylinder_current_status ccs
--SET    fk_current_vehicle_load = vl.pk_vehicle_load_id,
--       updated_at              = now()
--FROM   public.tbl_cylinder_states cs
--JOIN   public.tbl_vehicle_load vl
--          ON vl.fk_vehicle_trip = ccs.fk_current_vehicle_trip
--WHERE  cs.pk_cylinder_state_id = ccs.fk_current_state
--  AND  cs.cylinder_state       = 'FULL_PICKED_FROM_SUPPLIER'
--  AND  ccs.fk_current_vehicle_load IS NULL
--  AND  ccs.fk_current_vehicle_trip  IS NOT NULL;

-- =============================================================================
-- END V68
-- =============================================================================