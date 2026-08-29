-- Remove the testing fixture override introduced by V169.
-- Test and live consumption rates must use the same delivery-history calculation.

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
)
SELECT
    od.customer_id,
    od.customer_name,
    od.product_id,
    od.product_name,
    od.previous_delivered_at,
    od.delivered_at AS last_delivered_at,
    od.delivered_cylinder_count AS last_delivered_cylinder_count,
    COALESCE(od.previous_delivered_cylinder_count, 0)::bigint AS previous_delivered_cylinder_count,
    COALESCE(ah.current_cylinder_count, 0)::bigint AS current_cylinder_count,
    CASE
        WHEN od.previous_delivered_at IS NULL
          OR COALESCE(od.previous_delivered_cylinder_count, 0) <= 0
            THEN 0::numeric
        ELSE ROUND(
            (EXTRACT(EPOCH FROM (od.delivered_at - od.previous_delivered_at)) / 86400.0)::numeric
            / od.previous_delivered_cylinder_count::numeric,
            2
        )
    END AS consumption_days_per_cylinder,
    CASE
        WHEN od.previous_delivered_at IS NULL
          OR COALESCE(od.previous_delivered_cylinder_count, 0) <= 0
            THEN NULL::timestamp
        ELSE od.delivered_at + (
            GREATEST(COALESCE(ah.current_cylinder_count, 0), 1)::numeric
            * ROUND(
                (EXTRACT(EPOCH FROM (od.delivered_at - od.previous_delivered_at)) / 86400.0)::numeric
                / od.previous_delivered_cylinder_count::numeric,
                2
              )
            || ' days'
        )::interval
    END AS expected_need_at
FROM ordered_delivery od
LEFT JOIN active_holding ah
  ON ah.customer_id = od.customer_id
 AND ah.product_id = od.product_id
WHERE od.latest_rank = 1;

DROP TABLE IF EXISTS public.tbl_customer_test_delivery_consumption_fixture;

COMMENT ON VIEW public.vw_customer_product_delivery_consumption IS
'One row per customer/product. Test and live values both use delivery recurrence from tbl_cylinder_party_custody; no fixture override is used.';
