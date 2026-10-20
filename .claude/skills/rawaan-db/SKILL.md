---
name: rawaan-db
description: Rawaan's Supabase database — conventions, domain invariants, test style, the PGlite test runner, and the contract for the D-series migrations (D1–D8). Load BEFORE writing or changing anything under supabase/migrations or db/ in this project, including a new migration, a test file, an RLS policy, or db/apply-schema.mjs.
---

# Rawaan DB (D-series)

Rawaan is a school-transport startup in Peshawar: parents pay a monthly fee, verified drivers carry children to school, and the fee is split between driver, school and Rawaan. The database is the product's safety and money boundary, so its rules are enforced in SQL rather than in application code.

Also load `supabase-postgres-best-practices` (installed in this project) for general Postgres/RLS rules. **Where the two disagree, this skill wins.**

## Files

| Path | What |
|---|---|
| `supabase/migrations/2026100600000N_dN_<topic>.sql` | One migration per D-step, applied in filename order |
| `db/tests/dN_<topic>.test.sql` | One executable test per migration |
| `db/runner/run.mjs` | Applies all migrations then runs all tests in PGlite (Postgres 17 + PostGIS + pgcrypto) |
| `db/apply-schema.mjs` | Renders the migrations into a demo-schema variant (see below) |

The spec documents the comments cite (`MASTER_CONTEXT.md`, `D-series.md`) are **not in the repo**. The migration comments are the surviving spec. Read the header and forward-references of D1–D4 before writing a later step, and keep citing `MASTER_CONTEXT.md §N` only where an existing file already does.

## Running

```bash
cd db/runner && npm install        # once
node db/runner/run.mjs                     # everything; exit 0 == ALL GREEN
node db/runner/run.mjs --tests d5          # all migrations, only d5 tests
node db/runner/run.mjs --exclude 000006    # skip a sibling migration+test that is mid-edit
node db/runner/run.mjs --sql probe.sql     # extra ad-hoc file at the end
```

The runner stubs Supabase: the `auth` schema (`auth.users`, `auth.uid()`, `auth.role()`), the `anon` / `authenticated` / `service_role` roles, and **Supabase's default grants (ALL on every public table and function to anon and authenticated)**. A table without RLS is therefore wide open here exactly as it is on Supabase.

Impersonate a user inside a test:

```sql
PERFORM set_config('request.jwt.claim.sub', v_user_id::text, true);
SET LOCAL ROLE authenticated;
SELECT count(*) INTO v_n FROM student;   -- now filtered by RLS
RESET ROLE;
```

A step is not done until `node db/runner/run.mjs` prints `ALL GREEN`.

## Binding conventions (from D1, never relax them)

- Objects are written **unqualified**. Every migration starts with `SET search_path TO public, extensions;`. Never hard-code a schema name. The one exception is the `'public'` literal inside a `SECURITY DEFINER ... SET search_path = public, pg_temp` clause, which `apply-schema.mjs` rewrites.
- Tables are **singular** snake_case (`invoice`, `driver`). The D1 header says "plural", but every table is singular; follow the code. Columns are snake_case.
- Timestamps are `timestamptz` with an `_at` suffix. Dates use the `date` type with an `_on` or `_date` suffix.
- Constraint names: `pk_`, `fk_<table>_<column>`, `uq_<table>_<cols>` (partial unique indexes too, e.g. `uq_<table>_one_<thing>_per_<parent>`), `ck_<table>_<col>`, `idx_<table>_<cols>`, `trg_<table>_<event>`.
- **Money is integer paisa in `bigint`.** 1 PKR = 100 paisa. Never float or numeric. Basis points are `int`, and a split triple sums to exactly 10000.
- Booleans are prefixed `is_` / `has_` / `can_`.
- Every table has `created_at` and `updated_at`, plus `trg_<table>_updated_at BEFORE UPDATE ... EXECUTE FUNCTION set_updated_at()`. `assert_updated_at_convention()` fails otherwise.
- Every `SECURITY DEFINER` function pins `SET search_path = public, pg_temp` (add `extensions` only when it calls PostGIS or pgcrypto).
- A cross-table rule is a BEFORE trigger raising SQLSTATE `23514` (check_violation) or `23503`, never application code.
- An actor/audit pointer (`created_by`, `confirmed_by`, `reviewed_by`) is a plain uuid with no FK, unless the existing table already declares one.
- **No RLS in D1–D7.** D8 enables it on every table that exists at that point.
- **Migration numbering.** `20261006000005`–`000008` are reserved for D5–D8; never take one for anything else, because two files with one version number collide in Supabase. A feature migration that is not part of the D-series goes **after D8**, using the next free `2026100600000N` (9, 10, …) or a later date stamp. Because it runs after D8's enable-everything pass, it must **enable RLS and write the policies for its own tables** (using `current_app_role()` / `is_admin()`). Otherwise D8's "no table has RLS off" test fails, and the table is open to anon through Supabase's default grants.
- **RLS hides rows, not columns.** If a value must be hidden from some callers who can see the row, for example school earnings when `school_admin.can_view_earnings` is false, expose it through a SECURITY DEFINER function that checks the caller and returns NULL, not through a plain view.
- **Regex is Postgres ARE, not PCRE.** `[[:^space:]]` is invalid and throws on every insert; use `'\S'` (and `'^\s*$'` for "blank"). Write SQL with the Write/Edit tools, not shell heredocs or `sed`: the shell silently eats the backslash, and `'\S'` turns into `'S'`.
- Heavy explanatory comments are the house style: a `-- ---` banner per object, a `COMMENT ON` for every table and for every non-obvious column. Explain *why*, especially the failure mode a rule prevents.
- Every view gets `WITH (security_invoker = true)`. A view without it runs as its owner and bypasses RLS.

