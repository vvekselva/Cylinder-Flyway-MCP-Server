-- public.tbl_vehicle_review_status definition

-- Drop table

-- DROP TABLE public.tbl_vehicle_review_status;

CREATE TABLE public.tbl_vehicle_review_status (
	pk_vehicle_review_status_id int8 NOT NULL,
	review_status varchar(100) NOT NULL,
	"comments" varchar(500) NULL,
	CONSTRAINT tbl_vehicle_review_status_pk PRIMARY KEY (pk_vehicle_review_status_id),
	CONSTRAINT tbl_vehicle_review_status_unique UNIQUE (review_status)
);

-- Permissions

ALTER TABLE public.tbl_vehicle_review_status OWNER TO postgres;
GRANT ALL ON TABLE public.tbl_vehicle_review_status TO postgres;



 DROP SEQUENCE IF EXISTS public.pk_vehicle_review_status_id_serial;

CREATE SEQUENCE public.pk_vehicle_review_status_id_serial
	INCREMENT BY 1
	MINVALUE 1
	MAXVALUE 9223372036854775807
	START 1
	CACHE 1
	NO CYCLE;
	
	
	INSERT INTO public.tbl_vehicle_review_status (
pk_vehicle_review_status_id,
review_status,
comments
)
VALUES (
nextval('public.pk_vehicle_review_status_id_serial'),
'NOT_REVIEWED',
'Vehicle trip or stop is pending operational review'
);

INSERT INTO public.tbl_vehicle_review_status (
pk_vehicle_review_status_id,
review_status,
comments
)
VALUES (
nextval('public.pk_vehicle_review_status_id_serial'),
'REVIEWED',
'Vehicle trip or stop has been operationally reviewed'
);
