-- =============================================================================
-- V84__YardAuditCheckpoints_And_BusinessDayHarmonization.sql
-- =============================================================================
--
-- FIXES:
--   FIX-0  addr.address_line1 → addr.address_line_1 in all four dashboard
--          views (V83 failed at this column — views are recreated here).
--
-- NEW CHECKPOINT TYPES (added to constraint):
--   YARD_AUDIT_MORNING   – physical yard audit AFTER last trip departs;
--                          validates what remains in the yard is consistent
--                          with the load manifest.
--   YARD_AUDIT_POST_TRIP – physical yard count after a trip returns and
--                          empties its load into the yard, BEFORE the next
--                          trip is planned.
--   YARD_AUDIT_EOD       – end-of-day physical audit after ALL vehicles have
--                          returned and emptied. Gates the DAILY_CLOSING.
--
-- SCHEMA CHANGE:
--   tbl_yard_stock_check gains  check_context  varchar(30)
--     'MORNING' | 'POST_TRIP' | 'EOD' | 'ADHOC'
--   and  fk_vehicle_trip  int8 NULL  (which trip triggered this audit)
--
-- TRIGGER:
--   tbl_yard_stock_check AFTER INSERT → fn_yard_stock_check_checkpoint()
--     Creates the correct YARD_AUDIT_* checkpoint type based on check_context.
--   tbl_yard_stock_check AFTER UPDATE (check_status → COMPLETED)
--     → fn_yard_stock_check_completed()
--     Resolves the checkpoint with actual scanned count vs expected.
--
-- BUSINESS DAY HARMONIZATION:
--   The orchestrator now understands the two-trip-slot day:
--
--     BOD
--      │  fn_open_daily_count()        → DAILY_OPENING checkpoint
--      │
--      ├─ SLOT A (Morning trip)
--      │   tbl_vehicle_trip → Loaded   → TRIP_LOAD_CONFIRMED + TRIP_DEPARTURE
--      │   [vehicles depart]
--      │   tbl_yard_stock_check INSERT
--      │     check_context = 'MORNING' → YARD_AUDIT_MORNING  ← NEW
--      │   [vehicles return by noon, empty contents into yard]
--      │   tbl_vehicle_trip → Halt     → resolve TRIP_DEPARTURE
--      │   tbl_yard_stock_check INSERT
--      │     check_context = 'POST_TRIP' → YARD_AUDIT_POST_TRIP  ← NEW
--      │   [office plans afternoon trip using verified yard count]
--      │
--      ├─ SLOT B (Afternoon trip) — identical LOAD/DEPARTURE/HALT sequence
--      │   [vehicles return evening, empty contents into yard]
--      │   tbl_vehicle_trip → Halt     → resolve TRIP_DEPARTURE
--      │
--      │  EOD yard audit (all trips halted)
--      │   tbl_yard_stock_check INSERT
--      │     check_context = 'EOD' → YARD_AUDIT_EOD  ← NEW
--      │
--      │  Office clicks "Close Day" only after YARD_AUDIT_EOD is MATCHED
--      │   → DAILY_CLOSING checkpoint
--     EOD
--
--   NOTE ON CHALLAN TIMING:
--   Delivery challans are entered next morning. This is by design.
--   TRIP_DEPARTURE is created at 'Loaded' (before vehicles leave) — so the
--   checkpoint count is already locked to the physical reality. The challan
--   entry (TRIP_STOP_DELIVERY) happens retrospectively and resolves at
--   whatever time the office enters it. The YARD_AUDIT_EOD does NOT wait
--   for challans — it validates cylinder count in the yard against what
--   the system believes is physically present, independent of challan state.
-- =============================================================================


-- =============================================================================
-- PART 0 — Fix addr.address_line1 → addr.address_line_1 in all V83 views
--           Recreate all four dashboard views with correct column name.
--           (tbl_customer_address joins tbl_address via fk_address;
--            tbl_address has address_line_1, not address_line1)
-- =============================================================================

CREATE OR REPLACE VIEW public.vw_cylinders_at_customers AS
SELECT
    cust.customer_name,
    -- tbl_customer_address → tbl_address via fk_address; column = address_line_1
    a.address_line_1                                    AS delivery_location,
    c.cylinder_serial,
    p.product_name,
    cs.cylinder_state                                   AS current_state,
    cpc.entered_at                                      AS delivered_at,
    o.challan_number                                    AS delivery_challan,
    EXTRACT(DAY FROM now() - cpc.entered_at)::int       AS days_at_customer,
    CASE
        WHEN EXTRACT(DAY FROM now() - cpc.entered_at) > 30 THEN 'OVERDUE'
        WHEN EXTRACT(DAY FROM now() - cpc.entered_at) > 14 THEN 'FOLLOW_UP'
        ELSE 'OK'
    END                                                 AS aging_flag
