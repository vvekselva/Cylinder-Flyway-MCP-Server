-- =====================================================================
-- V119__Trip_Load_Reconciliation_Refactor.sql
-- =====================================================================
-- Purpose:
--   Refactor TRIP_LOAD reconciliation from count-only / event-specific
--   handling to serial-level parent accountability.
--
-- Rule:
--   Every cylinder loaded into a vehicle load creates one TRIP_LOAD line.
--   The parent TRIP_LOAD header remains OPEN until every loaded cylinder
--   is accounted through a valid settlement path:
--     CUSTOMER_DELIVERY, SUPPLIER_DROPOFF, RETURNED_TO_YARD
-- =====================================================================



-- =====================================================================
-- Add TRIP_LOAD checkpoint type while preserving existing checkpoint types
-- =====================================================================
ALTER TABLE public.tbl_reconciliation_checkpoint
DROP CONSTRAINT IF EXISTS tbl_recon_checkpoint_type_chk;

ALTER TABLE public.tbl_reconciliation_checkpoint
ADD CONSTRAINT tbl_recon_checkpoint_type_chk
CHECK (
    checkpoint_type IN (
        'DAILY_OPENING',
        'DAILY_CLOSING',
        'TRIP_LOAD_CONFIRMED',
        'TRIP_DEPARTURE',
        'TRIP_LOAD',
        'TRIP_STOP_DELIVERY',
        'TRIP_STOP_EMPTY_PICKUP',
        'TRIP_RETURN',
        'YARD_AUDIT',
        'SUPPLIER_DROPOFF',
        'SUPPLIER_COLLECTION'
    )
);

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
    v_new_status VARCHAR(30);
BEGIN
    IF p_header_id IS NULL THEN
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_expected_count
      FROM public.tbl_reconciliation_checkpoint
     WHERE fk_header = p_header_id;

    SELECT COUNT(*) INTO v_accounted_count
      FROM public.tbl_reconciliation_checkpoint
     WHERE fk_header = p_header_id
       AND line_status IN ('ACCOUNTED', 'MATCHED', 'CLOSED');

    SELECT COUNT(*) INTO v_variance_count
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
           closed_at       = CASE WHEN v_new_status = 'CLOSED'
                                  THEN COALESCE(closed_at, now())
                                  ELSE NULL END,
           updated_at      = now()
     WHERE pk_header_id = p_header_id;
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
        SELECT fk_vehicle_trip INTO p_trip_id
          FROM public.tbl_vehicle_load
         WHERE pk_vehicle_load_id = p_load_id;
    END IF;

    IF p_load_id IS NULL AND p_trip_id IS NOT NULL THEN
        SELECT pk_vehicle_load_id INTO p_load_id
          FROM public.tbl_vehicle_load
         WHERE fk_vehicle_trip = p_trip_id
         ORDER BY pk_vehicle_load_id DESC
         LIMIT 1;
    END IF;

    IF p_trip_id IS NULL OR p_load_id IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT pk_header_id INTO v_header_id
      FROM public.tbl_reconciliation_header
     WHERE header_type = 'TRIP_LOAD'
       AND fk_vehicle_trip = p_trip_id
       AND fk_vehicle_load = p_load_id
     ORDER BY pk_header_id DESC
     LIMIT 1;

    IF v_header_id IS NOT NULL THEN
        RETURN v_header_id;
    END IF;

    SELECT COUNT(*) INTO v_expected_count
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
        'Trip ' || p_trip_id || ' loaded: ' || v_expected_count
            || ' cylinders sealed for departure.'
    )
    RETURNING pk_header_id INTO v_header_id;

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
BEGIN
    IF p_header_id IS NULL OR p_load_id IS NULL THEN
        RETURN;
    END IF;

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
    )
    SELECT
        CURRENT_DATE,
        'TRIP_LOAD',
        'tbl_vehicle_load_line',
        vll.pk_vehicle_load_line_id,
        p_trip_id,
        p_load_id,
        1,
        NULL,
        'PENDING',
        NULL,
        'Cylinder serial ' || c.cylinder_serial
            || ' loaded on trip ' || p_trip_id
            || '. Pending settlement.',
        p_header_id,
        vll.fk_cylinder,
        'PENDING',
        'LOADED'
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
      );

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
    v_rows_updated INTEGER := 0;
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
        RAISE NOTICE '[TRIP_LOAD_ACCOUNTABILITY] No load found for trip %, cylinder %.',
            p_trip_id, p_cylinder_id;
        RETURN;
    END IF;

    v_header_id := public.fn_ensure_trip_load_reconciliation_header(p_trip_id, v_load_id);

    PERFORM public.fn_seed_trip_load_reconciliation_lines(v_header_id, p_trip_id, v_load_id);

    UPDATE public.tbl_reconciliation_checkpoint
       SET line_status = 'ACCOUNTED',
           checkpoint_status = 'MATCHED',
           accountability_bucket = p_accountability_bucket,
           actual_count = 1,
           line_resolved_at = now(),
           line_resolved_by = 'SYSTEM',
           resolved_at = now(),
           remarks = COALESCE(remarks, '')
                     || ' | Accounted via '
                     || COALESCE(p_accountability_bucket, 'UNKNOWN_BUCKET')
                     || CASE
                            WHEN p_resolved_via_entity IS NOT NULL THEN
                                ' using ' || p_resolved_via_entity
                                || COALESCE('#' || p_resolved_via_id::text, '')
                            ELSE ''
                        END
     WHERE fk_header = v_header_id
       AND checkpoint_type = 'TRIP_LOAD'
       AND fk_cylinder = p_cylinder_id
       AND line_status IN ('PENDING', 'LOADED', 'VARIANCE', 'UNACCOUNTED');

    GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

    IF v_rows_updated = 0 THEN
        RAISE NOTICE '[TRIP_LOAD_ACCOUNTABILITY] No pending line resolved. header %, trip %, cylinder %, bucket %.',
            v_header_id, p_trip_id, p_cylinder_id, p_accountability_bucket;
    END IF;

    PERFORM public.fn_recompute_reconciliation_header_status(v_header_id);
