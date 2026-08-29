-- =============================================================================
-- V74__CylinderCorrectionAndPartyCustody.sql
-- =============================================================================
--
-- ADDRESSES TWO GAPS:
--
-- ─────────────────────────────────────────────────────────────────────────────
-- GAP 1 — No ability to correct a wrongly recorded cylinder serial
-- ─────────────────────────────────────────────────────────────────────────────
-- When a loadman writes cylinder 906 as 609 (transposition) on a manual challan,
-- and both 906 and 609 were physically loaded on the vehicle, the BEFORE-INSERT
-- trigger on tbl_order_line cannot catch the error (609 is a valid, loaded
-- cylinder). The same issue exists for tbl_empty_pickup_line.
--
-- Currently no correction path exists. This migration adds:
--
--   tbl_cylinder_correction_log
--     One row per correction event. Records the wrong cylinder, the correct
--     cylinder, who approved the correction, and a reason. Linked to either
--     an order_line or a pickup_line.
--
--   fn_correct_order_line_cylinder(p_order_line_id, p_wrong_cyl, p_correct_cyl,
--                                   p_reason, p_corrected_by)
--     Safely swaps the cylinder on a delivery order line.
--     Preconditions checked:
--       a) Wrong cylinder is currently in DELIVERED_FOR_CONSUMPTION state.
--       b) Correct cylinder is currently in FULL_PICKED_UP_FOR_DELIVERY state.
--       c) Both cylinders were loaded on the SAME vehicle load as the order.
--       d) The order line has not been invoiced (is_invoiced = false).
--     Actions:
--       1. Inserts into tbl_cylinder_correction_log.
--       2. Reverts wrong cylinder: DELIVERED_FOR_CONSUMPTION → FULL_PICKED_UP_FOR_DELIVERY
--          (audit row with CORRECTION flag).
--       3. Updates tbl_order_line.fk_cylinder to the correct cylinder.
--       4. Transitions correct cylinder: FULL_PICKED_UP_FOR_DELIVERY → DELIVERED_FOR_CONSUMPTION
--          (audit row linked to the original order).
--       5. Updates tbl_cylinder_current_status for both cylinders.
--
--   fn_correct_empty_pickup_line_cylinder(p_pickup_line_id, p_wrong_cyl,
--                                          p_correct_cyl, p_reason, p_corrected_by)
--     Same pattern but for tbl_empty_pickup_line.
--     Preconditions:
--       a) Wrong cylinder is currently in EMPTY_IN_TRANSIT_TO_YARD.
--       b) Correct cylinder is currently in DELIVERED_FOR_CONSUMPTION.
--       c) Both cylinders belong to the same customer (via tbl_empty_pickup header).
--       d) The pickup line has not been invoiced.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- GAP 2 — No table linking a cylinder's ENTRY into a party with its EXIT
-- ─────────────────────────────────────────────────────────────────────────────
-- tbl_cylinder_current_status holds the current state but gives no history of
-- how long a cylinder sat with a customer or supplier, and no single row that
-- pairs the delivery event with the matching empty-pickup event (or the
-- supplier drop-off with the matching refill collection).
--
-- This migration adds:
--
--   tbl_cylinder_party_custody
--     One row per cylinder per visit to a party (customer or supplier).
--     The entry side is written on the same INSERT trigger that drives the
--     cylinder state machine. The exit side is filled in when the cylinder
--     leaves. A NULL exited_at / custody_status = 'ACTIVE' means the cylinder
--     is still at that party.
--
--     Triggers that open a custody record:
--       AFTER INSERT on tbl_order_line         → CUSTOMER entry (delivery)
--       AFTER INSERT on tbl_supplier_trip_line → SUPPLIER entry (dropoff for refill)
--
--     Triggers that close a custody record:
--       AFTER INSERT on tbl_empty_pickup_line                → CUSTOMER exit
--       AFTER INSERT on tbl_supplier_refill_collection_line  → SUPPLIER exit
--
-- =============================================================================


-- =============================================================================
-- PART 1  tbl_cylinder_correction_log
-- =============================================================================

DROP SEQUENCE IF EXISTS public.pk_cylinder_correction_id_serial;
CREATE SEQUENCE public.pk_cylinder_correction_id_serial
    INCREMENT BY 1 MINVALUE 1 START 1 CACHE 1 NO CYCLE;

