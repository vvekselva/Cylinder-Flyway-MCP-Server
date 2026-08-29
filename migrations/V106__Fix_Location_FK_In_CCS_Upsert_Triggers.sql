-- =============================================================================
-- V106__Fix_Location_FK_In_CCS_Upsert_Triggers.sql
-- =============================================================================
--
-- ROOT CAUSE
-- ─────────────────────────────────────────────────────────────────────────────
-- V104 added fk_current_location (NOT NULL FK → tbl_cylinder_location) to
-- tbl_cylinder_current_status and rewrote fn_sync_cylinder_current_status to
-- populate it.  However, two AFTER INSERT trigger functions that also write
-- directly to tbl_cylinder_current_status via INSERT … ON CONFLICT DO UPDATE
-- were NOT updated in V104 and still omit fk_current_location entirely.
-- Any INSERT that hits the ON CONFLICT INSERT path (i.e. cylinder not yet in
-- the status table) fails at runtime with:
--
--   ERROR: null value in column "fk_current_location" of relation
--          "tbl_cylinder_current_status" violates not-null constraint
--
-- AFFECTED FUNCTIONS (2)
-- ─────────────────────────────────────────────────────────────────────────────
--  1. fn_audit_supplier_trip_line_insert  (last defined V65)
--       Fires AFTER INSERT on tbl_supplier_trip_line.
--       Transitions: EMPTY_PICKED_FOR_REFILL → EMPTY_DELIVERED_FOR_REFILL.
--       Location that must be set: 'Supplier Location'
--       (cylinder has been physically handed to the supplier).
--
--  2. fn_audit_cylinder_yard_entry_after  (last defined V95, replaces V65/V78)
--       Fires AFTER INSERT on tbl_yard_entries.
--       Handles four yard-entry transitions (all end up at the Yard):
--         FULL_PICKED_FROM_SUPPLIER       → FULL
--         FULL_PICKED_UP_FOR_DELIVERY     → FULL
--         EMPTY_IN_TRANSIT_TO_YARD        → EMPTY
--         EMPTY_PICKED_FOR_REFILL         → EMPTY
--       Location that must be set: 'Yard'
--
-- FIX STRATEGY
-- ─────────────────────────────────────────────────────────────────────────────
-- Each function is replaced in-place (CREATE OR REPLACE).
-- In the INSERT … ON CONFLICT block the fix is surgical — three lines per
-- function:
--   DECLARE  : add  v_location_id  int4
--   INSERT   : add  fk_current_location  column + value
--   DO UPDATE: add  fk_current_location = v_supplier_location_id / v_yard_loc_id
--
-- All other logic is preserved verbatim from V65 / V95.
--
-- DEPENDENCIES
--   V41  tbl_cylinder_current_status
--   V65  fn_audit_supplier_trip_line_insert (full function; used as base here)
--   V95  fn_audit_cylinder_yard_entry_after (full function; used as base here)
--   V104 tbl_cylinder_location + fk_current_location (what introduced the bug)
-- =============================================================================


-- =============================================================================
-- FIX 1 — fn_audit_supplier_trip_line_insert
--          (last defined in V65; omitted from V104 update)
-- =============================================================================
--  Cylinder is physically handed to the supplier → fk_current_location must
--  be set to the 'Supplier Location' row in tbl_cylinder_location.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_audit_supplier_trip_line_insert()
RETURNS TRIGGER AS $$
DECLARE
    v_empty_picked_state_id    int8;
    v_empty_delivered_state_id int8;
    v_current_state_id         int8;
    v_current_state_name       varchar(100);
    v_supplier_id              int8;
    v_supplier_vehicle_trip_id int8;
    v_supplier_location_id     int4;   -- V106: FK to tbl_cylinder_location
