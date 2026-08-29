-- =============================================================================
-- V78__YardEntry_EmptyPickedForRefill_Return.sql
-- =============================================================================
--
-- REQUIREMENT
-- ───────────────────────────────────────────────────────────────────────────
-- Some empty cylinders loaded onto a vehicle with purpose EMPTY_FOR_SUPPLIER
-- (state: EMPTY_PICKED_FOR_REFILL) may be brought BACK to the yard WITHOUT
-- ever being dropped off to a supplier. This happens when:
--   • The supplier is unavailable on that day.
--   • The vehicle ran out of time and returned without completing the dropoff.
--   • A scheduling change cancelled the supplier run mid-trip.
--
-- PROBLEM (before this fix)
-- ───────────────────────────────────────────────────────────────────────────
-- tbl_yard_entries (V65) was designed to receive cylinders that had been
-- refilled by a supplier and were being returned to yard:
--
--   FULL_PICKED_FROM_SUPPLIER → FULL
--
-- The BEFORE INSERT trigger (fn_validate_yard_entry_state) enforces that the
-- cylinder must be in one of these three states when a yard entry is created:
--
--   FULL_PICKED_UP_FOR_DELIVERY   (a vehicle returned a full cylinder)
--   EMPTY_IN_TRANSIT_TO_YARD      (empty pickup collected from customer)
--   FULL_PICKED_FROM_SUPPLIER     (refilled cylinder arriving from supplier)
--
-- EMPTY_PICKED_FOR_REFILL is NOT in this list, so a driver attempting to
-- return an un-dropped-off empty cylinder to the yard gets a validation
-- exception.
--
-- FIX
-- ───────────────────────────────────────────────────────────────────────────
-- Add EMPTY_PICKED_FOR_REFILL to the allowed states in the validation trigger.
-- When a cylinder in this state is entered into tbl_yard_entries:
--
--   EMPTY_PICKED_FOR_REFILL → EMPTY   (returned to yard without supplier visit)
--
-- The AFTER INSERT audit trigger is updated to handle this new transition.
-- The tbl_cylinder_current_status row is updated to reflect the cylinder is
-- back in the yard (vehicle load FK cleared, state = EMPTY).
--
-- DEPENDENCY ON V65 (tbl_yard_entries)
-- ───────────────────────────────────────────────────────────────────────────
-- This migration replaces two trigger functions originally created in V65:
--   fn_validate_yard_entry_state   (BEFORE INSERT on tbl_yard_entries)
--   fn_audit_yard_entry_after      (AFTER  INSERT on tbl_yard_entries)
-- Both are replaced with CREATE OR REPLACE — the trigger bindings remain.
-- =============================================================================


-- =============================================================================
-- PART 1 — Replace BEFORE INSERT validation trigger
--           Add EMPTY_PICKED_FOR_REFILL as an accepted entry state.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_validate_yard_entry_state()
RETURNS TRIGGER AS $$
DECLARE
    v_current_state_id   int8;
    v_current_state_name varchar(100);

    -- Accepted states for a yard entry
    v_full_picked_from_supplier_id    int8;
    v_full_picked_up_for_delivery_id  int8;
    v_empty_in_transit_id             int8;
    v_empty_picked_for_refill_id      int8;   -- NEW
BEGIN
    -- ── Resolve all accepted source-state IDs ─────────────────────────────
    SELECT pk_cylinder_state_id INTO v_full_picked_from_supplier_id
    FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL_PICKED_FROM_SUPPLIER';

    SELECT pk_cylinder_state_id INTO v_full_picked_up_for_delivery_id
    FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL_PICKED_UP_FOR_DELIVERY';

    SELECT pk_cylinder_state_id INTO v_empty_in_transit_id
    FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_IN_TRANSIT_TO_YARD';

    -- NEW: empty cylinder returning to yard without supplier dropoff
    SELECT pk_cylinder_state_id INTO v_empty_picked_for_refill_id
    FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_PICKED_FOR_REFILL';

    -- ── Resolve the cylinder's current state ─────────────────────────────
    SELECT ccs.fk_current_state, cs.cylinder_state
    INTO v_current_state_id, v_current_state_name
    FROM public.tbl_cylinder_current_status ccs
    JOIN public.tbl_cylinder_states cs
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

    -- ── Validate: cylinder must be in one of the four accepted states ─────
    IF v_current_state_id NOT IN (
        v_full_picked_from_supplier_id,
        v_full_picked_up_for_delivery_id,
        v_empty_in_transit_id,
        v_empty_picked_for_refill_id      -- NEW
    ) THEN
        RAISE EXCEPTION
            'Yard Entry Validation Failed: Cylinder % cannot be entered into the yard '
            'from state [%]. '
            'Accepted states: '
            'FULL_PICKED_FROM_SUPPLIER, '
            'FULL_PICKED_UP_FOR_DELIVERY, '
            'EMPTY_IN_TRANSIT_TO_YARD, '
            'EMPTY_PICKED_FOR_REFILL (returned without supplier dropoff). '
            'Yard entry: %.',
            NEW.fk_cylinder,
            COALESCE(v_current_state_name, 'UNKNOWN — no state record'),
            NEW.pk_yard_entry_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_validate_yard_entry_state() IS
    'V78 — Extended from V65. '
    'Accepts four source states for a yard entry: '
    'FULL_PICKED_FROM_SUPPLIER (refill return), '
    'FULL_PICKED_UP_FOR_DELIVERY (full cylinder returned from trip), '
    'EMPTY_IN_TRANSIT_TO_YARD (empty collected from customer), '
    'EMPTY_PICKED_FOR_REFILL (empty returned to yard without supplier dropoff — NEW in V78). '
    'Trigger binding (trg_01_validate_yard_entry_state) is unchanged; '
    'replacing the function is sufficient.';


