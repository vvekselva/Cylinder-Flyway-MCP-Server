-- =============================================================================
-- V111__WalkIn_Counter_Return_State.sql
-- =============================================================================
--
-- ROOT CAUSE OF V110 RUNTIME FAILURE
-- ─────────────────────────────────────────────────────────────────────────────
-- V110 reused EMPTY_IN_TRANSIT_TO_YARD as the staging state for walk-in counter
-- returns.  That state was inserted in V43 with location = 'In Transit'.
-- V98 then bulk-set expects_load_fk = TRUE for every 'In Transit' state.
-- fn_cylinder_fk_consistency() (BEFORE trigger on tbl_cylinder_current_status)
-- therefore requires fk_current_vehicle_load IS NOT NULL whenever any trigger
-- writes EMPTY_IN_TRANSIT_TO_YARD.
--
-- Walk-in counter returns have no vehicle load.  The V110 pickup trigger
-- sets fk_current_vehicle_load = NULL, and fn_cylinder_fk_consistency()
-- raises:
--   FK VIOLATION — fk_cylinder=1, state=[EMPTY_IN_TRANSIT_TO_YARD]:
--   fk_current_vehicle_load must be SET.
--
-- WHY EMPTY_IN_TRANSIT_TO_YARD CANNOT BE PATCHED IN PLACE
-- ─────────────────────────────────────────────────────────────────────────────
-- Setting expects_load_fk = FALSE on EMPTY_IN_TRANSIT_TO_YARD would break all
-- existing vehicle-trip empty-pickup paths that correctly depend on the FK
-- being present for reconciliation (fn_trip_status_after_update, V95, V97).
--
-- CORRECT FIX
-- ─────────────────────────────────────────────────────────────────────────────
-- Introduce a dedicated state for the walk-in counter return path:
--
--   EMPTY_RETURNED_WALKIN
--     location     = 'Yard'            (customer hands cylinder over at the yard
--                                       counter — it is already on yard premises)
--     expects_load_fk = FALSE           (no vehicle involved)
--     expects_trip_fk = FALSE           (no vehicle involved)
--
-- Corrected walk-in return lifecycle:
--
--   1. Walk-in delivery (existing, unchanged):
--        FULL → DELIVERED_FOR_CONSUMPTION        (tbl_order_line trigger)
--
--   2. Walk-in counter return (V110 trigger — updated here):
--        DELIVERED_FOR_CONSUMPTION → EMPTY_RETURNED_WALKIN
--
--   3. Yard receipt (tbl_yard_entries trigger — updated here):
--        EMPTY_RETURNED_WALKIN → EMPTY
--
-- CHANGES IN THIS MIGRATION
-- ─────────────────────────────────────────────────────────────────────────────
--   STEP 1  Insert EMPTY_RETURNED_WALKIN into tbl_cylinder_states
--              (location='Yard', expects_load_fk=FALSE, expects_trip_fk=FALSE)
--   STEP 2  Add state-transition rows:
--              DELIVERED_FOR_CONSUMPTION → EMPTY_RETURNED_WALKIN
--              EMPTY_RETURNED_WALKIN     → EMPTY
--   STEP 3  Replace fn_walk_in_pickup_line_after_insert (V110)
--              swap EMPTY_IN_TRANSIT_TO_YARD → EMPTY_RETURNED_WALKIN
--   STEP 4  Replace fn_check_cylinder_before_yard_entry (V95)
--              add EMPTY_RETURNED_WALKIN to the accepted-state set
--   STEP 5  Replace fn_audit_cylinder_yard_entry_after (V95)
--              add EMPTY_RETURNED_WALKIN → EMPTY branch
--   STEP 6  Verification
--
-- DEPENDENCIES
--   V43   EMPTY_IN_TRANSIT_TO_YARD state (NOT changed)
--   V95   fn_check_cylinder_before_yard_entry, fn_audit_cylinder_yard_entry_after
--   V98   fn_cylinder_fk_consistency, expects_load_fk / expects_trip_fk columns
--   V110  fn_walk_in_pickup_line_after_insert, tbl_walk_in_pickup_line
-- =============================================================================


