-- =============================================================================
-- V56__SupplierRefillCollection_CustomerLocationTracking.sql
-- =============================================================================
--
-- ADDRESSES TWO GAPS:
--
-- GAP 1 — Supplier refilled cylinders are not tracked (Issues 1 & 2)
-- ─────────────────────────────────────────────────────────────────────────────
-- Current state of the refill cycle after V28/V45:
--
--   EMPTY → EMPTY_PICKED_FOR_REFILL
--     [V42 trigger: vehicle_load_line EMPTY_FOR_SUPPLIER]
--
--   EMPTY_PICKED_FOR_REFILL → EMPTY_DELIVERED_FOR_REFILL
--     [NO TRIGGER — stop at supplier not yet wired to state machine]
--
--   EMPTY_DELIVERED_FOR_REFILL → FULL_PICKED_FROM_SUPPLIER
--     [NO TABLE, NO TRIGGER — the gap this migration closes]
--
--   FULL_PICKED_FROM_SUPPLIER → FULL
--     [Expected at YARD_END reconciliation — not changed here]
--
-- Fix:
--   PART 1 — Link tbl_supplier_trip to tbl_vehicle_trip directly
--             (the DROPOFF trip). V45 added fk_vehicle_load; now add
--             fk_vehicle_trip for the same dropoff trip.
--
--   PART 2 — New table: tbl_supplier_refill_collection
--             Tracks the collection trip (a DIFFERENT, later trip) that
--             returns to the supplier to pick up the refilled cylinders.
--
--   PART 3 — New table: tbl_supplier_refill_collection_line
--             One row per cylinder collected. BEFORE-INSERT trigger validates
--             cylinder is in EMPTY_DELIVERED_FOR_REFILL. AFTER-INSERT trigger
--             transitions cylinder to FULL_PICKED_FROM_SUPPLIER and updates
--             tbl_cylinder_current_status.
--
--   PART 4 — Update tbl_supplier_trip_line: add fk_vehicle_trip_stop
--             so each dropoff line is linked to the exact SUPPLIER_DROPOFF stop
--             where that cylinder was physically handed to the supplier. This
--             also fires the EMPTY_PICKED_FOR_REFILL → EMPTY_DELIVERED_FOR_REFILL
--             state transition that had no trigger.
--
-- GAP 2 — Cylinder location at customer level is too coarse (Issue 2)
-- ─────────────────────────────────────────────────────────────────────────────
-- tbl_cylinder_current_status.fk_current_customer records the customer holding
-- the cylinder, but not WHICH of their addresses/locations.
-- A customer can have multiple delivery locations. After delivery we lose the
-- exact location.
--
-- Fix:
--   PART 5 — Add fk_current_customer_address to tbl_cylinder_current_status.
--   PART 6 — Update fn_audit_cylinder_delivery_after (V21 trigger) to also
--             populate fk_current_customer_address from tbl_order.fk_delivery_address.
--   PART 7 — Add fk_delivery_address to tbl_order_line so a single challan
--             can split deliveries across multiple addresses (multi-location order).
--             Each line records which exact address its cylinder was delivered to.
--             This overrides the header-level fk_delivery_address when populated.
--
-- ENTITY CHANGES (see Java files):
--   SupplierTripDo           + fk_vehicle_trip (dropoff trip)
--   SupplierTripLineDo       + fk_vehicle_trip_stop (exact stop)
--   SupplierRefillCollectionDo    NEW ENTITY
--   SupplierRefillCollectionLineDo NEW ENTITY
--   VehicleTripDo            + List<SupplierRefillCollectionDo> refillCollections
--   CylinderCurrentStatusDo  + fk_current_customer_address
--   OrderLineDo              + fk_delivery_address (nullable override)
-- =============================================================================


-- =============================================================================
-- PART 1  tbl_supplier_trip — direct link to the DROPOFF vehicle trip
-- =============================================================================
-- V45 added fk_vehicle_load. After V55 the correct parent is fk_vehicle_trip.
-- Keep fk_vehicle_load for backwards compatibility; add fk_vehicle_trip.