CREATE TABLE public.tbl_cylinder_correction_log (
    pk_correction_id        int8         NOT NULL
        DEFAULT nextval('public.pk_cylinder_correction_id_serial'),

    -- Which transaction line was corrected?
    correction_context      varchar(30)  NOT NULL,   -- 'ORDER_LINE' | 'PICKUP_LINE'
    fk_order_line           int8         NULL,
    fk_pickup_line          int8         NULL,

    -- What was wrong, what is correct?
    fk_wrong_cylinder       int8         NOT NULL,
    fk_correct_cylinder     int8         NOT NULL,

    -- Traceability
    reason                  varchar(500) NOT NULL,
    corrected_by            varchar(200) NOT NULL,
    corrected_at            timestamp    NOT NULL DEFAULT now(),

    -- Approval workflow (optional — set to APPROVED immediately for now)
    correction_status       varchar(30)  NOT NULL DEFAULT 'APPLIED',

    CONSTRAINT tbl_cylinder_correction_log_pk
        PRIMARY KEY (pk_correction_id),

    CONSTRAINT tbl_cylinder_correction_log_context_chk
        CHECK (correction_context IN ('ORDER_LINE', 'PICKUP_LINE')),

    CONSTRAINT tbl_cylinder_correction_log_status_chk
        CHECK (correction_status IN ('PENDING', 'APPROVED', 'APPLIED', 'REJECTED')),

    CONSTRAINT tbl_cylinder_correction_log_order_line_fk
        FOREIGN KEY (fk_order_line)
        REFERENCES public.tbl_order_line(pk_order_line_id),

    CONSTRAINT tbl_cylinder_correction_log_pickup_line_fk
        FOREIGN KEY (fk_pickup_line)
        REFERENCES public.tbl_empty_pickup_line(pk_pickup_line_id),

    CONSTRAINT tbl_cylinder_correction_log_wrong_cyl_fk
        FOREIGN KEY (fk_wrong_cylinder)
        REFERENCES public.tbl_cylinder(pk_cylinder_id),

    CONSTRAINT tbl_cylinder_correction_log_correct_cyl_fk
        FOREIGN KEY (fk_correct_cylinder)
        REFERENCES public.tbl_cylinder(pk_cylinder_id),

    -- Exactly one line type must be set
    CONSTRAINT tbl_cylinder_correction_log_line_type_chk
        CHECK (
            (correction_context = 'ORDER_LINE'  AND fk_order_line  IS NOT NULL AND fk_pickup_line IS NULL) OR
            (correction_context = 'PICKUP_LINE' AND fk_pickup_line IS NOT NULL AND fk_order_line  IS NULL)
        )
);

CREATE INDEX idx_correction_log_order_line
    ON public.tbl_cylinder_correction_log(fk_order_line)
    WHERE fk_order_line IS NOT NULL;

CREATE INDEX idx_correction_log_pickup_line
    ON public.tbl_cylinder_correction_log(fk_pickup_line)
    WHERE fk_pickup_line IS NOT NULL;

CREATE INDEX idx_correction_log_wrong_cyl
    ON public.tbl_cylinder_correction_log(fk_wrong_cylinder);

CREATE INDEX idx_correction_log_correct_cyl
    ON public.tbl_cylinder_correction_log(fk_correct_cylinder);

COMMENT ON TABLE public.tbl_cylinder_correction_log IS
    'Audit log for cylinder serial corrections. One row per correction event. '
    'Created by fn_correct_order_line_cylinder or fn_correct_empty_pickup_line_cylinder. '
    'Records the wrong cylinder, the correct cylinder, and who authorised the change.';


-- =============================================================================
-- PART 2a  fn_correct_order_line_cylinder
--           Corrects fk_cylinder on a delivery order line
-- =============================================================================
-- Parameters:
--   p_order_line_id   pk of the tbl_order_line row to correct
--   p_wrong_cyl_id    pk of the cylinder that was mistakenly recorded
--   p_correct_cyl_id  pk of the cylinder that was actually delivered
--   p_reason          free-text explanation (stored in correction log)
--   p_corrected_by    username / employee name making the change
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
    v_delivered_state_id        int8;
    v_picked_up_state_id        int8;
    v_wrong_current_state_id    int8;
    v_correct_current_state_id  int8;
    v_order_id                  int8;
    v_is_invoiced               bool;

    -- Vehicle load validation
    v_wrong_load_id             int8;
    v_correct_load_id           int8;
