-- public.tbl_empty_pickup_line definition

-- Drop table

-- DROP TABLE public.tbl_empty_pickup_line;

CREATE TABLE public.tbl_empty_pickup_line (
	pk_pickup_line_id int8 NOT NULL,
	fk_empty_pickup int8 NOT NULL,
	fk_cylinder int8 NOT NULL,
	fk_product int8 NOT NULL,
	cylinder_condition varchar(50) NOT NULL,
	damage_description varchar(500) NULL,
	replacement_cylinder_id int8 NULL,
	replacement_provided bool DEFAULT false NOT NULL,
	CONSTRAINT tbl_empty_pickup_line_pk PRIMARY KEY (pk_pickup_line_id),
	CONSTRAINT tbl_empty_pickup_line_unique UNIQUE (fk_empty_pickup, fk_cylinder),
	CONSTRAINT tbl_empty_pickup_line_cylinder_fk FOREIGN KEY (fk_cylinder) REFERENCES public.tbl_cylinder(pk_cylinder_id),
	CONSTRAINT tbl_empty_pickup_line_pickup_fk FOREIGN KEY (fk_empty_pickup) REFERENCES public.tbl_empty_pickup(pk_pickup_id),
	CONSTRAINT tbl_empty_pickup_line_product_fk FOREIGN KEY (fk_product) REFERENCES public.tbl_product(pk_product_id),
	CONSTRAINT tbl_empty_pickup_line_replacement_fk FOREIGN KEY (replacement_cylinder_id) REFERENCES public.tbl_cylinder(pk_cylinder_id)
);


-- public.pk_empty_pickup_line_id_serial definition

DROP SEQUENCE IF EXISTS public.pk_empty_pickup_line_id_serial;

CREATE SEQUENCE public.pk_empty_pickup_line_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;