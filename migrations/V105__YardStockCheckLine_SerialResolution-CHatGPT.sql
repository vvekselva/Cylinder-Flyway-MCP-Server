-- =============================================================================
-- V105__YardStockCheckLine_SerialResolution.sql
-- =============================================================================
-- Purpose
--   Completes the Yard Stock Check line-level reconciliation flow.
--
-- Requirement covered
--   Auditor types/scans a cylinder serial into tbl_yard_stock_check_line.observed_cylinder.
--   The database must:
--     1. Resolve observed_cylinder to tbl_cylinder.pk_cylinder_id.
--     2. Populate fk_cylinder when the cylinder belongs to our system.
--     3. Snapshot the system state into fk_system_cylinder_state and system_state_name.
--     4. Check whether the cylinder is currently available in the Yard.
--     5. Check whether the observed physical state matches the system state.
--     6. Set state_matches_system.
--     7. Allow third-party/unknown cylinders by keeping fk_cylinder NULL.
--     8. Notify management using tbl_yard_check_event when a third-party cylinder is scanned.
--
-- Notes
--   - This migration intentionally drops the old observed-state vocabulary CHECK.
--     After V92/V94, observed_cylinder is a free-form serial string, not FULL/EMPTY/etc.
--   - fk_observed_cylinder_state remains the auditor's selected physical state FK.
--   - state_matches_system means:
--       TRUE  = known cylinder + currently located in Yard + observed state equals system state.
--       FALSE = known cylinder but not in Yard, or observed state differs from system state.
--       NULL  = serial not found in tbl_cylinder, or no observed state was supplied.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- PART 1 — Remove obsolete CHECK constraint on observed_cylinder
-- -----------------------------------------------------------------------------
-- This constraint was originally created when the old column represented an enum
-- value like FULL/EMPTY/DAMAGED. The column was later renamed to observed_cylinder
-- and now stores the auditor-entered cylinder serial, so the old vocabulary check
-- is invalid and causes inserts like observed_cylinder = 'A1' to fail.
ALTER TABLE public.tbl_yard_stock_check_line
    DROP CONSTRAINT IF EXISTS tbl_yard_stock_check_line_obs_state_vocab_chk;

ALTER TABLE public.tbl_yard_stock_check_line
    DROP CONSTRAINT IF EXISTS tbl_yard_stock_check_line_obs_state_chk;

COMMENT ON COLUMN public.tbl_yard_stock_check_line.observed_cylinder IS
    'Auditor-entered cylinder serial number. Free-form value. Resolved by '
    'fn_resolve_yard_stock_check_line() into fk_cylinder when it matches '
    'tbl_cylinder.cylinder_serial. Unknown / third-party cylinders remain '
    'with fk_cylinder = NULL.';


-- -----------------------------------------------------------------------------
-- PART 2 — Allow third-party-cylinder notification event
-- -----------------------------------------------------------------------------
-- V85 created tbl_yard_check_event with a fixed event_type CHECK list.
-- V105 needs one more event so management can see when an unknown / other-vendor
-- cylinder was found during a yard audit without treating it as our inventory.
ALTER TABLE public.tbl_yard_check_event
    DROP CONSTRAINT IF EXISTS tbl_yard_check_event_type_chk;

ALTER TABLE public.tbl_yard_check_event
    ADD CONSTRAINT tbl_yard_check_event_type_chk
    CHECK (event_type IN (
        'AUDIT_CREATED',
        'SCANNING_STARTED',
        'CYLINDER_SCANNED',
        'THIRD_PARTY_CYLINDER_FOUND',
        'SCANNING_PAUSED',
        'SCANNING_RESUMED',
        'AUDIT_COMPLETED',
        'VARIANCE_RAISED',
        'VARIANCE_RESOLVED',
        'SUPERVISOR_REVIEWED',
        'AUDIT_REOPENED'
    ));


-- -----------------------------------------------------------------------------
-- PART 3 — Resolve yard stock check line from observed serial
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_resolve_yard_stock_check_line()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_cylinder_id       int8;
    v_system_state_id   int8;
    v_system_state_name varchar(100);
    v_system_location   varchar(100);
    v_yard_location_id  int4;
    v_current_location  int4;
    v_checked_by        varchar(200);
    v_scan_count        int4;
    v_event_remarks     varchar(500);