ALTER TABLE public.tbl_supplier_trip
    ADD COLUMN IF NOT EXISTS fk_vehicle_trip int8 NULL;

ALTER TABLE public.tbl_supplier_trip
    ADD CONSTRAINT tbl_supplier_trip_vehicle_trip_fk
    FOREIGN KEY (fk_vehicle_trip)
    REFERENCES public.tbl_vehicle_trip(pk_vehicle_trip_id);

-- Backfill via existing fk_vehicle_load → fk_vehicle_trip chain
UPDATE public.tbl_supplier_trip st
SET    fk_vehicle_trip = vl.fk_vehicle_trip
FROM   public.tbl_vehicle_load vl
WHERE  vl.pk_vehicle_load_id = st.fk_vehicle_load
AND    st.fk_vehicle_load IS NOT NULL;

CREATE INDEX idx_supplier_trip_vehicle_trip
    ON public.tbl_supplier_trip(fk_vehicle_trip)
    WHERE fk_vehicle_trip IS NOT NULL;

COMMENT ON COLUMN public.tbl_supplier_trip.fk_vehicle_trip IS
    'The vehicle trip on which empty cylinders were transported to the supplier '
    '(SUPPLIER_DROPOFF stop). Added in V56; previously only fk_vehicle_load existed.';


-- =============================================================================
-- PART 2  tbl_supplier_refill_collection  (NEW TABLE)
-- =============================================================================
-- Header for the collection event — a separate trip returns to the supplier
-- to collect cylinders that have been refilled.
-- One collection can pick up from one or more supplier_trip_line records.

DROP SEQUENCE IF EXISTS public.pk_supplier_refill_collection_id_serial;
CREATE SEQUENCE public.pk_supplier_refill_collection_id_serial
    INCREMENT BY 1 MINVALUE 1 START 1 CACHE 1 NO CYCLE;

CREATE TABLE public.tbl_supplier_refill_collection (
    pk_collection_id        int8         NOT NULL,
    collection_number       varchar(50)   NULL,

    -- Which supplier is handing back the refilled cylinders?
    fk_supplier             int8         NOT NULL,

    -- Which vehicle trip carried out this collection?
    fk_vehicle_trip         int8         NOT NULL,

    -- Optional: which supplier dropoff event is being fulfilled?
    -- NULL when collecting from multiple earlier dropoffs in one trip.
    fk_supplier_trip        int8         NULL,

    collection_date         date         NOT NULL,
    collected_by            varchar(200) NOT NULL,

    -- PENDING → IN_TRANSIT → RECEIVED → VERIFIED
    collection_status       varchar(50)  NOT NULL DEFAULT 'PENDING',

    remarks                 varchar(500) NULL,
    created_at              timestamp    NOT NULL DEFAULT now(),

    CONSTRAINT tbl_supplier_refill_collection_pk
        PRIMARY KEY (pk_collection_id),

    CONSTRAINT tbl_supplier_refill_collection_number_unique
        UNIQUE (collection_number),

    CONSTRAINT tbl_supplier_refill_collection_status_chk
        CHECK (collection_status IN ('PENDING','IN_TRANSIT','RECEIVED','VERIFIED')),

    CONSTRAINT tbl_supplier_refill_collection_supplier_fk
        FOREIGN KEY (fk_supplier)
        REFERENCES public.tbl_supplier(pk_supplier_id),

    CONSTRAINT tbl_supplier_refill_collection_vehicle_trip_fk
        FOREIGN KEY (fk_vehicle_trip)
        REFERENCES public.tbl_vehicle_trip(pk_vehicle_trip_id),

    CONSTRAINT tbl_supplier_refill_collection_supplier_trip_fk
        FOREIGN KEY (fk_supplier_trip)
        REFERENCES public.tbl_supplier_trip(pk_supplier_trip_id)
);

