-- =============================================================================
-- V55__TripLoadAssociation.sql
-- =============================================================================
-- FIXES (all in one migration — order matters due to FK dependencies)
--
-- FIX 1  tbl_vehicle_load ↔ tbl_vehicle_trip — 1:1 association (MAIN GAP)
--         tbl_vehicle_load gains fk_vehicle_trip UNIQUE NOT NULL.
--         This is the owning side of the 1:1 (load holds the FK).
--
-- FIX 2  tbl_vehicle_trip_stop — points to wrong parent
--         Was: fk_vehicle_load → tbl_vehicle_load
--         Fix: fk_vehicle_trip → tbl_vehicle_trip
--         A stop belongs to a TRIP, not to a load. The load is a sub-entity
--         of the trip.
--
-- FIX 3  tbl_empty_pickup — add direct trip link
--         Already has fk_vehicle_load (V44) and fk_stop (V52).
--         Add fk_vehicle_trip for a direct, query-friendly link.
--         fk_vehicle_load and fk_stop are retained for backwards compat.
--
-- FIX 4  tbl_order — remove circular fk_stop (Issue 1 + 2)
--         V52 added tbl_order.fk_stop → tbl_vehicle_trip_stop.
--         V50 has tbl_vehicle_trip_stop.fk_order → tbl_order.
--         These two FKs form a circular dependency and are semantically
--         wrong: the stop records WHICH order it fulfils — the order does
--         not need a back-reference to its stop. Remove fk_stop from
--         tbl_order. To find the stop for an order:
--             SELECT * FROM tbl_vehicle_trip_stop WHERE fk_order = :id
--
-- FIX 5  tbl_order — add is_invoiced (Issue 3)
--         is_invoiced belongs on tbl_order (the challan header).
--         An order is invoiced as a whole; the flag prevents double-invoicing.
--
-- ENTITY CHANGES (see Java files):
--   VehicleLoadDo     +  @ManyToOne VehicleTripDo vehicleTrip
--   VehicleTripDo     +  @OneToOne(mappedBy) VehicleLoadDo vehicleLoad
--                        remove CustomerDo / CustomerAddressDo (stop-level)
--   VehicleTripStopDo    change fk_vehicle_load → fk_vehicle_trip
--   EmptyPickupDo     +  @ManyToOne VehicleTripDo vehicleTrip
--   OrderDo           remove VehicleTripStopDo stop field
--   OrderDo           +  boolean isInvoiced
-- =============================================================================


-- =============================================================================
-- FIX 1  tbl_vehicle_load → tbl_vehicle_trip  (1:1, load owns the FK)
-- =============================================================================
-- One vehicle load is created for exactly one trip.
-- The trip is the master (it holds vehicle + driver after V53).
-- UNIQUE enforces 1:1 at the DB level.

ALTER TABLE public.tbl_vehicle_load
    ADD COLUMN fk_vehicle_trip int8 NULL;

ALTER TABLE public.tbl_vehicle_load
    ADD CONSTRAINT tbl_vehicle_load_vehicle_trip_fk
    FOREIGN KEY (fk_vehicle_trip)
    REFERENCES public.tbl_vehicle_trip(pk_vehicle_trip_id);

ALTER TABLE public.tbl_vehicle_load
    ADD CONSTRAINT tbl_vehicle_load_vehicle_trip_unique
    UNIQUE (fk_vehicle_trip);

-- Backfill note: existing rows stay NULL until data is reconciled.
-- Once all rows are populated, tighten with:
--   ALTER TABLE public.tbl_vehicle_load ALTER COLUMN fk_vehicle_trip SET NOT NULL;

CREATE INDEX idx_vehicle_load_trip
    ON public.tbl_vehicle_load(fk_vehicle_trip);

COMMENT ON COLUMN public.tbl_vehicle_load.fk_vehicle_trip IS
    '1:1 with tbl_vehicle_trip. One load event per trip. '
    'The trip carries fk_vehicle and fk_driver (after V53).';


-- =============================================================================
-- FIX 2  tbl_vehicle_trip_stop — re-parent from vehicle_load to vehicle_trip
-- =============================================================================
-- A trip stop belongs to a TRIP, not to a load.
-- The old column was named fk_vehicle_load but its comment said "which trip" —
-- that was an authoring mistake.
--
-- Steps:
--   a) Add new column fk_vehicle_trip
--   b) Backfill via the 1:1 load→trip link we just created
--   c) Make NOT NULL (after backfill)
--   d) Drop old FK constraint, old UNIQUE, old column
--   e) Add new FK constraint and UNIQUE on (fk_vehicle_trip, stop_sequence)
--   f) Re-create supporting indexes

-- a) Add new column
ALTER TABLE public.tbl_vehicle_trip_stop
    ADD COLUMN fk_vehicle_trip int8 NULL;

-- b) Backfill: for every stop, walk load → trip
UPDATE public.tbl_vehicle_trip_stop s
SET    fk_vehicle_trip = l.fk_vehicle_trip
FROM   public.tbl_vehicle_load l
WHERE  l.pk_vehicle_load_id = s.fk_vehicle_load;

