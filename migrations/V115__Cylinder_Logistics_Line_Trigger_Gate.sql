-- =====================================================================
-- V115__Cylinder_Logistics_Line_Trigger_Gate.sql
--
-- Purpose:
-- 1. Add a DB-level gate for tbl_cylinder_logistics_execution_line.
-- 2. Prevent invalid logistics lifecycle states from entering the ownership
--    model silently.
-- 3. Use tbl_cylinder_state_transition as the lifecycle authority.
--
-- Important timing note:
-- Existing legacy triggers may already update tbl_cylinder_current_status /
-- tbl_cylinder_state_audit before the service inserts the logistics line.
-- Therefore this gate allows both:
--   a) current_state -> logistics_state exists in tbl_cylinder_state_transition
--   b) current_state already equals logistics_state
--
-- This avoids duplicate-transition rejection while still blocking invalid states.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Ensure yard inventory can accept all returnable yard-end states.
-- Existing V113 already inserted most of these; this migration adds the
-- missing return-compatible states idempotently.
-- ---------------------------------------------------------------------
INSERT INTO public.tbl_yard_inventory_allowed_state
(
    fk_cylinder_state,
    is_active,
    created_at,
    updated_at
)
SELECT
    cs.pk_cylinder_state_id,
    TRUE,
    CURRENT_TIMESTAMP,
    CURRENT_TIMESTAMP
FROM public.tbl_cylinder_states cs
WHERE cs.cylinder_state IN (
    'EMPTY_PICKED_UP_FROM_SUPPLIER',
    'EMPTY_RETURNED_WALKIN'
)
ON CONFLICT (fk_cylinder_state) DO UPDATE
SET is_active = TRUE,
    updated_at = CURRENT_TIMESTAMP;


-- ---------------------------------------------------------------------
-- Logistics line lifecycle gate.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_validate_cylinder_logistics_line_state()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_new_state_name      VARCHAR(60);
    v_current_state_id    BIGINT;
    v_current_state_name  VARCHAR(60);
BEGIN
    -- Only active logistics lines represent current in-vehicle ownership.
    -- Completion updates set is_active=false and should not be blocked here.
    IF NEW.is_active IS DISTINCT FROM TRUE THEN
        RETURN NEW;
    END IF;

    -- Exception lines are operational exceptions; they can be inspected and
    -- resolved separately without this lifecycle gate blocking them.
    IF NEW.is_exception IS TRUE THEN
        RETURN NEW;
    END IF;

    SELECT cs.cylinder_state
      INTO v_new_state_name
      FROM public.tbl_cylinder_states cs
     WHERE cs.pk_cylinder_state_id = NEW.fk_cylinder_state;

    IF v_new_state_name IS NULL THEN
        RAISE EXCEPTION
            'LOGISTICS LINE VALIDATION FAILED — fk_cylinder=%, fk_cylinder_state=% does not resolve to tbl_cylinder_states.',
            NEW.fk_cylinder, NEW.fk_cylinder_state;
    END IF;

    -- Prefer current-status snapshot when available.
    SELECT ccs.fk_current_state
      INTO v_current_state_id
      FROM public.tbl_cylinder_current_status ccs
     WHERE ccs.fk_cylinder = NEW.fk_cylinder;

    -- Fallback to latest audit row if current-status is unavailable.
    IF v_current_state_id IS NULL THEN
        SELECT csa.fk_new_state
          INTO v_current_state_id
          FROM public.tbl_cylinder_state_audit csa
         WHERE csa.fk_cylinder = NEW.fk_cylinder
         ORDER BY csa.changed_at DESC, csa.pk_audit_id DESC
         LIMIT 1;
    END IF;

    IF v_current_state_id IS NULL THEN
        RAISE EXCEPTION
            'LOGISTICS LINE VALIDATION FAILED — fk_cylinder=% has no current status/audit state before logistics state [%].',
            NEW.fk_cylinder, v_new_state_name;
    END IF;

    SELECT cs.cylinder_state
      INTO v_current_state_name
      FROM public.tbl_cylinder_states cs
     WHERE cs.pk_cylinder_state_id = v_current_state_id;

    IF v_current_state_name IS NULL THEN
        RAISE EXCEPTION
            'LOGISTICS LINE VALIDATION FAILED — fk_cylinder=% current state id % does not resolve to tbl_cylinder_states.',
            NEW.fk_cylinder, v_current_state_id;
    END IF;

    -- Legacy trigger may have already advanced the state to the logistics state.
    -- In that case, accepting the row is correct and avoids false rejection.
    IF v_current_state_name = v_new_state_name THEN
        RETURN NEW;
    END IF;

    -- Otherwise, the current state must legally transition into the logistics state.
    IF NOT EXISTS (
        SELECT 1
          FROM public.tbl_cylinder_state_transition cst
         WHERE cst.from_state = v_current_state_name
           AND cst.to_state   = v_new_state_name
    ) THEN
        RAISE EXCEPTION
            'LOGISTICS LINE VALIDATION FAILED — fk_cylinder=%, illegal logistics transition [%] -> [%].',
            NEW.fk_cylinder, v_current_state_name, v_new_state_name;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_cylinder_logistics_line_state
ON public.tbl_cylinder_logistics_execution_line;

CREATE TRIGGER trg_validate_cylinder_logistics_line_state
BEFORE INSERT OR UPDATE OF fk_cylinder_state, is_active, is_exception
ON public.tbl_cylinder_logistics_execution_line
FOR EACH ROW
EXECUTE FUNCTION public.fn_validate_cylinder_logistics_line_state();