CREATE INDEX idx_refill_collection_vehicle_trip
    ON public.tbl_supplier_refill_collection(fk_vehicle_trip);

CREATE INDEX idx_refill_collection_supplier
    ON public.tbl_supplier_refill_collection(fk_supplier);

CREATE INDEX idx_refill_collection_status
    ON public.tbl_supplier_refill_collection(collection_status)
    WHERE collection_status NOT IN ('VERIFIED');

COMMENT ON TABLE public.tbl_supplier_refill_collection IS
    'Tracks the event where our vehicle returns to the supplier to collect '
    'cylinders that have been refilled. One collection per collection trip. '
    'Individual cylinders collected are in tbl_supplier_refill_collection_line.';


-- =============================================================================
-- PART 3  tbl_supplier_refill_collection_line  (NEW TABLE)
-- =============================================================================
-- One row per cylinder collected from the supplier.
-- References the original supplier_trip_line so the full chain is:
--   vehicle_load_line (empty picked up at yard)
--     → supplier_trip_line (empty handed to supplier)
--       → supplier_refill_collection_line (full cylinder collected from supplier)

DROP SEQUENCE IF EXISTS public.pk_supplier_refill_collection_line_id_serial;
CREATE SEQUENCE public.pk_supplier_refill_collection_line_id_serial
    INCREMENT BY 1 MINVALUE 1 START 1 CACHE 1 NO CYCLE;

CREATE TABLE public.tbl_supplier_refill_collection_line (
    pk_collection_line_id   int8         NOT NULL,
    fk_collection           int8         NOT NULL,

    -- Back-reference to the specific dropoff line this cylinder belongs to.
    -- Allows full traceability: this FULL cylinder was empty on this supplier trip.
    fk_supplier_trip_line   int8         NOT NULL,

    fk_cylinder             int8         NOT NULL,
    fk_product              int8         NOT NULL,

    -- Condition as observed on collection
    -- OK | DAMAGED | MISSING (supplier could not return)
    condition_on_collection varchar(20)  NOT NULL DEFAULT 'OK',

    collected_at            timestamp    NULL,

    CONSTRAINT tbl_supplier_refill_collection_line_pk
        PRIMARY KEY (pk_collection_line_id),

    -- A cylinder can only appear once per collection event
    CONSTRAINT tbl_supplier_refill_collection_line_unique
        UNIQUE (fk_collection, fk_cylinder),

    -- A supplier_trip_line can only be collected once
    CONSTRAINT tbl_supplier_refill_collection_line_trip_line_unique
        UNIQUE (fk_supplier_trip_line),

    CONSTRAINT tbl_refill_collection_line_condition_chk
        CHECK (condition_on_collection IN ('OK','DAMAGED','MISSING')),

    CONSTRAINT tbl_refill_collection_line_collection_fk
        FOREIGN KEY (fk_collection)
        REFERENCES public.tbl_supplier_refill_collection(pk_collection_id),

    CONSTRAINT tbl_refill_collection_line_supplier_trip_line_fk
        FOREIGN KEY (fk_supplier_trip_line)
        REFERENCES public.tbl_supplier_trip_line(pk_supplier_trip_line_id),

    CONSTRAINT tbl_refill_collection_line_cylinder_fk
        FOREIGN KEY (fk_cylinder)
        REFERENCES public.tbl_cylinder(pk_cylinder_id),

    CONSTRAINT tbl_refill_collection_line_product_fk
        FOREIGN KEY (fk_product)
        REFERENCES public.tbl_product(pk_product_id)
);

CREATE INDEX idx_refill_collection_line_collection
    ON public.tbl_supplier_refill_collection_line(fk_collection);

CREATE INDEX idx_refill_collection_line_cylinder
    ON public.tbl_supplier_refill_collection_line(fk_cylinder);

COMMENT ON TABLE public.tbl_supplier_refill_collection_line IS
    'One row per cylinder collected from the supplier after refilling. '
    'BEFORE-INSERT trigger validates cylinder state; AFTER-INSERT trigger '
    'transitions cylinder to FULL_PICKED_FROM_SUPPLIER.';


