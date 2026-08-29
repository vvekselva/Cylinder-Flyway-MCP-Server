-- =============================================================================
-- V72__YardAuditFixes.sql
-- =============================================================================
-- FIXES TWO STRUCTURAL ISSUES IN V60__YardAuditExtensions.sql:
--
-- FIX 1 — tbl_yard_stock_check.fk_daily_count — FK may be absent
--   V60 adds the column and the constraint, but if the column existed already
--   from an earlier partial migration the ADD CONSTRAINT may have been skipped.
--   This migration uses a DO-block guard to add the FK only when it is missing.
--
-- FIX 2 — tbl_yard_stock_check_line.observed_state — must reference tbl_cylinder_states
--   The current implementation is a bare varchar(50) with a CHECK constraint
--   capping values to 'FULL','EMPTY','DAMAGED','UNKNOWN'.  This couples the
--   auditor vocabulary to a hard-coded list and prevents the UI from reading
--   display names from the canonical tbl_cylinder_states table.
--
--   Correct approach:
--     a) Add fk_observed_cylinder_state int8 → tbl_cylinder_states  (nullable;
--        NULL when the auditor selects "UNKNOWN" which has no system state row).
--     b) Seed an AUDIT_UNKNOWN row into tbl_cylinder_states for completeness
--        (so even UNKNOWN has a proper FK target if desired).
--     c) Drop the old CHECK constraint.
--     d) Update fn_evaluate_yard_line_state_match (V60 BEFORE INSERT trigger) to
--        populate fk_observed_cylinder_state automatically from observed_state.
--     e) Backfill fk_observed_cylinder_state for any existing rows.
--
-- IDEMPOTENT: every structural change is guarded with IF NOT EXISTS / DO-blocks.
-- =============================================================================


-- ===========================================================================
-- FIX 1 — Ensure FK constraint on tbl_yard_stock_check.fk_daily_count
-- ===========================================================================
-- V60 already adds both the column and the constraint. This guard fires only
-- when the constraint row is absent from pg_constraint (e.g., first-time apply
-- on a schema where V60 ran an older version without the constraint).
-- ===========================================================================
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname   = 'tbl_yard_stock_check_daily_count_fk'
           AND conrelid  = 'public.tbl_yard_stock_check'::regclass
           AND contype   = 'f'
    ) THEN
        -- Make sure the column exists before adding the FK
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name   = 'tbl_yard_stock_check'
               AND column_name  = 'fk_daily_count'
        ) THEN
            ALTER TABLE public.tbl_yard_stock_check
                ADD COLUMN fk_daily_count int8 NULL;
        END IF;

        ALTER TABLE public.tbl_yard_stock_check
            ADD CONSTRAINT tbl_yard_stock_check_daily_count_fk
                FOREIGN KEY (fk_daily_count)
                REFERENCES public.tbl_daily_cylinder_count(pk_daily_count_id)
                DEFERRABLE INITIALLY DEFERRED;

        RAISE NOTICE 'V72: Added tbl_yard_stock_check_daily_count_fk constraint.';
    ELSE
        RAISE NOTICE 'V72: tbl_yard_stock_check_daily_count_fk already exists — skipped.';
    END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_yard_stock_check_daily_count_v72
    ON public.tbl_yard_stock_check(fk_daily_count)
    WHERE fk_daily_count IS NOT NULL;


-- ===========================================================================
-- FIX 2a — Seed AUDIT_UNKNOWN into tbl_cylinder_states (if absent)
-- ===========================================================================
-- AUDIT_UNKNOWN represents the physical observation "cannot determine state".
-- It lives in tbl_cylinder_states so the FK is always satisfiable, but it is
-- marked as an audit-only state — never used in operational state transitions.
-- ===========================================================================
INSERT INTO public.tbl_cylinder_states (pk_cylinder_state_id, cylinder_state, description, location)
SELECT
    nextval('public.pk_cylinder_state_id_serial'),
    'AUDIT_UNKNOWN',
    'Cylinder state could not be determined during a physical yard audit. '
        'Audit-only state — never used in operational transitions.',
    'Yard'
WHERE NOT EXISTS (
    SELECT 1 FROM public.tbl_cylinder_states WHERE cylinder_state = 'AUDIT_UNKNOWN'
);

-- Also set the ui_display_name added in V67 (column exists by this migration)
UPDATE public.tbl_cylinder_states
   SET ui_display_name = 'Unknown (Audit)'
 WHERE cylinder_state  = 'AUDIT_UNKNOWN'
   AND ui_display_name IS NULL;

