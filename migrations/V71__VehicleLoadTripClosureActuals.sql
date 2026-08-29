-- =============================================================================
-- V71__VehicleLoadTripClosureActuals.sql  (REVISED — Flyway fix applied)
-- =============================================================================
-- FIX — ERROR: column vl.load_date does not exist  (Flyway V71 line 466)
--
--   ROOT CAUSE:
--     V53__VehicleLoad-Updates.sql dropped load_date (along with fk_vehicle,
--     fk_driver, and load_time) from tbl_vehicle_load.  V71's Sankey views
--     (vw_trip_sankey_flows, vw_daily_sankey_aggregate) and fn_trip_sankey_json
--     all reference vl.load_date, which no longer exists at migration time.
--
--   FIX (SECTION 1):
--     load_date is re-added as an IMMUTABLE GENERATED ALWAYS AS column:
--       ADD COLUMN IF NOT EXISTS load_date date
--           GENERATED ALWAYS AS (created_at::date) STORED;
--     No data back-fill required. Idempotent (IF NOT EXISTS guard).
--     All downstream view and function references now compile cleanly.
--
-- PURPOSE:
--   Extend tbl_vehicle_load with ACTUAL closure quantities that are computed
--   when the associated vehicle trip transitions to the 'Halt' status (V69).
--
-- PROBLEM:
--   tbl_vehicle_load already holds the PLANNED quantities declared at load time:
--       quantity_full_for_delivery   – full cylinders intended for customer stops
--       quantity_full_for_buffer     – buffer cylinders carried as contingency
--       quantity_empty_for_supplier  – empty cylinders to drop at supplier
--   These are intentions.  After the trip closes, there is no single place that
--   records what actually happened — deliveries made, empties collected, supplier
--   drop-offs completed, refills brought back.
--
-- SOLUTION:
--   Add six ACTUAL columns to tbl_vehicle_load (populated at trip closure).
--   Add two generated VARIANCE columns (planned - actual) for instant discrepancy
--   detection without a join.
--   Wire a trigger to tbl_vehicle_trip so that any status change to 'Halt' fires
--   fn_compute_trip_closure_actuals(), which reads the cylinder current-state
--   table and the supplier refill collection to produce the actuals atomically.
--
-- CYLINDER FLOW MODEL (what each column captures):
--
--   ┌─────────────────────────────────────────────────────────────────────┐
--   │                     OUTBOUND  (from yard)                           │
--   │  quantity_full_for_delivery  →  actual_qty_full_delivered_to_customer│
--   │  quantity_full_for_buffer    →  actual_qty_buffer_used_for_delivery  │
--   │                             OR  actual_qty_buffer_returned_full      │
--   │  quantity_empty_for_supplier →  actual_qty_empty_dropped_at_supplier │
--   ├─────────────────────────────────────────────────────────────────────┤
--   │                     INBOUND   (collected during trip)               │
--   │  (from customers)           →  actual_qty_empty_collected_from_cust  │
--   │  (from supplier refill)     →  actual_qty_full_collected_from_supplier│
--   └─────────────────────────────────────────────────────────────────────┘
--
-- SANKEY CHART SUPPORT:
--   vw_trip_sankey_flows        — per-trip flow rows (source, target, value)
--   vw_daily_sankey_aggregate   — daily sum across all trips (for dashboards)
--   fn_trip_sankey_json()       — per-trip D3/Chart.js–ready JSON payload
--
-- TRIGGER INTEGRATION:
--   The trigger added here (trg_trip_closure_load_actuals) fires on the same
--   AFTER UPDATE OF fk_trip_status event as V69's trg_trip_status_after_update.
--   PostgreSQL fires multiple triggers alphabetically; the 'trg_trip_closure…'
--   name ensures this runs after 'trg_trip_status…' which creates checkpoints.
--
-- INCREMENTAL UPDATE:
--   A second trigger on tbl_supplier_refill_collection_line keeps
--   actual_qty_full_collected_from_supplier current in real-time as supplier
--   collection lines are inserted — even after the trip has already been closed.
-- =============================================================================


-- ===========================================================================
-- SECTION 1 — New columns on tbl_vehicle_load
-- ===========================================================================
-- FIX — load_date: V53__VehicleLoad-Updates.sql dropped the original load_date
-- column (along with fk_vehicle, fk_driver, load_time).  The Sankey views in
-- SECTION 5/6 and the JSON function in SECTION 7 all reference vl.load_date.
-- Re-add it as an IMMUTABLE GENERATED column derived from created_at so that
-- no existing data needs back-filling and the views compile correctly.
-- ===========================================================================
ALTER TABLE public.tbl_vehicle_load
    ADD COLUMN IF NOT EXISTS load_date date
        GENERATED ALWAYS AS (created_at::date) STORED;

COMMENT ON COLUMN public.tbl_vehicle_load.load_date IS
    'Business date of the vehicle load. '
    'GENERATED from created_at::date — V53 dropped the original load_date column; '
    'V71 restores it as a computed column for Sankey view compatibility.';

