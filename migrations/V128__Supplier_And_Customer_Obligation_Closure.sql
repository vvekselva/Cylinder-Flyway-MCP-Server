-- =====================================================================
-- V128__Supplier_And_Customer_Obligation_Closure.sql
-- =====================================================================
--
-- Purpose:
--   Close per-cylinder customer/supplier obligations when the cylinder
--   returns to controlled ownership through a future pickup/collection event.
--
-- Customer obligation:
--   Created by: ORDER_DELIVERY
--   Closed by : EMPTY_PICKUP
--
-- Supplier obligation:
--   Created by: SUPPLIER_DROPOFF
--   Closed by : REFILL_COLLECTION
-- =====================================================================



CREATE OR REPLACE FUNCTION public.fn_close_customer_obligation_from_empty_pickup_line()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
DECLARE
    v_pickup_id BIGINT;
    v_cylinder_id BIGINT;
    v_trip_id BIGINT;
    v_load_id BIGINT;
    v_stop_id BIGINT;
    v_custody_id BIGINT;
BEGIN
    v_pickup_id := public.fn_try_read_bigint_column(
        'tbl_empty_pickup_line',
        'pk_empty_pickup_line_id',
        NEW.pk_empty_pickup_line_id,
        'fk_empty_pickup'
    );

    v_cylinder_id := public.fn_try_read_bigint_column(
        'tbl_empty_pickup_line',
        'pk_empty_pickup_line_id',
        NEW.pk_empty_pickup_line_id,
        'fk_cylinder'
    );

    IF v_pickup_id IS NULL OR v_cylinder_id IS NULL THEN
        RETURN NEW;
    END IF;

    v_trip_id := public.fn_try_read_bigint_column(
        'tbl_empty_pickup',
        'pk_empty_pickup_id',
        v_pickup_id,
        'fk_vehicle_trip'
    );

    v_load_id := COALESCE(
        public.fn_try_read_bigint_column(
            'tbl_empty_pickup',
            'pk_empty_pickup_id',
            v_pickup_id,
            'fk_vehicle_load'
        ),
        public.fn_cpc_latest_load_for_trip(v_trip_id)
    );

    v_stop_id := public.fn_cpc_find_stop(
        v_trip_id,
        NULL,
        NULL,
        v_pickup_id
    );

    SELECT pk_custody_id
      INTO v_custody_id
      FROM public.tbl_cylinder_party_custody
     WHERE fk_cylinder = v_cylinder_id
       AND party_type = 'CUSTOMER'
       AND custody_status = 'ACTIVE'
     ORDER BY entered_at ASC, pk_custody_id ASC
     LIMIT 1;

    IF v_custody_id IS NULL THEN
        RAISE NOTICE
            '[CUSTOMER_OBLIGATION_CLOSE] No ACTIVE CUSTOMER custody found for cylinder %, empty pickup line %.',
            v_cylinder_id, NEW.pk_empty_pickup_line_id;
        RETURN NEW;
    END IF;

    UPDATE public.tbl_cylinder_party_custody
       SET custody_status = 'CLOSED',
           exit_event_type = 'EMPTY_PICKUP',
           fk_exit_empty_pickup = v_pickup_id,
           fk_exit_trip = COALESCE(fk_exit_trip, v_trip_id),
           fk_exit_load = COALESCE(fk_exit_load, v_load_id),
           fk_exit_stop = COALESCE(fk_exit_stop, v_stop_id),
           exited_at = COALESCE(exited_at, now()),
           remarks = COALESCE(remarks, '')
               || ' Closed by EMPTY_PICKUP line #'
               || NEW.pk_empty_pickup_line_id
               || '.'
     WHERE pk_custody_id = v_custody_id
       AND custody_status = 'ACTIVE';

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_close_customer_obligation_from_empty_pickup_line
ON public.tbl_empty_pickup_line;

CREATE TRIGGER trg_close_customer_obligation_from_empty_pickup_line
AFTER INSERT
ON public.tbl_empty_pickup_line
FOR EACH ROW
EXECUTE FUNCTION public.fn_close_customer_obligation_from_empty_pickup_line();



CREATE OR REPLACE FUNCTION public.fn_close_supplier_obligation_from_refill_collection_line()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
DECLARE
    v_collection_id BIGINT;
    v_cylinder_id BIGINT;
    v_trip_id BIGINT;
    v_load_id BIGINT;
    v_stop_id BIGINT;
    v_custody_id BIGINT;
BEGIN
    v_collection_id := public.fn_try_read_bigint_column(
        'tbl_supplier_refill_collection_line',
        'pk_supplier_refill_collection_line_id',
        NEW.pk_supplier_refill_collection_line_id,
        'fk_supplier_refill_collection'
    );

    v_cylinder_id := public.fn_try_read_bigint_column(
        'tbl_supplier_refill_collection_line',
        'pk_supplier_refill_collection_line_id',
        NEW.pk_supplier_refill_collection_line_id,
        'fk_cylinder'
    );

    IF v_collection_id IS NULL OR v_cylinder_id IS NULL THEN
        RETURN NEW;
    END IF;

    v_trip_id := public.fn_try_read_bigint_column(
        'tbl_supplier_refill_collection',
        'pk_supplier_refill_collection_id',
        v_collection_id,
        'fk_vehicle_trip'
    );

    v_load_id := COALESCE(
        public.fn_try_read_bigint_column(
            'tbl_supplier_refill_collection',
            'pk_supplier_refill_collection_id',
            v_collection_id,
            'fk_vehicle_load'
        ),
        public.fn_cpc_latest_load_for_trip(v_trip_id)
    );

    v_stop_id := public.fn_try_read_bigint_column(
        'tbl_supplier_refill_collection',
        'pk_supplier_refill_collection_id',
        v_collection_id,
        'fk_vehicle_trip_stop'
    );

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
            v_cylinder_id, NEW.pk_supplier_refill_collection_line_id;
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
               || NEW.pk_supplier_refill_collection_line_id
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