-- =============================================================================
-- STEP 1 — New state: EMPTY_RETURNED_WALKIN
-- =============================================================================
-- Location 'Yard':  the customer has physically handed the cylinder to yard staff
--                   at the counter.  It is on yard premises — no transit leg.
-- expects_load_fk = FALSE, expects_trip_fk = FALSE: no vehicle involved.
-- =============================================================================

-- fk_location is NOT NULL on tbl_cylinder_states (enforced by V104).
-- The subquery is inlined directly into the INSERT so the column is
-- populated in the same statement — a subsequent UPDATE would be too late.
INSERT INTO public.tbl_cylinder_states (
    pk_cylinder_state_id,
    cylinder_state,
    description,
    location,
    fk_location,
    expects_load_fk,
    expects_trip_fk,
    ui_display_name
)
SELECT
    nextval('public.pk_cylinder_state_id_serial'),
    'EMPTY_RETURNED_WALKIN',
    'Empty cylinder returned by customer at the yard counter (walk-in return). '
    'No vehicle or trip involved. Awaiting yard staff receipt confirmation.',
    'Yard',
    (SELECT pk_location_id FROM public.tbl_cylinder_location WHERE location_name = 'Yard' LIMIT 1),
    FALSE,
    FALSE,
    'Empty Returned (Walk-In)'
WHERE NOT EXISTS (
    SELECT 1
      FROM public.tbl_cylinder_states
     WHERE cylinder_state = 'EMPTY_RETURNED_WALKIN'
);


-- =============================================================================
-- STEP 2 — State-transition rows
-- =============================================================================

-- tbl_cylinder_state_transition has columns: from_state, to_state, description only.
-- The allowed_event column does not exist in this schema.
INSERT INTO public.tbl_cylinder_state_transition (
    from_state,
    to_state,
    description
)
VALUES
    (
        'DELIVERED_FOR_CONSUMPTION',
        'EMPTY_RETURNED_WALKIN',
        'Customer returns empty cylinder at the yard counter (walk-in return). '
        'No vehicle or trip involved. '
        'Recorded via tbl_walk_in_pickup_line; awaiting yard-staff receipt.'
    ),
    (
        'EMPTY_RETURNED_WALKIN',
        'EMPTY',
        'Yard staff confirms receipt of walk-in returned empty cylinder. '
        'State: EMPTY_RETURNED_WALKIN → EMPTY. '
        'Recorded via tbl_yard_entries.'
    )
ON CONFLICT (from_state, to_state) DO NOTHING;

-- Remove the now-superseded V110 transition seed if it was inserted
-- (WHERE NOT EXISTS guard in V110 means it was only inserted on databases
-- that did NOT already have this row from V98, so this DELETE is safe either way)
-- allowed_event column does not exist on tbl_cylinder_state_transition in this schema.
-- V98 seeded DELIVERED_FOR_CONSUMPTION → EMPTY_IN_TRANSIT_TO_YARD without an event column;
-- that row is intentionally left untouched as it covers vehicle-trip pickup paths.


-- =============================================================================
-- STEP 3 — Replace fn_walk_in_pickup_line_after_insert (V110)
--           Only change: EMPTY_IN_TRANSIT_TO_YARD  →  EMPTY_RETURNED_WALKIN
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_walk_in_pickup_line_after_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_customer_id                   int8;
    v_previous_state_id             int8;
    v_previous_state_name           varchar(100);
    v_empty_returned_walkin_id      int8;
    v_yard_location_id              int8;
    v_cylinder_serial               varchar(100);
