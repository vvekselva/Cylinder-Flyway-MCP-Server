-- V165 — Align forecast confirmation with the latest customer delivery
--
-- Demand planning is quantity based. Forecast is a non-deterministic signal.
-- Phone verification, customer order request and submitted customer spot check
-- are deterministic confirmations. No confidence weighting or score multiplication
-- is used. Existing score-named columns are retained for application compatibility,
-- but now contain cylinder quantities.

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
    SELECT DISTINCT ON (v.fk_customer, v.fk_customer_address, v.fk_product)
        v.fk_customer AS customer_id,
        v.fk_customer_address AS customer_address_id,
        v.fk_product AS product_id,
        COALESCE(v.empty_cylinder_count, 0) AS phone_verified_empty_count,
        COALESCE(v.full_cylinder_count, 0) AS phone_verified_full_count,
        v.created_at AS phone_verified_at
    FROM public.tbl_customer_phone_stock_verification v
    WHERE v.is_active = TRUE
    ORDER BY v.fk_customer, v.fk_customer_address, v.fk_product, v.created_at DESC, v.pk_customer_phone_stock_verification_id DESC
), spot_observation AS (
    SELECT
        h.pk_customer_spot_check_id,
        h.fk_customer AS customer_id,
        h.fk_customer_address AS customer_address_id,
        c.fk_product AS product_id,
        COUNT(*) FILTER (WHERE UPPER(l.observed_condition) = 'EMPTY') AS spot_check_empty_count,
        COUNT(*) FILTER (WHERE UPPER(l.observed_condition) = 'FULL') AS spot_check_full_count,
        h.checked_at AS spot_checked_at
    FROM public.tbl_customer_spot_cylinder_check h
    JOIN public.tbl_customer_spot_cylinder_check_line l ON l.fk_customer_spot_check = h.pk_customer_spot_check_id
    LEFT JOIN public.tbl_cylinder c ON c.pk_cylinder_id = l.fk_matched_cylinder
    WHERE h.entry_status = 'SUBMITTED'
      AND h.fk_customer_address IS NOT NULL
      AND c.fk_product IS NOT NULL
    GROUP BY h.pk_customer_spot_check_id, h.fk_customer, h.fk_customer_address, c.fk_product, h.checked_at
), spot_signal AS (
    SELECT DISTINCT ON (customer_id, customer_address_id, product_id)
        customer_id, customer_address_id, product_id,
        spot_check_empty_count, spot_check_full_count, spot_checked_at
    FROM spot_observation
    ORDER BY customer_id, customer_address_id, product_id, spot_checked_at DESC, pk_customer_spot_check_id DESC
), forecast_signal AS (
    SELECT
        p.customer_id,
        p.customer_address_id,
        p.product_id,
        p.active_holding_cylinders,
        p.latest_delivered_at,
        p.closed_sample_count,
        p.avg_consumption_days_per_cylinder,
        p.projected_days_remaining,
        p.projected_empty_at,
        p.projection_status,
        p.forecast_confidence,
        CASE
            WHEN p.projected_empty_at IS NULL THEN NULL
            WHEN p.projected_empty_at::date <= CURRENT_DATE THEN 'TODAY'
            WHEN p.projected_empty_at::date = CURRENT_DATE + 1 THEN 'TOMORROW'
            WHEN p.projected_empty_at::date <= (date_trunc('week', CURRENT_DATE)::date + 6) THEN 'THIS_WEEK'
            WHEN p.projected_empty_at::date <= (date_trunc('week', CURRENT_DATE)::date + 13) THEN 'NEXT_WEEK'
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
    SELECT customer_id, customer_address_id, product_id FROM forecast_signal WHERE forecast_window IN ('TODAY','TOMORROW','THIS_WEEK','NEXT_WEEK')
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

    GREATEST(
        CASE WHEN sp.spot_checked_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR sp.spot_checked_at >= fc.latest_delivered_at) THEN COALESCE(sp.spot_check_empty_count, 0) ELSE 0 END,
        CASE WHEN ph.phone_verified_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR ph.phone_verified_at >= fc.latest_delivered_at) THEN COALESCE(ph.phone_verified_empty_count, 0) ELSE 0 END,
        CASE WHEN ord.latest_order_requested_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR ord.latest_order_requested_at >= fc.latest_delivered_at) THEN COALESCE(ord.order_requested_cylinder_count, 0) ELSE 0 END
    )::BIGINT AS deterministic_demand_score,
    CASE
        WHEN fc.forecast_window IN ('TODAY','TOMORROW','THIS_WEEK','NEXT_WEEK')
         AND NOT (
            (ph.phone_verified_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR ph.phone_verified_at >= fc.latest_delivered_at))
            OR (sp.spot_checked_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR sp.spot_checked_at >= fc.latest_delivered_at))
            OR (ord.latest_order_requested_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR ord.latest_order_requested_at >= fc.latest_delivered_at))
         )
        THEN COALESCE(fc.active_holding_cylinders, 0)::BIGINT
        ELSE 0::BIGINT
    END AS non_deterministic_demand_score,

    CASE
        WHEN sp.spot_checked_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR sp.spot_checked_at >= fc.latest_delivered_at) THEN 'SPOT_CHECK_CONFIRMED'
        WHEN ord.latest_order_requested_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR ord.latest_order_requested_at >= fc.latest_delivered_at) THEN 'ORDER_REQUEST_CONFIRMED'
        WHEN ph.phone_verified_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR ph.phone_verified_at >= fc.latest_delivered_at) THEN 'PHONE_VERIFIED_CONFIRMED'
        WHEN fc.forecast_window = 'TODAY' THEN 'FORECAST_TODAY'
        WHEN fc.forecast_window = 'TOMORROW' THEN 'FORECAST_TOMORROW'
        WHEN fc.forecast_window = 'THIS_WEEK' THEN 'FORECAST_THIS_WEEK'
        WHEN fc.forecast_window = 'NEXT_WEEK' THEN 'FORECAST_NEXT_WEEK'
        ELSE 'NO_DEMAND'
    END AS demand_category,
    CASE
        WHEN (
            (sp.spot_checked_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR sp.spot_checked_at >= fc.latest_delivered_at))
            OR (ord.latest_order_requested_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR ord.latest_order_requested_at >= fc.latest_delivered_at))
            OR (ph.phone_verified_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR ph.phone_verified_at >= fc.latest_delivered_at))
        )
        AND fc.forecast_window IN ('TODAY','TOMORROW','THIS_WEEK','NEXT_WEEK')
            THEN 'MIXED'
        WHEN (
            (sp.spot_checked_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR sp.spot_checked_at >= fc.latest_delivered_at))
            OR (ord.latest_order_requested_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR ord.latest_order_requested_at >= fc.latest_delivered_at))
            OR (ph.phone_verified_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR ph.phone_verified_at >= fc.latest_delivered_at))
        )
            THEN 'DETERMINISTIC'
        WHEN fc.forecast_window IN ('TODAY','TOMORROW','THIS_WEEK','NEXT_WEEK')
            THEN 'NON_DETERMINISTIC'
        ELSE 'NONE'
    END AS demand_signal_type,
    CASE
        WHEN sp.spot_checked_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR sp.spot_checked_at >= fc.latest_delivered_at) THEN '#7f1d1d'
        WHEN ord.latest_order_requested_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR ord.latest_order_requested_at >= fc.latest_delivered_at) THEN '#dc2626'
        WHEN ph.phone_verified_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR ph.phone_verified_at >= fc.latest_delivered_at) THEN '#7c3aed'
        WHEN fc.forecast_window = 'TODAY' THEN '#f97316'
        WHEN fc.forecast_window = 'TOMORROW' THEN '#fb923c'
        WHEN fc.forecast_window = 'THIS_WEEK' THEN '#f59e0b'
        WHEN fc.forecast_window = 'NEXT_WEEK' THEN '#eab308'
        ELSE '#16a34a'
    END AS marker_color,
    CASE
        WHEN sp.spot_checked_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR sp.spot_checked_at >= fc.latest_delivered_at) THEN 1
        WHEN ord.latest_order_requested_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR ord.latest_order_requested_at >= fc.latest_delivered_at) THEN 2
        WHEN ph.phone_verified_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR ph.phone_verified_at >= fc.latest_delivered_at) THEN 3
        WHEN fc.forecast_window = 'TODAY' THEN 4
        WHEN fc.forecast_window = 'TOMORROW' THEN 5
        WHEN fc.forecast_window = 'THIS_WEEK' THEN 6
        WHEN fc.forecast_window = 'NEXT_WEEK' THEN 7
        ELSE 99
    END AS priority_rank,
    GREATEST(
        CASE WHEN sp.spot_checked_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR sp.spot_checked_at >= fc.latest_delivered_at) THEN COALESCE(sp.spot_check_empty_count, 0) ELSE 0 END,
        CASE WHEN ph.phone_verified_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR ph.phone_verified_at >= fc.latest_delivered_at) THEN COALESCE(ph.phone_verified_empty_count, 0) ELSE 0 END,
        CASE WHEN ord.latest_order_requested_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR ord.latest_order_requested_at >= fc.latest_delivered_at) THEN COALESCE(ord.order_requested_cylinder_count, 0) ELSE 0 END,
        CASE WHEN fc.forecast_window IN ('TODAY','TOMORROW','THIS_WEEK','NEXT_WEEK')
             THEN COALESCE(fc.active_holding_cylinders, 0) ELSE 0 END
    )::BIGINT AS demand_score,

    -- New confirmation columns are appended after every V164 column so
    -- CREATE OR REPLACE VIEW preserves the existing PostgreSQL view contract.
    fc.latest_delivered_at,
    GREATEST(ph.phone_verified_at, sp.spot_checked_at, ord.latest_order_requested_at) AS last_confirmation_at,
    CASE
        WHEN fc.forecast_window NOT IN ('TODAY','TOMORROW','THIS_WEEK','NEXT_WEEK') THEN FALSE
        WHEN (
            (ph.phone_verified_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR ph.phone_verified_at >= fc.latest_delivered_at))
            OR (sp.spot_checked_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR sp.spot_checked_at >= fc.latest_delivered_at))
            OR (ord.latest_order_requested_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR ord.latest_order_requested_at >= fc.latest_delivered_at))
        ) THEN TRUE
        ELSE FALSE
    END AS confirmation_is_current,
    CASE
        WHEN fc.forecast_window NOT IN ('TODAY','TOMORROW','THIS_WEEK','NEXT_WEEK') THEN 'NO_FORECAST'
        WHEN (
            (ph.phone_verified_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR ph.phone_verified_at >= fc.latest_delivered_at))
            OR (sp.spot_checked_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR sp.spot_checked_at >= fc.latest_delivered_at))
            OR (ord.latest_order_requested_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR ord.latest_order_requested_at >= fc.latest_delivered_at))
        ) THEN 'CONFIRMED'
        WHEN ph.phone_verified_at IS NOT NULL OR sp.spot_checked_at IS NOT NULL OR ord.latest_order_requested_at IS NOT NULL THEN 'STALE_CONFIRMATION'
        ELSE 'UNCONFIRMED'
    END AS confirmation_status,
    NULLIF(CONCAT_WS(', ',
        CASE WHEN ph.phone_verified_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR ph.phone_verified_at >= fc.latest_delivered_at) THEN 'PHONE' END,
        CASE WHEN sp.spot_checked_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR sp.spot_checked_at >= fc.latest_delivered_at) THEN 'DRIVER_SPOT_CHECK' END,
        CASE WHEN ord.latest_order_requested_at IS NOT NULL AND (fc.latest_delivered_at IS NULL OR ord.latest_order_requested_at >= fc.latest_delivered_at) THEN 'CUSTOMER_ORDER' END
    ), '') AS confirmation_source
