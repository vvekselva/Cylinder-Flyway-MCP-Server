-- =============================================================================
-- V102__Fix_SyncTrigger_VehicleLoadFK.sql
-- =============================================================================
--
-- ROOT CAUSE (confirmed from logs + migration history)
-- ─────────────────────────────────────────────────────────────────────────────
-- The fix written in V100_StateMachineMigrationFixes.sql was NEVER applied
-- to the database.
--
-- WHY: The file is named  V100_StateMachineMigrationFixes.sql
--                                  ↑ single underscore
--      Flyway requires              V{version}__{description}.sql
--                                              ↑ DOUBLE underscore
--
-- Flyway silently ignores the file and logs:
--   [DEBUG] Filtering out resource: V100_StateMachineMigrationFixes.sql
--   [INFO]  Set 'validateMigrationNaming' to true to see invalid file names.
--
-- The database therefore still runs the fn_sync_cylinder_current_status()
-- defined in V63__SupplierTracking_And_SupplierTripLine_Trigger.sql (Part 3),
-- which does NOT populate fk_current_vehicle_load or fk_current_vehicle_trip.
--
-- TRIGGER CALL CHAIN (what fires on every tbl_vehicle_load_line INSERT):
--
--   INSERT tbl_vehicle_load_line
--     └─► fn_audit_cylinder_load_after()          [AFTER trigger, V42]
--           ├─ inserts tbl_cylinder_state_audit
--           │     └─► fn_sync_cylinder_current_status()  [AFTER trigger, V41/V63]
--           │           └─ UPSERT tbl_cylinder_current_status
--           │                 └─► fn_cylinder_fk_consistency()  [BEFORE trigger, V98]
--           │                       └─ RAISES if fk_current_vehicle_load IS NULL
--           │                          for states that expect_load_fk = TRUE
--           └─ UPDATE tbl_cylinder_current_status  ← this UPDATE runs TOO LATE:
--                SET fk_current_vehicle_load = NEW.fk_vehicle_load
--                ← fn_cylinder_fk_consistency() already fired on the UPSERT above
--
-- WHY THE SERVICE LAYER FIX ALSO FAILED:
--   Same reason — Java code runs after the DB transaction commits or after the
--   flush that triggers the above chain. By the time Java sets the FK, the
--   consistency check has already raised an exception and rolled back the row.
--
-- THE CORRECT FIX:
--   fn_sync_cylinder_current_status() fires ON the audit row INSERT.
--   At that moment NEW refers to tbl_cylinder_state_audit, which does NOT
--   carry fk_vehicle_load. We must look it up from tbl_vehicle_load_line
--   using NEW.fk_cylinder (the cylinder that just changed state).
--
--   Because the audit insert is itself inside fn_audit_cylinder_load_after(),
--   which has NEW.fk_vehicle_load available, we have two clean options:
--
--   OPTION A (chosen here — no schema change):
--     Inside fn_sync_cylinder_current_status(), when the new state is an
--     "In Transit" state (expects_load_fk = TRUE), look up the most recent
--     vehicle load line for this cylinder to obtain the vehicle load FK and
--     resolve the vehicle trip from it. This is safe because the load line
--     row is already committed at AFTER trigger time.
--
--   OPTION B (requires DDL + Flyway migration):
--     Add fk_vehicle_load to tbl_cylinder_state_audit and populate it in
--     fn_audit_cylinder_load_after(). Then fn_sync_cylinder_current_status()
--     can read NEW.fk_vehicle_load directly. Cleaner long-term but requires
--     a schema change.
--
-- This migration implements OPTION A — no schema change, immediately deployable.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_sync_cylinder_current_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_customer_id       BIGINT  := NULL;
    v_vehicle_load_id   BIGINT  := NULL;
    v_vehicle_trip_id   BIGINT  := NULL;
    v_state_name        TEXT;
    v_expects_load_fk   BOOLEAN := FALSE;
    v_expects_trip_fk   BOOLEAN := FALSE;