BEGIN
    -- Resolve pickup customer.
    SELECT fk_customer
      INTO v_customer_id
      FROM public.tbl_walk_in_pickup
     WHERE pk_walk_in_pickup_id = NEW.fk_walk_in_pickup;

    IF v_customer_id IS NULL THEN
        RAISE EXCEPTION
            'Walk-in pickup validation failed: pickup header % not found.',
            NEW.fk_walk_in_pickup;
    END IF;

    -- Resolve current cylinder state; cylinder must be held by this customer.
    SELECT ccs.fk_current_state, cs.cylinder_state
      INTO v_previous_state_id, v_previous_state_name
      FROM public.tbl_cylinder_current_status ccs
      JOIN public.tbl_cylinder_states cs
        ON cs.pk_cylinder_state_id = ccs.fk_current_state
     WHERE ccs.fk_cylinder = NEW.fk_cylinder
       AND ccs.fk_current_holder_customer = v_customer_id;

    IF NOT FOUND THEN
        SELECT cylinder_serial
          INTO v_cylinder_serial
          FROM public.tbl_cylinder
         WHERE pk_cylinder_id = NEW.fk_cylinder;

        RAISE EXCEPTION
            'Walk-in pickup validation failed: cylinder % (%) is not currently '
            'held by customer %.',
            COALESCE(v_cylinder_serial, '?'),
            NEW.fk_cylinder,
            v_customer_id;
    END IF;

    IF v_previous_state_name <> 'DELIVERED_FOR_CONSUMPTION' THEN
        SELECT cylinder_serial
          INTO v_cylinder_serial
          FROM public.tbl_cylinder
         WHERE pk_cylinder_id = NEW.fk_cylinder;

        RAISE EXCEPTION
            'Walk-in pickup validation failed: cylinder % (%) is in state [%]. '
            'Expected state [DELIVERED_FOR_CONSUMPTION] before walk-in counter return.',
            COALESCE(v_cylinder_serial, '?'),
            NEW.fk_cylinder,
            COALESCE(v_previous_state_name, 'UNKNOWN');
    END IF;

    -- Resolve the new state.
    -- EMPTY_RETURNED_WALKIN has expects_load_fk = FALSE, expects_trip_fk = FALSE
    -- so fn_cylinder_fk_consistency() accepts NULL for both vehicle FKs.
    SELECT pk_cylinder_state_id
      INTO v_empty_returned_walkin_id
      FROM public.tbl_cylinder_states
     WHERE cylinder_state = 'EMPTY_RETURNED_WALKIN';

    IF v_empty_returned_walkin_id IS NULL THEN
        RAISE EXCEPTION
            'Walk-in pickup validation failed: cylinder state EMPTY_RETURNED_WALKIN '
            'is missing. Ensure V111 migration has been applied.';
    END IF;

    -- Yard location: the cylinder is physically at the yard counter.
    SELECT pk_location_id
      INTO v_yard_location_id
      FROM public.tbl_cylinder_location
     WHERE location_name IN ('Yard', 'Yard Location')
     ORDER BY CASE WHEN location_name = 'Yard' THEN 1 ELSE 2 END
     LIMIT 1;

    IF v_yard_location_id IS NULL THEN
        RAISE EXCEPTION
            'Walk-in pickup validation failed: Yard location not found in '
            'tbl_cylinder_location.';
    END IF;

    -- Audit the transition.
    INSERT INTO public.tbl_cylinder_state_audit (
        pk_audit_id,
        fk_cylinder,
        fk_previous_state,
        fk_new_state,
        changed_at,
        remarks
    ) VALUES (
        nextval('public.pk_cylinder_state_id_serial'),
        NEW.fk_cylinder,
        v_previous_state_id,
        v_empty_returned_walkin_id,
        now(),
        'Walk-in counter return. '
        'State: DELIVERED_FOR_CONSUMPTION → EMPTY_RETURNED_WALKIN. '
        'Pickup id: ' || NEW.fk_walk_in_pickup
    );

    -- Update current status.
    -- fk_current_vehicle_load = NULL and fk_current_vehicle_trip = NULL are
    -- correct and REQUIRED: EMPTY_RETURNED_WALKIN has expects_load_fk = FALSE.
    -- fn_cylinder_fk_consistency() will PASS this update.
    UPDATE public.tbl_cylinder_current_status
       SET fk_current_state            = v_empty_returned_walkin_id,
           fk_current_location         = v_yard_location_id,
           fk_current_holder_customer  = NULL,
           fk_current_customer_address = NULL,
           fk_current_supplier         = NULL,
           fk_current_vehicle_trip     = NULL,
           fk_current_vehicle_load     = NULL,
           updated_at                  = now()
     WHERE fk_cylinder = NEW.fk_cylinder;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.fn_walk_in_pickup_line_after_insert() IS
    'V111 update (was V110). '
    'Transitions cylinder from DELIVERED_FOR_CONSUMPTION → EMPTY_RETURNED_WALKIN '
    'on walk-in counter return. EMPTY_RETURNED_WALKIN has expects_load_fk = FALSE '
    'so fn_cylinder_fk_consistency() accepts NULL vehicle FKs. '
    'The yard receipt step (tbl_yard_entries) then moves the cylinder to EMPTY.';


