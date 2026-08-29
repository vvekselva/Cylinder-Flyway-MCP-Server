-- public.tbl_driver definition

-- Drop table
 --DROP TABLE public.tbl_vehicle;

CREATE TABLE public.tbl_vehicle (
	pk_vehicle_id int8 NOT NULL,
	vehicle_number varchar(50) NOT NULL,
	vehicle_type varchar(100) NOT NULL,
	capacity numeric(8, 2) NOT NULL,
	registration_date date NOT NULL,
	is_active bool DEFAULT true NOT NULL,
	CONSTRAINT tbl_vehicle_pk PRIMARY KEY (pk_vehicle_id),
	CONSTRAINT tbl_vehicle_unique UNIQUE (vehicle_number)
);

-- public.pk_driver_id_serial definition

DROP SEQUENCE IF EXISTS public.pk_vehicle_id_serial;

CREATE SEQUENCE public.pk_vehicle_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;