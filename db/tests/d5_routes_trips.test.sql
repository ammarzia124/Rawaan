-- =============================================================================
-- D5 test — routes, trips, check-ins, deferred FKs, money hardening
-- =============================================================================
-- Executable assertions for 20261006000005_d5_routes_trips.sql.
-- Plain SQL, no test framework, no docker. Run with:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/d5_routes_trips.test.sql
--
-- STYLE (same as d3/d4)
--   Every assertion is ATTEMPTED, each in its own BEGIN ... EXCEPTION block
--   (a savepoint). Failures accumulate and are reported in ONE exception at
--   the end. Negative cases assert WHICH constraint or guard refused the row
--   by checking SQLERRM. When a statement that should have failed succeeds,
--   its row is removed again before the failure is counted.
--
--   Blocks that must leave no trace (the transition matrix, the start-of-trip
--   re-check) end with RAISE EXCEPTION 'd5_rollback', which rolls back the
--   savepoint; plpgsql variables keep what was learned inside it.
--
-- DEPENDENCY ORDER
--   auth.users -> app_user -> school -> student, guardian -> driver, vehicle,
--   driver_school -> route, route_stop, route_manifest -> enrollment -> trip,
--   trip_qr_token, trip_checkin -> billing_period, invoice, invoice_line,
--   payout, payout_line.
--
-- RE-RUNNABLE
--   Every fixture is namespaced with a random() suffix.
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
  v_driver_users uuid[];
  v_parents     uuid[];
  v_school_user uuid;

  v_s1          uuid;   -- the school everything runs at
  v_s2          uuid;   -- another school
  v_st1         uuid;   -- manifested, checks in
  v_st2         uuid;   -- manifested
  v_st3         uuid;   -- on school 1, NOT manifested
  v_st_other    uuid;   -- on school 2
  v_g1          uuid;
  v_g2          uuid;

  v_dA          uuid;   -- approved, approved for school 1
  v_dB          uuid;   -- approved, no driver_school row
  v_dC          uuid;   -- not_submitted
  v_vA          uuid;   -- dA, verified
  v_vA_unv      uuid;   -- dA, NOT verified
  v_vB          uuid;   -- dB, verified

  v_r1          uuid;   -- school 1, dA + vA: trips and check-ins
  v_r2          uuid;   -- school 1, dA + vA: billing and delete
  v_r_other     uuid;   -- school 2, no driver
  v_stop1       uuid;
  v_stop_other  uuid;   -- stop on r_other

  v_e1          uuid;   -- st1 on r1
  v_e2          uuid;   -- st2 on r2

  v_t1          uuid;   -- walked scheduled -> completed
  v_tc          uuid;   -- check-in trip, arrived_pickup
  v_t_sched     uuid;   -- check-in "other trip", stays scheduled

  v_bp          uuid;
  v_inv         uuid;
  v_line        uuid;
  v_p1          uuid;
  v_p2          uuid;
  v_p3          uuid;

  -- Scratch ----------------------------------------------------------------
  v_id          uuid;
  v_trip        uuid;
  v_row         trip;
  v_ok          boolean;
  v_count       int;
  v_text        text;
  v_token       text;
  v_token2      text;
  v_result      checkin_result;
  v_bt          beneficiary_type;
  v_absent_def  text;
  v_billable    boolean;
  v_states      trip_status[] := enum_range(NULL::trip_status);
  v_from        trip_status;
  v_to          trip_status;
  v_step        trip_status;
  v_path        trip_status[];
  v_outcome     text;
  v_bad         text;
  v_legal       text[] := ARRAY[
    'scheduled>driver_en_route', 'scheduled>cancelled', 'scheduled>no_show',
    'driver_en_route>arrived_pickup', 'driver_en_route>cancelled',
    'arrived_pickup>in_progress', 'arrived_pickup>cancelled', 'arrived_pickup>no_show',
    'in_progress>arrived_school', 'in_progress>cancelled',
    'arrived_school>completed', 'arrived_school>cancelled'];
  v_case        record;

  v_failures    int := 0;
  v_msg         text := '';
