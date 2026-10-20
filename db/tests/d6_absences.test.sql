-- =============================================================================
-- D6 test — absences, the child_absent hook, the driver's stop list, outbox
-- =============================================================================
-- Executable assertions for 20261006000006_d6_absences.sql.
-- Plain SQL, no test framework, no docker. Run with:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/d6_absences.test.sql
--
-- STYLE (same as d3/d4/d5)
--   Every assertion is ATTEMPTED, each in its own BEGIN ... EXCEPTION block
--   (a savepoint). Failures accumulate and are reported in ONE exception at
--   the end. Negative cases assert WHICH constraint or guard refused the row
--   by checking SQLERRM (and SQLSTATE where the contract names one). When a
--   statement that should have failed succeeds, its row is removed again
--   before the failure is counted.
--
-- DEPENDENCY ORDER
--   auth.users -> app_user -> school -> student, guardian -> driver, vehicle,
--   driver_school -> route, route_stop, route_manifest -> enrollment -> trip
--   -> absence -> trip_checkin, notification.
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
  v_driver_user uuid;
  v_parents     uuid[];
  v_school_user uuid;

  v_s1          uuid;
  v_st1         uuid;   -- reported absent; stop 1
  v_st2         uuid;   -- rides normally; stop 2
  v_g1          uuid;   -- guardian of st1
  v_g2          uuid;   -- guardian of st2, NOT of st1

  v_dA          uuid;
  v_vA          uuid;
  v_r1          uuid;
  v_stop1       uuid;
  v_stop2       uuid;
  v_e1          uuid;
  v_trip        uuid;   -- on v_day, boarding

  v_day         date := DATE '2031-09-15';   -- st1 absent
  v_day_cancel  date := DATE '2031-09-16';   -- st1 absent, then cancelled

  v_a1          uuid;   -- st1 on v_day, cancelled in 3
  v_a2          uuid;   -- st1 on v_day, the resubmission (active)
  v_a3          uuid;   -- st1 on v_day_cancel, cancelled

  -- Scratch ----------------------------------------------------------------
  v_id          uuid;
  v_ok          boolean;
  v_count       int;
  v_status      absence_status;
  v_ts          timestamptz;
  v_result      checkin_result;
  v_bad         text;
  v_row         record;

  v_failures    int := 0;
  v_msg         text := '';