FROM   public.tbl_cylinder_party_custody    cpc
JOIN   public.tbl_cylinder                  c    ON c.pk_cylinder_id      = cpc.fk_cylinder
JOIN   public.tbl_product                   p    ON p.pk_product_id       = c.fk_product
JOIN   public.tbl_customer                  cust ON cust.pk_customer_id   = cpc.fk_customer
-- tbl_customer_address links customer→address via fk_address
LEFT   JOIN public.tbl_customer_address     ca   ON ca.pk_customer_address_id
                                                        = cpc.fk_customer_address
LEFT   JOIN public.tbl_address              a    ON a.pk_address_id       = ca.fk_address
LEFT   JOIN public.tbl_order                o    ON o.pk_order_id         = cpc.fk_entry_order
LEFT   JOIN public.tbl_cylinder_current_status ccs
           ON ccs.fk_cylinder = cpc.fk_cylinder
LEFT   JOIN public.tbl_cylinder_states      cs
           ON cs.pk_cylinder_state_id = ccs.fk_current_state
WHERE  cpc.custody_status = 'ACTIVE'
  AND  cpc.party_type     = 'CUSTOMER'
ORDER  BY days_at_customer DESC, cust.customer_name, c.cylinder_serial;

COMMENT ON VIEW public.vw_cylinders_at_customers IS
    'Live view: every cylinder currently at a customer. '
    'address_line_1 is read via tbl_customer_address.fk_address → tbl_address. '
    'aging_flag = OVERDUE (>30 days), FOLLOW_UP (>14 days), OK.';


CREATE OR REPLACE VIEW public.vw_cylinders_at_suppliers AS
SELECT
    s.supplier_name,
    c.cylinder_serial,
    p.product_name,
    cs.cylinder_state                                   AS current_state,
    cpc.entered_at                                      AS dropped_at,
    st.dropoff_date                                        AS dropoff_trip_date,
    EXTRACT(DAY FROM now() - cpc.entered_at)::int       AS days_at_supplier,
    CASE
        WHEN EXTRACT(DAY FROM now() - cpc.entered_at) > 7  THEN 'OVERDUE'
        WHEN EXTRACT(DAY FROM now() - cpc.entered_at) > 3  THEN 'FOLLOW_UP'
        ELSE 'OK'
    END                                                 AS aging_flag
FROM   public.tbl_cylinder_party_custody    cpc
JOIN   public.tbl_cylinder                  c    ON c.pk_cylinder_id    = cpc.fk_cylinder
JOIN   public.tbl_product                   p    ON p.pk_product_id     = c.fk_product
JOIN   public.tbl_supplier                  s    ON s.pk_supplier_id    = cpc.fk_supplier
LEFT   JOIN public.tbl_supplier_trip        st   ON st.pk_supplier_trip_id
                                                        = cpc.fk_entry_supplier_trip
LEFT   JOIN public.tbl_cylinder_current_status ccs
           ON ccs.fk_cylinder = cpc.fk_cylinder
LEFT   JOIN public.tbl_cylinder_states      cs
           ON cs.pk_cylinder_state_id = ccs.fk_current_state
WHERE  cpc.custody_status = 'ACTIVE'
  AND  cpc.party_type     = 'SUPPLIER'
ORDER  BY days_at_supplier DESC, s.supplier_name, c.cylinder_serial;

COMMENT ON VIEW public.vw_cylinders_at_suppliers IS
    'Live view: every cylinder currently at a supplier awaiting refill. '
    'aging_flag = OVERDUE (>7 days), FOLLOW_UP (>3 days), OK.';


CREATE OR REPLACE VIEW public.vw_party_cylinder_dashboard AS
SELECT
    party_type,
    CASE party_type
        WHEN 'CUSTOMER' THEN cust.customer_name
        WHEN 'SUPPLIER' THEN s.supplier_name
    END                                                 AS party_name,
    CASE party_type
        WHEN 'CUSTOMER' THEN cpc.fk_customer::text
        WHEN 'SUPPLIER' THEN cpc.fk_supplier::text
    END                                                 AS party_id,
    COUNT(*)                                            AS cylinders_held,
    COUNT(*) FILTER (
        WHERE EXTRACT(DAY FROM now() - cpc.entered_at) > 14
          AND party_type = 'CUSTOMER'
    )                                                   AS overdue_at_customer,
    COUNT(*) FILTER (
        WHERE EXTRACT(DAY FROM now() - cpc.entered_at) > 3
          AND party_type = 'SUPPLIER'
    )                                                   AS overdue_at_supplier,
    MIN(cpc.entered_at)                                 AS oldest_cylinder_since,
    MAX(cpc.entered_at)                                 AS newest_cylinder_since
FROM   public.tbl_cylinder_party_custody    cpc
LEFT   JOIN public.tbl_customer             cust ON cust.pk_customer_id = cpc.fk_customer
LEFT   JOIN public.tbl_supplier             s    ON s.pk_supplier_id    = cpc.fk_supplier
WHERE  cpc.custody_status = 'ACTIVE'
GROUP  BY party_type, party_name, party_id
ORDER  BY party_type, cylinders_held DESC;