BEGIN
    -- ── 1. Resolve state metadata ──────────────────────────────────────────
    --    NEW here refers to a row in tbl_cylinder_state_audit.
    SELECT cylinder_state, expects_load_fk, expects_trip_fk
      INTO v_state_name,   v_expects_load_fk, v_expects_trip_fk
      FROM public.tbl_cylinder_states
     WHERE pk_cylinder_state_id = NEW.fk_new_state;

    -- ── 2. Resolve customer context ────────────────────────────────────────
    IF v_state_name IN ('DELIVERED_FOR_CONSUMPTION', 'LOST') THEN
        IF NEW.fk_order IS NOT NULL THEN
            SELECT fk_customer
              INTO v_customer_id
              FROM public.tbl_order
             WHERE pk_order_id = NEW.fk_order;
        END IF;
    END IF;
    -- For all other states v_customer_id stays NULL (cylinder not at customer)

    -- ── 3. Resolve vehicle load + trip when state expects them ─────────────
    --    This is the critical fix.
    --    fn_sync_cylinder_current_status fires AFTER INSERT on tbl_cylinder_state_audit.
    --    The audit row is inserted by fn_audit_cylinder_load_after, which itself
    --    fires AFTER INSERT on tbl_vehicle_load_line.
    --    By the time we run here, the tbl_vehicle_load_line row is committed
    --    and visible in the same transaction — we can safely look it up.
    IF v_expects_load_fk = TRUE THEN
        SELECT vll.fk_vehicle_load
          INTO v_vehicle_load_id
          FROM public.tbl_vehicle_load_line vll
         WHERE vll.fk_cylinder = NEW.fk_cylinder
         ORDER BY vll.pk_vehicle_load_line_id DESC
         LIMIT 1;

        -- Resolve vehicle trip from the load
        IF v_vehicle_load_id IS NOT NULL THEN
            SELECT vl.fk_vehicle_trip
              INTO v_vehicle_trip_id
              FROM public.tbl_vehicle_load vl
             WHERE vl.pk_vehicle_load_id = v_vehicle_load_id;
        END IF;
    END IF;
    -- For non-transit states (expects_load_fk = FALSE), both remain NULL,
    -- which is exactly what fn_cylinder_fk_consistency() requires.

    -- ── 4. UPSERT tbl_cylinder_current_status — fully consistent row ──────
    INSERT INTO public.tbl_cylinder_current_status (
        fk_cylinder,
        fk_current_state,
        fk_current_holder_customer,
        fk_current_supplier,            -- cleared here; supplier triggers own it
        fk_last_order,
        fk_current_vehicle_load,        -- ← correctly populated now
        fk_current_vehicle_trip,        -- ← correctly populated now
        updated_at
    )
    VALUES (
        NEW.fk_cylinder,
        NEW.fk_new_state,
        v_customer_id,
        NULL,                           -- cleared; fn_audit_supplier_dropoff_stop_completed overwrites if needed
        NEW.fk_order,
        v_vehicle_load_id,              -- NULL for non-transit states, SET for transit states
        v_vehicle_trip_id,              -- NULL for non-transit states, SET for transit states
        now()
    )
    ON CONFLICT (fk_cylinder) DO UPDATE
        SET fk_current_state            = EXCLUDED.fk_current_state,
            fk_current_holder_customer  = EXCLUDED.fk_current_holder_customer,
            fk_current_supplier         = CASE
                WHEN (
                    SELECT cylinder_state
                      FROM public.tbl_cylinder_states
                     WHERE pk_cylinder_state_id = EXCLUDED.fk_current_state
                ) = 'EMPTY_DELIVERED_FOR_REFILL'
                THEN public.tbl_cylinder_current_status.fk_current_supplier  -- preserve; specific trigger will set
                ELSE NULL
            END,
            fk_last_order               = EXCLUDED.fk_last_order,
            fk_current_vehicle_load     = EXCLUDED.fk_current_vehicle_load,  -- correctly NULLed/SETted
            fk_current_vehicle_trip     = EXCLUDED.fk_current_vehicle_trip,  -- correctly NULLed/SETted
            updated_at                  = EXCLUDED.updated_at;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.fn_sync_cylinder_current_status() IS
    'V102 fix: resolves fk_current_vehicle_load and fk_current_vehicle_trip by looking up '
    'the most recent tbl_vehicle_load_line row for the cylinder when expects_load_fk = TRUE. '
    'For non-transit states both are set to NULL, satisfying fn_cylinder_fk_consistency(). '
    'Root cause of the bug was V100_StateMachineMigrationFixes.sql being silently ignored '
    'by Flyway due to a single-underscore naming convention (V100_ vs required V100__).';

-- =============================================================================
-- VERIFICATION QUERIES — run after applying to confirm fix
-- =============================================================================
-- SELECT * FROM public.vw_fk_consistency_violations;   -- must return 0 rows
-- SELECT cylinder_state, expects_load_fk, expects_trip_fk
--   FROM public.tbl_cylinder_states ORDER BY cylinder_state;
-- =============================================================================
