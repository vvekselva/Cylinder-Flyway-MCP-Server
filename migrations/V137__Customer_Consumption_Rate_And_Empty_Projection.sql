-- ============================================================================
-- V137__Customer_Consumption_Rate_And_Empty_Projection.sql
-- ============================================================================
-- Purpose
--   Add customer/product consumption intelligence using the authoritative
--   serialized custody table.
--
-- Business meaning
--   1. A CUSTOMER custody row is opened when a full cylinder is delivered to a
--      customer.
--   2. The same custody row is closed when the empty cylinder is picked up.
--   3. Closed rows become the historical consumption sample.
--   4. ACTIVE customer custody rows become the current customer holding.
--   5. Forecast = current active holding / historical consumption rate.
--
-- Notes
--   - This intentionally does not use tbl_customer_order_request as the source
--     for consumption. Demand request is planned/requested demand; custody is
--     actual serialized consumption history.
--   - Legacy holding rows can appear as ACTIVE holdings, but they do not produce
--     consumption rate until they are closed through empty pickup/correction.
-- ============================================================================

DROP VIEW IF EXISTS public.vw_customer_product_consumption_projection CASCADE;
DROP VIEW IF EXISTS public.vw_customer_active_cylinder_empty_projection CASCADE;
DROP VIEW IF EXISTS public.vw_customer_product_active_holding CASCADE;
DROP VIEW IF EXISTS public.vw_customer_product_consumption_rate CASCADE;
DROP VIEW IF EXISTS public.vw_customer_cylinder_consumption_history CASCADE;

-- ----------------------------------------------------------------------------
-- 1. Serial-level historical consumption samples.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.vw_customer_cylinder_consumption_history AS
SELECT
    cpc.pk_custody_id AS custody_id,
    cpc.fk_customer AS customer_id,
    cust.customer_name,
    cpc.fk_customer_address AS customer_address_id,
    cyl.pk_cylinder_id AS cylinder_id,
    cyl.cylinder_serial,
    p.pk_product_id AS product_id,
    p.product_name,
    cpc.fk_entry_order AS entry_order_id,
    o.challan_number AS entry_challan_number,
    cpc.fk_exit_empty_pickup AS exit_empty_pickup_id,
    cpc.entered_at AS delivered_at,
    cpc.exited_at AS emptied_or_picked_up_at,
    EXTRACT(EPOCH FROM (cpc.exited_at - cpc.entered_at)) / 86400.0 AS consumption_days,
    EXTRACT(EPOCH FROM (cpc.exited_at - cpc.entered_at)) / 3600.0 AS consumption_hours,
    cpc.entry_event_type,
    cpc.exit_event_type
FROM public.tbl_cylinder_party_custody cpc
JOIN public.tbl_cylinder cyl
  ON cyl.pk_cylinder_id = cpc.fk_cylinder
JOIN public.tbl_product p
  ON p.pk_product_id = cyl.fk_product
JOIN public.tbl_customer cust
  ON cust.pk_customer_id = cpc.fk_customer
LEFT JOIN public.tbl_order o
  ON o.pk_order_id = cpc.fk_entry_order
WHERE cpc.party_type = 'CUSTOMER'
  AND cpc.custody_status = 'CLOSED'
  AND cpc.entered_at IS NOT NULL
  AND cpc.exited_at IS NOT NULL
  AND cpc.exited_at > cpc.entered_at;

