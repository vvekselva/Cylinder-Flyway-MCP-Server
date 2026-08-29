-- =====================================================================
-- V122__Party_Custody_Obligation_Enhancements.sql
-- =====================================================================
--
-- IMPORTANT ARCHITECTURAL DECISION
-- ---------------------------------------------------------------------
-- public.tbl_cylinder_party_custody is the authoritative
-- CYLINDER OBLIGATION table.
--
-- Do NOT create separate tables such as:
--   - tbl_cylinder_obligation
--   - tbl_customer_obligation
--   - tbl_supplier_obligation
--
-- Business meaning:
--   A custody row is created when a serialized cylinder enters a party
--   custody chain. That custody row is the obligation to recover or close
--   that cylinder later.
--
-- Customer flow:
--   Customer Delivery      -> creates CUSTOMER custody obligation
--   Customer Empty Pickup  -> closes CUSTOMER custody obligation
--
-- Supplier flow:
--   Supplier Empty Drop    -> creates SUPPLIER custody obligation
--   Supplier Full Pickup   -> closes SUPPLIER custody obligation
--
-- Reconciliation meaning:
--   custody_status = 'ACTIVE' means OPEN obligation.
--   custody_status = 'CLOSED' means CLOSED obligation.
--
-- This migration does not create a new obligation table. It only enhances
-- tbl_cylinder_party_custody with trip/load/stop traceability and aging
-- fields required by reconciliation.
-- =====================================================================


-- =====================================================================
-- 1. Add traceability columns
-- =====================================================================

ALTER TABLE public.tbl_cylinder_party_custody
ADD COLUMN IF NOT EXISTS fk_entry_trip bigint;

ALTER TABLE public.tbl_cylinder_party_custody
ADD COLUMN IF NOT EXISTS fk_entry_load bigint;

ALTER TABLE public.tbl_cylinder_party_custody
ADD COLUMN IF NOT EXISTS fk_entry_stop bigint;

ALTER TABLE public.tbl_cylinder_party_custody
ADD COLUMN IF NOT EXISTS fk_exit_trip bigint;

ALTER TABLE public.tbl_cylinder_party_custody
ADD COLUMN IF NOT EXISTS fk_exit_load bigint;

ALTER TABLE public.tbl_cylinder_party_custody
ADD COLUMN IF NOT EXISTS fk_exit_stop bigint;

ALTER TABLE public.tbl_cylinder_party_custody
ADD COLUMN IF NOT EXISTS aging_due_at timestamp;

ALTER TABLE public.tbl_cylinder_party_custody
ADD COLUMN IF NOT EXISTS escalated_at timestamp;


-- =====================================================================
-- 2. Add foreign keys safely
-- =====================================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'tbl_cpc_entry_trip_fk'
    ) THEN
        ALTER TABLE public.tbl_cylinder_party_custody
        ADD CONSTRAINT tbl_cpc_entry_trip_fk
        FOREIGN KEY (fk_entry_trip)
        REFERENCES public.tbl_vehicle_trip(pk_vehicle_trip_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'tbl_cpc_entry_load_fk'
    ) THEN
        ALTER TABLE public.tbl_cylinder_party_custody
        ADD CONSTRAINT tbl_cpc_entry_load_fk
        FOREIGN KEY (fk_entry_load)
        REFERENCES public.tbl_vehicle_load(pk_vehicle_load_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'tbl_cpc_entry_stop_fk'
    ) THEN
        ALTER TABLE public.tbl_cylinder_party_custody
        ADD CONSTRAINT tbl_cpc_entry_stop_fk
        FOREIGN KEY (fk_entry_stop)
        REFERENCES public.tbl_vehicle_trip_stop(pk_stop_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'tbl_cpc_exit_trip_fk'
    ) THEN
        ALTER TABLE public.tbl_cylinder_party_custody
        ADD CONSTRAINT tbl_cpc_exit_trip_fk
        FOREIGN KEY (fk_exit_trip)
        REFERENCES public.tbl_vehicle_trip(pk_vehicle_trip_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'tbl_cpc_exit_load_fk'
    ) THEN
        ALTER TABLE public.tbl_cylinder_party_custody
        ADD CONSTRAINT tbl_cpc_exit_load_fk
        FOREIGN KEY (fk_exit_load)
        REFERENCES public.tbl_vehicle_load(pk_vehicle_load_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'tbl_cpc_exit_stop_fk'
    ) THEN
        ALTER TABLE public.tbl_cylinder_party_custody
        ADD CONSTRAINT tbl_cpc_exit_stop_fk
        FOREIGN KEY (fk_exit_stop)
        REFERENCES public.tbl_vehicle_trip_stop(pk_stop_id);
    END IF;
END $$;


-- =====================================================================
-- 3. Helpful indexes for obligation aging and trip closure checks
-- =====================================================================

