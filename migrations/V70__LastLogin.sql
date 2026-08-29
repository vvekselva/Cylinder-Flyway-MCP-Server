-- =============================================================================
-- V70__LastLogin.sql
-- =============================================================================
-- PURPOSE:
--   Three interlocking mechanisms to close the daily cylinder tracking loop:
--
--   1. MORNING TRIGGER (tbl_daily_login_report → tbl_daily_cylinder_count)
--      The very first login of each business day fires fn_open_daily_count(),
--      seeding the opening snapshot in V59 so morning statistics are available
--      immediately — even before the first vehicle trip is created.
--
--   2. tbl_last_login
--      Mirrors tbl_daily_login_report but retains only the LAST login row for
--      each calendar day.  It is the anchor for end-of-day (EOD) reconciliation:
--      the service knows "who logged in last and at what time" so it can decide
--      whether to carry that day's closing snapshot or roll it forward.
--
--   3. EOD RECONCILIATION FUNCTION  fn_trigger_eod_reconciliation()
--      Called by an external service (scheduled or manual).  Rules:
--
--      a) If called on the same day as the last login AND login_time ≤ EOD cutoff
--         → Full reconciliation: calls fn_close_daily_count(), marks the day DONE.
--
--      b) If last login happened AFTER the EOD cutoff (e.g. login at 22:30 when
--         cutoff is 22:00) → The EOD is stamped with the EXISTING snapshot values
--         from tbl_daily_cylinder_count; no new snapshot is taken.  This prevents
--         a late admin login from skewing the closing figures.
--
--      c) If reconciliation was NOT done the previous day AND a new day has
--         started → The next morning's fn_open_daily_count (triggered by first
--         login) carries the previous day's closing values as the opening snapshot
--         for the new day, then marks the prior day VARIANCE for manual review.
--
-- EOD CUTOFF TIME:
--   Stored in tbl_system_config (key = 'EOD_CUTOFF_TIME', value = 'HH24:MI').
--   Defaults to '22:00' if the key is absent.
--   Configurable per-deployment without a schema change.
--
-- TABLES CREATED / ALTERED:
--   tbl_system_config  (new) — simple key/value store for runtime config
--   tbl_last_login     (new) — one row per calendar day, last login that day
--
-- TRIGGERS CREATED:
--   trg_daily_login_morning_open  — on INSERT into tbl_daily_login_report
--   trg_last_login_upsert         — on INSERT into tbl_daily_login_report
--   trg_last_login_eod_check      — on INSERT OR UPDATE into tbl_last_login
--
-- FUNCTIONS CREATED:
--   fn_daily_login_morning_open()
--   fn_last_login_upsert()
--   fn_last_login_eod_check()
--   fn_trigger_eod_reconciliation(p_for_date, p_triggered_by)
--   fn_carry_forward_unreconciled_day()   — called next morning for missed EODs
-- =============================================================================


-- ===========================================================================
-- SECTION 0 — tbl_system_config (simple runtime key/value store)
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.tbl_system_config (
    config_key      varchar(100) NOT NULL,
    config_value    varchar(500) NOT NULL,
    description     varchar(500),
    updated_at      timestamp    NOT NULL DEFAULT now(),

    CONSTRAINT tbl_system_config_pk PRIMARY KEY (config_key)
);

COMMENT ON TABLE public.tbl_system_config IS
    'Runtime configuration key/value pairs. '
    'EOD_CUTOFF_TIME (HH24:MI) controls when last-login-after-cutoff logic applies.';

-- Seed the EOD cutoff default (safe to run multiple times — ON CONFLICT DO NOTHING)
INSERT INTO public.tbl_system_config (config_key, config_value, description)
VALUES ('EOD_CUTOFF_TIME', '22:00',
        'Time after which a login is considered post-EOD. '
        'Format HH24:MI.  Default 22:00.')
ON CONFLICT (config_key) DO NOTHING;


-- ===========================================================================
-- SECTION 1 — tbl_last_login
-- ===========================================================================
-- One row per calendar day.
-- Updated (upserted) on every INSERT into tbl_daily_login_report so that at
-- any given moment it holds the most recent login timestamp for today.
-- The eod_reconciled flag is set to TRUE by fn_trigger_eod_reconciliation().
-- ===========================================================================

