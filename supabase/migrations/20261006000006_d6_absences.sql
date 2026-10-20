-- =============================================================================
-- D6 — Attendance and absences
-- =============================================================================
-- CONVENTIONS (binding, restated from D1 — they still hold):
--   * Objects are written UNQUALIFIED. The target schema is set by the
--     SET search_path line below, which db/apply-schema.mjs rewrites when
--     rendering the demo variant. Do NOT hard-code a schema name anywhere
--     in this file. The single exception is the 'public' literal inside a
--     SET search_path function clause, which is what the rewriter keys off.
--   * Singular snake_case tables, snake_case columns.
--   * Timestamps: timestamptz, column suffix _at. Dates: date, suffix _on.
--   * Constraints named pk_ / fk_<table>_<column> / uq_ / ck_ / idx_ / trg_.
--   * Booleans prefixed is_ or has_.
--   * Every table gets created_at, updated_at and trg_<table>_updated_at.
--   * A cross-table rule is a BEFORE trigger raising 23514 (check_violation).
--   * NO RLS in this file. RLS is applied in D8, across every table.
--
-- ENUMS reused from D1, not redeclared: absence_status, checkin_result.
--
-- WHAT THIS FILE IS FOR
--   1. absence: a guardian tells us their child will not ride on a date.
--      Only a guardian OF THAT CHILD may say so (trigger).
--   2. The real is_student_absent(), replacing the D5 stub. That is the whole
--      of the child_absent hook: D5's record_trip_checkin() already calls
--      is_student_absent(v_student, v_trip.trip_date) and records
--      'child_absent' when it answers true. record_trip_checkin() itself is
--      NOT redefined here.
--   3. v_trip_stop_attendance: the driver's stop list for a trip, with the
--      stops whose every rider is absent marked skippable.
--   4. notification: a minimal, pointer-only outbox, fed by absence changes so
--      the driver hears about them. No provider integration.
--
-- WHAT AN ABSENCE IS NOT: a billing event. The monthly fee is a flat
-- subscription for a seat on the route; absences do not prorate it, credit it
-- or pause the enrollment. Nothing in D2's billing path reads this table.
-- =============================================================================

SET search_path TO public, extensions;

-- -----------------------------------------------------------------------------
-- absence — "my child will not ride on this date"
-- -----------------------------------------------------------------------------
-- ONE ROW PER CHILD PER DATE, not a date range. A three-day absence is three
-- rows. That is deliberate:
--   * The duplicate guard is then a plain partial unique index, which the
--     database proves, instead of an overlap exclusion constraint (which
--     needs btree_gist) or an overlap trigger (which races).
--   * Cancelling one day of a longer absence is cancelling one row, not
--     splitting a range in two.
--   * is_student_absent() becomes an index equality lookup.
--
-- CANCELLING IS A STATUS CHANGE, NOT A DELETE. A cancelled row stays as the
-- record that the guardian said "absent" and then changed their mind, which
-- is exactly what a driver who skipped the stop on the strength of it needs
-- to be able to show. A new absence for the same date may be submitted after
-- a cancellation (the unique index ignores cancelled rows). D8 revokes DELETE.
--
-- The submitter is recorded as a guardian row, not a bare app_user id: the
-- guardian row is what makes someone this child's parent (see D3), and the
-- FK lets trg_absence_rules prove the link instead of trusting the caller.
-- -----------------------------------------------------------------------------

CREATE TABLE absence (
  id               uuid           PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id       uuid           NOT NULL,
  absent_on        date           NOT NULL,
  reason           text,
  status           absence_status NOT NULL DEFAULT 'submitted',
  guardian_id      uuid           NOT NULL,
  acknowledged_at  timestamptz,
  acknowledged_by  uuid,
  cancelled_at     timestamptz,
  created_at       timestamptz    NOT NULL DEFAULT now(),
  updated_at       timestamptz    NOT NULL DEFAULT now(),
  CONSTRAINT fk_absence_student_id FOREIGN KEY (student_id)
    REFERENCES student(id) ON DELETE RESTRICT,
  CONSTRAINT fk_absence_guardian_id FOREIGN KEY (guardian_id)
    REFERENCES guardian(id) ON DELETE RESTRICT,
  CONSTRAINT ck_absence_reason_not_blank CHECK (
    reason IS NULL OR length(btrim(reason)) > 0
  ),
  CONSTRAINT ck_absence_cancelled_at_paired CHECK (
    (status = 'cancelled') = (cancelled_at IS NOT NULL)
  ),
  CONSTRAINT ck_absence_acknowledged_at_set CHECK (
    status <> 'acknowledged' OR acknowledged_at IS NOT NULL
  )
);