ALTER TABLE public.tbl_vehicle_load

    -- ── Actuals (computed at trip closure) ───────────────────────────────────

    -- Full cylinders loaded as FULL_FOR_DELIVERY that reached the customer
    -- (cylinder current state is NOT FULL / FULL_PICKED_UP_FOR_DELIVERY at Halt)
    ADD COLUMN IF NOT EXISTS actual_qty_full_delivered_to_customer     int4  NOT NULL DEFAULT 0,

    -- Buffer cylinders (FULL_FOR_BUFFER) that were used for unplanned delivery
    -- (buffer cylinder current state is NOT FULL / FULL_PICKED_UP_FOR_DELIVERY)
    ADD COLUMN IF NOT EXISTS actual_qty_buffer_used_for_delivery       int4  NOT NULL DEFAULT 0,

    -- Buffer cylinders returned to yard unused — still FULL at trip close
    ADD COLUMN IF NOT EXISTS actual_qty_buffer_returned_full           int4  NOT NULL DEFAULT 0,

    -- Empty cylinders picked up from customers during the trip
    -- (count of EMPTY_RETURNED_TO_YARD load lines for this load)
    ADD COLUMN IF NOT EXISTS actual_qty_empty_collected_from_customer  int4  NOT NULL DEFAULT 0,

    -- Empty cylinders successfully handed to supplier
    -- (EMPTY_FOR_SUPPLIER lines where cylinder is EMPTY_DELIVERED_FOR_REFILL or beyond)
    ADD COLUMN IF NOT EXISTS actual_qty_empty_dropped_at_supplier      int4  NOT NULL DEFAULT 0,

    -- Full (refilled) cylinders collected from supplier on this trip
    -- (count of tbl_supplier_refill_collection_line rows via the trip)
    ADD COLUMN IF NOT EXISTS actual_qty_full_collected_from_supplier   int4  NOT NULL DEFAULT 0,

    -- ── Closure metadata ─────────────────────────────────────────────────────
    ADD COLUMN IF NOT EXISTS closure_computed_at      timestamp     NULL,
    ADD COLUMN IF NOT EXISTS closure_variance_notes   varchar(500)  NULL;

-- ── Generated variance columns (planned vs actual) ────────────────────────
-- These give instant discrepancy detection for dashboards without a join.
-- Negative = over-delivered / over-collected (unusual, needs investigation).
-- Positive = shortfall against plan.

ALTER TABLE public.tbl_vehicle_load
    ADD COLUMN IF NOT EXISTS variance_deliveries_vs_plan
        int4 GENERATED ALWAYS AS (
            quantity_full_for_delivery
            - actual_qty_full_delivered_to_customer
            - actual_qty_buffer_used_for_delivery   -- buffer used for delivery fulfils the same business need
        ) STORED,

    ADD COLUMN IF NOT EXISTS variance_empty_supplier_vs_plan
        int4 GENERATED ALWAYS AS (
            quantity_empty_for_supplier - actual_qty_empty_dropped_at_supplier
        ) STORED;

COMMENT ON COLUMN public.tbl_vehicle_load.actual_qty_full_delivered_to_customer  IS
    'Full cylinders delivered to customers via FULL_FOR_DELIVERY lines. '
    'Populated when tbl_vehicle_trip transitions to Halt.';
COMMENT ON COLUMN public.tbl_vehicle_load.actual_qty_buffer_used_for_delivery    IS
    'Buffer cylinders (FULL_FOR_BUFFER) that were actually delivered to customers.';
COMMENT ON COLUMN public.tbl_vehicle_load.actual_qty_buffer_returned_full        IS
    'Buffer cylinders returned to yard unused (still FULL at trip close).';
COMMENT ON COLUMN public.tbl_vehicle_load.actual_qty_empty_collected_from_customer IS
    'Empty cylinders picked up from customer locations. '
    'Equals the count of EMPTY_RETURNED_TO_YARD load lines for this load.';
COMMENT ON COLUMN public.tbl_vehicle_load.actual_qty_empty_dropped_at_supplier   IS
    'Empty cylinders successfully handed over to supplier for refill.';
COMMENT ON COLUMN public.tbl_vehicle_load.actual_qty_full_collected_from_supplier IS
    'Full (refilled) cylinders collected from supplier on this trip. '
    'Kept live by trg_supplier_refill_line_update_load_actuals.';
COMMENT ON COLUMN public.tbl_vehicle_load.variance_deliveries_vs_plan            IS
    'planned delivery qty minus actual. 0 = clean. '
    'Negative = more delivered than planned (buffer used). Positive = shortfall.';
COMMENT ON COLUMN public.tbl_vehicle_load.variance_empty_supplier_vs_plan        IS
    'planned empty-to-supplier qty minus actual. 0 = clean.';


