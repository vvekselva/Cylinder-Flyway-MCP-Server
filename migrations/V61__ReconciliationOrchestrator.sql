-- =============================================================================
-- V61__ReconciliationOrchestrator.sql
-- =============================================================================
-- PURPOSE:
--   Create a central ORCHESTRATOR that governs the reconciliation lifecycle.
--
-- CORE PRINCIPLE:
--   Every significant event in the cylinder lifecycle must produce a
--   "reconciliation checkpoint" that can be audited, queried, and tracked to
--   closure. The orchestrator is NOT a replacement for the existing audit tables
--   — it is a SUPERVISOR layer that watches all of them and raises alerts when
--   expected checkpoints are missing or counts don't balance.
--
-- CHECKPOINT TYPES (in day-order):
--   DAILY_OPENING         – created when the business day is opened
--   TRIP_DEPARTURE        – created when a vehicle trip departs with cylinders
--   SUPPLIER_DROPOFF      – created when a supplier trip cylinder is handed over
--   YARD_AUDIT            – created when a yard audit starts
--   TRIP_RETURN           – created when a trip returns and cylinders are verified
--   SUPPLIER_COLLECTION   – created when refilled cylinders are collected
--   DAILY_CLOSING         – created when the day is closed and counts match
--
-- ORCHESTRATOR INVARIANT:
--   For every TRIP_DEPARTURE there must be a corresponding TRIP_RETURN
--   with actual_count = expected_count within X hours. If not, raise an alert.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- SEQUENCE
-- ---------------------------------------------------------------------------
DROP SEQUENCE IF EXISTS public.pk_reconciliation_checkpoint_id_serial;
CREATE SEQUENCE public.pk_reconciliation_checkpoint_id_serial
    INCREMENT BY 1 MINVALUE 1 START 1 CACHE 1 NO CYCLE;

-- ---------------------------------------------------------------------------
-- TABLE: tbl_reconciliation_checkpoint (the orchestrator)
-- ---------------------------------------------------------------------------
CREATE TABLE public.tbl_reconciliation_checkpoint (
    pk_checkpoint_id        int8        NOT NULL DEFAULT nextval('public.pk_reconciliation_checkpoint_id_serial'),
    checkpoint_date         date        NOT NULL DEFAULT CURRENT_DATE,

    -- Which phase of the cylinder lifecycle does this checkpoint govern?
    checkpoint_type         varchar(50) NOT NULL,

    -- Reference to the business entity this checkpoint guards
    --   TRIP_DEPARTURE / TRIP_RETURN → fk_vehicle_trip
    --   SUPPLIER_DROPOFF / SUPPLIER_COLLECTION → fk_supplier_trip
    --   YARD_AUDIT → fk_yard_stock_check
    --   DAILY_OPENING / DAILY_CLOSING → fk_daily_count
    reference_entity_type   varchar(100),
    reference_entity_id     int8,

    -- Link to the daily count row for this date
    fk_daily_count          int8        NULL,

    -- ─── COUNTS ──────────────────────────────────────────────────────────────
    -- How many cylinders were expected at this checkpoint
    expected_count          int4        NOT NULL,
    -- How many were actually verified (NULL = checkpoint not yet closed)
    actual_count            int4,
    -- Derived: actual - expected (0 = balanced, non-zero = investigation required)
    variance                int4        GENERATED ALWAYS AS (
                                            CASE WHEN actual_count IS NOT NULL
                                                 THEN actual_count - expected_count
                                                 ELSE NULL END
                                        ) STORED,

    -- ─── STATUS LIFECYCLE ────────────────────────────────────────────────────
    -- PENDING   – checkpoint created, awaiting the return/completion event
    -- MATCHED   – actual_count = expected_count, all cylinders accounted for
    -- VARIANCE  – counts differ; human investigation required
    -- ESCALATED – variance open for > escalation_threshold_hours hours
    checkpoint_status       varchar(50) NOT NULL DEFAULT 'PENDING',

    -- When to auto-escalate if still PENDING (hours from created_at)
    -- e.g., a TRIP_DEPARTURE should have a TRIP_RETURN within 12 hours
    escalation_threshold_hours int4    DEFAULT 24,
    escalated_at            timestamp,

    remarks                 varchar(500),
    created_at              timestamp   NOT NULL DEFAULT now(),
    resolved_at             timestamp,

    CONSTRAINT tbl_recon_checkpoint_pk
        PRIMARY KEY (pk_checkpoint_id),

    CONSTRAINT tbl_recon_checkpoint_type_chk
        CHECK (checkpoint_type IN (
            'DAILY_OPENING',
            'TRIP_DEPARTURE',
            'SUPPLIER_DROPOFF',
            'YARD_AUDIT',
            'TRIP_RETURN',
            'SUPPLIER_COLLECTION',
            'DAILY_CLOSING'
        )),

    CONSTRAINT tbl_recon_checkpoint_status_chk
        CHECK (checkpoint_status IN ('PENDING','MATCHED','VARIANCE','ESCALATED')),

    CONSTRAINT tbl_recon_checkpoint_daily_count_fk
        FOREIGN KEY (fk_daily_count)
        REFERENCES public.tbl_daily_cylinder_count(pk_daily_count_id)
);

