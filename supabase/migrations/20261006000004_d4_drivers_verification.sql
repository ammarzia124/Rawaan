-- =============================================================================
-- D4 — Drivers, vehicles, and the verification pipeline
-- =============================================================================
-- CONVENTIONS (binding, restated from D1 — they still hold):
--   * Objects are written UNQUALIFIED. The target schema is set by the
--     SET search_path line below, which db/apply-schema.mjs rewrites when
--     rendering the demo variant. Do NOT hard-code a schema name anywhere
--     in this file. The single exception is the 'public' literal inside a
--     SECURITY DEFINER SET search_path clause, which is what the rewriter
--     keys off. Nothing else may write a schema name as a string.
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
--   * Booleans prefixed is_ or has_.
--   * Every table gets created_at, updated_at, and trg_<table>_updated_at
--     calling set_updated_at(). Reference tables count too: D1's
--     assert_updated_at_convention() fails any table in the schema that
--     lacks an updated_at column, so required_document carries timestamps.
--   * NO RLS in this file. RLS is applied in D8, across every table. The one
--     place that matters most here: driver_document must never become
--     readable to a parent or to a school, not even as metadata.
--
-- ENUMS reused from D1, not redeclared: verification_status, document_type.
--
-- DEPENDENCIES: app_user (D1) and school (D3). Both exist by the time this
-- migration runs, because migrations apply in filename order. No schema
-- name is needed to say so.
--
-- WHAT THIS FILE IS FOR
--   This migration is what makes the website's safety claim honest. Until
--   this pipeline exists AND has actually processed a driver end to end,
--   the public site must say "Verification process launching with our
--   pilot" and must NOT claim "CNIC + licence checked before any driver can
--   carry a child". That coupling is written into the schema as a COMMENT
--   ON TABLE driver, so it survives in code review rather than in somebody's
--   memory. See the comment at the end of the driver section.
-- =============================================================================

SET search_path TO public, extensions;

-- -----------------------------------------------------------------------------
-- driver — the person, their verification state, and the paperwork behind it
-- -----------------------------------------------------------------------------
-- A driver row exists the moment an admin promotes an app_user to the driver
-- role, which is long before that person has been verified. verification_status
-- is therefore the authority on whether this driver may carry a child, and it
-- is never inferred from the presence of documents.
--
-- KNOWN LIMITATION (documented, not enforced here): the role trigger below
-- fires on driver, not on app_user. Demoting an app_user from 'driver' to
-- 'parent' while a driver row exists is therefore not caught by this file.
-- That transition belongs to the admin flow in B-series, and D8's RLS decides
-- who is allowed to make it.
-- -----------------------------------------------------------------------------

CREATE TABLE driver (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_user_id         uuid NOT NULL,
  full_name           text NOT NULL CHECK (length(btrim(full_name)) > 0),
  phone               text NOT NULL CHECK (length(btrim(phone)) > 0),
  cnic_last4          text CHECK (cnic_last4 IS NULL OR cnic_last4 ~ '^[0-9]{4}$'),
  verification_status verification_status NOT NULL DEFAULT 'not_submitted',
  -- Human-readable note describing how the driver reached the current
  -- status, in plain language. Shown to the driver, so keep it addressable.
  status_reason       text,
  submitted_at        timestamptz,
  reviewed_by         uuid,
  reviewed_at         timestamptz,
  review_notes        text,
  rejection_reason    text,
  suspended_at        timestamptz,
  suspended_reason    text,
  -- NULL means "no ratings yet". 0.0 is therefore never a real rating, and a
  -- dashboard must not render it as a zero-star driver.
  rating              numeric(2,1) CHECK (rating IS NULL OR rating BETWEEN 0 AND 5),
  is_active           boolean      NOT NULL DEFAULT true,
  created_at          timestamptz  NOT NULL DEFAULT now(),
  updated_at          timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT fk_driver_app_user_id FOREIGN KEY (app_user_id)
    REFERENCES app_user(id) ON DELETE CASCADE,
  CONSTRAINT uq_driver_app_user_id UNIQUE (app_user_id),
  -- The rule the whole admin queue exists to enforce safely.
  CONSTRAINT ck_driver_rejected_requires_reason CHECK (
    verification_status <> 'rejected'
    OR (rejection_reason IS NOT NULL AND length(btrim(rejection_reason)) > 0)
  )
);

