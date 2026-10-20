-- =============================================================================
-- D5 — Routes, trips, check-ins, and the deferred foreign keys
-- =============================================================================
-- CONVENTIONS (binding, restated from D1 — they still hold):
--   * Objects are written UNQUALIFIED. The target schema is set by the
--     SET search_path line below, which db/apply-schema.mjs rewrites when
--     rendering the demo variant. Do NOT hard-code a schema name anywhere
--     in this file. The single exception is the 'public' literal inside a
--     SET search_path function clause, which is what the rewriter keys off.
--   * Singular snake_case tables, snake_case columns.
--   * Timestamps: timestamptz, column suffix _at. Dates: date, suffix _date.
--   * Constraints named pk_ / fk_<table>_<column> / uq_ / ck_ / idx_ / trg_.
--   * Money: integer paisa in bigint. Never float.
--   * Booleans prefixed is_ or has_.
--   * Every table gets created_at, updated_at and trg_<table>_updated_at.
--   * A cross-table rule is a BEFORE trigger raising 23514 (check_violation).
--   * NO RLS in this file. RLS is applied in D8, across every table.
--
-- ENUMS reused from D1, not redeclared: trip_status, checkin_method,
-- checkin_result. D2's beneficiary_type is reused on payout_line.
--
-- WHAT THIS FILE IS FOR
--   1. Routes, stops and the manifest: which child rides which route, and
--      where they are collected. Safety invariant 4 lives here: a route or a
--      trip can only be given to a driver who is platform-approved AND
--      school-approved, in a vehicle of their own that has been verified.
--   2. Trips and their state machine, driven ONLY through transition_trip().
--   3. Check-ins: every scan attempt is a row, including the failures, plus
--      short-lived hashed QR tokens.
--   4. The debts earlier migrations could not pay because their targets did
--      not exist yet: the deferred enrollment -> route block at the end of
--      D3, the D2 -> D3/D4 foreign keys, and two money hardening fixes found
--      in review.
-- =============================================================================

SET search_path TO public, extensions;

