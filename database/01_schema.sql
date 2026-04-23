-- =============================================================================
-- RememberMe-d — Esquema Principal de Base de Datos
-- Universidad Politécnica de Chiapas · AWOS
-- Equipo: Luis Ángel Pérez Aguilera (243757),
--         Héctor Isaac Espinoza Mendoza (243751),
--         Fernando Mora Mercado (243743)
-- Versión: 1.0.0 · Ejecutar como superusuario de PostgreSQL
-- =============================================================================
-- ORDEN DE EJECUCIÓN:
--   01_schema.sql  → este archivo  (DDL, usuario, permisos)
--   02_seed.sql    → datos mock
--   03_views.sql   → vistas y objetos derivados
-- =============================================================================


-- =============================================================================
-- SECCIÓN 0 · SEGURIDAD: ROL Y USUARIO DE APLICACIÓN
-- =============================================================================
-- El backend Express se conecta ÚNICAMENTE con el usuario `rememberme_app`.
-- Este usuario no tiene privilegios de superusuario, no puede crear bases de
-- datos ni otros roles. Solo opera sobre el esquema `rememberme`.
-- La contraseña debe moverse a una variable de entorno en producción.
-- =============================================================================

-- Rol base sin capacidad de login (agrupa los permisos)
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'rememberme_role') THEN
    CREATE ROLE rememberme_role
      NOLOGIN
      NOSUPERUSER
      NOCREATEDB
      NOCREATEROLE
      NOINHERIT;
  END IF;
END
$$;

-- Usuario de aplicación: el único que el backend Express usará
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'rememberme_app') THEN
    CREATE USER rememberme_app WITH
      PASSWORD 'RemMe_AppP@ss_2026!'   -- ⚠ cambiar por variable de entorno en producción
      NOSUPERUSER
      NOCREATEDB
      NOCREATEROLE
      INHERIT
      LOGIN
      CONNECTION LIMIT 20;
  END IF;
END
$$;

-- Vincular usuario al rol
GRANT rememberme_role TO rememberme_app;

-- Fijar search_path del usuario de aplicación al esquema del proyecto
ALTER USER rememberme_app SET search_path TO rememberme, public;


-- =============================================================================
-- SECCIÓN 1 · ESQUEMA DEDICADO
-- =============================================================================
-- Todas las tablas, vistas, funciones y tipos viven bajo `rememberme`.
-- Esto aísla el proyecto de otros schemas y facilita backups selectivos.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS rememberme;

-- Revocar acceso público al esquema antes de otorgarlo selectivamente
REVOKE ALL ON SCHEMA rememberme FROM PUBLIC;
GRANT USAGE ON SCHEMA rememberme TO rememberme_role;


-- =============================================================================
-- SECCIÓN 2 · TIPOS ENUMERADOS (ENUMS)
-- =============================================================================

-- Roles del sistema
DO $$ BEGIN
  CREATE TYPE rememberme.role_enum AS ENUM ('PATIENT', 'DOCTOR');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Estados de una toma programada
