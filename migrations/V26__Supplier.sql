-- public.tbl_supplier definition

-- Drop table

-- DROP TABLE public.tbl_supplier;

CREATE TABLE public.tbl_supplier (
	pk_supplier_id int8 NOT NULL,
	supplier_name varchar(200) NOT NULL,
	gst_number varchar(15) NULL,
	fk_address int8 NULL,
	fk_phone_number int8 NULL,
	is_active bool DEFAULT true NOT NULL,
	CONSTRAINT tbl_supplier_pk PRIMARY KEY (pk_supplier_id),
	CONSTRAINT tbl_supplier_unique UNIQUE (supplier_name),
	CONSTRAINT tbl_supplier_address_fk FOREIGN KEY (fk_address) REFERENCES public.tbl_address(pk_address_id),
	CONSTRAINT tbl_supplier_phone_fk FOREIGN KEY (fk_phone_number) REFERENCES public.tbl_phone_number(pk_phone_number_id)
);


-- public.pk_supplier_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_supplier_id_serial;

CREATE SEQUENCE public.pk_supplier_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;