-- =============================================================================
-- STEP 4 — Replace fn_check_cylinder_before_yard_entry (V95)
--           Add EMPTY_RETURNED_WALKIN to the accepted-state set.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_check_cylinder_before_yard_entry()
RETURNS TRIGGER AS $$
DECLARE
    v_current_state_id   int8;
    v_current_state_name varchar(100);

    v_full_picked_from_supplier_id    int8;
    v_full_picked_up_for_delivery_id  int8;
    v_empty_in_transit_id             int8;
    v_empty_picked_for_refill_id      int8;
    v_empty_returned_walkin_id        int8;   -- V111: walk-in counter return
BEGIN
    SELECT pk_cylinder_state_id INTO v_full_picked_from_supplier_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL_PICKED_FROM_SUPPLIER';

    SELECT pk_cylinder_state_id INTO v_full_picked_up_for_delivery_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL_PICKED_UP_FOR_DELIVERY';

    SELECT pk_cylinder_state_id INTO v_empty_in_transit_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_IN_TRANSIT_TO_YARD';

    SELECT pk_cylinder_state_id INTO v_empty_picked_for_refill_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_PICKED_FOR_REFILL';

    SELECT pk_cylinder_state_id INTO v_empty_returned_walkin_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_RETURNED_WALKIN';

    -- Resolve current state: fast path via tbl_cylinder_current_status.
    SELECT ccs.fk_current_state, cs.cylinder_state
      INTO v_current_state_id, v_current_state_name
      FROM public.tbl_cylinder_current_status ccs
      JOIN public.tbl_cylinder_states cs
           ON cs.pk_cylinder_state_id = ccs.fk_current_state
     WHERE ccs.fk_cylinder = NEW.fk_cylinder;

    -- Fallback: audit trail (for cylinders with no current_status row).
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

    -- Gate: must be one of the five accepted states.
    IF v_current_state_id NOT IN (
        v_full_picked_from_supplier_id,    -- post-refill collection
        v_full_picked_up_for_delivery_id,  -- full cylinder returned un-delivered
        v_empty_in_transit_id,             -- empty collected from customer by vehicle
        v_empty_picked_for_refill_id,      -- empty returned without supplier dropoff
        v_empty_returned_walkin_id         -- V111: walk-in counter return
    ) THEN
        RAISE EXCEPTION
            'Yard Entry Validation Failed: Cylinder % cannot enter the yard from '
            'state [%]. '
            'Accepted states: '
            'FULL_PICKED_FROM_SUPPLIER (post-refill collection), '
            'FULL_PICKED_UP_FOR_DELIVERY (full cylinder returned un-delivered), '
            'EMPTY_IN_TRANSIT_TO_YARD (empty collected from customer by vehicle), '
            'EMPTY_PICKED_FOR_REFILL (empty returned without supplier dropoff), '
            'EMPTY_RETURNED_WALKIN (walk-in counter return). '
            'Yard entry row: %.',
            NEW.fk_cylinder,
            COALESCE(v_current_state_name, 'UNKNOWN — no state record'),
            NEW.pk_yard_entry_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_check_cylinder_before_yard_entry() IS
    'V111 update (was V95). '
    'Accepts five source states for a yard entry: '
    'FULL_PICKED_FROM_SUPPLIER (refill return), '
    'FULL_PICKED_UP_FOR_DELIVERY (undelivered full returned), '
    'EMPTY_IN_TRANSIT_TO_YARD (customer empty collected by vehicle mid-trip), '
    'EMPTY_PICKED_FOR_REFILL (empty brought back without supplier stop), '
    'EMPTY_RETURNED_WALKIN (walk-in customer returns empty at yard counter — V111).';