-- Backfill already closed customer custody rows.
UPDATE public.tbl_cylinder_party_custody cpc
   SET fk_exit_trip = COALESCE(
            cpc.fk_exit_trip,
            public.fn_try_read_bigint_column(
                'tbl_empty_pickup',
                'pk_empty_pickup_id',
                cpc.fk_exit_empty_pickup,
                'fk_vehicle_trip'
            )
       ),
       fk_exit_load = COALESCE(
            cpc.fk_exit_load,
            public.fn_try_read_bigint_column(
                'tbl_empty_pickup',
                'pk_empty_pickup_id',
                cpc.fk_exit_empty_pickup,
                'fk_vehicle_load'
            ),
            public.fn_cpc_latest_load_for_trip(
                public.fn_try_read_bigint_column(
                    'tbl_empty_pickup',
                    'pk_empty_pickup_id',
                    cpc.fk_exit_empty_pickup,
                    'fk_vehicle_trip'
                )
            )
       ),
       fk_exit_stop = COALESCE(
            cpc.fk_exit_stop,
            public.fn_cpc_find_stop(
                public.fn_try_read_bigint_column(
                    'tbl_empty_pickup',
                    'pk_empty_pickup_id',
                    cpc.fk_exit_empty_pickup,
                    'fk_vehicle_trip'
                ),
                NULL,
                NULL,
                cpc.fk_exit_empty_pickup
            )
       )
 WHERE cpc.party_type = 'CUSTOMER'
   AND cpc.custody_status = 'CLOSED'
   AND cpc.fk_exit_empty_pickup IS NOT NULL;


-- Backfill already closed supplier custody rows.
UPDATE public.tbl_cylinder_party_custody cpc
   SET fk_exit_trip = COALESCE(
            cpc.fk_exit_trip,
            public.fn_try_read_bigint_column(
                'tbl_supplier_refill_collection',
                'pk_supplier_refill_collection_id',
                cpc.fk_exit_supplier_refill_collection,
                'fk_vehicle_trip'
            )
       ),
       fk_exit_load = COALESCE(
            cpc.fk_exit_load,
            public.fn_try_read_bigint_column(
                'tbl_supplier_refill_collection',
                'pk_supplier_refill_collection_id',
                cpc.fk_exit_supplier_refill_collection,
                'fk_vehicle_load'
            ),
            public.fn_cpc_latest_load_for_trip(
                public.fn_try_read_bigint_column(
                    'tbl_supplier_refill_collection',
                    'pk_supplier_refill_collection_id',
                    cpc.fk_exit_supplier_refill_collection,
                    'fk_vehicle_trip'
                )
            )
       ),
       fk_exit_stop = COALESCE(
            cpc.fk_exit_stop,
            public.fn_try_read_bigint_column(
                'tbl_supplier_refill_collection',
                'pk_supplier_refill_collection_id',
                cpc.fk_exit_supplier_refill_collection,
                'fk_vehicle_trip_stop'
            ),
            public.fn_cpc_find_stop(
                public.fn_try_read_bigint_column(
                    'tbl_supplier_refill_collection',
                    'pk_supplier_refill_collection_id',
                    cpc.fk_exit_supplier_refill_collection,
                    'fk_vehicle_trip'
                ),
                NULL,
                NULL,
                NULL
            )
       )
 WHERE cpc.party_type = 'SUPPLIER'
   AND cpc.custody_status = 'CLOSED'
   AND cpc.fk_exit_supplier_refill_collection IS NOT NULL;



-- Recompute closure for affected trips after backfill.
DO $$
DECLARE
    v_trip RECORD;
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_proc WHERE proname = 'fn_recompute_trip_closure_from_custody'
    ) THEN
        FOR v_trip IN
            SELECT DISTINCT fk_entry_trip AS trip_id
              FROM public.tbl_cylinder_party_custody
             WHERE fk_entry_trip IS NOT NULL
        LOOP
            PERFORM public.fn_recompute_trip_closure_from_custody(v_trip.trip_id);
        END LOOP;
    END IF;
END $$;


COMMENT ON FUNCTION public.fn_close_customer_obligation_from_empty_pickup_line() IS
'Closes ACTIVE CUSTOMER custody/obligation when an empty pickup line is inserted. Populates exit trip/load/stop.';

COMMENT ON FUNCTION public.fn_close_supplier_obligation_from_refill_collection_line() IS
'Closes ACTIVE SUPPLIER custody/obligation when a supplier refill collection line is inserted. Populates exit trip/load/stop.';


DO $$
BEGIN
    RAISE NOTICE 'V128 OK: Customer obligation closure trigger installed.';
    RAISE NOTICE 'V128 OK: Supplier obligation closure trigger installed.';
    RAISE NOTICE 'V128 OK: Existing closed custody rows backfilled where source links were available.';
END $$;
