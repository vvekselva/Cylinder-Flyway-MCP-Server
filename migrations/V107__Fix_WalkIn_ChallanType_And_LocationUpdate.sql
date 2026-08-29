-- =============================================================================
-- V107__Fix_WalkIn_ChallanType_And_LocationUpdate.sql
-- =============================================================================
--
-- ROOT CAUSE ANALYSIS
-- ─────────────────────────────────────────────────────────────────────────────
-- TWO BUGS introduced by the interaction between V89 and V104:
--
--
-- BUG 1 — fn_check_cylinder_is_picked_up (BEFORE INSERT on tbl_order_line)
--          PATH C (FULL cylinder) challan-type guard is too strict
-- ─────────────────────────────────────────────────────────────────────────────
-- V89 added PATH C which allows FULL cylinders only when challan_type = WALK_IN
-- AND an OPEN tbl_walk_in_sale row exists.
--
-- V104 added the state transitions that make the walk-in sale flow possible:
--   FULL → DELIVERED_FOR_CONSUMPTION  (customer picks up at yard counter)
--   DELIVERED_FOR_CONSUMPTION → EMPTY (customer returns empty cylinder)
--
-- However, WalkinSaleIngestionController creates orders with challan_type =
-- 'DELIVERY' (not 'WALK_IN'). The trigger therefore raises:
--
--   Validation Failed: Cylinder A1 (1) is in FULL state (at yard).
--   A FULL cylinder can only be added to a WALK_IN challan (yard counter sale).
--   This challan is type [DELIVERY].
--
-- The FULL → DELIVERED_FOR_CONSUMPTION state transition (added in V104) is
-- never reached because the BEFORE trigger blocks the order_line INSERT first.
--
-- Fix: Relax the challan-type guard in PATH C.
--   Primary guard: an OPEN tbl_walk_in_sale row must exist for the order.
--   Secondary guard: challan_type must be WALK_IN or DELIVERY.
--
-- Rationale: tbl_walk_in_sale existence is the authoritative signal that this
-- is a walk-in sale (it is explicitly created by WalkinSaleIngestionController
-- before order lines are inserted). The challan type alone is unreliable
-- because WalkinSaleIngestionController currently creates DELIVERY-type orders.
-- Accepting both WALK_IN and DELIVERY maintains forward-compatibility when the
-- Java controller is updated to use WALK_IN.
--
-- BUG 2 — fn_audit_cylinder_delivery_after (AFTER INSERT on tbl_order_line)
--          fk_current_location not updated — stale location after delivery
-- ─────────────────────────────────────────────────────────────────────────────
-- V104 added fk_current_location (NOT NULL FK → tbl_cylinder_location) to
-- tbl_cylinder_current_status. V89's fn_audit_cylinder_delivery_after does a
-- direct UPDATE on that table but does NOT set fk_current_location.
--
-- This does not cause a crash (UPDATE preserves existing NOT NULL values), but
-- leaves the column pointing at the cylinder's PREVIOUS location (Yard) after
-- delivery instead of 'Customer Location'. Every downstream query that reads
-- fk_current_location to count "cylinders at customers" will be wrong.
--
-- Fix: Add fk_current_location = v_customer_loc_id to the UPDATE SET clause.
--
-- DEPENDENCIES
--   V21  tbl_order_line trigger binding (unchanged)
--   V89  fn_check_cylinder_is_picked_up (full function; base for this rewrite)
--   V89  fn_audit_cylinder_delivery_after (full function; base for this rewrite)
--   V104 tbl_cylinder_location + FULL/DELIVERED_FOR_CONSUMPTION transitions
-- =============================================================================


-- =============================================================================
-- FIX 1 — fn_check_cylinder_is_picked_up
--          BEFORE INSERT on tbl_order_line
--          PATH C: accept tbl_walk_in_sale as the authoritative walk-in guard;
--          allow challan_type WALK_IN or DELIVERY (not just WALK_IN)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_check_cylinder_is_picked_up()
RETURNS TRIGGER AS $$
DECLARE
    v_delivery_state_id         int8;
    v_direct_delivery_state_id  int8;
    v_full_state_id             int8;
    v_current_state_id          int8;
    v_current_state_name        varchar(100);
    v_challan_type              varchar(50);
    v_trip_id                   int8;
    v_cylinder_serial           varchar(50);
