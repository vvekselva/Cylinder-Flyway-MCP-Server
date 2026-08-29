-- =====================================================================
-- V146__Remove_Assignment_Status_From_Trip_Challan_Book_Assignment.sql
-- =====================================================================
-- Purpose:
--   Correct V145 after removing assignment_status from trip challan book
--   assignment design.
--
-- Why this migration is needed:
--   PostgreSQL cannot change an existing view column name/order using
--   CREATE OR REPLACE VIEW. The earlier view had assignment_status, and the
--   corrected view has active_assignment. Therefore the view must be dropped
--   and recreated.
--
-- Design:
--   - Physical book location remains in tbl_challan_book_registry.current_location.
--   - Existing Java BookLocation enum continues to represent physical location.
--   - Active trip assignment is derived from returned_at IS NULL.
-- =====================================================================

-- =====================================================================
-- 1. Drop dependent views first
-- =====================================================================

DROP VIEW IF EXISTS public.vw_trip_challan_book_assignments;
DROP VIEW IF EXISTS public.vw_active_challan_books_for_trip_load;


-- =====================================================================
-- 2. Drop old trigger before altering table/function behavior
-- =====================================================================

DROP TRIGGER IF EXISTS trg_validate_trip_challan_book_assignment
ON public.tbl_trip_challan_book_assignment;


-- =====================================================================
-- 3. Remove old assignment_status artifacts if they exist
-- =====================================================================

DROP INDEX IF EXISTS public.idx_trip_challan_book_assignment_status;
DROP INDEX IF EXISTS public.uq_active_trip_challan_book_assignment;

ALTER TABLE public.tbl_trip_challan_book_assignment
    DROP CONSTRAINT IF EXISTS tbl_trip_challan_book_assignment_status_chk;

ALTER TABLE public.tbl_trip_challan_book_assignment
    DROP COLUMN IF EXISTS assignment_status;


-- =====================================================================
-- 4. Recreate indexes using returned_at based active assignment rule
-- =====================================================================

-- Only one open trip can hold a challan book at a time.
CREATE UNIQUE INDEX IF NOT EXISTS uq_active_trip_challan_book_assignment
ON public.tbl_trip_challan_book_assignment(fk_challan_book)
WHERE returned_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_trip_challan_book_assignment_trip
ON public.tbl_trip_challan_book_assignment(fk_vehicle_trip);

CREATE INDEX IF NOT EXISTS idx_trip_challan_book_assignment_load
ON public.tbl_trip_challan_book_assignment(fk_vehicle_load);

CREATE INDEX IF NOT EXISTS idx_trip_challan_book_assignment_book
ON public.tbl_trip_challan_book_assignment(fk_challan_book);

CREATE INDEX IF NOT EXISTS idx_trip_challan_book_assignment_active
ON public.tbl_trip_challan_book_assignment(fk_vehicle_trip, fk_vehicle_load)
WHERE returned_at IS NULL;


-- =====================================================================
-- 5. Recreate validation + registry sync function
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
    SELECT l.fk_vehicle_trip, l.fk_vehicle
      INTO v_load_trip_id, v_vehicle_id
      FROM public.tbl_vehicle_load l
     WHERE l.pk_vehicle_load_id = NEW.fk_vehicle_load;

    IF v_load_trip_id IS NULL THEN
        RAISE EXCEPTION 'Vehicle load % does not exist or is not linked to a vehicle trip.', NEW.fk_vehicle_load;
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

    -- Keep existing registry location fields in sync.
    -- returned_at NULL means the book is physically with the trip/vehicle.
    IF NEW.returned_at IS NULL THEN
        UPDATE public.tbl_challan_book_registry
           SET current_location = 'IN_VEHICLE_TRANSIT',
               fk_assigned_vehicle = v_vehicle_id,
               updated_at = now()
         WHERE pk_book_id = NEW.fk_challan_book;
    ELSE
        -- Once returned, location is decided from remaining pages.
        -- If no unused pages remain, the book is exhausted/archived.
        -- Otherwise, it is available in office again.
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

CREATE TRIGGER trg_validate_trip_challan_book_assignment
BEFORE INSERT OR UPDATE
ON public.tbl_trip_challan_book_assignment
FOR EACH ROW
EXECUTE FUNCTION public.fn_validate_trip_challan_book_assignment();


