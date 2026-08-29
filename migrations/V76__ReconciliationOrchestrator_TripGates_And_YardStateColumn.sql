-- =============================================================================
-- V76__ReconciliationOrchestrator_TripGates_And_YardStateColumn.sql
-- =============================================================================
--
-- WHAT THIS MIGRATION DOES
-- ────────────────────────
-- Three independent improvements, all backward-compatible:
--
-- PART 1 — Per-trip atomic checkpoint gates (extends V61 + V69)
--   V61 only had two trip-level types: TRIP_DEPARTURE and TRIP_RETURN.
--   V69 resolved TRIP_DEPARTURE when the vehicle halted — one gate for the
--   entire trip. This means if cylinder C15 was missing from stop 3 out of 7,
--   the deviation was invisible until the whole trip returned.
--
--   This part expands the checkpoint lifecycle to one gate per meaningful
--   event on a trip:
--
--     TRIP_LOAD_CONFIRMED    → vehicle load locked and cylinder count tallied
--     TRIP_DEPARTURE         → vehicle leaves the yard  [existing, kept]
--     TRIP_STOP_DELIVERY     → delivery challan posted for a customer stop
--     TRIP_STOP_EMPTY_PICKUP → empty-pickup challan posted for a customer stop
--     TRIP_RETURN_SCAN       → driver returns; physical cylinder count done
--     TRIP_RETURN            → all TRIP_STOP_* gates resolved  [existing, kept]
--     TRIP_CLOSURE           → full trip reconciliation signed off
--     CYLINDER_CORRECTION    → a serial correction applied; awaits supervisor ack
--
--   DIRECT FK COLUMNS are added to tbl_reconciliation_checkpoint so each
--   checkpoint row can be joined directly to a trip or load without parsing
--   reference_entity_type / reference_entity_id.
--
-- PART 2 — V75 correction functions wired into the orchestrator
--   fn_correct_order_line_cylinder and fn_correct_empty_pickup_line_cylinder
--   (V75) now emit a CYLINDER_CORRECTION checkpoint after every successful
--   correction. The checkpoint stays PENDING until a supervisor calls
--   fn_acknowledge_correction_checkpoint(), giving the office a clear
--   sign-off queue for every challan correction that has ever been applied.
--
-- PART 3 — Yard stock check line: system state column + trigger ownership
--   V60 added state_matches_system (boolean, trigger-computed) but the trigger
--   did not persist WHICH system state it compared against. After the audit
--   is closed it was impossible to know what the system believed the cylinder
--   state was at scan time (the current_status row may have changed since).
--
--   This part adds:
--     fk_system_cylinder_state  — FK to tbl_cylinder_states, set by trigger
--     system_state_name         — denormalised text snapshot (immutable)
--
--   The existing trigger fn_evaluate_yard_line_state_match (V60) is replaced
--   with an enhanced version that populates both new columns.
--   state_matches_system remains trigger-computed (not a generated column)
--   so the comparison logic can be updated without a schema migration.
--
-- DEPENDENCIES
--   V15  tbl_cylinder_states
--   V23  tbl_yard_stock_check
--   V24  tbl_yard_stock_check_line
--   V35  tbl_vehicle_load
--   V46  tbl_vehicle_trip
--   V60  tbl_yard_stock_check_line extensions, fn_evaluate_yard_line_state_match
--   V61  tbl_reconciliation_checkpoint, fn_create_checkpoint, fn_resolve_checkpoint
--   V69  fn_trip_status_after_update (creates TRIP_DEPARTURE checkpoints)
--   V74  tbl_cylinder_correction_log
--   V75  fn_correct_order_line_cylinder, fn_correct_empty_pickup_line_cylinder
-- =============================================================================


-- =============================================================================
-- PART 1A — Extend tbl_reconciliation_checkpoint
--            • Widen the checkpoint_type enum
--            • Add direct FK columns fk_vehicle_trip / fk_vehicle_load
--            • Add trip_stop_sequence for ordered stop tracking
-- =============================================================================

-- ── 1. Drop the old CHECK constraint so we can replace it ──────────────────
ALTER TABLE public.tbl_reconciliation_checkpoint
    DROP CONSTRAINT IF EXISTS tbl_recon_checkpoint_type_chk;

-- ── 2. Re-add with the full per-trip event vocabulary ─────────────────────
ALTER TABLE public.tbl_reconciliation_checkpoint
    ADD CONSTRAINT tbl_recon_checkpoint_type_chk
    CHECK (checkpoint_type IN (
        -- Day-level gates (unchanged from V61)
        'DAILY_OPENING',
        'DAILY_CLOSING',

        -- Per-trip atomic gates (NEW — one row per event per trip)
        'TRIP_LOAD_CONFIRMED',      -- load sealed, cylinder tally locked before departure
        'TRIP_DEPARTURE',           -- vehicle leaves the yard [was the only trip gate in V61]
        'TRIP_STOP_DELIVERY',       -- delivery challan entered for one customer stop
        'TRIP_STOP_EMPTY_PICKUP',   -- empty-pickup challan entered for one customer stop
        'TRIP_RETURN_SCAN',         -- driver physically back; cylinders counted at gate
        'TRIP_RETURN',              -- all expected cylinders accounted for after return
        'TRIP_CLOSURE',             -- full trip signed off; all stop gates matched

        -- Correction gate (NEW — emitted by V75 correction functions)
        'CYLINDER_CORRECTION',      -- a challan serial correction applied; pending supervisor ack

        -- Supplier-level gates (unchanged from V61)
        'SUPPLIER_DROPOFF',
        'SUPPLIER_COLLECTION',

        -- Yard audit gate (unchanged from V61)
        'YARD_AUDIT'
    ));

