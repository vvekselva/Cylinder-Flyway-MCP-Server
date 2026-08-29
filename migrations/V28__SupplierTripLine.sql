-- public.tbl_supplier_trip_line definition

-- Drop table

-- DROP TABLE public.tbl_supplier_trip_line;

CREATE TABLE public.tbl_supplier_trip_line (
	pk_supplier_trip_line_id int8 NOT NULL,
	fk_supplier_trip int8 NOT NULL,
	fk_cylinder int8 NOT NULL,
	fk_product int8 NOT NULL,
	collected bool DEFAULT false NOT NULL,
	collected_at timestamp NULL,
	CONSTRAINT tbl_supplier_trip_line_pk PRIMARY KEY (pk_supplier_trip_line_id),
	CONSTRAINT tbl_supplier_trip_line_unique UNIQUE (fk_supplier_trip, fk_cylinder),
	CONSTRAINT tbl_supplier_trip_line_cylinder_fk FOREIGN KEY (fk_cylinder) REFERENCES public.tbl_cylinder(pk_cylinder_id),
	CONSTRAINT tbl_supplier_trip_line_product_fk FOREIGN KEY (fk_product) REFERENCES public.tbl_product(pk_product_id),
	CONSTRAINT tbl_supplier_trip_line_trip_fk FOREIGN KEY (fk_supplier_trip) REFERENCES public.tbl_supplier_trip(pk_supplier_trip_id)
);


-- public.pk_supplier_trip_line_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_supplier_trip_line_id_serial;

CREATE SEQUENCE public.pk_supplier_trip_line_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;