## Domain invariants (do not "simplify" these)

1. **The split is exact.** `allocate_split(fee, driver_bps, school_bps)`: driver and school take the floor, and Rawaan absorbs the remainder. It is the only place a split is computed. Baseline: Rs 4,000 = 400000 paisa; standard 8000/1000/1000; founding 8000/1500/500.
2. **Billing is snapshot-once.** `enrollment.fee_paisa` and its `*_bps` columns are the ONLY billing input. They are copied onto `invoice_line` at issue time, and `rate_snapshot` is never read at invoice time.
3. **Two money gates.** Gate 1, `is_billable()`: an active enrollment, on an (active) route, whose window overlaps the period. Gate 2, payout: `invoice.status = 'paid'`. The school earns only on transported children with paid invoices, never on the school roll count.
4. **Safety.** A driver may carry children only when `driver.verification_status = 'approved'` AND an active approved `driver_school` row exists AND the vehicle has `is_vehicle_verified`. The public site may not claim "CNIC + licence checked" until a real driver has gone through the pipeline end to end.
5. **Children never authenticate.** A student has no `app_user`. Access runs through `guardian`. Child location is readable only through `can_view_student_location()` (D8). No CNIC on a student, ever.
6. Documents and receipts are **pointers into private storage**, never bytes and never URLs.
7. **Every reduction says who pays for it.** A discount, credit or waiver lowers what the guardian pays, and it lands on someone. If it reduces the fee itself (`fee_paisa`, or a negative invoice line), the cut is shared 80/10/10. If it sits in `invoice.discount_paisa`, Rawaan alone absorbs it. On founding terms (Rawaan keeps 5%), a discount over 5% means Rawaan loses money on that child. Pick one deliberately, write the choice and its consequence in a COMMENT, and surface it as a business decision in your report. Never let the choice happen by accident.
8. **Negative lines and the split.** `allocate_split()` rejects negative amounts, but `proration_credit` and credit `adjustment` lines are negative. Split a credit line as the negation of `allocate_split(-amount, …)` so it nets out with the same flooring rule. Never reimplement the arithmetic.

## Test style (copy d3/d4 exactly)

- One `DO $test$ ... $test$;` block. Fixtures go `auth.users` → `app_user` → … and are namespaced with a `random()` suffix.
- Each assertion sits in its own `BEGIN ... EXCEPTION WHEN OTHERS` sub-block. Failures accumulate in `v_failures` / `v_msg`, and there is ONE `RAISE EXCEPTION` at the end.
- A negative case checks **which** constraint fired (`SQLERRM LIKE '%ck_name%'`). When an insert that should have failed succeeds, delete the row before counting the failure.
- Cleanup runs before the report.
- **Known pitfalls that broke earlier tests:** `IF ... ELSE ... END IF;` (not `END;`). `RAISE` uses `%`, not `%s`, and the placeholder count must equal the argument count (this is checked at compile time). `format()` uses `%s`. Paired columns (`consent_at` + `consent_version`) must be set together in fixtures. Do not invert pass/fail flags. `now()` is fixed for the whole transaction, so an "updated_at was bumped" test must compare against a backdated value (set `updated_at` to `now() - interval '1 day'` first), not wait for the clock.
- **Every negative case names its constraint or error.** Assert on `SQLERRM LIKE '%ck_…%'` (or `SQLSTATE = '23514'` plus a message fragment for trigger errors). A bare `WHEN OTHERS THEN pass` counts as a pass for the wrong reason the first time an unrelated error fires, which is how an invalid regex in D2 went unnoticed until a test inserted a real row.

## D-series contract

**All of D1–D8 are written and green (148 assertions).** The sections below describe what each step contains; read the migration itself before changing it. Any new feature migration goes after D8 and brings its own RLS (see Migration numbering).

