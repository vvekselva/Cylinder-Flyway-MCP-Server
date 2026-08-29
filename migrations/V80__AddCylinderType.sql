-- =============================================================================
-- V80__AddCylinderType.sql
-- =============================================================================
--
-- PURPOSE
-- ───────────────────────────────────────────────────────────────────────────
-- Adds the cylinder_type column to tbl_cylinder to record the physical
-- category of each gas cylinder.
--
-- This column is required BEFORE the Java migration tool is run with
-- migration.run-mode=MIGRATE_GASES. Without it, the cylinder INSERT
-- statements in GasesRepository will fail.
--
-- CYLINDER TYPE DOMAIN
-- ───────────────────────────────────────────────────────────────────────────
--   Bulk    — large permanently-stationed industrial cylinders
--   A-Type  — A-size portable cylinder
--   B-Type  — B-size portable cylinder   (39 rows in the current Excel)
--   C-Type  — C-size portable cylinder
--
-- Current Excel data (V7__Type_of_Gasesv1.xlsx):
--   Bulk   → 1,288 cylinders
--   B-Type →    39 cylinders  (stored as "B Type" in Excel; normalised by parser)
--   A-Type and C-Type have no rows in the current sheet but are valid for
--   future commissioning.
--
-- NORMALISATION IN THE JAVA PARSER
-- ───────────────────────────────────────────────────────────────────────────
-- GasesExcelParser#normalisedCylinderType() maps Excel values → DB values:
--   "Bulk"   → "Bulk"
--   "B Type" → "B-Type"
--   "A Type" → "A-Type"
--   "C Type" → "C-Type"
-- Unknown values are inserted as-is and will violate the CHECK constraint,
-- making the problem visible in logs rather than silently discarding data.
-- =============================================================================


-- ── 1. Add the column (NULL initially — existing rows have no type yet) ───────
ALTER TABLE public.tbl_cylinder
    ADD COLUMN IF NOT EXISTS cylinder_type varchar(20) NULL;

COMMENT ON COLUMN public.tbl_cylinder.cylinder_type IS
    'Physical category of the cylinder. '
    'Allowed values enforced by chk_cylinder_type: '
    'Bulk, A-Type, B-Type, C-Type. '
    'NULL for cylinders commissioned before V80 migration.';


-- ── 2. CHECK constraint — enforces the allowed domain ────────────────────────
ALTER TABLE public.tbl_cylinder
    DROP CONSTRAINT IF EXISTS chk_cylinder_type;

ALTER TABLE public.tbl_cylinder
    ADD CONSTRAINT chk_cylinder_type
    CHECK (cylinder_type IN ('Bulk', 'A-Type', 'B-Type', 'C-Type'));


-- ── 3. Index — cylinder_type will be used in inventory queries ────────────────
CREATE INDEX IF NOT EXISTS idx_cylinder_type
    ON public.tbl_cylinder (cylinder_type);


-- ── 4. Verification queries (run manually after migration) ────────────────────
--
-- Confirm column and constraint exist:
--   SELECT column_name, data_type, character_maximum_length, is_nullable
--   FROM   information_schema.columns
--   WHERE  table_schema = 'public'
--     AND  table_name   = 'tbl_cylinder'
--     AND  column_name  = 'cylinder_type';
--
--   SELECT conname, pg_get_constraintdef(oid)
--   FROM   pg_constraint
--   WHERE  conrelid = 'public.tbl_cylinder'::regclass
--     AND  conname  = 'chk_cylinder_type';
--
-- After running MIGRATE_GASES — check type distribution:
--   SELECT cylinder_type, COUNT(*) AS cnt
--   FROM   public.tbl_cylinder
--   GROUP  BY cylinder_type
--   ORDER  BY cnt DESC;
--
-- Expected output for V7 data:
--   cylinder_type | cnt
--   ──────────────┼──────
--   Bulk          | 1288
--   B-Type        |   39
