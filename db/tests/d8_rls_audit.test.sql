-- =============================================================================
-- D8 test — RLS, grants, guarded functions, audit log, role-change guard
-- =============================================================================
-- Executable assertions for 20261006000008_d8_rls_audit.sql. Same style as
-- d3/d4: one DO block, every assertion in its own BEGIN ... EXCEPTION
-- sub-block, failures accumulated and reported in ONE exception at the end,
-- negative cases checked against the SQLSTATE and the message that names the
-- rule, fixtures namespaced with a random() suffix and removed before the
-- report.
--
-- THE WORLD: two schools (A, B). Staff A (school A, can_view_earnings) and
-- staff B (school B, earnings-blind). Parent 1 with two children at A, one of
-- them manifested on driver 1's route; parent 2 with one child at B. Driver 1
-- approved, linked to A, driving route A in a verified van; driver 2 not yet
-- submitted. An admin. Invoices, lines, splits, payments, payouts, earnings,
-- one trip.
--
-- Each role is impersonated exactly as Supabase does it:
--   PERFORM set_config('request.jwt.claim.sub', <uuid>, true);
--   SET LOCAL ROLE authenticated;   ...   RESET ROLE;
-- and SET LOCAL ROLE anon (no sub) for the public.
--
-- audit_log rows written by this test are NOT cleaned up: the table refuses
-- DELETE by design. They are tagged by the fixture row ids and harmless.
-- =============================================================================

SET search_path TO public, extensions;

DO $test$
DECLARE
  v_suffix    text;
  v_auth_id   uuid;
  v_auth_ids  uuid[] := '{}';
  v_role      app_role;
  v_name      text;

  u_admin uuid; u_par1 uuid; u_par2 uuid; u_staff_a uuid; u_staff_b uuid;
  u_drv1  uuid; u_drv2 uuid;

  s_a uuid; s_b uuid;
  st1 uuid; st1b uuid; st2 uuid;
  g1 uuid; g1b uuid; g2 uuid;
  d1 uuid; d2 uuid; v1 uuid;
  doc1 uuid; doc2 uuid;
  ra uuid; stop_a uuid;
  e1 uuid; e1b uuid; e2 uuid;
  bp_a uuid; bp_b uuid;
  i1 uuid; i2 uuid; l1 uuid; l2 uuid;
  p1 uuid; p2 uuid; p_new uuid;
  po_d1 uuid; po_sa uuid; po_sb uuid;
  de1 uuid; de2 uuid;
  t1 uuid;
  adj uuid;
  ab1 uuid;

  v_students uuid[];
  v_fix_tables text[];
  v_rel      text;
  v_n        bigint;
  v_n2       bigint;
  v_ids      uuid[];
  v_text     text;
  v_token    text;
  v_status   text;
  v_bool     boolean;
  v_loc      geography;
  v_earn     bigint;
  v_audit    record;
  v_fn       text;
  v_secdef   boolean;
  v_vol      char;
  v_config   text[];
  v_trip     trip;
  v_period   date := DATE '2031-01-01';
  v_trip_on  date := DATE '2031-06-01';

  v_failures int := 0;
  v_msg      text := '';
