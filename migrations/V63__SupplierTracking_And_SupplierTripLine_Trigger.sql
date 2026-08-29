-- =============================================================================
-- V63__SupplierTracking_And_SupplierTripLine_Trigger.sql
-- =============================================================================
-- TWO REQUIREMENTS ADDRESSED:
--
-- REQUIREMENT 1 — tbl_cylinder_current_status.fk_current_supplier
-- ─────────────────────────────────────────────────────────────────────────────
--   tbl_cylinder_current_status already tracks:
--     fk_current_holder_customer  (who has it at customer side)
--     fk_current_vehicle_trip     (which trip it is on in transit)
--   But there is no column to answer: "which supplier physically holds this
--   cylinder right now?" — the only link was through fk_last_supplier_trip
--   which is a LAST-TRIP pointer, not a CURRENT-HOLDER pointer.
--
--   This migration adds fk_current_supplier: populated when the cylinder's
--   state is EMPTY_DELIVERED_FOR_REFILL (physically at supplier) and cleared
--   when the cylinder is collected back (FULL_PICKED_FROM_SUPPLIER).
--
-- REQUIREMENT 2 — tbl_supplier_trip_line INSERT trigger
-- ─────────────────────────────────────────────────────────────────────────────
--   When a supplier trip line is added (i.e., an empty cylinder is assigned
--   to a supplier refill trip), the cylinder's state must automatically
--   transition EMPTY → EMPTY_PICKED_FOR_REFILL in tbl_cylinder_state_audit
--   and tbl_cylinder_current_status must be updated.
--
--   Currently this transition has NO trigger — the operator had to manually
--   manage the state, or it was implied by a vehicle load line purpose trigger
--   (V42). The direct trigger on tbl_supplier_trip_line is the correct and
--   unambiguous place for this.
--
-- RELATED FUNCTION UPDATES (CREATE OR REPLACE — no data loss):
--   fn_sync_cylinder_current_status     — clears fk_current_supplier on non-supplier states
--   fn_audit_supplier_dropoff_stop_completed — sets fk_current_supplier on dropoff
--   fn_audit_cylinder_refill_collection_after — clears fk_current_supplier on collection
--   vw_overdue_at_supplier              — rewritten to use direct fk_current_supplier join
--   fn_detect_dormant_cylinders         — rewritten to use direct fk_current_supplier
-- =============================================================================


-- =============================================================================
-- PART 1  tbl_cylinder_current_status — ADD fk_current_supplier
-- =============================================================================
-- Populated:   when state transitions to EMPTY_DELIVERED_FOR_REFILL
--              (cylinder handed to supplier; trigger: fn_audit_supplier_dropoff_stop_completed)
-- Cleared:     when state transitions to FULL_PICKED_FROM_SUPPLIER
--              (cylinder collected back; trigger: fn_audit_cylinder_refill_collection_after)
-- Always NULL: at Yard, In Transit to/from customer, at Customer

ALTER TABLE public.tbl_cylinder_current_status
    ADD COLUMN IF NOT EXISTS fk_current_supplier int8 NULL;

ALTER TABLE public.tbl_cylinder_current_status
    ADD CONSTRAINT tbl_cyl_cur_status_supplier_fk
    FOREIGN KEY (fk_current_supplier)
    REFERENCES public.tbl_supplier(pk_supplier_id);

CREATE INDEX idx_cyl_cur_status_supplier
    ON public.tbl_cylinder_current_status(fk_current_supplier)
    WHERE fk_current_supplier IS NOT NULL;

COMMENT ON COLUMN public.tbl_cylinder_current_status.fk_current_supplier IS
    'The supplier that physically holds this cylinder right now. '
    'Set when state = EMPTY_DELIVERED_FOR_REFILL (dropoff stop COMPLETED). '
    'Cleared when state = FULL_PICKED_FROM_SUPPLIER (collection trip fires). '
    'NULL at all other states (Yard, In Transit, Customer).';