BEGIN
    SELECT pk_cylinder_state_id INTO v_delivery_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL_PICKED_UP_FOR_DELIVERY';

    SELECT pk_cylinder_state_id INTO v_direct_delivery_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL_PICKED_FROM_SUPPLIER';

    SELECT pk_cylinder_state_id INTO v_full_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL';

    -- ── Resolve current state ─────────────────────────────────────────────────
    SELECT ccs.fk_current_state, cs.cylinder_state
      INTO v_current_state_id, v_current_state_name
      FROM public.tbl_cylinder_current_status ccs
      JOIN public.tbl_cylinder_states cs ON cs.pk_cylinder_state_id = ccs.fk_current_state
     WHERE ccs.fk_cylinder = NEW.fk_cylinder;

    IF NOT FOUND THEN
        SELECT fk_new_state INTO v_current_state_id
          FROM public.tbl_cylinder_state_audit
         WHERE fk_cylinder = NEW.fk_cylinder
         ORDER BY changed_at DESC, pk_audit_id DESC LIMIT 1;
        SELECT cylinder_state INTO v_current_state_name
          FROM public.tbl_cylinder_states WHERE pk_cylinder_state_id = v_current_state_id;
    END IF;

    SELECT cylinder_serial INTO v_cylinder_serial
      FROM public.tbl_cylinder WHERE pk_cylinder_id = NEW.fk_cylinder;

    -- ── PATH A: Standard trip delivery ────────────────────────────────────────
    -- Cylinder was loaded onto a vehicle (FULL → FULL_PICKED_UP_FOR_DELIVERY via
    -- tbl_vehicle_load_line). All good; AFTER trigger handles the state transition.
    IF v_current_state_id = v_delivery_state_id THEN
        RETURN NEW;
    END IF;

    -- ── PATH B: Direct delivery from supplier vehicle (V88/V89) ──────────────
    -- Cylinder was collected from the supplier (FULL_PICKED_FROM_SUPPLIER) and
    -- is being delivered directly to the customer without a yard stop.
    IF v_current_state_id = v_direct_delivery_state_id THEN
        SELECT fk_current_vehicle_trip INTO v_trip_id
          FROM public.tbl_cylinder_current_status
         WHERE fk_cylinder = NEW.fk_cylinder;

        IF v_trip_id IS NULL THEN
            RAISE EXCEPTION
                'Validation Failed: Cylinder % (%) is in FULL_PICKED_FROM_SUPPLIER state '
                'but has no active vehicle trip. The cylinder must be on a vehicle trip '
                'to be directly delivered to a customer. '
                'Check tbl_cylinder_current_status.fk_current_vehicle_trip.',
                v_cylinder_serial, NEW.fk_cylinder;
        END IF;

        RETURN NEW;
    END IF;

    -- ── PATH C: Walk-in counter sale (V89 + V107 fix) ─────────────────────────
    -- Cylinder is FULL and at the yard. The customer collects it directly from
    -- the yard counter (no vehicle loading). Introduces the state transition:
    --   FULL → DELIVERED_FOR_CONSUMPTION  (added to tbl_cylinder_state_transition in V104)
    --
    -- V107 FIX: The primary guard is tbl_walk_in_sale existence, NOT challan type.
    -- WalkinSaleIngestionController creates orders with challan_type = DELIVERY
    -- (pre-V89 behaviour), so requiring WALK_IN here would incorrectly block all
    -- walk-in sales.  Both WALK_IN and DELIVERY are accepted; the tbl_walk_in_sale
    -- row is the authoritative proof that this is a walk-in counter sale.
    IF v_current_state_id = v_full_state_id THEN

        -- Read the challan type for the informative error message only.
        SELECT ct.challan_type INTO v_challan_type
          FROM public.tbl_order o
          JOIN public.tbl_challan_type ct ON ct.pk_challan_type_id = o.fk_challan_type
         WHERE o.pk_order_id = NEW.fk_order;

        -- Guard: challan must be WALK_IN or DELIVERY (not a supplier / other type).
        -- WALK_IN = proper walk-in challan (V89+ controllers).
        -- DELIVERY = legacy walk-in challan (WalkinSaleIngestionController).
        -- V107: both are accepted; tbl_walk_in_sale is the real gate below.
        IF v_challan_type IS DISTINCT FROM 'WALK_IN'
           AND v_challan_type IS DISTINCT FROM 'DELIVERY' THEN
            RAISE EXCEPTION
                'Validation Failed: Cylinder % (%) is in FULL state (at yard). '
                'A FULL cylinder can only be added to a walk-in counter sale '
                '(challan_type WALK_IN or DELIVERY). '
                'This challan is type [%]. '
                'To deliver on a vehicle trip, load the cylinder first via '
                'tbl_vehicle_load_line (FULL → FULL_PICKED_UP_FOR_DELIVERY).',
                v_cylinder_serial, NEW.fk_cylinder,
                COALESCE(v_challan_type, 'UNKNOWN');
        END IF;

        -- Guard: an OPEN walk-in sale session must exist for this order.
        -- This is the authoritative check that WalkinSaleIngestionController
        -- created a valid session before inserting order lines.
        IF NOT EXISTS (
            SELECT 1 FROM public.tbl_walk_in_sale
             WHERE fk_order    = NEW.fk_order
               AND sale_status = 'OPEN'
        ) THEN
            RAISE EXCEPTION
                'Validation Failed: No OPEN walk-in sale session found for order %. '
                'WalkinSaleIngestionController must insert a tbl_walk_in_sale row '
                'with sale_status = OPEN before inserting order lines. '
                'Cylinder: % (%), challan_type: [%].',
                NEW.fk_order,
                v_cylinder_serial, NEW.fk_cylinder,
                COALESCE(v_challan_type, 'UNKNOWN');
        END IF;

        RETURN NEW;
    END IF;

    -- ── No valid path matched ─────────────────────────────────────────────────
    RAISE EXCEPTION
        'Validation Failed: Cylinder % (%) is in state [%]. '
        'Valid states for tbl_order_line are: '
        'FULL_PICKED_UP_FOR_DELIVERY (standard trip delivery), '
        'FULL_PICKED_FROM_SUPPLIER (direct delivery from supplier vehicle — V88), '
        'FULL (walk-in counter sale via WALK_IN or DELIVERY challan — V89/V107).',
        v_cylinder_serial, NEW.fk_cylinder,
        COALESCE(v_current_state_name, 'UNKNOWN — no state record found');
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_check_cylinder_is_picked_up() IS
    'Fires BEFORE INSERT on tbl_order_line. Three valid source states: '
    '  FULL_PICKED_UP_FOR_DELIVERY — standard trip delivery (loaded from yard). '
    '  FULL_PICKED_FROM_SUPPLIER   — direct delivery from supplier vehicle (V88/V89). '
    '    Validates: fk_current_vehicle_trip IS NOT NULL (cylinder must be on active trip). '
    '  FULL                        — walk-in counter sale (V89/V107). '
    '    Validates: challan_type IN (WALK_IN, DELIVERY) '
    '               AND an OPEN tbl_walk_in_sale exists for the order. '
    'V107 fix: PATH C previously required challan_type = WALK_IN exclusively. '
    'WalkinSaleIngestionController creates DELIVERY-type orders, so the guard was '
    'blocking all walk-in sales and preventing the FULL → DELIVERED_FOR_CONSUMPTION '
    'state transition (added to tbl_cylinder_state_transition in V104) from executing. '
    'Fix: tbl_walk_in_sale existence is now the primary gate; both WALK_IN and DELIVERY '
    'challan types are accepted for the walk-in path. '
    'History: V21 → V66 → V88 (dual state) → V89 (three states) → V107 (relax challan guard).';


