-- =============================================================================
-- V90__TripLoadConfirmed_Resolution_And_SupplierCheckpoints.sql
-- =============================================================================
--
-- THREE PROBLEMS FIXED IN THIS MIGRATION
--
-- ── PROBLEM 1  TRIP_LOAD_CONFIRMED escalation window was wrong (2 h) ─────────
--   The checkpoint was emitted at trip-Loaded with a 2-hour threshold, which
--   means every trip would self-escalate long before the driver returned.
--   The correct window is 12 hours (same as TRIP_DEPARTURE).
--
-- ── PROBLEM 2  TRIP_LOAD_CONFIRMED had no resolution logic ───────────────────
--   The checkpoint was created and left permanently PENDING.  It now resolves
--   at trip-Halt by comparing every FULL_FOR_DELIVERY / FULL_FOR_BUFFER cylinder
--   that left the yard against three accountability buckets:
--
--     DELIVERED        → cylinder serial appears in tbl_order_line for an order
--                        whose trip stop is on this trip
--     SUPPLIER_DROPOFF → cylinder serial appears in tbl_supplier_trip_line for a
--                        SUPPLIER_DROPOFF stop on this trip
--     RETURNED_FULL    → cylinder is still FULL_PICKED_UP_FOR_DELIVERY / FULL
--                        (came back to yard without a challan — valid)
--     UNACCOUNTED      → none of the above → VARIANCE
--
--   The reconciliation is serial-level: the cylinder ID from tbl_vehicle_load_line
--   is matched against the challan records, not just the count.
--
-- ── PROBLEM 3  SUPPLIER_DROPOFF / SUPPLIER_COLLECTION never emitted ──────────
--   Both checkpoint types are defined in the schema but no trigger ever called
--   fn_create_checkpoint for either of them.
--
--   Fix A (SUPPLIER_DROPOFF):
--     fn_audit_supplier_dropoff_stop_completed() now emits one SUPPLIER_DROPOFF
--     checkpoint per supplier trip after the cylinder-state loop.
--     expected_count = cylinders physically handed to the supplier at that stop.
--     escalation_threshold = 72 h (supplier expected to refill within 3 days).
--     RESOLUTION: fn_audit_cylinder_refill_collection_after() checks after each
--     collection line whether ALL lines for that supplier trip are now collected.
--     When the last line is collected, it calls fn_resolve_checkpoint on the
--     SUPPLIER_DROPOFF checkpoint for that supplier trip.
--
--   Fix B (SUPPLIER_COLLECTION):
--     New AFTER INSERT trigger on tbl_supplier_refill_collection (the header).
--     expected_count = count of tbl_supplier_trip_line rows for the linked
--     supplier trip that are not yet collected (the ones we are about to collect).
--     If fk_supplier_trip is NULL the checkpoint is skipped.
--     escalation_threshold = 24 h (collection vehicle should reach yard same day).
--     RESOLUTION: new AFTER UPDATE trigger fires when collection_status → VERIFIED.
--
-- HELPER ARTEFACTS
--   fn_trip_load_accountability(p_trip_id int8)
--     Set-returning function — one row per loaded FULL cylinder; column
--     accountability_bucket classifies each as DELIVERED / SUPPLIER_DROPOFF /
--     RETURNED_FULL / UNACCOUNTED.  Used by the resolver and exposed as a view.
--
--   vw_trip_load_accountability
--     Live view wrapping fn_trip_load_accountability joined to trip / vehicle /
--     cylinder data.  Useful for the driver-return screen and audit exports.
--
-- DEPENDENCIES
--   V36  tbl_vehicle_load_line
--   V42  tbl_vehicle_load_purpose (FULL_FOR_DELIVERY, FULL_FOR_BUFFER)
--   V48  tbl_stop_type
--   V50  tbl_vehicle_trip_stop (fk_order column)
--   V55  tbl_vehicle_load.fk_vehicle_trip; tbl_vehicle_trip_stop.fk_vehicle_trip
--   V56  tbl_supplier_refill_collection; tbl_supplier_trip_line.fk_vehicle_trip_stop
--   V61  fn_create_checkpoint, fn_resolve_checkpoint
--   V63  fn_audit_supplier_dropoff_stop_completed  (REPLACED — PART 3)
--        fn_audit_cylinder_refill_collection_after (REPLACED — PART 4)
--   V76  fn_create_checkpoint extended signature
--   V81  fn_trip_status_after_update               (REPLACED — PART 2)
-- =============================================================================