BEGIN

    -- ── 1. Resolve state IDs ────────────────────────────────────────────────
    SELECT pk_cylinder_state_id INTO v_delivered_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'DELIVERED_FOR_CONSUMPTION';

    SELECT pk_cylinder_state_id INTO v_picked_up_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'FULL_PICKED_UP_FOR_DELIVERY';

    -- ── 2. Fetch the order line ─────────────────────────────────────────────
    SELECT fk_order, is_invoiced
    INTO v_order_id, v_is_invoiced
    FROM public.tbl_order_line
    WHERE pk_order_line_id = p_order_line_id
      AND fk_cylinder       = p_wrong_cyl_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Correction Failed: order_line % does not exist or its current cylinder '
            'is not the declared wrong cylinder (%).',
            p_order_line_id, p_wrong_cyl_id;
    END IF;

    -- ── 3. Guard: must not be invoiced ──────────────────────────────────────
    IF v_is_invoiced THEN
        RAISE EXCEPTION
            'Correction Failed: order_line % has already been invoiced. '
            'Corrections are not allowed on invoiced lines. '
            'Raise a credit note instead.',
            p_order_line_id;
    END IF;

    -- ── 4. Guard: wrong cylinder must be DELIVERED_FOR_CONSUMPTION ──────────
    SELECT fk_current_state INTO v_wrong_current_state_id
    FROM public.tbl_cylinder_current_status
    WHERE fk_cylinder = p_wrong_cyl_id;

    IF v_wrong_current_state_id IS DISTINCT FROM v_delivered_state_id THEN
        RAISE EXCEPTION
            'Correction Failed: the wrong cylinder (%) must be in '
            'DELIVERED_FOR_CONSUMPTION state. It appears to be in a different state '
            '(state id: %). If the cylinder has already been picked up as empty, '
            'raise a pickup line correction instead.',
            p_wrong_cyl_id, v_wrong_current_state_id;
    END IF;

    -- ── 5. Guard: correct cylinder must be FULL_PICKED_UP_FOR_DELIVERY ──────
    SELECT fk_current_state INTO v_correct_current_state_id
    FROM public.tbl_cylinder_current_status
    WHERE fk_cylinder = p_correct_cyl_id;

    IF v_correct_current_state_id IS DISTINCT FROM v_picked_up_state_id THEN
        RAISE EXCEPTION
            'Correction Failed: the correct cylinder (%) must be in '
            'FULL_PICKED_UP_FOR_DELIVERY state (it should still be on the vehicle). '
            'Current state id: %.',
            p_correct_cyl_id, v_correct_current_state_id;
    END IF;

    -- ── 6. Guard: both cylinders must have been on the same vehicle load ─────
    SELECT fk_vehicle_load INTO v_wrong_load_id
    FROM public.tbl_vehicle_load_line
    WHERE fk_cylinder = p_wrong_cyl_id
    ORDER BY pk_vehicle_load_line_id DESC
    LIMIT 1;

    SELECT fk_vehicle_load INTO v_correct_load_id
    FROM public.tbl_vehicle_load_line
    WHERE fk_cylinder = p_correct_cyl_id
    ORDER BY pk_vehicle_load_line_id DESC
    LIMIT 1;

    IF v_wrong_load_id IS NULL OR v_correct_load_id IS NULL
       OR v_wrong_load_id <> v_correct_load_id THEN
        RAISE EXCEPTION
            'Correction Failed: cylinders % and % were not loaded on the same vehicle load '
            '(wrong_load: %, correct_load: %). '
            'A delivery correction is only valid within the same trip.',
            p_wrong_cyl_id, p_correct_cyl_id,
            v_wrong_load_id, v_correct_load_id;
    END IF;

    -- ── 7. Log the correction ────────────────────────────────────────────────
    INSERT INTO public.tbl_cylinder_correction_log (
        correction_context, fk_order_line,
        fk_wrong_cylinder, fk_correct_cylinder,
        reason, corrected_by, correction_status
    ) VALUES (
        'ORDER_LINE', p_order_line_id,
        p_wrong_cyl_id, p_correct_cyl_id,
        p_reason, p_corrected_by, 'APPLIED'
    );

    -- ── 8. Revert wrong cylinder: DELIVERED_FOR_CONSUMPTION → FULL_PICKED_UP ─
    INSERT INTO public.tbl_cylinder_state_audit (
        pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
        fk_order, changed_at, remarks
    ) VALUES (
        nextval('public.pk_cylinder_state_id_serial'),
        p_wrong_cyl_id,
        v_delivered_state_id,
        v_picked_up_state_id,
        v_order_id,
        now(),
        '[CORRECTION] Cylinder reverted from DELIVERED_FOR_CONSUMPTION. '
            || 'Was incorrectly recorded on order_line ' || p_order_line_id || '. '
            || 'Replaced by cylinder ' || p_correct_cyl_id || '. '
            || 'Reason: ' || p_reason || '. Corrected by: ' || p_corrected_by
    );

    UPDATE public.tbl_cylinder_current_status
    SET fk_current_state           = v_picked_up_state_id,
        fk_current_holder_customer = NULL,
        fk_current_customer_address= NULL,
        fk_current_vehicle_load    = v_wrong_load_id,
        fk_last_order              = v_order_id,
        updated_at                 = now()
    WHERE fk_cylinder = p_wrong_cyl_id;

    -- ── 9. Swap the cylinder on the order line ───────────────────────────────
    UPDATE public.tbl_order_line
    SET fk_cylinder = p_correct_cyl_id
    WHERE pk_order_line_id = p_order_line_id;

    -- ── 10. Transition correct cylinder: FULL_PICKED_UP → DELIVERED ──────────
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
        '[CORRECTION] Cylinder confirmed as the actually delivered cylinder. '
            || 'Replaced wrongly recorded cylinder ' || p_wrong_cyl_id || ' on order_line '
            || p_order_line_id || '. '
            || 'Reason: ' || p_reason || '. Corrected by: ' || p_corrected_by
    );

    -- Resolve customer and address from order header
    UPDATE public.tbl_cylinder_current_status ccs
    SET fk_current_state            = v_delivered_state_id,
        fk_current_holder_customer  = o.fk_customer,
        fk_current_customer_address = ol.fk_delivery_address,
        fk_current_vehicle_load     = NULL,
        fk_last_order               = v_order_id,
        updated_at                  = now()
    FROM public.tbl_order o
    JOIN public.tbl_order_line ol ON ol.pk_order_line_id = p_order_line_id
    WHERE o.pk_order_id = v_order_id
      AND ccs.fk_cylinder = p_correct_cyl_id;

    -- ── 11. Update party custody: close the wrong-cylinder entry,
    --        open a new one for the correct cylinder ──────────────────────────
    -- (Relies on PART 3 tbl_cylinder_party_custody being present.)
    -- Close the erroneous custody record for the wrong cylinder
    UPDATE public.tbl_cylinder_party_custody
    SET exit_event_type  = 'CORRECTION',
        exited_at        = now(),
        custody_status   = 'CLOSED',
        remarks          = '[CORRECTION] Cylinder serial was wrong on order_line '
                               || p_order_line_id || '. Corrected to cylinder '
                               || p_correct_cyl_id || '. Reason: ' || p_reason
    WHERE fk_cylinder     = p_wrong_cyl_id
      AND custody_status  = 'ACTIVE'
      AND party_type      = 'CUSTOMER';

    -- Open a correct custody record for the right cylinder
    -- (The order_line trigger fn_custody_after_order_line would normally do this,
    --  but it already fired for the wrong cylinder. We insert manually here.)
    INSERT INTO public.tbl_cylinder_party_custody (
        fk_cylinder, party_type, fk_customer, fk_customer_address,
        entry_event_type, fk_entry_order,
        entered_at, custody_status
    )
    SELECT
        p_correct_cyl_id,
        'CUSTOMER',
        o.fk_customer,
        COALESCE(ol.fk_delivery_address, o.fk_delivery_address),
        'ORDER_DELIVERY',
        v_order_id,
        now(),
        'ACTIVE'
    FROM public.tbl_order o
    JOIN public.tbl_order_line ol ON ol.pk_order_line_id = p_order_line_id
    WHERE o.pk_order_id = v_order_id;

