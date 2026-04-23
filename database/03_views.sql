-- =============================================================================
-- RememberMe-d — Vistas y Objetos Derivados de Base de Datos
-- Universidad Politécnica de Chiapas · AWOS
-- Versión: 1.0.0 · Ejecutar DESPUÉS de 01_schema.sql y 02_seed.sql
-- =============================================================================
-- INVENTARIO DE VISTAS:
--   v_today_intake          → Tomas del día actual por paciente
--   v_patient_adherence     → Estadísticas de adherencia (30 días)
--   v_adherence_streak      → Racha de días con adherencia perfecta
--   v_doctor_dashboard      → Panel resumen de pacientes vinculados (médico)
--   v_high_severity_alerts  → Síntomas con severidad >= 8 (alertas clínicas)
--   v_medication_schedule   → Medicamentos activos con próxima toma pendiente
--   v_active_links          → Vínculos activos con datos de médico y paciente
--
-- INVENTARIO DE FUNCIONES:
--   fn_intake_is_adherent   → Calcula si una toma fue dentro de la ventana ±2h
--   fn_link_is_expired      → Calcula si un código de vínculo ha expirado
--
-- NOTAS DE USO:
--   - Todos los campos calculados (is_adherent, high_severity_alert, expires_at,
--     adherence_pct, streak) viven aquí, no en las tablas base.
--   - El backend puede consultar estas vistas directamente con SELECT.
--   - Los permisos de SELECT se otorgan al final de este archivo.
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1 · FUNCIONES AUXILIARES DE CÁLCULO
-- =============================================================================