-- =============================================================================
-- PART 3a  BEFORE-INSERT trigger on tbl_supplier_refill_collection_line
-- =============================================================================
-- Validates: cylinder must be in EMPTY_DELIVERED_FOR_REFILL state.
-- This ensures only cylinders that were actually handed to the supplier can
-- be marked as collected.

CREATE OR REPLACE FUNCTION public.fn_check_cylinder_before_refill_collection()
RETURNS TRIGGER AS $$
DECLARE
    v_required_state_id int8;
    v_current_state_id  int8;
BEGIN
    SELECT pk_cylinder_state_id INTO v_required_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL';

    -- Fast path: current status table
    SELECT fk_current_state INTO v_current_state_id
    FROM public.tbl_cylinder_current_status
    WHERE fk_cylinder = NEW.fk_cylinder;

    -- Fallback: audit log
    IF v_current_state_id IS NULL THEN
        SELECT fk_new_state INTO v_current_state_id
        FROM public.tbl_cylinder_state_audit
        WHERE fk_cylinder = NEW.fk_cylinder
        ORDER BY changed_at DESC, pk_audit_id DESC
        LIMIT 1;
    END IF;

    IF v_current_state_id IS DISTINCT FROM v_required_state_id THEN
        RAISE EXCEPTION
            'Validation Failed: Cylinder % must be in EMPTY_DELIVERED_FOR_REFILL '
            'before it can be collected from the supplier. '
            'Current state id: %.',
            NEW.fk_cylinder, v_current_state_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_01_check_cylinder_before_refill_collection
BEFORE INSERT ON public.tbl_supplier_refill_collection_line
FOR EACH ROW EXECUTE FUNCTION public.fn_check_cylinder_before_refill_collection();


-- =============================================================================
-- PART 3b  AFTER-INSERT trigger on tbl_supplier_refill_collection_line
-- =============================================================================
-- On successful collection line insert:
--   1. Write audit: EMPTY_DELIVERED_FOR_REFILL → FULL_PICKED_FROM_SUPPLIER
--   2. Update tbl_cylinder_current_status:
--        fk_current_state     = FULL_PICKED_FROM_SUPPLIER
--        fk_current_vehicle_trip = the collection trip (in transit back to yard)
--        fk_current_customer  = NULL (no longer at supplier or customer)
--   3. Mark the supplier_trip_line as collected.

CREATE OR REPLACE FUNCTION public.fn_audit_cylinder_refill_collection_after()
RETURNS TRIGGER AS $$
DECLARE
    v_empty_delivered_state_id int8;
    v_full_picked_state_id     int8;
    v_collection_trip_id       int8;
BEGIN
    SELECT pk_cylinder_state_id INTO v_empty_delivered_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL';

    SELECT pk_cylinder_state_id INTO v_full_picked_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'FULL_PICKED_FROM_SUPPLIER';

    -- Get the vehicle trip from the collection header
    SELECT fk_vehicle_trip INTO v_collection_trip_id
    FROM public.tbl_supplier_refill_collection
    WHERE pk_collection_id = NEW.fk_collection;

    -- 1. State audit
    INSERT INTO public.tbl_cylinder_state_audit (
        pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
        fk_order, changed_at, remarks
    ) VALUES (
        nextval('public.pk_cylinder_state_id_serial'),
        NEW.fk_cylinder,
        v_empty_delivered_state_id,
        v_full_picked_state_id,
        NULL,
        COALESCE(NEW.collected_at, now()),
        'Cylinder collected from supplier after refilling. In transit to yard. '
            || 'Collection line: ' || NEW.pk_collection_line_id
    );

    -- 2. Update current status: cylinder is now on the vehicle in transit to yard
    UPDATE public.tbl_cylinder_current_status
    SET fk_current_state        = v_full_picked_state_id,
        fk_current_vehicle_trip = v_collection_trip_id,
        fk_current_customer     = NULL,
        updated_at              = now()
    WHERE fk_cylinder = NEW.fk_cylinder;

    -- 3. Mark the original supplier trip line as collected
    UPDATE public.tbl_supplier_trip_line
    SET collected    = TRUE,
        collected_at = COALESCE(NEW.collected_at, now())
    WHERE pk_supplier_trip_line_id = NEW.fk_supplier_trip_line;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_02_audit_cylinder_refill_collection_after
