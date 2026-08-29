-- =============================================================================
-- V94 — Delivery Challan Decoupling & Yard Audit Serial-Scan Model
--
-- Prerequisites: V90 (fixed) → V93 must all be successfully applied first.
--
-- PART 1 — tbl_order: decouple challan_number
--   Delivery challan sheet numbers are now tracked through the new
--   tbl_challan_book_registry / tbl_challan_page_audit_ledger /
--   tbl_challan_transaction_link system introduced in V93.
--   The legacy challan_number column on tbl_order is made nullable for
--   backward compatibility; new orders will resolve their challan identity
--   through the polymorphic tbl_challan_transaction_link (discriminator
--   value = 'DELIVERY_RUN').
--
-- PART 2 — tbl_yard_stock_check_line: serial-string scan model
--   The observed_cylinder column (renamed from observed_state in V92) was
--   originally designed to hold an enum state (FULL / EMPTY / DAMAGED /
--   UNKNOWN). The requirement has changed:
--     • The operator scans or types the physical cylinder serial number.
--     • The value is stored as a raw string in observed_cylinder.
--     • The reconciliation orchestrator resolves the serial to fk_cylinder
--       and determines state mismatches in a separate pass.
--   The gate trigger (fn_evaluate_yard_line_state_match) that blocked
--   unknown cylinders and raised UNEXPECTED_STATE variances on INSERT is
--   therefore removed — it required fk_cylinder to already be set, which
--   is no longer guaranteed at scan time.
--
-- PART 3 — Update affected trigger functions
--   fn_yard_check_event_on_scan     (V85) — use observed_cylinder serial
--                                            directly; fk_cylinder is nullable
--   fn_yard_stock_check_line_reconcile (V91) — skip reconciliation line when
--                                            fk_cylinder not yet resolved
--
-- PART 4 — Recreate vw_yard_audit_scan_detail
--   PostgreSQL blocks ALTER COLUMN TYPE when a view depends on that column
--   (SQL State 0A000). vw_yard_audit_scan_detail (V76) references
--   observed_cylinder and uses an INNER JOIN on fk_cylinder — both of which
--   are incompatible with the serial-scan model. The view is dropped before
--   the ALTER and recreated afterward with:
--     • observed_cylinder exposed as the raw serial string
--     • INNER JOIN → LEFT JOIN on tbl_cylinder (fk_cylinder is now nullable)
--     • UNEXPECTED_STATE variance join removed (trigger deleted in PART 2D)
-- =============================================================================


-- =============================================================================
-- PART 1 — tbl_order: decouple challan_number
-- =============================================================================

-- Make challan_number nullable. New delivery orders will carry their sheet
-- reference via tbl_challan_transaction_link (DELIVERY_RUN discriminator)
-- rather than a manually-entered string on the order itself.
ALTER TABLE public.tbl_order
    ALTER COLUMN challan_number DROP NOT NULL;

-- The existing UNIQUE constraint (tbl_order_challan_number_unique) is kept:
-- PostgreSQL's UNIQUE index ignores NULL values, so multiple rows with
-- challan_number = NULL are allowed while still preventing duplicate
-- non-null challan codes on legacy orders.

COMMENT ON COLUMN public.tbl_order.challan_number IS
    'Legacy delivery challan reference number. Nullable as of V94: new orders '
    'track their physical sheet through tbl_challan_transaction_link '
    '(discriminator DELIVERY_RUN → OrderDo). Kept for backward compatibility '
    'with pre-V93 records that carried the challan number directly on the order.';


-- =============================================================================
-- PART 2 — tbl_yard_stock_check_line: serial-string scan model
-- =============================================================================

-- 2A. Drop the FULL / EMPTY / DAMAGED / UNKNOWN check constraint.
--     The column was originally observed_state (V60), renamed to
--     observed_cylinder in V92. It now stores an arbitrary serial number
--     string, not a controlled vocabulary of physical states.
ALTER TABLE public.tbl_yard_stock_check_line
    DROP CONSTRAINT IF EXISTS tbl_yard_stock_check_line_obs_state_chk;