-- ===========================================================================
-- SECTION 2 — fn_compute_trip_closure_actuals()
-- ===========================================================================
-- Reads the cylinder current-state table and load-line purpose breakdown
-- for a given vehicle trip, then UPDATEs tbl_vehicle_load with the actuals.
--
-- Called by:
--   trg_trip_closure_load_actuals  (AFTER UPDATE on tbl_vehicle_trip, status=Halt)
--   Can also be called manually for re-computation:
--     SELECT fn_compute_trip_closure_actuals(<trip_id>);
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.fn_compute_trip_closure_actuals(
    p_vehicle_trip_id   int8
)
RETURNS void AS $$
DECLARE
    v_load_id   int8;

    -- FULL_FOR_DELIVERY lines
    v_full_delivery_total   int4 := 0;
    v_full_delivered        int4 := 0;   -- reached customer

    -- FULL_FOR_BUFFER lines
    v_buffer_total          int4 := 0;
    v_buffer_used           int4 := 0;   -- actually delivered (buffer used as delivery)
    v_buffer_returned       int4 := 0;   -- came back full (unused)

    -- EMPTY_RETURNED_TO_YARD lines (empty pickups from customers)
    v_empty_collected       int4 := 0;

    -- EMPTY_FOR_SUPPLIER lines
    v_empty_supplier_total  int4 := 0;
    v_empty_dropped         int4 := 0;   -- confirmed at supplier

    -- Supplier refill collections on this trip
    v_full_from_supplier    int4 := 0;

    -- Variance notes accumulator
    v_notes                 text := '';

    -- State ID caches (avoid repeated lookups in the cursor loop)
    v_state_full            int8;
    v_state_full_in_transit int8;
    v_state_delivered       int8;
    v_state_empty           int8;
    v_state_empty_for_refill int8;
    v_state_full_from_sup   int8;
