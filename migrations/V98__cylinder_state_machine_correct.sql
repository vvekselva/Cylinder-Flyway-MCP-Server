-- ================================================================
-- MIGRATION V98: Cylinder State Machine — Full Data Layer Enforcement
-- ================================================================
--
-- ROOT CAUSE OF PREVIOUS FAILURE (SQL State 42703)
-- ──────────────────────────────────────────────────────────────────
-- The original V98 was written assuming tbl_cylinder_current_status
-- has a plain VARCHAR cylinder_state column. It does NOT.
-- State is stored as fk_current_state INT8 (FK →
-- tbl_cylinder_states.pk_cylinder_state_id). Every direct reference
-- to NEW.cylinder_state / OLD.cylinder_state / ccs.cylinder_state
-- against tbl_cylinder_current_status is wrong and was corrected here.
--
-- COMPLETE COLUMN MAP (as built by V41 + V56 + V63)
-- ──────────────────────────────────────────────────────────────────
-- tbl_cylinder_current_status
--   fk_cylinder              INT8  PK  (→ tbl_cylinder.pk_cylinder_id)
--   fk_current_state         INT8  FK  (→ tbl_cylinder_states.pk_cylinder_state_id)
--   fk_current_vehicle_load  INT8  NULL FK (→ tbl_vehicle_load)
--   fk_current_vehicle_trip  INT8  NULL FK (→ tbl_vehicle_trip)   [added V56]
--   fk_current_supplier      INT8  NULL FK (→ tbl_supplier)       [added V63]
--   fk_current_holder_customer INT8 NULL FK
--   fk_current_customer_address INT8 NULL FK
--   fk_last_order            INT8  NULL FK
--   fk_last_supplier_trip    INT8  NULL FK
--   updated_at               TIMESTAMP
--
-- tbl_cylinder            : pk_cylinder_id, cylinder_serial, fk_product
-- tbl_product             : pk_product_id, product_name
-- tbl_vehicle_load        : pk_vehicle_load_id, fk_vehicle_trip
-- tbl_vehicle_load_line   : pk_vehicle_load_line_id, fk_vehicle_load, fk_cylinder
-- tbl_cylinder_party_custody: pk_custody_id, fk_cylinder, party_type,
--                            fk_customer, fk_supplier, entered_at,
--                            custody_status ('ACTIVE'|'CLOSED')
-- tbl_empty_pickup        : pk_pickup_id, fk_customer, pickup_status
-- tbl_empty_pickup_line   : pk_pickup_line_id, fk_empty_pickup, fk_cylinder
-- ================================================================

BEGIN;

-- ════════════════════════════════════════════════════════════════
-- PART 0 — Correct historical typo: DECOMISSIONED → DECOMMISSIONED
-- ════════════════════════════════════════════════════════════════
-- tbl_cylinder_current_status uses fk_current_state (INT8 FK) —
-- there is NO cylinder_state varchar column on that table.
-- The PK in tbl_cylinder_states does not change; only the label does.
-- So only tbl_cylinder_states needs updating.
-- ════════════════════════════════════════════════════════════════

UPDATE public.tbl_cylinder_states
   SET cylinder_state = 'DECOMMISSIONED'
 WHERE cylinder_state = 'DECOMISSIONED';


-- ════════════════════════════════════════════════════════════════
-- PART 1 — Insert EMPTY_IN_TRANSIT_TO_YARD, correct all locations
-- ════════════════════════════════════════════════════════════════

INSERT INTO public.tbl_cylinder_states
    (pk_cylinder_state_id, cylinder_state, description, location)
VALUES
    (nextval('public.pk_cylinder_state_id_serial'),
     'EMPTY_IN_TRANSIT_TO_YARD',
     'Empty cylinder loaded on pickup vehicle, returning to yard',
     'In Transit')
ON CONFLICT (cylinder_state) DO UPDATE
    SET location    = 'In Transit',
        description = EXCLUDED.description;

