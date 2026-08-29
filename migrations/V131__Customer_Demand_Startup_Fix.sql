-- Fixes Customer Demand / tbl_customer_order_request columns used by DAO metrics and planned delivery search.

ALTER TABLE public.tbl_customer_order_request
    ADD COLUMN IF NOT EXISTS required_delivery_date DATE,
    ADD COLUMN IF NOT EXISTS requested_at TIMESTAMP,
    ADD COLUMN IF NOT EXISTS delivered_at TIMESTAMP,
    ADD COLUMN IF NOT EXISTS delivery_duration_minutes BIGINT;

UPDATE public.tbl_customer_order_request
SET requested_at = COALESCE(requested_at, created_at, requested_date::timestamp, NOW()),
    required_delivery_date = COALESCE(required_delivery_date, requested_date, CURRENT_DATE)
WHERE requested_at IS NULL
   OR required_delivery_date IS NULL;

ALTER TABLE public.tbl_customer_order_request
    ALTER COLUMN requested_at SET NOT NULL,
    ALTER COLUMN required_delivery_date SET NOT NULL;

UPDATE public.tbl_customer_order_request
SET delivery_duration_minutes = EXTRACT(EPOCH FROM (delivered_at - requested_at))::BIGINT / 60
WHERE delivered_at IS NOT NULL
  AND requested_at IS NOT NULL
  AND delivery_duration_minutes IS NULL;

CREATE INDEX IF NOT EXISTS idx_customer_order_request_required_delivery_date
    ON public.tbl_customer_order_request(required_delivery_date);

CREATE INDEX IF NOT EXISTS idx_customer_order_request_requested_at
    ON public.tbl_customer_order_request(requested_at);

CREATE INDEX IF NOT EXISTS idx_customer_order_request_delivered_at
    ON public.tbl_customer_order_request(delivered_at);
