-- public.tbl_order definition

-- Drop table

-- DROP TABLE public.tbl_order;

CREATE TABLE public.tbl_order (
	pk_order_id int8 NOT NULL,
	challan_number varchar(50) NOT NULL,
	challan_date date NOT NULL,
	fk_challan_type int8 NOT NULL,
	fk_customer int8 NOT NULL,
	fk_delivery_address int8 NULL,
	fk_driver int8 NULL,
	fk_vehicle int8 NULL,
	order_status varchar(50) DEFAULT 'DRAFT'::character varying NOT NULL,
	remarks varchar(500) NULL,
	created_at timestamp DEFAULT now() NOT NULL,
	updated_at timestamp NULL,
	CONSTRAINT tbl_order_challan_number_unique UNIQUE (challan_number),
	CONSTRAINT tbl_order_pk PRIMARY KEY (pk_order_id),
	CONSTRAINT tbl_order_tbl_challan_type_fk FOREIGN KEY (fk_challan_type) REFERENCES public.tbl_challan_type(pk_challan_type_id),
	CONSTRAINT tbl_order_tbl_customer_address_fk FOREIGN KEY (fk_delivery_address) REFERENCES public.tbl_customer_address(pk_customer_address_id),
	CONSTRAINT tbl_order_tbl_customer_fk FOREIGN KEY (fk_customer) REFERENCES public.tbl_customer(pk_customer_id),
	CONSTRAINT tbl_order_tbl_driver_fk FOREIGN KEY (fk_driver) REFERENCES public.tbl_driver(pk_driver_id),
	CONSTRAINT tbl_order_tbl_vehicle_fk FOREIGN KEY (fk_vehicle) REFERENCES public.tbl_vehicle(pk_vehicle_id)
);


-- public.pk_order_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_order_id_serial;

CREATE SEQUENCE public.pk_order_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;