COMMENT ON TABLE driver IS
  'A driver profile: the person, their verification state, and the paperwork '
  'that backs it. driver plus driver_document IS the verification pipeline '
  'the website makes promises about. '
  'MARKETING COUPLING, do not let the two drift apart: until this pipeline has '
  'processed at least one real driver end to end, every public page must say '
  '"Verification process launching with our pilot" (MASTER_CONTEXT.md §9). It '
  'must NOT say "CNIC + licence checked before any driver can carry a child". '
  'That second sentence is a factual claim about THIS table, so this table has '
  'to be true before the sentence ships, not after. An empty driver table is '
  'not evidence that no unverified driver exists; it is evidence that nothing '
  'has been verified yet.';

COMMENT ON COLUMN driver.cnic_last4 IS
  'Last four digits of the CNIC ONLY, for display and for the driver''s own '
  'reference. The full CNIC image, and any other copy of the number, lives in '
  'private storage as a driver_document row. A full 13-digit national ID in '
  'this table would be a plaintext copy of a government identifier sitting in '
  'every query result, every export and every log line.';

COMMENT ON COLUMN driver.verification_status IS
  'The authority on whether this driver may carry a child. ''approved'' is the '
  'only value that unlocks a driver_school row. Never infer it from the '
  'presence of uploaded documents: uploads are not verification.';

COMMENT ON COLUMN driver.rejection_reason IS
  'Mandatory whenever verification_status = ''rejected'' (enforced by '
  'ck_driver_rejected_requires_reason). A rejection the driver cannot '
  'understand does not resolve, it converts into a WhatsApp call, a support '
  'ticket and a resubmission cycle that lengthens the time an unverified '
  'driver is one admin decision away from carrying a child. Write it for the '
  'driver: what is wrong, and what to upload instead.';

COMMENT ON COLUMN driver.status_reason IS
  'Plain-language explanation of the current status, distinct from '
  'rejection_reason. Shown to the driver at every status, not only on failure.';

-- Role guard. SECURITY DEFINER because the driver onboarding flow inserts
-- this row from a context that may not own app_user. search_path is pinned so
-- an attacker who can create objects in a schema on the path cannot hijack
-- the function body. See the identical note on current_app_role() in D1.

CREATE OR REPLACE FUNCTION enforce_driver_app_user_role()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role app_role;
BEGIN
  SELECT u.role INTO v_role FROM app_user u WHERE u.id = NEW.app_user_id;

  IF v_role IS DISTINCT FROM 'driver' THEN
    RAISE EXCEPTION
      'driver.app_user_id % must reference an app_user with role = ''driver'' (found: %)',
      NEW.app_user_id, coalesce(v_role::text, 'no such app_user')
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION enforce_driver_app_user_role() IS
  'BEFORE INSERT OR UPDATE guard on driver: app_user_id must point at an '
  'app_user whose role is ''driver''. A cross-table rule cannot be a CHECK '
  'constraint, and duplicating it in application code would drift from the '
  'database the moment a second code path exists.';

CREATE TRIGGER trg_driver_app_user_role
  BEFORE INSERT OR UPDATE ON driver
  FOR EACH ROW EXECUTE FUNCTION enforce_driver_app_user_role();

CREATE TRIGGER trg_driver_updated_at
  BEFORE UPDATE ON driver
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- vehicle — one row per vehicle a driver drives
-- -----------------------------------------------------------------------------
-- Multiple vehicles per driver is normal, not an edge case: a van breaks down
-- mid-route. One of them is verified at a time (is_vehicle_verified); D5
-- assigns a specific vehicle to a specific trip.

CREATE TABLE vehicle (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id         uuid NOT NULL,
  make              text,
  model             text,
  year              int CHECK (year IS NULL OR year BETWEEN 1990 AND 2100),
  plate_number      text NOT NULL CHECK (length(btrim(plate_number)) > 0),
  colour            text,
  seating_capacity  int NOT NULL CHECK (seating_capacity > 0),
  is_vehicle_verified boolean NOT NULL DEFAULT false,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_vehicle_driver_id FOREIGN KEY (driver_id)
    REFERENCES driver(id) ON DELETE CASCADE,
  -- Unique across the whole platform, not per driver: two vehicles claiming
  -- one Peshawar plate is either a typo or a cloned plate, and both must be
  -- impossible to commit to the database.
  CONSTRAINT uq_vehicle_plate_number UNIQUE (plate_number)
);

