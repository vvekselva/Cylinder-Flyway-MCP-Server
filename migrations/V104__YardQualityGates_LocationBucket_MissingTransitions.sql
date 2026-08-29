-- =============================================================================
-- V104__YardQualityGates_LocationBucket_MissingTransitions.sql
-- =============================================================================
--
-- ADDRESSES THE FOLLOWING REQUIREMENTS
-- ─────────────────────────────────────────────────────────────────────────────
-- REQ-1  Two missing cylinder state transitions
--          EMPTY_IN_TRANSIT_TO_YARD  → EMPTY_DELIVERED_FOR_REFILL
--          FULL_PICKED_FROM_SUPPLIER → DELIVERED_FOR_CONSUMPTION
--
-- REQ-2  Normalised cylinder location model
--          tbl_cylinder_location  — new lookup table owning all location labels.
--          tbl_cylinder_states.fk_location — FK to the lookup (replaces the
--            free-form VARCHAR location column that had no referential integrity).
--          tbl_cylinder_current_status.fk_current_location — FK to the same
--            lookup, updated in real time by fn_sync_cylinder_current_status().
--          This gives three clean index-only queries with no string literals:
--            cylinders in yard:       WHERE fk_current_location = <YARD id>
--            cylinders at customers:  WHERE fk_current_location = <CUSTOMER id>
--            cylinders at suppliers:  WHERE fk_current_location = <SUPPLIER id>
--            cylinders in transit:    WHERE fk_current_location = <IN_TRANSIT id>
--
-- REQ-3  tbl_yard_quality_gate (management traffic-light table)
--          gate_status = GREEN | AMBER | RED | BLOCKED
--          One row per gate event per business day.
--
-- REQ-4  Challan-wait logic (Scenarios 7-9)
--          AMBER gate waits for office challan entry before escalating to RED.
--
-- SCENARIOS HANDLED (12 total, see inline comments on each trigger)
-- ─────────────────────────────────────────────────────────────────────────────
-- Sc-1   Fresh install — no cylinders — no gate rows — vw_current_day_gates
--        returns GREEN for every gate type (absence = GREEN).
-- Sc-2   Previous day fully GREEN → morning audit resolves GREEN immediately.
-- Sc-3   Audit before trip: expected = full yard count; GREEN if scan matches.
-- Sc-4   Audit after trip departs (MORNING): loaded cylinders are IN_TRANSIT,
--        excluded from expected count automatically (bucket-based).
-- Sc-5   Trip returns (HALT): POST_TRIP audit, TRIP_RETURN_GATE → GREEN.
-- Sc-6   Challans entered by office → fn_resolve_yard_gate_for_challan().
-- Sc-7   Next-day audit before yesterday's challans are entered → AMBER gate.
-- Sc-8   Office enters challans → gate resolves GREEN.
-- Sc-9   AMBER window elapses without challan entry → escalates to RED.
-- Sc-10  Supplier trip in progress: cylinders are at SUPPLIER location,
--        excluded from expected yard count; no false variance.
-- Sc-11  Direct bypass delivery (REQ-1 transitions): valid state machine paths.
-- Sc-12  Third-party cylinders scanned (fk_cylinder IS NULL): excluded from
--        count comparison; logged as UNREGISTERED event; gate stays GREEN.
--
-- DEPENDENCIES
--   V15   tbl_cylinder_states.location VARCHAR column (replaced with FK here)
--   V41   tbl_cylinder_current_status
--   V56   fk_current_vehicle_trip on tbl_cylinder_current_status
--   V61   tbl_reconciliation_checkpoint
--   V63   fk_current_supplier on tbl_cylinder_current_status
--   V69   tbl_trip_status, tbl_vehicle_trip.fk_trip_status
--   V84   tbl_yard_stock_check.check_context, fk_vehicle_trip
--   V91   tbl_reconciliation_header
--   V94   tbl_yard_stock_check_line.observed_cylinder, fk_cylinder nullable
--   V98   tbl_cylinder_state_transition
--   V100  fn_sync_cylinder_current_status (replaced here)
--   V103  EMPTY_PICKED_FOR_REFILL → EMPTY transition
-- =============================================================================

-- ============================================================================
-- PART 0 — Two missing cylinder state transitions (REQ-1)
-- ============================================================================
--
--  Path A: EMPTY_IN_TRANSIT_TO_YARD → EMPTY_DELIVERED_FOR_REFILL
--    Driver collects empties from a customer stop and drives directly to the
--    supplier for refill without returning to the yard first.
--    Combined pickup-and-dropoff run; saves a yard round-trip.
--
--  Path B: FULL_PICKED_FROM_SUPPLIER → DELIVERED_FOR_CONSUMPTION
--    Driver collects refilled cylinders from the supplier and delivers them
--    directly to a customer without staging through the yard.
--    Same-day supplier-to-customer direct run.
--
--  Both paths were absent from tbl_cylinder_state_transition (V98), causing
--  fn_cylinder_state_machine() to RAISE EXCEPTION on these legitimate moves.
-- ============================================================================

INSERT INTO public.tbl_cylinder_state_transition (from_state, to_state, description)
VALUES
    (
        'EMPTY_IN_TRANSIT_TO_YARD',
        'EMPTY_DELIVERED_FOR_REFILL',
        'Empty cylinder collected from customer delivered directly to supplier '
        'for refill — yard bypass. Driver combines empty-pickup and supplier-'
        'dropoff legs on one run.'
    ),
    (
        'FULL_PICKED_FROM_SUPPLIER',
        'DELIVERED_FOR_CONSUMPTION',
        'Full cylinder collected from supplier delivered directly to customer '
        '— yard bypass. Driver combines supplier-collection and customer-'
        'delivery legs on one run.'
    ),
     (
        'DELIVERED_FOR_CONSUMPTION',
        'EMPTY',
        'Walkin Customer Sale will have this direct transition '
        'NO vehile Involved '
        'Customer will pick up the cylinder'
    ),
     (
        'FULL',
        'DELIVERED_FOR_CONSUMPTION',
        'Walkin Customer Sale will have this direct transition '
        'NO vehile Involved '
        'Customer will deliver the cylinder directly to the yard'
    )
ON CONFLICT (from_state, to_state) DO NOTHING;


