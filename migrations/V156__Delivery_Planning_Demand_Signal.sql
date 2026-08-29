-- =============================================================================
-- V156 — Delivery Planning Demand Signal Foundation
-- =============================================================================
-- Separates deterministic demand signals from non-deterministic forecast signals
-- for map-driven delivery planning. Customer and yard points remain database
-- driven; MBTiles are replaceable filesystem map assets only.
-- =============================================================================

CREATE SEQUENCE IF NOT EXISTS public.pk_customer_phone_stock_verification_id_serial START WITH 1 INCREMENT BY 1;
CREATE SEQUENCE IF NOT EXISTS public.pk_delivery_planning_session_id_serial START WITH 1 INCREMENT BY 1;
CREATE SEQUENCE IF NOT EXISTS public.pk_delivery_planning_session_customer_id_serial START WITH 1 INCREMENT BY 1;

CREATE TABLE IF NOT EXISTS public.tbl_customer_phone_stock_verification (
    pk_customer_phone_stock_verification_id BIGINT PRIMARY KEY DEFAULT nextval('public.pk_customer_phone_stock_verification_id_serial'),
    fk_customer BIGINT NOT NULL,
    fk_customer_address BIGINT,
    fk_product BIGINT NOT NULL,
    empty_cylinder_count INTEGER NOT NULL DEFAULT 0,
    full_cylinder_count INTEGER NOT NULL DEFAULT 0,
    verified_by_employee_name VARCHAR(200),
    verified_by_mobile_number VARCHAR(30),
    verified_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT now(),
    verification_status VARCHAR(40) NOT NULL DEFAULT 'VERIFIED',
    remarks VARCHAR(500),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT now(),
    updated_at TIMESTAMP WITHOUT TIME ZONE,
    CONSTRAINT fk_phone_stock_verification_customer FOREIGN KEY (fk_customer) REFERENCES public.tbl_customer(pk_customer_id),
    CONSTRAINT fk_phone_stock_verification_address FOREIGN KEY (fk_customer_address) REFERENCES public.tbl_customer_address(pk_customer_address_id),
    CONSTRAINT fk_phone_stock_verification_product FOREIGN KEY (fk_product) REFERENCES public.tbl_product(pk_product_id),
    CONSTRAINT chk_phone_stock_verification_status CHECK (verification_status IN ('VERIFIED','UNREACHABLE','CUSTOMER_NOT_SURE','REJECTED','SUPERSEDED')),
    CONSTRAINT chk_phone_stock_verification_empty_count CHECK (empty_cylinder_count >= 0),
    CONSTRAINT chk_phone_stock_verification_full_count CHECK (full_cylinder_count >= 0)
);

CREATE INDEX IF NOT EXISTS idx_phone_stock_verification_customer
ON public.tbl_customer_phone_stock_verification(fk_customer, fk_customer_address, fk_product, verified_at DESC)
WHERE is_active = TRUE;

CREATE TABLE IF NOT EXISTS public.tbl_delivery_planning_session (
    pk_delivery_planning_session_id BIGINT PRIMARY KEY DEFAULT nextval('public.pk_delivery_planning_session_id_serial'),
    planning_name VARCHAR(200) NOT NULL,
    center_latitude NUMERIC(10,7),
    center_longitude NUMERIC(10,7),
    radius_meters NUMERIC(12,2),
    created_by VARCHAR(200),
    planning_status VARCHAR(40) NOT NULL DEFAULT 'DRAFT',
    remarks VARCHAR(500),
    created_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT now(),
    updated_at TIMESTAMP WITHOUT TIME ZONE,
    CONSTRAINT chk_delivery_planning_session_status CHECK (planning_status IN ('DRAFT','CONFIRMED','TRIP_CREATED','CANCELLED')),
    CONSTRAINT chk_delivery_planning_session_latitude CHECK (center_latitude IS NULL OR center_latitude BETWEEN -90 AND 90),
    CONSTRAINT chk_delivery_planning_session_longitude CHECK (center_longitude IS NULL OR center_longitude BETWEEN -180 AND 180),
    CONSTRAINT chk_delivery_planning_session_radius CHECK (radius_meters IS NULL OR radius_meters >= 0)
);