COMMENT ON TABLE public.tbl_cylinder_states IS
    'Canonical cylinder lifecycle states. '
    'AUDIT_UNKNOWN is a special audit-only state used when an auditor cannot '
    'determine physical condition; it never appears in tbl_cylinder_state_audit '
    'transition rows.';


-- ===========================================================================
-- FIX 2b — Add FK column fk_observed_cylinder_state on tbl_yard_stock_check_line
-- ===========================================================================
ALTER TABLE public.tbl_yard_stock_check_line
    ADD COLUMN IF NOT EXISTS fk_observed_cylinder_state int8 NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname  = 'tbl_yard_stock_check_line_obs_state_fk'
           AND conrelid = 'public.tbl_yard_stock_check_line'::regclass
           AND contype  = 'f'
    ) THEN
        ALTER TABLE public.tbl_yard_stock_check_line
            ADD CONSTRAINT tbl_yard_stock_check_line_obs_state_fk
                FOREIGN KEY (fk_observed_cylinder_state)
                REFERENCES public.tbl_cylinder_states(pk_cylinder_state_id);
    END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_yard_check_line_obs_state
    ON public.tbl_yard_stock_check_line(fk_observed_cylinder_state)
    WHERE fk_observed_cylinder_state IS NOT NULL;

COMMENT ON COLUMN public.tbl_yard_stock_check_line.fk_observed_cylinder_state IS
    'FK to tbl_cylinder_states representing the physical state the auditor observed. '
    'Maps the observed_state varchar to the canonical states table so the UI can '
    'drive the picker directly from tbl_cylinder_states. '
    'Auditor-visible values: FULL, EMPTY, DAMAGED, AUDIT_UNKNOWN. '
    'NULL = auditor did not record a physical state for this cylinder.';


-- ===========================================================================
-- FIX 2c — Drop old CHECK constraint on observed_state (replaced by FK)
-- ===========================================================================
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname  = 'tbl_yard_stock_check_line_obs_state_chk'
           AND conrelid = 'public.tbl_yard_stock_check_line'::regclass
           AND contype  = 'c'
    ) THEN
        ALTER TABLE public.tbl_yard_stock_check_line
            DROP CONSTRAINT tbl_yard_stock_check_line_obs_state_chk;
        RAISE NOTICE 'V72: Dropped tbl_yard_stock_check_line_obs_state_chk CHECK constraint.';
    END IF;
END;
$$;

-- Add a lightweight CHECK that allows the varchar to be NULL or one of the
-- auditor-friendly keys (consistent with the FK target rows).
-- This guards application bugs without duplicating the FK logic.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname  = 'tbl_yard_stock_check_line_obs_state_vocab_chk'
           AND conrelid = 'public.tbl_yard_stock_check_line'::regclass
    ) THEN
        ALTER TABLE public.tbl_yard_stock_check_line
            ADD CONSTRAINT tbl_yard_stock_check_line_obs_state_vocab_chk
            CHECK (observed_state IN ('FULL','EMPTY','DAMAGED','AUDIT_UNKNOWN') OR observed_state IS NULL);
    END IF;
END;
$$;


-- ===========================================================================
-- FIX 2d — Backfill fk_observed_cylinder_state from observed_state (existing rows)
-- ===========================================================================
UPDATE public.tbl_yard_stock_check_line scl
   SET fk_observed_cylinder_state = cs.pk_cylinder_state_id
  FROM public.tbl_cylinder_states cs
 WHERE scl.observed_state IS NOT NULL
   AND scl.fk_observed_cylinder_state IS NULL
   AND cs.cylinder_state = CASE scl.observed_state
                               WHEN 'UNKNOWN' THEN 'AUDIT_UNKNOWN'   -- remap legacy value
                               ELSE scl.observed_state
                           END;

-- Also remap any legacy 'UNKNOWN' varchar values to 'AUDIT_UNKNOWN'
UPDATE public.tbl_yard_stock_check_line
   SET observed_state = 'AUDIT_UNKNOWN'
 WHERE observed_state = 'UNKNOWN';


-- ===========================================================================
-- FIX 2e — Replace fn_evaluate_yard_line_state_match (V60)
-- ===========================================================================
-- Updated to:
--   1. Populate fk_observed_cylinder_state from the observed_state varchar.
--   2. Translate legacy 'UNKNOWN' → 'AUDIT_UNKNOWN'.
--   3. Use the FK (state name lookup) rather than hard-coded string comparisons.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.fn_evaluate_yard_line_state_match()
RETURNS TRIGGER AS $$
DECLARE
    v_observed_state_name   varchar(100);
    v_observed_state_id     int8;
    v_system_state_id       int8;
    v_system_state_name     varchar(100);
    v_system_location       varchar(100);
    v_matches               boolean;
