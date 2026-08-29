-- Reusable predefined delivery trips composed of existing delivery-planning stops.
CREATE SEQUENCE IF NOT EXISTS public.pk_predefined_delivery_trip_id_serial START WITH 1 INCREMENT BY 1;
CREATE SEQUENCE IF NOT EXISTS public.pk_predefined_delivery_trip_stop_id_serial START WITH 1 INCREMENT BY 1;

CREATE TABLE IF NOT EXISTS public.tbl_predefined_delivery_trip (
    pk_predefined_delivery_trip_id bigint PRIMARY KEY DEFAULT nextval('public.pk_predefined_delivery_trip_id_serial'),
    trip_name varchar(200) NOT NULL,
    description varchar(1000),
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamp without time zone NOT NULL DEFAULT now(),
    updated_at timestamp without time zone
);

CREATE TABLE IF NOT EXISTS public.tbl_predefined_delivery_trip_stop (
    pk_predefined_delivery_trip_stop_id bigint PRIMARY KEY DEFAULT nextval('public.pk_predefined_delivery_trip_stop_id_serial'),
    fk_predefined_delivery_trip bigint NOT NULL REFERENCES public.tbl_predefined_delivery_trip(pk_predefined_delivery_trip_id),
    fk_delivery_planning_stop bigint NOT NULL REFERENCES public.tbl_delivery_planning_stop(pk_delivery_planning_stop_id),
    stop_sequence integer NOT NULL,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamp without time zone NOT NULL DEFAULT now(),
    updated_at timestamp without time zone,
    CONSTRAINT ck_predefined_trip_stop_sequence CHECK (stop_sequence > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uk_predefined_delivery_trip_active_name ON public.tbl_predefined_delivery_trip(lower(trip_name)) WHERE is_active=true;
CREATE UNIQUE INDEX IF NOT EXISTS uk_predefined_trip_active_stop ON public.tbl_predefined_delivery_trip_stop(fk_predefined_delivery_trip,fk_delivery_planning_stop) WHERE is_active=true;
CREATE UNIQUE INDEX IF NOT EXISTS uk_predefined_trip_active_sequence ON public.tbl_predefined_delivery_trip_stop(fk_predefined_delivery_trip,stop_sequence) WHERE is_active=true;
CREATE INDEX IF NOT EXISTS idx_predefined_trip_stop_trip ON public.tbl_predefined_delivery_trip_stop(fk_predefined_delivery_trip, stop_sequence);
COMMENT ON TABLE public.tbl_predefined_delivery_trip IS 'Reusable route definition used for comparing current customer demand and empty-pickup signals before creating an operational vehicle trip.';
COMMENT ON TABLE public.tbl_predefined_delivery_trip_stop IS 'Ordered reusable delivery-planning stops assigned to a predefined trip.';
