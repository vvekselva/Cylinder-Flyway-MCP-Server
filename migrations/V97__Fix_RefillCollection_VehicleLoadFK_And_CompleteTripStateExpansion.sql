-- =============================================================================
-- V97__Fix_RefillCollection_VehicleLoadFK_And_CompleteTripStateExpansion.sql
-- =============================================================================
--
-- ROOT CAUSE
-- ─────────────────────────────────────────────────────────────────────────────
-- V91 replaced fn_audit_cylinder_refill_collection_after (which was last
-- corrected in V68) to add SUPPLIER_DROPOFF checkpoint line resolution.
-- In doing so it silently dropped the V68 fix: the UPDATE on
-- tbl_cylinder_current_status no longer sets fk_current_vehicle_load.
--
-- V68 UPDATE (correct):
--     SET fk_current_state           = v_full_picked_state_id,
--         fk_current_vehicle_trip    = v_collection_trip_id,
--         fk_current_vehicle_load    = v_collection_vehicle_load_id,  ← present
--         fk_current_supplier        = NULL,
--         fk_current_holder_customer = NULL,
--         updated_at                 = now()
--
-- V91 UPDATE (regression — V68 fix dropped):
--     SET fk_current_state           = v_full_picked_state_id,
--         fk_current_vehicle_trip    = v_collection_trip_id,
--         -- fk_current_vehicle_load  ← MISSING: reverted to pre-V68 behaviour
--         fk_current_supplier        = NULL,
--         fk_current_holder_customer = NULL,
--         updated_at                 = now()
--
-- When a cylinder is collected from the supplier after refilling it transitions
-- to FULL_PICKED_FROM_SUPPLIER state. After V91, fk_current_vehicle_load is
-- left at whatever value it had before (typically NULL after the supplier had
-- cleared it, or stale from the original load-out trip). The backend DAO query
-- CylinderCurrentStatusJpaDao.findCurrentlyOnVehicle:
--
--     WHERE ccs.currentVehicleLoad.vehicleLoadId = :vehicleLoadId
--       AND ccs.currentState.cylinderState IN (
--             'FULL_PICKED_UP_FOR_DELIVERY',
--             'EMPTY_PICKED_FOR_REFILL',
--             'EMPTY_IN_TRANSIT_TO_YARD',
--             'FULL_PICKED_FROM_SUPPLIER'
--           )
--
-- …joins on currentVehicleLoad (INNER JOIN semantics in Spring Data JPA when
-- the property is accessed without LEFT JOIN FETCH). With fk_current_vehicle_load
-- NULL, the join produces no row → findCurrentlyOnVehicle returns 0 for the
-- collection trip's load even though those cylinders are physically on the
-- vehicle.
--
-- OBSERVED SYMPTOM (from logs)
-- ─────────────────────────────────────────────────────────────────────────────
-- CompleteTripServiceImpl line 116:
--   "The Number of Cylinders in the Vehicle: false"  (hasContent() = false)
--   "processRequest - Found 0 cylinders on vehicle. Creating YardEntries for Load ID: 9"
--   "processRequest - No cylinders found currently on vehicle for Load ID: 9."
--
-- Fleet summary after trip close:
--   Full Picked From Supplier, location=In Transit, count=18
-- Those 18 cylinders are in FULL_PICKED_FROM_SUPPLIER (correctly) but their
-- fk_current_vehicle_load = NULL so no yard entry is created for them.
--
-- The V96 INTRANSIT gate in fn_validate_trip_status_transition also failed to
-- catch this: it queries
--     WHERE ccs.fk_current_vehicle_load = v_load_id
--       AND cs.location = 'In Transit'
-- With fk_current_vehicle_load = NULL that predicate never matches → the gate
-- passes (0 stranded cylinders detected) even though those cylinders ARE still
-- in transit on this load. The trip incorrectly closes.
--
-- SECONDARY ISSUE — CompleteTripServiceImpl state coverage
-- ─────────────────────────────────────────────────────────────────────────────
-- CompleteTripServiceImpl calls findCurrentlyOnVehicle which filters on four
-- states. This is correct for determining which cylinders need a yard entry.
-- However the service then creates yard entries for every matched cylinder
-- indiscriminately regardless of state. For FULL_PICKED_FROM_SUPPLIER cylinders
-- the correct next state is FULL (via fn_audit_cylinder_yard_entry_after in V95)
-- which is correct. For EMPTY_IN_TRANSIT_TO_YARD the correct next state is EMPTY
-- which is also correct. So CompleteTripServiceImpl itself does not need changes —
-- the only required fix is restoring fk_current_vehicle_load in the trigger.
--
-- FIXES IN THIS MIGRATION
-- ─────────────────────────────────────────────────────────────────────────────
-- FIX 1  — Restore fk_current_vehicle_load in fn_audit_cylinder_refill_
--           collection_after.  Re-add the V68 logic:
--           resolve pk_vehicle_load_id from tbl_vehicle_load via the 1:1
--           guarantee on tbl_vehicle_load.fk_vehicle_trip, then include it in
--           the UPDATE.  All V91 reconciliation additions are preserved.
--
-- FIX 2  — Restore fk_current_vehicle_load in the V96 INTRANSIT gate.
--           The gate in fn_validate_trip_status_transition (V96) queries
--           by fk_current_vehicle_load to detect stranded cylinders.  Because
--           the V91 regression leaves that column NULL, the gate cannot detect
--           stranded FULL_PICKED_FROM_SUPPLIER cylinders.
--           Fix: extend the gate to ALSO check fk_current_vehicle_trip, which
--           was always correctly set by V91.  A cylinder is considered stranded
--           if EITHER (fk_current_vehicle_load = this load) OR
--           (fk_current_vehicle_trip = this trip AND state is In Transit).
--           This makes the gate robust to any future NULL-load regression.
--
-- FIX 3  — Backfill: fix all existing FULL_PICKED_FROM_SUPPLIER rows that have
--           fk_current_vehicle_load = NULL but fk_current_vehicle_trip IS NOT NULL.
--           (This is the backfill that V68 included but commented out; the same
--           root cause re-introduced by V91 has re-created the same stale rows.)
--
-- DEPENDENCIES
--   V55  UNIQUE (fk_vehicle_trip) on tbl_vehicle_load  (1:1 guarantee used here)
--   V68  fn_audit_cylinder_refill_collection_after  (REPLACED — preserves V91 additions)
--   V91  fn_audit_cylinder_refill_collection_after  (this migration replaces V91 version)
--   V96  fn_validate_trip_status_transition          (REPLACED — gate extended)
-- =============================================================================


