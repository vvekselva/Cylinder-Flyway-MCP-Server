-- =============================================================================
-- V59__DailyCylinderCount.sql
-- =============================================================================
-- PURPOSE:
--   Track the cylinder count across a business day in a structured way that
--   survives the ordering problem:
--     "The vehicle trip may start BEFORE the daily yard audit happens."
--
-- PROBLEM STATEMENT:
--   The yard audit (tbl_yard_stock_check) assumes all cylinders are physically
--   present. But if a trip has already left the yard by audit time, the auditor
--   will count fewer cylinders than the system expects — generating false variances.
--   We need a daily count table that:
--     1. Captures the OPENING snapshot (before any movements)
--     2. Records movements during the day (deliveries, collections, supplier trips)
--     3. Captures the CLOSING snapshot (after all vehicles return)
--     4. Raises a warning if closing count != opening count +/- net movements
--
-- DESIGN:
--   One row per calendar day. The system (or a scheduled job) creates the row
--   at the start of each business day by sampling tbl_cylinder_current_status.
--   Each business event (trip start, trip close, audit) updates the movement
--   columns. End-of-day reconciliation compares expected vs actual closing count.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- SEQUENCE
-- ---------------------------------------------------------------------------
DROP SEQUENCE IF EXISTS public.pk_daily_cylinder_count_id_serial;
CREATE SEQUENCE public.pk_daily_cylinder_count_id_serial
    INCREMENT BY 1 MINVALUE 1 START 1 CACHE 1 NO CYCLE;

-- ---------------------------------------------------------------------------
-- TABLE
-- ---------------------------------------------------------------------------
CREATE TABLE public.tbl_daily_cylinder_count (
    pk_daily_count_id       int8        NOT NULL DEFAULT nextval('public.pk_daily_cylinder_count_id_serial'),
    count_date              date        NOT NULL,

    -- ─── OPENING SNAPSHOT (before any trip departs) ──────────────────────────
    -- Populated when the day is opened (business start or first trip request)
    opening_fleet_total     int4        NOT NULL,   -- from fn_current_fleet_count()
    opening_yard_full       int4        NOT NULL DEFAULT 0,
    opening_yard_empty      int4        NOT NULL DEFAULT 0,
    opening_in_transit      int4        NOT NULL DEFAULT 0,   -- should be 0 at true open
    opening_at_customer     int4        NOT NULL DEFAULT 0,
    opening_at_supplier     int4        NOT NULL DEFAULT 0,
    snapshot_opened_at      timestamp   NOT NULL DEFAULT now(),

    -- ─── MOVEMENTS DURING THE DAY ────────────────────────────────────────────
    -- Incremented by triggers as events happen (trip departures, returns, etc.)
    cylinders_delivered_out         int4    NOT NULL DEFAULT 0,  -- FULL → customer
    cylinders_empty_collected_in    int4    NOT NULL DEFAULT 0,  -- empty ← customer
    cylinders_sent_to_supplier      int4    NOT NULL DEFAULT 0,  -- empty → supplier
    cylinders_received_from_supplier int4   NOT NULL DEFAULT 0,  -- full ← supplier
    cylinders_commissioned          int4    NOT NULL DEFAULT 0,  -- new cylinders added
    cylinders_decommissioned        int4    NOT NULL DEFAULT 0,  -- removed from fleet

    -- ─── CLOSING SNAPSHOT (after all vehicles return & yard audit done) ───────
    closing_fleet_total     int4,
    closing_yard_full       int4,
    closing_yard_empty      int4,
    closing_in_transit      int4,
    closing_at_customer     int4,
    closing_at_supplier     int4,
    snapshot_closed_at      timestamp,

    -- ─── EXPECTED CLOSING (calculated) ───────────────────────────────────────
    -- Expected yard total = opening_yard + received_from_supplier + empty_collected_in
    --                       - delivered_out - sent_to_supplier
    -- Stored on close to make variance obvious without recalculation
    expected_closing_yard_total int4,
    expected_closing_fleet_total int4,

    -- ─── RECONCILIATION ──────────────────────────────────────────────────────
    -- OPEN         – day started, movements in progress
    -- PENDING_AUDIT– all trips returned, awaiting yard audit
    -- RECONCILED   – yard audit done, counts match
    -- VARIANCE     – counts do not match, investigation needed
    day_status              varchar(50) NOT NULL DEFAULT 'OPEN',
    variance_count          int4,   -- closing_fleet - expected_closing_fleet (0 = clean)
    reconciliation_notes    varchar(500),
    created_by              varchar(200),

    CONSTRAINT tbl_daily_cylinder_count_pk
        PRIMARY KEY (pk_daily_count_id),

    CONSTRAINT tbl_daily_cylinder_count_date_unique
        UNIQUE (count_date),

    CONSTRAINT tbl_daily_cylinder_count_status_chk
        CHECK (day_status IN ('OPEN','PENDING_AUDIT','RECONCILED','VARIANCE')),

    CONSTRAINT tbl_daily_count_nonneg_chk
        CHECK (
            opening_fleet_total >= 0
            AND cylinders_delivered_out >= 0
            AND cylinders_empty_collected_in >= 0
            AND cylinders_sent_to_supplier >= 0
            AND cylinders_received_from_supplier >= 0
        )
);

