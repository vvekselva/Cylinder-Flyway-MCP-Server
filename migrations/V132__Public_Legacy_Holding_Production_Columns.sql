-- ============================================================================
-- V132__Public_Legacy_Holding_Production_Columns.sql
-- ============================================================================
-- Purpose
--   Production-schema changes required before promoting legacy cylinder holding
--   rows from migration_import into public production tables.
--
-- Scope
--   Only alters public production tables.
--   Does not create migration staging tables and does not insert data.
-- ============================================================================

ALTER TABLE public.tbl_cylinder_party_custody
ADD COLUMN IF NOT EXISTS is_legacy BOOLEAN NOT NULL DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS legacy_source VARCHAR(100),
ADD COLUMN IF NOT EXISTS legacy_import_batch_no VARCHAR(100),
ADD COLUMN IF NOT EXISTS legacy_reference_number VARCHAR(100),
ADD COLUMN IF NOT EXISTS legacy_source_line_id BIGINT;

COMMENT ON COLUMN public.tbl_cylinder_party_custody.legacy_source_line_id IS
'Scalar reference to migration_import.tbl_cylinder_holding_import_line.pk_holding_line_id. No FK by design; public must not depend on migration schema.';

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'tbl_custody_entry_event_chk'
          AND conrelid = 'public.tbl_cylinder_party_custody'::regclass
    ) THEN
        ALTER TABLE public.tbl_cylinder_party_custody
        DROP CONSTRAINT tbl_custody_entry_event_chk;
    END IF;

    ALTER TABLE public.tbl_cylinder_party_custody
    ADD CONSTRAINT tbl_custody_entry_event_chk
    CHECK (entry_event_type IN ('ORDER_DELIVERY', 'SUPPLIER_DROPOFF', 'LEGACY_HOLDING'));
END $$;

CREATE INDEX IF NOT EXISTS idx_cpc_legacy_batch
ON public.tbl_cylinder_party_custody(legacy_import_batch_no)
WHERE is_legacy = TRUE;

CREATE INDEX IF NOT EXISTS idx_cpc_legacy_source_line
ON public.tbl_cylinder_party_custody(legacy_source_line_id)
WHERE legacy_source_line_id IS NOT NULL;

ALTER TABLE public.tbl_cylinder_state_audit
ADD COLUMN IF NOT EXISTS is_legacy BOOLEAN NOT NULL DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS legacy_source VARCHAR(100),
ADD COLUMN IF NOT EXISTS legacy_import_batch_no VARCHAR(100),
ADD COLUMN IF NOT EXISTS legacy_reference_number VARCHAR(100),
ADD COLUMN IF NOT EXISTS legacy_source_line_id BIGINT;

CREATE INDEX IF NOT EXISTS idx_csa_legacy_batch
ON public.tbl_cylinder_state_audit(legacy_import_batch_no)
WHERE is_legacy = TRUE;

ALTER TABLE public.tbl_yard_inventory_line
ADD COLUMN IF NOT EXISTS exit_event_type VARCHAR(50),
ADD COLUMN IF NOT EXISTS exited_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS is_legacy_closed BOOLEAN NOT NULL DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS legacy_import_batch_no VARCHAR(100),
ADD COLUMN IF NOT EXISTS legacy_source_line_id BIGINT;