-- Backfill: for any cylinder already in EMPTY_DELIVERED_FOR_REFILL state,
-- try to resolve the supplier from the last supplier trip.
-- (Only relevant if V58–V62 have already been run; idempotent if not.)
--UPDATE public.tbl_cylinder_current_status ccs
--SET fk_current_supplier = st.fk_supplier
--FROM public.tbl_cylinder_states cs
--JOIN public.tbl_supplier_trip st
--    ON st.pk_supplier_trip_id = ccs.fk_last_supplier_trip
--WHERE cs.pk_cylinder_state_id = ccs.fk_current_state
--  AND cs.cylinder_state       = 'EMPTY_DELIVERED_FOR_REFILL'
--  AND ccs.fk_current_supplier IS NULL
--  AND ccs.fk_last_supplier_trip IS NOT NULL;


-- =============================================================================
-- PART 2  TRIGGER: tbl_supplier_trip_line AFTER INSERT
--         → EMPTY (or COMMISSIONED) → EMPTY_PICKED_FOR_REFILL
-- =============================================================================
-- When a cylinder is added to a supplier refill trip, it has been physically
-- picked up from the yard and loaded on the vehicle heading to the supplier.
-- This is the definitive point of departure from the yard.
--
-- Validation: cylinder MUST be in EMPTY or COMMISSIONED state.
-- Action:
--   1. Insert audit: previous_state → EMPTY_PICKED_FOR_REFILL
--   2. Update tbl_cylinder_current_status:
--        fk_current_state        = EMPTY_PICKED_FOR_REFILL
--        fk_current_vehicle_trip = the vehicle trip on the supplier trip (if linked)
--        fk_current_supplier     = NULL (not yet at supplier)
--        fk_last_supplier_trip   = this supplier trip (track lineage)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_audit_supplier_trip_line_insert()
RETURNS TRIGGER AS $$
DECLARE
    v_empty_state_id             int8;
    v_commissioned_state_id      int8;
    v_empty_picked_state_id      int8;
    v_current_state_id           int8;
    v_current_state_name         varchar(100);
    v_supplier_vehicle_trip_id   int8;
