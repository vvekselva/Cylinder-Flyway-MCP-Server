-- =====================================================================
-- V121__Reconciliation_Event_Log_Keep_Trip_Load_Open_And_Party_Key.sql
-- =====================================================================
-- Purpose:
--   1. Add reconciliation event log table for system-generated audit trail.
--   2. Keep TRIP_LOAD open until final yard return.
--   3. Treat CUSTOMER_DELIVERY and SUPPLIER_DROPOFF as intermediate events.
--   4. Add party_dashboard_key to ownership party dashboard view to prevent
--      Hibernate cache/id collision between CUSTOMER:1 and SUPPLIER:1.
-- =====================================================================



CREATE SEQUENCE IF NOT EXISTS public.pk_reconciliation_event_log_id_serial
    START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;

CREATE TABLE IF NOT EXISTS public.tbl_reconciliation_event_log (
    pk_reconciliation_event_log_id BIGINT NOT NULL
        DEFAULT nextval('public.pk_reconciliation_event_log_id_serial'),

    fk_header BIGINT NULL,
    fk_checkpoint BIGINT NULL,
    fk_cylinder BIGINT NULL,
    fk_vehicle_trip BIGINT NULL,
    fk_vehicle_load BIGINT NULL,

    event_type VARCHAR(100) NOT NULL,

    old_header_status VARCHAR(50) NULL,
    new_header_status VARCHAR(50) NULL,

    old_line_status VARCHAR(50) NULL,
    new_line_status VARCHAR(50) NULL,

    old_accountability_bucket VARCHAR(100) NULL,
    new_accountability_bucket VARCHAR(100) NULL,

    source_entity_type VARCHAR(100) NULL,
    source_entity_id BIGINT NULL,

    event_message VARCHAR(1000) NULL,

    created_by VARCHAR(100) NOT NULL DEFAULT 'SYSTEM',
    created_at TIMESTAMP NOT NULL DEFAULT now(),

    CONSTRAINT tbl_reconciliation_event_log_pk
        PRIMARY KEY (pk_reconciliation_event_log_id),

    CONSTRAINT tbl_reconciliation_event_log_header_fk
        FOREIGN KEY (fk_header)
        REFERENCES public.tbl_reconciliation_header(pk_header_id),

    CONSTRAINT tbl_reconciliation_event_log_checkpoint_fk
        FOREIGN KEY (fk_checkpoint)
        REFERENCES public.tbl_reconciliation_checkpoint(pk_checkpoint_id),

    CONSTRAINT tbl_reconciliation_event_log_cylinder_fk
        FOREIGN KEY (fk_cylinder)
        REFERENCES public.tbl_cylinder(pk_cylinder_id),

    CONSTRAINT tbl_reconciliation_event_log_vehicle_trip_fk
        FOREIGN KEY (fk_vehicle_trip)
        REFERENCES public.tbl_vehicle_trip(pk_vehicle_trip_id),

    CONSTRAINT tbl_reconciliation_event_log_vehicle_load_fk
        FOREIGN KEY (fk_vehicle_load)
        REFERENCES public.tbl_vehicle_load(pk_vehicle_load_id)
);

CREATE INDEX IF NOT EXISTS idx_recon_event_log_header
    ON public.tbl_reconciliation_event_log(fk_header)
    WHERE fk_header IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_recon_event_log_checkpoint
    ON public.tbl_reconciliation_event_log(fk_checkpoint)
    WHERE fk_checkpoint IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_recon_event_log_cylinder
    ON public.tbl_reconciliation_event_log(fk_cylinder)
    WHERE fk_cylinder IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_recon_event_log_trip
    ON public.tbl_reconciliation_event_log(fk_vehicle_trip)
    WHERE fk_vehicle_trip IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_recon_event_log_created_at
    ON public.tbl_reconciliation_event_log(created_at);




-- =====================================================================
-- Reconciliation Status Audit
-- Tracks status transitions separately from business event trail.
-- =====================================================================

CREATE SEQUENCE IF NOT EXISTS public.pk_reconciliation_status_audit_id_serial
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

