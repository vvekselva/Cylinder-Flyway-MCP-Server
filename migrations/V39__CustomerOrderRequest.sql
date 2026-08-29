-- public.tbl_customer_order_request definition

-- Drop table

-- DROP TABLE public.tbl_customer_order_request;

CREATE TABLE public.tbl_customer_order_request (
	pk_customer_order_request_id int8 NOT NULL,
	request_number varchar(50) NOT NULL,
	fk_customer int8 NOT NULL,
	requested_date date NOT NULL,
	requested_cylinders int4 NOT NULL,
	fk_product int8 NOT NULL,
	fk_delivery_address int8 NULL,
	request_status varchar(50) DEFAULT 'PENDING'::character varying NOT NULL,
	fk_order int8 NULL,
	remarks varchar(500) NULL,
	received_by varchar(200) NOT NULL,
	created_at timestamp DEFAULT now() NOT NULL,
	updated_at timestamp NULL,
	CONSTRAINT tbl_customer_order_request_pk PRIMARY KEY (pk_customer_order_request_id),
	CONSTRAINT tbl_customer_order_request_unique UNIQUE (request_number),
	CONSTRAINT tbl_customer_order_request_address_fk FOREIGN KEY (fk_delivery_address) REFERENCES public.tbl_customer_address(pk_customer_address_id),
	CONSTRAINT tbl_customer_order_request_customer_fk FOREIGN KEY (fk_customer) REFERENCES public.tbl_customer(pk_customer_id),
	CONSTRAINT tbl_customer_order_request_order_fk FOREIGN KEY (fk_order) REFERENCES public.tbl_order(pk_order_id),
	CONSTRAINT tbl_customer_order_request_product_fk FOREIGN KEY (fk_product) REFERENCES public.tbl_product(pk_product_id)
);



 DROP SEQUENCE IF EXISTS public.pk_customer_order_request_id_serial;

CREATE SEQUENCE public.pk_customer_order_request_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1