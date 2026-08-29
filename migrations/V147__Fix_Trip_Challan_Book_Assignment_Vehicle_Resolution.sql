-- =====================================================================
-- V147__Fix_Trip_Challan_Book_Assignment_Vehicle_Resolution.sql
-- =====================================================================
-- Purpose:
--   Fix the trip challan book assignment trigger after the VehicleLoad
--   model was changed to store only fk_vehicle_trip.
--
-- Problem:
--   V145/V146 function fn_validate_trip_challan_book_assignment() resolves
--   the assigned vehicle using:
--
--       tbl_vehicle_load.fk_vehicle
--
--   But the current schema does not have tbl_vehicle_load.fk_vehicle.
--   Vehicle is owned by tbl_vehicle_trip:
--
--       tbl_vehicle_load.fk_vehicle_trip
--           -> tbl_vehicle_trip.pk_vehicle_trip_id
--           -> tbl_vehicle_trip.fk_vehicle
--
-- Scope:
--   This migration only fixes vehicle resolution inside the existing
--   trigger function. It does not introduce a new trip-return workflow.
--   Existing returned_at handling inside this function is preserved.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.fn_validate_trip_challan_book_assignment()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
DECLARE
    v_load_trip_id BIGINT;
    v_vehicle_id BIGINT;
    v_book RECORD;
    v_unused_pages INTEGER;
BEGIN
    -- Current schema path:
    -- tbl_vehicle_load -> tbl_vehicle_trip -> tbl_vehicle
    SELECT l.fk_vehicle_trip,
           t.fk_vehicle
      INTO v_load_trip_id,
           v_vehicle_id
      FROM public.tbl_vehicle_load l
      JOIN public.tbl_vehicle_trip t
        ON t.pk_vehicle_trip_id = l.fk_vehicle_trip
     WHERE l.pk_vehicle_load_id = NEW.fk_vehicle_load;

    IF v_load_trip_id IS NULL THEN
        RAISE EXCEPTION 'Vehicle load % does not exist or is not linked to a vehicle trip.', NEW.fk_vehicle_load;
    END IF;

    IF v_vehicle_id IS NULL THEN
        RAISE EXCEPTION 'Vehicle trip % linked to vehicle load % does not have a vehicle.',
            v_load_trip_id, NEW.fk_vehicle_load;
    END IF;

    IF v_load_trip_id <> NEW.fk_vehicle_trip THEN
        RAISE EXCEPTION 'Vehicle load % belongs to trip %, but assignment was made for trip %.',
            NEW.fk_vehicle_load, v_load_trip_id, NEW.fk_vehicle_trip;
    END IF;

    SELECT *
      INTO v_book
      FROM public.tbl_challan_book_registry b
     WHERE b.pk_book_id = NEW.fk_challan_book;

    IF v_book.pk_book_id IS NULL THEN
        RAISE EXCEPTION 'Challan book % does not exist.', NEW.fk_challan_book;
    END IF;

    SELECT COUNT(*)
      INTO v_unused_pages
      FROM public.tbl_challan_page_audit_ledger p
     WHERE p.fk_book_id = NEW.fk_challan_book
       AND p.page_status = 'UNUSED';

    -- New active assignment: book must be in office and must have at least one unused page.
    IF TG_OP = 'INSERT' AND NEW.returned_at IS NULL THEN
        IF v_book.current_location <> 'IN_OFFICE' THEN
            RAISE EXCEPTION 'Challan book % is not available in office. Current location: %.',
                NEW.fk_challan_book, v_book.current_location;
        END IF;

        IF COALESCE(v_unused_pages, 0) = 0 THEN
            RAISE EXCEPTION 'Challan book % has no UNUSED pages and cannot be assigned to a trip.', NEW.fk_challan_book;
        END IF;
    END IF;

    NEW.updated_at := now();

    -- Assignment active: book is physically with the vehicle.
    IF NEW.returned_at IS NULL THEN
        UPDATE public.tbl_challan_book_registry
           SET current_location = 'IN_VEHICLE_TRANSIT',
               fk_assigned_vehicle = v_vehicle_id,
               updated_at = now()
         WHERE pk_book_id = NEW.fk_challan_book;
    ELSE
        -- Existing behavior preserved from V146.
        -- Full return workflow can be redesigned later in the trip-return module.
        IF COALESCE(v_unused_pages, 0) = 0 THEN
            UPDATE public.tbl_challan_book_registry
               SET current_location = 'EXHAUSTED_ARCHIVED',
                   fk_assigned_vehicle = NULL,
                   updated_at = now()
             WHERE pk_book_id = NEW.fk_challan_book;
        ELSE
            UPDATE public.tbl_challan_book_registry
               SET current_location = 'IN_OFFICE',
                   fk_assigned_vehicle = NULL,
                   updated_at = now()
             WHERE pk_book_id = NEW.fk_challan_book;
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;