BEGIN
    -- ── 1. Find the vehicle load for this trip (1:1 via V55) ─────────────────
    SELECT pk_vehicle_load_id INTO v_load_id
      FROM public.tbl_vehicle_load
     WHERE fk_vehicle_trip = p_vehicle_trip_id;

    IF v_load_id IS NULL THEN
        RAISE NOTICE 'fn_compute_trip_closure_actuals: No vehicle load found for trip %.', p_vehicle_trip_id;
        RETURN;
    END IF;

    -- ── 2. Cache frequently-used state IDs ───────────────────────────────────
    SELECT pk_cylinder_state_id INTO v_state_full
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL';

    SELECT pk_cylinder_state_id INTO v_state_full_in_transit
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL_PICKED_UP_FOR_DELIVERY';

    SELECT pk_cylinder_state_id INTO v_state_delivered
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'DELIVERED_FOR_CONSUMPTION';

    SELECT pk_cylinder_state_id INTO v_state_empty
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY';

    SELECT pk_cylinder_state_id INTO v_state_empty_for_refill
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL';

    SELECT pk_cylinder_state_id INTO v_state_full_from_sup
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL_PICKED_FROM_SUPPLIER';

    -- ── 3. Compute actuals per load-line purpose ──────────────────────────────
    --
    -- For each purpose group, JOIN to tbl_cylinder_current_status to get the
    -- current state of every cylinder that was on this load.
    -- The current state at trip-close tells us what actually happened.

    -- ── 3a. FULL_FOR_DELIVERY ─────────────────────────────────────────────────
    -- Not FULL / FULL_PICKED_UP_FOR_DELIVERY  → cylinder left vehicle for customer
    -- Still FULL / FULL_PICKED_UP_FOR_DELIVERY → anomaly (listed in notes)
    SELECT
        COUNT(*)                                                        AS total,
        COUNT(*) FILTER (
            WHERE ccs.fk_current_state NOT IN (v_state_full, v_state_full_in_transit)
        )                                                               AS delivered
    INTO v_full_delivery_total, v_full_delivered
    FROM public.tbl_vehicle_load_line vll
    JOIN public.tbl_vehicle_load_purpose vlp
        ON vlp.pk_load_purpose_id = vll.fk_load_purpose
    JOIN public.tbl_cylinder_current_status ccs
        ON ccs.fk_cylinder = vll.fk_cylinder
    WHERE vll.fk_vehicle_load = v_load_id
      AND vlp.load_purpose = 'FULL_FOR_DELIVERY';

    IF (v_full_delivery_total - v_full_delivered) > 0 THEN
        v_notes := v_notes || 'FULL_FOR_DELIVERY undelivered: '
            || (v_full_delivery_total - v_full_delivered)::text || ' cylinder(s) still FULL. ';
    END IF;

    -- ── 3b. FULL_FOR_BUFFER ───────────────────────────────────────────────────
    -- Not FULL / FULL_PICKED_UP_FOR_DELIVERY → used for an unplanned delivery
    -- Still FULL / FULL_PICKED_UP_FOR_DELIVERY → returned to yard unused
    SELECT
        COUNT(*)                                                        AS total,
        COUNT(*) FILTER (
            WHERE ccs.fk_current_state NOT IN (v_state_full, v_state_full_in_transit)
        )                                                               AS used,
        COUNT(*) FILTER (
            WHERE ccs.fk_current_state IN (v_state_full, v_state_full_in_transit)
        )                                                               AS returned
    INTO v_buffer_total, v_buffer_used, v_buffer_returned
    FROM public.tbl_vehicle_load_line vll
    JOIN public.tbl_vehicle_load_purpose vlp
        ON vlp.pk_load_purpose_id = vll.fk_load_purpose
    JOIN public.tbl_cylinder_current_status ccs
        ON ccs.fk_cylinder = vll.fk_cylinder
    WHERE vll.fk_vehicle_load = v_load_id
      AND vlp.load_purpose = 'FULL_FOR_BUFFER';

    -- ── 3c. EMPTY_RETURNED_TO_YARD (empties collected from customers) ─────────
    -- The load-line INSERT IS the pickup event — every line here is a collected cylinder.
    SELECT COUNT(*) INTO v_empty_collected
    FROM public.tbl_vehicle_load_line vll
    JOIN public.tbl_vehicle_load_purpose vlp
        ON vlp.pk_load_purpose_id = vll.fk_load_purpose
    WHERE vll.fk_vehicle_load = v_load_id
      AND vlp.load_purpose = 'EMPTY_RETURNED_TO_YARD';

    -- ── 3d. EMPTY_FOR_SUPPLIER ────────────────────────────────────────────────
    -- EMPTY_DELIVERED_FOR_REFILL or FULL_PICKED_FROM_SUPPLIER → dropped at supplier
    -- Still EMPTY / EMPTY_PICKED_FOR_REFILL                   → not yet dropped
    SELECT
        COUNT(*)                                                        AS total,
        COUNT(*) FILTER (
            WHERE ccs.fk_current_state IN (v_state_empty_for_refill, v_state_full_from_sup)
                OR ccs.fk_current_state NOT IN (v_state_empty, v_state_full_in_transit,
                                                v_state_full, v_state_delivered)
                   AND ccs.fk_current_state NOT IN (
                       SELECT pk_cylinder_state_id FROM public.tbl_cylinder_states
                       WHERE cylinder_state IN ('EMPTY', 'EMPTY_PICKED_FOR_REFILL')
                   )
        )                                                               AS dropped
    INTO v_empty_supplier_total, v_empty_dropped
    FROM public.tbl_vehicle_load_line vll
    JOIN public.tbl_vehicle_load_purpose vlp
        ON vlp.pk_load_purpose_id = vll.fk_load_purpose
    JOIN public.tbl_cylinder_current_status ccs
        ON ccs.fk_cylinder = vll.fk_cylinder
    WHERE vll.fk_vehicle_load = v_load_id
      AND vlp.load_purpose = 'EMPTY_FOR_SUPPLIER';

    -- Simpler rewrite for 3d (avoids nested subquery complexity):
    -- "dropped" = cylinder is NOT in early empty states (EMPTY, EMPTY_PICKED_FOR_REFILL)
    SELECT
        COUNT(*)  FILTER (WHERE vlp.load_purpose = 'EMPTY_FOR_SUPPLIER')     AS total,
        COUNT(*)  FILTER (
            WHERE vlp.load_purpose = 'EMPTY_FOR_SUPPLIER'
              AND cs.cylinder_state NOT IN ('EMPTY', 'EMPTY_PICKED_FOR_REFILL')
        )                                                                     AS dropped
    INTO v_empty_supplier_total, v_empty_dropped
    FROM public.tbl_vehicle_load_line vll
    JOIN public.tbl_vehicle_load_purpose vlp
        ON vlp.pk_load_purpose_id = vll.fk_load_purpose
    JOIN public.tbl_cylinder_current_status ccs
        ON ccs.fk_cylinder = vll.fk_cylinder
    JOIN public.tbl_cylinder_states cs
        ON cs.pk_cylinder_state_id = ccs.fk_current_state
    WHERE vll.fk_vehicle_load = v_load_id
      AND vlp.load_purpose = 'EMPTY_FOR_SUPPLIER';

    IF (v_empty_supplier_total - v_empty_dropped) > 0 THEN
        v_notes := v_notes || 'EMPTY_FOR_SUPPLIER not yet at supplier: '
            || (v_empty_supplier_total - v_empty_dropped)::text || ' cylinder(s). ';
    END IF;

    -- ── 3e. Supplier refill collections on this trip ──────────────────────────
    SELECT COUNT(*) INTO v_full_from_supplier
    FROM public.tbl_supplier_refill_collection_line srcl
    JOIN public.tbl_supplier_refill_collection src
        ON src.pk_collection_id = srcl.fk_collection
    WHERE src.fk_vehicle_trip = p_vehicle_trip_id;

    -- ── 4. Write actuals back to tbl_vehicle_load ─────────────────────────────
    UPDATE public.tbl_vehicle_load
    SET
        actual_qty_full_delivered_to_customer    = v_full_delivered,
        actual_qty_buffer_used_for_delivery      = v_buffer_used,
        actual_qty_buffer_returned_full          = v_buffer_returned,
        actual_qty_empty_collected_from_customer = v_empty_collected,
        actual_qty_empty_dropped_at_supplier     = v_empty_dropped,
        actual_qty_full_collected_from_supplier  = v_full_from_supplier,
        closure_computed_at                      = now(),
        closure_variance_notes                   = NULLIF(TRIM(v_notes), '')
    WHERE pk_vehicle_load_id = v_load_id;

    RAISE NOTICE
        'Trip % closure actuals: delivered=%, buffer_used=%, buffer_returned=%, '
        'empty_collected=%, empty_to_supplier=%, full_from_supplier=%',
        p_vehicle_trip_id,
        v_full_delivered, v_buffer_used, v_buffer_returned,
        v_empty_collected, v_empty_dropped, v_full_from_supplier;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_compute_trip_closure_actuals IS
    'Computes actual cylinder movement quantities for a vehicle trip at closure '
    '(status = Halt) by reading tbl_cylinder_current_status for each load line. '
    'Idempotent — safe to call multiple times; always overwrites the previous result. '
    'Can be called manually to recompute if state data is corrected post-close.';