CREATE INDEX idx_daily_count_date       ON public.tbl_daily_cylinder_count(count_date DESC);
CREATE INDEX idx_daily_count_status     ON public.tbl_daily_cylinder_count(day_status)
    WHERE day_status NOT IN ('RECONCILED');

COMMENT ON TABLE public.tbl_daily_cylinder_count IS
    'One row per business day. Tracks opening/closing cylinder counts and all '
    'intra-day movements. The orchestrator creates the row at day open and closes '
    'it after all trips return and the yard audit completes. '
    'variance_count = 0 means the day closed cleanly.';

-- ---------------------------------------------------------------------------
-- FUNCTION: open a new day (call at business start or first event of the day)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_open_daily_count(
    p_date      date        DEFAULT CURRENT_DATE,
    p_opened_by varchar(200) DEFAULT 'SYSTEM'
)
RETURNS int8 AS $$
DECLARE
    v_existing_id   int8;
    v_new_id        int8;
    v_fleet_total   int4;
    v_yard_full     int4;
    v_yard_empty    int4;
    v_in_transit    int4;
    v_at_customer   int4;
    v_at_supplier   int4;
BEGIN
    -- Idempotent: if already opened for this date, return the existing ID
    SELECT pk_daily_count_id INTO v_existing_id
    FROM public.tbl_daily_cylinder_count
    WHERE count_date = p_date;

    IF v_existing_id IS NOT NULL THEN
        RETURN v_existing_id;
    END IF;

    -- Sample current status
    v_fleet_total := public.fn_current_fleet_count();

    SELECT
        COUNT(*) FILTER (WHERE cs.cylinder_state = 'FULL')  AS yard_full,
        COUNT(*) FILTER (WHERE cs.cylinder_state = 'EMPTY') AS yard_empty,
        COUNT(*) FILTER (WHERE cs.location = 'In Transit')  AS in_transit,
        COUNT(*) FILTER (WHERE cs.location = 'Customer Location') AS at_customer,
        COUNT(*) FILTER (WHERE cs.location = 'Supplier Location') AS at_supplier
    INTO v_yard_full, v_yard_empty, v_in_transit, v_at_customer, v_at_supplier
    FROM public.tbl_cylinder_current_status ccs
    JOIN public.tbl_cylinder_states cs ON cs.pk_cylinder_state_id = ccs.fk_current_state;

    INSERT INTO public.tbl_daily_cylinder_count (
        count_date,
        opening_fleet_total, opening_yard_full, opening_yard_empty,
        opening_in_transit, opening_at_customer, opening_at_supplier,
        snapshot_opened_at, created_by
    ) VALUES (
        p_date,
        v_fleet_total, v_yard_full, v_yard_empty,
        v_in_transit, v_at_customer, v_at_supplier,
        now(), p_opened_by
    )
    RETURNING pk_daily_count_id INTO v_new_id;

    RETURN v_new_id;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- FUNCTION: close the day (call after all vehicles have returned)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_close_daily_count(
    p_date  date DEFAULT CURRENT_DATE
)
RETURNS void AS $$
DECLARE
    v_row               public.tbl_daily_cylinder_count%ROWTYPE;
    v_closing_fleet     int4;
    v_closing_yard_full int4;
    v_closing_yard_empty int4;
    v_closing_in_transit int4;
    v_closing_at_customer int4;
    v_closing_at_supplier int4;
    v_expected_fleet    int4;
    v_expected_yard     int4;
    v_variance          int4;