BEGIN
    -- ── Normalise observed_state varchar ─────────────────────────────────────
    -- Legacy callers may still send 'UNKNOWN'; map it to the canonical name.
    IF NEW.observed_state = 'UNKNOWN' THEN
        NEW.observed_state := 'AUDIT_UNKNOWN';
    END IF;

    -- ── Resolve fk_observed_cylinder_state from observed_state ───────────────
    -- Only attempt when the varchar is provided; if the caller already set the FK
    -- directly, prefer that value.
    IF NEW.observed_state IS NOT NULL AND NEW.fk_observed_cylinder_state IS NULL THEN
        SELECT pk_cylinder_state_id INTO v_observed_state_id
          FROM public.tbl_cylinder_states
         WHERE cylinder_state = NEW.observed_state;

        IF FOUND THEN
            NEW.fk_observed_cylinder_state := v_observed_state_id;
        ELSE
            RAISE WARNING
                'fn_evaluate_yard_line_state_match: observed_state value "%" '
                'does not exist in tbl_cylinder_states. fk_observed_cylinder_state left NULL.',
                NEW.observed_state;
        END IF;
    ELSIF NEW.fk_observed_cylinder_state IS NOT NULL AND NEW.observed_state IS NULL THEN
        -- Caller set FK only — back-fill the varchar for readability
        SELECT cylinder_state INTO NEW.observed_state
          FROM public.tbl_cylinder_states
         WHERE pk_cylinder_state_id = NEW.fk_observed_cylinder_state;
    END IF;

    -- ── If no observed state at all, nothing to evaluate ─────────────────────
    IF NEW.fk_observed_cylinder_state IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT cylinder_state INTO v_observed_state_name
      FROM public.tbl_cylinder_states
     WHERE pk_cylinder_state_id = NEW.fk_observed_cylinder_state;

    -- ── Get the system's current state for this cylinder ─────────────────────
    SELECT cs.pk_cylinder_state_id, cs.cylinder_state, cs.location
      INTO v_system_state_id, v_system_state_name, v_system_location
      FROM public.tbl_cylinder_current_status ccs
      JOIN public.tbl_cylinder_states cs ON cs.pk_cylinder_state_id = ccs.fk_current_state
     WHERE ccs.fk_cylinder = NEW.fk_cylinder;

    IF NOT FOUND THEN
        v_matches           := FALSE;
        v_system_state_name := 'NO_STATUS_RECORD';
        v_system_location   := 'UNKNOWN';
    ELSE
        -- Match rules: auditor observation → acceptable system states
        -- FULL observed        → system is in a FULL-family state (at yard or in transit)
        -- EMPTY observed       → system is in an EMPTY-family state
        -- DAMAGED observed     → system is DAMAGED
        -- AUDIT_UNKNOWN        → cannot confirm match; treated as mismatch for safety
        v_matches := CASE v_observed_state_name
            WHEN 'FULL'    THEN v_system_state_name IN (
                                    'FULL',
                                    'FULL_PICKED_FROM_SUPPLIER',
                                    'FULL_PICKED_UP_FOR_DELIVERY'
                                )
            WHEN 'EMPTY'   THEN v_system_state_name IN (
                                    'EMPTY',
                                    'EMPTY_IN_TRANSIT_TO_YARD',
                                    'COMMISSIONED',
                                    'EMPTY_PICKED_FOR_REFILL'
                                )
            WHEN 'DAMAGED' THEN v_system_state_name = 'DAMAGED'
            ELSE FALSE  -- AUDIT_UNKNOWN = cannot confirm
        END;
    END IF;

    NEW.state_matches_system := v_matches;

    -- ── Raise variance when states conflict ───────────────────────────────────
    IF NOT v_matches THEN
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
            NEW.fk_stock_check,
            NEW.fk_cylinder,
            'UNEXPECTED_STATE',
            COALESCE(v_system_state_name, 'UNKNOWN'),
            COALESCE(v_system_location,   'UNKNOWN'),
            'OPEN',
            'Auditor observed [' || COALESCE(v_observed_state_name, 'NULL') ||
            '] but system records state as [' || COALESCE(v_system_state_name, 'NO_STATUS') || '].'
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_evaluate_yard_line_state_match IS
    'BEFORE INSERT on tbl_yard_stock_check_line. '
    'V72 update: '
    '  • Populates fk_observed_cylinder_state FK from observed_state varchar. '
    '  • Remaps legacy UNKNOWN → AUDIT_UNKNOWN. '
    '  • Compares observed state against tbl_cylinder_current_status. '
    '  • Inserts UNEXPECTED_STATE variance row on mismatch.';