-- Testing-only delivery-consumption fixtures used by the migration application.
-- Production application code never inserts rows here.
CREATE TABLE IF NOT EXISTS public.tbl_customer_test_delivery_consumption_fixture (
    pk_test_delivery_consumption_fixture_id bigserial PRIMARY KEY,
    fk_customer bigint NOT NULL REFERENCES public.tbl_customer(pk_customer_id),
    fk_product bigint NOT NULL REFERENCES public.tbl_product(pk_product_id),
    previous_delivered_at timestamp NOT NULL,
    last_delivered_at timestamp NOT NULL,
    previous_delivered_cylinder_count bigint NOT NULL,
    last_delivered_cylinder_count bigint NOT NULL,
    current_cylinder_count bigint NOT NULL,
    consumption_days_per_cylinder numeric(14,4) NOT NULL,
    expected_need_at timestamp NOT NULL,
    target_window varchar(30) NOT NULL,
    generated_by varchar(200) NOT NULL,
    generated_at timestamp NOT NULL DEFAULT now(),
    CONSTRAINT uq_test_delivery_consumption_fixture UNIQUE (fk_customer, fk_product)
);

CREATE OR REPLACE VIEW public.vw_customer_product_delivery_consumption AS
WITH real_delivery AS (
    WITH delivery_events AS (
        SELECT cpc.fk_customer AS customer_id, cust.customer_name,
               cyl.fk_product AS product_id, p.product_name,
               DATE_TRUNC('day', cpc.entered_at)::timestamp AS delivered_at,
               COUNT(*)::bigint AS delivered_cylinder_count
        FROM public.tbl_cylinder_party_custody cpc
        JOIN public.tbl_cylinder cyl ON cyl.pk_cylinder_id=cpc.fk_cylinder
        JOIN public.tbl_product p ON p.pk_product_id=cyl.fk_product
        JOIN public.tbl_customer cust ON cust.pk_customer_id=cpc.fk_customer
        WHERE cpc.party_type='CUSTOMER' AND cpc.entered_at IS NOT NULL
        GROUP BY cpc.fk_customer,cust.customer_name,cyl.fk_product,p.product_name,DATE_TRUNC('day',cpc.entered_at)
    ), ordered_delivery AS (
        SELECT de.*,
               LAG(de.delivered_at) OVER(PARTITION BY customer_id,product_id ORDER BY delivered_at) previous_delivered_at,
               LAG(de.delivered_cylinder_count) OVER(PARTITION BY customer_id,product_id ORDER BY delivered_at) previous_delivered_cylinder_count,
               ROW_NUMBER() OVER(PARTITION BY customer_id,product_id ORDER BY delivered_at DESC) latest_rank
        FROM delivery_events de
    ), active_holding AS (
        SELECT cpc.fk_customer customer_id,cyl.fk_product product_id,COUNT(*)::bigint current_cylinder_count
        FROM public.tbl_cylinder_party_custody cpc JOIN public.tbl_cylinder cyl ON cyl.pk_cylinder_id=cpc.fk_cylinder
        WHERE cpc.party_type='CUSTOMER' AND cpc.custody_status='ACTIVE'
        GROUP BY cpc.fk_customer,cyl.fk_product
    )
    SELECT od.customer_id,od.customer_name,od.product_id,od.product_name,
           od.previous_delivered_at,od.delivered_at last_delivered_at,
           od.delivered_cylinder_count last_delivered_cylinder_count,
           COALESCE(od.previous_delivered_cylinder_count,0)::bigint previous_delivered_cylinder_count,
           COALESCE(ah.current_cylinder_count,0)::bigint current_cylinder_count,
           CASE WHEN od.previous_delivered_at IS NULL OR COALESCE(od.previous_delivered_cylinder_count,0)<=0 THEN 0::numeric
                ELSE ROUND((EXTRACT(EPOCH FROM (od.delivered_at-od.previous_delivered_at))/86400.0)::numeric/od.previous_delivered_cylinder_count::numeric,2) END consumption_days_per_cylinder
    FROM ordered_delivery od LEFT JOIN active_holding ah ON ah.customer_id=od.customer_id AND ah.product_id=od.product_id
    WHERE od.latest_rank=1
), fixture AS (
    SELECT f.fk_customer customer_id,c.customer_name,f.fk_product product_id,p.product_name,
           f.previous_delivered_at,f.last_delivered_at,f.last_delivered_cylinder_count,
           f.previous_delivered_cylinder_count,f.current_cylinder_count,
           f.consumption_days_per_cylinder,f.expected_need_at
    FROM public.tbl_customer_test_delivery_consumption_fixture f
    JOIN public.tbl_customer c ON c.pk_customer_id=f.fk_customer
    JOIN public.tbl_product p ON p.pk_product_id=f.fk_product
)
SELECT f.customer_id,f.customer_name,f.product_id,f.product_name,f.previous_delivered_at,f.last_delivered_at,
       f.last_delivered_cylinder_count,f.previous_delivered_cylinder_count,f.current_cylinder_count,
       f.consumption_days_per_cylinder,f.expected_need_at
FROM fixture f
UNION ALL
SELECT r.customer_id,r.customer_name,r.product_id,r.product_name,r.previous_delivered_at,r.last_delivered_at,
       r.last_delivered_cylinder_count,r.previous_delivered_cylinder_count,r.current_cylinder_count,
       r.consumption_days_per_cylinder,
       CASE WHEN r.consumption_days_per_cylinder<=0 THEN NULL::timestamp
            ELSE r.last_delivered_at+(r.current_cylinder_count::numeric*r.consumption_days_per_cylinder||' days')::interval END expected_need_at
FROM real_delivery r
WHERE NOT EXISTS (SELECT 1 FROM fixture f WHERE f.customer_id=r.customer_id AND f.product_id=r.product_id);
