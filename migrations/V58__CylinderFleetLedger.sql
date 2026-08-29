-- =============================================================================
-- V58__CylinderFleetLedger.sql
-- =============================================================================
-- PURPOSE:
--   Establish a single-source-of-truth for the TOTAL cylinder fleet count.
--
-- PROBLEM STATEMENT:
--   Currently there is no table that answers "how many cylinders does the
--   business own right now?".  COUNT(*) on tbl_cylinder includes DECOMMISSIONED
--   and LOST cylinders.  There is no event trail for fleet additions/removals.
--
-- DESIGN:
--   tbl_cylinder_fleet_ledger — one row per event that changes the fleet size.
--   Events:  COMMISSIONED (fleet grows) | DECOMMISSIONED | LOST_CONFIRMED (fleet shrinks).
--   The running total is maintained as a computed column so any single row tells
--   you the fleet size at that point in time without summing the whole table.
--
--   A trigger on tbl_cylinder INSERT fires automatically for COMMISSIONED events.
--   State-transition triggers (via tbl_cylinder_state_audit) handle the shrink side.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- SEQUENCE
-- ---------------------------------------------------------------------------
DROP SEQUENCE IF EXISTS public.pk_cylinder_fleet_ledger_id_serial;
CREATE SEQUENCE public.pk_cylinder_fleet_ledger_id_serial
    INCREMENT BY 1 MINVALUE 1 START 1 CACHE 1 NO CYCLE;

-- ---------------------------------------------------------------------------
-- TABLE
-- ---------------------------------------------------------------------------
CREATE TABLE public.tbl_cylinder_fleet_ledger (
    pk_ledger_id        int8        NOT NULL DEFAULT nextval('public.pk_cylinder_fleet_ledger_id_serial'),

    -- The cylinder that caused this fleet change
    fk_cylinder         int8        NOT NULL,

    -- What happened:
    --   COMMISSIONED       – new cylinder entered the fleet
    --   DECOMMISSIONED     – cylinder permanently taken out of service
    --   LOST_CONFIRMED     – cylinder officially written off as lost
    event_type          varchar(50) NOT NULL,

    -- Running total BEFORE this event
    fleet_count_before  int4        NOT NULL,

    -- Running total AFTER this event (= before + delta)
    fleet_count_after   int4        NOT NULL,

    -- +1 for COMMISSIONED, -1 for DECOMMISSIONED / LOST_CONFIRMED
    delta               int2        NOT NULL,

    event_at            timestamp   NOT NULL DEFAULT now(),
    remarks             varchar(500),

    CONSTRAINT tbl_fleet_ledger_pk
        PRIMARY KEY (pk_ledger_id),

    CONSTRAINT tbl_fleet_ledger_cylinder_fk
        FOREIGN KEY (fk_cylinder) REFERENCES public.tbl_cylinder(pk_cylinder_id),

    CONSTRAINT tbl_fleet_ledger_event_type_chk
        CHECK (event_type IN ('COMMISSIONED', 'DECOMMISSIONED', 'LOST_CONFIRMED')),

    CONSTRAINT tbl_fleet_ledger_delta_chk
        CHECK (delta IN (1, -1)),

    -- Invariant: after = before + delta
    CONSTRAINT tbl_fleet_ledger_count_chk
        CHECK (fleet_count_after = fleet_count_before + delta),

    -- Fleet size can never go negative
    CONSTRAINT tbl_fleet_ledger_positive_chk
        CHECK (fleet_count_after >= 0)
);

CREATE INDEX idx_fleet_ledger_cylinder   ON public.tbl_cylinder_fleet_ledger(fk_cylinder);
CREATE INDEX idx_fleet_ledger_event_type ON public.tbl_cylinder_fleet_ledger(event_type);
CREATE INDEX idx_fleet_ledger_event_at   ON public.tbl_cylinder_fleet_ledger(event_at DESC);

COMMENT ON TABLE public.tbl_cylinder_fleet_ledger IS
    'Append-only ledger of every event that changes the total cylinder fleet size. '
    'fleet_count_after on the most recent row = current owned fleet size. '
    'Triggers maintain this automatically on cylinder INSERT and on '
    'DECOMMISSIONED/LOST_CONFIRMED state transitions.';

-- ---------------------------------------------------------------------------
-- HELPER FUNCTION: current fleet count (reads the latest ledger row)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_current_fleet_count()
RETURNS int4 AS $$
    SELECT COALESCE(
        (SELECT fleet_count_after
         FROM public.tbl_cylinder_fleet_ledger
         ORDER BY pk_ledger_id DESC
         LIMIT 1),
        0
    );
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION public.fn_current_fleet_count() IS
    'Returns the current total fleet count from the latest ledger row. '
    'O(1) lookup — no aggregate scan needed.';

