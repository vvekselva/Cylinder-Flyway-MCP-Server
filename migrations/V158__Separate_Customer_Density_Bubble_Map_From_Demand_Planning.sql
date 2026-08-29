-- =============================================================================
-- V158 — Separate Customer Density Bubble Map From Demand Planning Bubble Map
-- =============================================================================
-- The delivery-planning dashboard must keep its existing demand-planning bubble map.
-- Customer population density is a separate visualization and must not replace the
-- demand density view used by /delivery-planning/dashboard.
--
-- This migration restores public.vw_customer_delivery_planning_density_bucket to
-- demand-only density and adds public.vw_customer_population_density_bucket for
-- the separate customer-density bubble page.
-- =============================================================================

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

COMMENT ON VIEW public.vw_customer_delivery_planning_density_bucket IS 'Grid-bucket demand density view for delivery planning bubble map. This view intentionally includes only active demand rows.';

CREATE OR REPLACE VIEW public.vw_customer_population_density_bucket AS
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
), demand_by_address AS (
    SELECT
        d.customer_id,
        d.customer_address_id,
        SUM(CASE WHEN d.demand_signal_type = 'DETERMINISTIC' THEN d.demand_score ELSE 0 END)::BIGINT AS deterministic_demand_score,
        SUM(CASE WHEN d.demand_signal_type = 'NON_DETERMINISTIC' THEN d.demand_score ELSE 0 END)::BIGINT AS forecast_demand_score,
        SUM(COALESCE(d.demand_score, 0))::BIGINT AS total_demand_score
    FROM public.vw_customer_delivery_planning_signal d
    GROUP BY d.customer_id, d.customer_address_id
), location_with_optional_demand AS (
    SELECT
        loc.customer_id,
        loc.customer_name,
        loc.customer_address_id,
        loc.address_text,
        loc.latitude,
        loc.longitude,
        COALESCE(d.deterministic_demand_score, 0)::BIGINT AS deterministic_demand_score,
        COALESCE(d.forecast_demand_score, 0)::BIGINT AS forecast_demand_score,
        COALESCE(d.total_demand_score, 0)::BIGINT AS total_demand_score
    FROM active_locations loc
    LEFT JOIN demand_by_address d
      ON d.customer_id = loc.customer_id
     AND d.customer_address_id = loc.customer_address_id
)
SELECT
    ROUND(latitude::numeric, 3) AS latitude_bucket,
    ROUND(longitude::numeric, 3) AS longitude_bucket,
    ROUND(AVG(latitude)::numeric, 7) AS latitude,
    ROUND(AVG(longitude)::numeric, 7) AS longitude,
    COUNT(DISTINCT customer_address_id)::BIGINT AS customer_count,
    SUM(deterministic_demand_score)::BIGINT AS deterministic_demand_score,
    SUM(forecast_demand_score)::BIGINT AS forecast_demand_score,
    SUM(total_demand_score)::BIGINT AS total_demand_score,
    CASE
        WHEN SUM(total_demand_score) = 0 THEN 'POPULATION_ONLY'
        WHEN SUM(deterministic_demand_score) >= SUM(forecast_demand_score) THEN 'DETERMINISTIC_DOMINANT'
        ELSE 'FORECAST_DOMINANT'
    END AS dominant_signal_type
FROM location_with_optional_demand
GROUP BY ROUND(latitude::numeric, 3), ROUND(longitude::numeric, 3);

COMMENT ON VIEW public.vw_customer_population_density_bucket IS 'Grid-bucket customer population density view. Includes all active geocoded customer addresses and optionally includes demand score for context.';