-- -----------------------------------------------------------------------------
-- assert_driver_assignable — safety invariant 4, written once
-- -----------------------------------------------------------------------------
-- A driver may carry children of a school only when ALL of these hold:
--   * driver.verification_status = 'approved'           (platform says yes)
--   * an active driver_school row with approved_at      (the school says yes)
--   * the vehicle belongs to that driver                (no borrowed vans)
--   * vehicle.is_vehicle_verified                       (papers sighted)
--
-- Called by the route trigger, the trip trigger, and transition_trip() when a
-- trip starts. The start-of-trip re-check is the one that matters most: a
-- driver suspended overnight still has yesterday's route assignment, and
-- must not be able to drive off with it in the morning.
--
-- SECURITY DEFINER because the caller (a school admin assigning a route, or a
-- driver starting a trip) will not be able to read every row it needs once
-- D8 is in place. search_path pinned, as for every definer in this series.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION assert_driver_assignable(
  p_driver_id  uuid,
  p_vehicle_id uuid,
  p_school_id  uuid
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_status         verification_status;
  v_vehicle_driver uuid;
  v_vehicle_ok     boolean;
BEGIN
  SELECT d.verification_status INTO v_status FROM driver d WHERE d.id = p_driver_id;

  IF v_status IS DISTINCT FROM 'approved' THEN
    RAISE EXCEPTION
      'driver % is not assignable: verification_status is % (must be approved)',
      p_driver_id, coalesce(v_status::text, 'no such driver')
      USING ERRCODE = 'check_violation';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM driver_school ds
     WHERE ds.driver_id = p_driver_id
       AND ds.school_id = p_school_id
       AND ds.is_active
       AND ds.approved_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION
      'driver % is not assignable: no active approved driver_school row for school %',
      p_driver_id, p_school_id
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_vehicle_id IS NOT NULL THEN
    SELECT v.driver_id, v.is_vehicle_verified
      INTO v_vehicle_driver, v_vehicle_ok
      FROM vehicle v WHERE v.id = p_vehicle_id;

    IF v_vehicle_driver IS DISTINCT FROM p_driver_id THEN
      RAISE EXCEPTION
        'vehicle % does not belong to driver %', p_vehicle_id, p_driver_id
        USING ERRCODE = 'check_violation';
    END IF;

    IF NOT v_vehicle_ok THEN
      RAISE EXCEPTION
        'vehicle % is not verified (is_vehicle_verified = false)', p_vehicle_id
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
END;
$$;

COMMENT ON FUNCTION assert_driver_assignable(uuid, uuid, uuid) IS
  'Raises 23514 unless the driver is approved, holds an active approved '
  'driver_school row for the school, and (when given) the vehicle is theirs '
  'and is_vehicle_verified. The single statement of safety invariant 4; the '
  'route and trip triggers and transition_trip() all call it.';

-- -----------------------------------------------------------------------------
-- route — one school, one driver, one vehicle
-- -----------------------------------------------------------------------------
-- Phase 1 routes belong to exactly one school (D3). driver_id and vehicle_id
-- may be NULL while a route is being planned; the moment they are set on an
-- ACTIVE route the assignment must pass assert_driver_assignable().
--
-- An INACTIVE route is not checked, on purpose: deactivating a route whose
-- driver has just been suspended must always succeed. Reactivating it
-- re-runs the check.
-- -----------------------------------------------------------------------------

CREATE TABLE route (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id   uuid        NOT NULL,
  name        text        NOT NULL,
  driver_id   uuid,
  vehicle_id  uuid,
  is_active   boolean     NOT NULL DEFAULT true,
  notes       text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_route_school_id FOREIGN KEY (school_id)
    REFERENCES school(id) ON DELETE RESTRICT,
  CONSTRAINT fk_route_driver_id FOREIGN KEY (driver_id)
    REFERENCES driver(id) ON DELETE RESTRICT,
  CONSTRAINT fk_route_vehicle_id FOREIGN KEY (vehicle_id)
    REFERENCES vehicle(id) ON DELETE RESTRICT,
  CONSTRAINT uq_route_school_id_name UNIQUE (school_id, name),
  CONSTRAINT ck_route_name_not_blank CHECK (length(btrim(name)) > 0),
  CONSTRAINT ck_route_vehicle_requires_driver CHECK (
    vehicle_id IS NULL OR driver_id IS NOT NULL
  )
);

COMMENT ON TABLE route IS
  'A transport route serving exactly one school, with its assigned driver and '
  'vehicle. trg_route_driver_assignable enforces safety invariant 4 on every '
  'active route: approved driver, active approved driver_school row for THIS '
  'school, and a verified vehicle owned by that driver. is_active = false '
  'suspends a route without deleting it, and makes its enrollments '
  'non-billable (see is_billable()).';
COMMENT ON COLUMN route.school_id IS
  'Immutable once set: manifests and enrollments were validated against this '
  'school, so moving the route would silently invalidate them. Create a new '
  'route instead.';
COMMENT ON COLUMN route.is_active IS
  'Billing gate 1 requires an ACTIVE route. Setting this false stops the '
  'route''s children being billed going forward without deleting history.';
COMMENT ON COLUMN route.driver_id IS
  'The default driver for this route''s trips. Each trip records its own '
  'driver and vehicle as well, because a substitute driver or a spare van on '
  'one day must not rewrite the route.';

CREATE OR REPLACE FUNCTION enforce_route_assignment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.school_id IS DISTINCT FROM OLD.school_id THEN
    RAISE EXCEPTION 'route %: school_id is immutable (was %, attempted %)',
      NEW.id, OLD.school_id, NEW.school_id
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.is_active AND NEW.driver_id IS NOT NULL THEN
    PERFORM assert_driver_assignable(NEW.driver_id, NEW.vehicle_id, NEW.school_id);
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION enforce_route_assignment() IS
  'BEFORE INSERT OR UPDATE guard on route: school_id is immutable, and an '
  'active route with a driver must satisfy assert_driver_assignable().';

CREATE TRIGGER trg_route_driver_assignable
  BEFORE INSERT OR UPDATE OF school_id, driver_id, vehicle_id, is_active ON route
  FOR EACH ROW EXECUTE FUNCTION enforce_route_assignment();

CREATE TRIGGER trg_route_updated_at
  BEFORE UPDATE ON route
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- uq_route_school_id_name already leads with school_id, so it serves that FK.
CREATE INDEX idx_route_driver_id  ON route (driver_id)  WHERE driver_id IS NOT NULL;
CREATE INDEX idx_route_vehicle_id ON route (vehicle_id) WHERE vehicle_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- route_stop — ordered pickup points
-- -----------------------------------------------------------------------------
-- geography, not geometry, for the same reason as student.home_location in
-- D3: distances must be metres on the spheroid, not degrees.
-- -----------------------------------------------------------------------------

CREATE TABLE route_stop (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  route_id    uuid        NOT NULL,
  stop_order  int         NOT NULL,
  name        text        NOT NULL,
  location    geography(Point, 4326) NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_route_stop_route_id FOREIGN KEY (route_id)
    REFERENCES route(id) ON DELETE CASCADE,
  CONSTRAINT uq_route_stop_route_id_stop_order UNIQUE (route_id, stop_order),
  -- Target of route_manifest's composite foreign key: lets the database, not
  -- a trigger, prove that a manifested stop belongs to the manifested route.
  CONSTRAINT uq_route_stop_id_route_id UNIQUE (id, route_id),
  CONSTRAINT ck_route_stop_stop_order_positive CHECK (stop_order > 0),
  CONSTRAINT ck_route_stop_name_not_blank CHECK (length(btrim(name)) > 0)
);

COMMENT ON TABLE route_stop IS
  'An ordered pickup point on a route. location is child-adjacent location '
  'data (it is where a named child waits) and is protected in D8 the same way '
  'as student.pickup_location.';
COMMENT ON COLUMN route_stop.stop_order IS
  'Position in the run, 1 first. Unique per route.';

CREATE TRIGGER trg_route_stop_updated_at
  BEFORE UPDATE ON route_stop
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- route_manifest — which child rides which route, from which stop
-- -----------------------------------------------------------------------------
-- The manifest is what a check-in is validated against: a child not on the
-- active manifest of the trip's route is 'wrong_child', however valid their
-- QR token is.
--
-- The stop/route pairing is a composite foreign key rather than a trigger,
-- so it cannot be bypassed. The student/school pairing needs a second table
-- (route.school_id vs student.school_id), so that one is a trigger.
-- -----------------------------------------------------------------------------

CREATE TABLE route_manifest (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  route_id       uuid        NOT NULL,
  route_stop_id  uuid        NOT NULL,
  student_id     uuid        NOT NULL,
  is_active      boolean     NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_route_manifest_route_id FOREIGN KEY (route_id)
    REFERENCES route(id) ON DELETE CASCADE,
  -- NO ACTION (checked at end of statement), not RESTRICT: deleting a route
  -- cascades to both its stops and its manifest in one statement, and a
  -- RESTRICT here would fire mid-cascade and refuse it.
  CONSTRAINT fk_route_manifest_route_stop_id FOREIGN KEY (route_stop_id, route_id)
    REFERENCES route_stop(id, route_id),
  CONSTRAINT fk_route_manifest_student_id FOREIGN KEY (student_id)
    REFERENCES student(id) ON DELETE RESTRICT
);

COMMENT ON TABLE route_manifest IS
  'Which student rides which route, collected at which stop. One active row '
  'per (route, student). The stop must belong to the route '
  '(fk_route_manifest_route_stop_id, composite) and the student must attend '
  'the route''s school (trg_route_manifest_student_school). Check-ins are '
  'validated against the active rows here.';
COMMENT ON COLUMN route_manifest.is_active IS
  'false keeps the history of who used to ride; only active rows count for '
  'check-in. A child moving stop is an inactive old row plus a new row.';

CREATE OR REPLACE FUNCTION enforce_route_manifest_student_school()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_route_school   uuid;
  v_student_school uuid;
BEGIN
  SELECT r.school_id INTO v_route_school   FROM route r   WHERE r.id = NEW.route_id;
  SELECT s.school_id INTO v_student_school FROM student s WHERE s.id = NEW.student_id;

  IF v_route_school IS DISTINCT FROM v_student_school THEN
    RAISE EXCEPTION
      'route_manifest: student % is on school %, but route % serves school %',
      NEW.student_id, v_student_school, NEW.route_id, v_route_school
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION enforce_route_manifest_student_school() IS
  'BEFORE INSERT OR UPDATE guard on route_manifest: the student must attend '
  'the school the route serves. Without it a child could be put on another '
  'school''s van, and that school''s driver would hold their location.';

CREATE TRIGGER trg_route_manifest_student_school
  BEFORE INSERT OR UPDATE OF route_id, student_id ON route_manifest
  FOR EACH ROW EXECUTE FUNCTION enforce_route_manifest_student_school();

CREATE TRIGGER trg_route_manifest_updated_at
  BEFORE UPDATE ON route_manifest
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE UNIQUE INDEX uq_route_manifest_one_active_per_route_student
  ON route_manifest (route_id, student_id) WHERE is_active;

CREATE INDEX idx_route_manifest_route_id      ON route_manifest (route_id);
CREATE INDEX idx_route_manifest_route_stop_id ON route_manifest (route_stop_id);
CREATE INDEX idx_route_manifest_student_id    ON route_manifest (student_id);

-- -----------------------------------------------------------------------------
-- trip — one run of one route on one date
-- -----------------------------------------------------------------------------
-- The trip records its own driver and vehicle (a substitute or a spare van is
-- normal) and they pass the same assert_driver_assignable() as the route.
--
-- STATUS IS NOT WRITABLE DIRECTLY. See transition_trip() below for the state
-- machine and for how the direct-UPDATE block works.
-- -----------------------------------------------------------------------------

CREATE TABLE trip (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  route_id       uuid        NOT NULL,
  driver_id      uuid        NOT NULL,
  vehicle_id     uuid        NOT NULL,
  trip_date      date        NOT NULL,
  status         trip_status NOT NULL DEFAULT 'scheduled',
  status_reason  text,
  started_at     timestamptz,
  ended_at       timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_trip_route_id FOREIGN KEY (route_id)
    REFERENCES route(id) ON DELETE RESTRICT,
  CONSTRAINT fk_trip_driver_id FOREIGN KEY (driver_id)
    REFERENCES driver(id) ON DELETE RESTRICT,
  CONSTRAINT fk_trip_vehicle_id FOREIGN KEY (vehicle_id)
    REFERENCES vehicle(id) ON DELETE RESTRICT,
  CONSTRAINT uq_trip_route_id_trip_date UNIQUE (route_id, trip_date),
  CONSTRAINT ck_trip_cancelled_requires_reason CHECK (
    status <> 'cancelled' OR coalesce(status_reason ~ '\S', false)
  )
);

COMMENT ON TABLE trip IS
  'One run of one route on one date. status moves ONLY through '
  'transition_trip(); a direct UPDATE of status is refused by '
  'trg_trip_status_guard. Driver and vehicle are recorded per trip and must '
  'pass assert_driver_assignable() for the route''s school, again when the '
  'trip starts. Trips are history: routes, drivers and vehicles with trips '
  'cannot be deleted (ON DELETE RESTRICT).';
COMMENT ON COLUMN trip.status_reason IS
  'Why the trip reached its current status. Mandatory and non-blank for '
  'cancelled (ck_trip_cancelled_requires_reason): parents are told why their '
  'child was not collected.';
COMMENT ON COLUMN trip.started_at IS
  'Set by transition_trip() on scheduled -> driver_en_route.';
COMMENT ON COLUMN trip.ended_at IS
  'Set by transition_trip() on entering a terminal status (completed, '
  'cancelled, no_show).';

CREATE OR REPLACE FUNCTION enforce_trip_assignment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_school    uuid;
  v_is_active boolean;
BEGIN
  SELECT r.school_id, r.is_active INTO v_school, v_is_active
    FROM route r WHERE r.id = NEW.route_id;

  IF TG_OP = 'INSERT' AND v_is_active IS NOT TRUE THEN
    RAISE EXCEPTION 'trip: route % is not active', NEW.route_id
      USING ERRCODE = 'check_violation';
  END IF;

  PERFORM assert_driver_assignable(NEW.driver_id, NEW.vehicle_id, v_school);
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION enforce_trip_assignment() IS
  'BEFORE INSERT OR UPDATE guard on trip: a new trip needs an active route, '
  'and the trip''s driver and vehicle must pass assert_driver_assignable() for '
  'the route''s school.';

CREATE TRIGGER trg_trip_driver_assignable
  BEFORE INSERT OR UPDATE OF route_id, driver_id, vehicle_id ON trip
  FOR EACH ROW EXECUTE FUNCTION enforce_trip_assignment();

-- -----------------------------------------------------------------------------
-- The trip state machine
-- -----------------------------------------------------------------------------
--
--   scheduled ──> driver_en_route ──> arrived_pickup ──> in_progress ──> arrived_school ──> completed
--       │               │                  │                 │                 │
--       └───────────────┴──────────────────┴─────────────────┴─────────────────┴──> cancelled
--       │                                  │
--       └──────────────────────────────────┴──> no_show
--
--   cancelled  from every pre-completed state, with a mandatory reason.
--   no_show    from 'scheduled' (the driver never set off) and from
--              'arrived_pickup' (the driver arrived, nobody boarded). Not from
--              in_progress or later: once a child is aboard, it is not a
--              no-show, it is a trip.
--   completed, cancelled and no_show are terminal.
--
-- HOW DIRECT UPDATES ARE BLOCKED (D1: transitions are enforced by a function,
-- not a trigger). The function is the only place the transition RULES live.
-- A trigger is still needed to stop code from going around the function, and
-- it checks one thing only: is this status change happening inside
-- transition_trip()? transition_trip() announces itself by setting the
-- transaction-local GUC rawaan.trip_transition to the id of the trip it is
-- about to update, and clears it straight after its UPDATE. The trigger
-- refuses any status change whose trip id does not match. Keying on the trip
-- id (not a plain on/off flag) means a flag left behind by one call cannot
-- authorise an UPDATE of a different trip later in the same transaction.
--
-- ponytail: the GUC is a guard against accidental bypass (application code,
-- an admin console UPDATE), not a security boundary — any session can call
-- set_config() itself. D8 closes the deliberate route: REVOKE UPDATE (status)
-- ON trip from anon and authenticated, so only transition_trip(), running as
-- its caller under the D8 RLS UPDATE policy, can change it. transition_trip()
-- is deliberately SECURITY INVOKER for that reason: as a definer it would let
-- any caller move any trip.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION trip_transition_is_legal(p_from trip_status, p_to trip_status)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(
    CASE p_from
      WHEN 'scheduled'       THEN p_to IN ('driver_en_route', 'cancelled', 'no_show')
      WHEN 'driver_en_route' THEN p_to IN ('arrived_pickup', 'cancelled')
      WHEN 'arrived_pickup'  THEN p_to IN ('in_progress', 'cancelled', 'no_show')
      WHEN 'in_progress'     THEN p_to IN ('arrived_school', 'cancelled')
      WHEN 'arrived_school'  THEN p_to IN ('completed', 'cancelled')
      ELSE false
    END,
    false);
$$;

COMMENT ON FUNCTION trip_transition_is_legal(trip_status, trip_status) IS
  'The trip state machine as a pure function. transition_trip() is its only '
  'enforcer; the driver app may call it to decide which buttons to show.';

CREATE OR REPLACE FUNCTION enforce_trip_status_via_transition()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'scheduled' THEN
      RAISE EXCEPTION 'trip: a new trip must start as scheduled, not %', NEW.status
        USING ERRCODE = 'check_violation';
    END IF;
  ELSIF NEW.status IS DISTINCT FROM OLD.status
        AND current_setting('rawaan.trip_transition', true) IS DISTINCT FROM OLD.id::text THEN
    RAISE EXCEPTION
      'trip %: status may only change through transition_trip() (attempted % -> %)',
      OLD.id, OLD.status, NEW.status
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION enforce_trip_status_via_transition() IS
  'BEFORE INSERT OR UPDATE OF status guard on trip: inserts start as '
  'scheduled, and a status change is refused unless transition_trip() has '
  'set rawaan.trip_transition to this trip''s id.';

CREATE TRIGGER trg_trip_status_guard
  BEFORE INSERT OR UPDATE OF status ON trip
  FOR EACH ROW EXECUTE FUNCTION enforce_trip_status_via_transition();

CREATE TRIGGER trg_trip_updated_at
  BEFORE UPDATE ON trip
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE OR REPLACE FUNCTION transition_trip(
  p_trip_id uuid,
  p_to      trip_status,
  p_reason  text DEFAULT NULL
)
RETURNS trip
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_trip   trip;
  v_school uuid;
BEGIN
  SELECT * INTO v_trip FROM trip WHERE id = p_trip_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'transition_trip: no trip %', p_trip_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT trip_transition_is_legal(v_trip.status, p_to) THEN
    RAISE EXCEPTION 'transition_trip: illegal trip transition % -> % for trip %',
      v_trip.status, p_to, p_trip_id
      USING ERRCODE = 'check_violation';
  END IF;

  -- The start of a trip re-checks safety invariant 4. The driver or vehicle
  -- may have been suspended or unverified since the trip was scheduled.
  IF p_to = 'driver_en_route' THEN
    SELECT r.school_id INTO v_school FROM route r WHERE r.id = v_trip.route_id;
    PERFORM assert_driver_assignable(v_trip.driver_id, v_trip.vehicle_id, v_school);
  END IF;

  PERFORM set_config('rawaan.trip_transition', p_trip_id::text, true);

  UPDATE trip
     SET status        = p_to,
         status_reason = coalesce(p_reason, status_reason),
         started_at    = CASE WHEN p_to = 'driver_en_route' THEN now() ELSE started_at END,
         ended_at      = CASE WHEN p_to IN ('completed', 'cancelled', 'no_show')
                              THEN now() ELSE ended_at END
   WHERE id = p_trip_id
  RETURNING * INTO v_trip;

  PERFORM set_config('rawaan.trip_transition', '', true);

  RETURN v_trip;
END;
$$;

COMMENT ON FUNCTION transition_trip(uuid, trip_status, text) IS
  'The ONLY way to change trip.status. Raises 23514 on an illegal move (see '
  'trip_transition_is_legal()), re-checks assert_driver_assignable() when a '
  'trip starts, stamps started_at / ended_at, and records p_reason (mandatory '
  'for cancelled). SECURITY INVOKER on purpose: D8''s RLS decides who may move '
  'which trip.';

-- uq_trip_route_id_trip_date leads with route_id and serves that FK.
CREATE INDEX idx_trip_driver_id_trip_date ON trip (driver_id, trip_date);
CREATE INDEX idx_trip_vehicle_id          ON trip (vehicle_id);

-- -----------------------------------------------------------------------------
-- trip_qr_token — short-lived, hashed, single-use boarding passes
-- -----------------------------------------------------------------------------
-- The guardian's app asks issue_trip_qr_token() for a token for one child on
-- one trip, shows it as a QR code, and the driver scans it. The database
-- keeps ONLY the SHA-256 of the token. A dump, a log line or a read replica
-- therefore never holds a token that could board a child.
--
-- Unsalted SHA-256 is correct here and is not a password-hashing shortcut:
-- the token is 32 random bytes (256 bits), so there is no dictionary to
-- precompute against, and the lookup has to be an equality on the hash.
--
-- Short-lived is a CHECK, not a convention: a token may live at most 15
-- minutes. Purging expired rows is safe at any time; trip_checkin keeps its
-- record (fk ON DELETE SET NULL).
-- -----------------------------------------------------------------------------

CREATE TABLE trip_qr_token (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id      uuid        NOT NULL,
  student_id   uuid        NOT NULL,
  token_hash   bytea       NOT NULL,
  expires_at   timestamptz NOT NULL,
  consumed_at  timestamptz,
  issued_by    uuid,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_trip_qr_token_trip_id FOREIGN KEY (trip_id)
    REFERENCES trip(id) ON DELETE CASCADE,
  CONSTRAINT fk_trip_qr_token_student_id FOREIGN KEY (student_id)
    REFERENCES student(id) ON DELETE CASCADE,
  CONSTRAINT uq_trip_qr_token_token_hash UNIQUE (token_hash),
  CONSTRAINT ck_trip_qr_token_token_hash_sha256 CHECK (octet_length(token_hash) = 32),
  CONSTRAINT ck_trip_qr_token_short_lived CHECK (
    expires_at > created_at AND expires_at <= created_at + interval '15 minutes'
  )
);

COMMENT ON TABLE trip_qr_token IS
  'A boarding pass for one student on one trip. Stores the SHA-256 of the '
  'token, never the token: the raw value exists only in the response of '
  'issue_trip_qr_token() and on the guardian''s screen. Lives at most 15 '
  'minutes (ck_trip_qr_token_short_lived) and boards a child at most once.';
COMMENT ON COLUMN trip_qr_token.token_hash IS
  'digest(token, ''sha256''). 32 bytes, enforced by check.';
COMMENT ON COLUMN trip_qr_token.consumed_at IS
  'Set by the successful check-in that used this token. A re-scan of a '
  'consumed token records already_checked_in.';
COMMENT ON COLUMN trip_qr_token.issued_by IS
  'app_user id of the guardian who requested the token. Plain uuid audit '
  'pointer, no foreign key (see rate_snapshot.created_by).';

CREATE TRIGGER trg_trip_qr_token_updated_at
  BEFORE UPDATE ON trip_qr_token
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_trip_qr_token_trip_id_student_id ON trip_qr_token (trip_id, student_id);
CREATE INDEX idx_trip_qr_token_student_id         ON trip_qr_token (student_id);

CREATE OR REPLACE FUNCTION issue_trip_qr_token(
  p_trip_id    uuid,
  p_student_id uuid,
  p_ttl        interval DEFAULT interval '5 minutes',
  p_issued_by  uuid DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_status trip_status;
  v_token  text;
BEGIN
  SELECT t.status INTO v_status FROM trip t WHERE t.id = p_trip_id;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'issue_trip_qr_token: no trip %', p_trip_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_status IN ('completed', 'cancelled', 'no_show') THEN
    RAISE EXCEPTION 'issue_trip_qr_token: trip % is already %', p_trip_id, v_status
      USING ERRCODE = 'check_violation';
  END IF;

  v_token := encode(gen_random_bytes(32), 'hex');

  INSERT INTO trip_qr_token (trip_id, student_id, token_hash, expires_at, issued_by)
  VALUES (p_trip_id, p_student_id, digest(v_token, 'sha256'), now() + p_ttl, p_issued_by);

  RETURN v_token;
END;
$$;

COMMENT ON FUNCTION issue_trip_qr_token(uuid, uuid, interval, uuid) IS
  'Mints a 256-bit random token for one student on one trip, stores only its '
  'SHA-256, and returns the raw token once. p_ttl above 15 minutes is refused '
  'by ck_trip_qr_token_short_lived. Manifest membership is NOT checked here: '
  'record_trip_checkin() is the single place a boarding is validated.';

-- -----------------------------------------------------------------------------
-- is_student_absent — the D6 hook for the child_absent check-in result
-- -----------------------------------------------------------------------------
-- D6 creates the absence table. D5 cannot read a table that does not exist,
-- so the check-in path calls this small hook instead, and D6 CREATE OR
-- REPLACEs it with the real lookup (an absence for that student on that date
-- whose status is not 'cancelled').
--
-- Chosen over to_regclass('absence') plus dynamic SQL inside the check-in
-- function: that would make D5 guess D6's column names and hide a typo until
-- run time. A replaced hook is checked when D6 is applied, keeps
-- record_trip_checkin() untouched, and has exactly one signature to honour.
-- Until D6 lands it answers false, so child_absent cannot occur.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION is_student_absent(p_student_id uuid, p_on date)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT false;
$$;

COMMENT ON FUNCTION is_student_absent(uuid, date) IS
  'D6 HOOK. True when a guardian has reported the student absent on p_on. '
  'D5 ships a stub returning false; D6 CREATE OR REPLACEs it to read the '
  'absence table. Keep the signature: record_trip_checkin() calls it.';

-- -----------------------------------------------------------------------------
-- trip_checkin — every scan attempt, including the failures
-- -----------------------------------------------------------------------------
-- A failed scan is evidence: a run of wrong_trip scans is a child at the
-- wrong van, a burst of expired_token is a phone with a wrong clock or a
-- screenshot being replayed. Recording only successes would throw that away,
-- so record_trip_checkin() writes a row for every attempt.
-- -----------------------------------------------------------------------------

CREATE TABLE trip_checkin (
  id           uuid           PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id      uuid           NOT NULL,
  student_id   uuid,
  qr_token_id  uuid,
  method       checkin_method NOT NULL,
  result       checkin_result NOT NULL,
  scanned_by   uuid,
  scanned_at   timestamptz    NOT NULL DEFAULT now(),
  created_at   timestamptz    NOT NULL DEFAULT now(),
  updated_at   timestamptz    NOT NULL DEFAULT now(),
  CONSTRAINT fk_trip_checkin_trip_id FOREIGN KEY (trip_id)
    REFERENCES trip(id) ON DELETE RESTRICT,
  CONSTRAINT fk_trip_checkin_student_id FOREIGN KEY (student_id)
    REFERENCES student(id) ON DELETE RESTRICT,
  CONSTRAINT fk_trip_checkin_qr_token_id FOREIGN KEY (qr_token_id)
    REFERENCES trip_qr_token(id) ON DELETE SET NULL,
  CONSTRAINT ck_trip_checkin_success_has_student CHECK (
    result <> 'success' OR student_id IS NOT NULL
  ),
  CONSTRAINT ck_trip_checkin_manual_has_no_token CHECK (
    method <> 'manual_override' OR qr_token_id IS NULL
  )
);

COMMENT ON TABLE trip_checkin IS
  'One row per scan attempt on a trip, whatever its outcome. Written by '
  'record_trip_checkin(). At most one success per (trip, student) '
  '(uq_trip_checkin_one_success_per_trip_student), so a double scan can '
  'never board a child twice.';
COMMENT ON COLUMN trip_checkin.student_id IS
  'The child the attempt was about: the token''s student for a QR scan, the '
  'chosen student for a manual override. NULL only when an unknown token was '
  'scanned, since there is then no child to name.';
COMMENT ON COLUMN trip_checkin.result IS
  'expired_token covers unknown tokens too, deliberately: the scanner must '
  'not be an oracle for which tokens ever existed. wrong_trip also covers a '
  'scan on a trip that is not boarding (not driver_en_route, arrived_pickup '
  'or in_progress).';
COMMENT ON COLUMN trip_checkin.scanned_by IS
  'app_user id of the driver (or admin) who scanned. Plain uuid audit '
  'pointer, no foreign key.';

CREATE TRIGGER trg_trip_checkin_updated_at
  BEFORE UPDATE ON trip_checkin
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE UNIQUE INDEX uq_trip_checkin_one_success_per_trip_student
  ON trip_checkin (trip_id, student_id) WHERE result = 'success';

CREATE INDEX idx_trip_checkin_trip_id_student_id ON trip_checkin (trip_id, student_id);
CREATE INDEX idx_trip_checkin_student_id ON trip_checkin (student_id)
  WHERE student_id IS NOT NULL;
CREATE INDEX idx_trip_checkin_qr_token_id ON trip_checkin (qr_token_id)
  WHERE qr_token_id IS NOT NULL;

CREATE OR REPLACE FUNCTION record_trip_checkin(
  p_trip_id    uuid,
  p_method     checkin_method,
  p_token      text DEFAULT NULL,
  p_student_id uuid DEFAULT NULL,
  p_scanned_by uuid DEFAULT NULL
)
RETURNS checkin_result
LANGUAGE plpgsql
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_trip    trip;
  v_token   trip_qr_token;
  v_student uuid := p_student_id;
  v_result  checkin_result;
BEGIN
  -- Malformed calls are programming errors, not scan attempts: they raise.
  SELECT * INTO v_trip FROM trip WHERE id = p_trip_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_trip_checkin: no trip %', p_trip_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF p_method = 'qr_scan' AND p_token IS NULL THEN
    RAISE EXCEPTION 'record_trip_checkin: a qr_scan needs p_token'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_method = 'manual_override' AND (p_student_id IS NULL OR p_token IS NOT NULL) THEN
    RAISE EXCEPTION 'record_trip_checkin: a manual_override needs p_student_id and no p_token'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Token checks, in order: unknown or expired, other trip, other child.
  IF p_method = 'qr_scan' THEN
    SELECT * INTO v_token FROM trip_qr_token WHERE token_hash = digest(p_token, 'sha256');

    IF v_token.id IS NOT NULL THEN
      v_student := v_token.student_id;
    END IF;

    IF v_token.id IS NULL OR v_token.expires_at <= now() THEN
      v_result := 'expired_token';
    ELSIF v_token.trip_id <> p_trip_id THEN
      v_result := 'wrong_trip';
    ELSIF p_student_id IS NOT NULL AND p_student_id <> v_token.student_id THEN
      v_result := 'wrong_child';
    END IF;
  END IF;

  IF v_result IS NULL
     AND v_trip.status NOT IN ('driver_en_route', 'arrived_pickup', 'in_progress') THEN
    v_result := 'wrong_trip';
  END IF;

  IF v_result IS NULL AND NOT EXISTS (
    SELECT 1 FROM route_manifest m
     WHERE m.route_id = v_trip.route_id AND m.student_id = v_student AND m.is_active
  ) THEN
    v_result := 'wrong_child';
  END IF;

  IF v_result IS NULL AND is_student_absent(v_student, v_trip.trip_date) THEN
    v_result := 'child_absent';
  END IF;

  IF v_result IS NULL AND EXISTS (
    SELECT 1 FROM trip_checkin c
     WHERE c.trip_id = p_trip_id AND c.student_id = v_student AND c.result = 'success'
  ) THEN
    v_result := 'already_checked_in';
  END IF;

  IF v_result IS NULL THEN
    BEGIN
      INSERT INTO trip_checkin (trip_id, student_id, qr_token_id, method, result, scanned_by)
      VALUES (p_trip_id, v_student, v_token.id, p_method, 'success', p_scanned_by);

      UPDATE trip_qr_token SET consumed_at = now() WHERE id = v_token.id;
      RETURN 'success';
    EXCEPTION WHEN unique_violation THEN
      -- A concurrent scan of the same child won the race.
      v_result := 'already_checked_in';
    END;
  END IF;

  INSERT INTO trip_checkin (trip_id, student_id, qr_token_id, method, result, scanned_by)
  VALUES (p_trip_id, v_student, v_token.id, p_method, v_result, p_scanned_by);

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION record_trip_checkin(uuid, checkin_method, text, uuid, uuid) IS
  'Records ONE scan attempt and returns its checkin_result. Every attempt is '
  'written, failures included. Order of checks: expired_token (unknown or '
  'past expires_at), wrong_trip (token for another trip, or this trip is not '
  'boarding), wrong_child (token for another child than the one selected, or '
  'child not on the route''s active manifest), child_absent (D6 hook '
  'is_student_absent()), already_checked_in, then success. Raises only for '
  'malformed calls: unknown trip, qr_scan without a token, manual_override '
  'without a student or with a token.';

-- =============================================================================
-- THE DEFERRED BLOCK FROM D3 — enrollment.route_id
-- =============================================================================
-- Applied exactly as D3 promised, with one deliberate difference: the FK is
-- DEFERRABLE INITIALLY DEFERRED. The route id is still checked, at COMMIT
-- instead of per statement, so an enrollment and its route can be written
-- in either order inside one transaction (and D3's own test, which uses a
-- sentinel route id and deletes its rows before commit, keeps working).
-- Committed data always satisfies the FK.
--
-- For the same reason is_billable() and the view are written as "has a
-- route, and that route is not inactive". With the FK in force that is
-- identical to "the route is active" for every committed row.
-- =============================================================================

ALTER TABLE enrollment
  ADD CONSTRAINT fk_enrollment_route
  FOREIGN KEY (route_id) REFERENCES route(id)
  ON DELETE SET NULL
  DEFERRABLE INITIALLY DEFERRED;

CREATE INDEX idx_enrollment_route_id ON enrollment (route_id);

COMMENT ON COLUMN enrollment.route_id IS
  'Assigned route, or NULL while the child is not transported by Rawaan. '
  'fk_enrollment_route (D5, ON DELETE SET NULL, deferred to commit). Billing '
  'gate 1 requires the route to be active: route.is_active = false makes the '
  'enrollment non-billable going forward without deleting anything.';

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
      AND NOT EXISTS (
        SELECT 1 FROM route r WHERE r.id = e.route_id AND NOT r.is_active
      )
      AND e.starts_on <= p_period_end
      AND (e.ends_on IS NULL OR e.ends_on >= p_period_start)
    FROM enrollment e
   WHERE e.id = p_enrollment_id
  ), false);