-- ============================================================================
-- PART 1 — tbl_cylinder_location  (REQ-2: normalised location lookup)
-- ============================================================================
-- Previously, tbl_cylinder_states carried a free-form VARCHAR location column
-- (V15) with values like 'Yard', 'Customer Location', 'In Transit', etc.
-- Those strings had no referential integrity and were duplicated as magic
-- literals in triggers and application code.
--
-- This part introduces tbl_cylinder_location as the single authoritative
-- owner of all location labels.  Both tbl_cylinder_states (via fk_location)
-- and tbl_cylinder_current_status (via fk_current_location) reference it.
--
-- Location values seeded here match every distinct value set by V98:
--   'Yard'              — physically in the yard
--   'Customer Location' — at a customer site
--   'Supplier Location' — at a supplier site
--   'In Transit'        — on a vehicle between locations
--   'Decommissioned'    — retired / scrapped (was 'SCRAP' in V98)
--   'Unknown'           — newly commissioned, location not yet determined
-- ============================================================================

DROP SEQUENCE IF EXISTS public.pk_cylinder_location_id_serial;
CREATE SEQUENCE public.pk_cylinder_location_id_serial
    INCREMENT BY 1 MINVALUE 1 START 1 CACHE 1 NO CYCLE;

CREATE TABLE public.tbl_cylinder_location (
    pk_location_id  int4        NOT NULL
        DEFAULT nextval('public.pk_cylinder_location_id_serial'),
    location_name   varchar(60) NOT NULL,
    description     varchar(300) NOT NULL,

    CONSTRAINT tbl_cylinder_location_pk
        PRIMARY KEY (pk_location_id),
    CONSTRAINT tbl_cylinder_location_name_unique
        UNIQUE (location_name)
);

INSERT INTO public.tbl_cylinder_location (location_name, description) VALUES
    ('Yard',              'Cylinder is physically present at the business yard'),
    ('Customer Location', 'Cylinder is at a customer site (delivered for consumption)'),
    ('Supplier Location', 'Cylinder is at a supplier site awaiting or during refill'),
    ('In Transit',        'Cylinder is on a vehicle moving between locations'),
    ('Decommissioned',    'Cylinder has been retired, scrapped, or written off'),
    ('Unknown',           'Location not yet determined; typically a newly commissioned cylinder');

COMMENT ON TABLE public.tbl_cylinder_location IS
    'V104 — Authoritative lookup table for all cylinder location labels. '
    'tbl_cylinder_states.fk_location and '
    'tbl_cylinder_current_status.fk_current_location both FK to this table. '
    'Replaces the free-form VARCHAR location column on tbl_cylinder_states '
    'that had no referential integrity. '
    'Add new location types here; do not hardcode location strings elsewhere.';


-- ─────────────────────────────────────────────────────────────────────────────
-- Wire tbl_cylinder_states to tbl_cylinder_location
-- The existing location VARCHAR column is kept for backward compatibility
-- with any reporting queries written before V104; fk_location is the
-- normalised replacement that carries the FK constraint.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.tbl_cylinder_states
    ADD COLUMN IF NOT EXISTS fk_location int4 NULL;

-- Backfill fk_location from the existing location VARCHAR
UPDATE public.tbl_cylinder_states cs
SET    fk_location = cl.pk_location_id
FROM   public.tbl_cylinder_location cl
WHERE  cl.location_name = cs.location
    OR (cs.location = 'SCRAP' AND cl.location_name = 'Decommissioned');

-- If any row is still NULL (should not happen after V98, but defensive)
UPDATE public.tbl_cylinder_states
SET    fk_location = (
    SELECT pk_location_id FROM public.tbl_cylinder_location
     WHERE location_name = 'Unknown'
)
WHERE  fk_location IS NULL;

-- Now enforce NOT NULL and FK
ALTER TABLE public.tbl_cylinder_states
    ALTER COLUMN fk_location SET NOT NULL;

ALTER TABLE public.tbl_cylinder_states
    DROP CONSTRAINT IF EXISTS tbl_cylinder_states_location_fk;
ALTER TABLE public.tbl_cylinder_states
    ADD  CONSTRAINT tbl_cylinder_states_location_fk
         FOREIGN KEY (fk_location)
         REFERENCES public.tbl_cylinder_location(pk_location_id);

-- Index: group all states that share a location (e.g., find all 'In Transit' states)
CREATE INDEX idx_cylinder_states_location
    ON public.tbl_cylinder_states(fk_location);

COMMENT ON COLUMN public.tbl_cylinder_states.fk_location IS
    'V104 — FK to tbl_cylinder_location. Normalised replacement for the free-form '
    'VARCHAR location column. Every cylinder state maps to exactly one location. '
    'Use this FK in joins; the legacy location VARCHAR is retained only for '
    'backward compatibility with pre-V104 reports.';


-- ============================================================================
-- PART 2 — fk_current_location on tbl_cylinder_current_status (REQ-2)
-- ============================================================================
-- Replaces the transient VARCHAR current_location_bucket that existed only
-- between the time of design and this corrected migration.
-- fk_current_location is a proper FK to tbl_cylinder_location, so:
--   - Location vocabulary is enforced by the DB, not application logic.
--   - New location types automatically become available here when added to
--     tbl_cylinder_location.
--   - All management queries use an integer FK scan, not a string predicate.
--
-- Answers the three standard management queries:
--   Cylinders in yard:       JOIN tbl_cylinder_location l ON l.pk_location_id = fk_current_location
--                            WHERE l.location_name = 'Yard'
--   Or using the pre-resolved FK directly (fastest, index-only):
--                            WHERE fk_current_location = <Yard id>
-- ============================================================================

-- Remove any VARCHAR bucket column that may have been added by an earlier
-- draft of V104.  Safe to drop if it already exists; no-op otherwise.
ALTER TABLE public.tbl_cylinder_current_status
    DROP COLUMN IF EXISTS current_location_bucket;

ALTER TABLE public.tbl_cylinder_current_status
    ADD COLUMN IF NOT EXISTS fk_current_location int4 NULL;

-- Backfill from the now-populated tbl_cylinder_states.fk_location
UPDATE public.tbl_cylinder_current_status ccs
SET    fk_current_location = cs.fk_location
FROM   public.tbl_cylinder_states cs
WHERE  cs.pk_cylinder_state_id = ccs.fk_current_state;

-- Enforce NOT NULL and FK
ALTER TABLE public.tbl_cylinder_current_status
    ALTER COLUMN fk_current_location SET NOT NULL;

ALTER TABLE public.tbl_cylinder_current_status
    DROP CONSTRAINT IF EXISTS tbl_ccs_location_fk;
ALTER TABLE public.tbl_cylinder_current_status
    ADD  CONSTRAINT tbl_ccs_location_fk
         FOREIGN KEY (fk_current_location)
         REFERENCES public.tbl_cylinder_location(pk_location_id);

-- Indexes for the four common management queries
CREATE INDEX idx_ccs_current_location
    ON public.tbl_cylinder_current_status(fk_current_location);



