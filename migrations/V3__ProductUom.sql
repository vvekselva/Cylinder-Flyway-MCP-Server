-- public.tbl_product_uom definition

-- Drop table

-- DROP TABLE public.tbl_product_uom;

CREATE TABLE public.tbl_product_uom (
	pk_product_uom_id int8 NOT NULL,
	product_uom varchar(100) NOT NULL,
	description varchar(500) NOT NULL,
	CONSTRAINT tbl_product_uom_pk PRIMARY KEY (pk_product_uom_id),
	CONSTRAINT tbl_product_uom_unique UNIQUE (product_uom)
);



-- public.pk_product_uom_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_product_uom_id_serial;

CREATE SEQUENCE public.pk_product_uom_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;