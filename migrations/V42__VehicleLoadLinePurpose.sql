-- =============================================================================
-- V42__VehicleLoadPurpose.sql
-- =============================================================================
-- Introduces tbl_vehicle_load_purpose as a lookup table (mirrors the pattern
-- of tbl_cylinder_states) and adds fk_load_purpose to tbl_vehicle_load_line.
--
-- Three purposes cover the complete cylinder movement lifecycle on a vehicle:
--
--   FULL_FOR_DELIVERY      Yard → Customer   FULL → FULL_PICKED_UP_FOR_DELIVERY
--   EMPTY_FOR_SUPPLIER     Yard → Supplier   EMPTY → EMPTY_PICKED_FOR_REFILL
--   EMPTY_RETURNED_TO_YARD Customer → Yard   DELIVERED_FOR_CONSUMPTION
--                                              → EMPTY_IN_TRANSIT_TO_YARD
--
-- With all three purposes, tbl_vehicle_load_line is the single source of truth
-- for every cylinder movement on a vehicle.  tbl_empty_pickup_line becomes
-- the customer-side context record (condition, damages, replacement) rather
-- than a movement record.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- PART 1 — Lookup table
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE public.tbl_vehicle_load_purpose (
    pk_load_purpose_id  int8          NOT NULL,
    load_purpose        varchar(100)  NOT NULL,
    description         varchar(500)  NOT NULL,
    CONSTRAINT tbl_vehicle_load_purpose_pk     PRIMARY KEY (pk_load_purpose_id),
    CONSTRAINT tbl_vehicle_load_purpose_unique UNIQUE      (load_purpose)
);

DROP SEQUENCE IF EXISTS public.pk_load_purpose_id_serial;
CREATE SEQUENCE public.pk_load_purpose_id_serial
    INCREMENT BY 1 MINVALUE 1 START 1 CACHE 1 NO CYCLE;

INSERT INTO public.tbl_vehicle_load_purpose
    (pk_load_purpose_id, load_purpose, description)
VALUES
    (
        nextval('public.pk_load_purpose_id_serial'),
        'FULL_FOR_DELIVERY',
        'Full cylinder loaded at yard onto vehicle for delivery to a customer stop'
    ),
    (
        nextval('public.pk_load_purpose_id_serial'),
        'EMPTY_FOR_SUPPLIER',
        'Empty cylinder from yard loaded onto vehicle to be dropped at supplier for refill'
    ),
    (
        nextval('public.pk_load_purpose_id_serial'),
        'EMPTY_RETURNED_TO_YARD',
        'Empty cylinder picked up from customer loaded onto vehicle for return to yard for verification'
    );


-- ─────────────────────────────────────────────────────────────────────────────
-- PART 2 — Add FK column to tbl_vehicle_load_line
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.tbl_vehicle_load_line
    ADD COLUMN fk_load_purpose int8 NOT NULL
        REFERENCES public.tbl_vehicle_load_purpose(pk_load_purpose_id);

CREATE INDEX idx_vll_load_purpose
    ON public.tbl_vehicle_load_line(fk_load_purpose);


-- ─────────────────────────────────────────────────────────────────────────────
-- PART 3 — Replace validation trigger (BEFORE INSERT)
-- ─────────────────────────────────────────────────────────────────────────────
-- Each load purpose has exactly one required "from" state.
-- The trigger resolves the purpose name from the lookup table and then checks
-- the cylinder's current state against the required state.
-- Uses tbl_cylinder_current_status (V41) for the fast single-row lookup;
-- falls back to the audit table for any cylinder not yet in the status table.
-- ─────────────────────────────────────────────────────────────────────────────

DROP TRIGGER IF EXISTS trg_01_check_full_before_insert         ON public.tbl_vehicle_load_line;
DROP TRIGGER IF EXISTS trg_01_check_cylinder_before_vehicle_load ON public.tbl_vehicle_load_line;
DROP FUNCTION IF EXISTS public.fn_check_cylinder_before_vehicle_load();

CREATE OR REPLACE FUNCTION public.fn_check_cylinder_before_vehicle_load()
RETURNS TRIGGER AS $$
DECLARE
    v_purpose_name        varchar(100);
    v_required_state_name varchar(100);
    v_required_state_id   int8;
    v_current_state_id    int8;
BEGIN
    -- ── 1. Resolve the purpose name from the lookup table ──────────────────
    SELECT load_purpose
      INTO v_purpose_name
      FROM public.tbl_vehicle_load_purpose
     WHERE pk_load_purpose_id = NEW.fk_load_purpose;

    IF v_purpose_name IS NULL THEN
        RAISE EXCEPTION 'Unknown fk_load_purpose: %', NEW.fk_load_purpose;
    END IF;

    -- ── 2. Map purpose → required cylinder state ───────────────────────────
    v_required_state_name :=
        CASE v_purpose_name
            WHEN 'FULL_FOR_DELIVERY'       THEN 'FULL'
            WHEN 'EMPTY_FOR_SUPPLIER'      THEN 'EMPTY'
            WHEN 'EMPTY_RETURNED_TO_YARD'  THEN 'DELIVERED_FOR_CONSUMPTION'
            ELSE NULL
        END;

    IF v_required_state_name IS NULL THEN
        RAISE EXCEPTION
            'No required state mapping defined for load purpose "%". '
            'Add an entry to fn_check_cylinder_before_vehicle_load.',
            v_purpose_name;
    END IF;

    SELECT pk_cylinder_state_id
      INTO v_required_state_id
      FROM public.tbl_cylinder_states
     WHERE cylinder_state = v_required_state_name;

    -- ── 3. Get the cylinder's current state ────────────────────────────────
    -- Fast path: tbl_cylinder_current_status (V41)
    SELECT fk_current_state
      INTO v_current_state_id
      FROM public.tbl_cylinder_current_status
     WHERE fk_cylinder = NEW.fk_cylinder;

    -- Fallback: audit table (for cylinders not yet in the status table)
    IF v_current_state_id IS NULL THEN
        SELECT fk_new_state
          INTO v_current_state_id
          FROM public.tbl_cylinder_state_audit
         WHERE fk_cylinder = NEW.fk_cylinder
         ORDER BY changed_at DESC, pk_audit_id DESC
         LIMIT 1;
    END IF;

    -- ── 4. Validate ────────────────────────────────────────────────────────
    IF v_current_state_id IS DISTINCT FROM v_required_state_id THEN
        RAISE EXCEPTION
            'Validation Failed: Cylinder % must be in state "%" for load purpose "%".',
            NEW.fk_cylinder,
            v_required_state_name,
            v_purpose_name;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_01_check_cylinder_before_vehicle_load
