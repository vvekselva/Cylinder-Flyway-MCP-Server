-- =============================================================================
-- Issue-02 Fix — fn_sync_cylinder_current_status
-- =============================================================================
-- Root Cause:
--   fn_audit_cylinder_load_after() fires AFTER INSERT on tbl_vehicle_load_line.
--   It calls fn_sync_cylinder_current_status() which does an UPSERT on
--   tbl_cylinder_current_status.  At the moment that UPSERT executes, the row
--   lands in state EMPTY_PICKED_FOR_REFILL — but fk_current_vehicle_load is NULL
--   because the trigger never set it.
--
--   fn_cylinder_fk_consistency() (a BEFORE trigger on tbl_cylinder_current_status)
--   then raises:
--       "fk_current_vehicle_load must be SET"
--   before the Java layer ever gets a chance to back-fill the value.
--
-- Fix:
--   The trigger fn_sync_cylinder_current_status() must read fk_vehicle_load
--   and the vehicle trip directly from the load-line row (NEW) and include them
--   in the UPSERT.  The Java layer must stop attempting to set them afterward.
--
--   NEW columns used:
--     NEW.fk_vehicle_load  — already present on tbl_vehicle_load_line
--     v_vehicle_trip_id    — resolved via tbl_vehicle_load → tbl_vehicle_trip
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_sync_cylinder_current_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_customer_id     BIGINT;
    v_vehicle_trip_id BIGINT;
    v_state_name      TEXT;
BEGIN
    -- ── 1. Resolve state name for conditional logic ────────────────────────
    SELECT cylinder_state
      INTO v_state_name
      FROM public.tbl_cylinder_states
     WHERE pk_cylinder_state_id = NEW.fk_new_state;

    -- ── 2. Resolve customer context (from the load → trip → last delivery) ─
    --    Keep whatever logic you had here; shown as a placeholder.
    --    If the cylinder is going FULL_FOR_DELIVERY we can read the customer
    --    from the order on the load line; otherwise NULL/preserve.
    SELECT fk_customer
      INTO v_customer_id
      FROM public.tbl_order
     WHERE pk_order_id = NEW.fk_order
     LIMIT 1;

    -- ── 3. Resolve vehicle trip from the vehicle load ──────────────────────
    --    tbl_vehicle_load has a fk_vehicle_trip column.
    SELECT fk_vehicle_trip
      INTO v_vehicle_trip_id
      FROM public.tbl_vehicle_load
     WHERE pk_vehicle_load_id = NEW.fk_vehicle_load;

    -- ── 4. UPSERT tbl_cylinder_current_status — now includes vehicle FKs ──
    INSERT INTO public.tbl_cylinder_current_status (
        fk_cylinder,
        fk_current_state,
        fk_current_holder_customer,
        fk_current_supplier,        -- cleared here; supplier-dropoff trigger owns it
        fk_last_order,
        fk_current_vehicle_load,    -- ← NEW: populated from load-line context
        fk_current_vehicle_trip,    -- ← NEW: resolved via vehicle load
        updated_at
    )
    VALUES (
        NEW.fk_cylinder,
        NEW.fk_new_state,
        v_customer_id,
        NULL,                       -- supplier cleared; specific trigger overwrites if needed
        NEW.fk_order,
        NEW.fk_vehicle_load,        -- ← the load that caused this state transition
        v_vehicle_trip_id,          -- ← resolved above
        now()
    )
    ON CONFLICT (fk_cylinder) DO UPDATE
        SET fk_current_state           = EXCLUDED.fk_current_state,
            fk_current_holder_customer = EXCLUDED.fk_current_holder_customer,
            fk_current_supplier        = CASE
                WHEN (
                    SELECT cylinder_state
                      FROM public.tbl_cylinder_states
                     WHERE pk_cylinder_state_id = EXCLUDED.fk_current_state
                ) = 'EMPTY_DELIVERED_FOR_REFILL'
                THEN public.tbl_cylinder_current_status.fk_current_supplier  -- preserve; specific trigger will set
                ELSE NULL
            END,
            fk_last_order              = EXCLUDED.fk_last_order,
            fk_current_vehicle_load    = EXCLUDED.fk_current_vehicle_load,   -- ← NEW
            fk_current_vehicle_trip    = EXCLUDED.fk_current_vehicle_trip,   -- ← NEW
            updated_at                 = EXCLUDED.updated_at;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.fn_sync_cylinder_current_status() IS
    'Syncs tbl_cylinder_current_status on every load-line insert/update.
     Populates fk_current_vehicle_load and fk_current_vehicle_trip directly
     from the load-line row so fn_cylinder_fk_consistency() passes on the
     same statement.  The Java service layer must NOT attempt to back-fill
     these columns after the fact.';