-- public.tbl_product_category definition

-- Drop table

-- DROP TABLE public.tbl_product_category;

CREATE TABLE public.tbl_product_category (
	pk_product_category_id int8 NOT NULL,
	product_category varchar(100) NOT NULL,
	description varchar(500) NOT NULL,
	CONSTRAINT tbl_product_category_pk PRIMARY KEY (pk_product_category_id),
	CONSTRAINT tbl_product_category_unique UNIQUE (product_category)
);


-- public.pk_product_category_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_product_category_id_serial;

CREATE SEQUENCE public.pk_product_category_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;