-- public.tbl_state definition

-- Drop table

-- DROP TABLE public.tbl_state;

CREATE TABLE public.tbl_state (
	pk_state_id int8 NOT NULL,
	state_name varchar(500) NOT NULL,
	description varchar(500) NOT NULL,
	CONSTRAINT tbl_state_pk PRIMARY KEY (pk_state_id),
	CONSTRAINT tbl_state_unique UNIQUE (state_name)
);	


-- public.pk_state_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_state_id_serial;

CREATE SEQUENCE public.pk_state_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;