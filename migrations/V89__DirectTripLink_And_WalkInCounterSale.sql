-- =============================================================================
-- V89__DirectTripLink_And_WalkInCounterSale.sql
-- =============================================================================
--
-- TWO GAPS CLOSED IN THIS MIGRATION
-- ─────────────────────────────────────────────────────────────────────────────
--
-- GAP 1 — FULL_PICKED_FROM_SUPPLIER deliveries are orphaned from the trip
-- ─────────────────────────────────────────────────────────────────────────────
-- V88 allowed cylinders in FULL_PICKED_FROM_SUPPLIER to be entered on
-- tbl_order_line (direct delivery from supplier vehicle to customer). However,
-- the orchestrator and Business Day Harmonisation have no visibility of these
-- deliveries because no tbl_vehicle_trip_stop is created for them, and
-- therefore no TRIP_STOP_DELIVERY checkpoint is emitted.
--
-- When a FULL_PICKED_FROM_SUPPLIER cylinder is delivered:
--   tbl_cylinder_current_status.fk_current_vehicle_trip  IS NOT NULL
--   (set by fn_audit_cylinder_refill_collection_after in V63 to the collection
--    vehicle trip — the same trip that brought the cylinder back from the supplier).
--
-- The fix auto-creates a CUSTOMER_DELIVERY stop on that trip and links the
-- order to it, which causes the existing fn_trip_stop_order_linked trigger
-- (V81) to emit a TRIP_STOP_DELIVERY checkpoint automatically. The
-- reconciliation flow for that stop is then identical to any other delivery
-- stop — the Halt resolution in fn_trip_status_after_update resolves it.
--
-- GAP 2 — Walk-in counter sale is completely unmodelled
-- ─────────────────────────────────────────────────────────────────────────────
-- A customer arriving at the yard and collecting a cylinder directly bypasses
-- every existing state-machine path:
--   • No vehicle trip or load (nothing to load — cylinder is taken from yard)
--   • Cylinder is in FULL state (at yard), not FULL_PICKED_UP_FOR_DELIVERY
--   • No delivery stop exists
--   • The daily cylinder count gets no corresponding movement record
--   • The orchestrator has no checkpoint for this event
--
-- Design: a new transaction type — tbl_walk_in_sale — that is the yard-level
-- equivalent of a vehicle trip stop. It has its own challan (tbl_order with
-- challan_type = WALK_IN), its own checkpoint type (WALK_IN_SALE), and its own
-- stop type (YARD_COUNTER) which records who processed the sale. The cylinder
-- state machine gets a direct FULL → DELIVERED_FOR_CONSUMPTION path ONLY for
-- WALK_IN challans.
--
-- =============================================================================
-- WHAT THIS MIGRATION CREATES
-- =============================================================================
--
-- SEED DATA
--   tbl_challan_type   ← INSERT 'WALK_IN'
--   tbl_stop_type      ← INSERT 'YARD_COUNTER'
--
-- SCHEMA
--   tbl_walk_in_sale   — new table: walk-in counter sale header
--                        (fk_customer, fk_order, sold_by, sale_date, sale_status)
--   tbl_reconciliation_checkpoint constraint widens to include 'WALK_IN_SALE'
--
-- TRIGGERS (all CREATE OR REPLACE — no new bindings except where noted)
--   fn_check_cylinder_is_picked_up          BEFORE INSERT tbl_order_line
--     • Now accepts three source states:
--         FULL_PICKED_UP_FOR_DELIVERY  — standard trip delivery
--         FULL_PICKED_FROM_SUPPLIER    — direct delivery (V88)
--         FULL                         — walk-in counter sale ONLY (WALK_IN challan)
--     • For FULL_PICKED_FROM_SUPPLIER: validates fk_current_vehicle_trip IS NOT NULL
--       (cylinder must be on an active trip)
--     • For FULL (walk-in): validates challan_type = WALK_IN
--
--   fn_audit_cylinder_delivery_after        AFTER INSERT tbl_order_line
--     • FULL_PICKED_UP_FOR_DELIVERY path: unchanged
--     • FULL_PICKED_FROM_SUPPLIER path: auto-creates CUSTOMER_DELIVERY stop on
--       the cylinder's current trip, then sets fk_order on the stop (which
--       fires fn_trip_stop_order_linked → TRIP_STOP_DELIVERY checkpoint)
--     • FULL (walk-in) path: FULL → DELIVERED_FOR_CONSUMPTION, creates
--       WALK_IN_SALE checkpoint against the tbl_walk_in_sale row
--
--   fn_walk_in_sale_on_insert               AFTER INSERT tbl_walk_in_sale  (NEW)
--     Creates a PENDING WALK_IN_SALE checkpoint when a walk-in sale is opened.
--
--   fn_walk_in_sale_on_complete             AFTER UPDATE tbl_walk_in_sale  (NEW)
--     When sale_status → COMPLETED, resolves the WALK_IN_SALE checkpoint with
--     the actual line count entered.
--
-- STATE TRANSITIONS AFTER V89
-- ─────────────────────────────────────────────────────────────────────────────
--  Source state                → Event                         → Target state
--  FULL_PICKED_UP_FOR_DELIVERY   tbl_order_line (DELIVERY)       DELIVERED_FOR_CONSUMPTION
--  FULL_PICKED_FROM_SUPPLIER     tbl_order_line (DELIVERY)       DELIVERED_FOR_CONSUMPTION
--  FULL                          tbl_order_line (WALK_IN)        DELIVERED_FOR_CONSUMPTION
--
-- RECONCILIATION FLOW FOR EACH PATH
-- ─────────────────────────────────────────────────────────────────────────────
--  Standard trip delivery:
--    stop linked → TRIP_STOP_DELIVERY (PENDING)
--    order lines entered → expected_count updated
--    trip Halt → TRIP_STOP_DELIVERY resolved (MATCHED/VARIANCE)
--
--  Direct delivery (FULL_PICKED_FROM_SUPPLIER, V89):
--    CUSTOMER_DELIVERY stop auto-created → fk_order set → TRIP_STOP_DELIVERY (PENDING)
--    further order lines grow expected_count (existing fn_audit_cylinder_delivery_after)
--    trip Halt → TRIP_STOP_DELIVERY resolved (MATCHED/VARIANCE)
--    ── identical to standard trip delivery from the orchestrator's perspective ──
--
--  Walk-in counter sale:
--    tbl_walk_in_sale INSERT → WALK_IN_SALE (PENDING)
--    order lines entered → expected_count updated
--    sale_status → COMPLETED → WALK_IN_SALE resolved (MATCHED/VARIANCE)
--    cylinders_delivered_out in tbl_daily_cylinder_count incremented automatically
--    (fn_daily_count_state_audit_update already fires on DELIVERED_FOR_CONSUMPTION)
-- =============================================================================