COMMENT ON VIEW public.vw_party_cylinder_dashboard IS
    'Per-party aggregate for the operations dashboard. '
    'Shows how many cylinders each customer and supplier currently holds.';


CREATE OR REPLACE VIEW public.vw_cylinder_party_history AS
SELECT
    c.cylinder_serial,
    p.product_name,
    cpc.party_type,
    CASE cpc.party_type
        WHEN 'CUSTOMER' THEN cust.customer_name
        WHEN 'SUPPLIER' THEN s.supplier_name
    END                                                 AS party_name,
    a.address_line_1                                    AS customer_location,
    cpc.entry_event_type,
    o.challan_number                                    AS entry_challan,
    st.dropoff_date                                        AS entry_trip_date,
    cpc.entered_at,
    cpc.exit_event_type,
    ep.pickup_number                                    AS exit_pickup_number,
    src.collection_number                               AS exit_collection_number,
    cpc.exited_at,
    cpc.custody_status,
    CASE
        WHEN cpc.exited_at IS NOT NULL
        THEN EXTRACT(DAY FROM cpc.exited_at - cpc.entered_at)::int
        ELSE EXTRACT(DAY FROM now()          - cpc.entered_at)::int
    END                                                 AS days_held,
    cpc.remarks
FROM   public.tbl_cylinder_party_custody            cpc
JOIN   public.tbl_cylinder                          c
       ON c.pk_cylinder_id      = cpc.fk_cylinder
JOIN   public.tbl_product                           p
       ON p.pk_product_id       = c.fk_product
LEFT   JOIN public.tbl_customer                     cust
       ON cust.pk_customer_id   = cpc.fk_customer
LEFT   JOIN public.tbl_customer_address             ca
       ON ca.pk_customer_address_id = cpc.fk_customer_address
LEFT   JOIN public.tbl_address                      a
       ON a.pk_address_id       = ca.fk_address
LEFT   JOIN public.tbl_supplier                     s
       ON s.pk_supplier_id      = cpc.fk_supplier
LEFT   JOIN public.tbl_order                        o
       ON o.pk_order_id         = cpc.fk_entry_order
LEFT   JOIN public.tbl_supplier_trip                st
       ON st.pk_supplier_trip_id = cpc.fk_entry_supplier_trip
LEFT   JOIN public.tbl_empty_pickup                 ep
       ON ep.pk_pickup_id       = cpc.fk_exit_empty_pickup
LEFT   JOIN public.tbl_supplier_refill_collection   src
       ON src.pk_collection_id  = cpc.fk_exit_supplier_refill_collection
ORDER  BY cpc.fk_cylinder, cpc.entered_at DESC;

COMMENT ON VIEW public.vw_cylinder_party_history IS
    'Full custody ledger for every cylinder — every customer visit and supplier '
    'dropoff. Filter by cylinder_serial for per-serial audit trail.';


-- =============================================================================
-- PART 1 — Extend tbl_yard_stock_check with audit context
-- =============================================================================
-- check_context tells the orchestrator WHEN in the business day this audit
-- was performed, so it can create the right checkpoint type and apply the
-- right expected count and escalation window.
--
-- check_context values:
--   MORNING   – after last trip departs; validates what is left in the yard
--               matches opening_yard_total − cylinders_loaded_on_all_trips.
--               Performed AFTER the vehicles leave; any discrepancy here
--               means the load manifest was wrong.
--   POST_TRIP – after a trip returns and unloads into the yard, BEFORE the
--               next trip loads. Validates the yard increased by exactly
--               the number of cylinders that came back on that trip.
--               fk_vehicle_trip identifies which return triggered this audit.
--   EOD       – after ALL trips have returned and unloaded for the day.
--               Gates the DAILY_CLOSING checkpoint. The system will refuse
--               to close the day until this audit is COMPLETED and MATCHED.
--   ADHOC     – unscheduled spot check; creates a YARD_AUDIT checkpoint but
--               does not block any workflow gate.
-- =============================================================================

ALTER TABLE public.tbl_yard_stock_check
    ADD COLUMN IF NOT EXISTS check_context varchar(30) NOT NULL DEFAULT 'ADHOC';

ALTER TABLE public.tbl_yard_stock_check
    ADD COLUMN IF NOT EXISTS fk_vehicle_trip int8 NULL;

ALTER TABLE public.tbl_yard_stock_check
    DROP CONSTRAINT IF EXISTS tbl_yard_stock_check_context_chk;
ALTER TABLE public.tbl_yard_stock_check
    ADD CONSTRAINT tbl_yard_stock_check_context_chk
    CHECK (check_context IN ('MORNING', 'POST_TRIP', 'EOD', 'ADHOC'));

ALTER TABLE public.tbl_yard_stock_check
    DROP CONSTRAINT IF EXISTS tbl_yard_stock_check_trip_fk;