COMMENT ON TABLE absence IS
  'A guardian''s report that one child will not ride on one date. Feeds the '
  'child_absent check-in result (is_student_absent()) and lets the driver skip '
  'a stop (v_trip_stop_attendance). Only a guardian of the child may submit '
  '(trg_absence_rules). One active row per (student, date) '
  '(uq_absence_one_active_per_student_date); cancelling is a status change, '
  'never a DELETE. NOT BILLING-RELEVANT: an absence never prorates, credits or '
  'pauses the monthly fee, and no billing code reads this table.';
COMMENT ON COLUMN absence.absent_on IS
  'The date the child will not ride. One row per date: a multi-day absence is '
  'several rows, so the duplicate guard can be a unique index.';
COMMENT ON COLUMN absence.reason IS
  'Optional free text from the guardian ("sick", "family wedding"). Shown to '
  'the driver and school; must not be used to record medical detail beyond '
  'what the guardian chooses to type.';
COMMENT ON COLUMN absence.guardian_id IS
  'The guardian who submitted the absence. Must be a guardian OF student_id '
  '(trg_absence_rules, 23514). Immutable.';
COMMENT ON COLUMN absence.status IS
  'submitted -> acknowledged -> cancelled, or submitted -> cancelled. '
  'cancelled is terminal: re-reporting the date is a new row. Only '
  'submitted and acknowledged rows count as absent.';
COMMENT ON COLUMN absence.acknowledged_by IS
  'app_user id of the driver or school staff who acknowledged. Plain uuid '
  'audit pointer, no foreign key (see rate_snapshot.created_by).';
COMMENT ON COLUMN absence.cancelled_at IS
  'Stamped by trg_absence_rules when status becomes cancelled. Set if and only '
  'if status = cancelled (ck_absence_cancelled_at_paired).';

CREATE OR REPLACE FUNCTION enforce_absence_rules()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_guardian_student uuid;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT g.student_id INTO v_guardian_student
      FROM guardian g WHERE g.id = NEW.guardian_id;

    IF v_guardian_student IS DISTINCT FROM NEW.student_id THEN
      RAISE EXCEPTION 'absence: guardian % is not a guardian of student %',
        NEW.guardian_id, NEW.student_id
        USING ERRCODE = 'check_violation';
    END IF;

    IF NEW.status <> 'submitted' THEN
      RAISE EXCEPTION 'absence: a new absence must start as submitted, not %', NEW.status
        USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
  END IF;

  IF NEW.student_id IS DISTINCT FROM OLD.student_id
     OR NEW.absent_on IS DISTINCT FROM OLD.absent_on
     OR NEW.guardian_id IS DISTINCT FROM OLD.guardian_id THEN
    RAISE EXCEPTION
      'absence %: student_id, absent_on and guardian_id are immutable; cancel it and submit a new one',
      OLD.id
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT (
         (OLD.status = 'submitted'    AND NEW.status IN ('acknowledged', 'cancelled'))
      OR (OLD.status = 'acknowledged' AND NEW.status = 'cancelled')
    ) THEN
      RAISE EXCEPTION 'absence %: illegal status change % -> %',
        OLD.id, OLD.status, NEW.status
        USING ERRCODE = 'check_violation';
    END IF;

    IF NEW.status = 'acknowledged' THEN
      NEW.acknowledged_at := coalesce(NEW.acknowledged_at, now());
    ELSIF NEW.status = 'cancelled' THEN
      NEW.cancelled_at := coalesce(NEW.cancelled_at, now());
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION enforce_absence_rules() IS
  'BEFORE INSERT OR UPDATE guard on absence. Insert: the guardian must be a '
  'guardian of the student (23514; without it any parent could cancel another '
  'family''s pickup), and status starts as submitted. Update: student_id, '
  'absent_on and guardian_id are immutable, status moves only submitted -> '
  'acknowledged -> cancelled (cancelled terminal), and acknowledged_at / '
  'cancelled_at are stamped.';

CREATE TRIGGER trg_absence_rules
  BEFORE INSERT OR UPDATE ON absence
  FOR EACH ROW EXECUTE FUNCTION enforce_absence_rules();

CREATE TRIGGER trg_absence_updated_at
  BEFORE UPDATE ON absence
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- The duplicate guard, and the index is_student_absent() reads. Cancelled rows
-- are outside it, so cancel-then-resubmit works.
CREATE UNIQUE INDEX uq_absence_one_active_per_student_date
  ON absence (student_id, absent_on) WHERE status <> 'cancelled';

