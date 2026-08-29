-- public.tbl_cylinder_state_audit definition

-- Drop table

-- DROP TABLE public.tbl_cylinder_state_audit;

CREATE TABLE public.tbl_cylinder_state_audit (
	pk_audit_id int8 NOT NULL,
	fk_cylinder int8 NOT NULL,
	fk_previous_state int8 NULL,
	fk_new_state int8 NOT NULL,
	fk_order int8 NULL,
	changed_at timestamp DEFAULT now() NOT NULL,
	remarks varchar(500) NULL,
	CONSTRAINT tbl_cylinder_state_audit_pk PRIMARY KEY (pk_audit_id),
	CONSTRAINT tbl_cyl_audit_cylinder_fk FOREIGN KEY (fk_cylinder) REFERENCES public.tbl_cylinder(pk_cylinder_id),
	CONSTRAINT tbl_cyl_audit_new_state_fk FOREIGN KEY (fk_new_state) REFERENCES public.tbl_cylinder_states(pk_cylinder_state_id),
	CONSTRAINT tbl_cyl_audit_order_fk FOREIGN KEY (fk_order) REFERENCES public.tbl_order(pk_order_id),
	CONSTRAINT tbl_cyl_audit_prev_state_fk FOREIGN KEY (fk_previous_state) REFERENCES public.tbl_cylinder_states(pk_cylinder_state_id)
);


-- public.pk_cylinder_state_id_serial definition

--DROP SEQUENCE IF EXISTS public.pk_cylinder_state_audit_id_serial;

CREATE SEQUENCE public.pk_cylinder_state_audit_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;
	
	
