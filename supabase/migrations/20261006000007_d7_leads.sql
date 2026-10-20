-- =============================================================================
-- D7 — Leads: waitlist, school inquiries, driver applications, contact form
-- =============================================================================
-- CONVENTIONS (binding, restated from D1 — they still hold):
--   * Objects are written UNQUALIFIED. The target schema is set by the
--     SET search_path line below, which db/apply-schema.mjs rewrites when
--     rendering the demo variant. The single exception is the 'public'
--     literal inside a SECURITY DEFINER SET search_path clause.
--   * Singular snake_case tables, snake_case columns.
--   * Timestamps: timestamptz, column suffix _at.
--   * Constraint names: pk_, fk_<table>_<column>, uq_, ck_<table>_<col>,
--     idx_<table>_<cols>, trg_<table>_<event>.
--   * Every table gets created_at, updated_at, and trg_<table>_updated_at.
--   * Actor pointers (assigned_to) are plain uuids with no FK.
--   * NO RLS in this file. RLS is applied in D8, across every table.
--
-- ENUMS reused from D1, not redeclared: lead_status, lead_source, app_role.
--
-- DEPENDENCIES: app_user (D1), school (D3).
--
-- WHAT THIS FILE IS FOR
--   Driver and school accounts are NOT self-provisioned (D1, app_user NOTE).
--   The B2 auth flow creates a pending app_user plus a lead row pointing at
--   it; an admin reviews the lead and calls promote_lead_to_role(), which is
--   the ONLY sanctioned path from "someone filled in a form" to "this account
--   is a driver / a school". Waitlist and contact-form leads usually carry no
--   app_user at all.
--
-- PII
--   A lead is a stranger who has not signed a contract with us. We keep the
--   minimum needed to call them back: a name, a phone and/or an email, a
--   locale and their message. No CNIC, no address, no child details. Anything
--   more is collected later, inside the proper tables, once they are a
--   customer, driver or school.
-- =============================================================================

SET search_path TO public, extensions;

-- -----------------------------------------------------------------------------
-- lead
-- -----------------------------------------------------------------------------

CREATE TABLE lead (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source            lead_source NOT NULL,
  status            lead_status NOT NULL DEFAULT 'new',

  contact_name      text        NOT NULL,
  phone             text,
  email             text,
  -- Digits only, with a Pakistani leading 0 rewritten to the 92 country code,
  -- so '0300-1234567', '+92 300 1234567' and '923001234567' all compare equal.
  phone_normalized  text GENERATED ALWAYS AS (
                      regexp_replace(regexp_replace(phone, '\D', '', 'g'), '^0', '92')
                    ) STORED,
  preferred_locale  text        NOT NULL DEFAULT 'en',
  message           text,

  school_id         uuid,
  app_user_id       uuid,
  assigned_to       uuid,

  consent_at        timestamptz,
  consent_version   text,

  contacted_at      timestamptz,
  converted_at      timestamptz,
  closed_at         timestamptz,
  closed_reason     text,

  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT fk_lead_school_id FOREIGN KEY (school_id)
    REFERENCES school (id) ON DELETE SET NULL,
  CONSTRAINT fk_lead_app_user_id FOREIGN KEY (app_user_id)
    REFERENCES app_user (id) ON DELETE SET NULL,

  CONSTRAINT ck_lead_contact_name CHECK (contact_name ~ '\S'),
  CONSTRAINT ck_lead_contact_present CHECK (
    (phone IS NOT NULL AND phone ~ '\d') OR (email IS NOT NULL AND email ~ '\S')
  ),
  CONSTRAINT ck_lead_email_shape CHECK (email IS NULL OR email ~ '^\S+@\S+$'),
  CONSTRAINT ck_lead_preferred_locale CHECK (preferred_locale IN ('en', 'ur')),
  CONSTRAINT ck_lead_consent_paired CHECK (
    (consent_at IS NULL AND consent_version IS NULL)
    OR (consent_at IS NOT NULL AND consent_version IS NOT NULL)
  ),
  CONSTRAINT ck_lead_closed_reason CHECK (
    status <> 'closed' OR (closed_reason IS NOT NULL AND closed_reason ~ '\S')
  )
);

COMMENT ON TABLE lead IS
  'Inbound interest: waitlist, school inquiry, driver application, contact '
  'form. Minimal PII by design: name, phone and/or email, locale, message. '
  'RETENTION: a lead is kept while open. Once converted or closed its contact '
  'fields are to be purged (or the row deleted) after 12 months by an admin '
  'job; a converted lead''s person lives on in app_user, so nothing of value '
  'is lost. Never copy lead PII into analytics or logs.';
COMMENT ON COLUMN lead.phone_normalized IS
  'Generated: phone stripped to digits, leading 0 rewritten to 92. Exists only '
  'for dedup (uq_lead_one_open_per_phone_source). Never display it.';
COMMENT ON COLUMN lead.school_id IS
  'Set for a school inquiry about an existing school row. NULL when the school '
  'is not yet in the system (the name then lives in message).';
COMMENT ON COLUMN lead.app_user_id IS
  'The pending app_user the B2 flow created for this applicant. '
  'promote_lead_to_role() changes that account''s role and converts the lead.';
COMMENT ON COLUMN lead.assigned_to IS
  'Admin app_user.id handling this lead. Plain uuid, no FK, like every actor '
  'pointer in this schema.';