ALTER TABLE public.tbl_yard_stock_check
    ADD CONSTRAINT tbl_yard_stock_check_trip_fk
    FOREIGN KEY (fk_vehicle_trip) REFERENCES public.tbl_vehicle_trip(pk_vehicle_trip_id);

-- POST_TRIP audits must reference a trip; MORNING and EOD must not
ALTER TABLE public.tbl_yard_stock_check
    DROP CONSTRAINT IF EXISTS tbl_yard_stock_check_trip_context_chk;
ALTER TABLE public.tbl_yard_stock_check
    ADD CONSTRAINT tbl_yard_stock_check_trip_context_chk
    CHECK (
        (check_context = 'POST_TRIP' AND fk_vehicle_trip IS NOT NULL)
        OR check_context <> 'POST_TRIP'
    );

COMMENT ON COLUMN public.tbl_yard_stock_check.check_context IS
    'When in the business day this audit was performed. '
    'MORNING = after vehicles depart, validates yard remainder. '
    'POST_TRIP = after a specific trip returns and unloads; fk_vehicle_trip is set. '
    'EOD = end of day, gates DAILY_CLOSING. '
    'ADHOC = unscheduled spot check.';

COMMENT ON COLUMN public.tbl_yard_stock_check.fk_vehicle_trip IS
    'Set only for POST_TRIP audits. Identifies which trip return triggered '
    'this audit. Used by the orchestrator to calculate expected yard increase.';


-- =============================================================================
-- PART 2 — Widen the checkpoint_type constraint to include the three new types
-- =============================================================================

ALTER TABLE public.tbl_reconciliation_checkpoint
    DROP CONSTRAINT IF EXISTS tbl_recon_checkpoint_type_chk;

ALTER TABLE public.tbl_reconciliation_checkpoint
    ADD CONSTRAINT tbl_recon_checkpoint_type_chk
    CHECK (checkpoint_type IN (
        -- Day boundaries
        'DAILY_OPENING',
        'DAILY_CLOSING',

        -- Trip lifecycle
        'TRIP_LOAD_CONFIRMED',
        'TRIP_DEPARTURE',
        'TRIP_STOP_DELIVERY',
        'TRIP_STOP_EMPTY_PICKUP',
        'TRIP_RETURN_SCAN',
        'TRIP_RETURN',
        'TRIP_CLOSURE',

        -- Yard audits — three distinct moments in the business day
        'YARD_AUDIT_MORNING',     -- after all morning trips depart
        'YARD_AUDIT_POST_TRIP',   -- after each individual trip return unloads
        'YARD_AUDIT_EOD',         -- end of day; gates DAILY_CLOSING
        'YARD_AUDIT',             -- legacy / ADHOC

        -- Supplier
        'SUPPLIER_DROPOFF',
        'SUPPLIER_COLLECTION',

        -- Corrections
        'CYLINDER_CORRECTION'
    ));

COMMENT ON CONSTRAINT tbl_recon_checkpoint_type_chk
    ON public.tbl_reconciliation_checkpoint IS
    'Valid checkpoint types. YARD_AUDIT_MORNING / YARD_AUDIT_POST_TRIP / '
    'YARD_AUDIT_EOD are the three structured yard checks per business day. '
    'YARD_AUDIT is retained for legacy ADHOC checks.';


-- =============================================================================
-- PART 3 — fn_yard_stock_check_checkpoint()
--           AFTER INSERT on tbl_yard_stock_check
--           Creates the correct YARD_AUDIT_* checkpoint based on check_context
-- =============================================================================
-- expected_count calculation per context:
--
--   MORNING:
--     expected yard cylinders = opening_yard_full + opening_yard_empty
--                               − SUM of cylinders on all TRIP_DEPARTURE
--                                 checkpoints created today that are still PENDING
--     Rationale: everything that left in the morning load should no longer
--     be in the yard. What remains should equal opening yard minus departures.
--
--   POST_TRIP:
--     expected yard cylinders = current system yard count
--     (fn_current_yard_count snapshot at the moment of audit creation)
--     The audit validates the physical count matches the system state
--     at the moment just after the trip unloaded. expected = system state.
--
--   EOD:
--     expected yard cylinders = closing_yard_full + closing_yard_empty
--     from tbl_daily_cylinder_count for today (if fn_close_daily_count
--     has been called) OR fn_current_yard_count() if not yet called.
--
--   ADHOC:
--     expected = fn_current_yard_count() — system state at audit time.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_yard_stock_check_checkpoint()
RETURNS TRIGGER AS $$
DECLARE
    v_checkpoint_type   varchar(50);
    v_expected_count    int4 := 0;
    v_escalation_hours  int4;
    v_remarks           varchar(500);
    v_daily_count_id    int8;
    v_opening_yard      int4;
    v_departed_today    int4;
    v_current_yard      int4;
