
CREATE TABLE public.tbl_stop_type (
    pk_stop_type_id  int8         NOT NULL,
    stop_type        varchar(100) NOT NULL,
    description      varchar(500) NOT NULL,
    CONSTRAINT tbl_stop_type_pk     PRIMARY KEY (pk_stop_type_id),
    CONSTRAINT tbl_stop_type_unique UNIQUE      (stop_type)
);

DROP SEQUENCE IF EXISTS public.pk_stop_type_id_serial;
CREATE SEQUENCE public.pk_stop_type_id_serial
    INCREMENT BY 1 MINVALUE 1 START 1 CACHE 1 NO CYCLE;

INSERT INTO public.tbl_stop_type (pk_stop_type_id, stop_type, description)
VALUES
    (nextval('public.pk_stop_type_id_serial'), 'YARD_START',
        'Trip origin — vehicle loaded at yard; always stop sequence 1; never skipped'),
    (nextval('public.pk_stop_type_id_serial'), 'CUSTOMER_DELIVERY',
        'Intermediate stop at customer location; full cylinders delivered and empties collected'),
    (nextval('public.pk_stop_type_id_serial'), 'SUPPLIER_DROPOFF',
        'Intermediate stop at supplier; yard-origin empties dropped for refill; replaces tbl_supplier_trip'),
    (nextval('public.pk_stop_type_id_serial'), 'YARD_END',
        'Trip terminus — vehicle returns to yard; customer empties verified; full asset reconciliation performed');

