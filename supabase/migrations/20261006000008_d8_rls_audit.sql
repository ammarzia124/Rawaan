-- =============================================================================
-- D8 — Row-level security, grants, and the append-only audit log
-- =============================================================================
-- CONVENTIONS (binding, restated from D1 — they still hold):
--   * Objects are written UNQUALIFIED. The target schema is set by the
--     SET search_path line below, which db/apply-schema.mjs rewrites when
--     rendering the demo variant. Where a statement needs the schema NAME
--     (a grant loop, ALTER DEFAULT PRIVILEGES) it is read from
--     current_schema() inside a DO block, never written as a literal. The
--     single literal is the 'public' inside SECURITY DEFINER search_path
--     clauses, which is what the rewriter keys off.
--   * Singular snake_case tables, constraint names pk_/fk_/uq_/ck_/idx_/trg_.
--   * Every SECURITY DEFINER function pins SET search_path = public, pg_temp.
--   * NO FORCE ROW LEVEL SECURITY. The migration owner (and service_role,
--     which has BYPASSRLS) keep full access: they are the billing run, the
--     admin back office and the test suite. RLS is for anon and authenticated,
--     the two roles a browser or a phone can reach.
--
-- WHAT THIS FILE IS FOR
--   This file is the product's safety boundary. It protects three things a
--   leak of which cannot be undone: where a child is (student home and pickup
--   locations, route stops, manifests), who a driver is (CNIC and licence
--   scans in driver_document), and money (invoices, payments, earnings).
--
--   1. ENABLE ROW LEVEL SECURITY on every table, by a loop over pg_class, so
--      no table can be forgotten. D8's test asserts relrowsecurity everywhere.
--   2. Small SECURITY DEFINER helpers that answer "is the caller X of Y", and
--      explicit policies per table built only on those helpers plus D1's
--      current_app_user_id() / current_app_role() / is_admin().
--   3. Column privileges where RLS cannot help (RLS hides rows, not columns):
--      student location columns, trip.status, app_user.role.
--   4. EXECUTE hygiene: every function in the schema is revoked from PUBLIC,
--      anon and authenticated, then granted back one by one, deliberately.
--   5. Table-grant hygiene: anon loses everything except INSERT on lead.
--   6. audit_log, append-only, written by one generic trigger on the
--      privileged writes.
--   7. The D4 "known limitation": a role change away from driver / school /
--      parent is refused while the rows that depend on that role exist.
--
-- HOW THE POLICIES ARE SHAPED
--   * Every policy is TO authenticated (except lead's public insert). anon
--     has no policy anywhere, and no table privilege either, so an anonymous
--     request is refused by the grant before RLS is even consulted.
--   * Every table gets <table>_admin_all, FOR ALL USING (is_admin()), from
--     the same loop that enables RLS. Admin sees and writes everything that
--     its column privileges allow; role-specific policies are added below.
--   * Every helper call is wrapped as (select fn(...)) per the Supabase RLS
--     performance rule, so a call without row arguments is evaluated once
--     per statement instead of once per row.
--   * A role that should see nothing simply has no policy: RLS denies by
--     default. Where this file writes "no policy" it means it, e.g.
--     driver_document for parents and schools.
-- =============================================================================

SET search_path TO public, extensions;

-- -----------------------------------------------------------------------------
-- Default privileges: future objects created by this role in this schema are
-- no longer granted to anon. Supabase's defaults (reproduced by the runner)
-- GRANT ALL on every new table and function to anon; a D9 table would
-- otherwise arrive readable by the whole internet until someone noticed.
-- -----------------------------------------------------------------------------

DO $$
BEGIN
  EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I REVOKE ALL ON TABLES FROM anon', current_schema());
  EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I REVOKE ALL ON SEQUENCES FROM anon', current_schema());
  EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I REVOKE ALL ON FUNCTIONS FROM anon', current_schema());
END
$$;

-- =============================================================================
-- 1. Caller helpers
-- =============================================================================
-- All STABLE, SECURITY DEFINER, search_path pinned. DEFINER because they read
-- tables the caller cannot read under RLS (guardian, school_admin, driver,
-- route_manifest), which is also what keeps policies from recursing into each
-- other: a policy that calls a definer helper never re-enters RLS.
--
-- Each answers ONE yes/no question about the CALLER and never returns data,
-- so granting them to authenticated leaks nothing beyond that boolean.
-- -----------------------------------------------------------------------------

-- is_service_context — "this call did not come from the API's end-user roles".
-- Inside a SECURITY DEFINER function current_user is the owner, but the role
-- GUC still holds what SET ROLE set: 'authenticated' / 'anon' for a PostgREST
-- request, 'service_role' for a backend job, 'none' for the migration owner
-- and the test suite. The definer functions below use it to let the owner and
-- service_role through while end users are checked.
-- ponytail: trusts that end users cannot run arbitrary SQL (they cannot via
-- PostgREST: set_config/RESET ROLE are not exposed). If raw SQL access is ever
-- handed to end users, replace with an explicit service-role claim check.
CREATE OR REPLACE FUNCTION is_service_context()
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(current_setting('role', true), 'none') NOT IN ('anon', 'authenticated');
$$;

COMMENT ON FUNCTION is_service_context() IS
  'True when the caller is not an API end user (role GUC is neither anon nor '
  'authenticated): the migration owner, service_role, the test suite. Used by '
  'the guarded SECURITY DEFINER functions to keep backend paths open.';

CREATE OR REPLACE FUNCTION current_driver_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT d.id FROM driver d
   WHERE d.app_user_id = current_app_user_id() AND d.is_active;
$$;

COMMENT ON FUNCTION current_driver_id() IS
  'driver.id of the calling user, or NULL (not a driver, inactive driver row, '
  'inactive account, anonymous). A NULL compares false in every policy.';

CREATE OR REPLACE FUNCTION is_guardian_of(p_student_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM guardian g
     WHERE g.student_id = p_student_id AND g.app_user_id = current_app_user_id()
  );
$$;

COMMENT ON FUNCTION is_guardian_of(uuid) IS
  'True when the caller holds a guardian row for the student.';

CREATE OR REPLACE FUNCTION is_own_guardian_row(p_guardian_id uuid, p_must_manage_payments boolean DEFAULT false)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM guardian g
     WHERE g.id = p_guardian_id
       AND g.app_user_id = current_app_user_id()
       AND (NOT p_must_manage_payments OR g.can_manage_payments)
  );
$$;

COMMENT ON FUNCTION is_own_guardian_row(uuid, boolean) IS
  'True when guardian row p_guardian_id belongs to the caller (and, with '
  'p_must_manage_payments, carries can_manage_payments). invoice.guardian_id '
  'and payment.guardian_id are guardian ids, not app_user ids.';

CREATE OR REPLACE FUNCTION is_school_staff_of(p_school_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM school_admin sa
     WHERE sa.school_id = p_school_id AND sa.app_user_id = current_app_user_id()
  );
