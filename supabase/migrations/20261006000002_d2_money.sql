-- =============================================================================
-- D2 — Money: rate snapshots, invoices, payments, payouts
-- =============================================================================
-- CONVENTIONS (inherited from D1, still binding in this file):
--   * Objects are written UNQUALIFIED. The target schema is set by the
--     SET search_path line below, which db/apply-schema.mjs rewrites when
--     rendering the demo variant. Do NOT hard-code a schema name anywhere
--     in this file.
--   * Money: integer paisa in bigint. 1 PKR = 100 paisa. Never float, never
--     numeric, never a formatted string. quantity is the only numeric column
--     in this file and it is a dimensionless multiplier, not money.
--   * Basis points stored in int; driver_bps + school_bps + rawaan_bps = 10000
--     always, enforced by a check constraint wherever the triple is stored.
--   * Plural snake_case tables, snake_case columns, timestamptz with an _at
--     suffix. Never `timestamp`.
--   * Foreign key columns: _id. Constraints named:
--       pk_<table>              primary key
--       fk_<table>_<column>     foreign key
--       uq_<table>_<cols>       unique constraint (or partial unique index)
--       ck_<table>_<col>        check constraint
--       idx_<table>_<cols>      index
--       trg_<table>_<event>     trigger
--   * Every table gets updated_at, maintained by D1's set_updated_at().
--   * NO RLS in this file. RLS is applied in D8, across every table.
-- =============================================================================
--
-- BASELINE (MASTER_CONTEXT.md section 3):
--   Rs. 4,000 per child per month = 400000 paisa.
--     standard  driver 8000 / school 1000 / rawaan 1000 = 320000 / 40000 / 40000
--     founding  driver 8000 / school 1500 / rawaan  500 = 320000 / 60000 / 20000
--
-- The one rule this file exists to protect: the three legs of a split sum to
-- the fee EXACTLY, for every fee, forever. Driver and school floor; Rawaan
-- absorbs the remainder. Any later "simplification" that redistributes the
-- rounding reintroduces silent, cumulative financial drift. See allocate_split()
-- and db/tests/d2_money.test.sql, which asserts it over 10,000 combinations.
--
-- Billing is snapshot-once. Commercial terms are copied onto invoice lines at
-- issue time and never re-resolved from a rate table afterwards, so a rate
-- change today cannot rewrite last month's payouts.
-- =============================================================================

SET search_path TO public, extensions;

-- -----------------------------------------------------------------------------
-- D2-specific enum types
-- -----------------------------------------------------------------------------
-- D1 owns the lifecycle enums shared across the product, including
-- invoice_status, payment_status and payout_status. The four below exist only
-- because D2 needed a shape D1 could not supply: invoice_status is per-invoice,
-- whereas a billing period has its own, coarser lifecycle.
-- -----------------------------------------------------------------------------

-- A calendar month being billed for one school. 'closing' stages a period so
-- invoices can be generated and reconciled before the close is committed;
-- 'reopened' exists because a wrong close must be correctable with an audit
-- trail rather than by editing history.
CREATE TYPE billing_period_status AS ENUM (
  'open',
  'closing',
  'closed',
  'reopened'
);

-- One kind of charge on an invoice. proration_credit is recorded as its own
-- line instead of quietly reducing the fee, so a part-month is visible on the
-- guardian's invoice and the proration is auditable.
CREATE TYPE invoice_line_type AS ENUM (
  'transport_fee',
  'proration_credit',
  'adjustment',
  'late_fee'
);

-- Who a split leg belongs to. Deliberately polymorphic: beneficiary_id points
-- at school.id (D3) for 'school' and driver.id (D4) for 'driver'. No single
-- foreign key can express that, so none is declared.
CREATE TYPE beneficiary_type AS ENUM ('driver', 'school', 'rawaan');

-- Inbound payment rail. Cash and 'other' carry no provider and therefore no
-- transaction id, which is why the TID uniqueness constraint is nullable.
CREATE TYPE payment_method AS ENUM (
  'bank_transfer',
  'cash',
  'jazzcash',
  'easypaisa',
  'other'
);