-- =====================================================================
-- 6. Recreate active office books view
-- =====================================================================

CREATE VIEW public.vw_active_challan_books_for_trip_load AS
SELECT
    b.pk_book_id AS book_id,
    b.book_code,
    b.book_type::text AS book_type,
    b.series_prefix,
    b.start_sheet_number,
    b.end_sheet_number,
    b.current_location::text AS current_location,
    b.fk_assigned_vehicle,
    COUNT(p.pk_page_audit_id) FILTER (WHERE p.page_status = 'UNUSED') AS unused_count,
    COUNT(p.pk_page_audit_id) FILTER (WHERE p.page_status = 'USED_CONFIRMED') AS used_count,
    COUNT(p.pk_page_audit_id) FILTER (WHERE p.page_status = 'CANCELLED_SPOILED') AS spoiled_count,
    COUNT(p.pk_page_audit_id) FILTER (WHERE p.page_status = 'FLAGGED_MISSING') AS missing_count,
    MIN(p.sheet_number) FILTER (WHERE p.page_status = 'UNUSED') AS next_available_sheet_number
FROM public.tbl_challan_book_registry b
JOIN public.tbl_challan_page_audit_ledger p
  ON p.fk_book_id = b.pk_book_id
WHERE b.current_location = 'IN_OFFICE'
GROUP BY
    b.pk_book_id,
    b.book_code,
    b.book_type,
    b.series_prefix,
    b.start_sheet_number,
    b.end_sheet_number,
    b.current_location,
    b.fk_assigned_vehicle
HAVING COUNT(p.pk_page_audit_id) FILTER (WHERE p.page_status = 'UNUSED') > 0;

COMMENT ON VIEW public.vw_active_challan_books_for_trip_load IS
    'Challan books available for VehicleTripLoadWizard Step 2. Only IN_OFFICE books with UNUSED pages are shown.';


-- =====================================================================
-- 7. Recreate trip assigned books view
-- =====================================================================

CREATE VIEW public.vw_trip_challan_book_assignments AS
SELECT
    a.pk_trip_challan_book_assignment_id AS assignment_id,
    a.fk_vehicle_trip,
    a.fk_vehicle_load,
    a.fk_challan_book AS book_id,
    b.book_code,
    b.book_type::text AS book_type,
    b.series_prefix,
    b.start_sheet_number,
    b.end_sheet_number,
    b.current_location::text AS current_location,
    b.fk_assigned_vehicle,
    (a.returned_at IS NULL) AS active_assignment,
    a.assigned_at,
    a.assigned_by,
    a.returned_at,
    a.return_verified_by,
    a.remarks,
    COUNT(p.pk_page_audit_id) FILTER (WHERE p.page_status = 'UNUSED') AS unused_count,
    COUNT(p.pk_page_audit_id) FILTER (WHERE p.page_status = 'USED_CONFIRMED') AS used_count,
    COUNT(p.pk_page_audit_id) FILTER (WHERE p.page_status = 'CANCELLED_SPOILED') AS spoiled_count,
    COUNT(p.pk_page_audit_id) FILTER (WHERE p.page_status = 'FLAGGED_MISSING') AS missing_count,
    MIN(p.sheet_number) FILTER (WHERE p.page_status = 'UNUSED') AS next_available_sheet_number
FROM public.tbl_trip_challan_book_assignment a
JOIN public.tbl_challan_book_registry b
  ON b.pk_book_id = a.fk_challan_book
LEFT JOIN public.tbl_challan_page_audit_ledger p
  ON p.fk_book_id = b.pk_book_id
GROUP BY
    a.pk_trip_challan_book_assignment_id,
    a.fk_vehicle_trip,
    a.fk_vehicle_load,
    a.fk_challan_book,
    b.book_code,
    b.book_type,
    b.series_prefix,
    b.start_sheet_number,
    b.end_sheet_number,
    b.current_location,
    b.fk_assigned_vehicle,
    a.assigned_at,
    a.assigned_by,
    a.returned_at,
    a.return_verified_by,
    a.remarks;

COMMENT ON VIEW public.vw_trip_challan_book_assignments IS
    'Trip/load-level challan book assignments with page usage summary. active_assignment is derived from returned_at IS NULL.';
