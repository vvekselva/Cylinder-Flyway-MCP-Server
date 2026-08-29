-- =============================================================================
-- V91__ReconciliationHeader_LineExtensions_And_YardValidation.sql
-- =============================================================================
--
-- DESIGN INTENT
-- ─────────────────────────────────────────────────────────────────────────────
-- The existing tbl_reconciliation_checkpoint is a flat table: one row per
-- checkpoint event, tracking a count.  It cannot represent serial-level
-- accountability across the life of a multi-stop trip.
--
-- This migration promotes tbl_reconciliation_checkpoint to the LINES role
-- and introduces tbl_reconciliation_header as the lifecycle owner.
--
-- HEADER / LINES RELATIONSHIP
--   tbl_reconciliation_header  (one per business event: trip load, yard check,
--                                supplier dropoff, supplier collection)
--     └── tbl_reconciliation_checkpoint  (one per cylinder serial — the lines)
--
-- HEADER STATUS LIFECYCLE
--   OPEN
--     │
--     ├──► YARD_ACCOUNTED   yard scan confirms expected load-gap matches
--     │         │
--     │         └──► CLOSED      all lines ACCOUNTED, zero variance
--     │               or
--     │              VARIANCE    one or more lines unaccounted
--     │
--     └──► UNDER_VIGILANCE  escalation window elapsed, still not fully closed
--               │
--               └──► VARIANCE    forced close with open lines
--
-- LINE STATUS (column: line_status on tbl_reconciliation_checkpoint)
--   PENDING        → created, not yet matched
--   YARD_ACCOUNTED → yard scan confirmed this cylinder's expected location
--   ACCOUNTED      → challan / collection / scan proved cylinder location
--   VARIANCE       → header closed but this line was never resolved
--
-- ACCOUNTABILITY BUCKETS (column: accountability_bucket)
--   DELIVERED        cylinder confirmed in tbl_order_line (customer challan)
--   SUPPLIER_DROPOFF cylinder confirmed in tbl_supplier_trip_line
--   RETURNED_FULL    cylinder back in yard state (FULL_PICKED_UP / FULL)
--   EMPTY_PICKUP     empty cylinder collected from customer during this trip
--   YARD_PRESENT     cylinder found in yard scan (matches system expectation)
--   YARD_MISSING     cylinder expected in yard but not found in scan
--   YARD_UNEXPECTED  cylinder found in scan but system shows it elsewhere
--   UNACCOUNTED      none of the above — physical location unknown
--
-- NEW TRIGGERS
--   tbl_yard_stock_check_line AFTER INSERT
--     → fn_yard_stock_check_line_reconcile()
--       Creates / grows a YARD_CHECK header.
--       Creates one ACCOUNTED checkpoint line per scanned cylinder.
--
--   tbl_yard_stock_check AFTER UPDATE (check_status → COMPLETED)
--     → fn_yard_stock_check_completed_reconcile()
--       Compares scanned set against system-expected yard population.
--       Creates VARIANCE lines for missing and unexpected cylinders.
--       Closes the header CLOSED or VARIANCE.
--
--   tbl_empty_pickup_line AFTER INSERT
--     → fn_empty_pickup_line_reconcile()
--       Creates one ACCOUNTED checkpoint line under the trip's TRIP_LOAD header.
--       Provides serial-level record of every empty collected mid-trip.
--
-- REPLACED FUNCTIONS (all become header-aware)
--   fn_trip_status_after_update        (was V90 — now V91)
--   fn_audit_supplier_dropoff_stop_completed (was V90 — now V91)
--   fn_audit_cylinder_refill_collection_after (was V90 — now V91)
--   fn_supplier_collection_checkpoint  (was V90 — now V91)
--   fn_supplier_collection_verified    (was V90 — now V91)
--
-- DEPENDENCIES
--   V57  tbl_supplier_trip.fk_vehicle_trip_stop (NOT tbl_supplier_trip_line)
--   V61  tbl_reconciliation_checkpoint
--   V76  fn_create_checkpoint, fn_resolve_checkpoint
--   V81  fn_trip_status_after_update (trigger body replaced here)
--   V90  fn_trip_load_accountability, vw_trip_load_accountability (kept as-is)
-- =============================================================================


-- =============================================================================
-- PART 1 — tbl_reconciliation_header
--           Lifecycle owner for every multi-cylinder accountability event.
-- =============================================================================

DROP SEQUENCE IF EXISTS public.pk_reconciliation_header_id_serial;
CREATE SEQUENCE public.pk_reconciliation_header_id_serial
    INCREMENT BY 1 MINVALUE 1 START 1 CACHE 1 NO CYCLE;

CREATE TABLE public.tbl_reconciliation_header (
    pk_header_id                bigint      NOT NULL
        DEFAULT nextval('public.pk_reconciliation_header_id_serial'),

    -- ── What kind of event does this header govern? ───────────────────────────
    header_type                 varchar(60) NOT NULL,
    -- TRIP_LOAD        one per vehicle trip (FULL cylinders from yard to customers)
    -- YARD_CHECK       one per yard stock check event (MORNING / POST_TRIP / EOD)
    -- SUPPLIER_DROPOFF one per supplier trip (empties handed to supplier)
    -- SUPPLIER_COLLECTION one per collection run (refilled cylinders returned)

    -- ── Generic reference for backward compat ────────────────────────────────
    reference_entity_type       varchar(100),
    reference_entity_id         int8,

    -- ── Typed FKs — exactly one is non-NULL per header ───────────────────────
    fk_vehicle_trip             int8        NULL,
    fk_vehicle_load             int8        NULL,
    fk_supplier_trip            int8        NULL,
    fk_yard_stock_check         int8        NULL,
    fk_supplier_collection      int8        NULL,

    -- ── Lifecycle ────────────────────────────────────────────────────────────
    header_status               varchar(30) NOT NULL DEFAULT 'OPEN',
    -- OPEN | YARD_ACCOUNTED | UNDER_VIGILANCE | CLOSED | VARIANCE

    -- ── Counts ───────────────────────────────────────────────────────────────
    expected_count              int4        NOT NULL DEFAULT 0,
    accounted_count             int4        NOT NULL DEFAULT 0,
    -- variance = expected_count - accounted_count (non-zero → investigate)

    -- ── Escalation ───────────────────────────────────────────────────────────
    escalation_threshold_hours  int4        NULL,
    escalation_due_at           timestamptz NULL,

    -- ── Timestamps ───────────────────────────────────────────────────────────
    opened_at                   timestamptz NOT NULL DEFAULT now(),
    closed_at                   timestamptz NULL,
    remarks                     text        NULL,

    created_at                  timestamptz NOT NULL DEFAULT now(),
    updated_at                  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tbl_reconciliation_header_pk
        PRIMARY KEY (pk_header_id),

    CONSTRAINT tbl_reconciliation_header_type_chk
        CHECK (header_type IN (
            'TRIP_LOAD', 'YARD_CHECK', 'SUPPLIER_DROPOFF', 'SUPPLIER_COLLECTION'
        )),

    CONSTRAINT tbl_reconciliation_header_status_chk
        CHECK (header_status IN (
            'OPEN', 'YARD_ACCOUNTED', 'UNDER_VIGILANCE', 'CLOSED', 'VARIANCE'
        )),

    CONSTRAINT tbl_reconciliation_header_vehicle_trip_fk
        FOREIGN KEY (fk_vehicle_trip)
        REFERENCES public.tbl_vehicle_trip(pk_vehicle_trip_id),

    CONSTRAINT tbl_reconciliation_header_vehicle_load_fk
        FOREIGN KEY (fk_vehicle_load)
        REFERENCES public.tbl_vehicle_load(pk_vehicle_load_id),

    CONSTRAINT tbl_reconciliation_header_supplier_trip_fk
        FOREIGN KEY (fk_supplier_trip)
        REFERENCES public.tbl_supplier_trip(pk_supplier_trip_id),

    CONSTRAINT tbl_reconciliation_header_yard_check_fk
        FOREIGN KEY (fk_yard_stock_check)
        REFERENCES public.tbl_yard_stock_check(pk_stock_check_id),

    CONSTRAINT tbl_reconciliation_header_collection_fk
        FOREIGN KEY (fk_supplier_collection)
        REFERENCES public.tbl_supplier_refill_collection(pk_collection_id)
);

CREATE INDEX idx_recon_header_trip
    ON public.tbl_reconciliation_header(fk_vehicle_trip)
    WHERE fk_vehicle_trip IS NOT NULL;

CREATE INDEX idx_recon_header_supplier_trip
    ON public.tbl_reconciliation_header(fk_supplier_trip)
    WHERE fk_supplier_trip IS NOT NULL;

CREATE INDEX idx_recon_header_yard_check
    ON public.tbl_reconciliation_header(fk_yard_stock_check)
    WHERE fk_yard_stock_check IS NOT NULL;

CREATE INDEX idx_recon_header_status
    ON public.tbl_reconciliation_header(header_status)
    WHERE header_status NOT IN ('CLOSED');

CREATE INDEX idx_recon_header_type_opened
    ON public.tbl_reconciliation_header(header_type, opened_at DESC);

