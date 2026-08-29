-- public.tbl_supplier_payment definition

-- Drop table

-- DROP TABLE public.tbl_supplier_payment;

CREATE TABLE public.tbl_supplier_payment (
	pk_supplier_payment_id int8 NOT NULL,
	fk_supplier int8 NOT NULL,
	payment_date date NOT NULL,
	payment_mode varchar(50) NOT NULL,
	payment_reference varchar(100) NULL,
	amount_paid numeric(12, 2) NOT NULL,
	payment_status varchar(50) DEFAULT 'COMPLETED'::character varying NOT NULL,
	remarks varchar(500) NULL,
	created_at timestamp DEFAULT now() NOT NULL,
	CONSTRAINT tbl_supplier_payment_pk PRIMARY KEY (pk_supplier_payment_id),
	CONSTRAINT tbl_supplier_payment_supplier_fk FOREIGN KEY (fk_supplier) REFERENCES public.tbl_supplier(pk_supplier_id)
);



-- public.pk_supplier_payment_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_supplier_payment_id_serial;

CREATE SEQUENCE public.pk_supplier_payment_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;