UPDATE public.tbl_cylinder_states SET location = 'Unknown'           WHERE cylinder_state = 'COMMISSIONED';
UPDATE public.tbl_cylinder_states SET location = 'Yard'              WHERE cylinder_state = 'EMPTY';
UPDATE public.tbl_cylinder_states SET location = 'In Transit'        WHERE cylinder_state = 'EMPTY_PICKED_FOR_REFILL';
UPDATE public.tbl_cylinder_states SET location = 'Supplier Location' WHERE cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL';
UPDATE public.tbl_cylinder_states SET location = 'In Transit'        WHERE cylinder_state = 'FULL_PICKED_FROM_SUPPLIER';
UPDATE public.tbl_cylinder_states SET location = 'Yard'              WHERE cylinder_state = 'FULL';
UPDATE public.tbl_cylinder_states SET location = 'In Transit'        WHERE cylinder_state = 'FULL_PICKED_UP_FOR_DELIVERY';
UPDATE public.tbl_cylinder_states SET location = 'Customer Location' WHERE cylinder_state = 'DELIVERED_FOR_CONSUMPTION';
UPDATE public.tbl_cylinder_states SET location = 'In Transit'        WHERE cylinder_state = 'EMPTY_IN_TRANSIT_TO_YARD';
UPDATE public.tbl_cylinder_states SET location = 'In Transit'        WHERE cylinder_state = 'EMPTY_PICKED_UP_FROM_SUPPLIER';
UPDATE public.tbl_cylinder_states SET location = 'Customer Location' WHERE cylinder_state = 'DAMAGED';
UPDATE public.tbl_cylinder_states SET location = 'Customer Location' WHERE cylinder_state = 'LOST';
UPDATE public.tbl_cylinder_states SET location = 'SCRAP'             WHERE cylinder_state = 'DECOMMISSIONED';


-- ════════════════════════════════════════════════════════════════
-- PART 2 — FK expectation flags (derived from location)
-- ════════════════════════════════════════════════════════════════

ALTER TABLE public.tbl_cylinder_states
    ADD COLUMN IF NOT EXISTS expects_load_fk BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS expects_trip_fk BOOLEAN NOT NULL DEFAULT FALSE;

UPDATE public.tbl_cylinder_states
   SET expects_load_fk = TRUE, expects_trip_fk = TRUE
 WHERE location = 'In Transit';

UPDATE public.tbl_cylinder_states
   SET expects_load_fk = FALSE, expects_trip_fk = FALSE
 WHERE location != 'In Transit';

SELECT cylinder_state, location, expects_load_fk, expects_trip_fk
  FROM public.tbl_cylinder_states
 ORDER BY location, cylinder_state;


-- ════════════════════════════════════════════════════════════════
-- PART 3 — Legal transition table
-- ════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.tbl_cylinder_state_transition (
    from_state  VARCHAR(60) NOT NULL,
    to_state    VARCHAR(60) NOT NULL,
    description TEXT,
    PRIMARY KEY (from_state, to_state),
    FOREIGN KEY (from_state) REFERENCES public.tbl_cylinder_states(cylinder_state),
    FOREIGN KEY (to_state)   REFERENCES public.tbl_cylinder_states(cylinder_state)
);

TRUNCATE public.tbl_cylinder_state_transition;

INSERT INTO public.tbl_cylinder_state_transition (from_state, to_state, description) VALUES
('COMMISSIONED',                 'EMPTY',                       'New cylinder into yard stock'),
('FULL',                         'FULL_PICKED_UP_FOR_DELIVERY', 'Loaded on delivery vehicle'),
('FULL_PICKED_UP_FOR_DELIVERY',  'DELIVERED_FOR_CONSUMPTION',   'Delivered to customer'),
('DELIVERED_FOR_CONSUMPTION',    'EMPTY_IN_TRANSIT_TO_YARD',    'Loaded on pickup vehicle'),
('EMPTY_IN_TRANSIT_TO_YARD',     'EMPTY',                       'Checked into yard'),
('FULL_PICKED_UP_FOR_DELIVERY',  'FULL',                        'Returned to yard undelivered'),
('EMPTY',                        'EMPTY_PICKED_FOR_REFILL',     'Loaded for supplier'),
('EMPTY_PICKED_FOR_REFILL',      'EMPTY_DELIVERED_FOR_REFILL',  'Delivered to supplier'),
('EMPTY_DELIVERED_FOR_REFILL',   'FULL_PICKED_FROM_SUPPLIER',   'Refilled, loaded for return'),
('FULL_PICKED_FROM_SUPPLIER',    'FULL',                        'Full cylinder into yard'),
('EMPTY_DELIVERED_FOR_REFILL',   'EMPTY_PICKED_UP_FROM_SUPPLIER','Supplier returns empty'),
('EMPTY_PICKED_UP_FROM_SUPPLIER','EMPTY',                       'Returned to yard'),
('DELIVERED_FOR_CONSUMPTION',    'DAMAGED',                     'Damaged at customer'),
('DELIVERED_FOR_CONSUMPTION',    'LOST',                        'Lost at customer'),
('EMPTY_IN_TRANSIT_TO_YARD',     'DAMAGED',                     'Damage found during pickup'),
('EMPTY',                        'DECOMMISSIONED',              'Empty cylinder decommissioned'),
('DAMAGED',                      'DECOMMISSIONED',              'Damaged cylinder written off'),
('FULL',                         'DECOMMISSIONED',              'Full cylinder decommissioned');