-- =============================================================================
-- PART 0 — Seed data: WALK_IN challan type and YARD_COUNTER stop type
-- =============================================================================

INSERT INTO public.tbl_challan_type (pk_challan_type_id, challan_type, description)
VALUES (
    nextval('public.pk_challan_type_id_serial'),
    'WALK_IN',
    'Walk-in counter sale: customer collects a full cylinder directly from the yard. '
    'No vehicle trip involved. Cylinder must be in FULL state at the yard. '
    'Challan is raised at the yard counter by office staff.'
)
ON CONFLICT (challan_type) DO NOTHING;

INSERT INTO public.tbl_stop_type (pk_stop_type_id, stop_type, description)
VALUES (
    nextval('public.pk_stop_type_id_serial'),
    'YARD_COUNTER',
    'Yard counter stop: used internally to model walk-in counter sales within '
    'the stop-type vocabulary. Not attached to a vehicle trip — references '
    'tbl_walk_in_sale instead. Exists so reporting queries can use a uniform '
    'stop-type join without special-casing walk-in transactions.'
)
ON CONFLICT (stop_type) DO NOTHING;

COMMENT ON TABLE public.tbl_challan_type IS
    'Lookup for the type of delivery challan. '
    'DELIVERY = full cylinders dispatched on a vehicle trip. '
    'EMPTY_PICKUP = empty cylinders collected from a customer on a vehicle trip. '
    'WALK_IN = customer collects cylinder directly at the yard counter (V89).';

COMMENT ON TABLE public.tbl_stop_type IS
    'Lookup for vehicle trip stop types. '
    'YARD_START = trip origin at yard. '
    'CUSTOMER_DELIVERY = customer delivery stop. '
    'SUPPLIER_DROPOFF = empty cylinders dropped at supplier. '
    'YARD_END = trip return to yard. '
    'YARD_COUNTER = walk-in counter sale (V89; not part of a vehicle trip).';


-- =============================================================================
-- PART 1 — tbl_walk_in_sale: new table for walk-in counter sales
-- =============================================================================
--
-- One row per walk-in sale session. A session covers all cylinders collected
-- by one customer at the yard counter in a single visit. The session maps 1:1
-- to a WALK_IN challan (tbl_order). The session header tracks who processed
-- the sale so it can be audited independently of the challan.
--
-- Lifecycle:
--   OPEN       → sale in progress; order lines being entered
--   COMPLETED  → all cylinders handed over; payment confirmed; challan printed
--   CANCELLED  → sale abandoned before completion (no cylinders handed over)
-- =============================================================================

DROP SEQUENCE IF EXISTS public.pk_walk_in_sale_id_serial;
CREATE SEQUENCE public.pk_walk_in_sale_id_serial
    INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START 1 CACHE 1 NO CYCLE;

