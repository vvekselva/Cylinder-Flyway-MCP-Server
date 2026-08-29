-- =============================================================================
-- V75__CylinderCorrection_StateTolerant.sql
-- =============================================================================
--
-- REPLACES the two correction functions introduced in V74 with state-tolerant
-- versions that handle every real-world scenario.
--
-- THE PROBLEM WITH V74
-- ────────────────────
-- V74's functions required:
--   • Wrong cylinder  = DELIVERED_FOR_CONSUMPTION
--   • Correct cylinder = FULL_PICKED_UP_FOR_DELIVERY
--
-- In reality challans reach the office AFTER the vehicle has completed its
-- full route and returned to the yard. By then:
--   • The wrong cylinder may be at a DIFFERENT customer, back at the yard
--     as EMPTY/FULL, or still FULL_PICKED_UP_FOR_DELIVERY on the returned truck.
--   • The correct cylinder may still be FULL_PICKED_UP_FOR_DELIVERY (never
--     unloaded in the system), or may already be EMPTY_IN_TRANSIT / EMPTY /
--     FULL (delivered, consumed, and collected back to yard).
--
-- DESIGN PRINCIPLE
-- ────────────────
-- The correction function always does three things regardless of state:
--   1. Hard-stop only if the order line is already INVOICED.
--   2. Write a tbl_cylinder_correction_log row with a full state snapshot.
--   3. Swap fk_cylinder on the order/pickup line.
--
-- What changes based on CURRENT STATE is how deeply it touches the state
-- machine and custody table. See the decision matrix in each function below.
--
-- WHAT THIS MIGRATION CONTAINS
-- ─────────────────────────────
-- PART 1 — Extend tbl_cylinder_correction_log (add state-snapshot columns)
-- PART 2 — fn_correct_order_line_cylinder    (full replacement)
-- PART 3 — fn_correct_empty_pickup_line_cylinder (full replacement)
-- =============================================================================


-- =============================================================================
-- PART 1  Extend tbl_cylinder_correction_log
--         Add state-at-correction snapshot so the log is self-contained.
-- =============================================================================

ALTER TABLE public.tbl_cylinder_correction_log
    ADD COLUMN IF NOT EXISTS wrong_cyl_state_at_correction  varchar(100) NULL,
    ADD COLUMN IF NOT EXISTS correct_cyl_state_at_correction varchar(100) NULL,
    ADD COLUMN IF NOT EXISTS correction_action_summary       varchar(500) NULL,
    ADD COLUMN IF NOT EXISTS wrong_cyl_holder_customer_at_correction int8 NULL,
    ADD COLUMN IF NOT EXISTS correct_cyl_holder_customer_at_correction int8 NULL;

COMMENT ON COLUMN public.tbl_cylinder_correction_log.wrong_cyl_state_at_correction IS
    'State name of the wrong cylinder at the exact moment the correction was applied.';
COMMENT ON COLUMN public.tbl_cylinder_correction_log.correct_cyl_state_at_correction IS
    'State name of the correct cylinder at the exact moment the correction was applied.';
COMMENT ON COLUMN public.tbl_cylinder_correction_log.correction_action_summary IS
    'Human-readable summary of what the function actually did to the state machine.';