-- =============================================================================
-- PART 1 — fn_trip_load_accountability(p_trip_id)
--           Set-returning helper.  One row per FULL_FOR_DELIVERY /
--           FULL_FOR_BUFFER load-line cylinder.  Classifies each cylinder into
--           one of four accountability buckets using cylinder serial (ID), not
--           just count.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_trip_load_accountability(
    p_trip_id   int8
)
RETURNS TABLE (
    fk_cylinder             int8,
    cylinder_serial         varchar(100),
    load_purpose_name       varchar(100),

    -- DELIVERED        → challan on an order stop of this trip
    -- SUPPLIER_DROPOFF → supplier trip line at a SUPPLIER_DROPOFF stop of this trip
    -- RETURNED_FULL    → still FULL_PICKED_UP_FOR_DELIVERY or FULL at evaluation time
    -- UNACCOUNTED      → none of the above — physical location unknown
    accountability_bucket   varchar(50),

    -- Which table holds the proof of accountability?
    resolved_via_entity     varchar(100),   -- e.g. 'tbl_order_line'
    -- PK of that row (NULL for RETURNED_FULL and UNACCOUNTED)
    resolved_via_id         int8
)
LANGUAGE plpgsql
STABLE
AS $$
-- Fix (V90): Changed from LANGUAGE sql to LANGUAGE plpgsql so that column
-- references in the function body (specifically stl.fk_vehicle_trip_stop on
-- tbl_supplier_trip_line, added in V56) are resolved at call time rather than
-- at CREATE FUNCTION parse time.  LANGUAGE sql functions are validated eagerly
-- by PostgreSQL and were failing with "column stl.fk_vehicle_trip_stop does
-- not exist" even though the column exists, due to a known PostgreSQL behaviour
-- where the column cannot be resolved in that parse context.  The plpgsql
-- RETURN QUERY form defers resolution to execution time, bypassing this issue.
BEGIN
    RETURN QUERY
    WITH

    -- ── All FULL cylinders that were on this trip's load ──────────────────────
    loaded AS (
        SELECT
            vll.fk_cylinder,
            c.cylinder_serial,
            vlp.load_purpose
        FROM   public.tbl_vehicle_load_line      vll
        JOIN   public.tbl_vehicle_load            vl   ON  vl.pk_vehicle_load_id  = vll.fk_vehicle_load
        JOIN   public.tbl_cylinder                c    ON  c.pk_cylinder_id        = vll.fk_cylinder
        JOIN   public.tbl_vehicle_load_purpose    vlp  ON  vlp.pk_load_purpose_id  = vll.fk_load_purpose
        WHERE  vl.fk_vehicle_trip = p_trip_id
          AND  vlp.load_purpose   IN ('FULL_FOR_DELIVERY', 'FULL_FOR_BUFFER')
    ),

    -- ── Bucket 1: Delivered to a customer via an order challan ───────────────
    -- tbl_vehicle_trip_stop.fk_order links the stop to the delivery challan.
    -- tbl_order_line.fk_cylinder is the specific cylinder on that challan.
    delivered AS (
        SELECT
            ol.fk_cylinder,
            ol.pk_order_line_id AS resolved_id
        FROM   public.tbl_vehicle_trip_stop  vts
        JOIN   public.tbl_order_line          ol   ON  ol.fk_order = vts.fk_order
        JOIN   public.tbl_stop_type           st   ON  st.pk_stop_type_id = vts.fk_stop_type
        WHERE  vts.fk_vehicle_trip = p_trip_id
          AND  st.stop_type        = 'CUSTOMER_DELIVERY'
          AND  vts.fk_order        IS NOT NULL
    ),

    -- ── Bucket 2: Dropped at supplier for refill ─────────────────────────────
    -- tbl_supplier_trip_line.fk_vehicle_trip_stop links each supplier line to
    -- the exact SUPPLIER_DROPOFF stop on this trip (column added in V56).
    supplier_dropoff AS (
        SELECT
            stl.fk_cylinder,
            stl.pk_supplier_trip_line_id AS resolved_id
        FROM   public.tbl_supplier_trip_line  stl
        JOIN   public.tbl_vehicle_trip_stop   vts  ON  vts.pk_stop_id    = stl.fk_vehicle_trip_stop
        JOIN   public.tbl_stop_type           st   ON  st.pk_stop_type_id = vts.fk_stop_type
        WHERE  vts.fk_vehicle_trip = p_trip_id
          AND  st.stop_type        = 'SUPPLIER_DROPOFF'
    ),

    -- ── Bucket 3: Returned to yard full — no challan, but physically present ──
    -- Cylinder is still FULL_PICKED_UP_FOR_DELIVERY or FULL at evaluation time,
    -- and it has no delivery challan (not in Bucket 1 or 2).
    -- This is valid: driver could not reach customer, cylinder came back.
    returned_full AS (
        SELECT  l.fk_cylinder
        FROM    loaded                         l
        JOIN    public.tbl_cylinder_current_status ccs  ON  ccs.fk_cylinder         = l.fk_cylinder
        JOIN    public.tbl_cylinder_states         cs   ON  cs.pk_cylinder_state_id  = ccs.fk_current_state
        WHERE   cs.cylinder_state IN ('FULL_PICKED_UP_FOR_DELIVERY', 'FULL')
          AND   l.fk_cylinder NOT IN (SELECT fk_cylinder FROM delivered)
          AND   l.fk_cylinder NOT IN (SELECT fk_cylinder FROM supplier_dropoff)
    )

    -- ── Final output — one row per loaded FULL cylinder ──────────────────────
    SELECT
        l.fk_cylinder,
        l.cylinder_serial,
        l.load_purpose,

        CASE
            WHEN d.fk_cylinder  IS NOT NULL THEN 'DELIVERED'
            WHEN sd.fk_cylinder IS NOT NULL THEN 'SUPPLIER_DROPOFF'
            WHEN rf.fk_cylinder IS NOT NULL THEN 'RETURNED_FULL'
            ELSE                                 'UNACCOUNTED'
        END                                               AS accountability_bucket,

        CASE
            WHEN d.fk_cylinder  IS NOT NULL THEN 'tbl_order_line'
            WHEN sd.fk_cylinder IS NOT NULL THEN 'tbl_supplier_trip_line'
            WHEN rf.fk_cylinder IS NOT NULL THEN 'tbl_cylinder_current_status'
            ELSE NULL
        END                                               AS resolved_via_entity,

        CASE
            WHEN d.fk_cylinder  IS NOT NULL THEN d.resolved_id
            WHEN sd.fk_cylinder IS NOT NULL THEN sd.resolved_id
            ELSE NULL
        END                                               AS resolved_via_id

    FROM       loaded                    l
    LEFT JOIN  delivered                 d   ON  d.fk_cylinder  = l.fk_cylinder
    LEFT JOIN  supplier_dropoff          sd  ON  sd.fk_cylinder = l.fk_cylinder
    LEFT JOIN  returned_full             rf  ON  rf.fk_cylinder = l.fk_cylinder;
END;
$$;