$$;

COMMENT ON FUNCTION is_billable(uuid, date, date) IS
  'TRUE when the enrollment may be BILLED for a period: status active, an '
  'ACTIVE route assigned (D5), and the starts_on/ends_on window overlapping '
  'the period. FALSE means transport-ineligible, NOT unpaid. An unknown '
  'enrollment_id also returns FALSE. The billing engine must call this rather '
  'than filter on a stored flag, because there is no stored flag to drift.';

CREATE OR REPLACE VIEW v_billable_enrollment
WITH (security_invoker = true) AS
SELECT
  e.*,
  (
      e.status = 'active'
  AND e.route_id IS NOT NULL
  AND r.is_active IS NOT FALSE
  AND e.starts_on <= CURRENT_DATE
  AND (e.ends_on IS NULL OR e.ends_on >= CURRENT_DATE)
  ) AS is_billable
FROM enrollment e
LEFT JOIN route r ON r.id = e.route_id;

COMMENT ON VIEW v_billable_enrollment IS
  'Every enrollment, one row each, with is_billable computed from status, an '
  'ACTIVE route and the date window AS OF TODAY. Agrees with is_billable() for '
  'CURRENT_DATE. For a specific billing period call is_billable() instead. '
  'security_invoker = true so D8''s RLS applies to whoever queries it.';