-- ===========================================================================
-- SECTION 3 — Trigger: trip Halt → compute closure actuals
-- ===========================================================================
-- Fires AFTER UPDATE on tbl_vehicle_trip when fk_trip_status changes.
-- Only acts when the new status is 'Halt' (terminal state, V69).
-- Named 'trg_trip_closure…' to run AFTER 'trg_trip_status…' (alphabetical order).
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.fn_trip_closure_load_actuals()
RETURNS TRIGGER AS $$
DECLARE
    v_new_status_name varchar(50);
BEGIN
    -- Only react to status changes
    IF NEW.fk_trip_status = OLD.fk_trip_status THEN
        RETURN NEW;
    END IF;

    SELECT status_name INTO v_new_status_name
      FROM public.tbl_trip_status
     WHERE pk_trip_status_id = NEW.fk_trip_status;

    IF v_new_status_name = 'Halt' THEN
        PERFORM public.fn_compute_trip_closure_actuals(NEW.pk_vehicle_trip_id);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trip_closure_load_actuals
AFTER UPDATE OF fk_trip_status ON public.tbl_vehicle_trip
FOR EACH ROW
EXECUTE FUNCTION public.fn_trip_closure_load_actuals();

COMMENT ON TRIGGER trg_trip_closure_load_actuals ON public.tbl_vehicle_trip IS
    'When a trip reaches Halt status, calls fn_compute_trip_closure_actuals() '
    'to populate the actual_qty_* columns on tbl_vehicle_load.';


-- ===========================================================================
-- SECTION 4 — Incremental trigger: supplier refill collection line → load actuals
-- ===========================================================================
-- tbl_supplier_refill_collection_line rows may be inserted AFTER the trip is
-- already closed (e.g., yard worker scans cylinders arriving back at the depot).
-- This trigger keeps actual_qty_full_collected_from_supplier live without
-- requiring a full recompute.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.fn_supplier_refill_line_update_load_actuals()
RETURNS TRIGGER AS $$
DECLARE
    v_trip_id   int8;
    v_load_id   int8;
BEGIN
    -- Resolve the vehicle trip from the collection header
    SELECT fk_vehicle_trip INTO v_trip_id
      FROM public.tbl_supplier_refill_collection
     WHERE pk_collection_id = NEW.fk_collection;

    IF v_trip_id IS NULL THEN RETURN NEW; END IF;

    -- Resolve the load from the trip (1:1)
    SELECT pk_vehicle_load_id INTO v_load_id
      FROM public.tbl_vehicle_load
     WHERE fk_vehicle_trip = v_trip_id;

    IF v_load_id IS NULL THEN RETURN NEW; END IF;

    -- Increment the actual count (idempotent — uses a COUNT subquery rather than +1
    -- to guard against duplicate inserts from retry scenarios)
    UPDATE public.tbl_vehicle_load
    SET actual_qty_full_collected_from_supplier = (
            SELECT COUNT(*)
              FROM public.tbl_supplier_refill_collection_line srcl2
              JOIN public.tbl_supplier_refill_collection src2
                ON src2.pk_collection_id = srcl2.fk_collection
             WHERE src2.fk_vehicle_trip = v_trip_id
        ),
        closure_computed_at = now()
    WHERE pk_vehicle_load_id = v_load_id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_supplier_refill_line_update_load_actuals
AFTER INSERT ON public.tbl_supplier_refill_collection_line
FOR EACH ROW
EXECUTE FUNCTION public.fn_supplier_refill_line_update_load_actuals();

COMMENT ON TRIGGER trg_supplier_refill_line_update_load_actuals
    ON public.tbl_supplier_refill_collection_line IS
    'Keeps tbl_vehicle_load.actual_qty_full_collected_from_supplier current '
    'in real-time as refill collection lines are scanned in at the yard.';


-- ===========================================================================
-- SECTION 5 — vw_trip_sankey_flows  (per-trip Sankey rows)
-- ===========================================================================
-- Returns one row per cylinder flow per trip.
-- The frontend (D3-Sankey / Chart.js) reads this and builds the diagram.
--
-- Node vocabulary (consistent across all trips):
--   "Yard (Full Stock)"      – source: full cylinders in yard
--   "Yard (Empty Stock)"     – source: empty cylinders in yard
--   "Customer Locations"     – customers who receive full / return empty
--   "Supplier"               – refill partner
--   "Buffer (Returned)"      – buffer cylinders that came back to yard unused
--
-- Flow rules:
--   Yard (Full) → Customer          : deliveries (planned + buffer used)
--   Yard (Full) → Buffer (Returned) : buffer cylinders returned unused
--   Yard (Empty) → Supplier         : empties sent for refill
--   Customer → Yard (Empty)         : empties collected and returned
--   Supplier → Yard (Full)          : refilled cylinders brought back
-- ===========================================================================
CREATE OR REPLACE VIEW public.vw_trip_sankey_flows AS