$$;

COMMENT ON FUNCTION is_school_staff_of(uuid) IS
  'True when the caller has a school_admin row for the school.';

CREATE OR REPLACE FUNCTION can_view_school_earnings(p_school_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM school_admin sa
     WHERE sa.school_id = p_school_id
       AND sa.app_user_id = current_app_user_id()
       AND sa.can_view_earnings
  );
$$;

COMMENT ON FUNCTION can_view_school_earnings(uuid) IS
  'True when the caller is staff of the school WITH school_admin.can_view_earnings. '
  'The gate for every school revenue-share figure (split_allocation school legs, '
  'school payouts, rate_snapshot, school_earnings_paisa()).';

CREATE OR REPLACE FUNCTION can_approve_drivers_for(p_school_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM school_admin sa
     WHERE sa.school_id = p_school_id
       AND sa.app_user_id = current_app_user_id()
       AND sa.can_approve_drivers
  );
$$;

COMMENT ON FUNCTION can_approve_drivers_for(uuid) IS
  'True when the caller is staff of the school with can_approve_drivers. Closes '
  'the D4 note on driver_school.approved_by: only such staff (or admin) may '
  'write driver_school rows for that school, and only in their own name.';

CREATE OR REPLACE FUNCTION is_guardian_at_school(p_school_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM guardian g JOIN student s ON s.id = g.student_id
     WHERE g.app_user_id = current_app_user_id() AND s.school_id = p_school_id
  );
$$;

COMMENT ON FUNCTION is_guardian_at_school(uuid) IS
  'True when the caller is a guardian of some child of the school.';

CREATE OR REPLACE FUNCTION is_driver_at_school(p_school_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM driver_school ds
     WHERE ds.school_id = p_school_id
       AND ds.driver_id = current_driver_id()
       AND ds.is_active
  );
$$;

COMMENT ON FUNCTION is_driver_at_school(uuid) IS
  'True when the caller is a driver with an active driver_school row for the school.';

CREATE OR REPLACE FUNCTION is_driver_of_route(p_route_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM route r
     WHERE r.id = p_route_id AND r.is_active AND r.driver_id = current_driver_id()
  );
$$;

COMMENT ON FUNCTION is_driver_of_route(uuid) IS
  'True when the caller is the driver currently assigned to the ACTIVE route.';

CREATE OR REPLACE FUNCTION is_driver_linked_to_my_school(p_driver_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM driver_school ds
      JOIN school_admin sa ON sa.school_id = ds.school_id
     WHERE ds.driver_id = p_driver_id AND sa.app_user_id = current_app_user_id()
  );
$$;

COMMENT ON FUNCTION is_driver_linked_to_my_school(uuid) IS
  'True when the driver has any driver_school row (pending, active or ended) '
  'with a school the caller is staff of. A school must see a pending driver to '
  'approve them, which is why inactive rows count.';