-- =============================================================================
-- D2 -> D3/D4 FOREIGN KEYS
-- =============================================================================
-- D2 runs before D3 and D4, so these columns were plain uuids. All RESTRICT:
-- money records must never disappear because a school, guardian or payout
-- row was deleted. The polymorphic beneficiary_id columns stay FK-less on
-- purpose (see split_allocation.beneficiary_id).
--
-- Indexes: every one of these columns is already the leading column of an
-- index except rate_snapshot.school_id (its unique index is partial),
-- payment.guardian_id, payout.school_id and driver_earning.payout_id.
-- =============================================================================

ALTER TABLE rate_snapshot
  ADD CONSTRAINT fk_rate_snapshot_school_id FOREIGN KEY (school_id)
    REFERENCES school(id) ON DELETE RESTRICT;

ALTER TABLE billing_period
  ADD CONSTRAINT fk_billing_period_school_id FOREIGN KEY (school_id)
    REFERENCES school(id) ON DELETE RESTRICT;

ALTER TABLE invoice
  ADD CONSTRAINT fk_invoice_enrollment_id FOREIGN KEY (enrollment_id)
    REFERENCES enrollment(id) ON DELETE RESTRICT,
  ADD CONSTRAINT fk_invoice_guardian_id FOREIGN KEY (guardian_id)
    REFERENCES guardian(id) ON DELETE RESTRICT,
  ADD CONSTRAINT fk_invoice_school_id FOREIGN KEY (school_id)
    REFERENCES school(id) ON DELETE RESTRICT;