END;
$function$;


CREATE OR REPLACE FUNCTION public.fn_trip_load_accountability(p_trip_id bigint)
RETURNS TABLE(
    fk_cylinder bigint,
    cylinder_serial character varying,
    load_purpose_name character varying,
    accountability_bucket character varying,
    resolved_via_entity character varying,
    resolved_via_id bigint
)
LANGUAGE plpgsql
STABLE
AS $function$
BEGIN
    RETURN QUERY
    WITH loaded AS (
        SELECT
            vll.fk_cylinder,
            c.cylinder_serial,
            vlp.load_purpose,
            vll.pk_vehicle_load_line_id
        FROM public.tbl_vehicle_load_line vll
        JOIN public.tbl_vehicle_load vl
          ON vl.pk_vehicle_load_id = vll.fk_vehicle_load
        JOIN public.tbl_cylinder c
          ON c.pk_cylinder_id = vll.fk_cylinder
        LEFT JOIN public.tbl_vehicle_load_purpose vlp
          ON vlp.pk_load_purpose_id = vll.fk_load_purpose
        WHERE vl.fk_vehicle_trip = p_trip_id
    ),
    delivered AS (
        SELECT ol.fk_cylinder, ol.pk_order_line_id AS resolved_id
        FROM public.tbl_vehicle_trip_stop vts
        JOIN public.tbl_order_line ol ON ol.fk_order = vts.fk_order
        JOIN public.tbl_stop_type st ON st.pk_stop_type_id = vts.fk_stop_type
        WHERE vts.fk_vehicle_trip = p_trip_id
          AND vts.fk_order IS NOT NULL
          AND st.stop_type IN ('CUSTOMER_DELIVERY', 'CUSTOMER_STOP')
    ),
    supplier_dropoff AS (
        SELECT stl.fk_cylinder, stl.pk_supplier_trip_line_id AS resolved_id
        FROM public.tbl_supplier_trip_line stl
        JOIN public.tbl_supplier_trip stp ON stp.pk_supplier_trip_id = stl.fk_supplier_trip
        JOIN public.tbl_vehicle_trip_stop vts ON vts.pk_stop_id = stp.fk_vehicle_trip_stop
        JOIN public.tbl_stop_type st ON st.pk_stop_type_id = vts.fk_stop_type
        WHERE vts.fk_vehicle_trip = p_trip_id
          AND st.stop_type IN ('SUPPLIER_DROPOFF', 'SUPPLIER_STOP')
    ),
    yard_return AS (
        SELECT yil.fk_cylinder, yil.pk_yard_inventory_line_id AS resolved_id
        FROM public.tbl_yard_inventory_line yil
        WHERE yil.is_active = TRUE
    )
    SELECT
        l.fk_cylinder,
        l.cylinder_serial,
        COALESCE(l.load_purpose, 'UNKNOWN') AS load_purpose_name,
        CAST(
            CASE
                WHEN d.fk_cylinder IS NOT NULL THEN 'CUSTOMER_DELIVERY'
                WHEN sd.fk_cylinder IS NOT NULL THEN 'SUPPLIER_DROPOFF'
                WHEN yr.fk_cylinder IS NOT NULL THEN 'RETURNED_TO_YARD'
                ELSE 'UNACCOUNTED'
            END
        AS VARCHAR(100)) AS accountability_bucket,
        CAST(
            CASE
                WHEN d.fk_cylinder IS NOT NULL THEN 'tbl_order_line'
                WHEN sd.fk_cylinder IS NOT NULL THEN 'tbl_supplier_trip_line'
                WHEN yr.fk_cylinder IS NOT NULL THEN 'tbl_yard_inventory_line'
                ELSE NULL
            END
        AS VARCHAR(100)) AS resolved_via_entity,
        CASE
            WHEN d.fk_cylinder IS NOT NULL THEN d.resolved_id
            WHEN sd.fk_cylinder IS NOT NULL THEN sd.resolved_id
            WHEN yr.fk_cylinder IS NOT NULL THEN yr.resolved_id
            ELSE NULL
        END AS resolved_via_id
    FROM loaded l
    LEFT JOIN delivered d ON d.fk_cylinder = l.fk_cylinder
    LEFT JOIN supplier_dropoff sd ON sd.fk_cylinder = l.fk_cylinder
    LEFT JOIN yard_return yr ON yr.fk_cylinder = l.fk_cylinder;
