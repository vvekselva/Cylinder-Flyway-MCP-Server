-- ============================================================================
-- V138__Fix_Empty_Pickup_Primary_Key_References.sql
--
-- tbl_empty_pickup uses pk_pickup_id as its primary key. Earlier challan and
-- custody functions incorrectly referenced pk_empty_pickup_id, causing inserts
-- into tbl_empty_pickup to fail when AFTER INSERT triggers were executed.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_mark_challan_partial_from_empty_pickup()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
DECLARE
    v_trip_id BIGINT;
    v_load_id BIGINT;
BEGIN
    v_trip_id := public.fn_try_read_bigint_column(
        'tbl_empty_pickup',
        'pk_pickup_id',
        NEW.pk_pickup_id,
        'fk_vehicle_trip'
    );

    v_load_id := public.fn_try_read_bigint_column(
        'tbl_empty_pickup',
        'pk_pickup_id',
        NEW.pk_pickup_id,
        'fk_vehicle_load'
    );

    PERFORM public.fn_mark_trip_challan_entry_partial(
        v_trip_id,
        v_load_id,
        'tbl_empty_pickup',
        NEW.pk_pickup_id
    );

    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.fn_populate_party_custody_traceability()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
DECLARE
    v_entry_trip BIGINT;
    v_entry_load BIGINT;
    v_entry_stop BIGINT;

    v_exit_trip BIGINT;
    v_exit_load BIGINT;
    v_exit_stop BIGINT;

    v_supplier_stop BIGINT;