BEGIN
    -- ── Map check_context → checkpoint_type and escalation window ────────────
    CASE NEW.check_context
        WHEN 'MORNING'   THEN
            v_checkpoint_type  := 'YARD_AUDIT_MORNING';
            v_escalation_hours := 2;   -- must complete within 2 hrs of vehicle departure

        WHEN 'POST_TRIP' THEN
            v_checkpoint_type  := 'YARD_AUDIT_POST_TRIP';
            v_escalation_hours := 1;   -- must complete within 1 hr of trip return

        WHEN 'EOD'       THEN
            v_checkpoint_type  := 'YARD_AUDIT_EOD';
            v_escalation_hours := 3;   -- must complete before midnight

        ELSE  -- ADHOC
            v_checkpoint_type  := 'YARD_AUDIT';
            v_escalation_hours := 24;
    END CASE;

    -- ── Calculate expected_count per context ─────────────────────────────────

    IF NEW.check_context = 'MORNING' THEN
        -- Expected = opening yard − cylinders that left on today's trips
        SELECT opening_yard_full + opening_yard_empty INTO v_opening_yard
          FROM public.tbl_daily_cylinder_count
         WHERE count_date = CURRENT_DATE;

        -- Count cylinders on PENDING TRIP_DEPARTURE checkpoints today
        -- (these are the cylinders physically on the vehicles)
        SELECT COALESCE(SUM(expected_count), 0) INTO v_departed_today
          FROM public.tbl_reconciliation_checkpoint
         WHERE checkpoint_type   = 'TRIP_DEPARTURE'
           AND checkpoint_date   = CURRENT_DATE
           AND checkpoint_status = 'PENDING';

        v_expected_count := COALESCE(v_opening_yard, 0) - v_departed_today;
        v_remarks := 'Morning yard audit. '
            || 'Opening yard: ' || COALESCE(v_opening_yard::text, '?')
            || '. Cylinders departed on trips: ' || v_departed_today
            || '. Expected in yard: ' || v_expected_count;

    ELSIF NEW.check_context = 'POST_TRIP' THEN
        -- Expected = current system yard count (snapshot at audit creation)
        -- The trip has already halted and its cylinders are back in the system.
        SELECT COUNT(*) INTO v_current_yard
          FROM public.tbl_cylinder_current_status ccs
          JOIN public.tbl_cylinder_states cs
               ON cs.pk_cylinder_state_id = ccs.fk_current_state
         WHERE cs.cylinder_state IN ('FULL', 'EMPTY');

        v_expected_count := v_current_yard;
        v_remarks := 'Post-trip yard audit after trip '
            || COALESCE(NEW.fk_vehicle_trip::text, '?')
            || ' returned and unloaded. '
            || 'System yard count at audit creation: ' || v_current_yard;

    ELSIF NEW.check_context = 'EOD' THEN
        -- Expected = closing yard from daily count (if closed) or system count
        SELECT pk_daily_count_id,
               COALESCE(closing_yard_full, 0) + COALESCE(closing_yard_empty, 0)
          INTO v_daily_count_id, v_current_yard
          FROM public.tbl_daily_cylinder_count
         WHERE count_date = CURRENT_DATE;

        -- If fn_close_daily_count() hasn't been called yet, fall back to system count
        IF v_current_yard = 0 THEN
            SELECT COUNT(*) INTO v_current_yard
              FROM public.tbl_cylinder_current_status ccs
              JOIN public.tbl_cylinder_states cs
                   ON cs.pk_cylinder_state_id = ccs.fk_current_state
             WHERE cs.cylinder_state IN ('FULL', 'EMPTY');
        END IF;

        v_expected_count := v_current_yard;
        v_remarks := 'EOD yard audit. '
            || 'Expected yard count (system): ' || v_current_yard
            || '. All vehicles should have returned and unloaded.';

    ELSE -- ADHOC
        SELECT COUNT(*) INTO v_current_yard
          FROM public.tbl_cylinder_current_status ccs
          JOIN public.tbl_cylinder_states cs
               ON cs.pk_cylinder_state_id = ccs.fk_current_state
         WHERE cs.cylinder_state IN ('FULL', 'EMPTY');

        v_expected_count := v_current_yard;
        v_remarks := 'Ad-hoc yard audit. System yard count: ' || v_current_yard;
    END IF;

    -- ── Create the checkpoint ─────────────────────────────────────────────────
    BEGIN
        PERFORM public.fn_create_checkpoint(
            v_checkpoint_type,
            'tbl_yard_stock_check',
            NEW.pk_stock_check_id,
            v_expected_count,
            v_escalation_hours,
            v_remarks,
            CURRENT_DATE,
            NEW.fk_vehicle_trip,  -- fk_vehicle_trip (NULL for MORNING/EOD/ADHOC)
            NULL,                 -- fk_vehicle_load
            NULL                  -- stop_sequence
        );
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'fn_yard_stock_check_checkpoint [%]: %',
            v_checkpoint_type, SQLERRM;
    END;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_yard_stock_check_checkpoint ON public.tbl_yard_stock_check;
