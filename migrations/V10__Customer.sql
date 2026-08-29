-- public.tbl_customer definition

-- Drop table

-- DROP TABLE public.tbl_customer;

CREATE TABLE public.tbl_customer (
	pk_customer_id int8 NOT NULL,
	customer_name varchar(500) NOT NULL,
	gst_number varchar(15) NOT NULL,
	CONSTRAINT tbl_customer_pk PRIMARY KEY (pk_customer_id),
	CONSTRAINT tbl_customer_unique UNIQUE (gst_number)
);



ALTER TABLE public.tbl_customer ADD active boolean DEFAULT true NOT NULL;


-- public.pk_customer_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_customer_id_serial;

CREATE SEQUENCE public.pk_customer_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;