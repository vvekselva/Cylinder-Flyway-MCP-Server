-- ============================================================================
-- V119__Yard_Audit_Ownership_Model_Trigger_Redirect.sql
-- ============================================================================
-- Purpose
-- -------
-- Redirect Yard Audit trigger-chain decisions away from tbl_cylinder_current_status
-- and into the ownership model:
--
--   Yard expected source       : tbl_yard_inventory_line where is_active = true
--   Vehicle/logistics source   : tbl_cylinder_logistics_execution_line where is_active = true
--   Customer/Supplier source   : tbl_cylinder_party_custody where custody_status = 'ACTIVE'
--
-- Scope
-- -----
-- 1. fn_resolve_yard_stock_check_line()
--      Resolves scanned serial into known/third-party cylinder.
--      Snapshots ownership-derived system state.
--      Sets state_matches_system based on Yard ownership + observed state.
--
-- 2. fn_yard_stock_check_line_reconcile()
--      Keeps existing behavior for known cylinders.
--      Skips third-party cylinders from reconciliation counts.
--
-- 3. fn_yard_stock_check_completed_reconcile()
--      Compares scanned cylinders against active Yard inventory.
--      Treats only FULL and EMPTY active yard cylinders as expected for this phase.
--      Marks:
--          YARD_MISSING
--          YARD_UNEXPECTED
--          YARD_STATE_MISMATCH
--
-- Notes
-- -----
-- DAMAGED, LOST, DECOMMISSIONED are intentionally excluded from expected Yard
-- audit population in this phase.
-- ============================================================================


-- ============================================================================
-- 1. Resolve scanned line using ownership model
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_resolve_yard_stock_check_line()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_cylinder_id           int8;
    v_system_state_id       int8;
    v_system_state_name     varchar(100);
    v_checked_by            varchar(200);
    v_scan_count            int4;
    v_event_remarks         varchar(500);
    v_party_type            varchar(20);
