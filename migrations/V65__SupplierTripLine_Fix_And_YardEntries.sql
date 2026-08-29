-- =============================================================================
-- V65__SupplierTripLine_Fix_And_YardEntries.sql
-- =============================================================================
--
-- FIXES TWO GAPS IN THE CYLINDER STATE MACHINE:
--
-- ─────────────────────────────────────────────────────────────────────────────
-- FIX 1 — tbl_supplier_trip_line INSERT trigger was silently a no-op (Bug)
-- ─────────────────────────────────────────────────────────────────────────────
-- ROOT CAUSE (V63):
--   fn_audit_supplier_trip_line_insert() was written to transition:
--     EMPTY → EMPTY_PICKED_FOR_REFILL
--   But V42 (fn_audit_cylinder_load_after) ALREADY performs this transition
--   when the cylinder is loaded onto the vehicle with purpose EMPTY_FOR_SUPPLIER.
--   By the time a supplier_trip_line row is inserted, the cylinder is already
--   in EMPTY_PICKED_FOR_REFILL. V63's function detects this and hits its
--   early-return guard:
--
--       IF v_current_state_id = v_empty_picked_state_id THEN
--           RETURN NEW;   ← audit row is NEVER written
--       END IF;
--
--   Result: tbl_cylinder_state_audit is not updated. tbl_cylinder_current_status
--   is not updated. The cylinder appears to be on a vehicle indefinitely.
--
-- CORRECT FLOW (aligned with user-defined lifecycle):
--   Step 4-5 → tbl_vehicle_load_line (EMPTY_FOR_SUPPLIER purpose)
--               EMPTY → EMPTY_PICKED_FOR_REFILL          [V42 — unchanged]
--   Step 6-7 → tbl_supplier_trip_line INSERT
--               EMPTY_PICKED_FOR_REFILL → EMPTY_DELIVERED_FOR_REFILL  [THIS FIX]
--   Step 8-9 → tbl_supplier_refill_collection_line INSERT
--               EMPTY_DELIVERED_FOR_REFILL → FULL_PICKED_FROM_SUPPLIER [V56 — unchanged]
--   Step 10  → tbl_yard_entries INSERT
--               FULL_PICKED_FROM_SUPPLIER → FULL                       [THIS FIX]
--
-- SIDE EFFECT GUARDED:
--   V56 Part 4a (fn_audit_supplier_dropoff_stop_completed) also transitions
--   EMPTY_PICKED_FOR_REFILL → EMPTY_DELIVERED_FOR_REFILL on SUPPLIER_DROPOFF
--   stop completion. To avoid double audit rows, that function is updated to
--   skip cylinders already in EMPTY_DELIVERED_FOR_REFILL.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- FIX 2 — tbl_yard_entries does not exist
-- ─────────────────────────────────────────────────────────────────────────────
-- When a full cylinder (collected from a supplier refill trip) arrives at the
-- yard from the vehicle, it must be registered and its state transitioned:
--   FULL_PICKED_FROM_SUPPLIER → FULL
--
-- New table: tbl_yard_entries
--   One row per cylinder per yard arrival event.
--   Linked to the vehicle trip that carried it back.
--   BEFORE-INSERT trigger validates state.
--   AFTER-INSERT trigger writes audit + updates current status.
-- =============================================================================


-- =============================================================================
-- FIX 1a — Drop and replace fn_audit_supplier_trip_line_insert (V63)
-- =============================================================================

DROP TRIGGER IF EXISTS trg_01_audit_supplier_trip_line_insert ON public.tbl_supplier_trip_line;
DROP FUNCTION IF EXISTS public.fn_audit_supplier_trip_line_insert();

CREATE OR REPLACE FUNCTION public.fn_audit_supplier_trip_line_insert()
RETURNS TRIGGER AS $$
DECLARE
    v_empty_picked_state_id    int8;
    v_empty_delivered_state_id int8;
    v_current_state_id         int8;
    v_current_state_name       varchar(100);
    v_supplier_id              int8;
    v_supplier_vehicle_trip_id int8;