-- ════════════════════════════════════════════════════════════════
-- PART 4 — State machine trigger
--
-- FIX: tbl_cylinder_current_status has NO cylinder_state column.
--      State is stored as fk_current_state (INT8 FK).
--      Resolve state names via tbl_cylinder_states before checking
--      the transition table. Use fk_cylinder (not tbl_cylinder_id).
-- ════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.fn_cylinder_state_machine()
RETURNS trigger AS $$
DECLARE
    v_old_state VARCHAR(60);
    v_new_state VARCHAR(60);
BEGIN
    -- No state change → nothing to validate
    IF NEW.fk_current_state = OLD.fk_current_state THEN
        RETURN NEW;
    END IF;

    -- Resolve state names from the FK (state is stored as INT8, not VARCHAR)
    SELECT cylinder_state INTO v_old_state
      FROM public.tbl_cylinder_states
     WHERE pk_cylinder_state_id = OLD.fk_current_state;

    SELECT cylinder_state INTO v_new_state
      FROM public.tbl_cylinder_states
     WHERE pk_cylinder_state_id = NEW.fk_current_state;

    IF NOT EXISTS (
        SELECT 1
          FROM public.tbl_cylinder_state_transition
         WHERE from_state = v_old_state
           AND to_state   = v_new_state
    ) THEN
        RAISE EXCEPTION
            'ILLEGAL STATE TRANSITION — fk_cylinder=%, [%] → [%]. '
            'Add to tbl_cylinder_state_transition if valid.',
            NEW.fk_cylinder, v_old_state, v_new_state;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_cylinder_state_machine ON public.tbl_cylinder_current_status;
CREATE TRIGGER trg_cylinder_state_machine
BEFORE UPDATE ON public.tbl_cylinder_current_status
FOR EACH ROW EXECUTE FUNCTION public.fn_cylinder_state_machine();


-- ════════════════════════════════════════════════════════════════
-- PART 5 — FK consistency trigger
--
-- FIX: use fk_current_state, fk_current_vehicle_load,
--      fk_current_vehicle_trip, fk_cylinder — NOT the non-existent
--      cylinder_state / tbl_current_vehicle_load / tbl_cylinder_id.
-- ════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.fn_cylinder_fk_consistency()
RETURNS trigger AS $$
DECLARE
    v_exp_load   BOOLEAN;
    v_exp_trip   BOOLEAN;
    v_state_name VARCHAR(60);
BEGIN
    SELECT expects_load_fk, expects_trip_fk, cylinder_state
      INTO v_exp_load, v_exp_trip, v_state_name
      FROM public.tbl_cylinder_states
     WHERE pk_cylinder_state_id = NEW.fk_current_state;

    IF v_exp_load = TRUE  AND NEW.fk_current_vehicle_load IS NULL THEN
        RAISE EXCEPTION 'FK VIOLATION — fk_cylinder=%, state=[%]: fk_current_vehicle_load must be SET.',
            NEW.fk_cylinder, v_state_name;
    END IF;
    IF v_exp_load = FALSE AND NEW.fk_current_vehicle_load IS NOT NULL THEN
        RAISE EXCEPTION 'FK VIOLATION — fk_cylinder=%, state=[%]: fk_current_vehicle_load must be NULL.',
            NEW.fk_cylinder, v_state_name;
    END IF;
    IF v_exp_trip = TRUE  AND NEW.fk_current_vehicle_trip IS NULL THEN
        RAISE EXCEPTION 'FK VIOLATION — fk_cylinder=%, state=[%]: fk_current_vehicle_trip must be SET.',
            NEW.fk_cylinder, v_state_name;
    END IF;
    IF v_exp_trip = FALSE AND NEW.fk_current_vehicle_trip IS NOT NULL THEN
        RAISE EXCEPTION 'FK VIOLATION — fk_cylinder=%, state=[%]: fk_current_vehicle_trip must be NULL.',
            NEW.fk_cylinder, v_state_name;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_cylinder_fk_consistency ON public.tbl_cylinder_current_status;