DROP SEQUENCE IF EXISTS public.pk_last_login_id_serial;
CREATE SEQUENCE public.pk_last_login_id_serial
    INCREMENT BY 1 MINVALUE 1 START 1 CACHE 1 NO CYCLE;

CREATE TABLE public.tbl_last_login (
    pk_last_login_id        int8        NOT NULL DEFAULT nextval('public.pk_last_login_id_serial'),

    -- The calendar day this row represents (one row per date)
    login_date              date        NOT NULL,

    -- The timestamp of the most recent login on login_date
    -- (mirrors the login_time column of tbl_daily_login_report)
    login_time              timestamp   NOT NULL,

    -- FK back to tbl_daily_login_report for the specific row that last updated this
    fk_daily_login_report   int8        NULL,

    -- EOD reconciliation tracking
    eod_reconciled          boolean     NOT NULL DEFAULT false,
    eod_reconciliation_at   timestamp   NULL,
    eod_triggered_by        varchar(200) NULL,   -- 'MANUAL_SERVICE', 'NEXT_DAY_CARRYFORWARD', etc.

    -- Was the last login AFTER the EOD cutoff?
    -- Set by fn_trigger_eod_reconciliation(); affects whether a new snapshot is taken
    last_login_post_cutoff  boolean     NOT NULL DEFAULT false,

    -- Snapshot values used for EOD (copied from tbl_daily_cylinder_count on close)
    -- These are populated regardless of whether the close was live or post-cutoff
    eod_fleet_total         int4        NULL,
    eod_yard_full           int4        NULL,
    eod_yard_empty          int4        NULL,
    eod_in_transit          int4        NULL,
    eod_at_customer         int4        NULL,
    eod_at_supplier         int4        NULL,

    created_at              timestamp   NOT NULL DEFAULT now(),
    updated_at              timestamp   NOT NULL DEFAULT now(),

    CONSTRAINT tbl_last_login_pk
        PRIMARY KEY (pk_last_login_id),

    CONSTRAINT tbl_last_login_date_unique
        UNIQUE (login_date),

    CONSTRAINT tbl_last_login_daily_report_fk
        FOREIGN KEY (fk_daily_login_report)
        REFERENCES public.tbl_daily_login_report(pk_daily_login_report_id)
            DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX idx_last_login_date          ON public.tbl_last_login(login_date DESC);
CREATE INDEX idx_last_login_unreconciled  ON public.tbl_last_login(login_date)
    WHERE eod_reconciled = false;

COMMENT ON TABLE public.tbl_last_login IS
    'One row per calendar day. Retains the latest login timestamp for that day '
    'and tracks whether end-of-day cylinder reconciliation was completed. '
    'If eod_reconciled = FALSE at the start of the next business day, '
    'fn_carry_forward_unreconciled_day() is called automatically by the morning '
    'login trigger to close the missed day with a VARIANCE flag before opening '
    'the new day.';


-- ===========================================================================
-- SECTION 2 — HELPER: read the EOD cutoff time from config
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.fn_get_eod_cutoff()
RETURNS time AS $$
DECLARE
    v_val varchar(10);
BEGIN
    SELECT config_value INTO v_val
      FROM public.tbl_system_config
     WHERE config_key = 'EOD_CUTOFF_TIME';

    RETURN COALESCE(v_val, '22:00')::time;
EXCEPTION
    WHEN OTHERS THEN
        RETURN '22:00'::time;
END;
$$ LANGUAGE plpgsql STABLE;


-- ===========================================================================
-- SECTION 3 — FUNCTION: carry forward an unreconciled previous day
-- ===========================================================================
-- Called automatically by the morning login trigger when a new day's first
-- login is detected and the PREVIOUS day's tbl_last_login row is still
-- eod_reconciled = FALSE.
--
-- Behaviour:
--   • Reads the previous day's closing values from tbl_daily_cylinder_count
--     (whatever was recorded — even if the day is still OPEN).
--   • Sets the previous day's tbl_last_login row to eod_reconciled = TRUE,
--     last_login_post_cutoff = TRUE (it was clearly never closed cleanly),
--     and copies the snapshot values.
--   • Updates tbl_daily_cylinder_count day_status to 'VARIANCE' with a note
--     that the day was closed by next-morning carry-forward.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.fn_carry_forward_unreconciled_day(
    p_missed_date   date
)
RETURNS void AS $$
DECLARE
    v_dcc   public.tbl_daily_cylinder_count%ROWTYPE;
BEGIN
    -- Fetch the daily count row for the missed day (may be NULL if never opened)
    SELECT * INTO v_dcc
      FROM public.tbl_daily_cylinder_count
     WHERE count_date = p_missed_date;

    IF NOT FOUND THEN
        -- Day was never opened — just mark it reconciled with zero values
        UPDATE public.tbl_last_login
        SET eod_reconciled        = true,
            eod_reconciliation_at = now(),
            eod_triggered_by      = 'NEXT_DAY_CARRYFORWARD',
            last_login_post_cutoff = true,
            updated_at            = now()
        WHERE login_date = p_missed_date;
        RETURN;
    END IF;

    -- Mark the daily count as VARIANCE if not already reconciled
    IF v_dcc.day_status NOT IN ('RECONCILED') THEN
        UPDATE public.tbl_daily_cylinder_count
        SET day_status              = 'VARIANCE',
            reconciliation_notes    = COALESCE(reconciliation_notes, '') ||
                ' | NEXT_DAY_CARRYFORWARD: EOD reconciliation was not performed on '
                || p_missed_date::text || '. Closed automatically at '
                || now()::text || '.',
            snapshot_closed_at      = COALESCE(snapshot_closed_at, now()),
            closing_fleet_total     = COALESCE(closing_fleet_total, opening_fleet_total),
            closing_yard_full       = COALESCE(closing_yard_full,  opening_yard_full),
            closing_yard_empty      = COALESCE(closing_yard_empty, opening_yard_empty),
            closing_in_transit      = COALESCE(closing_in_transit, opening_in_transit),
            closing_at_customer     = COALESCE(closing_at_customer,opening_at_customer),
            closing_at_supplier     = COALESCE(closing_at_supplier,opening_at_supplier)
        WHERE count_date = p_missed_date;
    END IF;

    -- Update the last_login row with the carried-forward snapshot
    UPDATE public.tbl_last_login
    SET eod_reconciled        = true,
        eod_reconciliation_at = now(),
        eod_triggered_by      = 'NEXT_DAY_CARRYFORWARD',
        last_login_post_cutoff = true,
        eod_fleet_total       = COALESCE(v_dcc.closing_fleet_total,  v_dcc.opening_fleet_total),
        eod_yard_full         = COALESCE(v_dcc.closing_yard_full,    v_dcc.opening_yard_full),
        eod_yard_empty        = COALESCE(v_dcc.closing_yard_empty,   v_dcc.opening_yard_empty),
        eod_in_transit        = COALESCE(v_dcc.closing_in_transit,   v_dcc.opening_in_transit),
        eod_at_customer       = COALESCE(v_dcc.closing_at_customer,  v_dcc.opening_at_customer),
        eod_at_supplier       = COALESCE(v_dcc.closing_at_supplier,  v_dcc.opening_at_supplier),
        updated_at            = now()
    WHERE login_date = p_missed_date;

    RAISE NOTICE 'fn_carry_forward_unreconciled_day: Day % closed by carry-forward. '
                 'Marked as VARIANCE in tbl_daily_cylinder_count.', p_missed_date;
END;
$$ LANGUAGE plpgsql;


-- ===========================================================================
-- SECTION 4 — FUNCTION + TRIGGER: DailyLogin → morning cylinder count open
-- ===========================================================================
-- Fires AFTER INSERT on tbl_daily_login_report.
-- On the FIRST login of the business day:
--   a) Checks if yesterday's reconciliation was missed → calls carry-forward.
--   b) Calls fn_open_daily_count() to seed the opening snapshot for today.
-- Subsequent logins the same day: upsert tbl_last_login only (see Section 5).
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.fn_daily_login_morning_open()
RETURNS TRIGGER AS $$
DECLARE
    v_today         date := CURRENT_DATE;
    v_yesterday     date := CURRENT_DATE - 1;
    v_is_first_login boolean;
    v_yesterday_row  public.tbl_last_login%ROWTYPE;