COMMENT ON COLUMN lead.consent_at IS
  'When the person agreed to be contacted. Paired with consent_version by '
  'ck_lead_consent_paired: a timestamp without the text version shown proves '
  'nothing.';
COMMENT ON COLUMN lead.status IS
  'Forward-only: new -> contacted -> qualified -> converted, or -> closed from '
  'any non-converted state. Enforced by trg_lead_status_lifecycle.';
COMMENT ON COLUMN lead.closed_reason IS
  'Required (non-blank) when status = closed, by ck_lead_closed_reason. A lead '
  'closed with no reason cannot be reviewed later.';

CREATE INDEX idx_lead_school_id   ON lead (school_id);
CREATE INDEX idx_lead_app_user_id ON lead (app_user_id);
CREATE INDEX idx_lead_status_created_at ON lead (status, created_at);

-- -----------------------------------------------------------------------------
-- Dedup: one OPEN lead per phone per source
-- -----------------------------------------------------------------------------
-- A parent who submits the waitlist form three times must not become three
-- callbacks. Scoped to source because the same person can legitimately be a
-- waitlist parent and a driver applicant. Once a lead is converted or closed
-- the same phone may come back as a fresh lead.
-- -----------------------------------------------------------------------------

CREATE UNIQUE INDEX uq_lead_one_open_per_phone_source
  ON lead (source, phone_normalized)
  WHERE phone_normalized IS NOT NULL
    AND phone_normalized <> ''
    AND status NOT IN ('converted', 'closed');

-- -----------------------------------------------------------------------------
-- Status lifecycle guard
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION enforce_lead_status_lifecycle()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'new' THEN
      RAISE EXCEPTION
        'trg_lead_status_lifecycle: a lead must be created with status new (got %)',
        NEW.status
        USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  IF NOT (
       (OLD.status = 'new'       AND NEW.status = 'contacted')
    OR (OLD.status = 'contacted' AND NEW.status = 'qualified')
    OR (OLD.status = 'qualified' AND NEW.status = 'converted')
    OR (OLD.status IN ('new', 'contacted', 'qualified') AND NEW.status = 'closed')
  ) THEN
    RAISE EXCEPTION
      'trg_lead_status_lifecycle: illegal lead transition % -> % (lead %)',
      OLD.status, NEW.status, OLD.id
      USING ERRCODE = 'check_violation';
  END IF;

  CASE NEW.status
    WHEN 'contacted' THEN NEW.contacted_at := now();
    WHEN 'converted' THEN NEW.converted_at := now();
    WHEN 'closed'    THEN NEW.closed_at    := now();
    ELSE NULL;
  END CASE;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION enforce_lead_status_lifecycle() IS
  'BEFORE INSERT OR UPDATE guard on lead: inserts start at new; updates move '
  'one step forward (new -> contacted -> qualified -> converted) or to closed '
  'from any non-converted state, and stamp the matching *_at column. Converted '
  'and closed are terminal. Without this, a converted lead can be reopened and '
  'the dedup index stops meaning anything.';

CREATE TRIGGER trg_lead_status_lifecycle
  BEFORE INSERT OR UPDATE OF status ON lead
  FOR EACH ROW EXECUTE FUNCTION enforce_lead_status_lifecycle();

CREATE TRIGGER trg_lead_updated_at
  BEFORE UPDATE ON lead
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- promote_lead_to_role
-- -----------------------------------------------------------------------------
-- The admin action that turns a qualified driver application / school inquiry
-- into a real account. SECURITY DEFINER because the admin's own session does
-- not own other users' app_user rows once D8 turns RLS on.
--
-- D8 MUST: REVOKE EXECUTE ON FUNCTION promote_lead_to_role(uuid, app_role)
--          FROM PUBLIC, anon;  (the is_admin() check below is the real gate,
--          the revoke removes the surface).
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION promote_lead_to_role(p_lead_id uuid, p_role app_role)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_app_user_id uuid;
BEGIN
  IF NOT is_admin() THEN
    RAISE EXCEPTION 'promote_lead_to_role: admin only'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_role IS NULL OR p_role NOT IN ('driver', 'school') THEN
    RAISE EXCEPTION 'promote_lead_to_role: role must be driver or school (got %)',
      coalesce(p_role::text, 'NULL')
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT l.app_user_id INTO v_app_user_id
    FROM lead l WHERE l.id = p_lead_id
    FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'promote_lead_to_role: no lead %', p_lead_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF v_app_user_id IS NULL THEN
    RAISE EXCEPTION 'promote_lead_to_role: lead % has no linked app_user', p_lead_id
      USING ERRCODE = 'check_violation';
  END IF;

  UPDATE app_user SET role = p_role WHERE id = v_app_user_id;

  -- The lifecycle trigger refuses this unless the lead is qualified, which
  -- rolls back the role change above with it.
  UPDATE lead SET status = 'converted' WHERE id = p_lead_id;
END;
$$;

COMMENT ON FUNCTION promote_lead_to_role(uuid, app_role) IS
  'Admin only (is_admin(), else 42501). Sets the lead''s linked app_user role '
  'to driver or school and marks the lead converted (lead must be qualified). '
  'Atomic: a refused transition undoes the role change. The account still has '
  'to pass D4 verification before it can carry a child. D8 must REVOKE '
  'EXECUTE FROM PUBLIC, anon.';