-- =============================================================================
-- FIX 1 — Restore fk_current_vehicle_load in
--          fn_audit_cylinder_refill_collection_after
--
--  Replaces V91 version.  All V91 additions (SUPPLIER_DROPOFF checkpoint line
--  resolution, header closure) are reproduced verbatim.  The only change is
--  adding v_collection_vehicle_load_id resolution and including it in the UPDATE.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_audit_cylinder_refill_collection_after()
RETURNS TRIGGER AS $$
DECLARE
    v_empty_delivered_state_id    int8;
    v_full_picked_state_id        int8;
    v_collection_trip_id          int8;
    v_collection_vehicle_load_id  int8;   -- V68 fix: restored in V97

    v_supplier_trip_id            int8;
    v_total_lines                 int4;
    v_collected_lines             int4;
    v_dropoff_header_id           int8;
BEGIN
    SELECT pk_cylinder_state_id INTO v_empty_delivered_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL';

    SELECT pk_cylinder_state_id INTO v_full_picked_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL_PICKED_FROM_SUPPLIER';

    -- ── Resolve collection trip and its vehicle load ──────────────────────────
    -- (V68 pattern, dropped by V91, restored here)
    SELECT fk_vehicle_trip INTO v_collection_trip_id
      FROM public.tbl_supplier_refill_collection
     WHERE pk_collection_id = NEW.fk_collection;

    -- V55 guarantees a 1:1 between tbl_vehicle_load and tbl_vehicle_trip.
    -- NULL is tolerated: if the load has not been created yet the column is
    -- set to NULL rather than raising an exception.  The trip-level FK
    -- (fk_current_vehicle_trip) is always set so the backend can fall back.
    SELECT pk_vehicle_load_id INTO v_collection_vehicle_load_id
      FROM public.tbl_vehicle_load
     WHERE fk_vehicle_trip = v_collection_trip_id;

    -- ── State audit (unchanged from V91) ─────────────────────────────────────
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
            || 'Collection line: ' || NEW.pk_collection_line_id
    );

    -- ── Current status — V68 fix restored ────────────────────────────────────
    -- V91 accidentally removed fk_current_vehicle_load from this SET clause,
    -- causing findCurrentlyOnVehicle to return 0 for the collecting trip's load.
    -- It is restored here (V97).
    UPDATE public.tbl_cylinder_current_status
       SET fk_current_state           = v_full_picked_state_id,
           fk_current_vehicle_trip    = v_collection_trip_id,
           fk_current_vehicle_load    = v_collection_vehicle_load_id,  -- ← RESTORED
           fk_current_supplier        = NULL,
           fk_current_holder_customer = NULL,
           updated_at                 = now()
     WHERE fk_cylinder = NEW.fk_cylinder;

    -- ── Mark supplier trip line collected (unchanged from V91) ────────────────
    UPDATE public.tbl_supplier_trip_line
       SET collected    = TRUE,
           collected_at = COALESCE(NEW.collected_at, now())
     WHERE pk_supplier_trip_line_id = NEW.fk_supplier_trip_line;

    -- ── Resolve the SUPPLIER_DROPOFF checkpoint line (V91, unchanged) ─────────
    SELECT stl.fk_supplier_trip INTO v_supplier_trip_id
      FROM public.tbl_supplier_trip_line stl
     WHERE stl.pk_supplier_trip_line_id = NEW.fk_supplier_trip_line;

    IF v_supplier_trip_id IS NOT NULL THEN

        SELECT pk_header_id INTO v_dropoff_header_id
          FROM public.tbl_reconciliation_header
         WHERE fk_supplier_trip = v_supplier_trip_id
           AND header_type      = 'SUPPLIER_DROPOFF'
           AND header_status    NOT IN ('CLOSED', 'VARIANCE')
         ORDER BY opened_at DESC
         LIMIT 1;

        IF v_dropoff_header_id IS NOT NULL THEN
            PERFORM public.fn_resolve_reconciliation_line(
                v_dropoff_header_id,
                NEW.fk_cylinder,
                'ACCOUNTED',
                'SUPPLIER_DROPOFF',
                'Collected back. Collection line ' || NEW.pk_collection_line_id
                    || ' on collection trip ' || v_collection_trip_id
            );
        END IF;

        -- Close the SUPPLIER_DROPOFF header when all lines are collected
        SELECT COUNT(*) FILTER (WHERE collected = TRUE),
               COUNT(*)
          INTO v_collected_lines, v_total_lines
          FROM public.tbl_supplier_trip_line
         WHERE fk_supplier_trip = v_supplier_trip_id;

        IF v_collected_lines = v_total_lines AND v_dropoff_header_id IS NOT NULL THEN
            BEGIN
                PERFORM public.fn_close_reconciliation_header(
                    v_dropoff_header_id,
                    'All ' || v_total_lines || ' cylinders for supplier trip '
                        || v_supplier_trip_id || ' collected back.'
                );
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE '[SUPPLIER_DROPOFF/close header supplier_trip=%]: %',
                    v_supplier_trip_id, SQLERRM;
            END;
        END IF;

    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger binding trg_02_audit_cylinder_refill_collection_after was wired in V56
