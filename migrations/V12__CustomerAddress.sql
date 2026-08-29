-- public.tbl_customer_address definition

-- Drop table

-- DROP TABLE public.tbl_customer_address;

CREATE TABLE public.tbl_customer_address (
	pk_customer_address_id int8 NOT NULL,
	fk_customer int8 NULL,
	fk_address int8 NULL,
	fk_address_type int8 NULL,
	CONSTRAINT tbl_customer_address_pk PRIMARY KEY (pk_customer_address_id)
);


-- public.pk_customer_address_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_customer_address_id_serial;

CREATE SEQUENCE public.pk_customer_address_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;