COMMENT ON INDEX uq_absence_one_active_per_student_date IS
  'At most one non-cancelled absence per (student, date). Also serves '
  'is_student_absent().';

CREATE INDEX idx_absence_guardian_id ON absence (guardian_id);
-- Non-partial: serves fk_absence_student_id and the guardian's history view,
-- which include cancelled rows the partial unique index leaves out.
CREATE INDEX idx_absence_student_id_absent_on ON absence (student_id, absent_on);

-- -----------------------------------------------------------------------------
-- is_student_absent — the real D6 hook (replaces the D5 stub)
-- -----------------------------------------------------------------------------
-- Same signature as the D5 stub, as D5 requires. record_trip_checkin() and
-- v_trip_stop_attendance call it.
--
-- SECURITY DEFINER: under D8 a driver cannot read the absence table (it holds
-- a guardian's free-text reason), but the check-in and the stop list must
-- still know whether the child is absent. This answers that one boolean and
-- nothing else.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION is_student_absent(p_student_id uuid, p_on date)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM absence a
     WHERE a.student_id = p_student_id
       AND a.absent_on  = p_on
       AND a.status <> 'cancelled'
  );
$$;

COMMENT ON FUNCTION is_student_absent(uuid, date) IS
  'True when a guardian has reported the student absent on p_on (an absence '
  'row that is submitted or acknowledged; cancelled rows do not count). '
  'Replaces the D5 stub with the same signature; record_trip_checkin() calls '
  'it to record child_absent, and v_trip_stop_attendance to mark skippable '
  'stops. SECURITY DEFINER so a driver learns the boolean without reading the '
  'absence row.';