BEGIN
    -- ── Resolve state IDs ──────────────────────────────────────────────────
    SELECT pk_cylinder_state_id INTO v_empty_state_id
    FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY';

    SELECT pk_cylinder_state_id INTO v_commissioned_state_id
    FROM public.tbl_cylinder_states WHERE cylinder_state = 'COMMISSIONED';

    SELECT pk_cylinder_state_id INTO v_empty_picked_state_id
    FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_PICKED_FOR_REFILL';

    -- ── Get current cylinder state ──────────────────────────────────────────
    SELECT ccs.fk_current_state, cs.cylinder_state
    INTO v_current_state_id, v_current_state_name
    FROM public.tbl_cylinder_current_status ccs
    JOIN public.tbl_cylinder_states cs
        ON cs.pk_cylinder_state_id = ccs.fk_current_state
    WHERE ccs.fk_cylinder = NEW.fk_cylinder;

    -- Fallback: if no current_status record yet, read from latest audit
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

    -- ── Validate ────────────────────────────────────────────────────────────
    -- Cylinder must be EMPTY or COMMISSIONED to go to a supplier trip.
    -- EMPTY_PICKED_FOR_REFILL is also accepted (idempotent reassignment guard).
    IF v_current_state_id NOT IN (
        v_empty_state_id,
        v_commissioned_state_id,
        v_empty_picked_state_id   -- allow re-assignment to a different trip
    ) THEN
        RAISE EXCEPTION
            'Validation Failed: Cylinder % must be in EMPTY or COMMISSIONED state '
            'before it can be assigned to a supplier trip line. '
            'Current state: %. Supplier trip: %.',
            NEW.fk_cylinder,
            COALESCE(v_current_state_name, 'UNKNOWN'),
            NEW.fk_supplier_trip;
    END IF;

    -- If already EMPTY_PICKED_FOR_REFILL (reassignment case), skip to avoid
    -- duplicate audit rows for the same effective transition.
    IF v_current_state_id = v_empty_picked_state_id THEN
        RETURN NEW;
    END IF;

    -- ── Resolve the vehicle trip carrying this supplier trip ─────────────────
    -- fk_vehicle_trip was added to tbl_supplier_trip in V56.
    SELECT fk_vehicle_trip INTO v_supplier_vehicle_trip_id
    FROM public.tbl_supplier_trip
    WHERE pk_supplier_trip_id = NEW.fk_supplier_trip;

    -- ── 1. Write state audit row ────────────────────────────────────────────
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
        v_current_state_id,
        v_empty_picked_state_id,
        NULL,
        now(),
        'Cylinder assigned to supplier trip line. '
            || 'Picked up from yard for refill. '
            || 'Supplier trip ID: ' || NEW.fk_supplier_trip
    );

    -- ── 2. Update current status ────────────────────────────────────────────
    -- Use UPSERT in case the trigger on tbl_cylinder_state_audit (V41)
    -- does not yet exist for older cylinder rows.
    INSERT INTO public.tbl_cylinder_current_status (
        fk_cylinder,
        fk_current_state,
        fk_current_vehicle_trip,
        fk_current_holder_customer,
        fk_current_supplier,
        fk_last_supplier_trip,
        updated_at
    ) VALUES (
        NEW.fk_cylinder,
        v_empty_picked_state_id,
        v_supplier_vehicle_trip_id,
        NULL,                          -- no longer (or never) at customer
        NULL,                          -- not yet at supplier
        NEW.fk_supplier_trip,          -- track which supplier trip lineage
        now()
    )
    ON CONFLICT (fk_cylinder) DO UPDATE
        SET fk_current_state            = v_empty_picked_state_id,
            fk_current_vehicle_trip     = v_supplier_vehicle_trip_id,
            fk_current_holder_customer  = NULL,
            fk_current_supplier         = NULL,
            fk_last_supplier_trip       = NEW.fk_supplier_trip,
            fk_current_vehicle_load     = NULL,
            updated_at                  = now();

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Naming: trg_01 ensures this fires BEFORE the refill-collection BEFORE trigger (trg_01_check_...)
-- This is an AFTER INSERT — state is validated, then audit + status are written atomically.
CREATE TRIGGER trg_01_audit_supplier_trip_line_insert
AFTER INSERT ON public.tbl_supplier_trip_line
FOR EACH ROW
EXECUTE FUNCTION public.fn_audit_supplier_trip_line_insert();

COMMENT ON FUNCTION public.fn_audit_supplier_trip_line_insert() IS
    'Fires AFTER INSERT on tbl_supplier_trip_line. '
    'Transitions the cylinder from EMPTY → EMPTY_PICKED_FOR_REFILL. '
    'Validates that cylinder is in an eligible state before transitioning. '
    'Updates tbl_cylinder_current_status.fk_current_vehicle_trip from the '
    'supplier trip vehicle trip link (added in V56).';


-- =============================================================================
-- PART 3  UPDATE fn_sync_cylinder_current_status (originally V41)
--         Add fk_current_supplier clearing logic for non-supplier states
-- =============================================================================
-- The original function handles the general case for all state transitions
-- that come through tbl_cylinder_state_audit. We extend it to clear
-- fk_current_supplier whenever the cylinder leaves a supplier state.
-- The SET of fk_current_supplier is left to the specific supplier triggers
-- (Parts 4 and 5) which have full supplier context.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_sync_cylinder_current_status()
RETURNS TRIGGER AS $$
DECLARE
    v_customer_id   int8 := NULL;
    v_state_name    varchar(100);
