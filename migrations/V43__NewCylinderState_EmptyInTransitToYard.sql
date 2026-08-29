
-- ---------------------------------------------------------------------------
-- CHANGE B: New cylinder state — EMPTY_IN_TRANSIT_TO_YARD
-- ---------------------------------------------------------------------------
-- When a driver picks up an empty cylinder FROM A CUSTOMER during a delivery
-- trip, it is physically on the vehicle heading back to yard.
-- This is distinct from EMPTY (which means it is already verified in the yard).
-- ---------------------------------------------------------------------------
-- V43__NewCylinderState_EmptyInTransitToYard.sql



INSERT INTO public.tbl_cylinder_states
		(pk_cylinder_state_id, cylinder_state, description, location)
	VALUES
		(nextval('public.pk_cylinder_state_id_serial'),
		 'EMPTY_IN_TRANSIT_TO_YARD',
		 'Empty cylinder collected from customer, on vehicle returning to yard for verification',
		 'In Transit'),
		(nextval('public.pk_cylinder_state_id_serial'),
		 'MISSING',
		 'Cylinder reported missing after tally — not physically located anywhere in the system',
		 'Unknown');