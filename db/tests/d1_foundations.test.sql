-- =============================================================================
-- D1 test — foundations, enums, app_user, role helpers
-- =============================================================================
-- Executable assertions for 20261006000001_d1_foundations.sql. Same style as
-- d3/d4: one DO block, every assertion in its own BEGIN ... EXCEPTION
-- sub-block (a savepoint), failures accumulated and reported in ONE exception
-- at the end, negative cases checked against the constraint NAME, fixtures
-- namespaced with a random() suffix and removed before the report.
--
-- The role helpers are the single source of truth for "who is calling" that
-- every D8 policy will lean on, so they are exercised while impersonating a
-- real user under the `authenticated` role, exactly as Supabase calls them.
-- =============================================================================

SET search_path TO public, extensions;

DO $test$
DECLARE
  v_suffix     text;
  v_parent     uuid;
  v_admin      uuid;
  v_inactive   uuid;
  v_auth_ids   uuid[] := '{}';
  v_role       app_role;
  v_name       text;
  v_active     boolean;
  v_auth_id    uuid;

  v_uid        uuid;
  v_app_role   app_role;
  v_is_admin   boolean;

  v_enum       text;
  v_expected   text[];
  v_actual     text[];
  v_fn         text;
  v_secdef     boolean;
  v_config     text[];
  v_old        timestamptz;
  v_new        timestamptz;
  v_id         uuid;
  v_checked    int := 0;

  v_failures   int := 0;
  v_msg        text := '';