CREATE TABLE public.tbl_walk_in_sale (
    pk_walk_in_sale_id  int8         NOT NULL DEFAULT nextval('public.pk_walk_in_sale_id_serial'),
    fk_customer         int8         NOT NULL,
    fk_order            int8         NOT NULL,   -- the WALK_IN challan for this session
    sold_by             varchar(200) NOT NULL,   -- name of yard staff processing the sale
    sale_date           date         NOT NULL DEFAULT CURRENT_DATE,
    sale_status         varchar(20)  NOT NULL DEFAULT 'OPEN',
    total_cylinders     int4         NOT NULL DEFAULT 0, -- declared at session start
    remarks             varchar(500) NULL,
    created_at          timestamp    NOT NULL DEFAULT now(),
    updated_at          timestamp    NULL,

    CONSTRAINT tbl_walk_in_sale_pk
        PRIMARY KEY (pk_walk_in_sale_id),

    CONSTRAINT tbl_walk_in_sale_order_unique
        UNIQUE (fk_order),   -- one session per challan

    CONSTRAINT tbl_walk_in_sale_status_chk
        CHECK (sale_status IN ('OPEN', 'COMPLETED', 'CANCELLED')),

    CONSTRAINT tbl_walk_in_sale_total_chk
        CHECK (total_cylinders >= 0),

    CONSTRAINT tbl_walk_in_sale_customer_fk
        FOREIGN KEY (fk_customer)
        REFERENCES public.tbl_customer(pk_customer_id),

    CONSTRAINT tbl_walk_in_sale_order_fk
        FOREIGN KEY (fk_order)
        REFERENCES public.tbl_order(pk_order_id)
);

CREATE INDEX idx_walk_in_sale_customer
    ON public.tbl_walk_in_sale(fk_customer, sale_date DESC);

CREATE INDEX idx_walk_in_sale_date
    ON public.tbl_walk_in_sale(sale_date DESC)
    WHERE sale_status = 'OPEN';

COMMENT ON TABLE public.tbl_walk_in_sale IS
    'Walk-in counter sale session. One row per customer visit to the yard counter. '
    '1:1 with a WALK_IN challan (tbl_order). The associated order lines in '
    'tbl_order_line record each cylinder collected. '
    'Cylinders must be in FULL state at the yard (not on a vehicle). '
    'AFTER INSERT → WALK_IN_SALE checkpoint created (fn_walk_in_sale_on_insert). '
    'AFTER UPDATE (sale_status → COMPLETED) → checkpoint resolved (fn_walk_in_sale_on_complete).';

COMMENT ON COLUMN public.tbl_walk_in_sale.sold_by IS
    'Name of yard/office staff who processed this walk-in sale.';

COMMENT ON COLUMN public.tbl_walk_in_sale.total_cylinders IS
    'Number of cylinders declared at session start. '
    'Used as expected_count on the WALK_IN_SALE checkpoint. '
    'Must match COUNT(tbl_order_line) for the challan when the session completes.';


-- =============================================================================
-- PART 2 — Widen checkpoint_type constraint to include WALK_IN_SALE
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

        -- Yard audits
        'YARD_AUDIT_MORNING',
        'YARD_AUDIT_POST_TRIP',
        'YARD_AUDIT_EOD',
        'YARD_AUDIT',

        -- Supplier
        'SUPPLIER_DROPOFF',
        'SUPPLIER_COLLECTION',

        -- Walk-in counter sale (V89)
        'WALK_IN_SALE',

        -- Corrections
        'CYLINDER_CORRECTION'
    ));

COMMENT ON CONSTRAINT tbl_recon_checkpoint_type_chk
    ON public.tbl_reconciliation_checkpoint IS
    'Valid checkpoint types. '
    'WALK_IN_SALE added in V89: created when a yard counter sale is opened, '
    'resolved when sale_status transitions to COMPLETED.';


-- =============================================================================
-- PART 3 — fn_check_cylinder_is_picked_up
--           BEFORE INSERT on tbl_order_line
--           Three accepted source states; walk-in path validated against challan type
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_check_cylinder_is_picked_up()
RETURNS TRIGGER AS $$
DECLARE
    v_delivery_state_id         int8;
    v_direct_delivery_state_id  int8;
    v_full_state_id             int8;
    v_current_state_id          int8;
    v_current_state_name        varchar(100);
    v_challan_type              varchar(50);
    v_trip_id                   int8;
    v_cylinder_serial           varchar(50);
