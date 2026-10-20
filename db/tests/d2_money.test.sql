-- =============================================================================
-- D2 test — money: allocate_split, rate snapshots, invoices, payments, payouts
-- =============================================================================
-- Executable assertions for 20261006000002_d2_money.sql. Same style as d3/d4:
-- one DO block, every assertion in its own BEGIN ... EXCEPTION sub-block,
-- failures accumulated and reported in ONE exception at the end, negative
-- cases checked against the constraint NAME, a row that should have been
-- refused is deleted again before the failure is counted, fixtures namespaced
-- with a random() suffix and removed before the report.
--
-- REAL FIXTURES. D2 runs before D3, so its school / enrollment / guardian
-- columns start life as bare uuids; D5 adds the foreign keys. Every id used
-- here is therefore a real row (auth.users -> app_user -> school -> student ->
-- guardian -> enrollment), so this file passes both before and after D5.
-- =============================================================================

SET search_path TO public, extensions;

DO $test$
DECLARE
  v_suffix      text;
  v_parent      uuid;
  v_admin       uuid;
  v_auth_ids    uuid[] := '{}';
  v_school      uuid;
  v_student     uuid;
  v_guardian    uuid;
  v_enrollment  uuid;
  v_period      uuid;
  v_invoice     uuid;
  v_line        uuid;
  v_rate_open   uuid;

  v_id          uuid;
  v_combos      int;
  v_bad         int;
  v_d           bigint;
  v_s           bigint;
  v_r           bigint;
  v_case        text;
  v_fee         bigint;
  v_dbps        int;
  v_sbps        int;
  v_reason      text;
  v_sub         int := 0;

  v_failures    int := 0;
  v_msg         text := '';