BEGIN
    SELECT * INTO v_row
    FROM public.tbl_daily_cylinder_count
    WHERE count_date = p_date;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No daily count row found for date %', p_date;
    END IF;

    IF v_row.day_status NOT IN ('OPEN', 'PENDING_AUDIT') THEN
        RAISE EXCEPTION 'Day % is already in status %. Cannot close.', p_date, v_row.day_status;
    END IF;

    -- Take closing snapshot
    v_closing_fleet := public.fn_current_fleet_count();

    SELECT
        COUNT(*) FILTER (WHERE cs.cylinder_state = 'FULL'),
        COUNT(*) FILTER (WHERE cs.cylinder_state = 'EMPTY'),
        COUNT(*) FILTER (WHERE cs.location = 'In Transit'),
        COUNT(*) FILTER (WHERE cs.location = 'Customer Location'),
        COUNT(*) FILTER (WHERE cs.location = 'Supplier Location')
    INTO v_closing_yard_full, v_closing_yard_empty,
         v_closing_in_transit, v_closing_at_customer, v_closing_at_supplier
    FROM public.tbl_cylinder_current_status ccs
    JOIN public.tbl_cylinder_states cs ON cs.pk_cylinder_state_id = ccs.fk_current_state;

    -- Expected fleet = opening + commissioned - decommissioned
    v_expected_fleet := v_row.opening_fleet_total
                        + v_row.cylinders_commissioned
                        - v_row.cylinders_decommissioned;

    v_variance := v_closing_fleet - v_expected_fleet;

    UPDATE public.tbl_daily_cylinder_count
    SET
        closing_fleet_total         = v_closing_fleet,
        closing_yard_full           = v_closing_yard_full,
        closing_yard_empty          = v_closing_yard_empty,
        closing_in_transit          = v_closing_in_transit,
        closing_at_customer         = v_closing_at_customer,
        closing_at_supplier         = v_closing_at_supplier,
        snapshot_closed_at          = now(),
        expected_closing_fleet_total = v_expected_fleet,
        variance_count              = v_variance,
        day_status                  = CASE WHEN v_variance = 0 THEN 'PENDING_AUDIT' ELSE 'VARIANCE' END
    WHERE count_date = p_date;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- TRIGGER: auto-increment movement columns from fleet ledger events
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_daily_count_fleet_ledger_update()
RETURNS TRIGGER AS $$
BEGIN
    -- Ensure today's daily count row exists
    PERFORM public.fn_open_daily_count(CURRENT_DATE, 'SYSTEM_AUTO');

    IF NEW.event_type = 'COMMISSIONED' THEN
        UPDATE public.tbl_daily_cylinder_count
        SET cylinders_commissioned = cylinders_commissioned + 1
        WHERE count_date = CURRENT_DATE;

    ELSIF NEW.event_type IN ('DECOMMISSIONED', 'LOST_CONFIRMED') THEN
        UPDATE public.tbl_daily_cylinder_count
        SET cylinders_decommissioned = cylinders_decommissioned + 1
        WHERE count_date = CURRENT_DATE;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_daily_count_fleet_ledger
AFTER INSERT ON public.tbl_cylinder_fleet_ledger
FOR EACH ROW
EXECUTE FUNCTION public.fn_daily_count_fleet_ledger_update();

-- ---------------------------------------------------------------------------
-- TRIGGER: auto-increment delivery/collection columns from state_audit
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_daily_count_state_audit_update()
RETURNS TRIGGER AS $$
DECLARE
    v_new_state_name varchar(100);
BEGIN
    SELECT cylinder_state INTO v_new_state_name
    FROM public.tbl_cylinder_states
    WHERE pk_cylinder_state_id = NEW.fk_new_state;

    -- Ensure today's daily count row exists
    PERFORM public.fn_open_daily_count(CURRENT_DATE, 'SYSTEM_AUTO');

    CASE v_new_state_name
        WHEN 'DELIVERED_FOR_CONSUMPTION' THEN
            UPDATE public.tbl_daily_cylinder_count
            SET cylinders_delivered_out = cylinders_delivered_out + 1
            WHERE count_date = CURRENT_DATE;

        WHEN 'EMPTY_IN_TRANSIT_TO_YARD' THEN
            UPDATE public.tbl_daily_cylinder_count
            SET cylinders_empty_collected_in = cylinders_empty_collected_in + 1
            WHERE count_date = CURRENT_DATE;

        WHEN 'EMPTY_DELIVERED_FOR_REFILL' THEN
            UPDATE public.tbl_daily_cylinder_count
            SET cylinders_sent_to_supplier = cylinders_sent_to_supplier + 1
            WHERE count_date = CURRENT_DATE;

        WHEN 'FULL_PICKED_FROM_SUPPLIER' THEN
            UPDATE public.tbl_daily_cylinder_count
            SET cylinders_received_from_supplier = cylinders_received_from_supplier + 1
            WHERE count_date = CURRENT_DATE;

        ELSE
            NULL; -- no movement update needed
    END CASE;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_daily_count_state_audit
AFTER INSERT ON public.tbl_cylinder_state_audit
FOR EACH ROW
EXECUTE FUNCTION public.fn_daily_count_state_audit_update();