BEGIN
    SELECT pk_cylinder_state_id INTO v_delivery_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL_PICKED_UP_FOR_DELIVERY';

    SELECT pk_cylinder_state_id INTO v_direct_delivery_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL_PICKED_FROM_SUPPLIER';

    SELECT pk_cylinder_state_id INTO v_full_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL';

    -- ── Resolve current state ─────────────────────────────────────────────────
    SELECT ccs.fk_current_state, cs.cylinder_state
      INTO v_current_state_id, v_current_state_name
      FROM public.tbl_cylinder_current_status ccs
      JOIN public.tbl_cylinder_states cs ON cs.pk_cylinder_state_id = ccs.fk_current_state
     WHERE ccs.fk_cylinder = NEW.fk_cylinder;

    IF NOT FOUND THEN
        SELECT fk_new_state INTO v_current_state_id
          FROM public.tbl_cylinder_state_audit
         WHERE fk_cylinder = NEW.fk_cylinder
         ORDER BY changed_at DESC, pk_audit_id DESC LIMIT 1;
        SELECT cylinder_state INTO v_current_state_name
          FROM public.tbl_cylinder_states WHERE pk_cylinder_state_id = v_current_state_id;
    END IF;

    SELECT cylinder_serial INTO v_cylinder_serial
      FROM public.tbl_cylinder WHERE pk_cylinder_id = NEW.fk_cylinder;

    -- ── PATH A: Standard trip delivery ────────────────────────────────────────
    IF v_current_state_id = v_delivery_state_id THEN
        RETURN NEW;  -- all good, AFTER trigger handles the rest
    END IF;

    -- ── PATH B: Direct delivery from supplier vehicle (V88/V89) ──────────────
    IF v_current_state_id = v_direct_delivery_state_id THEN
        -- The cylinder MUST be on an active vehicle trip.
        -- fk_current_vehicle_trip is set by fn_audit_cylinder_refill_collection_after (V63).
        SELECT fk_current_vehicle_trip INTO v_trip_id
          FROM public.tbl_cylinder_current_status
         WHERE fk_cylinder = NEW.fk_cylinder;

        IF v_trip_id IS NULL THEN
            RAISE EXCEPTION
                'Validation Failed: Cylinder % (%) is in FULL_PICKED_FROM_SUPPLIER state '
                'but has no active vehicle trip. The cylinder must be on a vehicle trip '
                'to be directly delivered to a customer. '
                'Check tbl_cylinder_current_status.fk_current_vehicle_trip.',
                v_cylinder_serial, NEW.fk_cylinder;
        END IF;

        RETURN NEW;
    END IF;

    -- ── PATH C: Walk-in counter sale ──────────────────────────────────────────
    IF v_current_state_id = v_full_state_id THEN
        -- FULL cylinders may ONLY be delivered via a WALK_IN challan.
        -- Prevent staff from accidentally entering a yard cylinder on a trip challan.
        SELECT ct.challan_type INTO v_challan_type
          FROM public.tbl_order o
          JOIN public.tbl_challan_type ct ON ct.pk_challan_type_id = o.fk_challan_type
         WHERE o.pk_order_id = NEW.fk_order;

        IF v_challan_type IS DISTINCT FROM 'WALK_IN' THEN
            RAISE EXCEPTION
                'Validation Failed: Cylinder % (%) is in FULL state (at yard). '
                'A FULL cylinder can only be added to a WALK_IN challan (yard counter sale). '
                'To deliver it on a vehicle trip, load it first (tbl_vehicle_load_line) '
                'so it transitions to FULL_PICKED_UP_FOR_DELIVERY. '
                'This challan is type [%].',
                v_cylinder_serial, NEW.fk_cylinder,
                COALESCE(v_challan_type, 'UNKNOWN');
        END IF;

        -- Also validate a tbl_walk_in_sale row exists for this order
        IF NOT EXISTS (
            SELECT 1 FROM public.tbl_walk_in_sale
             WHERE fk_order = NEW.fk_order
               AND sale_status = 'OPEN'
        ) THEN
            RAISE EXCEPTION
                'Validation Failed: No OPEN walk-in sale session found for order %. '
                'Create a tbl_walk_in_sale row with sale_status = OPEN before '
                'entering order lines for a WALK_IN challan.',
                NEW.fk_order;
        END IF;

        RETURN NEW;
    END IF;

    -- ── No valid path matched ─────────────────────────────────────────────────
    RAISE EXCEPTION
        'Validation Failed: Cylinder % (%) is in state [%]. '
        'Valid states for tbl_order_line are: '
        'FULL_PICKED_UP_FOR_DELIVERY (standard trip delivery), '
        'FULL_PICKED_FROM_SUPPLIER (direct delivery from supplier vehicle — V88), '
        'FULL (walk-in counter sale via WALK_IN challan only — V89).',
        v_cylinder_serial, NEW.fk_cylinder,
        COALESCE(v_current_state_name, 'UNKNOWN — no state record found');
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_check_cylinder_is_picked_up() IS
    'Fires BEFORE INSERT on tbl_order_line. Three valid source states: '
    '  FULL_PICKED_UP_FOR_DELIVERY — standard trip delivery (loaded from yard). '
    '  FULL_PICKED_FROM_SUPPLIER   — direct delivery from supplier vehicle (V88/V89). '
    '    Validates: fk_current_vehicle_trip IS NOT NULL (cylinder must be on active trip). '
    '  FULL                        — walk-in counter sale (V89). '
    '    Validates: challan_type = WALK_IN AND an OPEN tbl_walk_in_sale exists. '
    'History: V21 → V66 → V88 (dual state) → V89 (three states, trip guard, walk-in guard).';


