-- =============================================================================
-- D3 — People and enrollment: schools, staff, students, guardians, enrollments
-- =============================================================================
-- CONVENTIONS (binding for D4, D5, D6, D7, D8):
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
--   * Unique INDEXES follow the uq_ prefix. When the uniqueness is partial the
--     name also carries the discriminating words, e.g.
--     uq_<table>_one_primary_per_<parent>, so the index explains itself in a
--     constraint error message with no further lookup.
--   * Money: integer paisa in bigint. 1 PKR = 100 paisa. Never float.
--   * Basis points stored in int; splits must sum to exactly 10000.
--   * Booleans prefixed is_ or has_.
--   * Every table gets updated_at, maintained by set_updated_at() from D1.
--   * Enum types created here are named for the table that owns them, so that
--     no two tables can ever disagree on what `admin` or `other` means.
--   * NO RLS in this file. RLS is applied in D8, across every table.
--
-- THE COMMERCIAL AMBIGUITY THIS FILE RESOLVES
-- ---------------------------------------------
-- A school earns its share ONLY for children who (1) are actively enrolled on
-- a Rawaan route AND (2) have a paid invoice. A child who attends the school
-- but is not transported by Rawaan earns the school NOTHING. The school share
-- is NOT a percentage of total student count. Reading it that way overpays
-- schools by a large multiple, and is the single most expensive mistake
-- available in this schema.
--
-- That rule is split into two SEPARATE gates so the two halves cannot form a
-- circular dependency. Payment needs an invoice; an invoice needs something to
-- bill; if billing required payment the FIRST invoice could never be issued.
--
--   Gate 1 — invoice eligibility (this file).
--     enrollment.status = 'active' AND the child is on a route AND the
--     starts_on/ends_on window overlaps the period.
--     Decides who gets BILLED. No dependency on payment.
--
--   Gate 2 — payout eligibility (B8, a later migration).
--     invoice.status = 'paid'.
--     Decides what anyone actually RECEIVES.
--
-- Therefore `is_billable` means TRANSPORT-ELIGIBLE, NOT PAID.
-- =============================================================================

SET search_path TO public, extensions;

-- -----------------------------------------------------------------------------
-- Enum types owned by D3
-- -----------------------------------------------------------------------------

-- What a staff member does at one school. Distinct from app_role, which
-- answers "what can this person do in Rawaan". A principal and an accountant
-- are both app_role = 'school'.
CREATE TYPE school_admin_role AS ENUM ('principal', 'admin', 'accountant');

-- How a guardian relates to the child. Drives consent copy and pickup
-- authorisation, so it is recorded rather than inferred from a name.
CREATE TYPE guardian_relationship AS ENUM ('mother', 'father', 'guardian', 'other');

-- -----------------------------------------------------------------------------
-- Cross-table role guards
-- -----------------------------------------------------------------------------
-- guardian.app_user_id must point at an app_user with role 'parent', and
-- school_admin.app_user_id at one with role 'school'. A CHECK constraint
-- cannot look at another table, so this is a BEFORE trigger instead.
--
-- One shared assertion, two thin trigger functions, so the rule is written
-- once. SECURITY DEFINER with search_path pinned for the same reason as
-- current_app_role() in D1: an object created by an untrusted role in a schema
-- on the search path must not be able to hijack the function body.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION assert_app_user_role(p_app_user_id uuid, p_required app_role)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role app_role;
BEGIN
  SELECT a.role INTO v_role
    FROM app_user a
   WHERE a.id = p_app_user_id;

  IF v_role IS NULL THEN
    RAISE EXCEPTION 'no app_user row exists for id %', p_app_user_id
      USING ERRCODE = '23503';
  END IF;

  IF v_role <> p_required THEN
    RAISE EXCEPTION 'app_user % has role %, but this row requires role %',
      p_app_user_id, v_role, p_required
      USING ERRCODE = '23514';
  END IF;
END;
$$;