CREATE TABLE IF NOT EXISTS public.tbl_reconciliation_status_audit (
    pk_reconciliation_status_audit_id BIGINT NOT NULL
        DEFAULT nextval('public.pk_reconciliation_status_audit_id_serial'),

    record_type VARCHAR(30) NOT NULL,
    record_id BIGINT NOT NULL,

    fk_header BIGINT NULL,
    fk_checkpoint BIGINT NULL,
    fk_cylinder BIGINT NULL,
    fk_vehicle_trip BIGINT NULL,
    fk_vehicle_load BIGINT NULL,

    old_status VARCHAR(100) NULL,
    new_status VARCHAR(100) NULL,

    source_event_type VARCHAR(100) NULL,
    source_entity_type VARCHAR(100) NULL,
    source_entity_id BIGINT NULL,

    changed_by VARCHAR(100) NOT NULL DEFAULT 'SYSTEM',
    changed_at TIMESTAMP NOT NULL DEFAULT now(),

    remarks VARCHAR(1000) NULL,

    CONSTRAINT tbl_reconciliation_status_audit_pk
        PRIMARY KEY (pk_reconciliation_status_audit_id),

    CONSTRAINT tbl_reconciliation_status_audit_record_type_chk
        CHECK (record_type IN ('HEADER', 'CHECKPOINT')),

    CONSTRAINT tbl_reconciliation_status_audit_header_fk
        FOREIGN KEY (fk_header)
        REFERENCES public.tbl_reconciliation_header(pk_header_id),

    CONSTRAINT tbl_reconciliation_status_audit_checkpoint_fk
        FOREIGN KEY (fk_checkpoint)
        REFERENCES public.tbl_reconciliation_checkpoint(pk_checkpoint_id),

    CONSTRAINT tbl_reconciliation_status_audit_cylinder_fk
        FOREIGN KEY (fk_cylinder)
        REFERENCES public.tbl_cylinder(pk_cylinder_id),

    CONSTRAINT tbl_reconciliation_status_audit_vehicle_trip_fk
        FOREIGN KEY (fk_vehicle_trip)
        REFERENCES public.tbl_vehicle_trip(pk_vehicle_trip_id),

    CONSTRAINT tbl_reconciliation_status_audit_vehicle_load_fk
        FOREIGN KEY (fk_vehicle_load)
        REFERENCES public.tbl_vehicle_load(pk_vehicle_load_id)
);

CREATE INDEX IF NOT EXISTS idx_recon_status_audit_header
    ON public.tbl_reconciliation_status_audit(fk_header)
    WHERE fk_header IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_recon_status_audit_checkpoint
    ON public.tbl_reconciliation_status_audit(fk_checkpoint)
    WHERE fk_checkpoint IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_recon_status_audit_record
    ON public.tbl_reconciliation_status_audit(record_type, record_id);

CREATE INDEX IF NOT EXISTS idx_recon_status_audit_changed_at
    ON public.tbl_reconciliation_status_audit(changed_at);


CREATE OR REPLACE FUNCTION public.fn_log_reconciliation_status_change(
    p_record_type VARCHAR,
    p_record_id BIGINT,
    p_header_id BIGINT,
    p_checkpoint_id BIGINT,
    p_cylinder_id BIGINT,
    p_vehicle_trip_id BIGINT,
    p_vehicle_load_id BIGINT,
    p_old_status VARCHAR,
    p_new_status VARCHAR,
    p_source_event_type VARCHAR,
    p_source_entity_type VARCHAR,
    p_source_entity_id BIGINT,
    p_remarks VARCHAR,
    p_changed_by VARCHAR DEFAULT 'SYSTEM'
)
RETURNS VOID
LANGUAGE plpgsql
AS $function$
BEGIN
    IF COALESCE(p_old_status, '') IS NOT DISTINCT FROM COALESCE(p_new_status, '') THEN
        RETURN;
    END IF;

    INSERT INTO public.tbl_reconciliation_status_audit (
        record_type,
        record_id,
        fk_header,
        fk_checkpoint,
        fk_cylinder,
        fk_vehicle_trip,
        fk_vehicle_load,
        old_status,
        new_status,
        source_event_type,
        source_entity_type,
        source_entity_id,
        remarks,
        changed_by
    ) VALUES (
        p_record_type,
        p_record_id,
        p_header_id,
        p_checkpoint_id,
        p_cylinder_id,
        p_vehicle_trip_id,
        p_vehicle_load_id,
        p_old_status,
        p_new_status,
        p_source_event_type,
        p_source_entity_type,
        p_source_entity_id,
        p_remarks,
        COALESCE(p_changed_by, 'SYSTEM')
    );
END;
$function$;