-- ── 3. Direct FK columns for efficient per-trip queries ────────────────────
ALTER TABLE public.tbl_reconciliation_checkpoint
    ADD COLUMN IF NOT EXISTS fk_vehicle_trip  int8 NULL,
    ADD COLUMN IF NOT EXISTS fk_vehicle_load  int8 NULL,
    ADD COLUMN IF NOT EXISTS trip_stop_sequence int4 NULL;

COMMENT ON COLUMN public.tbl_reconciliation_checkpoint.fk_vehicle_trip IS
    'Direct FK to tbl_vehicle_trip. Populated for all TRIP_* checkpoint types. '
    'Redundant with reference_entity_id when entity_type = tbl_vehicle_trip '
    'but avoids casting in joins.';

COMMENT ON COLUMN public.tbl_reconciliation_checkpoint.fk_vehicle_load IS
    'Direct FK to tbl_vehicle_load. Set on TRIP_LOAD_CONFIRMED checkpoints.';

COMMENT ON COLUMN public.tbl_reconciliation_checkpoint.trip_stop_sequence IS
    'Stop ordinal within the trip (1 = first stop). '
    'Set on TRIP_STOP_DELIVERY and TRIP_STOP_EMPTY_PICKUP checkpoints. '
    'Enables per-stop deviation tracking across the trip timeline.';

ALTER TABLE public.tbl_reconciliation_checkpoint
    ADD CONSTRAINT tbl_recon_checkpoint_vehicle_trip_fk
    FOREIGN KEY (fk_vehicle_trip)
    REFERENCES public.tbl_vehicle_trip(pk_vehicle_trip_id);

ALTER TABLE public.tbl_reconciliation_checkpoint
    ADD CONSTRAINT tbl_recon_checkpoint_vehicle_load_fk
    FOREIGN KEY (fk_vehicle_load)
    REFERENCES public.tbl_vehicle_load(pk_vehicle_load_id);

-- ── 4. Indexes for the new FK columns ─────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_recon_checkpoint_vehicle_trip
    ON public.tbl_reconciliation_checkpoint(fk_vehicle_trip)
    WHERE fk_vehicle_trip IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_recon_checkpoint_vehicle_load
    ON public.tbl_reconciliation_checkpoint(fk_vehicle_load)
    WHERE fk_vehicle_load IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_recon_checkpoint_trip_pending
    ON public.tbl_reconciliation_checkpoint(fk_vehicle_trip, checkpoint_type, checkpoint_status)
    WHERE fk_vehicle_trip IS NOT NULL
      AND checkpoint_status IN ('PENDING', 'VARIANCE', 'ESCALATED');

COMMENT ON TABLE public.tbl_reconciliation_checkpoint IS
    'Central orchestrator table. Every significant cylinder-movement event produces '
    'a checkpoint row — now including one gate per event per trip (TRIP_LOAD_CONFIRMED, '
    'TRIP_STOP_DELIVERY, TRIP_STOP_EMPTY_PICKUP, TRIP_RETURN_SCAN, TRIP_CLOSURE) and '
    'a CYLINDER_CORRECTION gate for each challan correction. '
    'The new fk_vehicle_trip column lets the dashboard filter by individual trip '
    'without pivoting on reference_entity_type.';


-- =============================================================================
-- PART 1B — fn_create_checkpoint (replace V61 version)
--            • Accept optional p_checkpoint_date so retroactive entries do
--              not stamp CURRENT_DATE when the event happened on a prior day
--            • Accept optional p_vehicle_trip_id / p_vehicle_load_id so the
--              new FK columns are populated in one call
--            • Accept optional p_stop_sequence
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_create_checkpoint(
    p_type                  varchar(50),
    p_entity_type           varchar(100),
    p_entity_id             int8,
    p_expected_count        int4,
    p_threshold_hours       int4        DEFAULT 24,
    p_remarks               varchar(500) DEFAULT NULL,
    p_checkpoint_date       date        DEFAULT NULL,   -- NULL → CURRENT_DATE
    p_vehicle_trip_id       int8        DEFAULT NULL,
    p_vehicle_load_id       int8        DEFAULT NULL,
    p_stop_sequence         int4        DEFAULT NULL
)
RETURNS int8 AS $$
DECLARE
    v_daily_count_id  int8;
    v_eff_date        date;
    v_new_id          int8;
BEGIN
    v_eff_date := COALESCE(p_checkpoint_date, CURRENT_DATE);

    -- Link to the daily count row for the effective date
    SELECT pk_daily_count_id INTO v_daily_count_id
    FROM   public.tbl_daily_cylinder_count
    WHERE  count_date = v_eff_date;

    INSERT INTO public.tbl_reconciliation_checkpoint (
        checkpoint_date,
        checkpoint_type,
        reference_entity_type,
        reference_entity_id,
        fk_daily_count,
        fk_vehicle_trip,
        fk_vehicle_load,
        trip_stop_sequence,
        expected_count,
        escalation_threshold_hours,
        remarks
    ) VALUES (
        v_eff_date,
        p_type,
        p_entity_type,
        p_entity_id,
        v_daily_count_id,
        p_vehicle_trip_id,
        p_vehicle_load_id,
        p_stop_sequence,
        p_expected_count,
        p_threshold_hours,
        p_remarks
    )
    RETURNING pk_checkpoint_id INTO v_new_id;

    RETURN v_new_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_create_checkpoint(varchar,varchar,int8,int4,int4,varchar,date,int8,int8,int4) IS
    'Creates a reconciliation checkpoint. New parameters: '
    'p_checkpoint_date (default CURRENT_DATE — set explicitly for retroactive entries), '
    'p_vehicle_trip_id (populates fk_vehicle_trip), '
    'p_vehicle_load_id (populates fk_vehicle_load), '
    'p_stop_sequence (stop ordinal within the trip). '
    'Backward-compatible: existing callers using the original 6-parameter signature '
    'will use the defaults for the new parameters.';


