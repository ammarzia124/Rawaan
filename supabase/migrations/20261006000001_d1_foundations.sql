-- =============================================================================
-- D1 — Foundations, enums, and the user profile
-- =============================================================================
-- CONVENTIONS (binding for D2, D3, D4, D5, D6, D7, D8):
--   * Objects are written UNQUALIFIED. The target schema is set by the
--     SET search_path line below, which db/apply-schema.mjs rewrites when
--     rendering the demo variant. Do NOT hard-code a schema name anywhere
--     in this file.
--   * Plural snake_case tables, snake_case columns.
--   * Timestamps: timestamptz, column suffix _at. Never `timestamp`.
--   * Foreign key columns: _id. Constraints named:
--       pk_<table>              primary key
--       fk_<table>_<column>     foreign key
--       uq_<table>_<cols>       unique constraint
--       ck_<table>_<col>        check constraint
--       idx_<table>_<cols>      index
--       trg_<table>_<event>     trigger
--   * Money: integer paisa in bigint. 1 PKR = 100 paisa. Never float.
--   * Basis points stored in int; splits must sum to exactly 10000.
--   * Booleans prefixed is_ or has_.
--   * Every table gets updated_at, maintained by trg_set_updated_at.
--   * NO RLS in this file. RLS is applied in D8, across every table.
-- =============================================================================

SET search_path TO public, extensions;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA extensions;

-- -----------------------------------------------------------------------------
-- Enum types
-- -----------------------------------------------------------------------------

-- User role. Exactly these four values; "school" covers school admins.
CREATE TYPE app_role AS ENUM ('parent', 'driver', 'school', 'admin');

-- Driver / document verification lifecycle.
CREATE TYPE verification_status AS ENUM (
  'not_submitted',
  'pending_review',
  'needs_resubmission',
  'approved',
  'rejected',
  'suspended'
);

-- Identity and vehicle documents held in private storage.
CREATE TYPE document_type AS ENUM (
  'cnic_front',
  'cnic_back',
  'driving_license',
  'police_character_certificate',
  'vehicle_registration',
  'insurance_policy'
);

-- An enrollment's lifecycle. Only 'active' enrollments are billable.
CREATE TYPE enrollment_status AS ENUM ('active', 'paused', 'ended');

-- Trip state machine. Legal transitions are enforced by the
-- transition_trip() function in D5, not by a trigger.
CREATE TYPE trip_status AS ENUM (
  'scheduled',
  'driver_en_route',
  'arrived_pickup',
  'in_progress',
  'arrived_school',
  'completed',
  'cancelled',
  'no_show'
);

CREATE TYPE checkin_method AS ENUM ('qr_scan', 'manual_override');

-- Every QR scan attempt is recorded, including failures.
CREATE TYPE checkin_result AS ENUM (
  'success',
  'already_checked_in',
  'wrong_trip',
  'wrong_child',
  'expired_token',
  'child_absent'
);

CREATE TYPE absence_status AS ENUM ('submitted', 'acknowledged', 'cancelled');

CREATE TYPE invoice_status AS ENUM ('draft', 'issued', 'paid', 'overdue', 'void');

CREATE TYPE payment_status AS ENUM (
  'awaiting_submission',
  'submitted',
  'confirmed',
  'failed',
  'rejected',
  'refunded'
);

CREATE TYPE payout_status AS ENUM ('pending', 'processing', 'paid', 'failed', 'cancelled');

CREATE TYPE lead_status AS ENUM ('new', 'contacted', 'qualified', 'converted', 'closed');

CREATE TYPE lead_source AS ENUM (
  'waitlist',
  'school_inquiry',
  'driver_application',
  'contact_form'
);

-- -----------------------------------------------------------------------------
-- Shared trigger function: updated_at maintenance
-- -----------------------------------------------------------------------------
-- Reused by every table carrying an updated_at column. Written once.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION set_updated_at() IS
  'Sets NEW.updated_at to now(). Attached to every table with an updated_at column.';