-- =============================================================================
-- FIX 2 — fn_audit_cylinder_delivery_after
--          AFTER INSERT on tbl_order_line
--          Add fk_current_location = Customer Location to the UPDATE SET clause.
--          V104 added this column as NOT NULL; V89 does not set it on UPDATE.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_audit_cylinder_delivery_after()
RETURNS TRIGGER AS $$
DECLARE
    -- state IDs
    v_previous_state_id         int8;
    v_delivered_state_id        int8;
    v_full_state_id             int8;
    v_direct_delivery_state_id  int8;

    -- routing flags
    v_is_direct_delivery        boolean := false;
    v_is_walk_in                boolean := false;

    -- order / customer
    v_customer_id               int8;
    v_delivery_address_id       int8;
    v_challan_type              varchar(50);

    -- trip / stop (direct delivery path)
    v_trip_id                   int8;
    v_customer_delivery_type_id int8;
    v_yard_end_type_id          int8;
    v_next_stop_seq             int4;
    v_new_stop_id               int8;

    -- walk-in path
    v_walk_in_sale_id           int8;

    -- checkpoint / line counting
    v_line_count                int4;

    -- V107: location FK
    v_customer_location_id      int4;
BEGIN
    -- ── Resolve state IDs ─────────────────────────────────────────────────────
    SELECT pk_cylinder_state_id INTO v_delivered_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'DELIVERED_FOR_CONSUMPTION';

    SELECT pk_cylinder_state_id INTO v_direct_delivery_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL_PICKED_FROM_SUPPLIER';

    SELECT pk_cylinder_state_id INTO v_full_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL';

    -- ── V107: Resolve 'Customer Location' FK ─────────────────────────────────
    SELECT pk_location_id INTO v_customer_location_id
      FROM public.tbl_cylinder_location WHERE location_name = 'Customer Location';

    -- ── Resolve the ACTUAL previous state at runtime ──────────────────────────
    SELECT fk_current_state INTO v_previous_state_id
      FROM public.tbl_cylinder_current_status WHERE fk_cylinder = NEW.fk_cylinder;

    IF NOT FOUND THEN
        SELECT fk_new_state INTO v_previous_state_id
          FROM public.tbl_cylinder_state_audit
         WHERE fk_cylinder = NEW.fk_cylinder
         ORDER BY changed_at DESC, pk_audit_id DESC LIMIT 1;
    END IF;

    v_is_direct_delivery := (v_previous_state_id = v_direct_delivery_state_id);
    v_is_walk_in         := (v_previous_state_id = v_full_state_id);

    -- ── Resolve customer and delivery address ─────────────────────────────────
    SELECT o.fk_customer,
           COALESCE(NEW.fk_delivery_address, o.fk_delivery_address),
           ct.challan_type
      INTO v_customer_id, v_delivery_address_id, v_challan_type
      FROM public.tbl_order o
      JOIN public.tbl_challan_type ct ON ct.pk_challan_type_id = o.fk_challan_type
     WHERE o.pk_order_id = NEW.fk_order;

    -- =========================================================================
    -- STEP 1 — Write state audit row (all three paths)
    -- =========================================================================
    INSERT INTO public.tbl_cylinder_state_audit (
        pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
        fk_order, changed_at, remarks
    ) VALUES (
        nextval('public.pk_cylinder_state_id_serial'),
        NEW.fk_cylinder,
        v_previous_state_id,
        v_delivered_state_id,
        NEW.fk_order,
        now(),
        CASE
            WHEN v_is_walk_in THEN
                'Walk-in counter sale. State: FULL → DELIVERED_FOR_CONSUMPTION. '
                || 'Customer collected cylinder directly from yard (V89/V107).'
            WHEN v_is_direct_delivery THEN
                'Direct delivery from supplier vehicle. '
                || 'State: FULL_PICKED_FROM_SUPPLIER → DELIVERED_FOR_CONSUMPTION. '
                || 'No yard entry created (V88/V89 direct-delivery path).'
            ELSE
                'Standard trip delivery. '
                || 'State: FULL_PICKED_UP_FOR_DELIVERY → DELIVERED_FOR_CONSUMPTION.'
        END
    );

    -- =========================================================================
    -- STEP 2 — Update tbl_cylinder_current_status (all three paths)
    -- V107: add fk_current_location = Customer Location.
    --   V89 omitted this column from the UPDATE; since V104 made it NOT NULL,
    --   the row kept pointing at the Yard after every delivery — incorrect.
    -- =========================================================================
    UPDATE public.tbl_cylinder_current_status
       SET fk_current_state            = v_delivered_state_id,
           fk_current_location         = v_customer_location_id,  -- V107: was missing
           fk_current_holder_customer  = v_customer_id,
           fk_current_customer_address = v_delivery_address_id,
           fk_current_vehicle_trip     = NULL,
           fk_current_vehicle_load     = NULL,
           fk_last_supplier_trip       = CASE
                                             WHEN v_is_direct_delivery OR v_is_walk_in
                                             THEN NULL
                                             ELSE fk_last_supplier_trip
                                         END,
           updated_at                  = now()
     WHERE fk_cylinder = NEW.fk_cylinder;

    -- =========================================================================
    -- STEP 3 — PATH-SPECIFIC: direct delivery → auto-create CUSTOMER_DELIVERY stop
    -- =========================================================================
    IF v_is_direct_delivery THEN

        SELECT src.fk_vehicle_trip
          INTO v_trip_id
          FROM public.tbl_supplier_refill_collection_line srcl
          JOIN public.tbl_supplier_refill_collection      src
               ON src.pk_collection_id = srcl.fk_collection
         WHERE srcl.fk_cylinder = NEW.fk_cylinder
         ORDER BY src.pk_collection_id DESC
         LIMIT 1;

        IF v_trip_id IS NOT NULL THEN

            IF NOT EXISTS (
                SELECT 1 FROM public.tbl_vehicle_trip_stop
                 WHERE fk_vehicle_trip = v_trip_id
                   AND fk_order        = NEW.fk_order
            ) THEN
                SELECT pk_stop_type_id INTO v_customer_delivery_type_id
                  FROM public.tbl_stop_type WHERE stop_type = 'CUSTOMER_DELIVERY';

                SELECT pk_stop_type_id INTO v_yard_end_type_id
                  FROM public.tbl_stop_type WHERE stop_type = 'YARD_END';

                SELECT COALESCE(MAX(s.stop_sequence), 1) + 1
                  INTO v_next_stop_seq
                  FROM public.tbl_vehicle_trip_stop s
                 WHERE s.fk_vehicle_trip = v_trip_id
                   AND s.fk_stop_type   <> v_yard_end_type_id;

                v_new_stop_id := nextval('public.pk_trip_stop_id_serial');

                INSERT INTO public.tbl_vehicle_trip_stop (
                    pk_stop_id, fk_vehicle_trip, stop_sequence, fk_stop_type,
                    fk_customer, fk_delivery_address,
                    arrived_at, departed_at, stop_status
                ) VALUES (
                    v_new_stop_id,
                    v_trip_id,
                    v_next_stop_seq,
                    v_customer_delivery_type_id,
                    v_customer_id,
                    v_delivery_address_id,
                    now(),
                    now(),
                    'COMPLETED'
                );

                UPDATE public.tbl_vehicle_trip_stop
                   SET fk_order = NEW.fk_order
                 WHERE pk_stop_id = v_new_stop_id;

            END IF;
        END IF;

    END IF;

    -- =========================================================================
    -- STEP 4 — PATH-SPECIFIC: walk-in → update WALK_IN_SALE checkpoint
    -- =========================================================================
    IF v_is_walk_in THEN
        SELECT pk_walk_in_sale_id INTO v_walk_in_sale_id
          FROM public.tbl_walk_in_sale WHERE fk_order = NEW.fk_order;

        SELECT COUNT(*) INTO v_line_count
          FROM public.tbl_order_line WHERE fk_order = NEW.fk_order;

        UPDATE public.tbl_reconciliation_checkpoint
           SET remarks = 'Walk-in sale ' || COALESCE(v_walk_in_sale_id::text, '?')
                      || ' — entered: ' || v_line_count
                      || ' / declared: '
                      || (SELECT total_cylinders FROM public.tbl_walk_in_sale
                           WHERE pk_walk_in_sale_id = v_walk_in_sale_id)
         WHERE reference_entity_type = 'tbl_walk_in_sale'
           AND reference_entity_id   = v_walk_in_sale_id
           AND checkpoint_type       = 'WALK_IN_SALE'
           AND checkpoint_status     = 'PENDING';
    END IF;

    -- =========================================================================
    -- STEP 5 — Update TRIP_STOP_DELIVERY checkpoint remarks (standard + direct)
    -- =========================================================================
    IF NOT v_is_walk_in THEN
        SELECT COUNT(*) INTO v_line_count
          FROM public.tbl_order_line WHERE fk_order = NEW.fk_order;

        UPDATE public.tbl_reconciliation_checkpoint
           SET remarks = 'Challan ' || NEW.fk_order
                      || ' — entered: ' || v_line_count
                      || ' / declared: '
                      || (SELECT total_cylinders_delivered
                            FROM public.tbl_order WHERE pk_order_id = NEW.fk_order)
         WHERE reference_entity_type = 'tbl_order'
           AND reference_entity_id   = NEW.fk_order
           AND checkpoint_type       = 'TRIP_STOP_DELIVERY'
           AND checkpoint_status     = 'PENDING';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_audit_cylinder_delivery_after() IS
    'Fires AFTER INSERT on tbl_order_line. Three delivery paths: '
    '  FULL_PICKED_UP_FOR_DELIVERY — standard trip delivery; updates TRIP_STOP_DELIVERY remarks. '
    '  FULL_PICKED_FROM_SUPPLIER   — direct delivery (V88/V89); auto-creates CUSTOMER_DELIVERY '
    '    stop on the cylinder''s current vehicle trip. '
    '  FULL (walk-in)              — yard counter sale; updates WALK_IN_SALE checkpoint remarks. '
    'Previous state resolved at runtime (not hardcoded). '
    'V107 fix: fk_current_location now set to Customer Location on UPDATE. '
    'V104 added fk_current_location (NOT NULL) but V89 omitted it from the UPDATE, '
    'leaving every delivered cylinder''s location pointing at Yard. '
    'History: V21 → V56 → V66 → V81 → V82 → V88 → V89 → V107 (location fix + walk-in gate).';