BEGIN
    -- Normalise the entered serial for storage/comparison.
    -- Keep the user's casing, but remove accidental leading/trailing spaces.
    NEW.observed_cylinder := NULLIF(BTRIM(NEW.observed_cylinder), '');

    -- If no serial is supplied, do not try to resolve anything.
    IF NEW.observed_cylinder IS NULL THEN
        NEW.fk_cylinder              := NULL;
        NEW.fk_system_cylinder_state := NULL;
        NEW.system_state_name        := NULL;
        NEW.state_matches_system     := NULL;
        RETURN NEW;
    END IF;

    -- Resolve serial to our cylinder master.
    -- Case-insensitive exact match, because yard scans often differ by casing.
    SELECT c.pk_cylinder_id
      INTO v_cylinder_id
      FROM public.tbl_cylinder c
     WHERE UPPER(BTRIM(c.cylinder_serial)) = UPPER(NEW.observed_cylinder)
     ORDER BY c.pk_cylinder_id
     LIMIT 1;

    -- Unknown / third-party cylinder.
    -- Keep the raw serial, but do not force an FK. Also create a management
    -- event so the presence of an other-vendor / unknown cylinder is visible
    -- without affecting registered-inventory reconciliation counts.
    IF v_cylinder_id IS NULL THEN
        NEW.fk_cylinder              := NULL;
        NEW.fk_system_cylinder_state := NULL;
        NEW.system_state_name        := NULL;
        NEW.state_matches_system     := NULL;

        SELECT ysc.checked_by
          INTO v_checked_by
          FROM public.tbl_yard_stock_check ysc
         WHERE ysc.pk_stock_check_id = NEW.fk_stock_check;

        SELECT COUNT(*)::int4
          INTO v_scan_count
          FROM public.tbl_yard_stock_check_line scl
         WHERE scl.fk_stock_check = NEW.fk_stock_check;

        IF TG_OP = 'INSERT' THEN
            v_scan_count := COALESCE(v_scan_count, 0) + 1;
        ELSE
            v_scan_count := COALESCE(v_scan_count, 0);
        END IF;

        v_event_remarks := 'Third-party / unknown cylinder scanned: ' || NEW.observed_cylinder;

        -- Avoid duplicate notification rows if the same existing line is updated
        -- or if a backfill re-fires this resolver.
        IF NOT EXISTS (
            SELECT 1
              FROM public.tbl_yard_check_event e
             WHERE e.fk_stock_check = NEW.fk_stock_check
               AND e.event_type = 'THIRD_PARTY_CYLINDER_FOUND'
               AND e.event_remarks = v_event_remarks
        ) THEN
            INSERT INTO public.tbl_yard_check_event (
                fk_stock_check,
                event_type,
                event_at,
                performed_by,
                fk_cylinder,
                fk_variance,
                event_remarks,
                cumulative_scanned
            ) VALUES (
                NEW.fk_stock_check,
                'THIRD_PARTY_CYLINDER_FOUND',
                now(),
                COALESCE(v_checked_by, 'SYSTEM'),
                NULL,
                NULL,
                v_event_remarks,
                v_scan_count
            );
        END IF;

        RETURN NEW;
    END IF;

    NEW.fk_cylinder := v_cylinder_id;

    -- Snapshot current system state and current location.
    SELECT ccs.fk_current_state,
           cs.cylinder_state,
           ccs.fk_current_location,
           cl.location_name
      INTO v_system_state_id,
           v_system_state_name,
           v_current_location,
           v_system_location
      FROM public.tbl_cylinder_current_status ccs
      JOIN public.tbl_cylinder_states cs
        ON cs.pk_cylinder_state_id = ccs.fk_current_state
      LEFT JOIN public.tbl_cylinder_location cl
        ON cl.pk_location_id = ccs.fk_current_location
     WHERE ccs.fk_cylinder = v_cylinder_id;

    NEW.fk_system_cylinder_state := v_system_state_id;
    NEW.system_state_name        := v_system_state_name;

    -- If the cylinder master exists but current status is missing, it is a known
    -- cylinder but cannot be verified. Treat as mismatch only when auditor gave
    -- an observed state.
    IF v_system_state_id IS NULL THEN
        IF NEW.fk_observed_cylinder_state IS NULL THEN
            NEW.state_matches_system := NULL;
        ELSE
            NEW.state_matches_system := FALSE;
        END IF;
        RETURN NEW;
    END IF;

    -- Resolve Yard location id.
    SELECT pk_location_id
      INTO v_yard_location_id
      FROM public.tbl_cylinder_location
     WHERE location_name = 'Yard';

    -- Match rule:
    --   known cylinder must be physically expected in Yard
    --   and auditor observed-state FK must equal current system-state FK.
    -- If observed state is not supplied, leave result NULL because state cannot
    -- be evaluated, even though fk_cylinder/system state were resolved.
    IF NEW.fk_observed_cylinder_state IS NULL THEN
        NEW.state_matches_system := NULL;
    ELSE
        NEW.state_matches_system :=
            (v_current_location = v_yard_location_id)
            AND (NEW.fk_observed_cylinder_state = v_system_state_id);
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.fn_resolve_yard_stock_check_line() IS
    'V105 — BEFORE INSERT/UPDATE resolver for tbl_yard_stock_check_line. '
    'Resolves observed_cylinder serial to fk_cylinder, snapshots system state, '
    'and sets state_matches_system. Unknown third-party cylinders remain with '
    'fk_cylinder NULL, are excluded from registered-cylinder count checks, and '
    'raise THIRD_PARTY_CYLINDER_FOUND events for management visibility.';