DO $$ BEGIN
  CREATE TYPE rememberme.intake_status_enum AS ENUM (
    'pending',  -- aún no confirmada
    'taken',    -- confirmada dentro de la ventana
    'skipped',  -- omitida por el paciente
    'late'      -- confirmada fuera de la ventana de ±2h
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Estados del vínculo médico-paciente
DO $$ BEGIN
  CREATE TYPE rememberme.link_status_enum AS ENUM (
    'pending',  -- código generado, esperando que el médico lo reclame
    'active',   -- vínculo activo y vigente
    'revoked'   -- vínculo disuelto (soft delete)
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;


-- =============================================================================
-- SECCIÓN 3 · TABLAS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 3.1  users
-- Entidad raíz del sistema. Almacena la identidad y el rol de cada persona.
-- El campo `password_hash` guarda el resultado de bcrypt (nunca texto plano).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rememberme.users (
  id            SERIAL         PRIMARY KEY,
  email         VARCHAR(255)   NOT NULL,
  password_hash VARCHAR(255)   NOT NULL,
  full_name     VARCHAR(255)   NOT NULL,
  phone         VARCHAR(20),
  role          rememberme.role_enum NOT NULL,
  date_of_birth DATE,
  created_at    TIMESTAMPTZ    NOT NULL DEFAULT NOW(),

  -- Restricciones de dominio
  CONSTRAINT uq_users_email
    UNIQUE (email),

  CONSTRAINT chk_users_email_format
    CHECK (email ~* '^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$'),

  CONSTRAINT chk_users_full_name_length
    CHECK (LENGTH(TRIM(full_name)) >= 2),

  CONSTRAINT chk_users_password_hash_length
    CHECK (LENGTH(password_hash) >= 20),

  CONSTRAINT chk_users_dob_past
    CHECK (date_of_birth IS NULL OR date_of_birth < CURRENT_DATE),

  CONSTRAINT chk_users_phone_format
    CHECK (phone IS NULL OR phone ~ '^[0-9+\-\s()]{7,20}$')
);

COMMENT ON TABLE rememberme.users IS
  'Entidad raíz. Almacena credenciales, rol y datos básicos de cada usuario.';
COMMENT ON COLUMN rememberme.users.password_hash IS
  'Hash bcrypt de la contraseña. Nunca almacenar texto plano.';


-- -----------------------------------------------------------------------------
-- 3.2  medical_profiles
-- Extensión clínica 1:1 del paciente. Se crea automáticamente al registrar
-- un usuario con rol PATIENT (responsabilidad del backend).
-- Se desagrega emergency_contact en tres columnas para mejor normalización.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rememberme.medical_profiles (
  id                         SERIAL       PRIMARY KEY,
  user_id                    INTEGER      NOT NULL,
  allergies                  TEXT,
  chronic_conditions         TEXT,
  emergency_contact_name     VARCHAR(255),
  emergency_contact_phone    VARCHAR(20),
  emergency_contact_relation VARCHAR(100),
  created_at                 TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at                 TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  CONSTRAINT fk_medical_profiles_user
    FOREIGN KEY (user_id) REFERENCES rememberme.users(id)
    ON DELETE CASCADE,

  -- Garantiza la relación 1:1 a nivel de base de datos
  CONSTRAINT uq_medical_profiles_user
    UNIQUE (user_id),

  CONSTRAINT chk_medical_profiles_phone_format
    CHECK (
      emergency_contact_phone IS NULL
      OR emergency_contact_phone ~ '^[0-9+\-\s()]{7,20}$'
    )
);

COMMENT ON TABLE rememberme.medical_profiles IS
  'Ficha clínica extendida del paciente (1:1 con users). Solo aplica a PATIENT.';


-- -----------------------------------------------------------------------------
-- 3.3  medications
-- Registro de tratamientos del paciente. Su creación en el backend dispara
-- la generación automática de tomas en intake_logs.
-- `end_date` NULL indica tratamiento crónico.
-- `is_active = FALSE` es soft delete (preserva historial).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rememberme.medications (
  id              SERIAL        PRIMARY KEY,
  patient_id      INTEGER       NOT NULL,
  name            VARCHAR(255)  NOT NULL,
  dosage          VARCHAR(100)  NOT NULL,
  frequency_hours INTEGER       NOT NULL,
  start_date      DATE          NOT NULL,
  end_date        DATE,
  instructions    TEXT,
  is_active       BOOLEAN       NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

  CONSTRAINT fk_medications_patient
    FOREIGN KEY (patient_id) REFERENCES rememberme.users(id)
    ON DELETE CASCADE,

  -- Solo intervalos definidos por el dominio (horas entre tomas)
  CONSTRAINT chk_medications_frequency
    CHECK (frequency_hours IN (4, 6, 8, 12, 24)),

  -- La fecha de fin no puede ser anterior a la de inicio
  CONSTRAINT chk_medications_end_date
    CHECK (end_date IS NULL OR end_date >= start_date),

  CONSTRAINT chk_medications_name_not_empty
    CHECK (LENGTH(TRIM(name)) >= 1),

  CONSTRAINT chk_medications_dosage_not_empty
    CHECK (LENGTH(TRIM(dosage)) >= 1)
);

COMMENT ON TABLE rememberme.medications IS
  'Tratamientos activos o históricos del paciente. La creación genera intake_logs automáticamente.';
COMMENT ON COLUMN rememberme.medications.is_active IS
  'FALSE = soft delete. No borrar físicamente para conservar historial de adherencia.';
COMMENT ON COLUMN rememberme.medications.end_date IS
  'NULL indica tratamiento crónico (renovación automática de 30 días en backend).';


-- -----------------------------------------------------------------------------
-- 3.4  intake_logs
-- Cada fila representa una toma individual programada.
-- El par (medication_id, scheduled_date, scheduled_time) es único.
-- `is_adherent` se calcula en runtime (backend/vista), no se almacena.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rememberme.intake_logs (
  id             SERIAL                        PRIMARY KEY,
  medication_id  INTEGER                       NOT NULL,
  scheduled_date DATE                          NOT NULL,
  scheduled_time TIME                          NOT NULL,
  taken_at       TIMESTAMPTZ,
  status         rememberme.intake_status_enum NOT NULL DEFAULT 'pending',
  created_at     TIMESTAMPTZ                   NOT NULL DEFAULT NOW(),

  CONSTRAINT fk_intake_logs_medication
    FOREIGN KEY (medication_id) REFERENCES rememberme.medications(id)
    ON DELETE CASCADE,

  -- Si el estado es 'taken', debe haber un timestamp de confirmación
  CONSTRAINT chk_intake_logs_taken_requires_timestamp
    CHECK (
      (status = 'taken' AND taken_at IS NOT NULL) OR
      (status <> 'taken')
    ),

  -- No se puede registrar taken_at en el futuro
  CONSTRAINT chk_intake_logs_taken_at_not_future
    CHECK (taken_at IS NULL OR taken_at <= NOW() + INTERVAL '5 minutes'),

  -- Un mismo slot de toma no puede duplicarse
  CONSTRAINT uq_intake_logs_slot
    UNIQUE (medication_id, scheduled_date, scheduled_time)
);

COMMENT ON TABLE rememberme.intake_logs IS
  'Registro de cada toma individual. Generado automáticamente al crear un medicamento.';
COMMENT ON COLUMN rememberme.intake_logs.taken_at IS
  'Timestamp real de confirmación. Obligatorio cuando status = taken.';


-- -----------------------------------------------------------------------------
-- 3.5  symptom_entries
-- Bitácora diaria de síntomas del paciente.
-- Un mismo síntoma no puede registrarse dos veces el mismo día (uq_per_day).
-- `high_severity_alert` (severity >= 8) se calcula en runtime.
-- `symptom_name` es texto libre en esta versión (MVP).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rememberme.symptom_entries (
  id           SERIAL       PRIMARY KEY,
  patient_id   INTEGER      NOT NULL,
  symptom_name VARCHAR(255) NOT NULL,
  severity     SMALLINT     NOT NULL,
  notes        TEXT,
  entry_date   DATE         NOT NULL DEFAULT CURRENT_DATE,
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  CONSTRAINT fk_symptom_entries_patient
    FOREIGN KEY (patient_id) REFERENCES rememberme.users(id)
    ON DELETE CASCADE,

  -- Escala clínica 1-10 (documentada en propuesta y API spec)
  CONSTRAINT chk_symptom_severity_range
    CHECK (severity BETWEEN 1 AND 10),

  CONSTRAINT chk_symptom_name_not_empty
    CHECK (LENGTH(TRIM(symptom_name)) >= 1),

  -- No se puede registrar la misma queja dos veces el mismo día
  CONSTRAINT uq_symptom_per_day
    UNIQUE (patient_id, symptom_name, entry_date)
);

COMMENT ON TABLE rememberme.symptom_entries IS
  'Bitácora de síntomas diarios. Severity >= 8 activa high_severity_alert (calculado en runtime).';
COMMENT ON COLUMN rememberme.symptom_entries.symptom_name IS
  'Texto libre en MVP. En versión futura puede referenciar un catálogo `symptoms_catalog`.';


-- -----------------------------------------------------------------------------
-- 3.6  doctor_patient_links
-- Modela el vínculo entre médico y paciente mediante código alfanumérico.
-- Un paciente solo puede tener UN vínculo activo a la vez
-- (garantizado por índice único parcial en SECCIÓN 4).
-- La expiración (created_at + 24h) se calcula en runtime.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rememberme.doctor_patient_links (
  id         SERIAL                       PRIMARY KEY,
  doctor_id  INTEGER                      NOT NULL,
  patient_id INTEGER,                     -- NULL hasta que el médico reclame el código
  link_code  VARCHAR(10)                  NOT NULL,
  status     rememberme.link_status_enum  NOT NULL DEFAULT 'pending',
  created_at TIMESTAMPTZ                  NOT NULL DEFAULT NOW(),

  CONSTRAINT fk_links_doctor
    FOREIGN KEY (doctor_id) REFERENCES rememberme.users(id)
    ON DELETE CASCADE,

  CONSTRAINT fk_links_patient
    FOREIGN KEY (patient_id) REFERENCES rememberme.users(id)
    ON DELETE CASCADE,

  -- El código de vínculo debe ser único globalmente
  CONSTRAINT uq_link_code
    UNIQUE (link_code),

  -- Un usuario no puede vincularse consigo mismo
  CONSTRAINT chk_links_no_self_link
    CHECK (patient_id IS NULL OR doctor_id <> patient_id),

  -- El código debe tener entre 4 y 10 caracteres alfanuméricos
  CONSTRAINT chk_link_code_format
    CHECK (link_code ~ '^[A-Z0-9]{4,10}$')
);

COMMENT ON TABLE rememberme.doctor_patient_links IS
  'Vínculo médico-paciente por código. expires_at = created_at + 24h se calcula en runtime.';
COMMENT ON COLUMN rememberme.doctor_patient_links.patient_id IS
  'NULL mientras el código no ha sido reclamado (status = pending).';


-- =============================================================================
-- SECCIÓN 4 · ÍNDICES DE RENDIMIENTO
-- =============================================================================
-- Los índices cubren los patrones de consulta dominantes del sistema:
--   · Login por email (users)
--   · Medicamentos activos por paciente (medications)
--   · Dashboard diario de tomas (intake_logs por fecha)
--   · Historial de síntomas por paciente y fecha (symptom_entries)
--   · Búsqueda de vínculo activo (doctor_patient_links)
-- =============================================================================

-- ---- users ------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_users_email
  ON rememberme.users (email);

CREATE INDEX IF NOT EXISTS idx_users_role
  ON rememberme.users (role);

-- ---- medical_profiles -------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_medical_profiles_user
  ON rememberme.medical_profiles (user_id);

-- ---- medications ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_medications_patient
  ON rememberme.medications (patient_id);

-- Índice parcial: solo medicamentos activos (los más consultados)
CREATE INDEX IF NOT EXISTS idx_medications_active
  ON rememberme.medications (patient_id)
  WHERE is_active = TRUE;

CREATE INDEX IF NOT EXISTS idx_medications_dates
  ON rememberme.medications (start_date, end_date);

-- ---- intake_logs ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_intake_medication
  ON rememberme.intake_logs (medication_id);

CREATE INDEX IF NOT EXISTS idx_intake_date
  ON rememberme.intake_logs (scheduled_date);

CREATE INDEX IF NOT EXISTS idx_intake_status
  ON rememberme.intake_logs (status);

-- Índice compuesto para el dashboard diario (medication_id + fecha)
CREATE INDEX IF NOT EXISTS idx_intake_medication_date
  ON rememberme.intake_logs (medication_id, scheduled_date);

-- Índice compuesto para historial paginado (medication_id + fecha DESC)
CREATE INDEX IF NOT EXISTS idx_intake_medication_date_desc
  ON rememberme.intake_logs (medication_id, scheduled_date DESC);

-- ---- symptom_entries --------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_symptoms_patient
  ON rememberme.symptom_entries (patient_id);

CREATE INDEX IF NOT EXISTS idx_symptoms_date
  ON rememberme.symptom_entries (entry_date);

-- Índice compuesto para historial clínico ordenado por paciente y fecha
CREATE INDEX IF NOT EXISTS idx_symptoms_patient_date
  ON rememberme.symptom_entries (patient_id, entry_date DESC);

-- Índice parcial para alertas de alta severidad
CREATE INDEX IF NOT EXISTS idx_symptoms_high_severity
  ON rememberme.symptom_entries (patient_id, entry_date)
  WHERE severity >= 8;

-- ---- doctor_patient_links ---------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_links_doctor
  ON rememberme.doctor_patient_links (doctor_id);

CREATE INDEX IF NOT EXISTS idx_links_patient
  ON rememberme.doctor_patient_links (patient_id);

CREATE INDEX IF NOT EXISTS idx_links_status
  ON rememberme.doctor_patient_links (status);

CREATE INDEX IF NOT EXISTS idx_links_code
  ON rememberme.doctor_patient_links (link_code);

-- ============================================================
-- ÍNDICE ÚNICO PARCIAL: máximo un vínculo activo por paciente
-- Garantiza la regla RN-10 del dominio directamente en PostgreSQL.
-- El backend valida esto también, pero la BD es la última barrera.
-- ============================================================
CREATE UNIQUE INDEX IF NOT EXISTS uq_active_link_per_patient
  ON rememberme.doctor_patient_links (patient_id)
  WHERE status = 'active';


-- =============================================================================
-- SECCIÓN 5 · FUNCIÓN Y TRIGGERS: updated_at AUTOMÁTICO
-- =============================================================================
-- Evita que el backend tenga que enviar `updated_at` manualmente.
-- El trigger lo actualiza en cada UPDATE sobre las tablas que lo necesitan.
-- =============================================================================

CREATE OR REPLACE FUNCTION rememberme.fn_set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION rememberme.fn_set_updated_at() IS
  'Trigger function: actualiza automáticamente updated_at en cada UPDATE.';

-- medical_profiles
CREATE OR REPLACE TRIGGER trg_medical_profiles_updated_at
  BEFORE UPDATE ON rememberme.medical_profiles
  FOR EACH ROW EXECUTE FUNCTION rememberme.fn_set_updated_at();

-- medications
CREATE OR REPLACE TRIGGER trg_medications_updated_at
  BEFORE UPDATE ON rememberme.medications
  FOR EACH ROW EXECUTE FUNCTION rememberme.fn_set_updated_at();

-- symptom_entries
CREATE OR REPLACE TRIGGER trg_symptom_entries_updated_at
  BEFORE UPDATE ON rememberme.symptom_entries
  FOR EACH ROW EXECUTE FUNCTION rememberme.fn_set_updated_at();


-- =============================================================================
-- SECCIÓN 6 · FUNCIÓN AUXILIAR: validar que solo PATIENT registre medicamentos
-- =============================================================================
-- Esta función puede usarse como CHECK constraint o llamarse desde el backend.
-- Garantiza que un `patient_id` en `medications` sea efectivamente un PATIENT.
-- =============================================================================

CREATE OR REPLACE FUNCTION rememberme.fn_is_patient(p_user_id INTEGER)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM rememberme.users
    WHERE id = p_user_id AND role = 'PATIENT'
  );
$$;

COMMENT ON FUNCTION rememberme.fn_is_patient(INTEGER) IS
  'Retorna TRUE si el usuario existe y tiene rol PATIENT. Usada en constraints y backend.';

-- Aplicar constraint en medications usando la función auxiliar
ALTER TABLE rememberme.medications
  ADD CONSTRAINT chk_medications_patient_is_patient
  CHECK (rememberme.fn_is_patient(patient_id));

-- Aplicar constraint en symptom_entries usando la función auxiliar
ALTER TABLE rememberme.symptom_entries
  ADD CONSTRAINT chk_symptoms_patient_is_patient
  CHECK (rememberme.fn_is_patient(patient_id));


-- =============================================================================
-- SECCIÓN 7 · FUNCIÓN AUXILIAR: validar que doctor_id sea DOCTOR
-- =============================================================================

CREATE OR REPLACE FUNCTION rememberme.fn_is_doctor(p_user_id INTEGER)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM rememberme.users
    WHERE id = p_user_id AND role = 'DOCTOR'
  );