COMMENT ON TABLE vehicle IS
  'A vehicle a driver is allowed to drive. Platform-wide unique plate_number: '
  'a duplicate plate is either a data-entry typo or a cloned plate, and the '
  'second reading is a safety incident, not a nuisance.';

COMMENT ON COLUMN vehicle.is_vehicle_verified IS
  'Whether registration and insurance have been sighted for THIS vehicle. '
  'Distinct from the driver''s own verification_status: a fully verified '
  'driver in an unverified vehicle is still not cleared to take children.';

CREATE TRIGGER trg_vehicle_updated_at
  BEFORE UPDATE ON vehicle
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- driver_document — the paperwork, as a pointer to private storage
-- -----------------------------------------------------------------------------
-- THIS TABLE NEVER STORES IMAGE BYTES. A CNIC scan is 200 KB of base64; ten
-- drivers' worth would bloat the database, defeat every index, and turn a
-- routine SELECT into a full-table read of identity documents. What lives
-- here is where the file is, and what it is. Reading the bytes is always a
-- signed URL from the private bucket, which is an auditable grant, never a
-- permanent link.
--
-- vehicle_id NULL means the document belongs to the person (CNIC, licence,
-- police certificate). NOT NULL means it belongs to a vehicle (registration,
-- insurance). ck_driver_document_scope_matches_type enforces that mapping,
-- because without it a driver could sidestep the person-scoped unique index
-- below by hanging two competing CNIC fronts off two different vehicles.

CREATE TABLE driver_document (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id         uuid NOT NULL,
  vehicle_id        uuid,
  document_type     document_type NOT NULL,
  storage_bucket    text NOT NULL CHECK (length(btrim(storage_bucket)) > 0),
  storage_path      text NOT NULL CHECK (length(btrim(storage_path)) > 0),
  mime_type         text NOT NULL CHECK (length(btrim(mime_type)) > 0),
  byte_size         int NOT NULL CHECK (byte_size > 0),
  status            verification_status NOT NULL DEFAULT 'pending_review',
  uploaded_at       timestamptz NOT NULL DEFAULT now(),
  reviewed_by       uuid,
  reviewed_at       timestamptz,
  rejection_reason  text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_driver_document_driver_id FOREIGN KEY (driver_id)
    REFERENCES driver(id) ON DELETE CASCADE,
  CONSTRAINT fk_driver_document_vehicle_id FOREIGN KEY (vehicle_id)
    REFERENCES vehicle(id) ON DELETE CASCADE,
  CONSTRAINT fk_driver_document_reviewed_by FOREIGN KEY (reviewed_by)
    REFERENCES app_user(id) ON DELETE SET NULL,
  CONSTRAINT ck_driver_document_scope_matches_type CHECK (
    CASE
      WHEN document_type IN ('cnic_front', 'cnic_back',
                             'driving_license', 'police_character_certificate')
        THEN vehicle_id IS NULL
      WHEN document_type IN ('vehicle_registration', 'insurance_policy')
        THEN vehicle_id IS NOT NULL
      ELSE false
    END
  ),
  -- Same rationale as ck_driver_rejected_requires_reason, one level down: a
  -- rejected document the driver cannot act on is the same support incident.
  CONSTRAINT ck_driver_document_rejected_requires_reason CHECK (
    status <> 'rejected'
    OR (rejection_reason IS NOT NULL AND length(btrim(rejection_reason)) > 0)
  )
);

COMMENT ON TABLE driver_document IS
  'Pointer to one uploaded document in private storage. Stores the location '
  'and the classification of the file, never its bytes. '
  'ACCESS IS ABSOLUTE AND ENFORCED IN D8: no SELECT policy for the parent or '
  'school roles, not even metadata-only. A school approving a driver needs to '
  'know the driver is verified, not to read their CNIC; that is what '
  'driver_verification_summary is for. Parents never see this table at all.';

COMMENT ON COLUMN driver_document.storage_path IS
  'Object key inside a PRIVATE bucket. Never a public URL and never a signed '
  'URL: a signed URL pasted into a log or a support thread outlives its '
  'expiry. Resolve at read time, with the grant audited.';