ALTER TABLE payment
  ADD CONSTRAINT fk_payment_guardian_id FOREIGN KEY (guardian_id)
    REFERENCES guardian(id) ON DELETE RESTRICT;

ALTER TABLE payout
  ADD CONSTRAINT fk_payout_school_id FOREIGN KEY (school_id)
    REFERENCES school(id) ON DELETE RESTRICT;

ALTER TABLE driver_earning
  ADD CONSTRAINT fk_driver_earning_payout_id FOREIGN KEY (payout_id)
    REFERENCES payout(id) ON DELETE RESTRICT;

COMMENT ON COLUMN driver_earning.payout_id IS
  'The D2 payout this earning was released in. fk_driver_earning_payout_id '
  'added by D5 (D2 runs before D4, so neither could declare it). RESTRICT: a '
  'released payout cannot be deleted out from under its earnings record.';

CREATE INDEX idx_rate_snapshot_school_id ON rate_snapshot (school_id);
CREATE INDEX idx_payment_guardian_id     ON payment (guardian_id);
CREATE INDEX idx_payout_school_id        ON payout (school_id);
CREATE INDEX idx_driver_earning_payout_id ON driver_earning (payout_id)
  WHERE payout_id IS NOT NULL;

-- =============================================================================
-- MONEY HARDENING (found in review)
-- =============================================================================

