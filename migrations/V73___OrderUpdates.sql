ALTER TABLE public.tbl_order ADD fk_vehicle_load int8 NULL;
ALTER TABLE public.tbl_order ADD fk_vehicle_trip int8 NULL;
ALTER TABLE public.tbl_order ADD fk_vehicle_trip_stop int8 NULL;
ALTER TABLE public.tbl_order ADD CONSTRAINT tbl_order_tbl_vehicle_trip_fk FOREIGN KEY (fk_vehicle_trip) REFERENCES public.tbl_vehicle_trip(pk_vehicle_trip_id);
ALTER TABLE public.tbl_order ADD CONSTRAINT tbl_order_tbl_vehicle_load_fk FOREIGN KEY (fk_vehicle_load) REFERENCES public.tbl_vehicle_load(pk_vehicle_load_id);
ALTER TABLE public.tbl_order ADD CONSTRAINT tbl_order_tbl_vehicle_trip_stop_fk FOREIGN KEY (fk_vehicle_trip_stop) REFERENCES public.tbl_vehicle_trip_stop(pk_stop_id);



ALTER TABLE public.tbl_supplier_refill_collection ADD fk_vehicle_load int8 NULL;
ALTER TABLE public.tbl_supplier_refill_collection ADD CONSTRAINT tbl_supplier_refill_collection_tbl_vehicle_load_fk FOREIGN KEY (fk_vehicle_load) REFERENCES public.tbl_vehicle_load(pk_vehicle_load_id);
ALTER TABLE public.tbl_supplier_refill_collection ADD fk_vehicle_trip_stop int8 NULL;
ALTER TABLE public.tbl_supplier_refill_collection ADD CONSTRAINT tbl_supplier_refill_collection_tbl_vehicle_trip_stop_fk FOREIGN KEY (fk_vehicle_trip_stop) REFERENCES public.tbl_vehicle_trip_stop(pk_stop_id);