-- =============================================================================
-- PART 1C — fn_resolve_checkpoint (replace V61 version)
--            • Also accept p_vehicle_trip_id for faster PENDING lookup
--              when the entity_type / entity_id combination is ambiguous
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_resolve_checkpoint(
    p_entity_type       varchar(100),
    p_entity_id         int8,
    p_checkpoint_type   varchar(50),
    p_actual_count      int4,
    p_remarks           varchar(500) DEFAULT NULL,
    p_vehicle_trip_id   int8         DEFAULT NULL   -- optional fast-path filter
)
RETURNS void AS $$
DECLARE
    v_expected int4;
    v_variance int4;
    v_status   varchar(50);
    v_pk       int8;
BEGIN
    -- Find the most-recent PENDING checkpoint for this entity + type
    SELECT pk_checkpoint_id, expected_count
    INTO   v_pk, v_expected
    FROM   public.tbl_reconciliation_checkpoint
    WHERE  reference_entity_type = p_entity_type
      AND  reference_entity_id   = p_entity_id
      AND  checkpoint_type       = p_checkpoint_type
      AND  checkpoint_status     = 'PENDING'
      -- optional fast-path: match fk_vehicle_trip if supplied
      AND  (p_vehicle_trip_id IS NULL OR fk_vehicle_trip = p_vehicle_trip_id)
    ORDER BY created_at DESC
    LIMIT  1;

    IF NOT FOUND THEN
        RAISE NOTICE 'fn_resolve_checkpoint: No PENDING checkpoint for %:% type:%',
            p_entity_type, p_entity_id, p_checkpoint_type;
        RETURN;
    END IF;

    v_variance := p_actual_count - v_expected;
    v_status   := CASE WHEN v_variance = 0 THEN 'MATCHED' ELSE 'VARIANCE' END;

    UPDATE public.tbl_reconciliation_checkpoint
    SET    actual_count      = p_actual_count,
           checkpoint_status = v_status,
           resolved_at       = now(),
           remarks           = COALESCE(p_remarks, remarks)
    WHERE  pk_checkpoint_id  = v_pk;

    IF v_status = 'VARIANCE' THEN
        RAISE NOTICE 'VARIANCE on checkpoint id=% (%:% type:%). Expected=% Actual=% Diff=%',
            v_pk, p_entity_type, p_entity_id, p_checkpoint_type,
            v_expected, p_actual_count, v_variance;
    END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_resolve_checkpoint(varchar,int8,varchar,int4,varchar,int8) IS
    'Resolves the most-recent PENDING checkpoint for the given entity. '
    'Added p_vehicle_trip_id as an optional fast-path filter.';


-- =============================================================================
-- PART 1D — fn_acknowledge_correction_checkpoint
--            Supervisor sign-off function for CYLINDER_CORRECTION checkpoints.
--            Called after the supervisor verifies a serial correction is valid.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_acknowledge_correction_checkpoint(
    p_correction_log_id int8,
    p_acknowledged_by   varchar(200),
    p_remarks           varchar(500) DEFAULT NULL
)
RETURNS void AS $$
DECLARE
    v_checkpoint_id int8;
BEGIN
    -- Find the PENDING CYLINDER_CORRECTION checkpoint for this correction log row.
    -- The correction functions (PART 2 below) store the correction_log_id as
    -- reference_entity_id with entity_type = 'tbl_cylinder_correction_log'.
    SELECT pk_checkpoint_id INTO v_checkpoint_id
    FROM   public.tbl_reconciliation_checkpoint
    WHERE  reference_entity_type = 'tbl_cylinder_correction_log'
      AND  reference_entity_id   = p_correction_log_id
      AND  checkpoint_type       = 'CYLINDER_CORRECTION'
      AND  checkpoint_status     = 'PENDING'
    ORDER  BY created_at DESC
    LIMIT  1;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'No PENDING CYLINDER_CORRECTION checkpoint for correction_log_id=%. '
            'Either it was already acknowledged or the ID is wrong.',
            p_correction_log_id;
    END IF;

    -- The "actual_count" for a correction checkpoint is always 1 (one correction verified).
    UPDATE public.tbl_reconciliation_checkpoint
    SET    actual_count      = 1,
           checkpoint_status = 'MATCHED',
           resolved_at       = now(),
           remarks           = '[ACKNOWLEDGED by ' || p_acknowledged_by || '] '
                               || COALESCE(p_remarks, 'Correction verified as legitimate.')
    WHERE  pk_checkpoint_id  = v_checkpoint_id;

    RAISE NOTICE 'Correction checkpoint % acknowledged by %.', v_checkpoint_id, p_acknowledged_by;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_acknowledge_correction_checkpoint(int8,varchar,varchar) IS
    'Supervisor sign-off for a CYLINDER_CORRECTION reconciliation checkpoint. '
    'Every challan serial correction applied by fn_correct_order_line_cylinder '
    'or fn_correct_empty_pickup_line_cylinder creates a PENDING checkpoint. '
    'This function resolves it to MATCHED after supervisor review. '
    'Un-acknowledged corrections remain visible in vw_reconciliation_dashboard '
    'and vw_unverified_corrections until signed off.';


-- =============================================================================
-- PART 1E — Enhanced views
-- =============================================================================