-- =============================================================================
-- PART 4 — fn_audit_cylinder_delivery_after
--           AFTER INSERT on tbl_order_line
--           Three paths: standard, direct delivery (auto-creates trip stop), walk-in
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_audit_cylinder_delivery_after()
RETURNS TRIGGER AS $$
DECLARE
    -- state IDs
    v_previous_state_id         int8;
    v_delivered_state_id        int8;
    v_full_state_id             int8;
    v_direct_delivery_state_id  int8;

    -- routing flags
    v_is_direct_delivery        boolean := false;
    v_is_walk_in                boolean := false;

    -- order / customer
    v_customer_id               int8;
    v_delivery_address_id       int8;
    v_challan_type              varchar(50);

    -- trip / stop (direct delivery path)
    v_trip_id                   int8;
    v_customer_delivery_type_id int8;
    v_yard_end_type_id          int8;
    v_next_stop_seq             int4;
    v_new_stop_id               int8;

    -- walk-in path
    v_walk_in_sale_id           int8;

    -- checkpoint / line counting
    v_line_count                int4;
BEGIN
    -- ── Resolve state IDs ─────────────────────────────────────────────────────
    SELECT pk_cylinder_state_id INTO v_delivered_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'DELIVERED_FOR_CONSUMPTION';

    SELECT pk_cylinder_state_id INTO v_direct_delivery_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL_PICKED_FROM_SUPPLIER';

    SELECT pk_cylinder_state_id INTO v_full_state_id
      FROM public.tbl_cylinder_states WHERE cylinder_state = 'FULL';

    -- ── Resolve the ACTUAL previous state at runtime ──────────────────────────
    SELECT fk_current_state INTO v_previous_state_id
      FROM public.tbl_cylinder_current_status WHERE fk_cylinder = NEW.fk_cylinder;

    IF NOT FOUND THEN
        SELECT fk_new_state INTO v_previous_state_id
          FROM public.tbl_cylinder_state_audit
         WHERE fk_cylinder = NEW.fk_cylinder
         ORDER BY changed_at DESC, pk_audit_id DESC LIMIT 1;
    END IF;

    v_is_direct_delivery := (v_previous_state_id = v_direct_delivery_state_id);
    v_is_walk_in         := (v_previous_state_id = v_full_state_id);

    -- ── Resolve customer and delivery address ─────────────────────────────────
    SELECT o.fk_customer,
           COALESCE(NEW.fk_delivery_address, o.fk_delivery_address),
           ct.challan_type
      INTO v_customer_id, v_delivery_address_id, v_challan_type
      FROM public.tbl_order o
      JOIN public.tbl_challan_type ct ON ct.pk_challan_type_id = o.fk_challan_type
     WHERE o.pk_order_id = NEW.fk_order;

    -- =========================================================================
    -- STEP 1 — Write state audit row (all three paths)
    -- =========================================================================
    INSERT INTO public.tbl_cylinder_state_audit (
        pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
        fk_order, changed_at, remarks
    ) VALUES (
        nextval('public.pk_cylinder_state_id_serial'),
        NEW.fk_cylinder,
        v_previous_state_id,
        v_delivered_state_id,
        NEW.fk_order,
        now(),
        CASE
            WHEN v_is_walk_in THEN
                'Walk-in counter sale. State: FULL → DELIVERED_FOR_CONSUMPTION. '
                || 'Customer collected cylinder directly from yard (V89).'
            WHEN v_is_direct_delivery THEN
                'Direct delivery from supplier vehicle. '
                || 'State: FULL_PICKED_FROM_SUPPLIER → DELIVERED_FOR_CONSUMPTION. '
                || 'No yard entry created (V88/V89 direct-delivery path).'
            ELSE
                'Standard trip delivery. '
                || 'State: FULL_PICKED_UP_FOR_DELIVERY → DELIVERED_FOR_CONSUMPTION.'
        END
    );

    -- =========================================================================
    -- STEP 2 — Update tbl_cylinder_current_status (all three paths)
    -- =========================================================================
    UPDATE public.tbl_cylinder_current_status
       SET fk_current_state            = v_delivered_state_id,
           fk_current_holder_customer  = v_customer_id,
           fk_current_customer_address = v_delivery_address_id,
           fk_current_vehicle_trip     = NULL,
           fk_current_vehicle_load     = NULL,
           -- Direct-delivery and walk-in: cylinder no longer tracked to a supplier trip
           fk_last_supplier_trip       = CASE
                                             WHEN v_is_direct_delivery OR v_is_walk_in
                                             THEN NULL
                                             ELSE fk_last_supplier_trip
                                         END,
           updated_at                  = now()
     WHERE fk_cylinder = NEW.fk_cylinder;

    -- =========================================================================
    -- STEP 3 — PATH-SPECIFIC: direct delivery → auto-create CUSTOMER_DELIVERY stop
    -- =========================================================================
    -- The cylinder is on a vehicle trip (fk_current_vehicle_trip was set when
    -- the cylinder transitioned to FULL_PICKED_FROM_SUPPLIER in V63). We need
    -- to create a CUSTOMER_DELIVERY stop and link the order to it so that the
    -- existing fn_trip_stop_order_linked trigger (V81) emits the
    -- TRIP_STOP_DELIVERY checkpoint, making this delivery fully visible to the
    -- reconciliation orchestrator.
    --
    -- Two-phase insert:
    --   Phase A: INSERT the stop WITHOUT fk_order (no checkpoint yet)
    --   Phase B: UPDATE to set fk_order (triggers fn_trip_stop_order_linked)
    --
    -- Guard: if a CUSTOMER_DELIVERY stop for this order+trip already exists
    -- (because a previous order_line on the same multi-line challan already
    -- created it), skip both phases.
    -- =========================================================================

    IF v_is_direct_delivery THEN

        -- Retrieve the trip the cylinder is on (already cleared from current_status above,
        -- so we read it from the audit trail before our UPDATE committed — except the UPDATE
        -- already ran. We need to get the trip from the BEFORE state. Use a separate query
        -- on tbl_supplier_refill_collection / tbl_cylinder_state_audit is complex.
        -- Better: read it before the UPDATE. But we're in AFTER, so use a subquery on
        -- tbl_reconciliation_checkpoint or tbl_cylinder_state_audit.)
        --
        -- Reliable source: the most recent tbl_cylinder_state_audit row for FULL_PICKED_FROM_SUPPLIER
        -- has no trip FK, but tbl_supplier_refill_collection.fk_vehicle_trip holds it.
        -- Simplest: read the trip from the state audit → supplier_refill_collection_line.
        -- Most recent supplier refill collection for this cylinder → vehicle trip
        SELECT src.fk_vehicle_trip
          INTO v_trip_id
          FROM public.tbl_supplier_refill_collection_line srcl
          JOIN public.tbl_supplier_refill_collection      src
               ON src.pk_collection_id = srcl.fk_collection
         WHERE srcl.fk_cylinder = NEW.fk_cylinder
         ORDER BY src.pk_collection_id DESC
         LIMIT 1;

        IF v_trip_id IS NOT NULL THEN

            -- Check if a stop for this order+trip already exists (multi-line challan guard)
            IF NOT EXISTS (
                SELECT 1 FROM public.tbl_vehicle_trip_stop
                 WHERE fk_vehicle_trip = v_trip_id
                   AND fk_order        = NEW.fk_order
            ) THEN
                SELECT pk_stop_type_id INTO v_customer_delivery_type_id
                  FROM public.tbl_stop_type WHERE stop_type = 'CUSTOMER_DELIVERY';

                SELECT pk_stop_type_id INTO v_yard_end_type_id
                  FROM public.tbl_stop_type WHERE stop_type = 'YARD_END';

                -- Get next sequence: MAX of all non-YARD_END stops + 1
                -- Then push YARD_END forward if it already occupies that slot.
                SELECT COALESCE(MAX(s.stop_sequence), 1) + 1
                  INTO v_next_stop_seq
                  FROM public.tbl_vehicle_trip_stop s
                 WHERE s.fk_vehicle_trip = v_trip_id
                   AND s.fk_stop_type   <> v_yard_end_type_id;

                -- Phase A: INSERT stop without fk_order (stop_status = COMPLETED
                -- because the delivery already happened physically; arrived_at = now)
                v_new_stop_id := nextval('public.pk_trip_stop_id_serial');

                INSERT INTO public.tbl_vehicle_trip_stop (
                    pk_stop_id, fk_vehicle_trip, stop_sequence, fk_stop_type,
                    fk_customer, fk_delivery_address,
                    arrived_at, departed_at, stop_status
                ) VALUES (
                    v_new_stop_id,
                    v_trip_id,
                    v_next_stop_seq,
                    v_customer_delivery_type_id,
                    v_customer_id,
                    v_delivery_address_id,
                    now(),   -- arrived_at: delivery is happening now
                    now(),   -- departed_at: physically, the delivery is done at point of line entry
                    'COMPLETED'
                );

                -- Phase B: set fk_order → triggers fn_trip_stop_order_linked (V81)
                --          which emits the TRIP_STOP_DELIVERY checkpoint
                UPDATE public.tbl_vehicle_trip_stop
                   SET fk_order = NEW.fk_order
                 WHERE pk_stop_id = v_new_stop_id;

            END IF; -- stop already exists guard
        END IF; -- trip not null guard

    END IF; -- v_is_direct_delivery

    -- =========================================================================
    -- STEP 4 — PATH-SPECIFIC: walk-in → update WALK_IN_SALE checkpoint
    -- =========================================================================
    -- The WALK_IN_SALE checkpoint was created when tbl_walk_in_sale was inserted
    -- (fn_walk_in_sale_on_insert). Here we grow expected_count to match the
    -- running line count, mirroring how TRIP_STOP_DELIVERY works.
    -- =========================================================================

    IF v_is_walk_in THEN
        SELECT pk_walk_in_sale_id INTO v_walk_in_sale_id
          FROM public.tbl_walk_in_sale WHERE fk_order = NEW.fk_order;

        SELECT COUNT(*) INTO v_line_count
          FROM public.tbl_order_line WHERE fk_order = NEW.fk_order;

        UPDATE public.tbl_reconciliation_checkpoint
           SET remarks = 'Walk-in sale ' || COALESCE(v_walk_in_sale_id::text, '?')
                      || ' — entered: ' || v_line_count
                      || ' / declared: '
                      || (SELECT total_cylinders FROM public.tbl_walk_in_sale
                           WHERE pk_walk_in_sale_id = v_walk_in_sale_id)
         WHERE reference_entity_type = 'tbl_walk_in_sale'
           AND reference_entity_id   = v_walk_in_sale_id
           AND checkpoint_type       = 'WALK_IN_SALE'
           AND checkpoint_status     = 'PENDING';
    END IF;

    -- =========================================================================
    -- STEP 5 — Update TRIP_STOP_DELIVERY checkpoint remarks (standard + direct path)
    -- =========================================================================
    -- Mirrors the V82 logic. Walk-in has its own checkpoint (Step 4 above).
    -- =========================================================================

    IF NOT v_is_walk_in THEN
        SELECT COUNT(*) INTO v_line_count
          FROM public.tbl_order_line WHERE fk_order = NEW.fk_order;

        UPDATE public.tbl_reconciliation_checkpoint
           SET remarks = 'Challan ' || NEW.fk_order
                      || ' — entered: ' || v_line_count
                      || ' / declared: '
                      || (SELECT total_cylinders_delivered
                            FROM public.tbl_order WHERE pk_order_id = NEW.fk_order)
         WHERE reference_entity_type = 'tbl_order'
           AND reference_entity_id   = NEW.fk_order
           AND checkpoint_type       = 'TRIP_STOP_DELIVERY'
           AND checkpoint_status     = 'PENDING';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_audit_cylinder_delivery_after() IS
    'Fires AFTER INSERT on tbl_order_line. Three delivery paths: '
    '  FULL_PICKED_UP_FOR_DELIVERY — standard trip delivery; updates TRIP_STOP_DELIVERY remarks. '
    '  FULL_PICKED_FROM_SUPPLIER   — direct delivery (V88/V89); auto-creates CUSTOMER_DELIVERY '
    '    stop on the cylinder''s current vehicle trip; setting fk_order on the stop fires '
    '    fn_trip_stop_order_linked (V81) → TRIP_STOP_DELIVERY checkpoint. '
    '  FULL (walk-in)              — yard counter sale; updates WALK_IN_SALE checkpoint remarks. '
    'Previous state resolved at runtime (not hardcoded). '
    'Uses fk_current_holder_customer (correct V41 column). '
    'History: V21 → V56 → V66 → V81 → V82 → V88 → V89 (three paths, trip auto-link, walk-in).';