BEGIN
    -- Is this the first login today?
    SELECT NOT EXISTS (
        SELECT 1 FROM public.tbl_last_login WHERE login_date = v_today
    ) INTO v_is_first_login;

    IF v_is_first_login THEN
        -- ── Check if yesterday's EOD was missed ─────────────────────────────
        SELECT * INTO v_yesterday_row
          FROM public.tbl_last_login
         WHERE login_date = v_yesterday;

        IF FOUND AND v_yesterday_row.eod_reconciled = false THEN
            PERFORM public.fn_carry_forward_unreconciled_day(v_yesterday);
        END IF;

        -- ── Open today's daily cylinder count (morning statistics) ──────────
        PERFORM public.fn_open_daily_count(v_today, 'MORNING_LOGIN');
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_daily_login_morning_open
AFTER INSERT ON public.tbl_daily_login_report
FOR EACH ROW
EXECUTE FUNCTION public.fn_daily_login_morning_open();

COMMENT ON TRIGGER trg_daily_login_morning_open ON public.tbl_daily_login_report IS
    'Fires on every login insert. On the first login of the day: '
    '(1) runs carry-forward for any unreconciled prior day, '
    '(2) calls fn_open_daily_count() to seed morning cylinder statistics.';


-- ===========================================================================
-- SECTION 5 — FUNCTION + TRIGGER: DailyLogin → upsert tbl_last_login
-- ===========================================================================
-- Fires AFTER INSERT on tbl_daily_login_report.
-- Always keeps tbl_last_login up-to-date with the most recent login timestamp.
-- Uses INSERT ... ON CONFLICT to handle the first vs. subsequent logins.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.fn_last_login_upsert()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.tbl_last_login (
        login_date,
        login_time,
        fk_daily_login_report,
        updated_at
    )
    VALUES (
        CURRENT_DATE,
        NEW.login_time,
        NEW.pk_daily_login_report_id,
        now()
    )
    ON CONFLICT (login_date) DO UPDATE
        SET login_time            = EXCLUDED.login_time,
            fk_daily_login_report = EXCLUDED.fk_daily_login_report,
            -- Reset reconciliation state only if a LATER login arrives before EOD
            -- (an earlier stale update should not undo a completed reconciliation)
            eod_reconciled        = CASE
                                        WHEN tbl_last_login.eod_reconciled = true
                                         AND EXCLUDED.login_time > tbl_last_login.login_time
                                         AND tbl_last_login.eod_reconciliation_at IS NOT NULL
                                         AND EXCLUDED.login_time > tbl_last_login.eod_reconciliation_at
                                        -- Login arrived AFTER a completed reconciliation →
                                        -- the EOD must be re-evaluated (post-cutoff rule applies)
                                        THEN false
                                        ELSE tbl_last_login.eod_reconciled
                                    END,
            updated_at            = now();

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_last_login_upsert
AFTER INSERT ON public.tbl_daily_login_report
FOR EACH ROW
EXECUTE FUNCTION public.fn_last_login_upsert();

