-- public.tbl_daily_login_report definition

-- Drop table

-- DROP TABLE public.tbl_daily_login_report;

CREATE TABLE public.tbl_daily_login_report (
	pk_daily_login_report_id int8 NULL,
	login_time timestamp NOT NULL,
	CONSTRAINT tbl_daily_login_report_unique UNIQUE (pk_daily_login_report_id)
);



-- public.pk_daily_login_id_serial definition

DROP SEQUENCE IF EXISTS public.pk_daily_login_id_serial;

CREATE SEQUENCE public.pk_daily_login_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;