CREATE OR REPLACE FUNCTION public.fn_log_reconciliation_event(
    p_header_id BIGINT,
    p_checkpoint_id BIGINT,
    p_cylinder_id BIGINT,
    p_vehicle_trip_id BIGINT,
    p_vehicle_load_id BIGINT,
    p_event_type VARCHAR,
    p_old_header_status VARCHAR,
    p_new_header_status VARCHAR,
    p_old_line_status VARCHAR,
    p_new_line_status VARCHAR,
    p_old_bucket VARCHAR,
    p_new_bucket VARCHAR,
    p_source_entity_type VARCHAR,
    p_source_entity_id BIGINT,
    p_event_message VARCHAR,
    p_created_by VARCHAR DEFAULT 'SYSTEM'
)
RETURNS VOID
LANGUAGE plpgsql
AS $function$
BEGIN
    INSERT INTO public.tbl_reconciliation_event_log (
        fk_header,
        fk_checkpoint,
        fk_cylinder,
        fk_vehicle_trip,
        fk_vehicle_load,
        event_type,
        old_header_status,
        new_header_status,
        old_line_status,
        new_line_status,
        old_accountability_bucket,
        new_accountability_bucket,
        source_entity_type,
        source_entity_id,
        event_message,
        created_by
    ) VALUES (
        p_header_id,
        p_checkpoint_id,
        p_cylinder_id,
        p_vehicle_trip_id,
        p_vehicle_load_id,
        p_event_type,
        p_old_header_status,
        p_new_header_status,
        p_old_line_status,
        p_new_line_status,
        p_old_bucket,
        p_new_bucket,
        p_source_entity_type,
        p_source_entity_id,
        p_event_message,
        COALESCE(p_created_by, 'SYSTEM')
    );
END;
$function$;



CREATE OR REPLACE FUNCTION public.fn_recompute_reconciliation_header_status(
    p_header_id BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
AS $function$
DECLARE
    v_expected_count INTEGER := 0;
    v_accounted_count INTEGER := 0;
    v_variance_count INTEGER := 0;
    v_old_status VARCHAR(50);
    v_new_status VARCHAR(50);
BEGIN
    IF p_header_id IS NULL THEN
        RETURN;
    END IF;

    SELECT header_status
      INTO v_old_status
      FROM public.tbl_reconciliation_header
     WHERE pk_header_id = p_header_id;

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
       SET expected_count  = v_expected_count,
           accounted_count = v_accounted_count,
           header_status   = v_new_status,
           closed_at       = CASE
                                WHEN v_new_status = 'CLOSED'
                                THEN COALESCE(closed_at, now())
                                ELSE NULL
                             END,
           updated_at      = now()
     WHERE pk_header_id = p_header_id;

    IF COALESCE(v_old_status, '') IS DISTINCT FROM COALESCE(v_new_status, '') THEN
        PERFORM public.fn_log_reconciliation_event(
            p_header_id, NULL, NULL, NULL, NULL,
            'HEADER_STATUS_CHANGE',
            v_old_status, v_new_status,
            NULL, NULL, NULL, NULL,
            'tbl_reconciliation_header', p_header_id,
            'Header status changed from '
                || COALESCE(v_old_status, 'NULL')
                || ' to '
                || COALESCE(v_new_status, 'NULL'),
            'SYSTEM'
        );
    
        PERFORM public.fn_log_reconciliation_status_change(
            'HEADER',
            p_header_id,
            p_header_id,
            NULL,
            NULL,
            NULL,
            NULL,
            v_old_status,
            v_new_status,
            'HEADER_STATUS_CHANGE',
            'tbl_reconciliation_header',
            p_header_id,
            'Header status changed from '
                || COALESCE(v_old_status, 'NULL')
                || ' to '
                || COALESCE(v_new_status, 'NULL'),
            'SYSTEM'
        );
END IF;
END;
$function$;



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
        'OPEN',
        v_expected_count,
        0,
        12,
        now() + interval '12 hours',
        'TRIP_LOAD accountability opened. See tbl_reconciliation_event_log for system trail.'
    )
    RETURNING pk_header_id INTO v_header_id;

    PERFORM public.fn_log_reconciliation_event(
        v_header_id, NULL, NULL, p_trip_id, p_load_id,
        'TRIP_LOAD_HEADER_OPENED',
        NULL, 'OPEN',
        NULL, NULL, NULL, NULL,
        'tbl_vehicle_load', p_load_id,
        'TRIP_LOAD header opened for trip ' || p_trip_id
            || ', load ' || p_load_id
            || ', initial expected count ' || COALESCE(v_expected_count, 0),
        'SYSTEM'
    );

    PERFORM public.fn_log_reconciliation_status_change(
        'HEADER',
        v_header_id,
        v_header_id,
        NULL,
        NULL,
        p_trip_id,
        p_load_id,
        NULL,
        'OPEN',
        'TRIP_LOAD_HEADER_OPENED',
        'tbl_vehicle_load',
        p_load_id,
        'Initial header status OPEN for TRIP_LOAD.',
        'SYSTEM'
    );

    RETURN v_header_id;
