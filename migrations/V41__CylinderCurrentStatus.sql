-- V41__CylinderCurrentStatus.sql

CREATE TABLE public.tbl_cylinder_current_status (
    fk_cylinder             int8        NOT NULL,
    fk_current_state        int8        NOT NULL,

    -- Who physically holds it right now?
    -- NULL  → Yard / In-Transit (not at a customer site)
    -- value → the customer who currently has the cylinder
    fk_current_holder_customer int8     NULL,

    -- Which vehicle is it on right now (while in transit)?
    -- NULL once it reaches its destination
    fk_current_vehicle_load    int8     NULL,

    -- Which order placed it at the customer (last delivery)?
    -- Useful for invoice / deposit reconciliation
    fk_last_order              int8     NULL,

    -- Which supplier trip took it for refill?
    fk_last_supplier_trip      int8     NULL,

    updated_at              timestamp   NOT NULL DEFAULT now(),

    CONSTRAINT tbl_cyl_cur_status_pk
        PRIMARY KEY (fk_cylinder),

    CONSTRAINT tbl_cyl_cur_status_cylinder_fk
        FOREIGN KEY (fk_cylinder)
        REFERENCES public.tbl_cylinder(pk_cylinder_id),

    CONSTRAINT tbl_cyl_cur_status_state_fk
        FOREIGN KEY (fk_current_state)
        REFERENCES public.tbl_cylinder_states(pk_cylinder_state_id),

    CONSTRAINT tbl_cyl_cur_status_customer_fk
        FOREIGN KEY (fk_current_holder_customer)
        REFERENCES public.tbl_customer(pk_customer_id),

    CONSTRAINT tbl_cyl_cur_status_vehicle_load_fk
        FOREIGN KEY (fk_current_vehicle_load)
        REFERENCES public.tbl_vehicle_load(pk_vehicle_load_id),

    CONSTRAINT tbl_cyl_cur_status_order_fk
        FOREIGN KEY (fk_last_order)
        REFERENCES public.tbl_order(pk_order_id),

    CONSTRAINT tbl_cyl_cur_status_supplier_trip_fk
        FOREIGN KEY (fk_last_supplier_trip)
        REFERENCES public.tbl_supplier_trip(pk_supplier_trip_id)
);

-- Index for customer-holding queries (Problem 2 answer)
CREATE INDEX idx_cyl_cur_status_customer
    ON public.tbl_cylinder_current_status(fk_current_holder_customer)
    WHERE fk_current_holder_customer IS NOT NULL;

-- Index for vehicle-load queries (what is on this vehicle right now?)
CREATE INDEX idx_cyl_cur_status_vehicle_load
    ON public.tbl_cylinder_current_status(fk_current_vehicle_load)
    WHERE fk_current_vehicle_load IS NOT NULL;

-- Index for state-based filtering (find all EMPTY cylinders in yard)
CREATE INDEX idx_cyl_cur_status_state
    ON public.tbl_cylinder_current_status(fk_current_state);

-- ---------------------------------------------------------------------------
-- TRIGGER: keep tbl_cylinder_current_status in sync with tbl_cylinder_state_audit
-- ---------------------------------------------------------------------------
-- Every time a row is inserted into tbl_cylinder_state_audit the trigger below
-- performs an UPSERT on tbl_cylinder_current_status.
-- The trigger uses the audit's fk_order to decide:
--   • If the new state is DELIVERED_FOR_CONSUMPTION  → set the holder customer
--   • If the new state is EMPTY / FULL / yard state  → clear holder customer
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_sync_cylinder_current_status()
RETURNS TRIGGER AS $$
DECLARE
    v_customer_id   int8 := NULL;
    v_state_name    varchar(100);
BEGIN
    -- Resolve the customer from the order (if an order is attached)
    IF NEW.fk_order IS NOT NULL THEN
        SELECT fk_customer INTO v_customer_id
        FROM public.tbl_order
        WHERE pk_order_id = NEW.fk_order;
    END IF;

    -- Resolve the state name so we can make routing decisions
    SELECT cylinder_state INTO v_state_name
    FROM public.tbl_cylinder_states
    WHERE pk_cylinder_state_id = NEW.fk_new_state;

    -- Clear customer when cylinder leaves customer premises
    IF v_state_name NOT IN ('DELIVERED_FOR_CONSUMPTION', 'LOST') THEN
        v_customer_id := NULL;
    END IF;

    INSERT INTO public.tbl_cylinder_current_status (
        fk_cylinder,
        fk_current_state,
        fk_current_holder_customer,
        fk_last_order,
        updated_at
    )
    VALUES (
        NEW.fk_cylinder,
        NEW.fk_new_state,
        v_customer_id,
        NEW.fk_order,
        now()
    )
    ON CONFLICT (fk_cylinder) DO UPDATE
        SET fk_current_state            = EXCLUDED.fk_current_state,
            fk_current_holder_customer  = EXCLUDED.fk_current_holder_customer,
            fk_last_order               = EXCLUDED.fk_last_order,
            updated_at                  = EXCLUDED.updated_at;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sync_current_status_after_audit
AFTER INSERT ON public.tbl_cylinder_state_audit
FOR EACH ROW
EXECUTE FUNCTION public.fn_sync_cylinder_current_status();

-- ---------------------------------------------------------------------------
-- QUERY EXAMPLES — after this change
-- ---------------------------------------------------------------------------

-- Problem 1 answer: current state of any cylinder (single-row lookup, no join)
--   SELECT cs.cylinder_state
--   FROM   tbl_cylinder_current_status ccs
--   JOIN   tbl_cylinder_states cs ON cs.pk_cylinder_state_id = ccs.fk_current_state
--   WHERE  ccs.fk_cylinder = :cylinderId;

-- Problem 2 answer: all cylinders currently held by a customer
--   SELECT c.cylinder_serial, cs.cylinder_state
--   FROM   tbl_cylinder_current_status ccs
--   JOIN   tbl_cylinder c  ON c.pk_cylinder_id   = ccs.fk_cylinder
--   JOIN   tbl_cylinder_states cs ON cs.pk_cylinder_state_id = ccs.fk_current_state
--   WHERE  ccs.fk_current_holder_customer = :customerId;