BEGIN
    -- Normalise the entered serial for storage/comparison.
    NEW.observed_cylinder := NULLIF(BTRIM(NEW.observed_cylinder), '');

    IF NEW.observed_cylinder IS NULL THEN
        NEW.fk_cylinder              := NULL;
        NEW.fk_system_cylinder_state := NULL;
        NEW.system_state_name        := NULL;
        NEW.state_matches_system     := NULL;
        RETURN NEW;
    END IF;

    -- Resolve observed serial to cylinder master. Unknown serials are allowed.
    SELECT c.pk_cylinder_id
      INTO v_cylinder_id
      FROM public.tbl_cylinder c
     WHERE UPPER(BTRIM(c.cylinder_serial)) = UPPER(NEW.observed_cylinder)
     ORDER BY c.pk_cylinder_id
     LIMIT 1;

    -- Unknown / third-party cylinder.
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

    -- Ownership priority:
    -- 1. Active Yard inventory line        -> actual expected Yard state
    -- 2. Active Logistics execution line   -> in-transit state
    -- 3. Active Party custody              -> derived party state
    -- 4. No ownership record               -> ownership unknown
    SELECT yil.fk_cylinder_state,
           cs.cylinder_state
      INTO v_system_state_id,
           v_system_state_name
      FROM public.tbl_yard_inventory_line yil
      JOIN public.tbl_cylinder_states cs
        ON cs.pk_cylinder_state_id = yil.fk_cylinder_state
     WHERE yil.fk_cylinder = v_cylinder_id
       AND yil.is_active = TRUE
     ORDER BY yil.entry_date DESC, yil.pk_yard_inventory_line_id DESC
     LIMIT 1;

    IF v_system_state_id IS NULL THEN
        SELECT clel.fk_cylinder_state,
               cs.cylinder_state
          INTO v_system_state_id,
               v_system_state_name
          FROM public.tbl_cylinder_logistics_execution_line clel
          JOIN public.tbl_cylinder_states cs
            ON cs.pk_cylinder_state_id = clel.fk_cylinder_state
         WHERE clel.fk_cylinder = v_cylinder_id
           AND clel.is_active = TRUE
         ORDER BY clel.created_at DESC, clel.pk_cylinder_logistics_execution_line_id DESC
         LIMIT 1;
    END IF;

    IF v_system_state_id IS NULL THEN
        SELECT cpc.party_type
          INTO v_party_type
          FROM public.tbl_cylinder_party_custody cpc
         WHERE cpc.fk_cylinder = v_cylinder_id
           AND cpc.custody_status = 'ACTIVE'
         ORDER BY cpc.entered_at DESC, cpc.pk_custody_id DESC
         LIMIT 1;

        IF v_party_type = 'CUSTOMER' THEN
            SELECT cs.pk_cylinder_state_id, cs.cylinder_state
              INTO v_system_state_id, v_system_state_name
              FROM public.tbl_cylinder_states cs
             WHERE cs.cylinder_state = 'DELIVERED_FOR_CONSUMPTION'
             LIMIT 1;
        ELSIF v_party_type = 'SUPPLIER' THEN
            SELECT cs.pk_cylinder_state_id, cs.cylinder_state
              INTO v_system_state_id, v_system_state_name
              FROM public.tbl_cylinder_states cs
             WHERE cs.cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL'
             LIMIT 1;
        END IF;
    END IF;

    NEW.fk_system_cylinder_state := v_system_state_id;
    NEW.system_state_name        := v_system_state_name;

    -- Known cylinder with no active ownership record.
    IF v_system_state_id IS NULL THEN
        NEW.system_state_name := 'OWNERSHIP_UNKNOWN';
        IF NEW.fk_observed_cylinder_state IS NULL THEN
            NEW.state_matches_system := NULL;
        ELSE
            NEW.state_matches_system := FALSE;
        END IF;
        RETURN NEW;
    END IF;

    -- Match rule for Yard Audit:
    -- A scanned system cylinder is considered matching only when it is expected
    -- in active Yard ownership and the observed state equals the active yard state.
    -- Known cylinders currently in Logistics / Customer / Supplier are system
    -- cylinders but are not expected in Yard; they become mismatch/unexpected.
    IF NEW.fk_observed_cylinder_state IS NULL THEN
        NEW.state_matches_system := NULL;
    ELSE
        NEW.state_matches_system :=
            EXISTS (
                SELECT 1
                  FROM public.tbl_yard_inventory_line yil
                 WHERE yil.fk_cylinder = v_cylinder_id
                   AND yil.is_active = TRUE
                   AND yil.fk_cylinder_state IN (
                       SELECT cs.pk_cylinder_state_id
                         FROM public.tbl_cylinder_states cs
                        WHERE cs.cylinder_state IN ('FULL', 'EMPTY')
                   )
            )
            AND NEW.fk_observed_cylinder_state = v_system_state_id;
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.fn_resolve_yard_stock_check_line() IS
    'Ownership-model resolver for Yard Audit scan lines. Resolves observed serial, '
    'classifies third-party cylinders, snapshots ownership-derived system state, '
    'and sets state_matches_system using active Yard inventory as expected source.';


-- ============================================================================
-- 2. Reconcile line-level known scan rows
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_yard_stock_check_line_reconcile()
RETURNS TRIGGER AS $$
DECLARE
    v_header_id         int8;
    v_check_context     varchar(30);
    v_fk_vehicle_trip   int8;