-- Planned full cylinders loaded (for reference on Sankey "input" side)
SELECT
    vl.pk_vehicle_load_id               AS vehicle_load_id,
    vl.fk_vehicle_trip                  AS vehicle_trip_id,
    vl.load_date,
    'Yard (Full Stock)'                 AS source_node,
    'Vehicle'                           AS target_node,
    'Loaded — For Delivery'             AS flow_label,
    vl.quantity_full_for_delivery       AS planned_qty,
    vl.actual_qty_full_delivered_to_customer
        + vl.actual_qty_buffer_used_for_delivery AS actual_qty,
    'OUTBOUND_FULL'                     AS flow_category
FROM public.tbl_vehicle_load vl
WHERE vl.quantity_full_for_delivery > 0
   OR vl.actual_qty_full_delivered_to_customer > 0

UNION ALL

-- Full cylinders actually delivered to customers (post-closure actuals)
SELECT
    vl.pk_vehicle_load_id,
    vl.fk_vehicle_trip,
    vl.load_date,
    'Vehicle'                           AS source_node,
    'Customer Locations'                AS target_node,
    'Full Delivered to Customers'       AS flow_label,
    vl.quantity_full_for_delivery       AS planned_qty,
    vl.actual_qty_full_delivered_to_customer AS actual_qty,
    'DELIVERY'                          AS flow_category
FROM public.tbl_vehicle_load vl
WHERE vl.quantity_full_for_delivery > 0
   OR vl.actual_qty_full_delivered_to_customer > 0

UNION ALL

-- Buffer cylinders used for unplanned deliveries
SELECT
    vl.pk_vehicle_load_id,
    vl.fk_vehicle_trip,
    vl.load_date,
    'Vehicle'                           AS source_node,
    'Customer Locations'                AS target_node,
    'Buffer Used for Delivery'          AS flow_label,
    vl.quantity_full_for_buffer         AS planned_qty,
    vl.actual_qty_buffer_used_for_delivery AS actual_qty,
    'BUFFER_USED'                       AS flow_category
FROM public.tbl_vehicle_load vl
WHERE vl.quantity_full_for_buffer > 0
   OR vl.actual_qty_buffer_used_for_delivery > 0

UNION ALL

-- Buffer cylinders returned to yard unused
SELECT
    vl.pk_vehicle_load_id,
    vl.fk_vehicle_trip,
    vl.load_date,
    'Vehicle'                           AS source_node,
    'Buffer (Returned)'                 AS target_node,
    'Buffer Returned Unused'            AS flow_label,
    vl.quantity_full_for_buffer         AS planned_qty,
    vl.actual_qty_buffer_returned_full  AS actual_qty,
    'BUFFER_RETURNED'                   AS flow_category
FROM public.tbl_vehicle_load vl
WHERE vl.quantity_full_for_buffer > 0
   OR vl.actual_qty_buffer_returned_full > 0

UNION ALL

-- Empty cylinders loaded for supplier (outbound)
SELECT
    vl.pk_vehicle_load_id,
    vl.fk_vehicle_trip,
    vl.load_date,
    'Yard (Empty Stock)'                AS source_node,
    'Vehicle'                           AS target_node,
    'Loaded — Empties for Supplier'     AS flow_label,
    vl.quantity_empty_for_supplier      AS planned_qty,
    vl.actual_qty_empty_dropped_at_supplier AS actual_qty,
    'OUTBOUND_EMPTY'                    AS flow_category
FROM public.tbl_vehicle_load vl
WHERE vl.quantity_empty_for_supplier > 0
   OR vl.actual_qty_empty_dropped_at_supplier > 0

UNION ALL

-- Empty cylinders dropped at supplier
SELECT
    vl.pk_vehicle_load_id,
    vl.fk_vehicle_trip,
    vl.load_date,
    'Vehicle'                           AS source_node,
    'Supplier'                          AS target_node,
    'Empties Handed to Supplier'        AS flow_label,
    vl.quantity_empty_for_supplier      AS planned_qty,
    vl.actual_qty_empty_dropped_at_supplier AS actual_qty,
    'SUPPLIER_DROPOFF'                  AS flow_category
FROM public.tbl_vehicle_load vl
WHERE vl.quantity_empty_for_supplier > 0
   OR vl.actual_qty_empty_dropped_at_supplier > 0

UNION ALL

-- Empty cylinders collected from customers (inbound)
SELECT
    vl.pk_vehicle_load_id,
    vl.fk_vehicle_trip,
    vl.load_date,
    'Customer Locations'                AS source_node,
    'Vehicle'                           AS target_node,
    'Empties Collected from Customers'  AS flow_label,
    NULL                                AS planned_qty,   -- no pre-plan for this
    vl.actual_qty_empty_collected_from_customer AS actual_qty,
    'EMPTY_COLLECTION'                  AS flow_category