FROM demand_keys dk
JOIN active_locations loc ON loc.customer_id = dk.customer_id AND loc.customer_address_id = dk.customer_address_id
LEFT JOIN public.tbl_product prod ON prod.pk_product_id = dk.product_id
LEFT JOIN order_signal ord ON ord.customer_id = dk.customer_id AND ord.customer_address_id IS NOT DISTINCT FROM dk.customer_address_id AND ord.product_id IS NOT DISTINCT FROM dk.product_id
LEFT JOIN phone_signal ph ON ph.customer_id = dk.customer_id AND ph.customer_address_id IS NOT DISTINCT FROM dk.customer_address_id AND ph.product_id IS NOT DISTINCT FROM dk.product_id
LEFT JOIN spot_signal sp ON sp.customer_id = dk.customer_id AND sp.customer_address_id IS NOT DISTINCT FROM dk.customer_address_id AND sp.product_id IS NOT DISTINCT FROM dk.product_id
LEFT JOIN forecast_signal fc ON fc.customer_id = dk.customer_id AND fc.customer_address_id IS NOT DISTINCT FROM dk.customer_address_id AND fc.product_id IS NOT DISTINCT FROM dk.product_id;

COMMENT ON VIEW public.vw_customer_delivery_planning_signal IS
'Unified quantity-based delivery-planning signals. Phone, customer order and driver spot observations confirm a forecast only when recorded on or after the latest delivery; older observations remain visible as stale address history.';