COMMENT ON TABLE public.tbl_reconciliation_header IS
    'V91 — Lifecycle owner for multi-cylinder reconciliation events. '
    'One header per TRIP_LOAD / YARD_CHECK / SUPPLIER_DROPOFF / SUPPLIER_COLLECTION. '
    'Children are rows in tbl_reconciliation_checkpoint (one per cylinder serial). '
    'header_status tracks the event from OPEN → CLOSED or VARIANCE. '
    'expected_count is set at open time; accounted_count grows as cylinders are resolved.';


-- =============================================================================
-- PART 2 — Extend tbl_reconciliation_checkpoint with line-level columns
--           Existing rows and constraints are preserved.
-- =============================================================================

ALTER TABLE public.tbl_reconciliation_checkpoint
    -- Links this checkpoint row to its parent header (NULL for legacy rows)
    ADD COLUMN IF NOT EXISTS fk_header              int8        NULL,

    -- Direct cylinder reference — NULL for aggregate checkpoints (DAILY_OPENING etc.)
    ADD COLUMN IF NOT EXISTS fk_cylinder            int8        NULL,

    -- Per-line lifecycle status (complements checkpoint_status for serial tracking)
    ADD COLUMN IF NOT EXISTS line_status            varchar(30) NOT NULL DEFAULT 'PENDING',

    -- Which accountability bucket this cylinder fell into
    ADD COLUMN IF NOT EXISTS accountability_bucket  varchar(50) NULL,

    -- When and by whom this line was resolved (NULL while PENDING)
    ADD COLUMN IF NOT EXISTS line_resolved_at       timestamptz NULL,
    ADD COLUMN IF NOT EXISTS line_resolved_by       varchar(100) NULL;

ALTER TABLE public.tbl_reconciliation_checkpoint
    ADD CONSTRAINT tbl_recon_checkpoint_header_fk
        FOREIGN KEY (fk_header)
        REFERENCES public.tbl_reconciliation_header(pk_header_id),

    ADD CONSTRAINT tbl_recon_checkpoint_cylinder_fk
        FOREIGN KEY (fk_cylinder)
        REFERENCES public.tbl_cylinder(pk_cylinder_id),

    ADD CONSTRAINT tbl_recon_checkpoint_line_status_chk
        CHECK (line_status IN (
            'PENDING', 'YARD_ACCOUNTED', 'ACCOUNTED', 'VARIANCE'
        ));

CREATE INDEX idx_recon_checkpoint_header
    ON public.tbl_reconciliation_checkpoint(fk_header)
    WHERE fk_header IS NOT NULL;

CREATE INDEX idx_recon_checkpoint_cylinder
    ON public.tbl_reconciliation_checkpoint(fk_cylinder)
    WHERE fk_cylinder IS NOT NULL;

CREATE INDEX idx_recon_checkpoint_line_status
    ON public.tbl_reconciliation_checkpoint(fk_header, line_status)
    WHERE fk_header IS NOT NULL;

COMMENT ON COLUMN public.tbl_reconciliation_checkpoint.fk_header IS
    'V91 — Parent reconciliation header. NULL on legacy rows created before V91.';
COMMENT ON COLUMN public.tbl_reconciliation_checkpoint.fk_cylinder IS
    'V91 — Cylinder whose movement this line tracks. NULL for aggregate checkpoints.';
COMMENT ON COLUMN public.tbl_reconciliation_checkpoint.line_status IS
    'V91 — Per-cylinder lifecycle: PENDING → YARD_ACCOUNTED → ACCOUNTED | VARIANCE.';
COMMENT ON COLUMN public.tbl_reconciliation_checkpoint.accountability_bucket IS
    'V91 — How this cylinder was accounted: DELIVERED | SUPPLIER_DROPOFF | '
    'RETURNED_FULL | EMPTY_PICKUP | YARD_PRESENT | YARD_MISSING | YARD_UNEXPECTED | UNACCOUNTED.';


-- =============================================================================
-- PART 3 — fn_open_reconciliation_header
--           Creates a header and returns its pk_header_id.
--           Called by all event triggers below.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_open_reconciliation_header(
    p_header_type               varchar(60),
    p_reference_entity_type     varchar(100),
    p_reference_entity_id       int8,
    p_expected_count            int4,
    p_escalation_hours          int4,
    p_fk_vehicle_trip           int8    DEFAULT NULL,
    p_fk_vehicle_load           int8    DEFAULT NULL,
    p_fk_supplier_trip          int8    DEFAULT NULL,
    p_fk_yard_stock_check       int8    DEFAULT NULL,
    p_fk_supplier_collection    int8    DEFAULT NULL,
    p_remarks                   text    DEFAULT NULL
)
RETURNS int8      -- pk_header_id
LANGUAGE plpgsql
AS $$
DECLARE
    v_header_id int8;
BEGIN
    INSERT INTO public.tbl_reconciliation_header (
        header_type,
        reference_entity_type,
        reference_entity_id,
        expected_count,
        escalation_threshold_hours,
        escalation_due_at,
        fk_vehicle_trip,
        fk_vehicle_load,
        fk_supplier_trip,
        fk_yard_stock_check,
        fk_supplier_collection,
        remarks
    ) VALUES (
        p_header_type,
        p_reference_entity_type,
        p_reference_entity_id,
        p_expected_count,
        p_escalation_hours,
        CASE WHEN p_escalation_hours IS NOT NULL
             THEN now() + (p_escalation_hours || ' hours')::interval
             ELSE NULL END,
        p_fk_vehicle_trip,
        p_fk_vehicle_load,
        p_fk_supplier_trip,
        p_fk_yard_stock_check,
        p_fk_supplier_collection,
        p_remarks
    )
    RETURNING pk_header_id INTO v_header_id;

    RETURN v_header_id;
END;
$$;

COMMENT ON FUNCTION public.fn_open_reconciliation_header IS
    'V91 — Creates a reconciliation header and returns its PK. '
    'Called by event triggers (trip load, yard check, supplier dropoff, collection).';


-- =============================================================================
-- PART 4 — fn_add_reconciliation_line
--           Adds one checkpoint line (per cylinder) under a header.
--           Returns pk_checkpoint_id of the inserted row.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_add_reconciliation_line(
    p_header_id             int8,
    p_fk_cylinder           int8,
    p_checkpoint_type       varchar(50),
    p_line_status           varchar(30),    -- PENDING | ACCOUNTED | VARIANCE
    p_accountability_bucket varchar(50),
    p_reference_entity_type varchar(100)    DEFAULT NULL,
    p_reference_entity_id   int8            DEFAULT NULL,
    p_fk_vehicle_trip       int8            DEFAULT NULL,
    p_fk_vehicle_load       int8            DEFAULT NULL,
    p_remarks               varchar(500)    DEFAULT NULL,
    p_checkpoint_date       date            DEFAULT CURRENT_DATE
)
RETURNS int8      -- pk_checkpoint_id
LANGUAGE plpgsql
AS $$
DECLARE
    v_line_id   int8;
    v_cp_status varchar(50);
BEGIN
    -- Map line_status → checkpoint_status (backward compat column)
    v_cp_status := CASE p_line_status
                       WHEN 'ACCOUNTED'      THEN 'MATCHED'
                       WHEN 'VARIANCE'       THEN 'VARIANCE'
                       WHEN 'YARD_ACCOUNTED' THEN 'PENDING'   -- still open at header level
                       ELSE                       'PENDING'
                   END;

    INSERT INTO public.tbl_reconciliation_checkpoint (
        checkpoint_date,
        checkpoint_type,
        checkpoint_status,
        reference_entity_type,
        reference_entity_id,
        fk_vehicle_trip,
        fk_vehicle_load,
        expected_count,
        actual_count,
        escalation_threshold_hours,
        remarks,
        resolved_at,
        -- V91 line columns
        fk_header,
        fk_cylinder,
        line_status,
        accountability_bucket,
        line_resolved_at
    ) VALUES (
        p_checkpoint_date,
        p_checkpoint_type,
        v_cp_status,
        p_reference_entity_type,
        p_reference_entity_id,
        p_fk_vehicle_trip,
        p_fk_vehicle_load,
        1,   -- each line guards exactly 1 cylinder
        CASE WHEN p_line_status IN ('ACCOUNTED','YARD_ACCOUNTED') THEN 1 ELSE NULL END,
        NULL,  -- individual lines don't escalate; the header does
        p_remarks,
        CASE WHEN p_line_status IN ('ACCOUNTED','VARIANCE') THEN now() ELSE NULL END,
        -- V91
        p_header_id,
        p_fk_cylinder,
        p_line_status,
        p_accountability_bucket,
        CASE WHEN p_line_status IN ('ACCOUNTED','YARD_ACCOUNTED','VARIANCE') THEN now() ELSE NULL END
    )
    RETURNING pk_checkpoint_id INTO v_line_id;

    RETURN v_line_id;
END;
$$;

COMMENT ON FUNCTION public.fn_add_reconciliation_line IS
    'V91 — Inserts one tbl_reconciliation_checkpoint row as a child line of a header. '
    'One row per cylinder serial. Maps line_status to the legacy checkpoint_status column.';


