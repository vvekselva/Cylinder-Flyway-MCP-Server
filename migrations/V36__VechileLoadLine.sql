-- public.tbl_vehicle_load_line definition

-- Drop table

-- DROP TABLE public.tbl_vehicle_load_line;

CREATE TABLE public.tbl_vehicle_load_line (
	pk_vehicle_load_line_id int8 NOT NULL,
	fk_vehicle_load int8 NOT NULL,
	fk_cylinder int8 NOT NULL,
	loaded_at timestamp DEFAULT now() NULL,
	CONSTRAINT tbl_vehicle_load_line_pkey PRIMARY KEY (pk_vehicle_load_line_id),
	CONSTRAINT tbl_vehicle_load_line_tbl_cylinder_fk FOREIGN KEY (fk_cylinder) REFERENCES public.tbl_cylinder(pk_cylinder_id),
	CONSTRAINT tbl_vehicle_load_line_tbl_vehicle_load_fk FOREIGN KEY (fk_vehicle_load) REFERENCES public.tbl_vehicle_load(pk_vehicle_load_id)
);


-- public.pk_vehicle_load_line_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_vehicle_load_line_id_serial;

CREATE SEQUENCE public.pk_vehicle_load_line_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;
	
	
CREATE OR REPLACE FUNCTION fn_check_cylinder_is_full()
RETURNS TRIGGER AS $$
DECLARE
    v_full_state_id int8;
    v_current_state_id int8;
BEGIN
    -- 1. Identify the 'FULL' state ID
    SELECT pk_cylinder_state_id INTO v_full_state_id 
    FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL';

    -- 2. Find the most recent state in the audit log 
    SELECT fk_new_state INTO v_current_state_id
    FROM public.tbl_cylinder_state_audit
    WHERE fk_cylinder = NEW.fk_cylinder
    ORDER BY changed_at DESC, pk_audit_id DESC
    LIMIT 1;

    -- 3. Validation logic
    IF v_current_state_id IS DISTINCT FROM v_full_state_id THEN
        RAISE EXCEPTION 'Validation Failed: Cylinder % is not in FULL state.', NEW.fk_cylinder;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_01_check_full_before_insert
BEFORE INSERT ON public.tbl_vehicle_load_line
FOR EACH ROW EXECUTE FUNCTION fn_check_cylinder_is_full();



CREATE OR REPLACE FUNCTION fn_audit_cylinder_load_after()
RETURNS TRIGGER AS $$
DECLARE
    v_full_state_id int8;
    v_delivery_state_id int8;
BEGIN
    -- Fetch State IDs
    SELECT pk_cylinder_state_id INTO v_full_state_id 
    FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL';
    
    SELECT pk_cylinder_state_id INTO v_delivery_state_id 
    FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL_PICKED_UP_FOR_DELIVERY';

    -- Insert the audit trail using the requested values [cite: 66, 67]
    INSERT INTO public.tbl_cylinder_state_audit (
        pk_audit_id, 
        fk_cylinder, 
        fk_previous_state, 
        fk_new_state, 
        fk_order, 
        changed_at, 
        remarks
    )
    VALUES (
        nextval('public.pk_cylinder_state_id_serial'), 
        NEW.fk_cylinder, 
        v_full_state_id, 
        v_delivery_state_id, 
        NULL, 
        now(), 
        'Added the Audit State by Trigger'
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_02_audit_after_insert
AFTER INSERT ON public.tbl_vehicle_load_line
FOR EACH ROW EXECUTE FUNCTION fn_audit_cylinder_load_after();