CREATE TRIGGER trg_cylinder_fk_consistency
BEFORE UPDATE ON public.tbl_cylinder_current_status
FOR EACH ROW EXECUTE FUNCTION public.fn_cylinder_fk_consistency();


-- ════════════════════════════════════════════════════════════════
-- PART 6 — Stranded cylinder repair tracking
--
-- FIX: "stranded" cylinders are those with an ACTIVE CUSTOMER
--      custody record (tbl_cylinder_party_custody) with no open
--      empty pickup. The old query incorrectly used tbl_order_lines
--      (wrong table name), tbl_cylinder_id, tbl_vehicle_load_id,
--      delivered_at (none of which exist on tbl_order_line), and
--      tbl_empty_lines (non-existent; correct table is
--      tbl_empty_pickup_line joined via tbl_empty_pickup).
-- ════════════════════════════════════════════════════════════════

-- Diagnostic audit: stranded cylinders at time of migration
SELECT
    cpc.fk_cylinder,
    c.cylinder_serial,
    cs.cylinder_state                           AS current_state,
    cpc.fk_customer,
    cpc.entered_at                              AS delivered_at,
    CURRENT_TIMESTAMP - cpc.entered_at          AS stranded_duration,
    vll.fk_vehicle_load                         AS last_delivery_load_id,
    vl.fk_vehicle_trip                          AS last_delivery_trip_id
FROM public.tbl_cylinder_party_custody     cpc
JOIN public.tbl_cylinder                   c   ON c.pk_cylinder_id        = cpc.fk_cylinder
JOIN public.tbl_cylinder_current_status    ccs ON ccs.fk_cylinder         = cpc.fk_cylinder
JOIN public.tbl_cylinder_states            cs  ON cs.pk_cylinder_state_id = ccs.fk_current_state
-- Most recent vehicle load that carried this cylinder
JOIN LATERAL (
    SELECT vll2.fk_vehicle_load
      FROM public.tbl_vehicle_load_line vll2
     WHERE vll2.fk_cylinder = cpc.fk_cylinder
     ORDER BY vll2.pk_vehicle_load_line_id DESC
     LIMIT 1
) vll ON true
JOIN public.tbl_vehicle_load vl ON vl.pk_vehicle_load_id = vll.fk_vehicle_load
WHERE cpc.custody_status = 'ACTIVE'
  AND cpc.party_type     = 'CUSTOMER'
  -- No open empty pickup for this cylinder
  AND NOT EXISTS (
        SELECT 1
          FROM public.tbl_empty_pickup_line epl
          JOIN public.tbl_empty_pickup      ep  ON ep.pk_pickup_id = epl.fk_empty_pickup
         WHERE epl.fk_cylinder      = cpc.fk_cylinder
           AND ep.pickup_status NOT IN ('COMPLETED', 'CANCELLED')
  )
ORDER BY cpc.entered_at ASC;


CREATE TABLE IF NOT EXISTS public.tbl_cylinder_stranded_repair (
    repair_id               BIGSERIAL   PRIMARY KEY,
    fk_cylinder             BIGINT      NOT NULL,
    cylinder_serial         VARCHAR(60),
    stranded_state          VARCHAR(60),
    last_delivery_load_id   BIGINT,
    last_delivery_trip_id   BIGINT,
    delivered_at            TIMESTAMP,
    detected_at             TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    resolved_at             TIMESTAMP,
    resolved_by_load_id     BIGINT,
    resolved_by_trip_id     BIGINT,
    notes                   TEXT
);

INSERT INTO public.tbl_cylinder_stranded_repair
    (fk_cylinder, cylinder_serial, stranded_state,
     last_delivery_load_id, last_delivery_trip_id, delivered_at)
