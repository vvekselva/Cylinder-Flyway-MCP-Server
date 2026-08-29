-- public.tbl_yard_stock_variance definition

-- Drop table

-- DROP TABLE public.tbl_yard_stock_variance;

CREATE TABLE public.tbl_yard_stock_variance (
	pk_variance_id int8 NOT NULL,
	fk_stock_check int8 NOT NULL,
	fk_cylinder int8 NOT NULL,
	variance_type varchar(50) NOT NULL,
	system_state varchar(100) NOT NULL,
	system_location varchar(100) NOT NULL,
	variance_status varchar(50) DEFAULT 'OPEN'::character varying NOT NULL,
	resolution_remarks varchar(500) NULL,
	raised_at timestamp DEFAULT now() NOT NULL,
	resolved_at timestamp NULL,
	CONSTRAINT tbl_yard_stock_variance_pk PRIMARY KEY (pk_variance_id),
	CONSTRAINT tbl_yard_stock_variance_check_fk FOREIGN KEY (fk_stock_check) REFERENCES public.tbl_yard_stock_check(pk_stock_check_id),
	CONSTRAINT tbl_yard_stock_variance_cylinder_fk FOREIGN KEY (fk_cylinder) REFERENCES public.tbl_cylinder(pk_cylinder_id)
);


-- public.pk_stock_yard_variance_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_stock_yard_variance_id_serial;

CREATE SEQUENCE public.pk_stock_yard_variance_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;
	
UPDATE tbl_yard_stock_variance
SET
    variance_status    = 'RESOLVED',
    resolution_remarks = 'Found in back storage — state corrected',
    resolved_at        = now()
WHERE pk_variance_id = 2;