END;
$$;

COMMENT ON FUNCTION public.fn_correct_order_line_cylinder(int8,int8,int8,varchar,varchar) IS
    'Safely swaps a wrongly recorded cylinder on a delivery order line. '
    'Pre-conditions: wrong cylinder must be DELIVERED_FOR_CONSUMPTION; '
    'correct cylinder must be FULL_PICKED_UP_FOR_DELIVERY; '
    'both must share the same vehicle load; order line must not be invoiced. '
    'Writes a correction log row, two audit rows, and updates current status for both cylinders. '
    'Also corrects the linked tbl_cylinder_party_custody record.';


-- =============================================================================
-- PART 2b  fn_correct_empty_pickup_line_cylinder
--           Corrects fk_cylinder on an empty-pickup line
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
    v_wrong_current_state_id    int8;
    v_correct_current_state_id  int8;
    v_pickup_id                 int8;
    v_customer_id               int8;
    v_is_invoiced               bool;
    v_wrong_customer_id         int8;
    v_correct_customer_id       int8;
BEGIN

    -- ── 1. Resolve state IDs ────────────────────────────────────────────────
    SELECT pk_cylinder_state_id INTO v_delivered_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'DELIVERED_FOR_CONSUMPTION';

    SELECT pk_cylinder_state_id INTO v_empty_transit_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'EMPTY_IN_TRANSIT_TO_YARD';

    -- ── 2. Fetch the pickup line ─────────────────────────────────────────────
    SELECT epl.fk_empty_pickup, epl.is_invoiced, ep.fk_customer
    INTO v_pickup_id, v_is_invoiced, v_customer_id
    FROM public.tbl_empty_pickup_line epl
    JOIN public.tbl_empty_pickup ep ON ep.pk_pickup_id = epl.fk_empty_pickup
    WHERE epl.pk_pickup_line_id = p_pickup_line_id
      AND epl.fk_cylinder       = p_wrong_cyl_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Correction Failed: pickup_line % does not exist or its current cylinder '
            'is not the declared wrong cylinder (%).',
            p_pickup_line_id, p_wrong_cyl_id;
    END IF;

    -- ── 3. Guard: must not be invoiced ───────────────────────────────────────
    IF v_is_invoiced THEN
        RAISE EXCEPTION
            'Correction Failed: pickup_line % has already been invoiced.',
            p_pickup_line_id;
    END IF;

    -- ── 4. Guard: wrong cylinder must be EMPTY_IN_TRANSIT_TO_YARD ───────────
    SELECT fk_current_state INTO v_wrong_current_state_id
    FROM public.tbl_cylinder_current_status
    WHERE fk_cylinder = p_wrong_cyl_id;

    IF v_wrong_current_state_id IS DISTINCT FROM v_empty_transit_state_id THEN
        RAISE EXCEPTION
            'Correction Failed: the wrong cylinder (%) must be in '
            'EMPTY_IN_TRANSIT_TO_YARD state. Current state id: %.',
            p_wrong_cyl_id, v_wrong_current_state_id;
    END IF;

    -- ── 5. Guard: correct cylinder must be DELIVERED_FOR_CONSUMPTION ─────────
    SELECT fk_current_state INTO v_correct_current_state_id
    FROM public.tbl_cylinder_current_status
    WHERE fk_cylinder = p_correct_cyl_id;

    IF v_correct_current_state_id IS DISTINCT FROM v_delivered_state_id THEN
        RAISE EXCEPTION
            'Correction Failed: the correct cylinder (%) must be in '
            'DELIVERED_FOR_CONSUMPTION state (still at customer). Current state id: %.',
            p_correct_cyl_id, v_correct_current_state_id;
    END IF;

    -- ── 6. Guard: both cylinders must belong to the same customer ────────────
    SELECT fk_current_holder_customer INTO v_wrong_customer_id
    FROM public.tbl_cylinder_current_status
    WHERE fk_cylinder = p_wrong_cyl_id;
    -- Note: after EMPTY_IN_TRANSIT the customer is already NULL on wrong cyl.
    -- So we trust the pickup header's fk_customer for the wrong cylinder check.

    SELECT fk_current_holder_customer INTO v_correct_customer_id
    FROM public.tbl_cylinder_current_status
    WHERE fk_cylinder = p_correct_cyl_id;

    IF v_correct_customer_id IS DISTINCT FROM v_customer_id THEN
        RAISE EXCEPTION
            'Correction Failed: the correct cylinder (%) is held by customer %, '
            'but pickup % belongs to customer %. '
            'Both cylinders must be associated with the same customer.',
            p_correct_cyl_id, v_correct_customer_id,
            p_pickup_line_id,  v_customer_id;
    END IF;

    -- ── 7. Log the correction ────────────────────────────────────────────────
    INSERT INTO public.tbl_cylinder_correction_log (
        correction_context, fk_pickup_line,
        fk_wrong_cylinder, fk_correct_cylinder,
        reason, corrected_by, correction_status
    ) VALUES (
        'PICKUP_LINE', p_pickup_line_id,
        p_wrong_cyl_id, p_correct_cyl_id,
        p_reason, p_corrected_by, 'APPLIED'
    );

    -- ── 8. Revert wrong cylinder: EMPTY_IN_TRANSIT → DELIVERED_FOR_CONSUMPTION
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
        '[CORRECTION] Cylinder reverted from EMPTY_IN_TRANSIT_TO_YARD. '
            || 'Was incorrectly recorded on pickup_line ' || p_pickup_line_id || '. '
            || 'Replaced by cylinder ' || p_correct_cyl_id || '. '
            || 'Reason: ' || p_reason || '. Corrected by: ' || p_corrected_by
    );

    UPDATE public.tbl_cylinder_current_status
    SET fk_current_state            = v_delivered_state_id,
        fk_current_holder_customer  = v_customer_id,
        updated_at                  = now()
    WHERE fk_cylinder = p_wrong_cyl_id;

    -- ── 9. Swap the cylinder on the pickup line ──────────────────────────────
    UPDATE public.tbl_empty_pickup_line
    SET fk_cylinder = p_correct_cyl_id
    WHERE pk_pickup_line_id = p_pickup_line_id;

    -- ── 10. Transition correct cylinder: DELIVERED → EMPTY_IN_TRANSIT ────────
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
        '[CORRECTION] Cylinder confirmed as the actually collected empty. '
            || 'Replaced wrongly recorded cylinder ' || p_wrong_cyl_id
            || ' on pickup_line ' || p_pickup_line_id || '. '
            || 'Reason: ' || p_reason || '. Corrected by: ' || p_corrected_by
    );

    UPDATE public.tbl_cylinder_current_status
    SET fk_current_state            = v_empty_transit_state_id,
        fk_current_holder_customer  = NULL,
        fk_current_customer_address = NULL,
        updated_at                  = now()
    WHERE fk_cylinder = p_correct_cyl_id;

    -- ── 11. Update party custody ─────────────────────────────────────────────
    -- Re-open the custody record for the wrong cylinder (back to ACTIVE)
    UPDATE public.tbl_cylinder_party_custody
    SET exit_event_type = NULL,
        fk_exit_empty_pickup = NULL,
        exited_at       = NULL,
        custody_status  = 'ACTIVE',
        remarks         = '[CORRECTION] Empty pickup line ' || p_pickup_line_id
                              || ' was for wrong cylinder. Reverted. '
                              || 'Correct cylinder: ' || p_correct_cyl_id
    WHERE fk_cylinder    = p_wrong_cyl_id
      AND custody_status = 'CLOSED'
      AND party_type     = 'CUSTOMER'
      AND fk_exit_empty_pickup = v_pickup_id;

    -- Close the custody record for the correct cylinder
    UPDATE public.tbl_cylinder_party_custody
    SET exit_event_type      = 'EMPTY_PICKUP',
        fk_exit_empty_pickup = v_pickup_id,
        exited_at            = now(),
        custody_status       = 'CLOSED',
        remarks              = '[CORRECTION] Cylinder confirmed as picked up empty '
                                   || 'on pickup ' || v_pickup_id || '.'
    WHERE fk_cylinder    = p_correct_cyl_id
      AND custody_status = 'ACTIVE'
      AND party_type     = 'CUSTOMER';