-- -----------------------------------------------------------------------------
-- allocate_split() — the deterministic remainder rule
-- -----------------------------------------------------------------------------
-- MASTER_CONTEXT.md section 3, rule 2. This is the ONLY place a money split is
-- computed. If application code or a later migration needs a split it calls
-- this; it never reimplements the arithmetic.
--
--   driver = floor(fee * driver_bps / 10000)
--   school = floor(fee * school_bps / 10000)
--   rawaan = fee - driver - school            <-- Rawaan absorbs the remainder
--
-- The third leg is derived rather than computed, so the three always sum to
-- p_fee_paisa exactly. The nominal rawaan leg is still recoverable as
-- 10000 - p_driver_bps - p_school_bps and is what split_allocation.rate_bps
-- records, but the paisa amount is the remainder. Rounding loss is therefore
-- never distributed: at worst a paisa lands on Rawaan, which is the only party
-- that reconciles against its own books.
--
-- p_rawaan_bps is not a parameter because it is not an independent choice. A
-- triple that does not sum to 10000 is a data error, so it is rejected rather
-- than repaired: the driver's share can never be inflated by a bad school leg,
-- and the school's can never be inflated by a bad Rawaan leg.
--
-- IMMUTABLE: no table access, no clock, deterministic for a given input.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION allocate_split(
  p_fee_paisa   bigint,
  p_driver_bps  int,
  p_school_bps  int
)
RETURNS TABLE(beneficiary_type text, amount_paisa bigint)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_driver_paisa bigint;
  v_school_paisa bigint;
  v_rawaan_paisa bigint;
BEGIN
  IF p_fee_paisa IS NULL OR p_fee_paisa < 0 THEN
    RAISE EXCEPTION
      'allocate_split: fee_paisa must be zero or positive, got %', p_fee_paisa
      USING ERRCODE = '22023';
  END IF;

  IF p_driver_bps IS NULL OR p_driver_bps < 0 OR p_driver_bps > 10000
     OR p_school_bps IS NULL OR p_school_bps < 0 OR p_school_bps > 10000 THEN
    RAISE EXCEPTION
      'allocate_split: bps must be within 0..10000, got driver=% school=%',
      p_driver_bps, p_school_bps
      USING ERRCODE = '22023';
  END IF;

  -- The implied third leg is 10000 - driver_bps - school_bps, which is in range
  -- exactly when driver_bps + school_bps <= 10000. That is where the "splits
  -- must sum to 10000" invariant is enforced for this function.
  IF p_driver_bps + p_school_bps > 10000 THEN
    RAISE EXCEPTION
      'allocate_split: driver_bps + school_bps = % exceeds 10000, so the split '
      'cannot sum to 10000 (driver=% school=%)',
      p_driver_bps + p_school_bps, p_driver_bps, p_school_bps
      USING ERRCODE = '22023';
  END IF;

  v_driver_paisa := floor(p_fee_paisa * p_driver_bps::numeric / 10000)::bigint;
  v_school_paisa := floor(p_fee_paisa * p_school_bps::numeric / 10000)::bigint;
  v_rawaan_paisa := p_fee_paisa - v_driver_paisa - v_school_paisa;

  RETURN QUERY
    SELECT *
      FROM (VALUES
              ('driver'::text, v_driver_paisa),
              ('school'::text, v_school_paisa),
              ('rawaan'::text, v_rawaan_paisa)
           ) AS legs(leg, share);
END;
$$;

COMMENT ON FUNCTION allocate_split(bigint, int, int) IS
  'Splits a fee in paisa into driver / school / rawaan legs in basis points, '
  'summing EXACTLY to the fee. Driver and school floor; Rawaan absorbs the '
  'remainder, so no paisa is ever lost or invented. Raises 22023 when a bps leg '
  'is outside 0..10000 or when driver_bps + school_bps exceeds 10000 (a triple '
  'that cannot sum to 10000). The single source of truth for money splits.';

-- -----------------------------------------------------------------------------
-- rate_snapshot — a school's commercial terms
-- -----------------------------------------------------------------------------
-- ONBOARDING DEFAULT ONLY. This table records what a school is currently
-- offered; when a NEW enrollment is created, those terms are copied onto the
-- enrollment as its frozen commercial snapshot. Invoice generation reads the
-- enrollment-level snapshot and NEVER this table. Editing a rate here is a
-- forward-looking commercial action; it does not touch an issued invoice.
--
-- The bps-sum-to-10000 constraint is the invariant that makes an overpayment
-- impossible to express: no school and no driver can be credited more than the
-- contract says, and no leg can be left dangling.
-- -----------------------------------------------------------------------------

