-- public.tbl_driver definition

-- Drop table

-- DROP TABLE public.tbl_driver;

CREATE TABLE public.tbl_driver (
	pk_driver_id int8 NOT NULL,
	driver_name varchar(200) NOT NULL,
	fk_phone_number int8 NULL,
	licence_number varchar(50) NULL,
	CONSTRAINT tbl_driver_pk PRIMARY KEY (pk_driver_id),
	CONSTRAINT tbl_driver_tbl_phone_number_fk FOREIGN KEY (fk_phone_number) REFERENCES public.tbl_phone_number(pk_phone_number_id)
);


-- public.pk_driver_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_driver_id_serial;

CREATE SEQUENCE public.pk_driver_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;