-- -----------------------------------------------------------------------------
-- PART 4 — Attach trigger
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_resolve_yard_stock_check_line
    ON public.tbl_yard_stock_check_line;

CREATE TRIGGER trg_resolve_yard_stock_check_line
BEFORE INSERT OR UPDATE OF observed_cylinder, fk_observed_cylinder_state
ON public.tbl_yard_stock_check_line
FOR EACH ROW
EXECUTE FUNCTION public.fn_resolve_yard_stock_check_line();


-- -----------------------------------------------------------------------------
-- PART 5 — Backfill existing unresolved scan rows
-- -----------------------------------------------------------------------------
-- Re-saving the same values fires the resolver for existing rows.
UPDATE public.tbl_yard_stock_check_line
   SET observed_cylinder = observed_cylinder
 WHERE observed_cylinder IS NOT NULL
   AND (fk_cylinder IS NULL
        OR fk_system_cylinder_state IS NULL
        OR state_matches_system IS NULL);


-- -----------------------------------------------------------------------------
-- PART 6 — Helpful indexes
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_yard_stock_check_line_observed_cylinder_norm
    ON public.tbl_yard_stock_check_line (UPPER(BTRIM(observed_cylinder)))
    WHERE observed_cylinder IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_cylinder_serial_norm
    ON public.tbl_cylinder (UPPER(BTRIM(cylinder_serial)));


-- -----------------------------------------------------------------------------
-- PART 7 — Verification
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_bad_constraint int4;
    v_trigger_count  int4;
BEGIN
    SELECT COUNT(*) INTO v_bad_constraint
      FROM pg_constraint
     WHERE conname IN (
            'tbl_yard_stock_check_line_obs_state_vocab_chk',
            'tbl_yard_stock_check_line_obs_state_chk'
          )
       AND conrelid = 'public.tbl_yard_stock_check_line'::regclass;

    IF v_bad_constraint > 0 THEN
        RAISE WARNING 'V105 VERIFY: obsolete observed-state CHECK constraint still exists.';
    ELSE
        RAISE NOTICE 'V105 OK: obsolete observed-state CHECK constraints removed.';
    END IF;

    SELECT COUNT(*) INTO v_trigger_count
      FROM pg_trigger
     WHERE tgname = 'trg_resolve_yard_stock_check_line'
       AND tgrelid = 'public.tbl_yard_stock_check_line'::regclass
       AND NOT tgisinternal;

    IF v_trigger_count = 1 THEN
        RAISE NOTICE 'V105 OK: yard stock check line resolver trigger installed.';
    ELSE
        RAISE WARNING 'V105 VERIFY: resolver trigger count = %.', v_trigger_count;
    END IF;
END;
$$;