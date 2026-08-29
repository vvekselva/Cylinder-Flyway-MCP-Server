-- public.tbl_empty_pickup definition

-- Drop table

-- DROP TABLE public.tbl_empty_pickup;

CREATE TABLE public.tbl_empty_pickup (
	pk_pickup_id int8 NOT NULL,
	pickup_number varchar(50) NOT NULL,
	pickup_date date NOT NULL,
	fk_customer int8 NOT NULL,
	fk_pickup_address int8 NULL,
	fk_driver int8 NULL,
	fk_vehicle int8 NULL,
	pickup_status varchar(50) DEFAULT 'DRAFT'::character varying NOT NULL,
	total_empty_cylinders int4 NOT NULL,
	damaged_cylinders int4 DEFAULT 0 NOT NULL,
	good_cylinders int4 NOT NULL,
	remarks varchar(500) NULL,
	created_at timestamp DEFAULT now() NOT NULL,
	updated_at timestamp NULL,
	CONSTRAINT tbl_empty_pickup_pk PRIMARY KEY (pk_pickup_id),
	CONSTRAINT tbl_empty_pickup_unique UNIQUE (pickup_number),
	CONSTRAINT tbl_empty_pickup_address_fk FOREIGN KEY (fk_pickup_address) REFERENCES public.tbl_customer_address(pk_customer_address_id),
	CONSTRAINT tbl_empty_pickup_customer_fk FOREIGN KEY (fk_customer) REFERENCES public.tbl_customer(pk_customer_id),
	CONSTRAINT tbl_empty_pickup_driver_fk FOREIGN KEY (fk_driver) REFERENCES public.tbl_driver(pk_driver_id),
	CONSTRAINT tbl_empty_pickup_vehicle_fk FOREIGN KEY (fk_vehicle) REFERENCES public.tbl_vehicle(pk_vehicle_id)
);


-- public.pk_empty_pickup_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_empty_pickup_id_serial;

CREATE SEQUENCE public.pk_empty_pickup_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;