-- ── Per-trip checkpoint matrix ────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.vw_trip_checkpoint_matrix AS
SELECT
    vt.pk_vehicle_trip_id                                   AS trip_id,
    vt.trip_started_at::date                                AS trip_date,
    ts.status_name                                          AS trip_status,
    rc.checkpoint_type,
    rc.trip_stop_sequence,
    rc.pk_checkpoint_id,
    rc.expected_count,
    rc.actual_count,
    rc.variance,
    rc.checkpoint_status,
    rc.escalation_threshold_hours,
    EXTRACT(HOUR FROM now() - rc.created_at)::int           AS age_hours,
    CASE
        WHEN rc.checkpoint_status = 'PENDING'
         AND EXTRACT(HOUR FROM now() - rc.created_at) > rc.escalation_threshold_hours
        THEN TRUE ELSE FALSE
    END                                                     AS overdue,
    rc.remarks,
    rc.created_at                                           AS gate_opened_at,
    rc.resolved_at                                          AS gate_closed_at
FROM   public.tbl_vehicle_trip             vt
JOIN   public.tbl_trip_status              ts ON ts.pk_trip_status_id = vt.fk_trip_status
LEFT   JOIN public.tbl_reconciliation_checkpoint rc
           ON  rc.fk_vehicle_trip  = vt.pk_vehicle_trip_id
ORDER  BY vt.trip_started_at DESC,
          vt.pk_vehicle_trip_id,
          rc.created_at;

COMMENT ON VIEW public.vw_trip_checkpoint_matrix IS
    'One row per checkpoint per trip. Shows the full event timeline for every '
    'trip: TRIP_LOAD_CONFIRMED → TRIP_DEPARTURE → TRIP_STOP_DELIVERY(×N) → '
    'TRIP_STOP_EMPTY_PICKUP(×M) → TRIP_RETURN_SCAN → TRIP_RETURN → TRIP_CLOSURE. '
    'overdue = TRUE flags any gate that has sat PENDING beyond its threshold. '
    'A fully clean trip has all gates at MATCHED with variance = 0.';

-- ── Unverified corrections (supervisor sign-off queue) ───────────────────────
CREATE OR REPLACE VIEW public.vw_unverified_corrections AS
SELECT
    rc.pk_checkpoint_id,
    rc.checkpoint_date,
    rc.created_at                                           AS correction_applied_at,
    EXTRACT(HOUR FROM now() - rc.created_at)::int           AS age_hours,
    cl.pk_correction_id,
    cl.correction_context,                                  -- ORDER_LINE or PICKUP_LINE
    cl.corrected_by,
    cl.reason,
    cl.wrong_cyl_state_at_correction,
    cl.correct_cyl_state_at_correction,
    cl.correction_action_summary,
    wc.cylinder_serial                                      AS wrong_serial,
    cc.cylinder_serial                                      AS correct_serial,
    vt.pk_vehicle_trip_id                                   AS trip_id,
    vt.trip_started_at::date                                AS trip_date,
    rc.remarks                                              AS checkpoint_remarks
FROM   public.tbl_reconciliation_checkpoint rc
JOIN   public.tbl_cylinder_correction_log   cl
           ON  cl.pk_correction_id = rc.reference_entity_id
          AND  rc.reference_entity_type = 'tbl_cylinder_correction_log'
JOIN   public.tbl_cylinder                  wc ON wc.pk_cylinder_id = cl.fk_wrong_cylinder
JOIN   public.tbl_cylinder                  cc ON cc.pk_cylinder_id = cl.fk_correct_cylinder
LEFT   JOIN public.tbl_reconciliation_checkpoint trip_gate
           ON  trip_gate.fk_vehicle_trip  = rc.fk_vehicle_trip
          AND  trip_gate.checkpoint_type  = 'TRIP_DEPARTURE'
LEFT   JOIN public.tbl_vehicle_trip         vt ON vt.pk_vehicle_trip_id = rc.fk_vehicle_trip
WHERE  rc.checkpoint_type   = 'CYLINDER_CORRECTION'
  AND  rc.checkpoint_status = 'PENDING'
ORDER  BY rc.created_at DESC;

COMMENT ON VIEW public.vw_unverified_corrections IS
    'All CYLINDER_CORRECTION checkpoints that have not yet been acknowledged by '
    'a supervisor. Call fn_acknowledge_correction_checkpoint(pk_correction_id, ...) '
    'to sign off. Corrections older than 48 hours without acknowledgement should '
    'be escalated.';

-- ── Refresh vw_reconciliation_dashboard to include new columns ───────────────
-- DROP required because the new SELECT inserts fk_vehicle_trip / fk_vehicle_load /
-- trip_stop_sequence before existing columns; CREATE OR REPLACE cannot reorder.
DROP VIEW IF EXISTS public.vw_reconciliation_dashboard;
CREATE OR REPLACE VIEW public.vw_reconciliation_dashboard AS
SELECT
    rc.pk_checkpoint_id,
    rc.checkpoint_date,
    rc.checkpoint_type,
    rc.reference_entity_type,
    rc.reference_entity_id,
    rc.fk_vehicle_trip,
    rc.fk_vehicle_load,
    rc.trip_stop_sequence,
    rc.expected_count,
    rc.actual_count,
    rc.variance,
    rc.checkpoint_status,
    rc.escalation_threshold_hours,
    EXTRACT(HOUR FROM now() - rc.created_at)::int           AS age_hours,
    CASE
        WHEN rc.checkpoint_status = 'PENDING'
         AND EXTRACT(HOUR FROM now() - rc.created_at) > rc.escalation_threshold_hours
        THEN TRUE ELSE FALSE
    END                                                     AS should_escalate,
    rc.remarks,
    rc.created_at
FROM   public.tbl_reconciliation_checkpoint rc
WHERE  rc.checkpoint_status IN ('PENDING', 'VARIANCE', 'ESCALATED')
ORDER  BY rc.checkpoint_date DESC, rc.created_at DESC;