-- -----------------------------------------------------------------------------
-- fn_intake_is_adherent
-- Determina si una toma fue confirmada dentro de la ventana permitida (±2h).
-- Retorna NULL si el status no es 'taken' o si taken_at es NULL.
-- Uso: SELECT rememberme.fn_intake_is_adherent(taken_at, scheduled_date, scheduled_time)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rememberme.fn_intake_is_adherent(
  p_taken_at       TIMESTAMPTZ,
  p_scheduled_date DATE,
  p_scheduled_time TIME
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
  SELECT
    CASE
      WHEN p_taken_at IS NULL THEN NULL
      ELSE ABS(
             EXTRACT(EPOCH FROM (
               p_taken_at
               - (p_scheduled_date + p_scheduled_time)::TIMESTAMP AT TIME ZONE 'UTC'
             ))
           ) / 3600.0 <= 2.0
    END;
$$;

COMMENT ON FUNCTION rememberme.fn_intake_is_adherent(TIMESTAMPTZ, DATE, TIME) IS
  'Devuelve TRUE si taken_at está dentro de ±2h del slot programado. NULL si aún no se tomó.';


-- -----------------------------------------------------------------------------
-- fn_link_is_expired
-- Verifica si un código de vínculo ha expirado (más de 24h desde created_at).
-- Aplica solo a vínculos con status = ''pending''.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rememberme.fn_link_is_expired(
  p_created_at TIMESTAMPTZ,
  p_status     rememberme.link_status_enum
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
  SELECT
    CASE
      WHEN p_status <> 'pending' THEN FALSE
      ELSE NOW() > p_created_at + INTERVAL '24 hours'
    END;
$$;

COMMENT ON FUNCTION rememberme.fn_link_is_expired(TIMESTAMPTZ, rememberme.link_status_enum) IS
  'Retorna TRUE si el código de vínculo (status=pending) tiene más de 24h sin ser reclamado.';


-- =============================================================================
-- SECCIÓN 2 · VISTA: v_today_intake
-- =============================================================================
-- Uso principal: GET /api/intake-logs/today
-- Expone las tomas programadas para HOY con nombre de medicamento, paciente
-- y el campo calculado `is_adherent`.
-- El backend filtra por patient_id desde el JWT para el scope correcto.
-- =============================================================================

CREATE OR REPLACE VIEW rememberme.v_today_intake AS
SELECT
  il.id                                         AS intake_id,
  il.medication_id,
  m.name                                        AS medication_name,
  m.dosage,
  m.patient_id,
  u.full_name                                   AS patient_name,
  il.scheduled_date,
  il.scheduled_time,
  il.taken_at,
  il.status,
  -- Campo calculado: is_adherent (dentro de ±2h del slot programado)
  rememberme.fn_intake_is_adherent(
    il.taken_at, il.scheduled_date, il.scheduled_time
  )                                             AS is_adherent
FROM
  rememberme.intake_logs  il
  JOIN rememberme.medications m ON il.medication_id = m.id
  JOIN rememberme.users       u ON m.patient_id = u.id
WHERE
  il.scheduled_date = CURRENT_DATE
  AND m.is_active = TRUE;

COMMENT ON VIEW rememberme.v_today_intake IS
  'Tomas del día actual con nombre de medicamento, paciente e is_adherent calculado.
   Filtrar por patient_id en el backend según JWT.';


-- =============================================================================
-- SECCIÓN 3 · VISTA: v_patient_adherence
-- =============================================================================
-- Uso principal: GET /api/intake-logs/stats
-- Calcula las estadísticas de adherencia de los últimos 30 días por paciente.
-- `adherence_pct` = taken / (taken + skipped + late) * 100
-- =============================================================================

CREATE OR REPLACE VIEW rememberme.v_patient_adherence AS
SELECT
  u.id                                                            AS patient_id,
  u.full_name,
  -- Tomas resueltas (excluyendo pending)
  COUNT(il.id) FILTER (
    WHERE il.status IN ('taken', 'skipped', 'late')
  )                                                               AS total_resolved,
  COUNT(il.id) FILTER (WHERE il.status = 'taken')                AS total_taken,
  COUNT(il.id) FILTER (WHERE il.status = 'skipped')              AS total_skipped,
  COUNT(il.id) FILTER (WHERE il.status = 'late')                 AS total_late,
  COUNT(il.id) FILTER (WHERE il.status = 'pending')              AS total_pending,
  -- Porcentaje de adherencia sobre tomas resueltas
  ROUND(
    CASE
      WHEN COUNT(il.id) FILTER (WHERE il.status IN ('taken', 'skipped', 'late')) = 0
        THEN 0.0
      ELSE
        COUNT(il.id) FILTER (WHERE il.status = 'taken')::NUMERIC
        / COUNT(il.id) FILTER (WHERE il.status IN ('taken', 'skipped', 'late')) * 100
    END, 2
  )                                                               AS adherence_pct,
  -- Periodo de cálculo
  CURRENT_DATE - INTERVAL '30 days'                              AS period_start,
  CURRENT_DATE                                                    AS period_end
FROM
  rememberme.users       u
  JOIN rememberme.medications  m  ON u.id = m.patient_id
  JOIN rememberme.intake_logs  il ON m.id = il.medication_id
WHERE
  u.role = 'PATIENT'
  AND il.scheduled_date >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY
  u.id, u.full_name;

COMMENT ON VIEW rememberme.v_patient_adherence IS
  'Estadísticas de adherencia por paciente en los últimos 30 días.
   adherence_pct = taken / (taken+skipped+late) * 100.';


-- =============================================================================
-- SECCIÓN 4 · VISTA: v_adherence_streak
-- =============================================================================
-- Uso principal: campo `streak` en GET /api/intake-logs/stats
-- Calcula el número de días consecutivos en que TODAS las tomas
-- del paciente fueron confirmadas como 'taken'.
-- Devuelve la racha vigente (la que incluye el día más reciente disponible).
-- =============================================================================

CREATE OR REPLACE VIEW rememberme.v_adherence_streak AS
WITH

-- Paso 1: para cada paciente y día, ¿se tomaron TODAS las tomas?
daily_adherence AS (
  SELECT
    m.patient_id,
    il.scheduled_date,
    BOOL_AND(il.status = 'taken')  AS full_day_taken
  FROM
    rememberme.intake_logs  il
    JOIN rememberme.medications m ON il.medication_id = m.id
  WHERE
    il.scheduled_date <= CURRENT_DATE
    AND il.status <> 'pending'         -- ignorar días futuros/incompletos
  GROUP BY
    m.patient_id, il.scheduled_date
),

-- Paso 2: solo los días de adherencia perfecta
perfect_days AS (
  SELECT
    patient_id,
    scheduled_date
  FROM daily_adherence
  WHERE full_day_taken = TRUE
),

-- Paso 3: agrupar días consecutivos con la técnica gaps-and-islands
islands AS (
  SELECT
    patient_id,
    scheduled_date,
    -- Al restar el número de fila de la fecha, las fechas consecutivas
    -- producen el mismo "grupo"
    -- bien
    scheduled_date - (ROW_NUMBER() OVER (
      PARTITION BY patient_id
      ORDER BY scheduled_date
    ))::INT       AS streak_group
  FROM perfect_days
),

-- Paso 4: agregar cada isla
streaks AS (
  SELECT
    patient_id,
    streak_group,
    COUNT(*)                           AS streak_days,
    MIN(scheduled_date)                AS streak_start,
    MAX(scheduled_date)                AS streak_end
  FROM islands
  GROUP BY patient_id, streak_group
),

-- Paso 5: la racha vigente es la que termina en la fecha más reciente
current_streak AS (
  SELECT DISTINCT ON (patient_id)
    patient_id,
    streak_days,
    streak_start,
    streak_end
  FROM streaks
  ORDER BY patient_id, streak_end DESC
)

SELECT
  cs.patient_id,
  u.full_name,
  cs.streak_days                       AS streak,
  cs.streak_start,
  cs.streak_end,
  -- Si la racha llega a ayer o hoy, está activa
  cs.streak_end >= CURRENT_DATE - INTERVAL '1 day' AS is_active
FROM
  current_streak cs
  JOIN rememberme.users u ON cs.patient_id = u.id;

COMMENT ON VIEW rememberme.v_adherence_streak IS
  'Racha vigente de días con adherencia perfecta (todas las tomas = taken) por paciente.
   is_active=TRUE si la racha llega a ayer o hoy.';


-- =============================================================================
-- SECCIÓN 5 · VISTA: v_doctor_dashboard
-- =============================================================================
-- Uso principal: panel de médico — lista de pacientes vinculados con
-- métricas resumidas (tomas pendientes hoy, alertas de severidad esta semana).
-- El backend filtra por doctor_id desde el JWT.
-- =============================================================================

CREATE OR REPLACE VIEW rememberme.v_doctor_dashboard AS
SELECT
  -- Datos del médico
  dpl.doctor_id,
  d.full_name                                                 AS doctor_name,

  -- Datos del paciente
  dpl.patient_id,
  p.full_name                                                 AS patient_name,
  p.email                                                     AS patient_email,
  p.phone                                                     AS patient_phone,
  p.date_of_birth                                             AS patient_dob,

  -- Datos del vínculo
  dpl.id                                                      AS link_id,
  dpl.status                                                  AS link_status,
  dpl.created_at                                              AS linked_at,

  -- Condiciones crónicas del perfil clínico
  mp.chronic_conditions,
  mp.allergies,

  -- Tomas pendientes hoy
  COUNT(il.id) FILTER (
    WHERE il.scheduled_date = CURRENT_DATE
      AND il.status = 'pending'
  )                                                           AS pending_intakes_today,

  -- Tomas tomadas hoy
  COUNT(il.id) FILTER (
    WHERE il.scheduled_date = CURRENT_DATE
      AND il.status = 'taken'
  )                                                           AS taken_intakes_today,

  -- Alertas de alta severidad en los últimos 7 días
  COUNT(se.id) FILTER (
    WHERE se.severity >= 8
      AND se.entry_date >= CURRENT_DATE - INTERVAL '7 days'
  )                                                           AS high_severity_alerts_week,

  -- Medicamentos activos del paciente
  COUNT(DISTINCT m.id) FILTER (
    WHERE m.is_active = TRUE
  )                                                           AS active_medications

FROM
  rememberme.doctor_patient_links  dpl
  JOIN rememberme.users            d   ON dpl.doctor_id   = d.id
  JOIN rememberme.users            p   ON dpl.patient_id  = p.id
  LEFT JOIN rememberme.medical_profiles mp ON mp.user_id  = dpl.patient_id
  LEFT JOIN rememberme.medications      m  ON m.patient_id = dpl.patient_id
  LEFT JOIN rememberme.intake_logs      il ON il.medication_id = m.id
  LEFT JOIN rememberme.symptom_entries  se ON se.patient_id   = dpl.patient_id

WHERE
  dpl.status = 'active'

GROUP BY
  dpl.doctor_id, d.full_name,
  dpl.patient_id, p.full_name, p.email, p.phone, p.date_of_birth,
  dpl.id, dpl.status, dpl.created_at,
  mp.chronic_conditions, mp.allergies;

COMMENT ON VIEW rememberme.v_doctor_dashboard IS
  'Panel de pacientes vinculados para el médico. Incluye métricas de hoy y alertas de la semana.
   Filtrar por doctor_id en el backend según JWT.';


-- =============================================================================
-- SECCIÓN 6 · VISTA: v_high_severity_alerts
-- =============================================================================
-- Uso principal: GET /api/symptoms/history/{patientId} — sección de alertas.
-- Lista todos los síntomas con severity >= 8, ordenados por fecha y severidad.
-- El campo `high_severity_alert` es siempre TRUE aquí (se filtra en la vista).
-- =============================================================================

CREATE OR REPLACE VIEW rememberme.v_high_severity_alerts AS
SELECT
  se.id                           AS symptom_id,
  se.patient_id,
  u.full_name                     AS patient_name,
  se.symptom_name,
  se.severity,
  se.notes,
  se.entry_date,
  se.created_at,
  TRUE                            AS high_severity_alert,   -- siempre TRUE aquí
  CURRENT_DATE - se.entry_date    AS days_ago
FROM
  rememberme.symptom_entries  se
  JOIN rememberme.users       u ON se.patient_id = u.id
WHERE
  se.severity >= 8
ORDER BY
  se.entry_date  DESC,
  se.severity    DESC;

COMMENT ON VIEW rememberme.v_high_severity_alerts IS
  'Síntomas con severity >= 8 (high_severity_alert = TRUE). Ordenados por fecha y severidad desc.';


-- =============================================================================
-- SECCIÓN 7 · VISTA: v_medication_schedule
-- =============================================================================
-- Uso principal: módulo "Mis Medicamentos" y recordatorios del dashboard.
-- Muestra medicamentos activos con la próxima toma pendiente y el estado
-- calculado del tratamiento (activo / último día / vencido / crónico).
-- =============================================================================

CREATE OR REPLACE VIEW rememberme.v_medication_schedule AS
SELECT
  m.id                          AS medication_id,
  m.patient_id,
  u.full_name                   AS patient_name,
  m.name                        AS medication_name,
  m.dosage,
  m.frequency_hours,
  m.instructions,
  m.start_date,
  m.end_date,
  m.is_active,
  m.created_at                  AS medication_created_at,

  -- Estado calculado del tratamiento
  CASE
    WHEN m.end_date IS NULL          THEN 'crónico'
    WHEN m.end_date <  CURRENT_DATE  THEN 'vencido'
    WHEN m.end_date =  CURRENT_DATE  THEN 'último día'
    ELSE                                  'activo'
  END                           AS treatment_status,

  -- Timestamp de la próxima toma pendiente
  MIN(
    (il.scheduled_date + il.scheduled_time)::TIMESTAMP
  )                             AS next_intake_at,

  -- Cantidad de tomas pendientes a partir de hoy
  COUNT(il.id) FILTER (
    WHERE il.status = 'pending'
      AND il.scheduled_date >= CURRENT_DATE
  )                             AS pending_intakes_count

FROM
  rememberme.medications    m
  JOIN rememberme.users     u  ON m.patient_id = u.id
  LEFT JOIN rememberme.intake_logs il
    ON  il.medication_id  = m.id
    AND il.status         = 'pending'
    AND il.scheduled_date >= CURRENT_DATE

WHERE
  m.is_active = TRUE

GROUP BY
  m.id, m.patient_id, u.full_name, m.name, m.dosage,
  m.frequency_hours, m.instructions, m.start_date, m.end_date,
  m.is_active, m.created_at;

COMMENT ON VIEW rememberme.v_medication_schedule IS
  'Medicamentos activos con próxima toma pendiente y estado del tratamiento calculado.
   Filtrar por patient_id en el backend.';


-- =============================================================================
-- SECCIÓN 8 · VISTA: v_active_links
-- =============================================================================
-- Uso principal: GET /api/links/patients y GET /api/links/my-doctor
-- Lista los vínculos activos enriquecidos con datos básicos de ambas partes.
-- `expires_at` aplica solo cuando status = 'pending' (calculado con +24h).
-- =============================================================================

CREATE OR REPLACE VIEW rememberme.v_active_links AS
SELECT
  dpl.id                                              AS link_id,
  dpl.link_code,
  dpl.status,
  dpl.created_at,

  -- Expiración calculada (solo relevante mientras status = 'pending')
  dpl.created_at + INTERVAL '24 hours'                AS expires_at,
  rememberme.fn_link_is_expired(dpl.created_at, dpl.status)
                                                      AS is_expired,

  -- Datos del médico
  dpl.doctor_id,
  d.full_name                                         AS doctor_name,
  d.email                                             AS doctor_email,

  -- Datos del paciente (NULL mientras status = 'pending')
  dpl.patient_id,
  p.full_name                                         AS patient_name,
  p.email                                             AS patient_email,
  p.phone                                             AS patient_phone

FROM
  rememberme.doctor_patient_links  dpl
  JOIN rememberme.users            d ON dpl.doctor_id = d.id
  LEFT JOIN rememberme.users       p ON dpl.patient_id = p.id;

COMMENT ON VIEW rememberme.v_active_links IS
  'Vínculos médico-paciente con datos de ambas partes, expires_at y is_expired calculados.
   Filtrar por doctor_id o patient_id en el backend según el rol del JWT.';


-- =============================================================================
-- SECCIÓN 9 · VISTA: v_symptom_history
-- =============================================================================
-- Uso principal: GET /api/symptoms/history y GET /api/symptoms/history/{patientId}
-- Historial de síntomas con `high_severity_alert` calculado en runtime.
-- El campo `days_ago` facilita el filtrado temporal en el frontend.
-- =============================================================================

CREATE OR REPLACE VIEW rememberme.v_symptom_history AS
SELECT
  se.id                             AS symptom_id,
  se.patient_id,
  u.full_name                       AS patient_name,
  se.symptom_name,
  se.severity,
  se.notes,
  se.entry_date,
  se.created_at,
  se.updated_at,
  -- Campo calculado: alerta de alta severidad
  se.severity >= 8                  AS high_severity_alert,
  CURRENT_DATE - se.entry_date      AS days_ago
FROM
  rememberme.symptom_entries  se
  JOIN rememberme.users       u ON se.patient_id = u.id
ORDER BY
  se.entry_date  DESC,
  se.created_at  DESC;

COMMENT ON VIEW rememberme.v_symptom_history IS
  'Historial completo de síntomas con high_severity_alert calculado.
   Filtrar por patient_id en el backend. Usar para el propio paciente y para el médico vinculado.';


-- =============================================================================
-- SECCIÓN 10 · PERMISOS SOBRE VISTAS Y FUNCIONES
-- =============================================================================

-- Vistas: solo SELECT (sin INSERT/UPDATE/DELETE sobre las vistas)
GRANT SELECT ON rememberme.v_today_intake         TO rememberme_role;
GRANT SELECT ON rememberme.v_patient_adherence    TO rememberme_role;
GRANT SELECT ON rememberme.v_adherence_streak     TO rememberme_role;
GRANT SELECT ON rememberme.v_doctor_dashboard     TO rememberme_role;
GRANT SELECT ON rememberme.v_high_severity_alerts TO rememberme_role;
GRANT SELECT ON rememberme.v_medication_schedule  TO rememberme_role;
GRANT SELECT ON rememberme.v_active_links         TO rememberme_role;
GRANT SELECT ON rememberme.v_symptom_history      TO rememberme_role;

-- Funciones auxiliares usadas en las vistas
GRANT EXECUTE ON FUNCTION rememberme.fn_intake_is_adherent(TIMESTAMPTZ, DATE, TIME)
  TO rememberme_role;

GRANT EXECUTE ON FUNCTION rememberme.fn_link_is_expired(TIMESTAMPTZ, rememberme.link_status_enum)
  TO rememberme_role;


-- =============================================================================
-- SECCIÓN 11 · GUÍA DE USO PARA EL BACKEND EXPRESS
-- =============================================================================
--
-- GET /api/intake-logs/today
--   SELECT * FROM rememberme.v_today_intake
--   WHERE patient_id = $1;
--
-- GET /api/intake-logs/stats
--   SELECT * FROM rememberme.v_patient_adherence WHERE patient_id = $1;
--   SELECT streak FROM rememberme.v_adherence_streak WHERE patient_id = $1;
--
-- GET /api/symptoms/history (paciente propio)
--   SELECT * FROM rememberme.v_symptom_history
--   WHERE patient_id = $1
--   ORDER BY entry_date DESC
--   LIMIT $2 OFFSET $3;
--
-- GET /api/symptoms/history/:patientId (médico vinculado)
--   SELECT * FROM rememberme.v_symptom_history
--   WHERE patient_id = $1;
--   -- Validar antes que doctor_id tenga vínculo activo con $1
--
-- Panel médico
--   SELECT * FROM rememberme.v_doctor_dashboard WHERE doctor_id = $1;
--
-- GET /api/links/patients (médico)
--   SELECT * FROM rememberme.v_active_links
--   WHERE doctor_id = $1 AND status = 'active';
--
-- GET /api/links/my-doctor (paciente)
--   SELECT * FROM rememberme.v_active_links
--   WHERE patient_id = $1 AND status = 'active';
--
-- Medicamentos activos con próxima toma
--   SELECT * FROM rememberme.v_medication_schedule
--   WHERE patient_id = $1;
--
-- Alertas clínicas de un paciente (para el médico)
--   SELECT * FROM rememberme.v_high_severity_alerts
--   WHERE patient_id = $1
--   AND entry_date >= CURRENT_DATE - INTERVAL '7 days';
--
-- =============================================================================
-- FIN DE 03_views.sql
-- =============================================================================
