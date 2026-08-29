ALTER TABLE public.tbl_supplier_trip DROP CONSTRAINT tbl_supplier_trip_unique;


ALTER TABLE public.tbl_supplier_trip ADD fk_vehicle_trip_stop int8 NULL;
ALTER TABLE public.tbl_supplier_trip ADD CONSTRAINT tbl_supplier_trip_tbl_vehicle_trip_stop_fk FOREIGN KEY (fk_vehicle_trip_stop) REFERENCES public.tbl_vehicle_trip_stop(pk_stop_id);


ALTER TABLE public.tbl_supplier_trip_line DROP CONSTRAINT tbl_supplier_trip_line_vehicle_trip_stop_fk;
ALTER TABLE public.tbl_supplier_trip_line DROP COLUMN fk_vehicle_trip_stop;