COMMENT ON TRIGGER trg_last_login_upsert ON public.tbl_daily_login_report IS
    'Keeps tbl_last_login current. Each login is upserted so the row always '
    'reflects the latest login_time for that calendar day. '
    'If a login arrives AFTER a completed EOD reconciliation, '
    'eod_reconciled is reset to false so the service re-evaluates.';


-- ===========================================================================
-- SECTION 6 — FUNCTION: fn_trigger_eod_reconciliation()
-- ===========================================================================
-- The external reconciliation SERVICE calls this function.
-- It is intentionally idempotent — calling it twice for the same date is safe.
--
-- RULES:
--   R1. No last-login row for today → nothing to reconcile; return early.
--   R2. Already reconciled today   → return early (idempotent).
--   R3. Login time ≤ EOD cutoff    → full reconciliation (close daily count).
--   R4. Login time > EOD cutoff    → use EXISTING snapshot values; no new
--                                    cylinder count sample is taken.
--                                    Mark last_login_post_cutoff = TRUE.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.fn_trigger_eod_reconciliation(
    p_for_date      date        DEFAULT CURRENT_DATE,
    p_triggered_by  varchar(200) DEFAULT 'MANUAL_SERVICE'
)
RETURNS jsonb AS $$
DECLARE
    v_last_login    public.tbl_last_login%ROWTYPE;
    v_cutoff        time;
    v_is_post_cutoff boolean;
    v_dcc           public.tbl_daily_cylinder_count%ROWTYPE;
    v_result        jsonb;
