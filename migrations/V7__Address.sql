-- public.tbl_address definition

-- Drop table

-- DROP TABLE public.tbl_address;

CREATE TABLE public.tbl_address (
	pk_address_id int8 NOT NULL,
	address_line_1 varchar(100) NOT NULL,
	address_line_2 varchar(100) NOT NULL,
	address_line_3 varchar(100) NULL,
	landmark varchar(100) NULL,
	fk_city int8 NOT NULL,
	fk_state int8 NOT NULL,
	fk_country int8 NOT NULL,
	CONSTRAINT tbl_address_pk PRIMARY KEY (pk_address_id),
	CONSTRAINT tbl_address_tbl_city_fk FOREIGN KEY (fk_city) REFERENCES public.tbl_city(pk_city_id),
	CONSTRAINT tbl_address_tbl_country_fk FOREIGN KEY (fk_country) REFERENCES public.tbl_country(pk_country_id),
	CONSTRAINT tbl_address_tbl_state_fk FOREIGN KEY (fk_state) REFERENCES public.tbl_state(pk_state_id)
);



-- public.pk_address_id_serial definition

 DROP SEQUENCE IF EXISTS public.pk_address_id_serial;

CREATE SEQUENCE public.pk_address_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;