-- public.tbl_customer_phone_number definition

-- Drop table

-- DROP TABLE public.tbl_customer_phone_number;

CREATE TABLE public.tbl_customer_phone_number (
	pk_customer_phone_number_id int8 NOT NULL,
	fk_customer int8 NOT NULL,
	fk_phone_number int8 NOT NULL,
	CONSTRAINT tbl_customer_phone_number_pk PRIMARY KEY (pk_customer_phone_number_id),
	CONSTRAINT tbl_customer_phone_number_unique UNIQUE (fk_customer, fk_phone_number),
	CONSTRAINT tbl_customer_phone_number_tbl_customer_fk FOREIGN KEY (fk_customer) REFERENCES public.tbl_customer(pk_customer_id),
	CONSTRAINT tbl_customer_phone_number_tbl_phone_number_fk FOREIGN KEY (fk_phone_number) REFERENCES public.tbl_phone_number(pk_phone_number_id)
);



-- public.pk_customer_phone_number_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_customer_phone_number_id_serial;

CREATE SEQUENCE public.pk_customer_phone_number_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;