CREATE TABLE rate_snapshot (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id           uuid        NOT NULL,
  effective_from      date        NOT NULL,
  effective_to        date,
  fee_paisa           bigint      NOT NULL,
  driver_bps          int         NOT NULL,
  school_bps          int         NOT NULL,
  rawaan_bps          int         NOT NULL,
  is_founding_school  boolean     NOT NULL DEFAULT false,
  notes               text,
  created_by          uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_rate_snapshot_fee_positive  CHECK (fee_paisa > 0),
  CONSTRAINT ck_rate_snapshot_driver_bps    CHECK (driver_bps BETWEEN 0 AND 10000),
  CONSTRAINT ck_rate_snapshot_school_bps    CHECK (school_bps BETWEEN 0 AND 10000),
  CONSTRAINT ck_rate_snapshot_rawaan_bps    CHECK (rawaan_bps BETWEEN 0 AND 10000),
  CONSTRAINT ck_rate_snapshot_bps_sum_10000 CHECK (
    driver_bps + school_bps + rawaan_bps = 10000
  ),
  CONSTRAINT ck_rate_snapshot_effective_range CHECK (
    effective_to IS NULL OR effective_to >= effective_from
  )
);

COMMENT ON TABLE rate_snapshot IS
  'A school''s commercial terms: monthly fee in paisa plus the 80/10/10 (or '
  'founding 80/15/5) split in basis points. This is an ONBOARDING DEFAULT and '
  'is NOT a billing input: at invoice generation the terms are read from the '
  'enrollment-level snapshot, never from this table. Rows are superseded by '
  'inserting a new one with a later effective_from rather than by updating one, '
  'so the terms a school was onboarded under stay legible.';
COMMENT ON COLUMN rate_snapshot.effective_to IS
  'NULL means this is the current default. The partial unique index '
  'uq_rate_snapshot_school_id_open_ended permits only one such row per school.';
COMMENT ON COLUMN rate_snapshot.is_founding_school IS
  'Marks the reduced-Rawaan founding terms for the first 12 months. '
  'Informational: the authoritative split is the bps triple, which the checks '
  'pin to 10000.';
COMMENT ON COLUMN rate_snapshot.created_by IS
  'app_user id of the staff member who set these terms. Intentionally not a '
  'foreign key: an audit pointer must survive account deletion, and the '
  'append-only audit_log written in D8 carries the immutable actor record.';

-- One open-ended row per school. Without this, two concurrent "current terms"
-- rows would make the onboarding default ambiguous.
CREATE UNIQUE INDEX uq_rate_snapshot_school_id_open_ended
  ON rate_snapshot (school_id)
  WHERE effective_to IS NULL;

CREATE TRIGGER trg_rate_snapshot_updated_at
  BEFORE UPDATE ON rate_snapshot
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- billing_period — one calendar month being billed for one school
-- -----------------------------------------------------------------------------

CREATE TABLE billing_period (
  id            uuid                   PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id     uuid                   NOT NULL,
  period_start  date                   NOT NULL,
  period_end    date                   NOT NULL,
  period_label  text                   NOT NULL,
  status        billing_period_status  NOT NULL DEFAULT 'open',
  closed_at     timestamptz,
  closed_by     uuid,
  created_at    timestamptz            NOT NULL DEFAULT now(),
  updated_at    timestamptz            NOT NULL DEFAULT now(),
  CONSTRAINT uq_billing_period_school_id_period_start
    UNIQUE (school_id, period_start),
  CONSTRAINT ck_billing_period_period_range CHECK (period_end >= period_start)
);

COMMENT ON TABLE billing_period IS
  'One calendar month of billing for one school. Re-running a close against '
  'the same period is safe because invoice carries UNIQUE (enrollment_id, '
  'billing_period_id): a second run can never double-issue. DELIBERATELY has '
  'no rate_snapshot_id foreign key — see the note below.';
COMMENT ON COLUMN billing_period.period_label IS
  'Display label, e.g. ''2026-03''. Human-facing only; period_start is the '
  'authoritative value and is what the unique constraint is built on.';