BEGIN
  IF to_regclass('app_user') IS NULL THEN
    RAISE NOTICE 'D1 test SKIPPED: relation "app_user" does not exist. Apply D1 first.';
    RETURN;
  END IF;

  v_suffix := replace(substr(random()::text, 3), '.', '');

  -- ---------------------------------------------------------------------------
  -- Fixtures: an active parent, an active admin, an INACTIVE admin. The
  -- inactive admin is the dangerous case: a deactivated staff account must
  -- lose every privilege at once, without anyone having to change its role.
  -- ---------------------------------------------------------------------------

  FOR v_role, v_name, v_active IN
    SELECT * FROM (VALUES
      ('parent'::app_role, 'Nasreen Bibi',        true),
      ('admin'::app_role,  'Rawaan Operations',   true),
      ('admin'::app_role,  'Former Ops Account',  false)
    ) AS t(r, n, a)
  LOOP
    v_auth_id := gen_random_uuid();
    INSERT INTO auth.users (id, aud, role, email, created_at, updated_at,
                            raw_app_meta_data, raw_user_meta_data)
    VALUES (v_auth_id, 'authenticated', 'authenticated',
            format('%s@%s.example', lower(replace(v_name, ' ', '.')), v_suffix),
            now(), now(), '{}'::jsonb, '{}'::jsonb);
    -- updated_at is backdated so assertion 13 can see the trigger move it:
    -- now() is frozen for the whole transaction this test runs in.
    INSERT INTO app_user (id, role, full_name, is_active, updated_at)
    VALUES (v_auth_id, v_role, v_name, v_active, timestamptz '2000-01-01 00:00+00');
    v_auth_ids := v_auth_ids || v_auth_id;
  END LOOP;
  v_parent   := v_auth_ids[1];
  v_admin    := v_auth_ids[2];
  v_inactive := v_auth_ids[3];

  -- ---------------------------------------------------------------------------
  -- 1. assert_updated_at_convention() holds for the whole schema
  -- ---------------------------------------------------------------------------

  BEGIN
    IF assert_updated_at_convention() IS NOT TRUE THEN
      RAISE EXCEPTION 'assert_updated_at_convention() returned false: a table lacks updated_at';
    END IF;
    RAISE NOTICE 'pass 1: every table carries updated_at';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  1: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 2. Every D1 enum has exactly the documented values, in order. Adding a
  --    value silently widens every policy and CASE that switches on it.
  -- ---------------------------------------------------------------------------

  FOR v_enum, v_expected IN
    SELECT * FROM (VALUES
      ('app_role',            ARRAY['parent','driver','school','admin']),
      ('verification_status', ARRAY['not_submitted','pending_review','needs_resubmission',
                                    'approved','rejected','suspended']),
      ('document_type',       ARRAY['cnic_front','cnic_back','driving_license',
                                    'police_character_certificate','vehicle_registration',
                                    'insurance_policy']),
      ('enrollment_status',   ARRAY['active','paused','ended']),
      ('trip_status',         ARRAY['scheduled','driver_en_route','arrived_pickup','in_progress',
                                    'arrived_school','completed','cancelled','no_show']),
      ('checkin_method',      ARRAY['qr_scan','manual_override']),
      ('checkin_result',      ARRAY['success','already_checked_in','wrong_trip','wrong_child',
                                    'expired_token','child_absent']),
      ('absence_status',      ARRAY['submitted','acknowledged','cancelled']),
      ('invoice_status',      ARRAY['draft','issued','paid','overdue','void']),
      ('payment_status',      ARRAY['awaiting_submission','submitted','confirmed','failed',
                                    'rejected','refunded']),
      ('payout_status',       ARRAY['pending','processing','paid','failed','cancelled']),
      ('lead_status',         ARRAY['new','contacted','qualified','converted','closed']),
      ('lead_source',         ARRAY['waitlist','school_inquiry','driver_application','contact_form'])
    ) AS t(e, x)
  LOOP
    BEGIN
      SELECT array_agg(en.enumlabel::text ORDER BY en.enumsortorder) INTO v_actual
        FROM pg_enum en
        JOIN pg_type ty ON ty.oid = en.enumtypid
       WHERE ty.typname = v_enum
         AND ty.typnamespace = current_schema()::regnamespace;
      IF v_actual IS DISTINCT FROM v_expected THEN
        RAISE EXCEPTION 'enum % is %, expected %', v_enum, v_actual, v_expected;
      END IF;
      v_checked := v_checked + 1;
    EXCEPTION WHEN OTHERS THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  2: %s', SQLERRM);
    END;
  END LOOP;
  RAISE NOTICE 'pass 2: % of 13 enums have exactly their documented values', v_checked;

  -- ---------------------------------------------------------------------------
  -- 3. Role helpers while impersonating an ACTIVE parent under `authenticated`
  -- ---------------------------------------------------------------------------

  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_parent::text, true);
    SET LOCAL ROLE authenticated;
    SELECT current_app_user_id(), current_app_role(), is_admin()
      INTO v_uid, v_app_role, v_is_admin;
    RESET ROLE;
    IF v_uid IS DISTINCT FROM v_parent OR v_app_role IS DISTINCT FROM 'parent'
       OR v_is_admin IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'parent: got id=% role=% admin=%', v_uid, v_app_role, v_is_admin;
    END IF;
    RAISE NOTICE 'pass 3: an active parent resolves to its own id, role parent, not admin';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  3: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 4. Role helpers while impersonating an ACTIVE admin
  -- ---------------------------------------------------------------------------

  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);
    SET LOCAL ROLE authenticated;
    SELECT current_app_user_id(), current_app_role(), is_admin()
      INTO v_uid, v_app_role, v_is_admin;
    RESET ROLE;
    IF v_uid IS DISTINCT FROM v_admin OR v_app_role IS DISTINCT FROM 'admin'
       OR v_is_admin IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'admin: got id=% role=% admin=%', v_uid, v_app_role, v_is_admin;
    END IF;
    RAISE NOTICE 'pass 4: an active admin resolves to role admin and is_admin() = true';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  4: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 5. An INACTIVE admin gets nothing: NULL id, NULL role, is_admin() false
  -- ---------------------------------------------------------------------------

  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_inactive::text, true);
    SET LOCAL ROLE authenticated;
    SELECT current_app_user_id(), current_app_role(), is_admin()
      INTO v_uid, v_app_role, v_is_admin;
    RESET ROLE;
    IF v_uid IS NOT NULL OR v_app_role IS NOT NULL OR v_is_admin IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'inactive admin: got id=% role=% admin=%', v_uid, v_app_role, v_is_admin;
    END IF;
    RAISE NOTICE 'pass 5: a deactivated admin resolves to NULL / NULL / false';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  5: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 6. Unauthenticated (no sub claim, anon role): NULL / NULL / false.
  --    is_admin() must be false, never NULL: NULL in a policy is easy to
  --    mis-handle with NOT.
  -- ---------------------------------------------------------------------------

  BEGIN
    PERFORM set_config('request.jwt.claim.sub', '', true);
    SET LOCAL ROLE anon;
    SELECT current_app_user_id(), current_app_role(), is_admin()
      INTO v_uid, v_app_role, v_is_admin;
    RESET ROLE;
    IF v_uid IS NOT NULL OR v_app_role IS NOT NULL OR v_is_admin IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'anon: got id=% role=% admin=%', v_uid, v_app_role, v_is_admin;
    END IF;
    RAISE NOTICE 'pass 6: unauthenticated resolves to NULL / NULL / false';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  6: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 7. The helpers are SECURITY DEFINER with search_path pinned to
  --    <schema>, pg_temp. Without the pin, anyone who can create an object on
  --    the caller's path could shadow app_user and forge a role.
  -- ---------------------------------------------------------------------------

  FOREACH v_fn IN ARRAY ARRAY['current_app_user_id', 'current_app_role', 'is_admin'] LOOP
    BEGIN
      SELECT p.prosecdef, p.proconfig INTO v_secdef, v_config
        FROM pg_proc p
       WHERE p.proname = v_fn AND p.pronamespace = current_schema()::regnamespace;
      IF v_secdef IS NOT TRUE THEN
        RAISE EXCEPTION '%() is not SECURITY DEFINER', v_fn;
      END IF;
      IF v_config IS NULL
         OR NOT (format('search_path=%s, pg_temp', current_schema()) = ANY (v_config)) THEN
        RAISE EXCEPTION '%() search_path is not pinned to %, pg_temp: proconfig=%',
          v_fn, current_schema(), v_config;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  7: %s', SQLERRM);
    END;
  END LOOP;
  RAISE NOTICE 'pass 7: role helpers checked for SECURITY DEFINER and a pinned search_path';

  -- ---------------------------------------------------------------------------
  -- 8. ck_app_user_consent_paired: consent time without version is refused
  -- 9. ck_app_user_consent_paired: version without consent time is refused
  -- 10. Both together are accepted
  -- ---------------------------------------------------------------------------

  BEGIN
    UPDATE app_user SET consent_given_at = now() WHERE id = v_parent;
    UPDATE app_user SET consent_given_at = NULL WHERE id = v_parent;
    v_failures := v_failures + 1;
    v_msg := v_msg || E'\n  8: consent_given_at without consent_version was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ck_app_user_consent_paired%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  8: refused for the wrong reason: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 8: ck_app_user_consent_paired refused a time without a version';
    END IF;
  END;

  BEGIN
    UPDATE app_user SET consent_version = 'v3' WHERE id = v_parent;
    UPDATE app_user SET consent_version = NULL WHERE id = v_parent;
    v_failures := v_failures + 1;
    v_msg := v_msg || E'\n  9: consent_version without consent_given_at was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ck_app_user_consent_paired%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  9: refused for the wrong reason: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 9: ck_app_user_consent_paired refused a version without a time';
    END IF;
  END;

  BEGIN
    UPDATE app_user SET consent_given_at = now(), consent_version = '2026-01-consent-v3'
     WHERE id = v_parent;
    RAISE NOTICE 'pass 10: consent time and version together are accepted';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  10: paired consent was refused: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 11. preferred_locale outside ('en', 'ur') is refused
  -- 12. 'ur' is accepted
  -- ---------------------------------------------------------------------------

  BEGIN
    UPDATE app_user SET preferred_locale = 'fr' WHERE id = v_parent;
    UPDATE app_user SET preferred_locale = 'en' WHERE id = v_parent;
    v_failures := v_failures + 1;
    v_msg := v_msg || E'\n  11: preferred_locale ''fr'' was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%app_user_preferred_locale_check%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  11: refused for the wrong reason: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 11: app_user_preferred_locale_check refused ''fr''';
    END IF;
  END;

  BEGIN
    UPDATE app_user SET preferred_locale = 'ur' WHERE id = v_parent;
    RAISE NOTICE 'pass 12: preferred_locale ''ur'' is accepted';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  12: preferred_locale ''ur'' was refused: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 13. trg_app_user_updated_at bumps updated_at, and wins over a caller who
  --     tries to set it explicitly. The admin fixture was inserted backdated
  --     and has not been updated since.
  -- ---------------------------------------------------------------------------

  BEGIN
    SELECT updated_at INTO v_old FROM app_user WHERE id = v_admin;

    UPDATE app_user SET full_name = 'Rawaan Ops', updated_at = timestamptz '1999-01-01 00:00+00'
     WHERE id = v_admin;
    SELECT updated_at INTO v_new FROM app_user WHERE id = v_admin;

    IF v_old <> timestamptz '2000-01-01 00:00+00' OR v_new IS DISTINCT FROM now() THEN
      RAISE EXCEPTION 'updated_at went % -> %, expected now() = %', v_old, v_new, now();
    END IF;
    RAISE NOTICE 'pass 13: trg_app_user_updated_at set updated_at to now() on UPDATE';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  13: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- Cleanup, then report
  -- ---------------------------------------------------------------------------

  BEGIN
    PERFORM set_config('request.jwt.claim.sub', '', true);
    DELETE FROM app_user   WHERE id = ANY (v_auth_ids);
    DELETE FROM auth.users WHERE id = ANY (v_auth_ids);
    RAISE NOTICE 'fixtures for run % removed', v_suffix;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'cleanup failed for run %: %', v_suffix, SQLERRM;
  END;

  IF v_failures = 0 THEN
    RAISE NOTICE 'D1: all 13 assertions passed (13 enums, 3 helpers checked individually).';
  ELSE
    RAISE EXCEPTION 'D1: % assertion(s) failed:%', v_failures, v_msg;
  END IF;
END
$test$;