-- 2B. Drop the dependent view before altering the column type.
--     PostgreSQL raises SQL State 0A000 if any view references the column
--     being altered. vw_yard_audit_scan_detail (created in V76) references
--     observed_cylinder directly. It is recreated in PART 4 below with an
--     updated schema that reflects the serial-scan model.
DROP VIEW IF EXISTS public.vw_yard_audit_scan_detail;

-- 2C. Widen observed_cylinder to accommodate real-world cylinder serial formats.
--     (The old observed_state was varchar(50); cylinder serials can be longer.)
ALTER TABLE public.tbl_yard_stock_check_line
    ALTER COLUMN observed_cylinder TYPE varchar(100);

COMMENT ON COLUMN public.tbl_yard_stock_check_line.observed_cylinder IS
    'The cylinder serial number as entered by the auditor at scan time. '
    'Stored as a raw string. The orchestrator resolves this serial to '
    'fk_cylinder (tbl_cylinder) in a subsequent pass and may also populate '
    'fk_system_cylinder_state and state_matches_system at that point. '
    'Allows scanning of cylinders not yet registered in the system '
    '(e.g., cylinders accidentally transferred by a customer from another party).';

-- 2D. Drop the BEFORE INSERT state-match gate trigger.
--     This trigger required fk_cylinder to be present at insert time to look up
--     the system state and emit UNEXPECTED_STATE variances. Both assumptions are
--     now invalid: fk_cylinder is nullable and state evaluation happens later.
DROP TRIGGER IF EXISTS trg_evaluate_yard_line_state_match
    ON public.tbl_yard_stock_check_line;

-- 2E. Drop the gate function itself.
DROP FUNCTION IF EXISTS public.fn_evaluate_yard_line_state_match();

-- The columns added by the old gate (fk_system_cylinder_state, system_state_name,
-- state_matches_system) are intentionally kept. The orchestrator will populate
-- them when it resolves observed_cylinder → fk_cylinder, preserving the
-- point-in-time state snapshot capability for audit reports.

COMMENT ON COLUMN public.tbl_yard_stock_check_line.fk_system_cylinder_state IS
    'FK to tbl_cylinder_states. Populated by the reconciliation orchestrator '
    'when it resolves observed_cylinder to fk_cylinder (i.e., after scan, '
    'not at INSERT time). NULL until resolution occurs.';

COMMENT ON COLUMN public.tbl_yard_stock_check_line.system_state_name IS
    'Denormalised copy of tbl_cylinder_states.cylinder_state at orchestrator '
    'resolution time. NULL until the orchestrator pass runs.';

COMMENT ON COLUMN public.tbl_yard_stock_check_line.state_matches_system IS
    'Set by the orchestrator after resolving observed_cylinder → fk_cylinder. '
    'TRUE  = the cylinder''s recorded state is consistent with expectations. '
    'FALSE = state mismatch; orchestrator will emit a variance row. '
    'NULL  = not yet evaluated (fk_cylinder not yet resolved).';


-- =============================================================================
-- PART 3A — Replace fn_yard_check_event_on_scan (V85)
--            Use observed_cylinder as the serial string directly.
--            fk_cylinder is now nullable at scan time.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_yard_check_event_on_scan()
RETURNS TRIGGER AS $$
DECLARE
    v_checked_by        varchar(200);
    v_check_context     varchar(30);
    v_scan_count        int4;
    v_cylinder_serial   varchar(100);
