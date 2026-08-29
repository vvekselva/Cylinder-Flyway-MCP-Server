-- public.tbl_phone_number definition

-- Drop table

-- DROP TABLE public.tbl_phone_number;

CREATE TABLE public.tbl_phone_number (
	pk_phone_number_id int8 NOT NULL,
	phone_number varchar(100) NOT NULL,
	CONSTRAINT tbl_phone_number_pk PRIMARY KEY (pk_phone_number_id),
	CONSTRAINT tbl_phone_number_unique UNIQUE (phone_number)
);


-- public.pk_phone_number_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_phone_number_id_serial;

CREATE SEQUENCE public.pk_phone_number_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;