BEGIN
    -- Supplier drop entry: fk_entry_supplier_trip
    IF NEW.fk_entry_supplier_trip IS NOT NULL THEN

        v_entry_trip := public.fn_try_read_bigint_column(
            'tbl_supplier_trip',
            'pk_supplier_trip_id',
            NEW.fk_entry_supplier_trip,
            'fk_vehicle_trip'
        );

        v_supplier_stop := public.fn_try_read_bigint_column(
            'tbl_supplier_trip',
            'pk_supplier_trip_id',
            NEW.fk_entry_supplier_trip,
            'fk_vehicle_trip_stop'
        );

        IF v_entry_trip IS NULL AND v_supplier_stop IS NOT NULL THEN
            SELECT fk_vehicle_trip
              INTO v_entry_trip
              FROM public.tbl_vehicle_trip_stop
             WHERE pk_stop_id = v_supplier_stop;
        END IF;

        v_entry_load := COALESCE(
            public.fn_try_read_bigint_column(
                'tbl_supplier_trip',
                'pk_supplier_trip_id',
                NEW.fk_entry_supplier_trip,
                'fk_vehicle_load'
            ),
            public.fn_cpc_latest_load_for_trip(v_entry_trip)
        );

        v_entry_stop := COALESCE(
            v_supplier_stop,
            public.fn_cpc_find_stop(
                v_entry_trip,
                NULL,
                NEW.fk_entry_supplier_trip,
                NULL
            )
        );

        NEW.fk_entry_trip := COALESCE(NEW.fk_entry_trip, v_entry_trip);
        NEW.fk_entry_load := COALESCE(NEW.fk_entry_load, v_entry_load);
        NEW.fk_entry_stop := COALESCE(NEW.fk_entry_stop, v_entry_stop);
    END IF;


    -- Customer delivery entry: fk_entry_order
    IF NEW.fk_entry_order IS NOT NULL THEN

        v_entry_trip := public.fn_try_read_bigint_column(
            'tbl_order',
            'pk_order_id',
            NEW.fk_entry_order,
            'fk_vehicle_trip'
        );

        v_entry_load := COALESCE(
            public.fn_try_read_bigint_column(
                'tbl_order',
                'pk_order_id',
                NEW.fk_entry_order,
                'fk_vehicle_load'
            ),
            public.fn_cpc_latest_load_for_trip(v_entry_trip)
        );

        v_entry_stop := public.fn_cpc_find_stop(
            v_entry_trip,
            NEW.fk_entry_order,
            NULL,
            NULL
        );

        NEW.fk_entry_trip := COALESCE(NEW.fk_entry_trip, v_entry_trip);
        NEW.fk_entry_load := COALESCE(NEW.fk_entry_load, v_entry_load);
        NEW.fk_entry_stop := COALESCE(NEW.fk_entry_stop, v_entry_stop);
    END IF;


    -- Customer empty pickup exit: fk_exit_empty_pickup
    IF NEW.fk_exit_empty_pickup IS NOT NULL THEN

        v_exit_trip := public.fn_try_read_bigint_column(
            'tbl_empty_pickup',
            'pk_pickup_id',
            NEW.fk_exit_empty_pickup,
            'fk_vehicle_trip'
        );

        v_exit_load := COALESCE(
            public.fn_try_read_bigint_column(
                'tbl_empty_pickup',
                'pk_pickup_id',
                NEW.fk_exit_empty_pickup,
                'fk_vehicle_load'
            ),
            public.fn_cpc_latest_load_for_trip(v_exit_trip)
        );

        v_exit_stop := public.fn_cpc_find_stop(
            v_exit_trip,
            NULL,
            NULL,
            NEW.fk_exit_empty_pickup
        );

        NEW.fk_exit_trip := COALESCE(NEW.fk_exit_trip, v_exit_trip);
        NEW.fk_exit_load := COALESCE(NEW.fk_exit_load, v_exit_load);
        NEW.fk_exit_stop := COALESCE(NEW.fk_exit_stop, v_exit_stop);
    END IF;


    -- Supplier full pickup / refill collection exit.
    IF NEW.fk_exit_supplier_refill_collection IS NOT NULL THEN

        v_exit_trip := public.fn_try_read_bigint_column(
            'tbl_supplier_refill_collection',
            'pk_supplier_refill_collection_id',
            NEW.fk_exit_supplier_refill_collection,
            'fk_vehicle_trip'
        );

        v_exit_load := COALESCE(
            public.fn_try_read_bigint_column(
                'tbl_supplier_refill_collection',
                'pk_supplier_refill_collection_id',
                NEW.fk_exit_supplier_refill_collection,
                'fk_vehicle_load'
            ),
            public.fn_cpc_latest_load_for_trip(v_exit_trip)
        );

        v_exit_stop := public.fn_try_read_bigint_column(
            'tbl_supplier_refill_collection',
            'pk_supplier_refill_collection_id',
            NEW.fk_exit_supplier_refill_collection,
            'fk_vehicle_trip_stop'
        );

        IF v_exit_stop IS NULL THEN
            v_exit_stop := public.fn_cpc_find_stop(
                v_exit_trip,
                NULL,
                NULL,
                NULL
            );
        END IF;

        NEW.fk_exit_trip := COALESCE(NEW.fk_exit_trip, v_exit_trip);
        NEW.fk_exit_load := COALESCE(NEW.fk_exit_load, v_exit_load);
        NEW.fk_exit_stop := COALESCE(NEW.fk_exit_stop, v_exit_stop);
    END IF;


    -- Aging due date.
    IF NEW.custody_status = 'ACTIVE'
       AND NEW.aging_due_at IS NULL THEN
        IF NEW.party_type = 'CUSTOMER' THEN
            NEW.aging_due_at := COALESCE(NEW.entered_at, now()) + interval '30 days';
        ELSIF NEW.party_type = 'SUPPLIER' THEN
            NEW.aging_due_at := COALESCE(NEW.entered_at, now()) + interval '7 days';
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

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
        'pk_pickup_id',
        v_pickup_id,
        'fk_vehicle_trip'
    );

    v_load_id := COALESCE(
        public.fn_try_read_bigint_column(
            'tbl_empty_pickup',
            'pk_pickup_id',
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


-- Repair traceability columns for customer custody rows already closed
-- through an empty pickup before this correction was installed.
UPDATE public.tbl_cylinder_party_custody cpc
   SET fk_exit_trip = COALESCE(
            cpc.fk_exit_trip,
            public.fn_try_read_bigint_column(
                'tbl_empty_pickup',
                'pk_pickup_id',
                cpc.fk_exit_empty_pickup,
                'fk_vehicle_trip'
            )
       ),
       fk_exit_load = COALESCE(
            cpc.fk_exit_load,
            public.fn_try_read_bigint_column(
                'tbl_empty_pickup',
                'pk_pickup_id',
                cpc.fk_exit_empty_pickup,
                'fk_vehicle_load'
            ),
            public.fn_cpc_latest_load_for_trip(
                public.fn_try_read_bigint_column(
                    'tbl_empty_pickup',
                    'pk_pickup_id',
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
                    'pk_pickup_id',
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
