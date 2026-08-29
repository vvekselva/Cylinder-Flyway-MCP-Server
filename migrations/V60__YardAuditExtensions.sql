-- =============================================================================
-- V60__YardAuditExtensions.sql
-- =============================================================================
-- PURPOSE:
--   Extend the yard audit tables to capture:
--     1. AUDIT CONTEXT  — Is this a pre-trip, post-trip, or ad-hoc audit?
--                        This determines what the "expected" cylinder count is.
--     2. OBSERVED STATE — For each scanned cylinder, what state did the auditor
--                        physically observe (FULL / EMPTY / DAMAGED)?
--                        Currently the audit only records presence, not state.
--     3. EXPECTED COUNT — Snapshot the expected count at audit time (from
--                        tbl_daily_cylinder_count) so comparison is permanent.
--     4. STATE MISMATCH — Flag when the auditor's observation contradicts the
--                        system's recorded state.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- EXTEND: tbl_yard_stock_check — audit context and counts
-- ---------------------------------------------------------------------------

-- Context of the audit relative to the day's vehicle trips
-- PRE_TRIP  : audit done before any vehicle leaves — expected_count = opening_yard
-- POST_TRIP : audit done after all vehicles return — expected_count = closing_yard
-- INTRA_DAY : audit done while some vehicles are out (ad-hoc or scheduled midday)
-- STANDARD  : legacy / no trip context (backward-compatible default)
ALTER TABLE public.tbl_yard_stock_check
    ADD COLUMN IF NOT EXISTS audit_context varchar(50) NOT NULL DEFAULT 'STANDARD';

ALTER TABLE public.tbl_yard_stock_check
    ADD CONSTRAINT tbl_yard_stock_check_context_chk
    CHECK (audit_context IN ('PRE_TRIP','POST_TRIP','INTRA_DAY','STANDARD'));

-- Link to the daily count row for this date — enables the audit to know
-- how many cylinders SHOULD be present given what trips are in flight
ALTER TABLE public.tbl_yard_stock_check
    ADD COLUMN IF NOT EXISTS fk_daily_count int8 NULL;

ALTER TABLE public.tbl_yard_stock_check
    ADD CONSTRAINT tbl_yard_stock_check_daily_count_fk
    FOREIGN KEY (fk_daily_count)
    REFERENCES public.tbl_daily_cylinder_count(pk_daily_count_id);

-- Cylinders known to be on vehicles AT THE TIME the audit starts
-- (so auditors know to subtract these from the expected total)
ALTER TABLE public.tbl_yard_stock_check
    ADD COLUMN IF NOT EXISTS cylinders_known_in_transit int4 NOT NULL DEFAULT 0;

-- Expected count at audit time (calculated and stored when audit is opened)
--   PRE_TRIP  → opening_yard_full + opening_yard_empty
--   POST_TRIP → expected_closing_yard_total (from daily count row)
--   INTRA_DAY → fleet_total - in_transit - at_customer - at_supplier
ALTER TABLE public.tbl_yard_stock_check
    ADD COLUMN IF NOT EXISTS expected_cylinder_count int4 NULL;

-- Actual count from scanning (populated when audit is completed)
ALTER TABLE public.tbl_yard_stock_check
    ADD COLUMN IF NOT EXISTS actual_cylinder_count int4 NULL;

-- Count variance: positive = surplus found, negative = cylinders missing
ALTER TABLE public.tbl_yard_stock_check
    ADD COLUMN IF NOT EXISTS count_variance int4
        GENERATED ALWAYS AS (
            CASE WHEN actual_cylinder_count IS NOT NULL AND expected_cylinder_count IS NOT NULL
                 THEN actual_cylinder_count - expected_cylinder_count
                 ELSE NULL END
        ) STORED;

COMMENT ON COLUMN public.tbl_yard_stock_check.audit_context IS
    'PRE_TRIP = before any vehicle departs (expected = opening_yard). '
    'POST_TRIP = after all vehicles return (expected = closing_yard). '
    'INTRA_DAY = while vehicles are out (expected = fleet − in_transit − at_customer − at_supplier).';

COMMENT ON COLUMN public.tbl_yard_stock_check.count_variance IS
    'Positive = more cylinders found than expected (data gap or unregistered cylinder). '
    'Negative = fewer cylinders found (possible loss, theft, or data gap). '
    'MUST be 0 after full reconciliation.';

-- Mark the yard audit as RECONCILED once it is linked to the daily count
CREATE INDEX idx_yard_stock_check_daily_count
    ON public.tbl_yard_stock_check(fk_daily_count)
    WHERE fk_daily_count IS NOT NULL;

