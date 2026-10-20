-- =============================================================================
-- D7 test — leads
-- =============================================================================
-- Executable assertions for 20261006000007_d7_leads.sql.
-- Plain SQL, no test framework, no docker. Run with:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/d7_leads.test.sql
--
-- STYLE (same as d3/d4)
--   Every assertion is ATTEMPTED inside its own BEGIN ... EXCEPTION block.
--   Failures accumulate and are reported in ONE exception at the end.
--   Negative cases assert on WHICH constraint or guard refused the row. When
--   an insert that should have failed succeeds, the row is deleted before the
--   failure is counted.
--
-- DEPENDENCY ORDER
--   auth.users  ->  app_user (D1)  ->  lead. A lead needs nothing else.
--
-- RE-RUNNABLE
--   Fixtures are namespaced with a random() suffix, and every phone number is
--   random, so the dedup index cannot collide with an earlier run.
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
  v_admin_user  uuid;
  v_parent_user uuid;   -- an ordinary non-admin account
  v_applicant   uuid;   -- the pending account the B2 flow created

  v_digits      text;   -- 7 random digits; the subscriber part of the phone
  v_lead        uuid;   -- lifecycle subject
  v_dup_a       uuid;   -- first open lead on the shared phone
  v_dup_b       uuid;   -- same phone, other source
  v_dup_c       uuid;   -- same phone, same source, after v_dup_a closed
  v_app_lead    uuid;   -- driver application linked to v_applicant
  v_leads       uuid[] := '{}';

  -- Scratch ----------------------------------------------------------------
  v_id          uuid;
  v_status      lead_status;
  v_at          timestamptz;
  v_got_role    app_role;

  v_failures    int := 0;
  v_msg         text := '';