-- =============================================================================
-- PART 2 — Replace AFTER INSERT audit trigger
--           Handle the new transition:
--             EMPTY_PICKED_FOR_REFILL → EMPTY
--           in addition to the three already handled by V65.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_audit_yard_entry_after()
RETURNS TRIGGER AS $$
DECLARE
    -- Source state IDs
    v_full_picked_from_supplier_id    int8;
    v_full_picked_up_for_delivery_id  int8;
    v_empty_in_transit_id             int8;
    v_empty_picked_for_refill_id      int8;   -- NEW

    -- Target state IDs
    v_full_state_id   int8;
    v_empty_state_id  int8;

    -- Current state of the cylinder at trigger time
    v_current_state_id   int8;
    v_previous_state_id  int8;
    v_new_state_id       int8;
    v_remarks_text       varchar(500);

    v_vehicle_load_id    int8;
BEGIN
    -- ── Resolve state IDs ─────────────────────────────────────────────────
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

    -- ── Resolve last known vehicle load (for current_status backfill) ─────
    SELECT fk_current_vehicle_load INTO v_vehicle_load_id
    FROM public.tbl_cylinder_current_status
    WHERE fk_cylinder = NEW.fk_cylinder;

    -- ── Route: determine previous and new state based on current state ─────
    --
    --  Current state                     → New yard state
    --  ─────────────────────────────────────────────────────────────────────
    --  FULL_PICKED_FROM_SUPPLIER         → FULL   (refill collection return)
    --  FULL_PICKED_UP_FOR_DELIVERY       → FULL   (unused full returned to yard)
    --  EMPTY_IN_TRANSIT_TO_YARD          → EMPTY  (customer pickup arrived)
    --  EMPTY_PICKED_FOR_REFILL  ← NEW   → EMPTY  (empty returned, no supplier visit)
    --
    IF v_current_state_id IN (
            v_full_picked_from_supplier_id,
            v_full_picked_up_for_delivery_id
        )
    THEN
        v_previous_state_id := v_current_state_id;
        v_new_state_id      := v_full_state_id;
        v_remarks_text :=
            CASE v_current_state_id
                WHEN v_full_picked_from_supplier_id THEN
                    'Cylinder arrived at yard after supplier refill collection. '
                    'State: FULL_PICKED_FROM_SUPPLIER → FULL. '
                    'Yard entry: ' || NEW.pk_yard_entry_id || '.'
                WHEN v_full_picked_up_for_delivery_id THEN
                    'Full cylinder returned to yard without delivery. '
                    'State: FULL_PICKED_UP_FOR_DELIVERY → FULL. '
                    'Yard entry: ' || NEW.pk_yard_entry_id || '.'
            END;

    ELSIF v_current_state_id = v_empty_in_transit_id THEN
        v_previous_state_id := v_empty_in_transit_id;
        v_new_state_id      := v_empty_state_id;
        v_remarks_text :=
            'Empty cylinder arrived at yard from customer pickup (EMPTY_IN_TRANSIT_TO_YARD → EMPTY). '
            'Yard entry: ' || NEW.pk_yard_entry_id || '.';

    -- ── NEW BRANCH: EMPTY_PICKED_FOR_REFILL returned without supplier visit ──
    ELSIF v_current_state_id = v_empty_picked_for_refill_id THEN
        v_previous_state_id := v_empty_picked_for_refill_id;
        v_new_state_id      := v_empty_state_id;
        v_remarks_text :=
            'Empty cylinder returned to yard without supplier dropoff. '
            'State: EMPTY_PICKED_FOR_REFILL → EMPTY. '
            'Yard entry: ' || NEW.pk_yard_entry_id || '. '
            'No supplier trip line was created for this cylinder. '
            'It is available in the yard for the next scheduled refill run.';

    ELSE
        -- Should not reach here given the BEFORE trigger guard, but be safe
        RAISE EXCEPTION
            'fn_audit_yard_entry_after: Unexpected cylinder state (id=%) for cylinder %. '
            'BEFORE trigger should have prevented this yard entry.',
            v_current_state_id, NEW.fk_cylinder;
    END IF;

    -- ── 1. Write the state audit row ──────────────────────────────────────
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
        v_previous_state_id,
        v_new_state_id,
        NULL,
        now(),
        v_remarks_text
    );

    -- ── 2. Update tbl_cylinder_current_status ────────────────────────────
    --    • Clear vehicle load (cylinder is no longer on any vehicle)
    --    • Clear supplier trip (only relevant for FULL_PICKED_FROM_SUPPLIER path)
    --    • Set new state
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
        NULL,           -- not at a customer
        NULL,           -- cleared: not on a vehicle
        NULL,           -- cleared: supplier trip complete (or not visited)
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