COMMENT ON VIEW public.vw_reconciliation_dashboard IS
    'Live view of all open checkpoints. Now includes fk_vehicle_trip, '
    'fk_vehicle_load, and trip_stop_sequence so per-trip filtering is a '
    'single WHERE clause instead of a join on reference_entity_type.';

-- ── Refresh vw_daily_reconciliation_health ───────────────────────────────────
-- DROP required: new columns (loads_confirmed_clean, delivery_stops_with_variance,
-- pickup_stops_with_variance, corrections_awaiting_ack) are inserted in the middle
-- of the existing V61 column list; CREATE OR REPLACE cannot reorder columns.
DROP VIEW IF EXISTS public.vw_daily_reconciliation_health;
CREATE OR REPLACE VIEW public.vw_daily_reconciliation_health AS
SELECT
    rc.checkpoint_date,
    COUNT(DISTINCT rc.fk_vehicle_trip)
        FILTER (WHERE rc.checkpoint_type = 'TRIP_DEPARTURE')               AS trips_departed,
    COUNT(*)
        FILTER (WHERE rc.checkpoint_type = 'TRIP_LOAD_CONFIRMED'
                  AND rc.checkpoint_status = 'MATCHED')                     AS loads_confirmed_clean,
    COUNT(*)
        FILTER (WHERE rc.checkpoint_type = 'TRIP_RETURN'
                  AND rc.checkpoint_status = 'MATCHED')                     AS trips_returned_clean,
    COUNT(*)
        FILTER (WHERE rc.checkpoint_type = 'TRIP_RETURN'
                  AND rc.checkpoint_status = 'VARIANCE')                    AS trips_with_variance,
    COUNT(*)
        FILTER (WHERE rc.checkpoint_type = 'TRIP_STOP_DELIVERY'
                  AND rc.checkpoint_status = 'VARIANCE')                    AS delivery_stops_with_variance,
    COUNT(*)
        FILTER (WHERE rc.checkpoint_type = 'TRIP_STOP_EMPTY_PICKUP'
                  AND rc.checkpoint_status = 'VARIANCE')                    AS pickup_stops_with_variance,
    COUNT(*)
        FILTER (WHERE rc.checkpoint_type = 'CYLINDER_CORRECTION'
                  AND rc.checkpoint_status = 'PENDING')                     AS corrections_awaiting_ack,
    COUNT(*)
        FILTER (WHERE rc.checkpoint_type = 'TRIP_DEPARTURE'
                  AND rc.checkpoint_status = 'PENDING')                     AS trips_not_yet_returned,
    COUNT(*)
        FILTER (WHERE rc.checkpoint_type = 'YARD_AUDIT'
                  AND rc.checkpoint_status = 'MATCHED')                     AS audits_clean,
    COUNT(*)
        FILTER (WHERE rc.checkpoint_status = 'VARIANCE')                    AS total_variances,
    MAX(CASE WHEN rc.checkpoint_type = 'DAILY_CLOSING'
             THEN rc.checkpoint_status END)                                  AS day_close_status
FROM   public.tbl_reconciliation_checkpoint rc
GROUP  BY rc.checkpoint_date
ORDER  BY rc.checkpoint_date DESC;

COMMENT ON VIEW public.vw_daily_reconciliation_health IS
    'Day-level summary. A fully clean day: trips_returned_clean = trips_departed, '
    'trips_not_yet_returned = 0, delivery_stops_with_variance = 0, '
    'corrections_awaiting_ack = 0, total_variances = 0, day_close_status = MATCHED.';


-- =============================================================================
-- PART 2 — Wire V75 correction functions into the orchestrator
--           Replace both correction functions to emit CYLINDER_CORRECTION
--           checkpoints after every successful correction.
--
-- The correction checkpoint contract:
--   expected_count = 1   (one correction event to be verified)
--   actual_count   = 1   (set by fn_acknowledge_correction_checkpoint)
--   entity_type        = 'tbl_cylinder_correction_log'
--   entity_id          = pk_correction_id (just inserted)
--   fk_vehicle_trip    = trip of the order/pickup load (informational)
--   threshold          = 48 hours (supervisor has 48h to acknowledge)
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

    -- Vehicle load (informational — no longer a hard gate)
    v_wrong_load_id             int8;
    v_correct_load_id           int8;
    v_same_load                 bool := false;

    -- Trip (for correction checkpoint)
    v_vehicle_trip_id           int8;

    -- Correction log
    v_correction_log_id         int8;

    -- Action summary
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

    -- ── 5. Resolve load IDs and trip ID (informational) ─────────────────────
    SELECT vll.fk_vehicle_load, vl.fk_vehicle_trip
    INTO   v_wrong_load_id, v_vehicle_trip_id
    FROM   public.tbl_vehicle_load_line vll
    JOIN   public.tbl_vehicle_load      vl  ON vl.pk_vehicle_load_id = vll.fk_vehicle_load
    WHERE  vll.fk_cylinder = p_wrong_cyl_id
    ORDER  BY vll.pk_vehicle_load_line_id DESC
    LIMIT  1;

    SELECT fk_vehicle_load INTO v_correct_load_id
    FROM   public.tbl_vehicle_load_line
    WHERE  fk_cylinder = p_correct_cyl_id
    ORDER  BY pk_vehicle_load_line_id DESC
    LIMIT  1;

    v_same_load := (v_wrong_load_id IS NOT NULL
                    AND v_correct_load_id IS NOT NULL
                    AND v_wrong_load_id = v_correct_load_id);

    -- ── 6. Swap fk_cylinder on the order line ────────────────────────────────
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
               fk_current_vehicle_load     = v_wrong_load_id,
               fk_last_order               = v_order_id,
               updated_at                  = now()
        WHERE  fk_cylinder = p_wrong_cyl_id;

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
            '[CORRECTION-NOTE] Wrong cylinder was incorrectly entered on order_line '
                || p_order_line_id || ' (customer ' || v_order_customer_id || '). '
                || 'Cylinder is currently DELIVERED at a different customer ('
                || COALESCE(v_wrong_holder_customer::text, 'NULL') || '). '
                || 'State NOT changed — that delivery may be legitimate. '
                || 'Correct cylinder: ' || p_correct_cyl_id || '. Reason: ' || p_reason
        );

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
        -- ── Case C-2: Already DELIVERED at THIS customer ──────────────────────
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
                || ' but is now DELIVERED at a different customer ('
                || COALESCE(v_correct_holder_customer::text, 'NULL') || '). '
                || 'Retroactive delivery note. Current state NOT changed. '
                || 'Reason: ' || p_reason
        );

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

    -- ── 9. Write the correction log row ──────────────────────────────────────
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
    )
    RETURNING pk_correction_id INTO v_correction_log_id;

    -- ── 10. NEW ─ Emit a CYLINDER_CORRECTION reconciliation checkpoint ────────
    --  • expected_count = 1  (one correction event)
    --  • actual_count   = NULL  (supervisor must call fn_acknowledge_correction_checkpoint)
    --  • threshold      = 48 hours
    PERFORM public.fn_create_checkpoint(
        'CYLINDER_CORRECTION',
        'tbl_cylinder_correction_log',
        v_correction_log_id,
        1,                              -- expected_count = 1
        48,                             -- 48-hour supervisor ack window
        'ORDER_LINE correction: wrong=' || p_wrong_cyl_id
            || ' correct=' || p_correct_cyl_id
            || ' corrected_by=' || p_corrected_by
            || ' action=' || v_action_summary,
        NULL,                           -- checkpoint_date = today
        v_vehicle_trip_id,              -- link to the originating trip
        v_wrong_load_id,                -- link to the originating load
        NULL                            -- stop_sequence not applicable
    );

