-- Customer demand / demand capture enhancements.
-- Base table exists from V39__CustomerOrderRequest.sql and is currently empty.
-- This migration keeps tbl_customer_order_request as the demand table and adds fields
-- required for same-day/planned delivery tracking and metrics.

ALTER TABLE public.tbl_customer_order_request
    ADD COLUMN IF NOT EXISTS request_type varchar(30) NULL,
    ADD COLUMN IF NOT EXISTS requested_at timestamp NOT NULL DEFAULT now(),
    ADD COLUMN IF NOT EXISTS required_delivery_date date NULL,
    ADD COLUMN IF NOT EXISTS delivered_at timestamp NULL,
    ADD COLUMN IF NOT EXISTS delivery_duration_minutes int8 NULL,
    ADD COLUMN IF NOT EXISTS cancelled_at timestamp NULL,
    ADD COLUMN IF NOT EXISTS cancellation_reason varchar(500) NULL;

-- Existing V39 column requested_date is treated as the delivery-required date.
UPDATE public.tbl_customer_order_request
SET required_delivery_date = requested_date
WHERE required_delivery_date IS NULL;

UPDATE public.tbl_customer_order_request
SET request_type = CASE
    WHEN requested_date = CURRENT_DATE THEN 'SAME_DAY'
    ELSE 'PLANNED'
END
WHERE request_type IS NULL;

ALTER TABLE public.tbl_customer_order_request
    ALTER COLUMN required_delivery_date SET NOT NULL,
    ALTER COLUMN request_type SET NOT NULL;

ALTER TABLE public.tbl_customer_order_request
    DROP CONSTRAINT IF EXISTS chk_customer_demand_status;

ALTER TABLE public.tbl_customer_order_request
    ADD CONSTRAINT chk_customer_demand_status
    CHECK (request_status IN ('PENDING', 'PLANNED', 'SCHEDULED', 'ORDER_CREATED', 'DELIVERED', 'CANCELLED'));

ALTER TABLE public.tbl_customer_order_request
    DROP CONSTRAINT IF EXISTS chk_customer_demand_type;

ALTER TABLE public.tbl_customer_order_request
    ADD CONSTRAINT chk_customer_demand_type
    CHECK (request_type IN ('SAME_DAY', 'PLANNED'));

CREATE INDEX IF NOT EXISTS idx_customer_demand_requested_at
    ON public.tbl_customer_order_request (requested_at);

CREATE INDEX IF NOT EXISTS idx_customer_demand_required_delivery_date
    ON public.tbl_customer_order_request (required_delivery_date);

CREATE INDEX IF NOT EXISTS idx_customer_demand_status
    ON public.tbl_customer_order_request (request_status);

CREATE INDEX IF NOT EXISTS idx_customer_demand_customer
    ON public.tbl_customer_order_request (fk_customer);

CREATE INDEX IF NOT EXISTS idx_customer_demand_product
    ON public.tbl_customer_order_request (fk_product);

-- Dashboard list view with customer/product/address display names.
CREATE OR REPLACE VIEW public.vw_customer_demand_dashboard AS
SELECT
    cor.pk_customer_order_request_id AS customer_demand_id,
    cor.request_number,
    cor.fk_customer AS customer_id,
    c.customer_name,
    cor.fk_delivery_address AS customer_address_id,
    trim(concat_ws(', ', a.address_line_1, a.address_line_2, a.address_line_3, a.landmark)) AS delivery_address_text,
    cor.fk_product AS product_id,
    p.product_name,
    cor.requested_cylinders,
    cor.requested_at,
    cor.requested_date,
    cor.required_delivery_date,
    cor.request_type,
    cor.request_status,
    cor.fk_order AS order_id,
    o.challan_number,
    o.challan_date,
    cor.delivered_at,
    cor.delivery_duration_minutes,
    cor.received_by,
    cor.remarks,
    cor.created_at,
    cor.updated_at
FROM public.tbl_customer_order_request cor
JOIN public.tbl_customer c ON c.pk_customer_id = cor.fk_customer
JOIN public.tbl_product p ON p.pk_product_id = cor.fk_product
LEFT JOIN public.tbl_customer_address ca ON ca.pk_customer_address_id = cor.fk_delivery_address
LEFT JOIN public.tbl_address a ON a.pk_address_id = ca.fk_address
LEFT JOIN public.tbl_order o ON o.pk_order_id = cor.fk_order;

-- Product-wise daily metrics view.
CREATE OR REPLACE VIEW public.vw_customer_demand_daily_product_metrics AS
SELECT
    p.pk_product_id AS product_id,
    p.product_name,
    COUNT(*) FILTER (WHERE cor.requested_at::date = CURRENT_DATE) AS orders_requested_today,
    COALESCE(SUM(cor.requested_cylinders) FILTER (WHERE cor.requested_at::date = CURRENT_DATE), 0) AS cylinders_requested_today,
    COUNT(*) FILTER (WHERE cor.delivered_at::date = CURRENT_DATE OR cor.request_status = 'DELIVERED' AND cor.updated_at::date = CURRENT_DATE) AS orders_delivered_today,
    COALESCE(SUM(cor.requested_cylinders) FILTER (WHERE cor.delivered_at::date = CURRENT_DATE OR cor.request_status = 'DELIVERED' AND cor.updated_at::date = CURRENT_DATE), 0) AS cylinders_delivered_today,
    CAST(ROUND(AVG(cor.delivery_duration_minutes) FILTER (WHERE cor.delivery_duration_minutes IS NOT NULL), 0) AS BIGINT) AS avg_delivery_duration_minutes
FROM public.tbl_product p
LEFT JOIN public.tbl_customer_order_request cor ON cor.fk_product = p.pk_product_id
GROUP BY p.pk_product_id, p.product_name;