COMMENT ON COLUMN billing_period.status IS
  '''closing'' stages a period so invoices can be generated and reconciled '
  'before the close is committed. ''reopened'' records that a committed close '
  'was wrong; it does not rewrite the invoices already issued from it.';
COMMENT ON COLUMN billing_period.closed_by IS
  'app_user id of the admin who closed the period. Plain uuid, no foreign key: '
  'see rate_snapshot.created_by.';

CREATE TRIGGER trg_billing_period_updated_at
  BEFORE UPDATE ON billing_period
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- DELIBERATE REMOVAL (do not re-add).
-- D-series.md originally specified `rate_snapshot_id uuid not null references
-- rate_snapshot(id)` here, with the period binding one snapshot at close.
-- That column is NOT present, on purpose. Invoice generation reads exactly one
-- commercial source: the rate columns frozen on the enrollment. A second
-- billing input bound at period level could only ever disagree with that
-- enrollment snapshot, and a disagreement between two billing inputs silently
-- over- or under-pays a real driver's real money, in a way no reconciliation
-- would attribute. One source of truth, one possible invoice.

-- -----------------------------------------------------------------------------
-- invoice — what a guardian owes for one enrollment in one period
-- -----------------------------------------------------------------------------

CREATE TABLE invoice (
  id                 uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  enrollment_id      uuid          NOT NULL,
  billing_period_id  uuid          NOT NULL,
  guardian_id        uuid          NOT NULL,
  school_id          uuid          NOT NULL,
  status             invoice_status NOT NULL DEFAULT 'draft',
  subtotal_paisa     bigint        NOT NULL,
  discount_paisa     bigint        NOT NULL DEFAULT 0,
  total_paisa        bigint        NOT NULL,
  issued_at          timestamptz,
  due_date           date,
  paid_at            timestamptz,
  created_at         timestamptz   NOT NULL DEFAULT now(),
  updated_at         timestamptz   NOT NULL DEFAULT now(),
  CONSTRAINT uq_invoice_enrollment_id_billing_period_id
    UNIQUE (enrollment_id, billing_period_id),
  CONSTRAINT ck_invoice_total_equals_subtotal_less_discount CHECK (
    total_paisa = subtotal_paisa - discount_paisa
  ),
  CONSTRAINT ck_invoice_discount_non_negative CHECK (discount_paisa >= 0),
  CONSTRAINT fk_invoice_billing_period_id FOREIGN KEY (billing_period_id)
    REFERENCES billing_period(id) ON DELETE RESTRICT
);

COMMENT ON TABLE invoice IS
  'One enrollment, one billing period, one amount owed by one guardian. '
  'subtotal_paisa is the sum of the lines, discount_paisa is a deliberate '
  'reduction, and a check forces total_paisa to be exactly the difference, so '
  'the three can never disagree.';
COMMENT ON COLUMN invoice.total_paisa IS
  'CHECK-constrained to subtotal_paisa - discount_paisa. The caller states '
  'subtotal and discount; the constraint derives the truth.';
COMMENT ON COLUMN invoice.status IS
  '''draft'' invoices are still editable. ''issued'' and ''paid'' are the states '
  'B8 joins to for payout eligibility. ''void'' cancels an invoice without '
  'payment and is the only way to stop a billed month, never a DELETE.';
COMMENT ON COLUMN invoice.paid_at IS
  'Set when the covering payments are confirmed, not when they are submitted.';
COMMENT ON COLUMN invoice.guardian_id IS
  'The guardian being billed, which need not be the student''s primary '
  'guardian when a second guardian pays.';
COMMENT ON COLUMN invoice.issued_at IS
  'Set when the invoice leaves draft. Lines and totals are frozen from here '
  'regardless.';

CREATE TRIGGER trg_invoice_updated_at
  BEFORE UPDATE ON invoice
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- invoice_line — the charges, carrying their own frozen rate
-- -----------------------------------------------------------------------------
-- driver_bps / school_bps / rawaan_bps are DENORMALISED onto every line, and
-- that is the point, not an oversight. A rate-table join at read time means a
-- rate change silently restates history: a dispute about March's invoice would
-- resolve against a number that did not exist in March, and the money would
-- move. Copying the triple at issue time makes each line self-describing and
-- immune to later contract changes, and it is what allows allocate_split() to
-- be a pure function of its arguments.
-- -----------------------------------------------------------------------------

CREATE TABLE invoice_line (
  id             uuid              PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id     uuid              NOT NULL,
  line_type      invoice_line_type NOT NULL,
  description    text              NOT NULL,
  quantity       numeric(10, 4)    NOT NULL DEFAULT 1,
  unit_paisa     bigint,
  amount_paisa   bigint            NOT NULL,
  driver_bps     int               NOT NULL,
  school_bps     int               NOT NULL,
  rawaan_bps     int               NOT NULL,
  created_at     timestamptz       NOT NULL DEFAULT now(),
  updated_at     timestamptz       NOT NULL DEFAULT now(),
  CONSTRAINT fk_invoice_line_invoice_id FOREIGN KEY (invoice_id)
    REFERENCES invoice(id) ON DELETE CASCADE,
  CONSTRAINT ck_invoice_line_quantity_positive CHECK (quantity > 0),
  CONSTRAINT ck_invoice_line_driver_bps   CHECK (driver_bps BETWEEN 0 AND 10000),
  CONSTRAINT ck_invoice_line_school_bps   CHECK (school_bps BETWEEN 0 AND 10000),
  CONSTRAINT ck_invoice_line_rawaan_bps   CHECK (rawaan_bps BETWEEN 0 AND 10000),
  CONSTRAINT ck_invoice_line_bps_sum_10000 CHECK (
    driver_bps + school_bps + rawaan_bps = 10000
  )
);

