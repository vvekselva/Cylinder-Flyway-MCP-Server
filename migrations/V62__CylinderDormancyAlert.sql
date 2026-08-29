-- =============================================================================
-- V62__CylinderDormancyAlert.sql
-- =============================================================================
-- PURPOSE:
--   Detect cylinders that have NOT entered any system event for more than
--   30 days. "Entering the system" = any INSERT into tbl_cylinder_state_audit
--   or tbl_yard_stock_check_line for that cylinder.
--
-- PROBLEM STATEMENT:
--   A cylinder can go dormant in several silent ways:
--     • Delivered to a customer who never returns it (no empty pickup)
--     • Parked at a supplier with no refill activity
--     • Left in a truck that is not in service
--     • Sitting in a corner of the yard that auditors miss
--     • Lost but not yet written off
--   None of these scenarios raise an automatic alert today.
--
-- DESIGN:
--   tbl_cylinder_dormancy_alert — one OPEN row per dormant cylinder.
--   A scheduled database job (or application scheduler) calls
--   fn_detect_dormant_cylinders() daily to detect new cases and auto-close
--   resolved ones.
--   The detection threshold is configurable via tbl_system_config.
--
-- NOTE — V63 PARTIAL OVERRIDE:
--   V63__SupplierTracking_And_SupplierTripLine_Trigger.sql adds
--   fk_current_supplier to tbl_cylinder_current_status and then uses
--   CREATE OR REPLACE to update:
--     • fn_detect_dormant_cylinders()  — uses fk_current_supplier directly
--     • vw_overdue_at_supplier         — uses fk_current_supplier directly
--   The versions defined here in V62 are the initial, correct implementations.
--   V63 refines them once the supplier column exists.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- SYSTEM CONFIG TABLE (if not already present)
-- Used to store operational thresholds without code changes.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tbl_system_config (
    config_key      varchar(100) NOT NULL PRIMARY KEY,
    config_value    varchar(500) NOT NULL,
    description     varchar(500),
    updated_at      timestamp    NOT NULL DEFAULT now()
);

INSERT INTO public.tbl_system_config (config_key, config_value, description)
VALUES
    ('DORMANCY_THRESHOLD_DAYS',     '30',  'Days without any activity before a cylinder is flagged dormant'),
    ('OVERDUE_CUSTOMER_DAYS',       '90',  'Days a cylinder can stay at a customer before flagged overdue'),
    ('OVERDUE_SUPPLIER_DAYS',       '14',  'Days a cylinder can stay at a supplier before flagged overdue'),
    ('TRIP_RETURN_THRESHOLD_HOURS', '12',  'Hours after departure before a non-returned trip is escalated')
