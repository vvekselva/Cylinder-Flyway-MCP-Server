-- =====================================================================
-- V120__Merge_Trip_Departure_Into_Trip_Load.sql
-- =====================================================================
-- Purpose:
--   Merge TRIP_DEPARTURE and TRIP_LOAD_CONFIRMED behavior into the new
--   TRIP_LOAD parent accountability checkpoint introduced in V119.
--
-- Clean database assumption:
--   No historical UPDATE is required.
--
-- Rules:
--   1. Loaded status seeds only TRIP_LOAD header + serial lines.
--   2. Loaded status must NOT create TRIP_LOAD_CONFIRMED.
--   3. Loaded status must NOT create TRIP_DEPARTURE.
--   4. Halt status must NOT resolve TRIP_DEPARTURE.
--   5. Halt status attempts serial-level TRIP_LOAD settlement only.
--   6. Unsettled serials remain OPEN/PENDING for later settlement/escalation.
-- =====================================================================


CREATE OR REPLACE FUNCTION public.fn_trip_status_after_update()
RETURNS TRIGGER AS $$
DECLARE
    v_new_name              varchar(50);

    v_load_id               int8;
    v_cyl_count             int4 := 0;
    v_header_id             int8;

    v_stop_rec              RECORD;
    v_actual_lines          int4;
    v_acc_rec               RECORD;

    v_accounted_attempts    int4 := 0;
    v_unaccounted_count     int4 := 0;
