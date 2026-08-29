
-- Customer address location and offline-map provisioning for LAN-only deployments.
-- No WhatsApp webhook is created. Coordinates enter the system through manual paste/import screens.

CREATE SEQUENCE IF NOT EXISTS public.pk_customer_address_location_id_serial START WITH 1 INCREMENT BY 1;
CREATE SEQUENCE IF NOT EXISTS public.pk_customer_location_import_inbox_id_serial START WITH 1 INCREMENT BY 1;
CREATE SEQUENCE IF NOT EXISTS public.pk_yard_location_id_serial START WITH 1 INCREMENT BY 1;

CREATE TABLE IF NOT EXISTS public.tbl_customer_address_location (
    pk_customer_address_location_id BIGINT PRIMARY KEY DEFAULT nextval('public.pk_customer_address_location_id_serial'),
    fk_customer_address BIGINT NOT NULL,
    latitude NUMERIC(10,7) NOT NULL,
    longitude NUMERIC(10,7) NOT NULL,
    location_source VARCHAR(40) NOT NULL,
    location_status VARCHAR(40) NOT NULL,
    source_reference VARCHAR(500),
    captured_by_employee_name VARCHAR(200),
    captured_by_mobile_number VARCHAR(30),
    captured_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT now(),
    verified_at TIMESTAMP WITHOUT TIME ZONE,
    verified_by VARCHAR(200),
    remarks VARCHAR(500),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT now(),
    updated_at TIMESTAMP WITHOUT TIME ZONE,
    CONSTRAINT fk_customer_address_location_customer_address
        FOREIGN KEY (fk_customer_address) REFERENCES public.tbl_customer_address(pk_customer_address_id),
    CONSTRAINT chk_customer_address_location_source
        CHECK (location_source IN ('MANUAL_ENTRY','WHATSAPP_COPY_PASTE','WHATSAPP_EXPORT_IMPORT','MOBILE_SCREENSHOT_ENTRY','OFFICE_VERIFIED','IMPORT')),
    CONSTRAINT chk_customer_address_location_status
        CHECK (location_status IN ('PENDING_REVIEW','VERIFIED','REJECTED','SUPERSEDED')),
    CONSTRAINT chk_customer_address_location_latitude CHECK (latitude BETWEEN -90 AND 90),
    CONSTRAINT chk_customer_address_location_longitude CHECK (longitude BETWEEN -180 AND 180)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_customer_address_location_active
ON public.tbl_customer_address_location(fk_customer_address)
WHERE is_active = TRUE;

CREATE TABLE IF NOT EXISTS public.tbl_customer_location_import_inbox (
    pk_location_import_inbox_id BIGINT PRIMARY KEY DEFAULT nextval('public.pk_customer_location_import_inbox_id_serial'),
    source_type VARCHAR(40) NOT NULL,
    raw_text TEXT NOT NULL,
    parsed_latitude NUMERIC(10,7),
    parsed_longitude NUMERIC(10,7),
    sender_name VARCHAR(200),
    sender_mobile VARCHAR(30),
    message_datetime TIMESTAMP WITHOUT TIME ZONE,
    imported_by VARCHAR(200),
    imported_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT now(),
    mapping_status VARCHAR(40) NOT NULL DEFAULT 'UNMAPPED',
    fk_customer BIGINT,
    fk_customer_address BIGINT,
    remarks VARCHAR(500),
    CONSTRAINT fk_location_import_inbox_customer FOREIGN KEY (fk_customer) REFERENCES public.tbl_customer(pk_customer_id),
    CONSTRAINT fk_location_import_inbox_customer_address FOREIGN KEY (fk_customer_address) REFERENCES public.tbl_customer_address(pk_customer_address_id),
    CONSTRAINT chk_location_import_inbox_status CHECK (mapping_status IN ('UNMAPPED','MAPPED','REJECTED','DUPLICATE'))
);

CREATE TABLE IF NOT EXISTS public.tbl_yard_location (
    pk_yard_location_id BIGINT PRIMARY KEY DEFAULT nextval('public.pk_yard_location_id_serial'),
    fk_yard BIGINT NOT NULL,
    latitude NUMERIC(10,7) NOT NULL,
    longitude NUMERIC(10,7) NOT NULL,
    location_status VARCHAR(40) NOT NULL DEFAULT 'VERIFIED',
    is_default_start_point BOOLEAN NOT NULL DEFAULT FALSE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT now(),
    updated_at TIMESTAMP WITHOUT TIME ZONE,
    CONSTRAINT fk_yard_location_yard FOREIGN KEY (fk_yard) REFERENCES public.tbl_yard_inventory(pk_yard_inventory_id),
    CONSTRAINT chk_yard_location_status CHECK (location_status IN ('PENDING_REVIEW','VERIFIED','REJECTED','SUPERSEDED')),
    CONSTRAINT chk_yard_location_latitude CHECK (latitude BETWEEN -90 AND 90),
    CONSTRAINT chk_yard_location_longitude CHECK (longitude BETWEEN -180 AND 180)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_yard_location_default_active
ON public.tbl_yard_location(fk_yard)
WHERE is_active = TRUE AND is_default_start_point = TRUE;

CREATE OR REPLACE VIEW public.vw_customer_address_location_status AS
SELECT
    ca.pk_customer_address_id AS customer_address_id,
    c.pk_customer_id AS customer_id,
    c.customer_name AS customer_name,
    c.gst_number AS gst_number,
    a.pk_address_id AS address_id,
    concat_ws(', ', a.address_line_1, a.address_line_2, a.address_line_3, a.landmark) AS address_text,
    loc.pk_customer_address_location_id AS customer_address_location_id,
    loc.latitude,
    loc.longitude,
    loc.location_source,
    loc.location_status,
    loc.is_active AS location_active,
    CASE WHEN loc.pk_customer_address_location_id IS NULL THEN TRUE ELSE FALSE END AS location_missing
FROM public.tbl_customer_address ca
JOIN public.tbl_customer c ON c.pk_customer_id = ca.fk_customer
JOIN public.tbl_address a ON a.pk_address_id = ca.fk_address
LEFT JOIN public.tbl_customer_address_location loc
    ON loc.fk_customer_address = ca.pk_customer_address_id
   AND loc.is_active = TRUE
   AND loc.location_status = 'VERIFIED';

CREATE OR REPLACE VIEW public.vw_trip_review_customer_stop_location AS
SELECT
    vts.fk_vehicle_trip AS vehicle_trip_id,
    vts.pk_stop_id AS stop_id,
    vts.stop_sequence,
    COALESCE(st.stop_type, 'CUSTOMER') AS stop_type,
    vts.fk_customer AS customer_id,
    c.customer_name,
    vts.fk_delivery_address AS customer_address_id,
    concat_ws(', ', a.address_line_1, a.address_line_2, a.address_line_3, a.landmark) AS address_text,
    loc.latitude,
    loc.longitude,
    loc.location_status,
    CASE WHEN loc.pk_customer_address_location_id IS NOT NULL THEN TRUE ELSE FALSE END AS plottable
FROM public.tbl_vehicle_trip_stop vts
LEFT JOIN public.tbl_stop_type st ON st.pk_stop_type_id = vts.fk_stop_type
LEFT JOIN public.tbl_customer c ON c.pk_customer_id = vts.fk_customer
LEFT JOIN public.tbl_customer_address ca ON ca.pk_customer_address_id = vts.fk_delivery_address
LEFT JOIN public.tbl_address a ON a.pk_address_id = ca.fk_address
LEFT JOIN public.tbl_customer_address_location loc
    ON loc.fk_customer_address = vts.fk_delivery_address
   AND loc.is_active = TRUE
   AND loc.location_status = 'VERIFIED'
WHERE vts.fk_customer IS NOT NULL
  AND vts.fk_delivery_address IS NOT NULL;

CREATE OR REPLACE FUNCTION public.fn_refresh_customer_location_summary_metrics()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO public.tbl_summary_metric_lookup(look_up_key, ui_label_for_the_lookup_field, actual_meaning, value, is_decimal_value)
    VALUES
    ('TOTAL_CUSTOMER_ADDRESSES', 'Total Customer Addresses', 'Total number of customer address rows available for geolocation.', (SELECT COUNT(*) FROM public.tbl_customer_address), false),
    ('CUSTOMER_ADDRESSES_WITH_VERIFIED_LOCATION', 'Customer Addresses With Location', 'Customer addresses that have one active verified coordinate row.', (SELECT COUNT(*) FROM public.vw_customer_address_location_status WHERE location_missing = FALSE), false),
    ('CUSTOMER_ADDRESSES_WITHOUT_VERIFIED_LOCATION', 'Customer Addresses Missing Location', 'Customer addresses without an active verified coordinate row.', (SELECT COUNT(*) FROM public.vw_customer_address_location_status WHERE location_missing = TRUE), false),
    ('CUSTOMER_LOCATIONS_PENDING_REVIEW', 'Customer Locations Pending Review', 'Location rows captured but not yet verified.', (SELECT COUNT(*) FROM public.tbl_customer_address_location WHERE is_active = TRUE AND location_status = 'PENDING_REVIEW'), false),
    ('CUSTOMER_LOCATIONS_IMPORTED_UNMAPPED', 'Imported Locations Unmapped', 'Imported WhatsApp/copy-paste location rows not mapped to a customer address.', (SELECT COUNT(*) FROM public.tbl_customer_location_import_inbox WHERE mapping_status = 'UNMAPPED'), false)
    ON CONFLICT (look_up_key) DO UPDATE
    SET ui_label_for_the_lookup_field = EXCLUDED.ui_label_for_the_lookup_field,
        actual_meaning = EXCLUDED.actual_meaning,
        value = EXCLUDED.value,
        is_decimal_value = EXCLUDED.is_decimal_value;
END;
$$;
