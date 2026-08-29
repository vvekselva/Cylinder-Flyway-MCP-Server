-- public.tbl_order_line definition

-- Drop table

-- DROP TABLE public.tbl_order_line;

CREATE TABLE public.tbl_order_line (
	pk_order_line_id int8 NOT NULL,
	fk_order int8 NOT NULL,
	fk_cylinder int8 NOT NULL,
	fk_product int8 NOT NULL,
	quantity numeric(10, 3) NOT NULL,
	CONSTRAINT tbl_order_line_pk PRIMARY KEY (pk_order_line_id),
	CONSTRAINT tbl_order_line_unique UNIQUE (fk_order, fk_cylinder),
	CONSTRAINT tbl_order_line_tbl_cylinder_fk FOREIGN KEY (fk_cylinder) REFERENCES public.tbl_cylinder(pk_cylinder_id),
	CONSTRAINT tbl_order_line_tbl_order_fk FOREIGN KEY (fk_order) REFERENCES public.tbl_order(pk_order_id),
	CONSTRAINT tbl_order_line_tbl_product_fk FOREIGN KEY (fk_product) REFERENCES public.tbl_product(pk_product_id)
);

-- public.pk_order_line_id_serial definition

DROP SEQUENCE IF EXISTS public.pk_order_line_id_serial;

CREATE SEQUENCE public.pk_order_line_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;
	
CREATE OR REPLACE FUNCTION fn_check_cylinder_is_picked_up()
RETURNS TRIGGER AS $$
DECLARE
    v_picked_up_state_id int8;
    v_current_state_id   int8;
BEGIN
    -- 1. Identify the 'FULL_PICKED_UP_FOR_DELIVERY' state ID
    SELECT pk_cylinder_state_id INTO v_picked_up_state_id 
    FROM public.tbl_cylinder_states 
    WHERE cylinder_state = 'FULL_PICKED_UP_FOR_DELIVERY';

    -- 2. Find the most recent state in the audit log
    SELECT fk_new_state INTO v_current_state_id
    FROM public.tbl_cylinder_state_audit
    WHERE fk_cylinder = NEW.fk_cylinder
    ORDER BY changed_at DESC, pk_audit_id DESC
    LIMIT 1;

    -- 3. Validation logic
    IF v_current_state_id IS DISTINCT FROM v_picked_up_state_id THEN
        RAISE EXCEPTION 'Validation Failed: Cylinder % must be FULL_PICKED_UP_FOR_DELIVERY before ordering.', NEW.fk_cylinder;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_01_check_picked_up_before_order
BEFORE INSERT ON public.tbl_order_line
FOR EACH ROW EXECUTE FUNCTION fn_check_cylinder_is_picked_up();


CREATE OR REPLACE FUNCTION fn_audit_cylinder_delivery_after()
RETURNS TRIGGER AS $$
DECLARE
    v_picked_up_state_id int8;
    v_delivered_state_id int8;
BEGIN
    -- Fetch State IDs
    SELECT pk_cylinder_state_id INTO v_picked_up_state_id 
    FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL_PICKED_UP_FOR_DELIVERY';
    
    SELECT pk_cylinder_state_id INTO v_delivered_state_id 
    FROM public.tbl_cylinder_states WHERE cylinder_state = 'DELIVERED_FOR_CONSUMPTION';

    -- Insert the audit trail linking to the order ID
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
        v_picked_up_state_id, 
        v_delivered_state_id, 
        NEW.fk_order, 
        now(), 
        'Cylinder delivered to customer. State updated by Order Line Trigger.'
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_02_audit_delivery_after_order
AFTER INSERT ON public.tbl_order_line
FOR EACH ROW EXECUTE FUNCTION fn_audit_cylinder_delivery_after();