-- ---------------------------------------------------------------------------
-- TRIGGER: COMMISSIONED — fires when a new cylinder is inserted
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_fleet_ledger_on_cylinder_insert()
RETURNS TRIGGER AS $$
DECLARE
    v_before int4;
BEGIN
    v_before := public.fn_current_fleet_count();

    INSERT INTO public.tbl_cylinder_fleet_ledger (
        fk_cylinder, event_type, fleet_count_before, fleet_count_after, delta, remarks
    ) VALUES (
        NEW.pk_cylinder_id,
        'COMMISSIONED',
        v_before,
        v_before + 1,
        1,
        'Cylinder commissioned: serial=' || NEW.cylinder_serial
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_fleet_ledger_on_cylinder_insert
AFTER INSERT ON public.tbl_cylinder
FOR EACH ROW
EXECUTE FUNCTION public.fn_fleet_ledger_on_cylinder_insert();

-- ---------------------------------------------------------------------------
-- TRIGGER: DECOMMISSIONED / LOST_CONFIRMED — fires on state_audit INSERT
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_fleet_ledger_on_state_audit()
RETURNS TRIGGER AS $$
DECLARE
    v_new_state_name varchar(100);
    v_event_type     varchar(50);
    v_before         int4;
BEGIN
    SELECT cylinder_state INTO v_new_state_name
    FROM public.tbl_cylinder_states
    WHERE pk_cylinder_state_id = NEW.fk_new_state;

    -- Only act on fleet-shrinking states
    IF v_new_state_name = 'DECOMISSIONED' THEN
        v_event_type := 'DECOMMISSIONED';
    ELSIF v_new_state_name = 'LOST' THEN
        v_event_type := 'LOST_CONFIRMED';
    ELSE
        RETURN NEW;  -- not a fleet-change event
    END IF;

    v_before := public.fn_current_fleet_count();

    INSERT INTO public.tbl_cylinder_fleet_ledger (
        fk_cylinder, event_type, fleet_count_before, fleet_count_after, delta, remarks
    ) VALUES (
        NEW.fk_cylinder,
        v_event_type,
        v_before,
        v_before - 1,
        -1,
        COALESCE(NEW.remarks, 'State transition to ' || v_new_state_name)
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_fleet_ledger_on_state_audit
AFTER INSERT ON public.tbl_cylinder_state_audit
FOR EACH ROW
EXECUTE FUNCTION public.fn_fleet_ledger_on_state_audit();

-- ---------------------------------------------------------------------------
-- VIEW: current fleet breakdown (use alongside tbl_cylinder_current_status)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.vw_cylinder_fleet_summary AS
SELECT
    public.fn_current_fleet_count()                                    AS total_fleet,
    COUNT(*) FILTER (WHERE cs.location = 'Yard')                       AS at_yard,
    COUNT(*) FILTER (WHERE cs.location = 'Customer Location')          AS at_customer,
    COUNT(*) FILTER (WHERE cs.location = 'In Transit')                 AS in_transit,
    COUNT(*) FILTER (WHERE cs.location = 'Supplier Location')          AS at_supplier,
    COUNT(*) FILTER (WHERE cs.location = 'SCRAP')                      AS scrapped,
    COUNT(*) FILTER (WHERE cs.location = 'Unknown')                    AS missing,
    -- Reconciliation invariant: total = at_yard + at_customer + in_transit + at_supplier
    (COUNT(*) FILTER (WHERE cs.location = 'Yard')
     + COUNT(*) FILTER (WHERE cs.location = 'Customer Location')
     + COUNT(*) FILTER (WHERE cs.location = 'In Transit')
     + COUNT(*) FILTER (WHERE cs.location = 'Supplier Location'))      AS accounted_for,
    public.fn_current_fleet_count()
    - (COUNT(*) FILTER (WHERE cs.location = 'Yard')
       + COUNT(*) FILTER (WHERE cs.location = 'Customer Location')
       + COUNT(*) FILTER (WHERE cs.location = 'In Transit')
       + COUNT(*) FILTER (WHERE cs.location = 'Supplier Location'))    AS unaccounted_variance
FROM public.tbl_cylinder_current_status ccs
JOIN public.tbl_cylinder_states cs ON cs.pk_cylinder_state_id = ccs.fk_current_state;

COMMENT ON VIEW public.vw_cylinder_fleet_summary IS
    'One-row snapshot of current fleet distribution. '
    'unaccounted_variance MUST always be 0. Non-zero means a reconciliation gap.';