BEGIN
    -- Resolve the customer from the order (if an order is attached)
    IF NEW.fk_order IS NOT NULL THEN
        SELECT fk_customer INTO v_customer_id
        FROM public.tbl_order
        WHERE pk_order_id = NEW.fk_order;
    END IF;

    -- Resolve the state name so we can make routing decisions
    SELECT cylinder_state INTO v_state_name
    FROM public.tbl_cylinder_states
    WHERE pk_cylinder_state_id = NEW.fk_new_state;

    -- Clear customer when cylinder leaves customer premises
    IF v_state_name NOT IN ('DELIVERED_FOR_CONSUMPTION', 'LOST') THEN
        v_customer_id := NULL;
    END IF;

    INSERT INTO public.tbl_cylinder_current_status (
        fk_cylinder,
        fk_current_state,
        fk_current_holder_customer,
        -- fk_current_supplier: cleared for ALL states EXCEPT EMPTY_DELIVERED_FOR_REFILL.
        -- That state's supplier assignment is handled by the specific supplier-dropoff
        -- trigger (fn_audit_supplier_dropoff_stop_completed) which has full supplier context.
        -- Here we default to clearing it; the specific trigger fires after and overwrites.
        fk_current_supplier,
        fk_last_order,
        updated_at
    )
    VALUES (
        NEW.fk_cylinder,
        NEW.fk_new_state,
        v_customer_id,
        -- Only preserve supplier context for the EMPTY_DELIVERED_FOR_REFILL state;
        -- for all other states, clear it. Since the specific trigger (fn_audit_supplier_dropoff_stop_completed)
        -- fires on the UPDATE path (stop status change), not on this INSERT path,
        -- the UPSERT below simply NULLs it for all general state transitions.
        -- The supplier-dropoff trigger directly updates the row afterwards.
        NULL,
        NEW.fk_order,
        now()
    )
    ON CONFLICT (fk_cylinder) DO UPDATE
        SET fk_current_state            = EXCLUDED.fk_current_state,
            fk_current_holder_customer  = EXCLUDED.fk_current_holder_customer,
            -- Clear supplier for all general state transitions.
            -- Specific supplier triggers will set it back if appropriate.
            fk_current_supplier         = CASE
                WHEN (SELECT cylinder_state FROM public.tbl_cylinder_states
                      WHERE pk_cylinder_state_id = EXCLUDED.fk_current_state)
                     = 'EMPTY_DELIVERED_FOR_REFILL'
                THEN public.tbl_cylinder_current_status.fk_current_supplier  -- preserve: will be set by specific trigger
                ELSE NULL
            END,
            fk_last_order               = EXCLUDED.fk_last_order,
            updated_at                  = EXCLUDED.updated_at;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_sync_cylinder_current_status() IS
    'General-purpose UPSERT on tbl_cylinder_current_status, fired by trg_sync_current_status_after_audit '
    'on every tbl_cylinder_state_audit INSERT. '
    'fk_current_supplier is cleared for all states except EMPTY_DELIVERED_FOR_REFILL, '
    'where the existing value is preserved pending the specific dropoff trigger overwrite.';


-- =============================================================================
-- PART 4  UPDATE fn_audit_supplier_dropoff_stop_completed (originally V56 Part 4a)
--         Set fk_current_supplier when cylinder is handed to the supplier
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_audit_supplier_dropoff_stop_completed()
RETURNS TRIGGER AS $$
DECLARE
    v_stop_type_name           varchar(100);
    v_empty_picked_state_id    int8;
    v_empty_delivered_state_id int8;
    v_supplier_id              int8;
    rec                        RECORD;
