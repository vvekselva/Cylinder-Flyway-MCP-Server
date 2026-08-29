-- Reusable geographic stops used as planning centres on the delivery-planning dashboard.
CREATE SEQUENCE IF NOT EXISTS public.pk_delivery_planning_stop_id_serial START WITH 1 INCREMENT BY 1;
CREATE TABLE IF NOT EXISTS public.tbl_delivery_planning_stop (
  pk_delivery_planning_stop_id BIGINT PRIMARY KEY DEFAULT nextval('public.pk_delivery_planning_stop_id_serial'),
  stop_name VARCHAR(200) NOT NULL,
  latitude NUMERIC(10,7) NOT NULL,
  longitude NUMERIC(10,7) NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  remarks VARCHAR(500),
  created_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITHOUT TIME ZONE,
  CONSTRAINT chk_delivery_planning_stop_lat CHECK (latitude BETWEEN -90 AND 90),
  CONSTRAINT chk_delivery_planning_stop_lng CHECK (longitude BETWEEN -180 AND 180)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_delivery_planning_stop_name_active
ON public.tbl_delivery_planning_stop (lower(stop_name)) WHERE is_active = TRUE;
COMMENT ON TABLE public.tbl_delivery_planning_stop IS 'Reusable named coordinates used as radius centres during delivery trip planning.';