BEGIN
    IF NEW.fk_trip_status = OLD.fk_trip_status THEN
        RETURN NEW;
    END IF;

    SELECT status_name
      INTO v_new_name
      FROM public.tbl_trip_status
     WHERE pk_trip_status_id = NEW.fk_trip_status;

    SELECT pk_vehicle_load_id
      INTO v_load_id
      FROM public.tbl_vehicle_load
     WHERE fk_vehicle_trip = NEW.pk_vehicle_trip_id
     ORDER BY pk_vehicle_load_id DESC
     LIMIT 1;

    IF v_load_id IS NOT NULL THEN
        SELECT COUNT(pk_vehicle_load_line_id)
          INTO v_cyl_count
          FROM public.tbl_vehicle_load_line
         WHERE fk_vehicle_load = v_load_id;

        IF v_cyl_count = 0 THEN
            SELECT COALESCE(total_cylinders_loaded, 0)
              INTO v_cyl_count
              FROM public.tbl_vehicle_load
             WHERE pk_vehicle_load_id = v_load_id;
        END IF;
    END IF;


    -- =====================================================================
    -- LOADED
    -- =====================================================================
    -- Old behavior:
    --   - create TRIP_LOAD_CONFIRMED lines
    --   - create TRIP_DEPARTURE aggregate checkpoint
    --
    -- New behavior:
    --   - only ensure TRIP_LOAD header and serial lines.
    -- =====================================================================
    IF v_new_name = 'Loaded' THEN

        BEGIN
            PERFORM public.fn_open_daily_count(CURRENT_DATE, 'TRIP_LOAD');
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[Loaded/daily_count]: %', SQLERRM;
        END;

        IF v_load_id IS NOT NULL THEN
            BEGIN
                v_header_id := public.fn_ensure_trip_load_reconciliation_header(
                    NEW.pk_vehicle_trip_id,
                    v_load_id
                );

                PERFORM public.fn_seed_trip_load_reconciliation_lines(
                    v_header_id,
                    NEW.pk_vehicle_trip_id,
                    v_load_id
                );

                RAISE NOTICE
                    '[Loaded/TRIP_LOAD]: seeded header %, trip %, load %, cylinders %.',
                    v_header_id, NEW.pk_vehicle_trip_id, v_load_id, v_cyl_count;

            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE '[Loaded/TRIP_LOAD seed]: %', SQLERRM;
            END;
        END IF;

    END IF;


    -- =====================================================================
    -- HALT
    -- =====================================================================
    -- Keep stop aggregate resolution for stop-level visibility, but do not
    -- close parent TRIP_LOAD merely because the trip halted.
    --
    -- TRIP_LOAD remains open if any loaded serial is still unaccounted.
    -- =====================================================================
    IF v_new_name = 'Halt' THEN

        -- Keep existing customer delivery aggregate resolution, if such rows exist.
        FOR v_stop_rec IN
            SELECT pk_checkpoint_id, reference_entity_id AS order_id, expected_count
              FROM public.tbl_reconciliation_checkpoint
             WHERE fk_vehicle_trip   = NEW.pk_vehicle_trip_id
               AND checkpoint_type   = 'TRIP_STOP_DELIVERY'
               AND checkpoint_status = 'PENDING'
               AND fk_header IS NULL
        LOOP
            SELECT COUNT(*)
              INTO v_actual_lines
              FROM public.tbl_order_line
             WHERE fk_order = v_stop_rec.order_id;

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


        -- Keep existing empty pickup aggregate resolution, if such rows exist.
        FOR v_stop_rec IN
            SELECT pk_checkpoint_id, reference_entity_id AS pickup_id, expected_count
              FROM public.tbl_reconciliation_checkpoint
             WHERE fk_vehicle_trip   = NEW.pk_vehicle_trip_id
               AND checkpoint_type   = 'TRIP_STOP_EMPTY_PICKUP'
               AND checkpoint_status = 'PENDING'
               AND fk_header IS NULL
        LOOP
            SELECT COUNT(*)
              INTO v_actual_lines
              FROM public.tbl_empty_pickup_line
             WHERE fk_empty_pickup = v_stop_rec.pickup_id;

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


        -- Attempt parent TRIP_LOAD serial settlement using the V119 common path.
        BEGIN
            SELECT pk_header_id
              INTO v_header_id
              FROM public.tbl_reconciliation_header
             WHERE fk_vehicle_trip = NEW.pk_vehicle_trip_id
               AND header_type     = 'TRIP_LOAD'
               AND header_status IN ('OPEN', 'VARIANCE')
             ORDER BY opened_at DESC
             LIMIT 1;

            IF v_header_id IS NULL AND v_load_id IS NOT NULL THEN
                v_header_id := public.fn_ensure_trip_load_reconciliation_header(
                    NEW.pk_vehicle_trip_id,
                    v_load_id
                );

                PERFORM public.fn_seed_trip_load_reconciliation_lines(
                    v_header_id,
                    NEW.pk_vehicle_trip_id,
                    v_load_id
                );
            END IF;

            IF v_header_id IS NULL THEN
                RAISE NOTICE '[Halt/TRIP_LOAD]: No TRIP_LOAD header found for trip %.',
                    NEW.pk_vehicle_trip_id;
            ELSE
                FOR v_acc_rec IN
                    SELECT *
                      FROM public.fn_trip_load_accountability(NEW.pk_vehicle_trip_id)
                LOOP
                    IF v_acc_rec.accountability_bucket = 'UNACCOUNTED' THEN
                        v_unaccounted_count := v_unaccounted_count + 1;
                    ELSE
                        v_accounted_attempts := v_accounted_attempts + 1;

                        PERFORM public.fn_resolve_trip_load_accountability(
                            NEW.pk_vehicle_trip_id,
                            v_acc_rec.fk_cylinder,
                            v_acc_rec.accountability_bucket,
                            v_acc_rec.resolved_via_entity,
                            v_acc_rec.resolved_via_id
                        );
                    END IF;
                END LOOP;

                PERFORM public.fn_recompute_reconciliation_header_status(v_header_id);

                RAISE NOTICE
                    '[Halt/TRIP_LOAD]: trip %, accounted attempts %, unaccounted currently %.',
                    NEW.pk_vehicle_trip_id, v_accounted_attempts, v_unaccounted_count;
            END IF;

        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[Halt/TRIP_LOAD settlement]: %', SQLERRM;
        END;

    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


COMMENT ON FUNCTION public.fn_trip_status_after_update() IS
    'V120 — Merges TRIP_DEPARTURE and TRIP_LOAD_CONFIRMED into TRIP_LOAD. '
    'Loaded seeds only TRIP_LOAD header and serial lines. '
    'Halt attempts TRIP_LOAD serial settlement but does not close unresolved '
    'assets as variance merely because the trip halted. Pending serials remain '
    'open for later settlement/escalation.';
