-- =============================================================================
-- V85__YardCheckEventLog.sql
-- =============================================================================
--
-- PURPOSE:
--   Management needs a precise, tamper-evident timeline of every yard audit:
--   when it was opened, who started scanning, when each status transition
--   happened, how long each phase took, and who was present at each step.
--
--   tbl_yard_stock_check currently has only two timestamps:
--     created_at    → when the audit header was created
--     completed_at  → when it was marked COMPLETED
--   Everything in between — scanning start, pauses, reassignments,
--   variance discoveries, supervisor reviews — is invisible.
--
-- DESIGN:
--   tbl_yard_check_event
--     One row per lifecycle event on a yard stock check.
--     Written automatically by triggers on tbl_yard_stock_check and
--     tbl_yard_stock_check_line, and by explicit calls from the
--     application layer for events that require operator context
--     (e.g. who supervised a variance review).
--
-- EVENT TYPES:
--   AUDIT_CREATED       – header row inserted; audit session opened
--   SCANNING_STARTED    – first cylinder scanned (derived from first line)
--   CYLINDER_SCANNED    – each individual cylinder scan (one row per scan)
--   SCANNING_PAUSED     – app calls fn_record_yard_check_event('PAUSED', ...)
--   SCANNING_RESUMED    – app calls fn_record_yard_check_event('RESUMED', ...)
--   AUDIT_COMPLETED     – check_status → COMPLETED
--   VARIANCE_RAISED     – a cylinder in system state is not found in scan
--                         (OR a scanned cylinder is not in the expected state)
--   VARIANCE_RESOLVED   – a variance row is resolved
--   SUPERVISOR_REVIEWED – a manager signed off on the completed audit
--   AUDIT_REOPENED      – a completed audit was reopened for re-scanning
--
-- TRIGGERS:
--   AFTER INSERT on tbl_yard_stock_check       → AUDIT_CREATED event
--   AFTER INSERT on tbl_yard_stock_check_line  → CYLINDER_SCANNED event
--                                                 + SCANNING_STARTED on first scan
--   AFTER UPDATE (check_status) on
--     tbl_yard_stock_check                     → AUDIT_COMPLETED or AUDIT_REOPENED
--   AFTER INSERT on tbl_yard_stock_variance    → VARIANCE_RAISED event
--   AFTER UPDATE (variance_status) on
--     tbl_yard_stock_variance                  → VARIANCE_RESOLVED event
--
-- QUERIES THE MANAGEMENT REPORT USES:
--   • Total duration of each audit (AUDIT_CREATED → AUDIT_COMPLETED)
--   • Scanning duration (SCANNING_STARTED → AUDIT_COMPLETED)
--   • Throughput: cylinders scanned per minute
--   • All audits for a date range with their event timelines
--   • Which audits had variances and how quickly they were resolved
-- =============================================================================


-- =============================================================================
-- SEQUENCE
-- =============================================================================
DROP SEQUENCE IF EXISTS public.pk_yard_check_event_id_serial;
CREATE SEQUENCE public.pk_yard_check_event_id_serial
    INCREMENT BY 1 MINVALUE 1 START 1 CACHE 1 NO CYCLE;


-- =============================================================================
-- TABLE: tbl_yard_check_event
-- =============================================================================

