
-- =============================================================================
-- V52 — Modify tbl_order and tbl_empty_pickup
-- =============================================================================

-- ── tbl_order: link each delivery challan to its trip stop ───────────────────
ALTER TABLE public.tbl_order
    ADD COLUMN fk_stop int8 NULL
        REFERENCES public.tbl_vehicle_trip_stop(pk_stop_id);

CREATE INDEX idx_order_stop ON public.tbl_order(fk_stop) WHERE fk_stop IS NOT NULL;

-- ── tbl_empty_pickup: link to the stop where empties were collected ───────────
-- fk_driver and fk_vehicle are already on tbl_vehicle_load (the trip header);
-- they are redundant on the pickup but kept for backwards compatibility.
-- fk_stop carries the full context (trip + sequence + customer).

ALTER TABLE public.tbl_empty_pickup
    ADD COLUMN fk_stop int8 NULL
        REFERENCES public.tbl_vehicle_trip_stop(pk_stop_id);

CREATE INDEX idx_empty_pickup_stop
    ON public.tbl_empty_pickup(fk_stop) WHERE fk_stop IS NOT NULL;

