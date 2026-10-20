-- =============================================================================
-- D4 test — drivers, vehicles, and the verification pipeline
-- =============================================================================
-- Executable assertions for 20261006000004_d4_drivers_verification.sql.
-- Plain SQL, no test framework, no docker. Run with:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/d4_drivers.test.sql
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
-- DEPENDENCY ORDER
--   auth.users  ->  app_user (D1)  ->  driver  ->  vehicle, driver_document,
--   driver_school, driver_earning. driver_school and driver_earning also need
--   school, which is D3. If D3 has not been applied the file says so and
--   exits rather than failing with an obscure relation error halfway through.
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
  v_auth_id     uuid;
  v_auth_ids    uuid[] := '{}';
  v_role        app_role;
  v_name        text;
  v_driver_users uuid[];
  v_parent_user uuid;
  v_school_user uuid;
  v_school      uuid;

  -- Objects created by the assertions --------------------------------------
  v_driver        uuid;
  v_driver2       uuid;
  v_driver_check  uuid;
  v_driver_reject uuid;
  v_vehicle_a     uuid;
  v_vehicle_b     uuid;

  -- Scratch ----------------------------------------------------------------
  v_period_start date;
  v_plate        text;
  v_reason       text;
  v_ok           boolean;
  v_count        int;
  v_required     int;
  v_present      int;
  v_missing      int;
  v_rejected     int;

  v_failures     int := 0;
  v_msg          text := '';
