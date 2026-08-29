ALTER TABLE public.tbl_delivery_planning_stop
ADD COLUMN IF NOT EXISTS default_radius_meters NUMERIC(12,2) NOT NULL DEFAULT 5000;

ALTER TABLE public.tbl_delivery_planning_stop
DROP CONSTRAINT IF EXISTS chk_delivery_planning_stop_radius;
ALTER TABLE public.tbl_delivery_planning_stop
ADD CONSTRAINT chk_delivery_planning_stop_radius CHECK (default_radius_meters > 0);

-- Ensure the promoted MAIN yard has the agreed verified default start point.
INSERT INTO public.tbl_yard_location(fk_yard,latitude,longitude,location_status,is_default_start_point,is_active)
SELECT yi.pk_yard_inventory_id,11.024387,76.981745,'VERIFIED',TRUE,TRUE
FROM public.tbl_yard_inventory yi
WHERE upper(trim(yi.yard_code))='MAIN' AND yi.is_active=TRUE
  AND NOT EXISTS (SELECT 1 FROM public.tbl_yard_location yl WHERE yl.fk_yard=yi.pk_yard_inventory_id AND yl.is_active=TRUE AND yl.is_default_start_point=TRUE);