COMMENT ON COLUMN public.tbl_cylinder_current_status.fk_current_location IS
    'V104 — FK to tbl_cylinder_location. Normalised location of this cylinder '
    'right now. Maintained in real time by fn_sync_cylinder_current_status(). '
    'Replaces the free-form VARCHAR bucket column. '
    'Answers: cylinders in yard / at customers / at suppliers / in transit '
    'via a single FK predicate. Do not update manually.';


-- ─────────────────────────────────────────────────────────────────────────────
-- Replace fn_sync_cylinder_current_status to maintain fk_current_location.
-- Preserves all V100 logic (vehicle FK back-fill, supplier-state preservation).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.fn_sync_cylinder_current_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_customer_id       BIGINT  := NULL;
    v_vehicle_load_id   BIGINT  := NULL;
    v_vehicle_trip_id   BIGINT  := NULL;
    v_location_id       INT4;
    v_in_transit_loc_id INT4;
BEGIN
    -- 1. Resolve location FK directly from the state's fk_location column.
    --    NEW here is a row from tbl_cylinder_state_audit.
    --    tbl_cylinder_state_audit does NOT contain fk_vehicle_load.
    SELECT cs.fk_location
      INTO v_location_id
      FROM public.tbl_cylinder_states cs
     WHERE cs.pk_cylinder_state_id = NEW.fk_new_state;

    -- 2. Resolve customer from the order attached to this audit row.
    IF NEW.fk_order IS NOT NULL THEN
        SELECT fk_customer
          INTO v_customer_id
          FROM public.tbl_order
         WHERE pk_order_id = NEW.fk_order
         LIMIT 1;
    END IF;

    -- Clear customer FK when cylinder is not at a customer site.
    IF v_location_id <> (
        SELECT pk_location_id
          FROM public.tbl_cylinder_location
         WHERE location_name = 'Customer Location'
    ) THEN
        v_customer_id := NULL;
    END IF;

    -- 3. Resolve vehicle load + trip only when the new state is In Transit.
    --    We must NOT use NEW.fk_vehicle_load here, because NEW belongs to
    --    tbl_cylinder_state_audit and that table has no fk_vehicle_load column.
    SELECT pk_location_id
      INTO v_in_transit_loc_id
      FROM public.tbl_cylinder_location
     WHERE location_name = 'In Transit';

    IF v_location_id = v_in_transit_loc_id THEN
        SELECT vll.fk_vehicle_load
          INTO v_vehicle_load_id
          FROM public.tbl_vehicle_load_line vll
         WHERE vll.fk_cylinder = NEW.fk_cylinder
         ORDER BY vll.pk_vehicle_load_line_id DESC
         LIMIT 1;

        IF v_vehicle_load_id IS NOT NULL THEN
            SELECT vl.fk_vehicle_trip
              INTO v_vehicle_trip_id
              FROM public.tbl_vehicle_load vl
             WHERE vl.pk_vehicle_load_id = v_vehicle_load_id;
        END IF;
    END IF;

    -- 4. UPSERT — fk_current_location set from the state's FK, not a string.
    INSERT INTO public.tbl_cylinder_current_status (
        fk_cylinder,
        fk_current_state,
        fk_current_location,
        fk_current_holder_customer,
        fk_current_supplier,
        fk_last_order,
        fk_current_vehicle_load,
        fk_current_vehicle_trip,
        updated_at
    )
    VALUES (
        NEW.fk_cylinder,
        NEW.fk_new_state,
        v_location_id,
        v_customer_id,
        NULL,               -- supplier FK cleared here; supplier-dropoff trigger owns it
        NEW.fk_order,
        v_vehicle_load_id,  -- NULL for non-transit states; resolved for transit states
        v_vehicle_trip_id,  -- NULL for non-transit states; resolved for transit states
        now()
    )
    ON CONFLICT (fk_cylinder) DO UPDATE
        SET fk_current_state            = EXCLUDED.fk_current_state,
            fk_current_location         = EXCLUDED.fk_current_location,
            fk_current_holder_customer  = EXCLUDED.fk_current_holder_customer,
            -- Preserve fk_current_supplier when cylinder is at supplier;
            -- the dedicated supplier-dropoff trigger writes the FK on arrival
            -- and the collection trigger clears it on return.
            fk_current_supplier         = CASE
                WHEN EXCLUDED.fk_current_location = (
                    SELECT pk_location_id
                      FROM public.tbl_cylinder_location
                     WHERE location_name = 'Supplier Location'
                )
                THEN public.tbl_cylinder_current_status.fk_current_supplier
                ELSE NULL
            END,
            fk_last_order               = EXCLUDED.fk_last_order,
            fk_current_vehicle_load     = EXCLUDED.fk_current_vehicle_load,
            fk_current_vehicle_trip     = EXCLUDED.fk_current_vehicle_trip,
            updated_at                  = EXCLUDED.updated_at;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.fn_sync_cylinder_current_status() IS
    'V104 — Maintains tbl_cylinder_current_status after every cylinder state '
    'audit row. Sets fk_current_location by reading cs.fk_location (FK to '
    'tbl_cylinder_location) — no string comparisons. Preserves '
    'fk_current_supplier for the Supplier Location state. Called by '
    'trg_sync_current_status_after_audit AFTER INSERT on tbl_cylinder_state_audit.';


-- ============================================================================
-- PART 3 — tbl_yard_gate_config (tunable escalation windows)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.tbl_yard_gate_config (
    pk_config_id                    int4    NOT NULL DEFAULT 1,
    challan_entry_window_hours      int4    NOT NULL DEFAULT 12,
    trip_return_escalation_hours    int4    NOT NULL DEFAULT 14,
    recon_escalation_hours          int4    NOT NULL DEFAULT 24,
    challan_gate_escalation_hours   int4    NOT NULL DEFAULT 12,
    updated_at                      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tbl_yard_gate_config_pk     PRIMARY KEY (pk_config_id),
    CONSTRAINT tbl_yard_gate_config_single CHECK (pk_config_id = 1)
);

INSERT INTO public.tbl_yard_gate_config DEFAULT VALUES
    ON CONFLICT DO NOTHING;

COMMENT ON TABLE public.tbl_yard_gate_config IS
    'V104 — Single-row configuration for yard gate escalation windows. '
    'Exactly one row (pk_config_id = 1) enforced by CHECK. '
    'challan_entry_window_hours: how long an AMBER yard audit gate waits '
    'for the office to enter challans before escalating to RED. '
    'trip_return_escalation_hours: how long before an overdue trip turns RED.';