AFTER INSERT ON public.tbl_supplier_refill_collection_line
FOR EACH ROW EXECUTE FUNCTION public.fn_audit_cylinder_refill_collection_after();


-- =============================================================================
-- PART 4  tbl_supplier_trip_line — add fk_vehicle_trip_stop
-- =============================================================================
-- Each cylinder handed to the supplier was handed over at a specific
-- SUPPLIER_DROPOFF stop. Recording this enables:
--   a) The EMPTY_PICKED_FOR_REFILL → EMPTY_DELIVERED_FOR_REFILL state transition
--      to be fired when the stop is confirmed (ARRIVED → COMPLETED).
--   b) Full traceability: vehicle_load_line → trip_stop → supplier_trip_line
--      → supplier_refill_collection_line.

ALTER TABLE public.tbl_supplier_trip_line
    ADD COLUMN IF NOT EXISTS fk_vehicle_trip_stop int8 NULL;

ALTER TABLE public.tbl_supplier_trip_line
    ADD CONSTRAINT tbl_supplier_trip_line_vehicle_trip_stop_fk
    FOREIGN KEY (fk_vehicle_trip_stop)
    REFERENCES public.tbl_vehicle_trip_stop(pk_stop_id);

CREATE INDEX idx_supplier_trip_line_vehicle_trip_stop
    ON public.tbl_supplier_trip_line(fk_vehicle_trip_stop)
    WHERE fk_vehicle_trip_stop IS NOT NULL;

COMMENT ON COLUMN public.tbl_supplier_trip_line.fk_vehicle_trip_stop IS
    'The SUPPLIER_DROPOFF stop at which this cylinder was physically handed to '
    'the supplier. When this stop transitions to COMPLETED, a trigger should '
    'fire EMPTY_PICKED_FOR_REFILL → EMPTY_DELIVERED_FOR_REFILL for all '
    'supplier_trip_lines linked to this stop.';


-- =============================================================================
-- PART 4a  Trigger: SUPPLIER_DROPOFF stop COMPLETED → EMPTY_DELIVERED_FOR_REFILL
-- =============================================================================
-- When a SUPPLIER_DROPOFF stop's stop_status becomes COMPLETED, all cylinders
-- in tbl_supplier_trip_line linked to that stop transition:
--   EMPTY_PICKED_FOR_REFILL → EMPTY_DELIVERED_FOR_REFILL

CREATE OR REPLACE FUNCTION public.fn_audit_supplier_dropoff_stop_completed()
RETURNS TRIGGER AS $$
DECLARE
    v_stop_type_name           varchar(100);
    v_empty_picked_state_id    int8;
    v_empty_delivered_state_id int8;
    rec                        RECORD;