BEGIN
    SELECT check_context, fk_vehicle_trip
      INTO v_check_context, v_fk_vehicle_trip
      FROM public.tbl_yard_stock_check
     WHERE pk_stock_check_id = NEW.fk_stock_check;

    -- Third-party / unknown cylinders are intentionally not counted as registered
    -- system-accounted cylinders. Their visibility is handled by
    -- THIRD_PARTY_CYLINDER_FOUND events and dashboard alerts.
    IF NEW.fk_cylinder IS NULL THEN
        RAISE NOTICE
            '[YARD_CHECK/line]: Third-party or unresolved cylinder on scan line %. Serial "%".',
            NEW.pk_stock_check_line_id,
            COALESCE(NEW.observed_cylinder, '(not provided)');
        RETURN NEW;
    END IF;

    SELECT pk_header_id INTO v_header_id
      FROM public.tbl_reconciliation_header
     WHERE fk_yard_stock_check = NEW.fk_stock_check
       AND header_type         = 'YARD_CHECK'
     ORDER BY opened_at DESC
     LIMIT 1;

    IF v_header_id IS NULL THEN
        v_header_id := public.fn_open_reconciliation_header(
            'YARD_CHECK',
            'tbl_yard_stock_check',
            NEW.fk_stock_check,
            0,
            NULL,
            v_fk_vehicle_trip,
            NULL, NULL,
            NEW.fk_stock_check,
            NULL,
            'Yard check ' || COALESCE(v_check_context, 'ADHOC')
                || ' — check id ' || NEW.fk_stock_check || '. Scanning in progress.'
        );
    END IF;

    IF v_header_id IS NULL THEN
        RAISE NOTICE '[YARD_CHECK/line]: Could not create header for check %.', NEW.fk_stock_check;
        RETURN NEW;
    END IF;

    BEGIN
        PERFORM public.fn_add_reconciliation_line(
            v_header_id,
            NEW.fk_cylinder,
            'YARD_AUDIT',
            'ACCOUNTED',
            'YARD_PRESENT',
            'tbl_yard_stock_check_line',
            NEW.pk_stock_check_line_id,
            v_fk_vehicle_trip,
            NULL,
            'Cylinder scanned present in yard at '
                || to_char(NEW.scanned_at, 'YYYY-MM-DD HH24:MI')
                || ' (check context: ' || COALESCE(v_check_context, 'ADHOC') || ')',
            NEW.scanned_at::date
        );

        UPDATE public.tbl_reconciliation_header
           SET accounted_count = accounted_count + 1,
               updated_at      = now()
         WHERE pk_header_id = v_header_id;

    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE '[YARD_CHECK/line cylinder=%]: %', NEW.fk_cylinder, SQLERRM;
    END;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- 3. Completion reconciliation using active Yard inventory as expected source
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_yard_stock_check_completed_reconcile()
RETURNS TRIGGER AS $$
DECLARE
    v_header_id                 int8;
    v_expected_count            int4 := 0;
    v_missing_count             int4 := 0;
    v_unexpected_count          int4 := 0;
    v_state_mismatch_count      int4 := 0;
    v_missing_serials           text := '';
    v_unexpected_serials        text := '';
    v_state_mismatch_serials    text := '';
    v_closing_remarks           text;
    v_fk_vehicle_trip           int8;
    v_rec                       RECORD;