SELECT
    cpc.fk_cylinder,
    c.cylinder_serial,
    cs.cylinder_state,
    vll.fk_vehicle_load,
    vl.fk_vehicle_trip,
    cpc.entered_at
FROM public.tbl_cylinder_party_custody     cpc
JOIN public.tbl_cylinder                   c   ON c.pk_cylinder_id        = cpc.fk_cylinder
JOIN public.tbl_cylinder_current_status    ccs ON ccs.fk_cylinder         = cpc.fk_cylinder
JOIN public.tbl_cylinder_states            cs  ON cs.pk_cylinder_state_id = ccs.fk_current_state
JOIN LATERAL (
    SELECT vll2.fk_vehicle_load
      FROM public.tbl_vehicle_load_line vll2
     WHERE vll2.fk_cylinder = cpc.fk_cylinder
     ORDER BY vll2.pk_vehicle_load_line_id DESC
     LIMIT 1
) vll ON true
JOIN public.tbl_vehicle_load vl ON vl.pk_vehicle_load_id = vll.fk_vehicle_load
WHERE cpc.custody_status = 'ACTIVE'
  AND cpc.party_type     = 'CUSTOMER'
  AND NOT EXISTS (
        SELECT 1
          FROM public.tbl_empty_pickup_line epl
          JOIN public.tbl_empty_pickup      ep  ON ep.pk_pickup_id = epl.fk_empty_pickup
         WHERE epl.fk_cylinder      = cpc.fk_cylinder
           AND ep.pickup_status NOT IN ('COMPLETED', 'CANCELLED')
  )
  AND NOT EXISTS (
        SELECT 1
          FROM public.tbl_cylinder_stranded_repair r
         WHERE r.fk_cylinder  = cpc.fk_cylinder
           AND r.resolved_at IS NULL
  );


-- ════════════════════════════════════════════════════════════════
-- PART 7 — Monitoring views
--
-- FIX throughout: join tbl_cylinder_states on pk_cylinder_state_id
--   = ccs.fk_current_state (not the non-existent ccs.cylinder_state).
--   Use ccs.fk_cylinder, c.pk_cylinder_id, c.fk_product,
--   p.pk_product_id, ccs.fk_current_vehicle_load,
--   ccs.fk_current_vehicle_trip — correcting all tbl_* aliases.
--   Stranded views use tbl_cylinder_party_custody, not tbl_order_lines.
-- ════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW public.vw_cylinder_inventory_by_product AS
SELECT
    p.pk_product_id,
    p.product_name,
    cs.cylinder_state,
    cs.location,
    cs.expects_load_fk,
    cs.expects_trip_fk,
    COUNT(*) AS cylinder_count
FROM public.tbl_cylinder_current_status ccs
JOIN public.tbl_cylinder_states cs ON cs.pk_cylinder_state_id = ccs.fk_current_state
JOIN public.tbl_cylinder        c  ON c.pk_cylinder_id        = ccs.fk_cylinder
JOIN public.tbl_product         p  ON p.pk_product_id         = c.fk_product
GROUP BY p.pk_product_id, p.product_name, cs.cylinder_state, cs.location,
         cs.expects_load_fk, cs.expects_trip_fk
ORDER BY p.product_name, cs.location, cs.cylinder_state;


CREATE OR REPLACE VIEW public.vw_cylinders_on_active_vehicles AS
SELECT
    ccs.fk_cylinder,
    c.cylinder_serial,
    p.product_name,
    cs.cylinder_state,
    cs.location,
    ccs.fk_current_vehicle_load AS vehicle_load_id,
    ccs.fk_current_vehicle_trip AS vehicle_trip_id
FROM public.tbl_cylinder_current_status ccs
JOIN public.tbl_cylinder_states cs ON cs.pk_cylinder_state_id = ccs.fk_current_state
JOIN public.tbl_cylinder        c  ON c.pk_cylinder_id        = ccs.fk_cylinder
JOIN public.tbl_product         p  ON p.pk_product_id         = c.fk_product
WHERE cs.location = 'In Transit'
ORDER BY ccs.fk_current_vehicle_trip, p.product_name, cs.cylinder_state;