BEGIN
    -- Only fire on COMPLETED transition
    IF NEW.stop_status <> 'COMPLETED' THEN
        RETURN NEW;
    END IF;
    IF OLD.stop_status = 'COMPLETED' THEN
        RETURN NEW;  -- idempotent — already processed
    END IF;

    SELECT stop_type INTO v_stop_type_name
    FROM public.tbl_stop_type
    WHERE pk_stop_type_id = NEW.fk_stop_type;

    IF v_stop_type_name <> 'SUPPLIER_DROPOFF' THEN
        RETURN NEW;  -- only process SUPPLIER_DROPOFF stops
    END IF;

    SELECT pk_cylinder_state_id INTO v_empty_picked_state_id
    FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_PICKED_FOR_REFILL';

    SELECT pk_cylinder_state_id INTO v_empty_delivered_state_id
    FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL';

    -- For every supplier_trip_line linked to this stop, transition state
    FOR rec IN
        SELECT stl.fk_cylinder, stl.pk_supplier_trip_line_id
        FROM public.tbl_supplier_trip_line stl
        WHERE stl.fk_vehicle_trip_stop = NEW.pk_stop_id
    LOOP
        INSERT INTO public.tbl_cylinder_state_audit (
            pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
            fk_order, changed_at, remarks
        ) VALUES (
            nextval('public.pk_cylinder_state_id_serial'),
            rec.fk_cylinder,
            v_empty_picked_state_id,
            v_empty_delivered_state_id,
            NULL,
            now(),
            'Cylinder handed to supplier at SUPPLIER_DROPOFF stop '
                || NEW.pk_stop_id || '. Awaiting refill.'
        );

        UPDATE public.tbl_cylinder_current_status
        SET fk_current_state        = v_empty_delivered_state_id,
            fk_current_vehicle_trip = NULL,  -- no longer on vehicle
            updated_at              = now()
        WHERE fk_cylinder = rec.fk_cylinder;
    END LOOP;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_supplier_dropoff_stop_completed
AFTER UPDATE OF stop_status ON public.tbl_vehicle_trip_stop
FOR EACH ROW EXECUTE FUNCTION public.fn_audit_supplier_dropoff_stop_completed();


-- =============================================================================
-- PART 5  tbl_cylinder_current_status — add fk_current_customer_address
-- =============================================================================
-- Tracks the exact delivery location within a customer's locations.
-- Populated by trigger on tbl_order_line (updated in PART 6).
-- Cleared when the cylinder is picked up (empty pickup trigger sets it NULL).

ALTER TABLE public.tbl_cylinder_current_status
    ADD COLUMN IF NOT EXISTS fk_current_customer_address int8 NULL;

ALTER TABLE public.tbl_cylinder_current_status
    ADD CONSTRAINT tbl_cylinder_current_status_customer_address_fk
    FOREIGN KEY (fk_current_customer_address)
    REFERENCES public.tbl_customer_address(pk_customer_address_id);

CREATE INDEX idx_cylinder_current_status_customer_address
    ON public.tbl_cylinder_current_status(fk_current_customer_address)
    WHERE fk_current_customer_address IS NOT NULL;

COMMENT ON COLUMN public.tbl_cylinder_current_status.fk_current_customer_address IS
    'Exact delivery address within the customer where this cylinder currently sits. '
    'Set by fn_audit_cylinder_delivery_after on tbl_order_line INSERT. '
    'Uses order_line.fk_delivery_address if set, otherwise falls back to '
    'tbl_order.fk_delivery_address. Cleared to NULL on empty pickup.';

-- Also add fk_current_vehicle_trip if not already present (used by refill trigger above)
ALTER TABLE public.tbl_cylinder_current_status
    ADD COLUMN IF NOT EXISTS fk_current_vehicle_trip int8 NULL;

ALTER TABLE public.tbl_cylinder_current_status
    ADD CONSTRAINT tbl_cylinder_current_status_vehicle_trip_fk
    FOREIGN KEY (fk_current_vehicle_trip)
    REFERENCES public.tbl_vehicle_trip(pk_vehicle_trip_id);


-- =============================================================================
-- PART 6  Update fn_audit_cylinder_delivery_after to set customer address
-- =============================================================================
-- Original trigger (V21): fires after INSERT on tbl_order_line.
-- Adds: populate fk_current_customer AND fk_current_customer_address on
--       tbl_cylinder_current_status.
-- Address resolution order:
--   1. tbl_order_line.fk_delivery_address (line-level override — added in PART 7)
--   2. tbl_order.fk_delivery_address      (header-level fallback)