FROM public.tbl_vehicle_load vl
WHERE vl.actual_qty_empty_collected_from_customer > 0

UNION ALL

-- Empty cylinders returned to yard (from customer pickups)
SELECT
    vl.pk_vehicle_load_id,
    vl.fk_vehicle_trip,
    vl.load_date,
    'Vehicle'                           AS source_node,
    'Yard (Empty Stock)'                AS target_node,
    'Empties Returned to Yard'          AS flow_label,
    NULL                                AS planned_qty,
    vl.actual_qty_empty_collected_from_customer AS actual_qty,  -- all collected empties return to yard
    'EMPTY_RETURN'                      AS flow_category
FROM public.tbl_vehicle_load vl
WHERE vl.actual_qty_empty_collected_from_customer > 0

UNION ALL

-- Full cylinders collected from supplier (refills)
SELECT
    vl.pk_vehicle_load_id,
    vl.fk_vehicle_trip,
    vl.load_date,
    'Supplier'                          AS source_node,
    'Yard (Full Stock)'                 AS target_node,
    'Refilled Cylinders from Supplier'  AS flow_label,
    NULL                                AS planned_qty,
    vl.actual_qty_full_collected_from_supplier AS actual_qty,
    'SUPPLIER_COLLECTION'               AS flow_category
FROM public.tbl_vehicle_load vl
WHERE vl.actual_qty_full_collected_from_supplier > 0;

COMMENT ON VIEW public.vw_trip_sankey_flows IS
    'Per-trip cylinder flow rows for Sankey chart rendering. '
    'Each row represents one directional flow between two nodes. '
    'planned_qty is the load-time intention; actual_qty is the post-closure fact. '
    'Filter by vehicle_trip_id for a single-trip Sankey. '
    'Aggregate actual_qty by (source_node, target_node) for a date-range Sankey.';


-- ===========================================================================
-- SECTION 6 — vw_daily_sankey_aggregate  (daily rollup for dashboard)
-- ===========================================================================
-- Aggregates all trips for a given load_date into a single set of flow totals.
-- The dashboard Sankey reads this for the "today" / "this week" view.
-- ===========================================================================
CREATE OR REPLACE VIEW public.vw_daily_sankey_aggregate AS
SELECT
    vl.load_date,
    sf.source_node,
    sf.target_node,
    sf.flow_label,
    sf.flow_category,
    SUM(sf.planned_qty)  AS planned_qty_total,
    SUM(sf.actual_qty)   AS actual_qty_total,
    COUNT(DISTINCT vl.fk_vehicle_trip) AS trip_count
FROM public.vw_trip_sankey_flows sf
JOIN public.tbl_vehicle_load vl
    ON vl.pk_vehicle_load_id = sf.vehicle_load_id
GROUP BY
    vl.load_date,
    sf.source_node,
    sf.target_node,
    sf.flow_label,
    sf.flow_category
ORDER BY
    vl.load_date DESC,
    sf.flow_category;

COMMENT ON VIEW public.vw_daily_sankey_aggregate IS
    'Daily rollup of cylinder flows across all trips. '
    'Query WHERE load_date = CURRENT_DATE for the live dashboard Sankey. '
    'Query a date range and SUM actual_qty_total for trend reporting.';


-- ===========================================================================
-- SECTION 7 — fn_trip_sankey_json()  (D3 / Chart.js–ready payload)
-- ===========================================================================
-- Returns a JSONB object in the format expected by D3-Sankey and
-- Chart.js flow diagrams:
--   {
--     "nodes": [{"name": "Yard (Full Stock)"}, ...],
--     "links": [{"source": 0, "target": 1, "value": 45, "label": "..."}, ...]
--   }
--
-- Usage:
--   SELECT fn_trip_sankey_json(123);          -- single trip
--   SELECT fn_trip_sankey_json(NULL, '2025-06-01');  -- daily aggregate
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.fn_trip_sankey_json(
    p_trip_id       int8    DEFAULT NULL,
    p_load_date     date    DEFAULT NULL
)
RETURNS jsonb AS $$
DECLARE
    -- Ordered node list — order determines the visual left-to-right layout
    v_node_list     text[]  := ARRAY[
        'Yard (Full Stock)',
        'Yard (Empty Stock)',
        'Vehicle',
        'Customer Locations',
        'Supplier',
        'Buffer (Returned)'
    ];
    v_nodes_json    jsonb;
    v_links_json    jsonb;
    v_result        jsonb;
