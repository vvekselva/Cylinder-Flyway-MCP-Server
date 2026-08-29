-- public.tbl_invoice definition

-- Drop table

-- DROP TABLE public.tbl_invoice;

CREATE TABLE public.tbl_invoice (
	pk_invoice_id int8 NOT NULL,
	invoice_number varchar(50) NOT NULL,
	invoice_date date NOT NULL,
	fk_customer int8 NOT NULL,
	billing_month int2 NOT NULL,
	billing_year int4 NOT NULL,
	invoice_status varchar(50) DEFAULT 'DRAFT'::character varying NOT NULL,
	taxable_amount numeric(12, 2) DEFAULT 0 NOT NULL,
	igst_amount numeric(12, 2) NULL,
	cgst_amount numeric(12, 2) NULL,
	sgst_amount numeric(12, 2) NULL,
	total_amount numeric(12, 2) DEFAULT 0 NOT NULL,
	paid_amount numeric(12, 2) DEFAULT 0 NOT NULL,
	balance_amount numeric(12, 2) GENERATED ALWAYS AS ((total_amount - paid_amount)) STORED NULL,
	remarks varchar(500) NULL,
	created_at timestamp DEFAULT now() NOT NULL,
	updated_at timestamp NULL,
	CONSTRAINT tbl_invoice_month_unique UNIQUE (fk_customer, billing_month, billing_year),
	CONSTRAINT tbl_invoice_pk PRIMARY KEY (pk_invoice_id),
	CONSTRAINT tbl_invoice_unique UNIQUE (invoice_number),
	CONSTRAINT tbl_invoice_customer_fk FOREIGN KEY (fk_customer) REFERENCES public.tbl_customer(pk_customer_id)
);



-- public.pk_invoice_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_invoice_id_serial;

CREATE SEQUENCE public.pk_invoice_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;