-- ============================================================================
-- PART 4 — tbl_yard_quality_gate (REQ-3: management traffic-light table)
-- ============================================================================
-- Gate types:
--   YARD_AUDIT_GATE       — one per yard stock check session
--   RECONCILIATION_GATE   — one per reconciliation header
--   BUSINESS_HARMONIZER_GATE — one per day; aggregate of all child gates
--   CHALLAN_ENTRY_GATE    — raised when a trip halts; pending challan entry
--   TRIP_RETURN_GATE      — raised when a trip departs; vehicle on road
--   DAILY_CLOSING_GATE    — raised at EOD; blocks day close until GREEN
--
-- Absence of a gate row for a type = implicitly GREEN.
-- (A fresh install with zero cylinders never raises any gate.)
-- ============================================================================

DROP SEQUENCE IF EXISTS public.pk_yard_quality_gate_id_serial;
CREATE SEQUENCE public.pk_yard_quality_gate_id_serial
    INCREMENT BY 1 MINVALUE 1 START 1 CACHE 1 NO CYCLE;

CREATE TABLE public.tbl_yard_quality_gate (
    pk_gate_id                  bigint      NOT NULL
        DEFAULT nextval('public.pk_yard_quality_gate_id_serial'),

    gate_date                   date        NOT NULL DEFAULT CURRENT_DATE,
    gate_type                   varchar(60) NOT NULL,

    -- ── Traffic-light ────────────────────────────────────────────────────────
    gate_status                 varchar(20) NOT NULL DEFAULT 'AMBER',
    -- GREEN   = all conditions met
    -- AMBER   = time-bound wait in progress
    -- RED     = variance confirmed; investigation required
    -- BLOCKED = downstream action blocked until this resolves

    status_reason               text        NULL,

    -- ── Typed FKs (at most one non-null per row) ─────────────────────────────
    fk_yard_stock_check         bigint      NULL,
    fk_vehicle_trip             bigint      NULL,
    fk_reconciliation_header    bigint      NULL,
    fk_daily_count              bigint      NULL,

    -- ── AMBER window ─────────────────────────────────────────────────────────
    amber_wait_until            timestamptz NULL,
    amber_reason                varchar(500) NULL,

    -- ── Cylinder counts for management summary ────────────────────────────────
    expected_cylinder_count     int4        NULL,
    observed_cylinder_count     int4        NULL,
    variance_count              int4        GENERATED ALWAYS AS (
                                                CASE
                                                    WHEN observed_cylinder_count IS NOT NULL
                                                     AND expected_cylinder_count IS NOT NULL
                                                    THEN observed_cylinder_count
                                                         - expected_cylinder_count
                                                    ELSE NULL
                                                END
                                            ) STORED,

    -- ── Lifecycle ────────────────────────────────────────────────────────────
    escalated_at                timestamptz NULL,
    opened_at                   timestamptz NOT NULL DEFAULT now(),
    resolved_at                 timestamptz NULL,
    resolved_by                 varchar(200) NULL,
    remarks                     text        NULL,

    CONSTRAINT tbl_yard_quality_gate_pk
        PRIMARY KEY (pk_gate_id),
    CONSTRAINT tbl_yard_quality_gate_type_chk
        CHECK (gate_type IN (
            'YARD_AUDIT_GATE', 'RECONCILIATION_GATE',
            'BUSINESS_HARMONIZER_GATE', 'CHALLAN_ENTRY_GATE',
            'TRIP_RETURN_GATE', 'DAILY_CLOSING_GATE'
        )),
    CONSTRAINT tbl_yard_quality_gate_status_chk
        CHECK (gate_status IN ('GREEN','AMBER','RED','BLOCKED')),

    CONSTRAINT tbl_yard_quality_gate_stock_check_fk
        FOREIGN KEY (fk_yard_stock_check)
        REFERENCES public.tbl_yard_stock_check(pk_stock_check_id),
    CONSTRAINT tbl_yard_quality_gate_vehicle_trip_fk
        FOREIGN KEY (fk_vehicle_trip)
        REFERENCES public.tbl_vehicle_trip(pk_vehicle_trip_id),
    CONSTRAINT tbl_yard_quality_gate_recon_header_fk
        FOREIGN KEY (fk_reconciliation_header)
        REFERENCES public.tbl_reconciliation_header(pk_header_id),
    CONSTRAINT tbl_yard_quality_gate_daily_count_fk
        FOREIGN KEY (fk_daily_count)
        REFERENCES public.tbl_daily_cylinder_count(pk_daily_count_id)
);

CREATE INDEX idx_yard_quality_gate_date_type
    ON public.tbl_yard_quality_gate(gate_date DESC, gate_type);
CREATE INDEX idx_yard_quality_gate_open
    ON public.tbl_yard_quality_gate(gate_status, gate_date DESC)
    WHERE gate_status IN ('AMBER','RED','BLOCKED');
CREATE INDEX idx_yard_quality_gate_vehicle_trip
    ON public.tbl_yard_quality_gate(fk_vehicle_trip)
    WHERE fk_vehicle_trip IS NOT NULL;
CREATE INDEX idx_yard_quality_gate_stock_check
    ON public.tbl_yard_quality_gate(fk_yard_stock_check)
    WHERE fk_yard_stock_check IS NOT NULL;
CREATE INDEX idx_yard_quality_gate_amber_expiry
    ON public.tbl_yard_quality_gate(amber_wait_until)
    WHERE gate_status = 'AMBER' AND amber_wait_until IS NOT NULL;

COMMENT ON TABLE public.tbl_yard_quality_gate IS
    'V104 — Management-facing quality gate table. One row per gate event per day. '
    'gate_status is the traffic light: GREEN / AMBER / RED / BLOCKED. '
    'Missing row for a gate type = implicitly GREEN. '
    'Fresh install with no cylinders never produces any gate rows. '
    'See vw_current_day_gates for the dashboard view.';