CREATE OR REPLACE VIEW public.vw_stranded_cylinders AS
SELECT
    cpc.fk_cylinder,
    c.cylinder_serial,
    p.product_name,
    cs.cylinder_state                       AS current_state,
    cpc.fk_customer,
    cpc.entered_at                          AS delivered_at,
    CURRENT_TIMESTAMP - cpc.entered_at      AS stranded_duration,
    vll.fk_vehicle_load                     AS last_delivery_load_id,
    vl.fk_vehicle_trip                      AS last_delivery_trip_id
FROM public.tbl_cylinder_party_custody     cpc
JOIN public.tbl_cylinder                   c   ON c.pk_cylinder_id        = cpc.fk_cylinder
JOIN public.tbl_product                    p   ON p.pk_product_id         = c.fk_product
JOIN public.tbl_cylinder_current_status    ccs ON ccs.fk_cylinder         = cpc.fk_cylinder
JOIN public.tbl_cylinder_states            cs  ON cs.pk_cylinder_state_id = ccs.fk_current_state
JOIN LATERAL (
    SELECT vll2.fk_vehicle_load
      FROM public.tbl_vehicle_load_line vll2
     WHERE vll2.fk_cylinder = cpc.fk_cylinder
     ORDER BY vll2.pk_vehicle_load_line_id DESC
     LIMIT 1
) vll ON true
JOIN public.tbl_vehicle_load vl ON vl.pk_vehicle_load_id = vll.fk_vehicle_load
WHERE cpc.custody_status = 'ACTIVE'
  AND cpc.party_type     = 'CUSTOMER'
  AND NOT EXISTS (
        SELECT 1
          FROM public.tbl_empty_pickup_line epl
          JOIN public.tbl_empty_pickup      ep ON ep.pk_pickup_id = epl.fk_empty_pickup
         WHERE epl.fk_cylinder      = cpc.fk_cylinder
           AND ep.pickup_status NOT IN ('COMPLETED', 'CANCELLED')
  )
ORDER BY cpc.entered_at ASC;


CREATE OR REPLACE VIEW public.vw_stranded_by_delivery_trip AS
SELECT
    last_delivery_trip_id,
    last_delivery_load_id,
    COUNT(*)                            AS stranded_count,
    STRING_AGG(cylinder_serial, ', ')   AS stranded_serials,
    MIN(delivered_at)                   AS earliest_delivery,
    MAX(stranded_duration)              AS max_stranded_duration
FROM public.vw_stranded_cylinders
GROUP BY last_delivery_trip_id, last_delivery_load_id
ORDER BY max_stranded_duration DESC;


CREATE OR REPLACE VIEW public.vw_supplier_cylinder_movements AS
SELECT
    p.pk_product_id,
    p.product_name,
    cs.cylinder_state,
    COUNT(*) AS cylinder_count
FROM public.tbl_cylinder_current_status ccs
JOIN public.tbl_cylinder_states cs ON cs.pk_cylinder_state_id = ccs.fk_current_state
JOIN public.tbl_cylinder        c  ON c.pk_cylinder_id        = ccs.fk_cylinder
JOIN public.tbl_product         p  ON p.pk_product_id         = c.fk_product
WHERE cs.cylinder_state IN (
    'EMPTY_PICKED_FOR_REFILL','EMPTY_DELIVERED_FOR_REFILL',
    'FULL_PICKED_FROM_SUPPLIER','EMPTY_PICKED_UP_FROM_SUPPLIER'
)
GROUP BY p.pk_product_id, p.product_name, cs.cylinder_state
ORDER BY p.product_name, cs.cylinder_state;


CREATE OR REPLACE VIEW public.vw_fk_consistency_violations AS
SELECT
    ccs.fk_cylinder,
    c.cylinder_serial,
    cs.cylinder_state,
    cs.location,
    cs.expects_load_fk,
    cs.expects_trip_fk,
    ccs.fk_current_vehicle_load,
    ccs.fk_current_vehicle_trip,
    CASE
        WHEN cs.expects_load_fk = TRUE  AND ccs.fk_current_vehicle_load IS NULL
            THEN 'load FK must be SET for ' || cs.cylinder_state
        WHEN cs.expects_load_fk = FALSE AND ccs.fk_current_vehicle_load IS NOT NULL
            THEN 'load FK must be NULL for ' || cs.cylinder_state
        WHEN cs.expects_trip_fk = TRUE  AND ccs.fk_current_vehicle_trip IS NULL
            THEN 'trip FK must be SET for ' || cs.cylinder_state
        WHEN cs.expects_trip_fk = FALSE AND ccs.fk_current_vehicle_trip IS NOT NULL
            THEN 'trip FK must be NULL for ' || cs.cylinder_state
    END AS violation