COMMENT ON FUNCTION public.fn_audit_yard_entry_after() IS
    'V78 — Extended from V65. '
    'Handles four yard-entry transitions: '
    'FULL_PICKED_FROM_SUPPLIER → FULL, '
    'FULL_PICKED_UP_FOR_DELIVERY → FULL, '
    'EMPTY_IN_TRANSIT_TO_YARD → EMPTY, '
    'EMPTY_PICKED_FOR_REFILL → EMPTY (NEW — empty returned without supplier dropoff). '
    'In all cases: clears fk_current_vehicle_load and fk_last_supplier_trip '
    'in tbl_cylinder_current_status, and writes a tbl_cylinder_state_audit row.';


-- =============================================================================
-- PART 3 — Reconciliation orchestrator: update TRIP_DEPARTURE cylinder count
--           The fn_validate_yard_entry_state guard previously excluded
--           EMPTY_PICKED_FOR_REFILL from the vehicle-on-trip count. Now that
--           these cylinders are legitimately on the vehicle until they either
--           go to a supplier OR return to yard, the TRIP_DEPARTURE checkpoint
--           expected_count in V69 / V76 already uses COUNT(load_lines) which
--           correctly includes them. No change needed to fn_create_checkpoint.
--
--           HOWEVER: the TRIP_RETURN resolve in fn_trip_status_after_update
--           (V69) uses the same line count. This is still correct because the
--           yard entry records the cylinder as back in the yard and the
--           load_line count does not change. The actual_count at Halt should
--           equal the number of cylinders that left on departure, regardless
--           of whether they went to a supplier or came back as empties.
--           No trigger change required.
-- =============================================================================

-- =============================================================================
-- PART 4 — Descriptive comment on the states table row for EMPTY_PICKED_FOR_REFILL
--           (previously said "Empty cylinder delivered to supplier for refill"
--            which is not yet true at this state — it is only PICKED for refill)
-- =============================================================================

UPDATE public.tbl_cylinder_states
SET description = 'Empty cylinder loaded onto vehicle designated for supplier refill. '
                  'Cylinder is in transit. It will transition to EMPTY_DELIVERED_FOR_REFILL '
                  'when dropped off at the supplier, OR back to EMPTY if returned to the yard '
                  'without a supplier visit (yard entry without supplier trip line).'
WHERE cylinder_state = 'EMPTY_PICKED_FOR_REFILL';


-- =============================================================================
-- VERIFICATION QUERIES (run manually after migration)
-- =============================================================================

-- 1. Confirm the updated description
--    SELECT cylinder_state, description
--    FROM   public.tbl_cylinder_states
--    WHERE  cylinder_state = 'EMPTY_PICKED_FOR_REFILL';

-- 2. Simulate a yard return for an EMPTY_PICKED_FOR_REFILL cylinder
--    (replace :cylinder_id and :trip_id with real values):
--
--    INSERT INTO public.tbl_yard_entries (fk_cylinder, fk_vehicle_trip, remarks)
--    VALUES (:cylinder_id, :trip_id,
--            'Empty cylinder returned to yard without supplier dropoff.');
--
--    Then verify:
--    SELECT cs.cylinder_state, ccs.fk_current_vehicle_load, ccs.updated_at
--    FROM   public.tbl_cylinder_current_status ccs
--    JOIN   public.tbl_cylinder_states cs ON cs.pk_cylinder_state_id = ccs.fk_current_state
--    WHERE  ccs.fk_cylinder = :cylinder_id;
--    -- Expected: cylinder_state = 'EMPTY', fk_current_vehicle_load = NULL

-- 3. Confirm audit trail
--    SELECT fk_previous_state, fk_new_state, remarks, changed_at
--    FROM   public.tbl_cylinder_state_audit
--    WHERE  fk_cylinder = :cylinder_id
--    ORDER  BY changed_at DESC
--    LIMIT  3;