-- -----------------------------------------------------------------------------
-- can_view_student_location — THE child-location gate (D3, D5)
-- -----------------------------------------------------------------------------
-- Exactly three kinds of caller may know where a child is:
--   * a guardian of the child;
--   * the driver currently assigned to an ACTIVE route on which the child is
--     ACTIVELY manifested (route.driver_id, not "any driver at the school",
--     and not a driver whose route was deactivated);
--   * an admin.
-- School staff are deliberately absent: a school needs to know who rides,
-- not where they sleep. Their single sanctioned location read is
-- find_nearby_students() for their own school, required by the D3 contract.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION can_view_student_location(p_student_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT is_admin()
      OR is_guardian_of(p_student_id)
      OR EXISTS (
           SELECT 1 FROM route_manifest m
             JOIN route r ON r.id = m.route_id
            WHERE m.student_id = p_student_id
              AND m.is_active
              AND r.is_active
              AND r.driver_id = current_driver_id()
         );
$$;

COMMENT ON FUNCTION can_view_student_location(uuid) IS
  'The child-location boundary: guardian of the child, the driver assigned to '
  'an active route the child is actively manifested on, or admin. Gates the '
  'student, route_manifest and route_stop policies and student_location().';

-- -----------------------------------------------------------------------------
-- student_location — the ONLY end-user read path for a child's location
-- -----------------------------------------------------------------------------
-- RLS cannot hide columns, so student.home_address / home_location /
-- pickup_location have their column SELECT privilege revoked from
-- authenticated (section 4) and are served here, one child at a time, after
-- can_view_student_location() says yes. A caller who may see the student row
-- (school staff) still cannot see where the child lives.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION student_location(p_student_id uuid)
RETURNS TABLE (
  home_address    text,
  home_location   geography(Point, 4326),
  pickup_location geography(Point, 4326)
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
BEGIN
  IF NOT (is_service_context() OR can_view_student_location(p_student_id)) THEN
    RAISE EXCEPTION 'student_location: caller may not view the location of student %', p_student_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
    SELECT s.home_address, s.home_location, s.pickup_location
      FROM student s WHERE s.id = p_student_id;
END;
$$;

COMMENT ON FUNCTION student_location(uuid) IS
  'Home address, home point and pickup point of one student, or 42501 unless '
  'can_view_student_location(). The column privileges on those three student '
  'columns are revoked from authenticated; this accessor is the only way an '
  'end user reads them.';

-- -----------------------------------------------------------------------------
-- school_earnings_paisa — the school revenue share, NULL unless allowed
-- -----------------------------------------------------------------------------
-- The skill rule "RLS hides rows, not columns": a staff member without
-- can_view_earnings may see the school's invoices (fees owed), but not what
-- the school earns from them. This aggregate returns NULL for them.
-- Gate 2 applies: only PAID invoices count, never issued or the roll count.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION school_earnings_paisa(p_school_id uuid, p_period_start date)
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN is_service_context() OR is_admin() OR can_view_school_earnings(p_school_id) THEN (
      SELECT coalesce(sum(sa.amount_paisa), 0)::bigint
        FROM split_allocation sa
        JOIN invoice_line il ON il.id = sa.invoice_line_id
        JOIN invoice i       ON i.id  = il.invoice_id
        JOIN billing_period bp ON bp.id = i.billing_period_id
       WHERE sa.beneficiary_type = 'school'
         AND sa.beneficiary_id   = p_school_id
         AND i.school_id         = p_school_id
         AND i.status            = 'paid'
         AND bp.period_start     = p_period_start)
  END;
$$;

COMMENT ON FUNCTION school_earnings_paisa(uuid, date) IS
  'Sum of the school''s split_allocation legs on PAID invoices of the billing '
  'period starting p_period_start, in paisa. NULL (not 0) when the caller is '
  'not admin and not staff of the school with can_view_earnings: 0 would be a '
  'false statement, NULL is "not yours to know".';

-- =============================================================================
-- 2. Guarded SECURITY DEFINER functions from D3 / D5
-- =============================================================================

-- -----------------------------------------------------------------------------
-- find_nearby_students — identical signature, columns and query as D3, plus
-- the guard D3 asked for: admin, or school staff for their OWN school_id.
-- plpgsql only so the guard can raise; #variable_conflict use_column keeps the
-- RETURNS TABLE names from shadowing the query's columns.
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
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
#variable_conflict use_column
BEGIN
  IF NOT (is_service_context() OR is_admin() OR is_school_staff_of(p_school_id)) THEN
    RAISE EXCEPTION 'find_nearby_students: caller may not search students of school %', p_school_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
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
END;
$$;

COMMENT ON FUNCTION find_nearby_students(uuid, double precision, double precision, double precision) IS
  'Active students of one school whose home_location lies within '
  'p_radius_meters of the given point, nearest first, with distance_meters on '
  'the spheroid (geography, metres). Returns child home addresses, so D8 '
  'guards it: EXECUTE is revoked from anon, and inside, only admin, school '
  'staff of p_school_id, or a service context may call it (else 42501).';

-- -----------------------------------------------------------------------------
-- transition_trip — now SECURITY DEFINER with an in-function role check
-- -----------------------------------------------------------------------------
-- D5 handed over: the rawaan.trip_transition GUC is forgeable, so it is not a
-- boundary by itself. D8 makes it one:
--   * UPDATE on trip.status is no longer granted to anon or authenticated
--     (section 4), so no end user can UPDATE status directly, GUC or not;
--   * this function runs as its owner, so it can still perform the UPDATE,
--     and decides itself who may move which trip:
--       - admin: any legal transition of any trip;
--       - the trip's own driver: any legal transition except 'cancelled'
--         (cancelling tells parents their child will not be collected, which
--         is an operations decision, not a driver's);
--       - service context (owner, service_role): anything legal.
--   Everyone else gets 42501. Body otherwise identical to D5.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION transition_trip(
  p_trip_id uuid,
  p_to      trip_status,
  p_reason  text DEFAULT NULL
)
RETURNS trip
LANGUAGE plpgsql
SECURITY DEFINER
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

  IF NOT (is_service_context()
          OR is_admin()
          OR (v_trip.driver_id = current_driver_id() AND p_to <> 'cancelled')) THEN
    RAISE EXCEPTION 'transition_trip: caller may not move trip % to %', p_trip_id, p_to
      USING ERRCODE = 'insufficient_privilege';
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
  'The ONLY way to change trip.status. SECURITY DEFINER since D8: UPDATE of '
  'trip.status is not granted to end users, and this function authorises the '
  'caller itself (admin: any legal move; the trip''s driver: any legal move '
  'except cancelled; service context: any legal move; else 42501). Raises '
  '23514 on an illegal move, re-checks assert_driver_assignable() when a trip '
  'starts, stamps started_at / ended_at, records p_reason.';

-- -----------------------------------------------------------------------------
-- issue_trip_qr_token / record_trip_checkin — SECURITY DEFINER plus guard
-- -----------------------------------------------------------------------------
-- The token table is now readable by admin only (its hashes are never shown
-- to a parent or a school), so both functions run as owner and check the
-- caller themselves. Bodies identical to D5 apart from the guard.
--
-- issue_trip_qr_token: the trip's driver, admin, service context, AND the
-- guardian of p_student_id. The skill's D5 hand-over lists "driver or admin"
-- only, but D5's own design is that "the guardian's app asks
-- issue_trip_qr_token() for a token ... and the driver scans it"; refusing
-- the guardian would make the boarding pass unissuable from the one screen
-- that shows it. A guardian can only mint for their own child, and the token
-- still boards nobody who is not on the trip's active manifest.
--
-- record_trip_checkin: the trip's driver, admin, service context. Never a
-- guardian: a parent must not be able to board their own child.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION issue_trip_qr_token(
  p_trip_id    uuid,
  p_student_id uuid,
  p_ttl        interval DEFAULT interval '5 minutes',
  p_issued_by  uuid DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_status trip_status;
  v_token  text;
BEGIN
  IF NOT (is_service_context()
          OR is_admin()
          OR is_guardian_of(p_student_id)
          OR EXISTS (SELECT 1 FROM trip t
                      WHERE t.id = p_trip_id AND t.driver_id = current_driver_id())) THEN
    RAISE EXCEPTION 'issue_trip_qr_token: caller may not issue a token for student % on trip %',
      p_student_id, p_trip_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

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
  'SHA-256, and returns the raw token once. Callers since D8: the guardian of '
  'the student, the trip''s driver, admin, service context (else 42501). p_ttl '
  'above 15 minutes is refused by ck_trip_qr_token_short_lived. Manifest '
  'membership is checked by record_trip_checkin(), not here.';

CREATE OR REPLACE FUNCTION record_trip_checkin(
  p_trip_id    uuid,
  p_method     checkin_method,
  p_token      text DEFAULT NULL,
  p_student_id uuid DEFAULT NULL,
  p_scanned_by uuid DEFAULT NULL
)
RETURNS checkin_result
LANGUAGE plpgsql
SECURITY DEFINER
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

  IF NOT (is_service_context() OR is_admin() OR v_trip.driver_id = current_driver_id()) THEN
    RAISE EXCEPTION 'record_trip_checkin: caller is not the driver of trip %', p_trip_id
      USING ERRCODE = 'insufficient_privilege';
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
  'Records ONE scan attempt and returns its checkin_result; every attempt is '
  'written, failures included. Callers since D8: the trip''s driver, admin, '
  'service context (else 42501). Order of checks: expired_token, wrong_trip, '
  'wrong_child, child_absent (is_student_absent()), already_checked_in, '
  'success. Raises only for malformed calls and unauthorised callers.';

-- -----------------------------------------------------------------------------
-- v_trip_stop_attendance — same columns, now limited to the trip's driver,
-- admin and service context (D6 hand-over). Under security_invoker the RLS
-- on trip / route_stop / route_manifest would otherwise also let school staff
-- and guardians see per-stop rider counts of trips they can see.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_trip_stop_attendance
WITH (security_invoker = true) AS
SELECT
  t.id           AS trip_id,
  t.trip_date,
  t.route_id,
  s.id           AS route_stop_id,
  s.stop_order,
  s.name         AS stop_name,
  count(m.id)::int AS rider_count,
  (count(m.id) FILTER (WHERE is_student_absent(m.student_id, t.trip_date)))::int AS absent_count,
  count(m.id) = count(m.id) FILTER (WHERE is_student_absent(m.student_id, t.trip_date))
                 AS is_skippable
FROM trip t
JOIN route_stop s
  ON s.route_id = t.route_id
LEFT JOIN route_manifest m
  ON m.route_stop_id = s.id AND m.route_id = s.route_id AND m.is_active
WHERE (SELECT is_service_context())
   OR (SELECT is_admin())
   OR t.driver_id = (SELECT current_driver_id())
GROUP BY t.id, t.trip_date, t.route_id, s.id, s.stop_order, s.name;

COMMENT ON VIEW v_trip_stop_attendance IS
  'Per trip, every stop on its route with rider_count (active manifest), '
  'absent_count (is_student_absent() on the trip date) and is_skippable. The '
  'driver app''s stop list: rows only for the trip''s own driver, admin and '
  'service context (D8). security_invoker = true so RLS also applies.';

-- =============================================================================
-- 3. audit_log — append-only record of privileged writes
-- =============================================================================

CREATE TABLE audit_log (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  at                 timestamptz NOT NULL DEFAULT clock_timestamp(),
  actor_app_user_id  uuid,
  actor_role         app_role,
  db_role            text        NOT NULL,
  action             text        NOT NULL,
  table_name         text        NOT NULL,
  row_id             uuid,
  before             jsonb,
  after              jsonb,
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_audit_log_has_image CHECK (before IS NOT NULL OR after IS NOT NULL)
);

COMMENT ON TABLE audit_log IS
  'Append-only record of privileged writes: payment status changes, every '
  'adjustment / payout / payout_line write, driver verification changes, '
  'driver_school approval changes, enrollment rate/status changes, app_user '
  'role changes and lead promotion. Written only by write_audit_log() (a '
  'SECURITY DEFINER trigger). Nobody holds INSERT, UPDATE or DELETE on it, and '
  'trg_audit_log_append_only raises on UPDATE / DELETE / TRUNCATE even for the '
  'owner. Admin may SELECT; nobody else. Rows are never cleaned up, including '
  'test fixtures: that is the point of the table.';
COMMENT ON COLUMN audit_log.at IS
  'clock_timestamp() of the write, so rows from one transaction keep their order.';
COMMENT ON COLUMN audit_log.actor_app_user_id IS
  'current_app_user_id() of the caller. NULL for the migration owner, '
  'service_role and other backend paths; db_role then says which. Plain uuid, '
  'no FK: an audit record must outlive the account it names.';
COMMENT ON COLUMN audit_log.actor_role IS
  'current_app_role() at the time of the write, frozen: a later role change '
  'does not restate who did what.';
COMMENT ON COLUMN audit_log.db_role IS
  'The database role the request ran as (authenticated, service_role, or the '
  'session user for the owner).';
COMMENT ON COLUMN audit_log.action IS
  'The trigger''s label (status_change, verification_status_change, '
  'approval_change, rate_or_status_change, role_change, lead_promotion) or the '
  'operation (insert / update / delete) for tables audited on every write.';
COMMENT ON COLUMN audit_log.before IS
  'Row image before the write (NULL on insert). For app_user, driver and lead '
  'only an allow-listed subset of columns is kept, so personal data that '
  'other tables purge (lead contact fields, phone numbers) does not become '
  'immortal here.';
COMMENT ON COLUMN audit_log.updated_at IS
  'Exists for assert_updated_at_convention(). Always equal to the insert time: '
  'the row can never be updated, which is also why this is the one table '
  'without a trg_<table>_updated_at trigger.';

CREATE INDEX idx_audit_log_table_name_row_id ON audit_log (table_name, row_id);
CREATE INDEX idx_audit_log_at ON audit_log (at);

CREATE OR REPLACE FUNCTION refuse_audit_log_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'trg_audit_log_append_only: audit_log is append-only (% refused)', TG_OP
    USING ERRCODE = 'check_violation';
END;
$$;

COMMENT ON FUNCTION refuse_audit_log_change() IS
  'Statement-level BEFORE UPDATE / DELETE / TRUNCATE on audit_log: always '
  'raises 23514. Statement level so even a zero-row UPDATE is refused, and so '
  'TRUNCATE (which skips row triggers and RLS) is covered too.';

CREATE TRIGGER trg_audit_log_append_only
  BEFORE UPDATE OR DELETE OR TRUNCATE ON audit_log
  FOR EACH STATEMENT EXECUTE FUNCTION refuse_audit_log_change();

-- -----------------------------------------------------------------------------
-- write_audit_log — the one generic audit trigger
-- -----------------------------------------------------------------------------
-- TG_ARGV[0]: action label ('' or absent = the operation name).
-- TG_ARGV[1]: optional comma-separated allow-list of columns kept in the
--             before/after images (privacy, see audit_log.before).
-- AFTER trigger, so it records what was actually committed by the statement,
-- after every BEFORE trigger has had its say.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION write_audit_log()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_before jsonb;
  v_after  jsonb;
  v_row_id uuid;
  v_keys   text[];
BEGIN
  IF TG_OP IN ('UPDATE', 'DELETE') THEN v_before := to_jsonb(OLD); END IF;
  IF TG_OP IN ('INSERT', 'UPDATE') THEN v_after  := to_jsonb(NEW); END IF;
  v_row_id := (coalesce(v_after, v_before) ->> 'id')::uuid;

  IF TG_NARGS > 1 THEN
    v_keys := string_to_array(TG_ARGV[1], ',');
    SELECT jsonb_object_agg(e.key, e.value) INTO v_before
      FROM jsonb_each(v_before) e WHERE e.key = ANY (v_keys);
    SELECT jsonb_object_agg(e.key, e.value) INTO v_after
      FROM jsonb_each(v_after) e WHERE e.key = ANY (v_keys);
  END IF;

  INSERT INTO audit_log (actor_app_user_id, actor_role, db_role, action,
                         table_name, row_id, before, after)
  VALUES (current_app_user_id(),
          current_app_role(),
          coalesce(nullif(current_setting('role', true), 'none'), session_user::text),
          CASE WHEN TG_NARGS > 0 AND TG_ARGV[0] <> '' THEN TG_ARGV[0] ELSE lower(TG_OP) END,
          TG_TABLE_NAME,
          v_row_id,
          v_before,
          v_after);

  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION write_audit_log() IS
  'Generic AFTER ROW trigger: appends one audit_log row with actor, action, '
  'table, row id and before/after jsonb. SECURITY DEFINER so it can insert '
  'into audit_log, which no caller role may write.';

-- payment: status changes (submitted -> confirmed / rejected / refunded ...).
CREATE TRIGGER trg_payment_audit
  AFTER UPDATE OF status ON payment
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION write_audit_log('status_change');

-- adjustment, payout, payout_line: every write. These are money moving.
CREATE TRIGGER trg_adjustment_audit
  AFTER INSERT OR UPDATE OR DELETE ON adjustment
  FOR EACH ROW EXECUTE FUNCTION write_audit_log();

CREATE TRIGGER trg_payout_audit
  AFTER INSERT OR UPDATE OR DELETE ON payout
  FOR EACH ROW EXECUTE FUNCTION write_audit_log();

CREATE TRIGGER trg_payout_line_audit
  AFTER INSERT OR UPDATE OR DELETE ON payout_line
  FOR EACH ROW EXECUTE FUNCTION write_audit_log();

-- driver: verification decisions. Phone and CNIC digits are not copied.
CREATE TRIGGER trg_driver_audit
  AFTER UPDATE OF verification_status ON driver
  FOR EACH ROW WHEN (OLD.verification_status IS DISTINCT FROM NEW.verification_status)
  EXECUTE FUNCTION write_audit_log('verification_status_change',
    'id,app_user_id,verification_status,status_reason,rejection_reason,reviewed_by,reviewed_at,suspended_at,suspended_reason');

-- driver_school: a new link, and any change to whether it is approved/active.
CREATE TRIGGER trg_driver_school_audit_insert
  AFTER INSERT ON driver_school
  FOR EACH ROW EXECUTE FUNCTION write_audit_log('approval_change');

CREATE TRIGGER trg_driver_school_audit_update
  AFTER UPDATE OF approved_at, approved_by, is_active, ended_at ON driver_school
  FOR EACH ROW WHEN (OLD.approved_at IS DISTINCT FROM NEW.approved_at
                  OR OLD.approved_by IS DISTINCT FROM NEW.approved_by
                  OR OLD.is_active   IS DISTINCT FROM NEW.is_active
                  OR OLD.ended_at    IS DISTINCT FROM NEW.ended_at)
  EXECUTE FUNCTION write_audit_log('approval_change');

-- enrollment: the billing input (fee and split) and the billing gate (status).
CREATE TRIGGER trg_enrollment_audit
  AFTER UPDATE OF fee_paisa, driver_bps, school_bps, rawaan_bps, status ON enrollment
  FOR EACH ROW WHEN (OLD.fee_paisa  IS DISTINCT FROM NEW.fee_paisa
                  OR OLD.driver_bps IS DISTINCT FROM NEW.driver_bps
                  OR OLD.school_bps IS DISTINCT FROM NEW.school_bps
                  OR OLD.rawaan_bps IS DISTINCT FROM NEW.rawaan_bps
                  OR OLD.status     IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION write_audit_log('rate_or_status_change');

-- app_user: role changes (privilege changes). Name and phone are not copied.
CREATE TRIGGER trg_app_user_audit
  AFTER UPDATE OF role ON app_user
  FOR EACH ROW WHEN (OLD.role IS DISTINCT FROM NEW.role)
  EXECUTE FUNCTION write_audit_log('role_change', 'id,role,is_active');

-- lead: promotion (-> converted). Contact fields are not copied: lead PII is
-- purged after 12 months (D7) and must not survive here.
CREATE TRIGGER trg_lead_audit
  AFTER UPDATE OF status ON lead
  FOR EACH ROW WHEN (NEW.status = 'converted' AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION write_audit_log('lead_promotion', 'id,source,status,app_user_id,converted_at');

-- =============================================================================
-- 3b. The D4 known limitation: role changes that would orphan role rows
-- =============================================================================
-- D4's role trigger fires on driver, not on app_user, so an app_user could be
-- moved from 'driver' to 'parent' while their driver row stayed active, and
-- every driver policy (current_driver_id()) would keep treating them as a
-- driver. Same hole for 'school' (school_admin rows keep granting school
-- visibility) and 'parent' (guardian rows keep granting a child's location).
-- The change must happen in the right order: end the dependent rows first.
--
-- Business consequence, worth knowing: one account cannot be both a parent
-- (with guardian rows) and a driver. promote_lead_to_role() on an applicant
-- who is already a guardian is refused; such a person needs two accounts.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION enforce_app_user_role_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.role IS NOT DISTINCT FROM OLD.role THEN
    RETURN NEW;
  END IF;

  IF OLD.role = 'driver'
     AND EXISTS (SELECT 1 FROM driver d WHERE d.app_user_id = OLD.id AND d.is_active) THEN
    RAISE EXCEPTION
      'trg_app_user_role_change_guard: app_user % has an active driver row; deactivate it before changing role driver -> %',
      OLD.id, NEW.role
      USING ERRCODE = 'check_violation';
  END IF;

  IF OLD.role = 'school'
     AND EXISTS (SELECT 1 FROM school_admin sa WHERE sa.app_user_id = OLD.id) THEN
    RAISE EXCEPTION
      'trg_app_user_role_change_guard: app_user % still has school_admin rows; remove them before changing role school -> %',
      OLD.id, NEW.role
      USING ERRCODE = 'check_violation';
  END IF;

  IF OLD.role = 'parent'
     AND EXISTS (SELECT 1 FROM guardian g WHERE g.app_user_id = OLD.id) THEN
    RAISE EXCEPTION
      'trg_app_user_role_change_guard: app_user % still has guardian rows; remove them before changing role parent -> %',
      OLD.id, NEW.role
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION enforce_app_user_role_change() IS
  'BEFORE UPDATE OF role guard on app_user (23514): refuses leaving driver '
  'while an active driver row exists, school while school_admin rows exist, '
  'parent while guardian rows exist. Closes the D4 known limitation.';

CREATE TRIGGER trg_app_user_role_change_guard
  BEFORE UPDATE OF role ON app_user
  FOR EACH ROW EXECUTE FUNCTION enforce_app_user_role_change();

-- =============================================================================
-- 4. ENABLE RLS everywhere, admin policy everywhere, grant hygiene
-- =============================================================================
-- One loop over every ordinary table in this schema, so a table added before
-- D8 cannot be missed. audit_log gets its own SELECT-only admin policy below.
--
-- Grants, applied to every table and view:
--   * anon: ALL revoked. Re-granted: INSERT on lead (selected columns).
--   * authenticated: TRUNCATE, REFERENCES and TRIGGER revoked. TRUNCATE in
--     particular ignores RLS entirely and must never reach an end user.
--     On views: everything but SELECT revoked.
-- =============================================================================

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT c.relname, c.relkind
      FROM pg_class c
     WHERE c.relnamespace = current_schema()::regnamespace
       AND c.relkind IN ('r', 'p', 'v', 'm')
       AND NOT EXISTS (SELECT 1 FROM pg_depend dep
                        WHERE dep.objid = c.oid AND dep.deptype = 'e')
     ORDER BY c.relname
  LOOP
    EXECUTE format('REVOKE ALL ON TABLE %I FROM anon', r.relname);

    IF r.relkind IN ('r', 'p') THEN
      EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', r.relname);
      EXECUTE format('REVOKE TRUNCATE, REFERENCES, TRIGGER ON TABLE %I FROM authenticated', r.relname);
      IF r.relname <> 'audit_log' THEN
        EXECUTE format(
          'CREATE POLICY %I ON %I FOR ALL TO authenticated '
          'USING ((select is_admin())) WITH CHECK ((select is_admin()))',
          r.relname || '_admin_all', r.relname);
      END IF;
    ELSE
      EXECUTE format('REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE %I FROM authenticated', r.relname);
    END IF;
  END LOOP;
END
$$;

-- -----------------------------------------------------------------------------
-- Column and write privileges that RLS cannot express
-- -----------------------------------------------------------------------------

-- audit_log: SELECT only, and only admin through the policy. No INSERT,
-- UPDATE or DELETE for any API role; write_audit_log() writes as owner.
REVOKE ALL ON TABLE audit_log FROM authenticated;
GRANT SELECT ON TABLE audit_log TO authenticated;

-- student: the three location columns are not selectable by end users at all
-- (RLS hides rows, not columns). They are read through student_location().
-- Consequence for clients: `SELECT * FROM student` is refused; list columns.
REVOKE SELECT ON TABLE student FROM authenticated;
GRANT SELECT (id, full_name, date_of_birth, school_id, grade, section,
              emergency_contact_name, emergency_contact_phone, is_active,
              created_at, updated_at)
  ON TABLE student TO authenticated;

-- trip: status is not writable by any end user; transition_trip() (definer)
-- is the only path. The table-level UPDATE has to go, because a column-level
-- REVOKE does nothing while a table-level grant exists.
REVOKE UPDATE ON TABLE trip FROM authenticated;
GRANT UPDATE (driver_id, vehicle_id, trip_date, status_reason) ON TABLE trip TO authenticated;

-- trip_qr_token / trip_checkin: written only by issue_trip_qr_token() and
-- record_trip_checkin() (definers). "Every scan attempt is recorded" must not
-- be editable after the fact by anyone holding an API key.
REVOKE INSERT, UPDATE, DELETE ON TABLE trip_qr_token FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON TABLE trip_checkin FROM authenticated;

-- app_user: no end-user INSERT (the B2 auth flow provisions profiles on the
-- server, as service_role) and no UPDATE of role by anyone through the API:
-- a self-service role change is privilege escalation. Role changes go through
-- promote_lead_to_role() or service_role.
REVOKE INSERT, UPDATE, DELETE ON TABLE app_user FROM authenticated;
GRANT UPDATE (full_name, phone, preferred_locale, is_active, consent_given_at, consent_version)
  ON TABLE app_user TO authenticated;

-- absence: cancelling is a status change, never a DELETE (D6).
REVOKE DELETE ON TABLE absence FROM authenticated;

-- lead: the one thing anon may do. Only the columns a public form fills;
-- status, app_user_id, assigned_to and the lifecycle stamps are not granted,
-- and the lead_public_insert policy re-checks them anyway.
GRANT INSERT (source, contact_name, phone, email, preferred_locale, message,
              school_id, consent_at, consent_version)
  ON TABLE lead TO anon;

-- =============================================================================
-- 5. Policies per table (besides <table>_admin_all)
-- =============================================================================
-- Read the policy name as <table>_<who>_<what>. Anything not listed for a role
-- is denied by default.
-- -----------------------------------------------------------------------------

-- app_user: yourself.
CREATE POLICY app_user_self_select ON app_user FOR SELECT TO authenticated
  USING (id = (select current_app_user_id()));
CREATE POLICY app_user_self_update ON app_user FOR UPDATE TO authenticated
  USING (id = (select current_app_user_id()))
  WITH CHECK (id = (select current_app_user_id()));

-- school: staff of it, guardians of its children, drivers serving it.
CREATE POLICY school_member_select ON school FOR SELECT TO authenticated
  USING ((select is_school_staff_of(id))
      OR (select is_guardian_at_school(id))
      OR (select is_driver_at_school(id)));

-- school_admin: your own staff rows.
CREATE POLICY school_admin_self_select ON school_admin FOR SELECT TO authenticated
  USING (app_user_id = (select current_app_user_id()));

-- student: guardian / assigned driver (via the location gate) and the
-- school's staff. Staff may add and edit their own school's roll; they can
-- never move a child into another school's roll (WITH CHECK).
CREATE POLICY student_viewer_select ON student FOR SELECT TO authenticated
  USING ((select can_view_student_location(id)) OR (select is_school_staff_of(school_id)));
CREATE POLICY student_staff_insert ON student FOR INSERT TO authenticated
  WITH CHECK ((select is_school_staff_of(school_id)));
CREATE POLICY student_staff_update ON student FOR UPDATE TO authenticated
  USING ((select is_school_staff_of(school_id)))
  WITH CHECK ((select is_school_staff_of(school_id)));

-- guardian: your own rows and your children's other guardians. Writes are
-- admin only: a parent able to edit guardian.student_id could make
-- themselves the guardian of any child.
CREATE POLICY guardian_family_select ON guardian FOR SELECT TO authenticated
  USING (app_user_id = (select current_app_user_id()) OR (select is_guardian_of(student_id)));

-- enrollment: the child's guardians and the school's staff. Writes admin only
-- (it carries the frozen commercial terms).
CREATE POLICY enrollment_viewer_select ON enrollment FOR SELECT TO authenticated
  USING ((select is_guardian_of(student_id)) OR (select is_school_staff_of(school_id)));

-- rate_snapshot: earnings-entitled staff of the school. Writes admin only.
CREATE POLICY rate_snapshot_earnings_select ON rate_snapshot FOR SELECT TO authenticated
  USING ((select can_view_school_earnings(school_id)));

-- billing_period: the school's staff.
CREATE POLICY billing_period_staff_select ON billing_period FOR SELECT TO authenticated
  USING ((select is_school_staff_of(school_id)));

-- invoice: the billed guardian and the school's staff (all staff: an invoice
-- is what a family owes, not what the school earns).
CREATE POLICY invoice_viewer_select ON invoice FOR SELECT TO authenticated
  USING ((select is_own_guardian_row(guardian_id)) OR (select is_school_staff_of(school_id)));

-- invoice_line: whoever can see the invoice (nested RLS on invoice).
CREATE POLICY invoice_line_viewer_select ON invoice_line FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM invoice i WHERE i.id = invoice_line.invoice_id));

-- split_allocation: earnings. A driver their own legs; a school its legs only
-- with can_view_earnings. Parents see the invoice lines, not the split.
CREATE POLICY split_allocation_beneficiary_select ON split_allocation FOR SELECT TO authenticated
  USING ((beneficiary_type = 'driver' AND beneficiary_id = (select current_driver_id()))
      OR (beneficiary_type = 'school' AND (select can_view_school_earnings(beneficiary_id))));

-- payment: the billed guardian sees theirs, and may INSERT one only as
-- 'submitted', in their own name, against their own invoice, with nothing
-- confirmed. No UPDATE policy: a parent cannot confirm, reject or edit.
CREATE POLICY payment_guardian_select ON payment FOR SELECT TO authenticated
  USING ((select is_own_guardian_row(guardian_id)));
CREATE POLICY payment_guardian_insert ON payment FOR INSERT TO authenticated
  WITH CHECK (
        status = 'submitted'
    AND confirmed_by IS NULL
    AND confirmed_at IS NULL
    AND rejection_reason IS NULL
    AND submitted_by = (select current_app_user_id())
    AND (select is_own_guardian_row(guardian_id, true))
    AND EXISTS (SELECT 1 FROM invoice i
                 WHERE i.id = payment.invoice_id AND i.guardian_id = payment.guardian_id));

-- payout / payout_line: same beneficiary rule as split_allocation. Writes
-- admin only, including the DELETE that releases a failed payout's lines (D5).
CREATE POLICY payout_beneficiary_select ON payout FOR SELECT TO authenticated
  USING ((beneficiary_type = 'driver' AND beneficiary_id = (select current_driver_id()))
      OR (beneficiary_type = 'school' AND (select can_view_school_earnings(beneficiary_id))));
CREATE POLICY payout_line_beneficiary_select ON payout_line FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM payout p WHERE p.id = payout_line.payout_id));

-- adjustment: admin only (no extra policy). The driver sees the net effect in
-- driver_earning.adjustment_paisa.

-- driver: yourself, and the staff of any school you are linked to (pending
-- links included, so a school can approve you). This is the "what schools
-- need" substitute for driver_document. Writes admin only: a driver able to
-- UPDATE their own row could set verification_status = 'approved'.
CREATE POLICY driver_viewer_select ON driver FOR SELECT TO authenticated
  USING (app_user_id = (select current_app_user_id()) OR (select is_driver_linked_to_my_school(id)));

-- vehicle: the owning driver and the linked schools' staff. Writes admin only
-- (is_vehicle_verified must not be self-set).
CREATE POLICY vehicle_viewer_select ON vehicle FOR SELECT TO authenticated
  USING (driver_id = (select current_driver_id()) OR (select is_driver_linked_to_my_school(driver_id)));

-- driver_document: THE DRIVER AND ADMIN, NOBODY ELSE. No policy at all for a
-- parent or a school, not even for metadata. The driver may upload (INSERT)
-- their own documents, only as pending_review, unreviewed, and only against a
-- vehicle of their own. Review (UPDATE) and removal are admin only.
CREATE POLICY driver_document_owner_select ON driver_document FOR SELECT TO authenticated
  USING (driver_id = (select current_driver_id()));
CREATE POLICY driver_document_owner_insert ON driver_document FOR INSERT TO authenticated
  WITH CHECK (
        driver_id = (select current_driver_id())
    AND status = 'pending_review'
    AND reviewed_by IS NULL
    AND reviewed_at IS NULL
    AND (vehicle_id IS NULL OR EXISTS (SELECT 1 FROM vehicle v
                                        WHERE v.id = driver_document.vehicle_id
                                          AND v.driver_id = driver_document.driver_id)));

-- required_document: the checklist is not sensitive; every signed-in user.
CREATE POLICY required_document_read ON required_document FOR SELECT TO authenticated
  USING (true);

-- driver_school: the driver, the school's staff. Staff with
-- can_approve_drivers may create and update their own school's rows, and only
-- in their own name (approved_by). enforce_driver_school_driver_approved()
-- still refuses approving an unverified driver.
CREATE POLICY driver_school_viewer_select ON driver_school FOR SELECT TO authenticated
  USING (driver_id = (select current_driver_id()) OR (select is_school_staff_of(school_id)));
CREATE POLICY driver_school_approver_insert ON driver_school FOR INSERT TO authenticated
  WITH CHECK ((select can_approve_drivers_for(school_id))
          AND (approved_by IS NULL OR approved_by = (select current_app_user_id())));
CREATE POLICY driver_school_approver_update ON driver_school FOR UPDATE TO authenticated
  USING ((select can_approve_drivers_for(school_id)))
  WITH CHECK ((select can_approve_drivers_for(school_id))
          AND (approved_by IS NULL OR approved_by = (select current_app_user_id())));

-- driver_earning: the driver. Not the school (it is the driver's money).
CREATE POLICY driver_earning_owner_select ON driver_earning FOR SELECT TO authenticated
  USING (driver_id = (select current_driver_id()));

-- route: its driver, the school's staff, and guardians of a child on its
-- manifest (nested RLS on route_manifest, i.e. the location gate).
CREATE POLICY route_viewer_select ON route FOR SELECT TO authenticated
  USING (driver_id = (select current_driver_id())
      OR (select is_school_staff_of(school_id))
      OR EXISTS (SELECT 1 FROM route_manifest m WHERE m.route_id = route.id));

-- route_stop: child-adjacent location. The route's driver, and anyone who may
-- see a manifested child's location at that stop (nested RLS on
-- route_manifest). School staff are not included, by the location rule.
CREATE POLICY route_stop_viewer_select ON route_stop FOR SELECT TO authenticated
  USING ((select is_driver_of_route(route_id))
      OR EXISTS (SELECT 1 FROM route_manifest m WHERE m.route_stop_id = route_stop.id));

-- route_manifest: through can_view_student_location(). A driver additionally
-- only for their own route, so a child on two routes is not revealed to the
-- other route's driver by this row.
CREATE POLICY route_manifest_viewer_select ON route_manifest FOR SELECT TO authenticated
  USING ((select can_view_student_location(student_id))
     AND ((select current_driver_id()) IS NULL OR (select is_driver_of_route(route_id))));

-- trip: its driver (substitutes included) and whoever can see its route.
-- Writes: admin (non-status columns); status only via transition_trip().
CREATE POLICY trip_viewer_select ON trip FOR SELECT TO authenticated
  USING (driver_id = (select current_driver_id())
      OR EXISTS (SELECT 1 FROM route r WHERE r.id = trip.route_id));

-- trip_qr_token: admin only (no extra policy). Hashes are never shown to a
-- parent, a school or a driver; the functions read them as owner.

-- trip_checkin: the child's guardians and the trip's driver.
CREATE POLICY trip_checkin_viewer_select ON trip_checkin FOR SELECT TO authenticated
  USING ((select is_guardian_of(student_id))
      OR EXISTS (SELECT 1 FROM trip t
                  WHERE t.id = trip_checkin.trip_id AND t.driver_id = (select current_driver_id())));

-- absence: the child's guardians (read, submit, cancel) and the school's
-- staff (read). Drivers have NO policy: the guardian's free-text reason is not
-- theirs; they get is_student_absent() and v_trip_stop_attendance instead.
-- trg_absence_rules still enforces the legal status moves and immutability.
CREATE POLICY absence_viewer_select ON absence FOR SELECT TO authenticated
  USING ((select is_guardian_of(student_id))
      OR EXISTS (SELECT 1 FROM student s
                  WHERE s.id = absence.student_id AND (select is_school_staff_of(s.school_id))));
CREATE POLICY absence_guardian_insert ON absence FOR INSERT TO authenticated
  WITH CHECK ((select is_own_guardian_row(guardian_id)) AND (select is_guardian_of(student_id)));
CREATE POLICY absence_guardian_update ON absence FOR UPDATE TO authenticated
  USING ((select is_own_guardian_row(guardian_id)))
  WITH CHECK ((select is_own_guardian_row(guardian_id)));

-- notification: the recipient's own rows. Delivery status is the worker's
-- (service_role) business.
CREATE POLICY notification_recipient_select ON notification FOR SELECT TO authenticated
  USING (recipient_app_user_id = (select current_app_user_id()));

-- lead: admin only, plus the public site forms. anon AND authenticated may
-- INSERT a brand-new lead (a signed-in parent can still use the contact
-- form), but only as status 'new', unlinked to any account, unassigned and
-- with no lifecycle stamps. Linking a lead to an app_user is the B2 flow's
-- job (service_role). Nobody but admin reads a lead back.
CREATE POLICY lead_public_insert ON lead FOR INSERT TO anon, authenticated
  WITH CHECK (status = 'new'
          AND app_user_id IS NULL
          AND assigned_to IS NULL
          AND contacted_at IS NULL
          AND converted_at IS NULL
          AND closed_at IS NULL);

-- audit_log: admin may read. Nobody may write (no grant), nobody may change
-- (no grant, plus trg_audit_log_append_only).
CREATE POLICY audit_log_admin_select ON audit_log FOR SELECT TO authenticated
  USING ((select is_admin()));

-- =============================================================================
-- 6. Function EXECUTE hygiene
-- =============================================================================
-- Supabase grants EXECUTE on every function to anon and authenticated, and
-- Postgres grants it to PUBLIC. Revoke all three from EVERY function in the
-- schema, then grant back exactly what an end user needs. service_role and
-- the owner keep EXECUTE (backend paths). Trigger functions need no EXECUTE
-- at fire time, so they stay revoked.
-- -----------------------------------------------------------------------------

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p
     WHERE p.pronamespace = current_schema()::regnamespace
       AND p.prokind = 'f'
       AND NOT EXISTS (SELECT 1 FROM pg_depend dep
                        WHERE dep.objid = p.oid AND dep.deptype = 'e')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', r.sig);
  END LOOP;
END
$$;

-- Identity helpers. anon keeps them deliberately: they answer NULL / NULL /
-- false for an anonymous caller and reveal nothing (d1 test 6 relies on it).
GRANT EXECUTE ON FUNCTION current_app_user_id() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION current_app_role()    TO anon, authenticated;
GRANT EXECUTE ON FUNCTION is_admin()            TO anon, authenticated;

-- Policy helpers: called by the policies as the caller, so authenticated
-- must hold EXECUTE. Each returns one boolean about the caller.
GRANT EXECUTE ON FUNCTION is_service_context()                  TO authenticated;
GRANT EXECUTE ON FUNCTION current_driver_id()                   TO authenticated;
GRANT EXECUTE ON FUNCTION is_guardian_of(uuid)                  TO authenticated;
GRANT EXECUTE ON FUNCTION is_own_guardian_row(uuid, boolean)    TO authenticated;
GRANT EXECUTE ON FUNCTION is_school_staff_of(uuid)              TO authenticated;
GRANT EXECUTE ON FUNCTION can_view_school_earnings(uuid)        TO authenticated;
GRANT EXECUTE ON FUNCTION can_approve_drivers_for(uuid)         TO authenticated;
GRANT EXECUTE ON FUNCTION is_guardian_at_school(uuid)           TO authenticated;
GRANT EXECUTE ON FUNCTION is_driver_at_school(uuid)             TO authenticated;
GRANT EXECUTE ON FUNCTION is_driver_of_route(uuid)              TO authenticated;
GRANT EXECUTE ON FUNCTION is_driver_linked_to_my_school(uuid)   TO authenticated;
GRANT EXECUTE ON FUNCTION can_view_student_location(uuid)       TO authenticated;

-- Guarded end-user entry points (each checks the caller inside).
GRANT EXECUTE ON FUNCTION student_location(uuid)                TO authenticated;
GRANT EXECUTE ON FUNCTION school_earnings_paisa(uuid, date)     TO authenticated;
GRANT EXECUTE ON FUNCTION find_nearby_students(uuid, double precision, double precision, double precision)
  TO authenticated;
GRANT EXECUTE ON FUNCTION transition_trip(uuid, trip_status, text) TO authenticated;
GRANT EXECUTE ON FUNCTION issue_trip_qr_token(uuid, uuid, interval, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION record_trip_checkin(uuid, checkin_method, text, uuid, uuid) TO authenticated;
-- D7: revoked from PUBLIC and anon; authenticated keeps it so a non-admin gets
-- the function's own "admin only" 42501 rather than a bare permission error.
GRANT EXECUTE ON FUNCTION promote_lead_to_role(uuid, app_role)  TO authenticated;

-- Pure or caller-safe functions.
--   allocate_split: pure arithmetic (split preview in the apps).
--   trip_transition_is_legal: pure; the driver app uses it to pick buttons.
--   is_student_absent: SECURITY DEFINER boolean; v_trip_stop_attendance runs
--   as the driver and needs it. ponytail: any signed-in user who knows a
--   student uuid can learn whether that child is absent on a date; add a
--   caller check if that boolean is ever judged sensitive.
GRANT EXECUTE ON FUNCTION allocate_split(bigint, int, int)           TO authenticated;
GRANT EXECUTE ON FUNCTION trip_transition_is_legal(trip_status, trip_status) TO authenticated;
GRANT EXECUTE ON FUNCTION is_student_absent(uuid, date)              TO authenticated;

-- Deliberately NOT granted to any API role (internal or trigger-only):
--   is_billable (billing engine, service_role), assert_app_user_role,
--   assert_driver_assignable, assert_updated_at_convention, set_updated_at,
--   every guard/enforce_* trigger function, enqueue_absence_notification,
--   set_/sync_payout_line_beneficiary_type, write_audit_log,
--   refuse_audit_log_change, enforce_app_user_role_change.

-- =============================================================================
-- Deliberately NOT in this file
-- =============================================================================
--   * FORCE ROW LEVEL SECURITY. The owner and service_role are the backend.
--   * Parent self-service writes on student / guardian / app_user (adding a
--     child, recording consent, signing up). Each would let a client write a
--     row that grants access (a guardian row IS access), so they belong in
--     B-series SECURITY DEFINER RPCs that validate the whole step, not in a
--     table policy.
--   * Parent read of their child's driver and vehicle. Useful, but the driver
--     row carries review notes and phone; it wants a narrow definer accessor
--     in B-series, not a policy on driver.
--   * driver_verification_summary for schools counts documents through
--     driver_document, which schools cannot read, so its *_count columns read
--     0 for them. They must rely on verification_status, which is correct.
--   * Driver / school acknowledgement of an absence (absence.acknowledged_*):
--     drivers cannot read the table; acknowledgement wants a definer RPC.
-- =============================================================================