FROM public.tbl_cylinder_current_status ccs
JOIN public.tbl_cylinder_states cs ON cs.pk_cylinder_state_id = ccs.fk_current_state
JOIN public.tbl_cylinder        c  ON c.pk_cylinder_id        = ccs.fk_cylinder
WHERE (cs.expects_load_fk = TRUE  AND ccs.fk_current_vehicle_load IS NULL)
   OR (cs.expects_load_fk = FALSE AND ccs.fk_current_vehicle_load IS NOT NULL)
   OR (cs.expects_trip_fk = TRUE  AND ccs.fk_current_vehicle_trip IS NULL)
   OR (cs.expects_trip_fk = FALSE AND ccs.fk_current_vehicle_trip IS NOT NULL);


-- ════════════════════════════════════════════════════════════════
-- PART 8 — Indexes
--
-- FIX: tbl_cylinder_current_status has no cylinder_state column and
--      no tbl_cylinder_id / tbl_current_vehicle_load / tbl_current_vehicle_trip.
--      Partial indexes on state must filter via fk_current_state
--      using a subquery (PostgreSQL partial index WHERE clause does
--      not allow subqueries, so state-filtered indexes are replaced
--      with plain indexes on fk_current_state).
--      tbl_order_lines → tbl_order_line; tbl_empty_lines → tbl_empty_pickup_line.
-- ════════════════════════════════════════════════════════════════

CREATE INDEX IF NOT EXISTS idx_ccs_vehicle_load
    ON public.tbl_cylinder_current_status (fk_current_vehicle_load)
    WHERE fk_current_vehicle_load IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_ccs_vehicle_trip
    ON public.tbl_cylinder_current_status (fk_current_vehicle_trip)
    WHERE fk_current_vehicle_trip IS NOT NULL;

-- Covers state-based lookups (replaces the illegal cylinder_state partial indexes)
CREATE INDEX IF NOT EXISTS idx_ccs_current_state
    ON public.tbl_cylinder_current_status (fk_current_state, fk_cylinder);

-- Composite covering index for findCurrentlyOnVehicle DAO query
CREATE INDEX IF NOT EXISTS idx_ccs_load_and_state
    ON public.tbl_cylinder_current_status (fk_current_vehicle_load, fk_current_state)
    WHERE fk_current_vehicle_load IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_ccs_trip_and_state
    ON public.tbl_cylinder_current_status (fk_current_vehicle_trip, fk_current_state)
    WHERE fk_current_vehicle_trip IS NOT NULL;

-- tbl_vehicle_load_line — cylinder movement history
CREATE INDEX IF NOT EXISTS idx_vll_cylinder
    ON public.tbl_vehicle_load_line (fk_cylinder, pk_vehicle_load_line_id DESC);

-- tbl_cylinder_party_custody — active custody lookups
CREATE INDEX IF NOT EXISTS idx_custody_active_customer
    ON public.tbl_cylinder_party_custody (fk_cylinder, custody_status)
    WHERE custody_status = 'ACTIVE' AND party_type = 'CUSTOMER';

-- tbl_empty_pickup_line — open pickup lookup per cylinder
CREATE INDEX IF NOT EXISTS idx_epl_cylinder
    ON public.tbl_empty_pickup_line (fk_cylinder, fk_empty_pickup);


-- ════════════════════════════════════════════════════════════════
-- POST-MIGRATION CHECKS
-- SELECT * FROM public.vw_fk_consistency_violations;     -- must be 0 rows
-- SELECT * FROM public.vw_stranded_cylinders;            -- operational backlog
-- SELECT * FROM public.vw_cylinder_inventory_by_product; -- full snapshot
-- SELECT * FROM public.vw_cylinders_on_active_vehicles;  -- live on-vehicle
-- SELECT * FROM public.vw_stranded_by_delivery_trip;     -- per-trip stranded
-- ════════════════════════════════════════════════════════════════

COMMIT;