END;
$$;

COMMENT ON FUNCTION public.fn_correct_empty_pickup_line_cylinder(int8,int8,int8,varchar,varchar) IS
    'Safely swaps a wrongly recorded cylinder on an empty-pickup line. '
    'Pre-conditions: wrong cylinder must be EMPTY_IN_TRANSIT_TO_YARD; '
    'correct cylinder must be DELIVERED_FOR_CONSUMPTION and at the same customer; '
    'pickup line must not be invoiced. '
    'Writes a correction log row, two audit rows, and updates current status for both cylinders. '
    'Also corrects the linked tbl_cylinder_party_custody record.';


-- =============================================================================
-- PART 3  tbl_cylinder_party_custody  (NEW TABLE)
-- =============================================================================
-- Tracks every visit a cylinder makes to any party (customer or supplier).
-- Each row represents one complete or ongoing custody episode.
-- The entry side is set when the cylinder arrives; the exit side is set
-- when it leaves. NULL exited_at means the cylinder is still at that party.
-- =============================================================================

DROP SEQUENCE IF EXISTS public.pk_cylinder_party_custody_id_serial;
CREATE SEQUENCE public.pk_cylinder_party_custody_id_serial
    INCREMENT BY 1 MINVALUE 1 START 1 CACHE 1 NO CYCLE;