BEGIN
    -- Only fire on COMPLETED transition
    IF NEW.stop_status <> 'COMPLETED' THEN
        RETURN NEW;
    END IF;
    IF OLD.stop_status = 'COMPLETED' THEN
        RETURN NEW;  -- idempotent
    END IF;

    SELECT stop_type INTO v_stop_type_name
    FROM public.tbl_stop_type
    WHERE pk_stop_type_id = NEW.fk_stop_type;

    IF v_stop_type_name <> 'SUPPLIER_DROPOFF' THEN
        RETURN NEW;
    END IF;

    SELECT pk_cylinder_state_id INTO v_empty_picked_state_id
    FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_PICKED_FOR_REFILL';

    SELECT pk_cylinder_state_id INTO v_empty_delivered_state_id
    FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL';

    -- For every supplier_trip_line linked to this SUPPLIER_DROPOFF stop,
    -- transition state and record the actual supplier
    FOR rec IN
        SELECT
            stl.fk_cylinder,
            stl.pk_supplier_trip_line_id,
            st.fk_supplier           AS supplier_id
        FROM public.tbl_supplier_trip_line stl
        JOIN public.tbl_supplier_trip st
            ON st.pk_supplier_trip_id = stl.fk_supplier_trip
        WHERE stl.fk_vehicle_trip_stop = NEW.pk_stop_id
    LOOP
        -- ── State audit ──────────────────────────────────────────────────────
        INSERT INTO public.tbl_cylinder_state_audit (
            pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
            fk_order, changed_at, remarks
        ) VALUES (
            nextval('public.pk_cylinder_state_id_serial'),
            rec.fk_cylinder,
            v_empty_picked_state_id,
            v_empty_delivered_state_id,
            NULL,
            now(),
            'Cylinder handed to supplier at SUPPLIER_DROPOFF stop '
                || NEW.pk_stop_id
                || '. Supplier ID: ' || rec.supplier_id
                || '. Awaiting refill.'
        );

        -- ── Update current status: cylinder is now physically at the supplier ──
        UPDATE public.tbl_cylinder_current_status
        SET fk_current_state        = v_empty_delivered_state_id,
            fk_current_vehicle_trip = NULL,   -- no longer on vehicle
            fk_current_supplier     = rec.supplier_id,  -- NOW we know who has it
            updated_at              = now()
        WHERE fk_cylinder = rec.fk_cylinder;
    END LOOP;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_audit_supplier_dropoff_stop_completed() IS
    'Fires AFTER UPDATE OF stop_status on tbl_vehicle_trip_stop when a '
    'SUPPLIER_DROPOFF stop transitions to COMPLETED. '
    'For all linked supplier_trip_lines: '
    '  EMPTY_PICKED_FOR_REFILL → EMPTY_DELIVERED_FOR_REFILL '
    'Sets fk_current_supplier = the actual supplier receiving the cylinder. '
    'Clears fk_current_vehicle_trip (cylinder is no longer on the vehicle).';


-- =============================================================================
-- PART 5  UPDATE fn_audit_cylinder_refill_collection_after (originally V56 Part 3b)
--         Clear fk_current_supplier when the refilled cylinder is collected back
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_audit_cylinder_refill_collection_after()
RETURNS TRIGGER AS $$
DECLARE
    v_empty_delivered_state_id int8;
    v_full_picked_state_id     int8;
    v_collection_trip_id       int8;
BEGIN
    SELECT pk_cylinder_state_id INTO v_empty_delivered_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL';

    SELECT pk_cylinder_state_id INTO v_full_picked_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'FULL_PICKED_FROM_SUPPLIER';

    -- Get the collection vehicle trip from the header
    SELECT fk_vehicle_trip INTO v_collection_trip_id
    FROM public.tbl_supplier_refill_collection
    WHERE pk_collection_id = NEW.fk_collection;

    -- 1. State audit: EMPTY_DELIVERED_FOR_REFILL → FULL_PICKED_FROM_SUPPLIER
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

    -- 2. Update current status:
    --    Cylinder is now full, on the collection vehicle, heading back to yard.
    --    fk_current_supplier cleared — the supplier no longer holds it.
    UPDATE public.tbl_cylinder_current_status
    SET fk_current_state        = v_full_picked_state_id,
        fk_current_vehicle_trip = v_collection_trip_id,
        fk_current_supplier     = NULL,   -- ← cleared: cylinder leaving supplier
        fk_current_holder_customer = NULL,
        updated_at              = now()
    WHERE fk_cylinder = NEW.fk_cylinder;

    -- 3. Mark the original supplier trip line as collected
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
    'Marks tbl_supplier_trip_line.collected = TRUE.';


-- =============================================================================
-- PART 6  RECREATE vw_overdue_at_supplier using direct fk_current_supplier
--         (replaces the V62 version which joined via fk_last_supplier_trip)
-- =============================================================================

