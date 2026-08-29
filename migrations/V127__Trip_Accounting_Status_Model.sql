-- =====================================================================
-- V126__Trip_Accounting_Status_Model.sql
-- =====================================================================
-- Purpose:
--   Correct TRIP_LOAD accounting status model.
--
-- Accounting status:
--   UNACCOUNTED = load exists, challans/stops not fully entered/tallied yet
--   VARIANCE    = entered challans/stops do not tally with load lines
--   ACCOUNTED   = entered challans/stops tally with load lines
--
-- Closure status:
--   OPEN / CLOSED / AGING / ESCALATED
--   handled separately by V125 closure_status.
-- =====================================================================


-- =====================================================================
-- 1. Replace/relax header_status constraint
-- =====================================================================

DO $$
DECLARE
    v_constraint_name TEXT;
BEGIN
    FOR v_constraint_name IN
        SELECT conname
          FROM pg_constraint
         WHERE conrelid = 'public.tbl_reconciliation_header'::regclass
           AND contype = 'c'
           AND pg_get_constraintdef(oid) ILIKE '%header_status%'
    LOOP
        EXECUTE format(
            'ALTER TABLE public.tbl_reconciliation_header DROP CONSTRAINT IF EXISTS %I',
            v_constraint_name
        );
    END LOOP;

    IF NOT EXISTS (
        SELECT 1
          FROM pg_constraint
         WHERE conname = 'tbl_reconciliation_header_status_chk_v126'
    ) THEN
        ALTER TABLE public.tbl_reconciliation_header
        ADD CONSTRAINT tbl_reconciliation_header_status_chk_v126
        CHECK (
            header_status IN (
                'UNACCOUNTED',
                'ACCOUNTED',
                'VARIANCE',
                'OPEN',
                'CLOSED',
                'AGING',
                'ESCALATED'
            )
        );
    END IF;
END $$;


-- =====================================================================
-- 2. Replace/relax checkpoint_status and line_status constraints
-- =====================================================================

DO $$
DECLARE
    v_constraint_name TEXT;
BEGIN
    FOR v_constraint_name IN
        SELECT conname
          FROM pg_constraint
         WHERE conrelid = 'public.tbl_reconciliation_checkpoint'::regclass
           AND contype = 'c'
           AND (
                pg_get_constraintdef(oid) ILIKE '%checkpoint_status%'
                OR pg_get_constraintdef(oid) ILIKE '%line_status%'
           )
    LOOP
        EXECUTE format(
            'ALTER TABLE public.tbl_reconciliation_checkpoint DROP CONSTRAINT IF EXISTS %I',
            v_constraint_name
        );
    END LOOP;

    IF NOT EXISTS (
        SELECT 1
          FROM pg_constraint
         WHERE conname = 'tbl_reconciliation_checkpoint_status_chk_v126'
    ) THEN
        ALTER TABLE public.tbl_reconciliation_checkpoint
        ADD CONSTRAINT tbl_reconciliation_checkpoint_status_chk_v126
        CHECK (
            checkpoint_status IS NULL
            OR checkpoint_status IN (
                'PENDING',
                'MATCHED',
                'ACCOUNTED',
                'UNACCOUNTED',
                'VARIANCE',
                'AGING',
                'ESCALATED',
                'CLOSED',
                'OPEN'
            )
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM pg_constraint
         WHERE conname = 'tbl_reconciliation_checkpoint_line_status_chk_v126'
    ) THEN
        ALTER TABLE public.tbl_reconciliation_checkpoint
        ADD CONSTRAINT tbl_reconciliation_checkpoint_line_status_chk_v126
        CHECK (
            line_status IS NULL
            OR line_status IN (
                'PENDING',
                'ACCOUNTED',
                'UNACCOUNTED',
                'VARIANCE',
                'MATCHED',
                'CLOSED',
                'AGING',
                'ESCALATED'
            )
        );
    END IF;
END $$;


-- =====================================================================
-- 3. Recompute reconciliation header accounting status
-- =====================================================================

