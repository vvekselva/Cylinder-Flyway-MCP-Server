-- public.tbl_deposit_status definition

-- Drop table

-- DROP TABLE public.tbl_deposit_status;

CREATE TABLE public.tbl_deposit_status (
	pk_deposit_status_id int8 NOT NULL,
	deposit_status varchar(50) NOT NULL,
	description varchar(500) NOT NULL,
	CONSTRAINT tbl_deposit_status_pk PRIMARY KEY (pk_deposit_status_id),
	CONSTRAINT tbl_deposit_status_unique UNIQUE (deposit_status)
);

-- public.pk_cylinder_deposit_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_cylinder_deposit_id_serial;

CREATE SEQUENCE public.pk_cylinder_deposit_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;

INSERT INTO public.tbl_deposit_status (pk_deposit_status_id, deposit_status, description)
VALUES
    (nextval('pk_cylinder_deposit_id_serial'), 'HELD',      'Deposit currently held against customer account'),
    (nextval('pk_cylinder_deposit_id_serial'), 'REFUNDED',  'Deposit fully or partially refunded to customer'),
    (nextval('pk_cylinder_deposit_id_serial'), 'FORFEITED', 'Deposit forfeited due to outstanding dues or damages');
