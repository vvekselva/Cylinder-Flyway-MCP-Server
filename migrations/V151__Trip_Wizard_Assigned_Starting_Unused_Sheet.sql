-- V151__Trip_Wizard_Assigned_Starting_Unused_Sheet.sql
-- Purpose:
--   Capture the starting UNUSED challan leaf/page selected in the trip-load wizard
--   for each physical challan book assigned to a vehicle trip/load.
--
-- Business reason:
--   The vehicle may receive a book whose earlier pages are already used/spoiled/missing.
--   At trip creation, the office must record the first unused page physically handed
--   over with the vehicle. During Returned Trip processing, pages before the returned
--   first-unused page must only be marked pending-entry from this assigned start page
--   onward.

ALTER TABLE public.tbl_trip_challan_book_assignment
    ADD COLUMN IF NOT EXISTS assigned_start_sheet_number INTEGER;

COMMENT ON COLUMN public.tbl_trip_challan_book_assignment.assigned_start_sheet_number IS
    'First UNUSED challan sheet/page physically issued with this trip-load assignment. Captured in VehicleTripLoadWizard Step 2.';

DROP VIEW IF EXISTS public.vw_trip_challan_book_assignments;

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
    a.assigned_start_sheet_number,
    a.returned_at,
    a.return_verified_by,
    a.remarks,
    COUNT(p.pk_page_audit_id) FILTER (WHERE p.page_status::text = 'UNUSED') AS unused_count,
    COUNT(p.pk_page_audit_id) FILTER (WHERE p.page_status::text = 'USED_CONFIRMED') AS used_count,
    COUNT(p.pk_page_audit_id) FILTER (WHERE p.page_status::text = 'PHYSICALLY_USED_PENDING_ENTRY') AS pending_entry_count,
    COUNT(p.pk_page_audit_id) FILTER (WHERE p.page_status::text = 'CANCELLED_SPOILED') AS spoiled_count,
    COUNT(p.pk_page_audit_id) FILTER (WHERE p.page_status::text = 'FLAGGED_MISSING') AS missing_count,
    MIN(p.sheet_number) FILTER (WHERE p.page_status::text IN ('UNUSED','PHYSICALLY_USED_PENDING_ENTRY')) AS next_available_sheet_number
FROM public.tbl_trip_challan_book_assignment a
JOIN public.tbl_challan_book_registry b ON b.pk_book_id = a.fk_challan_book
LEFT JOIN public.tbl_challan_page_audit_ledger p ON p.fk_book_id = b.pk_book_id
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
    a.assigned_start_sheet_number,
    a.returned_at,
    a.return_verified_by,
    a.remarks;

COMMENT ON VIEW public.vw_trip_challan_book_assignments IS
    'Trip/load-level challan book assignments with assigned starting unused sheet and unused, pending-entry, used, spoiled and missing counts.';