BEGIN
  IF to_regprocedure('allocate_split(bigint, int, int)') IS NULL
     OR to_regclass('payout_line') IS NULL THEN
    RAISE NOTICE 'D2 test SKIPPED: D2 is not applied.';
    RETURN;
  END IF;
  IF to_regclass('enrollment') IS NULL THEN
    RAISE NOTICE 'D2 test SKIPPED: the fixtures need D3 (school, student, guardian, enrollment).';
    RETURN;
  END IF;

  v_suffix := replace(substr(random()::text, 3), '.', '');

  -- ---------------------------------------------------------------------------
  -- Fixtures
  -- ---------------------------------------------------------------------------

  v_parent := gen_random_uuid();
  v_admin  := gen_random_uuid();
  v_auth_ids := ARRAY[v_parent, v_admin];
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  VALUES (v_parent, 'authenticated', 'authenticated', format('parent@%s.example', v_suffix),
          now(), now(), '{}'::jsonb, '{}'::jsonb),
         (v_admin, 'authenticated', 'authenticated', format('ops@%s.example', v_suffix),
          now(), now(), '{}'::jsonb, '{}'::jsonb);
  INSERT INTO app_user (id, role, full_name, consent_given_at, consent_version)
  VALUES (v_parent, 'parent', 'Nasreen Bibi', now(), '2026-01-consent-v3');
  INSERT INTO app_user (id, role, full_name)
  VALUES (v_admin, 'admin', 'Rawaan Operations');

  INSERT INTO school (name, slug, address, city)
  VALUES ('D2 Test School ' || v_suffix, 'd2-test-' || v_suffix, 'University Road', 'Peshawar')
  RETURNING id INTO v_school;

  INSERT INTO student (full_name, date_of_birth, school_id, grade)
  VALUES ('Ayesha Khan', '2014-04-09', v_school, 'Grade 5')
  RETURNING id INTO v_student;

  INSERT INTO guardian (app_user_id, student_id, relationship, is_primary,
                        can_manage_payments, consent_at, consent_version)
  VALUES (v_parent, v_student, 'mother', true, true, now(), '2026-01-consent-v3')
  RETURNING id INTO v_guardian;

  -- route_id stays NULL: D5 turns it into a real FK to route.
  INSERT INTO enrollment (student_id, school_id, guardian_id, status, starts_on,
                          fee_paisa, driver_bps, school_bps, rawaan_bps)
  VALUES (v_student, v_school, v_guardian, 'active', DATE '2026-01-01',
          400000, 8000, 1000, 1000)
  RETURNING id INTO v_enrollment;

  INSERT INTO rate_snapshot (school_id, effective_from, fee_paisa,
                             driver_bps, school_bps, rawaan_bps, created_by)
  VALUES (v_school, DATE '2026-01-01', 400000, 8000, 1000, 1000, v_admin)
  RETURNING id INTO v_rate_open;

  INSERT INTO billing_period (school_id, period_start, period_end, period_label)
  VALUES (v_school, DATE '2026-03-01', DATE '2026-03-31', '2026-03')
  RETURNING id INTO v_period;

  INSERT INTO invoice (enrollment_id, billing_period_id, guardian_id, school_id,
                       subtotal_paisa, discount_paisa, total_paisa)
  VALUES (v_enrollment, v_period, v_guardian, v_school, 400000, 0, 400000)
  RETURNING id INTO v_invoice;

  INSERT INTO invoice_line (invoice_id, line_type, description, unit_paisa, amount_paisa,
                            driver_bps, school_bps, rawaan_bps)
  VALUES (v_invoice, 'transport_fee', 'Transport, March 2026', 400000, 400000, 8000, 1000, 1000)
  RETURNING id INTO v_line;

  -- ---------------------------------------------------------------------------
  -- 1. allocate_split sums EXACTLY to the fee over >= 10,000 combinations,
  --    with driver and school flooring and Rawaan taking a non-negative
  --    remainder. Edge fees, odd primes, the full bps grid at 250 bps steps,
  --    the bps boundaries, and 2,000 pseudo-random large fees.
  -- ---------------------------------------------------------------------------

  BEGIN
    WITH fees(fee) AS (
      SELECT unnest(ARRAY[0, 1, 2, 3, 7, 13, 97, 101, 9973, 9999, 10000, 10001,
                          7919, 104729, 399999, 400000, 400001, 999983,
                          2147483647, 1000000000039]::bigint[])
    ),
    grid(d, s) AS (
      SELECT d, s
        FROM generate_series(0, 10000, 250) d,
             generate_series(0, 10000, 250) s
       WHERE d + s <= 10000
      UNION
      SELECT * FROM (VALUES (1, 1), (9999, 1), (1, 9999), (9999, 0), (0, 9999),
                            (3333, 3333), (8000, 1500), (8000, 1000)) b(d, s)
    ),
    combos(fee, d, s) AS (
      SELECT f.fee, g.d, g.s FROM fees f CROSS JOIN grid g
      UNION
      SELECT r.fee, r.d, (abs(hashint4(r.i + 7919)) % (10001 - r.d))::int
        FROM (SELECT i, (abs(hashint8(i)) % 100000000000)::bigint AS fee,
                     (abs(hashint4(i)) % 10001)::int AS d
                FROM generate_series(1, 2000) i) r
    ),
    legs AS (
      SELECT c.fee, c.d, c.s,
             sum(a.amount_paisa) AS total,
             count(*)            AS n,
             max(a.amount_paisa) FILTER (WHERE a.beneficiary_type = 'driver') AS drv,
             max(a.amount_paisa) FILTER (WHERE a.beneficiary_type = 'school') AS sch,
             max(a.amount_paisa) FILTER (WHERE a.beneficiary_type = 'rawaan') AS raw
        FROM combos c
        CROSS JOIN LATERAL allocate_split(c.fee, c.d, c.s) a
       GROUP BY c.fee, c.d, c.s
    )
    SELECT count(*)::int,
           count(*) FILTER (WHERE total <> fee
                               OR n <> 3
                               OR drv <> (fee * d) / 10000
                               OR sch <> (fee * s) / 10000
                               OR raw < 0)::int
      INTO v_combos, v_bad
      FROM legs;

    IF v_combos < 10000 THEN
      RAISE EXCEPTION 'only % combinations exercised, need >= 10000', v_combos;
    END IF;
    IF v_bad <> 0 THEN
      RAISE EXCEPTION '% of % combinations did not sum exactly / floor correctly', v_bad, v_combos;
    END IF;
    RAISE NOTICE 'pass 1: allocate_split exact over % combinations', v_combos;
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  1: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 2. Baseline splits from MASTER_CONTEXT.md section 3
  -- ---------------------------------------------------------------------------

  BEGIN
    SELECT max(amount_paisa) FILTER (WHERE beneficiary_type = 'driver'),
           max(amount_paisa) FILTER (WHERE beneficiary_type = 'school'),
           max(amount_paisa) FILTER (WHERE beneficiary_type = 'rawaan')
      INTO v_d, v_s, v_r FROM allocate_split(400000, 8000, 1000);
    IF (v_d, v_s, v_r) IS DISTINCT FROM (320000::bigint, 40000::bigint, 40000::bigint) THEN
      RAISE EXCEPTION 'standard split gave %/%/%', v_d, v_s, v_r;
    END IF;
    SELECT max(amount_paisa) FILTER (WHERE beneficiary_type = 'driver'),
           max(amount_paisa) FILTER (WHERE beneficiary_type = 'school'),
           max(amount_paisa) FILTER (WHERE beneficiary_type = 'rawaan')
      INTO v_d, v_s, v_r FROM allocate_split(400000, 8000, 1500);
    IF (v_d, v_s, v_r) IS DISTINCT FROM (320000::bigint, 60000::bigint, 20000::bigint) THEN
      RAISE EXCEPTION 'founding split gave %/%/%', v_d, v_s, v_r;
    END IF;
    RAISE NOTICE 'pass 2: standard 320000/40000/40000 and founding 320000/60000/20000';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  2: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 3. allocate_split refuses bad input with SQLSTATE 22023
  -- ---------------------------------------------------------------------------

  FOR v_case, v_fee, v_dbps, v_sbps IN
    SELECT * FROM (VALUES
      ('negative fee',          -1::bigint, 8000,  1000),
      ('NULL fee',              NULL,       8000,  1000),
      ('driver_bps < 0',        400000,     -1,    1000),
      ('driver_bps > 10000',    400000,     10001, 0),
      ('school_bps < 0',        400000,     8000,  -1),
      ('school_bps > 10000',    400000,     0,     10001),
      ('NULL bps',              400000,     NULL,  1000),
      ('driver + school 10001', 400000,     8000,  2001)
    ) AS t(c, f, d, s)
  LOOP
    BEGIN
      PERFORM * FROM allocate_split(v_fee, v_dbps, v_sbps);
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  3: allocate_split accepted %s', v_case);
    EXCEPTION WHEN OTHERS THEN
      IF SQLSTATE <> '22023' THEN
        v_failures := v_failures + 1;
        v_msg := v_msg || format(E'\n  3: %s raised %s, expected 22023: %s', v_case, SQLSTATE, SQLERRM);
      ELSE
        v_sub := v_sub + 1;
      END IF;
    END;
  END LOOP;
  RAISE NOTICE 'pass 3: % of 8 bad inputs raised 22023', v_sub;

  -- ---------------------------------------------------------------------------
  -- 4. ck_rate_snapshot_bps_sum_10000
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO rate_snapshot (school_id, effective_from, effective_to, fee_paisa,
                               driver_bps, school_bps, rawaan_bps)
    VALUES (v_school, DATE '2025-01-01', DATE '2025-12-31', 400000, 8000, 1000, 1001)
    RETURNING id INTO v_id;
    DELETE FROM rate_snapshot WHERE id = v_id;
    v_failures := v_failures + 1;
    v_msg := v_msg || E'\n  4: rate_snapshot accepted a triple summing to 10001';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ck_rate_snapshot_bps_sum_10000%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  4: wrong reason: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 4: ck_rate_snapshot_bps_sum_10000';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 5. uq_rate_snapshot_school_id_open_ended: a second open-ended row refused
  -- 6. ... while a closed historical row beside the open one is fine
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO rate_snapshot (school_id, effective_from, fee_paisa,
                               driver_bps, school_bps, rawaan_bps, is_founding_school)
    VALUES (v_school, DATE '2026-06-01', 400000, 8000, 1500, 500, true)
    RETURNING id INTO v_id;
    DELETE FROM rate_snapshot WHERE id = v_id;
    v_failures := v_failures + 1;
    v_msg := v_msg || E'\n  5: a second open-ended rate_snapshot was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%uq_rate_snapshot_school_id_open_ended%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  5: wrong reason: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 5: uq_rate_snapshot_school_id_open_ended';
    END IF;
  END;

  BEGIN
    INSERT INTO rate_snapshot (school_id, effective_from, effective_to, fee_paisa,
                               driver_bps, school_bps, rawaan_bps, is_founding_school)
    VALUES (v_school, DATE '2025-01-01', DATE '2025-12-31', 400000, 8000, 1500, 500, true);
    RAISE NOTICE 'pass 6: a closed rate_snapshot coexists with the open one';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  6: closed rate_snapshot refused: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 7. uq_billing_period_school_id_period_start
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO billing_period (school_id, period_start, period_end, period_label)
    VALUES (v_school, DATE '2026-03-01', DATE '2026-03-31', '2026-03 again')
    RETURNING id INTO v_id;
    DELETE FROM billing_period WHERE id = v_id;
    v_failures := v_failures + 1;
    v_msg := v_msg || E'\n  7: a duplicate billing_period was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%uq_billing_period_school_id_period_start%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  7: wrong reason: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 7: uq_billing_period_school_id_period_start';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 8. ck_invoice_total_equals_subtotal_less_discount (on UPDATE of the
  --    fixture, so the enrollment/period unique constraint cannot fire first)
  -- 9. uq_invoice_enrollment_id_billing_period_id: no double-issue
  -- ---------------------------------------------------------------------------

  BEGIN
    UPDATE invoice SET discount_paisa = 10000 WHERE id = v_invoice;
    UPDATE invoice SET discount_paisa = 0 WHERE id = v_invoice;
    v_failures := v_failures + 1;
    v_msg := v_msg || E'\n  8: invoice total disagreeing with subtotal - discount was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ck_invoice_total_equals_subtotal_less_discount%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  8: wrong reason: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 8: ck_invoice_total_equals_subtotal_less_discount';
    END IF;
  END;

  BEGIN
    INSERT INTO invoice (enrollment_id, billing_period_id, guardian_id, school_id,
                         subtotal_paisa, total_paisa)
    VALUES (v_enrollment, v_period, v_guardian, v_school, 400000, 400000)
    RETURNING id INTO v_id;
    DELETE FROM invoice WHERE id = v_id;
    v_failures := v_failures + 1;
    v_msg := v_msg || E'\n  9: a second invoice for the same enrollment and period was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%uq_invoice_enrollment_id_billing_period_id%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  9: wrong reason: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 9: uq_invoice_enrollment_id_billing_period_id';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 10. ck_invoice_line_bps_sum_10000
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO invoice_line (invoice_id, line_type, description, amount_paisa,
                              driver_bps, school_bps, rawaan_bps)
    VALUES (v_invoice, 'adjustment', 'bad triple', 100, 8000, 1000, 999)
    RETURNING id INTO v_id;
    DELETE FROM invoice_line WHERE id = v_id;
    v_failures := v_failures + 1;
    v_msg := v_msg || E'\n  10: invoice_line accepted a triple summing to 9999';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ck_invoice_line_bps_sum_10000%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  10: wrong reason: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 10: ck_invoice_line_bps_sum_10000';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 11. split_allocation: a Rawaan leg WITH a beneficiary is refused
  -- 12. split_allocation: a driver leg WITHOUT a beneficiary is refused
  -- 13. the legal shapes (school with id, rawaan without) are accepted
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO split_allocation (invoice_line_id, beneficiary_type, beneficiary_id,
                                  amount_paisa, rate_bps)
    VALUES (v_line, 'rawaan', v_school, 40000, 1000)
    RETURNING id INTO v_id;
    DELETE FROM split_allocation WHERE id = v_id;
    v_failures := v_failures + 1;
    v_msg := v_msg || E'\n  11: a rawaan leg with a beneficiary_id was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ck_split_allocation_beneficiary_id_required%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  11: wrong reason: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 11: ck_split_allocation_beneficiary_id_required (rawaan with id)';
    END IF;
  END;

  BEGIN
    INSERT INTO split_allocation (invoice_line_id, beneficiary_type, beneficiary_id,
                                  amount_paisa, rate_bps)
    VALUES (v_line, 'driver', NULL, 320000, 8000)
    RETURNING id INTO v_id;
    DELETE FROM split_allocation WHERE id = v_id;
    v_failures := v_failures + 1;
    v_msg := v_msg || E'\n  12: a driver leg without a beneficiary_id was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ck_split_allocation_beneficiary_id_required%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  12: wrong reason: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 12: ck_split_allocation_beneficiary_id_required (driver without id)';
    END IF;
  END;

  BEGIN
    INSERT INTO split_allocation (invoice_line_id, beneficiary_type, beneficiary_id,
                                  amount_paisa, rate_bps)
    VALUES (v_line, 'school', v_school, 40000, 1000),
           (v_line, 'rawaan', NULL,     40000, 1000);
    RAISE NOTICE 'pass 13: school-with-id and rawaan-without-id legs are accepted';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  13: legal split_allocation legs refused: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 14. ck_payment_provider_triple_paired: a txn id without provider/merchant
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO payment (invoice_id, guardian_id, amount_paisa, method, provider_txn_id)
    VALUES (v_invoice, v_guardian, 400000, 'jazzcash', 'TID-' || v_suffix)
    RETURNING id INTO v_id;
    DELETE FROM payment WHERE id = v_id;
    v_failures := v_failures + 1;
    v_msg := v_msg || E'\n  14: a half-filled provider triple was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ck_payment_provider_triple_paired%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  14: wrong reason: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 14: ck_payment_provider_triple_paired';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 15. uq_payment_provider_merchant_account_id_provider_txn_id: the same
  --     mobile transaction cannot pay twice
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO payment (invoice_id, guardian_id, amount_paisa, method,
                         provider, merchant_account_id, provider_txn_id, idempotency_key)
    VALUES (v_invoice, v_guardian, 400000, 'jazzcash',
            'jazzcash', 'MA-' || v_suffix, 'TID-' || v_suffix, 'idem-' || v_suffix);
    BEGIN
      INSERT INTO payment (invoice_id, guardian_id, amount_paisa, method,
                           provider, merchant_account_id, provider_txn_id)
      VALUES (v_invoice, v_guardian, 400000, 'jazzcash',
              'jazzcash', 'MA-' || v_suffix, 'TID-' || v_suffix)
      RETURNING id INTO v_id;
      DELETE FROM payment WHERE id = v_id;
      v_failures := v_failures + 1;
      v_msg := v_msg || E'\n  15: a duplicate provider transaction was accepted';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%uq_payment_provider_merchant_account_id_provider_txn_id%' THEN
        v_failures := v_failures + 1;
        v_msg := v_msg || format(E'\n  15: wrong reason: %s', SQLERRM);
      ELSE
        RAISE NOTICE 'pass 15: uq_payment_provider_merchant_account_id_provider_txn_id';
      END IF;
    END;
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  15: the first, valid payment was refused: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 16. uq_payment_idempotency_key: a retried request is refused
  -- 17. ... while NULL keys (cash logged by an admin) are unconstrained
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO payment (invoice_id, guardian_id, amount_paisa, method, idempotency_key)
    VALUES (v_invoice, v_guardian, 400000, 'cash', 'idem-' || v_suffix)
    RETURNING id INTO v_id;
    DELETE FROM payment WHERE id = v_id;
    v_failures := v_failures + 1;
    v_msg := v_msg || E'\n  16: a reused idempotency_key was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%uq_payment_idempotency_key%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  16: wrong reason: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 16: uq_payment_idempotency_key';
    END IF;
  END;

  BEGIN
    INSERT INTO payment (invoice_id, guardian_id, amount_paisa, method)
    VALUES (v_invoice, v_guardian, 1000, 'cash'),
           (v_invoice, v_guardian, 1000, 'cash');
    RAISE NOTICE 'pass 17: two cash payments with NULL idempotency_key coexist';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  17: NULL idempotency keys collided: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------------------------
  -- 18. ck_payout_net_equals_gross_plus_adjustment
  -- 19. ck_payout_beneficiary_type: Rawaan never pays itself
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO payout (beneficiary_type, beneficiary_id, school_id, period_start, period_end,
                        gross_paisa, adjustment_paisa, net_paisa)
    VALUES ('school', v_school, v_school, DATE '2026-03-01', DATE '2026-03-31',
            40000, -500, 40000)
    RETURNING id INTO v_id;
    DELETE FROM payout WHERE id = v_id;
    v_failures := v_failures + 1;
    v_msg := v_msg || E'\n  18: payout net differing from gross + adjustment was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ck_payout_net_equals_gross_plus_adjustment%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  18: wrong reason: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 18: ck_payout_net_equals_gross_plus_adjustment';
    END IF;
  END;

  BEGIN
    INSERT INTO payout (beneficiary_type, beneficiary_id, school_id, period_start, period_end,
                        gross_paisa, adjustment_paisa, net_paisa)
    VALUES ('rawaan', v_school, v_school, DATE '2026-03-01', DATE '2026-03-31',
            40000, 0, 40000)
    RETURNING id INTO v_id;
    DELETE FROM payout WHERE id = v_id;
    v_failures := v_failures + 1;
    v_msg := v_msg || E'\n  19: a payout to rawaan was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ck_payout_beneficiary_type%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  19: wrong reason: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 19: ck_payout_beneficiary_type';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- 20. ck_adjustment_reason_not_blank: '', spaces, tabs and newlines refused
  -- 21. ck_adjustment_amount_not_zero
  -- ---------------------------------------------------------------------------

  BEGIN
    INSERT INTO adjustment (beneficiary_type, beneficiary_id, amount_paisa, reason, created_by)
    VALUES ('school', v_school, -500, 'Overpaid March by one child', v_admin);
    RAISE NOTICE 'pass 20a: an adjustment with a real reason is accepted';
  EXCEPTION WHEN OTHERS THEN
    v_failures := v_failures + 1;
    v_msg := v_msg || format(E'\n  20a: a valid adjustment was refused: %s', SQLERRM);
  END;

  v_sub := 0;
  FOREACH v_reason IN ARRAY ARRAY['', '   ', E'\t', E'\n', E' \t\r\n '] LOOP
    BEGIN
      INSERT INTO adjustment (beneficiary_type, beneficiary_id, amount_paisa, reason, created_by)
      VALUES ('school', v_school, -500, v_reason, v_admin)
      RETURNING id INTO v_id;
      DELETE FROM adjustment WHERE id = v_id;
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  20: blank reason %L was accepted', v_reason);
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%ck_adjustment_reason_not_blank%' THEN
        v_failures := v_failures + 1;
        v_msg := v_msg || format(E'\n  20: wrong reason for %L: %s', v_reason, SQLERRM);
      ELSE
        v_sub := v_sub + 1;
      END IF;
    END;
  END LOOP;
  RAISE NOTICE 'pass 20: ck_adjustment_reason_not_blank refused % of 5 blank reasons', v_sub;

  BEGIN
    INSERT INTO adjustment (beneficiary_type, beneficiary_id, amount_paisa, reason, created_by)
    VALUES ('school', v_school, 0, 'changes nothing', v_admin)
    RETURNING id INTO v_id;
    DELETE FROM adjustment WHERE id = v_id;
    v_failures := v_failures + 1;
    v_msg := v_msg || E'\n  21: a zero adjustment was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ck_adjustment_amount_not_zero%' THEN
      v_failures := v_failures + 1;
      v_msg := v_msg || format(E'\n  21: wrong reason: %s', SQLERRM);
    ELSE
      RAISE NOTICE 'pass 21: ck_adjustment_amount_not_zero';
    END IF;
  END;

  -- ---------------------------------------------------------------------------
  -- Cleanup, then report
  -- ---------------------------------------------------------------------------

  BEGIN
    DELETE FROM adjustment     WHERE beneficiary_id = v_school;
    DELETE FROM payout         WHERE school_id = v_school;
    DELETE FROM payment        WHERE invoice_id = v_invoice;
    DELETE FROM invoice        WHERE id = v_invoice;   -- cascades lines, allocations
    DELETE FROM billing_period WHERE school_id = v_school;
    DELETE FROM rate_snapshot  WHERE school_id = v_school;
    DELETE FROM enrollment     WHERE id = v_enrollment;
    DELETE FROM guardian       WHERE id = v_guardian;
    DELETE FROM student        WHERE id = v_student;
    DELETE FROM school         WHERE id = v_school;
    DELETE FROM app_user       WHERE id = ANY (v_auth_ids);
    DELETE FROM auth.users     WHERE id = ANY (v_auth_ids);
    RAISE NOTICE 'fixtures for run % removed', v_suffix;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'cleanup failed for run %: %', v_suffix, SQLERRM;
  END;

  IF v_failures = 0 THEN
    RAISE NOTICE 'D2: all 22 assertions passed.';
  ELSE
    RAISE EXCEPTION 'D2: % assertion(s) failed:%', v_failures, v_msg;
  END IF;
END
$test$;