-- =============================================================================
-- VERIFICATION
-- =============================================================================

DO $$
DECLARE
    v_before_fn_ok  boolean;
    v_after_fn_ok   boolean;
    v_transitions   int4;
BEGIN
    -- Confirm BEFORE trigger now references DELIVERY as an accepted type
    SELECT prosrc ILIKE '%DELIVERY%' AND prosrc ILIKE '%tbl_walk_in_sale%'
      INTO v_before_fn_ok
      FROM pg_proc WHERE proname = 'fn_check_cylinder_is_picked_up';

    -- Confirm AFTER trigger now references fk_current_location
    SELECT prosrc ILIKE '%fk_current_location%'
      INTO v_after_fn_ok
      FROM pg_proc WHERE proname = 'fn_audit_cylinder_delivery_after';

    -- Confirm both V104 walk-in transitions exist
    SELECT COUNT(*) INTO v_transitions
      FROM public.tbl_cylinder_state_transition
     WHERE (from_state = 'FULL'                   AND to_state = 'DELIVERED_FOR_CONSUMPTION')
        OR (from_state = 'DELIVERED_FOR_CONSUMPTION' AND to_state = 'EMPTY');

    IF NOT COALESCE(v_before_fn_ok, false) THEN
        RAISE WARNING 'V107 VERIFY: fn_check_cylinder_is_picked_up does not look patched — check DELIVERY guard.';
    ELSE
        RAISE NOTICE 'V107 OK: fn_check_cylinder_is_picked_up accepts WALK_IN and DELIVERY for walk-in path.';
    END IF;

    IF NOT COALESCE(v_after_fn_ok, false) THEN
        RAISE WARNING 'V107 VERIFY: fn_audit_cylinder_delivery_after does not set fk_current_location.';
    ELSE
        RAISE NOTICE 'V107 OK: fn_audit_cylinder_delivery_after now sets fk_current_location = Customer Location.';
    END IF;

    IF v_transitions < 2 THEN
        RAISE WARNING 'V107 VERIFY: Only % walk-in state transitions found in tbl_cylinder_state_transition (expected 2). '
                      'Ensure V104 has been applied.',
                      v_transitions;
    ELSE
        RAISE NOTICE 'V107 OK: Both walk-in state transitions present (FULL → DELIVERED_FOR_CONSUMPTION, DELIVERED_FOR_CONSUMPTION → EMPTY).';
    END IF;
END;
$$;
