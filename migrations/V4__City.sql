-- public.tbl_city definition

-- Drop table

-- DROP TABLE public.tbl_city;

CREATE TABLE public.tbl_city (
	pk_city_id int8 NOT NULL,
	city varchar(100) NOT NULL,
	description varchar(500) NOT NULL,
	CONSTRAINT tbl_city_pk PRIMARY KEY (pk_city_id),
	CONSTRAINT tbl_city_unique UNIQUE (city)
);	



-- public.pk_city_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_city_id_serial;

CREATE SEQUENCE public.pk_city_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;