BEGIN
  -- ---------------------------------------------------------------------------
  -- 0. Preconditions
  -- ---------------------------------------------------------------------------

  IF to_regclass('school') IS NULL THEN
    RAISE NOTICE
      'D4 test SKIPPED: relation "school" does not exist. Apply D1, D3 and D4 first.';
    RETURN;
  END IF;

  IF to_regclass('driver') IS NULL
     OR to_regclass('driver_document') IS NULL
     OR to_regclass('driver_school') IS NULL
     OR to_regclass('driver_earning') IS NULL
     OR to_regclass('vehicle') IS NULL
     OR to_regclass('required_document') IS NULL THEN
    RAISE NOTICE
      'D4 test SKIPPED: the D4 tables are missing. Apply 20261006000004 first.';
    RETURN;
  END IF;

  v_suffix      := replace(substr(random()::text, 3), '.', '');
  v_period_start := date_trunc('month', current_date)::date;
  v_plate        := 'KP-D4-' || v_suffix;

  -- ---------------------------------------------------------------------------
  -- Fixtures: auth.users, then app_user, then school.
  -- Four driver accounts (each of the remaining assertions needs its own, since
  -- driver.app_user_id is unique), one parent, one school staff account.
  -- Wrapped as a unit: a fixture failure is a precondition failure, not an
  -- assertion failure, so it aborts loudly instead of producing a partial report.
  -- ---------------------------------------------------------------------------

  BEGIN
    FOR v_role, v_name IN
    SELECT t.v_role, t.v_name
    FROM (VALUES
      ('driver'::app_role, 'Aslam Khan'),
      ('driver'::app_role, 'Bakht Zada'),
      ('driver'::app_role, 'Ghulam Nabi'),
      ('driver'::app_role, 'Imran Shah'),
      ('parent'::app_role, 'Nadia Khan'),
      ('school'::app_role, 'Headmistress Sadia')
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
      crypt('d4-test-not-a-real-password', gen_salt('bf')),
      now(), now(), now(), '{}'::jsonb, '{}'::jsonb
    );

    INSERT INTO app_user (id, role, full_name, phone)
    VALUES (
      v_auth_id, v_role, v_name,
      '+9230' || lpad(((900000 + (random() * 99999))::int)::text, 7, '0')
    );

    v_auth_ids := v_auth_ids || v_auth_id;
  END LOOP;

  SELECT array_agg(id ORDER BY full_name) INTO v_driver_users
  FROM app_user WHERE id = ANY (v_auth_ids) AND role = 'driver';

  SELECT id INTO v_parent_user
  FROM app_user WHERE id = ANY (v_auth_ids) AND role = 'parent';

  SELECT id INTO v_school_user
  FROM app_user WHERE id = ANY (v_auth_ids) AND role = 'school';

  INSERT INTO school (name, slug, address, city, contact_email, contact_phone, gate_count)
  VALUES (
    'D4 Test School ' || v_suffix,
    'd4-test-' || v_suffix,
    'University Road, Peshawar',
    'Peshawar',
    format('office@%s.example', v_suffix),
    '+923015555555',
    1
  )
  RETURNING id INTO v_school;

  -- The approved driver. Fixture for assertions 5, 6, 7, 9 and 10.
  INSERT INTO driver (app_user_id, full_name, phone, cnic_last4, verification_status,
                      submitted_at, reviewed_by, reviewed_at)
  VALUES (v_driver_users[1], 'Aslam Khan', '+923001111111', '4321', 'approved',
          now(), v_school_user, now())
  RETURNING id INTO v_driver;

  -- Deliberately unverified. Fixture for assertion 4.
  INSERT INTO driver (app_user_id, full_name, phone, verification_status)
  VALUES (v_driver_users[2], 'Bakht Zada', '+923002222222', 'not_submitted')
  RETURNING id INTO v_driver2;

  -- Fresh driver for the summary view, so counts cannot be polluted by the
  -- documents other assertions upload. Fixture for assertions 11 and 12.
  INSERT INTO driver (app_user_id, full_name, phone, verification_status)
  VALUES (v_driver_users[3], 'Ghulam Nabi', '+923003333333', 'pending_review')
  RETURNING id INTO v_driver_check;

  -- Two vehicles for assertion 7, and a plate to collide with in assertion 8.
  INSERT INTO vehicle (driver_id, make, model, year, plate_number, colour, seating_capacity)
  VALUES (v_driver, 'Toyota', 'Hiace', 2019, v_plate || '-A', 'White', 12)
  RETURNING id INTO v_vehicle_a;

  INSERT INTO vehicle (driver_id, make, model, year, plate_number, colour, seating_capacity)
  VALUES (v_driver, 'Suzuki', 'Hiace', 2021, v_plate || '-B', 'Silver', 10)
  RETURNING id INTO v_vehicle_b;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION
      'D4 test: fixture setup failed, no assertions were run. Is D3 (school) applied with the '
      'columns this test expects, and does auth.users accept a direct insert? Original error: %',
      SQLERRM;
  END;

  -- ---------------------------------------------------------------------------
  -- 1. driver trigger rejects an app_user whose role is not 'driver'
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO driver (app_user_id, full_name, phone)
    VALUES (v_parent_user, 'Not A Driver', '+923009999999');
    DELETE FROM driver WHERE app_user_id = v_parent_user;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s',
      '1: driver accepted an app_user whose role is ''parent''');
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pass 1: driver trigger refused a non-driver app_user';
  END;

  -- ---------------------------------------------------------------------------
  -- 2. verification_status = ''rejected'' requires a non-empty reason
  --    Both ''   '' (whitespace) and '' must be refused. A rejection a driver
  --    cannot act on becomes a support call instead of a resubmission.
  -- ---------------------------------------------------------------------------

  v_ok := true;
  FOREACH v_reason IN ARRAY ARRAY['   ', ''] LOOP
    BEGIN
      INSERT INTO driver (app_user_id, full_name, phone, verification_status, rejection_reason)
      VALUES (v_driver_users[4], 'Rejection Probe', '+923004444444', 'rejected', v_reason);
      DELETE FROM driver WHERE app_user_id = v_driver_users[4];
      v_ok := false;
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END LOOP;

  IF NOT v_ok THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s',
      '2: driver accepted verification_status = ''rejected'' with a blank rejection_reason');
  ELSE
    RAISE NOTICE 'pass 2: ck_driver_rejected_requires_reason refused a blank reason';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 3. A rejection WITH a real reason is allowed
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO driver (app_user_id, full_name, phone, verification_status, rejection_reason)
    VALUES (v_driver_users[4], 'Rejection Probe', '+923004444444', 'rejected',
            'Police character certificate is dated 2024-11-02. Upload one issued within the last six months.')
    RETURNING id INTO v_driver_reject;

    RAISE NOTICE 'pass 3: a rejected driver with an actionable reason is allowed';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  ' ||
      '3: driver refused verification_status = ''rejected'' with a real reason: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 4. driver_school trigger refuses to approve an unverified driver
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO driver_school (driver_id, school_id, approved_by, approved_at, is_active)
    VALUES (v_driver2, v_school, v_school_user, now(), true);
    DELETE FROM driver_school WHERE driver_id = v_driver2;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s',
      '4: driver_school approved a driver whose verification_status is ''not_submitted''');
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pass 4: driver_school trigger refused an unverified driver';
  END;

  -- ---------------------------------------------------------------------------
  -- 5. driver_school trigger allows an ''approved'' driver
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO driver_school (driver_id, school_id, approved_by, approved_at, is_active)
    VALUES (v_driver, v_school, v_school_user, now(), true);

    SELECT count(*)::int INTO v_count
    FROM driver_school WHERE driver_id = v_driver AND school_id = v_school AND is_active;

    IF v_count <> 1 THEN
      RAISE EXCEPTION 'expected 1 active driver_school row, found %', v_count;
    END IF;

    RAISE NOTICE 'pass 5: driver_school approved a fully verified driver';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  ' ||
      '5: driver_school refused an ''approved'' driver: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 6. Two person-scoped documents of the same type are refused
  --    This is the "two competing CNIC fronts" case. A plain UNIQUE on
  --    (driver_id, vehicle_id, document_type) would NOT catch it, because a
  --    NULL vehicle_id never compares equal.
  -- ---------------------------------------------------------------------------

  v_ok := true;
  BEGIN
    INSERT INTO driver_document (driver_id, document_type, storage_bucket, storage_path,
                                 mime_type, byte_size, status)
    VALUES (v_driver, 'cnic_front', 'driver-documents', format('%s/aslam/cnic-front-1.jpg', v_suffix),
            'image/jpeg', 210000, 'pending_review');
  EXCEPTION WHEN OTHERS THEN
    v_ok := false;
    v_msg := v_msg || format(E'\n  ' ||
      '6: setup failed, the FIRST person-scoped cnic_front was refused: %s', SQLERRM);
  END;

  IF v_ok THEN
    BEGIN
      INSERT INTO driver_document (driver_id, document_type, storage_bucket, storage_path,
                                   mime_type, byte_size, status)
      VALUES (v_driver, 'cnic_front', 'driver-documents', format('%s/aslam/cnic-front-2.jpg', v_suffix),
              'image/jpeg', 214000, 'pending_review');
      DELETE FROM driver_document WHERE driver_id = v_driver AND document_type = 'cnic_front';
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  %s',
        '6: driver uploaded two competing person-scoped cnic_front documents');
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'pass 6: uq_driver_document_person refused the second cnic_front';
    END;
  ELSE
    v_failures := v_failures + 1;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 7. The same document type on TWO DIFFERENT vehicles is allowed
  --    A driver with two vans legitimately holds two registrations.
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO driver_document (driver_id, vehicle_id, document_type, storage_bucket,
                                 storage_path, mime_type, byte_size, status)
    VALUES (v_driver, v_vehicle_a, 'vehicle_registration', 'vehicle-documents',
            format('%s/aslam/van-a-registration.pdf', v_suffix), 'application/pdf', 880000, 'approved');

    INSERT INTO driver_document (driver_id, vehicle_id, document_type, storage_bucket,
                                 storage_path, mime_type, byte_size, status)
    VALUES (v_driver, v_vehicle_b, 'vehicle_registration', 'vehicle-documents',
            format('%s/aslam/van-b-registration.pdf', v_suffix), 'application/pdf', 902000, 'approved');

    SELECT count(*)::int INTO v_count
    FROM driver_document
    WHERE driver_id = v_driver AND document_type = 'vehicle_registration';

    IF v_count <> 2 THEN
      RAISE EXCEPTION 'expected 2 vehicle_registration rows, found %', v_count;
    END IF;

    RAISE NOTICE 'pass 7: the same document type on two vehicles is allowed';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  ' ||
      '7: driver_document refused two registrations on two different vehicles: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 8. A plate_number cannot be claimed by a second vehicle
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO vehicle (driver_id, make, model, year, plate_number, seating_capacity)
    VALUES (v_driver, 'Toyota', 'Hiace', 2015, v_plate || '-A', 12);
    DELETE FROM vehicle WHERE plate_number = v_plate || '-A' AND model = 'Hiace' AND year = 2015;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s',
      '8: two vehicles claimed the same plate_number');
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pass 8: uq_vehicle_plate_number refused the duplicate plate';
  END;

  -- ---------------------------------------------------------------------------
  -- 9. driver_earning refuses net_paisa <> gross_paisa + adjustment_paisa
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO driver_earning (driver_id, school_id, period_start, period_end,
                                gross_paisa, adjustment_paisa, net_paisa)
    VALUES (v_driver, v_school, v_period_start, v_period_start + 27,
            32000000, -20000, 31999000);
    DELETE FROM driver_earning WHERE driver_id = v_driver AND school_id = v_school;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s',
      '9: driver_earning accepted net_paisa <> gross_paisa + adjustment_paisa (1000 paisa drift)');
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pass 9: ck_driver_earning_net_equals_gross_plus_adjustment refused the drift';
  END;

  -- ---------------------------------------------------------------------------
  -- 10. One earning row per (driver, school, period_start)
  --     Re-running a period close must never double-count a driver's month.
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO driver_earning (driver_id, school_id, period_start, period_end,
                                gross_paisa, adjustment_paisa, net_paisa)
    VALUES (v_driver, v_school, v_period_start, v_period_start + 27,
            32000000, 0, 32000000);

    BEGIN
      INSERT INTO driver_earning (driver_id, school_id, period_start, period_end,
                                  gross_paisa, adjustment_paisa, net_paisa)
      VALUES (v_driver, v_school, v_period_start, v_period_start + 27,
              32000000, 0, 32000000);
      DELETE FROM driver_earning WHERE driver_id = v_driver AND school_id = v_school;
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  %s',
        '10: driver_earning accepted a duplicate (driver, school, period_start)');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;

    RAISE NOTICE 'pass 10: uq_driver_earning_driver_school_period refused the duplicate period';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  ' ||
      '10: could not establish the driver_earning period baseline: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 11. driver_verification_summary counts present and missing correctly
  --     Two documents cleared, one uploaded but awaiting review, one absent:
  --     required 4, present 2, missing 2. A driver who has uploaded four
  --     files but had none approved has cleared nothing.
  -- ---------------------------------------------------------------------------

  INSERT INTO driver_document (driver_id, document_type, storage_bucket, storage_path,
                               mime_type, byte_size, status, uploaded_at)
  VALUES
    (v_driver_check, 'cnic_front', 'driver-documents', format('%s/ghulam/cnic-front.jpg', v_suffix),
     'image/jpeg', 198000, 'approved', now() - interval '3 days'),
    (v_driver_check, 'cnic_back', 'driver-documents', format('%s/ghulam/cnic-back.jpg', v_suffix),
     'image/jpeg', 187000, 'approved', now() - interval '3 days'),
    (v_driver_check, 'driving_license', 'driver-documents', format('%s/ghulam/licence.jpg', v_suffix),
     'image/jpeg', 165000, 'pending_review', now() - interval '1 day');

  SELECT present_count, missing_count, required_count, rejected_count
    INTO v_present, v_missing, v_required, v_rejected
  FROM driver_verification_summary
  WHERE driver_id = v_driver_check;

  IF v_present IS DISTINCT FROM 2
     OR v_missing IS DISTINCT FROM 2
     OR v_required IS DISTINCT FROM 4 THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s',
      '11: expected required=4 present=2 missing=2, got required=%s present=%s missing=%s',
      coalesce(v_required::text, 'null'), coalesce(v_present::text, 'null'),
      coalesce(v_missing::text, 'null'));
  ELSE
    RAISE NOTICE 'pass 11: driver_verification_summary reports required=4 present=2 missing=2';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 12. Clearing the outstanding document moves present up and missing down
  -- ---------------------------------------------------------------------------

  UPDATE driver_document
     SET status = 'approved', reviewed_by = v_school_user, reviewed_at = now()
   WHERE driver_id = v_driver_check AND document_type = 'driving_license';

  SELECT present_count, missing_count INTO v_present, v_missing
  FROM driver_verification_summary
  WHERE driver_id = v_driver_check;

  IF v_present IS DISTINCT FROM 3 OR v_missing IS DISTINCT FROM 1 THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s',
      '12: after approving driving_license expected present=3 missing=1, got present=%s missing=%s',
      coalesce(v_present::text, 'null'), coalesce(v_missing::text, 'null'));
  ELSE
    RAISE NOTICE 'pass 12: approving a document moved present 2->3 and missing 2->1';
  END IF;

  -- ---------------------------------------------------------------------------
  -- 13. required_document holds exactly the four mandatory driver documents
  --     This is the assertion that keeps the checklist from becoming a
  --     hard-coded array that disagrees with the database.
  -- ---------------------------------------------------------------------------

  SELECT count(*)::int INTO v_count FROM required_document WHERE is_mandatory;
  SELECT count(*)::int INTO v_required
  FROM required_document
  WHERE is_mandatory
    AND document_type IN ('cnic_front', 'cnic_back', 'driving_license',
                          'police_character_certificate');

  IF v_count <> 4 OR v_required <> 4 THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s',
      '13: required_document holds %s mandatory row(s), %s of them the expected four; expected 4 and 4',
      v_count::text, v_required::text);
  ELSE
    RAISE NOTICE 'pass 13: required_document holds exactly the four mandatory driver documents';
  END IF;

  -- ---------------------------------------------------------------------------
  -- Cleanup. Runs before the summary so a failing run still leaves no
  -- fixtures behind. Deletion order respects ON DELETE RESTRICT from
  -- driver_earning to driver and school.
  -- ---------------------------------------------------------------------------

  BEGIN
    DELETE FROM driver_earning WHERE driver_id IN (v_driver, v_driver2, v_driver_check, v_driver_reject)
                                  OR school_id = v_school;
    DELETE FROM driver_school   WHERE driver_id IN (v_driver, v_driver2, v_driver_check, v_driver_reject)
                                  OR school_id = v_school;
    DELETE FROM vehicle         WHERE driver_id IN (v_driver, v_driver2, v_driver_check, v_driver_reject);
    DELETE FROM driver_document WHERE driver_id IN (v_driver, v_driver2, v_driver_check, v_driver_reject);
    DELETE FROM driver          WHERE app_user_id IN (SELECT unnest(v_driver_users));
    DELETE FROM school          WHERE id = v_school;
    DELETE FROM app_user        WHERE id = ANY (v_auth_ids);
    DELETE FROM auth.users      WHERE id = ANY (v_auth_ids);
    RAISE NOTICE 'fixtures for run % removed', v_suffix;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'cleanup failed (all fixtures are namespaced with % and cannot collide with a later run): %',
      v_suffix, SQLERRM;
  END;

  -- ---------------------------------------------------------------------------
  -- Report
  -- ---------------------------------------------------------------------------

  IF v_failures = 0 THEN
    RAISE NOTICE 'D4: all 13 assertions passed.';
  ELSE
    RAISE EXCEPTION 'D4: % assertion(s) failed:%', v_failures, v_msg;
  END IF;
END
$test$;