### D5 — routes, trips, check-ins (`20261006000005_d5_routes_trips.sql`)
Promised by earlier files:
- `route` (belongs to exactly one school; `is_active`; driver + vehicle assignment). Assignable drivers come from **active approved `driver_school` rows** only, and the vehicle must be `is_vehicle_verified`, enforced by trigger. Also `route_stop` (geography points) and a manifest of which students ride which route/stop.
- **The deferred block at the end of D3**: `fk_enrollment_route` (ON DELETE SET NULL), `idx_enrollment_route_id`, the `v_billable_enrollment` replacement that joins `route.is_active` (WITH `security_invoker`), and `is_billable()` requiring `r.is_active`.
- **The D2 → D3/D4 foreign keys that could not exist in D2** (D2 runs before D3): `rate_snapshot.school_id`, `billing_period.school_id`, `invoice.enrollment_id`, `invoice.guardian_id` (→ `guardian.id`), `invoice.school_id`, `payment.guardian_id` (→ `guardian.id`), `payout.school_id`, and `driver_earning.payout_id → payout`. Polymorphic `beneficiary_id` columns stay FK-less on purpose.
- **Money hardening found in review**: `invoice` must have `subtotal_paisa >= 0` and `total_paisa >= 0`. One invoice line must not be payable twice to the same beneficiary type across payouts (today `payout_line` only has UNIQUE(payout_id, invoice_line_id)). Close that, e.g. with a `beneficiary_type` on `payout_line` kept in sync with its payout by trigger, plus a unique index on (invoice_line_id, beneficiary_type).
- `trip` using the `trip_status` enum. **Legal transitions are enforced by a `transition_trip()` function, not a trigger** (D1 says so). Also `trip_checkin` using `checkin_method` / `checkin_result`, where **every scan attempt is recorded, including failures**, plus the QR token mechanism (short-lived, hashed; never store a reusable secret).

### D6 — attendance and absences (`..._000006_d6_absences.sql`)
- `absence` (guardian reports that a child will not ride on a date, `absence_status`). It feeds the `child_absent` check-in result and lets a driver skip a stop. Only a guardian of that child may submit one (trigger). Not billing-relevant: an absence does not prorate the fee.
- Optional: a `notification` outbox table (pointer-only, no provider integration).

### D7 — leads (`..._000007_d7_leads.sql`)
- `lead` using `lead_status` / `lead_source` (waitlist, school inquiry, driver application, contact form). Per D1, driver and school accounts are not self-provisioned: the B2 auth flow creates a pending `app_user` plus a lead, and an admin promotes it. Store minimal PII and record consent.

### D8 — RLS, grants, audit (`..._000008_d8_rls_audit.sql`)
- `ENABLE ROW LEVEL SECURITY` on **every** table. The D8 test must assert that no table in the schema has RLS off.
- Policies per role via `current_app_role()` / `current_app_user_id()` / `is_admin()`. Never re-derive these.
- `can_view_student_location(student_id)`: guardian of the child, the driver currently assigned to the child's route, or admin. Students' location columns are protected by it.
- `driver_document`: **no SELECT for parent or school, not even metadata.** Driver sees own; admin sees all.
- Money tables: parents see their own invoices/payments; schools with `can_view_earnings` see their school's aggregates; drivers see their own `driver_earning`.
- `REVOKE EXECUTE ... FROM PUBLIC, anon` on SECURITY DEFINER functions: `find_nearby_students` (admin, plus school for its own school_id only, checked inside), `is_billable`, `allocate_split` as appropriate.
- **Handed over by D5:**
  - `transition_trip()` is SECURITY INVOKER and authorises the status UPDATE with a trip-id-valued GUC (`rawaan.trip_transition`). Any session can forge that GUC, so D8 must make it a real boundary. Either `REVOKE UPDATE (status) ON trip FROM anon, authenticated` and make `transition_trip` SECURITY DEFINER with an in-function role check (the assigned driver for their trip's driver-side states, admin for anything), or an equivalent design.
  - `issue_trip_qr_token` / `record_trip_checkin`: driver of that trip or admin only. `trip_qr_token.token_hash` is never readable by parent or school.
  - `route_manifest` and `route_stop` locations are child-location data, so they go through `can_view_student_location()`.
  - `payout_line`: a failed or cancelled payout must DELETE its lines before re-paying (enforced by `uq_payout_line_invoice_line_id_beneficiary_type`); keep that path admin-only.
- An append-only `audit_log` (actor, action, table, row id, before/after jsonb, at). Triggers on the privileged writes: payment confirm/reject, adjustment, payout, driver verification status, driver_school approval. UPDATE/DELETE on audit_log is impossible (revoke plus a trigger that raises).

### Also outstanding
- `db/tests/d1_foundations.test.sql` (calls `assert_updated_at_convention()`, role helpers) and `db/tests/d2_money.test.sql` (`allocate_split` sums exactly over 10,000 combinations, plus every D2 check).
- `db/apply-schema.mjs`: reads the migrations in order, and for a `--schema demo` render replaces `SET search_path TO public, extensions;` and the `SET search_path = public, pg_temp` / `public, extensions, pg_temp` literals with the demo schema, prepending `CREATE SCHEMA IF NOT EXISTS demo;`. Default output goes to stdout, with an optional `--out file`. Node stdlib only.
- Remove the stray `-- @@CONTINUE@@` at the end of D2, and fix the typo "ENFORGED".
