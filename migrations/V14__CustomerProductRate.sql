-- public.tb_customer_product_rates definition

-- Drop table

-- DROP TABLE public.tb_customer_product_rates;

CREATE TABLE public.tb_customer_product_rates (
	pk_customer_product_rate_id int8 NOT NULL,
	fk_customer int8 NULL,
	fk_product int8 NULL,
	rate_per_uom numeric(10, 2) NOT NULL,
	CONSTRAINT tb_customer_product_rates_pk PRIMARY KEY (pk_customer_product_rate_id),
	CONSTRAINT tb_customer_product_rates_tbl_customer_fk FOREIGN KEY (fk_customer) REFERENCES public.tbl_customer(pk_customer_id),
	CONSTRAINT tb_customer_product_rates_tbl_product_fk FOREIGN KEY (fk_product) REFERENCES public.tbl_product(pk_product_id)
);



-- public.pk_customer_product_rate_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_customer_product_rate_id_serial;

CREATE SEQUENCE public.pk_customer_product_rate_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;