END;
$$;

COMMENT ON FUNCTION public.fn_correct_order_line_cylinder(int8,int8,int8,varchar,varchar) IS
    'V76 — State-tolerant delivery line correction (V75 logic preserved). '
    'Now emits a CYLINDER_CORRECTION reconciliation checkpoint after every '
    'successful correction. The checkpoint stays PENDING until a supervisor '
    'calls fn_acknowledge_correction_checkpoint(correction_log_id, ...). '
    'Only hard stop: is_invoiced = true.';


-- ── fn_correct_empty_pickup_line_cylinder — same pattern ─────────────────────
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

    -- Trip/load (for checkpoint)
    v_vehicle_load_id           int8;
    v_vehicle_trip_id           int8;

    -- Correction log
    v_correction_log_id         int8;

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

    -- ── 4b. Resolve load/trip for checkpoint ─────────────────────────────────
    SELECT vll.fk_vehicle_load, vl.fk_vehicle_trip
    INTO   v_vehicle_load_id, v_vehicle_trip_id
    FROM   public.tbl_vehicle_load_line vll
    JOIN   public.tbl_vehicle_load      vl ON vl.pk_vehicle_load_id = vll.fk_vehicle_load
    WHERE  vll.fk_cylinder = p_wrong_cyl_id
    ORDER  BY vll.pk_vehicle_load_line_id DESC
    LIMIT  1;

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
            NULL, now(),
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
        -- ── Case W-3: Any other state ─────────────────────────────────────────
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
            NULL, now(),
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
        -- ── Case C-2: Already EMPTY_IN_TRANSIT ─────────────────────────────────
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
        -- ── Case C-4: EMPTY / FULL / yard state ───────────────────────────────
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
    )
    RETURNING pk_correction_id INTO v_correction_log_id;

    -- ── 9. NEW — Emit a CYLINDER_CORRECTION reconciliation checkpoint ─────────
    PERFORM public.fn_create_checkpoint(
        'CYLINDER_CORRECTION',
        'tbl_cylinder_correction_log',
        v_correction_log_id,
        1,
        48,
        'PICKUP_LINE correction: wrong=' || p_wrong_cyl_id
            || ' correct=' || p_correct_cyl_id
            || ' corrected_by=' || p_corrected_by
            || ' action=' || v_action_summary,
        NULL,
        v_vehicle_trip_id,
        v_vehicle_load_id,
        NULL
    );

END;
$$;

COMMENT ON FUNCTION public.fn_correct_empty_pickup_line_cylinder(int8,int8,int8,varchar,varchar) IS
    'V76 — State-tolerant pickup line correction (V75 logic preserved). '
    'Now emits a CYLINDER_CORRECTION reconciliation checkpoint that requires '
    'supervisor acknowledgement via fn_acknowledge_correction_checkpoint(). '
    'Only hard stop: is_invoiced = true.';


-- =============================================================================
-- PART 3 — Yard stock check line: add fk_system_cylinder_state column
--           and update the state-match trigger to populate it.
--
-- Why a FK column rather than just reading current_status at query time?
--   tbl_cylinder_current_status changes every time the cylinder moves.
--   After the audit closes, the system state row no longer reflects what the
--   system believed at scan time. Storing fk_system_cylinder_state on the
--   line makes every scan row a self-contained historical record.
--
-- state_matches_system (boolean) remains trigger-computed — not a generated
--   column — so the match logic can be refined without a schema migration.
-- =============================================================================

-- ── 3A. Add the new columns ───────────────────────────────────────────────────
ALTER TABLE public.tbl_yard_stock_check_line
    ADD COLUMN IF NOT EXISTS fk_system_cylinder_state int8 NULL,
    ADD COLUMN IF NOT EXISTS system_state_name        varchar(100) NULL;

