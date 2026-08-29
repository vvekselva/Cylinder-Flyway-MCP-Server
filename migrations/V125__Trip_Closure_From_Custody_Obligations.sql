-- =====================================================================
-- V125__Trip_Closure_From_Custody_Obligations.sql
-- =====================================================================
--
-- Purpose:
--   Add trip closure tracking based on per-cylinder obligations.
--
-- Business Rule:
--   Trip accounting and trip closure are different.
--
--   Trip Accounting:
--     UNACCOUNTED / ACCOUNTED / VARIANCE
--     Based on load/challan/serial tally.
--
--   Trip Closure:
--     OPEN / CLOSED / AGING / ESCALATED
--     Based on obligations created by the trip.
--
--   A trip is closure-CLOSED only when all obligations created by that trip
--   are CLOSED in tbl_cylinder_party_custody.
--
-- Architecture:
--   tbl_cylinder_party_custody is the authoritative per-cylinder obligation table.
--   ACTIVE custody = OPEN obligation.
--   CLOSED custody = CLOSED obligation.
--
-- =====================================================================


-- =====================================================================
-- 1. Add closure fields to reconciliation header
-- =====================================================================

ALTER TABLE public.tbl_reconciliation_header
ADD COLUMN IF NOT EXISTS closure_status VARCHAR(30);

ALTER TABLE public.tbl_reconciliation_header
ADD COLUMN IF NOT EXISTS closure_due_at TIMESTAMP;

ALTER TABLE public.tbl_reconciliation_header
ADD COLUMN IF NOT EXISTS closure_closed_at TIMESTAMP;

ALTER TABLE public.tbl_reconciliation_header
ADD COLUMN IF NOT EXISTS closure_escalated_at TIMESTAMP;

ALTER TABLE public.tbl_reconciliation_header
ADD COLUMN IF NOT EXISTS closure_remarks VARCHAR(1000);


-- =====================================================================
-- 2. Closure status constraint
-- =====================================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM pg_constraint
         WHERE conname = 'tbl_reconciliation_header_closure_status_chk'
    ) THEN
        ALTER TABLE public.tbl_reconciliation_header
        ADD CONSTRAINT tbl_reconciliation_header_closure_status_chk
        CHECK (
            closure_status IS NULL
            OR closure_status IN ('OPEN', 'CLOSED', 'AGING', 'ESCALATED')
        );
    END IF;
END $$;


-- =====================================================================
-- 3. Indexes
-- =====================================================================

CREATE INDEX IF NOT EXISTS idx_recon_header_trip_closure
ON public.tbl_reconciliation_header(fk_vehicle_trip, closure_status)
WHERE fk_vehicle_trip IS NOT NULL
  AND closure_status IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_recon_header_closure_due
ON public.tbl_reconciliation_header(closure_due_at)
WHERE closure_status IN ('OPEN', 'AGING')
  AND closure_due_at IS NOT NULL;


-- =====================================================================
-- 4. Helper: ensure trip closure fields exist on TRIP_LOAD header
-- =====================================================================