COMMENT ON TABLE invoice_line IS
  'The charges making up an invoice. amount_paisa is signed: a proration_credit '
  'line is negative, so credits net out visibly instead of being folded into a '
  'smaller fee. The bps triple is copied from the enrollment''s frozen rate at '
  'issue time and is DENORMALISED deliberately, so a line can never be '
  'restated by a later rate change.';
COMMENT ON COLUMN invoice_line.quantity IS
  'A dimensionless multiplier, e.g. 0.5000 for half a month of a proration '
  'line. numeric is correct here and ONLY here: 0.5 is not money, and this '
  'column never carries paisa.';
COMMENT ON COLUMN invoice_line.unit_paisa IS
  'Paisa per unit of quantity. NULL for lines that are not priced per unit, '
  'such as a flat goodwill correction.';
COMMENT ON COLUMN invoice_line.driver_bps IS
  'Frozen basis points copied from the enrollment-level rate snapshot. Kept on '
  'the line rather than joined from rate_snapshot precisely so that a later '
  'rate change cannot rewrite this invoice. school_bps and rawaan_bps follow '
  'the same rule; the three always sum to 10000.';
COMMENT ON COLUMN invoice_line.amount_paisa IS
  'Sign convention: charges positive, credits negative. quantity * unit_paisa '
  'is deliberately NOT required to equal amount_paisa, because proration '
  'floors. amount_paisa is what was actually charged and is authoritative.';

CREATE TRIGGER trg_invoice_line_updated_at
  BEFORE UPDATE ON invoice_line
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- split_allocation — the money owed to each party, per line
-- -----------------------------------------------------------------------------
-- Allocations are written when the invoice is generated, not when it is paid,
-- so the split is visible and reviewable BEFORE any money moves. They are a
-- transparency artefact, not a payment instruction.
--
-- PAYOUT ELIGIBILITY IS NOT ENFORCED HERE. It is enforced in B8 by joining to
-- invoice.status = 'paid': an allocation against an issued-but-unpaid invoice
-- exists and is displayable, and becomes payable only once that invoice is
-- paid. This holds for BOTH school and driver payouts — the school is a
-- creditor exactly like the driver and gates on the same condition. A school
-- whose invoices are unpaid must not be paid out.
-- -----------------------------------------------------------------------------

CREATE TABLE split_allocation (
  id                uuid             PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_line_id   uuid             NOT NULL,
  beneficiary_type  beneficiary_type NOT NULL,
  beneficiary_id    uuid,
  amount_paisa      bigint           NOT NULL,
  rate_bps          int              NOT NULL,
  created_at        timestamptz      NOT NULL DEFAULT now(),
  updated_at        timestamptz      NOT NULL DEFAULT now(),
  CONSTRAINT fk_split_allocation_invoice_line_id FOREIGN KEY (invoice_line_id)
    REFERENCES invoice_line(id) ON DELETE CASCADE,
  CONSTRAINT uq_split_allocation_invoice_line_id_beneficiary_type
    UNIQUE (invoice_line_id, beneficiary_type),
  CONSTRAINT ck_split_allocation_beneficiary_id_required CHECK (
    (beneficiary_type = 'rawaan') = (beneficiary_id IS NULL)
  ),
  CONSTRAINT ck_split_allocation_rate_bps CHECK (rate_bps BETWEEN 0 AND 10000)
);

COMMENT ON TABLE split_allocation IS
  'One row per invoice line per beneficiary: the exact paisa each party earned '
  'on that line, written at invoice generation for transparency and '
  'reconciliation. NOT PAYABLE until the parent invoice is paid — B8 gates '
  'payouts on invoice.status = ''paid'', for driver and school alike.';
COMMENT ON COLUMN split_allocation.beneficiary_id IS
  'school.id (D3) for a school leg, driver.id (D4) for a driver leg, NULL for '
  'Rawaan because the platform is not its own beneficiary row. Deliberately '
  'polymorphic, so no foreign key is declared: the check constraint instead '
  'pins the one invariant that matters, that Rawaan legs carry no beneficiary '
  'and driver/school legs always do.';