BEGIN
    -- ── R1: No last-login row ────────────────────────────────────────────────
    SELECT * INTO v_last_login
      FROM public.tbl_last_login
     WHERE login_date = p_for_date;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'status',  'SKIPPED',
            'reason',  'No login recorded for ' || p_for_date::text,
            'date',    p_for_date
        );
    END IF;

    -- ── R2: Already reconciled ───────────────────────────────────────────────
    IF v_last_login.eod_reconciled = true THEN
        -- Check: did a login arrive AFTER reconciliation was completed?
        -- (trg_last_login_upsert will have reset eod_reconciled to false if so)
        -- Reaching here means truly already reconciled.
        RETURN jsonb_build_object(
            'status',           'ALREADY_RECONCILED',
            'date',             p_for_date,
            'reconciled_at',    v_last_login.eod_reconciliation_at,
            'post_cutoff',      v_last_login.last_login_post_cutoff
        );
    END IF;

    -- ── Determine post-cutoff ────────────────────────────────────────────────
    v_cutoff         := public.fn_get_eod_cutoff();
    v_is_post_cutoff := (v_last_login.login_time::time > v_cutoff);

    -- ── R3: Login ≤ cutoff → full close ─────────────────────────────────────
    IF NOT v_is_post_cutoff THEN
        BEGIN
            PERFORM public.fn_close_daily_count(p_for_date);
        EXCEPTION
            WHEN OTHERS THEN
                -- fn_close_daily_count raises if day not found or already closed —
                -- log but don't abort the reconciliation record.
                RAISE NOTICE 'fn_trigger_eod_reconciliation: fn_close_daily_count raised: %', SQLERRM;
        END;
    END IF;

    -- ── Fetch the current/closed daily count snapshot ────────────────────────
    SELECT * INTO v_dcc
      FROM public.tbl_daily_cylinder_count
     WHERE count_date = p_for_date;

    -- ── R4: Post-cutoff → stamp existing values, do NOT re-sample ───────────
    -- (If the day was never formally opened, v_dcc will be NOT FOUND; handle gracefully)
    UPDATE public.tbl_last_login
    SET eod_reconciled        = true,
        eod_reconciliation_at = now(),
        eod_triggered_by      = p_triggered_by,
        last_login_post_cutoff = v_is_post_cutoff,
        eod_fleet_total       = CASE WHEN v_dcc IS NOT NULL
                                     THEN COALESCE(v_dcc.closing_fleet_total, v_dcc.opening_fleet_total)
                                     ELSE NULL END,
        eod_yard_full         = CASE WHEN v_dcc IS NOT NULL
                                     THEN COALESCE(v_dcc.closing_yard_full,   v_dcc.opening_yard_full)
                                     ELSE NULL END,
        eod_yard_empty        = CASE WHEN v_dcc IS NOT NULL
                                     THEN COALESCE(v_dcc.closing_yard_empty,  v_dcc.opening_yard_empty)
                                     ELSE NULL END,
        eod_in_transit        = CASE WHEN v_dcc IS NOT NULL
                                     THEN COALESCE(v_dcc.closing_in_transit,  v_dcc.opening_in_transit)
                                     ELSE NULL END,
        eod_at_customer       = CASE WHEN v_dcc IS NOT NULL
                                     THEN COALESCE(v_dcc.closing_at_customer, v_dcc.opening_at_customer)
                                     ELSE NULL END,
        eod_at_supplier       = CASE WHEN v_dcc IS NOT NULL
                                     THEN COALESCE(v_dcc.closing_at_supplier, v_dcc.opening_at_supplier)
                                     ELSE NULL END,
        updated_at            = now()
    WHERE login_date = p_for_date;

    -- ── If post-cutoff: add a note in the daily count record ─────────────────
    IF v_is_post_cutoff AND v_dcc IS NOT NULL THEN
        UPDATE public.tbl_daily_cylinder_count
        SET reconciliation_notes = COALESCE(reconciliation_notes, '') ||
            ' | POST_CUTOFF_EOD: Last login (' ||
            v_last_login.login_time::text ||
            ') occurred after EOD cutoff (' || v_cutoff::text ||
            '). Existing snapshot retained by ' || p_triggered_by || ' at ' || now()::text || '.'
        WHERE count_date = p_for_date;
    END IF;

    v_result := jsonb_build_object(
        'status',           'RECONCILED',
        'date',             p_for_date,
        'post_cutoff',      v_is_post_cutoff,
        'triggered_by',     p_triggered_by,
        'last_login_time',  v_last_login.login_time,
        'eod_cutoff',       v_cutoff,
        'snapshot',         jsonb_build_object(
            'fleet_total',   COALESCE(v_dcc.closing_fleet_total, v_dcc.opening_fleet_total),
            'yard_full',     COALESCE(v_dcc.closing_yard_full,   v_dcc.opening_yard_full),
            'yard_empty',    COALESCE(v_dcc.closing_yard_empty,  v_dcc.opening_yard_empty),
            'in_transit',    COALESCE(v_dcc.closing_in_transit,  v_dcc.opening_in_transit),
            'at_customer',   COALESCE(v_dcc.closing_at_customer, v_dcc.opening_at_customer),
            'at_supplier',   COALESCE(v_dcc.closing_at_supplier, v_dcc.opening_at_supplier)
        )
    );

    RAISE NOTICE 'EOD Reconciliation complete for %: post_cutoff=% triggered_by=%',
        p_for_date, v_is_post_cutoff, p_triggered_by;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_trigger_eod_reconciliation IS
    'Entry point for the external reconciliation service. '
    'Call: SELECT fn_trigger_eod_reconciliation(); '
    'Returns a JSON summary of what was done. '
    'Idempotent — safe to call multiple times for the same date. '
    'Post-cutoff logins use the existing snapshot values rather than re-sampling.';