COMMENT ON FUNCTION assert_app_user_role(uuid, app_role) IS
  'Raises unless the referenced app_user carries p_required. Used by the '
  'guardian and school_admin role-guard triggers, which a CHECK constraint '
  'cannot express.';

CREATE OR REPLACE FUNCTION guard_school_admin_role()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM assert_app_user_role(NEW.app_user_id, 'school');
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION guard_guardian_role()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM assert_app_user_role(NEW.app_user_id, 'parent');
  RETURN NEW;
END;
$$;

-- -----------------------------------------------------------------------------
-- school
-- -----------------------------------------------------------------------------
-- One row per school we serve. Phase 1 routes belong to exactly one school;
-- multi-school pooling stays a data question, not a structural one.
-- -----------------------------------------------------------------------------

CREATE TABLE school (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text        NOT NULL CHECK (length(btrim(name)) > 0),
  slug          text        NOT NULL CHECK (length(btrim(slug)) > 0),
  address       text,
  city          text        NOT NULL DEFAULT 'Peshawar',
  contact_email text,
  contact_phone text,
  gate_count    int         CHECK (gate_count IS NULL OR gate_count > 0),
  timezone      text        NOT NULL DEFAULT 'Asia/Karachi',
  logo_path     text,
  is_active     boolean     NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_school_slug UNIQUE (slug)
);

COMMENT ON TABLE school IS
  'A school served by Rawaan. Contact details are the school office, never a '
  'named individual.';
COMMENT ON COLUMN school.logo_path IS
  'Pointer to an object in private storage. Never a URL, never an image blob.';

CREATE TRIGGER trg_school_updated_at
  BEFORE UPDATE ON school
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- school_admin
-- -----------------------------------------------------------------------------
-- The many-to-many between an app_user and a school. A principal who also
-- administers a second school has two rows here, each with its own
-- role_at_school and its own earning visibility.
--
-- The linked app_user must carry role 'school'; enforced by trigger, because a
-- CHECK constraint cannot read another table.
-- -----------------------------------------------------------------------------

CREATE TABLE school_admin (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id             uuid            NOT NULL REFERENCES school(id),
  app_user_id           uuid            NOT NULL REFERENCES app_user(id),
  role_at_school        school_admin_role NOT NULL DEFAULT 'admin',
  can_approve_drivers   boolean         NOT NULL DEFAULT false,
  can_view_earnings     boolean         NOT NULL DEFAULT true,
  created_at            timestamptz     NOT NULL DEFAULT now(),
  updated_at            timestamptz     NOT NULL DEFAULT now(),
  CONSTRAINT uq_school_admin_school_user UNIQUE (school_id, app_user_id)
);

COMMENT ON TABLE school_admin IS
  'School staff, scoped to one school each. The role-guard trigger rejects any '
  'app_user whose role is not school, so this table cannot become a back door '
  'into school visibility for parents or drivers.';
COMMENT ON COLUMN school_admin.can_view_earnings IS
  'Whether this person may see school revenue-share figures. An accountant '
  'normally yes; a principal may delegate this to no one, which is why it is a '
  'column rather than implied by role_at_school.';

CREATE TRIGGER trg_school_admin_updated_at
  BEFORE UPDATE ON school_admin
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_school_admin_role_guard
  BEFORE INSERT OR UPDATE OF app_user_id ON school_admin
  FOR EACH ROW EXECUTE FUNCTION guard_school_admin_role();

CREATE INDEX idx_school_admin_app_user_id ON school_admin (app_user_id);

-- -----------------------------------------------------------------------------
-- student
-- -----------------------------------------------------------------------------
-- Children are minors and NEVER authenticate, so a student has no app_user
-- row. Identity and access run through the guardian link below.
--
-- PRIVACY: no national ID number is stored on this table, in any form, by
-- default. A student CNIC is a direct government identifier on a minor. If it
-- is ever genuinely required, it must be stored encrypted, or hashed with a
-- lookup table so equality search works without exposing the value, and that
-- choice must be justified and reviewed before any column is added. Do not add
-- a plaintext CNIC column to this table.
--
-- Home and pickup points are geography, not geometry: distance on a sphere in
-- metres is what the route planner and find_nearby_students() actually need.
-- -----------------------------------------------------------------------------