COMMENT ON COLUMN split_allocation.amount_paisa IS
  'Signed to match the line: a credit line allocates negative amounts. For a '
  'single invoice the three allocations per line sum exactly to the line '
  'amount, which is the reconciliation B8 asserts.';
COMMENT ON COLUMN split_allocation.rate_bps IS
  'The NOMINAL basis points from the line, i.e. 10000 - driver_bps - '
  'school_bps for a Rawaan leg. On a very small fee the realised share can '
  'differ from the nominal rate by the absorbed remainder; the amount, not the '
  'rate, is what is paid.';

CREATE TRIGGER trg_split_allocation_updated_at
  BEFORE UPDATE ON split_allocation
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- payment — inbound money
-- -----------------------------------------------------------------------------
-- Manual confirmation only in this phase. JazzCash/Easypaisa merchant APIs
-- generally require SECP/NTN registration, which Rawaan does not have yet, so
-- the flow is: invoice issued -> parent pays -> parent submits the transaction
-- id -> admin confirms. The ledger is built now; a real gateway plugs in later
-- behind an adapter. No gateway integration is faked anywhere in this schema.
-- -----------------------------------------------------------------------------

CREATE TABLE payment (
  id                  uuid           PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id          uuid           NOT NULL,
  guardian_id         uuid           NOT NULL,
  amount_paisa        bigint         NOT NULL,
  method              payment_method NOT NULL,
  provider            text,
  merchant_account_id text,
  provider_txn_id     text,
  idempotency_key     text,
  status              payment_status NOT NULL DEFAULT 'awaiting_submission',
  submitted_by        uuid,
  submitted_at        timestamptz,
  confirmed_by        uuid,
  confirmed_at        timestamptz,
  rejection_reason    text,
  receipt_path        text,
  created_at          timestamptz    NOT NULL DEFAULT now(),
  updated_at          timestamptz    NOT NULL DEFAULT now(),
  CONSTRAINT fk_payment_invoice_id FOREIGN KEY (invoice_id)
    REFERENCES invoice(id) ON DELETE RESTRICT,
  CONSTRAINT ck_payment_amount_positive CHECK (amount_paisa > 0),
  CONSTRAINT ck_payment_provider_triple_paired CHECK (
    (provider IS NULL AND merchant_account_id IS NULL AND provider_txn_id IS NULL)
    OR (provider IS NOT NULL AND merchant_account_id IS NOT NULL
        AND provider_txn_id IS NOT NULL)
  ),
  CONSTRAINT uq_payment_provider_merchant_account_id_provider_txn_id
    UNIQUE (provider, merchant_account_id, provider_txn_id)
);

COMMENT ON TABLE payment IS
  'Inbound money against an invoice. A payment is a claim, not a movement of '
  'funds: it becomes real money only when status reaches ''confirmed''. '
  'UNIQUE (provider, merchant_account_id, provider_txn_id) is the guard '
  'against one mobile transaction id paying two invoices.';
COMMENT ON COLUMN payment.amount_paisa IS
  'Must be greater than zero: a payment is inbound. Outbound corrections are '
  'adjustments or a refund, never a negative payment row.';
COMMENT ON COLUMN payment.provider_txn_id IS
  'The transaction id the parent reads off their confirmation SMS. NOT unique '
  'on its own: mobile transaction ids collide across merchants and between '
  'parents, so the uniqueness constraint is on the provider + merchant '
  'account + tid triple. A parent whose confirmation SMS is slow will submit '
  'twice; this is the constraint that stops the second submission from paying '
  'the same money twice, and it is the reason a duplicate is reported to the '
  'parent as "already submitted" rather than as an error.';
COMMENT ON COLUMN payment.idempotency_key IS
  'Client-supplied key so a retried request from a flaky mobile connection '
  'cannot create two payment rows. Partial UNIQUE index: rows created before '
  'the key existed, and cash payments logged by an admin, carry NULL and are '
  'unconstrained.';
COMMENT ON COLUMN payment.status IS
  'awaiting_submission -> submitted -> confirmed, with failed, rejected and '
  'refunded as terminal branches. The invoice is only marked paid on '
  'confirmation, never on submission.';
COMMENT ON COLUMN payment.confirmed_by IS
  'app_user id of the admin who verified the money actually arrived. Plain '
  'uuid, no foreign key: see rate_snapshot.created_by. This is a privileged '
  'action and is additionally written to the D8 append-only audit log.';