-- ----------------------------------------------------------------------------
-- 2. Customer/product rate derived from closed custody history.
--    avg_consumption_days_per_cylinder answers: how long one delivered cylinder
--    usually remains at the customer before empty pickup.
--    cylinders_consumed_per_day answers: how fast this customer consumes this gas.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.vw_customer_product_consumption_rate AS
WITH base AS (
    SELECT
        h.customer_id,
        h.customer_name,
        h.product_id,
        h.product_name,
        COUNT(*)::bigint AS closed_sample_count,
        MIN(h.delivered_at) AS first_delivery_at,
        MAX(h.emptied_or_picked_up_at) AS last_empty_pickup_at,
        AVG(h.consumption_days) AS avg_consumption_days_per_cylinder,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY h.consumption_days) AS median_consumption_days_per_cylinder,
        MIN(h.consumption_days) AS min_consumption_days_per_cylinder,
        MAX(h.consumption_days) AS max_consumption_days_per_cylinder
    FROM public.vw_customer_cylinder_consumption_history h
    GROUP BY h.customer_id, h.customer_name, h.product_id, h.product_name
), rate AS (
    SELECT
        b.*,
        GREATEST(EXTRACT(EPOCH FROM (b.last_empty_pickup_at - b.first_delivery_at)) / 86400.0, 1.0) AS observed_window_days
    FROM base b
)
SELECT
    r.customer_id,
    r.customer_name,
    r.product_id,
    r.product_name,
    r.closed_sample_count,
    r.first_delivery_at,
    r.last_empty_pickup_at,
    ROUND(r.avg_consumption_days_per_cylinder::numeric, 2) AS avg_consumption_days_per_cylinder,
    ROUND(r.median_consumption_days_per_cylinder::numeric, 2) AS median_consumption_days_per_cylinder,
    ROUND(r.min_consumption_days_per_cylinder::numeric, 2) AS min_consumption_days_per_cylinder,
    ROUND(r.max_consumption_days_per_cylinder::numeric, 2) AS max_consumption_days_per_cylinder,
    ROUND(r.observed_window_days::numeric, 2) AS observed_window_days,
    ROUND((r.closed_sample_count::numeric / r.observed_window_days::numeric), 4) AS cylinders_consumed_per_day,
    ROUND((r.closed_sample_count::numeric / r.observed_window_days::numeric) * 7.0, 2) AS cylinders_consumed_per_week,
    ROUND((r.closed_sample_count::numeric / r.observed_window_days::numeric) * 30.0, 2) AS cylinders_consumed_per_month,
    CASE
        WHEN r.closed_sample_count >= 10 THEN 'HIGH'
        WHEN r.closed_sample_count >= 3 THEN 'MEDIUM'
        ELSE 'LOW'
    END::varchar AS forecast_confidence
FROM rate r;

-- ----------------------------------------------------------------------------
-- 3. Current active customer holding by customer/product.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.vw_customer_product_active_holding AS
SELECT
    cpc.fk_customer AS customer_id,
    cust.customer_name,
    cpc.fk_customer_address AS customer_address_id,
    cyl.fk_product AS product_id,
    p.product_name,
    COUNT(*)::bigint AS active_holding_cylinders,
    MIN(cpc.entered_at) AS oldest_delivered_at,
    MAX(cpc.entered_at) AS latest_delivered_at,
    STRING_AGG(cyl.cylinder_serial, ', ' ORDER BY cpc.entered_at, cyl.cylinder_serial) AS active_cylinder_serials
FROM public.tbl_cylinder_party_custody cpc
JOIN public.tbl_cylinder cyl
  ON cyl.pk_cylinder_id = cpc.fk_cylinder
JOIN public.tbl_product p
  ON p.pk_product_id = cyl.fk_product
JOIN public.tbl_customer cust
  ON cust.pk_customer_id = cpc.fk_customer
WHERE cpc.party_type = 'CUSTOMER'
  AND cpc.custody_status = 'ACTIVE'
GROUP BY cpc.fk_customer, cust.customer_name, cpc.fk_customer_address, cyl.fk_product, p.product_name;

-- ----------------------------------------------------------------------------
-- 4. Customer/product forecast.
--    projected_empty_at estimates when the CURRENT holding for that product
--    will be consumed, based on historical consumption speed.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.vw_customer_product_consumption_projection AS
SELECT
    ah.customer_id,
    ah.customer_name,
    ah.customer_address_id,
    ah.product_id,
    ah.product_name,
    ah.active_holding_cylinders,
    ah.oldest_delivered_at,
    ah.latest_delivered_at,
    ah.active_cylinder_serials,
    cr.closed_sample_count,
    cr.avg_consumption_days_per_cylinder,
    cr.median_consumption_days_per_cylinder,
    cr.cylinders_consumed_per_day,
    cr.cylinders_consumed_per_week,
    cr.cylinders_consumed_per_month,
    cr.forecast_confidence,
    CASE
        WHEN cr.cylinders_consumed_per_day IS NULL OR cr.cylinders_consumed_per_day <= 0 THEN NULL
        ELSE ROUND((ah.active_holding_cylinders::numeric / cr.cylinders_consumed_per_day), 2)
    END AS projected_days_remaining,
    CASE
        WHEN cr.cylinders_consumed_per_day IS NULL OR cr.cylinders_consumed_per_day <= 0 THEN NULL
        ELSE now() + ((ah.active_holding_cylinders::numeric / cr.cylinders_consumed_per_day) || ' days')::interval
    END AS projected_empty_at,
    CASE
        WHEN cr.closed_sample_count IS NULL THEN 'NO_HISTORY'
        WHEN cr.closed_sample_count < 3 THEN 'INSUFFICIENT_HISTORY'
        WHEN cr.cylinders_consumed_per_day IS NULL OR cr.cylinders_consumed_per_day <= 0 THEN 'NO_RATE'
        WHEN now() + ((ah.active_holding_cylinders::numeric / cr.cylinders_consumed_per_day) || ' days')::interval <= now() + interval '2 days' THEN 'URGENT'
        WHEN now() + ((ah.active_holding_cylinders::numeric / cr.cylinders_consumed_per_day) || ' days')::interval <= now() + interval '7 days' THEN 'DUE_SOON'
        ELSE 'NORMAL'
    END::varchar AS projection_status