BEGIN
  IF to_regclass('audit_log') IS NULL THEN
    RAISE NOTICE 'D8 test SKIPPED: relation "audit_log" does not exist. Apply D8 first.';
    RETURN;
  END IF;

  v_suffix := replace(substr(random()::text, 3), '.', '');

  -- ---------------------------------------------------------------------------
  -- Fixtures (as the migration owner, which bypasses RLS). A fixture failure
  -- is a precondition failure and aborts loudly.
  -- ---------------------------------------------------------------------------

  BEGIN
    FOR v_role, v_name IN
      SELECT t.r, t.n FROM (VALUES
        ('admin'::app_role,  'Rawaan Ops'),
        ('parent'::app_role, 'Nasreen Bibi'),
        ('parent'::app_role, 'Zahid Iqbal'),
        ('school'::app_role, 'Staff Alpha'),
        ('school'::app_role, 'Staff Beta'),
        ('driver'::app_role, 'Aslam Khan'),
        ('driver'::app_role, 'Bakht Zada')
      ) AS t(r, n)
    LOOP
      v_auth_id := gen_random_uuid();
      INSERT INTO auth.users (id, aud, role, email, created_at, updated_at,
                              raw_app_meta_data, raw_user_meta_data)
      VALUES (v_auth_id, 'authenticated', 'authenticated',
              format('%s@%s.example', lower(replace(v_name, ' ', '.')), v_suffix),
              now(), now(), '{}'::jsonb, '{}'::jsonb);
      INSERT INTO app_user (id, role, full_name, phone)
      VALUES (v_auth_id, v_role, v_name, '+92300' || lpad((random() * 9999999)::int::text, 7, '0'));
      v_auth_ids := v_auth_ids || v_auth_id;
    END LOOP;
    u_admin := v_auth_ids[1]; u_par1 := v_auth_ids[2]; u_par2 := v_auth_ids[3];
    u_staff_a := v_auth_ids[4]; u_staff_b := v_auth_ids[5];
    u_drv1 := v_auth_ids[6]; u_drv2 := v_auth_ids[7];

    INSERT INTO school (name, slug) VALUES ('D8 School A ' || v_suffix, 'd8-a-' || v_suffix) RETURNING id INTO s_a;
    INSERT INTO school (name, slug) VALUES ('D8 School B ' || v_suffix, 'd8-b-' || v_suffix) RETURNING id INTO s_b;

    INSERT INTO school_admin (school_id, app_user_id, role_at_school, can_approve_drivers, can_view_earnings)
    VALUES (s_a, u_staff_a, 'accountant', true, true);
    INSERT INTO school_admin (school_id, app_user_id, role_at_school, can_approve_drivers, can_view_earnings)
    VALUES (s_b, u_staff_b, 'principal', false, false);

    INSERT INTO student (full_name, school_id, home_address, home_location, pickup_location)
    VALUES ('Ayesha Khan', s_a, 'House 1, Street 2, Hayatabad',
            ST_SetSRID(ST_MakePoint(71.5249, 34.03307), 4326)::geography,
            ST_SetSRID(ST_MakePoint(71.5250, 34.03310), 4326)::geography)
    RETURNING id INTO st1;
    INSERT INTO student (full_name, school_id, home_address, home_location)
    VALUES ('Bilal Khan', s_a, 'House 1, Street 2, Hayatabad',
            ST_SetSRID(ST_MakePoint(71.5249, 34.03307), 4326)::geography)
    RETURNING id INTO st1b;
    INSERT INTO student (full_name, school_id, home_address, home_location)
    VALUES ('Omar Shah', s_b, 'Flat 9, Saddar',
            ST_SetSRID(ST_MakePoint(71.5400, 34.0000), 4326)::geography)
    RETURNING id INTO st2;
    v_students := ARRAY[st1, st1b, st2];

    INSERT INTO guardian (app_user_id, student_id, relationship, is_primary, consent_at, consent_version)
    VALUES (u_par1, st1, 'mother', true, now(), '2026-01-consent-v3') RETURNING id INTO g1;
    INSERT INTO guardian (app_user_id, student_id, relationship, is_primary, consent_at, consent_version)
    VALUES (u_par1, st1b, 'mother', true, now(), '2026-01-consent-v3') RETURNING id INTO g1b;
    INSERT INTO guardian (app_user_id, student_id, relationship, is_primary, consent_at, consent_version)
    VALUES (u_par2, st2, 'father', true, now(), '2026-01-consent-v3') RETURNING id INTO g2;

    INSERT INTO driver (app_user_id, full_name, phone, verification_status)
    VALUES (u_drv1, 'Aslam Khan', '+923001110000', 'approved') RETURNING id INTO d1;
    INSERT INTO driver (app_user_id, full_name, phone, verification_status)
    VALUES (u_drv2, 'Bakht Zada', '+923002220000', 'not_submitted') RETURNING id INTO d2;

    INSERT INTO vehicle (driver_id, plate_number, seating_capacity, is_vehicle_verified)
    VALUES (d1, 'KP-D8-' || v_suffix, 12, true) RETURNING id INTO v1;

    INSERT INTO driver_document (driver_id, document_type, storage_bucket, storage_path, mime_type, byte_size)
    VALUES (d1, 'cnic_front', 'driver-documents', 'd8/' || v_suffix || '/d1-cnic.jpg', 'image/jpeg', 200000)
    RETURNING id INTO doc1;
    INSERT INTO driver_document (driver_id, document_type, storage_bucket, storage_path, mime_type, byte_size)
    VALUES (d2, 'cnic_front', 'driver-documents', 'd8/' || v_suffix || '/d2-cnic.jpg', 'image/jpeg', 210000)
    RETURNING id INTO doc2;

    INSERT INTO driver_school (driver_id, school_id, approved_by, approved_at, is_active)
    VALUES (d1, s_a, u_staff_a, now(), true);
    INSERT INTO driver_school (driver_id, school_id, is_active)
    VALUES (d2, s_b, true);

    INSERT INTO route (school_id, name, driver_id, vehicle_id)
    VALUES (s_a, 'D8 Hayatabad Morning ' || v_suffix, d1, v1) RETURNING id INTO ra;
    INSERT INTO route_stop (route_id, stop_order, name, location)
    VALUES (ra, 1, 'Phase 3 Chowk', ST_SetSRID(ST_MakePoint(71.4410, 33.9940), 4326)::geography)
    RETURNING id INTO stop_a;
    INSERT INTO route_manifest (route_id, route_stop_id, student_id) VALUES (ra, stop_a, st1);

    INSERT INTO enrollment (student_id, school_id, guardian_id, starts_on, route_id,
                            fee_paisa, driver_bps, school_bps, rawaan_bps)
    VALUES (st1, s_a, g1, DATE '2031-01-01', ra, 400000, 8000, 1000, 1000) RETURNING id INTO e1;
    INSERT INTO enrollment (student_id, school_id, guardian_id, starts_on,
                            fee_paisa, driver_bps, school_bps, rawaan_bps)
    VALUES (st1b, s_a, g1b, DATE '2031-01-01', 400000, 8000, 1000, 1000) RETURNING id INTO e1b;
    INSERT INTO enrollment (student_id, school_id, guardian_id, starts_on,
                            fee_paisa, driver_bps, school_bps, rawaan_bps)
    VALUES (st2, s_b, g2, DATE '2031-01-01', 400000, 8000, 1000, 1000) RETURNING id INTO e2;

    INSERT INTO billing_period (school_id, period_start, period_end, period_label)
    VALUES (s_a, v_period, DATE '2031-01-31', '2031-01') RETURNING id INTO bp_a;
    INSERT INTO billing_period (school_id, period_start, period_end, period_label)
    VALUES (s_b, v_period, DATE '2031-01-31', '2031-01') RETURNING id INTO bp_b;

    INSERT INTO invoice (enrollment_id, billing_period_id, guardian_id, school_id, status,
                         subtotal_paisa, total_paisa, issued_at, paid_at)
    VALUES (e1, bp_a, g1, s_a, 'paid', 400000, 400000, now(), now()) RETURNING id INTO i1;
    INSERT INTO invoice (enrollment_id, billing_period_id, guardian_id, school_id, status,
                         subtotal_paisa, total_paisa, issued_at)
    VALUES (e2, bp_b, g2, s_b, 'issued', 400000, 400000, now()) RETURNING id INTO i2;

    INSERT INTO invoice_line (invoice_id, line_type, description, unit_paisa, amount_paisa,
                              driver_bps, school_bps, rawaan_bps)
    VALUES (i1, 'transport_fee', 'Transport, January 2031', 400000, 400000, 8000, 1000, 1000)
    RETURNING id INTO l1;
    INSERT INTO invoice_line (invoice_id, line_type, description, unit_paisa, amount_paisa,
                              driver_bps, school_bps, rawaan_bps)
    VALUES (i2, 'transport_fee', 'Transport, January 2031', 400000, 400000, 8000, 1000, 1000)
    RETURNING id INTO l2;

    INSERT INTO split_allocation (invoice_line_id, beneficiary_type, beneficiary_id, amount_paisa, rate_bps)
    VALUES (l1, 'driver', d1,   320000, 8000),
           (l1, 'school', s_a,   40000, 1000),
           (l1, 'rawaan', NULL,  40000, 1000),
           (l2, 'school', s_b,   40000, 1000),
           (l2, 'rawaan', NULL,  40000, 1000);

    INSERT INTO payment (invoice_id, guardian_id, amount_paisa, method, provider, merchant_account_id,
                         provider_txn_id, status, submitted_by, submitted_at)
    VALUES (i1, g1, 400000, 'jazzcash', 'jazzcash', 'D8-MERCHANT', 'TID-A-' || v_suffix,
            'submitted', u_par1, now()) RETURNING id INTO p1;
    INSERT INTO payment (invoice_id, guardian_id, amount_paisa, method, provider, merchant_account_id,
                         provider_txn_id, status, submitted_by, submitted_at)
    VALUES (i2, g2, 400000, 'easypaisa', 'easypaisa', 'D8-MERCHANT', 'TID-B-' || v_suffix,
            'submitted', u_par2, now()) RETURNING id INTO p2;

    INSERT INTO payout (beneficiary_type, beneficiary_id, school_id, period_start, period_end,
                        gross_paisa, net_paisa)
    VALUES ('driver', d1, s_a, v_period, DATE '2031-01-31', 320000, 320000) RETURNING id INTO po_d1;
    INSERT INTO payout (beneficiary_type, beneficiary_id, school_id, period_start, period_end,
                        gross_paisa, net_paisa)
    VALUES ('school', s_a, s_a, v_period, DATE '2031-01-31', 40000, 40000) RETURNING id INTO po_sa;
    INSERT INTO payout (beneficiary_type, beneficiary_id, school_id, period_start, period_end,
                        gross_paisa, net_paisa)
    VALUES ('school', s_b, s_b, v_period, DATE '2031-01-31', 40000, 40000) RETURNING id INTO po_sb;
    INSERT INTO payout_line (payout_id, invoice_id, invoice_line_id, amount_paisa)
    VALUES (po_d1, i1, l1, 320000);

    INSERT INTO driver_earning (driver_id, school_id, period_start, period_end, gross_paisa, net_paisa)
    VALUES (d1, s_a, v_period, DATE '2031-01-31', 320000, 320000) RETURNING id INTO de1;
    INSERT INTO driver_earning (driver_id, school_id, period_start, period_end, gross_paisa, net_paisa)
    VALUES (d2, s_a, v_period, DATE '2031-01-31', 1000, 1000) RETURNING id INTO de2;

    INSERT INTO trip (route_id, driver_id, vehicle_id, trip_date)
    VALUES (ra, d1, v1, v_trip_on) RETURNING id INTO t1;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'D8 test: fixture setup failed, no assertions were run. Original error: %', SQLERRM;
  END;

  -- ---------------------------------------------------------------------------
  -- 1. No table in the schema has RLS off
  -- ---------------------------------------------------------------------------

  BEGIN
    SELECT string_agg(c.relname, ', ') INTO v_text
      FROM pg_class c
     WHERE c.relnamespace = current_schema()::regnamespace
       AND c.relkind IN ('r', 'p')
       AND NOT c.relrowsecurity;
    IF v_text IS NOT NULL THEN
      RAISE EXCEPTION 'RLS is OFF on: %', v_text;
    END IF;
    RAISE NOTICE 'pass 1: every table in the schema has relrowsecurity = true';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  1: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 2. anon holds no table privilege anywhere, except INSERT on lead
  -- ---------------------------------------------------------------------------

  BEGIN
    SELECT string_agg(c.relname || ':' || pr.p, ', ') INTO v_text
      FROM pg_class c
      CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'REFERENCES']) AS pr(p)
     WHERE c.relnamespace = current_schema()::regnamespace
       AND c.relkind IN ('r', 'p', 'v', 'm')
       AND has_any_column_privilege('anon', c.oid, pr.p)
       AND NOT (c.relname = 'lead' AND pr.p = 'INSERT');
    SELECT concat_ws(', ', v_text, string_agg(c.relname || ':' || pr.p, ', ')) INTO v_text
      FROM pg_class c
      CROSS JOIN unnest(ARRAY['DELETE', 'TRUNCATE', 'TRIGGER']) AS pr(p)
     WHERE c.relnamespace = current_schema()::regnamespace
       AND c.relkind IN ('r', 'p', 'v', 'm')
       AND has_table_privilege('anon', c.oid, pr.p);
    IF v_text IS NOT NULL AND v_text <> '' THEN
      RAISE EXCEPTION 'anon still holds: %', v_text;
    END IF;
    IF NOT has_any_column_privilege('anon', 'lead', 'INSERT') THEN
      RAISE EXCEPTION 'anon cannot INSERT into lead: the public forms would break';
    END IF;
    IF has_table_privilege('authenticated', 'audit_log', 'INSERT')
       OR has_table_privilege('authenticated', 'audit_log', 'UPDATE')
       OR has_table_privilege('authenticated', 'audit_log', 'DELETE')
       OR has_table_privilege('authenticated', 'trip', 'UPDATE')
       OR has_column_privilege('authenticated', 'trip', 'status', 'UPDATE')
       OR has_column_privilege('authenticated', 'student', 'home_location', 'SELECT')
       OR has_column_privilege('authenticated', 'app_user', 'role', 'UPDATE')
       OR has_table_privilege('authenticated', 'absence', 'DELETE') THEN
      RAISE EXCEPTION 'an authenticated column/write privilege that D8 revokes is still granted';
    END IF;
    RAISE NOTICE 'pass 2: anon holds only INSERT on lead; the authenticated column revokes are in place';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  2: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 3. Function EXECUTE hygiene: anon may run only the three identity
  --    helpers, and PUBLIC holds EXECUTE on no SECURITY DEFINER function
  -- ---------------------------------------------------------------------------

  BEGIN
    SELECT string_agg(p.proname, ', ') INTO v_text
      FROM pg_proc p
     WHERE p.pronamespace = current_schema()::regnamespace
       AND p.prokind = 'f'
       AND NOT EXISTS (SELECT 1 FROM pg_depend dep WHERE dep.objid = p.oid AND dep.deptype = 'e')
       AND has_function_privilege('anon', p.oid, 'EXECUTE')
       AND p.proname NOT IN ('current_app_user_id', 'current_app_role', 'is_admin');
    IF v_text IS NOT NULL THEN
      RAISE EXCEPTION 'anon may execute: %', v_text;
    END IF;
    SELECT string_agg(p.proname, ', ') INTO v_text
      FROM pg_proc p
     WHERE p.pronamespace = current_schema()::regnamespace
       AND p.prosecdef
       AND EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                    WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE');
    IF v_text IS NOT NULL THEN
      RAISE EXCEPTION 'PUBLIC may execute SECURITY DEFINER: %', v_text;
    END IF;
    IF has_function_privilege('authenticated', 'is_billable(uuid, date, date)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'write_audit_log()', 'EXECUTE') THEN
      RAISE EXCEPTION 'an internal function is executable by authenticated';
    END IF;
    RAISE NOTICE 'pass 3: EXECUTE is revoked from PUBLIC/anon and granted back deliberately';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  3: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 4. The D8 helpers are STABLE, SECURITY DEFINER, search_path pinned
  -- ---------------------------------------------------------------------------

  v_n := 0;
  FOREACH v_fn IN ARRAY ARRAY['current_driver_id', 'is_guardian_of', 'is_own_guardian_row',
    'is_school_staff_of', 'can_view_school_earnings', 'can_approve_drivers_for',
    'is_guardian_at_school', 'is_driver_at_school', 'is_driver_of_route',
    'is_driver_linked_to_my_school', 'can_view_student_location', 'student_location',
    'school_earnings_paisa'] LOOP
    BEGIN
      SELECT p.prosecdef, p.provolatile, p.proconfig INTO v_secdef, v_vol, v_config
        FROM pg_proc p
       WHERE p.proname = v_fn AND p.pronamespace = current_schema()::regnamespace;
      IF v_secdef IS NOT TRUE OR v_vol <> 's'
         OR NOT EXISTS (SELECT 1 FROM unnest(v_config) c WHERE c LIKE 'search_path=%pg_temp%') THEN
        RAISE EXCEPTION '% is secdef=% volatility=% config=%', v_fn, v_secdef, v_vol, v_config;
      END IF;
      v_n := v_n + 1;
    EXCEPTION WHEN OTHERS THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  4: %s', SQLERRM);
    END;
  END LOOP;
  RAISE NOTICE 'pass 4: % of 13 helpers are STABLE SECURITY DEFINER with a pinned search_path', v_n;

  -- ===========================================================================
  -- ANON
  -- ===========================================================================

  SELECT array_agg(c.relname::text ORDER BY c.relname) INTO v_fix_tables
    FROM pg_class c
   WHERE c.relnamespace = current_schema()::regnamespace
     AND c.relkind IN ('r', 'p', 'v', 'm')
     AND NOT EXISTS (SELECT 1 FROM pg_depend dep WHERE dep.objid = c.oid AND dep.deptype = 'e');

  -- ---------------------------------------------------------------------------
  -- 5. anon reads ZERO rows from every table and view (refused outright)
  -- ---------------------------------------------------------------------------

  PERFORM set_config('request.jwt.claim.sub', '', true);
  SET LOCAL ROLE anon;
  v_text := NULL;
  v_n2 := 0;
  FOREACH v_rel IN ARRAY v_fix_tables LOOP
    BEGIN
      EXECUTE format('SELECT count(*) FROM %I', v_rel) INTO v_n;
      IF v_n <> 0 THEN
        v_text := concat_ws(', ', v_text, format('%s (%s rows)', v_rel, v_n));
      ELSE
        v_n2 := v_n2 + 1;
      END IF;
    EXCEPTION WHEN insufficient_privilege THEN
      v_n2 := v_n2 + 1;
    END;
  END LOOP;
  RESET ROLE;
  IF v_text IS NULL AND v_n2 = array_length(v_fix_tables, 1) THEN
    RAISE NOTICE 'pass 5: anon reads nothing from any of % tables/views', v_n2;
  ELSE
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  5: anon read rows from: %s', v_text);
  END IF;

  -- ---------------------------------------------------------------------------
  -- 6. anon CAN insert a new lead (the public site forms)
  -- ---------------------------------------------------------------------------

  SET LOCAL ROLE anon;
  BEGIN
    INSERT INTO lead (source, contact_name, phone, consent_at, consent_version)
    VALUES ('waitlist', 'D8 Public ' || v_suffix, '0311' || lpad((random() * 9999999)::int::text, 7, '0'),
            now(), '2026-01-consent-v3');
    RESET ROLE;
    SELECT count(*) INTO v_n FROM lead WHERE contact_name = 'D8 Public ' || v_suffix AND status = 'new';
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'expected the anon lead to exist with status new, found % rows', v_n;
    END IF;
    RAISE NOTICE 'pass 6: anon inserted a waitlist lead with status new';
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  6: anon lead insert refused: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 7. anon can do nothing else: a linked or non-new lead, any other table,
  --    find_nearby_students, student_location -> 42501 permission denied
  -- ---------------------------------------------------------------------------

  SET LOCAL ROLE anon;
  v_n := 0;
  BEGIN
    INSERT INTO lead (source, contact_name, phone, app_user_id)
    VALUES ('driver_application', 'D8 Sneaky ' || v_suffix, '03001234567', u_admin);
    v_msg := v_msg || E'\n  7: anon inserted a lead linked to an app_user';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '42501' AND SQLERRM LIKE '%permission denied for table lead%' THEN v_n := v_n + 1;
    ELSE v_msg := v_msg || format(E'\n  7a: wrong reason: %s %s', SQLSTATE, SQLERRM); END IF;
  END;
  BEGIN
    INSERT INTO lead (source, contact_name, phone, status)
    VALUES ('waitlist', 'D8 Sneaky2 ' || v_suffix, '03001234568', 'qualified');
    v_msg := v_msg || E'\n  7: anon inserted a qualified lead';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '42501' AND SQLERRM LIKE '%permission denied for table lead%' THEN v_n := v_n + 1;
    ELSE v_msg := v_msg || format(E'\n  7b: wrong reason: %s %s', SQLSTATE, SQLERRM); END IF;
  END;
  BEGIN
    INSERT INTO school (name, slug) VALUES ('Anon School', 'anon-' || v_suffix);
    v_msg := v_msg || E'\n  7: anon inserted a school';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '42501' AND SQLERRM LIKE '%permission denied for table school%' THEN v_n := v_n + 1;
    ELSE v_msg := v_msg || format(E'\n  7c: wrong reason: %s %s', SQLSTATE, SQLERRM); END IF;
  END;
  BEGIN
    PERFORM count(*) FROM find_nearby_students(s_a, 34.03307, 71.5249, 5000.0);
    v_msg := v_msg || E'\n  7: anon ran find_nearby_students';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '42501' AND SQLERRM LIKE '%permission denied for function find_nearby_students%' THEN v_n := v_n + 1;
    ELSE v_msg := v_msg || format(E'\n  7d: wrong reason: %s %s', SQLSTATE, SQLERRM); END IF;
  END;
  BEGIN
    PERFORM * FROM student_location(st1);
    v_msg := v_msg || E'\n  7: anon read a child location';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '42501' AND SQLERRM LIKE '%permission denied for function student_location%' THEN v_n := v_n + 1;
    ELSE v_msg := v_msg || format(E'\n  7e: wrong reason: %s %s', SQLSTATE, SQLERRM); END IF;
  END;
  RESET ROLE;
  IF v_n = 5 THEN
    RAISE NOTICE 'pass 7: anon refused (42501) a linked lead, a qualified lead, a school insert, find_nearby_students and student_location';
  ELSE
    v_failures := v_failures + 1;
    DELETE FROM lead WHERE contact_name LIKE 'D8 Sneaky%' || v_suffix;
    DELETE FROM school WHERE slug = 'anon-' || v_suffix;
  END IF;

  -- ===========================================================================
  -- PARENT 1 (two children at school A, one manifested)
  -- ===========================================================================

  PERFORM set_config('request.jwt.claim.sub', u_par1::text, true);
  SET LOCAL ROLE authenticated;

  -- 8. Sees exactly their own children, and their own guardian rows
  BEGIN
    SELECT array_agg(id ORDER BY id) INTO v_ids FROM student WHERE id = ANY (v_students);
    IF v_ids IS DISTINCT FROM (SELECT array_agg(x ORDER BY x) FROM unnest(ARRAY[st1, st1b]) x) THEN
      RAISE EXCEPTION 'students visible: %', v_ids;
    END IF;
    SELECT array_agg(id ORDER BY id) INTO v_ids FROM guardian WHERE id IN (g1, g1b, g2);
    IF v_ids IS DISTINCT FROM (SELECT array_agg(x ORDER BY x) FROM unnest(ARRAY[g1, g1b]) x) THEN
      RAISE EXCEPTION 'guardians visible: %', v_ids;
    END IF;
    SELECT count(*) INTO v_n FROM school WHERE id IN (s_a, s_b);
    IF v_n <> 1 THEN RAISE EXCEPTION 'schools visible: %', v_n; END IF;
    RAISE NOTICE 'pass 8: parent sees only their two children, their guardian rows and their school';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  8: %s', SQLERRM);
  END;

  -- 9. Sees only their own invoices and payments
  BEGIN
    SELECT array_agg(id) INTO v_ids FROM invoice WHERE id IN (i1, i2);
    IF v_ids IS DISTINCT FROM ARRAY[i1] THEN RAISE EXCEPTION 'invoices visible: %', v_ids; END IF;
    SELECT array_agg(id) INTO v_ids FROM payment WHERE id IN (p1, p2);
    IF v_ids IS DISTINCT FROM ARRAY[p1] THEN RAISE EXCEPTION 'payments visible: %', v_ids; END IF;
    SELECT count(*) INTO v_n FROM invoice_line WHERE id IN (l1, l2);
    IF v_n <> 1 THEN RAISE EXCEPTION 'invoice lines visible: %', v_n; END IF;
    RAISE NOTICE 'pass 9: parent sees only the invoice, line and payment they are billed for';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  9: %s', SQLERRM);
  END;

  -- 10. Reads their own child's location through the accessor; not another
  --     child's (42501); and never through the student columns (42501)
  BEGIN
    SELECT l.home_location INTO v_loc FROM student_location(st1) l;
    IF v_loc IS NULL THEN RAISE EXCEPTION 'own child location came back NULL'; END IF;
    BEGIN
      PERFORM * FROM student_location(st2);
      RAISE EXCEPTION 'read another family''s child location';
    EXCEPTION WHEN insufficient_privilege THEN
      IF SQLERRM NOT LIKE '%student_location: caller may not view%' THEN RAISE; END IF;
    END;
    BEGIN
      PERFORM home_location FROM student WHERE id = st1;
      RAISE EXCEPTION 'selected student.home_location directly';
    EXCEPTION WHEN insufficient_privilege THEN
      IF SQLERRM NOT LIKE '%permission denied for table student%' THEN RAISE; END IF;
    END;
    RAISE NOTICE 'pass 10: parent reads own child location via student_location(), not another child''s, never the raw column (42501)';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  10: %s %s', SQLSTATE, SQLERRM);
  END;

  -- 11. Nothing from driver_document, audit_log, split_allocation,
  --     trip_qr_token, payout, driver_earning, or the driver stop list
  BEGIN
    SELECT (SELECT count(*) FROM driver_document) + (SELECT count(*) FROM audit_log)
         + (SELECT count(*) FROM split_allocation) + (SELECT count(*) FROM trip_qr_token)
         + (SELECT count(*) FROM payout) + (SELECT count(*) FROM driver_earning)
         + (SELECT count(*) FROM v_trip_stop_attendance) + (SELECT count(*) FROM adjustment)
      INTO v_n;
    IF v_n <> 0 THEN RAISE EXCEPTION 'parent read % rows across the closed tables', v_n; END IF;
    RAISE NOTICE 'pass 11: parent reads 0 rows of driver_document, audit_log, splits, tokens, payouts, earnings, stop list';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  11: %s', SQLERRM);
  END;

  -- 12. Cannot confirm a payment: no UPDATE policy, so the UPDATE matches 0
  --     rows (the RLS outcome), and the row is unchanged
  BEGIN
    UPDATE payment SET status = 'confirmed', confirmed_by = u_par1, confirmed_at = now() WHERE id = p1;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n <> 0 THEN RAISE EXCEPTION 'parent UPDATE touched % payment rows', v_n; END IF;
    RAISE NOTICE 'pass 12: a parent UPDATE confirming their payment matched 0 rows';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  12: %s', SQLERRM);
  END;

  -- 13. May INSERT a payment only as 'submitted', own name, own invoice
  BEGIN
    INSERT INTO payment (invoice_id, guardian_id, amount_paisa, method, status, submitted_by, submitted_at)
    VALUES (i1, g1, 1000, 'cash', 'submitted', u_par1, now()) RETURNING id INTO p_new;
    BEGIN
      INSERT INTO payment (invoice_id, guardian_id, amount_paisa, method, status, submitted_by)
      VALUES (i1, g1, 1000, 'cash', 'confirmed', u_par1);
      RAISE EXCEPTION 'parent inserted a confirmed payment';
    EXCEPTION WHEN insufficient_privilege THEN
      IF SQLERRM NOT LIKE '%row-level security policy for table "payment"%' THEN RAISE; END IF;
    END;
    BEGIN
      INSERT INTO payment (invoice_id, guardian_id, amount_paisa, method, status, submitted_by)
      VALUES (i2, g1, 1000, 'cash', 'submitted', u_par1);
      RAISE EXCEPTION 'parent paid someone else''s invoice under their own guardian id';
    EXCEPTION WHEN insufficient_privilege THEN
      IF SQLERRM NOT LIKE '%row-level security policy for table "payment"%' THEN RAISE; END IF;
    END;
    BEGIN
      INSERT INTO payment (invoice_id, guardian_id, amount_paisa, method, status, submitted_by)
      VALUES (i2, g2, 1000, 'cash', 'submitted', u_par1);
      RAISE EXCEPTION 'parent submitted a payment as another guardian';
    EXCEPTION WHEN insufficient_privilege THEN
      IF SQLERRM NOT LIKE '%row-level security policy for table "payment"%' THEN RAISE; END IF;
    END;
    RAISE NOTICE 'pass 13: parent inserts a submitted payment; confirmed / foreign-invoice / foreign-guardian refused by RLS';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  13: %s %s', SQLSTATE, SQLERRM);
  END;

  -- 14. find_nearby_students is refused inside the function (42501)
  BEGIN
    PERFORM count(*) FROM find_nearby_students(s_a, 34.03307, 71.5249, 5000.0);
    v_failures := v_failures + 1;
    v_msg := v_msg || E'\n  14: a parent ran find_nearby_students';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> '42501' OR SQLERRM NOT LIKE '%find_nearby_students: caller may not search%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  14: wrong reason: %s %s', SQLSTATE, SQLERRM);
    ELSE
      RAISE NOTICE 'pass 14: find_nearby_students refused a parent (42501)';
    END IF;
  END;

  -- 15. Absence: the parent submits one, cannot DELETE it (42501), and may
  --     mint a boarding token for their own child
  BEGIN
    INSERT INTO absence (student_id, absent_on, reason, guardian_id)
    VALUES (st1, v_trip_on, 'Fever', g1) RETURNING id INTO ab1;
    BEGIN
      DELETE FROM absence WHERE id = ab1;
      RAISE EXCEPTION 'parent deleted an absence';
    EXCEPTION WHEN insufficient_privilege THEN
      IF SQLERRM NOT LIKE '%permission denied for table absence%' THEN RAISE; END IF;
    END;
    v_token := issue_trip_qr_token(t1, st1);
    IF v_token IS NULL THEN RAISE EXCEPTION 'no token issued'; END IF;
    RAISE NOTICE 'pass 15: parent submits an absence, cannot DELETE it (42501), mints a token for own child';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  15: %s %s', SQLSTATE, SQLERRM);
  END;

  -- 16. Cannot move a trip (42501)
  BEGIN
    PERFORM transition_trip(t1, 'cancelled', 'parent says so');
    v_failures := v_failures + 1;
    v_msg := v_msg || E'\n  16: a parent cancelled a trip';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> '42501' OR SQLERRM NOT LIKE '%transition_trip: caller may not move%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  16: wrong reason: %s %s', SQLSTATE, SQLERRM);
    ELSE
      RAISE NOTICE 'pass 16: transition_trip refused a parent (42501)';
    END IF;
  END;
  RESET ROLE;

  -- Owner check for 12: the payment is still 'submitted'.
  SELECT status::text INTO v_status FROM payment WHERE id = p1;
  IF v_status <> 'submitted' THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  12b: payment status became %s', v_status);
  END IF;

  -- ===========================================================================
  -- PARENT 2 (one child at school B)
  -- ===========================================================================

  -- 17. Cannot read parent 1's child (row or location) or mint a token for it
  PERFORM set_config('request.jwt.claim.sub', u_par2::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    SELECT count(*) INTO v_n FROM student WHERE id IN (st1, st1b);
    IF v_n <> 0 THEN RAISE EXCEPTION 'parent 2 sees % of parent 1''s children', v_n; END IF;
    SELECT count(*) INTO v_n FROM invoice WHERE id = i1;
    IF v_n <> 0 THEN RAISE EXCEPTION 'parent 2 sees parent 1''s invoice'; END IF;
    BEGIN
      PERFORM * FROM student_location(st1);
      RAISE EXCEPTION 'parent 2 read parent 1''s child location';
    EXCEPTION WHEN insufficient_privilege THEN
      IF SQLERRM NOT LIKE '%student_location: caller may not view%' THEN RAISE; END IF;
    END;
    BEGIN
      PERFORM issue_trip_qr_token(t1, st1);
      RAISE EXCEPTION 'parent 2 minted a boarding token for another child';
    EXCEPTION WHEN insufficient_privilege THEN
      IF SQLERRM NOT LIKE '%issue_trip_qr_token: caller may not issue%' THEN RAISE; END IF;
    END;
    RAISE NOTICE 'pass 17: parent 2 cannot see parent 1''s children, invoice, child location, or mint their token';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  17: %s %s', SQLSTATE, SQLERRM);
  END;
  RESET ROLE;

  -- ===========================================================================
  -- STAFF A (school A, can_view_earnings)
  -- ===========================================================================

  PERFORM set_config('request.jwt.claim.sub', u_staff_a::text, true);
  SET LOCAL ROLE authenticated;

  -- 18. Only school A: school, students, invoices, the linked driver
  BEGIN
    SELECT array_agg(id) INTO v_ids FROM school WHERE id IN (s_a, s_b);
    IF v_ids IS DISTINCT FROM ARRAY[s_a] THEN RAISE EXCEPTION 'schools visible: %', v_ids; END IF;
    SELECT count(*) INTO v_n FROM student WHERE id = ANY (v_students);
    SELECT count(*) INTO v_n2 FROM student WHERE id = st2;
    IF v_n <> 2 OR v_n2 <> 0 THEN RAISE EXCEPTION 'students visible: % (school B: %)', v_n, v_n2; END IF;
    SELECT array_agg(id) INTO v_ids FROM invoice WHERE id IN (i1, i2);
    IF v_ids IS DISTINCT FROM ARRAY[i1] THEN RAISE EXCEPTION 'invoices visible: %', v_ids; END IF;
    SELECT array_agg(id) INTO v_ids FROM driver WHERE id IN (d1, d2);
    IF v_ids IS DISTINCT FROM ARRAY[d1] THEN RAISE EXCEPTION 'drivers visible: %', v_ids; END IF;
    SELECT count(*) INTO v_n FROM driver_verification_summary WHERE driver_id IN (d1, d2);
    IF v_n <> 1 THEN RAISE EXCEPTION 'driver_verification_summary rows: %', v_n; END IF;
    SELECT count(*) INTO v_n FROM payment WHERE id IN (p1, p2);
    IF v_n <> 0 THEN RAISE EXCEPTION 'staff sees % payments', v_n; END IF;
    RAISE NOTICE 'pass 18: staff A sees only school A, its students and invoices, and the driver linked to it';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  18: %s', SQLERRM);
  END;

  -- 19. Earnings visible: aggregate, the school leg, the school payout
  BEGIN
    v_earn := school_earnings_paisa(s_a, v_period);
    IF v_earn IS DISTINCT FROM 40000 THEN RAISE EXCEPTION 'school_earnings_paisa = %', v_earn; END IF;
    SELECT count(*) INTO v_n FROM split_allocation WHERE invoice_line_id IN (l1, l2);
    IF v_n <> 1 THEN RAISE EXCEPTION 'split rows visible: %', v_n; END IF;
    SELECT array_agg(id) INTO v_ids FROM payout WHERE id IN (po_d1, po_sa, po_sb);
    IF v_ids IS DISTINCT FROM ARRAY[po_sa] THEN RAISE EXCEPTION 'payouts visible: %', v_ids; END IF;
    SELECT count(*) INTO v_n FROM driver_earning WHERE id IN (de1, de2);
    IF v_n <> 0 THEN RAISE EXCEPTION 'staff sees driver earnings'; END IF;
    RAISE NOTICE 'pass 19: staff A with can_view_earnings sees 40000 paisa, its school leg and its payout only';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  19: %s', SQLERRM);
  END;

  -- 20. No driver_document, no child location, find_nearby for own school OK
  BEGIN
    SELECT count(*) INTO v_n FROM driver_document;
    IF v_n <> 0 THEN RAISE EXCEPTION 'staff read % driver_document rows', v_n; END IF;
    BEGIN
      PERFORM * FROM student_location(st1);
      RAISE EXCEPTION 'staff read a child location via the accessor';
    EXCEPTION WHEN insufficient_privilege THEN
      IF SQLERRM NOT LIKE '%student_location: caller may not view%' THEN RAISE; END IF;
    END;
    SELECT count(*) INTO v_n FROM find_nearby_students(s_a, 34.03307, 71.5249, 5000.0);
    IF v_n < 1 THEN RAISE EXCEPTION 'find_nearby_students for own school returned nothing'; END IF;
    RAISE NOTICE 'pass 20: staff A reads no driver_document, no child location, and may search its own school';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  20: %s %s', SQLSTATE, SQLERRM);
  END;
  RESET ROLE;

  -- ===========================================================================
  -- STAFF B (school B, earnings-blind)
  -- ===========================================================================

  PERFORM set_config('request.jwt.claim.sub', u_staff_b::text, true);
  SET LOCAL ROLE authenticated;

  -- 21. Sees its invoice, but earnings are NULL / denied
  BEGIN
    SELECT array_agg(id) INTO v_ids FROM invoice WHERE id IN (i1, i2);
    IF v_ids IS DISTINCT FROM ARRAY[i2] THEN RAISE EXCEPTION 'invoices visible: %', v_ids; END IF;
    v_earn := school_earnings_paisa(s_b, v_period);
    IF v_earn IS NOT NULL THEN RAISE EXCEPTION 'earnings-blind staff got %', v_earn; END IF;
    SELECT (SELECT count(*) FROM split_allocation WHERE invoice_line_id IN (l1, l2))
         + (SELECT count(*) FROM payout WHERE id IN (po_d1, po_sa, po_sb))
         + (SELECT count(*) FROM rate_snapshot)
      INTO v_n;
    IF v_n <> 0 THEN RAISE EXCEPTION 'earnings-blind staff read % earnings rows', v_n; END IF;
    SELECT count(*) INTO v_n FROM driver_document;
    IF v_n <> 0 THEN RAISE EXCEPTION 'staff B read % driver_document rows', v_n; END IF;
    RAISE NOTICE 'pass 21: earnings-blind staff B sees its invoice but NULL earnings, 0 splits/payouts, 0 documents';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  21: %s', SQLERRM);
  END;

  -- 22. find_nearby_students for ANOTHER school is refused (42501)
  BEGIN
    PERFORM count(*) FROM find_nearby_students(s_a, 34.03307, 71.5249, 5000.0);
    v_failures := v_failures + 1;
    v_msg := v_msg || E'\n  22: school B staff searched school A';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> '42501' OR SQLERRM NOT LIKE '%find_nearby_students: caller may not search%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  22: wrong reason: %s %s', SQLSTATE, SQLERRM);
    ELSE
      RAISE NOTICE 'pass 22: find_nearby_students refused school B staff querying school A (42501)';
    END IF;
  END;
  RESET ROLE;

  -- ===========================================================================
  -- DRIVER 1 (approved, drives route A)
  -- ===========================================================================

  PERFORM set_config('request.jwt.claim.sub', u_drv1::text, true);
  SET LOCAL ROLE authenticated;

  -- 23. Own documents, earnings, legs, payouts only
  BEGIN
    SELECT array_agg(id) INTO v_ids FROM driver_document WHERE id IN (doc1, doc2);
    IF v_ids IS DISTINCT FROM ARRAY[doc1] THEN RAISE EXCEPTION 'documents visible: %', v_ids; END IF;
    SELECT array_agg(id) INTO v_ids FROM driver_earning WHERE id IN (de1, de2);
    IF v_ids IS DISTINCT FROM ARRAY[de1] THEN RAISE EXCEPTION 'earnings visible: %', v_ids; END IF;
    SELECT count(*) INTO v_n FROM split_allocation WHERE invoice_line_id IN (l1, l2);
    IF v_n <> 1 THEN RAISE EXCEPTION 'split rows visible: %', v_n; END IF;
    SELECT array_agg(id) INTO v_ids FROM payout WHERE id IN (po_d1, po_sa, po_sb);
    IF v_ids IS DISTINCT FROM ARRAY[po_d1] THEN RAISE EXCEPTION 'payouts visible: %', v_ids; END IF;
    SELECT count(*) INTO v_n FROM payout_line WHERE payout_id = po_d1;
    IF v_n <> 1 THEN RAISE EXCEPTION 'payout lines visible: %', v_n; END IF;
    SELECT count(*) INTO v_n FROM invoice WHERE id IN (i1, i2);
    IF v_n <> 0 THEN RAISE EXCEPTION 'driver sees % invoices', v_n; END IF;
    RAISE NOTICE 'pass 23: driver sees only their own documents, earnings, split leg and payout';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  23: %s', SQLERRM);
  END;

  -- 24. Own route's manifest; manifested child's location only
  BEGIN
    SELECT count(*) INTO v_n FROM route_manifest WHERE student_id = ANY (v_students);
    IF v_n <> 1 THEN RAISE EXCEPTION 'manifest rows visible: %', v_n; END IF;
    SELECT array_agg(id) INTO v_ids FROM student WHERE id = ANY (v_students);
    IF v_ids IS DISTINCT FROM ARRAY[st1] THEN RAISE EXCEPTION 'students visible: %', v_ids; END IF;
    SELECT l.pickup_location INTO v_loc FROM student_location(st1) l;
    IF v_loc IS NULL THEN RAISE EXCEPTION 'manifested child pickup came back NULL'; END IF;
    SELECT count(*) INTO v_n FROM route_stop WHERE id = stop_a;
    IF v_n <> 1 THEN RAISE EXCEPTION 'own route stop not visible'; END IF;
    BEGIN
      PERFORM * FROM student_location(st1b);
      RAISE EXCEPTION 'driver read an unmanifested sibling''s location';
    EXCEPTION WHEN insufficient_privilege THEN
      IF SQLERRM NOT LIKE '%student_location: caller may not view%' THEN RAISE; END IF;
    END;
    BEGIN
      PERFORM * FROM student_location(st2);
      RAISE EXCEPTION 'driver read another school''s child location';
    EXCEPTION WHEN insufficient_privilege THEN
      IF SQLERRM NOT LIKE '%student_location: caller may not view%' THEN RAISE; END IF;
    END;
    RAISE NOTICE 'pass 24: driver sees their manifest and stop, reads the manifested child''s location only (others 42501)';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  24: %s %s', SQLSTATE, SQLERRM);
  END;

  -- 25. No absence rows (guardian's reason), but the boolean and the
  --     notification reach the driver
  BEGIN
    SELECT count(*) INTO v_n FROM absence;
    IF v_n <> 0 THEN RAISE EXCEPTION 'driver read % absence rows', v_n; END IF;
    IF NOT is_student_absent(st1, v_trip_on) THEN RAISE EXCEPTION 'is_student_absent false'; END IF;
    SELECT count(*) INTO v_n FROM notification WHERE payload ->> 'absence_id' = ab1::text;
    IF v_n <> 1 THEN RAISE EXCEPTION 'driver sees % absence notifications', v_n; END IF;
    RAISE NOTICE 'pass 25: driver reads no absence row, but is_student_absent() and their notification work';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  25: %s', SQLERRM);
  END;

  -- 26. A direct UPDATE of trip.status is refused by the grant (42501)
  BEGIN
    UPDATE trip SET status = 'completed' WHERE id = t1;
    v_failures := v_failures + 1;
    v_msg := v_msg || E'\n  26: a driver updated trip.status directly';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> '42501' OR SQLERRM NOT LIKE '%permission denied for table trip%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  26: wrong reason: %s %s', SQLSTATE, SQLERRM);
    ELSE
      RAISE NOTICE 'pass 26: a direct UPDATE of trip.status is refused (42501)';
    END IF;
  END;

  -- 27. transition_trip on their own trip works; the stop list is theirs
  BEGIN
    v_trip := transition_trip(t1, 'driver_en_route');
    IF v_trip.status <> 'driver_en_route' THEN RAISE EXCEPTION 'status is %', v_trip.status; END IF;
    SELECT count(*) INTO v_n FROM v_trip_stop_attendance WHERE trip_id = t1 AND is_skippable;
    IF v_n <> 1 THEN RAISE EXCEPTION 'expected 1 skippable stop (child absent), got %', v_n; END IF;
    RAISE NOTICE 'pass 27: driver moves their own trip via transition_trip() and sees its stop list';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  27: %s %s', SQLSTATE, SQLERRM);
  END;
  RESET ROLE;

  -- ===========================================================================
  -- DRIVER 2 (not on this trip)
  -- ===========================================================================

  -- 28. Cannot transition another driver's trip (42501); own document only
  PERFORM set_config('request.jwt.claim.sub', u_drv2::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    SELECT array_agg(id) INTO v_ids FROM driver_document WHERE id IN (doc1, doc2);
    IF v_ids IS DISTINCT FROM ARRAY[doc2] THEN RAISE EXCEPTION 'documents visible: %', v_ids; END IF;
    BEGIN
      PERFORM transition_trip(t1, 'arrived_pickup');
      RAISE EXCEPTION 'driver 2 moved driver 1''s trip';
    EXCEPTION WHEN insufficient_privilege THEN
      IF SQLERRM NOT LIKE '%transition_trip: caller may not move%' THEN RAISE; END IF;
    END;
    BEGIN
      PERFORM record_trip_checkin(t1, 'manual_override', NULL, st1);
      RAISE EXCEPTION 'driver 2 checked a child into driver 1''s trip';
    EXCEPTION WHEN insufficient_privilege THEN
      IF SQLERRM NOT LIKE '%record_trip_checkin: caller is not the driver%' THEN RAISE; END IF;
    END;
    SELECT count(*) INTO v_n FROM student_location(st1);
    RAISE EXCEPTION 'driver 2 read a child location';
  EXCEPTION
    WHEN insufficient_privilege THEN
      IF SQLERRM LIKE '%student_location: caller may not view%' THEN
        RAISE NOTICE 'pass 28: driver 2 cannot move or check in on driver 1''s trip, nor read its child (42501)';
      ELSE
        v_failures := v_failures + 1;
        v_msg := v_msg || format(E'\n  28: wrong reason: %s', SQLERRM);
      END IF;
    WHEN OTHERS THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  28: %s %s', SQLSTATE, SQLERRM);
  END;
  RESET ROLE;

  -- ===========================================================================
  -- ADMIN
  -- ===========================================================================

  PERFORM set_config('request.jwt.claim.sub', u_admin::text, true);
  SET LOCAL ROLE authenticated;

  -- 29. Sees everything
  BEGIN
    SELECT (SELECT count(*) FROM student WHERE id = ANY (v_students))           -- 3
         + (SELECT count(*) FROM driver_document WHERE id IN (doc1, doc2))      -- 2
         + (SELECT count(*) FROM invoice WHERE id IN (i1, i2))                  -- 2
         + (SELECT count(*) FROM payment WHERE invoice_id IN (i1, i2))          -- 3
         + (SELECT count(*) FROM split_allocation WHERE invoice_line_id IN (l1, l2)) -- 5
         + (SELECT count(*) FROM payout WHERE id IN (po_d1, po_sa, po_sb))      -- 3
         + (SELECT count(*) FROM trip_qr_token WHERE trip_id = t1)              -- 1
         + (SELECT count(*) FROM absence WHERE id = ab1)                        -- 1
         + (SELECT count(*) FROM lead WHERE contact_name = 'D8 Public ' || v_suffix) -- 1
      INTO v_n;
    IF v_n <> 21 THEN RAISE EXCEPTION 'admin sees % of 21 fixture rows', v_n; END IF;
    SELECT count(*) INTO v_n FROM audit_log WHERE row_id IN (po_d1, po_sa, po_sb);
    IF v_n < 3 THEN RAISE EXCEPTION 'admin sees % payout audit rows', v_n; END IF;
    SELECT count(*) INTO v_n FROM find_nearby_students(s_a, 34.03307, 71.5249, 5000.0);
    IF v_n < 1 THEN RAISE EXCEPTION 'admin find_nearby_students returned nothing'; END IF;
    SELECT l.home_address INTO v_text FROM student_location(st2) l;
    IF v_text IS NULL THEN RAISE EXCEPTION 'admin location read came back NULL'; END IF;
    RAISE NOTICE 'pass 29: admin sees every fixture row, the audit log, nearby students and any location';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  29: %s %s', SQLSTATE, SQLERRM);
  END;

  -- 30. Privileged writes as admin: confirm a payment, add an adjustment,
  --     move a driver's verification status
  BEGIN
    UPDATE payment SET status = 'confirmed', confirmed_by = u_admin, confirmed_at = now() WHERE id = p1;
    INSERT INTO adjustment (beneficiary_type, beneficiary_id, amount_paisa, reason, created_by)
    VALUES ('driver', d1, -5000, 'Missed the 2031-06-02 afternoon run', u_admin) RETURNING id INTO adj;
    UPDATE driver SET verification_status = 'pending_review', submitted_at = now() WHERE id = d2;
    RAISE NOTICE 'pass 30: admin confirmed a payment, added an adjustment, moved a verification status';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  30: %s %s', SQLSTATE, SQLERRM);
  END;

  -- 31. Even admin cannot UPDATE or DELETE the audit log (no grant, 42501)
  v_n := 0;
  BEGIN
    UPDATE audit_log SET action = 'tampered' WHERE row_id = p1;
    v_msg := v_msg || E'\n  31: admin updated audit_log';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '42501' AND SQLERRM LIKE '%permission denied for table audit_log%' THEN v_n := v_n + 1;
    ELSE v_msg := v_msg || format(E'\n  31a: wrong reason: %s %s', SQLSTATE, SQLERRM); END IF;
  END;
  BEGIN
    DELETE FROM audit_log WHERE row_id = p1;
    v_msg := v_msg || E'\n  31: admin deleted audit_log rows';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '42501' AND SQLERRM LIKE '%permission denied for table audit_log%' THEN v_n := v_n + 1;
    ELSE v_msg := v_msg || format(E'\n  31b: wrong reason: %s %s', SQLSTATE, SQLERRM); END IF;
  END;
  BEGIN
    INSERT INTO audit_log (db_role, action, table_name, after) VALUES ('x', 'forged', 'payment', '{}');
    v_msg := v_msg || E'\n  31: admin forged an audit_log row';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '42501' AND SQLERRM LIKE '%permission denied for table audit_log%' THEN v_n := v_n + 1;
    ELSE v_msg := v_msg || format(E'\n  31c: wrong reason: %s %s', SQLSTATE, SQLERRM); END IF;
  END;
  IF v_n = 3 THEN
    RAISE NOTICE 'pass 31: admin cannot UPDATE, DELETE or INSERT audit_log (42501)';
  ELSE
    v_failures := v_failures + 1;
  END IF;
  RESET ROLE;
  PERFORM set_config('request.jwt.claim.sub', '', true);

  -- ===========================================================================
  -- AUDIT LOG CONTENT (as owner)
  -- ===========================================================================

  -- 32. Payment confirmation recorded with actor and before/after
  BEGIN
    SELECT * INTO v_audit FROM audit_log
     WHERE table_name = 'payment' AND row_id = p1 AND action = 'status_change';
    IF NOT FOUND THEN RAISE EXCEPTION 'no audit row for the payment confirmation'; END IF;
    IF v_audit.before ->> 'status' <> 'submitted' OR v_audit.after ->> 'status' <> 'confirmed'
       OR v_audit.actor_app_user_id IS DISTINCT FROM u_admin OR v_audit.actor_role IS DISTINCT FROM 'admin'
       OR v_audit.db_role <> 'authenticated' THEN
      RAISE EXCEPTION 'audit row wrong: before=% after=% actor=% role=% db=%',
        v_audit.before ->> 'status', v_audit.after ->> 'status', v_audit.actor_app_user_id,
        v_audit.actor_role, v_audit.db_role;
    END IF;
    RAISE NOTICE 'pass 32: payment confirmation audited: submitted -> confirmed by the admin';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  32: %s', SQLERRM);
  END;

  -- 33. Adjustment recorded (insert, after image, no before)
  BEGIN
    SELECT * INTO v_audit FROM audit_log WHERE table_name = 'adjustment' AND row_id = adj;
    IF NOT FOUND THEN RAISE EXCEPTION 'no audit row for the adjustment'; END IF;
    IF v_audit.action <> 'insert' OR v_audit.before IS NOT NULL
       OR (v_audit.after ->> 'amount_paisa')::bigint <> -5000
       OR v_audit.actor_app_user_id IS DISTINCT FROM u_admin THEN
      RAISE EXCEPTION 'adjustment audit wrong: action=% amount=%', v_audit.action, v_audit.after ->> 'amount_paisa';
    END IF;
    RAISE NOTICE 'pass 33: adjustment audited as insert with its amount and actor';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  33: %s', SQLERRM);
  END;

  -- 34. Driver verification change recorded, without the phone number
  BEGIN
    SELECT * INTO v_audit FROM audit_log
     WHERE table_name = 'driver' AND row_id = d2 AND action = 'verification_status_change';
    IF NOT FOUND THEN RAISE EXCEPTION 'no audit row for the verification change'; END IF;
    IF v_audit.before ->> 'verification_status' <> 'not_submitted'
       OR v_audit.after ->> 'verification_status' <> 'pending_review'
       OR v_audit.after ? 'phone' OR v_audit.after ? 'cnic_last4' THEN
      RAISE EXCEPTION 'verification audit wrong: %', v_audit.after;
    END IF;
    RAISE NOTICE 'pass 34: driver verification change audited (not_submitted -> pending_review), phone not copied';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  34: %s', SQLERRM);
  END;

  -- 35. audit_log is append-only even for the owner (trg_audit_log_append_only)
  v_n := 0;
  BEGIN
    UPDATE audit_log SET action = 'tampered' WHERE row_id = p1;
    v_msg := v_msg || E'\n  35: the owner updated audit_log';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '23514' AND SQLERRM LIKE '%trg_audit_log_append_only%' THEN v_n := v_n + 1;
    ELSE v_msg := v_msg || format(E'\n  35a: wrong reason: %s %s', SQLSTATE, SQLERRM); END IF;
  END;
  BEGIN
    DELETE FROM audit_log WHERE row_id = p1;
    v_msg := v_msg || E'\n  35: the owner deleted audit_log rows';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '23514' AND SQLERRM LIKE '%trg_audit_log_append_only%' THEN v_n := v_n + 1;
    ELSE v_msg := v_msg || format(E'\n  35b: wrong reason: %s %s', SQLSTATE, SQLERRM); END IF;
  END;
  IF v_n = 2 THEN
    RAISE NOTICE 'pass 35: trg_audit_log_append_only refused UPDATE and DELETE by the owner (23514)';
  ELSE
    v_failures := v_failures + 1;
  END IF;

  -- ===========================================================================
  -- 36. Role-change guard (closes the D4 known limitation)
  -- ===========================================================================

  v_n := 0;
  FOR v_auth_id, v_role IN
    SELECT * FROM (VALUES (u_drv1, 'parent'::app_role), (u_staff_a, 'parent'::app_role),
                          (u_par1, 'driver'::app_role)) AS c(u, r)
  LOOP
    BEGIN
      UPDATE app_user SET role = v_role WHERE id = v_auth_id;
      v_msg := v_msg || format(E'\n  36: role change to %s accepted for %s', v_role, v_auth_id);
    EXCEPTION WHEN OTHERS THEN
      IF SQLSTATE = '23514' AND SQLERRM LIKE '%trg_app_user_role_change_guard%' THEN v_n := v_n + 1;
      ELSE v_msg := v_msg || format(E'\n  36: wrong reason: %s %s', SQLSTATE, SQLERRM); END IF;
    END;
  END LOOP;
  BEGIN
    UPDATE driver SET is_active = false WHERE id = d2;
    UPDATE app_user SET role = 'parent' WHERE id = u_drv2;
    SELECT * INTO v_audit FROM audit_log WHERE table_name = 'app_user' AND row_id = u_drv2 AND action = 'role_change';
    IF NOT FOUND OR v_audit.after ->> 'role' <> 'parent' OR v_audit.after ? 'full_name' THEN
      RAISE EXCEPTION 'role change not audited as expected';
    END IF;
    v_n := v_n + 1;
  EXCEPTION WHEN OTHERS THEN
    v_msg := v_msg || format(E'\n  36: demotion after deactivating the driver row refused: %s', SQLERRM);
  END;
  IF v_n = 4 THEN
    RAISE NOTICE 'pass 36: trg_app_user_role_change_guard refused driver/school/parent role changes with dependent rows, allowed (and audited) it once cleared';
  ELSE
    v_failures := v_failures + 1;
  END IF;

  -- ---------------------------------------------------------------------------
  -- Cleanup (as owner). audit_log rows stay: the table is append-only.
  -- ---------------------------------------------------------------------------

  RESET ROLE;
  PERFORM set_config('request.jwt.claim.sub', '', true);
  BEGIN
    DELETE FROM absence        WHERE student_id = ANY (v_students);
    DELETE FROM trip_checkin   WHERE trip_id = t1;
    DELETE FROM trip           WHERE id = t1;
    DELETE FROM driver_earning WHERE id IN (de1, de2);
    DELETE FROM payout         WHERE id IN (po_d1, po_sa, po_sb);
    DELETE FROM payment        WHERE invoice_id IN (i1, i2);
    DELETE FROM adjustment     WHERE id = adj;
    DELETE FROM invoice        WHERE id IN (i1, i2);
    DELETE FROM billing_period WHERE id IN (bp_a, bp_b);
    DELETE FROM enrollment     WHERE id IN (e1, e1b, e2);
    DELETE FROM route_manifest WHERE route_id = ra;
    DELETE FROM route          WHERE id = ra;
    DELETE FROM driver_school  WHERE driver_id IN (d1, d2);
    DELETE FROM driver_document WHERE driver_id IN (d1, d2);
    DELETE FROM vehicle        WHERE driver_id IN (d1, d2);
    DELETE FROM driver         WHERE id IN (d1, d2);
    DELETE FROM guardian       WHERE id IN (g1, g1b, g2);
    DELETE FROM student        WHERE id = ANY (v_students);
    DELETE FROM school_admin   WHERE app_user_id = ANY (v_auth_ids);
    DELETE FROM lead           WHERE contact_name LIKE 'D8 %' || v_suffix;
    DELETE FROM school         WHERE id IN (s_a, s_b);
    DELETE FROM notification   WHERE recipient_app_user_id = ANY (v_auth_ids);
    DELETE FROM app_user       WHERE id = ANY (v_auth_ids);
    DELETE FROM auth.users     WHERE id = ANY (v_auth_ids);
    RAISE NOTICE 'fixtures for run % removed (audit_log rows are kept by design)', v_suffix;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'cleanup failed (all fixtures are namespaced with % and cannot collide with a later run): %',
      v_suffix, SQLERRM;
  END;

  -- ---------------------------------------------------------------------------
  -- Report
  -- ---------------------------------------------------------------------------

  IF v_failures = 0 THEN
    RAISE NOTICE 'D8: all 36 assertions passed.';
  ELSE
    RAISE EXCEPTION 'D8: % assertion(s) failed:%', v_failures, v_msg;
  END IF;
END
$test$;