BEGIN
    -- ── Resolve state IDs ──────────────────────────────────────────────────
    SELECT pk_cylinder_state_id INTO v_empty_picked_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'EMPTY_PICKED_FOR_REFILL';

    SELECT pk_cylinder_state_id INTO v_empty_delivered_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL';

    -- ── Get current cylinder state ─────────────────────────────────────────
    -- Fast path: tbl_cylinder_current_status
    SELECT ccs.fk_current_state, cs.cylinder_state
    INTO v_current_state_id, v_current_state_name
    FROM public.tbl_cylinder_current_status ccs
    JOIN public.tbl_cylinder_states cs
        ON cs.pk_cylinder_state_id = ccs.fk_current_state
    WHERE ccs.fk_cylinder = NEW.fk_cylinder;

    -- Fallback: latest audit row (for cylinders without a current_status record)
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

    -- ── Validate ───────────────────────────────────────────────────────────
    -- Cylinder MUST be in EMPTY_PICKED_FOR_REFILL at this point.
    -- V42 (vehicle_load_line EMPTY_FOR_SUPPLIER) is responsible for the prior
    -- transition EMPTY → EMPTY_PICKED_FOR_REFILL.
    IF v_current_state_id IS DISTINCT FROM v_empty_picked_state_id THEN
        RAISE EXCEPTION
            'Validation Failed: Cylinder % must be in EMPTY_PICKED_FOR_REFILL state '
            'before it can be added to a supplier trip line. '
            'Ensure the cylinder was loaded onto a vehicle with purpose EMPTY_FOR_SUPPLIER first. '
            'Current state: [%]. Supplier trip: %.',
            NEW.fk_cylinder,
            COALESCE(v_current_state_name, 'UNKNOWN — no state record found'),
            NEW.fk_supplier_trip;
    END IF;

    -- ── Idempotent guard ───────────────────────────────────────────────────
    -- If somehow already in EMPTY_DELIVERED_FOR_REFILL (e.g. manual correction),
    -- skip the audit to avoid a duplicate row.
    IF v_current_state_id = v_empty_delivered_state_id THEN
        RETURN NEW;
    END IF;

    -- ── Resolve supplier and vehicle trip from the supplier trip header ────
    SELECT fk_supplier, fk_vehicle_trip
    INTO v_supplier_id, v_supplier_vehicle_trip_id
    FROM public.tbl_supplier_trip
    WHERE pk_supplier_trip_id = NEW.fk_supplier_trip;

    -- ── V106: Resolve 'Supplier Location' FK ──────────────────────────────
    SELECT pk_location_id INTO v_supplier_location_id
    FROM public.tbl_cylinder_location
    WHERE location_name = 'Supplier Location';

    -- ── 1. Write state audit row ───────────────────────────────────────────
    --    EMPTY_PICKED_FOR_REFILL → EMPTY_DELIVERED_FOR_REFILL
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
        v_empty_picked_state_id,
        v_empty_delivered_state_id,
        NULL,
        now(),
        'Cylinder assigned to supplier trip line — physically delivered to supplier for refill. '
            || 'Supplier trip ID: ' || NEW.fk_supplier_trip
            || CASE WHEN v_supplier_id IS NOT NULL
                    THEN '. Supplier ID: ' || v_supplier_id
                    ELSE '' END
    );

    -- ── 2. Update current status ───────────────────────────────────────────
    --    - State          → EMPTY_DELIVERED_FOR_REFILL
    --    - Location       → Supplier Location           (V106 fix)
    --    - Vehicle trip   → NULL  (cylinder is no longer on the vehicle)
    --    - Supplier       → the supplier now physically holding it
    --    - Last sup. trip → this supplier trip (lineage tracking)
    INSERT INTO public.tbl_cylinder_current_status (
        fk_cylinder,
        fk_current_state,
        fk_current_location,           -- V106: added; was missing, caused NOT NULL violation
        fk_current_vehicle_trip,
        fk_current_holder_customer,
        fk_current_supplier,
        fk_last_supplier_trip,
        updated_at
    ) VALUES (
        NEW.fk_cylinder,
        v_empty_delivered_state_id,
        v_supplier_location_id,        -- V106: 'Supplier Location' FK
        NULL,                          -- no longer on vehicle
        NULL,                          -- not at customer
        v_supplier_id,                 -- now physically at supplier
        NEW.fk_supplier_trip,
        now()
    )
    ON CONFLICT (fk_cylinder) DO UPDATE
        SET fk_current_state            = v_empty_delivered_state_id,
            fk_current_location         = v_supplier_location_id,  -- V106: added
            fk_current_vehicle_trip     = NULL,
            fk_current_holder_customer  = NULL,
            fk_current_supplier         = v_supplier_id,
            fk_last_supplier_trip       = NEW.fk_supplier_trip,
            fk_current_vehicle_load     = NULL,
            updated_at                  = now();

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_audit_supplier_trip_line_insert() IS
    'Fires AFTER INSERT on tbl_supplier_trip_line. '
    'Transitions the cylinder: EMPTY_PICKED_FOR_REFILL → EMPTY_DELIVERED_FOR_REFILL. '
    'Validates that V42 (vehicle_load_line EMPTY_FOR_SUPPLIER trigger) has already run. '
    'Sets fk_current_supplier on tbl_cylinder_current_status. '
    'Clears fk_current_vehicle_trip (cylinder is now physically at the supplier). '
    'Fixed in V65: V63 incorrectly targeted EMPTY → EMPTY_PICKED_FOR_REFILL. '
    'Fixed in V106: V104 added fk_current_location (NOT NULL) to '
    'tbl_cylinder_current_status but this function was not updated. '
    'Now resolves and sets fk_current_location = Supplier Location.';