CREATE TABLE IF NOT EXISTS public.tbl_delivery_planning_session_customer (
    pk_delivery_planning_session_customer_id BIGINT PRIMARY KEY DEFAULT nextval('public.pk_delivery_planning_session_customer_id_serial'),
    fk_delivery_planning_session BIGINT NOT NULL,
    fk_customer BIGINT NOT NULL,
    fk_customer_address BIGINT,
    fk_product BIGINT,
    selected_cylinder_count INTEGER NOT NULL DEFAULT 0,
    selection_reason VARCHAR(500),
    demand_category VARCHAR(60),
    is_selected BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT now(),
    updated_at TIMESTAMP WITHOUT TIME ZONE,
    CONSTRAINT fk_delivery_planning_session_customer_session FOREIGN KEY (fk_delivery_planning_session) REFERENCES public.tbl_delivery_planning_session(pk_delivery_planning_session_id),
    CONSTRAINT fk_delivery_planning_session_customer_customer FOREIGN KEY (fk_customer) REFERENCES public.tbl_customer(pk_customer_id),
    CONSTRAINT fk_delivery_planning_session_customer_address FOREIGN KEY (fk_customer_address) REFERENCES public.tbl_customer_address(pk_customer_address_id),
    CONSTRAINT fk_delivery_planning_session_customer_product FOREIGN KEY (fk_product) REFERENCES public.tbl_product(pk_product_id),
    CONSTRAINT chk_delivery_planning_selected_count CHECK (selected_cylinder_count >= 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_delivery_planning_session_customer_active
ON public.tbl_delivery_planning_session_customer(fk_delivery_planning_session, fk_customer, COALESCE(fk_customer_address, -1), COALESCE(fk_product, -1));

-- -----------------------------------------------------------------------------
-- Unified customer-level delivery planning signal.
-- Deterministic signals: customer order request, phone verification, spot check.
-- Non-deterministic signals: consumption forecast due today/this week/next week.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.vw_customer_delivery_planning_signal AS
WITH active_locations AS (
    SELECT
        s.customer_id,
        s.customer_name,
        s.customer_address_id,
        s.address_text,
        s.latitude,
        s.longitude
    FROM public.vw_customer_address_location_status s
    WHERE s.location_missing = FALSE
      AND s.latitude IS NOT NULL
      AND s.longitude IS NOT NULL
), order_signal AS (
    SELECT
        r.fk_customer AS customer_id,
        r.fk_delivery_address AS customer_address_id,
        r.fk_product AS product_id,
        COUNT(1) AS order_request_count,
        COALESCE(SUM(r.requested_cylinders), 0) AS order_requested_cylinder_count,
        MIN(r.required_delivery_date) AS earliest_required_delivery_date,
        MAX(r.requested_at) AS latest_order_requested_at
    FROM public.tbl_customer_order_request r
    WHERE r.delivered_at IS NULL
      AND UPPER(COALESCE(r.request_status, 'PENDING')) NOT IN ('DELIVERED','CLOSED','CANCELLED','CANCELED','REJECTED')
    GROUP BY r.fk_customer, r.fk_delivery_address, r.fk_product
), phone_signal AS (
    SELECT
        v.fk_customer AS customer_id,
        v.fk_customer_address AS customer_address_id,
        v.fk_product AS product_id,
        COALESCE(SUM(v.empty_cylinder_count), 0) AS phone_verified_empty_count,
        COALESCE(SUM(v.full_cylinder_count), 0) AS phone_verified_full_count,
        MAX(v.verified_at) AS phone_verified_at
    FROM public.tbl_customer_phone_stock_verification v
    WHERE v.is_active = TRUE
      AND v.verification_status = 'VERIFIED'
    GROUP BY v.fk_customer, v.fk_customer_address, v.fk_product
), spot_signal AS (
    SELECT
        h.fk_customer AS customer_id,
        h.fk_customer_address AS customer_address_id,
        c.fk_product AS product_id,
        COUNT(*) FILTER (WHERE UPPER(l.observed_condition) = 'EMPTY') AS spot_check_empty_count,
        COUNT(*) FILTER (WHERE UPPER(l.observed_condition) = 'FULL') AS spot_check_full_count,
        MAX(h.checked_at) AS spot_checked_at
    FROM public.tbl_customer_spot_cylinder_check h
    JOIN public.tbl_customer_spot_cylinder_check_line l ON l.fk_customer_spot_check = h.pk_customer_spot_check_id
    LEFT JOIN public.tbl_cylinder c ON c.pk_cylinder_id = l.fk_matched_cylinder
    WHERE h.entry_status = 'SUBMITTED'
      AND h.fk_customer_address IS NOT NULL
      AND c.fk_product IS NOT NULL
    GROUP BY h.fk_customer, h.fk_customer_address, c.fk_product
), forecast_signal AS (
    SELECT
        p.customer_id,
        p.customer_address_id,
        p.product_id,
        p.active_holding_cylinders,
        p.closed_sample_count,
        p.avg_consumption_days_per_cylinder,
        p.projected_days_remaining,
        p.projected_empty_at,
        p.projection_status,
        p.forecast_confidence,
        CASE
            WHEN p.projected_empty_at IS NULL THEN NULL
            WHEN p.projected_empty_at::date <= CURRENT_DATE THEN 'TODAY'
            WHEN p.projected_empty_at::date <= CURRENT_DATE + 7 THEN 'THIS_WEEK'
            WHEN p.projected_empty_at::date <= CURRENT_DATE + 14 THEN 'NEXT_WEEK'
            ELSE 'LATER'
        END AS forecast_window
    FROM public.vw_customer_product_consumption_projection p
    WHERE p.customer_address_id IS NOT NULL
), demand_keys AS (
    SELECT customer_id, customer_address_id, product_id FROM order_signal
    UNION
    SELECT customer_id, customer_address_id, product_id FROM phone_signal
    UNION
    SELECT customer_id, customer_address_id, product_id FROM spot_signal
    UNION
    SELECT customer_id, customer_address_id, product_id FROM forecast_signal WHERE forecast_window IN ('TODAY','THIS_WEEK','NEXT_WEEK')
)
SELECT
    dk.customer_id,
    loc.customer_name,
    dk.customer_address_id,
    loc.address_text,
    dk.product_id,
    prod.product_name,
    loc.latitude,
    loc.longitude,

    COALESCE(ord.order_request_count, 0)::BIGINT AS order_request_count,
    COALESCE(ord.order_requested_cylinder_count, 0)::BIGINT AS order_requested_cylinder_count,
    ord.earliest_required_delivery_date,
    ord.latest_order_requested_at,

    COALESCE(ph.phone_verified_empty_count, 0)::BIGINT AS phone_verified_empty_count,
    COALESCE(ph.phone_verified_full_count, 0)::BIGINT AS phone_verified_full_count,
    ph.phone_verified_at,

    COALESCE(sp.spot_check_empty_count, 0)::BIGINT AS spot_check_empty_count,
    COALESCE(sp.spot_check_full_count, 0)::BIGINT AS spot_check_full_count,
    sp.spot_checked_at,

    COALESCE(fc.active_holding_cylinders, 0)::BIGINT AS active_holding_cylinders,
    fc.closed_sample_count,
    fc.avg_consumption_days_per_cylinder,
    fc.projected_days_remaining,
    fc.projected_empty_at,
    fc.projection_status,
    fc.forecast_confidence,
    fc.forecast_window,

    CASE
        WHEN COALESCE(sp.spot_check_empty_count, 0) > 0 THEN 'SPOT_CHECK_CONFIRMED'
        WHEN COALESCE(ord.order_requested_cylinder_count, 0) > 0 THEN 'ORDER_REQUEST_CONFIRMED'
        WHEN COALESCE(ph.phone_verified_empty_count, 0) > 0 THEN 'PHONE_VERIFIED_CONFIRMED'
        WHEN fc.forecast_window = 'TODAY' THEN 'FORECAST_TODAY'
        WHEN fc.forecast_window = 'THIS_WEEK' THEN 'FORECAST_THIS_WEEK'
        WHEN fc.forecast_window = 'NEXT_WEEK' THEN 'FORECAST_NEXT_WEEK'
        ELSE 'NO_DEMAND'
    END AS demand_category,
    CASE
        WHEN COALESCE(sp.spot_check_empty_count, 0) > 0 OR COALESCE(ord.order_requested_cylinder_count, 0) > 0 OR COALESCE(ph.phone_verified_empty_count, 0) > 0 THEN 'DETERMINISTIC'
        WHEN fc.forecast_window IN ('TODAY','THIS_WEEK','NEXT_WEEK') THEN 'NON_DETERMINISTIC'
        ELSE 'NONE'
    END AS demand_signal_type,
    CASE
        WHEN COALESCE(sp.spot_check_empty_count, 0) > 0 THEN '#7f1d1d'
        WHEN COALESCE(ord.order_requested_cylinder_count, 0) > 0 THEN '#dc2626'
        WHEN COALESCE(ph.phone_verified_empty_count, 0) > 0 THEN '#7c3aed'
        WHEN fc.forecast_window = 'TODAY' THEN '#f97316'
        WHEN fc.forecast_window = 'THIS_WEEK' THEN '#f59e0b'
        WHEN fc.forecast_window = 'NEXT_WEEK' THEN '#eab308'
        ELSE '#16a34a'
    END AS marker_color,
    CASE
        WHEN COALESCE(sp.spot_check_empty_count, 0) > 0 THEN 1
        WHEN COALESCE(ord.order_requested_cylinder_count, 0) > 0 THEN 2
        WHEN COALESCE(ph.phone_verified_empty_count, 0) > 0 THEN 3
        WHEN fc.forecast_window = 'TODAY' THEN 4
        WHEN fc.forecast_window = 'THIS_WEEK' THEN 5
        WHEN fc.forecast_window = 'NEXT_WEEK' THEN 6
        ELSE 99
    END AS priority_rank,
    (
        COALESCE(sp.spot_check_empty_count, 0) * 5
        + COALESCE(ord.order_requested_cylinder_count, 0) * 4
        + COALESCE(ph.phone_verified_empty_count, 0) * 3
        + CASE fc.forecast_window WHEN 'TODAY' THEN 3 WHEN 'THIS_WEEK' THEN 2 WHEN 'NEXT_WEEK' THEN 1 ELSE 0 END
    )::BIGINT AS demand_score
FROM demand_keys dk
JOIN active_locations loc ON loc.customer_id = dk.customer_id AND loc.customer_address_id = dk.customer_address_id
LEFT JOIN public.tbl_product prod ON prod.pk_product_id = dk.product_id
LEFT JOIN order_signal ord ON ord.customer_id = dk.customer_id AND ord.customer_address_id IS NOT DISTINCT FROM dk.customer_address_id AND ord.product_id IS NOT DISTINCT FROM dk.product_id
LEFT JOIN phone_signal ph ON ph.customer_id = dk.customer_id AND ph.customer_address_id IS NOT DISTINCT FROM dk.customer_address_id AND ph.product_id IS NOT DISTINCT FROM dk.product_id
LEFT JOIN spot_signal sp ON sp.customer_id = dk.customer_id AND sp.customer_address_id IS NOT DISTINCT FROM dk.customer_address_id AND sp.product_id IS NOT DISTINCT FROM dk.product_id
LEFT JOIN forecast_signal fc ON fc.customer_id = dk.customer_id AND fc.customer_address_id IS NOT DISTINCT FROM dk.customer_address_id AND fc.product_id IS NOT DISTINCT FROM dk.product_id;

CREATE OR REPLACE VIEW public.vw_customer_delivery_planning_density_bucket AS
SELECT
    ROUND(latitude::numeric, 3) AS latitude_bucket,
    ROUND(longitude::numeric, 3) AS longitude_bucket,
    ROUND(AVG(latitude)::numeric, 7) AS latitude,
    ROUND(AVG(longitude)::numeric, 7) AS longitude,
    COUNT(DISTINCT customer_address_id)::BIGINT AS customer_count,
    SUM(CASE WHEN demand_signal_type = 'DETERMINISTIC' THEN demand_score ELSE 0 END)::BIGINT AS deterministic_demand_score,
    SUM(CASE WHEN demand_signal_type = 'NON_DETERMINISTIC' THEN demand_score ELSE 0 END)::BIGINT AS forecast_demand_score,
    SUM(demand_score)::BIGINT AS total_demand_score,
    CASE
        WHEN SUM(CASE WHEN demand_signal_type = 'DETERMINISTIC' THEN demand_score ELSE 0 END) >= SUM(CASE WHEN demand_signal_type = 'NON_DETERMINISTIC' THEN demand_score ELSE 0 END) THEN 'DETERMINISTIC_DOMINANT'
        ELSE 'FORECAST_DOMINANT'
    END AS dominant_signal_type
FROM public.vw_customer_delivery_planning_signal
WHERE demand_category <> 'NO_DEMAND'
GROUP BY ROUND(latitude::numeric, 3), ROUND(longitude::numeric, 3);

COMMENT ON VIEW public.vw_customer_delivery_planning_signal IS 'Unified customer delivery planning demand signals combining deterministic demand and non-deterministic consumption forecast demand.';
COMMENT ON VIEW public.vw_customer_delivery_planning_density_bucket IS 'Grid-bucket demand density view for delivery planning bubble map.';