COMMENT ON COLUMN payment.rejection_reason IS
  'Required by B-series when a payment is rejected; the same non-blank rule '
  'used by adjustment.reason applies, enforced in application code because '
  'the rejection path also needs to accept a null reason while undecided.';
COMMENT ON COLUMN payment.receipt_path IS
  'Pointer only, to a PRIVATE storage bucket — never a public URL and never '
  'image bytes in the database. Reads go through an expiring signed URL.';

CREATE UNIQUE INDEX uq_payment_idempotency_key
  ON payment (idempotency_key)
  WHERE idempotency_key IS NOT NULL;

CREATE TRIGGER trg_payment_updated_at
  BEFORE UPDATE ON payment
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- payout — outbound money to a driver or a school
-- -----------------------------------------------------------------------------
-- One payout covers one beneficiary over one period. Rawaan keeps its own
-- revenue; it never pays itself, hence beneficiary_type excludes 'rawaan'.
-- -----------------------------------------------------------------------------

CREATE TABLE payout (
  id                uuid             PRIMARY KEY DEFAULT gen_random_uuid(),
  beneficiary_type  beneficiary_type NOT NULL,
  beneficiary_id    uuid             NOT NULL,
  school_id         uuid             NOT NULL,
  period_start      date             NOT NULL,
  period_end        date             NOT NULL,
  status            payout_status    NOT NULL DEFAULT 'pending',
  gross_paisa       bigint           NOT NULL,
  adjustment_paisa  bigint           NOT NULL DEFAULT 0,
  net_paisa         bigint           NOT NULL,
  method            text,
  reference         text,
  paid_at           timestamptz,
  created_at        timestamptz      NOT NULL DEFAULT now(),
  updated_at        timestamptz      NOT NULL DEFAULT now(),
  CONSTRAINT ck_payout_beneficiary_type CHECK (
    beneficiary_type IN ('driver', 'school')
  ),
  CONSTRAINT ck_payout_net_equals_gross_plus_adjustment CHECK (
    net_paisa = gross_paisa + adjustment_paisa
  ),
  CONSTRAINT ck_payout_period_range CHECK (period_end >= period_start)
);

COMMENT ON TABLE payout IS
  'Outbound money to one beneficiary over one period, built by B8 from '
  'split_allocation rows on PAID invoices only. gross_paisa is the sum of the '
  'allocated lines; adjustment_paisa is the signed sum of any adjustment rows '
  'attached to this payout; net_paisa is what is actually transferred and is '
  'check-constrained to the sum of the two, so a payout can never quietly '
  'differ from its own lines.';
COMMENT ON COLUMN payout.beneficiary_type IS
  'Restricted to ''driver'' and ''school'' by check. Rawaan is the platform and '
  'is never a payout recipient.';
COMMENT ON COLUMN payout.beneficiary_id IS
  'driver.id (D4) or school.id (D3) depending on beneficiary_type. '
  'Deliberately polymorphic, so no foreign key is declared — the check on '
  'beneficiary_type is what keeps the pair unambiguous.';
COMMENT ON COLUMN payout.adjustment_paisa IS
  'Signed. Negative reduces a payout, positive increases it. Every paisa here '
  'must be traceable to an adjustment row carrying a non-blank reason.';
COMMENT ON COLUMN payout.reference IS
  'Bank or transfer reference supplied by the admin releasing the payout. '
  'Part of the audit trail for a privileged action.';
COMMENT ON COLUMN payout.school_id IS
  'The school whose billing period the payout came from. Recorded on driver '
  'payouts too, because a driver serving one school may be paid per school and '
  'the reconciliation is per school.';

CREATE TRIGGER trg_payout_updated_at
  BEFORE UPDATE ON payout
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- payout_line — which allocations a payout actually pays
-- -----------------------------------------------------------------------------

CREATE TABLE payout_line (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  payout_id       uuid        NOT NULL,
  invoice_id      uuid        NOT NULL,
  invoice_line_id uuid        NOT NULL,
  amount_paisa    bigint      NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_payout_line_payout_id FOREIGN KEY (payout_id)
    REFERENCES payout(id) ON DELETE CASCADE,
  CONSTRAINT fk_payout_line_invoice_id FOREIGN KEY (invoice_id)
    REFERENCES invoice(id) ON DELETE RESTRICT,
  CONSTRAINT fk_payout_line_invoice_line_id FOREIGN KEY (invoice_line_id)
    REFERENCES invoice_line(id) ON DELETE RESTRICT,
  CONSTRAINT uq_payout_line_payout_id_invoice_line_id
    UNIQUE (payout_id, invoice_line_id)
);

