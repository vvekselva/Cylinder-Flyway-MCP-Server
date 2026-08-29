-- public.tbl_yard_stock_check_line definition

-- Drop table

-- DROP TABLE public.tbl_yard_stock_check_line;

CREATE TABLE public.tbl_yard_stock_check_line (
	pk_stock_check_line_id int8 NOT NULL,
	fk_stock_check int8 NOT NULL,
	fk_cylinder int8 NOT NULL,
	scanned_at timestamp DEFAULT now() NOT NULL,
	CONSTRAINT tbl_yard_stock_check_line_pk PRIMARY KEY (pk_stock_check_line_id),
	CONSTRAINT tbl_yard_stock_check_line_unique UNIQUE (fk_stock_check, fk_cylinder),
	CONSTRAINT tbl_yard_stock_check_line_check_fk FOREIGN KEY (fk_stock_check) REFERENCES public.tbl_yard_stock_check(pk_stock_check_id),
	CONSTRAINT tbl_yard_stock_check_line_cylinder_fk FOREIGN KEY (fk_cylinder) REFERENCES public.tbl_cylinder(pk_cylinder_id)
);


-- public.pk_stock_check_line_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_stock_check_line_id_serial;

CREATE SEQUENCE public.pk_stock_check_line_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;