-- public.tbl_address_type definition

-- Drop table

-- DROP TABLE public.tbl_address_type;

CREATE TABLE public.tbl_address_type (
	pk_address_type_id int8 NOT NULL,
	address_type varchar(100) NOT NULL,
	description varchar(100) NOT NULL,
	CONSTRAINT tbl_address_type_pk PRIMARY KEY (pk_address_type_id),
	CONSTRAINT tbl_address_type_unique UNIQUE (address_type)
);



-- public.pk_address_type_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_address_type_id_serial;

CREATE SEQUENCE public.pk_address_type_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;