CREATE OR REPLACE FUNCTION fn_audit_cylinder_delivery_after()
RETURNS TRIGGER AS $$
DECLARE
    v_picked_up_state_id     int8;
    v_delivered_state_id     int8;
    v_customer_id            int8;
    v_delivery_address_id    int8;
BEGIN
    SELECT pk_cylinder_state_id INTO v_picked_up_state_id
    FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL_PICKED_UP_FOR_DELIVERY';

    SELECT pk_cylinder_state_id INTO v_delivered_state_id
    FROM public.tbl_cylinder_states WHERE cylinder_state = 'DELIVERED_FOR_CONSUMPTION';

    -- Resolve customer and delivery address:
    -- Line-level fk_delivery_address takes priority (multi-location challan)
    SELECT
        o.fk_customer,
        COALESCE(NEW.fk_delivery_address, o.fk_delivery_address)
    INTO v_customer_id, v_delivery_address_id
    FROM public.tbl_order o
    WHERE o.pk_order_id = NEW.fk_order;

    -- Audit trail
    INSERT INTO public.tbl_cylinder_state_audit (
        pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
        fk_order, changed_at, remarks
    ) VALUES (
        nextval('public.pk_cylinder_state_id_serial'),
        NEW.fk_cylinder,
        v_picked_up_state_id,
        v_delivered_state_id,
        NEW.fk_order,
        now(),
        'Cylinder delivered to customer. State updated by Order Line Trigger.'
    );

    -- Update current status — now also records exact customer address
    UPDATE public.tbl_cylinder_current_status
    SET fk_current_state            = v_delivered_state_id,
        fk_current_customer         = v_customer_id,
        fk_current_customer_address = v_delivery_address_id,
        fk_current_vehicle_trip     = NULL,   -- no longer on vehicle
        fk_current_vehicle_load     = NULL,
        updated_at                  = now()
    WHERE fk_cylinder = NEW.fk_cylinder;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- The existing trigger trg_02_audit_delivery_after_order already points to this
-- function via CREATE OR REPLACE — no need to DROP/CREATE the trigger.


-- =============================================================================
-- PART 7  tbl_order_line — add fk_delivery_address  (multi-location challan)
-- =============================================================================
-- A single delivery challan can list cylinders for multiple customer addresses.
-- When populated, this overrides tbl_order.fk_delivery_address for this line.
-- When NULL, the header-level address applies (standard single-location order).

ALTER TABLE public.tbl_order_line
    ADD COLUMN IF NOT EXISTS fk_delivery_address int8 NULL;

ALTER TABLE public.tbl_order_line
    ADD CONSTRAINT tbl_order_line_customer_address_fk
    FOREIGN KEY (fk_delivery_address)
    REFERENCES public.tbl_customer_address(pk_customer_address_id);

CREATE INDEX idx_order_line_delivery_address
    ON public.tbl_order_line(fk_delivery_address)
    WHERE fk_delivery_address IS NOT NULL;

COMMENT ON COLUMN public.tbl_order_line.fk_delivery_address IS
    'Optional per-line delivery address override. When set, this cylinder was '
    'delivered to a specific customer location that differs from the challan '
    'header (tbl_order.fk_delivery_address). Used when a single challan covers '
    'multiple delivery locations for the same customer. '
    'fn_audit_cylinder_delivery_after uses COALESCE(line.addr, header.addr).';


-- =============================================================================
-- PART 7a  Update fn_audit_empty_pickup_line_after (V44)
-- =============================================================================
-- When an empty is picked up, clear fk_current_customer_address on
-- tbl_cylinder_current_status — the cylinder is now in transit back to yard.

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

    -- Clear customer and address — cylinder is on the vehicle now
    UPDATE public.tbl_cylinder_current_status
    SET fk_current_state            = v_empty_in_transit_state_id,
        fk_current_customer         = NULL,
        fk_current_customer_address = NULL,
        updated_at                  = now()
    WHERE fk_cylinder = NEW.fk_cylinder;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Existing trigger trg_01_audit_empty_pickup_line_after points to this function.