END;
$function$;


CREATE OR REPLACE FUNCTION public.fn_trip_load_reconciliation_seed_after_load()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    v_header_id BIGINT;
BEGIN
    IF NEW.pk_vehicle_load_id IS NULL OR NEW.fk_vehicle_trip IS NULL THEN
        RETURN NEW;
    END IF;

    v_header_id := public.fn_ensure_trip_load_reconciliation_header(
        NEW.fk_vehicle_trip,
        NEW.pk_vehicle_load_id
    );

    PERFORM public.fn_seed_trip_load_reconciliation_lines(
        v_header_id,
        NEW.fk_vehicle_trip,
        NEW.pk_vehicle_load_id
    );

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_trip_load_reconciliation_seed_after_load
ON public.tbl_vehicle_load;

CREATE TRIGGER trg_trip_load_reconciliation_seed_after_load
AFTER INSERT OR UPDATE OF total_cylinders_loaded
ON public.tbl_vehicle_load
FOR EACH ROW
EXECUTE FUNCTION public.fn_trip_load_reconciliation_seed_after_load();


CREATE OR REPLACE FUNCTION public.fn_settle_trip_load_on_supplier_drop()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    v_trip_id BIGINT;
BEGIN
    SELECT st.fk_vehicle_trip
      INTO v_trip_id
      FROM public.tbl_supplier_trip st
     WHERE st.pk_supplier_trip_id = NEW.fk_supplier_trip;

    IF v_trip_id IS NULL THEN
        SELECT vts.fk_vehicle_trip
          INTO v_trip_id
          FROM public.tbl_supplier_trip st
          JOIN public.tbl_vehicle_trip_stop vts
            ON vts.pk_stop_id = st.fk_vehicle_trip_stop
         WHERE st.pk_supplier_trip_id = NEW.fk_supplier_trip;
    END IF;

    PERFORM public.fn_resolve_trip_load_accountability(
        v_trip_id,
        NEW.fk_cylinder,
        'SUPPLIER_DROPOFF',
        'tbl_supplier_trip_line',
        NEW.pk_supplier_trip_line_id
    );

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_settle_trip_load_on_supplier_drop
ON public.tbl_supplier_trip_line;