-- =============================================================================
-- STEP 5 — Replace fn_audit_cylinder_yard_entry_after (V95)
--           Add EMPTY_RETURNED_WALKIN → EMPTY branch.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_audit_cylinder_yard_entry_after()
RETURNS TRIGGER AS $$
DECLARE
    v_full_picked_from_supplier_id    int8;
    v_full_picked_up_for_delivery_id  int8;
    v_empty_in_transit_id             int8;
    v_empty_picked_for_refill_id      int8;
    v_empty_returned_walkin_id        int8;   -- V111

    v_full_state_id   int8;
    v_empty_state_id  int8;

    v_current_state_id   int8;
    v_previous_state_id  int8;
    v_new_state_id       int8;
    v_yard_location_id   int8;
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

    SELECT pk_cylinder_state_id INTO v_empty_returned_walkin_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_RETURNED_WALKIN';

    SELECT pk_cylinder_state_id INTO v_full_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL';

    SELECT pk_cylinder_state_id INTO v_empty_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY';

    SELECT pk_location_id INTO v_yard_location_id
      FROM public.tbl_cylinder_location WHERE location_name = 'Yard' LIMIT 1;

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
    --  ─────────────────────────────────────────────────────────────────────
    --  FULL_PICKED_FROM_SUPPLIER        → FULL   (refill collected, returned to yard)
    --  FULL_PICKED_UP_FOR_DELIVERY      → FULL   (full cylinder not delivered, returned)
    --  EMPTY_IN_TRANSIT_TO_YARD         → EMPTY  (customer empty collected by vehicle)
    --  EMPTY_PICKED_FOR_REFILL          → EMPTY  (aborted trip, empty returned — V95)
    --  EMPTY_RETURNED_WALKIN            → EMPTY  (walk-in counter return — V111)
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
            'Empty cylinder arrived at yard from vehicle customer pickup. '
            'State: EMPTY_IN_TRANSIT_TO_YARD → EMPTY. '
            'Yard entry: ' || NEW.pk_yard_entry_id || '.';

    ELSIF v_current_state_id = v_empty_picked_for_refill_id THEN
        v_previous_state_id := v_empty_picked_for_refill_id;
        v_new_state_id      := v_empty_state_id;
        v_remarks_text :=
            'Empty cylinder returned to yard without supplier dropoff (aborted trip). '
            'State: EMPTY_PICKED_FOR_REFILL → EMPTY. '
            'Yard entry: ' || NEW.pk_yard_entry_id || '. '
            'Cylinder is available for the next scheduled refill run.';

    -- ── V111: walk-in counter return ──────────────────────────────────────
    ELSIF v_current_state_id = v_empty_returned_walkin_id THEN
        v_previous_state_id := v_empty_returned_walkin_id;
        v_new_state_id      := v_empty_state_id;
        v_remarks_text :=
            'Walk-in customer returned empty cylinder at yard counter. '
            'State: EMPTY_RETURNED_WALKIN → EMPTY. '
            'Yard entry: ' || NEW.pk_yard_entry_id || '. '
            'Cylinder is available for the next refill run.';

    ELSE
        RAISE EXCEPTION
            'fn_audit_cylinder_yard_entry_after: Unexpected cylinder state (id=%) '
            'for cylinder %. '
            'Expected one of: FULL_PICKED_FROM_SUPPLIER, FULL_PICKED_UP_FOR_DELIVERY, '
            'EMPTY_IN_TRANSIT_TO_YARD, EMPTY_PICKED_FOR_REFILL, EMPTY_RETURNED_WALKIN. '
            'Yard entry: %.',
            COALESCE(v_current_state_id::text, 'NULL'),
            NEW.fk_cylinder,
            NEW.pk_yard_entry_id;
    END IF;

    -- ── Audit the yard-entry transition ───────────────────────────────────
    INSERT INTO public.tbl_cylinder_state_audit (
        pk_audit_id,
        fk_cylinder,
        fk_previous_state,
        fk_new_state,
        changed_at,
        remarks
    ) VALUES (
        nextval('public.pk_cylinder_state_id_serial'),
        NEW.fk_cylinder,
        v_previous_state_id,
        v_new_state_id,
        now(),
        v_remarks_text
    );

    -- ── Update current status ─────────────────────────────────────────────
    -- Both FULL and EMPTY have expects_load_fk = FALSE, expects_trip_fk = FALSE.
    -- NULL vehicle FKs are correct and required.
    UPDATE public.tbl_cylinder_current_status
       SET fk_current_state            = v_new_state_id,
           fk_current_location         = v_yard_location_id,
           fk_current_holder_customer  = NULL,
           fk_current_customer_address = NULL,
           fk_current_supplier         = NULL,
           fk_current_vehicle_trip     = NULL,
           fk_current_vehicle_load     = NULL,
           updated_at                  = now()
     WHERE fk_cylinder = NEW.fk_cylinder;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_audit_cylinder_yard_entry_after() IS
    'V111 update (was V95). '
    'Routes yard entry to the correct target state based on the cylinder''s '
    'source state at the time of yard receipt: '
    'FULL_PICKED_FROM_SUPPLIER / FULL_PICKED_UP_FOR_DELIVERY → FULL; '
    'EMPTY_IN_TRANSIT_TO_YARD / EMPTY_PICKED_FOR_REFILL → EMPTY; '
    'EMPTY_RETURNED_WALKIN → EMPTY (V111: walk-in counter return path).';