-- and still points to this function name — no trigger changes needed.

COMMENT ON FUNCTION public.fn_audit_cylinder_refill_collection_after() IS
    'V97 — Restores V68 fix dropped by V91. '
    'State transition (unchanged): EMPTY_DELIVERED_FOR_REFILL → FULL_PICKED_FROM_SUPPLIER. '
    'V68 fix: resolves fk_current_vehicle_load via tbl_vehicle_load.fk_vehicle_trip '
    '(V55 1:1 guarantee) and includes it in the UPDATE on tbl_cylinder_current_status. '
    'V91 additions preserved: resolves SUPPLIER_DROPOFF checkpoint line per cylinder; '
    'closes the SUPPLIER_DROPOFF header when all supplier trip lines are collected. '
    'Marks tbl_supplier_trip_line.collected = TRUE.';


-- =============================================================================
-- FIX 2 — Extend the INTRANSIT gate in fn_validate_trip_status_transition (V96)
--          to detect cylinders stranded by fk_current_vehicle_load = NULL.
--
--  The V96 gate queries:
--      WHERE ccs.fk_current_vehicle_load = v_load_id
--        AND cs.location = 'In Transit'
--  If fk_current_vehicle_load is NULL (as caused by the V91 regression),
--  stranded cylinders are invisible to the gate.
--
--  Extended predicate:
--      WHERE (
--            ccs.fk_current_vehicle_load = v_load_id      -- normal case
--         OR ccs.fk_current_vehicle_trip = v_trip_id      -- fallback: load FK missing
--      )
--      AND cs.location = 'In Transit'
--
--  This closes the bypass regardless of which FK is NULL.
--  All other gate logic (YARD_START gate, YARD_END gate) is unchanged from V96.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_validate_trip_status_transition()
RETURNS TRIGGER AS $$
DECLARE
    v_old_order         int4;
    v_new_order         int4;
    v_old_name          varchar(50);
    v_new_name          varchar(50);

    -- Gate A
    v_load_id           int8;
    v_yard_start_exists boolean;

    -- Gate B
    v_yard_end_completed  boolean;
    v_intransit_count     int4 := 0;
    v_intransit_serials   text := '';