ON CONFLICT (config_key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- SEQUENCE
-- ---------------------------------------------------------------------------
DROP SEQUENCE IF EXISTS public.pk_cylinder_dormancy_alert_id_serial;
CREATE SEQUENCE public.pk_cylinder_dormancy_alert_id_serial
    INCREMENT BY 1 MINVALUE 1 START 1 CACHE 1 NO CYCLE;

-- ---------------------------------------------------------------------------
-- TABLE
-- ---------------------------------------------------------------------------
CREATE TABLE public.tbl_cylinder_dormancy_alert (
    pk_alert_id             int8         NOT NULL DEFAULT nextval('public.pk_cylinder_dormancy_alert_id_serial'),
    fk_cylinder             int8         NOT NULL,

    -- When was this cylinder last seen in any event?
    last_seen_at            timestamp    NOT NULL,

    -- How many days have passed since last_seen_at (at the time of alert creation)
    dormancy_days           int4         NOT NULL,

    -- What state does the system think this cylinder is in?
    last_known_state        varchar(100) NOT NULL,
    last_known_location     varchar(100),

    -- Who or what holds it (if applicable)?
    -- last_known_customer_id: from tbl_cylinder_current_status.fk_current_holder_customer
    -- last_known_supplier_id: resolved via fk_last_supplier_trip → tbl_supplier_trip.fk_supplier
    --                         (V63 refines this to use the direct fk_current_supplier column)
    -- last_known_vehicle_id:  reserved for future vehicle-level tracking
    last_known_customer_id  int8         NULL,
    last_known_supplier_id  int8         NULL,
    last_known_vehicle_id   int8         NULL,

    -- Alert lifecycle:
    --   OPEN          – cylinder is dormant, no action taken
    --   INVESTIGATING – someone has picked this up for investigation
    --   RESOLVED      – cylinder has re-entered the system or been written off
    alert_status            varchar(50)  NOT NULL DEFAULT 'OPEN',

    raised_at               timestamp    NOT NULL DEFAULT now(),
    resolved_at             timestamp,
    resolution_remarks      varchar(500),
    assigned_to             varchar(200),

    CONSTRAINT tbl_dormancy_alert_pk
        PRIMARY KEY (pk_alert_id),

    -- Only one OPEN alert per cylinder at a time
    CONSTRAINT tbl_dormancy_alert_cylinder_open_unique
        UNIQUE (fk_cylinder, alert_status),

    CONSTRAINT tbl_dormancy_alert_cylinder_fk
        FOREIGN KEY (fk_cylinder)
        REFERENCES public.tbl_cylinder(pk_cylinder_id),

    CONSTRAINT tbl_dormancy_alert_status_chk
        CHECK (alert_status IN ('OPEN', 'INVESTIGATING', 'RESOLVED')),

    CONSTRAINT tbl_dormancy_alert_customer_fk
        FOREIGN KEY (last_known_customer_id)
        REFERENCES public.tbl_customer(pk_customer_id),

    CONSTRAINT tbl_dormancy_alert_supplier_fk
        FOREIGN KEY (last_known_supplier_id)
        REFERENCES public.tbl_supplier(pk_supplier_id)
);

CREATE INDEX idx_dormancy_alert_cylinder ON public.tbl_cylinder_dormancy_alert(fk_cylinder);
CREATE INDEX idx_dormancy_alert_status   ON public.tbl_cylinder_dormancy_alert(alert_status)
    WHERE alert_status IN ('OPEN', 'INVESTIGATING');
CREATE INDEX idx_dormancy_alert_raised   ON public.tbl_cylinder_dormancy_alert(raised_at DESC);

COMMENT ON TABLE public.tbl_cylinder_dormancy_alert IS
    'One OPEN row per cylinder that has not appeared in any system event for '
    'more than DORMANCY_THRESHOLD_DAYS days. '
    'fn_detect_dormant_cylinders() is called by the application scheduler daily. '
    'last_known_supplier_id is resolved via fk_last_supplier_trip in this version; '
    'V63 replaces fn_detect_dormant_cylinders with a version that uses the direct '
    'fk_current_supplier column on tbl_cylinder_current_status.';

-- ---------------------------------------------------------------------------
-- FUNCTION: detect and raise dormancy alerts (run nightly via scheduler)
-- ---------------------------------------------------------------------------
-- NOTE: V63 replaces this function with CREATE OR REPLACE to use the direct
--       fk_current_supplier column added to tbl_cylinder_current_status in V63.
--       This V62 version resolves the supplier via fk_last_supplier_trip which
--       is available at V62 execution time.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_detect_dormant_cylinders()
RETURNS TABLE (
    cylinder_id     int8,
    cylinder_serial varchar(50),
    last_seen       timestamp,
    dormant_days    int4,
    action          varchar(20)   -- 'RAISED' | 'ALREADY_OPEN' | 'AUTO_RESOLVED'
) AS $$
DECLARE
    v_threshold_days int4;
    rec RECORD;
BEGIN
    SELECT config_value::int4 INTO v_threshold_days
    FROM public.tbl_system_config
    WHERE config_key = 'DORMANCY_THRESHOLD_DAYS';

    v_threshold_days := COALESCE(v_threshold_days, 30);

    -- ── STEP 1: AUTO-RESOLVE alerts where the cylinder has re-appeared ────────
    UPDATE public.tbl_cylinder_dormancy_alert da
    SET alert_status       = 'RESOLVED',
        resolved_at        = now(),
        resolution_remarks = 'Auto-resolved: cylinder re-entered the system'
    FROM (
        SELECT DISTINCT fk_cylinder
        FROM public.tbl_cylinder_state_audit
        WHERE changed_at >= now() - (v_threshold_days || ' days')::interval
    ) recent
    WHERE da.fk_cylinder   = recent.fk_cylinder
      AND da.alert_status IN ('OPEN', 'INVESTIGATING');

    -- ── STEP 2: FIND NEW DORMANT CYLINDERS ───────────────────────────────────
    FOR rec IN
        WITH last_activity AS (
            SELECT fk_cylinder, MAX(changed_at)  AS last_event
            FROM public.tbl_cylinder_state_audit
            GROUP BY fk_cylinder

            UNION ALL

            SELECT cl.fk_cylinder, MAX(cl.scanned_at) AS last_event
            FROM public.tbl_yard_stock_check_line cl
            GROUP BY cl.fk_cylinder
        ),
        latest_per_cylinder AS (
            SELECT fk_cylinder, MAX(last_event) AS last_seen_at
            FROM last_activity
            GROUP BY fk_cylinder
        ),
        dormant AS (
            SELECT
                c.pk_cylinder_id,
                c.cylinder_serial,
                l.last_seen_at,
                EXTRACT(DAY FROM now() - l.last_seen_at)::int4  AS dormant_days,
                ccs.fk_current_state,
                cs.cylinder_state                               AS state_name,
                cs.location                                     AS location_name,
                ccs.fk_current_holder_customer,
                -- Resolve supplier via fk_last_supplier_trip (V62 approach).
                -- V63 will replace this function to use fk_current_supplier directly.
                st.fk_supplier                                  AS current_supplier_id
            FROM latest_per_cylinder l
            JOIN public.tbl_cylinder c
                ON c.pk_cylinder_id = l.fk_cylinder
            LEFT JOIN public.tbl_cylinder_current_status ccs
                ON ccs.fk_cylinder = l.fk_cylinder
            LEFT JOIN public.tbl_cylinder_states cs
                ON cs.pk_cylinder_state_id = ccs.fk_current_state
            -- Resolve the supplier from the last supplier trip.
            -- Only meaningful when cylinder is EMPTY_DELIVERED_FOR_REFILL;
            -- for other states this will join to a trip that may be historical.
            LEFT JOIN public.tbl_supplier_trip st
                ON st.pk_supplier_trip_id = ccs.fk_last_supplier_trip
                AND cs.cylinder_state     = 'EMPTY_DELIVERED_FOR_REFILL'
            WHERE l.last_seen_at < now() - (v_threshold_days || ' days')::interval
              AND (cs.cylinder_state IS NULL
                   OR cs.cylinder_state NOT IN ('DECOMISSIONED', 'LOST', 'DAMAGED'))
        )
        SELECT * FROM dormant
    LOOP
        -- Already flagged?
        IF EXISTS (
            SELECT 1 FROM public.tbl_cylinder_dormancy_alert
            WHERE fk_cylinder  = rec.pk_cylinder_id
              AND alert_status IN ('OPEN', 'INVESTIGATING')
        ) THEN
            RETURN QUERY SELECT rec.pk_cylinder_id, rec.cylinder_serial,
                                rec.last_seen_at, rec.dormant_days,
                                'ALREADY_OPEN'::varchar(20);
        ELSE
            -- Raise new alert — last_known_supplier_id resolved via supplier trip join
            INSERT INTO public.tbl_cylinder_dormancy_alert (
                fk_cylinder,
                last_seen_at,
                dormancy_days,
                last_known_state,
                last_known_location,
                last_known_customer_id,
                last_known_supplier_id
            ) VALUES (
                rec.pk_cylinder_id,
                rec.last_seen_at,
                rec.dormant_days,
                COALESCE(rec.state_name,      'UNKNOWN'),
                COALESCE(rec.location_name,   'UNKNOWN'),
                rec.fk_current_holder_customer,
                rec.current_supplier_id        -- NULL for non-supplier states
            );

            -- Auto-transition to MISSING if not already in a terminal/tracking state
            IF rec.state_name NOT IN ('MISSING', 'LOST', 'DECOMISSIONED') THEN
                INSERT INTO public.tbl_cylinder_state_audit (
                    pk_audit_id, fk_cylinder, fk_previous_state, fk_new_state,
                    changed_at, remarks
                )
                SELECT
                    nextval('public.pk_cylinder_state_id_serial'),
                    rec.pk_cylinder_id,
                    ccs.fk_current_state,
                    (SELECT pk_cylinder_state_id
                     FROM public.tbl_cylinder_states
                     WHERE cylinder_state = 'MISSING'),
                    now(),
                    'Auto-flagged MISSING after '
                        || rec.dormant_days
                        || ' days without any system activity.'
                FROM public.tbl_cylinder_current_status ccs
                WHERE ccs.fk_cylinder = rec.pk_cylinder_id;
            END IF;

            RETURN QUERY SELECT rec.pk_cylinder_id, rec.cylinder_serial,
                                rec.last_seen_at, rec.dormant_days,
                                'RAISED'::varchar(20);
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.fn_detect_dormant_cylinders() IS
    'Idempotent nightly function. Detects cylinders with no event in > DORMANCY_THRESHOLD_DAYS days. '
    'V62 version: resolves last_known_supplier_id via fk_last_supplier_trip join. '
    'V63 replaces this with a version using the direct fk_current_supplier column.';

-- ---------------------------------------------------------------------------
-- VIEW: cylinders overdue at customer
-- (unchanged from original — no supplier dependency)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.vw_overdue_at_customer AS
SELECT
    c.pk_cylinder_id,
    c.cylinder_serial,
    cs.cylinder_state,
    cust.pk_customer_id,
    cust.customer_name,
    -- tbl_customer_address is a link table (fk_customer, fk_address, fk_address_type).
    -- Address text lives in tbl_address via ca.fk_address.
    CONCAT_WS(', ', a.address_line_1, a.address_line_2)  AS delivery_address,
    ccs.updated_at                                      AS delivered_at,
    EXTRACT(DAY FROM now() - ccs.updated_at)::int       AS days_at_customer,
    (SELECT config_value::int
     FROM public.tbl_system_config
     WHERE config_key = 'OVERDUE_CUSTOMER_DAYS')        AS threshold_days,
    o.pk_order_id                                       AS last_order_id
FROM public.tbl_cylinder_current_status ccs
JOIN public.tbl_cylinder c         ON c.pk_cylinder_id         = ccs.fk_cylinder
JOIN public.tbl_cylinder_states cs ON cs.pk_cylinder_state_id  = ccs.fk_current_state
JOIN public.tbl_customer cust      ON cust.pk_customer_id       = ccs.fk_current_holder_customer
LEFT JOIN public.tbl_customer_address ca
    ON ca.pk_customer_address_id = ccs.fk_current_customer_address
LEFT JOIN public.tbl_address a
    ON a.pk_address_id = ca.fk_address
LEFT JOIN public.tbl_order o       ON o.pk_order_id             = ccs.fk_last_order
WHERE cs.cylinder_state = 'DELIVERED_FOR_CONSUMPTION'
  AND ccs.updated_at < now() - (
        (SELECT config_value
         FROM public.tbl_system_config
         WHERE config_key = 'OVERDUE_CUSTOMER_DAYS')
        || ' days'
      )::interval
ORDER BY days_at_customer DESC;

COMMENT ON VIEW public.vw_overdue_at_customer IS
    'Cylinders that have been with a customer longer than OVERDUE_CUSTOMER_DAYS. '
    'These are candidates for collection follow-up and deposit reconciliation.';

-- ---------------------------------------------------------------------------
-- VIEW: cylinders overdue at supplier
-- V62 version — joins via fk_last_supplier_trip.
-- V63 replaces this view with a version using the direct fk_current_supplier column.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.vw_overdue_at_supplier AS
SELECT
    c.pk_cylinder_id,
    c.cylinder_serial,
    cs.cylinder_state,
    s.pk_supplier_id,
    s.supplier_name,
    ccs.updated_at                                      AS delivered_to_supplier_at,
    EXTRACT(DAY FROM now() - ccs.updated_at)::int       AS days_at_supplier,
    (SELECT config_value::int
     FROM public.tbl_system_config
     WHERE config_key = 'OVERDUE_SUPPLIER_DAYS')        AS threshold_days
FROM public.tbl_cylinder_current_status ccs
JOIN public.tbl_cylinder c         ON c.pk_cylinder_id        = ccs.fk_cylinder
JOIN public.tbl_cylinder_states cs ON cs.pk_cylinder_state_id = ccs.fk_current_state
-- V62: resolve supplier through fk_last_supplier_trip (indirect)
JOIN public.tbl_supplier_trip st   ON st.pk_supplier_trip_id  = ccs.fk_last_supplier_trip
JOIN public.tbl_supplier s         ON s.pk_supplier_id         = st.fk_supplier
WHERE cs.cylinder_state = 'EMPTY_DELIVERED_FOR_REFILL'
  AND ccs.updated_at < now() - (
        (SELECT config_value
         FROM public.tbl_system_config
         WHERE config_key = 'OVERDUE_SUPPLIER_DAYS')
        || ' days'
      )::interval
ORDER BY days_at_supplier DESC;

COMMENT ON VIEW public.vw_overdue_at_supplier IS
    'V62 version: joins via fk_last_supplier_trip → tbl_supplier_trip → tbl_supplier. '
    'V63 replaces this with a direct join on fk_current_supplier. '
    'Cylinders left with a supplier longer than OVERDUE_SUPPLIER_DAYS.';