BEGIN
  -- ---------------------------------------------------------------------------
  -- 0. Preconditions
  -- ---------------------------------------------------------------------------

  IF to_regclass('absence') IS NULL OR to_regclass('notification') IS NULL
     OR to_regclass('v_trip_stop_attendance') IS NULL
     OR to_regprocedure('record_trip_checkin(uuid, checkin_method, text, uuid, uuid)') IS NULL THEN
    RAISE NOTICE 'D6 test SKIPPED: the D6 (or D5) objects are missing. Apply 20261006000006 first.';
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
        ('driver'::app_role, 'Fazal Rabbi'),
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
        crypt('d6-test-not-a-real-password', gen_salt('bf')),
        now(), now(), now(), '{}'::jsonb, '{}'::jsonb
      );

      INSERT INTO app_user (id, role, full_name, phone)
      VALUES (v_auth_id, v_role, v_name,
              '+9230' || lpad(((900000 + (random() * 99999))::int)::text, 7, '0'));

      v_auth_ids := v_auth_ids || v_auth_id;
    END LOOP;

    SELECT id INTO v_driver_user
      FROM app_user WHERE id = ANY (v_auth_ids) AND role = 'driver';
    SELECT array_agg(id ORDER BY full_name) INTO v_parents
      FROM app_user WHERE id = ANY (v_auth_ids) AND role = 'parent';
    SELECT id INTO v_school_user
      FROM app_user WHERE id = ANY (v_auth_ids) AND role = 'school';

    INSERT INTO school (name, slug) VALUES ('D6 School ' || v_suffix, 'd6-one-' || v_suffix)
    RETURNING id INTO v_s1;

    INSERT INTO student (full_name, school_id) VALUES ('Ayesha Khan', v_s1) RETURNING id INTO v_st1;
    INSERT INTO student (full_name, school_id) VALUES ('Bilal Khan',  v_s1) RETURNING id INTO v_st2;

    INSERT INTO guardian (app_user_id, student_id, relationship, is_primary, consent_at, consent_version)
    VALUES (v_parents[1], v_st1, 'mother', true, now(), '2026-01-consent-v3')
    RETURNING id INTO v_g1;
    INSERT INTO guardian (app_user_id, student_id, relationship, is_primary, consent_at, consent_version)
    VALUES (v_parents[2], v_st2, 'father', true, now(), '2026-01-consent-v3')
    RETURNING id INTO v_g2;

    INSERT INTO driver (app_user_id, full_name, phone, verification_status)
    VALUES (v_driver_user, 'Fazal Rabbi', '+923004444444', 'approved') RETURNING id INTO v_dA;
    INSERT INTO vehicle (driver_id, plate_number, seating_capacity, is_vehicle_verified)
    VALUES (v_dA, 'KP-D6-A-' || v_suffix, 12, true) RETURNING id INTO v_vA;
    INSERT INTO driver_school (driver_id, school_id, approved_by, approved_at, is_active)
    VALUES (v_dA, v_s1, v_school_user, now(), true);

    INSERT INTO route (school_id, name, driver_id, vehicle_id)
    VALUES (v_s1, 'Hayatabad Morning', v_dA, v_vA) RETURNING id INTO v_r1;

    INSERT INTO route_stop (route_id, stop_order, name, location)
    VALUES (v_r1, 1, 'Phase 3 Chowk', ST_SetSRID(ST_MakePoint(71.4410, 33.9940), 4326)::geography)
    RETURNING id INTO v_stop1;
    INSERT INTO route_stop (route_id, stop_order, name, location)
    VALUES (v_r1, 2, 'Phase 5 Gate', ST_SetSRID(ST_MakePoint(71.4500, 33.9900), 4326)::geography)
    RETURNING id INTO v_stop2;

    INSERT INTO route_manifest (route_id, route_stop_id, student_id) VALUES (v_r1, v_stop1, v_st1);
    INSERT INTO route_manifest (route_id, route_stop_id, student_id) VALUES (v_r1, v_stop2, v_st2);

    INSERT INTO enrollment (student_id, school_id, guardian_id, status, starts_on,
                            route_id, fee_paisa, driver_bps, school_bps, rawaan_bps)
    VALUES (v_st1, v_s1, v_g1, 'active', DATE '2031-01-01', v_r1, 400000, 8000, 1000, 1000)
    RETURNING id INTO v_e1;

    INSERT INTO trip (route_id, driver_id, vehicle_id, trip_date)
    VALUES (v_r1, v_dA, v_vA, v_day) RETURNING id INTO v_trip;
    PERFORM transition_trip(v_trip, 'driver_en_route');
    PERFORM transition_trip(v_trip, 'arrived_pickup');
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'D6 test: fixture setup failed, no assertions were run. Original error: %', SQLERRM;
  END;

  -- ---------------------------------------------------------------------------
  -- 1. Only a guardian of the child may submit: g2 (st2's father) cannot
  --    report st1 absent. 23514, from trg_absence_rules.
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO absence (student_id, absent_on, guardian_id)
    VALUES (v_st1, v_day, v_g2) RETURNING id INTO v_id;
    DELETE FROM absence WHERE id = v_id;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s', '1: a guardian of another child submitted an absence');
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> '23514' OR SQLERRM NOT LIKE '%is not a guardian of student%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  1: refused for the wrong reason (%s): %s', SQLSTATE, SQLERRM);
    ELSE
      RAISE NOTICE 'pass 1: trg_absence_rules refused a non-guardian with 23514';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 2. The child's own guardian may submit, and it starts as submitted
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO absence (student_id, absent_on, guardian_id, reason)
    VALUES (v_st1, v_day, v_g1, 'Fever') RETURNING id, status INTO v_a1, v_status;
    IF v_status IS DISTINCT FROM 'submitted' THEN
      RAISE EXCEPTION 'expected status submitted, got %', v_status;
    END IF;
    RAISE NOTICE 'pass 2: the child''s guardian submitted an absence';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  2: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 3. A second active absence for the same child and date is refused
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO absence (student_id, absent_on, guardian_id)
    VALUES (v_st1, v_day, v_g1) RETURNING id INTO v_id;
    DELETE FROM absence WHERE id = v_id;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s', '3: a duplicate active absence was accepted');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%uq_absence_one_active_per_student_date%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  3: refused for the wrong reason: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 3: uq_absence_one_active_per_student_date refused a duplicate';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 4. Cancel, then resubmit the same date: allowed. cancelled_at is stamped,
  --    and the cancelled row cannot be revived.
  -- ---------------------------------------------------------------------------

  BEGIN
    UPDATE absence SET status = 'cancelled' WHERE id = v_a1 RETURNING cancelled_at INTO v_ts;
    IF v_ts IS NULL THEN
      RAISE EXCEPTION 'cancelled_at was not stamped';
    END IF;

    INSERT INTO absence (student_id, absent_on, guardian_id)
    VALUES (v_st1, v_day, v_g1) RETURNING id INTO v_a2;

    BEGIN
      UPDATE absence SET status = 'submitted' WHERE id = v_a1;
      RAISE EXCEPTION 'a cancelled absence was revived';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%illegal status change cancelled -> submitted%' THEN
        RAISE EXCEPTION 'revival refused for the wrong reason: %', SQLERRM;
      END IF;
    END;

    SELECT count(*)::int INTO v_count FROM absence WHERE student_id = v_st1 AND absent_on = v_day;
    IF v_count <> 2 THEN
      RAISE EXCEPTION 'expected the cancelled row and the resubmission (2 rows), found %', v_count;
    END IF;
    RAISE NOTICE 'pass 4: cancel is a status change, resubmission after cancel is allowed, cancelled is terminal';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  4: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 5. student_id / absent_on / guardian_id are immutable
  -- ---------------------------------------------------------------------------

  BEGIN
    UPDATE absence SET absent_on = v_day + 1 WHERE id = v_a2;
    UPDATE absence SET absent_on = v_day WHERE id = v_a2;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s', '5: an absence was moved to another date');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%are immutable%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  5: refused for the wrong reason: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 5: an absence cannot be moved to another date or child';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 6. is_student_absent(): true for an active absence, false for a cancelled
  --    one, another date, and another child.
  -- ---------------------------------------------------------------------------

  v_bad := '';
  BEGIN
    INSERT INTO absence (student_id, absent_on, guardian_id)
    VALUES (v_st1, v_day_cancel, v_g1) RETURNING id INTO v_a3;
    IF NOT is_student_absent(v_st1, v_day_cancel) THEN v_bad := v_bad || ' [submitted not absent]'; END IF;
    UPDATE absence SET status = 'cancelled' WHERE id = v_a3;

    IF NOT is_student_absent(v_st1, v_day)         THEN v_bad := v_bad || ' [active absence not seen]'; END IF;
    IF is_student_absent(v_st1, v_day_cancel)      THEN v_bad := v_bad || ' [cancelled absence counted]'; END IF;
    IF is_student_absent(v_st1, v_day + 30)        THEN v_bad := v_bad || ' [other date counted]'; END IF;
    IF is_student_absent(v_st2, v_day)             THEN v_bad := v_bad || ' [other child counted]'; END IF;

    UPDATE absence SET status = 'acknowledged', acknowledged_by = v_driver_user WHERE id = v_a2;
    IF NOT is_student_absent(v_st1, v_day)         THEN v_bad := v_bad || ' [acknowledged not absent]'; END IF;
  EXCEPTION WHEN OTHERS THEN
    v_bad := v_bad || ' [raised: ' || SQLERRM || ']';
  END;

  IF v_bad <> '' THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  6: is_student_absent wrong:%s', v_bad);
  ELSE
    RAISE NOTICE 'pass 6: is_student_absent honours status, date and child';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 7. Check-in on an absent child records child_absent (through D5's
  --    unmodified record_trip_checkin); a present child still boards.
  -- ---------------------------------------------------------------------------

  v_bad := '';
  BEGIN
    v_result := record_trip_checkin(v_trip, 'manual_override', NULL, v_st1, v_driver_user);
    IF v_result IS DISTINCT FROM 'child_absent' THEN v_bad := v_bad || ' [absent child: ' || v_result || ']'; END IF;

    SELECT count(*)::int INTO v_count FROM trip_checkin
     WHERE trip_id = v_trip AND student_id = v_st1 AND result = 'child_absent';
    IF v_count <> 1 THEN v_bad := v_bad || format(' [expected 1 child_absent row, found %s]', v_count); END IF;

    v_result := record_trip_checkin(v_trip, 'manual_override', NULL, v_st2, v_driver_user);
    IF v_result IS DISTINCT FROM 'success' THEN v_bad := v_bad || ' [present child: ' || v_result || ']'; END IF;
  EXCEPTION WHEN OTHERS THEN
    v_bad := v_bad || ' [raised: ' || SQLERRM || ']';
  END;

  IF v_bad <> '' THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  7: check-in:%s', v_bad);
  ELSE
    RAISE NOTICE 'pass 7: record_trip_checkin recorded child_absent for the absent child and success for the other';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 8. The driver's stop list: stop 1 (only st1, absent) is skippable,
  --    stop 2 (st2, present) is not.
  -- ---------------------------------------------------------------------------

  v_bad := '';
  BEGIN
    FOR v_row IN
      SELECT * FROM v_trip_stop_attendance WHERE trip_id = v_trip ORDER BY stop_order
    LOOP
      IF v_row.route_stop_id = v_stop1
         AND NOT (v_row.rider_count = 1 AND v_row.absent_count = 1 AND v_row.is_skippable) THEN
        v_bad := v_bad || format(' [stop 1: %s/%s skippable=%s]', v_row.absent_count, v_row.rider_count, v_row.is_skippable);
      ELSIF v_row.route_stop_id = v_stop2
         AND NOT (v_row.rider_count = 1 AND v_row.absent_count = 0 AND NOT v_row.is_skippable) THEN
        v_bad := v_bad || format(' [stop 2: %s/%s skippable=%s]', v_row.absent_count, v_row.rider_count, v_row.is_skippable);
      END IF;
    END LOOP;

    SELECT count(*)::int INTO v_count FROM v_trip_stop_attendance WHERE trip_id = v_trip;
    IF v_count <> 2 THEN v_bad := v_bad || format(' [expected 2 stops, found %s]', v_count); END IF;
  EXCEPTION WHEN OTHERS THEN
    v_bad := v_bad || ' [raised: ' || SQLERRM || ']';
  END;

  IF v_bad <> '' THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  8: v_trip_stop_attendance wrong:%s', v_bad);
  ELSE
    RAISE NOTICE 'pass 8: v_trip_stop_attendance marks the all-absent stop skippable';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 9. The driver was told, pointer-only: one absence_submitted per absence
  --    (a1, a2, a3) and one absence_cancelled per cancellation (a1, a3).
  --    The payload is ids and a date, nothing else.
  -- ---------------------------------------------------------------------------

  v_bad := '';
  BEGIN
    SELECT count(*)::int INTO v_count FROM notification
     WHERE recipient_app_user_id = v_driver_user AND kind = 'absence_submitted';
    IF v_count <> 3 THEN v_bad := v_bad || format(' [expected 3 absence_submitted, found %s]', v_count); END IF;

    SELECT count(*)::int INTO v_count FROM notification
     WHERE recipient_app_user_id = v_driver_user AND kind = 'absence_cancelled';
    IF v_count <> 2 THEN v_bad := v_bad || format(' [expected 2 absence_cancelled, found %s]', v_count); END IF;

    SELECT count(*)::int INTO v_count FROM notification
     WHERE recipient_app_user_id = v_driver_user
       AND (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(payload) AS k)
           IS DISTINCT FROM ARRAY['absence_id', 'absent_on', 'student_id'];
    IF v_count <> 0 THEN v_bad := v_bad || format(' [%s payload(s) carry more than ids]', v_count); END IF;

    SELECT count(*)::int INTO v_count FROM notification
     WHERE recipient_app_user_id = ANY (v_parents);
    IF v_count <> 0 THEN v_bad := v_bad || ' [a guardian was notified of their own absence]'; END IF;
  EXCEPTION WHEN OTHERS THEN
    v_bad := v_bad || ' [raised: ' || SQLERRM || ']';
  END;

  IF v_bad <> '' THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  9: notification outbox wrong:%s', v_bad);
  ELSE
    RAISE NOTICE 'pass 9: trg_absence_notify queued pointer-only notifications for the driver';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 10. An absence is not billing-relevant: the enrollment stays billable for
  --     the month that contains it.
  -- ---------------------------------------------------------------------------

  BEGIN
    IF NOT is_billable(v_e1, DATE '2031-09-01', DATE '2031-09-30') THEN
      RAISE EXCEPTION 'enrollment became non-billable in a month with an absence';
    END IF;
    RAISE NOTICE 'pass 10: an absence does not affect is_billable()';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  10: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- Cleanup. Runs before the summary so a failing run leaves nothing behind.
  -- Order respects the RESTRICT foreign keys.
  -- ---------------------------------------------------------------------------

  BEGIN
    DELETE FROM notification   WHERE recipient_app_user_id = ANY (v_auth_ids);
    DELETE FROM trip_checkin   WHERE trip_id IN (SELECT id FROM trip WHERE route_id = v_r1);
    DELETE FROM absence        WHERE student_id IN (v_st1, v_st2);
    DELETE FROM trip           WHERE route_id = v_r1;
    DELETE FROM enrollment     WHERE school_id = v_s1;
    DELETE FROM route          WHERE school_id = v_s1;
    DELETE FROM driver_school  WHERE driver_id = v_dA;
    DELETE FROM driver         WHERE id = v_dA;
    DELETE FROM guardian       WHERE id IN (v_g1, v_g2);
    DELETE FROM student        WHERE school_id = v_s1;
    DELETE FROM school         WHERE id = v_s1;
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
    RAISE NOTICE 'D6: all 10 assertions passed.';
  ELSE
    RAISE EXCEPTION 'D6: % assertion(s) failed:%', v_failures, v_msg;
  END IF;
END
$test$;
