-- =============================================================================
-- D3 test — schools, students, guardians, enrollments
-- =============================================================================
-- Executable assertions for 20261006000003_d3_people_enrollment.sql.
-- Plain SQL, no test framework, no docker. Run with:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/d3_enrollment.test.sql
--
-- STYLE
--   Every assertion is ATTEMPTED. Each "this must fail" case runs inside its
--   own nested BEGIN ... EXCEPTION block, which is a savepoint: the failure is
--   caught, the failed statement is rolled back, and the run continues.
--   Failures accumulate in a counter and are reported together in ONE
--   exception at the end, so a single run shows every problem instead of
--   stopping at the first one.
--
--   When an insert that should have failed unexpectedly succeeds, the row is
--   deleted again before the failure is counted. Nothing this file creates
--   survives it, so a failure never leaves the database in a state that
--   makes the NEXT run behave differently.
--
--   Negative cases assert on WHICH constraint refused the row, by checking the
--   constraint name inside SQLERRM. A test that only checks "something broke"
--   passes for the wrong reason the first time an unrelated constraint fires.
--
-- DEPENDENCY ORDER
--   auth.users  ->  app_user (D1)  ->  school  ->  school_admin, student,
--   guardian  ->  enrollment. auth.users is seeded HERE, not assumed: a freshly
--   migrated database has no auth users at all, and app_user.id references
--   auth.users(id).
--
-- RE-RUNNABLE
--   Every fixture is namespaced with a random() suffix, so running this file
--   twice, or two copies of it concurrently, cannot collide.
-- =============================================================================

SET search_path TO public, extensions;

DO $test$
DECLARE
  -- Fixture identity -------------------------------------------------------
  v_suffix      text;
  v_role        app_role;
  v_name        text;
  v_auth_id     uuid;
  v_auth_ids    uuid[] := '{}';
  v_parents     uuid[] := '{}';
  v_school_user uuid;
  v_admin_user  uuid;

  v_school      uuid;
  v_s1          uuid;   -- subject of the guardian and enrollment assertions
  v_s2          uuid;   -- subject of the no-route enrollment
  v_s3          uuid;   -- subject of the enrollment constraint assertions
  v_s_near      uuid;   -- PostGIS, about 2 km from the probe point
  v_s_far       uuid;   -- PostGIS, about 10 km from the probe point
  v_students    uuid[] := '{}';

  v_g1          uuid;   -- primary guardian of v_s1
  v_g2          uuid;   -- non-primary guardian of v_s1
  v_g3          uuid;   -- non-primary guardian of v_s1
  v_g4          uuid;   -- non-primary guardian of v_s2, used to probe a
                         -- second primary on v_s1 without colliding on the
                         -- (app_user_id, student_id) unique constraint
  v_g5          uuid;   -- guardian of v_s2
  v_g6          uuid;   -- guardian of v_s3
  v_guardians   uuid[] := '{}';

  -- Sentinel route. `route` arrives in D5, so route_id has no FK yet and the
  -- value cannot be validated against it. Any uuid will do: what is_billable
  -- tests is route_id IS NOT NULL.
  v_route       uuid := gen_random_uuid();

  v_e_active    uuid;   -- v_s1, active, on a route, 2026 full year
  v_e_paused    uuid;
  v_e_ended     uuid;
  v_e_noroute   uuid;   -- v_s2, active, NO route: attends school, rides nothing
  v_e_s3        uuid;   -- v_s3, active. Baseline for assertions 7 and 8
  v_e_reject    uuid;
  v_enrollments uuid[] := '{}';

  -- Frozen commercial terms. Rs. 4,000 baseline = 400000 paisa, standard
  -- split 80/10/10. See MASTER_CONTEXT.md section 3.
  v_fee_paisa     bigint := 400000;
  v_driver_bps    int    := 8000;
  v_school_bps    int    := 1000;
  v_rawaan_bps    int    := 1000;

  -- Scratch ----------------------------------------------------------------
  v_id           uuid;   -- throwaway id for a row that should not have survived
  v_ok           boolean;
  v_count        int;
  v_dist         double precision;
  v_far_count    int;
  v_far_dist     double precision;
  v_fee          bigint;
  v_dbps         int;
  v_sbps         int;
  v_rbps         int;
  v_postgis      boolean;
  v_billable     boolean;

  v_failures     int := 0;
  v_msg          text := '';