-- 1. An invoice can never be negative. A credit larger than the charges is an
--    adjustment owed to the guardian, not an invoice with a minus sign that a
--    payout run would read as money owed by Rawaan.
ALTER TABLE invoice
  ADD CONSTRAINT ck_invoice_subtotal_non_negative CHECK (subtotal_paisa >= 0),
  ADD CONSTRAINT ck_invoice_total_non_negative    CHECK (total_paisa >= 0);

-- 2. One invoice line is payable at most ONCE per beneficiary type, across
--    all payouts. D2's UNIQUE (payout_id, invoice_line_id) only stops the same
--    line twice in ONE payout; two driver payouts could each include it and
--    pay the driver leg twice. payout_line now carries its payout's
--    beneficiary_type, copied by trigger (callers cannot set it), and a unique
--    index closes the hole. A failed or cancelled payout must DELETE its
--    payout_line rows to release them for a retry: that is an explicit,
--    auditable act rather than something a status flip does silently.

ALTER TABLE payout_line ADD COLUMN beneficiary_type beneficiary_type;

UPDATE payout_line pl
   SET beneficiary_type = p.beneficiary_type
  FROM payout p
 WHERE p.id = pl.payout_id;

ALTER TABLE payout_line ALTER COLUMN beneficiary_type SET NOT NULL;