COMMENT ON COLUMN driver_document.byte_size IS
  'Size in bytes of the stored object, for the upload quota and for spotting '
  'a mis-uploaded 40 MB PDF of a scanned book. Advisory, not a limit: the '
  'enforced ceiling belongs to the storage bucket policy.';

COMMENT ON COLUMN driver_document.status IS
  'Review state of THIS document, independent of the driver''s overall '
  'verification_status. Uploading is not approving: a row lands in '
  '''pending_review'' and stays there until a human clears it.';

-- A driver must never have two competing documents of the same type sitting
-- in the queue. Two partial indexes rather than one nullable-aware index,
-- because a plain UNIQUE (driver_id, vehicle_id, document_type) would let a
-- NULL vehicle_id bypass uniqueness entirely in Postgres, which is exactly the
-- "two CNIC fronts" case this is meant to close.

CREATE UNIQUE INDEX uq_driver_document_person
  ON driver_document (driver_id, document_type)
  WHERE vehicle_id IS NULL;

CREATE UNIQUE INDEX uq_driver_document_vehicle
  ON driver_document (driver_id, vehicle_id, document_type)
  WHERE vehicle_id IS NOT NULL;

COMMENT ON INDEX uq_driver_document_person IS
  'One person-scoped document per (driver, document_type). Closing the NULL '
  'hole in a plain UNIQUE constraint is the entire point of this index.';
COMMENT ON INDEX uq_driver_document_vehicle IS
  'One vehicle-scoped document per (driver, vehicle, document_type). A driver '
  'with two vans holds two registrations, which is correct.';

CREATE TRIGGER trg_driver_document_updated_at
  BEFORE UPDATE ON driver_document
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- required_document — the approval checklist, as data
-- -----------------------------------------------------------------------------
-- WHY A TABLE AND NOT A CONSTANT IN APPLICATION CODE
--   The admin verification queue has to answer "what is still missing?" and
--   it must get the same answer as the approval guard, the driver-facing
--   upload screen, and the marketing claim about what we check. The moment
--   that list lives in a TypeScript array, there are four copies of it, two
--   of them stale, and no test can catch the disagreement because the copies
--   are not compared to anything. The police character certificate is the
--   obvious casualty: it gets added to the driver app and forgotten by the
--   admin queue, and drivers are approved missing it.
--
--   Two concrete payoffs. The requirement list can change — add
--   vehicle_registration, retire a document, reorder what the driver sees
--   first — with an UPDATE instead of a redeploy. And the driver-side upload
--   screen is rendered from the same rows the queue measures against, so it
--   cannot tell a driver "all four uploaded, one moment" while the database
--   is waiting on three more.

CREATE TABLE required_document (
  document_type  document_type NOT NULL,
  is_mandatory   boolean NOT NULL DEFAULT true,
  display_order  int CHECK (display_order IS NULL OR display_order > 0),
  description    text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pk_required_document PRIMARY KEY (document_type)
);

COMMENT ON COLUMN required_document.description IS
  'Admin-facing English explanation of what the document is and why it is '
  'asked for. The driver-facing label and instructions come from the '
  'application''s locale files, including Urdu: this column must never be the '
  'only place a requirement is explained to a driver.';

COMMENT ON COLUMN required_document.is_mandatory IS
  'false reserves a row for a document that is collected but not required for '
  'approval, so it can be added to a checklist without silently tightening '
  'the approval rule. Set it carefully: this flag is what '
  'driver_verification_summary counts against.';

INSERT INTO required_document (document_type, is_mandatory, display_order, description)
VALUES
  ('cnic_front',                   true, 10,
   'Front of the national identity card, all four corners visible, no glare over the photo or the number.'),
  ('cnic_back',                    true, 20,
   'Back of the national identity card, all four corners visible.'),
  ('driving_license',              true, 30,
   'Driving licence valid for a passenger vehicle. A commercial or goods licence does not qualify.'),
  ('police_character_certificate', true, 40,
   'Police character certificate dated within the last six months.');

COMMENT ON TABLE required_document IS
  'What must be present before a driver can be approved. A TABLE, not a '
  'hard-coded array in application code, because the admin verification queue '
  'must compute "what is missing" from the database: (1) the requirement list '
  'can then change without a redeploy, and (2) no code path can disagree with '
  'the database about what is required. An array literal would be copied into '
  'the driver app, the admin queue and the approval guard, and the copies '
  'would drift silently. '
  'Seeded with the four mandatory driver documents. The two vehicle documents '
  '(vehicle_registration, insurance_policy) are deliberately NOT listed here: '
  'they gate vehicle approval, not driver approval, and are checked against '
  'vehicle.is_vehicle_verified. Add them as is_mandatory = false rows if the '
  'admin checklist needs to collect them up front.';

CREATE TRIGGER trg_required_document_updated_at
  BEFORE UPDATE ON required_document
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- driver_school — which schools have cleared which driver
-- -----------------------------------------------------------------------------
-- This is the gate that makes the safety claim real at the school level. The
-- trip assignment in D5 draws from active rows here, so a row here is the
-- difference between "verified in general" and "allowed to collect children at
-- this gate at this hour".

CREATE TABLE driver_school (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id    uuid NOT NULL,
  school_id    uuid NOT NULL,
  approved_by  uuid,
  approved_at  timestamptz,
  is_active    boolean NOT NULL DEFAULT true,
  ended_at     timestamptz,
  notes        text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_driver_school_driver_id FOREIGN KEY (driver_id)
    REFERENCES driver(id) ON DELETE CASCADE,
  CONSTRAINT fk_driver_school_school_id FOREIGN KEY (school_id)
    REFERENCES school(id) ON DELETE CASCADE,
  CONSTRAINT fk_driver_school_approved_by FOREIGN KEY (approved_by)
    REFERENCES app_user(id) ON DELETE SET NULL,
  CONSTRAINT ck_driver_school_ended_after_approved CHECK (
    ended_at IS NULL OR approved_at IS NULL OR ended_at >= approved_at
  )
);

COMMENT ON TABLE driver_school IS
  'School-by-school approval of a driver. An active row here is what makes a '
  'driver assignable to this school''s trips in D5. '
  'Only a driver with verification_status = ''approved'' may hold an approved '
  'row, enforced by enforce_driver_school_driver_approved(): platform-level '
  'verification and school-level trust are two separate decisions and the '
  'second one is never implied by the first. '
  'A row may exist inactive or without approved_at as a staged link before a '
  'school decides; the trigger only constrains the moment of approval.';

COMMENT ON COLUMN driver_school.approved_by IS
  'The app_user who recorded the approval, normally a school_admin for this '
  'school. No trigger enforces that role here: membership in school_admin is '
  'per-school, so the check needs both columns and belongs to D8''s RLS and '
  'to the admin endpoint that writes this column.';

-- Suspension is NOT cascaded by this trigger. When a verified driver is
-- suspended, the suspension is recorded on driver.verification_status and the
-- B-series admin flow is responsible for ending the affected driver_school
-- rows and notifying the schools. Doing it here would mean a verification
-- decision silently rewriting a school''s roster, with no notification and no
-- audit entry of its own.

CREATE OR REPLACE FUNCTION enforce_driver_school_driver_approved()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_status verification_status;
BEGIN
  IF NEW.is_active AND NEW.approved_at IS NOT NULL THEN
    SELECT d.verification_status INTO v_status FROM driver d WHERE d.id = NEW.driver_id;

    IF v_status IS DISTINCT FROM 'approved' THEN
      RAISE EXCEPTION
        'driver % cannot be approved for school % while verification_status is % (must be ''approved'')',
        NEW.driver_id, NEW.school_id, coalesce(v_status::text, 'no such driver')
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION enforce_driver_school_driver_approved() IS
  'BEFORE INSERT OR UPDATE guard on driver_school: a row that is active AND '
  'carries an approved_at timestamp may only exist when the linked driver''s '
  'verification_status is ''approved''. SECURITY DEFINER with a pinned '
  'search_path because the school admin approving a driver does not own the '
  'driver row. Without this, an unverified driver becomes assignable to a '
  'school''s trips in D5 and the safety claim is false at the exact moment it '
  'is made.';

CREATE TRIGGER trg_driver_school_driver_approved
  BEFORE INSERT OR UPDATE ON driver_school
  FOR EACH ROW EXECUTE FUNCTION enforce_driver_school_driver_approved();

CREATE TRIGGER trg_driver_school_updated_at
  BEFORE UPDATE ON driver_school
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE UNIQUE INDEX uq_driver_school_active
  ON driver_school (driver_id, school_id)
  WHERE is_active;

COMMENT ON INDEX uq_driver_school_active IS
  'One active approval per (driver, school). History is kept: ending a row '
  'sets is_active = false and ended_at, and a later re-approval is a new row '
  'rather than an overwrite of what the school agreed to months ago.';

-- -----------------------------------------------------------------------------
-- driver_earning — per-school, per-period read model for the driver dashboard
-- -----------------------------------------------------------------------------
-- WHY A READ MODEL: the driver dashboard opens on every app foreground. If it
-- aggregated split_allocation, invoice and invoice_line on each of those
-- opens, the driver would be waiting on a five-table join to see last month's
-- figure, on a phone, on Peshawar mobile data. One row per driver, school and
-- period, written once by the billing run, read by the dashboard.
--
-- WHO WRITES IT: the B8 billing run, and nothing else. No trigger on
-- invoice or split_allocation touches this table. A trigger cannot know
-- which period a payment belongs to, cannot survive a late or partial
-- payment, and cannot be re-run safely — which is exactly what period close
-- has to be.

CREATE TABLE driver_earning (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id        uuid NOT NULL,
  school_id        uuid NOT NULL,
  period_start     date NOT NULL,
  period_end       date NOT NULL,
  gross_paisa      bigint NOT NULL,
  adjustment_paisa bigint NOT NULL DEFAULT 0,
  net_paisa        bigint NOT NULL,
  paid_at          timestamptz,
  payout_id        uuid,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_driver_earning_driver_id FOREIGN KEY (driver_id)
    REFERENCES driver(id) ON DELETE RESTRICT,
  CONSTRAINT fk_driver_earning_school_id FOREIGN KEY (school_id)
    REFERENCES school(id) ON DELETE RESTRICT,
  CONSTRAINT uq_driver_earning_driver_school_period
    UNIQUE (driver_id, school_id, period_start),
  CONSTRAINT ck_driver_earning_net_equals_gross_plus_adjustment CHECK (
    net_paisa = gross_paisa + adjustment_paisa
  ),
  CONSTRAINT ck_driver_earning_period_ordered CHECK (
    period_end >= period_start
  )
);

COMMENT ON TABLE driver_earning IS
  'Per-driver, per-school, per-period earnings read model. Money is integer '
  'paisa in bigint; 1 PKR = 100 paisa, and no amount here is ever a float. '
  'Populated by the billing run in B8, NOT by triggers. '
  'PAYOUT ELIGIBILITY DOES NOT GATE ON THIS TABLE. Release of money is gated '
  'on the underlying invoice.status = ''paid'' in D2, for both driver and '
  'school payouts: paid_at and payout_id on this table are a record of what '
  'happened, and a row that is unpaid here does not by itself prove the money '
  'is owed. An unpaid row can be a billing run that has not caught up, and '
  'paying from this table instead of from paid invoices pays a driver twice.';

COMMENT ON COLUMN driver_earning.adjustment_paisa IS
  'Signed manual credit or debit, from the adjustment table in D2 with its '
  'mandatory reason. Kept separate from gross_paisa so the dashboard can show '
  'what was earned and what was manually changed without reconstructing it.';

COMMENT ON COLUMN driver_earning.payout_id IS
  'The D2 payout this earning was released in. Deliberately NOT an inline '
  'foreign key: payout is defined in D2 and this file will not take a '
  'dependency on a table it does not own. D2 adds the constraint when it '
  'creates the payout table.';

COMMENT ON COLUMN driver_earning.paid_at IS
  'When this period''s money was actually released, as opposed to when it was '
  'earned. NULL means not yet released, not "free".';

CREATE TRIGGER trg_driver_earning_updated_at
  BEFORE UPDATE ON driver_earning
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- Indexes
-- -----------------------------------------------------------------------------
-- Only the query patterns that actually exist. The admin queue filters
-- verification_status; the queue renders one driver's paperwork; a school loads
-- its approved drivers; a driver loads their own vehicles.

CREATE INDEX idx_driver_verification_status
  ON driver (verification_status);

CREATE INDEX idx_driver_document_driver_status
  ON driver_document (driver_id, status);

CREATE INDEX idx_driver_school_school_active
  ON driver_school (school_id, is_active);

CREATE INDEX idx_vehicle_driver_id
  ON vehicle (driver_id);

-- -----------------------------------------------------------------------------
-- driver_verification_summary — what the admin queue actually reads
-- -----------------------------------------------------------------------------
-- One row per driver, answering the six questions the verification queue asks,
-- in one round trip. The alternative is six queries per driver in a paginated
-- queue, which is how a verification queue ends up rendering a driver's
-- paperwork from three different moments in time.
--
-- COLUMN SEMANTICS, precisely:
--   required_count  mandatory rows in required_document.
--   present_count   mandatory document types whose person-scoped
--                   driver_document has been CLEARED (status = 'approved').
--   missing_count   required_count - present_count, i.e. still outstanding.
--   rejected_count  mandatory document types whose current document row was
--                   rejected, so the driver knows and has been told why.
--
-- present_count counts cleared items, not merely uploaded ones, on purpose:
-- it is the number the approval decision is made from. A driver with four
-- uploads sitting in pending_review has missing_count = 4, which is the
-- truthful state of the queue. The reviewer sees the un-cleared uploads
-- through driver_document(driver_id, status), and the driver-facing screen
-- reads required_document directly.
--
-- Only person-scoped documents (vehicle_id IS NULL) count, so a vehicle
-- registration can never stand in for a licence.

-- security_invoker matters here and is not optional. A PostgreSQL view runs
-- with its OWNER's privileges by default, so a view owned by the migration
-- role reads driver and driver_document with RLS switched off — which would
-- hand every parent and every school admin the full driver list through a
-- single granted view and quietly undo D8. security_invoker = true makes the
-- view run as the querying role, so the policies in D8 decide what it returns.
-- Before D8 exists it changes nothing: RLS is not enabled yet.

CREATE VIEW driver_verification_summary
WITH (security_invoker = true) AS
WITH mandatory AS (
  SELECT r.document_type
  FROM required_document r
  WHERE r.is_mandatory
),
current_document AS (
  SELECT dd.driver_id, dd.document_type, dd.status
  FROM driver_document dd
  JOIN mandatory m ON m.document_type = dd.document_type
  WHERE dd.vehicle_id IS NULL
),
per_driver AS (
  SELECT
    c.driver_id,
    (count(*) FILTER (WHERE c.status = 'approved'))::int AS present_count,
    (count(*) FILTER (WHERE c.status = 'rejected'))::int AS rejected_count
  FROM current_document c
  GROUP BY c.driver_id
)
SELECT
  d.id                  AS driver_id,
  d.full_name,
  d.phone,
  d.verification_status,
  d.rejection_reason,
  d.submitted_at,
  d.reviewed_at,
  (SELECT count(*)::int FROM mandatory)              AS required_count,
  coalesce(p.present_count, 0)                      AS present_count,
  (SELECT count(*)::int FROM mandatory)
    - coalesce(p.present_count, 0)                  AS missing_count,
  coalesce(p.rejected_count, 0)                     AS rejected_count
FROM driver d
LEFT JOIN per_driver p ON p.driver_id = d.id;

COMMENT ON VIEW driver_verification_summary IS
  'One row per driver: identity, verification status, and how many mandatory '
  'documents are cleared, still missing, or rejected. THE ADMIN VERIFICATION '
  'QUEUE READS THIS VIEW, not six separate queries, so every column on screen '
  'comes from a single consistent snapshot. '
  'This view is also the sanctioned substitute for document access: a school '
  'approving a driver is told the driver is verified through columns here, and '
  'is never granted a SELECT on driver_document. '
  'present_count counts documents a human has cleared, not documents that have '
  'been uploaded, because this is the number the approval decision is made '
  'from.';

-- =============================================================================
-- Deliberately NOT in this file
-- =============================================================================
--   * OCR or text extraction from CNIC images. Out of scope per D-series §D4,
--     and deliberately so: an automated read of a national ID that gets one
--     character wrong is a mismatch a human will blame on the driver.
--   * Background-check API calls. Same reason. Approval is a human decision.
--   * Automatic cascade from driver.verification_status = 'suspended' to ending
--     driver_school rows. Suspension already blocks new approvals; ending a
--     school's roster is a notification-bearing action belonging to B-series.
--   * A trigger or index enforcing that driver_school.approved_by holds a
--     school_admin role for that school. Per-school membership cannot be
--     checked from this table's columns alone; D8's RLS and the admin
--     endpoint that writes the column own that decision.
--   * RLS of any kind. D8 applies it across every table, and driver_document
--     is the table it must get most right.
-- =============================================================================
