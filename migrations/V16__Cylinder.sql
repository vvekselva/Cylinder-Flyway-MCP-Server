-- public.tbl_cylinder definition

-- Drop table

-- DROP TABLE public.tbl_cylinder;

CREATE TABLE public.tbl_cylinder (
	pk_cylinder_id int8 NOT NULL,
	cylinder_serial varchar(50) NOT NULL,
	description varchar(100) NOT NULL,
	fk_uom int8 NOT NULL,
	total_quantity numeric(5, 2) NOT NULL,
	CONSTRAINT tbl_cylinder_pk PRIMARY KEY (pk_cylinder_id),
	CONSTRAINT tbl_cylinder_unique UNIQUE (cylinder_serial),
	CONSTRAINT tbl_cylinder_tbl_product_uom_fk FOREIGN KEY (fk_uom) REFERENCES public.tbl_product_uom(pk_product_uom_id)
);


-- public.pk_cylinder_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_cylinder_id_serial;

CREATE SEQUENCE public.pk_cylinder_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;
	
	
-- 1. Drop existing trigger and function if they exist to avoid conflicts
DROP TRIGGER IF EXISTS trg_on_cylinder_insertion ON public.tbl_cylinder;
DROP FUNCTION IF EXISTS public.fn_cylinder_lifecycle_logging();
DROP TRIGGER IF EXISTS trg_cylinder_state_on_insert ON public.tbl_cylinder;

-- 2. Audit Function logic
CREATE OR REPLACE FUNCTION public.fn_cylinder_state_lifecycle_logging()
RETURNS TRIGGER AS $$
DECLARE
    state_commissioned_id int8;
    state_empty_id        int8;
BEGIN
    -- 1. Fetch the IDs for the states (adjust the 'WHERE' clause based on your actual data)
    SELECT pk_cylinder_state_id INTO state_commissioned_id FROM public.tbl_cylinder_states WHERE cylinder_state = 'COMMISSIONED';
    SELECT pk_cylinder_state_id INTO state_empty_id FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY';

    -- 2. Transition 1: NULL to COMMISSIONED
    INSERT INTO public.tbl_cylinder_state_audit (
        pk_audit_id, 
        fk_cylinder, 
        fk_previous_state, 
        fk_new_state, 
        remarks
    )
    VALUES (
        nextval('public.pk_cylinder_state_id_serial'), -- Using your defined sequence
        NEW.pk_cylinder_id, 
        state_commissioned_id, 
        state_commissioned_id, 
        'Initial commissioning of cylinder'
    );

    -- 3. Transition 2: COMMISSIONED to EMPTY
    INSERT INTO public.tbl_cylinder_state_audit (
        pk_audit_id, 
        fk_cylinder, 
        fk_previous_state, 
        fk_new_state, 
        remarks
    )
    VALUES (
        nextval('public.pk_cylinder_state_id_serial'),
        NEW.pk_cylinder_id, 
        state_commissioned_id, 
        state_empty_id, 
        'Status activated to empty'
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
-- 3. Bind the new trigger to tbl_cylinder
CREATE TRIGGER trg_cylinder_state_on_insert
AFTER INSERT ON public.tbl_cylinder
FOR EACH ROW
EXECUTE FUNCTION public.fn_cylinder_state_lifecycle_logging();


ALTER TABLE public.tbl_cylinder ADD fk_product int8 NOT NULL;
ALTER TABLE public.tbl_cylinder ADD CONSTRAINT tbl_cylinder_tbl_product_fk FOREIGN KEY (fk_product) REFERENCES public.tbl_product(pk_product_id);
