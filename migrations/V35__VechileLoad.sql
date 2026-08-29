-- public.tbl_vehicle_load definition

-- Drop table

-- DROP TABLE public.tbl_vehicle_load;

CREATE TABLE public.tbl_vehicle_load (
	pk_vehicle_load_id int8 NOT NULL,
	fk_vehicle int8 NOT NULL,
	fk_driver int8 NOT NULL,
	load_date date NOT NULL,
	load_time timestamp NOT NULL,
	total_cylinders_loaded int4 NOT NULL,
	loaded_by varchar(200) NOT NULL,
	remarks varchar(500) NULL,
	created_at timestamp DEFAULT now() NULL,
	CONSTRAINT tbl_vehicle_load_pkey PRIMARY KEY (pk_vehicle_load_id),
	CONSTRAINT tbl_vehicle_load_tbl_driver_fk FOREIGN KEY (fk_driver) REFERENCES public.tbl_driver(pk_driver_id),
	CONSTRAINT tbl_vehicle_load_tbl_vehicle_fk FOREIGN KEY (fk_vehicle) REFERENCES public.tbl_vehicle(pk_vehicle_id)
);


-- public.pk_vehicle_load_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_vehicle_load_id_serial;

CREATE SEQUENCE public.pk_vehicle_load_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;