CREATE TRIGGER trg_yard_stock_check_checkpoint
AFTER INSERT ON public.tbl_yard_stock_check
FOR EACH ROW EXECUTE FUNCTION public.fn_yard_stock_check_checkpoint();

COMMENT ON FUNCTION public.fn_yard_stock_check_checkpoint() IS
    'AFTER INSERT on tbl_yard_stock_check. Creates YARD_AUDIT_MORNING, '
    'YARD_AUDIT_POST_TRIP, YARD_AUDIT_EOD, or YARD_AUDIT checkpoint '
    'depending on check_context. expected_count is calculated from the '
    'daily count opening snapshot and active trip departures for MORNING, '
    'from the live system count for POST_TRIP, EOD, and ADHOC.';


-- =============================================================================
-- PART 4 — fn_yard_stock_check_completed()
--           AFTER UPDATE on tbl_yard_stock_check WHERE check_status → COMPLETED
--           Resolves the YARD_AUDIT_* checkpoint with the actual scanned count.
--           For EOD: also checks that all TRIP_DEPARTURE checkpoints are
--           resolved before allowing the EOD audit to close MATCHED.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_yard_stock_check_completed()
RETURNS TRIGGER AS $$
DECLARE
    v_checkpoint_type   varchar(50);
    v_actual_count      int4;
    v_pending_trips     int4;
    v_resolution_remarks varchar(500);
BEGIN
    -- Only fire when status changes TO COMPLETED
    IF NEW.check_status <> 'COMPLETED' OR OLD.check_status = 'COMPLETED' THEN
        RETURN NEW;
    END IF;

    -- Map context → checkpoint type (same logic as INSERT trigger)
    CASE NEW.check_context
        WHEN 'MORNING'   THEN v_checkpoint_type := 'YARD_AUDIT_MORNING';
        WHEN 'POST_TRIP' THEN v_checkpoint_type := 'YARD_AUDIT_POST_TRIP';
        WHEN 'EOD'       THEN v_checkpoint_type := 'YARD_AUDIT_EOD';
        ELSE                  v_checkpoint_type := 'YARD_AUDIT';
    END CASE;

    -- Actual count = number of cylinders scanned in this audit
SELECT COUNT(*) INTO v_actual_count
FROM public.tbl_yard_stock_check_line
WHERE fk_stock_check = NEW.pk_stock_check_id
  AND fk_cylinder IS NOT NULL;

    -- ── EOD special gate: refuse to mark MATCHED if any trip is still out ────
    IF NEW.check_context = 'EOD' THEN
        SELECT COUNT(*) INTO v_pending_trips
          FROM public.tbl_reconciliation_checkpoint
         WHERE checkpoint_type   = 'TRIP_DEPARTURE'
           AND checkpoint_date   = CURRENT_DATE
           AND checkpoint_status = 'PENDING';

        IF v_pending_trips > 0 THEN
            -- Mark the audit itself as blocked; do not resolve checkpoint yet
            UPDATE public.tbl_yard_stock_check
               SET remarks = COALESCE(remarks, '')
                          || ' [BLOCKED: ' || v_pending_trips
                          || ' trip(s) still PENDING — cannot close EOD audit until all vehicles return]'
             WHERE pk_stock_check_id = NEW.pk_stock_check_id;

            RAISE NOTICE
                'fn_yard_stock_check_completed [EOD]: % trip(s) still PENDING. '
                'EOD audit cannot be resolved until all TRIP_DEPARTURE '
                'checkpoints are MATCHED or VARIANCE.',
                v_pending_trips;

            RETURN NEW;  -- do NOT resolve the checkpoint — block the close
        END IF;
    END IF;

    v_resolution_remarks :=
        NEW.check_context || ' yard audit completed by ' || NEW.checked_by
        || '. Scanned: ' || v_actual_count
        || ' cylinders. Completed at: ' || now()::text;

    -- ── Resolve the checkpoint with actual scan count ─────────────────────────
    -- fn_resolve_checkpoint sets MATCHED if actual = expected, VARIANCE if not
    BEGIN
        PERFORM public.fn_resolve_checkpoint(
            'tbl_yard_stock_check',
            NEW.pk_stock_check_id,
            v_checkpoint_type,
            v_actual_count,
            v_resolution_remarks,
            NEW.fk_vehicle_trip   -- NULL for MORNING/EOD/ADHOC
        );
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'fn_yard_stock_check_completed [resolve %]: %',
            v_checkpoint_type, SQLERRM;
    END;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_yard_stock_check_completed ON public.tbl_yard_stock_check;
CREATE TRIGGER trg_yard_stock_check_completed
AFTER UPDATE OF check_status ON public.tbl_yard_stock_check
FOR EACH ROW EXECUTE FUNCTION public.fn_yard_stock_check_completed();

