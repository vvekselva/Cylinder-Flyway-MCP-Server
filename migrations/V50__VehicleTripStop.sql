
-- =============================================================================
-- V50 — tbl_vehicle_trip_stop  (Core new table)
-- =============================================================================
-- One row per waypoint per trip.
-- Replaces tbl_supplier_trip entirely — SUPPLIER_DROPOFF stops carry
-- fk_supplier and supplier_reference instead.
--
-- Stop lifecycle:  PLANNED → ARRIVED → TALLY_PENDING → COMPLETED
--                                                 └── VARIANCE_PENDING (if tally mismatch)
--
-- PLANNED        : Stop is part of the trip plan, vehicle not yet there
-- ARRIVED        : Driver has confirmed arrival; activity (delivery/pickup) begins
-- TALLY_PENDING  : Activity done; waiting for driver to record physical cylinder count
-- VARIANCE_PENDING: Tally submitted but count does not match expected; blocked until
--                   supervisor acknowledges
-- COMPLETED      : Tally matched (or variance acknowledged); vehicle may depart
--
-- FIX (V50): PostgreSQL does not allow subqueries inside CHECK constraints
-- (SQL State 0A000).  The original tbl_trip_stop_yard_start_seq_chk constraint
-- used a SELECT subquery to look up the YARD_START stop_type id, which is
-- illegal.  That constraint has been removed from the CREATE TABLE and is now
-- enforced by the BEFORE INSERT OR UPDATE trigger
-- trg_check_yard_start_sequence defined at the bottom of this file.
-- =============================================================================

DROP SEQUENCE IF EXISTS public.pk_trip_stop_id_serial;
CREATE SEQUENCE public.pk_trip_stop_id_serial
    INCREMENT BY 1 MINVALUE 1 START 1 CACHE 1 NO CYCLE;

CREATE TABLE public.tbl_vehicle_trip_stop (
    pk_stop_id              int8         NOT NULL,
    fk_vehicle_load         int8         NOT NULL,   -- which trip
    stop_sequence           int4         NOT NULL,   -- 1 = YARD_START (always)
    fk_stop_type            int8         NOT NULL,

    -- ── Contextual columns (one set populated per stop_type) ─────────────────
    -- CUSTOMER_DELIVERY
    fk_customer             int8         NULL,
    fk_delivery_address     int8         NULL,
    fk_order                int8         NULL,       -- delivery challan for this stop

    -- SUPPLIER_DROPOFF  (replaces tbl_supplier_trip header columns)
    fk_supplier             int8         NULL,
    supplier_reference      varchar(50)  NULL,       -- supplier's own reference / DO number
    dropoff_date            date         NULL,

    -- ── Timing ───────────────────────────────────────────────────────────────
    planned_arrive_at       timestamp    NULL,
    arrived_at              timestamp    NULL,
    departed_at             timestamp    NULL,

    -- ── Status ───────────────────────────────────────────────────────────────
    stop_status             varchar(50)  NOT NULL DEFAULT 'PLANNED',

    -- ── Constraints ──────────────────────────────────────────────────────────
    CONSTRAINT tbl_trip_stop_pk
        PRIMARY KEY (pk_stop_id),

    CONSTRAINT tbl_trip_stop_sequence_unique
        UNIQUE (fk_vehicle_load, stop_sequence),

    CONSTRAINT tbl_trip_stop_status_chk
        CHECK (stop_status IN
            ('PLANNED', 'ARRIVED', 'TALLY_PENDING', 'VARIANCE_PENDING', 'COMPLETED')),

    -- NOTE: tbl_trip_stop_yard_start_seq_chk has been intentionally removed.
    -- PostgreSQL forbids subqueries inside CHECK constraints (ERROR 0A000).
    -- The equivalent business rule is enforced by the trigger
    -- trg_check_yard_start_sequence defined below.

    CONSTRAINT tbl_trip_stop_vehicle_load_fk
        FOREIGN KEY (fk_vehicle_load)
        REFERENCES public.tbl_vehicle_load(pk_vehicle_load_id),

    CONSTRAINT tbl_trip_stop_stop_type_fk
        FOREIGN KEY (fk_stop_type)
        REFERENCES public.tbl_stop_type(pk_stop_type_id),

    CONSTRAINT tbl_trip_stop_customer_fk
        FOREIGN KEY (fk_customer)
        REFERENCES public.tbl_customer(pk_customer_id),

    CONSTRAINT tbl_trip_stop_address_fk
        FOREIGN KEY (fk_delivery_address)
        REFERENCES public.tbl_customer_address(pk_customer_address_id),

    CONSTRAINT tbl_trip_stop_order_fk
        FOREIGN KEY (fk_order)
        REFERENCES public.tbl_order(pk_order_id),

    CONSTRAINT tbl_trip_stop_supplier_fk
        FOREIGN KEY (fk_supplier)
        REFERENCES public.tbl_supplier(pk_supplier_id)
);

CREATE INDEX idx_trip_stop_vehicle_load
    ON public.tbl_vehicle_trip_stop(fk_vehicle_load, stop_sequence);

CREATE INDEX idx_trip_stop_type
    ON public.tbl_vehicle_trip_stop(fk_stop_type);

CREATE INDEX idx_trip_stop_status
    ON public.tbl_vehicle_trip_stop(stop_status)
    WHERE stop_status NOT IN ('COMPLETED');

-- =============================================================================
-- TRIGGER: enforce YARD_START must always be stop_sequence = 1
-- =============================================================================
-- Replaces the illegal subquery CHECK constraint that was originally written as:
--
--   CONSTRAINT tbl_trip_stop_yard_start_seq_chk
--       CHECK (
--           stop_sequence > 1
--           OR fk_stop_type = (
--               SELECT pk_stop_type_id FROM public.tbl_stop_type
--               WHERE stop_type = 'YARD_START'
--           )
--       )
--
-- The trigger enforces both directions of the rule:
--   1. A YARD_START stop MUST be sequence 1.
--   2. Sequence 1 MUST be a YARD_START stop.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_check_yard_start_sequence()
RETURNS TRIGGER AS $$
DECLARE
    v_yard_start_type_id int8;
BEGIN
    -- Resolve the YARD_START stop_type id from the lookup table
    SELECT pk_stop_type_id
      INTO v_yard_start_type_id
      FROM public.tbl_stop_type
     WHERE stop_type = 'YARD_START';

    -- Rule 1: A YARD_START stop must always be stop_sequence = 1
    IF NEW.fk_stop_type = v_yard_start_type_id AND NEW.stop_sequence <> 1 THEN
        RAISE EXCEPTION
            'Validation Failed: A YARD_START stop must always be stop_sequence = 1. Got stop_sequence = %.',
            NEW.stop_sequence;
    END IF;

    -- Rule 2: stop_sequence = 1 must always be a YARD_START stop
    IF NEW.stop_sequence = 1 AND NEW.fk_stop_type <> v_yard_start_type_id THEN
        RAISE EXCEPTION
            'Validation Failed: stop_sequence = 1 must always be a YARD_START stop.';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_yard_start_sequence
BEFORE INSERT OR UPDATE ON public.tbl_vehicle_trip_stop
FOR EACH ROW EXECUTE FUNCTION public.fn_check_yard_start_sequence();