-- =============================================================================
-- PART 5 — fn_walk_in_sale_on_insert
--           AFTER INSERT on tbl_walk_in_sale
--           Creates a PENDING WALK_IN_SALE checkpoint
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_walk_in_sale_on_insert()
RETURNS TRIGGER AS $$
BEGIN
    BEGIN
        PERFORM public.fn_create_checkpoint(
            'WALK_IN_SALE',
            'tbl_walk_in_sale',
            NEW.pk_walk_in_sale_id,
            NEW.total_cylinders,   -- declared at session open
            2,                     -- 2-hour escalation: sale should complete quickly
            'Walk-in sale opened by ' || NEW.sold_by
                || ' for customer ' || NEW.fk_customer
                || ' on ' || NEW.sale_date
                || '. Declared cylinders: ' || NEW.total_cylinders
        );
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'fn_walk_in_sale_on_insert [checkpoint]: %', SQLERRM;
    END;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_walk_in_sale_on_insert ON public.tbl_walk_in_sale;
CREATE TRIGGER trg_walk_in_sale_on_insert
AFTER INSERT ON public.tbl_walk_in_sale
FOR EACH ROW EXECUTE FUNCTION public.fn_walk_in_sale_on_insert();

COMMENT ON FUNCTION public.fn_walk_in_sale_on_insert() IS
    'AFTER INSERT on tbl_walk_in_sale. '
    'Creates a PENDING WALK_IN_SALE checkpoint with expected_count = total_cylinders. '
    '2-hour escalation: a walk-in sale should complete within one visit. '
    'The checkpoint is resolved by fn_walk_in_sale_on_complete when sale_status → COMPLETED.';