CREATE TRIGGER trg_settle_trip_load_on_supplier_drop
AFTER INSERT
ON public.tbl_supplier_trip_line
FOR EACH ROW
EXECUTE FUNCTION public.fn_settle_trip_load_on_supplier_drop();


CREATE OR REPLACE FUNCTION public.fn_settle_trip_load_on_customer_delivery()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    v_trip_id BIGINT;
BEGIN
    SELECT vts.fk_vehicle_trip
      INTO v_trip_id
      FROM public.tbl_vehicle_trip_stop vts
     WHERE vts.fk_order = NEW.fk_order
     ORDER BY vts.pk_stop_id DESC
     LIMIT 1;

    IF v_trip_id IS NULL THEN
        RETURN NEW;
    END IF;

    PERFORM public.fn_resolve_trip_load_accountability(
        v_trip_id,
        NEW.fk_cylinder,
        'CUSTOMER_DELIVERY',
        'tbl_order_line',
        NEW.pk_order_line_id
    );

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_settle_trip_load_on_customer_delivery
ON public.tbl_order_line;

CREATE TRIGGER trg_settle_trip_load_on_customer_delivery
AFTER INSERT
ON public.tbl_order_line
FOR EACH ROW
EXECUTE FUNCTION public.fn_settle_trip_load_on_customer_delivery();


CREATE OR REPLACE FUNCTION public.fn_settle_trip_load_on_yard_inventory_return()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    v_trip_id BIGINT;
BEGIN
    IF NEW.is_active IS DISTINCT FROM TRUE THEN
        RETURN NEW;
    END IF;

    SELECT h.fk_vehicle_trip
      INTO v_trip_id
      FROM public.tbl_reconciliation_header h
      JOIN public.tbl_reconciliation_checkpoint l
        ON l.fk_header = h.pk_header_id
     WHERE h.header_type = 'TRIP_LOAD'
       AND h.header_status IN ('OPEN', 'VARIANCE')
       AND l.fk_cylinder = NEW.fk_cylinder
       AND l.line_status IN ('PENDING', 'LOADED', 'VARIANCE', 'UNACCOUNTED')
     ORDER BY h.opened_at DESC
     LIMIT 1;

    IF v_trip_id IS NULL THEN
        RETURN NEW;
    END IF;

    PERFORM public.fn_resolve_trip_load_accountability(
        v_trip_id,
        NEW.fk_cylinder,
        'RETURNED_TO_YARD',
        'tbl_yard_inventory_line',
        NEW.pk_yard_inventory_line_id
    );

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_settle_trip_load_on_yard_inventory_return
ON public.tbl_yard_inventory_line;

CREATE TRIGGER trg_settle_trip_load_on_yard_inventory_return
AFTER INSERT OR UPDATE OF is_active
ON public.tbl_yard_inventory_line
FOR EACH ROW
EXECUTE FUNCTION public.fn_settle_trip_load_on_yard_inventory_return();


DO $$
DECLARE
    rec RECORD;
    line_rec RECORD;
BEGIN
    FOR rec IN
        SELECT h.pk_header_id, h.fk_vehicle_trip, h.fk_vehicle_load
          FROM public.tbl_reconciliation_header h
         WHERE h.header_type = 'TRIP_LOAD'
    LOOP
        PERFORM public.fn_seed_trip_load_reconciliation_lines(
            rec.pk_header_id,
            rec.fk_vehicle_trip,
            rec.fk_vehicle_load
        );

        FOR line_rec IN
            SELECT *
              FROM public.fn_trip_load_accountability(rec.fk_vehicle_trip)
        LOOP
            IF line_rec.accountability_bucket <> 'UNACCOUNTED' THEN
                PERFORM public.fn_resolve_trip_load_accountability(
                    rec.fk_vehicle_trip,
                    line_rec.fk_cylinder,
                    line_rec.accountability_bucket,
                    line_rec.resolved_via_entity,
                    line_rec.resolved_via_id
                );
            END IF;
        END LOOP;

        PERFORM public.fn_recompute_reconciliation_header_status(rec.pk_header_id);
    END LOOP;
END $$;
