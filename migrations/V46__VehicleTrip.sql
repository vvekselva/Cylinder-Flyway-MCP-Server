-- public.tbl_vehicle_trip definition

-- Drop table

-- DROP TABLE public.tbl_vehicle_trip;

-- public.tbl_vehicle_trip definition

-- Drop table

-- DROP TABLE public.tbl_vehicle_trip;

CREATE TABLE public.tbl_vehicle_trip (
	pk_vehicle_trip_id int8 NOT NULL,
	fk_vehicle int8 NULL,
	fk_driver int8 NULL,
	starting_time time NULL,
	fk_customer_address int8 NULL,
	fk_customer int8 NULL,
	CONSTRAINT tbl_vechile_trip_pk PRIMARY KEY (pk_vehicle_trip_id),
	CONSTRAINT tbl_vehicle_trip_tbl_customer_address_fk FOREIGN KEY (fk_customer_address) REFERENCES public.tbl_customer_address(pk_customer_address_id),
	CONSTRAINT tbl_vehicle_trip_tbl_customer_fk FOREIGN KEY (fk_customer) REFERENCES public.tbl_customer(pk_customer_id),
	CONSTRAINT tbl_vehicle_trip_tbl_driver_fk FOREIGN KEY (fk_driver) REFERENCES public.tbl_driver(pk_driver_id),
	CONSTRAINT tbl_vehicle_trip_tbl_vehicle_fk FOREIGN KEY (fk_vehicle) REFERENCES public.tbl_vehicle(pk_vehicle_id)
);



CREATE SEQUENCE public.pk_vehicle_trip_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;