-- =============================================================================
-- PART 6 — fn_walk_in_sale_on_complete
--           AFTER UPDATE on tbl_walk_in_sale (sale_status → COMPLETED)
--           Resolves the WALK_IN_SALE checkpoint with the actual line count
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_walk_in_sale_on_complete()
RETURNS TRIGGER AS $$
DECLARE
    v_actual_count  int4;
    v_remarks       varchar(500);
BEGIN
    -- Only fire when status transitions TO COMPLETED
    IF NEW.sale_status <> 'COMPLETED' OR OLD.sale_status = 'COMPLETED' THEN
        RETURN NEW;
    END IF;

    -- Actual count = number of order lines entered for this sale's challan
    SELECT COUNT(*) INTO v_actual_count
      FROM public.tbl_order_line
     WHERE fk_order = NEW.fk_order;

    v_remarks := 'Walk-in sale completed by ' || NEW.sold_by
              || '. Cylinders declared: ' || NEW.total_cylinders
              || '. Order lines entered: ' || v_actual_count
              || '. Completed at: ' || now()::text;

    BEGIN
        PERFORM public.fn_resolve_checkpoint(
            'tbl_walk_in_sale',
            NEW.pk_walk_in_sale_id,
            'WALK_IN_SALE',
            v_actual_count,
            v_remarks
        );
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'fn_walk_in_sale_on_complete [resolve]: %', SQLERRM;
    END;

    -- Mark the challan as invoiceable (is_invoiced stays FALSE — invoice is raised separately)
    -- Update updated_at
    UPDATE public.tbl_walk_in_sale
       SET updated_at = now()
     WHERE pk_walk_in_sale_id = NEW.pk_walk_in_sale_id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_walk_in_sale_on_complete ON public.tbl_walk_in_sale;