BEGIN
    -- ── Resolve state IDs ──────────────────────────────────────────────────
    SELECT pk_cylinder_state_id INTO v_empty_picked_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'EMPTY_PICKED_FOR_REFILL';

    SELECT pk_cylinder_state_id INTO v_empty_delivered_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL';

    -- ── Get current cylinder state ─────────────────────────────────────────
    -- Fast path: tbl_cylinder_current_status
    SELECT ccs.fk_current_state, cs.cylinder_state
    INTO v_current_state_id, v_current_state_name
    FROM public.tbl_cylinder_current_status ccs
    JOIN public.tbl_cylinder_states cs
        ON cs.pk_cylinder_state_id = ccs.fk_current_state
    WHERE ccs.fk_cylinder = NEW.fk_cylinder;

    -- Fallback: latest audit row (for cylinders without a current_status record)
    IF NOT FOUND THEN
        SELECT fk_new_state INTO v_current_state_id
        FROM public.tbl_cylinder_state_audit
        WHERE fk_cylinder = NEW.fk_cylinder
        ORDER BY changed_at DESC, pk_audit_id DESC
        LIMIT 1;

        SELECT cylinder_state INTO v_current_state_name
        FROM public.tbl_cylinder_states
        WHERE pk_cylinder_state_id = v_current_state_id;
    END IF;

    -- ── Validate ───────────────────────────────────────────────────────────
    -- Cylinder MUST be in EMPTY_PICKED_FOR_REFILL at this point.
    -- V42 (vehicle_load_line EMPTY_FOR_SUPPLIER) is responsible for the prior
    -- transition EMPTY → EMPTY_PICKED_FOR_REFILL.
    IF v_current_state_id IS DISTINCT FROM v_empty_picked_state_id THEN
        RAISE EXCEPTION
            'Validation Failed: Cylinder % must be in EMPTY_PICKED_FOR_REFILL state '
            'before it can be added to a supplier trip line. '
            'Ensure the cylinder was loaded onto a vehicle with purpose EMPTY_FOR_SUPPLIER first. '
            'Current state: [%]. Supplier trip: %.',
            NEW.fk_cylinder,
            COALESCE(v_current_state_name, 'UNKNOWN — no state record found'),
            NEW.fk_supplier_trip;
    END IF;

    -- ── Idempotent guard ───────────────────────────────────────────────────
    -- If somehow already in EMPTY_DELIVERED_FOR_REFILL (e.g. manual correction),
    -- skip the audit to avoid a duplicate row.
    IF v_current_state_id = v_empty_delivered_state_id THEN
        RETURN NEW;
    END IF;

    -- ── Resolve supplier and vehicle trip from the supplier trip header ────
    SELECT fk_supplier, fk_vehicle_trip
    INTO v_supplier_id, v_supplier_vehicle_trip_id
    FROM public.tbl_supplier_trip
    WHERE pk_supplier_trip_id = NEW.fk_supplier_trip;

    -- ── 1. Write state audit row ───────────────────────────────────────────
    --    EMPTY_PICKED_FOR_REFILL → EMPTY_DELIVERED_FOR_REFILL
    INSERT INTO public.tbl_cylinder_state_audit (
        pk_audit_id,
        fk_cylinder,
        fk_previous_state,
        fk_new_state,
        fk_order,
        changed_at,
        remarks
    ) VALUES (
        nextval('public.pk_cylinder_state_id_serial'),
        NEW.fk_cylinder,
        v_empty_picked_state_id,
        v_empty_delivered_state_id,
        NULL,
        now(),
        'Cylinder assigned to supplier trip line — physically delivered to supplier for refill. '
            || 'Supplier trip ID: ' || NEW.fk_supplier_trip
            || CASE WHEN v_supplier_id IS NOT NULL
                    THEN '. Supplier ID: ' || v_supplier_id
                    ELSE '' END
    );

    -- ── 2. Update current status ───────────────────────────────────────────
    --    - State          → EMPTY_DELIVERED_FOR_REFILL
    --    - Vehicle trip   → NULL  (cylinder is no longer on the vehicle)
    --    - Supplier       → the supplier now physically holding it
    --    - Last sup. trip → this supplier trip (lineage tracking)
    INSERT INTO public.tbl_cylinder_current_status (
        fk_cylinder,
        fk_current_state,
        fk_current_vehicle_trip,
        fk_current_holder_customer,
        fk_current_supplier,
        fk_last_supplier_trip,
        updated_at
    ) VALUES (
        NEW.fk_cylinder,
        v_empty_delivered_state_id,
        NULL,                       -- no longer on vehicle
        NULL,                       -- not at customer
        v_supplier_id,              -- now physically at supplier
        NEW.fk_supplier_trip,
        now()
    )
    ON CONFLICT (fk_cylinder) DO UPDATE
        SET fk_current_state            = v_empty_delivered_state_id,
            fk_current_vehicle_trip     = NULL,
            fk_current_holder_customer  = NULL,
            fk_current_supplier         = v_supplier_id,
            fk_last_supplier_trip       = NEW.fk_supplier_trip,
            fk_current_vehicle_load     = NULL,
            updated_at                  = now();

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_01_audit_supplier_trip_line_insert
AFTER INSERT ON public.tbl_supplier_trip_line
FOR EACH ROW
EXECUTE FUNCTION public.fn_audit_supplier_trip_line_insert();