ALTER TABLE public.tbl_yard_stock_check_line
    ADD CONSTRAINT tbl_yard_stock_check_line_sys_state_fk
    FOREIGN KEY (fk_system_cylinder_state)
    REFERENCES public.tbl_cylinder_states(pk_cylinder_state_id);

COMMENT ON COLUMN public.tbl_yard_stock_check_line.fk_system_cylinder_state IS
    'FK to tbl_cylinder_states. Captures the system-recorded state of this cylinder '
    'at the exact moment it was scanned during the yard audit. '
    'Set by trigger fn_evaluate_yard_line_state_match (BEFORE INSERT). '
    'Immutable after insert — provides a point-in-time state snapshot '
    'even after tbl_cylinder_current_status changes.';

COMMENT ON COLUMN public.tbl_yard_stock_check_line.system_state_name IS
    'Denormalised copy of tbl_cylinder_states.cylinder_state at scan time. '
    'Stored alongside fk_system_cylinder_state so audit reports can read '
    'the state name without a join even if the states table is altered later.';

COMMENT ON COLUMN public.tbl_yard_stock_check_line.state_matches_system IS
    'TRUE  = auditor''s observed_state is consistent with fk_system_cylinder_state. '
    'FALSE = mismatch (e.g. system says FULL, auditor sees EMPTY) — a variance row '
    'is written to tbl_yard_stock_variance automatically by the trigger. '
    'NULL  = observed_state was not supplied for this scan line. '
    'Always trigger-computed (BEFORE INSERT); never set by application code.';

-- ── 3B. Replace the trigger function (V60 version) ───────────────────────────
--        Enhancement: also populate fk_system_cylinder_state and system_state_name.
CREATE OR REPLACE FUNCTION public.fn_evaluate_yard_line_state_match()
RETURNS TRIGGER AS $$
DECLARE
    v_system_state_id    int8;
    v_system_state_name  varchar(100);
    v_system_location    varchar(100);
    v_matches            boolean;
    v_stock_check_id     int8;
BEGIN
    -- ── Always capture the system state, even if observed_state is NULL ───────
    --    fk_current_state is the PK of tbl_cylinder_states, so we select it
    --    once and project both the ID and the human-readable name.
    SELECT ccs.fk_current_state,
           cs.cylinder_state,
           cs.location
    INTO   v_system_state_id,
           v_system_state_name,
           v_system_location
    FROM   public.tbl_cylinder_current_status ccs
    JOIN   public.tbl_cylinder_states cs
           ON cs.pk_cylinder_state_id = ccs.fk_current_state
    WHERE  ccs.fk_cylinder = NEW.fk_cylinder;

    IF NOT FOUND THEN
        -- Cylinder has no current_status record — flag as a variance
        v_system_state_id   := NULL;
        v_system_state_name := 'NO_STATUS_RECORD';
        v_system_location   := 'UNKNOWN';
    END IF;

    -- ── Persist the point-in-time system state snapshot ───────────────────────
    NEW.fk_system_cylinder_state := v_system_state_id;
    NEW.system_state_name        := v_system_state_name;

    -- ── Evaluate the match only if the auditor supplied an observed_state ──────
    IF NEW.observed_state IS NULL THEN
        -- No observed state → cannot evaluate match; leave state_matches_system NULL
        RETURN NEW;
    END IF;

    IF v_system_state_name = 'NO_STATUS_RECORD' THEN
        -- Cannot match if there is no system record
        v_matches := FALSE;
    ELSE
        -- Map observed physical state to acceptable system state names.
        -- FULL   in the yard → system may also say FULL_PICKED_FROM_SUPPLIER
        --                       or FULL_PICKED_UP_FOR_DELIVERY (still on vehicle)
        -- EMPTY  in the yard → system may also say EMPTY_IN_TRANSIT_TO_YARD
        --                       or COMMISSIONED (just entered the fleet)
        -- DAMAGED            → only DAMAGED is acceptable
        -- UNKNOWN            → auditor could not determine; treated as mismatch
        v_matches := CASE NEW.observed_state
            WHEN 'FULL'    THEN v_system_state_name IN (
                                    'FULL',
                                    'FULL_PICKED_FROM_SUPPLIER',
                                    'FULL_PICKED_UP_FOR_DELIVERY'
                                )
            WHEN 'EMPTY'   THEN v_system_state_name IN (
                                    'EMPTY',
                                    'EMPTY_IN_TRANSIT_TO_YARD',
                                    'COMMISSIONED'
                                )
            WHEN 'DAMAGED' THEN v_system_state_name = 'DAMAGED'
            ELSE FALSE   -- UNKNOWN observed state → cannot confirm match
        END;
    END IF;

    NEW.state_matches_system := v_matches;

    -- ── Write a variance row on mismatch ─────────────────────────────────────
    IF NOT v_matches THEN
        v_stock_check_id := NEW.fk_stock_check;

        INSERT INTO public.tbl_yard_stock_variance (
            pk_variance_id,
            fk_stock_check,
            fk_cylinder,
            variance_type,
            system_state,
            system_location,
            variance_status,
            resolution_remarks
        ) VALUES (
            nextval('public.pk_stock_yard_variance_id_serial'),
            v_stock_check_id,
            NEW.fk_cylinder,
            'UNEXPECTED_STATE',
            COALESCE(v_system_state_name, 'UNKNOWN'),
            COALESCE(v_system_location,   'UNKNOWN'),
            'OPEN',
            'Auditor observed ' || NEW.observed_state
                || ' but system records state as '
                || COALESCE(v_system_state_name, 'NO_STATUS')
                || '. System state FK: '
                || COALESCE(v_system_state_id::text, 'NULL')
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- The trigger itself (already named trg_evaluate_yard_line_state_match in V60)
-- does not need to be recreated — replacing the function is sufficient because
-- the trigger references the function by name, not body.
-- If for any reason the trigger was dropped, recreate it:
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'trg_evaluate_yard_line_state_match'
    ) THEN
        CREATE TRIGGER trg_evaluate_yard_line_state_match
        BEFORE INSERT ON public.tbl_yard_stock_check_line
        FOR EACH ROW
        EXECUTE FUNCTION public.fn_evaluate_yard_line_state_match();
    END IF;