-- =============================================================================
-- PART 5 — fn_resolve_reconciliation_line
--           Updates an existing PENDING line to ACCOUNTED or VARIANCE.
--           Increments the header accounted_count when ACCOUNTED.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_resolve_reconciliation_line(
    p_header_id             int8,
    p_fk_cylinder           int8,
    p_line_status           varchar(30),    -- ACCOUNTED | YARD_ACCOUNTED | VARIANCE
    p_accountability_bucket varchar(50),
    p_remarks               varchar(500)    DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows_updated int4;
BEGIN
    UPDATE public.tbl_reconciliation_checkpoint
       SET line_status           = p_line_status,
           accountability_bucket = p_accountability_bucket,
           checkpoint_status     = CASE p_line_status
                                       WHEN 'ACCOUNTED'      THEN 'MATCHED'
                                       WHEN 'YARD_ACCOUNTED' THEN 'PENDING'
                                       ELSE 'VARIANCE'
                                   END,
           actual_count          = CASE p_line_status
                                       WHEN 'ACCOUNTED'      THEN 1
                                       WHEN 'YARD_ACCOUNTED' THEN 1
                                       ELSE 0
                                   END,
           remarks               = COALESCE(p_remarks, remarks),
           line_resolved_at      = now(),
           resolved_at           = CASE p_line_status
                                       WHEN 'ACCOUNTED' THEN now()
                                       ELSE resolved_at
                                   END
     WHERE fk_header    = p_header_id
       AND fk_cylinder  = p_fk_cylinder
       AND line_status  = 'PENDING';

    GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

    -- Increment header accounted_count for fully resolved lines
    IF v_rows_updated > 0 AND p_line_status IN ('ACCOUNTED', 'YARD_ACCOUNTED') THEN
        UPDATE public.tbl_reconciliation_header
           SET accounted_count = accounted_count + v_rows_updated,
               updated_at      = now()
         WHERE pk_header_id = p_header_id;
    END IF;
END;
$$;

COMMENT ON FUNCTION public.fn_resolve_reconciliation_line IS
    'V91 — Resolves a PENDING line under a header. '
    'Increments header.accounted_count when line transitions to ACCOUNTED or YARD_ACCOUNTED.';


-- =============================================================================
-- PART 6 — fn_close_reconciliation_header
--           Evaluates the header: sets CLOSED (all accounted) or VARIANCE.
--           Called when the last expected line is resolved, or forced at Halt.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_close_reconciliation_header(
    p_header_id     int8,
    p_remarks       text    DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_expected      int4;
    v_accounted     int4;
    v_variance_lines int4;
    v_new_status    varchar(30);
BEGIN
    SELECT expected_count, accounted_count
      INTO v_expected, v_accounted
      FROM public.tbl_reconciliation_header
     WHERE pk_header_id = p_header_id;

    SELECT COUNT(*) INTO v_variance_lines
      FROM public.tbl_reconciliation_checkpoint
     WHERE fk_header   = p_header_id
       AND line_status IN ('PENDING', 'VARIANCE');

    -- Mark any still-PENDING lines as VARIANCE before closing
    IF v_variance_lines > 0 THEN
        UPDATE public.tbl_reconciliation_checkpoint
           SET line_status       = 'VARIANCE',
               checkpoint_status = 'VARIANCE',
               actual_count      = 0,
               line_resolved_at  = now()
         WHERE fk_header   = p_header_id
           AND line_status  = 'PENDING';

        v_new_status := 'VARIANCE';
    ELSE
        v_new_status := 'CLOSED';
    END IF;

    UPDATE public.tbl_reconciliation_header
       SET header_status   = v_new_status,
           accounted_count = v_accounted,
           closed_at       = now(),
           updated_at      = now(),
           remarks         = COALESCE(p_remarks,
                                 CASE v_new_status
                                     WHEN 'CLOSED' THEN
                                         'All ' || v_expected || ' cylinders accounted.'
                                     ELSE
                                         'VARIANCE: ' || (v_expected - v_accounted)
                                         || ' of ' || v_expected || ' cylinders unaccounted.'
                                 END)
     WHERE pk_header_id = p_header_id;
END;
$$;

COMMENT ON FUNCTION public.fn_close_reconciliation_header IS
    'V91 — Closes a reconciliation header. '
    'Any PENDING lines become VARIANCE. '
    'Sets header_status = CLOSED (all accounted) or VARIANCE (gap exists).';


-- =============================================================================
-- PART 7 — fn_trip_status_after_update  (replaces V90 version)
--
--   Loaded branch:
--     • fn_open_daily_count()          — unchanged
--     • Opens TRIP_LOAD reconciliation header
--     • Creates one checkpoint LINE per FULL_FOR_DELIVERY / FULL_FOR_BUFFER
--       cylinder (by serial) — line_status = PENDING
--     • TRIP_DEPARTURE checkpoint      — unchanged (12 h aggregate)
--
--   Halt branch:
--     1. Resolve each TRIP_STOP_DELIVERY  — unchanged
--     2. Resolve each TRIP_STOP_EMPTY_PICKUP — unchanged
--     3. Resolve TRIP_DEPARTURE          — unchanged
--     4. Resolve TRIP_LOAD header via fn_trip_load_accountability:
--        • Each DELIVERED cylinder          → resolve line ACCOUNTED (DELIVERED)
--        • Each SUPPLIER_DROPOFF cylinder   → resolve line ACCOUNTED (SUPPLIER_DROPOFF)
--        • Each RETURNED_FULL cylinder      → resolve line ACCOUNTED (RETURNED_FULL)
--        • Each UNACCOUNTED cylinder        → line stays PENDING → becomes VARIANCE on close
--        • fn_close_reconciliation_header closes header CLOSED or VARIANCE
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_trip_status_after_update()
RETURNS TRIGGER AS $$
DECLARE
    v_new_name              varchar(50);

    -- Load
    v_load_id               int8;
    v_cyl_count             int4 := 0;
    v_header_id             int8;

    -- Halt: stop checkpoint resolution
    v_stop_rec              RECORD;
    v_actual_lines          int4;
    v_delivered_count       int4 := 0;
    v_pickup_count          int4 := 0;

    -- Halt: TRIP_LOAD serial-level accountability
    v_acc_rec               RECORD;
    v_accounted_count       int4 := 0;
    v_unaccounted_count     int4 := 0;
    v_unaccounted_serials   text := '';
    v_load_remarks          text;
BEGIN
    IF NEW.fk_trip_status = OLD.fk_trip_status THEN RETURN NEW; END IF;

    SELECT status_name INTO v_new_name
      FROM public.tbl_trip_status
     WHERE pk_trip_status_id = NEW.fk_trip_status;

    SELECT pk_vehicle_load_id INTO v_load_id
      FROM public.tbl_vehicle_load
     WHERE fk_vehicle_trip = NEW.pk_vehicle_trip_id;

    IF v_load_id IS NOT NULL THEN
        SELECT COUNT(pk_vehicle_load_line_id) INTO v_cyl_count
          FROM public.tbl_vehicle_load_line
         WHERE fk_vehicle_load = v_load_id;

        IF v_cyl_count = 0 THEN
            SELECT COALESCE(total_cylinders_loaded, 0) INTO v_cyl_count
              FROM public.tbl_vehicle_load
             WHERE pk_vehicle_load_id = v_load_id;
        END IF;
    END IF;

    -- =========================================================================
    -- LOADED — open TRIP_LOAD header + create per-cylinder lines + TRIP_DEPARTURE
    -- =========================================================================
    IF v_new_name = 'Loaded' THEN

        BEGIN
            PERFORM public.fn_open_daily_count(CURRENT_DATE, 'TRIP_LOAD');
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[Loaded/daily_count]: %', SQLERRM;
        END;

        -- ── Open TRIP_LOAD header ─────────────────────────────────────────────
        BEGIN
            v_header_id := public.fn_open_reconciliation_header(
                'TRIP_LOAD',
                'tbl_vehicle_load',
                v_load_id,
                v_cyl_count,
                12,                              -- 12 h escalation window
                NEW.pk_vehicle_trip_id,          -- fk_vehicle_trip
                v_load_id,                       -- fk_vehicle_load
                NULL, NULL, NULL,
                'Trip ' || NEW.pk_vehicle_trip_id
                    || ' loaded: ' || v_cyl_count || ' FULL cylinders sealed for departure.'
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[Loaded/TRIP_LOAD header]: %', SQLERRM;
        END;

        -- ── Create one checkpoint LINE per FULL cylinder (by serial) ──────────
        -- Each line is PENDING until Halt resolves it via fn_trip_load_accountability.
        IF v_header_id IS NOT NULL AND v_load_id IS NOT NULL THEN
            BEGIN
                INSERT INTO public.tbl_reconciliation_checkpoint (
                    checkpoint_date,
                    checkpoint_type,
                    checkpoint_status,
                    reference_entity_type,
                    reference_entity_id,
                    fk_vehicle_trip,
                    fk_vehicle_load,
                    expected_count,
                    actual_count,
                    escalation_threshold_hours,
                    remarks,
                    fk_header,
                    fk_cylinder,
                    line_status,
                    accountability_bucket
                )
                SELECT
                    CURRENT_DATE,
                    'TRIP_LOAD_CONFIRMED',
                    'PENDING',
                    'tbl_vehicle_load_line',
                    vll.pk_vehicle_load_line_id,
                    NEW.pk_vehicle_trip_id,
                    v_load_id,
                    1,
                    NULL,
                    NULL,
                    'Load line: cylinder ' || c.cylinder_serial
                        || ' (' || vlp.load_purpose || ') — awaiting Halt accountability.',
                    v_header_id,
                    vll.fk_cylinder,
                    'PENDING',
                    'UNACCOUNTED'               -- starts unaccounted; updated at Halt
                FROM   public.tbl_vehicle_load_line   vll
                JOIN   public.tbl_cylinder             c    ON c.pk_cylinder_id    = vll.fk_cylinder
                JOIN   public.tbl_vehicle_load_purpose vlp  ON vlp.pk_load_purpose_id = vll.fk_load_purpose
                WHERE  vll.fk_vehicle_load = v_load_id
                  AND  vlp.load_purpose    IN ('FULL_FOR_DELIVERY', 'FULL_FOR_BUFFER');
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE '[Loaded/TRIP_LOAD lines]: %', SQLERRM;
            END;
        END IF;

        -- ── TRIP_DEPARTURE aggregate checkpoint (unchanged) ───────────────────
        BEGIN
            PERFORM public.fn_create_checkpoint(
                'TRIP_DEPARTURE',
                'tbl_vehicle_trip',
                NEW.pk_vehicle_trip_id,
                v_cyl_count,
                12,
                'Trip ' || NEW.pk_vehicle_trip_id
                    || ' departed with ' || v_cyl_count || ' cylinders.',
                CURRENT_DATE,
                NEW.pk_vehicle_trip_id,
                v_load_id,
                NULL
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[Loaded/TRIP_DEPARTURE]: %', SQLERRM;
        END;

    END IF;

    -- =========================================================================
    -- HALT — resolve all open checkpoints and the TRIP_LOAD header
    -- =========================================================================
    IF v_new_name = 'Halt' THEN

        -- ── Step 1: Resolve each TRIP_STOP_DELIVERY ───────────────────────────
        FOR v_stop_rec IN
            SELECT pk_checkpoint_id,
                   reference_entity_id AS order_id,
                   expected_count
              FROM public.tbl_reconciliation_checkpoint
             WHERE fk_vehicle_trip   = NEW.pk_vehicle_trip_id
               AND checkpoint_type   = 'TRIP_STOP_DELIVERY'
               AND checkpoint_status = 'PENDING'
               AND fk_header IS NULL   -- legacy aggregate rows only
        LOOP
            SELECT COUNT(*) INTO v_actual_lines
              FROM public.tbl_order_line
             WHERE fk_order = v_stop_rec.order_id;

            v_delivered_count := v_delivered_count + v_actual_lines;

            BEGIN
                PERFORM public.fn_resolve_checkpoint(
                    'tbl_order',
                    v_stop_rec.order_id,
                    'TRIP_STOP_DELIVERY',
                    v_actual_lines,
                    'Resolved at Halt. Lines entered: ' || v_actual_lines
                        || ' / Declared: ' || v_stop_rec.expected_count,
                    NEW.pk_vehicle_trip_id
                );
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE '[Halt/TRIP_STOP_DELIVERY order=%]: %',
                    v_stop_rec.order_id, SQLERRM;
            END;
        END LOOP;

        -- ── Step 2: Resolve each TRIP_STOP_EMPTY_PICKUP ──────────────────────
        FOR v_stop_rec IN
            SELECT pk_checkpoint_id,
                   reference_entity_id AS pickup_id,
                   expected_count
              FROM public.tbl_reconciliation_checkpoint
             WHERE fk_vehicle_trip   = NEW.pk_vehicle_trip_id
               AND checkpoint_type   = 'TRIP_STOP_EMPTY_PICKUP'
               AND checkpoint_status = 'PENDING'
               AND fk_header IS NULL
        LOOP
            SELECT COUNT(*) INTO v_actual_lines
              FROM public.tbl_empty_pickup_line
             WHERE fk_empty_pickup = v_stop_rec.pickup_id;

            v_pickup_count := v_pickup_count + v_actual_lines;

            BEGIN
                PERFORM public.fn_resolve_checkpoint(
                    'tbl_empty_pickup',
                    v_stop_rec.pickup_id,
                    'TRIP_STOP_EMPTY_PICKUP',
                    v_actual_lines,
                    'Resolved at Halt. Scanned: ' || v_actual_lines
                        || ' / Declared: ' || v_stop_rec.expected_count,
                    NEW.pk_vehicle_trip_id
                );
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE '[Halt/TRIP_STOP_EMPTY_PICKUP pickup=%]: %',
                    v_stop_rec.pickup_id, SQLERRM;
            END;
        END LOOP;

        -- ── Step 3: Resolve TRIP_DEPARTURE aggregate checkpoint ───────────────
        BEGIN
            PERFORM public.fn_resolve_checkpoint(
                'tbl_vehicle_trip',
                NEW.pk_vehicle_trip_id,
                'TRIP_DEPARTURE',
                v_delivered_count + v_pickup_count,
                COALESCE(
                    NEW.audit_notes,
                    'Halt — Delivered: ' || v_delivered_count
                        || ', Empties collected: ' || v_pickup_count
                        || ', Loaded: ' || v_cyl_count
                ),
                NEW.pk_vehicle_trip_id
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[Halt/TRIP_DEPARTURE]: %', SQLERRM;
        END;

        -- ── Step 4: Resolve TRIP_LOAD header — serial-level ──────────────────
        --
        --   For each loaded FULL cylinder, fn_trip_load_accountability assigns
        --   an accountability_bucket. We resolve the pre-created PENDING line for
        --   that cylinder: DELIVERED / SUPPLIER_DROPOFF / RETURNED_FULL → ACCOUNTED.
        --   UNACCOUNTED cylinders: their PENDING lines are left for
        --   fn_close_reconciliation_header to mark VARIANCE.
        --
        BEGIN
            -- Find the TRIP_LOAD header for this trip
            SELECT pk_header_id INTO v_header_id
              FROM public.tbl_reconciliation_header
             WHERE fk_vehicle_trip = NEW.pk_vehicle_trip_id
               AND header_type     = 'TRIP_LOAD'
               AND header_status   = 'OPEN'
             ORDER BY opened_at DESC
             LIMIT 1;

            IF v_header_id IS NULL THEN
                RAISE NOTICE '[Halt/TRIP_LOAD]: No open TRIP_LOAD header for trip %. '
                             'Header may have been created before V91 or was already closed.',
                    NEW.pk_vehicle_trip_id;
            ELSE
                FOR v_acc_rec IN
                    SELECT fk_cylinder,
                           cylinder_serial,
                           load_purpose_name,
                           accountability_bucket
                      FROM public.fn_trip_load_accountability(NEW.pk_vehicle_trip_id)
                LOOP
                    IF v_acc_rec.accountability_bucket = 'UNACCOUNTED' THEN
                        v_unaccounted_count := v_unaccounted_count + 1;
                        IF v_unaccounted_count <= 20 THEN
                            v_unaccounted_serials := v_unaccounted_serials
                                || v_acc_rec.cylinder_serial || ' ('
                                || v_acc_rec.load_purpose_name || '), ';
                        END IF;
                        -- PENDING line stays PENDING — fn_close_reconciliation_header
                        -- will mark it VARIANCE below.
                    ELSE
                        v_accounted_count := v_accounted_count + 1;
                        PERFORM public.fn_resolve_reconciliation_line(
                            v_header_id,
                            v_acc_rec.fk_cylinder,
                            'ACCOUNTED',
                            v_acc_rec.accountability_bucket,
                            'Halt: ' || v_acc_rec.accountability_bucket
                                || ' — serial ' || v_acc_rec.cylinder_serial
                        );
                    END IF;
                END LOOP;

                -- Build closing remarks
                IF v_unaccounted_count = 0 THEN
                    v_load_remarks :=
                        'All cylinders accounted at Halt. '
                        || 'Accounted: ' || v_accounted_count || '.';
                ELSE
                    v_load_remarks :=
                        'VARIANCE — ' || v_unaccounted_count || ' cylinder(s) UNACCOUNTED. '
                        || 'Serials: ' || rtrim(v_unaccounted_serials, ', ')
                        || CASE WHEN v_unaccounted_count > 20
                                THEN ' … (' || (v_unaccounted_count - 20) || ' more)'
                                ELSE '' END;
                END IF;

                -- Close the header (marks remaining PENDING lines as VARIANCE)
                PERFORM public.fn_close_reconciliation_header(v_header_id, v_load_remarks);

            END IF;

        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[Halt/TRIP_LOAD header]: %', SQLERRM;
        END;

    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger already exists from V69 — replacing function body is sufficient.

COMMENT ON FUNCTION public.fn_trip_status_after_update() IS
    'V91 — Replaces V90. '
    'Loaded: opens TRIP_LOAD reconciliation header + one checkpoint line per '
    'FULL_FOR_DELIVERY / FULL_FOR_BUFFER cylinder serial. Also emits aggregate '
    'TRIP_DEPARTURE checkpoint (unchanged). '
    'Halt: resolves all stop checkpoints (unchanged), resolves TRIP_DEPARTURE, '
    'then resolves TRIP_LOAD header via fn_trip_load_accountability — each '
    'cylinder line updated to ACCOUNTED (DELIVERED / SUPPLIER_DROPOFF / '
    'RETURNED_FULL) or VARIANCE (UNACCOUNTED). '
    'fn_close_reconciliation_header closes the header CLOSED or VARIANCE.';


-- =============================================================================
-- PART 8 — fn_audit_supplier_dropoff_stop_completed  (replaces V90 version)
--
--   SUPPLIER_DROPOFF header + per-cylinder lines (NEW in V91).
--   State transition loop: EMPTY_PICKED_FOR_REFILL → EMPTY_DELIVERED_FOR_REFILL
--     (unchanged from V90, fixed column: st.fk_vehicle_trip_stop not stl.)
--
--   The trip may deliver empties that originated from the yard load AND empties
--   collected from customers mid-trip.  No stop-type distinction is needed —
--   all empties physically present at the SUPPLIER_DROPOFF stop are treated
--   identically.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_audit_supplier_dropoff_stop_completed()
RETURNS TRIGGER AS $$
DECLARE
    v_stop_type_name           varchar(100);
    v_empty_picked_state_id    int8;
    v_empty_delivered_state_id int8;

    v_supplier_trip_id         int8;
    v_supplier_id              int8;
    v_cylinders_this_trip      int4 := 0;
    v_header_id                int8;

    rec                        RECORD;
BEGIN
    IF NEW.stop_status <> 'COMPLETED' THEN RETURN NEW; END IF;
    IF OLD.stop_status = 'COMPLETED'  THEN RETURN NEW; END IF;

    SELECT stop_type INTO v_stop_type_name
      FROM public.tbl_stop_type
     WHERE pk_stop_type_id = NEW.fk_stop_type;

    IF v_stop_type_name <> 'SUPPLIER_DROPOFF' THEN RETURN NEW; END IF;

    SELECT pk_cylinder_state_id INTO v_empty_picked_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_PICKED_FOR_REFILL';

    SELECT pk_cylinder_state_id INTO v_empty_delivered_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL';

    -- ── Cylinder state loop ───────────────────────────────────────────────────
    -- V57 moved fk_vehicle_trip_stop from tbl_supplier_trip_line to tbl_supplier_trip.
    -- Join: supplier_trip_line → supplier_trip → vehicle_trip_stop.
    FOR rec IN
        SELECT
            stl.fk_cylinder,
            stl.pk_supplier_trip_line_id,
            stl.fk_supplier_trip           AS supplier_trip_id,
            st.fk_supplier                 AS supplier_id
        FROM  public.tbl_supplier_trip_line  stl
        JOIN  public.tbl_supplier_trip       st   ON  st.pk_supplier_trip_id = stl.fk_supplier_trip
        WHERE st.fk_vehicle_trip_stop = NEW.pk_stop_id   -- corrected: st, not stl
    LOOP
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

        UPDATE public.tbl_cylinder_current_status
           SET fk_current_state        = v_empty_delivered_state_id,
               fk_current_vehicle_trip = NULL,
               fk_current_supplier     = rec.supplier_id,
               updated_at              = now()
         WHERE fk_cylinder = rec.fk_cylinder;

        v_supplier_trip_id    := rec.supplier_trip_id;
        v_supplier_id         := rec.supplier_id;
        v_cylinders_this_trip := v_cylinders_this_trip + 1;

    END LOOP;

    -- ── SUPPLIER_DROPOFF header + per-cylinder lines ──────────────────────────
    IF v_cylinders_this_trip > 0 AND v_supplier_trip_id IS NOT NULL THEN
        BEGIN
            -- Open the header (72 h: 3-day refill SLA)
            v_header_id := public.fn_open_reconciliation_header(
                'SUPPLIER_DROPOFF',
                'tbl_supplier_trip',
                v_supplier_trip_id,
                v_cylinders_this_trip,
                72,
                NEW.fk_vehicle_trip,
                NULL,
                v_supplier_trip_id,
                NULL, NULL,
                'Stop ' || NEW.pk_stop_id || ': '
                    || v_cylinders_this_trip || ' cylinders handed to supplier '
                    || v_supplier_id || '. Awaiting refill and collection.'
            );

            -- One checkpoint line per cylinder (PENDING — resolved at collection)
            INSERT INTO public.tbl_reconciliation_checkpoint (
                checkpoint_date,
                checkpoint_type,
                checkpoint_status,
                reference_entity_type,
                reference_entity_id,
                fk_vehicle_trip,
                fk_supplier_trip,
                expected_count,
                actual_count,
                escalation_threshold_hours,
                remarks,
                fk_header,
                fk_cylinder,
                line_status,
                accountability_bucket
            )
            SELECT
                CURRENT_DATE,
                'SUPPLIER_DROPOFF',
                'PENDING',
                'tbl_supplier_trip_line',
                stl.pk_supplier_trip_line_id,
                NEW.fk_vehicle_trip,
                v_supplier_trip_id,
                1,
                NULL,
                NULL,
                'Cylinder serial ' || c.cylinder_serial
                    || ' dropped at supplier ' || v_supplier_id
                    || '. Pending refill and collection.',
                v_header_id,
                stl.fk_cylinder,
                'PENDING',
                'SUPPLIER_DROPOFF'
            FROM  public.tbl_supplier_trip_line  stl
            JOIN  public.tbl_supplier_trip       st   ON  st.pk_supplier_trip_id = stl.fk_supplier_trip
            JOIN  public.tbl_cylinder            c    ON  c.pk_cylinder_id        = stl.fk_cylinder
            WHERE st.fk_vehicle_trip_stop = NEW.pk_stop_id;

        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[SUPPLIER_DROPOFF/header+lines supplier_trip=%]: %',
                v_supplier_trip_id, SQLERRM;
        END;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_audit_supplier_dropoff_stop_completed() IS
    'V91 — Replaces V90. '
    'State transition (unchanged): EMPTY_PICKED_FOR_REFILL → EMPTY_DELIVERED_FOR_REFILL. '
    'Fixed join: uses st.fk_vehicle_trip_stop (tbl_supplier_trip) per V57. '
    'NEW: opens SUPPLIER_DROPOFF reconciliation header + one PENDING checkpoint line '
    'per cylinder. Lines resolved by fn_audit_cylinder_refill_collection_after '
    'when each cylinder is collected back. Header closes when all lines ACCOUNTED.';


-- =============================================================================
-- PART 9 — fn_audit_cylinder_refill_collection_after  (replaces V90 version)
--
--   After each collection line INSERT:
--     • State transition (unchanged): EMPTY_DELIVERED_FOR_REFILL → FULL_PICKED_FROM_SUPPLIER
--     • Marks tbl_supplier_trip_line.collected = TRUE
--     • Resolves the SUPPLIER_DROPOFF checkpoint line for this cylinder
--     • When ALL lines for the supplier trip are now collected:
--         → fn_close_reconciliation_header closes the SUPPLIER_DROPOFF header
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_audit_cylinder_refill_collection_after()
RETURNS TRIGGER AS $$
DECLARE
    v_empty_delivered_state_id  int8;
    v_full_picked_state_id      int8;
    v_collection_trip_id        int8;

    v_supplier_trip_id          int8;
    v_total_lines               int4;
    v_collected_lines           int4;
    v_dropoff_header_id         int8;
BEGIN
    SELECT pk_cylinder_state_id INTO v_empty_delivered_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL';

    SELECT pk_cylinder_state_id INTO v_full_picked_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL_PICKED_FROM_SUPPLIER';

    SELECT fk_vehicle_trip INTO v_collection_trip_id
      FROM public.tbl_supplier_refill_collection
     WHERE pk_collection_id = NEW.fk_collection;

    -- ── State audit (unchanged) ───────────────────────────────────────────────
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

    -- ── Current status (unchanged) ────────────────────────────────────────────
    UPDATE public.tbl_cylinder_current_status
       SET fk_current_state           = v_full_picked_state_id,
           fk_current_vehicle_trip    = v_collection_trip_id,
           fk_current_supplier        = NULL,
           fk_current_holder_customer = NULL,
           updated_at                 = now()
     WHERE fk_cylinder = NEW.fk_cylinder;

    -- ── Mark supplier trip line collected (unchanged) ─────────────────────────
    UPDATE public.tbl_supplier_trip_line
       SET collected    = TRUE,
           collected_at = COALESCE(NEW.collected_at, now())
     WHERE pk_supplier_trip_line_id = NEW.fk_supplier_trip_line;

    -- ── Resolve the SUPPLIER_DROPOFF checkpoint line for this cylinder ─────────
    SELECT stl.fk_supplier_trip INTO v_supplier_trip_id
      FROM public.tbl_supplier_trip_line stl
     WHERE stl.pk_supplier_trip_line_id = NEW.fk_supplier_trip_line;

    IF v_supplier_trip_id IS NOT NULL THEN

        -- Find the open SUPPLIER_DROPOFF header for this supplier trip
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

        -- Check if ALL supplier trip lines are now collected
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

COMMENT ON FUNCTION public.fn_audit_cylinder_refill_collection_after() IS
    'V91 — Replaces V90. '
    'State transition (unchanged): EMPTY_DELIVERED_FOR_REFILL → FULL_PICKED_FROM_SUPPLIER. '
    'NEW: resolves the SUPPLIER_DROPOFF checkpoint line for this specific cylinder. '
    'When the last line is collected, closes the SUPPLIER_DROPOFF header.';


-- =============================================================================
-- PART 10 — fn_supplier_collection_checkpoint  (replaces V90 version)
--            AFTER INSERT on tbl_supplier_refill_collection (the header)
--
--   Opens a SUPPLIER_COLLECTION reconciliation header.
--   Creates one PENDING checkpoint line per uncollected supplier_trip_line.
--   Skipped when fk_supplier_trip IS NULL.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_supplier_collection_checkpoint()
RETURNS TRIGGER AS $$
DECLARE
    v_expected_count    int4 := 0;
    v_header_id         int8;
BEGIN
    IF NEW.fk_supplier_trip IS NULL THEN
        RAISE NOTICE
            '[SUPPLIER_COLLECTION]: fk_supplier_trip is NULL on collection %. Skipped.',
            NEW.pk_collection_id;
        RETURN NEW;
    END IF;

    SELECT COUNT(*) INTO v_expected_count
      FROM public.tbl_supplier_trip_line
     WHERE fk_supplier_trip = NEW.fk_supplier_trip
       AND collected         = FALSE;

    IF v_expected_count = 0 THEN
        RAISE NOTICE
            '[SUPPLIER_COLLECTION]: supplier_trip % has no uncollected lines. '
            'Collection % may be duplicate — skipped.',
            NEW.fk_supplier_trip, NEW.pk_collection_id;
        RETURN NEW;
    END IF;

    BEGIN
        -- Open SUPPLIER_COLLECTION header
        v_header_id := public.fn_open_reconciliation_header(
            'SUPPLIER_COLLECTION',
            'tbl_supplier_refill_collection',
            NEW.pk_collection_id,
            v_expected_count,
            24,                                 -- 24 h: same-day return
            NEW.fk_vehicle_trip,
            NULL,
            NEW.fk_supplier_trip,
            NULL,
            NEW.pk_collection_id,
            'Collection ' || COALESCE(NEW.collection_number, '#' || NEW.pk_collection_id)
                || ' — expecting ' || v_expected_count || ' refilled cylinders back.'
        );

        -- One PENDING line per cylinder to be collected
        INSERT INTO public.tbl_reconciliation_checkpoint (
            checkpoint_date,
            checkpoint_type,
            checkpoint_status,
            reference_entity_type,
            reference_entity_id,
            fk_vehicle_trip,
            fk_supplier_trip,
            expected_count,
            actual_count,
            escalation_threshold_hours,
            remarks,
            fk_header,
            fk_cylinder,
            line_status,
            accountability_bucket
        )
        SELECT
            NEW.collection_date,
            'SUPPLIER_COLLECTION',
            'PENDING',
            'tbl_supplier_trip_line',
            stl.pk_supplier_trip_line_id,
            NEW.fk_vehicle_trip,
            NEW.fk_supplier_trip,
            1,
            NULL,
            NULL,
            'Cylinder serial ' || c.cylinder_serial
                || ' — pending collection on run '
                || COALESCE(NEW.collection_number, '#' || NEW.pk_collection_id),
            v_header_id,
            stl.fk_cylinder,
            'PENDING',
            'SUPPLIER_DROPOFF'
        FROM  public.tbl_supplier_trip_line  stl
        JOIN  public.tbl_cylinder            c   ON c.pk_cylinder_id = stl.fk_cylinder
        WHERE stl.fk_supplier_trip = NEW.fk_supplier_trip
          AND stl.collected        = FALSE;

    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE '[SUPPLIER_COLLECTION/header+lines collection=%]: %',
            NEW.pk_collection_id, SQLERRM;
    END;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_supplier_collection_checkpoint
    ON public.tbl_supplier_refill_collection;

CREATE TRIGGER trg_supplier_collection_checkpoint
AFTER INSERT ON public.tbl_supplier_refill_collection
FOR EACH ROW EXECUTE FUNCTION public.fn_supplier_collection_checkpoint();

COMMENT ON FUNCTION public.fn_supplier_collection_checkpoint() IS
    'V91 — Replaces V90. Opens SUPPLIER_COLLECTION reconciliation header + '
    'one PENDING checkpoint line per uncollected supplier_trip_line. '
    'Header closed by fn_supplier_collection_verified when status → VERIFIED.';


-- =============================================================================
-- PART 11 — fn_supplier_collection_verified  (replaces V90 version)
--            AFTER UPDATE on tbl_supplier_refill_collection (status → VERIFIED)
--
--   Marks all PENDING SUPPLIER_COLLECTION lines as ACCOUNTED.
--   Closes the SUPPLIER_COLLECTION header CLOSED or VARIANCE.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_supplier_collection_verified()
RETURNS TRIGGER AS $$
DECLARE
    v_actual_count      int4 := 0;
    v_header_id         int8;
BEGIN
    IF NEW.collection_status <> 'VERIFIED'
    OR OLD.collection_status  = 'VERIFIED' THEN
        RETURN NEW;
    END IF;

    SELECT COUNT(*) INTO v_actual_count
      FROM public.tbl_supplier_refill_collection_line
     WHERE fk_collection = NEW.pk_collection_id;

    -- Find the SUPPLIER_COLLECTION header
    SELECT pk_header_id INTO v_header_id
      FROM public.tbl_reconciliation_header
     WHERE fk_supplier_collection = NEW.pk_collection_id
       AND header_type             = 'SUPPLIER_COLLECTION'
       AND header_status          NOT IN ('CLOSED', 'VARIANCE')
     ORDER BY opened_at DESC
     LIMIT 1;

    BEGIN
        IF v_header_id IS NOT NULL THEN
            -- Mark all PENDING lines ACCOUNTED
            UPDATE public.tbl_reconciliation_checkpoint
               SET line_status       = 'ACCOUNTED',
                   checkpoint_status = 'MATCHED',
                   actual_count      = 1,
                   line_resolved_at  = now(),
                   resolved_at       = now(),
                   remarks           = remarks || ' | Verified: '
                                       || COALESCE(NEW.collected_by, 'system')
                                       || ' at ' || now()::text
             WHERE fk_header    = v_header_id
               AND line_status  = 'PENDING';

            -- Update header accounted_count to match actual scanned
            UPDATE public.tbl_reconciliation_header
               SET accounted_count = v_actual_count,
                   updated_at      = now()
             WHERE pk_header_id = v_header_id;

            -- Close the header
            PERFORM public.fn_close_reconciliation_header(
                v_header_id,
                'Collection ' || COALESCE(NEW.collection_number, '#' || NEW.pk_collection_id)
                    || ' verified by ' || COALESCE(NEW.collected_by, 'system')
                    || '. Lines scanned: ' || v_actual_count
            );
        END IF;

        -- Also resolve the legacy aggregate checkpoint (backward compat)
        PERFORM public.fn_resolve_checkpoint(
            'tbl_supplier_refill_collection',
            NEW.pk_collection_id,
            'SUPPLIER_COLLECTION',
            v_actual_count,
            'Verified by: ' || COALESCE(NEW.collected_by, 'system')
                || ' on ' || now()::text
        );
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE '[SUPPLIER_COLLECTION/verify collection=%]: %',
            NEW.pk_collection_id, SQLERRM;
    END;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_supplier_collection_verified
    ON public.tbl_supplier_refill_collection;

CREATE TRIGGER trg_supplier_collection_verified
AFTER UPDATE OF collection_status ON public.tbl_supplier_refill_collection
FOR EACH ROW EXECUTE FUNCTION public.fn_supplier_collection_verified();

COMMENT ON FUNCTION public.fn_supplier_collection_verified() IS
    'V91 — Replaces V90. Fires when collection_status → VERIFIED. '
    'Marks all SUPPLIER_COLLECTION lines ACCOUNTED and closes the header.';


-- =============================================================================
-- PART 12 — fn_yard_stock_check_line_reconcile
--            AFTER INSERT on tbl_yard_stock_check_line
--
--   Each scanned cylinder creates:
--     1. A YARD_CHECK reconciliation header (first scan for this check_id)
--        OR grows the existing one (subsequent scans).
--     2. One ACCOUNTED checkpoint line for the scanned cylinder.
--
--   Validation of missing cylinders happens at check COMPLETION
--   (fn_yard_stock_check_completed_reconcile, PART 13).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_yard_stock_check_line_reconcile()
RETURNS TRIGGER AS $$
DECLARE
    v_header_id         int8;
    v_check_context     varchar(30);
    v_fk_vehicle_trip   int8;
BEGIN
    -- Get check context and optional trip link from the parent check
    SELECT check_context, fk_vehicle_trip
      INTO v_check_context, v_fk_vehicle_trip
      FROM public.tbl_yard_stock_check
     WHERE pk_stock_check_id = NEW.fk_stock_check;

    -- Get or create the YARD_CHECK header for this check event
    SELECT pk_header_id INTO v_header_id
      FROM public.tbl_reconciliation_header
     WHERE fk_yard_stock_check = NEW.fk_stock_check
       AND header_type         = 'YARD_CHECK'
     ORDER BY opened_at DESC
     LIMIT 1;

    IF v_header_id IS NULL THEN
        -- First cylinder scanned for this check — open the header
        -- expected_count will be updated when the check COMPLETES
        -- (we don't know upfront how many cylinders should be in the yard)
        v_header_id := public.fn_open_reconciliation_header(
            'YARD_CHECK',
            'tbl_yard_stock_check',
            NEW.fk_stock_check,
            0,                                  -- updated at completion
            NULL,                               -- no escalation on open; header closes when check is marked COMPLETED
            v_fk_vehicle_trip,
            NULL, NULL,
            NEW.fk_stock_check,
            NULL,
            'Yard check ' || COALESCE(v_check_context, 'ADHOC')
                || ' — check id ' || NEW.fk_stock_check || '. Scanning in progress.'
        );
    END IF;

    IF v_header_id IS NULL THEN
        RAISE NOTICE '[YARD_CHECK/line]: Could not create header for check %.', NEW.fk_stock_check;
        RETURN NEW;
    END IF;

    -- Create an ACCOUNTED checkpoint line for this scanned cylinder
    BEGIN
        PERFORM public.fn_add_reconciliation_line(
            v_header_id,
            NEW.fk_cylinder,
            'YARD_AUDIT',                       -- matches existing checkpoint type enum
            'ACCOUNTED',
            'YARD_PRESENT',
            'tbl_yard_stock_check_line',
            NEW.pk_stock_check_line_id,
            v_fk_vehicle_trip,
            NULL,
            'Cylinder scanned present in yard at '
                || to_char(NEW.scanned_at, 'YYYY-MM-DD HH24:MI')
                || ' (check context: ' || COALESCE(v_check_context, 'ADHOC') || ')',
            NEW.scanned_at::date
        );

        -- Grow the accounted_count on the header
        UPDATE public.tbl_reconciliation_header
           SET accounted_count = accounted_count + 1,
               updated_at      = now()
         WHERE pk_header_id = v_header_id;

    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE '[YARD_CHECK/line cylinder=%]: %', NEW.fk_cylinder, SQLERRM;
    END;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_yard_stock_check_line_reconcile
    ON public.tbl_yard_stock_check_line;

CREATE TRIGGER trg_yard_stock_check_line_reconcile
AFTER INSERT ON public.tbl_yard_stock_check_line
FOR EACH ROW EXECUTE FUNCTION public.fn_yard_stock_check_line_reconcile();

COMMENT ON FUNCTION public.fn_yard_stock_check_line_reconcile() IS
    'V91 — Fires AFTER INSERT on tbl_yard_stock_check_line. '
    'Opens a YARD_CHECK reconciliation header on the first scan for a check event. '
    'Creates one ACCOUNTED checkpoint line per scanned cylinder (YARD_PRESENT). '
    'Missing and unexpected cylinder detection happens at check COMPLETION '
    '(fn_yard_stock_check_completed_reconcile).';


-- =============================================================================
-- PART 13 — fn_yard_stock_check_completed_reconcile
--            AFTER UPDATE on tbl_yard_stock_check (check_status → COMPLETED)
--
--   Detects the gap between what the system expects to be in the yard and
--   what was physically scanned.
--
--   EXPECTED IN YARD:
--     Cylinders in tbl_cylinder_current_status where:
--       fk_current_vehicle_trip IS NULL  (not on a trip)
--       fk_current_supplier IS NULL      (not at supplier)
--       fk_current_holder_customer IS NULL (not at customer)
--     These are cylinders the system believes are physically at the yard.
--
--   SCANNED:
--     All fk_cylinder values in tbl_yard_stock_check_line for this check.
--
--   MISSING    = expected - scanned → VARIANCE line (YARD_MISSING bucket)
--   UNEXPECTED = scanned - expected → VARIANCE line (YARD_UNEXPECTED bucket)
--   PRESENT    = expected ∩ scanned → already ACCOUNTED by the line trigger
--
--   Sets header expected_count = |expected|, then closes CLOSED or VARIANCE.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_yard_stock_check_completed_reconcile()
RETURNS TRIGGER AS $$
DECLARE
    v_header_id             int8;
    v_expected_count        int4 := 0;
    v_missing_count         int4 := 0;
    v_unexpected_count      int4 := 0;
    v_missing_serials       text := '';
    v_unexpected_serials    text := '';
    v_closing_remarks       text;
    v_fk_vehicle_trip       int8;
    v_rec                   RECORD;
BEGIN
    -- Only fire on COMPLETED transition
    IF NEW.check_status <> 'COMPLETED'
    OR OLD.check_status  = 'COMPLETED' THEN
        RETURN NEW;
    END IF;

    -- Find the YARD_CHECK header
    SELECT pk_header_id, fk_vehicle_trip
      INTO v_header_id, v_fk_vehicle_trip
      FROM public.tbl_reconciliation_header
     WHERE fk_yard_stock_check = NEW.pk_stock_check_id
       AND header_type         = 'YARD_CHECK'
       AND header_status       NOT IN ('CLOSED', 'VARIANCE')
     ORDER BY opened_at DESC
     LIMIT 1;

    IF v_header_id IS NULL THEN
        RAISE NOTICE '[YARD_CHECK/completed]: No open header for check %.', NEW.pk_stock_check_id;
        RETURN NEW;
    END IF;

    -- Count cylinders expected in yard per system
    SELECT COUNT(*) INTO v_expected_count
      FROM public.tbl_cylinder_current_status ccs
     WHERE ccs.fk_current_vehicle_trip      IS NULL
       AND ccs.fk_current_supplier           IS NULL
       AND ccs.fk_current_holder_customer    IS NULL;

    -- Update header expected_count now that we know the population
    UPDATE public.tbl_reconciliation_header
       SET expected_count = v_expected_count,
           updated_at     = now()
     WHERE pk_header_id = v_header_id;

    -- ── MISSING: expected in yard but NOT scanned ─────────────────────────────
    FOR v_rec IN
        SELECT ccs.fk_cylinder, c.cylinder_serial
          FROM public.tbl_cylinder_current_status ccs
          JOIN public.tbl_cylinder                c   ON c.pk_cylinder_id = ccs.fk_cylinder
         WHERE ccs.fk_current_vehicle_trip     IS NULL
           AND ccs.fk_current_supplier          IS NULL
           AND ccs.fk_current_holder_customer   IS NULL
           AND ccs.fk_cylinder NOT IN (
              SELECT fk_cylinder
    FROM public.tbl_yard_stock_check_line
    WHERE fk_stock_check = NEW.pk_stock_check_id
      AND fk_cylinder IS NOT NULL
           )
    LOOP
        v_missing_count := v_missing_count + 1;
        IF v_missing_count <= 20 THEN
            v_missing_serials := v_missing_serials || v_rec.cylinder_serial || ', ';
        END IF;

        BEGIN
            PERFORM public.fn_add_reconciliation_line(
                v_header_id,
                v_rec.fk_cylinder,
                'YARD_AUDIT',
                'VARIANCE',
                'YARD_MISSING',
                'tbl_yard_stock_check',
                NEW.pk_stock_check_id,
                v_fk_vehicle_trip,
                NULL,
                'MISSING — cylinder ' || v_rec.cylinder_serial
                    || ' expected in yard but not found in scan.',
                NEW.check_date
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[YARD_CHECK/missing cylinder=%]: %', v_rec.fk_cylinder, SQLERRM;
        END;
    END LOOP;

    -- ── UNEXPECTED: scanned but system shows NOT in yard ─────────────────────
    FOR v_rec IN
        SELECT scl.fk_cylinder, c.cylinder_serial
          FROM public.tbl_yard_stock_check_line  scl
          JOIN public.tbl_cylinder                c   ON c.pk_cylinder_id = scl.fk_cylinder
         WHERE scl.fk_stock_check = NEW.pk_stock_check_id AND scl.fk_cylinder IS NOT NULL
           AND scl.fk_cylinder NOT IN (
               SELECT fk_cylinder
                 FROM public.tbl_cylinder_current_status
                WHERE fk_current_vehicle_trip    IS NULL
                  AND fk_current_supplier         IS NULL
                  AND fk_current_holder_customer  IS NULL
           )
    LOOP
        v_unexpected_count := v_unexpected_count + 1;
        IF v_unexpected_count <= 10 THEN
            v_unexpected_serials := v_unexpected_serials || v_rec.cylinder_serial || ', ';
        END IF;

        -- Update the already-ACCOUNTED line for this cylinder to VARIANCE
        UPDATE public.tbl_reconciliation_checkpoint
           SET line_status           = 'VARIANCE',
               checkpoint_status     = 'VARIANCE',
               accountability_bucket = 'YARD_UNEXPECTED',
               actual_count          = 0,
               line_resolved_at      = now(),
               remarks               = remarks || ' | UNEXPECTED: system shows '
                                       || 'this cylinder not in yard.'
         WHERE fk_header  = v_header_id
           AND fk_cylinder = v_rec.fk_cylinder
           AND line_status = 'ACCOUNTED';
    END LOOP;

    -- ── Build closing remarks ─────────────────────────────────────────────────
    IF v_missing_count = 0 AND v_unexpected_count = 0 THEN
        v_closing_remarks :=
            'Yard check ' || COALESCE(NEW.checked_by, 'system') || ' COMPLETED. '
            || v_expected_count || ' cylinders: all present, no variances.';
    ELSE
        v_closing_remarks :=
            'Yard check COMPLETED with VARIANCES. '
            || CASE WHEN v_missing_count > 0
                    THEN 'Missing: ' || v_missing_count || ' cylinders ('
                         || rtrim(v_missing_serials, ', ')
                         || CASE WHEN v_missing_count > 20 THEN ' …)' ELSE ')' END
                    ELSE '' END
            || CASE WHEN v_unexpected_count > 0
                    THEN ' Unexpected: ' || v_unexpected_count || ' cylinders ('
                         || rtrim(v_unexpected_serials, ', ')
                         || CASE WHEN v_unexpected_count > 10 THEN ' …)' ELSE ')' END
                    ELSE '' END;
    END IF;

    -- ── Close the header ──────────────────────────────────────────────────────
    BEGIN
        PERFORM public.fn_close_reconciliation_header(v_header_id, v_closing_remarks);
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE '[YARD_CHECK/close header]: %', SQLERRM;
    END;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_yard_stock_check_completed_reconcile
    ON public.tbl_yard_stock_check;

CREATE TRIGGER trg_yard_stock_check_completed_reconcile
AFTER UPDATE OF check_status ON public.tbl_yard_stock_check
FOR EACH ROW EXECUTE FUNCTION public.fn_yard_stock_check_completed_reconcile();

COMMENT ON FUNCTION public.fn_yard_stock_check_completed_reconcile() IS
    'V91 — Fires when tbl_yard_stock_check.check_status transitions to COMPLETED. '
    'Computes MISSING (expected in yard but not scanned) → VARIANCE lines (YARD_MISSING). '
    'Computes UNEXPECTED (scanned but system shows not in yard) → updates ACCOUNTED lines to VARIANCE (YARD_UNEXPECTED). '
    'Sets expected_count on header, then closes header CLOSED or VARIANCE.';


-- =============================================================================
-- PART 14 — fn_empty_pickup_line_reconcile
--            AFTER INSERT on tbl_empty_pickup_line
--
--   When an empty cylinder is scanned/logged during a pickup stop, creates an
--   ACCOUNTED checkpoint line under the trip's TRIP_LOAD header.
--
--   This is the ONLY event that records an empty pickup — no PENDING/DUE line
--   is pre-created.  The line is immediately ACCOUNTED (the pickup IS the event).
--
--   The line's accountability_bucket = EMPTY_PICKUP, providing a serial-level
--   record of every empty collected during the trip, traceable within the
--   TRIP_LOAD header.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_empty_pickup_line_reconcile()
RETURNS TRIGGER AS $$
DECLARE
    v_header_id         int8;
    v_trip_id           int8;
    v_cyl_serial        varchar(100);
BEGIN
    -- Resolve the vehicle trip from the empty pickup header
    SELECT vl.fk_vehicle_trip INTO v_trip_id
      FROM public.tbl_empty_pickup   ep
      JOIN public.tbl_vehicle_load   vl  ON vl.pk_vehicle_load_id = ep.fk_vehicle_load
     WHERE ep.pk_pickup_id = NEW.fk_empty_pickup;

    IF v_trip_id IS NULL THEN
        -- Empty pickup not linked to a trip (e.g. walk-in yard collection)
        RETURN NEW;
    END IF;

    -- Find the open TRIP_LOAD header for this trip
    SELECT pk_header_id INTO v_header_id
      FROM public.tbl_reconciliation_header
     WHERE fk_vehicle_trip = v_trip_id
       AND header_type     = 'TRIP_LOAD'
       AND header_status   NOT IN ('CLOSED', 'VARIANCE')
     ORDER BY opened_at DESC
     LIMIT 1;

    IF v_header_id IS NULL THEN
        -- Trip predates V91 or header already closed — silently skip
        RETURN NEW;
    END IF;

    SELECT cylinder_serial INTO v_cyl_serial
      FROM public.tbl_cylinder
     WHERE pk_cylinder_id = NEW.fk_cylinder;

    BEGIN
        PERFORM public.fn_add_reconciliation_line(
            v_header_id,
            NEW.fk_cylinder,
            'TRIP_STOP_EMPTY_PICKUP',
            'ACCOUNTED',
            'EMPTY_PICKUP',
            'tbl_empty_pickup_line',
            NEW.pk_pickup_line_id,
            v_trip_id,
            NULL,
            'Empty cylinder ' || COALESCE(v_cyl_serial, '#' || NEW.fk_cylinder)
                || ' collected from customer. Condition: '
                || NEW.cylinder_condition
                || CASE WHEN NEW.damage_description IS NOT NULL
                        THEN ' (' || NEW.damage_description || ')'
                        ELSE '' END
        );

        -- Grow the header expected_count by 1 for each empty collected
        -- (TRIP_LOAD header was sized for FULL cylinders; empties are additive)
        UPDATE public.tbl_reconciliation_header
           SET expected_count  = expected_count  + 1,
               accounted_count = accounted_count + 1,
               updated_at      = now()
         WHERE pk_header_id = v_header_id;

    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE '[EMPTY_PICKUP/line cylinder=%]: %', NEW.fk_cylinder, SQLERRM;
    END;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_empty_pickup_line_reconcile
    ON public.tbl_empty_pickup_line;

CREATE TRIGGER trg_empty_pickup_line_reconcile
AFTER INSERT ON public.tbl_empty_pickup_line
FOR EACH ROW EXECUTE FUNCTION public.fn_empty_pickup_line_reconcile();

COMMENT ON FUNCTION public.fn_empty_pickup_line_reconcile() IS
    'V91 — Fires AFTER INSERT on tbl_empty_pickup_line. '
    'Creates one ACCOUNTED checkpoint line (EMPTY_PICKUP bucket) under the '
    'trip''s TRIP_LOAD header. No PENDING/DUE line is pre-created — the pickup '
    'event itself is the sole notification. '
    'expected_count and accounted_count on the header are both incremented, '
    'since the empty pickup is immediately accounted for by the scan.';


-- =============================================================================
-- PART 15 — View: vw_reconciliation_header_dashboard
--            Operations dashboard — one row per open or recently closed header.
-- =============================================================================

CREATE OR REPLACE VIEW public.vw_reconciliation_header_dashboard AS
SELECT
    h.pk_header_id,
    h.header_type,
    h.header_status,
    h.expected_count,
    h.accounted_count,
    h.expected_count - h.accounted_count          AS variance_count,
    h.escalation_due_at,
    CASE WHEN h.escalation_due_at < now()
              AND h.header_status = 'OPEN'
         THEN TRUE ELSE FALSE END                  AS is_overdue,
    h.opened_at,
    h.closed_at,

    -- Trip details (TRIP_LOAD headers)
    vt.pk_vehicle_trip_id,
    v.vehicle_number,
    d.driver_name,

    -- Supplier details (SUPPLIER_DROPOFF / SUPPLIER_COLLECTION)
    sup.supplier_name,
    st.trip_number                                 AS supplier_trip_number,

    -- Yard check details (YARD_CHECK)
    ysc.check_date,
    ysc.check_context,
    ysc.checked_by,

    h.remarks

FROM   public.tbl_reconciliation_header          h
LEFT   JOIN public.tbl_vehicle_trip              vt   ON  vt.pk_vehicle_trip_id = h.fk_vehicle_trip
LEFT   JOIN public.tbl_vehicle                   v    ON  v.pk_vehicle_id        = vt.fk_vehicle
LEFT   JOIN public.tbl_driver                    d    ON  d.pk_driver_id         = vt.fk_driver
LEFT   JOIN public.tbl_supplier_trip             st   ON  st.pk_supplier_trip_id = h.fk_supplier_trip
LEFT   JOIN public.tbl_supplier                  sup  ON  sup.pk_supplier_id     = st.fk_supplier
LEFT   JOIN public.tbl_yard_stock_check          ysc  ON  ysc.pk_stock_check_id  = h.fk_yard_stock_check
WHERE  h.header_status NOT IN ('CLOSED')
    OR h.closed_at > now() - interval '24 hours'  -- keep last 24 h of closed headers visible
ORDER  BY h.opened_at DESC;

COMMENT ON VIEW public.vw_reconciliation_header_dashboard IS
    'V91 — Operations dashboard showing all open (and last 24 h closed) '
    'reconciliation headers. is_overdue = TRUE when escalation window elapsed. '
    'Drill down via fk_header on tbl_reconciliation_checkpoint for cylinder-level detail.';


-- =============================================================================
-- PART 16 — Backfill: fix existing TRIP_LOAD_CONFIRMED checkpoints
--            created with the incorrect 2-hour threshold (V90 backfill carried over)
-- =============================================================================

UPDATE public.tbl_reconciliation_checkpoint
   SET escalation_threshold_hours = 12
 WHERE checkpoint_type            = 'TRIP_LOAD_CONFIRMED'
   AND escalation_threshold_hours = 2
   AND checkpoint_status          = 'PENDING';
