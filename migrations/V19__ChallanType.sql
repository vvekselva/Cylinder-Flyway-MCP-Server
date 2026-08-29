-- public.tbl_challan_type definition

-- Drop table

-- DROP TABLE public.tbl_challan_type;

CREATE TABLE public.tbl_challan_type (
	pk_challan_type_id int8 NOT NULL,
	challan_type varchar(50) NOT NULL,
	description varchar(500) NOT NULL,
	CONSTRAINT tbl_challan_type_pk PRIMARY KEY (pk_challan_type_id),
	CONSTRAINT tbl_challan_type_unique UNIQUE (challan_type)
);


-- public.pk_challan_type_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_challan_type_id_serial;

CREATE SEQUENCE public.pk_challan_type_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;
	
INSERT INTO public.tbl_challan_type (pk_challan_type_id, challan_type, description)
VALUES
    (nextval('pk_challan_type_id_serial'), 'DELIVERY',     'Full cylinders dispatched to customer'),
    (nextval('pk_challan_type_id_serial'), 'EMPTY_PICKUP', 'Empty cylinders collected from customer');