FROM public.vw_customer_product_active_holding ah
LEFT JOIN public.vw_customer_product_consumption_rate cr
  ON cr.customer_id = ah.customer_id
 AND cr.product_id = ah.product_id;

-- ----------------------------------------------------------------------------
-- 5. Optional serial-level projection for currently held cylinders.
--    projected_cylinder_empty_at estimates the likely empty date for each
--    individual active custody row using avg days per delivered cylinder.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.vw_customer_active_cylinder_empty_projection AS
SELECT
    cpc.pk_custody_id AS custody_id,
    cpc.fk_customer AS customer_id,
    cust.customer_name,
    cpc.fk_customer_address AS customer_address_id,
    cyl.pk_cylinder_id AS cylinder_id,
    cyl.cylinder_serial,
    p.pk_product_id AS product_id,
    p.product_name,
    cpc.entered_at AS delivered_at,
    cr.closed_sample_count,
    cr.avg_consumption_days_per_cylinder,
    cr.cylinders_consumed_per_day,
    cr.forecast_confidence,
    CASE
        WHEN cr.avg_consumption_days_per_cylinder IS NULL THEN NULL
        ELSE cpc.entered_at + (cr.avg_consumption_days_per_cylinder || ' days')::interval
    END AS projected_cylinder_empty_at,
    CASE
        WHEN cr.avg_consumption_days_per_cylinder IS NULL THEN NULL
        ELSE ROUND(EXTRACT(EPOCH FROM ((cpc.entered_at + (cr.avg_consumption_days_per_cylinder || ' days')::interval) - now()))::numeric / 86400.0, 2)
    END AS projected_cylinder_days_remaining,
    CASE
        WHEN cr.closed_sample_count IS NULL THEN 'NO_HISTORY'
        WHEN cr.closed_sample_count < 3 THEN 'INSUFFICIENT_HISTORY'
        WHEN cpc.entered_at + (cr.avg_consumption_days_per_cylinder || ' days')::interval <= now() THEN 'LIKELY_EMPTY'
        WHEN cpc.entered_at + (cr.avg_consumption_days_per_cylinder || ' days')::interval <= now() + interval '2 days' THEN 'URGENT'
        WHEN cpc.entered_at + (cr.avg_consumption_days_per_cylinder || ' days')::interval <= now() + interval '7 days' THEN 'DUE_SOON'
        ELSE 'NORMAL'
    END::varchar AS projection_status
FROM public.tbl_cylinder_party_custody cpc
JOIN public.tbl_cylinder cyl
  ON cyl.pk_cylinder_id = cpc.fk_cylinder
JOIN public.tbl_product p
  ON p.pk_product_id = cyl.fk_product
JOIN public.tbl_customer cust
  ON cust.pk_customer_id = cpc.fk_customer
LEFT JOIN public.vw_customer_product_consumption_rate cr
  ON cr.customer_id = cpc.fk_customer
 AND cr.product_id = cyl.fk_product
WHERE cpc.party_type = 'CUSTOMER'
  AND cpc.custody_status = 'ACTIVE';

-- ----------------------------------------------------------------------------
-- 6. Indexes supporting the above views.
-- ----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_cpc_customer_status_product_lookup
ON public.tbl_cylinder_party_custody(fk_customer, custody_status, entered_at, exited_at)
WHERE party_type = 'CUSTOMER';

CREATE INDEX IF NOT EXISTS idx_cpc_customer_active_lookup
ON public.tbl_cylinder_party_custody(fk_customer, entered_at)
WHERE party_type = 'CUSTOMER'
  AND custody_status = 'ACTIVE';

CREATE INDEX IF NOT EXISTS idx_cylinder_product_lookup
ON public.tbl_cylinder(fk_product, pk_cylinder_id);

COMMENT ON VIEW public.vw_customer_cylinder_consumption_history IS
'Closed CUSTOMER custody rows used as serial-level consumption samples: delivery to empty pickup duration.';

COMMENT ON VIEW public.vw_customer_product_consumption_rate IS
'Customer/product consumption rate calculated from closed custody history.';

COMMENT ON VIEW public.vw_customer_product_active_holding IS
'Current ACTIVE customer custody grouped by customer/product.';

COMMENT ON VIEW public.vw_customer_product_consumption_projection IS
'Forecast of when current customer/product holding will become empty based on historical consumption rate.';

COMMENT ON VIEW public.vw_customer_active_cylinder_empty_projection IS
'Serial-level forecast of likely empty date for each currently held customer cylinder.';