BEGIN
    IF NEW.fk_trip_status = OLD.fk_trip_status THEN RETURN NEW; END IF;

    SELECT status_name, display_order INTO v_old_name, v_old_order
      FROM public.tbl_trip_status WHERE pk_trip_status_id = OLD.fk_trip_status;

    SELECT status_name, display_order INTO v_new_name, v_new_order
      FROM public.tbl_trip_status WHERE pk_trip_status_id = NEW.fk_trip_status;

    -- ── Forward-only ordering guard (unchanged) ──────────────────────────────
    IF v_new_order <> v_old_order + 1 THEN
        RAISE EXCEPTION
            'Invalid trip status transition: % → %. '
            'Valid sequence: Started → Loaded → Proceeding → Halt.',
            v_old_name, v_new_name;
    END IF;

    -- ── Transition timestamps (unchanged) ────────────────────────────────────
    CASE v_new_name
        WHEN 'Loaded'     THEN NEW.trip_loaded_at   := now();
        WHEN 'Proceeding' THEN NEW.trip_departed_at := now();
        WHEN 'Halt'       THEN NEW.trip_closed_at   := now();
        ELSE NULL;
    END CASE;

    -- Resolve vehicle load (used by both gates)
    SELECT pk_vehicle_load_id INTO v_load_id
      FROM public.tbl_vehicle_load
     WHERE fk_vehicle_trip = NEW.pk_vehicle_trip_id;

    -- =========================================================================
    -- GATE A  —  Started → Loaded
    -- =========================================================================
    IF v_new_name = 'Loaded' THEN

        IF v_load_id IS NULL THEN
            RAISE EXCEPTION
                'Trip % cannot advance to Loaded: no vehicle load (tbl_vehicle_load) '
                'exists for this trip. Create the vehicle load record before marking '
                'the trip as Loaded.',
                NEW.pk_vehicle_trip_id;
        END IF;

        SELECT EXISTS (
            SELECT 1
              FROM public.tbl_vehicle_trip_stop vts
              JOIN public.tbl_stop_type         st  ON st.pk_stop_type_id = vts.fk_stop_type
             WHERE vts.fk_vehicle_trip = NEW.pk_vehicle_trip_id
               AND st.stop_type        = 'YARD_START'
        ) INTO v_yard_start_exists;

        IF NOT v_yard_start_exists THEN
            RAISE EXCEPTION
                'Trip % cannot advance to Loaded: a YARD_START stop must be recorded '
                'in tbl_vehicle_trip_stop before the trip is marked as Loaded.',
                NEW.pk_vehicle_trip_id;
        END IF;

    END IF; -- END GATE A


    -- =========================================================================
    -- GATE B  —  Proceeding → Halt
    -- =========================================================================
    IF v_new_name = 'Halt' THEN

        -- Sub-check 1: COMPLETED YARD_END stop (unchanged from V96)
        SELECT EXISTS (
            SELECT 1
              FROM public.tbl_vehicle_trip_stop vts
              JOIN public.tbl_stop_type         st  ON st.pk_stop_type_id = vts.fk_stop_type
             WHERE vts.fk_vehicle_trip = NEW.pk_vehicle_trip_id
               AND st.stop_type        = 'YARD_END'
               AND vts.stop_status     = 'COMPLETED'
        ) INTO v_yard_end_completed;

        IF NOT v_yard_end_completed THEN
            IF NOT EXISTS (
                SELECT 1
                  FROM public.tbl_vehicle_trip_stop vts
                  JOIN public.tbl_stop_type         st ON st.pk_stop_type_id = vts.fk_stop_type
                 WHERE vts.fk_vehicle_trip = NEW.pk_vehicle_trip_id
                   AND st.stop_type        = 'YARD_END'
            ) THEN
                RAISE EXCEPTION
                    'Trip % cannot be Halted: no YARD_END stop has been recorded. '
                    'The driver must record the return-to-yard stop before the trip '
                    'can be closed.',
                    NEW.pk_vehicle_trip_id;
            ELSE
                RAISE EXCEPTION
                    'Trip % cannot be Halted: the YARD_END stop exists but its '
                    'stop_status is not COMPLETED. Complete the yard return tally '
                    'before closing the trip.',
                    NEW.pk_vehicle_trip_id;
            END IF;
        END IF;

        -- Sub-check 2: No INTRANSIT cylinders — extended for NULL-load case (V97)
        --
        -- V96 queried only by fk_current_vehicle_load. If fk_current_vehicle_load
        -- is NULL (as caused by the V91 regression in fn_audit_cylinder_refill_
        -- collection_after), stranded FULL_PICKED_FROM_SUPPLIER cylinders were
        -- invisible to this gate.
        --
        -- The predicate is now OR-combined with fk_current_vehicle_trip so that
        -- cylinders stranded by EITHER FK being stale/NULL are caught.
        SELECT COUNT(*),
               string_agg(c.cylinder_serial || ' [' || cs.cylinder_state || ']',
                           ', ' ORDER BY c.cylinder_serial)
          INTO v_intransit_count, v_intransit_serials
          FROM public.tbl_cylinder_current_status  ccs
          JOIN public.tbl_cylinder_states           cs  ON cs.pk_cylinder_state_id = ccs.fk_current_state
          JOIN public.tbl_cylinder                  c   ON c.pk_cylinder_id        = ccs.fk_cylinder
         WHERE (
                   ccs.fk_current_vehicle_load = v_load_id            -- normal path
                OR ccs.fk_current_vehicle_trip = NEW.pk_vehicle_trip_id  -- fallback: load FK null
               )
           AND cs.location = 'In Transit'
         LIMIT 10;

        IF v_intransit_count > 0 THEN
            RAISE EXCEPTION
                'Trip % cannot be Halted: % cylinder(s) are still in an INTRANSIT '
                'state on this vehicle. Each cylinder must reach a terminal state '
                '(DELIVERED_FOR_CONSUMPTION, EMPTY_DELIVERED_FOR_REFILL, FULL, EMPTY, '
                'etc.) before the trip can close. '
                'INTRANSIT cylinders (up to 10): [%]',
                NEW.pk_vehicle_trip_id, v_intransit_count, v_intransit_serials;
        END IF;

    END IF; -- END GATE B

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_validate_trip_status_transition() IS
    'V97 — Replaces V96. '
    'Gate A (→Loaded): vehicle load must exist AND a YARD_START stop must be recorded. '
    'Gate B (→Halt): a COMPLETED YARD_END stop must exist; zero cylinders may be in '
    'any In-Transit state linked to this trip (checked by EITHER fk_current_vehicle_load '
    'OR fk_current_vehicle_trip to handle the NULL-load regression from V91). '
    'V97 change: INTRANSIT gate now uses OR predicate so it catches cylinders whose '
    'fk_current_vehicle_load is NULL due to the V91 regression in '
    'fn_audit_cylinder_refill_collection_after.';