COMMENT ON FUNCTION public.fn_yard_stock_check_completed() IS
    'AFTER UPDATE on tbl_yard_stock_check (check_status → COMPLETED). '
    'Resolves the YARD_AUDIT_* checkpoint with actual scanned count. '
    'For EOD: blocks resolution if any TRIP_DEPARTURE is still PENDING — '
    'all vehicles must have returned before EOD can close MATCHED. '
    'MATCHED means physical count equals system state. '
    'VARIANCE means a cylinder is physically missing or extra.';


-- =============================================================================
-- PART 5 — Gate DAILY_CLOSING on YARD_AUDIT_EOD being MATCHED
-- =============================================================================
-- fn_close_daily_count() is called from the "Close Day" controller endpoint.
-- We add a guard function that the controller must call first, OR we add a
-- check inside fn_close_daily_count() itself.
-- Here we replace fn_close_daily_count() to include the gate.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_close_daily_count(
    p_date  date DEFAULT CURRENT_DATE
)
RETURNS void AS $$
DECLARE
    v_row                public.tbl_daily_cylinder_count%ROWTYPE;
    v_closing_fleet      int4;
    v_closing_yard_full  int4;
    v_closing_yard_empty int4;
    v_closing_in_transit int4;
    v_closing_at_customer int4;
    v_closing_at_supplier int4;
    v_expected_fleet     int4;
    v_variance           int4;
    v_eod_audit_status   varchar(30);
    v_pending_trips      int4;
BEGIN
    SELECT * INTO v_row
      FROM public.tbl_daily_cylinder_count
     WHERE count_date = p_date;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No daily count row found for date %.', p_date;
    END IF;

    IF v_row.day_status NOT IN ('OPEN', 'PENDING_AUDIT') THEN
        RAISE EXCEPTION 'Day % is already in status %. Cannot close.', p_date, v_row.day_status;
    END IF;

    -- ── Gate 1: all TRIP_DEPARTURE checkpoints must be resolved ──────────────
    SELECT COUNT(*) INTO v_pending_trips
      FROM public.tbl_reconciliation_checkpoint
     WHERE checkpoint_type   = 'TRIP_DEPARTURE'
       AND checkpoint_date   = p_date
       AND checkpoint_status = 'PENDING';

    IF v_pending_trips > 0 THEN
        RAISE EXCEPTION
            'Cannot close day %: % vehicle trip(s) have not yet returned. '
            'Resolve all TRIP_DEPARTURE checkpoints (trip status → Halt) '
            'before closing the day.',
            p_date, v_pending_trips;
    END IF;

    -- ── Gate 2: EOD yard audit must exist and be MATCHED ─────────────────────
    SELECT cp.checkpoint_status INTO v_eod_audit_status
      FROM public.tbl_reconciliation_checkpoint cp
     WHERE cp.checkpoint_type  = 'YARD_AUDIT_EOD'
       AND cp.checkpoint_date  = p_date
     ORDER BY cp.pk_checkpoint_id DESC
     LIMIT 1;

    IF v_eod_audit_status IS NULL THEN
        RAISE EXCEPTION
            'Cannot close day %: no EOD yard audit has been created. '
            'Create a yard stock check with check_context = ''EOD'' and complete it '
            'before closing the day.',
            p_date;
    END IF;

    IF v_eod_audit_status <> 'MATCHED' THEN
        RAISE EXCEPTION
            'Cannot close day %: the EOD yard audit is in status %. '
            'The physical yard count must match the system count (MATCHED) '
            'before the day can be closed. Investigate any VARIANCE first.',
            p_date, v_eod_audit_status;
    END IF;

    -- ── Take closing snapshot ─────────────────────────────────────────────────
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

    v_expected_fleet := v_row.opening_fleet_total
                        + v_row.cylinders_commissioned
                        - v_row.cylinders_decommissioned;

    v_variance := v_closing_fleet - v_expected_fleet;

    UPDATE public.tbl_daily_cylinder_count
       SET closing_fleet_total          = v_closing_fleet,
           closing_yard_full            = v_closing_yard_full,
           closing_yard_empty           = v_closing_yard_empty,
           closing_in_transit           = v_closing_in_transit,
           closing_at_customer          = v_closing_at_customer,
           closing_at_supplier          = v_closing_at_supplier,
           snapshot_closed_at           = now(),
           expected_closing_fleet_total = v_expected_fleet,
           variance_count               = v_variance,
           day_status                   = CASE WHEN v_variance = 0
                                              THEN 'RECONCILED'
                                              ELSE 'VARIANCE'
                                          END
     WHERE count_date = p_date;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_close_daily_count(date) IS
    'Closes the business day. Two hard gates must pass before the snapshot '
    'is taken: (1) all TRIP_DEPARTURE checkpoints must be MATCHED or VARIANCE '
    '(no vehicles still out); (2) YARD_AUDIT_EOD must exist and be MATCHED. '
    'If either gate fails, the function raises an exception and the Close Day '
    'button should display the specific failure reason to the office staff.';