CREATE TABLE public.tbl_yard_check_event (

    pk_event_id         int8         NOT NULL
        DEFAULT nextval('public.pk_yard_check_event_id_serial'),

    -- Which audit does this event belong to?
    fk_stock_check      int8         NOT NULL,

    -- What happened?
    event_type          varchar(50)  NOT NULL,

    -- When did it happen? (DB clock — not user-supplied, prevents backdating)
    event_at            timestamp    NOT NULL DEFAULT now(),

    -- Who was responsible for this event?
    -- For trigger-generated events (CYLINDER_SCANNED) this is the
    -- checked_by from the parent tbl_yard_stock_check header.
    -- For app-layer events (PAUSED, RESUMED, SUPERVISOR_REVIEWED) the
    -- application passes the logged-in user.
    performed_by        varchar(200) NOT NULL,

    -- Optional: which cylinder this event relates to
    -- Set for CYLINDER_SCANNED, VARIANCE_RAISED, VARIANCE_RESOLVED
    fk_cylinder         int8         NULL,

    -- Optional: which variance row this event closes
    -- Set for VARIANCE_RESOLVED
    fk_variance         int8         NULL,

    -- Free-text detail visible in the management report
    -- e.g. "Resumed after lunch break", "Cylinder C-909 found in rear shelf"
    event_remarks       varchar(500) NULL,

    -- Snapshot of cumulative scan count at this moment
    -- Makes it trivial to plot scanning progress over time without
    -- re-counting lines up to a given timestamp
    cumulative_scanned  int4         NULL,

    CONSTRAINT tbl_yard_check_event_pk
        PRIMARY KEY (pk_event_id),

    CONSTRAINT tbl_yard_check_event_type_chk
        CHECK (event_type IN (
            'AUDIT_CREATED',
            'SCANNING_STARTED',
            'CYLINDER_SCANNED',
            'SCANNING_PAUSED',
            'SCANNING_RESUMED',
            'AUDIT_COMPLETED',
            'VARIANCE_RAISED',
            'VARIANCE_RESOLVED',
            'SUPERVISOR_REVIEWED',
            'AUDIT_REOPENED'
        )),

    CONSTRAINT tbl_yard_check_event_stock_check_fk
        FOREIGN KEY (fk_stock_check)
        REFERENCES public.tbl_yard_stock_check(pk_stock_check_id),

    CONSTRAINT tbl_yard_check_event_cylinder_fk
        FOREIGN KEY (fk_cylinder)
        REFERENCES public.tbl_cylinder(pk_cylinder_id),

    CONSTRAINT tbl_yard_check_event_variance_fk
        FOREIGN KEY (fk_variance)
        REFERENCES public.tbl_yard_stock_variance(pk_variance_id)
);

-- Fast fetch of all events for one audit in timeline order
CREATE INDEX idx_yard_check_event_stock_check
    ON public.tbl_yard_check_event(fk_stock_check, event_at);

-- Management report: all events of a type across a date range
CREATE INDEX idx_yard_check_event_type_at
    ON public.tbl_yard_check_event(event_type, event_at DESC);

-- Per-cylinder event history
CREATE INDEX idx_yard_check_event_cylinder
    ON public.tbl_yard_check_event(fk_cylinder)
    WHERE fk_cylinder IS NOT NULL;

COMMENT ON TABLE public.tbl_yard_check_event IS
    'Tamper-evident event log for every lifecycle moment of a yard audit. '
    'One row per event. event_at uses the DB clock (DEFAULT now()) — '
    'the application cannot supply a backdated timestamp. '
    'Management queries this table to see duration, scanning throughput, '
    'variance timelines, and who was present at each phase.';

COMMENT ON COLUMN public.tbl_yard_check_event.cumulative_scanned IS
    'Running count of cylinders scanned up to and including this event. '
    'Set by the CYLINDER_SCANNED trigger. '
    'Used to plot scanning progress over time without window aggregation.';

COMMENT ON COLUMN public.tbl_yard_check_event.event_at IS
    'DB server clock timestamp. DEFAULT now() — never supplied by the '
    'application layer so it cannot be backdated. This is the source of '
    'truth for all duration calculations in the management report.';


