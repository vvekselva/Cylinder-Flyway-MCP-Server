-- =====================================================================
-- V113__Yard_Inventory.sql
-- Yard Inventory ownership model for cylinders currently/historically in yard.
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.tbl_yard_inventory_source_type (
    pk_yard_inventory_source_type_id BIGSERIAL PRIMARY KEY,
    source_type_code VARCHAR(50) NOT NULL,
    source_type_name VARCHAR(100) NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_yard_inventory_source_type_code UNIQUE (source_type_code)
);

INSERT INTO public.tbl_yard_inventory_source_type
(source_type_code, source_type_name, is_active, created_at, updated_at)
VALUES
('COMMISSIONING', 'Commissioning', TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
('CUSTOMER_RETURN', 'Customer Return', TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
('SUPPLIER_RETURN', 'Supplier Return', TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
('YARD_RETURN', 'Yard Return', TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
('MANUAL_ADJUSTMENT', 'Manual Adjustment', TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
('STOCK_RECONCILIATION', 'Stock Reconciliation', TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
ON CONFLICT (source_type_code) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.tbl_yard_inventory (
    pk_yard_inventory_id BIGSERIAL PRIMARY KEY,
    yard_code VARCHAR(50) NOT NULL,
    yard_name VARCHAR(100) NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_yard_inventory_code UNIQUE (yard_code)
);

INSERT INTO public.tbl_yard_inventory
(yard_code, yard_name, is_active, created_at, updated_at)
VALUES ('MAIN', 'Main Yard', TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
ON CONFLICT (yard_code) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.tbl_yard_inventory_allowed_state (
    pk_yard_inventory_allowed_state_id BIGSERIAL PRIMARY KEY,
    fk_cylinder_state BIGINT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_yard_inv_allowed_state_state
        FOREIGN KEY (fk_cylinder_state)
        REFERENCES public.tbl_cylinder_states(pk_cylinder_state_id),
    CONSTRAINT uq_yard_inv_allowed_state UNIQUE (fk_cylinder_state)
);

INSERT INTO public.tbl_yard_inventory_allowed_state
(fk_cylinder_state, is_active, created_at, updated_at)
SELECT cs.pk_cylinder_state_id, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
FROM public.tbl_cylinder_states cs
WHERE cs.cylinder_state IN (
    'EMPTY',
    'FULL',
    'FULL_PICKED_FROM_SUPPLIER',
    'FULL_PICKED_UP_FOR_DELIVERY',
    'EMPTY_IN_TRANSIT_TO_YARD',
    'EMPTY_PICKED_FOR_REFILL'
)
ON CONFLICT (fk_cylinder_state) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.tbl_yard_inventory_line (
    pk_yard_inventory_line_id BIGSERIAL PRIMARY KEY,
    fk_yard_inventory BIGINT NOT NULL,
    fk_cylinder BIGINT NOT NULL,
    fk_cylinder_state BIGINT NOT NULL,
    fk_yard_inventory_source_type BIGINT NOT NULL,
    fk_yard_entry BIGINT NULL,
    entry_date TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    remarks VARCHAR(500) NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_yard_inventory_line_header
        FOREIGN KEY (fk_yard_inventory)
        REFERENCES public.tbl_yard_inventory(pk_yard_inventory_id),
    CONSTRAINT fk_yard_inventory_line_cylinder
        FOREIGN KEY (fk_cylinder)
        REFERENCES public.tbl_cylinder(pk_cylinder_id),
    CONSTRAINT fk_yard_inventory_line_state
        FOREIGN KEY (fk_cylinder_state)
        REFERENCES public.tbl_cylinder_states(pk_cylinder_state_id),
    CONSTRAINT fk_yard_inventory_line_source_type
        FOREIGN KEY (fk_yard_inventory_source_type)
        REFERENCES public.tbl_yard_inventory_source_type(pk_yard_inventory_source_type_id),
    CONSTRAINT fk_yard_inventory_line_yard_entry
        FOREIGN KEY (fk_yard_entry)
        REFERENCES public.tbl_yard_entries(pk_yard_entry_id)
);

CREATE INDEX IF NOT EXISTS idx_yard_inventory_line_header ON public.tbl_yard_inventory_line(fk_yard_inventory);
CREATE INDEX IF NOT EXISTS idx_yard_inventory_line_cylinder ON public.tbl_yard_inventory_line(fk_cylinder);
CREATE INDEX IF NOT EXISTS idx_yard_inventory_line_state ON public.tbl_yard_inventory_line(fk_cylinder_state);
CREATE INDEX IF NOT EXISTS idx_yard_inventory_line_source_type ON public.tbl_yard_inventory_line(fk_yard_inventory_source_type);
CREATE INDEX IF NOT EXISTS idx_yard_inventory_line_yard_entry ON public.tbl_yard_inventory_line(fk_yard_entry);
CREATE INDEX IF NOT EXISTS idx_yard_inventory_line_active ON public.tbl_yard_inventory_line(is_active);

CREATE UNIQUE INDEX IF NOT EXISTS uq_yard_inventory_line_active_cylinder
ON public.tbl_yard_inventory_line(fk_cylinder)
WHERE is_active = TRUE;

CREATE OR REPLACE FUNCTION public.fn_validate_yard_inventory_line_state()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.is_active = TRUE THEN
        IF NOT EXISTS (
            SELECT 1
            FROM public.tbl_yard_inventory_allowed_state yias
            WHERE yias.fk_cylinder_state = NEW.fk_cylinder_state
              AND yias.is_active = TRUE
        ) THEN
            RAISE EXCEPTION 'Cylinder state % is not allowed for yard inventory entry', NEW.fk_cylinder_state;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_yard_inventory_line_state ON public.tbl_yard_inventory_line;

CREATE TRIGGER trg_validate_yard_inventory_line_state
BEFORE INSERT OR UPDATE OF fk_cylinder_state, is_active
ON public.tbl_yard_inventory_line
FOR EACH ROW
EXECUTE FUNCTION public.fn_validate_yard_inventory_line_state();
