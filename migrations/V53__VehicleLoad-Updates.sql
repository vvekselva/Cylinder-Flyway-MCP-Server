ALTER TABLE public.tbl_vehicle_load DROP CONSTRAINT tbl_vehicle_load_tbl_vehicle_fk;
ALTER TABLE public.tbl_vehicle_load DROP CONSTRAINT tbl_vehicle_load_tbl_driver_fk;
ALTER TABLE public.tbl_vehicle_load DROP COLUMN fk_vehicle;
ALTER TABLE public.tbl_vehicle_load DROP COLUMN fk_driver;
ALTER TABLE public.tbl_vehicle_load DROP COLUMN load_date;
ALTER TABLE public.tbl_vehicle_load DROP COLUMN load_time;