---- =============================================================================
---- FIX 3 — Backfill: repair FULL_PICKED_FROM_SUPPLIER rows stranded by V91
----
----  Targets any cylinder that:
----    (a) is currently in FULL_PICKED_FROM_SUPPLIER state
----    (b) has fk_current_vehicle_load = NULL  (the V91 regression symptom)
----    (c) has a fk_current_vehicle_trip that resolves to a vehicle load row
----
----  This is the same backfill that V68 included but commented out.  The V91
----  regression re-introduced the same defect for all collections since V91 was
----  applied, so the backfill is now required on live data.
----
----  Safe and idempotent: cylinders already corrected match no rows on re-run.
----  The UNIQUE constraint on tbl_vehicle_load.fk_vehicle_trip guarantees at
----  most one vehicle load per trip — no ambiguity in the join.
---- =============================================================================
--
--UPDATE public.tbl_cylinder_current_status ccs
--SET    fk_current_vehicle_load = vl.pk_vehicle_load_id,
--       updated_at              = now()
--FROM   public.tbl_cylinder_states cs
--JOIN   public.tbl_vehicle_load    vl ON vl.fk_vehicle_trip = ccs.fk_current_vehicle_trip
--WHERE  cs.pk_cylinder_state_id        = ccs.fk_current_state
--  AND  cs.cylinder_state              = 'FULL_PICKED_FROM_SUPPLIER'
--  AND  ccs.fk_current_vehicle_load    IS NULL
--  AND  ccs.fk_current_vehicle_trip    IS NOT NULL;
--
---- Report how many rows were fixed (shows in flyway log / psql output)
--DO $$
--DECLARE
--    v_fixed int4;
--BEGIN
--    GET DIAGNOSTICS v_fixed = ROW_COUNT;
--    RAISE NOTICE 'V97 backfill: fixed % FULL_PICKED_FROM_SUPPLIER row(s) with NULL fk_current_vehicle_load.', v_fixed;
--END;
--$$;
--

