-- public.tbl_supplier_trip definition

-- Drop table

-- DROP TABLE public.tbl_supplier_trip;

CREATE TABLE public.tbl_supplier_trip (
	pk_supplier_trip_id int8 NOT NULL,
	trip_number varchar(50) NULL,
	fk_supplier int8 NOT NULL,
	fk_driver int8 NULL,
	fk_vehicle int8 NULL,
	dropoff_date date NOT NULL,
	trip_status varchar(50) DEFAULT 'PENDING'::character varying NOT NULL,
	remarks varchar(500) NULL,
	created_at timestamp DEFAULT now() NOT NULL,
	CONSTRAINT tbl_supplier_trip_pk PRIMARY KEY (pk_supplier_trip_id),
	CONSTRAINT tbl_supplier_trip_unique UNIQUE (trip_number),
	CONSTRAINT tbl_supplier_trip_driver_fk FOREIGN KEY (fk_driver) REFERENCES public.tbl_driver(pk_driver_id),
	CONSTRAINT tbl_supplier_trip_supplier_fk FOREIGN KEY (fk_supplier) REFERENCES public.tbl_supplier(pk_supplier_id),
	CONSTRAINT tbl_supplier_trip_vehicle_fk FOREIGN KEY (fk_vehicle) REFERENCES public.tbl_vehicle(pk_vehicle_id)
);
-- public.pk_supplier_trip_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_supplier_trip_id_serial;

CREATE SEQUENCE public.pk_supplier_trip_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;