CREATE TABLE public.tbl_cylinder_party_custody (
    pk_custody_id           int8          NOT NULL
        DEFAULT nextval('public.pk_cylinder_party_custody_id_serial'),

    fk_cylinder             int8          NOT NULL,

    -- ── Party ──────────────────────────────────────────────────────────────
    party_type              varchar(20)   NOT NULL,     -- 'CUSTOMER' | 'SUPPLIER'
    fk_customer             int8          NULL,
    fk_supplier             int8          NULL,

    -- Exact customer location (NULL for SUPPLIER rows or when unspecified)
    fk_customer_address     int8          NULL,

    -- ── Entry (how the cylinder arrived) ──────────────────────────────────
    -- 'ORDER_DELIVERY' | 'SUPPLIER_DROPOFF'
    entry_event_type        varchar(50)   NOT NULL,
    fk_entry_order          int8          NULL,       -- set for ORDER_DELIVERY
    fk_entry_supplier_trip  int8          NULL,       -- set for SUPPLIER_DROPOFF
    entered_at              timestamp     NOT NULL DEFAULT now(),

    -- ── Exit (how the cylinder left) ──────────────────────────────────────
    -- 'EMPTY_PICKUP' | 'REFILL_COLLECTION' | 'CORRECTION' | NULL (still at party)
    exit_event_type         varchar(50)   NULL,
    fk_exit_empty_pickup             int8 NULL,
    fk_exit_supplier_refill_collection int8 NULL,
    exited_at               timestamp     NULL,

    -- ── Status ────────────────────────────────────────────────────────────
    custody_status          varchar(20)   NOT NULL DEFAULT 'ACTIVE',

    remarks                 varchar(500)  NULL,

    CONSTRAINT tbl_cylinder_party_custody_pk
        PRIMARY KEY (pk_custody_id),

    CONSTRAINT tbl_custody_party_type_chk
        CHECK (party_type IN ('CUSTOMER', 'SUPPLIER')),

    CONSTRAINT tbl_custody_status_chk
        CHECK (custody_status IN ('ACTIVE', 'CLOSED')),

    CONSTRAINT tbl_custody_entry_event_chk
        CHECK (entry_event_type IN ('ORDER_DELIVERY', 'SUPPLIER_DROPOFF')),

    CONSTRAINT tbl_custody_exit_event_chk
        CHECK (exit_event_type IN ('EMPTY_PICKUP', 'REFILL_COLLECTION', 'CORRECTION') OR exit_event_type IS NULL),

    -- Party column / entry reference consistency
    CONSTRAINT tbl_custody_customer_chk
        CHECK (party_type <> 'CUSTOMER' OR fk_customer IS NOT NULL),

    CONSTRAINT tbl_custody_supplier_chk
        CHECK (party_type <> 'SUPPLIER' OR fk_supplier IS NOT NULL),

    CONSTRAINT tbl_custody_cylinder_fk
        FOREIGN KEY (fk_cylinder)
        REFERENCES public.tbl_cylinder(pk_cylinder_id),

    CONSTRAINT tbl_custody_customer_fk
        FOREIGN KEY (fk_customer)
        REFERENCES public.tbl_customer(pk_customer_id),

    CONSTRAINT tbl_custody_supplier_fk
        FOREIGN KEY (fk_supplier)
        REFERENCES public.tbl_supplier(pk_supplier_id),

    CONSTRAINT tbl_custody_customer_address_fk
        FOREIGN KEY (fk_customer_address)
        REFERENCES public.tbl_customer_address(pk_customer_address_id),

    CONSTRAINT tbl_custody_entry_order_fk
        FOREIGN KEY (fk_entry_order)
        REFERENCES public.tbl_order(pk_order_id),

    CONSTRAINT tbl_custody_entry_supplier_trip_fk
        FOREIGN KEY (fk_entry_supplier_trip)
        REFERENCES public.tbl_supplier_trip(pk_supplier_trip_id),

    CONSTRAINT tbl_custody_exit_pickup_fk
        FOREIGN KEY (fk_exit_empty_pickup)
        REFERENCES public.tbl_empty_pickup(pk_pickup_id),

    CONSTRAINT tbl_custody_exit_refill_collection_fk
        FOREIGN KEY (fk_exit_supplier_refill_collection)
        REFERENCES public.tbl_supplier_refill_collection(pk_collection_id)
);