CREATE TABLE student (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name                text        NOT NULL CHECK (length(btrim(full_name)) > 0),
  date_of_birth            date,
  school_id                uuid        NOT NULL REFERENCES school(id),
  grade                    text,
  section                  text,
  home_address             text,
  home_location            geography(Point, 4326),
  pickup_location          geography(Point, 4326),
  emergency_contact_name   text,
  emergency_contact_phone  text,
  is_active                boolean     NOT NULL DEFAULT true,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE student IS
  'A child on a school roll. Minors do not authenticate and have no app_user '
  'row; a guardian link (see guardian) carries consent, payment rights and '
  'pickup authorisation. No national ID number is stored here: a student CNIC '
  'must, if ever required, be encrypted or hashed with a lookup table, and '
  'that choice justified before the column is added.';
COMMENT ON COLUMN student.home_location IS
  'Where the child lives. Child location data: readable only through '
  'can_view_student_location() in D8, which is the safety boundary for this '
  'product.';
COMMENT ON COLUMN student.pickup_location IS
  'Where the child is actually collected from. May differ from home_location; '
  'in practice it is the route stop the child is manifested to.';

CREATE TRIGGER trg_student_updated_at
  BEFORE UPDATE ON student
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_student_school_id ON student (school_id);
CREATE INDEX idx_student_home_location_gist ON student USING gist (home_location);
CREATE INDEX idx_student_pickup_location_gist ON student USING gist (pickup_location);

-- -----------------------------------------------------------------------------
-- guardian
-- -----------------------------------------------------------------------------
-- Links an authenticating parent to a child and records what they may do.
-- This row, not app_user.role, is what makes someone a parent: role says what
-- a person is, this says whose child they are.
-- -----------------------------------------------------------------------------

CREATE TABLE guardian (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_user_id          uuid        NOT NULL REFERENCES app_user(id),
  student_id           uuid        NOT NULL REFERENCES student(id),
  relationship         guardian_relationship NOT NULL DEFAULT 'other',
  is_primary           boolean     NOT NULL DEFAULT false,
  can_manage_payments  boolean     NOT NULL DEFAULT true,
  consent_at           timestamptz,
  consent_version      text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_guardian_app_user_student UNIQUE (app_user_id, student_id),
  CONSTRAINT ck_guardian_consent_paired CHECK (
    (consent_at IS NULL AND consent_version IS NULL)
    OR (consent_at IS NOT NULL AND consent_version IS NOT NULL)
  )
);

COMMENT ON TABLE guardian IS
  'A parent app_user authorised for one child. The role-guard trigger rejects '
  'an app_user whose role is not parent. At most one row per student may have '
  'is_primary = true (uq_guardian_one_primary_per_student).';
COMMENT ON COLUMN guardian.consent_at IS
  'When this guardian consented to the child being transported and tracked. '
  'Paired with consent_version by ck_guardian_consent_paired: the version of '
  'the consent text shown is part of the record, not an afterthought.';
COMMENT ON COLUMN guardian.can_manage_payments IS
  'Whether this guardian may pay invoices. Split from the relationship because '
  'a father may have full pickup rights and no billing access, or the reverse.';

CREATE TRIGGER trg_guardian_updated_at
  BEFORE UPDATE ON guardian
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_guardian_role_guard
  BEFORE INSERT OR UPDATE OF app_user_id ON guardian
  FOR EACH ROW EXECUTE FUNCTION guard_guardian_role();

-- One primary guardian per child. A child has exactly one person who answers
-- for them; a second primary is always a data-entry mistake, and the billing
-- and consent flows both need an unambiguous answer.
CREATE UNIQUE INDEX uq_guardian_one_primary_per_student
  ON guardian (student_id) WHERE is_primary;

CREATE INDEX idx_guardian_app_user_id ON guardian (app_user_id);
CREATE INDEX idx_guardian_student_id ON guardian (student_id);

-- -----------------------------------------------------------------------------
-- enrollment
-- -----------------------------------------------------------------------------
-- THE BILLING-RELEVANT LINK, and the table that resolves the commercial
-- ambiguity. A student row means "on the school roll". Only this table means
-- "Rawaan transports this child, and someone is billed for it".
--
-- RATE HIERARCHY — read this before changing any rate code path. There are
-- three places basis points appear, and they are not interchangeable:
--
--   enrollment.*_bps + fee_paisa   <- THE ONLY BILLING INPUT. The contract
--                                      anchor for this child. Immutable.
--   rate_snapshot (D2)             <- Onboarding DEFAULT for new enrollments.
--                                      Copied in at enrolment time. NEVER read
--                                      at invoice time.
--   invoice_line.*_bps (D2)        <- Immutable per-issue copy, copied from
--                                      the enrollment, which makes each issued
--                                      invoice self-describing and immune to
--                                      any later rate change.
--
-- If invoice generation ever reads rate_snapshot, a mid-month contract change
-- retroactively alters already-issued invoices. That is the failure mode D2
-- exists to prevent, and this table is the fix for it: the commercial terms
-- are frozen here, on the enrollment, at the moment the child joins.
-- -----------------------------------------------------------------------------

CREATE TABLE enrollment (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id    uuid              NOT NULL REFERENCES student(id),
  school_id     uuid              NOT NULL REFERENCES school(id),
  -- The guardian who is actually billed. app_user is not enough: a child can
  -- have two guardians, only one of whom holds can_manage_payments.
  guardian_id   uuid              NOT NULL REFERENCES guardian(id),
  status        enrollment_status NOT NULL DEFAULT 'active',
  starts_on     date              NOT NULL,
  ends_on       date,
  -- Per-enrollment proration cutoff, so a mid-month join is not charged a
  -- full month.
  billed_as_of  date,
  -- No foreign key here: `route` is created in D5. See the deferred FK block
  -- at the end of this file.
  route_id      uuid,
  -- Frozen commercial terms. The ONLY input to invoice generation.
  fee_paisa     bigint            NOT NULL,
  driver_bps    int               NOT NULL,
  school_bps    int               NOT NULL,
  rawaan_bps    int               NOT NULL,
  notes         text,
  created_at    timestamptz       NOT NULL DEFAULT now(),
  updated_at    timestamptz       NOT NULL DEFAULT now(),
  CONSTRAINT ck_enrollment_fee_paisa_positive CHECK (fee_paisa > 0),
  CONSTRAINT ck_enrollment_driver_bps_range CHECK (driver_bps BETWEEN 0 AND 10000),
  CONSTRAINT ck_enrollment_school_bps_range CHECK (school_bps BETWEEN 0 AND 10000),
  CONSTRAINT ck_enrollment_rawaan_bps_range CHECK (rawaan_bps BETWEEN 0 AND 10000),
  -- The invariant that guarantees no party is ever overpaid from a typo.
  CONSTRAINT ck_enrollment_split_bps_sum CHECK (driver_bps + school_bps + rawaan_bps = 10000),
  CONSTRAINT ck_enrollment_window_ordered CHECK (ends_on IS NULL OR ends_on >= starts_on)
);

COMMENT ON TABLE enrollment IS
  'The billing-relevant link between a child, a school, and the guardian who '
  'pays. Each row carries its own frozen commercial terms (fee_paisa and the '
  'three bps columns) so that a later contract change can never alter money '
  'that has already been invoiced. '
  'IMPORTANT: the final wording of the school revenue-share terms must come '
  'from the signed school agreement. Until that agreement exists these rate '
  'columns are a technical placeholder for it, not a record of an agreed '
  'commercial term, and must not be shown to any school as a quotation or an '
  'offer. See MASTER_CONTEXT.md section 3.';
COMMENT ON COLUMN enrollment.status IS
  'Gate 1 of 2 for money. Invoice eligibility is: status active AND the child '
  'is on a route AND the starts_on/ends_on window overlaps the period; see '
  'is_billable() and v_billable_enrollment. Gate 2, payout eligibility, is '
  'invoice.status = paid and is enforced in the B8 prompt, a later migration. '
  'An active enrollment with no paid invoice earns the school nothing.';
COMMENT ON COLUMN enrollment.school_bps IS
  'The school share for THIS child on THIS contract. The school is paid on '
  'paid invoices for transport-eligible children only, never on the school '
  'roll count.';
COMMENT ON COLUMN enrollment.fee_paisa IS
  'Monthly fee for this child in integer paisa, frozen at enrolment. Read '
  'together with driver_bps, school_bps and rawaan_bps these four columns are '
  'the entire billing input. rate_snapshot is NOT read at invoice time.';
COMMENT ON COLUMN enrollment.route_id IS
  'Assigned route, or NULL while the child is not transported by Rawaan. A '
  'NULL here means the child is on the school roll but rides nothing, and '
  'is_billable() therefore returns false for them. Foreign key added after D5.';
COMMENT ON COLUMN enrollment.billed_as_of IS
  'Proration cutoff for this enrollment. A child joining mid-month is billed '
  'only from this date, which is why is_billable() tests overlap with the '
  'billing window rather than full containment of it.';

CREATE TRIGGER trg_enrollment_updated_at
  BEFORE UPDATE ON enrollment
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- One active enrollment per child per school. A child cannot be enrolled
-- twice at the same school; a re-enrolment after a break is an ended row plus
-- a new active row, which is what makes the history legible.
CREATE UNIQUE INDEX uq_enrollment_one_active_per_student_school
  ON enrollment (student_id, school_id) WHERE status = 'active';

CREATE INDEX idx_enrollment_school_id_status ON enrollment (school_id, status);
CREATE INDEX idx_enrollment_guardian_id_status ON enrollment (guardian_id, status);
CREATE INDEX idx_enrollment_student_id ON enrollment (student_id);

-- -----------------------------------------------------------------------------
-- Party consistency
-- -----------------------------------------------------------------------------
-- An enrollment must name a guardian who is actually a guardian OF THIS CHILD,
-- at THIS child school. Nothing in the column types prevents
-- guardian_id pointing at the guardian of a different student, and that row
-- would then bill the wrong family for the wrong child: the most expensive
-- possible defect in this schema. Checked here because a CHECK constraint
-- cannot read other tables.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION assert_enrollment_parties_consistent()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_guardian_student uuid;
  v_student_school   uuid;
BEGIN
  SELECT g.student_id INTO v_guardian_student
    FROM guardian g
   WHERE g.id = NEW.guardian_id;

  IF v_guardian_student IS DISTINCT FROM NEW.student_id THEN
    RAISE EXCEPTION 'guardian % is linked to student %, not to enrollment student %',
      NEW.guardian_id, v_guardian_student, NEW.student_id
      USING ERRCODE = '23514';
  END IF;

  SELECT s.school_id INTO v_student_school
    FROM student s
   WHERE s.id = NEW.student_id;

  IF v_student_school IS DISTINCT FROM NEW.school_id THEN
    RAISE EXCEPTION 'student % is on school %, not on enrollment school %',
      NEW.student_id, v_student_school, NEW.school_id
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION assert_enrollment_parties_consistent() IS
  'Rejects an enrollment whose guardian does not belong to the enrollment '
  'student, or whose student is not on the enrollment school. Without it the '
  'billed guardian and the transported child can silently diverge.';

CREATE TRIGGER trg_enrollment_parties_consistent
  BEFORE INSERT OR UPDATE OF student_id, school_id, guardian_id ON enrollment
  FOR EACH ROW EXECUTE FUNCTION assert_enrollment_parties_consistent();

-- -----------------------------------------------------------------------------
-- is_billable — DERIVED, not stored
-- -----------------------------------------------------------------------------
-- There is deliberately no is_billable COLUMN on enrollment. A stored boolean
-- maintained by trigger is derived state, and derived state drifts: a route is
-- deactivated, a date is edited, a status is flipped, and the flag silently
-- disagrees with the truth. The only honest version of this fact is a query
-- that recomputes it from the columns it depends on.
--
-- The user-facing name is_billable is preserved because it is the term the
-- business uses. It is exposed two ways:
--   * v_billable_enrollment  — a column on a view, for ad-hoc reporting.
--   * is_billable(uuid, date, date) — a function, for the billing engine.
--
-- SEMANTICS: is_billable means TRANSPORT-ELIGIBLE, NOT PAID.
-- It answers "may this child be billed for this period", never "has money
-- arrived". Payment is a separate gate on invoice.status, and keeping the two
-- apart is what allows the first invoice to exist at all.
--
-- The window test is OVERLAP, not containment: starts_on <= p_period_end and
-- (ends_on IS NULL or ends_on >= p_period_start). Containment would make a
-- mid-month join un-billable forever, which would leave billed_as_of and all
-- proration with nothing to do.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION is_billable(
  p_enrollment_id uuid,
  p_period_start  date,
  p_period_end    date
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce((
    SELECT e.status = 'active'
      AND e.route_id IS NOT NULL
      AND e.starts_on <= p_period_end
      AND (e.ends_on IS NULL OR e.ends_on >= p_period_start)
    FROM enrollment e
   WHERE e.id = p_enrollment_id
  ), false);
$$;

COMMENT ON FUNCTION is_billable(uuid, date, date) IS
  'TRUE when the enrollment may be BILLED for a period: status active, a route '
  'assigned, and the starts_on/ends_on window overlapping the period. '
  'FALSE means transport-ineligible, NOT unpaid. An unknown enrollment_id also '
  'returns FALSE. The billing engine must call this rather than filter on a '
  'stored flag, because there is no stored flag to drift.';

CREATE OR REPLACE VIEW v_billable_enrollment AS
SELECT
  e.*,
  (
      e.status = 'active'
  AND e.route_id IS NOT NULL
  AND e.starts_on <= CURRENT_DATE
  AND (e.ends_on IS NULL OR e.ends_on >= CURRENT_DATE)
  ) AS is_billable
FROM enrollment e;

COMMENT ON VIEW v_billable_enrollment IS
  'Every enrollment, one row each, with is_billable computed from status, route '
  'assignment and the date window AS OF TODAY. Filter on is_billable for '
  'reporting. A view cannot take parameters, so do NOT use this column to '
  'decide a specific past or future billing period: call '
  'is_billable(enrollment_id, period_start, period_end) for that. Until D5 '
  'lands, route assignment is route_id IS NOT NULL; the deferred block at the '
  'end of this migration shows the replacement that also requires '
  'route.is_active.';

-- -----------------------------------------------------------------------------
-- find_nearby_students — radius search in metres
-- -----------------------------------------------------------------------------
-- Why geography and not geometry: ST_Distance on geometry returns DEGREES.
-- One degree of longitude at Peshawar's latitude (about 34 N) is roughly 92 km
-- while one degree of latitude is roughly 111 km. A radius expressed in degrees
-- therefore means something different depending on where you are, and a
-- "100 metre" filter computed in degrees is about 0.001 degrees, which is a
-- meaningless number of metres at this latitude and silently returns the wrong
-- children. Casting to geography makes both ST_DWithin and ST_Distance return
-- true metres measured on the spheroid.
--
-- SECURITY NOTE: this function returns child home addresses, and is SECURITY
-- DEFINER so that the aggregation cannot be defeated by row-level filtering on
-- the underlying table. D8 must therefore control EXECUTE on this function
-- explicitly. It must never be granted to anon, and the school role should get
-- it only for its own school_id.
--
-- SEARCH PATH NOTE: this is the one function in D3 pinned to
-- `public, extensions, pg_temp` rather than `public, pg_temp`. A function body
-- is parsed using the search_path in effect when it runs, and a function-level
-- SET replaces the caller path, so pinning to `public, pg_temp` alone would make
-- `geography`, `ST_DWithin` and `ST_MakePoint` unresolvable at run time: postgis
-- is installed into `extensions` by D1, not into `public`. The extension schema
-- is read-only infrastructure, so listing it here adds no shadowing risk, and
-- db/apply-schema.mjs rewrites the `public` literal to the demo schema exactly
-- as it does for every other function in this file.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION find_nearby_students(
  p_school_id     uuid,
  p_lat           double precision,
  p_lng           double precision,
  p_radius_meters double precision
)
RETURNS TABLE (
  id                      uuid,
  full_name               text,
  date_of_birth           date,
  school_id               uuid,
  grade                   text,
  section                 text,
  home_address            text,
  home_location           geography(Point, 4326),
  pickup_location         geography(Point, 4326),
  emergency_contact_name  text,
  emergency_contact_phone text,
  is_active               boolean,
  created_at              timestamptz,
  updated_at              timestamptz,
  distance_meters         double precision
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
  SELECT
    s.id,
    s.full_name,
    s.date_of_birth,
    s.school_id,
    s.grade,
    s.section,
    s.home_address,
    s.home_location,
    s.pickup_location,
    s.emergency_contact_name,
    s.emergency_contact_phone,
    s.is_active,
    s.created_at,
    s.updated_at,
    ST_Distance(
      s.home_location::geography,
      ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography
    ) AS distance_meters
  FROM student s
  WHERE s.school_id = p_school_id
    AND s.is_active
    AND s.home_location IS NOT NULL
    AND p_radius_meters >= 0
    AND ST_DWithin(
      s.home_location::geography,
      ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography,
      p_radius_meters
    )
  ORDER BY distance_meters;
$$;

COMMENT ON FUNCTION find_nearby_students(uuid, double precision, double precision, double precision) IS
  'Active students of one school whose home_location lies within '
  'p_radius_meters of the given point, nearest first, with distance_meters on '
  'the spheroid. Distance and radius are computed in geography (metres), never '
  'in raw geometry degrees, which are not metres at any latitude and '
  'especially not at Peshawar''s. Returns child home addresses: EXECUTE must '
  'be restricted in D8.';

-- -----------------------------------------------------------------------------
-- deferred FK: applied after D5
-- -----------------------------------------------------------------------------
-- `route` does not exist until D5 creates it, so enrollment.route_id cannot
-- carry an inline foreign key here. It is declared as a plain uuid, and the
-- constraint is applied by running the block below in a session that already
-- has D5 applied. This is intentional: leaving the column typed and documented
-- now is better than reordering the series or inventing a stub route table
-- that D5 would then have to reconcile.
--
-- Once route exists, run:
--
--   ALTER TABLE enrollment
--     ADD CONSTRAINT fk_enrollment_route
--     FOREIGN KEY (route_id) REFERENCES route(id) ON DELETE SET NULL;
--
--   CREATE INDEX idx_enrollment_route_id ON enrollment (route_id);
--
-- ON DELETE SET NULL is chosen on purpose: retiring a route must not delete a
-- child's enrollment history. Note the consequence, which is correct and
-- worth stating: an enrollment whose route_id becomes NULL is no longer
-- billable. Invoices already raised keep their own invoice_line copies of the
-- split and are unaffected, but the child stops being billed going forward. To
-- suspend a route without unbilling children, set route.is_active = false and
-- use the view replacement below instead of deleting the row.
--
-- Also run at that point, so transport eligibility additionally requires an
-- ACTIVE route rather than merely a route id:
--
--   CREATE OR REPLACE VIEW v_billable_enrollment AS
--   SELECT e.*,
--     (
--         e.status = 'active'
--     AND e.route_id IS NOT NULL
--     AND r.is_active
--     AND e.starts_on <= CURRENT_DATE
--     AND (e.ends_on IS NULL OR e.ends_on >= CURRENT_DATE)
--     ) AS is_billable
--   FROM enrollment e
--   LEFT JOIN route r ON r.id = e.route_id;
--
-- and change the route_id IS NOT NULL clause of is_billable() to a join on
-- route with r.is_active, keeping the same three other predicates.
-- -----------------------------------------------------------------------------