BEGIN
  -- ---------------------------------------------------------------------------
  -- 0. Preconditions
  -- ---------------------------------------------------------------------------

  IF to_regclass('route') IS NULL OR to_regclass('route_stop') IS NULL
     OR to_regclass('route_manifest') IS NULL OR to_regclass('trip') IS NULL
     OR to_regclass('trip_checkin') IS NULL OR to_regclass('trip_qr_token') IS NULL
     OR to_regprocedure('transition_trip(uuid, trip_status, text)') IS NULL THEN
    RAISE NOTICE 'D5 test SKIPPED: the D5 objects are missing. Apply 20261006000005 first.';
    RETURN;
  END IF;

  v_suffix := replace(substr(random()::text, 3), '.', '');

  -- ---------------------------------------------------------------------------
  -- Fixtures. A fixture failure aborts loudly: it is a precondition failure.
  -- ---------------------------------------------------------------------------

  BEGIN
    FOR v_role, v_name IN
      SELECT t.v_role, t.v_name
      FROM (VALUES
        ('driver'::app_role, 'Aslam Khan'),
        ('driver'::app_role, 'Bakht Zada'),
        ('driver'::app_role, 'Ghulam Nabi'),
        ('parent'::app_role, 'Nasreen Bibi'),
        ('parent'::app_role, 'Zahid Iqbal'),
        ('school'::app_role, 'Principal Sadia')
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
        crypt('d5-test-not-a-real-password', gen_salt('bf')),
        now(), now(), now(), '{}'::jsonb, '{}'::jsonb
      );

      INSERT INTO app_user (id, role, full_name, phone)
      VALUES (v_auth_id, v_role, v_name,
              '+9230' || lpad(((900000 + (random() * 99999))::int)::text, 7, '0'));

      v_auth_ids := v_auth_ids || v_auth_id;
    END LOOP;

    SELECT array_agg(id ORDER BY full_name) INTO v_driver_users
      FROM app_user WHERE id = ANY (v_auth_ids) AND role = 'driver';
    SELECT array_agg(id ORDER BY full_name) INTO v_parents
      FROM app_user WHERE id = ANY (v_auth_ids) AND role = 'parent';
    SELECT id INTO v_school_user
      FROM app_user WHERE id = ANY (v_auth_ids) AND role = 'school';

    INSERT INTO school (name, slug) VALUES ('D5 School One ' || v_suffix, 'd5-one-' || v_suffix)
    RETURNING id INTO v_s1;
    INSERT INTO school (name, slug) VALUES ('D5 School Two ' || v_suffix, 'd5-two-' || v_suffix)
    RETURNING id INTO v_s2;

    INSERT INTO student (full_name, school_id) VALUES ('Ayesha Khan', v_s1) RETURNING id INTO v_st1;
    INSERT INTO student (full_name, school_id) VALUES ('Bilal Khan',  v_s1) RETURNING id INTO v_st2;
    INSERT INTO student (full_name, school_id) VALUES ('Hira Khan',   v_s1) RETURNING id INTO v_st3;
    INSERT INTO student (full_name, school_id) VALUES ('Omar Shah',   v_s2) RETURNING id INTO v_st_other;

    INSERT INTO guardian (app_user_id, student_id, relationship, is_primary, consent_at, consent_version)
    VALUES (v_parents[1], v_st1, 'mother', true, now(), '2026-01-consent-v3')
    RETURNING id INTO v_g1;
    INSERT INTO guardian (app_user_id, student_id, relationship, is_primary, consent_at, consent_version)
    VALUES (v_parents[2], v_st2, 'father', true, now(), '2026-01-consent-v3')
    RETURNING id INTO v_g2;

    INSERT INTO driver (app_user_id, full_name, phone, verification_status)
    VALUES (v_driver_users[1], 'Aslam Khan', '+923001111111', 'approved') RETURNING id INTO v_dA;
    INSERT INTO driver (app_user_id, full_name, phone, verification_status)
    VALUES (v_driver_users[2], 'Bakht Zada', '+923002222222', 'approved') RETURNING id INTO v_dB;
    INSERT INTO driver (app_user_id, full_name, phone, verification_status)
    VALUES (v_driver_users[3], 'Ghulam Nabi', '+923003333333', 'not_submitted') RETURNING id INTO v_dC;

    INSERT INTO vehicle (driver_id, plate_number, seating_capacity, is_vehicle_verified)
    VALUES (v_dA, 'KP-D5-A-' || v_suffix, 12, true) RETURNING id INTO v_vA;
    INSERT INTO vehicle (driver_id, plate_number, seating_capacity, is_vehicle_verified)
    VALUES (v_dA, 'KP-D5-AU-' || v_suffix, 12, false) RETURNING id INTO v_vA_unv;
    INSERT INTO vehicle (driver_id, plate_number, seating_capacity, is_vehicle_verified)
    VALUES (v_dB, 'KP-D5-B-' || v_suffix, 10, true) RETURNING id INTO v_vB;

    INSERT INTO driver_school (driver_id, school_id, approved_by, approved_at, is_active)
    VALUES (v_dA, v_s1, v_school_user, now(), true);

    INSERT INTO route (school_id, name, driver_id, vehicle_id)
    VALUES (v_s1, 'Hayatabad Morning', v_dA, v_vA) RETURNING id INTO v_r1;
    INSERT INTO route (school_id, name, driver_id, vehicle_id)
    VALUES (v_s1, 'University Town Morning', v_dA, v_vA) RETURNING id INTO v_r2;
    INSERT INTO route (school_id, name) VALUES (v_s2, 'Other School Route') RETURNING id INTO v_r_other;

    INSERT INTO route_stop (route_id, stop_order, name, location)
    VALUES (v_r1, 1, 'Phase 3 Chowk', ST_SetSRID(ST_MakePoint(71.4410, 33.9940), 4326)::geography)
    RETURNING id INTO v_stop1;
    INSERT INTO route_stop (route_id, stop_order, name, location)
    VALUES (v_r_other, 1, 'Saddar', ST_SetSRID(ST_MakePoint(71.5400, 34.0000), 4326)::geography)
    RETURNING id INTO v_stop_other;

    INSERT INTO route_manifest (route_id, route_stop_id, student_id) VALUES (v_r1, v_stop1, v_st1);
    INSERT INTO route_manifest (route_id, route_stop_id, student_id) VALUES (v_r1, v_stop1, v_st2);

    INSERT INTO enrollment (student_id, school_id, guardian_id, status, starts_on,
                            route_id, fee_paisa, driver_bps, school_bps, rawaan_bps)
    VALUES (v_st1, v_s1, v_g1, 'active', DATE '2026-01-01', v_r1, 400000, 8000, 1000, 1000)
    RETURNING id INTO v_e1;
    INSERT INTO enrollment (student_id, school_id, guardian_id, status, starts_on,
                            route_id, fee_paisa, driver_bps, school_bps, rawaan_bps)
    VALUES (v_st2, v_s1, v_g2, 'active', DATE '2026-01-01', v_r2, 400000, 8000, 1000, 1000)
    RETURNING id INTO v_e2;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'D5 test: fixture setup failed, no assertions were run. Original error: %', SQLERRM;
  END;

  -- ---------------------------------------------------------------------------
  -- 1. The route trigger refuses every unsafe assignment, for the right reason
  --    and accepts the safe one (v_r1 above).
  -- ---------------------------------------------------------------------------

  v_ok := true;
  FOR v_case IN
    SELECT * FROM (VALUES
      ('unapproved driver',             v_dC, NULL::uuid, 'verification_status is not_submitted'),
      ('no driver_school row',          v_dB, v_vB,       'no active approved driver_school row'),
      ('vehicle of another driver',     v_dA, v_vB,       'does not belong to driver'),
      ('unverified vehicle',            v_dA, v_vA_unv,   'is not verified'),
      ('vehicle without driver',        NULL::uuid, v_vA, 'ck_route_vehicle_requires_driver')
    ) AS c(label, driver_id, vehicle_id, expected)
  LOOP
    BEGIN
      INSERT INTO route (school_id, name, driver_id, vehicle_id)
      VALUES (v_s1, 'Probe ' || v_case.label, v_case.driver_id, v_case.vehicle_id)
      RETURNING id INTO v_id;
      DELETE FROM route WHERE id = v_id;
      v_ok := false;
      v_msg := v_msg || format(E'\n  1: route accepted a %s', v_case.label);
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%' || v_case.expected || '%' THEN
        v_ok := false;
        v_msg := v_msg || format(E'\n  1: %s refused for the wrong reason, expected %s, got: %s',
          v_case.label, v_case.expected, SQLERRM);
      END IF;
    END;
  END LOOP;

  IF v_ok THEN
    RAISE NOTICE 'pass 1: trg_route_driver_assignable and ck_route_vehicle_requires_driver refused all five unsafe routes';
  ELSE
    v_failures := v_failures + 1;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 2. An INACTIVE route may hold an unapproved driver; activating it re-checks
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO route (school_id, name, driver_id, is_active)
    VALUES (v_s1, 'Dormant ' || v_suffix, v_dC, false)
    RETURNING id INTO v_id;

    BEGIN
      UPDATE route SET is_active = true WHERE id = v_id;
      RAISE EXCEPTION 'activating a route with an unapproved driver succeeded';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%verification_status is not_submitted%' THEN
        RAISE EXCEPTION 'activation refused for the wrong reason: %', SQLERRM;
      END IF;
    END;

    DELETE FROM route WHERE id = v_id;
    RAISE NOTICE 'pass 2: an inactive route skips the check, and reactivation re-runs it';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s', '2: ' || SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 3. route.school_id is immutable
  -- ---------------------------------------------------------------------------

  BEGIN
    UPDATE route SET school_id = v_s2 WHERE id = v_r2;
    UPDATE route SET school_id = v_s1 WHERE id = v_r2;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s', '3: route.school_id was changed');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%school_id is immutable%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  3: refused for the wrong reason: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 3: route.school_id is immutable';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 4. A manifested student must attend the route's school
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO route_manifest (route_id, route_stop_id, student_id)
    VALUES (v_r1, v_stop1, v_st_other) RETURNING id INTO v_id;
    DELETE FROM route_manifest WHERE id = v_id;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s', '4: a student of another school was manifested');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%route_manifest: student%serves school%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  4: refused for the wrong reason: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 4: trg_route_manifest_student_school refused a student of another school';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 5. A manifest stop must belong to the manifest route (composite FK)
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO route_manifest (route_id, route_stop_id, student_id)
    VALUES (v_r1, v_stop_other, v_st3) RETURNING id INTO v_id;
    DELETE FROM route_manifest WHERE id = v_id;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s', '5: a stop of another route was manifested');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%fk_route_manifest_route_stop_id%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  5: refused for the wrong reason: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 5: fk_route_manifest_route_stop_id refused a stop from another route';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 6. Trip inserts: must start scheduled, need an active route, and the
  --    trip's own driver must be assignable
  -- ---------------------------------------------------------------------------

  v_ok := true;
  BEGIN
    INSERT INTO trip (route_id, driver_id, vehicle_id, trip_date, status)
    VALUES (v_r1, v_dA, v_vA, DATE '2031-01-01', 'in_progress') RETURNING id INTO v_id;
    DELETE FROM trip WHERE id = v_id;
    v_ok := false;
    v_msg := v_msg || format(E'\n  %s', '6: a trip was inserted already in_progress');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%must start as scheduled%' THEN
      v_ok := false;
      v_msg := v_msg || format(E'\n  6: in_progress insert refused for the wrong reason: %s', SQLERRM);
    END IF;
  END;

  BEGIN
    UPDATE route SET is_active = false WHERE id = v_r2;
    BEGIN
      INSERT INTO trip (route_id, driver_id, vehicle_id, trip_date)
      VALUES (v_r2, v_dA, v_vA, DATE '2031-01-02') RETURNING id INTO v_id;
      DELETE FROM trip WHERE id = v_id;
      v_ok := false;
      v_msg := v_msg || format(E'\n  %s', '6: a trip was scheduled on an inactive route');
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%is not active%' THEN
        v_ok := false;
        v_msg := v_msg || format(E'\n  6: inactive-route trip refused for the wrong reason: %s', SQLERRM);
      END IF;
    END;
    UPDATE route SET is_active = true WHERE id = v_r2;
  END;

  BEGIN
    INSERT INTO trip (route_id, driver_id, vehicle_id, trip_date)
    VALUES (v_r1, v_dB, v_vB, DATE '2031-01-03') RETURNING id INTO v_id;
    DELETE FROM trip WHERE id = v_id;
    v_ok := false;
    v_msg := v_msg || format(E'\n  %s', '6: a trip accepted a driver with no driver_school row');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%no active approved driver_school row%' THEN
      v_ok := false;
      v_msg := v_msg || format(E'\n  6: substitute-driver trip refused for the wrong reason: %s', SQLERRM);
    END IF;
  END;

  IF v_ok THEN
    RAISE NOTICE 'pass 6: trip inserts start scheduled, need an active route and an assignable driver';
  ELSE
    v_failures := v_failures + 1;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 7. The full happy path, with started_at and ended_at stamped
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO trip (route_id, driver_id, vehicle_id, trip_date)
    VALUES (v_r1, v_dA, v_vA, DATE '2031-02-01') RETURNING id INTO v_t1;

    v_row := transition_trip(v_t1, 'driver_en_route');
    IF v_row.started_at IS NULL OR v_row.ended_at IS NOT NULL THEN
      RAISE EXCEPTION 'driver_en_route did not stamp started_at alone';
    END IF;
    PERFORM transition_trip(v_t1, 'arrived_pickup');
    PERFORM transition_trip(v_t1, 'in_progress');
    PERFORM transition_trip(v_t1, 'arrived_school');
    v_row := transition_trip(v_t1, 'completed');

    IF v_row.status <> 'completed' OR v_row.ended_at IS NULL THEN
      RAISE EXCEPTION 'completed trip has status % and ended_at %', v_row.status, v_row.ended_at;
    END IF;

    RAISE NOTICE 'pass 7: scheduled -> driver_en_route -> arrived_pickup -> in_progress -> arrived_school -> completed';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  7: the happy path failed: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 8. EVERY (from, to) pair, 64 of them: the 12 legal moves succeed and the
  --    52 others raise "illegal trip transition". The expected list is written
  --    out above, independently of trip_transition_is_legal().
  -- ---------------------------------------------------------------------------

  v_bad := '';
  FOREACH v_from IN ARRAY v_states LOOP
    v_path := CASE v_from
      WHEN 'scheduled'       THEN '{}'::trip_status[]
      WHEN 'driver_en_route' THEN '{driver_en_route}'
      WHEN 'arrived_pickup'  THEN '{driver_en_route,arrived_pickup}'
      WHEN 'in_progress'     THEN '{driver_en_route,arrived_pickup,in_progress}'
      WHEN 'arrived_school'  THEN '{driver_en_route,arrived_pickup,in_progress,arrived_school}'
      WHEN 'completed'       THEN '{driver_en_route,arrived_pickup,in_progress,arrived_school,completed}'
      WHEN 'cancelled'       THEN '{cancelled}'
      WHEN 'no_show'         THEN '{no_show}'
    END;

    FOREACH v_to IN ARRAY v_states LOOP
      v_outcome := NULL;
      BEGIN
        INSERT INTO trip (route_id, driver_id, vehicle_id, trip_date)
        VALUES (v_r1, v_dA, v_vA, DATE '2031-03-01') RETURNING id INTO v_trip;

        FOREACH v_step IN ARRAY v_path LOOP
          PERFORM transition_trip(v_trip, v_step, 'matrix setup');
        END LOOP;

        BEGIN
          PERFORM transition_trip(v_trip, v_to, 'matrix probe');
          v_outcome := 'legal';
        EXCEPTION WHEN OTHERS THEN
          v_outcome := CASE WHEN SQLERRM LIKE '%illegal trip transition%' THEN 'illegal'
                            ELSE 'error: ' || SQLERRM END;
        END;

        RAISE EXCEPTION 'd5_rollback';
      EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'd5_rollback' THEN
          v_outcome := 'setup error: ' || SQLERRM;
        END IF;
      END;

      v_text := CASE WHEN (v_from::text || '>' || v_to::text) = ANY (v_legal)
                     THEN 'legal' ELSE 'illegal' END;
      IF v_outcome IS DISTINCT FROM v_text THEN
        v_bad := v_bad || format(' [%s -> %s: %s]', v_from, v_to, v_outcome);
      END IF;
    END LOOP;
  END LOOP;

  IF v_bad <> '' THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  8: transition matrix mismatches:%s', v_bad);
  ELSE
    RAISE NOTICE 'pass 8: all 64 transitions behave: 12 legal, 52 refused as illegal';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 9. Cancelling needs a reason
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO trip (route_id, driver_id, vehicle_id, trip_date)
    VALUES (v_r1, v_dA, v_vA, DATE '2031-04-01') RETURNING id INTO v_trip;
    BEGIN
      PERFORM transition_trip(v_trip, 'cancelled');
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  %s', '9: a trip was cancelled without a reason');
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%ck_trip_cancelled_requires_reason%' THEN
        v_failures := v_failures + 1;
        v_msg := v_msg || format(E'\n  9: refused for the wrong reason: %s', SQLERRM);
      ELSE
        RAISE NOTICE 'pass 9: ck_trip_cancelled_requires_reason refused a reasonless cancellation';
      END IF;
    END;
    DELETE FROM trip WHERE id = v_trip;
  END;

  -- ---------------------------------------------------------------------------
  -- 10. Direct UPDATE of trip.status is blocked: plainly, after a legitimate
  --     transition_trip() in the same transaction, and with the GUC forged
  --     for a DIFFERENT trip. Non-status columns stay writable.
  -- ---------------------------------------------------------------------------

  v_ok := true;
  BEGIN
    INSERT INTO trip (route_id, driver_id, vehicle_id, trip_date)
    VALUES (v_r1, v_dA, v_vA, DATE '2031-05-01') RETURNING id INTO v_trip;

    FOR v_case IN SELECT * FROM (VALUES ('plain'), ('after transition_trip'), ('forged for another trip')) AS c(label)
    LOOP
      BEGIN
        IF v_case.label = 'after transition_trip' THEN
          PERFORM transition_trip(v_trip, 'driver_en_route');
        ELSIF v_case.label = 'forged for another trip' THEN
          PERFORM set_config('rawaan.trip_transition', v_t1::text, true);
        END IF;
        UPDATE trip SET status = 'completed' WHERE id = v_trip;
        v_ok := false;
        v_msg := v_msg || format(E'\n  10: direct status UPDATE succeeded (%s)', v_case.label);
      EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%status may only change through transition_trip()%' THEN
          v_ok := false;
          v_msg := v_msg || format(E'\n  10: %s refused for the wrong reason: %s', v_case.label, SQLERRM);
        END IF;
      END;
    END LOOP;
    PERFORM set_config('rawaan.trip_transition', '', true);

    UPDATE trip SET status_reason = 'note only' WHERE id = v_trip;
    DELETE FROM trip WHERE id = v_trip;
  EXCEPTION WHEN OTHERS THEN
    v_ok := false;
    v_msg := v_msg || format(E'\n  10: setup or non-status update failed: %s', SQLERRM);
  END;

  IF v_ok THEN
    RAISE NOTICE 'pass 10: trg_trip_status_guard refused every direct status UPDATE';
  ELSE
    v_failures := v_failures + 1;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 11. Starting a trip re-checks safety: a vehicle unverified after
  --     scheduling blocks scheduled -> driver_en_route
  -- ---------------------------------------------------------------------------

  v_outcome := NULL;
  BEGIN
    INSERT INTO trip (route_id, driver_id, vehicle_id, trip_date)
    VALUES (v_r1, v_dA, v_vA, DATE '2031-06-01') RETURNING id INTO v_trip;
    UPDATE vehicle SET is_vehicle_verified = false WHERE id = v_vA;
    BEGIN
      PERFORM transition_trip(v_trip, 'driver_en_route');
      v_outcome := 'started';
    EXCEPTION WHEN OTHERS THEN
      v_outcome := SQLERRM;
    END;
    RAISE EXCEPTION 'd5_rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'd5_rollback' THEN v_outcome := 'setup error: ' || SQLERRM; END IF;
  END;

  IF v_outcome IS NULL OR v_outcome NOT LIKE '%is not verified%' THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  11: starting with an unverified vehicle gave: %s', coalesce(v_outcome, 'null'));
  ELSE
    RAISE NOTICE 'pass 11: transition_trip re-checks the vehicle when a trip starts';
  END IF;

  -- ---------------------------------------------------------------------------
  -- Check-in fixtures: v_tc boarding (arrived_pickup), v_t_sched scheduled.
  -- ---------------------------------------------------------------------------

  INSERT INTO trip (route_id, driver_id, vehicle_id, trip_date)
  VALUES (v_r1, v_dA, v_vA, DATE '2031-07-01') RETURNING id INTO v_tc;
  PERFORM transition_trip(v_tc, 'driver_en_route');
  PERFORM transition_trip(v_tc, 'arrived_pickup');
  INSERT INTO trip (route_id, driver_id, vehicle_id, trip_date)
  VALUES (v_r1, v_dA, v_vA, DATE '2031-07-02') RETURNING id INTO v_t_sched;

  -- ---------------------------------------------------------------------------
  -- 12. Tokens are stored hashed, 32 bytes, never raw
  -- ---------------------------------------------------------------------------

  BEGIN
    v_token := issue_trip_qr_token(v_tc, v_st1);

    SELECT count(*)::int INTO v_count FROM trip_qr_token
     WHERE trip_id = v_tc AND token_hash = digest(v_token, 'sha256')
       AND octet_length(token_hash) = 32
       AND token_hash <> convert_to(v_token, 'UTF8');

    IF v_count <> 1 OR length(v_token) <> 64 THEN
      RAISE EXCEPTION 'expected one sha256-hashed row for a 64-hex-char token, found % row(s)', v_count;
    END IF;
    RAISE NOTICE 'pass 12: issue_trip_qr_token stores only the SHA-256 of a 256-bit token';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  12: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 13. Tokens are short-lived: a 30 minute TTL is refused
  -- ---------------------------------------------------------------------------

  BEGIN
    PERFORM issue_trip_qr_token(v_tc, v_st1, interval '30 minutes');
    DELETE FROM trip_qr_token WHERE trip_id = v_tc AND expires_at > now() + interval '15 minutes';
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s', '13: a 30-minute token was issued');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ck_trip_qr_token_short_lived%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  13: refused for the wrong reason: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 13: ck_trip_qr_token_short_lived refused a 30 minute token';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 14. No token for a finished trip
  -- ---------------------------------------------------------------------------

  BEGIN
    PERFORM issue_trip_qr_token(v_t1, v_st1);
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s', '14: a token was issued for a completed trip');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%is already completed%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  14: refused for the wrong reason: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 14: issue_trip_qr_token refused a completed trip';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 15. Every checkin_result, each from the scenario that should produce it,
  --     and every attempt recorded as a row
  -- ---------------------------------------------------------------------------

  v_bad := '';
  BEGIN
    -- wrong_child: valid token for st1, driver selected st2.
    v_result := record_trip_checkin(v_tc, 'qr_scan', v_token, v_st2);
    IF v_result IS DISTINCT FROM 'wrong_child' THEN v_bad := v_bad || ' [token/other child: ' || v_result || ']'; END IF;

    -- wrong_child: on the school roll, not on the manifest.
    v_result := record_trip_checkin(v_tc, 'manual_override', NULL, v_st3);
    IF v_result IS DISTINCT FROM 'wrong_child' THEN v_bad := v_bad || ' [not manifested: ' || v_result || ']'; END IF;

    -- success, and the token is consumed.
    v_result := record_trip_checkin(v_tc, 'qr_scan', v_token, NULL, v_driver_users[1]);
    IF v_result IS DISTINCT FROM 'success' THEN v_bad := v_bad || ' [first scan: ' || v_result || ']'; END IF;
    SELECT count(*)::int INTO v_count FROM trip_qr_token
     WHERE token_hash = digest(v_token, 'sha256') AND consumed_at IS NOT NULL;
    IF v_count <> 1 THEN v_bad := v_bad || ' [token not consumed]'; END IF;

    -- already_checked_in: re-scan, and manual override of the same child.
    v_result := record_trip_checkin(v_tc, 'qr_scan', v_token);
    IF v_result IS DISTINCT FROM 'already_checked_in' THEN v_bad := v_bad || ' [re-scan: ' || v_result || ']'; END IF;
    v_result := record_trip_checkin(v_tc, 'manual_override', NULL, v_st1);
    IF v_result IS DISTINCT FROM 'already_checked_in' THEN v_bad := v_bad || ' [manual repeat: ' || v_result || ']'; END IF;

    -- expired_token: unknown token, and a genuinely expired one.
    v_result := record_trip_checkin(v_tc, 'qr_scan', 'not-a-token-' || v_suffix);
    IF v_result IS DISTINCT FROM 'expired_token' THEN v_bad := v_bad || ' [unknown token: ' || v_result || ']'; END IF;

    v_token2 := encode(gen_random_bytes(32), 'hex');
    INSERT INTO trip_qr_token (trip_id, student_id, token_hash, expires_at, created_at)
    VALUES (v_tc, v_st2, digest(v_token2, 'sha256'), now() - interval '10 minutes', now() - interval '20 minutes');
    v_result := record_trip_checkin(v_tc, 'qr_scan', v_token2);
    IF v_result IS DISTINCT FROM 'expired_token' THEN v_bad := v_bad || ' [expired token: ' || v_result || ']'; END IF;

    -- wrong_trip: token minted for another trip, and a scan on a trip that is
    -- not boarding.
    v_token2 := issue_trip_qr_token(v_t_sched, v_st2);
    v_result := record_trip_checkin(v_tc, 'qr_scan', v_token2);
    IF v_result IS DISTINCT FROM 'wrong_trip' THEN v_bad := v_bad || ' [other trip token: ' || v_result || ']'; END IF;
    v_result := record_trip_checkin(v_t_sched, 'qr_scan', v_token2);
    IF v_result IS DISTINCT FROM 'wrong_trip' THEN v_bad := v_bad || ' [not boarding: ' || v_result || ']'; END IF;

    -- child_absent: swap the D6 hook for one that reports st2 absent, then
    -- put back whatever definition is installed (D5 stub or D6 real one).
    v_absent_def := pg_get_functiondef('is_student_absent(uuid, date)'::regprocedure);
    EXECUTE format(
      'CREATE OR REPLACE FUNCTION is_student_absent(p_student_id uuid, p_on date) '
      'RETURNS boolean LANGUAGE sql STABLE AS $f$ SELECT p_student_id = %L::uuid $f$', v_st2);
    v_result := record_trip_checkin(v_tc, 'manual_override', NULL, v_st2);
    EXECUTE v_absent_def;
    IF v_result IS DISTINCT FROM 'child_absent' THEN v_bad := v_bad || ' [absent: ' || v_result || ']'; END IF;

    -- Every one of the 10 attempts is a row: 9 on v_tc, 1 on v_t_sched.
    SELECT count(*)::int INTO v_count FROM trip_checkin WHERE trip_id IN (v_tc, v_t_sched);
    IF v_count <> 10 THEN v_bad := v_bad || format(' [expected 10 recorded attempts, found %s]', v_count); END IF;

    SELECT count(DISTINCT result)::int INTO v_count FROM trip_checkin WHERE trip_id IN (v_tc, v_t_sched);
    IF v_count <> 6 THEN v_bad := v_bad || format(' [expected all 6 results recorded, found %s]', v_count); END IF;
  EXCEPTION WHEN OTHERS THEN
    v_bad := v_bad || ' [raised: ' || SQLERRM || ']';
  END;

  IF v_bad <> '' THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  15: check-in results wrong:%s', v_bad);
  ELSE
    RAISE NOTICE 'pass 15: all six checkin_result values produced, all 10 attempts recorded';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 16. The database itself refuses a second success for one child on a trip
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO trip_checkin (trip_id, student_id, method, result)
    VALUES (v_tc, v_st1, 'manual_override', 'success') RETURNING id INTO v_id;
    DELETE FROM trip_checkin WHERE id = v_id;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s', '16: a second success row was accepted');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%uq_trip_checkin_one_success_per_trip_student%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  16: refused for the wrong reason: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 16: uq_trip_checkin_one_success_per_trip_student refused a double boarding';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 17. fk_enrollment_route exists, is deferred, and rejects an unknown route
  --     once forced IMMEDIATE
  -- ---------------------------------------------------------------------------

  BEGIN
    SELECT count(*)::int INTO v_count FROM pg_constraint
     WHERE conname = 'fk_enrollment_route' AND conrelid = 'enrollment'::regclass
       AND contype = 'f' AND condeferrable AND condeferred AND confdeltype = 'n';
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'fk_enrollment_route is missing or not DEFERRABLE INITIALLY DEFERRED ON DELETE SET NULL';
    END IF;
    IF to_regclass('idx_enrollment_route_id') IS NULL THEN
      RAISE EXCEPTION 'idx_enrollment_route_id is missing';
    END IF;

    BEGIN
      SET CONSTRAINTS fk_enrollment_route IMMEDIATE;
      UPDATE enrollment SET route_id = gen_random_uuid() WHERE id = v_e1;
      RAISE EXCEPTION 'an unknown route id was accepted';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%fk_enrollment_route%' THEN
        RAISE EXCEPTION 'unknown route refused for the wrong reason: %', SQLERRM;
      END IF;
    END;
    SET CONSTRAINTS fk_enrollment_route DEFERRED;

    RAISE NOTICE 'pass 17: fk_enrollment_route is deferred, indexed, and rejects an unknown route';
  EXCEPTION WHEN OTHERS THEN
    SET CONSTRAINTS fk_enrollment_route DEFERRED;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  17: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 18. An INACTIVE route makes the enrollment non-billable, in is_billable()
  --     and in the view; reactivating restores it. The view is
  --     security_invoker.
  -- ---------------------------------------------------------------------------

  BEGIN
    IF is_billable(v_e2, DATE '2026-03-01', DATE '2026-03-31') IS NOT TRUE THEN
      RAISE EXCEPTION 'baseline: e2 on an active route was not billable';
    END IF;

    UPDATE route SET is_active = false WHERE id = v_r2;

    IF is_billable(v_e2, DATE '2026-03-01', DATE '2026-03-31') IS NOT FALSE THEN
      RAISE EXCEPTION 'is_billable() was true on an inactive route';
    END IF;
    SELECT v.is_billable INTO v_billable FROM v_billable_enrollment v WHERE v.id = v_e2;
    IF v_billable IS NOT FALSE THEN
      RAISE EXCEPTION 'v_billable_enrollment.is_billable was % on an inactive route', v_billable::text;
    END IF;

    UPDATE route SET is_active = true WHERE id = v_r2;
    SELECT v.is_billable INTO v_billable FROM v_billable_enrollment v WHERE v.id = v_e2;
    IF v_billable IS NOT TRUE OR is_billable(v_e2, current_date, current_date) IS NOT TRUE THEN
      RAISE EXCEPTION 'reactivating the route did not restore billability';
    END IF;

    SELECT count(*)::int INTO v_count FROM pg_class
     WHERE oid = 'v_billable_enrollment'::regclass
       AND 'security_invoker=true' = ANY (reloptions);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'v_billable_enrollment is not security_invoker';
    END IF;

    RAISE NOTICE 'pass 18: an inactive route makes the enrollment non-billable (function and view)';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  18: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 19. Deleting a route sets enrollment.route_id NULL, keeping the enrollment
  -- ---------------------------------------------------------------------------

  BEGIN
    DELETE FROM route WHERE id = v_r2;
    SELECT count(*)::int INTO v_count FROM enrollment WHERE id = v_e2 AND route_id IS NULL;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'the enrollment was lost or still points at the deleted route';
    END IF;
    IF is_billable(v_e2, DATE '2026-03-01', DATE '2026-03-31') IS NOT FALSE THEN
      RAISE EXCEPTION 'an enrollment whose route was deleted is still billable';
    END IF;
    RAISE NOTICE 'pass 19: ON DELETE SET NULL kept the enrollment and made it non-billable';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  19: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- Money fixtures: one period, one invoice, one line.
  -- ---------------------------------------------------------------------------

  INSERT INTO billing_period (school_id, period_start, period_end, period_label)
  VALUES (v_s1, DATE '2026-03-01', DATE '2026-03-31', '2026-03') RETURNING id INTO v_bp;
  INSERT INTO invoice (enrollment_id, billing_period_id, guardian_id, school_id,
                       status, subtotal_paisa, total_paisa)
  VALUES (v_e1, v_bp, v_g1, v_s1, 'paid', 400000, 400000) RETURNING id INTO v_inv;
  INSERT INTO invoice_line (invoice_id, line_type, description, amount_paisa,
                            driver_bps, school_bps, rawaan_bps)
  VALUES (v_inv, 'transport_fee', 'Transport, March 2026', 400000, 8000, 1000, 1000)
  RETURNING id INTO v_line;

  -- ---------------------------------------------------------------------------
  -- 20. The D2 -> D3/D4 foreign keys reject orphans, each by name
  -- ---------------------------------------------------------------------------

  v_ok := true;
  FOR v_case IN
    SELECT * FROM (VALUES
      ('fk_rate_snapshot_school_id', format(
        'INSERT INTO rate_snapshot (school_id, effective_from, fee_paisa, driver_bps, school_bps, rawaan_bps) '
        'VALUES (%L, DATE ''2026-01-01'', 400000, 8000, 1000, 1000)', gen_random_uuid())),
      ('fk_billing_period_school_id', format(
        'INSERT INTO billing_period (school_id, period_start, period_end, period_label) '
        'VALUES (%L, DATE ''2026-04-01'', DATE ''2026-04-30'', ''2026-04'')', gen_random_uuid())),
      ('fk_invoice_enrollment_id', format(
        'INSERT INTO invoice (enrollment_id, billing_period_id, guardian_id, school_id, subtotal_paisa, total_paisa) '
        'VALUES (%L, %L, %L, %L, 400000, 400000)', gen_random_uuid(), v_bp, v_g1, v_s1)),
      ('fk_invoice_guardian_id', format(
        'INSERT INTO invoice (enrollment_id, billing_period_id, guardian_id, school_id, subtotal_paisa, total_paisa) '
        'VALUES (%L, %L, %L, %L, 400000, 400000)', v_e2, v_bp, gen_random_uuid(), v_s1)),
      ('fk_invoice_school_id', format(
        'INSERT INTO invoice (enrollment_id, billing_period_id, guardian_id, school_id, subtotal_paisa, total_paisa) '
        'VALUES (%L, %L, %L, %L, 400000, 400000)', v_e2, v_bp, v_g2, gen_random_uuid())),
      ('fk_payment_guardian_id', format(
        'INSERT INTO payment (invoice_id, guardian_id, amount_paisa, method) '
        'VALUES (%L, %L, 400000, ''cash'')', v_inv, gen_random_uuid())),
      ('fk_payout_school_id', format(
        'INSERT INTO payout (beneficiary_type, beneficiary_id, school_id, period_start, period_end, gross_paisa, net_paisa) '
        'VALUES (''driver'', %L, %L, DATE ''2026-03-01'', DATE ''2026-03-31'', 320000, 320000)', v_dA, gen_random_uuid())),
      ('fk_driver_earning_payout_id', format(
        'INSERT INTO driver_earning (driver_id, school_id, period_start, period_end, gross_paisa, net_paisa, payout_id) '
        'VALUES (%L, %L, DATE ''2026-03-01'', DATE ''2026-03-31'', 320000, 320000, %L)', v_dA, v_s1, gen_random_uuid()))
    ) AS c(expected, stmt)
  LOOP
    BEGIN
      EXECUTE v_case.stmt;
      v_ok := false;
      v_msg := v_msg || format(E'\n  20: an orphan was accepted where %s should refuse it', v_case.expected);
      RAISE EXCEPTION 'd5_rollback';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM <> 'd5_rollback' AND SQLERRM NOT LIKE '%' || v_case.expected || '%' THEN
        v_ok := false;
        v_msg := v_msg || format(E'\n  20: expected %s, got: %s', v_case.expected, SQLERRM);
      END IF;
    END;
  END LOOP;

  IF v_ok THEN
    RAISE NOTICE 'pass 20: all eight D2 -> D3/D4 foreign keys refused an orphan';
  ELSE
    v_failures := v_failures + 1;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 21. An invoice can never be negative (subtotal or total)
  -- ---------------------------------------------------------------------------

  v_ok := true;
  FOR v_case IN
    SELECT * FROM (VALUES
      (-100::bigint, 0::bigint,   -100::bigint, 'ck_invoice_subtotal_non_negative'),
      ( 100::bigint, 200::bigint, -100::bigint, 'ck_invoice_total_non_negative')
    ) AS c(subtotal, discount, total, expected)
  LOOP
    BEGIN
      INSERT INTO invoice (enrollment_id, billing_period_id, guardian_id, school_id,
                           subtotal_paisa, discount_paisa, total_paisa)
      VALUES (v_e2, v_bp, v_g2, v_s1, v_case.subtotal, v_case.discount, v_case.total)
      RETURNING id INTO v_id;
      DELETE FROM invoice WHERE id = v_id;
      v_ok := false;
      v_msg := v_msg || format(E'\n  21: a negative invoice was accepted (%s expected)', v_case.expected);
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%' || v_case.expected || '%' THEN
        v_ok := false;
        v_msg := v_msg || format(E'\n  21: expected %s, got: %s', v_case.expected, SQLERRM);
      END IF;
    END;
  END LOOP;

  IF v_ok THEN
    RAISE NOTICE 'pass 21: ck_invoice_subtotal_non_negative and ck_invoice_total_non_negative hold';
  ELSE
    v_failures := v_failures + 1;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 22. An invoice line is payable once per beneficiary type, across payouts.
  --     The line's label comes from its payout whatever the caller passes, a
  --     school leg of the same line is still payable, and relabelling a payout
  --     is checked too.
  -- ---------------------------------------------------------------------------

  v_bad := '';
  BEGIN
    INSERT INTO payout (beneficiary_type, beneficiary_id, school_id, period_start, period_end, gross_paisa, net_paisa)
    VALUES ('driver', v_dA, v_s1, DATE '2026-03-01', DATE '2026-03-31', 320000, 320000) RETURNING id INTO v_p1;
    INSERT INTO payout (beneficiary_type, beneficiary_id, school_id, period_start, period_end, gross_paisa, net_paisa)
    VALUES ('driver', v_dB, v_s1, DATE '2026-03-01', DATE '2026-03-31', 320000, 320000) RETURNING id INTO v_p2;
    INSERT INTO payout (beneficiary_type, beneficiary_id, school_id, period_start, period_end, gross_paisa, net_paisa)
    VALUES ('school', v_s1, v_s1, DATE '2026-03-01', DATE '2026-03-31', 40000, 40000) RETURNING id INTO v_p3;

    -- Mislabelled on purpose: the trigger must overwrite 'school' with 'driver'.
    INSERT INTO payout_line (payout_id, invoice_id, invoice_line_id, amount_paisa, beneficiary_type)
    VALUES (v_p1, v_inv, v_line, 320000, 'school') RETURNING beneficiary_type INTO v_bt;
    IF v_bt IS DISTINCT FROM 'driver' THEN
      v_bad := v_bad || format(' [line on a driver payout labelled %s]', v_bt);
    END IF;

    BEGIN
      INSERT INTO payout_line (payout_id, invoice_id, invoice_line_id, amount_paisa)
      VALUES (v_p2, v_inv, v_line, 320000) RETURNING id INTO v_id;
      DELETE FROM payout_line WHERE id = v_id;
      v_bad := v_bad || ' [the driver leg was paid twice]';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%uq_payout_line_invoice_line_id_beneficiary_type%' THEN
        v_bad := v_bad || ' [second driver payout refused for the wrong reason: ' || SQLERRM || ']';
      END IF;
    END;

    INSERT INTO payout_line (payout_id, invoice_id, invoice_line_id, amount_paisa)
    VALUES (v_p3, v_inv, v_line, 40000);

    BEGIN
      UPDATE payout SET beneficiary_type = 'driver', beneficiary_id = v_dB WHERE id = v_p3;
      UPDATE payout SET beneficiary_type = 'school', beneficiary_id = v_s1 WHERE id = v_p3;
      v_bad := v_bad || ' [relabelling a payout re-paid the driver leg]';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%uq_payout_line_invoice_line_id_beneficiary_type%' THEN
        v_bad := v_bad || ' [relabel refused for the wrong reason: ' || SQLERRM || ']';
      END IF;
    END;
  EXCEPTION WHEN OTHERS THEN
    v_bad := v_bad || ' [raised: ' || SQLERRM || ']';
  END;

  IF v_bad <> '' THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  22: double-payout guard:%s', v_bad);
  ELSE
    RAISE NOTICE 'pass 22: uq_payout_line_invoice_line_id_beneficiary_type stops a line being paid twice';
  END IF;

  -- ---------------------------------------------------------------------------
  -- Cleanup. Runs before the summary so a failing run leaves nothing behind.
  -- Order respects the RESTRICT foreign keys.
  -- ---------------------------------------------------------------------------

  BEGIN
    DELETE FROM payout_line    WHERE invoice_id = v_inv;
    DELETE FROM payout         WHERE school_id IN (v_s1, v_s2);
    DELETE FROM payment        WHERE invoice_id = v_inv;
    DELETE FROM invoice        WHERE school_id IN (v_s1, v_s2);
    DELETE FROM billing_period WHERE school_id IN (v_s1, v_s2);
    DELETE FROM trip_checkin   WHERE trip_id IN (SELECT id FROM trip WHERE route_id IN (v_r1, v_r2, v_r_other));
    DELETE FROM trip           WHERE route_id IN (v_r1, v_r2, v_r_other);
    DELETE FROM enrollment     WHERE school_id IN (v_s1, v_s2);
    DELETE FROM route          WHERE school_id IN (v_s1, v_s2);
    DELETE FROM driver_school  WHERE driver_id IN (v_dA, v_dB, v_dC);
    DELETE FROM driver         WHERE id IN (v_dA, v_dB, v_dC);
    DELETE FROM guardian       WHERE id IN (v_g1, v_g2);
    DELETE FROM student        WHERE school_id IN (v_s1, v_s2);
    DELETE FROM school         WHERE id IN (v_s1, v_s2);
    DELETE FROM app_user       WHERE id = ANY (v_auth_ids);
    DELETE FROM auth.users     WHERE id = ANY (v_auth_ids);
    RAISE NOTICE 'fixtures for run % removed', v_suffix;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'cleanup failed (all fixtures are namespaced with % and cannot collide with a later run): %',
      v_suffix, SQLERRM;
  END;

  -- ---------------------------------------------------------------------------
  -- Report
  -- ---------------------------------------------------------------------------

  IF v_failures = 0 THEN
    RAISE NOTICE 'D5: all 22 assertions passed.';
  ELSE
    RAISE EXCEPTION 'D5: % assertion(s) failed:%', v_failures, v_msg;
  END IF;
END
$test$;