END;
$$;

COMMENT ON FUNCTION public.fn_evaluate_yard_line_state_match() IS
    'V76 enhanced version. '
    'Runs BEFORE INSERT on tbl_yard_stock_check_line. '
    'Always sets fk_system_cylinder_state + system_state_name from '
    'tbl_cylinder_current_status at the moment of the scan, regardless of '
    'whether observed_state is supplied. '
    'If observed_state IS provided: evaluates state_matches_system (boolean) '
    'and writes a UNEXPECTED_STATE variance row to tbl_yard_stock_variance '
    'on mismatch. '
    'state_matches_system is never set by application code — trigger-owned.';


-- =============================================================================
-- PART 3C — Enhanced yard audit line view that exposes all new columns
-- =============================================================================
CREATE OR REPLACE VIEW public.vw_yard_audit_scan_detail AS
SELECT
    ysl.pk_stock_check_line_id,
    ysc.check_date,
    ysc.audit_context,
    ysc.checked_by,
    c.cylinder_serial,
    -- Physical observation
    ysl.observed_state,
    -- System state at scan time (point-in-time snapshot — does not change)
    ysl.fk_system_cylinder_state,
    ysl.system_state_name         AS system_state_at_scan,
    cs_now.cylinder_state         AS system_state_now,    -- current state (may differ)
    -- Match evaluation
    ysl.state_matches_system,
    -- Auditor notes
    ysl.auditor_notes,
    ysl.scanned_at,
    -- Variance
    v.pk_variance_id              AS variance_id,
    v.variance_status
FROM   public.tbl_yard_stock_check_line      ysl
JOIN   public.tbl_yard_stock_check           ysc ON ysc.pk_stock_check_id = ysl.fk_stock_check
JOIN   public.tbl_cylinder                   c   ON c.pk_cylinder_id      = ysl.fk_cylinder
LEFT   JOIN public.tbl_cylinder_states       cs_now
           ON cs_now.pk_cylinder_state_id = (
               SELECT fk_current_state
               FROM   public.tbl_cylinder_current_status
               WHERE  fk_cylinder = ysl.fk_cylinder
           )
LEFT   JOIN public.tbl_yard_stock_variance   v
           ON  v.fk_cylinder    = ysl.fk_cylinder
          AND  v.fk_stock_check = ysl.fk_stock_check
          AND  v.variance_type  = 'UNEXPECTED_STATE'
ORDER  BY ysc.check_date DESC, ysl.scanned_at;

COMMENT ON VIEW public.vw_yard_audit_scan_detail IS
    'Full detail for every yard audit scan line. '
    'system_state_at_scan = state recorded by the system at the moment of scan '
    '(immutable — persisted in fk_system_cylinder_state + system_state_name). '
    'system_state_now = the cylinder''s current system state (may differ if the '
    'cylinder moved after the audit). '
    'Rows where system_state_at_scan != system_state_now and state_matches_system = TRUE '
    'indicate the cylinder moved after the audit was clean — worth monitoring.';


-- =============================================================================
-- USAGE EXAMPLES
-- =============================================================================
--
-- 1. Apply a delivery serial correction:
--
--   SELECT public.fn_correct_order_line_cylinder(
--       1042,       -- pk_order_line_id
--       88,         -- wrong cylinder (e.g. 609)
--       91,         -- correct cylinder (e.g. 906)
--       'Loadman transposed digits 906 → 609 on challan 2026-05-12',
--       'office.user@company.com'
--   );
--   -- A PENDING CYLINDER_CORRECTION checkpoint is now in vw_unverified_corrections.
--
-- 2. Supervisor sign-off:
--
--   SELECT public.fn_acknowledge_correction_checkpoint(
--       <pk_correction_id from vw_unverified_corrections>,
--       'supervisor.name@company.com',
--       'Confirmed with customer — 906 was indeed delivered.'
--   );
--
-- 3. Check per-trip gate status:
--
--   SELECT * FROM public.vw_trip_checkpoint_matrix
--   WHERE  trip_id = 77
--   ORDER  BY gate_opened_at;
--
-- 4. See the full yard scan record with system state at scan time:
--
--   SELECT cylinder_serial,
--          observed_state,
--          system_state_at_scan,
--          system_state_now,
--          state_matches_system,
--          variance_id
--   FROM   public.vw_yard_audit_scan_detail
--   WHERE  check_date = '2026-05-12'
--   ORDER  BY scanned_at;
--
-- 5. Create a TRIP_STOP_DELIVERY checkpoint for stop 3 on trip 77:
--    (Called by the application when the office user submits a delivery challan)
--
--   SELECT public.fn_create_checkpoint(
--       'TRIP_STOP_DELIVERY',
--       'tbl_order',
--       <order_id>,
--       <cylinder_count_on_this_challan>,
--       4,                              -- 4-hour resolution window
--       'Customer delivery challan posted for trip 77 stop 3',
--       CURRENT_DATE,
--       77,                             -- fk_vehicle_trip_id
--       <vehicle_load_id>,
--       3                               -- stop sequence
--   );
-- =============================================================================