CREATE INDEX idx_yard_stock_check_variance
    ON public.tbl_yard_stock_check(check_date)
    WHERE check_status = 'COMPLETED';

-- ---------------------------------------------------------------------------
-- EXTEND: tbl_yard_stock_check_line — observed state per scanned cylinder
-- ---------------------------------------------------------------------------

-- Physical state observed by the auditor for each cylinder:
--   FULL    – cylinder appears full / pressurised
--   EMPTY   – cylinder is empty
--   DAMAGED – visibly damaged; may still be usable
--   UNKNOWN – auditor could not determine (e.g., no gauge, sealed)
ALTER TABLE public.tbl_yard_stock_check_line
    ADD COLUMN IF NOT EXISTS observed_state varchar(50) NULL;

ALTER TABLE public.tbl_yard_stock_check_line
    ADD CONSTRAINT tbl_yard_stock_check_line_obs_state_chk
    CHECK (observed_state IN ('FULL','EMPTY','DAMAGED','UNKNOWN') OR observed_state IS NULL);

-- TRUE  = observed state matches tbl_cylinder_current_status.fk_current_state
-- FALSE = mismatch (e.g., system says FULL but auditor sees EMPTY) → raise variance
-- NULL  = not yet evaluated
ALTER TABLE public.tbl_yard_stock_check_line
    ADD COLUMN IF NOT EXISTS state_matches_system boolean NULL;

-- Notes from the auditor for this specific cylinder (label damage, location note, etc.)
ALTER TABLE public.tbl_yard_stock_check_line
    ADD COLUMN IF NOT EXISTS auditor_notes varchar(300) NULL;

COMMENT ON COLUMN public.tbl_yard_stock_check_line.observed_state IS
    'Physical state observed by the auditor. Compared against '
    'tbl_cylinder_current_status to detect state mismatches. '
    'A cylinder the system thinks is FULL but is physically EMPTY means '
    'an unrecorded delivery or a data entry failure.';

COMMENT ON COLUMN public.tbl_yard_stock_check_line.state_matches_system IS
    'Populated by fn_evaluate_yard_line_state_match() trigger on INSERT. '
    'FALSE triggers insertion of a UNEXPECTED_STATE variance into '
    'tbl_yard_stock_variance.';

-- ---------------------------------------------------------------------------
-- TRIGGER: auto-evaluate state match on yard check line INSERT
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_evaluate_yard_line_state_match()
RETURNS TRIGGER AS $$
DECLARE
    v_system_state_name  varchar(100);
    v_matches            boolean;
    v_stock_check_id     int8;
    v_system_location    varchar(100);