$$;

COMMENT ON FUNCTION rememberme.fn_is_doctor(INTEGER) IS
  'Retorna TRUE si el usuario existe y tiene rol DOCTOR.';

-- Aplicar constraint en doctor_patient_links
ALTER TABLE rememberme.doctor_patient_links
  ADD CONSTRAINT chk_links_doctor_is_doctor
  CHECK (rememberme.fn_is_doctor(doctor_id));


-- =============================================================================
-- SECCIÓN 8 · PERMISOS SOBRE OBJETOS DEL ESQUEMA
-- =============================================================================
-- El usuario `rememberme_app` obtiene permisos DML completos sobre las tablas
-- pero NO puede: DROP, TRUNCATE, GRANT, ALTER, ni ejecutar como superusuario.
-- =============================================================================

-- Tablas: SELECT + INSERT + UPDATE + DELETE (sin DROP, sin TRUNCATE)
GRANT SELECT, INSERT, UPDATE, DELETE
  ON ALL TABLES IN SCHEMA rememberme
  TO rememberme_role;

-- Secuencias: USAGE y SELECT para poder usar SERIAL / NEXTVAL
GRANT USAGE, SELECT
  ON ALL SEQUENCES IN SCHEMA rememberme
  TO rememberme_role;

-- Funciones auxiliares: EXECUTE
GRANT EXECUTE ON FUNCTION rememberme.fn_set_updated_at() TO rememberme_role;
GRANT EXECUTE ON FUNCTION rememberme.fn_is_patient(INTEGER) TO rememberme_role;
GRANT EXECUTE ON FUNCTION rememberme.fn_is_doctor(INTEGER) TO rememberme_role;

-- Tipos enumerados: USAGE (necesario para operar con columnas enum)
GRANT USAGE ON TYPE rememberme.role_enum        TO rememberme_role;
GRANT USAGE ON TYPE rememberme.intake_status_enum TO rememberme_role;
GRANT USAGE ON TYPE rememberme.link_status_enum   TO rememberme_role;

-- Heredar permisos automáticamente para tablas/secuencias creadas en el futuro
ALTER DEFAULT PRIVILEGES IN SCHEMA rememberme
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO rememberme_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA rememberme
  GRANT USAGE, SELECT ON SEQUENCES TO rememberme_role;


-- =============================================================================
-- SECCIÓN 9 · PROTECCIÓN ADICIONAL: revocar acceso residual de PUBLIC
-- =============================================================================
REVOKE ALL ON ALL TABLES    IN SCHEMA rememberme FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA rememberme FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA rememberme FROM PUBLIC;


-- =============================================================================
-- FIN DE 01_schema.sql
-- Continuar con 02_seed.sql y luego 03_views.sql
-- =============================================================================