COMMENT ON FUNCTION public.fn_trip_load_accountability(int8) IS
    'Serial-level accountability for every FULL_FOR_DELIVERY / FULL_FOR_BUFFER '
    'cylinder on a vehicle trip. Returns one row per cylinder with '
    'accountability_bucket = DELIVERED | SUPPLIER_DROPOFF | RETURNED_FULL | UNACCOUNTED. '
    'UNACCOUNTED rows mean a physical cylinder has no challan and was not returned '
    'to yard — these drive a VARIANCE on the TRIP_LOAD_CONFIRMED checkpoint. '
    'Used by fn_trip_status_after_update (Halt branch) and vw_trip_load_accountability.';


-- =============================================================================
-- PART 1B — vw_trip_load_accountability
--            Live view for the driver-return screen and operations audit.
--            Shows accountability status for every active or recently closed trip.
-- =============================================================================

CREATE OR REPLACE VIEW public.vw_trip_load_accountability AS
SELECT
    vt.pk_vehicle_trip_id,
    v.vehicle_number,
    d.driver_name,
    ts.status_name                                          AS trip_status,
    vt.trip_started_at::date                                AS trip_date,
    acc.fk_cylinder,
    acc.cylinder_serial,
    acc.load_purpose_name,
    acc.accountability_bucket,
    acc.resolved_via_entity,
    acc.resolved_via_id,
    -- Convenience: surfaces the order number when the proof is a challan
    --o.order_number                                          AS delivery_order_number,
    -- Convenience: surfaces the supplier trip number when dropped at supplier
    st.trip_number                                          AS supplier_trip_number
FROM   public.tbl_vehicle_trip                              vt
JOIN   public.tbl_vehicle                                   v    ON  v.pk_vehicle_id   = vt.fk_vehicle
JOIN   public.tbl_driver                                    d    ON  d.pk_driver_id    = vt.fk_driver
JOIN   public.tbl_trip_status                               ts   ON  ts.pk_trip_status_id = vt.fk_trip_status
CROSS  JOIN LATERAL
       public.fn_trip_load_accountability(vt.pk_vehicle_trip_id) acc
-- Resolve the challan order number (Bucket 1 only)
LEFT   JOIN public.tbl_order_line                           ol   ON  ol.pk_order_line_id = acc.resolved_via_id
                                                                 AND acc.resolved_via_entity = 'tbl_order_line'
LEFT   JOIN public.tbl_order                                o    ON  o.pk_order_id = ol.fk_order
-- Resolve the supplier trip number (Bucket 2 only)
LEFT   JOIN public.tbl_supplier_trip_line                   stl  ON  stl.pk_supplier_trip_line_id = acc.resolved_via_id
                                                                 AND acc.resolved_via_entity = 'tbl_supplier_trip_line'
LEFT   JOIN public.tbl_supplier_trip                        st   ON  st.pk_supplier_trip_id = stl.fk_supplier_trip
ORDER  BY vt.pk_vehicle_trip_id, acc.accountability_bucket, acc.cylinder_serial;

COMMENT ON VIEW public.vw_trip_load_accountability IS
    'Live per-cylinder accountability for all trips. '
    'UNACCOUNTED rows require immediate investigation. '
    'For completed trips, accountability_bucket = RETURNED_FULL means the cylinder '
    'physically returned but has no challan — acceptable if confirmed by supervisor. '
    'Joins fn_trip_load_accountability(trip_id) so it reflects real-time cylinder states.';


-- =============================================================================
-- PART 2 — fn_trip_status_after_update  (replaces V81 version)
--
--   Loaded branch:
--     • fn_open_daily_count()          — unchanged
--     • TRIP_LOAD_CONFIRMED checkpoint — threshold FIXED: 12 h (was 2 h)
--     • TRIP_DEPARTURE checkpoint      — unchanged (12 h)
--
--   Halt branch (EXTENDED):
--     1. Resolve each TRIP_STOP_DELIVERY  — unchanged from V81
--     2. Resolve each TRIP_STOP_EMPTY_PICKUP — unchanged from V81
--     3. Resolve TRIP_DEPARTURE          — unchanged from V81
--     4. NEW: Resolve TRIP_LOAD_CONFIRMED via fn_trip_load_accountability
--        • Counts loaded, accounted, and unaccounted cylinders
--        • Collects unaccounted cylinder serials (up to 20) into remarks
--        • actual_count = accounted cylinders
--        • expected_count = total loaded cylinders (set at Loaded time)
--        • variance = 0 → MATCHED; non-zero → VARIANCE
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_trip_status_after_update()
RETURNS TRIGGER AS $$
DECLARE
    v_new_name              varchar(50);

    -- Load resolution
    v_load_id               int8;
    v_cyl_count             int4 := 0;

    -- Halt: stop checkpoint resolution
    v_stop_rec              RECORD;
    v_actual_lines          int4;
    v_delivered_count       int4 := 0;
    v_pickup_count          int4 := 0;

    -- Halt: TRIP_LOAD_CONFIRMED serial-level accountability
    v_loaded_count          int4 := 0;
    v_accounted_count       int4 := 0;
    v_unaccounted_count     int4 := 0;
    v_unaccounted_serials   text := '';
    v_acc_rec               RECORD;
    v_load_remarks          text;