-- =============================================================================
-- PART 2  fn_correct_order_line_cylinder  (full replacement)
-- =============================================================================
--
-- WRONG CYLINDER — decision matrix by current state
-- ┌──────────────────────────────────────────────────┬──────────────────────────────────────────────────────────┐
-- │ Current state of wrong cylinder                  │ Action                                                   │
-- ├──────────────────────────────────────────────────┼──────────────────────────────────────────────────────────┤
-- │ DELIVERED_FOR_CONSUMPTION                        │ Revert → FULL_PICKED_UP_FOR_DELIVERY.                    │
-- │   at THIS order's customer                       │ Update current_status. Close ACTIVE custody for          │
-- │                                                  │ this customer+order combination.                         │
-- ├──────────────────────────────────────────────────┼──────────────────────────────────────────────────────────┤
-- │ DELIVERED_FOR_CONSUMPTION                        │ Note-only audit. The cylinder was separately delivered   │
-- │   at a DIFFERENT customer                        │ there (another challan error or legitimate delivery).    │
-- │                                                  │ Do NOT touch its state or current_status.                │
-- │                                                  │ Close any stale ACTIVE custody tied to THIS order.       │
-- ├──────────────────────────────────────────────────┼──────────────────────────────────────────────────────────┤
-- │ FULL_PICKED_UP_FOR_DELIVERY                      │ Note-only audit. Cylinder never left the vehicle         │
-- │   (still on vehicle / returned with truck)       │ in the system. No state or custody change needed.        │
-- ├──────────────────────────────────────────────────┼──────────────────────────────────────────────────────────┤
-- │ Any other state (EMPTY_IN_TRANSIT, EMPTY,        │ Note-only audit. Physical events have already            │
-- │ FULL, EMPTY_PICKED_FOR_REFILL, etc.)             │ progressed past this point. Do NOT intervene.            │
-- └──────────────────────────────────────────────────┴──────────────────────────────────────────────────────────┘
--
-- CORRECT CYLINDER — decision matrix by current state
-- ┌──────────────────────────────────────────────────┬──────────────────────────────────────────────────────────┐
-- │ Current state of correct cylinder                │ Action                                                   │
-- ├──────────────────────────────────────────────────┼──────────────────────────────────────────────────────────┤
-- │ FULL_PICKED_UP_FOR_DELIVERY                      │ Standard path. Transition →                              │
-- │   (still on vehicle / returned with truck)       │ DELIVERED_FOR_CONSUMPTION. Update current_status.        │
-- │                                                  │ Open ACTIVE custody record for this customer.            │
-- ├──────────────────────────────────────────────────┼──────────────────────────────────────────────────────────┤
-- │ DELIVERED_FOR_CONSUMPTION                        │ State already correct. Note-only audit.                  │
-- │   at THIS order's customer                       │ Ensure ACTIVE custody record exists (insert if missing). │
-- ├──────────────────────────────────────────────────┼──────────────────────────────────────────────────────────┤
-- │ DELIVERED_FOR_CONSUMPTION                        │ Retroactive note audit. The cylinder shows delivered     │
-- │   at a DIFFERENT customer                        │ elsewhere (concurrent challan error). Do NOT disturb     │
-- │                                                  │ that delivery. Insert a CLOSED retroactive custody row   │
-- │                                                  │ to record this order's delivery event historically.      │
-- ├──────────────────────────────────────────────────┼──────────────────────────────────────────────────────────┤
-- │ Any other state (EMPTY_IN_TRANSIT, EMPTY,        │ Retroactive delivery. Insert audit row noting this was   │
-- │ FULL, etc.)                                      │ actually delivered but recording is late. Do NOT change  │
-- │                                                  │ current_status. Insert a CLOSED retroactive custody row. │
-- └──────────────────────────────────────────────────┴──────────────────────────────────────────────────────────┘
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_correct_order_line_cylinder(
    p_order_line_id  int8,
    p_wrong_cyl_id   int8,
    p_correct_cyl_id int8,
    p_reason         varchar(500),
    p_corrected_by   varchar(200)
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    -- State IDs
    v_delivered_state_id        int8;
    v_picked_up_state_id        int8;

    -- Order line context
    v_order_id                  int8;
    v_order_customer_id         int8;
    v_delivery_address_id       int8;
    v_is_invoiced               bool;

    -- Wrong cylinder
    v_wrong_state_id            int8;
    v_wrong_state_name          varchar(100);
    v_wrong_holder_customer     int8;

    -- Correct cylinder
    v_correct_state_id          int8;
    v_correct_state_name        varchar(100);
    v_correct_holder_customer   int8;

    -- Vehicle load (for information — no longer a hard gate)
    v_wrong_load_id             int8;
    v_correct_load_id           int8;
    v_same_load                 bool := false;

    -- Action summary built up during execution
    v_action_summary            varchar(500) := '';
BEGIN
    -- ── 1. Resolve the two state IDs we will reference most ─────────────────
    SELECT pk_cylinder_state_id INTO v_delivered_state_id
    FROM   public.tbl_cylinder_states
    WHERE  cylinder_state = 'DELIVERED_FOR_CONSUMPTION';

    SELECT pk_cylinder_state_id INTO v_picked_up_state_id
    FROM   public.tbl_cylinder_states
    WHERE  cylinder_state = 'FULL_PICKED_UP_FOR_DELIVERY';

    -- ── 2. Fetch the order line ──────────────────────────────────────────────
    SELECT ol.fk_order,
           ol.is_invoiced,
           COALESCE(ol.fk_delivery_address, o.fk_delivery_address),
           o.fk_customer
    INTO   v_order_id, v_is_invoiced, v_delivery_address_id, v_order_customer_id
    FROM   public.tbl_order_line ol
    JOIN   public.tbl_order      o  ON o.pk_order_id = ol.fk_order
    WHERE  ol.pk_order_line_id = p_order_line_id
      AND  ol.fk_cylinder      = p_wrong_cyl_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Correction Failed: order_line % does not exist or fk_cylinder '
            'is not the declared wrong cylinder (id=%).',
            p_order_line_id, p_wrong_cyl_id;
    END IF;

    -- ── 3. HARD STOP — invoiced lines cannot be corrected ───────────────────
    IF v_is_invoiced THEN
        RAISE EXCEPTION
            'Correction Failed: order_line % is already invoiced. '
            'Raise a credit note / replacement invoice instead.',
            p_order_line_id;
    END IF;

    -- ── 4. Snapshot current state of both cylinders ──────────────────────────
    SELECT ccs.fk_current_state,
           cs.cylinder_state,
           ccs.fk_current_holder_customer
    INTO   v_wrong_state_id, v_wrong_state_name, v_wrong_holder_customer
    FROM   public.tbl_cylinder_current_status ccs
    JOIN   public.tbl_cylinder_states cs
           ON cs.pk_cylinder_state_id = ccs.fk_current_state
    WHERE  ccs.fk_cylinder = p_wrong_cyl_id;

    SELECT ccs.fk_current_state,
           cs.cylinder_state,
           ccs.fk_current_holder_customer
    INTO   v_correct_state_id, v_correct_state_name, v_correct_holder_customer
    FROM   public.tbl_cylinder_current_status ccs
    JOIN   public.tbl_cylinder_states cs
           ON cs.pk_cylinder_state_id = ccs.fk_current_state
    WHERE  ccs.fk_cylinder = p_correct_cyl_id;

    -- ── 5. Check same vehicle load (informational — no longer a hard gate) ───
    SELECT fk_vehicle_load INTO v_wrong_load_id
    FROM   public.tbl_vehicle_load_line
    WHERE  fk_cylinder = p_wrong_cyl_id
    ORDER  BY pk_vehicle_load_line_id DESC
    LIMIT  1;

    SELECT fk_vehicle_load INTO v_correct_load_id
    FROM   public.tbl_vehicle_load_line
    WHERE  fk_cylinder = p_correct_cyl_id
    ORDER  BY pk_vehicle_load_line_id DESC
    LIMIT  1;

    v_same_load := (v_wrong_load_id IS NOT NULL
                    AND v_correct_load_id IS NOT NULL
                    AND v_wrong_load_id = v_correct_load_id);

    -- ── 6. Swap fk_cylinder on the order line  ───────────────────────────────
    --    Do this BEFORE the audit rows so the line is consistent if anything
    --    later raises an exception.
    UPDATE public.tbl_order_line
    SET    fk_cylinder = p_correct_cyl_id
    WHERE  pk_order_line_id = p_order_line_id;

    -- ═══════════════════════════════════════════════════════════════════════
    -- ── 7. WRONG CYLINDER — state-aware handling ────────────────────────────
    -- ═══════════════════════════════════════════════════════════════════════

    IF v_wrong_state_id = v_delivered_state_id
       AND v_wrong_holder_customer = v_order_customer_id
    THEN
        -- ── Case W-1: Wrongly delivered to THIS customer — full revert ───────
        -- The order_line INSERT was the sole event that caused DELIVERED state.
        -- Reverting is safe.
        INSERT INTO public.tbl_cylinder_state_audit (
            pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
            fk_order, changed_at, remarks
        ) VALUES (
            nextval('public.pk_cylinder_state_id_serial'),
            p_wrong_cyl_id,
            v_delivered_state_id,           -- was: DELIVERED_FOR_CONSUMPTION
            v_picked_up_state_id,           -- back to: FULL_PICKED_UP_FOR_DELIVERY
            v_order_id,
            now(),
            '[CORRECTION-REVERT] Wrong cylinder reverted from DELIVERED_FOR_CONSUMPTION '
                || 'back to FULL_PICKED_UP_FOR_DELIVERY. '
                || 'Was incorrectly recorded on order_line ' || p_order_line_id
                || ' for customer ' || v_order_customer_id || '. '
                || 'Replaced by cylinder ' || p_correct_cyl_id || '. '
                || 'Reason: ' || p_reason
        );

        UPDATE public.tbl_cylinder_current_status
        SET    fk_current_state            = v_picked_up_state_id,
               fk_current_holder_customer  = NULL,
               fk_current_customer_address = NULL,
               fk_current_vehicle_load     = v_wrong_load_id,   -- back to vehicle
               fk_last_order               = v_order_id,
               updated_at                  = now()
        WHERE  fk_cylinder = p_wrong_cyl_id;

        -- Close the stale custody record that was opened by the wrong delivery
        UPDATE public.tbl_cylinder_party_custody
        SET    exit_event_type  = 'CORRECTION',
               exited_at        = now(),
               custody_status   = 'CLOSED',
               remarks          = '[CORRECTION] Delivery of cylinder ' || p_wrong_cyl_id
                                      || ' on order_line ' || p_order_line_id
                                      || ' was a manual challan error. '
                                      || 'Correct cylinder: ' || p_correct_cyl_id
        WHERE  fk_cylinder     = p_wrong_cyl_id
          AND  custody_status  = 'ACTIVE'
          AND  party_type      = 'CUSTOMER'
          AND  fk_entry_order  = v_order_id;

        v_action_summary := v_action_summary
            || 'WRONG: Reverted DELIVERED→FULL_PICKED_UP, custody closed. ';

    ELSIF v_wrong_state_id = v_delivered_state_id
          AND (v_wrong_holder_customer IS DISTINCT FROM v_order_customer_id)
    THEN
        -- ── Case W-2: DELIVERED but at a DIFFERENT customer ──────────────────
        -- The wrong cylinder was recorded here AND separately delivered
        -- somewhere else (another challan error, or an unrelated delivery).
        -- Do NOT touch its state — that delivery is potentially real.
        -- Just note the correction.
        INSERT INTO public.tbl_cylinder_state_audit (
            pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
            fk_order, changed_at, remarks
        ) VALUES (
            nextval('public.pk_cylinder_state_id_serial'),
            p_wrong_cyl_id,
            v_wrong_state_id,               -- unchanged from
            v_wrong_state_id,               -- unchanged to
            v_order_id,
            now(),
            '[CORRECTION-NOTE] Wrong cylinder was incorrectly entered on order_line '
                || p_order_line_id || ' (customer ' || v_order_customer_id || '). '
                || 'Cylinder is currently DELIVERED at a different customer ('
                || COALESCE(v_wrong_holder_customer::text, 'NULL') || '). '
                || 'State NOT changed — that delivery may be legitimate. '
                || 'Correct cylinder: ' || p_correct_cyl_id || '. Reason: ' || p_reason
        );

        -- Close any stale ACTIVE custody that was specifically tied to THIS order
        UPDATE public.tbl_cylinder_party_custody
        SET    exit_event_type  = 'CORRECTION',
               exited_at        = now(),
               custody_status   = 'CLOSED',
               remarks          = '[CORRECTION] Stale custody from incorrect order_line '
                                      || p_order_line_id || '. Cylinder is now at another customer.'
        WHERE  fk_cylinder     = p_wrong_cyl_id
          AND  custody_status  = 'ACTIVE'
          AND  fk_entry_order  = v_order_id;

        v_action_summary := v_action_summary
            || 'WRONG: DELIVERED at different customer — note-only, state preserved. ';

    ELSIF v_wrong_state_id = v_picked_up_state_id THEN
        -- ── Case W-3: Still FULL_PICKED_UP_FOR_DELIVERY (on/with vehicle) ────
        -- The cylinder was never recorded as delivered anywhere; challan just
        -- had the wrong serial. The state is already correct.
        INSERT INTO public.tbl_cylinder_state_audit (
            pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
            fk_order, changed_at, remarks
        ) VALUES (
            nextval('public.pk_cylinder_state_id_serial'),
            p_wrong_cyl_id,
            v_wrong_state_id,
            v_wrong_state_id,
            v_order_id,
            now(),
            '[CORRECTION-NOTE] Wrong cylinder was entered on order_line '
                || p_order_line_id || ' but is still FULL_PICKED_UP_FOR_DELIVERY '
                || '(never recorded as delivered). No state change needed. '
                || 'Correct cylinder: ' || p_correct_cyl_id || '. Reason: ' || p_reason
        );

        v_action_summary := v_action_summary
            || 'WRONG: FULL_PICKED_UP — note-only, already correct state. ';

    ELSE
        -- ── Case W-4: Any other state (EMPTY_IN_TRANSIT, EMPTY, FULL…) ───────
        -- Physical lifecycle has already moved on past the delivery stage.
        -- Do NOT reverse — the cylinder may genuinely be in transit or back at yard.
        INSERT INTO public.tbl_cylinder_state_audit (
            pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
            fk_order, changed_at, remarks
        ) VALUES (
            nextval('public.pk_cylinder_state_id_serial'),
            p_wrong_cyl_id,
            v_wrong_state_id,
            v_wrong_state_id,
            v_order_id,
            now(),
            '[CORRECTION-NOTE] Wrong cylinder was entered on order_line '
                || p_order_line_id || '. Current state is ' || COALESCE(v_wrong_state_name, 'UNKNOWN')
                || ' — physical events have already progressed. State NOT changed. '
                || 'Correct cylinder: ' || p_correct_cyl_id || '. Reason: ' || p_reason
        );

        v_action_summary := v_action_summary
            || 'WRONG: State=' || COALESCE(v_wrong_state_name,'?') || ' — note-only, events progressed. ';
    END IF;

    -- ═══════════════════════════════════════════════════════════════════════
    -- ── 8. CORRECT CYLINDER — state-aware handling ──────────────────────────
    -- ═══════════════════════════════════════════════════════════════════════

    IF v_correct_state_id = v_picked_up_state_id THEN
        -- ── Case C-1: Still FULL_PICKED_UP_FOR_DELIVERY — standard path ──────
        INSERT INTO public.tbl_cylinder_state_audit (
            pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
            fk_order, changed_at, remarks
        ) VALUES (
            nextval('public.pk_cylinder_state_id_serial'),
            p_correct_cyl_id,
            v_picked_up_state_id,
            v_delivered_state_id,
            v_order_id,
            now(),
            '[CORRECTION] Correct cylinder confirmed as actually delivered on order_line '
                || p_order_line_id || ' to customer ' || v_order_customer_id || '. '
                || 'Replaced wrong cylinder ' || p_wrong_cyl_id || '. Reason: ' || p_reason
        );

        UPDATE public.tbl_cylinder_current_status
        SET    fk_current_state             = v_delivered_state_id,
               fk_current_holder_customer   = v_order_customer_id,
               fk_current_customer_address  = v_delivery_address_id,
               fk_current_vehicle_load      = NULL,
               fk_last_order                = v_order_id,
               updated_at                   = now()
        WHERE  fk_cylinder = p_correct_cyl_id;

        -- Open ACTIVE custody
        INSERT INTO public.tbl_cylinder_party_custody (
            fk_cylinder, party_type, fk_customer, fk_customer_address,
            entry_event_type, fk_entry_order, entered_at, custody_status
        ) VALUES (
            p_correct_cyl_id, 'CUSTOMER', v_order_customer_id, v_delivery_address_id,
            'ORDER_DELIVERY', v_order_id, now(), 'ACTIVE'
        );

        v_action_summary := v_action_summary
            || 'CORRECT: FULL_PICKED_UP→DELIVERED, current_status+custody opened. ';

    ELSIF v_correct_state_id = v_delivered_state_id
          AND v_correct_holder_customer = v_order_customer_id
    THEN
        -- ── Case C-2: Already DELIVERED at THIS customer — state already right ─
        INSERT INTO public.tbl_cylinder_state_audit (
            pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
            fk_order, changed_at, remarks
        ) VALUES (
            nextval('public.pk_cylinder_state_id_serial'),
            p_correct_cyl_id,
            v_delivered_state_id,
            v_delivered_state_id,
            v_order_id,
            now(),
            '[CORRECTION-NOTE] Correct cylinder already shows DELIVERED_FOR_CONSUMPTION '
                || 'at this customer (' || v_order_customer_id || '). '
                || 'State confirmed correct. order_line ' || p_order_line_id
                || ' updated. Reason: ' || p_reason
        );

        -- Ensure an ACTIVE custody record exists (may have been missed)
        INSERT INTO public.tbl_cylinder_party_custody (
            fk_cylinder, party_type, fk_customer, fk_customer_address,
            entry_event_type, fk_entry_order, entered_at, custody_status
        )
        SELECT p_correct_cyl_id, 'CUSTOMER', v_order_customer_id, v_delivery_address_id,
               'ORDER_DELIVERY', v_order_id, now(), 'ACTIVE'
        WHERE NOT EXISTS (
            SELECT 1 FROM public.tbl_cylinder_party_custody
            WHERE  fk_cylinder    = p_correct_cyl_id
              AND  fk_entry_order = v_order_id
              AND  custody_status = 'ACTIVE'
        );

        v_action_summary := v_action_summary
            || 'CORRECT: Already DELIVERED at this customer — note-only, custody ensured. ';

    ELSIF v_correct_state_id = v_delivered_state_id
          AND (v_correct_holder_customer IS DISTINCT FROM v_order_customer_id)
    THEN
        -- ── Case C-3: DELIVERED at a DIFFERENT customer ───────────────────────
        -- The correct cylinder has since been delivered to someone else
        -- (another trip/challan). Do NOT disturb that delivery.
        -- Record this order's delivery event retroactively as a CLOSED custody row.
        INSERT INTO public.tbl_cylinder_state_audit (
            pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
            fk_order, changed_at, remarks
        ) VALUES (
            nextval('public.pk_cylinder_state_id_serial'),
            p_correct_cyl_id,
            v_picked_up_state_id,           -- logical from-state at time of original delivery
            v_delivered_state_id,
            v_order_id,
            now(),
            '[CORRECTION-RETROACTIVE] Correct cylinder was actually delivered on order_line '
                || p_order_line_id || ' to customer ' || v_order_customer_id
                || ' but is now DELIVERED at a different customer ('
                || COALESCE(v_correct_holder_customer::text, 'NULL') || '). '
                || 'Retroactive delivery note. Current state NOT changed. '
                || 'Reason: ' || p_reason
        );

        -- Retroactive CLOSED custody — the cylinder was here and has since left
        INSERT INTO public.tbl_cylinder_party_custody (
            fk_cylinder, party_type, fk_customer, fk_customer_address,
            entry_event_type, fk_entry_order, entered_at,
            exit_event_type, exited_at, custody_status, remarks
        ) VALUES (
            p_correct_cyl_id, 'CUSTOMER', v_order_customer_id, v_delivery_address_id,
            'ORDER_DELIVERY', v_order_id, now(),
            'CORRECTION', now(), 'CLOSED',
            '[RETROACTIVE] Cylinder was delivered here but is now at another customer. '
                || 'Exit time is approximate (recorded at correction time).'
        );

        v_action_summary := v_action_summary
            || 'CORRECT: DELIVERED at different customer — retroactive note, current_status preserved. ';

    ELSE
        -- ── Case C-4: EMPTY_IN_TRANSIT / EMPTY / FULL / etc. ─────────────────
        -- Cylinder was delivered, consumed, picked up, and has returned.
        -- Recording the delivery retroactively — audit trail only.
        -- Do NOT change current_status (it's already past DELIVERED stage).
        INSERT INTO public.tbl_cylinder_state_audit (
            pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
            fk_order, changed_at, remarks
        ) VALUES (
            nextval('public.pk_cylinder_state_id_serial'),
            p_correct_cyl_id,
            v_picked_up_state_id,
            v_delivered_state_id,
            v_order_id,
            now(),
            '[CORRECTION-RETROACTIVE] Correct cylinder was actually delivered on order_line '
                || p_order_line_id || ' to customer ' || v_order_customer_id
                || '. Current state is ' || COALESCE(v_correct_state_name, 'UNKNOWN')
                || ' — physical lifecycle has progressed. Retroactive delivery recorded. '
                || 'current_status NOT changed. Reason: ' || p_reason
        );

        -- Retroactive CLOSED custody (cylinder came and went)
        INSERT INTO public.tbl_cylinder_party_custody (
            fk_cylinder, party_type, fk_customer, fk_customer_address,
            entry_event_type, fk_entry_order, entered_at,
            exit_event_type, exited_at, custody_status, remarks
        ) VALUES (
            p_correct_cyl_id, 'CUSTOMER', v_order_customer_id, v_delivery_address_id,
            'ORDER_DELIVERY', v_order_id, now(),
            'CORRECTION', now(), 'CLOSED',
            '[RETROACTIVE] Cylinder was delivered here; it has since returned to yard. '
                || 'Entry/exit times approximate. Current state: '
                || COALESCE(v_correct_state_name, 'UNKNOWN')
        );

        v_action_summary := v_action_summary
            || 'CORRECT: State=' || COALESCE(v_correct_state_name,'?')
            || ' — retroactive delivery note, custody closed. ';
    END IF;

    -- ── 9. Write the correction log row (with full state snapshot) ───────────
    INSERT INTO public.tbl_cylinder_correction_log (
        correction_context,
        fk_order_line,
        fk_wrong_cylinder,
        fk_correct_cylinder,
        wrong_cyl_state_at_correction,
        correct_cyl_state_at_correction,
        wrong_cyl_holder_customer_at_correction,
        correct_cyl_holder_customer_at_correction,
        reason,
        corrected_by,
        correction_status,
        correction_action_summary
    ) VALUES (
        'ORDER_LINE',
        p_order_line_id,
        p_wrong_cyl_id,
        p_correct_cyl_id,
        COALESCE(v_wrong_state_name,  'UNKNOWN — not in current_status'),
        COALESCE(v_correct_state_name,'UNKNOWN — not in current_status'),
        v_wrong_holder_customer,
        v_correct_holder_customer,
        p_reason,
        p_corrected_by,
        'APPLIED',
        v_action_summary
    );

END;
$$;

COMMENT ON FUNCTION public.fn_correct_order_line_cylinder(int8,int8,int8,varchar,varchar) IS
    'State-tolerant correction of a wrongly recorded cylinder serial on a delivery order line. '
    'Only hard stop: is_invoiced = true. '
    'Handles all real-world states: wrong cyl may be at same customer, different customer, '
    'still on vehicle, or already back at yard. Correct cyl may be on vehicle, at customer, '
    'or already returned. '
    'Always writes tbl_cylinder_correction_log + tbl_cylinder_state_audit for both cylinders '
    'and swaps fk_cylinder on tbl_order_line. '
    'State machine and custody changes scale with actual current state. '
    'Replaces the V74 version which required strict state preconditions.';


-- =============================================================================
-- PART 3  fn_correct_empty_pickup_line_cylinder  (full replacement)
-- =============================================================================
--
-- Same state-tolerant design for empty pickup corrections.
--
-- A pickup line correction means: the challan recorded C609 was collected as
-- empty from Customer A, but actually C906 was the one physically collected.
--
-- WRONG cylinder (incorrectly recorded as picked up):
-- ┌──────────────────────────────────────┬──────────────────────────────────────────────────────┐
-- │ Current state                        │ Action                                               │
-- ├──────────────────────────────────────┼──────────────────────────────────────────────────────┤
-- │ EMPTY_IN_TRANSIT_TO_YARD             │ Revert → DELIVERED_FOR_CONSUMPTION at pickup customer.│
-- │ (still in transit)                   │ Update current_status. Reopen custody record.         │
-- ├──────────────────────────────────────┼──────────────────────────────────────────────────────┤
-- │ DELIVERED_FOR_CONSUMPTION            │ Cylinder never left customer — note-only.             │
-- │ at pickup customer                   │ No state change. Custody stays ACTIVE.                │
-- ├──────────────────────────────────────┼──────────────────────────────────────────────────────┤
-- │ EMPTY / FULL / any yard state        │ Physical events progressed. Note-only audit.          │
-- └──────────────────────────────────────┴──────────────────────────────────────────────────────┘
--
-- CORRECT cylinder (actually collected empty):
-- ┌──────────────────────────────────────┬──────────────────────────────────────────────────────┐
-- │ Current state                        │ Action                                               │
-- ├──────────────────────────────────────┼──────────────────────────────────────────────────────┤
-- │ DELIVERED_FOR_CONSUMPTION            │ Standard path. Transition →                          │
-- │ at pickup customer                   │ EMPTY_IN_TRANSIT_TO_YARD. Update current_status.     │
-- │                                      │ Close custody record.                                │
-- ├──────────────────────────────────────┼──────────────────────────────────────────────────────┤
-- │ DELIVERED_FOR_CONSUMPTION            │ Retroactive note. Cylinder at different customer.     │
-- │ at DIFFERENT customer                │ Do not disturb. Add retroactive CLOSED custody row.  │
-- ├──────────────────────────────────────┼──────────────────────────────────────────────────────┤
-- │ EMPTY_IN_TRANSIT_TO_YARD             │ State already correct (already being picked up        │
-- │                                      │ from somewhere). Note-only.                          │
-- ├──────────────────────────────────────┼──────────────────────────────────────────────────────┤
-- │ EMPTY / FULL / any yard state        │ Retroactive pickup note. DO NOT change current_status.│
-- │                                      │ Insert CLOSED retroactive custody row.               │
-- └──────────────────────────────────────┴──────────────────────────────────────────────────────┘
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_correct_empty_pickup_line_cylinder(
    p_pickup_line_id int8,
    p_wrong_cyl_id   int8,
    p_correct_cyl_id int8,
    p_reason         varchar(500),
    p_corrected_by   varchar(200)
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_delivered_state_id        int8;
    v_empty_transit_state_id    int8;

    -- Pickup context
    v_pickup_id                 int8;
    v_pickup_customer_id        int8;
    v_pickup_address_id         int8;
    v_is_invoiced               bool;

    -- Wrong cylinder
    v_wrong_state_id            int8;
    v_wrong_state_name          varchar(100);
    v_wrong_holder_customer     int8;

    -- Correct cylinder
    v_correct_state_id          int8;
    v_correct_state_name        varchar(100);
    v_correct_holder_customer   int8;

    v_action_summary            varchar(500) := '';
BEGIN
    -- ── 1. Resolve state IDs ─────────────────────────────────────────────────
    SELECT pk_cylinder_state_id INTO v_delivered_state_id
    FROM   public.tbl_cylinder_states
    WHERE  cylinder_state = 'DELIVERED_FOR_CONSUMPTION';

    SELECT pk_cylinder_state_id INTO v_empty_transit_state_id
    FROM   public.tbl_cylinder_states
    WHERE  cylinder_state = 'EMPTY_IN_TRANSIT_TO_YARD';

    -- ── 2. Fetch the pickup line ──────────────────────────────────────────────
    SELECT epl.fk_empty_pickup,
           epl.is_invoiced,
           ep.fk_customer,
           ep.fk_pickup_address
    INTO   v_pickup_id, v_is_invoiced, v_pickup_customer_id, v_pickup_address_id
    FROM   public.tbl_empty_pickup_line epl
    JOIN   public.tbl_empty_pickup      ep ON ep.pk_pickup_id = epl.fk_empty_pickup
    WHERE  epl.pk_pickup_line_id = p_pickup_line_id
      AND  epl.fk_cylinder       = p_wrong_cyl_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Correction Failed: pickup_line % does not exist or fk_cylinder '
            'is not the declared wrong cylinder (id=%).',
            p_pickup_line_id, p_wrong_cyl_id;
    END IF;

    -- ── 3. HARD STOP — invoiced ───────────────────────────────────────────────
    IF v_is_invoiced THEN
        RAISE EXCEPTION
            'Correction Failed: pickup_line % is already invoiced.',
            p_pickup_line_id;
    END IF;

    -- ── 4. Snapshot states ────────────────────────────────────────────────────
    SELECT ccs.fk_current_state,
           cs.cylinder_state,
           ccs.fk_current_holder_customer
    INTO   v_wrong_state_id, v_wrong_state_name, v_wrong_holder_customer
    FROM   public.tbl_cylinder_current_status ccs
    JOIN   public.tbl_cylinder_states cs
           ON cs.pk_cylinder_state_id = ccs.fk_current_state
    WHERE  ccs.fk_cylinder = p_wrong_cyl_id;

    SELECT ccs.fk_current_state,
           cs.cylinder_state,
           ccs.fk_current_holder_customer
    INTO   v_correct_state_id, v_correct_state_name, v_correct_holder_customer
    FROM   public.tbl_cylinder_current_status ccs
    JOIN   public.tbl_cylinder_states cs
           ON cs.pk_cylinder_state_id = ccs.fk_current_state
    WHERE  ccs.fk_cylinder = p_correct_cyl_id;

    -- ── 5. Swap fk_cylinder on the pickup line ────────────────────────────────
    UPDATE public.tbl_empty_pickup_line
    SET    fk_cylinder = p_correct_cyl_id
    WHERE  pk_pickup_line_id = p_pickup_line_id;

    -- ═══════════════════════════════════════════════════════════════════════
    -- ── 6. WRONG CYLINDER — state-aware handling ────────────────────────────
    -- ═══════════════════════════════════════════════════════════════════════

    IF v_wrong_state_id = v_empty_transit_state_id THEN
        -- ── Case W-1: Still EMPTY_IN_TRANSIT — revert to DELIVERED ────────────
        INSERT INTO public.tbl_cylinder_state_audit (
            pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
            fk_order, changed_at, remarks
        ) VALUES (
            nextval('public.pk_cylinder_state_id_serial'),
            p_wrong_cyl_id,
            v_empty_transit_state_id,
            v_delivered_state_id,
            NULL,
            now(),
            '[CORRECTION-REVERT] Wrong cylinder reverted from EMPTY_IN_TRANSIT_TO_YARD '
                || 'back to DELIVERED_FOR_CONSUMPTION. '
                || 'Was incorrectly recorded on pickup_line ' || p_pickup_line_id
                || ' for customer ' || v_pickup_customer_id || '. '
                || 'Replaced by cylinder ' || p_correct_cyl_id || '. Reason: ' || p_reason
        );

        UPDATE public.tbl_cylinder_current_status
        SET    fk_current_state             = v_delivered_state_id,
               fk_current_holder_customer   = v_pickup_customer_id,
               fk_current_customer_address  = v_pickup_address_id,
               fk_current_vehicle_load      = NULL,
               updated_at                   = now()
        WHERE  fk_cylinder = p_wrong_cyl_id;

        -- Reopen the custody record (undo the close the pickup trigger did)
        UPDATE public.tbl_cylinder_party_custody
        SET    exit_event_type         = NULL,
               fk_exit_empty_pickup   = NULL,
               exited_at              = NULL,
               custody_status         = 'ACTIVE',
               remarks                = '[CORRECTION] Pickup of cylinder ' || p_wrong_cyl_id
                                            || ' on pickup_line ' || p_pickup_line_id
                                            || ' was a challan error. Custody reopened. '
                                            || 'Correct cylinder: ' || p_correct_cyl_id
        WHERE  fk_cylinder             = p_wrong_cyl_id
          AND  custody_status          = 'CLOSED'
          AND  party_type              = 'CUSTOMER'
          AND  fk_exit_empty_pickup    = v_pickup_id;

        v_action_summary := v_action_summary
            || 'WRONG: Reverted EMPTY_IN_TRANSIT→DELIVERED, custody reopened. ';

    ELSIF v_wrong_state_id = v_delivered_state_id
          AND v_wrong_holder_customer = v_pickup_customer_id
    THEN
        -- ── Case W-2: Still DELIVERED at pickup customer ───────────────────────
        -- The pickup trigger may not have fired yet or was deferred.
        -- Cylinder is still at this customer — note only.
        INSERT INTO public.tbl_cylinder_state_audit (
            pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
            fk_order, changed_at, remarks
        ) VALUES (
            nextval('public.pk_cylinder_state_id_serial'),
            p_wrong_cyl_id, v_wrong_state_id, v_wrong_state_id, NULL, now(),
            '[CORRECTION-NOTE] Wrong cylinder still DELIVERED at pickup customer '
                || v_pickup_customer_id || '. Not yet collected. '
                || 'pickup_line ' || p_pickup_line_id || ' corrected. '
                || 'Correct cylinder: ' || p_correct_cyl_id || '. Reason: ' || p_reason
        );

        v_action_summary := v_action_summary
            || 'WRONG: Still DELIVERED at same customer — note-only, state fine. ';

    ELSE
        -- ── Case W-3: Any other state (EMPTY, FULL, at different customer…) ───
        INSERT INTO public.tbl_cylinder_state_audit (
            pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
            fk_order, changed_at, remarks
        ) VALUES (
            nextval('public.pk_cylinder_state_id_serial'),
            p_wrong_cyl_id, v_wrong_state_id, v_wrong_state_id, NULL, now(),
            '[CORRECTION-NOTE] Wrong cylinder on pickup_line ' || p_pickup_line_id
                || '. Current state: ' || COALESCE(v_wrong_state_name,'UNKNOWN')
                || '. Physical events progressed. State NOT changed. '
                || 'Correct cylinder: ' || p_correct_cyl_id || '. Reason: ' || p_reason
        );

        v_action_summary := v_action_summary
            || 'WRONG: State=' || COALESCE(v_wrong_state_name,'?') || ' — note-only. ';
    END IF;

    -- ═══════════════════════════════════════════════════════════════════════
    -- ── 7. CORRECT CYLINDER — state-aware handling ──────────────────────────
    -- ═══════════════════════════════════════════════════════════════════════

    IF v_correct_state_id = v_delivered_state_id
       AND v_correct_holder_customer = v_pickup_customer_id
    THEN
        -- ── Case C-1: DELIVERED at pickup customer — standard path ─────────────
        INSERT INTO public.tbl_cylinder_state_audit (
            pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
            fk_order, changed_at, remarks
        ) VALUES (
            nextval('public.pk_cylinder_state_id_serial'),
            p_correct_cyl_id,
            v_delivered_state_id,
            v_empty_transit_state_id,
            NULL,
            now(),
            '[CORRECTION] Correct cylinder confirmed as actually collected on pickup_line '
                || p_pickup_line_id || ' from customer ' || v_pickup_customer_id || '. '
                || 'Replaced wrong cylinder ' || p_wrong_cyl_id || '. Reason: ' || p_reason
        );

        UPDATE public.tbl_cylinder_current_status
        SET    fk_current_state             = v_empty_transit_state_id,
               fk_current_holder_customer   = NULL,
               fk_current_customer_address  = NULL,
               fk_current_vehicle_load      = NULL,
               updated_at                   = now()
        WHERE  fk_cylinder = p_correct_cyl_id;

        -- Close the custody record for the correct cylinder
        UPDATE public.tbl_cylinder_party_custody
        SET    exit_event_type       = 'EMPTY_PICKUP',
               fk_exit_empty_pickup  = v_pickup_id,
               exited_at             = now(),
               custody_status        = 'CLOSED'
        WHERE  fk_cylinder     = p_correct_cyl_id
          AND  custody_status  = 'ACTIVE'
          AND  party_type      = 'CUSTOMER';

        v_action_summary := v_action_summary
            || 'CORRECT: DELIVERED→EMPTY_IN_TRANSIT, current_status updated, custody closed. ';

    ELSIF v_correct_state_id = v_empty_transit_state_id THEN
        -- ── Case C-2: Already EMPTY_IN_TRANSIT — state already correct ─────────
        INSERT INTO public.tbl_cylinder_state_audit (
            pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
            fk_order, changed_at, remarks
        ) VALUES (
            nextval('public.pk_cylinder_state_id_serial'),
            p_correct_cyl_id, v_empty_transit_state_id, v_empty_transit_state_id, NULL, now(),
            '[CORRECTION-NOTE] Correct cylinder already in EMPTY_IN_TRANSIT_TO_YARD. '
                || 'State confirmed correct. pickup_line ' || p_pickup_line_id || ' updated. '
                || 'Reason: ' || p_reason
        );

        v_action_summary := v_action_summary
            || 'CORRECT: Already EMPTY_IN_TRANSIT — note-only. ';

    ELSIF v_correct_state_id = v_delivered_state_id
          AND (v_correct_holder_customer IS DISTINCT FROM v_pickup_customer_id)
    THEN
        -- ── Case C-3: DELIVERED at a DIFFERENT customer ────────────────────────
        INSERT INTO public.tbl_cylinder_state_audit (
            pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
            fk_order, changed_at, remarks
        ) VALUES (
            nextval('public.pk_cylinder_state_id_serial'),
            p_correct_cyl_id, v_delivered_state_id, v_empty_transit_state_id, NULL, now(),
            '[CORRECTION-RETROACTIVE] Correct cylinder was actually collected from customer '
                || v_pickup_customer_id || ' on pickup_line ' || p_pickup_line_id
                || ' but is now DELIVERED at customer '
                || COALESCE(v_correct_holder_customer::text,'NULL')
                || '. Retroactive note. Current state NOT changed. Reason: ' || p_reason
        );

        -- Retroactive CLOSED custody (cylinder was at this customer and left)
        INSERT INTO public.tbl_cylinder_party_custody (
            fk_cylinder, party_type, fk_customer, fk_customer_address,
            entry_event_type, entered_at,
            exit_event_type, fk_exit_empty_pickup, exited_at,
            custody_status, remarks
        ) VALUES (
            p_correct_cyl_id, 'CUSTOMER', v_pickup_customer_id, v_pickup_address_id,
            'ORDER_DELIVERY', now(),
            'EMPTY_PICKUP', v_pickup_id, now(),
            'CLOSED',
            '[RETROACTIVE] Cylinder was at this customer; collected on pickup '
                || v_pickup_id || '. Times approximate.'
        );

        v_action_summary := v_action_summary
            || 'CORRECT: DELIVERED at different customer — retroactive note. ';

    ELSE
        -- ── Case C-4: EMPTY / FULL / yard state — retroactive ─────────────────
        INSERT INTO public.tbl_cylinder_state_audit (
            pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
            fk_order, changed_at, remarks
        ) VALUES (
            nextval('public.pk_cylinder_state_id_serial'),
            p_correct_cyl_id, v_delivered_state_id, v_empty_transit_state_id, NULL, now(),
            '[CORRECTION-RETROACTIVE] Correct cylinder was actually collected from customer '
                || v_pickup_customer_id || ' on pickup_line ' || p_pickup_line_id
                || '. Current state: ' || COALESCE(v_correct_state_name,'UNKNOWN')
                || '. Physical lifecycle progressed. current_status NOT changed. '
                || 'Reason: ' || p_reason
        );

        -- Retroactive CLOSED custody
        INSERT INTO public.tbl_cylinder_party_custody (
            fk_cylinder, party_type, fk_customer, fk_customer_address,
            entry_event_type, entered_at,
            exit_event_type, fk_exit_empty_pickup, exited_at,
            custody_status, remarks
        ) VALUES (
            p_correct_cyl_id, 'CUSTOMER', v_pickup_customer_id, v_pickup_address_id,
            'ORDER_DELIVERY', now(),
            'EMPTY_PICKUP', v_pickup_id, now(),
            'CLOSED',
            '[RETROACTIVE] Cylinder was collected here. Current state: '
                || COALESCE(v_correct_state_name,'UNKNOWN') || '. Times approximate.'
        );

        v_action_summary := v_action_summary
            || 'CORRECT: State=' || COALESCE(v_correct_state_name,'?')
            || ' — retroactive pickup note, custody closed. ';
    END IF;

    -- ── 8. Write the correction log row ──────────────────────────────────────
    INSERT INTO public.tbl_cylinder_correction_log (
        correction_context,
        fk_pickup_line,
        fk_wrong_cylinder,
        fk_correct_cylinder,
        wrong_cyl_state_at_correction,
        correct_cyl_state_at_correction,
        wrong_cyl_holder_customer_at_correction,
        correct_cyl_holder_customer_at_correction,
        reason,
        corrected_by,
        correction_status,
        correction_action_summary
    ) VALUES (
        'PICKUP_LINE',
        p_pickup_line_id,
        p_wrong_cyl_id,
        p_correct_cyl_id,
        COALESCE(v_wrong_state_name,  'UNKNOWN'),
        COALESCE(v_correct_state_name,'UNKNOWN'),
        v_wrong_holder_customer,
        v_correct_holder_customer,
        p_reason,
        p_corrected_by,
        'APPLIED',
        v_action_summary
    );

END;
$$;

COMMENT ON FUNCTION public.fn_correct_empty_pickup_line_cylinder(int8,int8,int8,varchar,varchar) IS
    'State-tolerant correction of a wrongly recorded cylinder serial on an empty pickup line. '
    'Only hard stop: is_invoiced = true. '
    'Wrong cylinder may be EMPTY_IN_TRANSIT (reverted), still DELIVERED (note-only), '
    'or already at yard (note-only). '
    'Correct cylinder may be DELIVERED at this customer (standard close), '
    'DELIVERED elsewhere (retroactive note), EMPTY_IN_TRANSIT (already correct), '
    'or back at yard (retroactive note). '
    'Replaces the V74 version which required strict state preconditions.';


-- =============================================================================
-- USAGE EXAMPLES
-- =============================================================================

-- Correct a delivery order line:
--
--   SELECT fn_correct_order_line_cylinder(
--       1042,       -- pk_order_line_id  (the line that has the wrong cylinder on it)
--       88,         -- pk_cylinder_id of the WRONG cylinder (609, as written on challan)
--       91,         -- pk_cylinder_id of the CORRECT cylinder (906, actually delivered)
--       'Loadman transposed digits 906 → 609 on challan dated 2026-05-10',
--       'employee.name@company.com'
--   );
--
-- Correct an empty pickup line:
--
--   SELECT fn_correct_empty_pickup_line_cylinder(
--       305,        -- pk_pickup_line_id
--       88,         -- wrong cylinder id
--       91,         -- correct cylinder id
--       'Loadman wrote 906 as 609 on pickup challan',
--       'employee.name@company.com'
--   );
--
-- Query the correction log:
--
--   SELECT cl.corrected_at,
--          wc.cylinder_serial  AS wrong_serial,
--          cc.cylinder_serial  AS correct_serial,
--          cl.wrong_cyl_state_at_correction,
--          cl.correct_cyl_state_at_correction,
--          cl.correction_action_summary,
--          cl.reason,
--          cl.corrected_by
--   FROM   tbl_cylinder_correction_log cl
--   JOIN   tbl_cylinder wc ON wc.pk_cylinder_id = cl.fk_wrong_cylinder
--   JOIN   tbl_cylinder cc ON cc.pk_cylinder_id = cl.fk_correct_cylinder
--   ORDER  BY cl.corrected_at DESC;