COMMENT ON COLUMN payout_line.beneficiary_type IS
  'Copy of payout.beneficiary_type, maintained by trg_payout_line_beneficiary_type '
  '(on insert/update) and trg_payout_beneficiary_type_sync (when the payout '
  'changes). Whatever the caller passes is overwritten. Exists only to back '
  'uq_payout_line_invoice_line_id_beneficiary_type.';

CREATE OR REPLACE FUNCTION set_payout_line_beneficiary_type()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  SELECT p.beneficiary_type INTO NEW.beneficiary_type
    FROM payout p WHERE p.id = NEW.payout_id;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION set_payout_line_beneficiary_type() IS
  'BEFORE INSERT OR UPDATE on payout_line: copies beneficiary_type from the '
  'parent payout, overwriting any value supplied, so the double-payout guard '
  'cannot be dodged by mislabelling a line.';

CREATE TRIGGER trg_payout_line_beneficiary_type
  BEFORE INSERT OR UPDATE ON payout_line
  FOR EACH ROW EXECUTE FUNCTION set_payout_line_beneficiary_type();

CREATE OR REPLACE FUNCTION sync_payout_line_beneficiary_type()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  UPDATE payout_line SET beneficiary_type = NEW.beneficiary_type
   WHERE payout_id = NEW.id;
  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION sync_payout_line_beneficiary_type() IS
  'AFTER UPDATE OF beneficiary_type on payout: re-labels the payout''s lines, '
  'so relabelling a payout is also checked against the double-payout index.';