BEGIN
  -- ---------------------------------------------------------------------------
  -- 0. Preconditions
  -- ---------------------------------------------------------------------------

  IF to_regclass('lead') IS NULL
     OR to_regprocedure('promote_lead_to_role(uuid, app_role)') IS NULL THEN
    RAISE NOTICE
      'D7 test SKIPPED: lead or promote_lead_to_role() is missing. Apply 20261006000007 first.';
    RETURN;
  END IF;

  v_suffix := replace(substr(random()::text, 3), '.', '');
  v_digits := lpad(((random() * 9999999)::int)::text, 7, '0');

  -- ---------------------------------------------------------------------------
  -- Fixtures. The applicant is created as 'parent': app_role has no 'pending'
  -- value, so a B2 account sits on the least-privileged role until promoted.
  -- ---------------------------------------------------------------------------

  FOR v_role, v_name IN
    SELECT t.v_role, t.v_name
    FROM (VALUES
      ('admin'::app_role,  'Rawaan Operations'),
      ('parent'::app_role, 'Nasreen Bibi'),
      ('parent'::app_role, 'Applicant Gul Khan')
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
      crypt('d7-test-not-a-real-password', gen_salt('bf')),
      now(), now(), now(), '{}'::jsonb, '{}'::jsonb
    );

    INSERT INTO app_user (id, role, full_name) VALUES (v_auth_id, v_role, v_name);

    v_auth_ids := v_auth_ids || v_auth_id;

    IF v_role = 'admin' THEN
      v_admin_user := v_auth_id;
    ELSIF v_name LIKE 'Applicant%' THEN
      v_applicant := v_auth_id;
    ELSE
      v_parent_user := v_auth_id;
    END IF;
  END LOOP;

  INSERT INTO lead (source, contact_name, email, consent_at, consent_version)
  VALUES ('waitlist', 'Lifecycle Subject', format('life@%s.example', v_suffix),
          now(), '2026-01-consent-v3')
  RETURNING id INTO v_lead;

  INSERT INTO lead (source, contact_name, phone, app_user_id, consent_at, consent_version)
  VALUES ('driver_application', 'Applicant Gul Khan', '0345' || v_digits,
          v_applicant, now(), '2026-01-consent-v3')
  RETURNING id INTO v_app_lead;

  v_leads := ARRAY[v_lead, v_app_lead];

  -- ---------------------------------------------------------------------------
  -- 1. A lead with neither phone nor email is REJECTED
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO lead (source, contact_name, phone, email)
    VALUES ('contact_form', 'No Contact', '  ', NULL)
    RETURNING id INTO v_id;
    DELETE FROM lead WHERE id = v_id;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s', '1: a lead with no phone and no email was accepted');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ck_lead_contact_present%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  1: wrong reason, expected ck_lead_contact_present, got: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 1: ck_lead_contact_present refused a lead with no way to reach them';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 2. consent_at without consent_version is REJECTED
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO lead (source, contact_name, email, consent_at)
    VALUES ('waitlist', 'Half Consent', format('half@%s.example', v_suffix), now())
    RETURNING id INTO v_id;
    DELETE FROM lead WHERE id = v_id;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s', '2: consent_at without consent_version was accepted');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ck_lead_consent_paired%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  2: wrong reason, expected ck_lead_consent_paired, got: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 2: ck_lead_consent_paired refused unpaired consent';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 3. A lead cannot be born past 'new'
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO lead (source, contact_name, email, status)
    VALUES ('waitlist', 'Born Qualified', format('born@%s.example', v_suffix), 'qualified')
    RETURNING id INTO v_id;
    DELETE FROM lead WHERE id = v_id;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s', '3: a lead was inserted with status qualified');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%trg_lead_status_lifecycle%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  3: wrong reason, expected trg_lead_status_lifecycle, got: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 3: trg_lead_status_lifecycle refused an insert past new';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 4. Skipping a step (new -> qualified) is REJECTED
  -- ---------------------------------------------------------------------------

  BEGIN
    UPDATE lead SET status = 'qualified' WHERE id = v_lead;
    UPDATE lead SET status = 'new' WHERE id = v_lead;   -- not reached if guarded
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s', '4: new -> qualified was accepted');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%trg_lead_status_lifecycle%' OR SQLSTATE <> '23514' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  4: wrong reason, expected trg_lead_status_lifecycle/23514, got %s: %s', SQLSTATE, SQLERRM);
    ELSE
      RAISE NOTICE 'pass 4: trg_lead_status_lifecycle refused new -> qualified (23514)';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 5. new -> contacted is ALLOWED and stamps contacted_at
  -- ---------------------------------------------------------------------------

  BEGIN
    UPDATE lead SET status = 'contacted' WHERE id = v_lead;
    SELECT status, contacted_at INTO v_status, v_at FROM lead WHERE id = v_lead;
    IF v_status = 'contacted' AND v_at IS NOT NULL THEN
      RAISE NOTICE 'pass 5: new -> contacted accepted, contacted_at stamped';
    ELSE
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  5: expected contacted with contacted_at, got %s / %s', v_status, v_at);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  5: new -> contacted refused: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 6. Going backwards (contacted -> new) is REJECTED
  -- ---------------------------------------------------------------------------

  BEGIN
    UPDATE lead SET status = 'new' WHERE id = v_lead;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s', '6: contacted -> new was accepted');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%trg_lead_status_lifecycle%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  6: wrong reason, expected trg_lead_status_lifecycle, got: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 6: trg_lead_status_lifecycle refused contacted -> new';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 7. Closing without a reason, or with a blank one, is REJECTED
  -- ---------------------------------------------------------------------------

  BEGIN
    UPDATE lead SET status = 'closed' WHERE id = v_lead;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s', '7a: closed with no closed_reason was accepted');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ck_lead_closed_reason%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  7a: wrong reason, expected ck_lead_closed_reason, got: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 7a: ck_lead_closed_reason refused a close with no reason';
    END IF;
  END;

  BEGIN
    UPDATE lead SET status = 'closed', closed_reason = E' \t ' WHERE id = v_lead;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s', '7b: closed with a blank closed_reason was accepted');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ck_lead_closed_reason%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  7b: wrong reason, expected ck_lead_closed_reason, got: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 7b: ck_lead_closed_reason refused a blank reason';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 8. contacted -> closed WITH a reason is ALLOWED and stamps closed_at
  -- ---------------------------------------------------------------------------

  BEGIN
    UPDATE lead SET status = 'closed', closed_reason = 'outside service area' WHERE id = v_lead;
    SELECT status, closed_at INTO v_status, v_at FROM lead WHERE id = v_lead;
    IF v_status = 'closed' AND v_at IS NOT NULL THEN
      RAISE NOTICE 'pass 8: contacted -> closed accepted, closed_at stamped';
    ELSE
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  8: expected closed with closed_at, got %s / %s', v_status, v_at);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  8: contacted -> closed refused: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 9. closed is terminal: closed -> contacted is REJECTED
  -- ---------------------------------------------------------------------------

  BEGIN
    UPDATE lead SET status = 'contacted' WHERE id = v_lead;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s', '9: closed -> contacted was accepted');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%trg_lead_status_lifecycle%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  9: wrong reason, expected trg_lead_status_lifecycle, got: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 9: trg_lead_status_lifecycle refused reopening a closed lead';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 10. Dedup: same phone in a different format, same source, both open,
  --     is REJECTED
  -- ---------------------------------------------------------------------------

  INSERT INTO lead (source, contact_name, phone)
  VALUES ('waitlist', 'Dup A', '0300-' || v_digits)
  RETURNING id INTO v_dup_a;
  v_leads := v_leads || v_dup_a;

  BEGIN
    INSERT INTO lead (source, contact_name, phone)
    VALUES ('waitlist', 'Dup Same', '+92 300 ' || v_digits)
    RETURNING id INTO v_id;
    DELETE FROM lead WHERE id = v_id;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s', '10: a second open waitlist lead on the same phone was accepted');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%uq_lead_one_open_per_phone_source%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  10: wrong reason, expected uq_lead_one_open_per_phone_source, got: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 10: uq_lead_one_open_per_phone_source refused 0300-... vs +92 300 ...';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 11. Same phone, DIFFERENT source, is ALLOWED
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO lead (source, contact_name, phone)
    VALUES ('contact_form', 'Dup Other Source', '92300' || v_digits)
    RETURNING id INTO v_dup_b;
    v_leads := v_leads || v_dup_b;
    RAISE NOTICE 'pass 11: the same phone is accepted under another source';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  11: same phone under a different source refused: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 12. Once the first lead closes, the same phone/source is ALLOWED again
  -- ---------------------------------------------------------------------------

  BEGIN
    UPDATE lead SET status = 'closed', closed_reason = 'duplicate test close' WHERE id = v_dup_a;
    INSERT INTO lead (source, contact_name, phone)
    VALUES ('waitlist', 'Dup After Close', '+92 300 ' || v_digits)
    RETURNING id INTO v_dup_c;
    v_leads := v_leads || v_dup_c;
    RAISE NOTICE 'pass 12: the phone may return as a new lead after the first one closed';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  12: re-inserting after close refused: %s', SQLERRM);
  END;

  -- Move the application to qualified, the only state promotion accepts.
  UPDATE lead SET status = 'contacted' WHERE id = v_app_lead;
  UPDATE lead SET status = 'qualified' WHERE id = v_app_lead;

  -- ---------------------------------------------------------------------------
  -- 13. promote_lead_to_role is REFUSED for a non-admin (42501)
  -- ---------------------------------------------------------------------------

  PERFORM set_config('request.jwt.claim.sub', v_parent_user::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    PERFORM promote_lead_to_role(v_app_lead, 'driver');
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s', '13: a parent promoted a lead');
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> '42501' OR SQLERRM NOT LIKE '%promote_lead_to_role: admin only%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  13: wrong reason, expected 42501 admin only, got %s: %s', SQLSTATE, SQLERRM);
    ELSE
      RAISE NOTICE 'pass 13: promote_lead_to_role refused a non-admin with 42501';
    END IF;
  END;
  RESET ROLE;

  -- ---------------------------------------------------------------------------
  -- 14. An admin may not promote to a role other than driver/school
  -- ---------------------------------------------------------------------------

  PERFORM set_config('request.jwt.claim.sub', v_admin_user::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    PERFORM promote_lead_to_role(v_app_lead, 'admin');
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s', '14: a lead was promoted to admin');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%role must be driver or school%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  14: wrong reason, expected the driver/school guard, got: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 14: promote_lead_to_role refused promotion to admin';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 15. An admin promotes the qualified application: role driver, converted
  -- ---------------------------------------------------------------------------

  BEGIN
    PERFORM promote_lead_to_role(v_app_lead, 'driver');
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  15: admin promotion refused: %s', SQLERRM);
  END;
  RESET ROLE;
  PERFORM set_config('request.jwt.claim.sub', '', true);

  SELECT role INTO v_got_role FROM app_user WHERE id = v_applicant;
  SELECT status, converted_at INTO v_status, v_at FROM lead WHERE id = v_app_lead;
  IF v_got_role = 'driver' AND v_status = 'converted' AND v_at IS NOT NULL THEN
    RAISE NOTICE 'pass 15: admin promotion set role driver and converted the lead';
  ELSE
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  15: expected driver/converted/stamped, got %s / %s / %s',
      v_got_role, v_status, v_at);
  END IF;

  -- ---------------------------------------------------------------------------
  -- 16. converted is terminal: converted -> closed is REJECTED
  -- ---------------------------------------------------------------------------

  BEGIN
    UPDATE lead SET status = 'closed', closed_reason = 'changed mind' WHERE id = v_app_lead;
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  %s', '16: converted -> closed was accepted');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%trg_lead_status_lifecycle%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  16: wrong reason, expected trg_lead_status_lifecycle, got: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 16: trg_lead_status_lifecycle refused closing a converted lead';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- Cleanup. Runs before the summary so a failing run leaves no fixtures.
  -- ---------------------------------------------------------------------------

  BEGIN
    DELETE FROM lead       WHERE id = ANY (v_leads) OR app_user_id = ANY (v_auth_ids);
    DELETE FROM app_user   WHERE id = ANY (v_auth_ids);
    DELETE FROM auth.users WHERE id = ANY (v_auth_ids);
    RAISE NOTICE 'fixtures for run % removed', v_suffix;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'cleanup failed (all fixtures are namespaced with % and cannot collide with a later run): %',
      v_suffix, SQLERRM;
  END;

  -- ---------------------------------------------------------------------------
  -- Report
  -- ---------------------------------------------------------------------------

  IF v_failures = 0 THEN
    RAISE NOTICE 'D7: all 16 assertions passed.';
  ELSE
    RAISE EXCEPTION 'D7: % assertion(s) failed:%', v_failures, v_msg;
  END IF;
END
$test$;
