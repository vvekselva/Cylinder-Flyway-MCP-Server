-- public.tbl_product definition

-- Drop table

-- DROP TABLE public.tbl_product;

CREATE TABLE public.tbl_product (
	pk_product_id int8 NOT NULL,
	product_name varchar(100) NOT NULL,
	description varchar(500) NOT NULL,
	igst_rate numeric(3, 2) NOT NULL,
	cgst_rate numeric(3, 2) NULL,
	sgst_rate numeric(3, 2) NULL,
	fk_product_category int8 NULL,
	fk_product_uom int8 NULL,
	CONSTRAINT tbl_product_pk PRIMARY KEY (pk_product_id),
	CONSTRAINT tbl_product_unique UNIQUE (product_name),
	CONSTRAINT tbl_product_tbl_product_category_fk FOREIGN KEY (fk_product_category) REFERENCES public.tbl_product_category(pk_product_category_id),
	CONSTRAINT tbl_product_tbl_product_uom_fk FOREIGN KEY (fk_product_uom) REFERENCES public.tbl_product_uom(pk_product_uom_id)
);



-- public.pk_product_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_product_id_serial;

CREATE SEQUENCE public.pk_product_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;
	
	
	
ALTER TABLE public.tbl_product ALTER COLUMN igst_rate TYPE numeric(5, 2) USING igst_rate::numeric(5, 2);
ALTER TABLE public.tbl_product ALTER COLUMN cgst_rate TYPE numeric(5, 2) USING cgst_rate::numeric(5, 2);
ALTER TABLE public.tbl_product ALTER COLUMN sgst_rate TYPE numeric(5, 2) USING sgst_rate::numeric(5, 2);