CREATE INDEX IF NOT EXISTS idx_cpc_active_aging_due
ON public.tbl_cylinder_party_custody(aging_due_at)
WHERE custody_status = 'ACTIVE'
  AND aging_due_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_cpc_entry_trip_active
ON public.tbl_cylinder_party_custody(fk_entry_trip)
WHERE fk_entry_trip IS NOT NULL
  AND custody_status = 'ACTIVE';

CREATE INDEX IF NOT EXISTS idx_cpc_entry_load
ON public.tbl_cylinder_party_custody(fk_entry_load)
WHERE fk_entry_load IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_cpc_entry_stop
ON public.tbl_cylinder_party_custody(fk_entry_stop)
WHERE fk_entry_stop IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_cpc_exit_trip
ON public.tbl_cylinder_party_custody(fk_exit_trip)
WHERE fk_exit_trip IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_cpc_exit_load
ON public.tbl_cylinder_party_custody(fk_exit_load)
WHERE fk_exit_load IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_cpc_exit_stop
ON public.tbl_cylinder_party_custody(fk_exit_stop)
WHERE fk_exit_stop IS NOT NULL;


-- =====================================================================
-- 4. Documentation comments
-- =====================================================================

COMMENT ON TABLE public.tbl_cylinder_party_custody IS
'Cylinder Party Custody is the authoritative Cylinder Obligation model.

Business Meaning:
- A custody record represents a per-cylinder obligation.
- A custody record is created when a cylinder enters Customer or Supplier custody.
- Customer Delivery creates a CUSTOMER custody obligation.
- Customer Empty Pickup closes the CUSTOMER custody obligation.
- Supplier Empty Drop creates a SUPPLIER custody obligation.
- Supplier Full Pickup closes the SUPPLIER custody obligation.

Reconciliation Meaning:
- custody_status = ACTIVE means OPEN obligation.
- custody_status = CLOSED means CLOSED obligation.
- Trip accounting and challan aging are separate reconciliation concepts.
- This table is the system of record for per-cylinder customer/supplier obligations.

Design Rule:
Do not duplicate this model with tbl_cylinder_obligation, tbl_customer_obligation,
or tbl_supplier_obligation. Future obligation enhancements must extend this table.';

COMMENT ON COLUMN public.tbl_cylinder_party_custody.custody_status IS
'Obligation lifecycle status. ACTIVE = OPEN obligation. CLOSED = CLOSED obligation.';

COMMENT ON COLUMN public.tbl_cylinder_party_custody.entered_at IS
'Timestamp when the cylinder obligation was created / entered party custody.';

COMMENT ON COLUMN public.tbl_cylinder_party_custody.exited_at IS
'Timestamp when the cylinder obligation was closed / exited party custody.';

COMMENT ON COLUMN public.tbl_cylinder_party_custody.entry_event_type IS
'Business event that created the obligation, such as ORDER_DELIVERY or SUPPLIER_DROPOFF.';

COMMENT ON COLUMN public.tbl_cylinder_party_custody.exit_event_type IS
'Business event that closed the obligation, such as EMPTY_PICKUP, REFILL_COLLECTION, or CORRECTION.';

COMMENT ON COLUMN public.tbl_cylinder_party_custody.fk_entry_trip IS
'Trip that created the custody obligation. Example: trip that delivered to customer or dropped empty at supplier.';

COMMENT ON COLUMN public.tbl_cylinder_party_custody.fk_entry_load IS
'Vehicle load that created the custody obligation.';

COMMENT ON COLUMN public.tbl_cylinder_party_custody.fk_entry_stop IS
'Trip stop/challan context that created the custody obligation.';

COMMENT ON COLUMN public.tbl_cylinder_party_custody.fk_exit_trip IS
'Future trip that closed the custody obligation. Example: trip that picked up empty from customer or full from supplier.';

COMMENT ON COLUMN public.tbl_cylinder_party_custody.fk_exit_load IS
'Future vehicle load that closed the custody obligation.';

COMMENT ON COLUMN public.tbl_cylinder_party_custody.fk_exit_stop IS
'Future trip stop/challan context that closed the custody obligation.';

COMMENT ON COLUMN public.tbl_cylinder_party_custody.aging_due_at IS
'Timestamp when the open custody obligation becomes aging if it is still ACTIVE.';

COMMENT ON COLUMN public.tbl_cylinder_party_custody.escalated_at IS
'Timestamp when the aging custody obligation was escalated for investigation.';


-- =====================================================================
-- 5. Verification notice
-- =====================================================================

DO $$
BEGIN
    RAISE NOTICE 'V122 OK: tbl_cylinder_party_custody documented as Cylinder Obligation model.';
    RAISE NOTICE 'V122 OK: entry/exit trip-load-stop traceability columns added.';
    RAISE NOTICE 'V122 OK: aging_due_at and escalated_at added for obligation aging.';
END $$;