BEGIN
    -- Only evaluate if an observed_state was provided
    IF NEW.observed_state IS NULL THEN
        RETURN NEW;
    END IF;

    -- Get the system's current state for this cylinder
    SELECT cs.cylinder_state, cs.location
    INTO v_system_state_name, v_system_location
    FROM public.tbl_cylinder_current_status ccs
    JOIN public.tbl_cylinder_states cs ON cs.pk_cylinder_state_id = ccs.fk_current_state
    WHERE ccs.fk_cylinder = NEW.fk_cylinder;

    IF NOT FOUND THEN
        -- Cylinder has no current status record (should not happen — raise a variance)
        v_matches := FALSE;
        v_system_state_name := 'NO_STATUS_RECORD';
        v_system_location := 'UNKNOWN';
    ELSE
        -- Evaluate match: map observed state to expected system state name(s)
        v_matches := CASE NEW.observed_state
            WHEN 'FULL'    THEN v_system_state_name IN ('FULL', 'FULL_PICKED_FROM_SUPPLIER', 'FULL_PICKED_UP_FOR_DELIVERY')
            WHEN 'EMPTY'   THEN v_system_state_name IN ('EMPTY', 'EMPTY_IN_TRANSIT_TO_YARD', 'COMMISSIONED')
            WHEN 'DAMAGED' THEN v_system_state_name = 'DAMAGED'
            ELSE FALSE  -- UNKNOWN observed state = cannot confirm match
        END;
    END IF;

    -- Store the match result
    NEW.state_matches_system := v_matches;

    -- If there is a mismatch, raise a variance row
    IF NOT v_matches THEN
        v_stock_check_id := NEW.fk_stock_check;

        INSERT INTO public.tbl_yard_stock_variance (
            pk_variance_id,
            fk_stock_check,
            fk_cylinder,
            variance_type,
            system_state,
            system_location,
            variance_status,
            resolution_remarks
        ) VALUES (
            nextval('public.pk_stock_yard_variance_id_serial'),
            v_stock_check_id,
            NEW.fk_cylinder,
            'UNEXPECTED_STATE',
            COALESCE(v_system_state_name, 'UNKNOWN'),
            COALESCE(v_system_location, 'UNKNOWN'),
            'OPEN',
            'Auditor observed ' || NEW.observed_state ||
            ' but system records state as ' || COALESCE(v_system_state_name, 'NO_STATUS')
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_evaluate_yard_line_state_match
BEFORE INSERT ON public.tbl_yard_stock_check_line
FOR EACH ROW
EXECUTE FUNCTION public.fn_evaluate_yard_line_state_match();

-- ---------------------------------------------------------------------------
-- EXTEND: tbl_yard_stock_variance — enrich variance_type values
-- ---------------------------------------------------------------------------
-- The existing variance_type column is varchar(50) with no CHECK constraint.
-- Document the valid values here so they can be enforced by the application:
--
--   PHANTOM_IN_SYSTEM   — System says cylinder should be in yard; not physically found.
--                         (Previously unlabelled gap)
--   UNEXPECTED_IN_YARD  — Cylinder found during scan that system says is elsewhere.
--   UNEXPECTED_STATE    — Cylinder found but its physical state differs from system.
--   MISSING_FROM_TRIP   — Cylinder not returned by a trip that carried it.
--   SUPPLIER_SHORTFALL  — Cylinder sent to supplier for refill; not returned.
--   OVERDUE_AT_CUSTOMER — Cylinder at customer beyond agreed return window.
--   DORMANT             — Cylinder not seen in any event for >30 days.
--   COUNT_MISMATCH      — Aggregate count differs (no specific cylinder identified yet).

ALTER TABLE public.tbl_yard_stock_variance
    ADD COLUMN IF NOT EXISTS fk_vehicle_trip int8 NULL;

ALTER TABLE public.tbl_yard_stock_variance
    ADD CONSTRAINT tbl_yard_stock_variance_vehicle_trip_fk
    FOREIGN KEY (fk_vehicle_trip)
    REFERENCES public.tbl_vehicle_trip(pk_vehicle_trip_id);

ALTER TABLE public.tbl_yard_stock_variance
    ADD COLUMN IF NOT EXISTS fk_supplier_trip int8 NULL;

ALTER TABLE public.tbl_yard_stock_variance
    ADD CONSTRAINT tbl_yard_stock_variance_supplier_trip_fk
    FOREIGN KEY (fk_supplier_trip)
    REFERENCES public.tbl_supplier_trip(pk_supplier_trip_id);

COMMENT ON COLUMN public.tbl_yard_stock_variance.variance_type IS
    'Valid types: PHANTOM_IN_SYSTEM | UNEXPECTED_IN_YARD | UNEXPECTED_STATE | '
    'MISSING_FROM_TRIP | SUPPLIER_SHORTFALL | OVERDUE_AT_CUSTOMER | DORMANT | COUNT_MISMATCH. '
    'See V60 migration for full descriptions.';

-- ---------------------------------------------------------------------------
-- VIEW: open variances dashboard
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.vw_open_variances AS
SELECT
    v.pk_variance_id,
    v.variance_type,
    v.variance_status,
    c.cylinder_serial,
    cs_system.cylinder_state           AS system_state,
    cs_system.location                 AS system_location,
    v.system_state                     AS variance_recorded_state,
    v.raised_at,
    EXTRACT(DAY FROM now() - v.raised_at)::int AS age_days,
    ysc.check_date                     AS audit_date,
    v.resolution_remarks
FROM public.tbl_yard_stock_variance v
JOIN public.tbl_cylinder c ON c.pk_cylinder_id = v.fk_cylinder
LEFT JOIN public.tbl_cylinder_current_status ccs ON ccs.fk_cylinder = v.fk_cylinder
LEFT JOIN public.tbl_cylinder_states cs_system ON cs_system.pk_cylinder_state_id = ccs.fk_current_state
LEFT JOIN public.tbl_yard_stock_check ysc ON ysc.pk_stock_check_id = v.fk_stock_check
WHERE v.variance_status = 'OPEN'
ORDER BY v.raised_at DESC;

COMMENT ON VIEW public.vw_open_variances IS
    'All unresolved variances across all audit types. '
    'age_days > 3 for a PHANTOM/UNEXPECTED variance is a red flag.';