END;
$function$;



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
            'PENDING',
            NULL,
            'TRIP_LOAD line opened. See tbl_reconciliation_event_log for system trail.',
            p_header_id,
            v_line.fk_cylinder,
            'PENDING',
            'LOADED'
        )
        RETURNING pk_checkpoint_id INTO v_checkpoint_id;

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
            'Cylinder ' || v_line.cylinder_serial
                || ' loaded on trip ' || p_trip_id
                || '. Awaiting final yard return.',
            'SYSTEM'
        );

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
    END LOOP;

    PERFORM public.fn_recompute_reconciliation_header_status(p_header_id);
END;
$function$;



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
        RAISE NOTICE
            '[TRIP_LOAD_ACCOUNTABILITY] No vehicle load found for trip %, cylinder %.',
            p_trip_id, p_cylinder_id;
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
        RAISE NOTICE
            '[TRIP_LOAD_ACCOUNTABILITY] No TRIP_LOAD line found. header %, trip %, cylinder %.',
            v_header_id, p_trip_id, p_cylinder_id;
        RETURN;
    END IF;

    IF p_accountability_bucket = 'RETURNED_TO_YARD' THEN
        v_new_line_status := 'ACCOUNTED';
        v_new_checkpoint_status := 'MATCHED';
        v_new_actual_count := 1;
        v_event_type := 'TRIP_LOAD_FINAL_SETTLEMENT';
        v_event_message := 'Cylinder returned to yard. TRIP_LOAD line finally accounted.';
    ELSE
        v_new_line_status := 'PENDING';
        v_new_checkpoint_status := 'PENDING';
        v_new_actual_count := NULL;
        v_event_type := 'TRIP_LOAD_INTERMEDIATE_SETTLEMENT';
        v_event_message := 'Cylinder moved to intermediate bucket '
            || COALESCE(p_accountability_bucket, 'UNKNOWN_BUCKET')
            || '. TRIP_LOAD remains open until yard return.';
    END IF;

    UPDATE public.tbl_reconciliation_checkpoint
       SET line_status = v_new_line_status,
           checkpoint_status = v_new_checkpoint_status,
           accountability_bucket = p_accountability_bucket,
           actual_count = v_new_actual_count,
           line_resolved_at = CASE
                                WHEN p_accountability_bucket = 'RETURNED_TO_YARD'
                                THEN now()
                                ELSE NULL
                              END,
           line_resolved_by = CASE
                                WHEN p_accountability_bucket = 'RETURNED_TO_YARD'
                                THEN 'SYSTEM'
                                ELSE NULL
                              END,
           resolved_at = CASE
                            WHEN p_accountability_bucket = 'RETURNED_TO_YARD'
                            THEN now()
                            ELSE NULL
                         END,
           remarks = 'TRIP_LOAD line current state. See tbl_reconciliation_event_log for system trail.'
     WHERE pk_checkpoint_id = v_checkpoint_id;

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
        CASE
            WHEN p_accountability_bucket = 'RETURNED_TO_YARD'
            THEN 'TRIP_LOAD_FINAL_SETTLEMENT'
            ELSE 'TRIP_LOAD_INTERMEDIATE_SETTLEMENT'
        END,
        p_resolved_via_entity,
        p_resolved_via_id,
        'TRIP_LOAD checkpoint status changed from '
            || COALESCE(v_old_line_status, 'NULL')
            || ' to '
            || COALESCE(v_new_line_status, 'NULL')
            || ' with bucket '
            || COALESCE(p_accountability_bucket, 'NULL'),
        'SYSTEM'
    );

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

    PERFORM public.fn_recompute_reconciliation_header_status(v_header_id);
END;
$function$;



COMMENT ON TABLE public.tbl_reconciliation_status_audit IS
    'Status transition audit for reconciliation headers and checkpoint lines. Separate from tbl_reconciliation_event_log business event history.';
