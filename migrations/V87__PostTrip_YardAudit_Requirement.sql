-- =============================================================================
-- V87__PostTrip_YardAudit_Requirement.sql
-- =============================================================================
-- PURPOSE:
--   Enforce that a yard audit occurs after every trip return.
--
-- BUSINESS RULE:
--   After a trip returns (TRIP_RETURN checkpoint matched), the yard count
--   should reflect:
--       expected_yard_after_trip =
--           daily_opening (opening_yard_full + opening_yard_empty)
--           − SUM(cylinders loaded on ALL trips that departed today)
--           + SUM(empty cylinders collected by today's trips)
--
--   If a YARD_AUDIT checkpoint for today does not exist, or exists but is
--   still PENDING more than `p_threshold_hours` after the last TRIP_RETURN,
--   it is escalated with a clear warning message.
--
-- IMPLEMENTATION:
--   PART 1 — fn_require_yard_audit_after_trip_return
--             Fires AFTER UPDATE on tbl_reconciliation_checkpoint when a
--             TRIP_RETURN transitions to MATCHED. It either creates a new
--             YARD_AUDIT checkpoint for today (if none exists) or escalates
--             the existing PENDING one with the updated expected count.
--
--   PART 2 — fn_escalate_pending_yard_audits
--             Scheduled / manually callable function that escalates any
--             YARD_AUDIT checkpoint still PENDING after its threshold,
--             particularly those that have gone unresolved after a trip return.
--
--   PART 3 — vw_post_trip_yard_audit_status
--             Dashboard view: for every trip today, shows whether a yard audit
--             has been done, what the expected count was, and whether it matched.
-- =============================================================================


-- =============================================================================
-- PART 1 — Trigger function: require yard audit after trip return
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_require_yard_audit_after_trip_return()
RETURNS TRIGGER AS $$
DECLARE
    v_trip_id           int8;
    v_today             date;
    v_daily_count_id    int8;
    v_opening_yard      int4 := 0;
    v_total_loaded      int4 := 0;
    v_total_returned    int4 := 0;
    v_expected_yard     int4;
    v_existing_audit_id int8;
    v_warning_text      varchar(500);
BEGIN
    -- Only react when a TRIP_RETURN checkpoint transitions TO matched
    IF NEW.checkpoint_type  <> 'TRIP_RETURN'  THEN RETURN NEW; END IF;
    IF NEW.checkpoint_status <> 'MATCHED'       THEN RETURN NEW; END IF;
    IF OLD.checkpoint_status  = 'MATCHED'       THEN RETURN NEW; END IF; -- already processed

    v_trip_id := NEW.fk_vehicle_trip;
    v_today   := NEW.checkpoint_date;

    -- ── 1. Pull today's opening yard count ───────────────────────────────────
    SELECT pk_daily_count_id,
           COALESCE(opening_yard_full, 0) + COALESCE(opening_yard_empty, 0)
      INTO v_daily_count_id, v_opening_yard
      FROM public.tbl_daily_cylinder_count
     WHERE count_date = v_today;

    IF v_daily_count_id IS NULL THEN
        RAISE NOTICE '[PostTripYardAudit] No daily count row for %. Skipping.', v_today;
        RETURN NEW;
    END IF;

    -- ── 2. Sum all cylinders loaded on trips that departed today ─────────────
    --       (all TRIP_DEPARTURE checkpoints for today, matched or not)
    SELECT COALESCE(SUM(expected_count), 0)
      INTO v_total_loaded
      FROM public.tbl_reconciliation_checkpoint
     WHERE checkpoint_type = 'TRIP_DEPARTURE'
       AND checkpoint_date = v_today;

    -- ── 3. Sum cylinders accounted for on returned trips today ───────────────
    --       (TRIP_RETURN checkpoints that are now MATCHED — actual_count =
    --        deliveries + empty pickups, so these cylinders left the yard)
    SELECT COALESCE(SUM(actual_count), 0)
      INTO v_total_returned
      FROM public.tbl_reconciliation_checkpoint
     WHERE checkpoint_type   = 'TRIP_RETURN'
       AND checkpoint_status = 'MATCHED'
       AND checkpoint_date   = v_today;

    -- ── 4. Compute expected yard total ───────────────────────────────────────
    --       = opening yard
    --         − cylinders that went out on trips (expected_count of departures)
    --         + cylinders confirmed back (actual_count of matched returns)
    --
    --   Note: this intentionally uses expected_count for departures (the load
    --   declaration) and actual_count for returns (what was physically verified).
    --   Any gap becomes the variance on the YARD_AUDIT checkpoint.
    v_expected_yard := v_opening_yard - v_total_loaded + v_total_returned;

    v_warning_text :=
        'POST-TRIP YARD AUDIT REQUIRED. '
        || 'Opening yard: '    || v_opening_yard
        || ', Loaded out: '    || v_total_loaded
        || ', Returned: '      || v_total_returned
        || ', Expected now: '  || v_expected_yard
        || '. Triggered by trip ' || v_trip_id || ' RETURN.';

    -- ── 5. Check whether a YARD_AUDIT checkpoint already exists for today ────
    SELECT pk_checkpoint_id
      INTO v_existing_audit_id
      FROM public.tbl_reconciliation_checkpoint
     WHERE checkpoint_type = 'YARD_AUDIT'
       AND checkpoint_date = v_today
     ORDER BY created_at DESC
     LIMIT 1;

    IF v_existing_audit_id IS NULL THEN
        -- No yard audit at all today — create a PENDING one as a reminder
        PERFORM public.fn_create_checkpoint(
            'YARD_AUDIT',
            'tbl_daily_cylinder_count',
            v_daily_count_id,
            v_expected_yard,
            4,   -- escalate after 4 hours if still PENDING
            v_warning_text,
            v_today,
            NULL,   -- not trip-specific
            NULL,
            NULL
        );
    ELSE
        -- Audit row exists — update expected_count to reflect post-trip reality
        -- and refresh the warning in remarks so the auditor sees the latest numbers
        UPDATE public.tbl_reconciliation_checkpoint
           SET expected_count = v_expected_yard,
               remarks        = v_warning_text
         WHERE pk_checkpoint_id = v_existing_audit_id
           AND checkpoint_status = 'PENDING';  -- don't touch already-resolved audits
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_require_yard_audit_after_trip_return() IS
    'Fires AFTER UPDATE on tbl_reconciliation_checkpoint when a TRIP_RETURN '
    'transitions to MATCHED. Creates (or updates) a YARD_AUDIT checkpoint for '
    'today with expected_count = opening_yard − total_loaded + total_returned. '
    'If the audit is not performed within 4 hours it auto-escalates.';

-- Wire the trigger
DROP TRIGGER IF EXISTS trg_require_yard_audit_after_trip_return
    ON public.tbl_reconciliation_checkpoint;

CREATE TRIGGER trg_require_yard_audit_after_trip_return
AFTER UPDATE OF checkpoint_status
ON public.tbl_reconciliation_checkpoint
FOR EACH ROW
EXECUTE FUNCTION public.fn_require_yard_audit_after_trip_return();


-- =============================================================================
-- PART 2 — fn_escalate_pending_yard_audits (call from a scheduler / cron)
-- =============================================================================
-- Escalates any YARD_AUDIT checkpoint that is still PENDING after its
-- escalation_threshold_hours since creation. Intended to be called nightly
-- (or by a Spring @Scheduled task) so operations managers are alerted.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_escalate_pending_yard_audits()
RETURNS int4 AS $$
DECLARE
    v_count int4 := 0;
BEGIN
    UPDATE public.tbl_reconciliation_checkpoint
       SET checkpoint_status = 'ESCALATED',
           escalated_at      = now(),
           remarks           = COALESCE(remarks, '')
                               || ' | AUTO-ESCALATED: yard audit overdue. '
                               || 'No physical count performed within threshold.'
     WHERE checkpoint_type   = 'YARD_AUDIT'
       AND checkpoint_status = 'PENDING'
       AND created_at + (escalation_threshold_hours || ' hours')::interval < now();

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_escalate_pending_yard_audits() IS
    'Escalates PENDING YARD_AUDIT checkpoints that have exceeded their '
    'escalation_threshold_hours. Returns the number of rows escalated. '
    'Call from a nightly job or Spring @Scheduled task.';


-- =============================================================================
-- PART 3 — vw_post_trip_yard_audit_status
-- For every trip today: did the required yard audit happen? Did it balance?
-- =============================================================================

CREATE OR REPLACE VIEW public.vw_post_trip_yard_audit_status AS
WITH trip_returns AS (
    SELECT
        rc.fk_vehicle_trip,
        rc.checkpoint_date,
        rc.actual_count                         AS cylinders_accounted,
        rc.expected_count                       AS cylinders_loaded,
        rc.checkpoint_status                    AS return_status,
        rc.resolved_at                          AS returned_at
      FROM public.tbl_reconciliation_checkpoint rc
     WHERE rc.checkpoint_type = 'TRIP_RETURN'
),
yard_audits AS (
    SELECT
        ya.checkpoint_date,
        ya.checkpoint_status                    AS audit_status,
        ya.expected_count                       AS audit_expected,
        ya.actual_count                         AS audit_actual,
        ya.variance                             AS audit_variance,
        ya.resolved_at                          AS audit_done_at,
        ya.escalated_at,
        ya.remarks                              AS audit_remarks
      FROM public.tbl_reconciliation_checkpoint ya
     WHERE ya.checkpoint_type = 'YARD_AUDIT'
)
SELECT
    tr.fk_vehicle_trip                          AS trip_id,
    tr.checkpoint_date                          AS trip_date,
    tr.return_status,
    tr.returned_at,
    tr.cylinders_loaded,
    tr.cylinders_accounted,
    (tr.cylinders_loaded - COALESCE(tr.cylinders_accounted, 0))
                                                AS unaccounted_cylinders,

    -- Yard audit columns (NULL if no audit for the day)
    ya.audit_status,
    ya.audit_expected,
    ya.audit_actual,
    ya.audit_variance,
    ya.audit_done_at,
    ya.escalated_at                             AS audit_escalated_at,

    -- Warning flags
    CASE
        WHEN ya.audit_status IS NULL
        THEN 'NO_AUDIT'                         -- trip returned, no yard audit at all
        WHEN ya.audit_status = 'PENDING'
        THEN 'AUDIT_PENDING'                    -- audit created but not yet done
        WHEN ya.audit_status = 'ESCALATED'
        THEN 'AUDIT_OVERDUE'                    -- threshold passed with no count
        WHEN ya.audit_status = 'VARIANCE'
        THEN 'AUDIT_VARIANCE'                   -- count done but mismatch found
        WHEN ya.audit_status = 'MATCHED'
        THEN 'OK'
        ELSE ya.audit_status
    END                                         AS yard_audit_flag,

    ya.audit_remarks
FROM   trip_returns tr
LEFT   JOIN yard_audits ya ON ya.checkpoint_date = tr.checkpoint_date
ORDER  BY tr.checkpoint_date DESC, tr.fk_vehicle_trip;

COMMENT ON VIEW public.vw_post_trip_yard_audit_status IS
    'Per-trip audit compliance view. For every TRIP_RETURN, shows whether '
    'the required post-trip YARD_AUDIT happened, what the expected count was '
    '(opening − loaded + returned), and whether it balanced. '
    'yard_audit_flag = NO_AUDIT means the physical count was never entered '
    'after the trip returned — an operational gap requiring immediate attention.';