-- =============================================================================
-- TRIGGER 1 — AFTER INSERT on tbl_yard_stock_check → AUDIT_CREATED
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_yard_check_event_on_create()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.tbl_yard_check_event (
        fk_stock_check,
        event_type,
        event_at,
        performed_by,
        event_remarks,
        cumulative_scanned
    ) VALUES (
        NEW.pk_stock_check_id,
        'AUDIT_CREATED',
        NEW.created_at,   -- use the header's own created_at for consistency
        NEW.checked_by,
        'Yard audit opened. Context: ' || NEW.check_context
            || CASE WHEN NEW.fk_vehicle_trip IS NOT NULL
                    THEN '. For trip: ' || NEW.fk_vehicle_trip
                    ELSE '' END,
        0
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_yard_check_event_on_create
AFTER INSERT ON public.tbl_yard_stock_check
FOR EACH ROW EXECUTE FUNCTION public.fn_yard_check_event_on_create();

COMMENT ON FUNCTION public.fn_yard_check_event_on_create() IS
    'AFTER INSERT on tbl_yard_stock_check. '
    'Writes AUDIT_CREATED event to tbl_yard_check_event. '
    'Uses the header created_at so the event timestamp matches the row timestamp exactly.';


-- =============================================================================
-- TRIGGER 2 — AFTER INSERT on tbl_yard_stock_check_line
--             → CYLINDER_SCANNED (every scan)
--             → SCANNING_STARTED (only for the first scan of each audit)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_yard_check_event_on_scan()
RETURNS TRIGGER AS $$
DECLARE
    v_checked_by        varchar(200);
    v_check_context     varchar(30);
    v_scan_count        int4;
    v_cylinder_serial   varchar(100);
BEGIN
    -- Fetch audit header context
    SELECT checked_by, check_context
      INTO v_checked_by, v_check_context
      FROM public.tbl_yard_stock_check
     WHERE pk_stock_check_id = NEW.fk_stock_check;

    -- Fetch cylinder serial for the remarks
    SELECT cylinder_serial INTO v_cylinder_serial
      FROM public.tbl_cylinder
     WHERE pk_cylinder_id = NEW.fk_cylinder;

    -- Count total scans including this one
    SELECT COUNT(*) INTO v_scan_count
      FROM public.tbl_yard_stock_check_line
     WHERE fk_stock_check = NEW.fk_stock_check;

    -- ── SCANNING_STARTED on the very first scan ───────────────────────────────
    IF v_scan_count = 1 THEN
        INSERT INTO public.tbl_yard_check_event (
            fk_stock_check, event_type, event_at,
            performed_by, fk_cylinder, event_remarks, cumulative_scanned
        ) VALUES (
            NEW.fk_stock_check,
            'SCANNING_STARTED',
            NEW.scanned_at,
            v_checked_by,
            NEW.fk_cylinder,
            'First cylinder scanned: ' || v_cylinder_serial
                || '. Audit context: ' || v_check_context,
            1
        );
    END IF;

    -- ── CYLINDER_SCANNED for every scan (including the first) ────────────────
    INSERT INTO public.tbl_yard_check_event (
        fk_stock_check, event_type, event_at,
        performed_by, fk_cylinder, event_remarks, cumulative_scanned
    ) VALUES (
        NEW.fk_stock_check,
        'CYLINDER_SCANNED',
        NEW.scanned_at,
        v_checked_by,
        NEW.fk_cylinder,
        'Scanned: ' || v_cylinder_serial,
        v_scan_count
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_yard_check_event_on_scan
AFTER INSERT ON public.tbl_yard_stock_check_line
FOR EACH ROW EXECUTE FUNCTION public.fn_yard_check_event_on_scan();

COMMENT ON FUNCTION public.fn_yard_check_event_on_scan() IS
    'AFTER INSERT on tbl_yard_stock_check_line. '
    'Writes CYLINDER_SCANNED event for every scan. '
    'Writes SCANNING_STARTED additionally for the first scan of each audit. '
    'cumulative_scanned is a running total enabling progress charts without '
    'window functions at query time.';


-- =============================================================================
-- TRIGGER 3 — AFTER UPDATE (check_status) on tbl_yard_stock_check
--             → AUDIT_COMPLETED or AUDIT_REOPENED
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_yard_check_event_on_status_change()
RETURNS TRIGGER AS $$
DECLARE
    v_scan_count    int4;
    v_event_type    varchar(50);
    v_remarks       varchar(500);
BEGIN
    IF NEW.check_status = OLD.check_status THEN
        RETURN NEW;
    END IF;

    SELECT COUNT(*) INTO v_scan_count
      FROM public.tbl_yard_stock_check_line
     WHERE fk_stock_check = NEW.pk_stock_check_id;

    IF NEW.check_status = 'COMPLETED' THEN
        v_event_type := 'AUDIT_COMPLETED';
        v_remarks    := 'Audit completed by ' || NEW.checked_by
                     || '. Total scanned: ' || v_scan_count
                     || '. Context: ' || NEW.check_context
                     || COALESCE('. Remarks: ' || NEW.remarks, '');

    ELSIF OLD.check_status = 'COMPLETED'
      AND NEW.check_status = 'IN_PROGRESS' THEN
        v_event_type := 'AUDIT_REOPENED';
        v_remarks    := 'Audit reopened from COMPLETED by ' || NEW.checked_by
                     || '. Scans so far: ' || v_scan_count;
    ELSE
        -- Other status transitions (e.g. IN_PROGRESS → PAUSED) are handled
        -- by the application layer via fn_record_yard_check_event()
        RETURN NEW;
    END IF;

    INSERT INTO public.tbl_yard_check_event (
        fk_stock_check, event_type, event_at,
        performed_by, event_remarks, cumulative_scanned
    ) VALUES (
        NEW.pk_stock_check_id,
        v_event_type,
        now(),
        NEW.checked_by,
        v_remarks,
        v_scan_count
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_yard_check_event_on_status_change
AFTER UPDATE OF check_status ON public.tbl_yard_stock_check
FOR EACH ROW EXECUTE FUNCTION public.fn_yard_check_event_on_status_change();

COMMENT ON FUNCTION public.fn_yard_check_event_on_status_change() IS
    'AFTER UPDATE of check_status on tbl_yard_stock_check. '
    'Writes AUDIT_COMPLETED when status → COMPLETED. '
    'Writes AUDIT_REOPENED when status reverts from COMPLETED → IN_PROGRESS. '
    'Other transitions (PAUSED, RESUMED) use fn_record_yard_check_event().';


-- =============================================================================
-- TRIGGER 4 — AFTER INSERT on tbl_yard_stock_variance → VARIANCE_RAISED
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_yard_check_event_on_variance_raised()
RETURNS TRIGGER AS $$
DECLARE
    v_checked_by      varchar(200);
    v_cylinder_serial varchar(100);
BEGIN
    SELECT checked_by INTO v_checked_by
      FROM public.tbl_yard_stock_check
     WHERE pk_stock_check_id = NEW.fk_stock_check;

    SELECT cylinder_serial INTO v_cylinder_serial
      FROM public.tbl_cylinder
     WHERE pk_cylinder_id = NEW.fk_cylinder;

    INSERT INTO public.tbl_yard_check_event (
        fk_stock_check, event_type, event_at,
        performed_by, fk_cylinder, fk_variance, event_remarks, cumulative_scanned
    ) VALUES (
        NEW.fk_stock_check,
        'VARIANCE_RAISED',
        NEW.raised_at,
        v_checked_by,
        NEW.fk_cylinder,
        NEW.pk_variance_id,
        'Variance raised for cylinder ' || v_cylinder_serial
            || '. Type: ' || NEW.variance_type
            || '. System state: ' || NEW.system_state
            || '. System location: ' || NEW.system_location,
        NULL   -- cumulative_scanned not relevant for variance events
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_yard_check_event_on_variance_raised
AFTER INSERT ON public.tbl_yard_stock_variance
FOR EACH ROW EXECUTE FUNCTION public.fn_yard_check_event_on_variance_raised();

COMMENT ON FUNCTION public.fn_yard_check_event_on_variance_raised() IS
    'AFTER INSERT on tbl_yard_stock_variance. '
    'Writes VARIANCE_RAISED to tbl_yard_check_event so management can see '
    'exactly when each discrepancy was discovered during the audit.';


-- =============================================================================
-- TRIGGER 5 — AFTER UPDATE (variance_status) on tbl_yard_stock_variance
--             → VARIANCE_RESOLVED
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_yard_check_event_on_variance_resolved()
RETURNS TRIGGER AS $$
DECLARE
    v_checked_by      varchar(200);
    v_cylinder_serial varchar(100);
BEGIN
    IF NEW.variance_status <> 'RESOLVED' OR OLD.variance_status = 'RESOLVED' THEN
        RETURN NEW;
    END IF;

    SELECT checked_by INTO v_checked_by
      FROM public.tbl_yard_stock_check
     WHERE pk_stock_check_id = NEW.fk_stock_check;

    SELECT cylinder_serial INTO v_cylinder_serial
      FROM public.tbl_cylinder
     WHERE pk_cylinder_id = NEW.fk_cylinder;

    INSERT INTO public.tbl_yard_check_event (
        fk_stock_check, event_type, event_at,
        performed_by, fk_cylinder, fk_variance, event_remarks, cumulative_scanned
    ) VALUES (
        NEW.fk_stock_check,
        'VARIANCE_RESOLVED',
        COALESCE(NEW.resolved_at, now()),
        v_checked_by,
        NEW.fk_cylinder,
        NEW.pk_variance_id,
        'Variance resolved for cylinder ' || v_cylinder_serial
            || '. Resolution: ' || COALESCE(NEW.resolution_remarks, '(no remarks)'),
        NULL
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_yard_check_event_on_variance_resolved
AFTER UPDATE OF variance_status ON public.tbl_yard_stock_variance
FOR EACH ROW EXECUTE FUNCTION public.fn_yard_check_event_on_variance_resolved();

COMMENT ON FUNCTION public.fn_yard_check_event_on_variance_resolved() IS
    'AFTER UPDATE of variance_status on tbl_yard_stock_variance. '
    'Writes VARIANCE_RESOLVED when variance_status → RESOLVED. '
    'Records resolved_at from the variance row itself.';


-- =============================================================================
-- APPLICATION HELPER: fn_record_yard_check_event()
-- =============================================================================
-- Called explicitly from the Spring service layer for events that need
-- operator context the triggers cannot infer from the row alone:
--   SCANNING_PAUSED, SCANNING_RESUMED, SUPERVISOR_REVIEWED
--
-- Usage:
--   SELECT public.fn_record_yard_check_event(
--       p_stock_check_id := 42,
--       p_event_type     := 'SCANNING_PAUSED',
--       p_performed_by   := 'John (Yard Staff)',
--       p_remarks        := 'Paused for shift change'
--   );
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_record_yard_check_event(
    p_stock_check_id int8,
    p_event_type     varchar(50),
    p_performed_by   varchar(200),
    p_remarks        varchar(500) DEFAULT NULL
)
RETURNS int8 AS $$
DECLARE
    v_allowed_app_types varchar(50)[] := ARRAY[
        'SCANNING_PAUSED',
        'SCANNING_RESUMED',
        'SUPERVISOR_REVIEWED'
    ];
    v_scan_count  int4;
    v_new_id      int8;
BEGIN
    -- Validate: only app-layer event types accepted here
    IF NOT (p_event_type = ANY(v_allowed_app_types)) THEN
        RAISE EXCEPTION
            'fn_record_yard_check_event: event type % is not an application-layer '
            'event. Trigger-generated events (AUDIT_CREATED, CYLINDER_SCANNED, '
            'AUDIT_COMPLETED, VARIANCE_RAISED, VARIANCE_RESOLVED) are written '
            'automatically and must not be inserted manually.',
            p_event_type;
    END IF;

    -- Validate: stock check must exist
    IF NOT EXISTS (
        SELECT 1 FROM public.tbl_yard_stock_check
         WHERE pk_stock_check_id = p_stock_check_id
    ) THEN
        RAISE EXCEPTION
            'fn_record_yard_check_event: yard stock check % does not exist.',
            p_stock_check_id;
    END IF;

    SELECT COUNT(*) INTO v_scan_count
      FROM public.tbl_yard_stock_check_line
     WHERE fk_stock_check = p_stock_check_id;

    INSERT INTO public.tbl_yard_check_event (
        fk_stock_check, event_type, event_at,
        performed_by, event_remarks, cumulative_scanned
    ) VALUES (
        p_stock_check_id,
        p_event_type,
        now(),              -- always DB clock; application cannot supply a time
        p_performed_by,
        p_remarks,
        v_scan_count
    )
    RETURNING pk_event_id INTO v_new_id;

    RETURN v_new_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_record_yard_check_event(int8, varchar, varchar, varchar) IS
    'Application-layer helper for events that require operator context: '
    'SCANNING_PAUSED, SCANNING_RESUMED, SUPERVISOR_REVIEWED. '
    'Trigger-generated events are written automatically and are blocked here. '
    'Always uses DB clock (now()) — the application cannot backdate events. '
    'Returns the pk_event_id of the new row.';


-- =============================================================================
-- MANAGEMENT VIEWS
-- =============================================================================

-- =============================================================================
-- VIEW A — vw_yard_check_timeline
-- Complete event timeline for every audit, one row per event.
-- The management report page shows this filtered by date or stock_check_id.
-- =============================================================================

CREATE OR REPLACE VIEW public.vw_yard_check_timeline AS
SELECT
    ysc.check_date,
    ysc.check_context,
    ysc.pk_stock_check_id,
    ysc.checked_by                              AS audit_owner,
    ysc.check_status                            AS current_audit_status,
    e.pk_event_id,
    e.event_type,
    e.event_at,
    e.performed_by,
    c.cylinder_serial,
    e.cumulative_scanned,
    e.event_remarks,
    -- Duration since the AUDIT_CREATED event for this audit (minutes)
    EXTRACT(EPOCH FROM (e.event_at - ysc.created_at)) / 60.0   AS minutes_since_open,
    -- Variance link
    v.variance_type,
    v.variance_status
FROM   public.tbl_yard_check_event           e
JOIN   public.tbl_yard_stock_check           ysc
       ON ysc.pk_stock_check_id = e.fk_stock_check
LEFT   JOIN public.tbl_cylinder              c
       ON c.pk_cylinder_id      = e.fk_cylinder
LEFT   JOIN public.tbl_yard_stock_variance   v
       ON v.pk_variance_id      = e.fk_variance
ORDER  BY ysc.check_date DESC, e.fk_stock_check, e.event_at;

COMMENT ON VIEW public.vw_yard_check_timeline IS
    'Complete event timeline for every yard audit. '
    'Filter by check_date or pk_stock_check_id for a specific audit. '
    'minutes_since_open shows elapsed time from audit open for each event.';


-- =============================================================================
-- VIEW B — vw_yard_check_summary
-- One row per audit. Durations, throughput, variance counts.
-- Management dashboard widget — shows all audits for the last N days.
-- =============================================================================

CREATE OR REPLACE VIEW public.vw_yard_check_summary AS
SELECT
    ysc.pk_stock_check_id,
    ysc.check_date,
    ysc.check_context,
    ysc.checked_by,
    ysc.check_status,

    -- ── Timestamps from the event log (not from the header columns) ──────────
    -- Using the event log timestamps ensures they are consistent with
    -- all other event_at values in the timeline.
    MIN(e.event_at) FILTER (WHERE e.event_type = 'AUDIT_CREATED')       AS opened_at,
    MIN(e.event_at) FILTER (WHERE e.event_type = 'SCANNING_STARTED')    AS scanning_started_at,
    MAX(e.event_at) FILTER (WHERE e.event_type = 'AUDIT_COMPLETED')     AS completed_at,

    -- ── Durations (minutes) ──────────────────────────────────────────────────
    -- Total: from open to completed
    ROUND(
        EXTRACT(EPOCH FROM (
            MAX(e.event_at) FILTER (WHERE e.event_type = 'AUDIT_COMPLETED')
            - MIN(e.event_at) FILTER (WHERE e.event_type = 'AUDIT_CREATED')
        )) / 60.0, 1
    )                                                                    AS total_duration_mins,

    -- Scanning only: from first scan to completed
    ROUND(
        EXTRACT(EPOCH FROM (
            MAX(e.event_at) FILTER (WHERE e.event_type = 'AUDIT_COMPLETED')
            - MIN(e.event_at) FILTER (WHERE e.event_type = 'SCANNING_STARTED')
        )) / 60.0, 1
    )                                                                    AS scanning_duration_mins,

    -- ── Counts ───────────────────────────────────────────────────────────────
    COUNT(e.pk_event_id) FILTER (WHERE e.event_type = 'CYLINDER_SCANNED') AS cylinders_scanned,
    COUNT(e.pk_event_id) FILTER (WHERE e.event_type = 'VARIANCE_RAISED')  AS variances_raised,
    COUNT(e.pk_event_id) FILTER (WHERE e.event_type = 'VARIANCE_RESOLVED') AS variances_resolved,
    COUNT(e.pk_event_id) FILTER (WHERE e.event_type = 'SCANNING_PAUSED')  AS times_paused,

    -- ── Throughput (cylinders per minute of active scanning) ─────────────────
    CASE
        WHEN EXTRACT(EPOCH FROM (
            MAX(e.event_at) FILTER (WHERE e.event_type = 'AUDIT_COMPLETED')
            - MIN(e.event_at) FILTER (WHERE e.event_type = 'SCANNING_STARTED')
        )) > 0
        THEN ROUND(
            COUNT(e.pk_event_id) FILTER (WHERE e.event_type = 'CYLINDER_SCANNED')
            /
            (EXTRACT(EPOCH FROM (
                MAX(e.event_at) FILTER (WHERE e.event_type = 'AUDIT_COMPLETED')
                - MIN(e.event_at) FILTER (WHERE e.event_type = 'SCANNING_STARTED')
            )) / 60.0), 1)
        ELSE NULL
    END                                                                  AS cylinders_per_minute,

    -- ── Checkpoint status (from reconciliation layer) ─────────────────────────
    MAX(rc.checkpoint_status)                                            AS checkpoint_status,
    MAX(rc.actual_count)                                                 AS checkpoint_actual,
    MAX(rc.expected_count)                                               AS checkpoint_expected,
    MAX(rc.actual_count) - MAX(rc.expected_count)                        AS checkpoint_variance,

    ysc.fk_vehicle_trip

FROM   public.tbl_yard_stock_check          ysc
LEFT   JOIN public.tbl_yard_check_event     e
       ON e.fk_stock_check = ysc.pk_stock_check_id
LEFT   JOIN public.tbl_reconciliation_checkpoint rc
       ON  rc.reference_entity_type = 'tbl_yard_stock_check'
       AND rc.reference_entity_id   = ysc.pk_stock_check_id
GROUP  BY ysc.pk_stock_check_id, ysc.check_date, ysc.check_context,
          ysc.checked_by, ysc.check_status, ysc.fk_vehicle_trip
ORDER  BY ysc.check_date DESC, ysc.pk_stock_check_id;

COMMENT ON VIEW public.vw_yard_check_summary IS
    'One row per yard audit. All timestamps and durations derived from '
    'tbl_yard_check_event (not from the header columns) so they are '
    'consistent with the full timeline. '
    'cylinders_per_minute = throughput of active scanning phase only. '
    'checkpoint_variance = actual_count - expected_count from the orchestrator.';