CREATE TRIGGER trg_payout_beneficiary_type_sync
  AFTER UPDATE OF beneficiary_type ON payout
  FOR EACH ROW
  WHEN (OLD.beneficiary_type IS DISTINCT FROM NEW.beneficiary_type)
  EXECUTE FUNCTION sync_payout_line_beneficiary_type();

CREATE UNIQUE INDEX uq_payout_line_invoice_line_id_beneficiary_type
  ON payout_line (invoice_line_id, beneficiary_type);

COMMENT ON INDEX uq_payout_line_invoice_line_id_beneficiary_type IS
  'An invoice line''s driver leg and school leg are each paid out at most '
  'once, across every payout. Also serves fk_payout_line_invoice_line_id.';

-- =============================================================================
-- Deliberately NOT in this file
-- =============================================================================
--   * The absence table and the real is_student_absent(). D6.
--   * Live GPS / trip location tracking. Location reads go through
--     can_view_student_location() in D8 and are a later step.
--   * A check that enrollment.route_id serves the enrollment's school, and
--     that it matches the child's route_manifest. Not in the D5 contract;
--     worth adding with the B-series enrollment flow.
--   * RLS, and the REVOKE UPDATE (status) ON trip that turns the
--     transition_trip() guard into a security boundary. D8.
-- =============================================================================
