ALTER TABLE public.tbl_vehicle_load_line ADD delivered_to_customer bool NULL;
ALTER TABLE public.tbl_vehicle_load_line ADD delivered_to_supplier bool NULL;


-- Index for performance during trip lookups
CREATE INDEX idx_vll_trip_delivery 
ON tbl_vehicle_load_line (fk_vehicle_load, delivered_to_supplier, delivered_to_customer);