-- ── Indexes ──────────────────────────────────────────────────────────────────
CREATE INDEX idx_custody_cylinder
    ON public.tbl_cylinder_party_custody(fk_cylinder);

CREATE INDEX idx_custody_active_cylinder
    ON public.tbl_cylinder_party_custody(fk_cylinder)
    WHERE custody_status = 'ACTIVE';

CREATE INDEX idx_custody_customer
    ON public.tbl_cylinder_party_custody(fk_customer)
    WHERE fk_customer IS NOT NULL;

CREATE INDEX idx_custody_supplier
    ON public.tbl_cylinder_party_custody(fk_supplier)
    WHERE fk_supplier IS NOT NULL;

CREATE INDEX idx_custody_entered_at
    ON public.tbl_cylinder_party_custody(entered_at DESC);

COMMENT ON TABLE public.tbl_cylinder_party_custody IS
    'One row per cylinder visit to a party (customer or supplier). '
    'The ENTRY side is written when the cylinder arrives (order delivery or supplier dropoff). '
    'The EXIT side is written when it leaves (empty pickup or refill collection). '
    'custody_status = ACTIVE means the cylinder is still at that party. '
    'Use this table to answer: how long is each cylinder sitting at each customer? '
    'Which cylinders at a customer have no matching empty pickup yet?';


-- =============================================================================
-- PART 4a  fn_custody_after_order_line
--           Opens a CUSTOMER custody record on delivery (tbl_order_line INSERT)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_custody_after_order_line()
RETURNS TRIGGER AS $$
DECLARE
    v_customer_id        int8;
    v_delivery_address   int8;