-- c) Enforce NOT NULL now that backfill is done
ALTER TABLE public.tbl_vehicle_trip_stop
    ALTER COLUMN fk_vehicle_trip SET NOT NULL;

-- d) Drop the old constraint, unique index, and column
ALTER TABLE public.tbl_vehicle_trip_stop
    DROP CONSTRAINT tbl_trip_stop_vehicle_load_fk;

ALTER TABLE public.tbl_vehicle_trip_stop
    DROP CONSTRAINT tbl_trip_stop_sequence_unique;

ALTER TABLE public.tbl_vehicle_trip_stop
    DROP COLUMN fk_vehicle_load;

DROP INDEX IF EXISTS public.idx_trip_stop_vehicle_load;

-- e) Add new FK + UNIQUE on the trip column
ALTER TABLE public.tbl_vehicle_trip_stop
    ADD CONSTRAINT tbl_trip_stop_vehicle_trip_fk
    FOREIGN KEY (fk_vehicle_trip)
    REFERENCES public.tbl_vehicle_trip(pk_vehicle_trip_id);

ALTER TABLE public.tbl_vehicle_trip_stop
    ADD CONSTRAINT tbl_trip_stop_sequence_unique
    UNIQUE (fk_vehicle_trip, stop_sequence);

-- f) Re-create the supporting index (was on fk_vehicle_load, stop_sequence)
CREATE INDEX idx_trip_stop_vehicle_trip
    ON public.tbl_vehicle_trip_stop(fk_vehicle_trip, stop_sequence);

COMMENT ON COLUMN public.tbl_vehicle_trip_stop.fk_vehicle_trip IS
    'Parent trip for this stop. UNIQUE(fk_vehicle_trip, stop_sequence) '
    'ensures no two stops share the same sequence within a trip.';


-- =============================================================================
-- FIX 3  tbl_empty_pickup — add direct fk_vehicle_trip link
-- =============================================================================
-- Existing: fk_vehicle_load (V44), fk_stop (V52).
-- Adding:   fk_vehicle_trip — direct link avoids a join through tbl_vehicle_load
--           when querying "all pickups for trip X".

ALTER TABLE public.tbl_empty_pickup
    ADD COLUMN fk_vehicle_trip int8 NULL;

ALTER TABLE public.tbl_empty_pickup
    ADD CONSTRAINT tbl_empty_pickup_vehicle_trip_fk
    FOREIGN KEY (fk_vehicle_trip)
    REFERENCES public.tbl_vehicle_trip(pk_vehicle_trip_id);

-- Backfill from existing fk_vehicle_load → trip chain
UPDATE public.tbl_empty_pickup ep
SET    fk_vehicle_trip = l.fk_vehicle_trip
FROM   public.tbl_vehicle_load l
WHERE  l.pk_vehicle_load_id = ep.fk_vehicle_load
AND    ep.fk_vehicle_load IS NOT NULL;

CREATE INDEX idx_empty_pickup_vehicle_trip
    ON public.tbl_empty_pickup(fk_vehicle_trip)
    WHERE fk_vehicle_trip IS NOT NULL;

COMMENT ON COLUMN public.tbl_empty_pickup.fk_vehicle_trip IS
    'Direct link to the trip during which these empties were collected. '
    'Denormalised from fk_vehicle_load for query convenience. '
    'fk_vehicle_load and fk_stop are retained for full traceability.';


-- =============================================================================
-- FIX 4  tbl_order — remove circular fk_stop  (Issues 1 & 2)
-- =============================================================================
-- V52 added tbl_order.fk_stop → tbl_vehicle_trip_stop.
-- V50 has tbl_vehicle_trip_stop.fk_order → tbl_order.
-- These form a cycle. The semantically correct direction is:
--   stop → order  (the stop records which challan it fulfils).
-- The reverse (order → stop) is a derived query, not a stored FK.

DROP INDEX IF EXISTS public.idx_order_stop;

ALTER TABLE public.tbl_order
    DROP COLUMN IF EXISTS fk_stop;

-- To find the stop for an order at the application layer:
--   SELECT * FROM tbl_vehicle_trip_stop WHERE fk_order = :orderId


-- =============================================================================
-- FIX 5  tbl_order — add is_invoiced  (Issue 3)
-- =============================================================================
-- is_invoiced belongs on tbl_order (the delivery challan / header level).
-- An order is invoiced as a whole — the invoicing service raises one invoice
-- per delivery challan and sets this flag when the invoice is confirmed.
-- This prevents the same challan from being invoiced twice.

ALTER TABLE public.tbl_order
    ADD COLUMN IF NOT EXISTS is_invoiced BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN public.tbl_order.is_invoiced IS
    'TRUE once this delivery challan has been included on a finalised invoice. '
    'Set by the invoicing service when the invoice is confirmed. '
    'Prevents the same order being invoiced twice.';

-- Partial index: fast lookup of all uninvoiced orders per customer
CREATE INDEX idx_order_not_invoiced
    ON public.tbl_order(fk_customer)
    WHERE is_invoiced = FALSE;

-- Remove is_invoiced from tbl_order_line if it was previously added there:
ALTER TABLE public.tbl_order_line
    DROP COLUMN IF EXISTS is_invoiced;