-- -----------------------------------------------------------------------------
-- v_trip_stop_attendance — the driver's stop list for a trip
-- -----------------------------------------------------------------------------
-- One row per (trip, stop on the trip's route): how many active manifest
-- riders the stop has, how many of them are absent on the trip date, and
-- whether the driver may skip it (every rider absent, or nobody manifested).
--
--   SELECT * FROM v_trip_stop_attendance WHERE trip_id = $1 ORDER BY stop_order;
--
-- security_invoker = true, so D8's RLS on trip / route_stop / route_manifest
-- decides which trips a driver sees here.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_trip_stop_attendance
WITH (security_invoker = true) AS
SELECT
  t.id           AS trip_id,
  t.trip_date,
  t.route_id,
  s.id           AS route_stop_id,
  s.stop_order,
  s.name         AS stop_name,
  count(m.id)::int AS rider_count,
  (count(m.id) FILTER (WHERE is_student_absent(m.student_id, t.trip_date)))::int AS absent_count,
  count(m.id) = count(m.id) FILTER (WHERE is_student_absent(m.student_id, t.trip_date))
                 AS is_skippable
FROM trip t
JOIN route_stop s
  ON s.route_id = t.route_id
LEFT JOIN route_manifest m
  ON m.route_stop_id = s.id AND m.route_id = s.route_id AND m.is_active
GROUP BY t.id, t.trip_date, t.route_id, s.id, s.stop_order, s.name;

COMMENT ON VIEW v_trip_stop_attendance IS
  'Per trip, every stop on its route with rider_count (active manifest), '
  'absent_count (is_student_absent() on the trip date) and is_skippable '
  '(all riders absent, or none manifested). The driver app''s stop list. '
  'security_invoker = true so D8''s RLS applies to whoever queries it.';

-- -----------------------------------------------------------------------------
-- notification — minimal pointer-only outbox
-- -----------------------------------------------------------------------------
-- The database records THAT someone should be told something; a worker
-- outside the database delivers it (push, SMS, WhatsApp) and flips status.
-- POINTER-ONLY: payload carries ids and dates, never a child's name, a reason
-- text or a location. The worker resolves what it needs under its own
-- permissions at send time, so a leaked outbox row reveals nothing about a
-- child, and a row queued before a guardian was unlinked cannot carry stale
-- personal data to the wrong person.
-- -----------------------------------------------------------------------------

CREATE TYPE notification_status AS ENUM ('pending', 'sent', 'failed');

CREATE TABLE notification (
  id                     uuid                PRIMARY KEY DEFAULT gen_random_uuid(),
  recipient_app_user_id  uuid                NOT NULL,
  kind                   text                NOT NULL,
  payload                jsonb               NOT NULL DEFAULT '{}'::jsonb,
  status                 notification_status NOT NULL DEFAULT 'pending',
  sent_at                timestamptz,
  created_at             timestamptz         NOT NULL DEFAULT now(),
  updated_at             timestamptz         NOT NULL DEFAULT now(),
  CONSTRAINT fk_notification_recipient_app_user_id FOREIGN KEY (recipient_app_user_id)
    REFERENCES app_user(id) ON DELETE CASCADE,
  CONSTRAINT ck_notification_kind_format CHECK (kind ~ '^[a-z][a-z0-9_]*$'),
  CONSTRAINT ck_notification_payload_object CHECK (jsonb_typeof(payload) = 'object'),
  CONSTRAINT ck_notification_sent_at_paired CHECK (
    (status = 'sent') = (sent_at IS NOT NULL)
  )
);

COMMENT ON TABLE notification IS
  'Outbox of messages to deliver to one app_user. Pointer-only: payload holds '
  'ids and dates, never names, reasons or locations. Delivered and marked '
  'sent/failed by a worker outside the database; no provider integration '
  'lives here. Written today by trg_absence_notify.';
COMMENT ON COLUMN notification.kind IS
  'Machine name of the message template, e.g. absence_submitted, '
  'absence_cancelled. snake_case (ck_notification_kind_format).';
COMMENT ON COLUMN notification.payload IS
  'Ids the worker needs to render the message (e.g. absence_id, student_id, '
  'absent_on). A JSON object. Never personal data.';
COMMENT ON COLUMN notification.sent_at IS
  'Set if and only if status = sent (ck_notification_sent_at_paired).';

CREATE TRIGGER trg_notification_updated_at
  BEFORE UPDATE ON notification
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_notification_recipient_app_user_id ON notification (recipient_app_user_id);
CREATE INDEX idx_notification_pending_created_at ON notification (created_at)
  WHERE status = 'pending';

-- -----------------------------------------------------------------------------
-- trg_absence_notify — tell the driver
-- -----------------------------------------------------------------------------
-- On a new absence, and on its cancellation, queue one notification per
-- driver who would otherwise turn up at the stop: the driver of every active
-- route the child is actively manifested on, plus the driver of any trip
-- already scheduled for that date on those routes (a substitute).
--
-- SECURITY DEFINER: the guardian submitting the absence can neither read
-- driver rows nor write another user's notifications under D8.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION enqueue_absence_notification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_kind text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_kind := 'absence_submitted';
  ELSIF NEW.status = 'cancelled' AND OLD.status IS DISTINCT FROM 'cancelled' THEN
    v_kind := 'absence_cancelled';
  ELSE
    RETURN NULL;
  END IF;

  INSERT INTO notification (recipient_app_user_id, kind, payload)
  SELECT DISTINCT d.app_user_id, v_kind,
         jsonb_build_object('absence_id', NEW.id,
                            'student_id', NEW.student_id,
                            'absent_on',  NEW.absent_on)
    FROM route_manifest m
    JOIN route r ON r.id = m.route_id AND r.is_active
    JOIN driver d ON d.id = r.driver_id
   WHERE m.student_id = NEW.student_id AND m.is_active
  UNION
  SELECT d.app_user_id, v_kind,
         jsonb_build_object('absence_id', NEW.id,
                            'student_id', NEW.student_id,
                            'absent_on',  NEW.absent_on)
    FROM route_manifest m
    JOIN trip t ON t.route_id = m.route_id AND t.trip_date = NEW.absent_on
    JOIN driver d ON d.id = t.driver_id
   WHERE m.student_id = NEW.student_id AND m.is_active;

  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION enqueue_absence_notification() IS
  'AFTER INSERT OR UPDATE OF status on absence: queues absence_submitted (on '
  'insert) or absence_cancelled (on cancellation) for each driver of the '
  'child''s active routes and of any trip on those routes that date. Payload '
  'is ids only.';

CREATE TRIGGER trg_absence_notify
  AFTER INSERT OR UPDATE OF status ON absence
  FOR EACH ROW EXECUTE FUNCTION enqueue_absence_notification();

-- =============================================================================
-- Deliberately NOT in this file
-- =============================================================================
--   * Any billing effect. Absences do not prorate, credit or pause the fee;
--     is_billable() and the invoice path are untouched.
--   * A redefinition of record_trip_checkin(). D5 already calls
--     is_student_absent(); replacing that function was the whole hook.
--   * Per-direction absences (morning vs afternoon). trip is one run per
--     route per date today; when it gains a direction, absence gains one too.
--   * RLS (guardians see and write their own children's absences; drivers
--     see none, only is_student_absent()), and REVOKE DELETE ON absence. D8.
-- =============================================================================