-- =============================================================================
-- PART 6 — Updated vw_daily_reconciliation_health
--           Adds EOD audit status and the two new yard audit types
-- =============================================================================

DROP VIEW IF EXISTS public.vw_daily_reconciliation_health;

CREATE OR REPLACE VIEW public.vw_daily_reconciliation_health AS
SELECT
    dcc.count_date,
    dcc.day_status,
    dcc.opening_fleet_total,
    dcc.opening_yard_full,
    dcc.opening_yard_empty,
    dcc.opening_at_customer,
    dcc.opening_at_supplier,
    dcc.cylinders_delivered_out,
    dcc.cylinders_empty_collected_in,
    dcc.cylinders_sent_to_supplier,
    dcc.cylinders_received_from_supplier,
    dcc.closing_fleet_total,
    dcc.variance_count,

    -- ── Checkpoint health ────────────────────────────────────────────────────
    COUNT(DISTINCT rc.pk_checkpoint_id)
        FILTER (WHERE rc.checkpoint_type = 'TRIP_DEPARTURE'
                  AND rc.checkpoint_status = 'PENDING')         AS trips_still_out,

    COUNT(DISTINCT rc.pk_checkpoint_id)
        FILTER (WHERE rc.checkpoint_type = 'TRIP_DEPARTURE'
                  AND rc.checkpoint_status = 'MATCHED')         AS trips_returned_clean,

    COUNT(DISTINCT rc.pk_checkpoint_id)
        FILTER (WHERE rc.checkpoint_type = 'TRIP_DEPARTURE'
                  AND rc.checkpoint_status = 'VARIANCE')        AS trips_with_variance,

    -- ── Yard audit status for this day ───────────────────────────────────────
    MAX(rc.checkpoint_status)
        FILTER (WHERE rc.checkpoint_type = 'YARD_AUDIT_MORNING')AS morning_audit_status,

    COUNT(DISTINCT rc.pk_checkpoint_id)
        FILTER (WHERE rc.checkpoint_type = 'YARD_AUDIT_POST_TRIP'
                  AND rc.checkpoint_status = 'MATCHED')         AS post_trip_audits_clean,

    COUNT(DISTINCT rc.pk_checkpoint_id)
        FILTER (WHERE rc.checkpoint_type = 'YARD_AUDIT_POST_TRIP'
                  AND rc.checkpoint_status = 'VARIANCE')        AS post_trip_audits_variance,

    MAX(rc.checkpoint_status)
        FILTER (WHERE rc.checkpoint_type = 'YARD_AUDIT_EOD')    AS eod_audit_status,

    -- ── Gate readiness ───────────────────────────────────────────────────────
    -- Can the Close Day button be enabled?
    CASE
        WHEN COUNT(rc.pk_checkpoint_id)
             FILTER (WHERE rc.checkpoint_type = 'TRIP_DEPARTURE'
                       AND rc.checkpoint_status = 'PENDING') > 0
        THEN 'BLOCKED: vehicles still out'
        WHEN MAX(rc.checkpoint_status)
             FILTER (WHERE rc.checkpoint_type = 'YARD_AUDIT_EOD') IS NULL
        THEN 'BLOCKED: EOD audit not started'
        WHEN MAX(rc.checkpoint_status)
             FILTER (WHERE rc.checkpoint_type = 'YARD_AUDIT_EOD') <> 'MATCHED'
        THEN 'BLOCKED: EOD audit not MATCHED'
        ELSE 'READY'
    END                                                         AS close_day_gate,

    -- Corrections waiting for supervisor sign-off
    COUNT(DISTINCT rc.pk_checkpoint_id)
        FILTER (WHERE rc.checkpoint_type   = 'CYLINDER_CORRECTION'
                  AND rc.checkpoint_status = 'PENDING')         AS corrections_pending_ack,

    MAX(CASE WHEN rc.checkpoint_type = 'DAILY_CLOSING'
             THEN rc.checkpoint_status END)                     AS day_close_status

FROM   public.tbl_daily_cylinder_count dcc
LEFT   JOIN public.tbl_reconciliation_checkpoint rc
           ON rc.checkpoint_date = dcc.count_date
GROUP  BY dcc.count_date, dcc.day_status, dcc.opening_fleet_total,
          dcc.opening_yard_full, dcc.opening_yard_empty,
          dcc.opening_at_customer, dcc.opening_at_supplier,
          dcc.cylinders_delivered_out, dcc.cylinders_empty_collected_in,
          dcc.cylinders_sent_to_supplier, dcc.cylinders_received_from_supplier,
          dcc.closing_fleet_total, dcc.variance_count
ORDER  BY dcc.count_date DESC;

COMMENT ON VIEW public.vw_daily_reconciliation_health IS
    'One row per business day. Shows trip gate status, yard audit status, '
    'and the close_day_gate column which the UI uses to enable/disable the '
    'Close Day button. READY means all gates have passed.';