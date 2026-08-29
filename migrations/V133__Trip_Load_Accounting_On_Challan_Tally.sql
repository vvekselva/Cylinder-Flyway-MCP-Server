-- =====================================================================
-- V133__Trip_Load_Accounting_On_Challan_Tally.sql
-- =====================================================================
-- Purpose:
--   Fix TRIP_LOAD accounting so that challan-entered, serial-resolved
--   custody movements make the trip ACCOUNTED.
--
-- Business meaning:
--   1. Vehicle load removes cylinders from yard and opens TRIP_LOAD as
--      UNACCOUNTED.
--   2. When challans are entered, each loaded cylinder becomes accounted
--      if its serial is found in one of the accepted resolution buckets:
--        - CUSTOMER_DELIVERY  : custody is now with customer
--        - SUPPLIER_DROPOFF   : custody is now with supplier/refill party
--        - RETURNED_TO_YARD   : cylinder came back to yard
--   3. Trip accounting is then ACCOUNTED when all loaded serials are
--      resolved to one of the known buckets.
--   4. Trip closure remains separate. closure_status becomes CLOSED only
--      when party custody obligations created by the trip are closed later.
-- =====================================================================


-- =====================================================================
-- 1. Resolve a loaded cylinder to an accounting-complete bucket
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

    -- Only the load that actually contains this cylinder for this trip can be
    -- resolved. This prevents challans from accidentally accounting cylinders
    -- that were not part of the trip load.
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

    -- IMPORTANT FIX:
    -- CUSTOMER_DELIVERY and SUPPLIER_DROPOFF are accounting-complete states.
    -- They are not closure-complete states. Closure is handled later by
    -- tbl_cylinder_party_custody / closure_status.
    IF p_accountability_bucket IN ('CUSTOMER_DELIVERY', 'SUPPLIER_DROPOFF', 'RETURNED_TO_YARD') THEN
        v_new_line_status := 'ACCOUNTED';
        v_new_checkpoint_status := 'ACCOUNTED';
        v_new_actual_count := 1;
        v_event_type := 'TRIP_LOAD_ACCOUNTED';
        v_event_message := 'Loaded cylinder accounting completed via '
            || p_accountability_bucket
            || '. Custody/destination is now known; trip closure remains separate.';
    ELSE
        v_new_line_status := 'PENDING';
        v_new_checkpoint_status := 'UNACCOUNTED';
        v_new_actual_count := NULL;
        v_event_type := 'TRIP_LOAD_UNACCOUNTED';
        v_event_message := 'Loaded cylinder is not yet resolved to a known accounting bucket. Current bucket: '
            || COALESCE(p_accountability_bucket, 'UNKNOWN_BUCKET')
            || '.';
    END IF;

    UPDATE public.tbl_reconciliation_checkpoint
       SET line_status = v_new_line_status,
           checkpoint_status = v_new_checkpoint_status,
           accountability_bucket = p_accountability_bucket,
           actual_count = v_new_actual_count,
           line_resolved_at = CASE WHEN v_new_line_status = 'ACCOUNTED' THEN now() ELSE NULL END,
           line_resolved_by = CASE WHEN v_new_line_status = 'ACCOUNTED' THEN 'SYSTEM' ELSE NULL END,
           resolved_at = CASE WHEN v_new_line_status = 'ACCOUNTED' THEN now() ELSE NULL END,
           remarks = CASE
                WHEN v_new_line_status = 'ACCOUNTED'
                THEN 'TRIP_LOAD line accounted by challan/serial tally. Trip closure is tracked separately.'
                ELSE 'TRIP_LOAD line is still awaiting challan/serial tally.'
           END
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

    -- Keep closure calculation separate and refreshed. This does not close the
    -- trip merely because accounting became ACCOUNTED.
    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fn_recompute_trip_closure_from_custody') THEN
        PERFORM public.fn_recompute_trip_closure_from_custody(p_trip_id);
    END IF;
END;
$function$;


COMMENT ON FUNCTION public.fn_resolve_trip_load_accountability(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT) IS
'V133: CUSTOMER_DELIVERY, SUPPLIER_DROPOFF and RETURNED_TO_YARD all complete TRIP_LOAD accounting. closure_status remains separate and depends on custody obligations.';


-- =====================================================================
-- 2. Backfill existing TRIP_LOAD headers/lines with the corrected semantics
-- =====================================================================

DO $$
DECLARE
    v_header RECORD;
    v_acc_rec RECORD;
BEGIN
    FOR v_header IN
        SELECT h.pk_header_id, h.fk_vehicle_trip, h.fk_vehicle_load
          FROM public.tbl_reconciliation_header h
         WHERE h.header_type = 'TRIP_LOAD'
           AND h.fk_vehicle_trip IS NOT NULL
    LOOP
        PERFORM public.fn_seed_trip_load_reconciliation_lines(
            v_header.pk_header_id,
            v_header.fk_vehicle_trip,
            v_header.fk_vehicle_load
        );

        FOR v_acc_rec IN
            SELECT *
              FROM public.fn_trip_load_accountability(v_header.fk_vehicle_trip)
        LOOP
            PERFORM public.fn_resolve_trip_load_accountability(
                v_header.fk_vehicle_trip,
                v_acc_rec.fk_cylinder,
                v_acc_rec.accountability_bucket,
                v_acc_rec.resolved_via_entity,
                v_acc_rec.resolved_via_id
            );
        END LOOP;

        PERFORM public.fn_recompute_reconciliation_header_status(v_header.pk_header_id);

        IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fn_recompute_trip_closure_from_custody') THEN
            PERFORM public.fn_recompute_trip_closure_from_custody(v_header.fk_vehicle_trip);
        END IF;
    END LOOP;
END $$;


DO $$
BEGIN
    RAISE NOTICE 'V133 OK: TRIP_LOAD accounting now completes on challan/serial tally for customer delivery, supplier dropoff, and yard return.';
    RAISE NOTICE 'V133 OK: Trip closure remains independent and is based on custody obligations.';
END $$;


-- =====================================================================
-- 3. Fix yard-return settlement lookup for the new accounting statuses
-- =====================================================================
-- Older trigger logic searched only OPEN/VARIANCE headers. After V127,
-- TRIP_LOAD headers are normally UNACCOUNTED/ACCOUNTED/VARIANCE, so a
-- returned cylinder could fail to settle while the header was UNACCOUNTED.

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
       AND h.header_status IN ('UNACCOUNTED', 'VARIANCE', 'OPEN')
       AND l.fk_cylinder = NEW.fk_cylinder
       AND (
            l.line_status IN ('PENDING', 'LOADED', 'VARIANCE', 'UNACCOUNTED')
            OR l.checkpoint_status IN ('PENDING', 'UNACCOUNTED', 'VARIANCE')
       )
     ORDER BY h.opened_at DESC, h.pk_header_id DESC
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

COMMENT ON FUNCTION public.fn_settle_trip_load_on_yard_inventory_return() IS
'V133: settles returned loaded cylinders even when TRIP_LOAD header_status is UNACCOUNTED.';