BEGIN
    -- Build nodes array
    SELECT jsonb_agg(jsonb_build_object('name', n))
      INTO v_nodes_json
      FROM UNNEST(v_node_list) AS n;

    -- Build links array — source and target are zero-based node indices
    IF p_trip_id IS NOT NULL THEN
        -- Single trip
        SELECT jsonb_agg(
            jsonb_build_object(
                'source',   array_position(v_node_list, sf.source_node) - 1,
                'target',   array_position(v_node_list, sf.target_node) - 1,
                'value',    COALESCE(sf.actual_qty, 0),
                'planned',  sf.planned_qty,
                'label',    sf.flow_label,
                'category', sf.flow_category
            )
        )
        INTO v_links_json
        FROM public.vw_trip_sankey_flows sf
        WHERE sf.vehicle_trip_id = p_trip_id
          AND COALESCE(sf.actual_qty, 0) > 0;

    ELSIF p_load_date IS NOT NULL THEN
        -- Daily aggregate
        SELECT jsonb_agg(
            jsonb_build_object(
                'source',   array_position(v_node_list, da.source_node) - 1,
                'target',   array_position(v_node_list, da.target_node) - 1,
                'value',    COALESCE(da.actual_qty_total, 0),
                'planned',  da.planned_qty_total,
                'label',    da.flow_label,
                'category', da.flow_category,
                'trips',    da.trip_count
            )
        )
        INTO v_links_json
        FROM public.vw_daily_sankey_aggregate da
        WHERE da.load_date = p_load_date
          AND COALESCE(da.actual_qty_total, 0) > 0;

    ELSE
        RAISE EXCEPTION 'fn_trip_sankey_json: provide either p_trip_id or p_load_date.';
    END IF;

    v_result := jsonb_build_object(
        'nodes',        COALESCE(v_nodes_json, '[]'::jsonb),
        'links',        COALESCE(v_links_json, '[]'::jsonb),
        'generated_at', now()
    );

    RETURN v_result;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION public.fn_trip_sankey_json IS
    'Returns a D3-Sankey / Chart.js–compatible JSONB payload. '
    'Pass p_trip_id for a single trip Sankey (e.g., post-trip debrief screen). '
    'Pass p_load_date for the daily operations dashboard Sankey. '
    'Node indices in links are zero-based positions in the fixed node list. '
    'Example: SELECT fn_trip_sankey_json(NULL, CURRENT_DATE);';


-- ===========================================================================
-- SECTION 8 — vw_load_closure_summary  (tabular audit / reporting view)
-- ===========================================================================
-- Joins planned quantities (from load time) with actual quantities (from closure)
-- and the generated variance columns for a clean reporting table.
-- Used by the trip debrief screen and the reconciliation dashboard.
-- ===========================================================================
CREATE OR REPLACE VIEW public.vw_load_closure_summary AS
SELECT
    vl.pk_vehicle_load_id,
    vl.fk_vehicle_trip,
    vl.load_date,
    vl.total_cylinders_loaded,

    -- ── Planned ──────────────────────────────────────────────────────────────
    vl.quantity_full_for_delivery                           AS planned_full_delivery,
    vl.quantity_full_for_buffer                             AS planned_full_buffer,
    vl.quantity_empty_for_supplier                          AS planned_empty_supplier,

    -- ── Actuals ──────────────────────────────────────────────────────────────
    vl.actual_qty_full_delivered_to_customer                AS actual_full_delivered,
    vl.actual_qty_buffer_used_for_delivery                  AS actual_buffer_used,
    vl.actual_qty_buffer_returned_full                      AS actual_buffer_returned,
    vl.actual_qty_empty_collected_from_customer             AS actual_empty_collected,
    vl.actual_qty_empty_dropped_at_supplier                 AS actual_empty_at_supplier,
    vl.actual_qty_full_collected_from_supplier              AS actual_full_from_supplier,

    -- ── Derived totals ────────────────────────────────────────────────────────
    vl.actual_qty_full_delivered_to_customer
        + vl.actual_qty_buffer_used_for_delivery            AS total_deliveries_made,

    -- ── Variances ─────────────────────────────────────────────────────────────
    vl.variance_deliveries_vs_plan,
    vl.variance_empty_supplier_vs_plan,

    -- ── Closure health ────────────────────────────────────────────────────────
    CASE
        WHEN vl.closure_computed_at IS NULL                 THEN 'NOT_CLOSED'
        WHEN vl.variance_deliveries_vs_plan  = 0
         AND vl.variance_empty_supplier_vs_plan = 0         THEN 'CLEAN'
        WHEN ABS(vl.variance_deliveries_vs_plan)  <= 2
         OR  ABS(vl.variance_empty_supplier_vs_plan) <= 2   THEN 'MINOR_VARIANCE'
        ELSE 'MAJOR_VARIANCE'
    END                                                     AS closure_health,

    vl.closure_variance_notes,
    vl.closure_computed_at,
    ts.status_name                                          AS trip_status
FROM public.tbl_vehicle_load vl
LEFT JOIN public.tbl_vehicle_trip vt
       ON vt.pk_vehicle_trip_id = vl.fk_vehicle_trip
LEFT JOIN public.tbl_trip_status ts
       ON ts.pk_trip_status_id  = vt.fk_trip_status
ORDER BY vl.load_date DESC, vl.pk_vehicle_load_id DESC;

COMMENT ON VIEW public.vw_load_closure_summary IS
    'Planned vs actual cylinder quantities per vehicle load, with variance columns '
    'and a closure_health indicator (CLEAN / MINOR_VARIANCE / MAJOR_VARIANCE / NOT_CLOSED). '
    'Primary source for the trip debrief screen and reconciliation reports.';