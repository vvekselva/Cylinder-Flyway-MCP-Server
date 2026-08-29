-- ---------------------------------------------------------------------------
-- CHANGE D: tbl_supplier_trip — link back to vehicle load (optional, traceability)
-- ---------------------------------------------------------------------------
-- When the driver drops yard-empties at the supplier, the supplier trip can
-- optionally reference the vehicle load that carried them there.
-- Empties from YARD loaded with load_purpose = 'EMPTY_FOR_SUPPLIER' were
-- already registered in tbl_vehicle_load_line. This FK closes the chain.
-- ---------------------------------------------------------------------------
-- V45__SupplierTripVehicleLoadLink.sql

ALTER TABLE public.tbl_supplier_trip
    ADD COLUMN fk_vehicle_load int8 NULL;

ALTER TABLE public.tbl_supplier_trip
    ADD CONSTRAINT tbl_supplier_trip_vehicle_load_fk
    FOREIGN KEY (fk_vehicle_load)
    REFERENCES public.tbl_vehicle_load(pk_vehicle_load_id);

CREATE INDEX idx_supplier_trip_vehicle_load
    ON public.tbl_supplier_trip(fk_vehicle_load)
    WHERE fk_vehicle_load IS NOT NULL;


-- =============================================================================
-- SUMMARY OF ALL CHANGES
-- =============================================================================
--
-- V41 — tbl_cylinder_current_status (NEW TABLE)
--        • Single-row per cylinder for instant state + holder lookup
--        • Populated by trigger on tbl_cylinder_state_audit (auto-maintained)
--        • Answers Problem 1 (state) and Problem 2 (customer holder) with
--          zero multi-join queries
--
-- V42 — tbl_vehicle_load_line.load_purpose (NEW COLUMN)
--        • 'FULL_FOR_DELIVERY' or 'EMPTY_FOR_SUPPLIER'
--        • Allows one vehicle trip to carry both full and empty cylinders
--        • Triggers updated to validate and audit correctly per purpose
--
-- V43 — tbl_cylinder_states: EMPTY_IN_TRANSIT_TO_YARD (NEW STATE)
--        • Represents empty picked up from customer, on vehicle, not yet
--          verified at yard — distinct from EMPTY (already in yard)
--
-- V44 — tbl_empty_pickup: fk_vehicle_load + fk_order + pickup_destination
--        • Links customer-pickup events to the delivery trip and stop
--        • CHECK constraint enforces Rule 1: customer empties always go to YARD
--
-- V45 — tbl_supplier_trip.fk_vehicle_load (NEW COLUMN, nullable)
--        • Closes the traceability chain: yard-empty → vehicle → supplier
--
-- =============================================================================
-- CONTROLLER MAPPING AFTER CHANGES (no controller code needs to change)
-- =============================================================================
--
--  Uc02Phase01VehicleLoadController  (/vehicleLoad)
--    UI sends load_purpose per cylinder line.
--    Service writes tbl_vehicle_load + tbl_vehicle_load_line (with load_purpose).
--    Trigger validates state and writes audit + updates current_status.
--
--  Uc02Phase02CylinderDeliveryController  (/cylinderDelivery)
--    Delivery challan (tbl_order + tbl_order_line) unchanged.
--    After saving order, UI also posts empty pickups for the same stop:
--      tbl_empty_pickup (fk_vehicle_load, fk_order set by service)
--      tbl_empty_pickup_line per cylinder picked up
--    Trigger writes EMPTY_IN_TRANSIT_TO_YARD state.
--
--  SupplierTripIngestionController  (/supplierTripIngestion)
--    Only cylinders in EMPTY_PICKED_FOR_REFILL state are eligible.
--    (These were loaded at yard with load_purpose = 'EMPTY_FOR_SUPPLIER'.)
--    Service sets fk_vehicle_load on tbl_supplier_trip.
--    Empties from customers (EMPTY_IN_TRANSIT_TO_YARD) are NOT eligible here —
--    they must complete yard verification first (state → EMPTY) before a new
--    supplier trip can include them.
-- =============================================================================
