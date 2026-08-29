

-- =============================================================================
-- V46c — tbl_vehicle_load_purpose  (Lookup)
-- =============================================================================
-- Three purposes cover every direction a cylinder can travel on a vehicle.
-- =============================================================================

--CREATE TABLE public.tbl_vehicle_load_purpose (
--    pk_load_purpose_id  int8         NOT NULL,
--    load_purpose        varchar(100) NOT NULL,
--    description         varchar(500) NOT NULL,
--    CONSTRAINT tbl_vehicle_load_purpose_pk     PRIMARY KEY (pk_load_purpose_id),
--    CONSTRAINT tbl_vehicle_load_purpose_unique UNIQUE      (load_purpose)
--);
--
--DROP SEQUENCE IF EXISTS public.pk_load_purpose_id_serial;
--CREATE SEQUENCE public.pk_load_purpose_id_serial
--    INCREMENT BY 1 MINVALUE 1 START 1 CACHE 1 NO CYCLE;
--
--INSERT INTO public.tbl_vehicle_load_purpose (pk_load_purpose_id, load_purpose, description)
--VALUES
--    (nextval('public.pk_load_purpose_id_serial'), 'FULL_FOR_DELIVERY',
--        'Full cylinder loaded at yard for delivery to customer stop'),
--    (nextval('public.pk_load_purpose_id_serial'), 'EMPTY_FOR_SUPPLIER',
--        'Empty cylinder from yard loaded for dropoff at supplier for refill'),
--    (nextval('public.pk_load_purpose_id_serial'), 'EMPTY_RETURNED_TO_YARD',
--        'Empty cylinder collected from customer, on vehicle returning to yard for verification');