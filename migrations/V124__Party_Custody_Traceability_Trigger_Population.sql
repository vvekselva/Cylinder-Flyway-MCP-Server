-- =====================================================================
-- V124__Party_Custody_Traceability_Trigger_Population.sql
-- =====================================================================
--
-- Purpose:
--   Populate traceability fields added in V122 on tbl_cylinder_party_custody:
--     fk_entry_trip, fk_entry_load, fk_entry_stop
--     fk_exit_trip,  fk_exit_load,  fk_exit_stop
--     aging_due_at
--
-- Architecture:
--   tbl_cylinder_party_custody is the authoritative per-cylinder obligation
--   table. This migration does not create a new obligation table.
--
-- Notes:
--   Existing custody triggers already create/close rows using:
--     fk_entry_order
--     fk_entry_supplier_trip
--     fk_exit_empty_pickup
--     fk_exit_supplier_refill_collection
--
--   This migration derives trip/load/stop context from those references.
-- =====================================================================


CREATE OR REPLACE FUNCTION public.fn_try_read_bigint_column(
    p_table_name TEXT,
    p_pk_column_name TEXT,
    p_pk_value BIGINT,
    p_column_name TEXT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $function$
DECLARE
    v_exists BOOLEAN;
    v_value BIGINT;
BEGIN
    IF p_table_name IS NULL
       OR p_pk_column_name IS NULL
       OR p_pk_value IS NULL
       OR p_column_name IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT EXISTS (
        SELECT 1
          FROM information_schema.columns
         WHERE table_schema = 'public'
           AND table_name = p_table_name
           AND column_name = p_column_name
    )
      INTO v_exists;

    IF NOT v_exists THEN
        RETURN NULL;
    END IF;

    EXECUTE format(
        'SELECT %I::bigint FROM public.%I WHERE %I = $1 LIMIT 1',
        p_column_name,
        p_table_name,
        p_pk_column_name
    )
    INTO v_value
    USING p_pk_value;

    RETURN v_value;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$function$;


CREATE OR REPLACE FUNCTION public.fn_cpc_latest_load_for_trip(
    p_trip_id BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $function$
DECLARE
    v_load_id BIGINT;
BEGIN
    IF p_trip_id IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT pk_vehicle_load_id
      INTO v_load_id
      FROM public.tbl_vehicle_load
     WHERE fk_vehicle_trip = p_trip_id
     ORDER BY pk_vehicle_load_id DESC
     LIMIT 1;

    RETURN v_load_id;
END;
$function$;


CREATE OR REPLACE FUNCTION public.fn_cpc_find_stop(
    p_trip_id BIGINT,
    p_order_id BIGINT,
    p_supplier_trip_id BIGINT,
    p_empty_pickup_id BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $function$
DECLARE
    v_stop_id BIGINT;
BEGIN
    IF p_trip_id IS NULL THEN
        RETURN NULL;
    END IF;

    IF p_order_id IS NOT NULL THEN
        SELECT pk_stop_id
          INTO v_stop_id
          FROM public.tbl_vehicle_trip_stop
         WHERE fk_vehicle_trip = p_trip_id
           AND fk_order = p_order_id
         ORDER BY pk_stop_id DESC
         LIMIT 1;

        IF v_stop_id IS NOT NULL THEN
            RETURN v_stop_id;
        END IF;
    END IF;

    IF p_supplier_trip_id IS NOT NULL THEN
        SELECT public.fn_try_read_bigint_column(
                   'tbl_supplier_trip',
                   'pk_supplier_trip_id',
                   p_supplier_trip_id,
                   'fk_vehicle_trip_stop'
               )
          INTO v_stop_id;

        IF v_stop_id IS NOT NULL THEN
            RETURN v_stop_id;
        END IF;
    END IF;

    IF p_empty_pickup_id IS NOT NULL THEN
        IF EXISTS (
            SELECT 1
              FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name = 'tbl_vehicle_trip_stop'
               AND column_name = 'fk_empty_pickup'
        ) THEN
            EXECUTE
                'SELECT pk_stop_id
                   FROM public.tbl_vehicle_trip_stop
                  WHERE fk_vehicle_trip = $1
                    AND fk_empty_pickup = $2
                  ORDER BY pk_stop_id DESC
                  LIMIT 1'
            INTO v_stop_id
            USING p_trip_id, p_empty_pickup_id;

            IF v_stop_id IS NOT NULL THEN
                RETURN v_stop_id;
            END IF;
        END IF;
    END IF;

    SELECT pk_stop_id
      INTO v_stop_id
      FROM public.tbl_vehicle_trip_stop
     WHERE fk_vehicle_trip = p_trip_id
     ORDER BY pk_stop_id DESC
     LIMIT 1;

    RETURN v_stop_id;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
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
            'pk_empty_pickup_id',
            NEW.fk_exit_empty_pickup,
            'fk_vehicle_trip'
        );

        v_exit_load := COALESCE(
            public.fn_try_read_bigint_column(
                'tbl_empty_pickup',
                'pk_empty_pickup_id',
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


DROP TRIGGER IF EXISTS trg_populate_party_custody_traceability
ON public.tbl_cylinder_party_custody;

CREATE TRIGGER trg_populate_party_custody_traceability
BEFORE INSERT OR UPDATE OF
    fk_entry_order,
    fk_entry_supplier_trip,
    fk_exit_empty_pickup,
    fk_exit_supplier_refill_collection,
    custody_status,
    entered_at,
    exited_at
ON public.tbl_cylinder_party_custody
FOR EACH ROW
EXECUTE FUNCTION public.fn_populate_party_custody_traceability();


-- Backfill existing rows.
UPDATE public.tbl_cylinder_party_custody
   SET custody_status = custody_status;


COMMENT ON FUNCTION public.fn_populate_party_custody_traceability() IS
'Populates party custody / cylinder obligation traceability fields: entry trip/load/stop, exit trip/load/stop, and aging_due_at.';

COMMENT ON FUNCTION public.fn_try_read_bigint_column(TEXT, TEXT, BIGINT, TEXT) IS
'Safely reads a bigint column from a public table only if the column exists.';

COMMENT ON FUNCTION public.fn_cpc_latest_load_for_trip(BIGINT) IS
'Returns latest vehicle load for a trip, used as fallback for party custody traceability.';

COMMENT ON FUNCTION public.fn_cpc_find_stop(BIGINT, BIGINT, BIGINT, BIGINT) IS
'Best-effort resolver for vehicle trip stop based on trip/order/supplier trip/empty pickup context.';


DO $$
BEGIN
    RAISE NOTICE 'V124 OK: party custody traceability trigger installed.';
    RAISE NOTICE 'V124 OK: existing party custody rows backfilled where source links were available.';
END $$;