COMMENT ON TABLE payout_line IS
  'The allocations a payout is made of, one row per invoice line. Together '
  'these rows must sum to payout.gross_paisa; B8 asserts that as the '
  'reconciliation before a payout is released. ON DELETE RESTRICT on the '
  'invoice side is deliberate: money that has been paid out must never be '
  'removable by cascading an invoice delete.';
COMMENT ON COLUMN payout_line.amount_paisa IS
  'The beneficiary''s share of that invoice line, copied from the '
  'split_allocation row rather than re-derived, so the payout is reconciled '
  'against exactly the numbers that were published.';

CREATE TRIGGER trg_payout_line_updated_at
  BEFORE UPDATE ON payout_line
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- adjustment — manual credit or debit with a mandatory reason
-- -----------------------------------------------------------------------------
-- Money moves for reasons no contract predicted: a driver ran an extra trip, a
-- school overpaid by a month, a parent was double-charged during a pilot bug.
-- An adjustment records that with a justification. The reason is NOT NULL and
-- a blank string is rejected by a check, so a row that says nothing about why
-- money moved cannot be written at all.
-- -----------------------------------------------------------------------------

CREATE TABLE adjustment (
  id               uuid             PRIMARY KEY DEFAULT gen_random_uuid(),
  beneficiary_type beneficiary_type NOT NULL,
  beneficiary_id   uuid             NOT NULL,
  amount_paisa     bigint           NOT NULL,
  reason           text             NOT NULL,
  created_by       uuid             NOT NULL,
  created_at       timestamptz      NOT NULL DEFAULT now(),
  updated_at       timestamptz      NOT NULL DEFAULT now(),
  CONSTRAINT ck_adjustment_reason_not_blank CHECK (reason ~ '\S'),
  CONSTRAINT ck_adjustment_amount_not_zero CHECK (amount_paisa <> 0)
);

COMMENT ON TABLE adjustment IS
  'A signed manual correction to what a beneficiary is owed, with a mandatory '
  'written justification. check ck_adjustment_reason_not_blank rejects the '
  'empty string and any whitespace-only value, including tabs and newlines, so '
  '"money moved without a reason" is not merely discouraged but unwritable.';
COMMENT ON COLUMN adjustment.amount_paisa IS
  'Signed: negative reduces what the beneficiary is owed, positive increases '
  'it. Zero is rejected — an adjustment that changes nothing is a mistake.';
COMMENT ON COLUMN adjustment.reason IS
  'Required, non-blank, and written for the person who reads it six months '
  'later during a dispute. Kept plain text; D8 records the change in the '
  'append-only audit log alongside before/after values.';
COMMENT ON COLUMN adjustment.created_by IS
  'app_user id of the staff member who authorised the adjustment. NOT NULL and '
  'plain uuid with no foreign key on purpose: an audit pointer must not be '
  'deletable, and blocking an account deletion to protect it would be the '
  'wrong trade. The D8 audit log carries the immutable record.';

CREATE TRIGGER trg_adjustment_updated_at
  BEFORE UPDATE ON adjustment
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- Indexes
-- -----------------------------------------------------------------------------
-- Exactly the read paths the product actually uses. Every one of these backs a
-- dashboard query or the billing run; none is speculative.
-- -----------------------------------------------------------------------------

-- B8 groups invoices by period when closing; the parent invoice list and the
-- admin billing console filter by enrollment.
CREATE INDEX idx_invoice_billing_period_id ON invoice (billing_period_id);
CREATE INDEX idx_invoice_enrollment_id     ON invoice (enrollment_id);

-- The receivables query: unpaid invoices, soonest due first.
CREATE INDEX idx_invoice_status_due_date ON invoice (status, due_date);

-- The parent's own invoice list, and the school dashboard's month view.
CREATE INDEX idx_invoice_guardian_id ON invoice (guardian_id);
CREATE INDEX idx_invoice_school_id   ON invoice (school_id);

-- "Which payments are against this invoice" and the admin confirmation queue.
CREATE INDEX idx_payment_invoice_id ON payment (invoice_id);
CREATE INDEX idx_payment_status     ON payment (status);

-- The driver earnings and school earnings screens: one beneficiary, one range.
CREATE INDEX idx_split_allocation_beneficiary_type_beneficiary_id
  ON split_allocation (beneficiary_type, beneficiary_id);

-- The payout release queue.
CREATE INDEX idx_payout_status ON payout (status);