COMMENT ON FUNCTION public.fn_audit_supplier_trip_line_insert() IS
    'Fires AFTER INSERT on tbl_supplier_trip_line. '
    'Transitions the cylinder: EMPTY_PICKED_FOR_REFILL → EMPTY_DELIVERED_FOR_REFILL. '
    'Validates that V42 (vehicle_load_line EMPTY_FOR_SUPPLIER trigger) has already run. '
    'Sets fk_current_supplier on tbl_cylinder_current_status. '
    'Clears fk_current_vehicle_trip (cylinder is now physically at the supplier). '
    'Fixed in V65: V63 incorrectly targeted EMPTY → EMPTY_PICKED_FOR_REFILL which '
    'caused the function to silently no-op on every real insert.';


-- =============================================================================
-- FIX 1b — Guard fn_audit_supplier_dropoff_stop_completed (V56/V63) against
--           double-transition now that supplier_trip_line fires first
-- =============================================================================
-- This function fires when a SUPPLIER_DROPOFF stop transitions to COMPLETED.
-- With FIX 1a, the supplier_trip_line trigger has already moved the cylinder to
-- EMPTY_DELIVERED_FOR_REFILL. This update adds a guard: cylinders already in
-- EMPTY_DELIVERED_FOR_REFILL are skipped (CONTINUE) rather than getting a
-- duplicate audit row.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_audit_supplier_dropoff_stop_completed()
RETURNS TRIGGER AS $$
DECLARE
    v_stop_type_name           varchar(100);
    v_empty_picked_state_id    int8;
    v_empty_delivered_state_id int8;
    rec                        RECORD;
BEGIN
    -- Only fire on the COMPLETED transition (idempotent guard)
    IF NEW.stop_status <> 'COMPLETED' THEN
        RETURN NEW;
    END IF;
    IF OLD.stop_status = 'COMPLETED' THEN
        RETURN NEW;
    END IF;

    SELECT stop_type INTO v_stop_type_name
    FROM public.tbl_stop_type
    WHERE pk_stop_type_id = NEW.fk_stop_type;

    IF v_stop_type_name <> 'SUPPLIER_DROPOFF' THEN
        RETURN NEW;
    END IF;

    SELECT pk_cylinder_state_id INTO v_empty_picked_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'EMPTY_PICKED_FOR_REFILL';

    SELECT pk_cylinder_state_id INTO v_empty_delivered_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL';

    FOR rec IN
        SELECT
            stl.fk_cylinder,
            stl.pk_supplier_trip_line_id,
            st.fk_supplier                   AS supplier_id,
            COALESCE(ccs.fk_current_state, 0) AS current_state_id  -- 0 = unknown
        FROM public.tbl_supplier_trip_line stl
        JOIN public.tbl_supplier_trip st
            ON st.pk_supplier_trip_id = stl.fk_supplier_trip
        LEFT JOIN public.tbl_cylinder_current_status ccs
            ON ccs.fk_cylinder = stl.fk_cylinder
        WHERE stl.fk_vehicle_trip_stop = NEW.pk_stop_id
    LOOP
        -- ── Guard: skip if already in EMPTY_DELIVERED_FOR_REFILL ─────────
        -- The supplier_trip_line INSERT trigger (fn_audit_supplier_trip_line_insert,
        -- V65) fires first and performs the same transition. Only write an audit row
        -- here if the cylinder was NOT reached by that path (e.g. a trip_line that
        -- was linked to a stop but never had a supplier_trip_line trigger run).
        IF rec.current_state_id = v_empty_delivered_state_id THEN
            CONTINUE;
        END IF;

        -- Only transition cylinders still in EMPTY_PICKED_FOR_REFILL
        IF rec.current_state_id <> v_empty_picked_state_id THEN
            CONTINUE;
        END IF;

        -- ── State audit ──────────────────────────────────────────────────
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
                || NEW.pk_stop_id
                || '. Supplier ID: ' || rec.supplier_id
                || '. Awaiting refill. (Fallback path via stop completion trigger.)'
        );

        -- ── Update current status ────────────────────────────────────────
        UPDATE public.tbl_cylinder_current_status
        SET fk_current_state        = v_empty_delivered_state_id,
            fk_current_vehicle_trip = NULL,
            fk_current_supplier     = rec.supplier_id,
            updated_at              = now()
        WHERE fk_cylinder = rec.fk_cylinder;
    END LOOP;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_audit_supplier_dropoff_stop_completed() IS
    'Fires AFTER UPDATE OF stop_status on tbl_vehicle_trip_stop when a '
    'SUPPLIER_DROPOFF stop transitions to COMPLETED. '
    'V65 update: cylinders already in EMPTY_DELIVERED_FOR_REFILL are now skipped '
    '(they were already transitioned by fn_audit_supplier_trip_line_insert). '
    'This function now acts as a fallback for cylinders not covered by the '
    'supplier_trip_line path.';


