-- ============================================================================
-- V168__Simplify_Customer_Consumption_To_Delivery_Based_Need.sql
-- ============================================================================
-- Purpose
--   Simplify the customer consumption dashboard to one row per customer/product.
--
-- New business rule
--   - Consumption is calculated only from delivery recurrence.
--   - First delivery has a consumption rate of 0 days per cylinder.
--   - From the second delivery onward:
--       consumption_days_per_cylinder =
--           days_between_previous_delivery_and_latest_delivery
--           / previous_delivery_cylinder_count
--   - Expected need date is calculated as:
--       latest_delivery_date + (current_active_cylinder_count * consumption_days_per_cylinder)
--
-- Notes
--   The existing public.vw_customer_product_consumption_projection view name is
--   kept for Java and delivery-planning compatibility. Extra analytical columns
--   are returned as NULL or compatibility aliases, but the dashboard uses only:
--       customer, product, latest delivery, active holding,
--       consumption days/cylinder, expected need date.
-- ============================================================================

CREATE OR REPLACE VIEW public.vw_customer_product_delivery_consumption AS
WITH delivery_events AS (
    SELECT
        cpc.fk_customer AS customer_id,
        cust.customer_name,
        cyl.fk_product AS product_id,
        p.product_name,
        DATE_TRUNC('day', cpc.entered_at)::timestamp AS delivered_at,
        COUNT(*)::bigint AS delivered_cylinder_count
    FROM public.tbl_cylinder_party_custody cpc
    JOIN public.tbl_cylinder cyl
      ON cyl.pk_cylinder_id = cpc.fk_cylinder
    JOIN public.tbl_product p
      ON p.pk_product_id = cyl.fk_product
    JOIN public.tbl_customer cust
      ON cust.pk_customer_id = cpc.fk_customer
    WHERE cpc.party_type = 'CUSTOMER'
      AND cpc.entered_at IS NOT NULL
    GROUP BY
        cpc.fk_customer,
        cust.customer_name,
        cyl.fk_product,
        p.product_name,
        DATE_TRUNC('day', cpc.entered_at)
), ordered_delivery AS (
    SELECT
        de.*,
        LAG(de.delivered_at) OVER (
            PARTITION BY de.customer_id, de.product_id
            ORDER BY de.delivered_at
        ) AS previous_delivered_at,
        LAG(de.delivered_cylinder_count) OVER (
            PARTITION BY de.customer_id, de.product_id
            ORDER BY de.delivered_at
        ) AS previous_delivered_cylinder_count,
        ROW_NUMBER() OVER (
            PARTITION BY de.customer_id, de.product_id
            ORDER BY de.delivered_at DESC
        ) AS latest_rank
    FROM delivery_events de
), latest_delivery AS (
    SELECT *
    FROM ordered_delivery
    WHERE latest_rank = 1
), active_holding AS (
    SELECT
        cpc.fk_customer AS customer_id,
        cyl.fk_product AS product_id,
        COUNT(*)::bigint AS current_cylinder_count
    FROM public.tbl_cylinder_party_custody cpc
    JOIN public.tbl_cylinder cyl
      ON cyl.pk_cylinder_id = cpc.fk_cylinder
    WHERE cpc.party_type = 'CUSTOMER'
      AND cpc.custody_status = 'ACTIVE'
    GROUP BY cpc.fk_customer, cyl.fk_product
), calculated AS (
    SELECT
        ld.customer_id,
        ld.customer_name,
        ld.product_id,
        ld.product_name,
        ld.previous_delivered_at,
        ld.delivered_at AS last_delivered_at,
        ld.delivered_cylinder_count AS last_delivered_cylinder_count,
        COALESCE(ld.previous_delivered_cylinder_count, 0)::bigint AS previous_delivered_cylinder_count,
        COALESCE(ah.current_cylinder_count, 0)::bigint AS current_cylinder_count,
        CASE
            WHEN ld.previous_delivered_at IS NULL THEN 0::numeric
            WHEN COALESCE(ld.previous_delivered_cylinder_count, 0) <= 0 THEN 0::numeric
            ELSE ROUND(
                (
                    EXTRACT(EPOCH FROM (ld.delivered_at - ld.previous_delivered_at))
                    / 86400.0
                )::numeric / ld.previous_delivered_cylinder_count::numeric,
                2
            )
        END AS consumption_days_per_cylinder
    FROM latest_delivery ld
    LEFT JOIN active_holding ah
      ON ah.customer_id = ld.customer_id
     AND ah.product_id = ld.product_id
)
SELECT
    c.customer_id,
    c.customer_name,
    c.product_id,
    c.product_name,
    c.previous_delivered_at,
    c.last_delivered_at,
    c.last_delivered_cylinder_count,
    c.previous_delivered_cylinder_count,
    c.current_cylinder_count,
    c.consumption_days_per_cylinder,
    CASE
        WHEN c.consumption_days_per_cylinder <= 0 THEN NULL::timestamp
        ELSE c.last_delivered_at + (GREATEST(c.current_cylinder_count, 1)::numeric * c.consumption_days_per_cylinder || ' days')::interval
    END AS expected_need_at
FROM calculated c;

CREATE OR REPLACE VIEW public.vw_customer_product_consumption_projection AS
SELECT
    d.customer_id,
    d.customer_name,
    NULL::bigint AS customer_address_id,
    d.product_id,
    d.product_name,
    d.current_cylinder_count AS active_holding_cylinders,
    d.previous_delivered_at AS oldest_delivered_at,
    d.last_delivered_at AS latest_delivered_at,
    NULL::text AS active_cylinder_serials,
    CASE
        WHEN d.previous_delivered_at IS NULL THEN 0::bigint
        ELSE d.previous_delivered_cylinder_count
    END AS closed_sample_count,
    d.consumption_days_per_cylinder AS avg_consumption_days_per_cylinder,
    NULL::numeric AS median_consumption_days_per_cylinder,
    NULL::numeric AS cylinders_consumed_per_day,
    NULL::numeric AS cylinders_consumed_per_week,
    NULL::numeric AS cylinders_consumed_per_month,
    NULL::varchar AS forecast_confidence,
    CASE
        WHEN d.expected_need_at IS NULL THEN NULL::numeric
        ELSE ROUND(EXTRACT(EPOCH FROM (d.expected_need_at - now()))::numeric / 86400.0, 2)
    END AS projected_days_remaining,
    d.expected_need_at::timestamptz AS projected_empty_at,
    CASE
        WHEN d.previous_delivered_at IS NULL THEN 'FIRST_DELIVERY'
        WHEN d.expected_need_at IS NOT NULL AND d.expected_need_at::date <= CURRENT_DATE THEN 'NEED_NOW'
        ELSE 'NORMAL'
    END::varchar AS projection_status
FROM public.vw_customer_product_delivery_consumption d;

COMMENT ON VIEW public.vw_customer_product_delivery_consumption IS
'One row per customer/product. Consumption rate is based only on delivery recurrence, not empty pickup history.';

COMMENT ON VIEW public.vw_customer_product_consumption_projection IS
'Simplified compatibility view for customer consumption. Dashboard uses latest delivery, active cylinders, days/cylinder, and expected need date.';