BEGIN
    IF NEW.check_status <> 'COMPLETED'
    OR OLD.check_status  = 'COMPLETED' THEN
        RETURN NEW;
    END IF;

    SELECT pk_header_id, fk_vehicle_trip
      INTO v_header_id, v_fk_vehicle_trip
      FROM public.tbl_reconciliation_header
     WHERE fk_yard_stock_check = NEW.pk_stock_check_id
       AND header_type         = 'YARD_CHECK'
       AND header_status       NOT IN ('CLOSED', 'VARIANCE')
     ORDER BY opened_at DESC
     LIMIT 1;

    IF v_header_id IS NULL THEN
        RAISE NOTICE '[YARD_CHECK/completed]: No open header for check %.', NEW.pk_stock_check_id;
        RETURN NEW;
    END IF;

    -- Expected population for this phase: active Yard ownership only, FULL/EMPTY.
    SELECT COUNT(*)::int4
      INTO v_expected_count
      FROM public.tbl_yard_inventory_line yil
      JOIN public.tbl_cylinder_states cs
        ON cs.pk_cylinder_state_id = yil.fk_cylinder_state
     WHERE yil.is_active = TRUE
       AND cs.cylinder_state IN ('FULL', 'EMPTY');

    UPDATE public.tbl_reconciliation_header
       SET expected_count = v_expected_count,
           updated_at     = now()
     WHERE pk_header_id = v_header_id;

    -- Missing: active yard cylinder not scanned in this audit.
    FOR v_rec IN
        SELECT yil.fk_cylinder, c.cylinder_serial
          FROM public.tbl_yard_inventory_line yil
          JOIN public.tbl_cylinder c
            ON c.pk_cylinder_id = yil.fk_cylinder
          JOIN public.tbl_cylinder_states cs
            ON cs.pk_cylinder_state_id = yil.fk_cylinder_state
         WHERE yil.is_active = TRUE
           AND cs.cylinder_state IN ('FULL', 'EMPTY')
           AND NOT EXISTS (
                 SELECT 1
                   FROM public.tbl_yard_stock_check_line scl
                  WHERE scl.fk_stock_check = NEW.pk_stock_check_id
                    AND scl.fk_cylinder = yil.fk_cylinder
           )
    LOOP
        v_missing_count := v_missing_count + 1;

        IF v_missing_count <= 20 THEN
            v_missing_serials := v_missing_serials || v_rec.cylinder_serial || ', ';
        END IF;

        BEGIN
            PERFORM public.fn_add_reconciliation_line(
                v_header_id,
                v_rec.fk_cylinder,
                'YARD_AUDIT',
                'VARIANCE',
                'YARD_MISSING',
                'tbl_yard_stock_check',
                NEW.pk_stock_check_id,
                v_fk_vehicle_trip,
                NULL,
                'MISSING — cylinder ' || v_rec.cylinder_serial
                    || ' expected in active yard inventory but not found in scan.',
                NEW.check_date
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '[YARD_CHECK/missing cylinder=%]: %', v_rec.fk_cylinder, SQLERRM;
        END;
    END LOOP;

    -- Unexpected known system cylinder: scanned but not active in expected yard population.
    FOR v_rec IN
        SELECT scl.fk_cylinder,
               c.cylinder_serial,
               scl.system_state_name
          FROM public.tbl_yard_stock_check_line scl
          JOIN public.tbl_cylinder c
            ON c.pk_cylinder_id = scl.fk_cylinder
         WHERE scl.fk_stock_check = NEW.pk_stock_check_id
           AND scl.fk_cylinder IS NOT NULL
           AND NOT EXISTS (
                 SELECT 1
                   FROM public.tbl_yard_inventory_line yil
                   JOIN public.tbl_cylinder_states cs
                     ON cs.pk_cylinder_state_id = yil.fk_cylinder_state
                  WHERE yil.fk_cylinder = scl.fk_cylinder
                    AND yil.is_active = TRUE
                    AND cs.cylinder_state IN ('FULL', 'EMPTY')
           )
    LOOP
        v_unexpected_count := v_unexpected_count + 1;

        IF v_unexpected_count <= 10 THEN
            v_unexpected_serials := v_unexpected_serials || v_rec.cylinder_serial || ', ';
        END IF;

        UPDATE public.tbl_reconciliation_checkpoint
           SET line_status           = 'VARIANCE',
               checkpoint_status     = 'VARIANCE',
               accountability_bucket = 'YARD_UNEXPECTED',
               actual_count          = 0,
               line_resolved_at      = now(),
               remarks               = COALESCE(remarks, '')
                                       || ' | KNOWN SYSTEM CYLINDER NOT EXPECTED IN YARD. '
                                       || 'Ownership/state snapshot: '
                                       || COALESCE(v_rec.system_state_name, 'UNKNOWN')
         WHERE fk_header  = v_header_id
           AND fk_cylinder = v_rec.fk_cylinder
           AND line_status = 'ACCOUNTED';
    END LOOP;

    -- State mismatch: active expected yard cylinder was scanned but observed state
    -- does not match active yard inventory state.
    FOR v_rec IN
        SELECT scl.fk_cylinder,
               c.cylinder_serial,
               scl.system_state_name
          FROM public.tbl_yard_stock_check_line scl
          JOIN public.tbl_cylinder c
            ON c.pk_cylinder_id = scl.fk_cylinder
         WHERE scl.fk_stock_check = NEW.pk_stock_check_id
           AND scl.fk_cylinder IS NOT NULL
           AND scl.state_matches_system = FALSE
           AND EXISTS (
                 SELECT 1
                   FROM public.tbl_yard_inventory_line yil
                   JOIN public.tbl_cylinder_states cs
                     ON cs.pk_cylinder_state_id = yil.fk_cylinder_state
                  WHERE yil.fk_cylinder = scl.fk_cylinder
                    AND yil.is_active = TRUE
                    AND cs.cylinder_state IN ('FULL', 'EMPTY')
           )
    LOOP
        v_state_mismatch_count := v_state_mismatch_count + 1;

        IF v_state_mismatch_count <= 10 THEN
            v_state_mismatch_serials := v_state_mismatch_serials || v_rec.cylinder_serial || ', ';
        END IF;

        UPDATE public.tbl_reconciliation_checkpoint
           SET line_status           = 'VARIANCE',
               checkpoint_status     = 'VARIANCE',
               accountability_bucket = 'YARD_STATE_MISMATCH',
               line_resolved_at      = now(),
               remarks               = COALESCE(remarks, '')
                                       || ' | STATE MISMATCH. Expected: '
                                       || COALESCE(v_rec.system_state_name, 'UNKNOWN')
         WHERE fk_header  = v_header_id
           AND fk_cylinder = v_rec.fk_cylinder
           AND line_status = 'ACCOUNTED';
    END LOOP;

    IF v_missing_count = 0
       AND v_unexpected_count = 0
       AND v_state_mismatch_count = 0 THEN
        v_closing_remarks :=
            'Yard check ' || COALESCE(NEW.checked_by, 'system') || ' COMPLETED. '
            || v_expected_count || ' expected yard cylinders: all present, no variances.';
    ELSE
        v_closing_remarks :=
            'Yard check COMPLETED with VARIANCES. '
            || CASE WHEN v_missing_count > 0
                    THEN 'Missing: ' || v_missing_count || ' cylinders ('
                         || rtrim(v_missing_serials, ', ')
                         || CASE WHEN v_missing_count > 20 THEN ' …)' ELSE ')' END
                    ELSE '' END
            || CASE WHEN v_unexpected_count > 0
                    THEN ' Unexpected: ' || v_unexpected_count || ' cylinders ('
                         || rtrim(v_unexpected_serials, ', ')
                         || CASE WHEN v_unexpected_count > 10 THEN ' …)' ELSE ')' END
                    ELSE '' END
            || CASE WHEN v_state_mismatch_count > 0
                    THEN ' State mismatch: ' || v_state_mismatch_count || ' cylinders ('
                         || rtrim(v_state_mismatch_serials, ', ')
                         || CASE WHEN v_state_mismatch_count > 10 THEN ' …)' ELSE ')' END
                    ELSE '' END;
    END IF;

    BEGIN
        PERFORM public.fn_close_reconciliation_header(v_header_id, v_closing_remarks);
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE '[YARD_CHECK/close header]: %', SQLERRM;
    END;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_yard_stock_check_completed_reconcile() IS
    'Ownership-model completion reconciliation for Yard Audit. Expected source is '
    'active tbl_yard_inventory_line in FULL/EMPTY states; scanned known cylinders '
    'outside active yard ownership become YARD_UNEXPECTED; active yard cylinders '
    'with wrong observed state become YARD_STATE_MISMATCH.';