CREATE INDEX idx_recon_checkpoint_date     ON public.tbl_reconciliation_checkpoint(checkpoint_date DESC);
CREATE INDEX idx_recon_checkpoint_status   ON public.tbl_reconciliation_checkpoint(checkpoint_status)
    WHERE checkpoint_status IN ('PENDING','VARIANCE','ESCALATED');
CREATE INDEX idx_recon_checkpoint_entity   ON public.tbl_reconciliation_checkpoint(reference_entity_type, reference_entity_id);
CREATE INDEX idx_recon_checkpoint_type     ON public.tbl_reconciliation_checkpoint(checkpoint_type, checkpoint_date);

COMMENT ON TABLE public.tbl_reconciliation_checkpoint IS
    'Central orchestrator table. Every significant cylinder-movement event produces '
    'a checkpoint row. The system monitors PENDING checkpoints and escalates those '
    'that exceed the threshold. A clean operation shows all checkpoints at MATCHED '
    'by end of day.';

-- ---------------------------------------------------------------------------
-- FUNCTION: create a checkpoint (called by triggers on other tables)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_create_checkpoint(
    p_type              varchar(50),
    p_entity_type       varchar(100),
    p_entity_id         int8,
    p_expected_count    int4,
    p_threshold_hours   int4    DEFAULT 24,
    p_remarks           varchar(500) DEFAULT NULL
)
RETURNS int8 AS $$
DECLARE
    v_daily_count_id int8;
    v_new_id         int8;
BEGIN
    -- Auto-link to today's daily count row
    SELECT pk_daily_count_id INTO v_daily_count_id
    FROM public.tbl_daily_cylinder_count
    WHERE count_date = CURRENT_DATE;

    INSERT INTO public.tbl_reconciliation_checkpoint (
        checkpoint_type,
        reference_entity_type,
        reference_entity_id,
        fk_daily_count,
        expected_count,
        escalation_threshold_hours,
        remarks
    ) VALUES (
        p_type,
        p_entity_type,
        p_entity_id,
        v_daily_count_id,
        p_expected_count,
        p_threshold_hours,
        p_remarks
    )
    RETURNING pk_checkpoint_id INTO v_new_id;

    RETURN v_new_id;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- FUNCTION: close / resolve a checkpoint
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_resolve_checkpoint(
    p_entity_type   varchar(100),
    p_entity_id     int8,
    p_checkpoint_type varchar(50),
    p_actual_count  int4,
    p_remarks       varchar(500) DEFAULT NULL
)
RETURNS void AS $$
DECLARE
    v_expected int4;
    v_variance int4;
    v_status   varchar(50);
