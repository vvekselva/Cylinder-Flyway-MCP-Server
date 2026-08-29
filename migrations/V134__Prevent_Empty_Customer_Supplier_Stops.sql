-- =============================================================================
-- V134 — Prevent empty customer/supplier stops - DB gate removed
-- =============================================================================
-- IMPORTANT:
--   The empty-stop rule is handled in VehicleTripStopIngestionService by checking
--   whether the current stop created/increased real transaction rows:
--      - logistics execution lines
--      - order lines
--      - empty pickup lines
--      - supplier trip lines
--      - supplier refill collection lines
--
--   A database-level gate is intentionally NOT installed here because the stop
--   row may be saved before/after line rows depending on service flush order.
--   A DB trigger can therefore reject valid workflows or rely on incorrect
--   column names.
--
-- Reason for this replacement:
--   Previous V134 failed on clean migration because it referenced
--      tbl_supplier_refill_collection_line.fk_supplier_refill_collection
--   but the actual column is:
--      tbl_supplier_refill_collection_line.fk_collection
-- =============================================================================

DROP TRIGGER IF EXISTS trg_validate_customer_supplier_stop_has_lines
ON public.tbl_vehicle_trip_stop;

DROP FUNCTION IF EXISTS public.fn_validate_customer_supplier_stop_has_lines();

DO $$
BEGIN
    RAISE NOTICE 'V134 OK: database empty-stop gate intentionally not installed. Empty customer/supplier stop prevention must be enforced in VehicleTripStopIngestionService using transaction-line count.';
END $$;