-- =============================================================================
-- FIX 2 — CREATE tbl_yard_entries
-- =============================================================================
-- Records the arrival of a cylinder at the yard from a vehicle trip.
-- Each row represents one cylinder entering the yard.
--
-- Trigger chain on INSERT:
--   BEFORE → fn_check_cylinder_before_yard_entry
--             Validates: cylinder must be in FULL_PICKED_FROM_SUPPLIER state.
--   AFTER  → fn_audit_cylinder_yard_entry_after
--             Transitions: FULL_PICKED_FROM_SUPPLIER → FULL
--             Updates tbl_cylinder_current_status: clears vehicle/supplier context.
-- =============================================================================

DROP SEQUENCE IF EXISTS public.pk_yard_entry_id_serial;
CREATE SEQUENCE public.pk_yard_entry_id_serial
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 9223372036854775807
    START 1
    CACHE 1
    NO CYCLE;

CREATE TABLE public.tbl_yard_entries (
    pk_yard_entry_id    int8          NOT NULL DEFAULT nextval('public.pk_yard_entry_id_serial'),

    -- Which cylinder arrived at the yard?
    fk_cylinder         int8          NOT NULL,

    -- Which vehicle trip brought it back from the supplier?
    -- NULL if the cylinder was walked in without a registered trip.
    fk_vehicle_trip     int8          NULL,

    -- When did it physically arrive at the yard?
    entry_date          timestamp     NOT NULL DEFAULT now(),

    -- Who received and logged it at the yard?
    received_by         varchar(200)  NULL,

    remarks             varchar(500)  NULL,

    CONSTRAINT tbl_yard_entries_pk
        PRIMARY KEY (pk_yard_entry_id),

    CONSTRAINT tbl_yard_entries_cylinder_fk
        FOREIGN KEY (fk_cylinder)
        REFERENCES public.tbl_cylinder(pk_cylinder_id),

    CONSTRAINT tbl_yard_entries_vehicle_trip_fk
        FOREIGN KEY (fk_vehicle_trip)
        REFERENCES public.tbl_vehicle_trip(pk_vehicle_trip_id)
);

CREATE INDEX idx_yard_entries_cylinder
    ON public.tbl_yard_entries(fk_cylinder);

CREATE INDEX idx_yard_entries_vehicle_trip
    ON public.tbl_yard_entries(fk_vehicle_trip)
    WHERE fk_vehicle_trip IS NOT NULL;

CREATE INDEX idx_yard_entries_date
    ON public.tbl_yard_entries(entry_date DESC);