BEGIN
    SELECT expected_count INTO v_expected
    FROM public.tbl_reconciliation_checkpoint
    WHERE reference_entity_type = p_entity_type
      AND reference_entity_id   = p_entity_id
      AND checkpoint_type       = p_checkpoint_type
      AND checkpoint_status     = 'PENDING'
    ORDER BY created_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE NOTICE 'No PENDING checkpoint found for %:% type:%', p_entity_type, p_entity_id, p_checkpoint_type;
        RETURN;
    END IF;

    v_variance := p_actual_count - v_expected;
    v_status   := CASE WHEN v_variance = 0 THEN 'MATCHED' ELSE 'VARIANCE' END;

    UPDATE public.tbl_reconciliation_checkpoint
    SET actual_count       = p_actual_count,
        checkpoint_status  = v_status,
        resolved_at        = now(),
        remarks            = COALESCE(p_remarks, remarks)
    WHERE reference_entity_type = p_entity_type
      AND reference_entity_id   = p_entity_id
      AND checkpoint_type       = p_checkpoint_type
      AND checkpoint_status     = 'PENDING'
      AND pk_checkpoint_id = (
            SELECT pk_checkpoint_id FROM public.tbl_reconciliation_checkpoint
            WHERE reference_entity_type = p_entity_type
              AND reference_entity_id   = p_entity_id
              AND checkpoint_type       = p_checkpoint_type
              AND checkpoint_status     = 'PENDING'
            ORDER BY created_at DESC
            LIMIT 1
          );

    IF v_status = 'VARIANCE' THEN
        RAISE NOTICE 'VARIANCE on checkpoint %:% (type:%). Expected=% Actual=% Diff=%',
            p_entity_type, p_entity_id, p_checkpoint_type, v_expected, p_actual_count, v_variance;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- VIEW: unmatched checkpoints (the reconciliation dashboard)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.vw_reconciliation_dashboard AS
SELECT
    rc.pk_checkpoint_id,
    rc.checkpoint_date,
    rc.checkpoint_type,
    rc.reference_entity_type,
    rc.reference_entity_id,
    rc.expected_count,
    rc.actual_count,
    rc.variance,
    rc.checkpoint_status,
    rc.escalation_threshold_hours,
    EXTRACT(HOUR FROM now() - rc.created_at)::int   AS age_hours,
    CASE WHEN rc.checkpoint_status = 'PENDING'
          AND EXTRACT(HOUR FROM now() - rc.created_at) > rc.escalation_threshold_hours
         THEN TRUE ELSE FALSE END                    AS should_escalate,
    rc.remarks,
    rc.created_at
FROM public.tbl_reconciliation_checkpoint rc
WHERE rc.checkpoint_status IN ('PENDING', 'VARIANCE', 'ESCALATED')
ORDER BY rc.checkpoint_date DESC, rc.created_at DESC;

COMMENT ON VIEW public.vw_reconciliation_dashboard IS
    'Live view of all open reconciliation checkpoints. '
    'should_escalate = TRUE means a trip/supplier event is overdue for closure. '
    'This view should be polled by the orchestrator service every 15-30 minutes.';

-- ---------------------------------------------------------------------------
-- VIEW: daily reconciliation health (one row per day)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.vw_daily_reconciliation_health AS
SELECT
    rc.checkpoint_date,
    COUNT(*) FILTER (WHERE rc.checkpoint_type = 'TRIP_DEPARTURE')     AS trips_departed,
    COUNT(*) FILTER (WHERE rc.checkpoint_type = 'TRIP_RETURN'
                           AND rc.checkpoint_status = 'MATCHED')       AS trips_returned_clean,
    COUNT(*) FILTER (WHERE rc.checkpoint_type = 'TRIP_RETURN'
                           AND rc.checkpoint_status = 'VARIANCE')      AS trips_with_variance,
    COUNT(*) FILTER (WHERE rc.checkpoint_type = 'TRIP_DEPARTURE'
                           AND rc.checkpoint_status = 'PENDING')       AS trips_not_yet_returned,
    COUNT(*) FILTER (WHERE rc.checkpoint_type = 'YARD_AUDIT'
                           AND rc.checkpoint_status = 'MATCHED')       AS audits_clean,
    COUNT(*) FILTER (WHERE rc.checkpoint_status = 'VARIANCE')         AS total_variances,
    MAX(CASE WHEN rc.checkpoint_type = 'DAILY_CLOSING'
             THEN rc.checkpoint_status END)                            AS day_close_status
FROM public.tbl_reconciliation_checkpoint rc
GROUP BY rc.checkpoint_date
ORDER BY rc.checkpoint_date DESC;

COMMENT ON VIEW public.vw_daily_reconciliation_health IS
    'Summary of reconciliation health per day. A fully clean day shows: '
    'trips_returned_clean = trips_departed, trips_not_yet_returned = 0, '
    'total_variances = 0, day_close_status = MATCHED.';