CREATE OR REPLACE VIEW public.vw_overdue_at_supplier AS
SELECT
    c.pk_cylinder_id,
    c.cylinder_serial,
    cs.cylinder_state,
    s.pk_supplier_id,
    s.supplier_name,
    ccs.updated_at                                          AS delivered_to_supplier_at,
    EXTRACT(DAY FROM now() - ccs.updated_at)::int           AS days_at_supplier,
    (SELECT config_value::int
     FROM public.tbl_system_config
     WHERE config_key = 'OVERDUE_SUPPLIER_DAYS')            AS threshold_days,
    -- Last supplier trip for traceability (separate from the current supplier FK)
    ccs.fk_last_supplier_trip
FROM public.tbl_cylinder_current_status ccs
JOIN public.tbl_cylinder c         ON c.pk_cylinder_id        = ccs.fk_cylinder
JOIN public.tbl_cylinder_states cs ON cs.pk_cylinder_state_id = ccs.fk_current_state
JOIN public.tbl_supplier s         ON s.pk_supplier_id         = ccs.fk_current_supplier
WHERE cs.cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL'
  AND ccs.fk_current_supplier IS NOT NULL
  AND ccs.updated_at < now() - (
        (SELECT config_value
         FROM public.tbl_system_config
         WHERE config_key = 'OVERDUE_SUPPLIER_DAYS')
        || ' days'
      )::interval
ORDER BY days_at_supplier DESC;

COMMENT ON VIEW public.vw_overdue_at_supplier IS
    'Cylinders left with a supplier for refill longer than OVERDUE_SUPPLIER_DAYS. '
    'Uses the direct fk_current_supplier column (added in V63) — no join through '
    'fk_last_supplier_trip needed. These should trigger a follow-up with the supplier. '
    'Replaces the V62 version of this view.';


-- =============================================================================
-- PART 7  RECREATE fn_detect_dormant_cylinders using fk_current_supplier
--         (replaces the V62 version which could not populate last_known_supplier_id)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_detect_dormant_cylinders()
RETURNS TABLE (
    cylinder_id     int8,
    cylinder_serial varchar(50),
    last_seen       timestamp,
    dormant_days    int4,
    action          varchar(20)   -- 'RAISED' | 'ALREADY_OPEN' | 'AUTO_RESOLVED'
) AS $$
DECLARE
    v_threshold_days int4;
    rec RECORD;