BEFORE INSERT ON public.tbl_vehicle_load_line
FOR EACH ROW EXECUTE FUNCTION public.fn_check_cylinder_before_vehicle_load();


-- ─────────────────────────────────────────────────────────────────────────────
-- PART 4 — Replace audit trigger (AFTER INSERT)
-- ─────────────────────────────────────────────────────────────────────────────
-- Writes the correct state transition into tbl_cylinder_state_audit and then
-- patches fk_current_vehicle_load in tbl_cylinder_current_status.
--
-- Purpose → state transition:
--   FULL_FOR_DELIVERY      FULL                    → FULL_PICKED_UP_FOR_DELIVERY
--   EMPTY_FOR_SUPPLIER     EMPTY                   → EMPTY_PICKED_FOR_REFILL
--   EMPTY_RETURNED_TO_YARD DELIVERED_FOR_CONSUMPTION → EMPTY_IN_TRANSIT_TO_YARD
-- ─────────────────────────────────────────────────────────────────────────────

DROP TRIGGER IF EXISTS trg_02_audit_after_insert              ON public.tbl_vehicle_load_line;
DROP TRIGGER IF EXISTS trg_02_audit_after_vehicle_load_insert  ON public.tbl_vehicle_load_line;
DROP FUNCTION IF EXISTS public.fn_audit_cylinder_load_after();

CREATE OR REPLACE FUNCTION public.fn_audit_cylinder_load_after()
RETURNS TRIGGER AS $$
DECLARE
    v_purpose_name  varchar(100);
    v_prev_state    varchar(100);
    v_new_state     varchar(100);
    v_prev_state_id int8;
    v_new_state_id  int8;
BEGIN
    -- ── 1. Resolve purpose name ────────────────────────────────────────────
    SELECT load_purpose
      INTO v_purpose_name
      FROM public.tbl_vehicle_load_purpose
     WHERE pk_load_purpose_id = NEW.fk_load_purpose;

    -- ── 2. Map purpose → (previous state, new state) ──────────────────────
    CASE v_purpose_name
        WHEN 'FULL_FOR_DELIVERY' THEN
            v_prev_state := 'FULL';
            v_new_state  := 'FULL_PICKED_UP_FOR_DELIVERY';

        WHEN 'EMPTY_FOR_SUPPLIER' THEN
            v_prev_state := 'EMPTY';
            v_new_state  := 'EMPTY_PICKED_FOR_REFILL';

        WHEN 'EMPTY_RETURNED_TO_YARD' THEN
            v_prev_state := 'DELIVERED_FOR_CONSUMPTION';
            v_new_state  := 'EMPTY_IN_TRANSIT_TO_YARD';

        ELSE
            RAISE EXCEPTION
                'No state transition defined for load purpose "%". '
                'Add an entry to fn_audit_cylinder_load_after.',
                v_purpose_name;
    END CASE;

    SELECT pk_cylinder_state_id INTO v_prev_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = v_prev_state;

    SELECT pk_cylinder_state_id INTO v_new_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = v_new_state;

    -- ── 3. Write audit row ─────────────────────────────────────────────────
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
        v_prev_state_id,
        v_new_state_id,
        NULL,
        now(),
        'Vehicle load line inserted — purpose: ' || v_purpose_name
    );

    -- ── 4. Patch vehicle load reference in current status ──────────────────
    -- fn_sync_cylinder_current_status (V41) fires from the audit insert above
    -- and updates fk_current_state.  We patch fk_current_vehicle_load here
    -- because the audit trigger has no visibility of the vehicle_load_id.
    UPDATE public.tbl_cylinder_current_status
       SET fk_current_vehicle_load = NEW.fk_vehicle_load,
           updated_at              = now()
     WHERE fk_cylinder = NEW.fk_cylinder;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_02_audit_after_vehicle_load_insert
AFTER INSERT ON public.tbl_vehicle_load_line
FOR EACH ROW EXECUTE FUNCTION public.fn_audit_cylinder_load_after();


-- =============================================================================
-- QUICK REFERENCE
-- =============================================================================
--
-- Add a future load purpose (no DDL needed — just two steps):
--
--   1. INSERT INTO tbl_vehicle_load_purpose (...)
--      VALUES (nextval(...), 'NEW_PURPOSE', 'Description here');
--
--   2. Add a WHEN branch in both trigger functions:
--        fn_check_cylinder_before_vehicle_load  → add required state mapping
--        fn_audit_cylinder_load_after           → add (prev_state, new_state) mapping
--
-- =============================================================================