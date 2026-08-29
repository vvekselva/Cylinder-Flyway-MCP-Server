-- public.tbl_cylinder_deposit definition

-- Drop table

-- DROP TABLE public.tbl_cylinder_deposit;

CREATE TABLE public.tbl_cylinder_deposit (
	pk_deposit_id int8 NOT NULL,
	fk_customer int8 NOT NULL,
	deposit_amount numeric(10, 2) NOT NULL,
	deposit_date date NOT NULL,
	fk_deposit_status int8 NOT NULL,
	fk_invoice int8 NULL,
	refund_date date NULL,
	refund_amount numeric(10, 2) NULL,
	refund_remarks varchar(500) NULL,
	created_at timestamp DEFAULT now() NOT NULL,
	CONSTRAINT tbl_cylinder_deposit_pk PRIMARY KEY (pk_deposit_id),
	CONSTRAINT tbl_cylinder_deposit_unique UNIQUE (fk_customer),
	CONSTRAINT tbl_cylinder_deposit_customer_fk FOREIGN KEY (fk_customer) REFERENCES public.tbl_customer(pk_customer_id),
	CONSTRAINT tbl_cylinder_deposit_invoice_fk FOREIGN KEY (fk_invoice) REFERENCES public.tbl_invoice(pk_invoice_id),
	CONSTRAINT tbl_cylinder_deposit_status_fk FOREIGN KEY (fk_deposit_status) REFERENCES public.tbl_deposit_status(pk_deposit_status_id)
);

-- public.pk_cylinder_deposit_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_cylinder_deposit_id_serial;

CREATE SEQUENCE public.pk_cylinder_deposit_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;