COMMENT ON TABLE public.tbl_yard_entries IS
    'Records the physical arrival of a cylinder at the yard from a vehicle trip. '
    'One row per cylinder per arrival event. '
    'BEFORE-INSERT trigger validates cylinder is in FULL_PICKED_FROM_SUPPLIER state. '
    'AFTER-INSERT trigger transitions cylinder to FULL and clears transit context. '
    'This is the final step in the supplier refill cycle before the cylinder is '
    'available for the next customer delivery.';

COMMENT ON COLUMN public.tbl_yard_entries.fk_vehicle_trip IS
    'The vehicle trip (collection trip from supplier) that transported this cylinder '
    'back to the yard. Should match the fk_vehicle_trip on the corresponding '
    'tbl_supplier_refill_collection row. NULL = cylinder arrived without a trip record.';


-- =============================================================================
-- FIX 2a — BEFORE INSERT trigger on tbl_yard_entries
-- =============================================================================
-- Validates that the cylinder is in FULL_PICKED_FROM_SUPPLIER state before
-- allowing it to be registered as a yard entry. Prevents data errors where a
-- cylinder in an invalid state is logged as arriving at the yard.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_check_cylinder_before_yard_entry()
RETURNS TRIGGER AS $$
DECLARE
    v_required_state_id  int8;
    v_current_state_id   int8;
    v_current_state_name varchar(100);
BEGIN
    SELECT pk_cylinder_state_id INTO v_required_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'FULL_PICKED_FROM_SUPPLIER';

    -- Fast path: tbl_cylinder_current_status
    SELECT ccs.fk_current_state, cs.cylinder_state
    INTO v_current_state_id, v_current_state_name
    FROM public.tbl_cylinder_current_status ccs
    JOIN public.tbl_cylinder_states cs
        ON cs.pk_cylinder_state_id = ccs.fk_current_state
    WHERE ccs.fk_cylinder = NEW.fk_cylinder;

    -- Fallback: audit log
    IF NOT FOUND THEN
        SELECT fk_new_state INTO v_current_state_id
        FROM public.tbl_cylinder_state_audit
        WHERE fk_cylinder = NEW.fk_cylinder
        ORDER BY changed_at DESC, pk_audit_id DESC
        LIMIT 1;

        SELECT cylinder_state INTO v_current_state_name
        FROM public.tbl_cylinder_states
        WHERE pk_cylinder_state_id = v_current_state_id;
    END IF;

    IF v_current_state_id IS DISTINCT FROM v_required_state_id THEN
        RAISE EXCEPTION
            'Validation Failed: Cylinder % must be in FULL_PICKED_FROM_SUPPLIER state '
            'before it can be entered into the yard. '
            'Ensure tbl_supplier_refill_collection_line was inserted for this cylinder first. '
            'Current state: [%].',
            NEW.fk_cylinder,
            COALESCE(v_current_state_name, 'UNKNOWN — no state record found');
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_01_check_cylinder_before_yard_entry
BEFORE INSERT ON public.tbl_yard_entries
FOR EACH ROW
EXECUTE FUNCTION public.fn_check_cylinder_before_yard_entry();

COMMENT ON FUNCTION public.fn_check_cylinder_before_yard_entry() IS
    'Fires BEFORE INSERT on tbl_yard_entries. '
    'Validates: cylinder must be in FULL_PICKED_FROM_SUPPLIER state. '
    'This ensures the full refill cycle (vehicle_load_line → supplier_trip_line → '
    'supplier_refill_collection_line) was completed before the yard entry is logged.';


-- =============================================================================
-- FIX 2b — AFTER INSERT trigger on tbl_yard_entries
-- =============================================================================
-- On successful yard entry:
--   1. Write audit row: FULL_PICKED_FROM_SUPPLIER → FULL
--   2. Update tbl_cylinder_current_status:
--        fk_current_state        = FULL
--        fk_current_vehicle_trip = NULL (no longer in transit)
--        fk_current_supplier     = NULL (no longer at supplier)
--        fk_current_vehicle_load = NULL (cleared)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_audit_cylinder_yard_entry_after()
RETURNS TRIGGER AS $$
DECLARE
    v_full_picked_state_id int8;
    v_full_state_id        int8;