BEGIN
    SELECT config_value::int4 INTO v_threshold_days
    FROM public.tbl_system_config
    WHERE config_key = 'DORMANCY_THRESHOLD_DAYS';

    v_threshold_days := COALESCE(v_threshold_days, 30);

    -- ── STEP 1: AUTO-RESOLVE alerts where the cylinder has re-appeared ────────
    UPDATE public.tbl_cylinder_dormancy_alert da
    SET alert_status       = 'RESOLVED',
        resolved_at        = now(),
        resolution_remarks = 'Auto-resolved: cylinder re-entered the system'
    FROM (
        SELECT DISTINCT fk_cylinder
        FROM public.tbl_cylinder_state_audit
        WHERE changed_at >= now() - (v_threshold_days || ' days')::interval
    ) recent
    WHERE da.fk_cylinder   = recent.fk_cylinder
      AND da.alert_status IN ('OPEN', 'INVESTIGATING');

    -- ── STEP 2: FIND NEW DORMANT CYLINDERS ───────────────────────────────────
    FOR rec IN
        WITH last_activity AS (
            SELECT fk_cylinder, MAX(changed_at)  AS last_event
            FROM public.tbl_cylinder_state_audit
            GROUP BY fk_cylinder

            UNION ALL

            SELECT cl.fk_cylinder, MAX(cl.scanned_at) AS last_event
            FROM public.tbl_yard_stock_check_line cl
            GROUP BY cl.fk_cylinder
        ),
        latest_per_cylinder AS (
            SELECT fk_cylinder, MAX(last_event) AS last_seen_at
            FROM last_activity
            GROUP BY fk_cylinder
        ),
        dormant AS (
            SELECT
                c.pk_cylinder_id,
                c.cylinder_serial,
                l.last_seen_at,
                EXTRACT(DAY FROM now() - l.last_seen_at)::int4  AS dormant_days,
                ccs.fk_current_state,
                cs.cylinder_state                               AS state_name,
                cs.location                                     AS location_name,
                ccs.fk_current_holder_customer,
                -- Direct supplier FK (V63 addition) — no join needed
                ccs.fk_current_supplier                         AS current_supplier_id
            FROM latest_per_cylinder l
            JOIN public.tbl_cylinder c
                ON c.pk_cylinder_id = l.fk_cylinder
            LEFT JOIN public.tbl_cylinder_current_status ccs
                ON ccs.fk_cylinder = l.fk_cylinder
            LEFT JOIN public.tbl_cylinder_states cs
                ON cs.pk_cylinder_state_id = ccs.fk_current_state
            WHERE l.last_seen_at < now() - (v_threshold_days || ' days')::interval
              -- Exclude terminal states — these do not need dormancy alerts
              AND (cs.cylinder_state IS NULL
                   OR cs.cylinder_state NOT IN ('DECOMISSIONED', 'LOST', 'DAMAGED'))
        )
        SELECT * FROM dormant
    LOOP
        -- Already flagged?
        IF EXISTS (
            SELECT 1 FROM public.tbl_cylinder_dormancy_alert
            WHERE fk_cylinder  = rec.pk_cylinder_id
              AND alert_status IN ('OPEN', 'INVESTIGATING')
        ) THEN
            RETURN QUERY SELECT rec.pk_cylinder_id, rec.cylinder_serial,
                                rec.last_seen_at, rec.dormant_days,
                                'ALREADY_OPEN'::varchar(20);
        ELSE
            -- Raise new alert — now includes last_known_supplier_id from direct FK
            INSERT INTO public.tbl_cylinder_dormancy_alert (
                fk_cylinder,
                last_seen_at,
                dormancy_days,
                last_known_state,
                last_known_location,
                last_known_customer_id,
                last_known_supplier_id    -- populated via V63 fk_current_supplier
            ) VALUES (
                rec.pk_cylinder_id,
                rec.last_seen_at,
                rec.dormant_days,
                COALESCE(rec.state_name,      'UNKNOWN'),
                COALESCE(rec.location_name,   'UNKNOWN'),
                rec.fk_current_holder_customer,
                rec.current_supplier_id       -- direct value — no join needed
            );

            -- Auto-transition to MISSING if not already in a terminal/tracking state
            IF rec.state_name NOT IN ('MISSING', 'LOST', 'DECOMISSIONED') THEN
                INSERT INTO public.tbl_cylinder_state_audit (
                    pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
                    changed_at, remarks
                )
                SELECT
                    nextval('public.pk_cylinder_state_id_serial'),
                    rec.pk_cylinder_id,
                    ccs.fk_current_state,
                    (SELECT pk_cylinder_state_id
                     FROM public.tbl_cylinder_states
                     WHERE cylinder_state = 'MISSING'),
                    now(),
                    'Auto-flagged MISSING after '
                        || rec.dormant_days
                        || ' days without any system activity.'
                FROM public.tbl_cylinder_current_status ccs
                WHERE ccs.fk_cylinder = rec.pk_cylinder_id;
            END IF;

            RETURN QUERY SELECT rec.pk_cylinder_id, rec.cylinder_serial,
                                rec.last_seen_at, rec.dormant_days,
                                'RAISED'::varchar(20);
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_detect_dormant_cylinders() IS
    'Idempotent nightly function. Detects cylinders with no event in > DORMANCY_THRESHOLD_DAYS days. '
    'Updated in V63 to use fk_current_supplier directly (no join through fk_last_supplier_trip). '
    'Auto-resolves alerts for re-appeared cylinders. '
    'Populates last_known_supplier_id in tbl_cylinder_dormancy_alert. '
    'Returns one row per affected cylinder with action taken.';