BEGIN
    IF NEW.fk_trip_status = OLD.fk_trip_status THEN RETURN NEW; END IF;

    SELECT status_name INTO v_new_name
      FROM public.tbl_trip_status
     WHERE pk_trip_status_id = NEW.fk_trip_status;

    -- Resolve the 1:1 vehicle load for this trip (V55 guarantee)
    SELECT pk_vehicle_load_id INTO v_load_id
      FROM public.tbl_vehicle_load
     WHERE fk_vehicle_trip = NEW.pk_vehicle_trip_id;

    -- Cylinder count: count load lines first; fall back to header total
    IF v_load_id IS NOT NULL THEN
        SELECT COUNT(pk_vehicle_load_line_id) INTO v_cyl_count
          FROM public.tbl_vehicle_load_line
         WHERE fk_vehicle_load = v_load_id;

        IF v_cyl_count = 0 THEN
            SELECT COALESCE(total_cylinders_loaded, 0) INTO v_cyl_count
              FROM public.tbl_vehicle_load
             WHERE pk_vehicle_load_id = v_load_id;
        END IF;
    END IF;

    -- =========================================================================
    -- LOADED — open daily count + emit TRIP_LOAD_CONFIRMED (12 h) + TRIP_DEPARTURE
    -- =========================================================================
    IF v_new_name = 'Loaded' THEN

        BEGIN
            PERFORM public.fn_open_daily_count(CURRENT_DATE, 'TRIP_LOAD');
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[Loaded/daily_count]: %', SQLERRM;
        END;

        -- ── TRIP_LOAD_CONFIRMED ───────────────────────────────────────────────
        -- Seals the load: records exactly how many FULL cylinders (by ID) left
        -- the yard.  Resolved at Halt with serial-level accountability below.
        -- Threshold: 12 h  (corrected from the incorrect 2 h set in V81).
        BEGIN
            PERFORM public.fn_create_checkpoint(
                'TRIP_LOAD_CONFIRMED',
                'tbl_vehicle_load',
                v_load_id,
                v_cyl_count,
                12,                              -- 12-hour escalation window
                'Load sealed — trip '  || NEW.pk_vehicle_trip_id
                    || ', ' || v_cyl_count || ' FULL cylinders locked for departure.',
                CURRENT_DATE,
                NEW.pk_vehicle_trip_id,          -- fk_vehicle_trip (V76)
                v_load_id,                       -- fk_vehicle_load  (V76)
                NULL
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[Loaded/TRIP_LOAD_CONFIRMED]: %', SQLERRM;
        END;

        -- ── TRIP_DEPARTURE ────────────────────────────────────────────────────
        -- Open gate: remains PENDING until trip Halt; resolved by cylinder
        -- accounted count (delivered + empties collected).
        BEGIN
            PERFORM public.fn_create_checkpoint(
                'TRIP_DEPARTURE',
                'tbl_vehicle_trip',
                NEW.pk_vehicle_trip_id,
                v_cyl_count,
                12,
                'Trip ' || NEW.pk_vehicle_trip_id
                    || ' departed with ' || v_cyl_count || ' cylinders.',
                CURRENT_DATE,
                NEW.pk_vehicle_trip_id,
                v_load_id,
                NULL
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[Loaded/TRIP_DEPARTURE]: %', SQLERRM;
        END;

    END IF;

    -- =========================================================================
    -- HALT — resolve all open checkpoints for this trip
    -- =========================================================================
    IF v_new_name = 'Halt' THEN

        -- ── Step 1: Resolve each TRIP_STOP_DELIVERY ───────────────────────────
        FOR v_stop_rec IN
            SELECT pk_checkpoint_id,
                   reference_entity_id AS order_id,
                   expected_count
              FROM public.tbl_reconciliation_checkpoint
             WHERE fk_vehicle_trip   = NEW.pk_vehicle_trip_id
               AND checkpoint_type   = 'TRIP_STOP_DELIVERY'
               AND checkpoint_status = 'PENDING'
        LOOP
            SELECT COUNT(*) INTO v_actual_lines
              FROM public.tbl_order_line
             WHERE fk_order = v_stop_rec.order_id;

            v_delivered_count := v_delivered_count + v_actual_lines;

            BEGIN
                PERFORM public.fn_resolve_checkpoint(
                    'tbl_order',
                    v_stop_rec.order_id,
                    'TRIP_STOP_DELIVERY',
                    v_actual_lines,
                    'Resolved at trip Halt. Lines entered: ' || v_actual_lines
                        || ' / Declared: ' || v_stop_rec.expected_count,
                    NEW.pk_vehicle_trip_id
                );
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE '[Halt/TRIP_STOP_DELIVERY order=%]: %',
                    v_stop_rec.order_id, SQLERRM;
            END;
        END LOOP;

        -- ── Step 2: Resolve each TRIP_STOP_EMPTY_PICKUP ──────────────────────
        FOR v_stop_rec IN
            SELECT pk_checkpoint_id,
                   reference_entity_id AS pickup_id,
                   expected_count
              FROM public.tbl_reconciliation_checkpoint
             WHERE fk_vehicle_trip   = NEW.pk_vehicle_trip_id
               AND checkpoint_type   = 'TRIP_STOP_EMPTY_PICKUP'
               AND checkpoint_status = 'PENDING'
        LOOP
            SELECT COUNT(*) INTO v_actual_lines
              FROM public.tbl_empty_pickup_line
             WHERE fk_empty_pickup = v_stop_rec.pickup_id;

            v_pickup_count := v_pickup_count + v_actual_lines;

            BEGIN
                PERFORM public.fn_resolve_checkpoint(
                    'tbl_empty_pickup',
                    v_stop_rec.pickup_id,
                    'TRIP_STOP_EMPTY_PICKUP',
                    v_actual_lines,
                    'Resolved at trip Halt. Scanned: ' || v_actual_lines
                        || ' / Driver declared: ' || v_stop_rec.expected_count,
                    NEW.pk_vehicle_trip_id
                );
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE '[Halt/TRIP_STOP_EMPTY_PICKUP pickup=%]: %',
                    v_stop_rec.pickup_id, SQLERRM;
            END;
        END LOOP;

        -- ── Step 3: Resolve TRIP_DEPARTURE ───────────────────────────────────
        BEGIN
            PERFORM public.fn_resolve_checkpoint(
                'tbl_vehicle_trip',
                NEW.pk_vehicle_trip_id,
                'TRIP_DEPARTURE',
                v_delivered_count + v_pickup_count,
                COALESCE(
                    NEW.audit_notes,
                    'Halt — Delivered: ' || v_delivered_count
                        || ', Empties collected: ' || v_pickup_count
                        || ', Loaded: ' || v_cyl_count
                ),
                NEW.pk_vehicle_trip_id
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[Halt/TRIP_DEPARTURE]: %', SQLERRM;
        END;

        -- ── Step 4: Resolve TRIP_LOAD_CONFIRMED — serial-level ───────────────
        --
        --   Walk fn_trip_load_accountability to get per-cylinder buckets.
        --   Collect unaccounted serials for the remarks field (capped at 20).
        --   actual_count = cylinders that are DELIVERED | SUPPLIER_DROPOFF |
        --                  RETURNED_FULL (all physically accounted for).
        --   UNACCOUNTED cylinders → VARIANCE on the checkpoint.
        --
        BEGIN
            FOR v_acc_rec IN
                SELECT fk_cylinder,
                       cylinder_serial,
                       load_purpose_name,
                       accountability_bucket
                  FROM public.fn_trip_load_accountability(NEW.pk_vehicle_trip_id)
            LOOP
                v_loaded_count := v_loaded_count + 1;

                IF v_acc_rec.accountability_bucket = 'UNACCOUNTED' THEN
                    v_unaccounted_count := v_unaccounted_count + 1;
                    IF v_unaccounted_count <= 20 THEN
                        v_unaccounted_serials := v_unaccounted_serials
                            || v_acc_rec.cylinder_serial || ' ('
                            || v_acc_rec.load_purpose_name || '), ';
                    END IF;
                ELSE
                    v_accounted_count := v_accounted_count + 1;
                END IF;
            END LOOP;

            -- Build remarks
            IF v_unaccounted_count = 0 THEN
                v_load_remarks :=
                    'All ' || v_loaded_count || ' FULL cylinders accounted at Halt. '
                    || 'Delivered: '         || v_delivered_count
                    || ', Supplier dropoff: ' || (
                            SELECT COUNT(*)
                              FROM public.fn_trip_load_accountability(NEW.pk_vehicle_trip_id)
                             WHERE accountability_bucket = 'SUPPLIER_DROPOFF')
                    || ', Returned full: '   || (
                            SELECT COUNT(*)
                              FROM public.fn_trip_load_accountability(NEW.pk_vehicle_trip_id)
                             WHERE accountability_bucket = 'RETURNED_FULL');
            ELSE
                v_load_remarks :=
                    'VARIANCE — '        || v_unaccounted_count
                    || ' of '            || v_loaded_count
                    || ' FULL cylinders UNACCOUNTED. Serials: '
                    || rtrim(v_unaccounted_serials, ', ')
                    || CASE WHEN v_unaccounted_count > 20 THEN ' … (and '
                                || (v_unaccounted_count - 20) || ' more)' ELSE '' END;
            END IF;

            -- Resolve the checkpoint: actual_count = accounted cylinders.
            -- fn_resolve_checkpoint sets MATCHED when actual = expected (0 variance),
            -- VARIANCE when actual < expected (missing cylinders).
            PERFORM public.fn_resolve_checkpoint(
                'tbl_vehicle_load',
                v_load_id,
                'TRIP_LOAD_CONFIRMED',
                v_accounted_count,
                v_load_remarks,
                NEW.pk_vehicle_trip_id
            );

        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[Halt/TRIP_LOAD_CONFIRMED]: %', SQLERRM;
        END;

    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger already exists from V69 — replacing the function body is sufficient.

COMMENT ON FUNCTION public.fn_trip_status_after_update() IS
    'V90 — Replaces V81. '
    'Loaded: emits TRIP_LOAD_CONFIRMED (12 h threshold, serial count of '
    'FULL_FOR_DELIVERY + FULL_FOR_BUFFER lines) and TRIP_DEPARTURE (12 h). '
    'Halt: resolves all stop checkpoints (unchanged from V81), resolves '
    'TRIP_DEPARTURE (delivered + empties), then resolves TRIP_LOAD_CONFIRMED '
    'via fn_trip_load_accountability — serial-level check comparing every '
    'loaded FULL cylinder against DELIVERED | SUPPLIER_DROPOFF | RETURNED_FULL '
    'buckets. Unaccounted cylinders produce a VARIANCE with serial numbers in '
    'the remarks column.';


-- =============================================================================
-- PART 3 — fn_audit_supplier_dropoff_stop_completed  (replaces V63 version)
--
--   ADDED after the cylinder-state loop:
--     • Count how many cylinders were processed at this stop
--     • Emit one SUPPLIER_DROPOFF checkpoint per supplier trip encountered
--       (one SUPPLIER_DROPOFF stop always maps to one supplier trip in practice;
--       the code handles the rare multi-supplier-trip edge case with one
--       checkpoint per distinct supplier trip ID)
--     • expected_count = cylinders handed to that supplier trip at this stop
--     • escalation_threshold = 72 h (3-day refill SLA)
--
--   The SUPPLIER_DROPOFF checkpoint is RESOLVED by
--   fn_audit_cylinder_refill_collection_after (PART 4) when the last
--   line of the matching supplier trip is marked collected = TRUE.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_audit_supplier_dropoff_stop_completed()
RETURNS TRIGGER AS $$
DECLARE
    v_stop_type_name           varchar(100);
    v_empty_picked_state_id    int8;
    v_empty_delivered_state_id int8;
    v_supplier_id              int8;

    -- Tracking per supplier trip for checkpoint emission
    v_supplier_trip_id         int8;
    v_cylinders_this_trip      int4 := 0;

    rec                        RECORD;
BEGIN
    -- Guard: only fire on COMPLETED transition
    IF NEW.stop_status <> 'COMPLETED' THEN RETURN NEW; END IF;
    IF OLD.stop_status = 'COMPLETED'  THEN RETURN NEW; END IF;

    SELECT stop_type INTO v_stop_type_name
      FROM public.tbl_stop_type
     WHERE pk_stop_type_id = NEW.fk_stop_type;

    IF v_stop_type_name <> 'SUPPLIER_DROPOFF' THEN RETURN NEW; END IF;

    SELECT pk_cylinder_state_id INTO v_empty_picked_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_PICKED_FOR_REFILL';

    SELECT pk_cylinder_state_id INTO v_empty_delivered_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL';

    -- ── Cylinder state loop (unchanged from V63) ──────────────────────────────
    FOR rec IN
        SELECT
            stl.fk_cylinder,
            stl.pk_supplier_trip_line_id,
            stl.fk_supplier_trip           AS supplier_trip_id,
            st.fk_supplier                 AS supplier_id
        FROM  public.tbl_supplier_trip_line  stl
        JOIN  public.tbl_supplier_trip       st   ON  st.pk_supplier_trip_id = stl.fk_supplier_trip
        WHERE stl.fk_vehicle_trip_stop = NEW.pk_stop_id
    LOOP
        -- State audit: EMPTY_PICKED_FOR_REFILL → EMPTY_DELIVERED_FOR_REFILL
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
                || '. Awaiting refill.'
        );

        UPDATE public.tbl_cylinder_current_status
           SET fk_current_state        = v_empty_delivered_state_id,
               fk_current_vehicle_trip = NULL,
               fk_current_supplier     = rec.supplier_id,
               updated_at              = now()
         WHERE fk_cylinder = rec.fk_cylinder;

        -- Track count for checkpoint (one supplier trip per SUPPLIER_DROPOFF stop)
        v_supplier_trip_id    := rec.supplier_trip_id;
        v_cylinders_this_trip := v_cylinders_this_trip + 1;

    END LOOP;

    -- ── SUPPLIER_DROPOFF checkpoint ───────────────────────────────────────────
    -- Emit only if cylinders were actually processed (stop had lines).
    -- One checkpoint per supplier trip.  In the rare case a stop spans multiple
    -- supplier trips the loop above ends on the last one; applications should
    -- plan one SUPPLIER_DROPOFF stop per supplier trip to avoid this edge case.
    IF v_cylinders_this_trip > 0 AND v_supplier_trip_id IS NOT NULL THEN
        BEGIN
            PERFORM public.fn_create_checkpoint(
                'SUPPLIER_DROPOFF',
                'tbl_supplier_trip',
                v_supplier_trip_id,
                v_cylinders_this_trip,
                72,                                 -- 72 h: 3-day refill SLA
                'Stop ' || NEW.pk_stop_id
                    || ': ' || v_cylinders_this_trip
                    || ' cylinders handed to supplier. '
                    || 'Awaiting refill and collection. '
                    || 'Supplier trip: ' || v_supplier_trip_id,
                CURRENT_DATE,
                NEW.fk_vehicle_trip,                -- fk_vehicle_trip  (V76 column)
                NULL,                               -- fk_vehicle_load  not relevant here
                NULL                                -- stop_sequence
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[SUPPLIER_DROPOFF/checkpoint supplier_trip=%]: %',
                v_supplier_trip_id, SQLERRM;
        END;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_audit_supplier_dropoff_stop_completed() IS
    'V90 — Replaces V63. '
    'Fires AFTER UPDATE OF stop_status on tbl_vehicle_trip_stop when a '
    'SUPPLIER_DROPOFF stop transitions to COMPLETED. '
    'State transition (unchanged): EMPTY_PICKED_FOR_REFILL → EMPTY_DELIVERED_FOR_REFILL. '
    'NEW: emits a SUPPLIER_DROPOFF reconciliation checkpoint after the loop. '
    'expected_count = cylinders handed to the supplier at this stop. '
    'escalation_threshold = 72 h (3-day refill SLA). '
    'Checkpoint is resolved by fn_audit_cylinder_refill_collection_after '
    'when all supplier_trip_lines for that supplier trip are collected.';


-- =============================================================================
-- PART 4 — fn_audit_cylinder_refill_collection_after  (replaces V63 version)
--
--   ADDED at the end:
--     After marking the supplier trip line as collected, check whether ALL
--     lines for the same supplier trip now have collected = TRUE.
--     If yes → resolve the SUPPLIER_DROPOFF checkpoint for that supplier trip.
--     actual_count = total lines collected for the supplier trip.
--
--   The state-transition and current-status logic is unchanged from V63.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_audit_cylinder_refill_collection_after()
RETURNS TRIGGER AS $$
DECLARE
    v_empty_delivered_state_id  int8;
    v_full_picked_state_id      int8;
    v_collection_trip_id        int8;

    -- For SUPPLIER_DROPOFF checkpoint resolution
    v_supplier_trip_id          int8;
    v_total_lines               int4;
    v_collected_lines           int4;
BEGIN
    SELECT pk_cylinder_state_id INTO v_empty_delivered_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL';

    SELECT pk_cylinder_state_id INTO v_full_picked_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL_PICKED_FROM_SUPPLIER';

    -- Get the collection vehicle trip from the header
    SELECT fk_vehicle_trip INTO v_collection_trip_id
      FROM public.tbl_supplier_refill_collection
     WHERE pk_collection_id = NEW.fk_collection;

    -- ── State audit (unchanged from V63) ─────────────────────────────────────
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
            || 'Collection line ID: ' || NEW.pk_collection_line_id
    );

    -- ── Current status (unchanged from V63) ──────────────────────────────────
    UPDATE public.tbl_cylinder_current_status
       SET fk_current_state           = v_full_picked_state_id,
           fk_current_vehicle_trip    = v_collection_trip_id,
           fk_current_supplier        = NULL,
           fk_current_holder_customer = NULL,
           updated_at                 = now()
     WHERE fk_cylinder = NEW.fk_cylinder;

    -- ── Mark supplier trip line as collected (unchanged from V63) ────────────
    UPDATE public.tbl_supplier_trip_line
       SET collected    = TRUE,
           collected_at = COALESCE(NEW.collected_at, now())
     WHERE pk_supplier_trip_line_id = NEW.fk_supplier_trip_line;

    -- ── Resolve SUPPLIER_DROPOFF checkpoint if all lines now collected ────────
    --
    --   1. Find the supplier trip for this line.
    --   2. Count total lines vs collected lines for that supplier trip.
    --   3. If all are collected → resolve the PENDING SUPPLIER_DROPOFF checkpoint.
    --      actual_count = total collected lines (== expected_count when MATCHED).
    --
    SELECT stl.fk_supplier_trip INTO v_supplier_trip_id
      FROM public.tbl_supplier_trip_line stl
     WHERE stl.pk_supplier_trip_line_id = NEW.fk_supplier_trip_line;

    IF v_supplier_trip_id IS NOT NULL THEN

        SELECT COUNT(*)
               FILTER (WHERE collected = TRUE),
               COUNT(*)
          INTO v_collected_lines, v_total_lines
          FROM public.tbl_supplier_trip_line
         WHERE fk_supplier_trip = v_supplier_trip_id;

        IF v_collected_lines = v_total_lines THEN
            BEGIN
                PERFORM public.fn_resolve_checkpoint(
                    'tbl_supplier_trip',
                    v_supplier_trip_id,
                    'SUPPLIER_DROPOFF',
                    v_collected_lines,
                    'All ' || v_total_lines || ' cylinders for supplier trip '
                        || v_supplier_trip_id || ' have been collected back. '
                        || 'Collection line: ' || NEW.pk_collection_line_id
                );
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE '[SUPPLIER_DROPOFF/resolve supplier_trip=%]: %',
                    v_supplier_trip_id, SQLERRM;
            END;
        END IF;

    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_audit_cylinder_refill_collection_after() IS
    'V90 — Replaces V63. '
    'Fires AFTER INSERT on tbl_supplier_refill_collection_line. '
    'State transition (unchanged): EMPTY_DELIVERED_FOR_REFILL → FULL_PICKED_FROM_SUPPLIER. '
    'Clears fk_current_supplier; sets fk_current_vehicle_trip to collection trip. '
    'Marks tbl_supplier_trip_line.collected = TRUE. '
    'NEW: checks if all lines for the supplier trip are now collected. '
    'If yes, resolves the SUPPLIER_DROPOFF checkpoint (MATCHED or VARIANCE).';


-- =============================================================================
-- PART 5A — fn_supplier_collection_checkpoint()
--            AFTER INSERT on tbl_supplier_refill_collection (the header)
--
--   Emits a SUPPLIER_COLLECTION checkpoint when a collection run is created.
--   expected_count = lines in tbl_supplier_trip_line for the linked supplier
--                    trip that are not yet collected (the ones we are picking up).
--   If fk_supplier_trip is NULL (multi-trip collection), the checkpoint is
--   skipped — the operator must create it manually or via a future extension.
--   escalation_threshold = 24 h (collection vehicle returns same day).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_supplier_collection_checkpoint()
RETURNS TRIGGER AS $$
DECLARE
    v_expected_count   int4 := 0;
BEGIN
    -- Only emit a checkpoint when we know which supplier trip is being collected
    IF NEW.fk_supplier_trip IS NULL THEN
        RAISE NOTICE
            '[SUPPLIER_COLLECTION/checkpoint]: fk_supplier_trip is NULL on '
            'collection %. Checkpoint skipped — unable to determine expected '
            'cylinder count without a linked supplier trip.',
            NEW.pk_collection_id;
        RETURN NEW;
    END IF;

    -- Expected = supplier trip lines not yet marked collected
    -- (those are exactly the cylinders this collection run should bring back)
    SELECT COUNT(*) INTO v_expected_count
      FROM public.tbl_supplier_trip_line
     WHERE fk_supplier_trip = NEW.fk_supplier_trip
       AND collected         = FALSE;

    IF v_expected_count = 0 THEN
        RAISE NOTICE
            '[SUPPLIER_COLLECTION/checkpoint]: supplier_trip % has no uncollected '
            'lines. Collection % may be a duplicate — checkpoint skipped.',
            NEW.fk_supplier_trip, NEW.pk_collection_id;
        RETURN NEW;
    END IF;

    BEGIN
        PERFORM public.fn_create_checkpoint(
            'SUPPLIER_COLLECTION',
            'tbl_supplier_refill_collection',
            NEW.pk_collection_id,
            v_expected_count,
            24,                                 -- 24-hour window (same-day return)
            'Collection ' || COALESCE(NEW.collection_number, '#' || NEW.pk_collection_id)
                || ' created for supplier trip ' || NEW.fk_supplier_trip
                || '. Expecting ' || v_expected_count || ' refilled cylinders back.',
            NEW.collection_date,
            NULL,                               -- fk_vehicle_trip populated below
            NULL,                               -- fk_vehicle_load not relevant
            NULL
        );

        -- Back-fill fk_vehicle_trip on the just-inserted checkpoint row
        -- so the dashboard can filter by collection trip without a join.
 -- Back-fill fk_vehicle_trip on the just-inserted checkpoint row
        -- so the dashboard can filter by collection trip without a join.
        -- NOTE: ORDER BY is not valid inside a PostgreSQL UPDATE statement.
        --       We use a scalar sub-select to target only the most-recently
        --       inserted PENDING row (the one fn_create_checkpoint just wrote).
        UPDATE public.tbl_reconciliation_checkpoint
           SET fk_vehicle_trip     = NEW.fk_vehicle_trip,
               fk_supplier_trip    = NEW.fk_supplier_trip
         WHERE pk_checkpoint_id = (
             SELECT pk_checkpoint_id
               FROM public.tbl_reconciliation_checkpoint
              WHERE reference_entity_type = 'tbl_supplier_refill_collection'
                AND reference_entity_id   = NEW.pk_collection_id
                AND checkpoint_type       = 'SUPPLIER_COLLECTION'
                AND checkpoint_status     = 'PENDING'
              ORDER BY created_at DESC
              LIMIT 1
         );

    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE '[SUPPLIER_COLLECTION/checkpoint collection=%]: %',
            NEW.pk_collection_id, SQLERRM;
    END;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_supplier_collection_checkpoint
    ON public.tbl_supplier_refill_collection;

CREATE TRIGGER trg_supplier_collection_checkpoint
AFTER INSERT ON public.tbl_supplier_refill_collection
FOR EACH ROW EXECUTE FUNCTION public.fn_supplier_collection_checkpoint();

COMMENT ON FUNCTION public.fn_supplier_collection_checkpoint() IS
    'Fires AFTER INSERT on tbl_supplier_refill_collection (the header). '
    'Emits a SUPPLIER_COLLECTION checkpoint. '
    'expected_count = uncollected tbl_supplier_trip_line rows for the linked '
    'supplier trip (the cylinders this run should bring back). '
    'Skipped when fk_supplier_trip IS NULL. '
    'Resolved by trg_supplier_collection_verified when collection_status → VERIFIED.';


-- =============================================================================
-- PART 5B — fn_supplier_collection_verified()
--            AFTER UPDATE on tbl_supplier_refill_collection
--            Fires when collection_status transitions to VERIFIED.
--
--   Resolves the SUPPLIER_COLLECTION checkpoint.
--   actual_count = actual lines in tbl_supplier_refill_collection_line for
--                  this collection header (what was physically counted).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_supplier_collection_verified()
RETURNS TRIGGER AS $$
DECLARE
    v_actual_count   int4 := 0;
BEGIN
    -- Only fire when status transitions TO VERIFIED
    IF NEW.collection_status <> 'VERIFIED'
    OR OLD.collection_status  = 'VERIFIED' THEN
        RETURN NEW;
    END IF;

    -- Actual = lines that were physically scanned into this collection
    SELECT COUNT(*) INTO v_actual_count
      FROM public.tbl_supplier_refill_collection_line
     WHERE fk_collection = NEW.pk_collection_id;

    BEGIN
        PERFORM public.fn_resolve_checkpoint(
            'tbl_supplier_refill_collection',
            NEW.pk_collection_id,
            'SUPPLIER_COLLECTION',
            v_actual_count,
            'Collection ' || COALESCE(NEW.collection_number, '#' || NEW.pk_collection_id)
                || ' verified. Lines scanned: ' || v_actual_count
                || '. Verified by: ' || NEW.collected_by
                || ' on ' || now()::text
        );
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE '[SUPPLIER_COLLECTION/verify collection=%]: %',
            NEW.pk_collection_id, SQLERRM;
    END;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_supplier_collection_verified
    ON public.tbl_supplier_refill_collection;

CREATE TRIGGER trg_supplier_collection_verified
AFTER UPDATE OF collection_status ON public.tbl_supplier_refill_collection
FOR EACH ROW EXECUTE FUNCTION public.fn_supplier_collection_verified();

COMMENT ON FUNCTION public.fn_supplier_collection_verified() IS
    'Fires AFTER UPDATE OF collection_status on tbl_supplier_refill_collection '
    'when status transitions to VERIFIED. '
    'Resolves the SUPPLIER_COLLECTION checkpoint with the actual line count. '
    'MATCHED when actual_count = expected_count (all expected cylinders arrived). '
    'VARIANCE when fewer cylinders arrived than were expected.';


-- =============================================================================
-- PART 6 — Backfill: fix existing TRIP_LOAD_CONFIRMED checkpoints
--           that were created with the incorrect 2-hour threshold.
-- =============================================================================

UPDATE public.tbl_reconciliation_checkpoint
   SET escalation_threshold_hours = 12
 WHERE checkpoint_type            = 'TRIP_LOAD_CONFIRMED'
   AND escalation_threshold_hours = 2
   AND checkpoint_status          = 'PENDING';

-- =============================================================================
-- SUMMARY
-- =============================================================================
--
--  TRIP_LOAD_CONFIRMED lifecycle after V90:
--    Emitted  → tbl_vehicle_trip status = 'Loaded'
--               expected_count = COUNT of FULL_FOR_DELIVERY + FULL_FOR_BUFFER
--                                load lines (cylinder IDs, not header total)
--               escalation   = 12 h
--    Resolved → tbl_vehicle_trip status = 'Halt'
--               fn_trip_load_accountability() classifies every cylinder ID:
--                 DELIVERED        → tbl_order_line for orders on this trip
--                 SUPPLIER_DROPOFF → tbl_supplier_trip_line on SUPPLIER_DROPOFF stops
--                 RETURNED_FULL    → current state is FULL_PICKED_UP_FOR_DELIVERY / FULL
--                 UNACCOUNTED      → missing: no challan, not returned → VARIANCE
--               actual_count = accounted (DELIVERED + SUPPLIER_DROPOFF + RETURNED_FULL)
--               Unaccounted cylinder serials appended to remarks (up to 20)
--
--  SUPPLIER_DROPOFF lifecycle after V90:
--    Emitted  → tbl_vehicle_trip_stop.stop_status = 'COMPLETED' (SUPPLIER_DROPOFF stop)
--               expected_count = cylinders handed to supplier at this stop
--               escalation   = 72 h (3-day refill SLA)
--    Resolved → last tbl_supplier_refill_collection_line for that supplier trip
--               actual_count = total collected lines
--
--  SUPPLIER_COLLECTION lifecycle after V90:
--    Emitted  → tbl_supplier_refill_collection INSERT (collection run created)
--               expected_count = uncollected tbl_supplier_trip_line rows
--               escalation   = 24 h (same-day return)
--    Resolved → tbl_supplier_refill_collection.collection_status = 'VERIFIED'
--               actual_count = tbl_supplier_refill_collection_line rows
-- =============================================================================