-- public.tbl_country definition

-- Drop table

-- DROP TABLE public.tbl_country;

CREATE TABLE public.tbl_country (
	pk_country_id int8 NOT NULL,
	country_name varchar(100) NOT NULL,
	description varchar(500) NOT NULL,
	CONSTRAINT tbl_country_pk PRIMARY KEY (pk_country_id),
	CONSTRAINT tbl_country_unique UNIQUE (country_name)
);


-- public.pk_country_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_country_id_serial;

CREATE SEQUENCE public.pk_country_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;