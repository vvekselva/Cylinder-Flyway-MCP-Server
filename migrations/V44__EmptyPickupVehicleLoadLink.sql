-- ---------------------------------------------------------------------------
-- CHANGE C: tbl_empty_pickup — link to vehicle load and order (delivery stop)
-- ---------------------------------------------------------------------------
-- The empty pickup at a customer now happens during a delivery trip.
-- Link it to the vehicle_load (the trip) and the order (the specific stop)
-- so the full movement chain is traceable without extra joins.
-- ---------------------------------------------------------------------------
-- V44__EmptyPickupVehicleLoadLink.sql

-- Which delivery trip was the vehicle on when these empties were picked up?
ALTER TABLE public.tbl_empty_pickup
    ADD COLUMN fk_vehicle_load int8 NULL;

ALTER TABLE public.tbl_empty_pickup
    ADD CONSTRAINT tbl_empty_pickup_vehicle_load_fk
    FOREIGN KEY (fk_vehicle_load)
    REFERENCES public.tbl_vehicle_load(pk_vehicle_load_id);

-- Which delivery challan (customer stop) triggered this pickup?
ALTER TABLE public.tbl_empty_pickup
    ADD COLUMN fk_order int8 NULL;

ALTER TABLE public.tbl_empty_pickup
    ADD CONSTRAINT tbl_empty_pickup_order_fk
    FOREIGN KEY (fk_order)
    REFERENCES public.tbl_order(pk_order_id);

-- Where are these empties being routed? (Enforcement of Rule 1)
ALTER TABLE public.tbl_empty_pickup
    ADD COLUMN pickup_destination varchar(50) NOT NULL DEFAULT 'YARD';

ALTER TABLE public.tbl_empty_pickup
    ADD CONSTRAINT chk_empty_pickup_destination
    CHECK (pickup_destination IN ('YARD'));
--  Customer pickups ALWAYS go to YARD. Yard→Supplier is SupplierTrip's job.
--  The CHECK constraint enforces the business rule at the DB level.

-- Index: "what empties were collected during trip X?"
CREATE INDEX idx_empty_pickup_vehicle_load
    ON public.tbl_empty_pickup(fk_vehicle_load)
    WHERE fk_vehicle_load IS NOT NULL;

-- Index: "what empties were picked up at this delivery stop?"
CREATE INDEX idx_empty_pickup_order
    ON public.tbl_empty_pickup(fk_order)
    WHERE fk_order IS NOT NULL;

-- ---------------------------------------------------------------------------
-- UPDATE TRIGGER on tbl_empty_pickup_line:
-- write EMPTY_IN_TRANSIT_TO_YARD state when a line is inserted
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION fn_audit_empty_pickup_line_after()
RETURNS TRIGGER AS $$
DECLARE
    v_delivered_state_id        int8;
    v_empty_in_transit_state_id int8;
BEGIN
    SELECT pk_cylinder_state_id INTO v_delivered_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'DELIVERED_FOR_CONSUMPTION';

    SELECT pk_cylinder_state_id INTO v_empty_in_transit_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'EMPTY_IN_TRANSIT_TO_YARD';

    INSERT INTO public.tbl_cylinder_state_audit (
        pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
        fk_order, changed_at, remarks
    ) VALUES (
        nextval('public.pk_cylinder_state_id_serial'),
        NEW.fk_cylinder,
        v_delivered_state_id,
        v_empty_in_transit_state_id,
        (SELECT fk_order FROM public.tbl_empty_pickup WHERE pk_pickup_id = NEW.fk_empty_pickup),
        now(),
        'Empty cylinder picked up from customer. In transit to yard.'
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- NOTE: If a trigger already exists on tbl_empty_pickup_line, extend it
-- or drop and recreate. Shown here as a new trigger.
CREATE TRIGGER trg_01_audit_empty_pickup_line_after
AFTER INSERT ON public.tbl_empty_pickup_line
FOR EACH ROW EXECUTE FUNCTION fn_audit_empty_pickup_line_after();

