-- public.tbl_yard_stock_check definition

-- Drop table

-- DROP TABLE public.tbl_yard_stock_check;

CREATE TABLE public.tbl_yard_stock_check (
	pk_stock_check_id int8 NOT NULL,
	check_date date NOT NULL,
	checked_by varchar(200) NOT NULL,
	check_status varchar(50) DEFAULT 'IN_PROGRESS'::character varying NOT NULL,
	remarks varchar(500) NULL,
	created_at timestamp DEFAULT now() NOT NULL,
	completed_at timestamp NULL,
	CONSTRAINT tbl_yard_stock_check_date_unique UNIQUE (check_date),
	CONSTRAINT tbl_yard_stock_check_pk PRIMARY KEY (pk_stock_check_id)
);


-- public.pk_stock_check_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_stock_check_id_serial;

CREATE SEQUENCE public.pk_stock_check_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;