-- =============================================================================
-- FIX 2 — fn_audit_cylinder_yard_entry_after
--          (last defined in V95, replaces V65/V78; omitted from V104 update)
-- =============================================================================
--  Cylinder arrives at the yard from any in-transit state → fk_current_location
--  must be set to the 'Yard' row in tbl_cylinder_location.
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
    v_yard_location_id   int4;   -- V106: FK to tbl_cylinder_location
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

    -- ── V106: Resolve 'Yard' location FK ─────────────────────────────────
    SELECT pk_location_id INTO v_yard_location_id
      FROM public.tbl_cylinder_location
     WHERE location_name = 'Yard';

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
        fk_current_location,           -- V106: added; was missing, caused NOT NULL violation
        fk_current_holder_customer,
        fk_current_vehicle_load,
        fk_last_supplier_trip,
        fk_last_order,
        updated_at
    )
    VALUES (
        NEW.fk_cylinder,
        v_new_state_id,
        v_yard_location_id,            -- V106: 'Yard' FK
        NULL,
        NULL,                          -- no longer on any vehicle
        NULL,                          -- no supplier trip completed (aborted path)
        NULL,
        now()
    )
    ON CONFLICT (fk_cylinder) DO UPDATE
        SET fk_current_state           = EXCLUDED.fk_current_state,
            fk_current_location        = v_yard_location_id,    -- V106: added
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
    'V95 corrects in-place. '
    'Fixed in V106: V104 added fk_current_location (NOT NULL) to '
    'tbl_cylinder_current_status but this function was not updated. '
    'Now resolves and sets fk_current_location = Yard.';


-- =============================================================================
-- VERIFICATION
-- =============================================================================

DO $$
DECLARE
    v_supplier_fn_ok  boolean;
    v_yard_fn_ok      boolean;
BEGIN
    -- Confirm fn_audit_supplier_trip_line_insert body references fk_current_location
    SELECT prosrc ILIKE '%fk_current_location%'
      INTO v_supplier_fn_ok
      FROM pg_proc
     WHERE proname = 'fn_audit_supplier_trip_line_insert';

    -- Confirm fn_audit_cylinder_yard_entry_after body references fk_current_location
    SELECT prosrc ILIKE '%fk_current_location%'
      INTO v_yard_fn_ok
      FROM pg_proc
     WHERE proname = 'fn_audit_cylinder_yard_entry_after';

    IF NOT COALESCE(v_supplier_fn_ok, false) THEN
        RAISE WARNING 'V106 VERIFY: fn_audit_supplier_trip_line_insert does NOT contain fk_current_location — check migration applied correctly.';
    ELSE
        RAISE NOTICE 'V106 OK: fn_audit_supplier_trip_line_insert now sets fk_current_location.';
    END IF;

    IF NOT COALESCE(v_yard_fn_ok, false) THEN
        RAISE WARNING 'V106 VERIFY: fn_audit_cylinder_yard_entry_after does NOT contain fk_current_location — check migration applied correctly.';
    ELSE
        RAISE NOTICE 'V106 OK: fn_audit_cylinder_yard_entry_after now sets fk_current_location.';
    END IF;
END;
$$;