CREATE OR REPLACE FUNCTION public.fn_ensure_trip_closure_header(
    p_trip_id BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $function$
DECLARE
    v_header_id BIGINT;
BEGIN
    IF p_trip_id IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT pk_header_id
      INTO v_header_id
      FROM public.tbl_reconciliation_header
     WHERE fk_vehicle_trip = p_trip_id
       AND header_type = 'TRIP_LOAD'
     ORDER BY pk_header_id DESC
     LIMIT 1;

    IF v_header_id IS NULL THEN
        RETURN NULL;
    END IF;

    UPDATE public.tbl_reconciliation_header
       SET closure_status = COALESCE(closure_status, 'OPEN'),
           closure_due_at = COALESCE(closure_due_at, opened_at + interval '30 days'),
           closure_remarks = COALESCE(
                closure_remarks,
                'Trip closure is based on obligations in tbl_cylinder_party_custody.'
           ),
           updated_at = now()
     WHERE pk_header_id = v_header_id;

    RETURN v_header_id;
END;
$function$;


-- =====================================================================
-- 5. Recompute trip closure from custody obligations
-- =====================================================================

CREATE OR REPLACE FUNCTION public.fn_recompute_trip_closure_from_custody(
    p_trip_id BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
AS $function$
DECLARE
    v_header_id BIGINT;

    v_total_obligations INTEGER := 0;
    v_open_obligations INTEGER := 0;
    v_closed_obligations INTEGER := 0;
    v_aging_obligations INTEGER := 0;

    v_old_status VARCHAR(30);
    v_new_status VARCHAR(30);
    v_due_at TIMESTAMP;
    v_message VARCHAR(1000);
BEGIN
    IF p_trip_id IS NULL THEN
        RETURN;
    END IF;

    v_header_id := public.fn_ensure_trip_closure_header(p_trip_id);

    IF v_header_id IS NULL THEN
        RETURN;
    END IF;

    SELECT closure_status, closure_due_at
      INTO v_old_status, v_due_at
      FROM public.tbl_reconciliation_header
     WHERE pk_header_id = v_header_id;

    SELECT
        COUNT(*),
        COUNT(*) FILTER (WHERE custody_status = 'ACTIVE'),
        COUNT(*) FILTER (WHERE custody_status = 'CLOSED'),
        COUNT(*) FILTER (
            WHERE custody_status = 'ACTIVE'
              AND aging_due_at IS NOT NULL
              AND now() > aging_due_at
        )
      INTO
        v_total_obligations,
        v_open_obligations,
        v_closed_obligations,
        v_aging_obligations
      FROM public.tbl_cylinder_party_custody
     WHERE fk_entry_trip = p_trip_id;

    IF v_total_obligations = 0 THEN
        v_new_status := 'CLOSED';
        v_message := 'No party custody obligations were created by this trip.';
    ELSIF v_open_obligations = 0 THEN
        v_new_status := 'CLOSED';
        v_message := 'All party custody obligations created by this trip are closed.';
    ELSIF v_aging_obligations > 0 THEN
        v_new_status := 'AGING';
        v_message := 'One or more obligations created by this trip are aging.';
    ELSIF v_due_at IS NOT NULL AND now() > v_due_at THEN
        v_new_status := 'AGING';
        v_message := 'Trip closure exceeded 30-day closure SLA.';
    ELSE
        v_new_status := 'OPEN';
        v_message := 'Trip has open party custody obligations.';
    END IF;

    UPDATE public.tbl_reconciliation_header
       SET closure_status = v_new_status,
           closure_closed_at = CASE
                WHEN v_new_status = 'CLOSED'
                THEN COALESCE(closure_closed_at, now())
                ELSE NULL
           END,
           closure_escalated_at = CASE
                WHEN v_new_status = 'ESCALATED'
                THEN COALESCE(closure_escalated_at, now())
                ELSE closure_escalated_at
           END,
           closure_remarks = v_message
                || ' Total=' || COALESCE(v_total_obligations, 0)
                || ', Open=' || COALESCE(v_open_obligations, 0)
                || ', Closed=' || COALESCE(v_closed_obligations, 0)
                || '.',
           updated_at = now()
     WHERE pk_header_id = v_header_id;

    IF COALESCE(v_old_status, '') IS DISTINCT FROM COALESCE(v_new_status, '') THEN

        IF EXISTS (
            SELECT 1
              FROM pg_proc
             WHERE proname = 'fn_log_reconciliation_status_change'
        ) THEN
            PERFORM public.fn_log_reconciliation_status_change(
                'HEADER',
                v_header_id,
                v_header_id,
                NULL,
                NULL,
                p_trip_id,
                NULL,
                v_old_status,
                v_new_status,
                'TRIP_CLOSURE_STATUS_CHANGE',
                'tbl_cylinder_party_custody',
                p_trip_id,
                v_message,
                'SYSTEM'
            );
        END IF;

        IF EXISTS (
            SELECT 1
              FROM pg_proc
             WHERE proname = 'fn_log_reconciliation_event'
        ) THEN
            PERFORM public.fn_log_reconciliation_event(
                v_header_id,
                NULL,
                NULL,
                p_trip_id,
                NULL,
                'TRIP_CLOSURE_STATUS_CHANGE',
                v_old_status,
                v_new_status,
                NULL,
                NULL,
                NULL,
                NULL,
                'tbl_cylinder_party_custody',
                p_trip_id,
                v_message,
                'SYSTEM'
            );
        END IF;
    END IF;
END;
$function$;


-- =====================================================================
-- 6. Trigger: custody insert/update recomputes creating trip closure
-- =====================================================================

CREATE OR REPLACE FUNCTION public.fn_recompute_trip_closure_on_custody_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.fk_entry_trip IS NOT NULL THEN
            PERFORM public.fn_recompute_trip_closure_from_custody(NEW.fk_entry_trip);
        END IF;

        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF NEW.fk_entry_trip IS NOT NULL THEN
            PERFORM public.fn_recompute_trip_closure_from_custody(NEW.fk_entry_trip);
        END IF;

        IF OLD.fk_entry_trip IS NOT NULL
           AND OLD.fk_entry_trip IS DISTINCT FROM NEW.fk_entry_trip THEN
            PERFORM public.fn_recompute_trip_closure_from_custody(OLD.fk_entry_trip);
        END IF;

        RETURN NEW;
    END IF;

    RETURN NEW;
END;
$function$;


DROP TRIGGER IF EXISTS trg_recompute_trip_closure_on_custody_change
ON public.tbl_cylinder_party_custody;

CREATE TRIGGER trg_recompute_trip_closure_on_custody_change
AFTER INSERT OR UPDATE OF
    custody_status,
    fk_entry_trip,
    aging_due_at,
    escalated_at,
    exited_at
ON public.tbl_cylinder_party_custody
FOR EACH ROW
EXECUTE FUNCTION public.fn_recompute_trip_closure_on_custody_change();


-- =====================================================================
-- 7. Aging refresh helper for trip closure
-- =====================================================================

CREATE OR REPLACE FUNCTION public.fn_refresh_trip_closure_aging()
RETURNS INTEGER
LANGUAGE plpgsql
AS $function$
DECLARE
    v_count INTEGER := 0;
    v_trip RECORD;
BEGIN
    FOR v_trip IN
        SELECT DISTINCT fk_entry_trip AS trip_id
          FROM public.tbl_cylinder_party_custody
         WHERE fk_entry_trip IS NOT NULL
    LOOP
        PERFORM public.fn_recompute_trip_closure_from_custody(v_trip.trip_id);
        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$function$;


-- =====================================================================
-- 8. Backfill existing TRIP_LOAD headers
-- =====================================================================

UPDATE public.tbl_reconciliation_header
   SET closure_status = COALESCE(closure_status, 'OPEN'),
       closure_due_at = COALESCE(closure_due_at, opened_at + interval '30 days'),
       closure_remarks = COALESCE(
            closure_remarks,
            'Trip closure is based on obligations in tbl_cylinder_party_custody.'
       ),
       updated_at = now()
 WHERE header_type = 'TRIP_LOAD'
   AND fk_vehicle_trip IS NOT NULL;


DO $$
DECLARE
    v_trip RECORD;
BEGIN
    FOR v_trip IN
        SELECT DISTINCT fk_vehicle_trip AS trip_id
          FROM public.tbl_reconciliation_header
         WHERE header_type = 'TRIP_LOAD'
           AND fk_vehicle_trip IS NOT NULL
    LOOP
        PERFORM public.fn_recompute_trip_closure_from_custody(v_trip.trip_id);
    END LOOP;
END $$;


-- =====================================================================
-- 9. Documentation
-- =====================================================================

COMMENT ON COLUMN public.tbl_reconciliation_header.closure_status IS
'Trip lifecycle closure status. OPEN/CLOSED/AGING/ESCALATED. Separate from accounting header_status.';

COMMENT ON COLUMN public.tbl_reconciliation_header.closure_due_at IS
'Trip closure due date. Default is TRIP_LOAD opened_at + 30 days.';

COMMENT ON COLUMN public.tbl_reconciliation_header.closure_closed_at IS
'Timestamp when all party custody obligations created by this trip became CLOSED.';

COMMENT ON COLUMN public.tbl_reconciliation_header.closure_escalated_at IS
'Timestamp when trip closure aging was escalated.';

COMMENT ON COLUMN public.tbl_reconciliation_header.closure_remarks IS
'Summary of trip closure calculation from tbl_cylinder_party_custody obligations.';

COMMENT ON FUNCTION public.fn_recompute_trip_closure_from_custody(BIGINT) IS
'Recomputes trip closure_status on TRIP_LOAD reconciliation header from tbl_cylinder_party_custody obligations created by the trip.';

COMMENT ON FUNCTION public.fn_refresh_trip_closure_aging() IS
'Recomputes closure aging for all trips that created party custody obligations. Intended for scheduler/manual execution.';


DO $$
BEGIN
    RAISE NOTICE 'V125 OK: Trip closure fields added to reconciliation header.';
    RAISE NOTICE 'V125 OK: Trip closure recomputes from tbl_cylinder_party_custody obligations.';
    RAISE NOTICE 'V125 OK: Trip accounting header_status remains separate from closure_status.';
END $$;