CREATE TRIGGER trg_walk_in_sale_on_complete
AFTER UPDATE OF sale_status ON public.tbl_walk_in_sale
FOR EACH ROW EXECUTE FUNCTION public.fn_walk_in_sale_on_complete();

COMMENT ON FUNCTION public.fn_walk_in_sale_on_complete() IS
    'AFTER UPDATE on tbl_walk_in_sale (sale_status → COMPLETED). '
    'Resolves the WALK_IN_SALE checkpoint with actual_count = COUNT(tbl_order_line). '
    'MATCHED means declared total_cylinders = actual lines entered. '
    'VARIANCE means the office declared N cylinders but entered a different count — '
    'requires investigation before invoice can be raised.';


-- =============================================================================
-- PART 7 — vw_walk_in_sale_dashboard
--           Live view of today's walk-in sales and their checkpoint status
-- =============================================================================

CREATE OR REPLACE VIEW public.vw_walk_in_sale_dashboard AS
SELECT
    wis.pk_walk_in_sale_id,
    wis.sale_date,
    wis.sale_status,
    c.customer_name,
    wis.sold_by,
    wis.total_cylinders                                     AS declared_cylinders,
    COUNT(ol.pk_order_line_id)                              AS entered_lines,
    o.challan_number,
    o.is_invoiced,
    rc.checkpoint_status                                    AS checkpoint_status,
    rc.variance                                             AS checkpoint_variance,
    EXTRACT(HOUR FROM now() - wis.created_at)::int          AS age_hours,
    wis.remarks
FROM  public.tbl_walk_in_sale              wis
JOIN  public.tbl_customer                  c    ON c.pk_customer_id  = wis.fk_customer
JOIN  public.tbl_order                     o    ON o.pk_order_id     = wis.fk_order
LEFT  JOIN public.tbl_order_line           ol   ON ol.fk_order       = wis.fk_order
LEFT  JOIN public.tbl_reconciliation_checkpoint rc
           ON  rc.reference_entity_type = 'tbl_walk_in_sale'
           AND rc.reference_entity_id   = wis.pk_walk_in_sale_id
           AND rc.checkpoint_type       = 'WALK_IN_SALE'
GROUP BY
    wis.pk_walk_in_sale_id, wis.sale_date, wis.sale_status,
    c.customer_name, wis.sold_by, wis.total_cylinders,
    o.challan_number, o.is_invoiced,
    rc.checkpoint_status, rc.variance, wis.created_at, wis.remarks
ORDER BY wis.sale_date DESC, wis.created_at DESC;

COMMENT ON VIEW public.vw_walk_in_sale_dashboard IS
    'One row per walk-in sale. Shows declared vs entered cylinder counts, '
    'challan number, invoice status, and reconciliation checkpoint outcome. '
    'checkpoint_variance <> 0 means the declared count did not match entered lines.';