BEGIN
  -- ---------------------------------------------------------------------------
  -- 0. Preconditions
  -- ---------------------------------------------------------------------------

  IF to_regclass('app_user') IS NULL THEN
    RAISE NOTICE
      'D3 test SKIPPED: relation "app_user" does not exist. Apply D1 first.';
    RETURN;
  END IF;

  IF to_regclass('school') IS NULL
     OR to_regclass('school_admin') IS NULL
     OR to_regclass('student') IS NULL
     OR to_regclass('guardian') IS NULL
     OR to_regclass('enrollment') IS NULL THEN
    RAISE NOTICE
      'D3 test SKIPPED: the D3 tables are missing. Apply 20261006000003 first.';
    RETURN;
  END IF;

  IF to_regprocedure('is_billable(uuid, date, date)') IS NULL
     OR to_regclass('v_billable_enrollment') IS NULL THEN
    RAISE NOTICE
      'D3 test SKIPPED: is_billable() or v_billable_enrollment is missing. '
      'Apply 20261006000003 in full.';
    RETURN;
  END IF;

  v_suffix := replace(substr(random()::text, 3), '.', '');

  -- ---------------------------------------------------------------------------
  -- Fixtures: auth.users, then app_user, then school, then people.
  --
  -- Four parents. A second is_primary probe needs a parent who is NOT already
  -- linked to v_s1, otherwise the (app_user_id, student_id) unique constraint
  -- fires first and the probe proves nothing about is_primary.
  -- ---------------------------------------------------------------------------

  FOR v_role, v_name IN
    SELECT t.v_role, t.v_name
    FROM (VALUES
      ('parent'::app_role, 'Nasreen Bibi'),
      ('parent'::app_role, 'Faisal Khan'),
      ('parent'::app_role, 'Shakeela Begum'),
      ('parent'::app_role, 'Zahid Iqbal'),
      ('school'::app_role, 'Principal Sadia Yousafzai'),
      ('admin'::app_role, 'Rawaan Operations')
    ) AS t(v_role, v_name)
  LOOP
    v_auth_id := gen_random_uuid();

    INSERT INTO auth.users (
      id, aud, role, email, encrypted_password, email_confirmed_at,
      created_at, updated_at, raw_app_meta_data, raw_user_meta_data
    )
    VALUES (
      v_auth_id, 'authenticated', 'authenticated',
      format('%s@%s.example', lower(replace(v_name, ' ', '.')), v_suffix),
      crypt('d3-test-not-a-real-password', gen_salt('bf')),
      now(), now(), now(), '{}'::jsonb, '{}'::jsonb
    );

    INSERT INTO app_user (id, role, full_name, phone)
    VALUES (
      v_auth_id, v_role, v_name,
      '+9230' || lpad(((900000 + (random() * 99999))::int)::text, 7, '0')
    );

    v_auth_ids := v_auth_ids || v_auth_id;
  END LOOP;

  SELECT array_agg(id ORDER BY full_name) INTO v_parents
    FROM app_user WHERE id = ANY (v_auth_ids) AND role = 'parent';

  SELECT id INTO v_school_user
    FROM app_user WHERE id = ANY (v_auth_ids) AND role = 'school';

  SELECT id INTO v_admin_user
    FROM app_user WHERE id = ANY (v_auth_ids) AND role = 'admin';

  INSERT INTO school (name, slug, address, city, contact_email, contact_phone, gate_count)
  VALUES (
    'D3 Test School ' || v_suffix,
    'd3-test-' || v_suffix,
    'University Road, Peshawar',
    'Peshawar',
    format('office@%s.example', v_suffix),
    '+923015555555',
    2
  )
  RETURNING id INTO v_school;

  INSERT INTO student (full_name, date_of_birth, school_id, grade, section, home_address)
  VALUES ('Ayesha Khan', '2014-04-09', v_school, 'Grade 5', 'B', 'D3 test address, Hayatabad')
  RETURNING id INTO v_s1;

  INSERT INTO student (full_name, date_of_birth, school_id, grade)
  VALUES ('Bilal Khan', '2013-11-22', v_school, 'Grade 7')
  RETURNING id INTO v_s2;

  INSERT INTO student (full_name, date_of_birth, school_id, grade)
  VALUES ('Hira Khan', '2015-02-14', v_school, 'Grade 4')
  RETURNING id INTO v_s3;

  v_students := ARRAY[v_s1, v_s2, v_s3];

  -- One primary guardian on v_s1, two non-primary, one guardian elsewhere.
  INSERT INTO guardian (app_user_id, student_id, relationship, is_primary,
                        can_manage_payments, consent_at, consent_version)
  VALUES (v_parents[1], v_s1, 'mother', true, true, now(), '2026-01-consent-v3')
  RETURNING id INTO v_g1;

  INSERT INTO guardian (app_user_id, student_id, relationship, is_primary,
                        can_manage_payments, consent_at, consent_version)
  VALUES (v_parents[2], v_s1, 'father', false, false, now(), '2026-01-consent-v3')
  RETURNING id INTO v_g2;

  INSERT INTO guardian (app_user_id, student_id, relationship, is_primary, consent_at, consent_version)
  VALUES (v_parents[3], v_s1, 'guardian', false, now(), '2026-01-consent-v3')
  RETURNING id INTO v_g3;

  INSERT INTO guardian (app_user_id, student_id, relationship, is_primary)
  VALUES (v_parents[4], v_s2, 'other', false)
  RETURNING id INTO v_g4;

  INSERT INTO guardian (app_user_id, student_id, relationship, is_primary)
  VALUES (v_parents[1], v_s2, 'mother', true)
  RETURNING id INTO v_g5;

  INSERT INTO guardian (app_user_id, student_id, relationship, is_primary)
  VALUES (v_parents[3], v_s3, 'mother', true)
  RETURNING id INTO v_g6;

  v_guardians := ARRAY[v_g1, v_g2, v_g3, v_g4, v_g5, v_g6];

  -- A healthy active enrollment: transported, on a route, standard contract.
  INSERT INTO enrollment (student_id, school_id, guardian_id, status, starts_on, ends_on,
                          route_id, fee_paisa, driver_bps, school_bps, rawaan_bps)
  VALUES (v_s1, v_school, v_g1, 'active', DATE '2026-01-01', DATE '2026-12-31',
          v_route, v_fee_paisa, v_driver_bps, v_school_bps, v_rawaan_bps)
  RETURNING id INTO v_e_active;

  INSERT INTO enrollment (student_id, school_id, guardian_id, status, starts_on, ends_on,
                          route_id, fee_paisa, driver_bps, school_bps, rawaan_bps)
  VALUES (v_s1, v_school, v_g1, 'paused', DATE '2026-01-01', DATE '2026-12-31',
          v_route, v_fee_paisa, v_driver_bps, v_school_bps, v_rawaan_bps)
  RETURNING id INTO v_e_paused;

  INSERT INTO enrollment (student_id, school_id, guardian_id, status, starts_on, ends_on,
                          route_id, fee_paisa, driver_bps, school_bps, rawaan_bps)
  VALUES (v_s1, v_school, v_g1, 'ended', DATE '2026-01-01', DATE '2026-12-31',
          v_route, v_fee_paisa, v_driver_bps, v_school_bps, v_rawaan_bps)
  RETURNING id INTO v_e_ended;

  -- The commercially decisive row: on the school roll, active, never assigned
  -- to a route. This child must never appear on a school invoice.
  INSERT INTO enrollment (student_id, school_id, guardian_id, status, starts_on,
                          route_id, fee_paisa, driver_bps, school_bps, rawaan_bps)
  VALUES (v_s2, v_school, v_g5, 'active', DATE '2026-01-01',
          NULL, v_fee_paisa, v_driver_bps, v_school_bps, v_rawaan_bps)
  RETURNING id INTO v_e_noroute;

  -- Baseline active enrollment for v_s3, so assertion 7 has something to
  -- collide with and assertion 8 has a sibling to sit beside.
  INSERT INTO enrollment (student_id, school_id, guardian_id, status, starts_on, ends_on,
                          route_id, fee_paisa, driver_bps, school_bps, rawaan_bps)
  VALUES (v_s3, v_school, v_g6, 'active', DATE '2026-01-01', DATE '2026-12-31',
          v_route, v_fee_paisa, v_driver_bps, v_school_bps, v_rawaan_bps)
  RETURNING id INTO v_e_s3;

  v_enrollments := ARRAY[v_e_active, v_e_paused, v_e_ended, v_e_noroute, v_e_s3];

  -- ---------------------------------------------------------------------------
  -- 1. A second is_primary guardian for the same student is REJECTED
  --    A child has exactly one person who answers for them. Consent and
  --    billing both need an unambiguous answer.
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO guardian (app_user_id, student_id, relationship, is_primary)
    VALUES (v_parents[4], v_s1, 'other', true)
    RETURNING id INTO v_id;
    DELETE FROM guardian WHERE id = v_id;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s',
      '1: a second is_primary guardian was accepted for the same student');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%uq_guardian_one_primary_per_student%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  ' ||
        '1: refused for the wrong reason, expected uq_guardian_one_primary_per_student, got: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 1: uq_guardian_one_primary_per_student refused the second is_primary guardian';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 2. Two non-primary guardians for the same student are ALLOWED
  --    Both a mother who pays and a father who only collects are normal.
  -- ---------------------------------------------------------------------------

  BEGIN
    SELECT count(*)::int INTO v_count
      FROM guardian
     WHERE student_id = v_s1 AND is_primary = false;

    IF v_count <> 2 THEN
      RAISE EXCEPTION 'expected 2 non-primary guardians on the student, found %', v_count;
    END IF;

    RAISE NOTICE 'pass 2: two non-primary guardians coexist on one student';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  ' ||
      '2: two non-primary guardians for one student were not both accepted: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 3. The guardian role guard rejects an app_user whose role is not 'parent'
  --    Otherwise a school or admin account could be linked to a child and
  --    inherit that child's location and invoice visibility in D8.
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO guardian (app_user_id, student_id, relationship, is_primary)
    VALUES (v_school_user, v_s1, 'other', false)
    RETURNING id INTO v_id;
    DELETE FROM guardian WHERE id = v_id;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s',
      '3: guardian accepted an app_user whose role is ''school''');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%requires role parent%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  ' ||
        '3: refused for the wrong reason, expected the role guard, got: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 3: guardian role guard refused a school-role app_user';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 4. The school_admin role guard rejects an app_user whose role is not 'school'
  --     Without this, a parent row here would grant school visibility in D8.
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO school_admin (school_id, app_user_id, role_at_school)
    VALUES (v_school, v_parents[1], 'admin')
    RETURNING id INTO v_id;
    DELETE FROM school_admin WHERE id = v_id;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s',
      '4: school_admin accepted an app_user whose role is ''parent''');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%requires role school%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  ' ||
        '4: refused for the wrong reason, expected the role guard, got: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 4: school_admin role guard refused a parent-role app_user';
    END IF;
  END;

  -- A valid school_admin still inserts. Proves the guard is a role check and
  -- not a blanket refusal.
  BEGIN
    INSERT INTO school_admin (school_id, app_user_id, role_at_school, can_approve_drivers)
    VALUES (v_school, v_school_user, 'principal', true)
    RETURNING id INTO v_id;

    SELECT count(*)::int INTO v_count
      FROM school_admin WHERE school_id = v_school AND app_user_id = v_school_user;

    IF v_count <> 1 THEN
      RAISE EXCEPTION 'expected 1 school_admin row for the school staff account, found %', v_count;
    END IF;

    RAISE NOTICE 'pass 4b: a genuine school-role staff account is accepted as a school_admin';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  ' ||
      '4b: school_admin refused a legitimate school-role app_user: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 5. The bps CHECK rejects a split that does not sum to 10000
  --    status is set to paused on purpose: the partial unique index is checked
  --    before CHECK constraints fire, so an active row here could be refused by
  --    the unique index and the assertion would prove nothing.
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO enrollment (student_id, school_id, guardian_id, status, starts_on,
                            route_id, fee_paisa, driver_bps, school_bps, rawaan_bps)
    VALUES (v_s3, v_school, v_g6, 'paused', DATE '2026-01-01',
            v_route, v_fee_paisa, 8000, 1000, 1200)
    RETURNING id INTO v_e_reject;
    DELETE FROM enrollment WHERE id = v_e_reject;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s',
      '5: enrollment accepted a split of 8000 + 1000 + 1200 = 10200 bps');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ck_enrollment_split_bps_sum%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  ' ||
        '5: refused for the wrong reason, expected ck_enrollment_split_bps_sum, got: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 5: ck_enrollment_split_bps_sum refused a split that does not total 10000';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 6. enrollment rejects ends_on earlier than starts_on
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO enrollment (student_id, school_id, guardian_id, status, starts_on, ends_on,
                            route_id, fee_paisa, driver_bps, school_bps, rawaan_bps)
    VALUES (v_s3, v_school, v_g6, 'paused', DATE '2026-01-01', DATE '2025-12-01',
            v_route, v_fee_paisa, v_driver_bps, v_school_bps, v_rawaan_bps)
    RETURNING id INTO v_e_reject;
    DELETE FROM enrollment WHERE id = v_e_reject;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s',
      '6: enrollment accepted ends_on before starts_on');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ck_enrollment_window_ordered%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  ' ||
        '6: refused for the wrong reason, expected ck_enrollment_window_ordered, got: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 6: ck_enrollment_window_ordered refused an inverted date window';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 7. A second ACTIVE enrollment for the same (student_id, school_id) is
  --     REJECTED. The partial unique index is the reason, and only the reason.
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO enrollment (student_id, school_id, guardian_id, status, starts_on, ends_on,
                            route_id, fee_paisa, driver_bps, school_bps, rawaan_bps)
    VALUES (v_s3, v_school, v_g6, 'active', DATE '2026-01-01', DATE '2026-12-31',
            v_route, v_fee_paisa, v_driver_bps, v_school_bps, v_rawaan_bps)
    RETURNING id INTO v_e_reject;
    DELETE FROM enrollment WHERE id = v_e_reject;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s',
      '7: two active enrollments exist for the same student at the same school');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%uq_enrollment_one_active_per_student_school%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  ' ||
        '7: refused for the wrong reason, expected uq_enrollment_one_active_per_student_school, got: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 7: uq_enrollment_one_active_per_student_school refused the duplicate active enrollment';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 8. An ENDED enrollment for the same pair IS allowed
  --     Re-enrolment after a break is the ordinary path, and it is only
  --     legible because the previous row is preserved with status ended.
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO enrollment (student_id, school_id, guardian_id, status, starts_on, ends_on,
                            route_id, fee_paisa, driver_bps, school_bps, rawaan_bps)
    VALUES (v_s3, v_school, v_g6, 'ended', DATE '2025-01-01', DATE '2025-12-31',
            v_route, v_fee_paisa, v_driver_bps, v_school_bps, v_rawaan_bps)
    RETURNING id INTO v_e_reject;

    SELECT count(*)::int INTO v_count
      FROM enrollment
     WHERE student_id = v_s3 AND school_id = v_school AND status = 'active';

    IF v_count <> 1 THEN
      RAISE EXCEPTION 'expected exactly 1 active enrollment for the student, found %', v_count;
    END IF;

    v_enrollments := v_enrollments || v_e_reject;
    RAISE NOTICE 'pass 8: a second, ended enrollment for the same student and school is allowed';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  ' ||
      '8: an ended enrollment for an existing active pair was refused: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 9. is_billable() is TRUE for an active, routed enrollment whose window
  --    covers the period
  -- ---------------------------------------------------------------------------

  v_ok := true;

  IF is_billable(v_e_active, DATE '2026-03-01', DATE '2026-03-31') IS NOT TRUE THEN
    v_ok := false;
    v_msg := v_msg || format(E'\n  %s',
      '9: is_billable() was false for an active routed enrollment over 2026-03');
  END IF;

  -- The exact first and last day of the window are both inside it.
  IF is_billable(v_e_active, DATE '2026-01-01', DATE '2026-01-01') IS NOT TRUE THEN
    v_ok := false;
    v_msg := v_msg || format(E'\n  %s',
      '9: is_billable() was false on starts_on itself, so the window is exclusive');
  END IF;

  IF is_billable(v_e_active, DATE '2026-12-31', DATE '2026-12-31') IS NOT TRUE THEN
    v_ok := false;
    v_msg := v_msg || format(E'\n  %s',
      '9: is_billable() was false on ends_on itself, so the window is exclusive');
  END IF;

  IF NOT v_ok THEN
    v_failures := v_failures + 1;
  ELSE
    RAISE NOTICE 'pass 9: is_billable() is true across the covered period, window ends included';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 10. is_billable() is FALSE at the window boundaries: one day before
  --     starts_on and one day after ends_on
  -- ---------------------------------------------------------------------------

  v_ok := true;

  IF is_billable(v_e_active, DATE '2025-12-31', DATE '2025-12-31') IS NOT FALSE THEN
    v_ok := false;
    v_msg := v_msg || format(E'\n  %s',
      '10: is_billable() was true one day before starts_on');
  END IF;

  IF is_billable(v_e_active, DATE '2027-01-01', DATE '2027-01-01') IS NOT FALSE THEN
    v_ok := false;
    v_msg := v_msg || format(E'\n  %s',
      '10: is_billable() was true one day after ends_on');
  END IF;

  IF is_billable(v_e_active, DATE '2027-02-01', DATE '2027-02-28') IS NOT FALSE THEN
    v_ok := false;
    v_msg := v_msg || format(E'\n  %s',
      '10: is_billable() was true for a whole month beyond ends_on');
  END IF;

  IF NOT v_ok THEN
    v_failures := v_failures + 1;
  ELSE
    RAISE NOTICE 'pass 10: is_billable() is false outside the date window, on both sides';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 11. is_billable() is FALSE for status paused and ended, even when the
  --     route and the date window both still qualify
  -- ---------------------------------------------------------------------------

  v_ok := true;

  IF is_billable(v_e_paused, DATE '2026-03-01', DATE '2026-03-31') IS NOT FALSE THEN
    v_ok := false;
    v_msg := v_msg || format(E'\n  %s',
      '11: is_billable() was true for a paused enrollment');
  END IF;

  IF is_billable(v_e_ended, DATE '2026-03-01', DATE '2026-03-31') IS NOT FALSE THEN
    v_ok := false;
    v_msg := v_msg || format(E'\n  %s',
      '11: is_billable() was true for an ended enrollment');
  END IF;

  -- Defensive: an unknown id, and a missing period, are both FALSE rather than
  -- NULL. A billing run that treated NULL as billable would invoice ghosts.
  IF is_billable(gen_random_uuid(), DATE '2026-03-01', DATE '2026-03-31') IS NOT FALSE THEN
    v_ok := false;
    v_msg := v_msg || format(E'\n  %s',
      '11: is_billable() did not return false for an unknown enrollment id');
  END IF;

  IF is_billable(v_e_active, NULL, NULL) IS NOT FALSE THEN
    v_ok := false;
    v_msg := v_msg || format(E'\n  %s',
      '11: is_billable() did not return false for a NULL period');
  END IF;

  IF NOT v_ok THEN
    v_failures := v_failures + 1;
  ELSE
    RAISE NOTICE 'pass 11: is_billable() is false for paused, ended, unknown and NULL input';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 12. find_nearby_students returns correct membership and a sane distance
  --
  --     Probe point 2 km north of central Peshawar (34.0151 N, 71.5249 E). One
  --     degree of latitude is about 111,320 m, so 2000 m is about 0.01797
  --     degrees. The far student sits about 10 km from the same probe point.
  --     With a 5 km radius the near student must come back and the far one
  --     must not.
  --
  --     PostGIS is asserted first. If it is absent the spatial assertions are
  --     reported as a NOTICE and skipped rather than failed: a missing
  --     extension is an environment problem, not a schema defect.
  -- ---------------------------------------------------------------------------

  SELECT exists (SELECT 1 FROM pg_extension WHERE extname = 'postgis') INTO v_postgis;

  IF NOT v_postgis THEN
    RAISE NOTICE
      'skip 12: the postgis extension is not installed in this database, so '
      'find_nearby_students cannot be exercised. Install postgis (D1 does this '
      'for you) and re-run.';
  ELSE
    BEGIN
      INSERT INTO student (full_name, school_id, grade, home_location)
      VALUES ('D3 Near Student', v_school, 'Grade 3',
              ST_SetSRID(ST_MakePoint(71.5249, 34.0151), 4326)::geography)
      RETURNING id INTO v_s_near;

      INSERT INTO student (full_name, school_id, grade, home_location)
      VALUES ('D3 Far Student', v_school, 'Grade 3',
              ST_SetSRID(ST_MakePoint(71.5249, 34.12290), 4326)::geography)
      RETURNING id INTO v_s_far;

      v_students := v_students || ARRAY[v_s_near, v_s_far];

      -- The near student is inside the 5 km radius, and the returned distance
      -- is metres rather than degrees.
      SELECT count(*)::int, min(d.distance_meters)
        INTO v_count, v_dist
        FROM find_nearby_students(v_school, 34.03307, 71.5249, 5000.0) d
       WHERE d.id = v_s_near;

      IF v_count <> 1 THEN
        RAISE EXCEPTION 'expected the student 2 km away to be returned once, got % row(s)', v_count;
      END IF;

      IF v_dist IS NULL OR v_dist < 1500 OR v_dist > 2500 THEN
        RAISE EXCEPTION 'expected a distance between 1500 and 2500 metres, got %', v_dist;
      END IF;

      -- The far student is outside 5 km and must be excluded...
      SELECT count(*)::int INTO v_far_count
        FROM find_nearby_students(v_school, 34.03307, 71.5249, 5000.0) d
       WHERE d.id = v_s_far;

      IF v_far_count <> 0 THEN
        RAISE EXCEPTION 'a student about 10 km away was returned inside a 5000 m radius';
      END IF;

      -- ...and must appear, at a sane distance, once the radius reaches it.
      SELECT count(*)::int, min(d.distance_meters)
        INTO v_far_count, v_far_dist
        FROM find_nearby_students(v_school, 34.03307, 71.5249, 20000.0) d
       WHERE d.id = v_s_far;

      IF v_far_count <> 1 THEN
        RAISE EXCEPTION 'expected the student 10 km away inside a 20 km radius, got % row(s)', v_far_count;
      END IF;

      IF v_far_dist IS NULL OR v_far_dist < 9000 OR v_far_dist > 11000 THEN
        RAISE EXCEPTION 'expected the far distance between 9000 and 11000 metres, got %', v_far_dist;
      END IF;

      RAISE NOTICE
        'pass 12: near student at % m, far student excluded at 5 km and found at % m',
        round(v_dist::numeric, 1), round(v_far_dist::numeric, 1);
    EXCEPTION WHEN OTHERS THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  ' ||
        '12: find_nearby_students membership or distance was wrong: %s', SQLERRM);
    END;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 13. The enrollment's own bps columns are the billing input, and they read
  --     back exactly as written
  --     There is deliberately no stored is_billable and no dependency on
  --     rate_snapshot here: the four rate columns live on the enrollment so a
  --     later contract change cannot reach back and alter them.
  -- ---------------------------------------------------------------------------

  BEGIN
    SELECT fee_paisa, driver_bps, school_bps, rawaan_bps
      INTO v_fee, v_dbps, v_sbps, v_rbps
      FROM enrollment
     WHERE id = v_e_active;

    IF v_fee IS DISTINCT FROM v_fee_paisa
       OR v_dbps IS DISTINCT FROM v_driver_bps
       OR v_sbps IS DISTINCT FROM v_school_bps
       OR v_rbps IS DISTINCT FROM v_rawaan_bps THEN
      RAISE EXCEPTION 'read back %/%/%/% instead of %/%/%/%',
        v_fee::text, v_dbps::text, v_sbps::text, v_rbps::text,
        v_fee_paisa::text, v_driver_bps::text, v_school_bps::text, v_rawaan_bps::text;
    END IF;

    IF v_dbps + v_sbps + v_rbps <> 10000 THEN
      RAISE EXCEPTION 'the stored split totals %, not 10000', (v_dbps + v_sbps + v_rbps)::text;
    END IF;

    RAISE NOTICE 'pass 13: enrollment % carries its own % paisa at %/%/% bps',
      v_e_active, v_fee, v_dbps, v_sbps, v_rbps;
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  ' ||
      '13: the enrollment rate columns did not read back as inserted: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 14. is_billable is DERIVED, not stored
  --     enrollment must have no is_billable column at all, and the view must
  --     expose one that agrees with the function for the same date. This is the
  --     assertion that stops someone "helpfully" adding a trigger-maintained
  --     boolean later and reintroducing drift.
  -- ---------------------------------------------------------------------------

  BEGIN
    SELECT count(*)::int INTO v_count
      FROM information_schema.columns
     WHERE table_schema = current_schema()
       AND table_name = 'enrollment'
       AND column_name = 'is_billable';

    IF v_count <> 0 THEN
      RAISE EXCEPTION 'enrollment has a stored is_billable column; it must be derived';
    END IF;

    SELECT v.is_billable INTO v_billable
      FROM v_billable_enrollment v
     WHERE v.id = v_e_paused;

    IF v_billable IS NOT FALSE THEN
      RAISE EXCEPTION 'v_billable_enrollment.is_billable was % for a paused enrollment', v_billable::text;
    END IF;

    SELECT v.is_billable INTO v_billable
      FROM v_billable_enrollment v
     WHERE v.id = v_e_active;

    IF v_billable IS DISTINCT FROM is_billable(v_e_active, current_date, current_date) THEN
      RAISE EXCEPTION
        'v_billable_enrollment.is_billable disagrees with is_billable() for today';
    END IF;

    RAISE NOTICE 'pass 14: is_billable is derived; enrollment stores no such column';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  ' ||
      '14: is_billable is not purely derived: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 15. THE COMMERCIAL RULE. An active child on the school roll who is not on
  --     a route is NOT billable, and so earns the school nothing.
  --     This is the assertion that exists so the ambiguity cannot be resolved
  --     the expensive way by a later migration.
  -- ---------------------------------------------------------------------------

  BEGIN
    IF is_billable(v_e_noroute, DATE '2026-03-01', DATE '2026-03-31') IS NOT FALSE THEN
      RAISE EXCEPTION 'an unrouted active enrollment reported itself billable';
    END IF;

    SELECT v.is_billable INTO v_billable
      FROM v_billable_enrollment v
     WHERE v.id = v_e_noroute;

    IF v_billable IS NOT FALSE THEN
      RAISE EXCEPTION 'v_billable_enrollment reported an unrouted enrollment as billable';
    END IF;

    RAISE NOTICE
      'pass 15: an active child with no route is not billable, so the school earns nothing from them';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  ' ||
      '15: an unrouted enrollment was treated as billable: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 16. An enrollment cannot name a guardian who belongs to another child
  --     Nothing in the column types prevents this, and if it were possible the
  --     wrong family would be billed for the wrong child.
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO enrollment (student_id, school_id, guardian_id, status, starts_on,
                            route_id, fee_paisa, driver_bps, school_bps, rawaan_bps)
    VALUES (v_s3, v_school, v_g1, 'paused', DATE '2026-01-01',
            v_route, v_fee_paisa, v_driver_bps, v_school_bps, v_rawaan_bps)
    RETURNING id INTO v_e_reject;
    DELETE FROM enrollment WHERE id = v_e_reject;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s',
      '16: enrollment accepted a guardian belonging to a different student');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%is linked to student%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  ' ||
        '16: refused for the wrong reason, expected the party-consistency guard, got: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 16: the party-consistency guard refused a guardian of another student';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- Cleanup. Runs before the summary so a failing run still leaves no
  -- fixtures behind.
  -- ---------------------------------------------------------------------------

  BEGIN
    DELETE FROM school_admin WHERE school_id = v_school;
    DELETE FROM enrollment   WHERE id = ANY (v_enrollments) OR school_id = v_school;
    DELETE FROM guardian     WHERE id = ANY (v_guardians) OR student_id = ANY (v_students);
    DELETE FROM student      WHERE id = ANY (v_students) OR school_id = v_school;
    DELETE FROM school       WHERE id = v_school;
    DELETE FROM app_user     WHERE id = ANY (v_auth_ids);
    DELETE FROM auth.users   WHERE id = ANY (v_auth_ids);
    RAISE NOTICE 'fixtures for run % removed', v_suffix;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'cleanup failed (all fixtures are namespaced with % and cannot collide with a later run): %',
      v_suffix, SQLERRM;
  END;

  -- ---------------------------------------------------------------------------
  -- Report
  -- ---------------------------------------------------------------------------

  IF v_failures = 0 THEN
    RAISE NOTICE 'D3: all 16 assertions passed (12 skipped if postgis is absent).';
  ELSE
    RAISE EXCEPTION 'D3: % assertion(s) failed:%', v_failures, v_msg;
  END IF;
END
$test$;