CREATE OR REPLACE FUNCTION public.fn_recompute_reconciliation_header_status(
    p_header_id BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
AS $function$
DECLARE
    v_header_type VARCHAR(100);
    v_old_status VARCHAR(50);
    v_new_status VARCHAR(50);
    v_trip_id BIGINT;
    v_load_id BIGINT;

    v_expected_count INTEGER := 0;
    v_accounted_count INTEGER := 0;
    v_variance_count INTEGER := 0;
    v_pending_count INTEGER := 0;
BEGIN
    IF p_header_id IS NULL THEN
        RETURN;
    END IF;

    SELECT header_type, header_status, fk_vehicle_trip, fk_vehicle_load
      INTO v_header_type, v_old_status, v_trip_id, v_load_id
      FROM public.tbl_reconciliation_header
     WHERE pk_header_id = p_header_id;

    IF v_header_type = 'TRIP_LOAD' THEN
        SELECT COUNT(*)
          INTO v_expected_count
          FROM public.tbl_reconciliation_checkpoint
         WHERE fk_header = p_header_id
           AND checkpoint_type = 'TRIP_LOAD';

        SELECT COUNT(*)
          INTO v_accounted_count
          FROM public.tbl_reconciliation_checkpoint
         WHERE fk_header = p_header_id
           AND checkpoint_type = 'TRIP_LOAD'
           AND (
                line_status IN ('ACCOUNTED', 'MATCHED', 'CLOSED')
                OR checkpoint_status IN ('ACCOUNTED', 'MATCHED', 'CLOSED')
           );

        SELECT COUNT(*)
          INTO v_variance_count
          FROM public.tbl_reconciliation_checkpoint
         WHERE fk_header = p_header_id
           AND checkpoint_type = 'TRIP_LOAD'
           AND (
                line_status IN ('VARIANCE', 'ESCALATED')
                OR checkpoint_status IN ('VARIANCE', 'ESCALATED')
           );

        SELECT COUNT(*)
          INTO v_pending_count
          FROM public.tbl_reconciliation_checkpoint
         WHERE fk_header = p_header_id
           AND checkpoint_type = 'TRIP_LOAD'
           AND (
                line_status IN ('PENDING', 'UNACCOUNTED')
                OR checkpoint_status IN ('PENDING', 'UNACCOUNTED')
           );

        IF v_expected_count = 0 THEN
            v_new_status := 'UNACCOUNTED';
        ELSIF v_variance_count > 0 THEN
            v_new_status := 'VARIANCE';
        ELSIF v_accounted_count = 0 THEN
            v_new_status := 'UNACCOUNTED';
        ELSIF v_accounted_count = v_expected_count AND v_pending_count = 0 THEN
            v_new_status := 'ACCOUNTED';
        ELSE
            v_new_status := 'VARIANCE';
        END IF;

        UPDATE public.tbl_reconciliation_header
           SET expected_count = v_expected_count,
               accounted_count = v_accounted_count,
               header_status = v_new_status,
               closed_at = CASE
                    WHEN v_new_status = 'ACCOUNTED'
                    THEN COALESCE(closed_at, now())
                    ELSE NULL
               END,
               updated_at = now()
         WHERE pk_header_id = p_header_id;

    ELSE
        SELECT COUNT(*)
          INTO v_expected_count
          FROM public.tbl_reconciliation_checkpoint
         WHERE fk_header = p_header_id;

        SELECT COUNT(*)
          INTO v_accounted_count
          FROM public.tbl_reconciliation_checkpoint
         WHERE fk_header = p_header_id
           AND line_status IN ('ACCOUNTED', 'MATCHED', 'CLOSED');

        SELECT COUNT(*)
          INTO v_variance_count
          FROM public.tbl_reconciliation_checkpoint
         WHERE fk_header = p_header_id
           AND line_status IN ('VARIANCE', 'ESCALATED');

        IF v_expected_count > 0
           AND v_accounted_count = v_expected_count
           AND v_variance_count = 0 THEN
            v_new_status := 'CLOSED';
        ELSIF v_variance_count > 0 THEN
            v_new_status := 'VARIANCE';
        ELSE
            v_new_status := 'OPEN';
        END IF;

        UPDATE public.tbl_reconciliation_header
           SET expected_count = v_expected_count,
               accounted_count = v_accounted_count,
               header_status = v_new_status,
               closed_at = CASE
                    WHEN v_new_status = 'CLOSED'
                    THEN COALESCE(closed_at, now())
                    ELSE NULL
               END,
               updated_at = now()
         WHERE pk_header_id = p_header_id;
    END IF;

    IF COALESCE(v_old_status, '') IS DISTINCT FROM COALESCE(v_new_status, '') THEN
        IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fn_log_reconciliation_event') THEN
            PERFORM public.fn_log_reconciliation_event(
                p_header_id,
                NULL,
                NULL,
                v_trip_id,
                v_load_id,
                CASE WHEN v_header_type = 'TRIP_LOAD'
                     THEN 'TRIP_ACCOUNTING_STATUS_CHANGE'
                     ELSE 'HEADER_STATUS_CHANGE'
                END,
                v_old_status,
                v_new_status,
                NULL,
                NULL,
                NULL,
                NULL,
                'tbl_reconciliation_header',
                p_header_id,
                'Header accounting status changed from '
                    || COALESCE(v_old_status, 'NULL')
                    || ' to '
                    || COALESCE(v_new_status, 'NULL'),
                'SYSTEM'
            );
        END IF;

        IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fn_log_reconciliation_status_change') THEN
            PERFORM public.fn_log_reconciliation_status_change(
                'HEADER',
                p_header_id,
                p_header_id,
                NULL,
                NULL,
                v_trip_id,
                v_load_id,
                v_old_status,
                v_new_status,
                CASE WHEN v_header_type = 'TRIP_LOAD'
                     THEN 'TRIP_ACCOUNTING_STATUS_CHANGE'
                     ELSE 'HEADER_STATUS_CHANGE'
                END,
                'tbl_reconciliation_header',
                p_header_id,
                'Header accounting status changed from '
                    || COALESCE(v_old_status, 'NULL')
                    || ' to '
                    || COALESCE(v_new_status, 'NULL'),
                'SYSTEM'
            );
        END IF;
    END IF;
END;
$function$;


-- =====================================================================
-- 4. Ensure TRIP_LOAD header opens as UNACCOUNTED
-- =====================================================================

CREATE OR REPLACE FUNCTION public.fn_ensure_trip_load_reconciliation_header(
    p_trip_id BIGINT,
    p_load_id BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $function$
DECLARE
    v_header_id BIGINT;
    v_expected_count INTEGER := 0;
BEGIN
    IF p_trip_id IS NULL AND p_load_id IS NOT NULL THEN
        SELECT fk_vehicle_trip
          INTO p_trip_id
          FROM public.tbl_vehicle_load
         WHERE pk_vehicle_load_id = p_load_id;
    END IF;

    IF p_load_id IS NULL AND p_trip_id IS NOT NULL THEN
        SELECT pk_vehicle_load_id
          INTO p_load_id
          FROM public.tbl_vehicle_load
         WHERE fk_vehicle_trip = p_trip_id
         ORDER BY pk_vehicle_load_id DESC
         LIMIT 1;
    END IF;

    IF p_trip_id IS NULL OR p_load_id IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT pk_header_id
      INTO v_header_id
      FROM public.tbl_reconciliation_header
     WHERE header_type = 'TRIP_LOAD'
       AND fk_vehicle_trip = p_trip_id
       AND fk_vehicle_load = p_load_id
     ORDER BY pk_header_id DESC
     LIMIT 1;

    IF v_header_id IS NOT NULL THEN
        RETURN v_header_id;
    END IF;

    SELECT COUNT(*)
      INTO v_expected_count
      FROM public.tbl_vehicle_load_line
     WHERE fk_vehicle_load = p_load_id;

    INSERT INTO public.tbl_reconciliation_header (
        header_type,
        reference_entity_type,
        reference_entity_id,
        fk_vehicle_trip,
        fk_vehicle_load,
        header_status,
        expected_count,
        accounted_count,
        escalation_threshold_hours,
        escalation_due_at,
        remarks
    ) VALUES (
        'TRIP_LOAD',
        'tbl_vehicle_load',
        p_load_id,
        p_trip_id,
        p_load_id,
        'UNACCOUNTED',
        v_expected_count,
        0,
        24,
        now() + interval '24 hours',
        'TRIP_LOAD accounting opened as UNACCOUNTED. Closure is tracked separately by closure_status.'
    )
    RETURNING pk_header_id INTO v_header_id;

    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fn_log_reconciliation_event') THEN
        PERFORM public.fn_log_reconciliation_event(
            v_header_id,
            NULL,
            NULL,
            p_trip_id,
            p_load_id,
            'TRIP_LOAD_HEADER_OPENED',
            NULL,
            'UNACCOUNTED',
            NULL,
            NULL,
            NULL,
            NULL,
            'tbl_vehicle_load',
            p_load_id,
            'TRIP_LOAD accounting opened for trip '
                || p_trip_id
                || ', load '
                || p_load_id
                || ', initial expected count '
                || COALESCE(v_expected_count, 0),
            'SYSTEM'
        );
    END IF;

    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fn_log_reconciliation_status_change') THEN
        PERFORM public.fn_log_reconciliation_status_change(
            'HEADER',
            v_header_id,
            v_header_id,
            NULL,
            NULL,
            p_trip_id,
            p_load_id,
            NULL,
            'UNACCOUNTED',
            'TRIP_LOAD_HEADER_OPENED',
            'tbl_vehicle_load',
            p_load_id,
            'Initial TRIP_LOAD accounting status UNACCOUNTED.',
            'SYSTEM'
        );
    END IF;

    RETURN v_header_id;
END;
$function$;


-- =====================================================================
-- 5. Seed TRIP_LOAD lines as UNACCOUNTED/PENDING
-- =====================================================================

CREATE OR REPLACE FUNCTION public.fn_seed_trip_load_reconciliation_lines(
    p_header_id BIGINT,
    p_trip_id BIGINT,
    p_load_id BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
AS $function$
DECLARE
    v_line RECORD;
    v_checkpoint_id BIGINT;
BEGIN
    IF p_header_id IS NULL OR p_load_id IS NULL THEN
        RETURN;
    END IF;

    FOR v_line IN
        SELECT
            vll.pk_vehicle_load_line_id,
            vll.fk_cylinder,
            c.cylinder_serial
        FROM public.tbl_vehicle_load_line vll
        JOIN public.tbl_cylinder c
          ON c.pk_cylinder_id = vll.fk_cylinder
        WHERE vll.fk_vehicle_load = p_load_id
          AND NOT EXISTS (
                SELECT 1
                  FROM public.tbl_reconciliation_checkpoint existing
                 WHERE existing.fk_header = p_header_id
                   AND existing.fk_cylinder = vll.fk_cylinder
                   AND existing.checkpoint_type = 'TRIP_LOAD'
          )
    LOOP
        INSERT INTO public.tbl_reconciliation_checkpoint (
            checkpoint_date,
            checkpoint_type,
            reference_entity_type,
            reference_entity_id,
            fk_vehicle_trip,
            fk_vehicle_load,
            expected_count,
            actual_count,
            checkpoint_status,
            escalation_threshold_hours,
            remarks,
            fk_header,
            fk_cylinder,
            line_status,
            accountability_bucket
        ) VALUES (
            CURRENT_DATE,
            'TRIP_LOAD',
            'tbl_vehicle_load_line',
            v_line.pk_vehicle_load_line_id,
            p_trip_id,
            p_load_id,
            1,
            NULL,
            'UNACCOUNTED',
            NULL,
            'TRIP_LOAD line opened. See tbl_reconciliation_event_log for system trail.',
            p_header_id,
            v_line.fk_cylinder,
            'PENDING',
            'LOADED'
        )
        RETURNING pk_checkpoint_id INTO v_checkpoint_id;

        IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fn_log_reconciliation_event') THEN
            PERFORM public.fn_log_reconciliation_event(
                p_header_id,
                v_checkpoint_id,
                v_line.fk_cylinder,
                p_trip_id,
                p_load_id,
                'TRIP_LOAD_LINE_OPENED',
                NULL,
                NULL,
                NULL,
                'PENDING',
                NULL,
                'LOADED',
                'tbl_vehicle_load_line',
                v_line.pk_vehicle_load_line_id,
                'Cylinder '
                    || v_line.cylinder_serial
                    || ' loaded on trip '
                    || p_trip_id
                    || '. Accounting pending challan/serial tally.',
                'SYSTEM'
            );
        END IF;

        IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fn_log_reconciliation_status_change') THEN
            PERFORM public.fn_log_reconciliation_status_change(
                'CHECKPOINT',
                v_checkpoint_id,
                p_header_id,
                v_checkpoint_id,
                v_line.fk_cylinder,
                p_trip_id,
                p_load_id,
                NULL,
                'PENDING',
                'TRIP_LOAD_LINE_OPENED',
                'tbl_vehicle_load_line',
                v_line.pk_vehicle_load_line_id,
                'Initial checkpoint line status PENDING for loaded cylinder.',
                'SYSTEM'
            );
        END IF;
    END LOOP;

    PERFORM public.fn_recompute_reconciliation_header_status(p_header_id);
END;
$function$;


-- =====================================================================
-- 6. Resolve TRIP_LOAD accountability using accounting status terms
-- =====================================================================

CREATE OR REPLACE FUNCTION public.fn_resolve_trip_load_accountability(
    p_trip_id BIGINT,
    p_cylinder_id BIGINT,
    p_accountability_bucket VARCHAR,
    p_resolved_via_entity VARCHAR,
    p_resolved_via_id BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
AS $function$
DECLARE
    v_load_id BIGINT;
    v_header_id BIGINT;
    v_checkpoint_id BIGINT;

    v_old_header_status VARCHAR(50);
    v_old_line_status VARCHAR(50);
    v_old_bucket VARCHAR(100);

    v_new_line_status VARCHAR(50);
    v_new_checkpoint_status VARCHAR(50);
    v_new_actual_count INTEGER;

    v_event_type VARCHAR(100);
    v_event_message VARCHAR(1000);
BEGIN
    IF p_trip_id IS NULL OR p_cylinder_id IS NULL THEN
        RETURN;
    END IF;

    SELECT vl.pk_vehicle_load_id
      INTO v_load_id
      FROM public.tbl_vehicle_load vl
      JOIN public.tbl_vehicle_load_line vll
        ON vll.fk_vehicle_load = vl.pk_vehicle_load_id
     WHERE vl.fk_vehicle_trip = p_trip_id
       AND vll.fk_cylinder = p_cylinder_id
     ORDER BY vl.pk_vehicle_load_id DESC
     LIMIT 1;

    IF v_load_id IS NULL THEN
        RETURN;
    END IF;

    v_header_id := public.fn_ensure_trip_load_reconciliation_header(p_trip_id, v_load_id);
    PERFORM public.fn_seed_trip_load_reconciliation_lines(v_header_id, p_trip_id, v_load_id);

    SELECT h.header_status,
           l.pk_checkpoint_id,
           l.line_status,
           l.accountability_bucket
      INTO v_old_header_status,
           v_checkpoint_id,
           v_old_line_status,
           v_old_bucket
      FROM public.tbl_reconciliation_header h
      JOIN public.tbl_reconciliation_checkpoint l
        ON l.fk_header = h.pk_header_id
     WHERE h.pk_header_id = v_header_id
       AND l.checkpoint_type = 'TRIP_LOAD'
       AND l.fk_cylinder = p_cylinder_id
     ORDER BY l.pk_checkpoint_id DESC
     LIMIT 1;

    IF v_checkpoint_id IS NULL THEN
        RETURN;
    END IF;

    IF p_accountability_bucket = 'RETURNED_TO_YARD' THEN
        v_new_line_status := 'ACCOUNTED';
        v_new_checkpoint_status := 'ACCOUNTED';
        v_new_actual_count := 1;
        v_event_type := 'TRIP_LOAD_FINAL_ACCOUNTING';
        v_event_message := 'Cylinder final accounting completed via RETURNED_TO_YARD.';
    ELSE
        v_new_line_status := 'PENDING';
        v_new_checkpoint_status := 'UNACCOUNTED';
        v_new_actual_count := NULL;
        v_event_type := 'TRIP_LOAD_INTERMEDIATE_MOVEMENT';
        v_event_message := 'Cylinder moved to intermediate bucket '
            || COALESCE(p_accountability_bucket, 'UNKNOWN_BUCKET')
            || '. Trip accounting remains incomplete until aggregate tally is complete.';
    END IF;

    UPDATE public.tbl_reconciliation_checkpoint
       SET line_status = v_new_line_status,
           checkpoint_status = v_new_checkpoint_status,
           accountability_bucket = p_accountability_bucket,
           actual_count = v_new_actual_count,
           line_resolved_at = CASE WHEN v_new_line_status = 'ACCOUNTED' THEN now() ELSE NULL END,
           line_resolved_by = CASE WHEN v_new_line_status = 'ACCOUNTED' THEN 'SYSTEM' ELSE NULL END,
           resolved_at = CASE WHEN v_new_line_status = 'ACCOUNTED' THEN now() ELSE NULL END,
           remarks = 'TRIP_LOAD line current accounting state. See tbl_reconciliation_event_log for system trail.'
     WHERE pk_checkpoint_id = v_checkpoint_id;

    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fn_log_reconciliation_event') THEN
        PERFORM public.fn_log_reconciliation_event(
            v_header_id,
            v_checkpoint_id,
            p_cylinder_id,
            p_trip_id,
            v_load_id,
            v_event_type,
            v_old_header_status,
            NULL,
            v_old_line_status,
            v_new_line_status,
            v_old_bucket,
            p_accountability_bucket,
            p_resolved_via_entity,
            p_resolved_via_id,
            v_event_message || ' Source: '
                || COALESCE(p_resolved_via_entity, 'UNKNOWN')
                || COALESCE('#' || p_resolved_via_id::TEXT, ''),
            'SYSTEM'
        );
    END IF;

    IF COALESCE(v_old_line_status, '') IS DISTINCT FROM COALESCE(v_new_line_status, '')
       AND EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fn_log_reconciliation_status_change') THEN
        PERFORM public.fn_log_reconciliation_status_change(
            'CHECKPOINT',
            v_checkpoint_id,
            v_header_id,
            v_checkpoint_id,
            p_cylinder_id,
            p_trip_id,
            v_load_id,
            v_old_line_status,
            v_new_line_status,
            v_event_type,
            p_resolved_via_entity,
            p_resolved_via_id,
            'TRIP_LOAD checkpoint line status changed from '
                || COALESCE(v_old_line_status, 'NULL')
                || ' to '
                || COALESCE(v_new_line_status, 'NULL')
                || ' with bucket '
                || COALESCE(p_accountability_bucket, 'NULL'),
            'SYSTEM'
        );
    END IF;

    PERFORM public.fn_recompute_reconciliation_header_status(v_header_id);
END;
$function$;


-- =====================================================================
-- 7. Backfill existing TRIP_LOAD accounting statuses
-- =====================================================================

UPDATE public.tbl_reconciliation_header
   SET header_status = 'UNACCOUNTED',
       updated_at = now()
 WHERE header_type = 'TRIP_LOAD'
   AND header_status IN ('OPEN', 'PENDING');

UPDATE public.tbl_reconciliation_header
   SET header_status = 'ACCOUNTED',
       updated_at = now()
 WHERE header_type = 'TRIP_LOAD'
   AND header_status IN ('CLOSED', 'MATCHED');

UPDATE public.tbl_reconciliation_checkpoint
   SET checkpoint_status = 'UNACCOUNTED'
 WHERE checkpoint_type = 'TRIP_LOAD'
   AND checkpoint_status IN ('PENDING', 'OPEN');

UPDATE public.tbl_reconciliation_checkpoint
   SET checkpoint_status = 'ACCOUNTED'
 WHERE checkpoint_type = 'TRIP_LOAD'
   AND checkpoint_status IN ('MATCHED', 'CLOSED');

DO $$
DECLARE
    v_header RECORD;
BEGIN
    FOR v_header IN
        SELECT pk_header_id
          FROM public.tbl_reconciliation_header
         WHERE header_type = 'TRIP_LOAD'
    LOOP
        PERFORM public.fn_recompute_reconciliation_header_status(v_header.pk_header_id);
    END LOOP;
END $$;


COMMENT ON COLUMN public.tbl_reconciliation_header.header_status IS
'Accounting status. For TRIP_LOAD use UNACCOUNTED / ACCOUNTED / VARIANCE. Trip closure is tracked separately in closure_status.';

COMMENT ON FUNCTION public.fn_recompute_reconciliation_header_status(BIGINT) IS
'V126: recomputes TRIP_LOAD accounting status as UNACCOUNTED / ACCOUNTED / VARIANCE. Non-TRIP_LOAD headers keep legacy OPEN/CLOSED behavior.';

COMMENT ON FUNCTION public.fn_resolve_trip_load_accountability(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT) IS
'V126: updates TRIP_LOAD line accounting. Intermediate movements remain UNACCOUNTED/PENDING; final accounting sets ACCOUNTED.';


DO $$
BEGIN
    RAISE NOTICE 'V126 OK: TRIP_LOAD accounting status model migrated to UNACCOUNTED / ACCOUNTED / VARIANCE.';
    RAISE NOTICE 'V126 OK: Trip closure remains separate in closure_status from V125.';
END $$;