BEGIN
    SELECT pk_cylinder_state_id INTO v_full_picked_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'FULL_PICKED_FROM_SUPPLIER';

    SELECT pk_cylinder_state_id INTO v_full_state_id
    FROM public.tbl_cylinder_states
    WHERE cylinder_state = 'FULL';

    -- ── 1. Write state audit row ───────────────────────────────────────────
    --    FULL_PICKED_FROM_SUPPLIER → FULL
    INSERT INTO public.tbl_cylinder_state_audit (
        pk_audit_id,
        fk_cylinder,
        fk_previous_state,
        fk_new_state,
        fk_order,
        changed_at,
        remarks
    ) VALUES (
        nextval('public.pk_cylinder_state_id_serial'),
        NEW.fk_cylinder,
        v_full_picked_state_id,
        v_full_state_id,
        NULL,
        COALESCE(NEW.entry_date, now()),
        'Full cylinder arrived at yard and registered. '
            || CASE
                WHEN NEW.fk_vehicle_trip IS NOT NULL
                THEN 'Vehicle trip ID: ' || NEW.fk_vehicle_trip || '. '
                ELSE 'No vehicle trip linked. '
               END
            || CASE
                WHEN NEW.received_by IS NOT NULL
                THEN 'Received by: ' || NEW.received_by || '.'
                ELSE ''
               END
    );

    -- ── 2. Update current status ───────────────────────────────────────────
    --    Cylinder is now in the yard, FULL, and ready for the next delivery.
    --    All transit and supplier context is cleared.
    UPDATE public.tbl_cylinder_current_status
    SET fk_current_state            = v_full_state_id,
        fk_current_vehicle_trip     = NULL,    -- no longer in transit
        fk_current_supplier         = NULL,    -- no longer at supplier
        fk_current_vehicle_load     = NULL,    -- no active load
        fk_current_holder_customer  = NULL,    -- not at customer
        updated_at                  = now()
    WHERE fk_cylinder = NEW.fk_cylinder;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_02_audit_cylinder_yard_entry_after
AFTER INSERT ON public.tbl_yard_entries
FOR EACH ROW
EXECUTE FUNCTION public.fn_audit_cylinder_yard_entry_after();

COMMENT ON FUNCTION public.fn_audit_cylinder_yard_entry_after() IS
    'Fires AFTER INSERT on tbl_yard_entries. '
    'Transitions cylinder: FULL_PICKED_FROM_SUPPLIER → FULL. '
    'Clears fk_current_vehicle_trip, fk_current_supplier, fk_current_vehicle_load. '
    'Cylinder is now in yard and available for the next delivery cycle. '
    'This is the terminal step of the supplier refill lifecycle.';


-- =============================================================================
-- QUICK REFERENCE — Complete Cylinder State Machine (Supplier Refill Cycle)
-- =============================================================================
--
--  EVENT                            TABLE INSERTED INTO                  FROM STATE                    → TO STATE
--  ───────────────────────────────  ───────────────────────────────────  ────────────────────────────  ──────────────────────────
--  1. Cylinder added                tbl_cylinder                         NULL                          → COMMISSIONED → EMPTY
--                                                                                                         (V16 trigger, two audit rows)
--  2. Loaded onto vehicle           tbl_vehicle_load_line                EMPTY                         → EMPTY_PICKED_FOR_REFILL
--     (purpose: EMPTY_FOR_SUPPLIER) (with fk_load_purpose = EMPTY_FOR_SUPPLIER)                          (V42 trigger)
--  3. Assigned to supplier trip     tbl_supplier_trip_line               EMPTY_PICKED_FOR_REFILL       → EMPTY_DELIVERED_FOR_REFILL
--                                                                                                         (V65 trigger — THIS FILE)
--  4. Refill collected from supplier tbl_supplier_refill_collection_line EMPTY_DELIVERED_FOR_REFILL    → FULL_PICKED_FROM_SUPPLIER
--                                                                                                         (V56 trigger)
--  5. Arrived at yard               tbl_yard_entries                     FULL_PICKED_FROM_SUPPLIER     → FULL
--                                                                                                         (V65 trigger — THIS FILE)
--  6. Loaded for customer delivery  tbl_vehicle_load_line                FULL                          → FULL_PICKED_UP_FOR_DELIVERY
--     (purpose: FULL_FOR_DELIVERY)  (with fk_load_purpose = FULL_FOR_DELIVERY)                           (V42 trigger)
-- =============================================================================