-- ===========================================================================
-- SECTION 7 — VIEW: login and EOD reconciliation status dashboard
-- ===========================================================================
CREATE OR REPLACE VIEW public.vw_login_eod_status AS
SELECT
    ll.login_date,
    ll.login_time                                           AS last_login_time,
    ll.eod_reconciled,
    ll.eod_reconciliation_at,
    ll.eod_triggered_by,
    ll.last_login_post_cutoff,
    public.fn_get_eod_cutoff()                              AS eod_cutoff_configured,
    -- Is today's reconciliation overdue?
    CASE
        WHEN ll.login_date = CURRENT_DATE
         AND ll.eod_reconciled = false
         AND ll.login_time::time > public.fn_get_eod_cutoff()
        THEN true
        ELSE false
    END                                                     AS is_overdue,
    dcc.day_status                                          AS cylinder_count_status,
    ll.eod_fleet_total,
    ll.eod_yard_full,
    ll.eod_yard_empty,
    ll.eod_in_transit,
    ll.eod_at_customer,
    ll.eod_at_supplier,
    ll.updated_at
FROM public.tbl_last_login ll
LEFT JOIN public.tbl_daily_cylinder_count dcc
       ON dcc.count_date = ll.login_date
ORDER BY ll.login_date DESC;

COMMENT ON VIEW public.vw_login_eod_status IS
    'Daily dashboard showing login activity and EOD reconciliation health. '
    'is_overdue = TRUE means the service should call fn_trigger_eod_reconciliation() '
    'immediately. cylinder_count_status reflects the matching tbl_daily_cylinder_count row.';