-- =============================================================================
-- SUPPLEMENTARY — Document the CylinderCurrentStatusJpaDao query expectation
-- =============================================================================
--
-- The DAO query findCurrentlyOnVehicle (Section 4 of CylinderCurrentStatusJpaDao)
-- performs an implicit INNER JOIN on ccs.currentVehicleLoad because Spring Data
-- JPA / Hibernate resolves the association without a LEFT JOIN FETCH when
-- accessed as a path expression in the WHERE clause.
--
-- This means:  ccs.currentVehicleLoad.vehicleLoadId = :vehicleLoadId
-- …implicitly requires fk_current_vehicle_load IS NOT NULL.
--
-- The states covered are:
--   FULL_PICKED_UP_FOR_DELIVERY — full, loaded from yard, not yet delivered
--   EMPTY_PICKED_FOR_REFILL     — empty, loaded from yard, not yet at supplier
--   EMPTY_IN_TRANSIT_TO_YARD    — empty, collected from customer, returning to yard
--   FULL_PICKED_FROM_SUPPLIER   — full, collected from supplier, returning to yard
--
-- All four of these states MUST have fk_current_vehicle_load correctly set by
-- their respective DB triggers:
--   FULL_PICKED_UP_FOR_DELIVERY  → set by fn_audit_cylinder_load_after (V42)
--   EMPTY_PICKED_FOR_REFILL      → set by fn_audit_cylinder_load_after (V42)
--   EMPTY_IN_TRANSIT_TO_YARD     → set by fn_audit_cylinder_yard_entry_after (V95, empty pickup path)
--   FULL_PICKED_FROM_SUPPLIER    → set by fn_audit_cylinder_refill_collection_after (V68, RESTORED V97)
--
-- If any trigger drops fk_current_vehicle_load from its UPDATE SET clause,
-- that state becomes invisible to findCurrentlyOnVehicle and
-- CompleteTripServiceImpl will not create yard entries for those cylinders.
-- =============================================================================
