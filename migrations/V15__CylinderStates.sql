-- public.tbl_cylinder_states definition

-- Drop table

-- DROP TABLE public.tbl_cylinder_states;

CREATE TABLE public.tbl_cylinder_states (
	pk_cylinder_state_id int8 NOT NULL,
	cylinder_state varchar(100) NOT NULL,
	description varchar(500) NOT NULL,
	CONSTRAINT tbl_cylinder_states_pk PRIMARY KEY (pk_cylinder_state_id),
	CONSTRAINT tbl_cylinder_states_unique UNIQUE (cylinder_state)
);


-- public.pk_cylinder_state_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_cylinder_state_id_serial;

CREATE SEQUENCE public.pk_cylinder_state_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;
	
	
	-- Insert cylinder states into tbl_cylinder_states
	
INSERT INTO public.tbl_cylinder_states (pk_cylinder_state_id, cylinder_state, description)
VALUES (nextval('public.pk_cylinder_state_id_serial'), 'COMMISSIONED', 'Cylinder is Purchased and can be used for business purposes');

INSERT INTO public.tbl_cylinder_states (pk_cylinder_state_id, cylinder_state, description)
VALUES (nextval('public.pk_cylinder_state_id_serial'), 'EMPTY', 'Cylinder is empty and ready for refill');


INSERT INTO public.tbl_cylinder_states (pk_cylinder_state_id, cylinder_state, description)
VALUES (nextval('public.pk_cylinder_state_id_serial'), 'EMPTY_PICKED_FOR_REFILL', 'Empty cylinder delivered to supplier for refill');

INSERT INTO public.tbl_cylinder_states (pk_cylinder_state_id, cylinder_state, description)
VALUES (nextval('public.pk_cylinder_state_id_serial'), 'EMPTY_DELIVERED_FOR_REFILL', 'Empty cylinder delivered to supplier for refill');

INSERT INTO public.tbl_cylinder_states (pk_cylinder_state_id, cylinder_state, description)
VALUES (nextval('public.pk_cylinder_state_id_serial'), 'FULL_PICKED_FROM_SUPPLIER', 'Full cylinder picked up from supplier');

INSERT INTO public.tbl_cylinder_states (pk_cylinder_state_id, cylinder_state, description)
VALUES (nextval('public.pk_cylinder_state_id_serial'), 'FULL', 'Cylinder is full and available for use');

INSERT INTO public.tbl_cylinder_states (pk_cylinder_state_id, cylinder_state, description)
VALUES (nextval('public.pk_cylinder_state_id_serial'), 'FULL_PICKED_UP_FOR_DELIVERY', 'Full cylinder picked up for delivery to customer');

INSERT INTO public.tbl_cylinder_states (pk_cylinder_state_id, cylinder_state, description)
VALUES (nextval('public.pk_cylinder_state_id_serial'), 'DELIVERED_FOR_CONSUMPTION', 'Cylinder delivered to customer for consumption');

INSERT INTO public.tbl_cylinder_states (pk_cylinder_state_id, cylinder_state, description)
VALUES (nextval('public.pk_cylinder_state_id_serial'), 'EMPTY_PICKED_UP_FROM_SUPPLIER', 'Empty cylinder picked up from supplier');

INSERT INTO public.tbl_cylinder_states (pk_cylinder_state_id, cylinder_state, description)
VALUES (nextval('public.pk_cylinder_state_id_serial'), 'DAMAGED', 'Cylinder returned in damaged condition');

INSERT INTO public.tbl_cylinder_states (pk_cylinder_state_id, cylinder_state, description)
VALUES (nextval('public.pk_cylinder_state_id_serial'), 'LOST', 'Cylinder lost and not returned');

INSERT INTO public.tbl_cylinder_states (pk_cylinder_state_id, cylinder_state, description)
VALUES (nextval('public.pk_cylinder_state_id_serial'), 'DECOMISSIONED', 'Cylinder is taken out of service');





ALTER TABLE public.tbl_cylinder_states
    ADD COLUMN location varchar(100) NOT NULL DEFAULT '';

UPDATE public.tbl_cylinder_states SET location = 'Unknown'           WHERE cylinder_state = 'COMISSIONED';
UPDATE public.tbl_cylinder_states SET location = 'Yard'              WHERE cylinder_state = 'EMPTY';
UPDATE public.tbl_cylinder_states SET location = 'In Transit'        WHERE cylinder_state = 'EMPTY_PICKED_FOR_REFILL';
UPDATE public.tbl_cylinder_states SET location = 'Supplier Location'        WHERE cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL';
UPDATE public.tbl_cylinder_states SET location = 'In Transit'        WHERE cylinder_state = 'FULL_PICKED_FROM_SUPPLIER';
UPDATE public.tbl_cylinder_states SET location = 'Yard'              WHERE cylinder_state = 'FULL';
UPDATE public.tbl_cylinder_states SET location = 'In Transit'        WHERE cylinder_state = 'FULL_PICKED_UP_FOR_DELIVERY';
UPDATE public.tbl_cylinder_states SET location = 'Customer Location' WHERE cylinder_state = 'DELIVERED_FOR_CONSUMPTION';
UPDATE public.tbl_cylinder_states SET location = 'In Transit'        WHERE cylinder_state = 'EMPTY_PICKED_UP_FROM_SUPPLIER';
UPDATE public.tbl_cylinder_states SET location = 'In Transit'        WHERE cylinder_state = 'EMPTY_PICKED_UP_FROM_CUSTOMER';
UPDATE public.tbl_cylinder_states SET location = 'In Transit'        WHERE cylinder_state = 'DAMAGED';
UPDATE public.tbl_cylinder_states SET location = 'Customer Location' WHERE cylinder_state = 'LOST';
UPDATE public.tbl_cylinder_states SET location = 'SCRAP' WHERE cylinder_state = 'DECOMISSIONED';
