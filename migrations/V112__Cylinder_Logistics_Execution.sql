-- =====================================================================
-- V112__Cylinder_Logistics_Execution.sql
-- Long-term deterministic cylinder logistics tracking
--
-- Important:
-- 1. Does NOT alter tbl_cylinder_states.
-- 2. Does NOT alter tbl_vehicle_load / tbl_vehicle_load_line.
-- 3. Existing cylinder state names remain valid.
-- 4. Uses fk_cylinder_state to reference the existing state table.
-- 5. tbl_cylinder_current_status should be updated by service layer
--    and used only as a quick lookup/snapshot.
-- =====================================================================


-- =====================================================================
-- Header Table
-- One record per vehicle trip/load logistics execution.
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.tbl_cylinder_logistics_execution (
    pk_cylinder_logistics_execution_id BIGSERIAL PRIMARY KEY,

    fk_vehicle_trip BIGINT NOT NULL,
    fk_vehicle_load BIGINT NOT NULL,

    execution_status VARCHAR(30) NOT NULL DEFAULT 'OPEN',

    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    closed_at TIMESTAMP NULL,

    CONSTRAINT chk_cyl_log_exec_status
        CHECK (execution_status IN ('OPEN', 'COMPLETED', 'CANCELLED')),

    CONSTRAINT fk_cyl_log_exec_trip
        FOREIGN KEY (fk_vehicle_trip)
        REFERENCES public.tbl_vehicle_trip(pk_vehicle_trip_id),

    CONSTRAINT fk_cyl_log_exec_load
        FOREIGN KEY (fk_vehicle_load)
        REFERENCES public.tbl_vehicle_load(pk_vehicle_load_id)
);

CREATE INDEX IF NOT EXISTS idx_cyl_log_exec_trip
ON public.tbl_cylinder_logistics_execution(fk_vehicle_trip);

CREATE INDEX IF NOT EXISTS idx_cyl_log_exec_load
ON public.tbl_cylinder_logistics_execution(fk_vehicle_load);

CREATE UNIQUE INDEX IF NOT EXISTS uq_cyl_log_exec_load
ON public.tbl_cylinder_logistics_execution(fk_vehicle_load);


-- =====================================================================
-- Line Table
-- One record per cylinder participating in a logistics execution.
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.tbl_cylinder_logistics_execution_line (
    pk_cylinder_logistics_execution_line_id BIGSERIAL PRIMARY KEY,

    fk_cylinder_logistics_execution BIGINT NOT NULL,
    fk_cylinder BIGINT NOT NULL,

    -- Existing cylinder state is reused by FK only.
    -- No existing state name is changed or made void.
    fk_cylinder_state BIGINT NOT NULL,

    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    is_completed BOOLEAN NOT NULL DEFAULT FALSE,
    is_exception BOOLEAN NOT NULL DEFAULT FALSE,

    exception_reason VARCHAR(500) NULL,
    completed_at TIMESTAMP NULL,

    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    remarks VARCHAR(500) NULL,

    CONSTRAINT fk_cyl_log_exec_line_hdr
        FOREIGN KEY (fk_cylinder_logistics_execution)
        REFERENCES public.tbl_cylinder_logistics_execution(
            pk_cylinder_logistics_execution_id
        ),

    CONSTRAINT fk_cyl_log_exec_line_cylinder
        FOREIGN KEY (fk_cylinder)
        REFERENCES public.tbl_cylinder(pk_cylinder_id),

    CONSTRAINT fk_cyl_log_exec_line_state
        FOREIGN KEY (fk_cylinder_state)
        REFERENCES public.tbl_cylinder_states(pk_cylinder_state_id)
);

CREATE INDEX IF NOT EXISTS idx_cyl_log_exec_line_hdr
ON public.tbl_cylinder_logistics_execution_line(fk_cylinder_logistics_execution);

CREATE INDEX IF NOT EXISTS idx_cyl_log_exec_line_cylinder
ON public.tbl_cylinder_logistics_execution_line(fk_cylinder);

CREATE INDEX IF NOT EXISTS idx_cyl_log_exec_line_state
ON public.tbl_cylinder_logistics_execution_line(fk_cylinder_state);

CREATE INDEX IF NOT EXISTS idx_cyl_log_exec_line_active
ON public.tbl_cylinder_logistics_execution_line(is_active);

CREATE INDEX IF NOT EXISTS idx_cyl_log_exec_line_completed
ON public.tbl_cylinder_logistics_execution_line(is_completed);

CREATE INDEX IF NOT EXISTS idx_cyl_log_exec_line_exception
ON public.tbl_cylinder_logistics_execution_line(is_exception);


-- One cylinder can have only one active logistics execution line at a time.
CREATE UNIQUE INDEX IF NOT EXISTS uq_cyl_log_exec_line_active_cylinder
ON public.tbl_cylinder_logistics_execution_line(fk_cylinder)
WHERE is_active = TRUE;


-- =====================================================================
-- Optional Backfill: Header records for existing vehicle loads.
-- This does not create line records yet.
-- Line creation should be handled from service/domain logic.
-- =====================================================================

INSERT INTO public.tbl_cylinder_logistics_execution
(
    fk_vehicle_trip,
    fk_vehicle_load,
    execution_status,
    created_at,
    updated_at
)
SELECT DISTINCT
    vl.fk_vehicle_trip,
    vl.pk_vehicle_load_id,
    'OPEN',
    CURRENT_TIMESTAMP,
    CURRENT_TIMESTAMP
FROM public.tbl_vehicle_load vl
WHERE vl.fk_vehicle_trip IS NOT NULL
  AND NOT EXISTS (
      SELECT 1
      FROM public.tbl_cylinder_logistics_execution cle
      WHERE cle.fk_vehicle_load = vl.pk_vehicle_load_id
  );


-- =====================================================================
-- Trip close validation idea:
--
-- SELECT COUNT(*)
-- FROM public.tbl_cylinder_logistics_execution cle
-- JOIN public.tbl_cylinder_logistics_execution_line clel
--   ON clel.fk_cylinder_logistics_execution = cle.pk_cylinder_logistics_execution_id
-- WHERE cle.fk_vehicle_trip = :vehicleTripId
--   AND clel.is_active = TRUE
--   AND clel.is_completed = FALSE
--   AND clel.is_exception = FALSE;
--
-- If count > 0, trip closure should be blocked.
-- =====================================================================