BEGIN
    SELECT
        o.fk_customer,
        COALESCE(NEW.fk_delivery_address, o.fk_delivery_address)
    INTO v_customer_id, v_delivery_address
    FROM public.tbl_order o
    WHERE o.pk_order_id = NEW.fk_order;

    INSERT INTO public.tbl_cylinder_party_custody (
        fk_cylinder, party_type, fk_customer, fk_customer_address,
        entry_event_type, fk_entry_order,
        entered_at, custody_status
    ) VALUES (
        NEW.fk_cylinder,
        'CUSTOMER',
        v_customer_id,
        v_delivery_address,
        'ORDER_DELIVERY',
        NEW.fk_order,
        now(),
        'ACTIVE'
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_03_custody_after_order_line
AFTER INSERT ON public.tbl_order_line
FOR EACH ROW
EXECUTE FUNCTION public.fn_custody_after_order_line();

COMMENT ON FUNCTION public.fn_custody_after_order_line() IS
    'Fires AFTER INSERT on tbl_order_line. '
    'Opens a CUSTOMER custody record in tbl_cylinder_party_custody. '
    'The record is closed by trg_03_custody_after_empty_pickup_line '
    'when the empty cylinder is collected.';


-- =============================================================================
-- PART 4b  fn_custody_after_empty_pickup_line
--           Closes the CUSTOMER custody record on empty pickup
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_custody_after_empty_pickup_line()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE public.tbl_cylinder_party_custody
    SET exit_event_type      = 'EMPTY_PICKUP',
        fk_exit_empty_pickup = NEW.fk_empty_pickup,
        exited_at            = now(),
        custody_status       = 'CLOSED'
    WHERE fk_cylinder    = NEW.fk_cylinder
      AND custody_status = 'ACTIVE'
      AND party_type     = 'CUSTOMER';

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Note: a BEFORE INSERT validation trigger already exists on this table (V66).
-- This is a second AFTER INSERT trigger — give it a distinct number.
CREATE TRIGGER trg_03_custody_after_empty_pickup_line
AFTER INSERT ON public.tbl_empty_pickup_line
FOR EACH ROW
EXECUTE FUNCTION public.fn_custody_after_empty_pickup_line();

COMMENT ON FUNCTION public.fn_custody_after_empty_pickup_line() IS
    'Fires AFTER INSERT on tbl_empty_pickup_line. '
    'Closes the ACTIVE CUSTOMER custody record for this cylinder in '
    'tbl_cylinder_party_custody by setting exit_event_type, fk_exit_empty_pickup, '
    'exited_at, and custody_status = CLOSED.';


-- =============================================================================
-- PART 4c  fn_custody_after_supplier_trip_line
--           Opens a SUPPLIER custody record on supplier dropoff
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_custody_after_supplier_trip_line()
RETURNS TRIGGER AS $$
DECLARE
    v_supplier_id int8;
BEGIN
    SELECT fk_supplier INTO v_supplier_id
    FROM public.tbl_supplier_trip
    WHERE pk_supplier_trip_id = NEW.fk_supplier_trip;

    INSERT INTO public.tbl_cylinder_party_custody (
        fk_cylinder, party_type, fk_supplier,
        entry_event_type, fk_entry_supplier_trip,
        entered_at, custody_status
    ) VALUES (
        NEW.fk_cylinder,
        'SUPPLIER',
        v_supplier_id,
        'SUPPLIER_DROPOFF',
        NEW.fk_supplier_trip,
        now(),
        'ACTIVE'
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- The existing AFTER INSERT trigger on tbl_supplier_trip_line is
-- trg_01_audit_supplier_trip_line_insert (V65). Use a higher number.
CREATE TRIGGER trg_02_custody_after_supplier_trip_line
AFTER INSERT ON public.tbl_supplier_trip_line
FOR EACH ROW
EXECUTE FUNCTION public.fn_custody_after_supplier_trip_line();

COMMENT ON FUNCTION public.fn_custody_after_supplier_trip_line() IS
    'Fires AFTER INSERT on tbl_supplier_trip_line. '
    'Opens a SUPPLIER custody record in tbl_cylinder_party_custody. '
    'The record is closed by trg_02_custody_after_refill_collection_line '
    'when the refilled cylinder is collected.';


-- =============================================================================
-- PART 4d  fn_custody_after_refill_collection_line
--           Closes the SUPPLIER custody record on refill collection
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_custody_after_refill_collection_line()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE public.tbl_cylinder_party_custody
    SET exit_event_type                  = 'REFILL_COLLECTION',
        fk_exit_supplier_refill_collection = NEW.fk_collection,
        exited_at                        = COALESCE(NEW.collected_at, now()),
        custody_status                   = 'CLOSED'
    WHERE fk_cylinder    = NEW.fk_cylinder
      AND custody_status = 'ACTIVE'
      AND party_type     = 'SUPPLIER';

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Existing AFTER trigger on this table is trg_02_audit_cylinder_refill_collection_after (V56).
CREATE TRIGGER trg_03_custody_after_refill_collection_line
AFTER INSERT ON public.tbl_supplier_refill_collection_line
FOR EACH ROW
EXECUTE FUNCTION public.fn_custody_after_refill_collection_line();

COMMENT ON FUNCTION public.fn_custody_after_refill_collection_line() IS
    'Fires AFTER INSERT on tbl_supplier_refill_collection_line. '
    'Closes the ACTIVE SUPPLIER custody record for this cylinder in '
    'tbl_cylinder_party_custody by setting exit_event_type, '
    'fk_exit_supplier_refill_collection, exited_at, and custody_status = CLOSED.';


-- =============================================================================
-- PART 5  USEFUL QUERIES (reference)
-- =============================================================================

-- Q1: Which cylinders are still at Customer X with no matching empty pickup?
--
-- SELECT c.cylinder_serial, cs.cylinder_state, cpc.entered_at, cpc.fk_entry_order
-- FROM   tbl_cylinder_party_custody cpc
-- JOIN   tbl_cylinder c  ON c.pk_cylinder_id = cpc.fk_cylinder
-- JOIN   tbl_cylinder_states cs
--        ON cs.pk_cylinder_state_id = (
--               SELECT fk_current_state FROM tbl_cylinder_current_status
--               WHERE fk_cylinder = cpc.fk_cylinder)
-- WHERE  cpc.fk_customer   = :customerId
--   AND  cpc.custody_status = 'ACTIVE'
-- ORDER  BY cpc.entered_at;

-- Q2: Full in/out history for a single cylinder
--
-- SELECT party_type,
--        COALESCE(c.cylinder_serial, '') AS cylinder,
--        entered_at, exited_at,
--        custody_status,
--        entry_event_type, exit_event_type
-- FROM   tbl_cylinder_party_custody cpc
-- JOIN   tbl_cylinder c ON c.pk_cylinder_id = cpc.fk_cylinder
-- WHERE  cpc.fk_cylinder = :cylinderId
-- ORDER  BY cpc.entered_at;

-- Q3: Average days at customer per cylinder type
--
-- SELECT p.product_name,
--        ROUND(AVG(EXTRACT(EPOCH FROM (exited_at - entered_at))/86400), 1) AS avg_days
-- FROM   tbl_cylinder_party_custody cpc
-- JOIN   tbl_cylinder cyl ON cyl.pk_cylinder_id = cpc.fk_cylinder
-- JOIN   tbl_product  p   ON p.pk_product_id    = cyl.fk_product
-- WHERE  cpc.custody_status = 'CLOSED'
--   AND  cpc.party_type     = 'CUSTOMER'
-- GROUP  BY p.product_name;

-- Q4: Correction history for a cylinder
--
-- SELECT correction_context, fk_order_line, fk_pickup_line,
--        fk_wrong_cylinder, fk_correct_cylinder,
--        reason, corrected_by, corrected_at
-- FROM   tbl_cylinder_correction_log
-- WHERE  fk_wrong_cylinder = :cylinderId
--    OR  fk_correct_cylinder = :cylinderId
-- ORDER  BY corrected_at DESC;