BEGIN
    -- Fetch audit header context
    SELECT checked_by, check_context
      INTO v_checked_by, v_check_context
      FROM public.tbl_yard_stock_check
     WHERE pk_stock_check_id = NEW.fk_stock_check;

    -- Prefer the user-entered serial from observed_cylinder.
    -- If fk_cylinder is already resolved (e.g. by an earlier orchestrator pass),
    -- confirm the authoritative serial from tbl_cylinder instead.
    IF NEW.fk_cylinder IS NOT NULL THEN
        SELECT cylinder_serial
          INTO v_cylinder_serial
          FROM public.tbl_cylinder
         WHERE pk_cylinder_id = NEW.fk_cylinder;
    END IF;

    v_cylinder_serial := COALESCE(
        v_cylinder_serial,
        NEW.observed_cylinder,
        '(serial not provided)'
    );

    -- Count total scans for this audit including the current row
    SELECT COUNT(*) INTO v_scan_count
      FROM public.tbl_yard_stock_check_line
     WHERE fk_stock_check = NEW.fk_stock_check;

    -- ── SCANNING_STARTED on the very first scan ───────────────────────────────
    IF v_scan_count = 1 THEN
        INSERT INTO public.tbl_yard_check_event (
            fk_stock_check, event_type, event_at,
            performed_by, fk_cylinder, event_remarks, cumulative_scanned
        ) VALUES (
            NEW.fk_stock_check,
            'SCANNING_STARTED',
            NEW.scanned_at,
            v_checked_by,
            NEW.fk_cylinder,        -- NULL when cylinder not yet resolved
            'First cylinder scanned: ' || v_cylinder_serial
                || '. Audit context: ' || v_check_context,
            1
        );
    END IF;

    -- ── CYLINDER_SCANNED for every scan ──────────────────────────────────────
    INSERT INTO public.tbl_yard_check_event (
        fk_stock_check, event_type, event_at,
        performed_by, fk_cylinder, event_remarks, cumulative_scanned
    ) VALUES (
        NEW.fk_stock_check,
        'CYLINDER_SCANNED',
        NEW.scanned_at,
        v_checked_by,
        NEW.fk_cylinder,            -- NULL when cylinder not yet resolved
        'Scanned: ' || v_cylinder_serial,
        v_scan_count
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_yard_check_event_on_scan() IS
    'V94 — Replaces V85 version. '
    'Resolves the display serial from observed_cylinder (user-entered string) '
    'first; falls back to tbl_cylinder.cylinder_serial only if fk_cylinder is '
    'already populated (orchestrator pre-resolved). '
    'fk_cylinder in the event row will be NULL for scans where the cylinder '
    'has not yet been resolved from the serial — the orchestrator will back-fill '
    'the event row fk_cylinder in its resolution pass if needed.';


-- =============================================================================
-- PART 3B — Replace fn_yard_stock_check_line_reconcile (V91)
--            Guard: skip reconciliation line creation when fk_cylinder is NULL.
--            The orchestrator creates the ACCOUNTED line after resolving the
--            serial to a known cylinder entity.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_yard_stock_check_line_reconcile()
RETURNS TRIGGER AS $$
DECLARE
    v_header_id         int8;
    v_check_context     varchar(30);
    v_fk_vehicle_trip   int8;
BEGIN
    -- Get check context and optional trip link from the parent check
    SELECT check_context, fk_vehicle_trip
      INTO v_check_context, v_fk_vehicle_trip
      FROM public.tbl_yard_stock_check
     WHERE pk_stock_check_id = NEW.fk_stock_check;

    -- Guard: if fk_cylinder is not yet resolved, skip reconciliation.
    -- The orchestrator resolves observed_cylinder → fk_cylinder and will
    -- call fn_add_reconciliation_line directly for each resolved scan line.
    IF NEW.fk_cylinder IS NULL THEN
        RAISE NOTICE
            '[YARD_CHECK/line]: fk_cylinder is NULL on scan line %. '
            'Cylinder serial "%" will be reconciled by the orchestrator '
            'after serial resolution.',
            NEW.pk_stock_check_line_id,
            COALESCE(NEW.observed_cylinder, '(not provided)');
        RETURN NEW;
    END IF;

    -- Get or create the YARD_CHECK reconciliation header for this audit event
    SELECT pk_header_id INTO v_header_id
      FROM public.tbl_reconciliation_header
     WHERE fk_yard_stock_check = NEW.fk_stock_check
       AND header_type         = 'YARD_CHECK'
     ORDER BY opened_at DESC
     LIMIT 1;

    IF v_header_id IS NULL THEN
        -- First resolved cylinder scanned — open the header
        v_header_id := public.fn_open_reconciliation_header(
            'YARD_CHECK',
            'tbl_yard_stock_check',
            NEW.fk_stock_check,
            0,                          -- expected_count updated at completion
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

    -- Create an ACCOUNTED checkpoint line for this scanned cylinder
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

COMMENT ON FUNCTION public.fn_yard_stock_check_line_reconcile() IS
    'V94 — Replaces V91 version. '
    'Guards against NULL fk_cylinder: when the operator enters a serial string '
    'and the cylinder is not yet resolved, the reconciliation line is deferred '
    'to the orchestrator resolution pass. When fk_cylinder IS set (either '
    'pre-resolved or re-triggered by the orchestrator UPDATE), the function '
    'opens the YARD_CHECK header on first hit and creates an ACCOUNTED '
    'checkpoint line per resolved cylinder.';


-- =============================================================================
-- PART 4 — Recreate vw_yard_audit_scan_detail
--
-- Changes from V76 original:
--   1. observed_cylinder now shows the raw serial string entered by the
--      operator instead of the FULL/EMPTY/DAMAGED/UNKNOWN state enum.
--   2. INNER JOIN on tbl_cylinder → LEFT JOIN: fk_cylinder is nullable until
--      the orchestrator resolves the serial to a known cylinder entity.
--      Unresolved rows appear in the view with cylinder_serial = NULL so
--      the audit dashboard can surface them for manual review.
--   3. The UNEXPECTED_STATE variance join is removed: that variance type was
--      emitted by fn_evaluate_yard_line_state_match, which is deleted in
--      PART 2D above. State-mismatch variances are now written by the
--      orchestrator after serial resolution.
-- =============================================================================

CREATE OR REPLACE VIEW public.vw_yard_audit_scan_detail AS
SELECT
    ysl.pk_stock_check_line_id,
    ysc.check_date,
    ysc.audit_context,
    ysc.checked_by,
    -- Serial entered by operator at scan time (always present)
    ysl.observed_cylinder                               AS scanned_serial,
    -- Resolved cylinder entity (NULL until orchestrator matches the serial)
    ysl.fk_cylinder,
    c.cylinder_serial                                   AS confirmed_serial,
    -- System state snapshot captured at orchestrator resolution time
    ysl.fk_system_cylinder_state,
    ysl.system_state_name                               AS system_state_at_resolution,
    cs_now.cylinder_state                               AS system_state_now,
    -- Match evaluation (NULL until orchestrator runs)
    ysl.state_matches_system,
    -- Auditor notes
    ysl.auditor_notes,
    ysl.scanned_at,
    -- Resolution status derived from fk_cylinder
    CASE
        WHEN ysl.fk_cylinder IS NULL THEN 'PENDING_RESOLUTION'
        ELSE 'RESOLVED'
    END                                                 AS resolution_status
FROM   public.tbl_yard_stock_check_line      ysl
JOIN   public.tbl_yard_stock_check           ysc
           ON ysc.pk_stock_check_id = ysl.fk_stock_check
LEFT   JOIN public.tbl_cylinder              c
           ON c.pk_cylinder_id = ysl.fk_cylinder
LEFT   JOIN public.tbl_cylinder_states       cs_now
           ON cs_now.pk_cylinder_state_id = (
               SELECT fk_current_state
               FROM   public.tbl_cylinder_current_status
               WHERE  fk_cylinder = ysl.fk_cylinder
           )
ORDER  BY ysc.check_date DESC, ysl.scanned_at;

COMMENT ON VIEW public.vw_yard_audit_scan_detail IS
    'V94 — Replaces V76 version. '
    'Full detail for every yard audit scan line under the serial-scan model. '
    'scanned_serial = raw serial string entered by the operator at scan time. '
    'confirmed_serial / fk_cylinder = NULL until the orchestrator resolves the '
    'serial to a tbl_cylinder entity. '
    'resolution_status = PENDING_RESOLUTION (fk_cylinder NULL) or RESOLVED. '
    'system_state_at_resolution = state recorded by the system at orchestrator '
    'resolution time (immutable after resolution). '
    'system_state_now = current system state (may differ if cylinder moved later). '
    'state_matches_system = NULL until orchestrator evaluates; FALSE triggers a '
    'variance row written by the orchestrator, not by a trigger.';