-- ============================================================================
-- PART 5 — Helper functions: fn_open_yard_gate / fn_resolve_yard_gate
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_open_yard_gate(
    p_gate_type             varchar(60),
    p_gate_status           varchar(20)     DEFAULT 'AMBER',
    p_status_reason         text            DEFAULT NULL,
    p_fk_yard_stock_check   bigint          DEFAULT NULL,
    p_fk_vehicle_trip       bigint          DEFAULT NULL,
    p_fk_reconciliation_header bigint       DEFAULT NULL,
    p_expected_count        int4            DEFAULT NULL,
    p_observed_count        int4            DEFAULT NULL,
    p_amber_wait_hours      int4            DEFAULT NULL,
    p_amber_reason          varchar(500)    DEFAULT NULL,
    p_remarks               text            DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    v_gate_id    bigint;
    v_wait_until timestamptz := NULL;
BEGIN
    IF p_amber_wait_hours IS NOT NULL THEN
        v_wait_until := now() + (p_amber_wait_hours || ' hours')::interval;
    END IF;

    INSERT INTO public.tbl_yard_quality_gate (
        gate_date, gate_type, gate_status, status_reason,
        fk_yard_stock_check, fk_vehicle_trip, fk_reconciliation_header,
        expected_cylinder_count, observed_cylinder_count,
        amber_wait_until, amber_reason, remarks
    ) VALUES (
        CURRENT_DATE, p_gate_type, p_gate_status, p_status_reason,
        p_fk_yard_stock_check, p_fk_vehicle_trip, p_fk_reconciliation_header,
        p_expected_count, p_observed_count,
        v_wait_until, p_amber_reason, p_remarks
    )
    RETURNING pk_gate_id INTO v_gate_id;

    RETURN v_gate_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.fn_resolve_yard_gate(
    p_gate_id       bigint,
    p_status        varchar(20),
    p_reason        text            DEFAULT NULL,
    p_resolved_by   varchar(200)    DEFAULT 'SYSTEM'
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE public.tbl_yard_quality_gate
       SET gate_status      = p_status,
           status_reason    = COALESCE(p_reason, status_reason),
           resolved_at      = CASE WHEN p_status = 'GREEN' THEN now() ELSE resolved_at END,
           resolved_by      = CASE WHEN p_status = 'GREEN' THEN p_resolved_by ELSE resolved_by END,
           escalated_at     = CASE WHEN p_status = 'RED'   THEN now() ELSE escalated_at END,
           amber_wait_until = CASE WHEN p_status <> 'AMBER' THEN NULL ELSE amber_wait_until END
     WHERE pk_gate_id = p_gate_id;
END;
$$;


-- ============================================================================
-- PART 6 — YARD_AUDIT_GATE: trigger on tbl_yard_stock_check
-- ============================================================================
-- INSERT  → open YARD_AUDIT_GATE AMBER (audit in progress).
--           Expected count = cylinders whose fk_current_location = 'Yard' id.
--           This count excludes IN_TRANSIT cylinders (on loaded vehicles),
--           so Sc-4 (audit after trip departs) is handled automatically.
--
-- UPDATE (→ COMPLETED) → evaluate observed vs expected:
--   match         → GREEN
--   mismatch + pending TRIP_RETURN_GATE from yesterday/today
--                 → AMBER (challan-wait; Sc-7/8/9)
--   mismatch, no pending trips
--                 → RED (confirmed variance)
--
-- Sc-12 (third-party cylinders): check lines where fk_cylinder IS NULL are
-- excluded from the observed count. They are logged by fn_yard_check_event_
-- on_scan (V94) and visible on the event log for manager review.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_yard_audit_gate_on_check_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_yard_loc_id int4;
BEGIN
    -- Resolve the 'Yard' location FK once
    SELECT pk_location_id INTO v_yard_loc_id
      FROM public.tbl_cylinder_location
     WHERE location_name = 'Yard';

    PERFORM public.fn_open_yard_gate(
        p_gate_type           := 'YARD_AUDIT_GATE',
        p_gate_status         := 'AMBER',
        p_status_reason       := 'Yard audit session opened (' || NEW.check_context
                                  || '). Scanning in progress — ' || NEW.checked_by || '.',
        p_fk_yard_stock_check := NEW.pk_stock_check_id,
        p_expected_count      := (
            SELECT COUNT(*)::int4
              FROM public.tbl_cylinder_current_status
             WHERE fk_current_location = v_yard_loc_id
        ),
        p_remarks             := 'check_context=' || NEW.check_context
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_yard_audit_gate_on_insert ON public.tbl_yard_stock_check;
CREATE TRIGGER trg_yard_audit_gate_on_insert
AFTER INSERT ON public.tbl_yard_stock_check
FOR EACH ROW
EXECUTE FUNCTION public.fn_yard_audit_gate_on_check_insert();


CREATE OR REPLACE FUNCTION public.fn_yard_audit_gate_on_check_complete()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_gate_id       bigint;
    v_expected      int4;
    v_observed      int4;
    v_pending_trips int4;
    v_trip_list     text;
    v_cfg_hours     int4;
BEGIN
    IF NEW.check_status <> 'COMPLETED' OR OLD.check_status = 'COMPLETED' THEN
        RETURN NEW;
    END IF;

    SELECT pk_gate_id, expected_cylinder_count
      INTO v_gate_id, v_expected
      FROM public.tbl_yard_quality_gate
     WHERE fk_yard_stock_check = NEW.pk_stock_check_id
       AND gate_type           = 'YARD_AUDIT_GATE'
       AND gate_status         IN ('AMBER','RED')
     ORDER BY opened_at DESC
     LIMIT 1;

    IF v_gate_id IS NULL THEN RETURN NEW; END IF;

    -- Count registered cylinders found (Sc-12: exclude fk_cylinder IS NULL)
    SELECT COUNT(*)::int4
      INTO v_observed
      FROM public.tbl_yard_stock_check_line
     WHERE fk_stock_check = NEW.pk_stock_check_id
       AND fk_cylinder    IS NOT NULL;

    UPDATE public.tbl_yard_quality_gate
       SET observed_cylinder_count = v_observed
     WHERE pk_gate_id = v_gate_id;

    IF v_observed = v_expected THEN
        PERFORM public.fn_resolve_yard_gate(v_gate_id, 'GREEN',
            'Audit COMPLETED. Observed ' || v_observed
            || ' = expected ' || v_expected || '. All cylinders accounted.');
        RETURN NEW;
    END IF;

    -- Counts differ — check if any trip from yesterday/today is still AMBER
    -- (either on road or halted but challans not entered)
    SELECT COUNT(*)::int4, STRING_AGG(fk_vehicle_trip::text, ', ')
      INTO v_pending_trips, v_trip_list
      FROM public.tbl_yard_quality_gate
     WHERE gate_type  = 'TRIP_RETURN_GATE'
       AND gate_status = 'AMBER'
       AND gate_date  >= CURRENT_DATE - 1;

    SELECT challan_entry_window_hours INTO v_cfg_hours
      FROM public.tbl_yard_gate_config WHERE pk_config_id = 1;
    v_cfg_hours := COALESCE(v_cfg_hours, 12);

    IF v_pending_trips > 0 THEN
        -- AMBER: plausible challan-wait explanation (Sc-7/8/9)
        UPDATE public.tbl_yard_quality_gate
           SET gate_status      = 'AMBER',
               status_reason    = 'Audit complete with variance of '
                                   || (v_observed - v_expected)::text
                                   || ' cylinders. Pending challan entry may '
                                   || 'explain the gap (trip IDs: '
                                   || COALESCE(v_trip_list,'?') || ').',
               amber_wait_until = now() + (v_cfg_hours || ' hours')::interval,
               amber_reason     = 'Waiting for office challan entry for trip(s): '
                                   || COALESCE(v_trip_list,'?')
                                   || '. Gate escalates to RED in '
                                   || v_cfg_hours::text || ' hours if unresolved.'
         WHERE pk_gate_id = v_gate_id;
    ELSE
        -- RED: confirmed variance with no pending explanation
        PERFORM public.fn_resolve_yard_gate(v_gate_id, 'RED',
            'Audit COMPLETED with confirmed variance. Observed '
            || v_observed || ', expected ' || v_expected
            || '. No pending trips to explain discrepancy. '
            || 'Management investigation required.');
    END IF;

    PERFORM public.fn_refresh_business_harmonizer_gate(CURRENT_DATE);
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_yard_audit_gate_on_complete ON public.tbl_yard_stock_check;
CREATE TRIGGER trg_yard_audit_gate_on_complete
AFTER UPDATE ON public.tbl_yard_stock_check
FOR EACH ROW
EXECUTE FUNCTION public.fn_yard_audit_gate_on_check_complete();


-- ============================================================================
-- PART 7 — TRIP_RETURN_GATE + CHALLAN_ENTRY_GATE: trigger on tbl_vehicle_trip
-- ============================================================================
-- Proceeding: vehicle on road → TRIP_RETURN_GATE AMBER (Sc-3/4)
-- Halt:       vehicle returned → TRIP_RETURN_GATE GREEN (Sc-5)
--             also raises CHALLAN_ENTRY_GATE AMBER (Sc-6/7)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_trip_gate_on_status_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_new_name      varchar(50);
    v_gate_id       bigint;
    v_cfg_trip      int4;
    v_cfg_chal      int4;
    v_transit_loc   int4;
    v_loaded_count  int4;
BEGIN
    IF NEW.fk_trip_status = OLD.fk_trip_status THEN RETURN NEW; END IF;

    SELECT status_name INTO v_new_name
      FROM public.tbl_trip_status WHERE pk_trip_status_id = NEW.fk_trip_status;

    SELECT trip_return_escalation_hours, challan_gate_escalation_hours
      INTO v_cfg_trip, v_cfg_chal
      FROM public.tbl_yard_gate_config WHERE pk_config_id = 1;
    v_cfg_trip := COALESCE(v_cfg_trip, 14);
    v_cfg_chal := COALESCE(v_cfg_chal, 12);

    -- Resolve 'In Transit' location FK
    SELECT pk_location_id INTO v_transit_loc
      FROM public.tbl_cylinder_location WHERE location_name = 'In Transit';

    IF v_new_name = 'Proceeding' THEN
        -- Count cylinders currently on this trip's vehicle (IN_TRANSIT)
        SELECT COUNT(*)::int4 INTO v_loaded_count
          FROM public.tbl_cylinder_current_status ccs
          JOIN public.tbl_vehicle_load vl
            ON vl.pk_vehicle_load_id = ccs.fk_current_vehicle_load
         WHERE vl.fk_vehicle_trip      = NEW.pk_vehicle_trip_id
           AND ccs.fk_current_location = v_transit_loc;

        PERFORM public.fn_open_yard_gate(
            p_gate_type        := 'TRIP_RETURN_GATE',
            p_gate_status      := 'AMBER',
            p_status_reason    := 'Vehicle trip ' || NEW.pk_vehicle_trip_id::text
                                   || ' departed with '
                                   || v_loaded_count::text || ' cylinders.',
            p_fk_vehicle_trip  := NEW.pk_vehicle_trip_id,
            p_expected_count   := v_loaded_count,
            p_amber_wait_hours := v_cfg_trip,
            p_amber_reason     := 'Vehicle on road. Expected return within '
                                   || v_cfg_trip::text || ' hours.'
        );

    ELSIF v_new_name = 'Halt' THEN
        -- Resolve TRIP_RETURN_GATE → GREEN
        SELECT pk_gate_id INTO v_gate_id
          FROM public.tbl_yard_quality_gate
         WHERE gate_type       = 'TRIP_RETURN_GATE'
           AND fk_vehicle_trip = NEW.pk_vehicle_trip_id
           AND gate_status     IN ('AMBER','RED')
         ORDER BY opened_at DESC LIMIT 1;

        IF v_gate_id IS NOT NULL THEN
            PERFORM public.fn_resolve_yard_gate(v_gate_id, 'GREEN',
                'Trip ' || NEW.pk_vehicle_trip_id::text
                || ' halted. Vehicle returned to yard.');
        END IF;

        -- Raise CHALLAN_ENTRY_GATE AMBER (office must enter challans)
        PERFORM public.fn_open_yard_gate(
            p_gate_type        := 'CHALLAN_ENTRY_GATE',
            p_gate_status      := 'AMBER',
            p_status_reason    := 'Trip ' || NEW.pk_vehicle_trip_id::text
                                   || ' halted. Awaiting office challan entry.',
            p_fk_vehicle_trip  := NEW.pk_vehicle_trip_id,
            p_amber_wait_hours := v_cfg_chal,
            p_amber_reason     := 'Challans from this trip must be entered by '
                                   || to_char(
                                        now() + (v_cfg_chal || ' hours')::interval,
                                        'YYYY-MM-DD HH24:MI'
                                      )
        );

        PERFORM public.fn_refresh_business_harmonizer_gate(CURRENT_DATE);
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_trip_gate_on_status ON public.tbl_vehicle_trip;
CREATE TRIGGER trg_trip_gate_on_status
AFTER UPDATE ON public.tbl_vehicle_trip
FOR EACH ROW
EXECUTE FUNCTION public.fn_trip_gate_on_status_change();


-- ============================================================================
-- PART 8 — fn_refresh_business_harmonizer_gate (aggregate day gate)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_refresh_business_harmonizer_gate(
    p_date date DEFAULT CURRENT_DATE
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_red     int4; v_amber int4; v_blocked int4;
    v_status  varchar(20); v_reason text;
    v_gate_id bigint;
BEGIN
    SELECT
        COUNT(*) FILTER (WHERE gate_status = 'RED'),
        COUNT(*) FILTER (WHERE gate_status = 'AMBER'),
        COUNT(*) FILTER (WHERE gate_status = 'BLOCKED')
      INTO v_red, v_amber, v_blocked
      FROM public.tbl_yard_quality_gate
     WHERE gate_date  = p_date
       AND gate_type <> 'BUSINESS_HARMONIZER_GATE';

    IF    v_red     > 0 THEN v_status := 'RED';
        v_reason := v_red::text || ' RED gate(s) require investigation.';
    ELSIF v_blocked > 0 THEN v_status := 'BLOCKED';
        v_reason := v_blocked::text || ' gate(s) blocking day close.';
    ELSIF v_amber   > 0 THEN v_status := 'AMBER';
        v_reason := v_amber::text || ' gate(s) in time-bound wait.';
    ELSE                     v_status := 'GREEN';
        v_reason := 'All gates resolved. Business day harmonized.';
    END IF;

    SELECT pk_gate_id INTO v_gate_id
      FROM public.tbl_yard_quality_gate
     WHERE gate_date = p_date AND gate_type = 'BUSINESS_HARMONIZER_GATE'
     LIMIT 1;

    IF v_gate_id IS NULL THEN
        IF (v_red + v_amber + v_blocked) > 0 OR EXISTS (
            SELECT 1 FROM public.tbl_yard_quality_gate
             WHERE gate_date = p_date AND gate_type <> 'BUSINESS_HARMONIZER_GATE'
        ) THEN
            PERFORM public.fn_open_yard_gate('BUSINESS_HARMONIZER_GATE',
                v_status, v_reason);
        END IF;
    ELSE
        UPDATE public.tbl_yard_quality_gate
           SET gate_status  = v_status, status_reason = v_reason,
               resolved_at  = CASE WHEN v_status = 'GREEN' THEN now() ELSE NULL END
         WHERE pk_gate_id   = v_gate_id;
    END IF;
END;
$$;


-- ============================================================================
-- PART 9 — fn_resolve_yard_gate_for_challan (app-callable)
-- ============================================================================
-- Called by the application when the office enters challans for a trip.
-- Returns (gate_id, gate_type, new_status) for each gate evaluated.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_resolve_yard_gate_for_challan(
    p_vehicle_trip_id bigint
)
RETURNS TABLE(gate_id bigint, gate_type varchar, new_status varchar)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rec          RECORD;
    v_yard_loc_id  int4;
    v_current_yard int4;
BEGIN
    SELECT pk_location_id INTO v_yard_loc_id
      FROM public.tbl_cylinder_location WHERE location_name = 'Yard';

    SELECT COUNT(*)::int4 INTO v_current_yard
      FROM public.tbl_cylinder_current_status
     WHERE fk_current_location = v_yard_loc_id;

    FOR v_rec IN
        SELECT pk_gate_id, gate_type, expected_cylinder_count
          FROM public.tbl_yard_quality_gate
         WHERE fk_vehicle_trip = p_vehicle_trip_id
           AND gate_status     = 'AMBER'
           AND gate_type       IN ('YARD_AUDIT_GATE','CHALLAN_ENTRY_GATE')
         ORDER BY opened_at
    LOOP
        IF v_rec.gate_type = 'YARD_AUDIT_GATE'
           AND v_rec.expected_cylinder_count IS NOT NULL
           AND v_current_yard = v_rec.expected_cylinder_count THEN
            PERFORM public.fn_resolve_yard_gate(v_rec.pk_gate_id, 'GREEN',
                'Challan entry for trip ' || p_vehicle_trip_id::text
                || ' resolved variance. Yard count ' || v_current_yard::text
                || ' now matches expected.');
            gate_id := v_rec.pk_gate_id; gate_type := v_rec.gate_type;
            new_status := 'GREEN'; RETURN NEXT;

        ELSIF v_rec.gate_type = 'CHALLAN_ENTRY_GATE' THEN
            PERFORM public.fn_resolve_yard_gate(v_rec.pk_gate_id, 'GREEN',
                'Challans for trip ' || p_vehicle_trip_id::text || ' entered.');
            gate_id := v_rec.pk_gate_id; gate_type := v_rec.gate_type;
            new_status := 'GREEN'; RETURN NEXT;

        ELSE
            UPDATE public.tbl_yard_quality_gate
               SET status_reason = 'Challan entry processed for trip '
                                    || p_vehicle_trip_id::text
                                    || '. Yard count ' || v_current_yard::text
                                    || ' still differs from expected '
                                    || v_rec.expected_cylinder_count::text
                                    || '. Further investigation required.'
             WHERE pk_gate_id = v_rec.pk_gate_id;
            gate_id := v_rec.pk_gate_id; gate_type := v_rec.gate_type;
            new_status := 'AMBER'; RETURN NEXT;
        END IF;
    END LOOP;

    PERFORM public.fn_refresh_business_harmonizer_gate(CURRENT_DATE);
END;
$$;

COMMENT ON FUNCTION public.fn_resolve_yard_gate_for_challan(bigint) IS
    'V104 — Call from the application when the office enters challans for a trip. '
    'Evaluates AMBER YARD_AUDIT_GATE and CHALLAN_ENTRY_GATE rows linked to that '
    'trip. Uses fk_current_location FK (not string) to count yard cylinders. '
    'Returns (gate_id, gate_type, new_status) for audit logging.';


-- ============================================================================
-- PART 10 — fn_escalate_expired_amber_gates (cron-callable)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_escalate_expired_amber_gates()
RETURNS int4
LANGUAGE plpgsql
AS $$
DECLARE v_count int4 := 0;
BEGIN
    UPDATE public.tbl_yard_quality_gate
       SET gate_status  = 'RED',
           escalated_at = now(),
           status_reason = COALESCE(status_reason,'')
               || ' [AUTO-ESCALATED: AMBER window expired at '
               || to_char(amber_wait_until,'YYYY-MM-DD HH24:MI') || '.]'
     WHERE gate_status     = 'AMBER'
       AND amber_wait_until < now();
    GET DIAGNOSTICS v_count = ROW_COUNT;

    IF v_count > 0 THEN
        PERFORM public.fn_refresh_business_harmonizer_gate(CURRENT_DATE);
        PERFORM public.fn_refresh_business_harmonizer_gate(CURRENT_DATE - 1);
    END IF;
    RETURN v_count;
END;
$$;

COMMENT ON FUNCTION public.fn_escalate_expired_amber_gates() IS
    'V104 — Cron-callable. Moves every AMBER gate whose amber_wait_until < now() '
    'to RED. Returns count escalated. Schedule every 30 minutes during business hours.';


-- ============================================================================
-- PART 11 — Management views
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- vw_current_day_gates — primary dashboard query
-- One row per gate type for today. Missing type = implicitly GREEN.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW public.vw_current_day_gates AS
WITH gate_types(gate_type) AS (
    VALUES
        ('YARD_AUDIT_GATE'),('RECONCILIATION_GATE'),
        ('BUSINESS_HARMONIZER_GATE'),('CHALLAN_ENTRY_GATE'),
        ('TRIP_RETURN_GATE'),('DAILY_CLOSING_GATE')
),
latest AS (
    SELECT DISTINCT ON (gate_type)
           pk_gate_id, gate_date, gate_type, gate_status, status_reason,
           fk_yard_stock_check, fk_vehicle_trip,
           expected_cylinder_count, observed_cylinder_count, variance_count,
           amber_wait_until, amber_reason, escalated_at, opened_at, resolved_at
      FROM public.tbl_yard_quality_gate
     WHERE gate_date = CURRENT_DATE
     ORDER BY gate_type, opened_at DESC
)
SELECT
    gt.gate_type,
    COALESCE(l.gate_status, 'GREEN')          AS gate_status,
    COALESCE(l.status_reason,
             'No activity recorded today.')   AS status_reason,
    l.pk_gate_id,
    l.fk_yard_stock_check,
    l.fk_vehicle_trip,
    l.expected_cylinder_count,
    l.observed_cylinder_count,
    l.variance_count,
    l.amber_wait_until,
    l.amber_reason,
    CASE WHEN l.gate_status = 'AMBER' AND l.amber_wait_until IS NOT NULL
         THEN EXTRACT(EPOCH FROM (l.amber_wait_until - now()))::int4 / 60
         ELSE NULL
    END                                        AS amber_minutes_remaining,
    l.escalated_at,
    l.opened_at,
    l.resolved_at
FROM      gate_types gt
LEFT JOIN latest l USING (gate_type)
ORDER BY
    CASE COALESCE(l.gate_status,'GREEN')
        WHEN 'RED'     THEN 1 WHEN 'BLOCKED' THEN 2
        WHEN 'AMBER'   THEN 3 WHEN 'GREEN'   THEN 4
    END,
    gt.gate_type;

COMMENT ON VIEW public.vw_current_day_gates IS
    'V104 — Management dashboard: one row per gate type for today. '
    'Missing gate types show GREEN (fresh install shows all GREEN). '
    'Sorted RED → BLOCKED → AMBER → GREEN. '
    'amber_minutes_remaining = minutes before AMBER auto-escalates to RED.';


-- ─────────────────────────────────────────────────────────────────────────────
-- vw_yard_cylinder_summary — location counts using FK join
-- Uses the normalised fk_current_location FK (not a string bucket).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW public.vw_yard_cylinder_summary AS
SELECT
    cl.location_name,
    cl.description              AS location_description,
    COUNT(ccs.fk_cylinder)      AS cylinder_count
FROM      public.tbl_cylinder_location        cl
LEFT JOIN public.tbl_cylinder_current_status  ccs
       ON ccs.fk_current_location = cl.pk_location_id
GROUP BY  cl.pk_location_id, cl.location_name, cl.description
ORDER BY  cl.location_name;

COMMENT ON VIEW public.vw_yard_cylinder_summary IS
    'V104 — Cylinder count grouped by location (from tbl_cylinder_location). '
    'Uses the normalised fk_current_location FK — no string matching. '
    'Rows with cylinder_count = 0 mean no cylinders are at that location currently.';


-- ─────────────────────────────────────────────────────────────────────────────
-- vw_open_gates_alert — all non-GREEN unresolved gates (operations feed)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW public.vw_open_gates_alert AS
SELECT
    g.gate_date, g.gate_type, g.gate_status, g.status_reason,
    g.fk_vehicle_trip, g.fk_yard_stock_check,
    g.variance_count,
    g.amber_wait_until, g.amber_reason,
    CASE WHEN g.gate_status = 'AMBER' AND g.amber_wait_until IS NOT NULL
         THEN EXTRACT(EPOCH FROM (g.amber_wait_until - now()))::int4 / 60
         ELSE NULL
    END                             AS amber_minutes_remaining,
    g.escalated_at,
    g.opened_at,
    ysc.check_context               AS audit_context,
    ysc.checked_by                  AS auditor
FROM   public.tbl_yard_quality_gate  g
LEFT   JOIN public.tbl_yard_stock_check ysc
       ON ysc.pk_stock_check_id = g.fk_yard_stock_check
WHERE  g.gate_status IN ('AMBER','RED','BLOCKED')
  AND  g.resolved_at IS NULL
ORDER BY
    CASE g.gate_status WHEN 'RED' THEN 1 WHEN 'BLOCKED' THEN 2 WHEN 'AMBER' THEN 3 END,
    g.gate_date DESC, g.opened_at DESC;

COMMENT ON VIEW public.vw_open_gates_alert IS
    'V104 — All non-GREEN unresolved gates, severity-sorted (RED first). '
    'Feed into the operations alert panel.';


-- ============================================================================
-- PART 12 — Verification
-- ============================================================================

DO $$
DECLARE
    v_trans     int4;  v_loc_rows  int4;
    v_states_fk int4;  v_ccs_fk    int4;
BEGIN
    SELECT COUNT(*) INTO v_trans
      FROM public.tbl_cylinder_state_transition
     WHERE (from_state='EMPTY_IN_TRANSIT_TO_YARD' AND to_state='EMPTY_DELIVERED_FOR_REFILL')
        OR (from_state='FULL_PICKED_FROM_SUPPLIER' AND to_state='DELIVERED_FOR_CONSUMPTION');

    SELECT COUNT(*) INTO v_loc_rows FROM public.tbl_cylinder_location;

    SELECT COUNT(*) INTO v_states_fk
      FROM public.tbl_cylinder_states WHERE fk_location IS NULL;

    SELECT COUNT(*) INTO v_ccs_fk
      FROM public.tbl_cylinder_current_status WHERE fk_current_location IS NULL;

    IF v_trans < 2 THEN
        RAISE WARNING 'V104 VERIFY: Expected 2 new transitions, found %.', v_trans;
    ELSE
        RAISE NOTICE 'V104 OK: Both bypass state transitions inserted.';
    END IF;

    IF v_loc_rows < 6 THEN
        RAISE WARNING 'V104 VERIFY: tbl_cylinder_location has only % rows.', v_loc_rows;
    ELSE
        RAISE NOTICE 'V104 OK: tbl_cylinder_location seeded with % location rows.', v_loc_rows;
    END IF;

    IF v_states_fk > 0 THEN
        RAISE WARNING 'V104 VERIFY: % tbl_cylinder_states rows have NULL fk_location.', v_states_fk;
    ELSE
        RAISE NOTICE 'V104 OK: All cylinder states have a valid fk_location FK.';
    END IF;

    IF v_ccs_fk > 0 THEN
        RAISE WARNING 'V104 VERIFY: % tbl_cylinder_current_status rows have NULL fk_current_location.', v_ccs_fk;
    ELSE
        RAISE NOTICE 'V104 OK: All cylinder_current_status rows have fk_current_location set.';
    END IF;
END;
$$;