-- -----------------------------------------------------------------------------
-- app_user — profile bridging Supabase Auth to the application
-- -----------------------------------------------------------------------------
-- Children are minors and never authenticate, so they get no app_user row.
-- Guardians, drivers, school staff and admins all do.
--
-- NOTE: driver and school accounts are NOT self-provisioned. The B2 auth flow
-- creates the row with a pending role and a lead record; an admin or school
-- admin promotes it. See MASTER_CONTEXT.md section 2.
-- -----------------------------------------------------------------------------

CREATE TABLE app_user (
  id                  uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  role                app_role      NOT NULL,
  full_name           text          NOT NULL CHECK (length(btrim(full_name)) > 0),
  phone               text,
  preferred_locale    text          NOT NULL DEFAULT 'en'
                                    CHECK (preferred_locale IN ('en', 'ur')),
  is_active           boolean       NOT NULL DEFAULT true,
  -- Parental consent. A parent cannot add a child without a recorded version.
  consent_given_at    timestamptz,
  consent_version     text,
  created_at          timestamptz   NOT NULL DEFAULT now(),
  updated_at          timestamptz   NOT NULL DEFAULT now(),
  CONSTRAINT ck_app_user_consent_paired CHECK (
    (consent_given_at IS NULL AND consent_version IS NULL)
    OR (consent_given_at IS NOT NULL AND consent_version IS NOT NULL)
  )
);

COMMENT ON TABLE app_user IS
  'Application profile for every authenticating human. Mirrors auth.users. '
  'Students do not authenticate and therefore have no row here.';
COMMENT ON COLUMN app_user.consent_version IS
  'Version identifier of the parental consent text shown at signup. '
  'Required before a guardian may be linked to a child (see guardian.consent_at).';

CREATE TRIGGER trg_app_user_updated_at
  BEFORE UPDATE ON app_user
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- Role and identity helpers
-- -----------------------------------------------------------------------------
-- These are the SINGLE source of truth for "who is the current user".
--
-- They are SECURITY DEFINER because anon/authenticated roles do not own
-- app_user rows. search_path is pinned to prevent object shadowing: an
-- attacker who can create objects in a schema on the path could otherwise
-- hijack the function body. db/apply-schema.mjs rewrites the 'public'
-- literal to the demo schema when rendering the demo variant, so these
-- must remain the ONLY place a schema name is written as a string literal.
--
-- Application code MUST call these rather than re-deriving permissions in
-- TypeScript. Duplicated permission logic drifts from the RLS policies and
-- eventually disagrees with them. See MASTER_CONTEXT.md section 5.2.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION current_app_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT a.id FROM app_user a WHERE a.id = auth.uid() AND a.is_active;
$$;

CREATE OR REPLACE FUNCTION current_app_role()
RETURNS app_role
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT a.role FROM app_user a WHERE a.id = auth.uid() AND a.is_active;
$$;

CREATE OR REPLACE FUNCTION is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(current_app_role() = 'admin', false);
$$;

COMMENT ON FUNCTION current_app_role() IS
  'Role of the calling user, or NULL when unauthenticated or inactive. '
  'Authoritative: do not re-derive this in application code.';
COMMENT ON FUNCTION is_admin() IS
  'True when the calling user has the admin role. Used by D8 RLS policies.';

-- -----------------------------------------------------------------------------
-- Structural assertions
-- -----------------------------------------------------------------------------
-- Every domain table (D2 onward) must carry updated_at and this trigger.
-- A table missing either will fail the D1 structural test.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION assert_updated_at_convention()
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  missing text;
BEGIN
  SELECT string_agg(c.relname, ', ')
    INTO missing
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'r'
    AND n.nspname = current_schema()
    AND c.relname NOT IN ('app_user')
    AND NOT EXISTS (
      SELECT 1 FROM pg_attribute a
      WHERE a.attrelid = c.oid
        AND a.attname = 'updated_at'
        AND NOT a.attisdropped
    );

  RETURN missing IS NULL;
END;
$$;

COMMENT ON FUNCTION assert_updated_at_convention() IS
  'Returns false when any table in the current schema lacks updated_at. '
  'Invoked by db/tests/d1_foundations.test.sql so the convention cannot regress.';