-- =============================================================================
-- STEP 6 — Verification
-- =============================================================================

DO $$
DECLARE
    v_state_exists       boolean;
    v_trans1_exists      boolean;
    v_trans2_exists      boolean;
    v_expects_load_ok    boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM public.tbl_cylinder_states
         WHERE cylinder_state = 'EMPTY_RETURNED_WALKIN'
    ) INTO v_state_exists;

    SELECT EXISTS (
        SELECT 1 FROM public.tbl_cylinder_state_transition
         WHERE from_state = 'DELIVERED_FOR_CONSUMPTION'
           AND to_state   = 'EMPTY_RETURNED_WALKIN'
    ) INTO v_trans1_exists;

    SELECT EXISTS (
        SELECT 1 FROM public.tbl_cylinder_state_transition
         WHERE from_state = 'EMPTY_RETURNED_WALKIN'
           AND to_state   = 'EMPTY'
    ) INTO v_trans2_exists;

    SELECT EXISTS (
        SELECT 1 FROM public.tbl_cylinder_states
         WHERE cylinder_state    = 'EMPTY_RETURNED_WALKIN'
           AND expects_load_fk   = FALSE
           AND expects_trip_fk   = FALSE
    ) INTO v_expects_load_ok;

    IF NOT v_state_exists THEN
        RAISE WARNING 'V111 VERIFY FAILED: EMPTY_RETURNED_WALKIN state missing.';
    ELSE
        RAISE NOTICE 'V111 OK: EMPTY_RETURNED_WALKIN state exists.';
    END IF;

    IF NOT v_trans1_exists THEN
        RAISE WARNING 'V111 VERIFY FAILED: DELIVERED_FOR_CONSUMPTION → EMPTY_RETURNED_WALKIN transition missing.';
    ELSE
        RAISE NOTICE 'V111 OK: DELIVERED_FOR_CONSUMPTION → EMPTY_RETURNED_WALKIN transition exists.';
    END IF;

    IF NOT v_trans2_exists THEN
        RAISE WARNING 'V111 VERIFY FAILED: EMPTY_RETURNED_WALKIN → EMPTY transition missing.';
    ELSE
        RAISE NOTICE 'V111 OK: EMPTY_RETURNED_WALKIN → EMPTY transition exists.';
    END IF;

    IF NOT v_expects_load_ok THEN
        RAISE WARNING 'V111 VERIFY FAILED: EMPTY_RETURNED_WALKIN has wrong expects_load_fk / expects_trip_fk flags.';
    ELSE
        RAISE NOTICE 'V111 OK: EMPTY_RETURNED_WALKIN has expects_load_fk=FALSE, expects_trip_fk=FALSE.';
    END IF;
END;
$$;
