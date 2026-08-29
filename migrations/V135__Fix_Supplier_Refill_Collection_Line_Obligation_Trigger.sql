-- V136__Fix_Supplier_Refill_Collection_Line_Obligation_Trigger.sql
-- Purpose:
--   Fix runtime failure in fn_close_supplier_obligation_from_refill_collection_line().
--
-- Problem:
--   The previous trigger function refers to OLD/NEW fields that do not exist on
--   tbl_supplier_refill_collection_line:
--       NEW.pk_supplier_refill_collection_line_id
--
--   Actual table columns are:
--       pk_collection_line_id
--       fk_collection
--       fk_cylinder
--       fk_product
--       fk_supplier_trip_line
--
-- Symptom:
--   ERROR: record "new" has no field "pk_supplier_refill_collection_line_id"
--
-- Fix:
--   Recreate the trigger function using the real column names.

CREATE OR REPLACE FUNCTION public.fn_close_supplier_obligation_from_refill_collection_line()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
DECLARE
    v_collection_id BIGINT;
    v_collection_line_id BIGINT;
    v_cylinder_id BIGINT;
    v_trip_id BIGINT;
    v_load_id BIGINT;
    v_stop_id BIGINT;
    v_custody_id BIGINT;
BEGIN
    -- tbl_supplier_refill_collection_line primary key is pk_collection_line_id,
    -- not pk_supplier_refill_collection_line_id.
    v_collection_line_id := NEW.pk_collection_line_id;
    v_collection_id := NEW.fk_collection;
    v_cylinder_id := NEW.fk_cylinder;

    IF v_collection_id IS NULL OR v_cylinder_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT src.fk_vehicle_trip,
           src.fk_vehicle_load,
           src.fk_vehicle_trip_stop
      INTO v_trip_id,
           v_load_id,
           v_stop_id
      FROM public.tbl_supplier_refill_collection src
     WHERE src.pk_collection_id = v_collection_id;

    IF v_trip_id IS NULL THEN
        RAISE NOTICE
            '[SUPPLIER_OBLIGATION_CLOSE] Collection % not found or trip missing for collection line %, cylinder %.',
            v_collection_id, v_collection_line_id, v_cylinder_id;
        RETURN NEW;
    END IF;

    v_load_id := COALESCE(v_load_id, public.fn_cpc_latest_load_for_trip(v_trip_id));

    IF v_stop_id IS NULL THEN
        v_stop_id := public.fn_cpc_find_stop(v_trip_id, NULL, NULL, NULL);
    END IF;

    SELECT pk_custody_id
      INTO v_custody_id
      FROM public.tbl_cylinder_party_custody
     WHERE fk_cylinder = v_cylinder_id
       AND party_type = 'SUPPLIER'
       AND custody_status = 'ACTIVE'
     ORDER BY entered_at ASC, pk_custody_id ASC
     LIMIT 1;

    IF v_custody_id IS NULL THEN
        RAISE NOTICE
            '[SUPPLIER_OBLIGATION_CLOSE] No ACTIVE SUPPLIER custody found for cylinder %, refill collection line %.',
            v_cylinder_id, v_collection_line_id;
        RETURN NEW;
    END IF;

    UPDATE public.tbl_cylinder_party_custody
       SET custody_status = 'CLOSED',
           exit_event_type = 'REFILL_COLLECTION',
           fk_exit_supplier_refill_collection = v_collection_id,
           fk_exit_trip = COALESCE(fk_exit_trip, v_trip_id),
           fk_exit_load = COALESCE(fk_exit_load, v_load_id),
           fk_exit_stop = COALESCE(fk_exit_stop, v_stop_id),
           exited_at = COALESCE(exited_at, now()),
           remarks = COALESCE(remarks, '')
               || ' Closed by REFILL_COLLECTION line #'
               || v_collection_line_id
               || '.'
     WHERE pk_custody_id = v_custody_id
       AND custody_status = 'ACTIVE';

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_close_supplier_obligation_from_refill_collection_line
ON public.tbl_supplier_refill_collection_line;

CREATE TRIGGER trg_close_supplier_obligation_from_refill_collection_line
AFTER INSERT
ON public.tbl_supplier_refill_collection_line
FOR EACH ROW
EXECUTE FUNCTION public.fn_close_supplier_obligation_from_refill_collection_line();

COMMENT ON FUNCTION public.fn_close_supplier_obligation_from_refill_collection_line() IS
'Closes ACTIVE SUPPLIER custody when a supplier refill collection line is inserted. Fixed to use actual tbl_supplier_refill_collection_line columns: pk_collection_line_id, fk_collection, fk_cylinder.';
