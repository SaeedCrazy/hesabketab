-- =====================================================================
-- حساب‌کتاب — 70_platform.sql   (سند طراحی: docs/design/09-owner-platform.md)
-- پایگاه دادهٔ «صفحهٔ کنترل» (control plane)، اسکیمای platform — PostgreSQL 18
--
-- این فایل روی یک پایگاه دادهٔ جدا اجرا می‌شود (ds_platform در آزمون؛ platform در تولید) و
-- هرگز روی پایگاه دادهٔ داده اجرا نمی‌شود. 00_foundation.sql روی این پایگاه داده اجرا نمی‌شود و
-- هیچ شیء core/ledger/... این‌جا وجود ندارد. صفحهٔ کنترل هیچ اتصال و اعتباری به پایگاه دادهٔ داده ندارد
-- (بخش ۰۱ D-06/D-09، INV-ARCH-11): ارتباط فقط از «حالت مطلوب» امضاشده، فرمان سلول و uplink است.
--
-- اجرا با نقش مالک (تولید: hk_platform_migrator؛ آزمون: postgres)، با psql -v ON_ERROR_STOP=1.
-- نقش‌های زمان اجرا (هیچ‌کدام مالک، superuser یا BYPASSRLS نیستند):
--   hk_platform_app       API پنل مالک (admin.{OPS_DOMAIN}) و platform-worker
--   hk_platform_ingest    شنوندهٔ داخلی mTLS کانال کنترل و uplink (سلول‌ها و نصب‌های On-prem)
--   hk_partner_app        پرتال نماینده (partner.{APP_DOMAIN})؛ RLS بر platform.current_reseller_id()
--   hk_platform_readonly  گزارش و BI؛ بدون ستون‌های راز
--   hk_platform_audit_writer  (NOLOGIN) مالک تنها تابع SECURITY DEFINER: platform.audit_seal
-- کدهای خطا: «HK_PLT_*: پیام» با SQLSTATE P0001 (نگاشت API در سند §۵-۲۰).
-- =====================================================================

SET client_min_messages = warning;

-- ---------- پیش‌شرط‌ها ----------
DO $$
BEGIN
  IF current_setting('server_encoding') <> 'UTF8' THEN
    RAISE EXCEPTION 'HK_ENCODING: control-plane database must be UTF8 (got %)', current_setting('server_encoding');
  END IF;
  IF current_setting('server_version_num')::int < 180000 THEN
    RAISE EXCEPTION 'HK_PG_VERSION: PostgreSQL 18+ required (uuidv7)';
  END IF;
  IF EXISTS (SELECT FROM pg_namespace WHERE nspname = 'ledger') THEN
    RAISE EXCEPTION 'HK_PLT_WRONG_DATABASE: 70_platform.sql must not be applied to a data-plane database';
  END IF;
END $$;

-- ---------- نقش‌ها (سطح کلاستر، idempotent؛ رمزهای این‌جا فقط برای توسعه/آزمون — C-01 بخش ۰۱) ----------
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hk_platform_app') THEN
    CREATE ROLE hk_platform_app LOGIN PASSWORD 'hk_platform_app' NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hk_platform_ingest') THEN
    CREATE ROLE hk_platform_ingest LOGIN PASSWORD 'hk_platform_ingest' NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hk_partner_app') THEN
    CREATE ROLE hk_partner_app LOGIN PASSWORD 'hk_partner_app' NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hk_platform_readonly') THEN
    CREATE ROLE hk_platform_readonly LOGIN PASSWORD 'hk_platform_readonly' NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hk_platform_audit_writer') THEN
    CREATE ROLE hk_platform_audit_writer NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
  END IF;
END $$;
ALTER ROLE hk_platform_app      SET statement_timeout = '30s';
ALTER ROLE hk_platform_app      SET idle_in_transaction_session_timeout = '15s';
ALTER ROLE hk_platform_ingest   SET statement_timeout = '10s';
ALTER ROLE hk_partner_app       SET statement_timeout = '15s';
ALTER ROLE hk_platform_readonly SET statement_timeout = '300s';

CREATE SCHEMA IF NOT EXISTS platform;
REVOKE ALL ON SCHEMA platform FROM PUBLIC;
GRANT USAGE ON SCHEMA platform TO hk_platform_app, hk_platform_ingest, hk_partner_app, hk_platform_readonly, hk_platform_audit_writer;
CREATE EXTENSION IF NOT EXISTS btree_gist;   -- EXCLUDE روی بازهٔ زمانی (دورهٔ اشتراک، قاعدهٔ کمیسیون، قلمرو، تعرفه)

-- =====================================================================
-- ۱. توابع کمکی
-- =====================================================================
CREATE OR REPLACE FUNCTION platform.fail(p_code text, p_msg text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '%: %', p_code, p_msg USING ERRCODE = 'P0001';
END $$;

-- زمینهٔ درخواست (هر تراکنش با set_config(..., true))
CREATE OR REPLACE FUNCTION platform.current_staff_id() RETURNS uuid
LANGUAGE sql STABLE AS $$ SELECT NULLIF(current_setting('app.staff_id', true), '')::uuid $$;
CREATE OR REPLACE FUNCTION platform.current_staff_session_id() RETURNS uuid
LANGUAGE sql STABLE AS $$ SELECT NULLIF(current_setting('app.staff_session_id', true), '')::uuid $$;
CREATE OR REPLACE FUNCTION platform.current_reseller_id() RETURNS uuid
LANGUAGE sql STABLE AS $$ SELECT NULLIF(current_setting('app.reseller_id', true), '')::uuid $$;
CREATE OR REPLACE FUNCTION platform.current_reseller_user_id() RETURNS uuid
LANGUAGE sql STABLE AS $$ SELECT NULLIF(current_setting('app.reseller_user_id', true), '')::uuid $$;

-- «تودرتو»: آیا این تریگر از درون تریگر دیگری اجرا می‌شود؟ ستون‌های مشتق (وضعیت مستأجر، ماندهٔ کیف پول،
-- مبلغ پرداخت‌شدهٔ صورتحساب، ...) فقط از مسیر تریگر رویداد/سطر مالک تغییر می‌کنند، نه با UPDATE مستقیم برنامه.
CREATE OR REPLACE FUNCTION platform.is_nested() RETURNS boolean
LANGUAGE sql STABLE AS $$ SELECT pg_trigger_depth() >= 2 $$;

CREATE OR REPLACE FUNCTION platform.touch_row() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  NEW.row_version := OLD.row_version + 1;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION platform.forbid_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'HK_PLT_IMMUTABLE: % on %.% is not allowed', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME
    USING ERRCODE = 'P0001';
END $$;

-- نسخهٔ CalVer (YYYY.M.P) برای مقایسه
CREATE OR REPLACE FUNCTION platform.calver_key(p text) RETURNS int[]
LANGUAGE sql IMMUTABLE STRICT AS $$ SELECT string_to_array(p, '.')::int[] $$;

-- sha256 متن UTF-8
CREATE OR REPLACE FUNCTION platform.sha256_text(p text) RETURNS bytea
LANGUAGE sql IMMUTABLE STRICT AS $$ SELECT sha256(convert_to(p, 'UTF8')) $$;

-- نصب تریگرهای فقط‌افزودنی (سطر و TRUNCATE)
CREATE OR REPLACE FUNCTION platform.make_append_only(tbl regclass) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('DROP TRIGGER IF EXISTS trg_immutable ON %s', tbl);
  EXECUTE format('CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION platform.forbid_mutation()', tbl);
  EXECUTE format('DROP TRIGGER IF EXISTS trg_no_truncate ON %s', tbl);
  EXECUTE format('CREATE TRIGGER trg_no_truncate BEFORE TRUNCATE ON %s FOR EACH STATEMENT EXECUTE FUNCTION platform.forbid_mutation()', tbl);
END $$;

CREATE OR REPLACE FUNCTION platform.add_touch(tbl regclass) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('DROP TRIGGER IF EXISTS trg_touch ON %s', tbl);
  EXECUTE format('CREATE TRIGGER trg_touch BEFORE UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION platform.touch_row()', tbl);
END $$;

-- RLS دونقشی: کارکنان و ingest و readonly همه‌چیز را می‌بینند (مجوز در برنامه)، نماینده فقط سطرهای خودش.
-- p_partner_using عبارت SQL بر حسب ستون‌های جدول است (مثلاً 'reseller_id = platform.current_reseller_id()').
CREATE OR REPLACE FUNCTION platform.enable_partner_rls(tbl regclass, p_partner_using text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', tbl);
  EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', tbl);
  EXECUTE format('DROP POLICY IF EXISTS staff_all ON %s', tbl);
  EXECUTE format('CREATE POLICY staff_all ON %s AS PERMISSIVE FOR ALL TO hk_platform_app, hk_platform_ingest, hk_platform_readonly USING (true) WITH CHECK (true)', tbl);
  EXECUTE format('DROP POLICY IF EXISTS partner_own ON %s', tbl);
  EXECUTE format('CREATE POLICY partner_own ON %s AS PERMISSIVE FOR ALL TO hk_partner_app USING (%s) WITH CHECK (%s)',
                 tbl, p_partner_using, p_partner_using);
END $$;

-- =====================================================================
-- ۲. دادهٔ مرجع جغرافیایی (همان کدهای ref.province/ref.city صفحهٔ داده؛ بارگذاری با migration)
-- =====================================================================
CREATE TABLE IF NOT EXISTS platform.geo_province (
  code      text PRIMARY KEY CHECK (code ~ '^[0-9A-Z_-]{1,12}$'),
  name_fa   text NOT NULL
);
CREATE TABLE IF NOT EXISTS platform.geo_city (
  province_code text NOT NULL REFERENCES platform.geo_province(code),
  code          text NOT NULL CHECK (code ~ '^[0-9A-Z_-]{1,16}$'),
  name_fa       text NOT NULL,
  PRIMARY KEY (province_code, code)
);

-- =====================================================================
-- ۳. کارکنان پلتفرم، نقش، مجوز، نشست (ورود: Keycloak OIDC + WebAuthn/TOTP؛ ۲FA اجباری)
-- =====================================================================
CREATE TABLE IF NOT EXISTS platform.staff_role (
  code           text PRIMARY KEY CHECK (code ~ '^[a-z][a-z_]{1,40}$'),
  name_fa        text NOT NULL,
  name_en        text NOT NULL,
  is_privileged  boolean NOT NULL DEFAULT false,   -- اعطای آن تأیید دونفره می‌خواهد
  grants_all     boolean NOT NULL DEFAULT false,   -- فقط owner
  CHECK (NOT grants_all OR is_privileged)
);

CREATE TABLE IF NOT EXISTS platform.staff_permission (
  code         text PRIMARY KEY CHECK (code ~ '^platform\.[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){1,3}$'),
  risk         text NOT NULL DEFAULT 'normal' CHECK (risk IN ('normal','sensitive','critical')),  -- critical = MFA تازه ≤ ۱۰ دقیقه
  description  text NOT NULL
);

CREATE TABLE IF NOT EXISTS platform.staff_role_permission (
  role_code        text NOT NULL REFERENCES platform.staff_role(code),
  permission_code  text NOT NULL REFERENCES platform.staff_permission(code),
  PRIMARY KEY (role_code, permission_code)
);

CREATE TABLE IF NOT EXISTS platform.staff (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  oidc_subject     text UNIQUE CHECK (char_length(oidc_subject) BETWEEN 1 AND 255),
  email            text NOT NULL UNIQUE CHECK (email ~ '^[^@[:space:]]+@[^@[:space:]]+$' AND email = lower(email)),
  display_name     text NOT NULL CHECK (char_length(btrim(display_name)) >= 2),
  mobile           text CHECK (mobile ~ '^09[0-9]{9}$'),
  status           text NOT NULL DEFAULT 'invited' CHECK (status IN ('invited','active','suspended','disabled')),
  mfa_methods      text[] NOT NULL DEFAULT '{}' CHECK (mfa_methods <@ ARRAY['webauthn','totp']::text[]),
  mfa_enrolled_at  timestamptz,
  allowed_cidrs    cidr[],
  last_login_at    timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  row_version      integer NOT NULL DEFAULT 1,
  -- ۲FA اجباری: کارمند فعال باید شناسهٔ OIDC و دست‌کم یک روش MFA ثبت‌شده داشته باشد
  CONSTRAINT staff_active_requires_mfa CHECK (status <> 'active' OR (oidc_subject IS NOT NULL AND mfa_enrolled_at IS NOT NULL AND cardinality(mfa_methods) >= 1)),
  CONSTRAINT staff_non_invited_has_subject CHECK (status = 'invited' OR oidc_subject IS NOT NULL)
);
SELECT platform.add_touch('platform.staff');

-- forward declaration of approval_request is needed by staff_role_assignment; ساخت جدول تأیید پیش از انتساب نقش
CREATE TABLE IF NOT EXISTS platform.approval_action (
  code                 text PRIMARY KEY CHECK (code ~ '^[a-z][a-z_]*\.[a-z][a-z_]*$'),
  subject_type         text NOT NULL CHECK (subject_type ~ '^[a-z][a-z_]*$'),
  approver_permission  text NOT NULL REFERENCES platform.staff_permission(code),
  ttl                  interval NOT NULL DEFAULT interval '24 hours' CHECK (ttl BETWEEN interval '5 minutes' AND interval '7 days'),
  require_fresh_mfa    boolean NOT NULL DEFAULT true,
  description_fa       text NOT NULL
);

CREATE TABLE IF NOT EXISTS platform.approval_request (
  id              uuid PRIMARY KEY DEFAULT uuidv7(),
  action          text NOT NULL REFERENCES platform.approval_action(code),
  subject_type    text NOT NULL,
  subject_id      uuid NOT NULL,
  payload         jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(payload) = 'object'),
  payload_sha256  bytea NOT NULL CHECK (octet_length(payload_sha256) = 32),
  requested_by    uuid NOT NULL REFERENCES platform.staff(id),
  reason          text NOT NULL CHECK (char_length(btrim(reason)) >= 10),
  ticket_ref      text CHECK (char_length(ticket_ref) BETWEEN 1 AND 64),
  status          text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','approved','rejected','cancelled','expired','consumed')),
  decided_by      uuid REFERENCES platform.staff(id),
  decided_at      timestamptz,
  decision_note   text,
  expires_at      timestamptz NOT NULL,
  consumed_at     timestamptz,
  consumed_ref    text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  row_version     integer NOT NULL DEFAULT 1,
  -- چهارچشمی: تصمیم‌گیرنده هرگز درخواست‌دهنده نیست
  CONSTRAINT approval_four_eyes CHECK (decided_by IS NULL OR decided_by <> requested_by),
  CONSTRAINT approval_decision_fields CHECK ((status IN ('approved','rejected','consumed')) = (decided_by IS NOT NULL AND decided_at IS NOT NULL)),
  CONSTRAINT approval_consumed_fields CHECK ((status = 'consumed') = (consumed_at IS NOT NULL AND consumed_ref IS NOT NULL)),
  CONSTRAINT approval_reject_note CHECK (status <> 'rejected' OR char_length(btrim(coalesce(decision_note, ''))) >= 5)
);
CREATE INDEX IF NOT EXISTS approval_request_subject ON platform.approval_request (subject_type, subject_id);
CREATE INDEX IF NOT EXISTS approval_request_pending ON platform.approval_request (status, expires_at) WHERE status = 'pending';
SELECT platform.add_touch('platform.approval_request');

CREATE TABLE IF NOT EXISTS platform.staff_role_assignment (
  id             uuid PRIMARY KEY DEFAULT uuidv7(),
  staff_id       uuid NOT NULL REFERENCES platform.staff(id),
  role_code      text NOT NULL REFERENCES platform.staff_role(code),
  granted_by     uuid REFERENCES platform.staff(id),     -- NULL فقط برای راه‌اندازی اولیه با نقش مالک پایگاه داده
  approval_id    uuid REFERENCES platform.approval_request(id),
  valid_from     timestamptz NOT NULL DEFAULT now(),
  valid_to       timestamptz,
  revoked_at     timestamptz,
  revoked_by     uuid REFERENCES platform.staff(id),
  revoke_reason  text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  CHECK (valid_to IS NULL OR valid_to > valid_from),
  CHECK ((revoked_at IS NULL) = (revoked_by IS NULL)),
  CHECK (revoked_at IS NULL OR char_length(btrim(coalesce(revoke_reason, ''))) >= 5),
  CONSTRAINT role_assignment_no_self_grant CHECK (granted_by IS NULL OR granted_by <> staff_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS staff_role_assignment_live ON platform.staff_role_assignment (staff_id, role_code) WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS platform.staff_session (
  id            uuid PRIMARY KEY DEFAULT uuidv7(),
  staff_id      uuid NOT NULL REFERENCES platform.staff(id),
  token_hash    bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),
  amr           text[] NOT NULL,                    -- روش‌های احراز هویت از ادعای OIDC
  mfa_at        timestamptz NOT NULL,               -- آخرین MFA (step-up به‌روزش می‌کند)
  ip            inet,
  user_agent    text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL,
  last_seen_at  timestamptz NOT NULL DEFAULT now(),
  revoked_at    timestamptz,
  revoke_reason text,
  CONSTRAINT staff_session_mfa CHECK (amr && ARRAY['hwk','otp','webauthn','totp']::text[]),
  CONSTRAINT staff_session_lifetime CHECK (expires_at > created_at AND expires_at <= created_at + interval '12 hours'),
  CHECK (mfa_at <= expires_at),
  CHECK ((revoked_at IS NULL) = (revoke_reason IS NULL))
);

-- آیا کارمند اکنون مجوز دارد؟
CREATE OR REPLACE FUNCTION platform.staff_has_permission(p_staff uuid, p_perm text) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1
    FROM platform.staff s
    JOIN platform.staff_role_assignment a ON a.staff_id = s.id
    JOIN platform.staff_role r ON r.code = a.role_code
    WHERE s.id = p_staff AND s.status = 'active'
      AND a.revoked_at IS NULL AND a.valid_from <= now() AND (a.valid_to IS NULL OR a.valid_to > now())
      AND (r.grants_all OR EXISTS (SELECT 1 FROM platform.staff_role_permission rp
                                   WHERE rp.role_code = r.code AND rp.permission_code = p_perm)))
$$;

CREATE OR REPLACE FUNCTION platform.staff_has_role(p_staff uuid, p_role text) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM platform.staff s JOIN platform.staff_role_assignment a ON a.staff_id = s.id
    WHERE s.id = p_staff AND s.status = 'active' AND a.role_code = p_role
      AND a.revoked_at IS NULL AND a.valid_from <= now() AND (a.valid_to IS NULL OR a.valid_to > now()))
$$;

-- نشست جاری (app.staff_session_id) متعلق به همین کارمند، باز، و با MFA تازه‌تر از p_within است؟
CREATE OR REPLACE FUNCTION platform.staff_mfa_fresh(p_staff uuid, p_within interval) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM platform.staff_session ss
    WHERE ss.id = platform.current_staff_session_id() AND ss.staff_id = p_staff
      AND ss.revoked_at IS NULL AND ss.expires_at > now() AND ss.mfa_at >= now() - p_within)
$$;

CREATE OR REPLACE FUNCTION platform.staff_session_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NOT EXISTS (SELECT 1 FROM platform.staff WHERE id = NEW.staff_id AND status = 'active') THEN
      PERFORM platform.fail('HK_PLT_STAFF_NOT_ACTIVE', 'session for a non-active staff member');
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.staff_id <> OLD.staff_id OR NEW.token_hash <> OLD.token_hash OR NEW.created_at <> OLD.created_at
     OR NEW.amr IS DISTINCT FROM OLD.amr THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'session identity columns are immutable');
  END IF;
  IF NEW.expires_at > OLD.expires_at THEN
    PERFORM platform.fail('HK_PLT_SESSION_EXTEND', 'session lifetime cannot be extended');
  END IF;
  IF OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at THEN
    PERFORM platform.fail('HK_PLT_SESSION_REVOKED', 'revoked session cannot be changed');
  END IF;
  IF OLD.revoked_at IS NOT NULL AND NEW.mfa_at <> OLD.mfa_at THEN
    PERFORM platform.fail('HK_PLT_SESSION_REVOKED', 'revoked session cannot be changed');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.staff_session;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON platform.staff_session FOR EACH ROW EXECUTE FUNCTION platform.staff_session_guard();

-- ---------- تأیید چهارچشمی ----------
CREATE OR REPLACE FUNCTION platform.approval_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_act platform.approval_action%ROWTYPE;
BEGIN
  SELECT * INTO v_act FROM platform.approval_action WHERE code = NEW.action;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'pending' THEN
      PERFORM platform.fail('HK_PLT_APPROVAL_STATE', 'approval requests start as pending');
    END IF;
    IF NEW.requested_by IS DISTINCT FROM platform.current_staff_id() THEN
      PERFORM platform.fail('HK_PLT_ACTOR_MISMATCH', 'requested_by must be the acting staff member');
    END IF;
    IF NEW.subject_type <> v_act.subject_type THEN
      PERFORM platform.fail('HK_PLT_APPROVAL_MISMATCH', format('action %s expects subject %s', NEW.action, v_act.subject_type));
    END IF;
    NEW.payload_sha256 := platform.sha256_text(NEW.payload::text);
    NEW.expires_at := now() + v_act.ttl;
    NEW.decided_by := NULL; NEW.decided_at := NULL; NEW.consumed_at := NULL; NEW.consumed_ref := NULL;
    RETURN NEW;
  END IF;

  IF NEW.action <> OLD.action OR NEW.subject_type <> OLD.subject_type OR NEW.subject_id <> OLD.subject_id
     OR NEW.payload <> OLD.payload OR NEW.payload_sha256 <> OLD.payload_sha256 OR NEW.requested_by <> OLD.requested_by
     OR NEW.reason <> OLD.reason OR NEW.expires_at <> OLD.expires_at OR NEW.created_at <> OLD.created_at THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'approval request content is immutable');
  END IF;
  IF NEW.status = OLD.status THEN
    IF NEW.decided_by IS DISTINCT FROM OLD.decided_by OR NEW.decided_at IS DISTINCT FROM OLD.decided_at
       OR NEW.consumed_at IS DISTINCT FROM OLD.consumed_at THEN
      PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'decision fields change only with a transition');
    END IF;
    RETURN NEW;
  END IF;

  IF OLD.status = 'pending' AND NEW.status IN ('approved','rejected') THEN
    IF now() >= OLD.expires_at THEN
      PERFORM platform.fail('HK_PLT_APPROVAL_EXPIRED', 'approval request has expired');
    END IF;
    IF NEW.decided_by IS DISTINCT FROM platform.current_staff_id() THEN
      PERFORM platform.fail('HK_PLT_ACTOR_MISMATCH', 'decided_by must be the acting staff member');
    END IF;
    IF NEW.decided_by = OLD.requested_by THEN
      PERFORM platform.fail('HK_PLT_FOUR_EYES', 'requester cannot decide own approval request');
    END IF;
    IF NOT platform.staff_has_permission(NEW.decided_by, v_act.approver_permission) THEN
      PERFORM platform.fail('HK_PLT_APPROVER_NOT_ELIGIBLE', format('decider lacks %s', v_act.approver_permission));
    END IF;
    IF v_act.require_fresh_mfa AND NOT platform.staff_mfa_fresh(NEW.decided_by, interval '10 minutes') THEN
      PERFORM platform.fail('HK_PLT_MFA_STALE', 'a fresh MFA (<= 10 minutes) is required to decide');
    END IF;
    NEW.decided_at := now();
  ELSIF OLD.status = 'pending' AND NEW.status = 'cancelled' THEN
    IF platform.current_staff_id() IS DISTINCT FROM OLD.requested_by THEN
      PERFORM platform.fail('HK_PLT_ACTOR_MISMATCH', 'only the requester can cancel');
    END IF;
  ELSIF OLD.status IN ('pending','approved') AND NEW.status = 'expired' THEN
    IF now() < OLD.expires_at THEN
      PERFORM platform.fail('HK_PLT_APPROVAL_STATE', 'not yet expired');
    END IF;
  ELSIF OLD.status = 'approved' AND NEW.status = 'consumed' THEN
    IF NOT platform.is_nested() THEN
      PERFORM platform.fail('HK_PLT_APPROVAL_CONSUME_DIRECT', 'approvals are consumed only by the guarded action');
    END IF;
  ELSE
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', format('approval %s -> %s', OLD.status, NEW.status));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.approval_request;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON platform.approval_request FOR EACH ROW EXECUTE FUNCTION platform.approval_guard();
DROP TRIGGER IF EXISTS trg_no_delete ON platform.approval_request;
CREATE TRIGGER trg_no_delete BEFORE DELETE ON platform.approval_request FOR EACH ROW EXECUTE FUNCTION platform.forbid_mutation();

-- مصرف یک‌بارهٔ تأیید؛ فقط از درون تریگر جدول محافظت‌شده (approval_guard مصرف مستقیم را رد می‌کند)
CREATE OR REPLACE FUNCTION platform.consume_approval(p_id uuid, p_action text, p_subject_type text, p_subject_id uuid, p_ref text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  r platform.approval_request%ROWTYPE;
BEGIN
  IF p_id IS NULL THEN
    PERFORM platform.fail('HK_PLT_APPROVAL_REQUIRED', format('action %s requires an approved four-eyes request', p_action));
  END IF;
  SELECT * INTO r FROM platform.approval_request WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    PERFORM platform.fail('HK_PLT_APPROVAL_REQUIRED', 'approval request not found');
  END IF;
  IF r.action <> p_action OR r.subject_type <> p_subject_type OR r.subject_id <> p_subject_id THEN
    PERFORM platform.fail('HK_PLT_APPROVAL_MISMATCH', format('approval is for %s %s:%s', r.action, r.subject_type, r.subject_id));
  END IF;
  IF r.status <> 'approved' THEN
    PERFORM platform.fail('HK_PLT_APPROVAL_NOT_APPROVED', format('approval status is %s', r.status));
  END IF;
  IF r.expires_at <= now() THEN
    PERFORM platform.fail('HK_PLT_APPROVAL_EXPIRED', 'approval has expired');
  END IF;
  UPDATE platform.approval_request SET status = 'consumed', consumed_at = now(), consumed_ref = p_ref WHERE id = p_id;
END $$;

-- انتساب نقش: بدون خوداعطا؛ نقش ممتاز با تأیید دونفره؛ بوت‌استرپ فقط با نقش مالک پایگاه داده؛ آخرین owner لغوشدنی نیست
CREATE OR REPLACE FUNCTION platform.role_assignment_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_priv boolean;
BEGIN
  SELECT is_privileged INTO v_priv FROM platform.staff_role WHERE code = NEW.role_code;
  IF TG_OP = 'INSERT' THEN
    IF NEW.revoked_at IS NOT NULL THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'assignment cannot be created revoked');
    END IF;
    IF NEW.granted_by IS NULL THEN
      IF current_user IN ('hk_platform_app','hk_platform_ingest','hk_partner_app','hk_platform_readonly') THEN
        PERFORM platform.fail('HK_PLT_BOOTSTRAP_ONLY', 'role assignment without grantor is reserved for bootstrap');
      END IF;
    ELSE
      IF NEW.granted_by IS DISTINCT FROM platform.current_staff_id() THEN
        PERFORM platform.fail('HK_PLT_ACTOR_MISMATCH', 'granted_by must be the acting staff member');
      END IF;
      IF NOT platform.staff_has_permission(NEW.granted_by, 'platform.staff.manage') THEN
        PERFORM platform.fail('HK_PLT_PERMISSION', 'grantor lacks platform.staff.manage');
      END IF;
      IF v_priv THEN
        PERFORM platform.consume_approval(NEW.approval_id, 'staff.grant_privileged_role', 'staff', NEW.staff_id,
                                          'staff_role_assignment:' || NEW.id::text || ':' || NEW.role_code);
      END IF;
    END IF;
    RETURN NEW;
  END IF;
  -- UPDATE: فقط لغو یا کوتاه‌کردن
  IF NEW.staff_id <> OLD.staff_id OR NEW.role_code <> OLD.role_code OR NEW.granted_by IS DISTINCT FROM OLD.granted_by
     OR NEW.approval_id IS DISTINCT FROM OLD.approval_id OR NEW.valid_from <> OLD.valid_from OR NEW.created_at <> OLD.created_at THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'role assignment identity is immutable');
  END IF;
  IF OLD.revoked_at IS NOT NULL AND (NEW.revoked_at IS DISTINCT FROM OLD.revoked_at OR NEW.valid_to IS DISTINCT FROM OLD.valid_to) THEN
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'revoked assignment is final');
  END IF;
  IF NEW.valid_to IS DISTINCT FROM OLD.valid_to AND OLD.valid_to IS NOT NULL AND (NEW.valid_to IS NULL OR NEW.valid_to > OLD.valid_to) THEN
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'assignment can only be shortened');
  END IF;
  IF NEW.revoked_by IS NOT NULL AND OLD.revoked_by IS NULL AND NEW.revoked_by IS DISTINCT FROM platform.current_staff_id()
     AND current_user IN ('hk_platform_app','hk_platform_ingest','hk_partner_app','hk_platform_readonly') THEN
    PERFORM platform.fail('HK_PLT_ACTOR_MISMATCH', 'revoked_by must be the acting staff member');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.staff_role_assignment;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON platform.staff_role_assignment FOR EACH ROW EXECUTE FUNCTION platform.role_assignment_guard();
DROP TRIGGER IF EXISTS trg_no_delete ON platform.staff_role_assignment;
CREATE TRIGGER trg_no_delete BEFORE DELETE ON platform.staff_role_assignment FOR EACH ROW EXECUTE FUNCTION platform.forbid_mutation();

CREATE OR REPLACE FUNCTION platform.last_owner_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.role_code = 'owner' AND OLD.revoked_at IS NULL AND (NEW.revoked_at IS NOT NULL OR NEW.valid_to IS NOT NULL) THEN
    IF NOT EXISTS (SELECT 1 FROM platform.staff_role_assignment a JOIN platform.staff s ON s.id = a.staff_id
                   WHERE a.role_code = 'owner' AND a.id <> NEW.id AND a.revoked_at IS NULL AND a.valid_to IS NULL
                     AND s.status = 'active') THEN
      PERFORM platform.fail('HK_PLT_LAST_OWNER', 'the last active owner assignment cannot be revoked or time-limited');
    END IF;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_last_owner ON platform.staff_role_assignment;
CREATE TRIGGER trg_last_owner AFTER UPDATE ON platform.staff_role_assignment FOR EACH ROW EXECUTE FUNCTION platform.last_owner_guard();

-- =====================================================================
-- ۴. ممیزی پلتفرم: فقط‌افزودنی با زنجیرهٔ hash (قالب hkpaudit1)
-- =====================================================================
CREATE TABLE IF NOT EXISTS platform.audit_chain_head (
  chain       text PRIMARY KEY CHECK (chain = 'platform'),
  last_seq    bigint NOT NULL DEFAULT 0 CHECK (last_seq >= 0),
  last_hash   bytea NOT NULL CHECK (octet_length(last_hash) = 32),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO platform.audit_chain_head (chain, last_seq, last_hash)
VALUES ('platform', 0, decode(repeat('00', 32), 'hex')) ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS platform.audit_log (
  seq             bigint PRIMARY KEY,
  recorded_at     timestamptz NOT NULL,
  occurred_at     timestamptz NOT NULL DEFAULT now(),
  actor_kind      text NOT NULL CHECK (actor_kind IN ('staff','reseller_user','billing_contact','cell','installation','system')),
  actor_id        uuid,
  actor_label     text,
  session_id      uuid,
  request_id      text,
  ip              inet,
  user_agent      text,
  action          text NOT NULL CHECK (action ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){1,4}$'),
  subject_type    text,
  subject_id      text,
  tenant_id       uuid,
  reseller_id     uuid,
  approval_id     uuid,
  outcome         text NOT NULL DEFAULT 'success' CHECK (outcome IN ('success','denied','failed')),
  reason          text,
  details         text NOT NULL DEFAULT '{}' CHECK (details IS JSON OBJECT),
  details_sha256  bytea NOT NULL,
  prev_hash       bytea NOT NULL CHECK (octet_length(prev_hash) = 32),
  row_hash        bytea NOT NULL UNIQUE CHECK (octet_length(row_hash) = 32),
  CHECK (actor_kind = 'system' OR actor_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS audit_log_tenant ON platform.audit_log (tenant_id, seq) WHERE tenant_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS audit_log_actor ON platform.audit_log (actor_kind, actor_id, seq);
CREATE INDEX IF NOT EXISTS audit_log_subject ON platform.audit_log (subject_type, subject_id);

-- قالب متعارف: «hkpaudit1» + هر فیلد به‌صورت <طول بایتی>:<مقدار>؛ NULL = «~»
CREATE OR REPLACE FUNCTION platform.audit_field(p text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p IS NULL THEN '~' ELSE octet_length(convert_to(p, 'UTF8'))::text || ':' || p END
$$;

CREATE OR REPLACE FUNCTION platform.audit_canonical(a platform.audit_log) RETURNS bytea
LANGUAGE sql STABLE AS $$
  SELECT convert_to(
    'hkpaudit1|' ||
    platform.audit_field(a.seq::text) || '|' ||
    platform.audit_field(to_char(a.recorded_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')) || '|' ||
    platform.audit_field(to_char(a.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')) || '|' ||
    platform.audit_field(a.actor_kind) || '|' || platform.audit_field(a.actor_id::text) || '|' ||
    platform.audit_field(a.actor_label) || '|' || platform.audit_field(a.session_id::text) || '|' ||
    platform.audit_field(a.request_id) || '|' || platform.audit_field(host(a.ip)) || '|' ||
    platform.audit_field(a.action) || '|' || platform.audit_field(a.subject_type) || '|' ||
    platform.audit_field(a.subject_id) || '|' || platform.audit_field(a.tenant_id::text) || '|' ||
    platform.audit_field(a.reseller_id::text) || '|' || platform.audit_field(a.approval_id::text) || '|' ||
    platform.audit_field(a.outcome) || '|' || platform.audit_field(a.reason) || '|' ||
    platform.audit_field(encode(a.details_sha256, 'hex')), 'UTF8')
$$;

-- مُهر هنگام درج (SECURITY DEFINER؛ مالک hk_platform_audit_writer؛ تنها تابع definer این پایگاه داده)
CREATE OR REPLACE FUNCTION platform.audit_seal() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_seq  bigint;
  v_hash bytea;
BEGIN
  SELECT last_seq, last_hash INTO v_seq, v_hash FROM platform.audit_chain_head WHERE chain = 'platform' FOR UPDATE;
  NEW.seq := v_seq + 1;
  NEW.recorded_at := clock_timestamp();
  NEW.details_sha256 := sha256(convert_to(NEW.details, 'UTF8'));
  NEW.prev_hash := v_hash;
  NEW.row_hash := sha256(v_hash || platform.audit_canonical(NEW));
  UPDATE platform.audit_chain_head SET last_seq = NEW.seq, last_hash = NEW.row_hash, updated_at = now() WHERE chain = 'platform';
  RETURN NEW;
END $$;
ALTER FUNCTION platform.audit_seal() OWNER TO hk_platform_audit_writer;
REVOKE ALL ON FUNCTION platform.audit_seal() FROM PUBLIC;
DROP TRIGGER IF EXISTS trg_seal ON platform.audit_log;
CREATE TRIGGER trg_seal BEFORE INSERT ON platform.audit_log FOR EACH ROW EXECUTE FUNCTION platform.audit_seal();
SELECT platform.make_append_only('platform.audit_log');

CREATE OR REPLACE FUNCTION platform.audit_head_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE', 'audit chain head cannot be deleted');
  END IF;
  IF NEW.last_seq <> OLD.last_seq + 1 THEN
    PERFORM platform.fail('HK_PLT_AUDIT_HEAD', 'audit head advances by exactly one');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.audit_chain_head;
CREATE TRIGGER trg_guard BEFORE UPDATE OR DELETE ON platform.audit_chain_head FOR EACH ROW EXECUTE FUNCTION platform.audit_head_guard();

-- راستی‌آزمایی زنجیره (همتای مستقل پایتون: platform/audit/verify.py)
CREATE OR REPLACE FUNCTION platform.audit_verify(p_from bigint DEFAULT 1, p_to bigint DEFAULT NULL)
RETURNS TABLE (seq bigint, problem text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  r       platform.audit_log;
  v_prev  bytea;
  v_exp   bigint := p_from;
BEGIN
  IF p_from > 1 THEN
    SELECT a.row_hash INTO v_prev FROM platform.audit_log a WHERE a.seq = p_from - 1;
  ELSE
    v_prev := decode(repeat('00', 32), 'hex');
  END IF;
  FOR r IN SELECT * FROM platform.audit_log a WHERE a.seq >= p_from AND (p_to IS NULL OR a.seq <= p_to) ORDER BY a.seq LOOP
    IF r.seq <> v_exp THEN
      seq := v_exp; problem := 'gap'; RETURN NEXT; v_exp := r.seq;
    END IF;
    IF r.prev_hash IS DISTINCT FROM v_prev THEN
      seq := r.seq; problem := 'prev_hash'; RETURN NEXT;
    END IF;
    IF r.details_sha256 <> sha256(convert_to(r.details, 'UTF8')) THEN
      seq := r.seq; problem := 'details_sha256'; RETURN NEXT;
    END IF;
    IF r.row_hash <> sha256(r.prev_hash || platform.audit_canonical(r)) THEN
      seq := r.seq; problem := 'row_hash'; RETURN NEXT;
    END IF;
    v_prev := r.row_hash;
    v_exp := r.seq + 1;
  END LOOP;
  RETURN;
END $$;

CREATE TABLE IF NOT EXISTS platform.audit_checkpoint (
  id              uuid PRIMARY KEY DEFAULT uuidv7(),
  verified_to_seq bigint NOT NULL CHECK (verified_to_seq >= 0),
  head_hash       bytea NOT NULL CHECK (octet_length(head_hash) = 32),
  result          text NOT NULL CHECK (result IN ('ok','broken')),
  problems        jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(problems) = 'array'),
  anchors         jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(anchors) = 'array'),  -- [{"target":"house_tenant_note|printed|owner_sms","ref":"…"}]
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK ((result = 'ok') = (jsonb_array_length(problems) = 0))
);
SELECT platform.make_append_only('platform.audit_checkpoint');

-- =====================================================================
-- ۵. زیرساخت: شماره‌گذاری بی‌فاصله، idempotency، صف کار (= outbox صفحهٔ کنترل)
-- =====================================================================
CREATE TABLE IF NOT EXISTS platform.number_counter (
  series      text NOT NULL CHECK (series ~ '^[a-z][a-z_]{1,30}$'),
  period_key  text NOT NULL CHECK (period_key ~ '^(all|jy:[0-9]{4})$'),
  prefix      text NOT NULL CHECK (prefix ~ '^[A-Z]{1,4}-([0-9]{4}-)?$'),
  next_value  bigint NOT NULL DEFAULT 1 CHECK (next_value >= 1),
  PRIMARY KEY (series, period_key)
);

CREATE OR REPLACE FUNCTION platform.number_counter_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE', 'number counters are never deleted');
  END IF;
  IF NOT platform.is_nested() THEN
    PERFORM platform.fail('HK_PLT_NUMBER_DIRECT', 'numbers are drawn only inside the issuing document''s trigger');
  END IF;
  IF NEW.series <> OLD.series OR NEW.period_key <> OLD.period_key OR NEW.prefix <> OLD.prefix
     OR NEW.next_value <> OLD.next_value + 1 THEN
    PERFORM platform.fail('HK_PLT_NUMBER_COUNTER', 'counter only advances by one');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.number_counter;
CREATE TRIGGER trg_guard BEFORE UPDATE OR DELETE ON platform.number_counter FOR EACH ROW EXECUTE FUNCTION platform.number_counter_guard();

-- شمارهٔ بعدی در همان تراکنش صدور (قفل ردیف شمارنده؛ rollback = بدون شکاف)
CREATE OR REPLACE FUNCTION platform.number_next(p_series text, p_period text, p_prefix text, p_width int DEFAULT 6)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v bigint;
BEGIN
  INSERT INTO platform.number_counter (series, period_key, prefix) VALUES (p_series, p_period, p_prefix)
  ON CONFLICT (series, period_key) DO NOTHING;
  UPDATE platform.number_counter SET next_value = next_value + 1
   WHERE series = p_series AND period_key = p_period
  RETURNING next_value - 1 INTO v;
  RETURN (SELECT prefix FROM platform.number_counter WHERE series = p_series AND period_key = p_period)
         || lpad(v::text, p_width, '0');
END $$;

CREATE TABLE IF NOT EXISTS platform.idempotency_key (
  principal_kind    text NOT NULL CHECK (principal_kind IN ('staff','reseller_user','billing_contact','cell','installation')),
  principal_id      uuid NOT NULL,
  key               text NOT NULL CHECK (key ~ '^[A-Za-z0-9._:-]{16,255}$'),
  method            text NOT NULL CHECK (method IN ('POST','PUT','PATCH','DELETE')),
  path              text NOT NULL,
  request_sha256    bytea NOT NULL CHECK (octet_length(request_sha256) = 32),
  response_status   smallint CHECK (response_status BETWEEN 200 AND 599),
  response_body     jsonb,
  response_headers  jsonb,
  created_at        timestamptz NOT NULL DEFAULT now(),
  expires_at        timestamptz NOT NULL,
  PRIMARY KEY (principal_kind, principal_id, key),
  CHECK (expires_at > created_at AND expires_at <= created_at + interval '7 days')
);

CREATE OR REPLACE FUNCTION platform.idempotency_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.principal_kind <> OLD.principal_kind OR NEW.principal_id <> OLD.principal_id OR NEW.key <> OLD.key
     OR NEW.request_sha256 <> OLD.request_sha256 OR NEW.method <> OLD.method OR NEW.path <> OLD.path THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'idempotency identity is immutable');
  END IF;
  IF OLD.response_status IS NOT NULL THEN
    PERFORM platform.fail('HK_PLT_IDEMPOTENCY_COMPLETED', 'completed idempotency record is immutable');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.idempotency_key;
CREATE TRIGGER trg_guard BEFORE UPDATE ON platform.idempotency_key FOR EACH ROW EXECUTE FUNCTION platform.idempotency_guard();

-- بدون پاسخ commit نمی‌شود (پاسخ در همان تراکنش اثر نوشته می‌شود)
CREATE OR REPLACE FUNCTION platform.idempotency_completed() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM platform.idempotency_key k
             WHERE k.principal_kind = NEW.principal_kind AND k.principal_id = NEW.principal_id AND k.key = NEW.key
               AND k.response_status IS NULL) THEN
    PERFORM platform.fail('HK_PLT_IDEMPOTENCY_INCOMPLETE', 'idempotency key committed without a response');
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_completed ON platform.idempotency_key;
CREATE CONSTRAINT TRIGGER trg_completed AFTER INSERT ON platform.idempotency_key
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION platform.idempotency_completed();

CREATE TABLE IF NOT EXISTS platform.job (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  kind             text NOT NULL CHECK (kind ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){1,4}$'),
  queue            text NOT NULL DEFAULT 'default'
                   CHECK (queue IN ('default','billing','sync','notify','signing','house_sync','reports')),
  payload          jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(payload) = 'object'),
  dedupe_key       text CHECK (char_length(dedupe_key) BETWEEN 1 AND 200),
  concurrency_key  text CHECK (char_length(concurrency_key) BETWEEN 1 AND 200),
  status           text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','running','succeeded','failed','dead','cancelled')),
  priority         smallint NOT NULL DEFAULT 100,
  run_after        timestamptz NOT NULL DEFAULT now(),
  attempts         integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  max_attempts     integer NOT NULL DEFAULT 10 CHECK (max_attempts BETWEEN 1 AND 100),
  locked_by        text,
  locked_until     timestamptz,
  lock_token       uuid,
  last_error       text,
  result           jsonb,
  created_at       timestamptz NOT NULL DEFAULT now(),
  started_at       timestamptz,
  finished_at      timestamptz,
  CHECK ((status = 'running') = (locked_by IS NOT NULL AND locked_until IS NOT NULL AND lock_token IS NOT NULL)),
  CHECK ((status IN ('succeeded','failed','dead','cancelled')) = (finished_at IS NOT NULL)),
  CHECK (attempts <= max_attempts)
);
CREATE UNIQUE INDEX IF NOT EXISTS job_dedupe ON platform.job (kind, dedupe_key) WHERE dedupe_key IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS job_concurrency_running ON platform.job (concurrency_key) WHERE status = 'running' AND concurrency_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS job_claim ON platform.job (queue, priority, run_after) WHERE status = 'queued';

-- درج کار از درون تریگرها (outbox تراکنشی)
CREATE OR REPLACE FUNCTION platform.enqueue(p_kind text, p_queue text, p_payload jsonb, p_dedupe text)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO platform.job (kind, queue, payload, dedupe_key) VALUES (p_kind, p_queue, p_payload, p_dedupe)
  ON CONFLICT (kind, dedupe_key) WHERE dedupe_key IS NOT NULL DO NOTHING
$$;

-- =====================================================================
-- ۶. نمایندگان (مدل داده v1؛ پرتال v1.1 — Q-E)
-- =====================================================================
CREATE TABLE IF NOT EXISTS platform.reseller_tier (
  code                    text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{1,30}$'),
  name_fa                 text NOT NULL,
  rank                    smallint NOT NULL UNIQUE CHECK (rank BETWEEN 1 AND 20),
  status                  text NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired'))
);

CREATE TABLE IF NOT EXISTS platform.reseller (
  id                   uuid PRIMARY KEY DEFAULT uuidv7(),
  code                 text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9][A-Z0-9-]{2,19}$'),
  legal_name           text NOT NULL,
  person_type          text NOT NULL CHECK (person_type IN ('natural','legal')),
  national_id          text NOT NULL,
  economic_code        text CHECK (economic_code ~ '^[0-9]{11,14}$'),
  is_taxpayer          boolean NOT NULL DEFAULT true,
  kinds                text[] NOT NULL CHECK (cardinality(kinds) >= 1
                         AND kinds <@ ARRAY['sales','support','onprem_install','migration','training']::text[]),
  tier_code            text NOT NULL REFERENCES platform.reseller_tier(code),
  status               text NOT NULL DEFAULT 'applicant' CHECK (status IN ('applicant','active','suspended','terminated')),
  contract_ref         text,
  contract_valid_from  date,
  contract_valid_to    date,
  referral_code        text NOT NULL UNIQUE CHECK (referral_code ~ '^[a-z0-9]{4,16}$'),
  sheba                text CHECK (sheba ~ '^IR[0-9]{24}$'),
  mobile               text CHECK (mobile ~ '^09[0-9]{9}$'),
  email                text,
  province_code        text REFERENCES platform.geo_province(code),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  CHECK (person_type = 'natural' AND national_id ~ '^[0-9]{10}$' OR person_type = 'legal' AND national_id ~ '^[0-9]{11}$'),
  CONSTRAINT reseller_active_has_contract CHECK (status <> 'active' OR (contract_ref IS NOT NULL AND contract_valid_from IS NOT NULL)),
  CHECK (contract_valid_to IS NULL OR contract_valid_to > contract_valid_from)
);
SELECT platform.add_touch('platform.reseller');

CREATE TABLE IF NOT EXISTS platform.reseller_territory (
  id             uuid PRIMARY KEY DEFAULT uuidv7(),
  reseller_id    uuid NOT NULL REFERENCES platform.reseller(id),
  province_code  text NOT NULL REFERENCES platform.geo_province(code),
  city_code      text,                         -- NULL = کل استان
  exclusive      boolean NOT NULL DEFAULT false,
  valid_from     date NOT NULL,
  valid_to       date,
  created_at     timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (province_code, city_code) REFERENCES platform.geo_city(province_code, code),
  CHECK (valid_to IS NULL OR valid_to > valid_from),
  -- قلمرو انحصاری هم‌پوشان (همان استان/شهر و بازهٔ هم‌پوشان) ممنوع
  CONSTRAINT reseller_territory_exclusive EXCLUDE USING gist (
    province_code WITH =, (coalesce(city_code, '*')) WITH =, daterange(valid_from, valid_to, '[)') WITH &&
  ) WHERE (exclusive)
);

-- انحصار سلسله‌مراتبی: انحصار کل استان با انحصار هر شهر همان استان (بازهٔ هم‌پوشان) نمی‌خواند
CREATE OR REPLACE FUNCTION platform.territory_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.exclusive AND EXISTS (
       SELECT 1 FROM platform.reseller_territory t
       WHERE t.id <> NEW.id AND t.exclusive AND t.province_code = NEW.province_code
         AND (t.city_code IS NULL) <> (NEW.city_code IS NULL)
         AND daterange(t.valid_from, t.valid_to, '[)') && daterange(NEW.valid_from, NEW.valid_to, '[)')) THEN
    PERFORM platform.fail('HK_PLT_TERRITORY_CONFLICT', 'exclusive territory overlaps a province/city exclusivity');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.reseller_territory;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON platform.reseller_territory FOR EACH ROW EXECUTE FUNCTION platform.territory_guard();

CREATE TABLE IF NOT EXISTS platform.reseller_user (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  reseller_id      uuid NOT NULL REFERENCES platform.reseller(id),
  oidc_subject     text UNIQUE,
  display_name     text NOT NULL,
  mobile           text NOT NULL CHECK (mobile ~ '^09[0-9]{9}$'),
  email            text,
  role             text NOT NULL CHECK (role IN ('reseller_admin','reseller_agent')),
  status           text NOT NULL DEFAULT 'invited' CHECK (status IN ('invited','active','disabled')),
  mfa_enrolled_at  timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  row_version      integer NOT NULL DEFAULT 1,
  CONSTRAINT reseller_user_active_requires_mfa CHECK (status <> 'active' OR (oidc_subject IS NOT NULL AND mfa_enrolled_at IS NOT NULL))
);
SELECT platform.add_touch('platform.reseller_user');

CREATE TABLE IF NOT EXISTS platform.commission_rule (
  id            uuid PRIMARY KEY DEFAULT uuidv7(),
  scope         text NOT NULL CHECK (scope IN ('tier','reseller')),
  tier_code     text REFERENCES platform.reseller_tier(code),
  reseller_id   uuid REFERENCES platform.reseller(id),
  product_code  text,                          -- NULL = همهٔ محصولات؛ FK پس از ساخت product
  event         text NOT NULL CHECK (event IN ('first_sale','renewal','addon','service','license_new','license_renewal')),
  rate_pct      numeric(5,2) NOT NULL CHECK (rate_pct >= 0 AND rate_pct <= 100),
  valid_from    date NOT NULL,
  valid_to      date,
  created_by    uuid REFERENCES platform.staff(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK ((scope = 'tier') = (tier_code IS NOT NULL AND reseller_id IS NULL)),
  CHECK ((scope = 'reseller') = (reseller_id IS NOT NULL AND tier_code IS NULL)),
  CHECK (valid_to IS NULL OR valid_to > valid_from),
  CONSTRAINT commission_rule_no_overlap EXCLUDE USING gist (
    scope WITH =, (coalesce(tier_code, reseller_id::text)) WITH =, (coalesce(product_code, '*')) WITH =,
    event WITH =, daterange(valid_from, valid_to, '[)') WITH &&)
);

-- قاعدهٔ کمیسیون تغییر نمی‌کند؛ فقط بستن (valid_to) آن از امروز به بعد
CREATE OR REPLACE FUNCTION platform.commission_rule_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.valid_from <= current_date THEN
      PERFORM platform.fail('HK_PLT_IMMUTABLE', 'an effective commission rule cannot be deleted');
    END IF;
    RETURN OLD;
  END IF;
  IF (to_jsonb(NEW) - 'valid_to') <> (to_jsonb(OLD) - 'valid_to') THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'commission rules change only by closing them');
  END IF;
  IF NEW.valid_to IS NULL OR NEW.valid_to < current_date OR (OLD.valid_to IS NOT NULL AND NEW.valid_to > OLD.valid_to) THEN
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'commission rule can only be closed from today on');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.commission_rule;
CREATE TRIGGER trg_guard BEFORE UPDATE OR DELETE ON platform.commission_rule FOR EACH ROW EXECUTE FUNCTION platform.commission_rule_guard();

-- =====================================================================
-- ۷. سلول‌ها و رجیستری مستأجر
-- =====================================================================
CREATE TABLE IF NOT EXISTS platform.cell (
  id                   text PRIMARY KEY CHECK (id ~ '^cell-[a-z0-9-]{2,30}$'),
  kind                 text NOT NULL CHECK (kind IN ('pooled','dedicated')),
  provider             text NOT NULL,
  region               text NOT NULL,
  status               text NOT NULL DEFAULT 'provisioning' CHECK (status IN ('provisioning','active','draining','readonly','retired')),
  -- فقط ارجاع به مسیر OpenBao؛ هرگز DSN یا رمز (INV-ARCH-11): این را ناوگان api صفحهٔ داده resolve می‌کند
  dsn_ref              text NOT NULL CHECK (dsn_ref ~ '^openbao://[A-Za-z0-9/_.-]+$'),
  replica_dsn_ref      text CHECK (replica_dsn_ref ~ '^openbao://[A-Za-z0-9/_.-]+$'),
  app_version          text CHECK (app_version ~ '^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$'),
  schema_head          text,
  capacity_hint        integer CHECK (capacity_hint > 0),
  control_pubkey       bytea CHECK (octet_length(control_pubkey) = 32),   -- Ed25519 سلول: امضای uplink و ادعای پرتال پرداخت
  control_kid          text,
  dedicated_tenant_id  uuid,                                              -- FK پس از ساخت tenant
  state_applied_version bigint NOT NULL DEFAULT 0,
  last_seen_at         timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  CHECK (kind = 'dedicated' OR dedicated_tenant_id IS NULL),
  CHECK ((control_pubkey IS NULL) = (control_kid IS NULL)),
  CONSTRAINT cell_active_has_key CHECK (status NOT IN ('active','draining','readonly') OR control_pubkey IS NOT NULL)
);
SELECT platform.add_touch('platform.cell');

CREATE TABLE IF NOT EXISTS platform.tenant (
  id                      uuid PRIMARY KEY DEFAULT uuidv7(),       -- همان core.tenant.id در صفحهٔ داده
  slug                    text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
  display_name            text NOT NULL,
  deployment              text NOT NULL CHECK (deployment IN ('saas_shared','saas_dedicated','onprem')),
  status                  text NOT NULL DEFAULT 'provisioning'
                          CHECK (status IN ('provisioning','trial','active','past_due','read_only','suspended',
                                            'cancelled','archived','purging','purged')),
  status_changed_at       timestamptz NOT NULL DEFAULT now(),
  industry_codes          text[] NOT NULL DEFAULT '{}',
  province_code           text REFERENCES platform.geo_province(code),
  city_code               text,
  reseller_id             uuid REFERENCES platform.reseller(id),
  reseller_attributed_at  timestamptz,
  attribution_source      text CHECK (attribution_source IN ('referral_code','reseller_portal','staff','import')),
  signup_channel          text NOT NULL DEFAULT 'web' CHECK (signup_channel IN ('web','reseller','staff','onprem_sale','migration')),
  is_internal             boolean NOT NULL DEFAULT false,
  is_house                boolean NOT NULL DEFAULT false,         -- دفاتر خود صاحب پلتفرم (صورتحساب مؤدیان اشتراک‌ها)
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  row_version             integer NOT NULL DEFAULT 1,
  UNIQUE (id, slug),
  FOREIGN KEY (province_code, city_code) REFERENCES platform.geo_city(province_code, code),
  CHECK ((reseller_id IS NULL) = (reseller_attributed_at IS NULL AND attribution_source IS NULL)),
  CHECK (NOT is_house OR (is_internal AND deployment <> 'onprem'))
);
CREATE UNIQUE INDEX IF NOT EXISTS tenant_one_house ON platform.tenant ((true)) WHERE is_house;
CREATE INDEX IF NOT EXISTS tenant_reseller ON platform.tenant (reseller_id) WHERE reseller_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS tenant_status ON platform.tenant (status);
SELECT platform.add_touch('platform.tenant');

ALTER TABLE platform.cell DROP CONSTRAINT IF EXISTS cell_dedicated_tenant_fk;
ALTER TABLE platform.cell ADD CONSTRAINT cell_dedicated_tenant_fk FOREIGN KEY (dedicated_tenant_id) REFERENCES platform.tenant(id);

-- گذارهای مجاز چرخهٔ عمر (کاتالوگ کدی)
CREATE TABLE IF NOT EXISTS platform.tenant_lifecycle_transition (
  from_status      text NOT NULL,
  to_status        text NOT NULL,
  actor_kinds      text[] NOT NULL CHECK (actor_kinds <@ ARRAY['system','staff','tenant']::text[] AND cardinality(actor_kinds) >= 1),
  approval_action  text REFERENCES platform.approval_action(code),
  PRIMARY KEY (from_status, to_status)
);

CREATE TABLE IF NOT EXISTS platform.tenant_lifecycle_event (
  id              uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id       uuid NOT NULL REFERENCES platform.tenant(id),
  seq             integer NOT NULL CHECK (seq >= 1),
  from_status     text,
  to_status       text NOT NULL,
  actor_kind      text NOT NULL CHECK (actor_kind IN ('system','staff','tenant')),
  actor_staff_id  uuid REFERENCES platform.staff(id),
  reason_code     text NOT NULL CHECK (reason_code ~ '^[a-z][a-z0-9_]{2,40}$'),
  reason          text,
  approval_id     uuid REFERENCES platform.approval_request(id),
  occurred_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, seq),
  CHECK ((actor_kind = 'staff') = (actor_staff_id IS NOT NULL)),
  CONSTRAINT lifecycle_staff_reason CHECK (actor_kind <> 'staff' OR char_length(btrim(coalesce(reason, ''))) >= 10)
);

CREATE TABLE IF NOT EXISTS platform.tenant_legal_hold (
  id                   uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id            uuid NOT NULL REFERENCES platform.tenant(id),
  case_ref             text NOT NULL,
  authority            text,
  reason               text NOT NULL CHECK (char_length(btrim(reason)) >= 10),
  placed_by            uuid NOT NULL REFERENCES platform.staff(id),
  placed_at            timestamptz NOT NULL DEFAULT now(),
  released_at          timestamptz,
  released_by          uuid REFERENCES platform.staff(id),
  release_approval_id  uuid REFERENCES platform.approval_request(id),
  CHECK ((released_at IS NULL) = (released_by IS NULL)),
  CHECK ((released_at IS NULL) = (release_approval_id IS NULL))
);

CREATE OR REPLACE FUNCTION platform.legal_hold_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE', 'legal holds are released, never deleted');
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.released_at IS NOT NULL THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'hold cannot be created released');
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.tenant_id <> OLD.tenant_id OR NEW.case_ref <> OLD.case_ref OR NEW.reason <> OLD.reason
     OR NEW.placed_by <> OLD.placed_by OR NEW.placed_at <> OLD.placed_at THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'legal hold content is immutable');
  END IF;
  IF OLD.released_at IS NOT NULL THEN
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'hold already released');
  END IF;
  IF NEW.released_at IS NOT NULL THEN
    PERFORM platform.consume_approval(NEW.release_approval_id, 'tenant.legal_hold_release', 'legal_hold', NEW.id,
                                      'legal_hold:' || NEW.id::text);
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.tenant_legal_hold;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.tenant_legal_hold FOR EACH ROW EXECUTE FUNCTION platform.legal_hold_guard();

CREATE TABLE IF NOT EXISTS platform.tenant_offboarding (
  tenant_id            uuid PRIMARY KEY REFERENCES platform.tenant(id),
  requested_at         timestamptz NOT NULL DEFAULT now(),
  requested_via        text NOT NULL CHECK (requested_via IN ('tenant_owner','staff','non_payment')),
  reason               text,
  export_window_ends   timestamptz NOT NULL,
  export_id            uuid,                         -- core.tenant_export.id در سلول
  export_sha256        bytea CHECK (octet_length(export_sha256) = 32),
  export_delivered_at  timestamptz,
  written_request_ref  text,                         -- نامهٔ کتبی مشتری برای پاک‌سازی زودتر
  archive_object_ref   text,
  archive_sha256       bytea CHECK (octet_length(archive_sha256) = 32),
  archive_verified_at  timestamptz,
  retention_until      date NOT NULL,                -- نگهداری بستهٔ بایگانی (پارامتر قانونی تاریخ‌دار، ⚠)
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  CHECK (export_window_ends > requested_at),
  CHECK (export_delivered_at IS NULL OR export_sha256 IS NOT NULL),
  CHECK (archive_verified_at IS NULL OR (archive_object_ref IS NOT NULL AND archive_sha256 IS NOT NULL))
);
SELECT platform.add_touch('platform.tenant_offboarding');

-- رویداد چرخهٔ عمر: تنها مسیر تغییر tenant.status
CREATE OR REPLACE FUNCTION platform.lifecycle_event_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  t   platform.tenant%ROWTYPE;
  tr  platform.tenant_lifecycle_transition%ROWTYPE;
  ob  platform.tenant_offboarding%ROWTYPE;
BEGIN
  SELECT * INTO t FROM platform.tenant WHERE id = NEW.tenant_id FOR UPDATE;
  NEW.seq := coalesce((SELECT max(e.seq) FROM platform.tenant_lifecycle_event e WHERE e.tenant_id = NEW.tenant_id), 0) + 1;
  NEW.occurred_at := now();
  IF NEW.seq = 1 THEN
    -- رویداد ساخت (از تریگر درج tenant)
    IF NOT platform.is_nested() OR NEW.to_status <> 'provisioning' THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'first lifecycle event is the creation event');
    END IF;
    NEW.from_status := NULL;
    RETURN NEW;
  END IF;
  NEW.from_status := t.status;
  IF NEW.actor_kind = 'staff' AND NEW.actor_staff_id IS DISTINCT FROM platform.current_staff_id() THEN
    PERFORM platform.fail('HK_PLT_ACTOR_MISMATCH', 'actor_staff_id must be the acting staff member');
  END IF;
  SELECT * INTO tr FROM platform.tenant_lifecycle_transition
   WHERE from_status = t.status AND to_status = NEW.to_status;
  IF NOT FOUND OR NOT (NEW.actor_kind = ANY (tr.actor_kinds)) THEN
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', format('tenant %s -> %s by %s', t.status, NEW.to_status, NEW.actor_kind));
  END IF;
  IF tr.approval_action IS NOT NULL THEN
    PERFORM platform.consume_approval(NEW.approval_id, tr.approval_action, 'tenant', NEW.tenant_id,
                                      'tenant_lifecycle_event:' || NEW.id::text);
  ELSIF NEW.approval_id IS NOT NULL THEN
    PERFORM platform.fail('HK_PLT_APPROVAL_MISMATCH', 'this transition takes no approval');
  END IF;
  IF NEW.to_status IN ('archived','purging') THEN
    SELECT * INTO ob FROM platform.tenant_offboarding WHERE tenant_id = NEW.tenant_id;
    IF NOT FOUND THEN
      PERFORM platform.fail('HK_PLT_OFFBOARDING_REQUIRED', 'archive/purge requires an offboarding record');
    END IF;
    IF NEW.to_status = 'archived' AND ob.export_window_ends > now() AND ob.export_delivered_at IS NULL THEN
      PERFORM platform.fail('HK_PLT_EXPORT_WINDOW_OPEN', 'export window still open and export not delivered');
    END IF;
    IF NEW.to_status = 'purging' THEN
      IF EXISTS (SELECT 1 FROM platform.tenant_legal_hold h WHERE h.tenant_id = NEW.tenant_id AND h.released_at IS NULL) THEN
        PERFORM platform.fail('HK_PLT_LEGAL_HOLD', 'tenant is under legal hold');
      END IF;
      IF NOT (ob.archive_verified_at IS NOT NULL
              OR (ob.export_delivered_at IS NOT NULL AND ob.written_request_ref IS NOT NULL)) THEN
        PERFORM platform.fail('HK_PLT_PURGE_PRECONDITION', 'purge needs a verified archive or a delivered export plus written request');
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.tenant_lifecycle_event;
CREATE TRIGGER trg_guard BEFORE INSERT ON platform.tenant_lifecycle_event FOR EACH ROW EXECUTE FUNCTION platform.lifecycle_event_guard();
SELECT platform.make_append_only('platform.tenant_lifecycle_event');

CREATE OR REPLACE FUNCTION platform.lifecycle_event_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.from_status IS NOT NULL THEN
    UPDATE platform.tenant SET status = NEW.to_status, status_changed_at = NEW.occurred_at WHERE id = NEW.tenant_id;
  END IF;
  -- هر تغییر وضعیت در همان تراکنش بازسازی «حالت مطلوب» را صف می‌کند
  PERFORM platform.enqueue('control.desired_state.build', 'sync',
                           jsonb_build_object('tenant_id', NEW.tenant_id, 'cause', 'lifecycle', 'event_seq', NEW.seq),
                           'lifecycle:' || NEW.tenant_id::text || ':' || NEW.seq::text);
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_apply ON platform.tenant_lifecycle_event;
CREATE TRIGGER trg_apply AFTER INSERT ON platform.tenant_lifecycle_event FOR EACH ROW EXECUTE FUNCTION platform.lifecycle_event_apply();

CREATE OR REPLACE FUNCTION platform.tenant_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE', 'tenants are purged by lifecycle, never deleted');
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'provisioning' THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'tenants are created in provisioning');
    END IF;
    IF NEW.is_house AND current_user IN ('hk_platform_app','hk_platform_ingest','hk_partner_app') THEN
      PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'house tenant flag is set by migration only');
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status OR NEW.status_changed_at IS DISTINCT FROM OLD.status_changed_at THEN
    IF NOT platform.is_nested() THEN
      PERFORM platform.fail('HK_PLT_STATUS_VIA_EVENT', 'tenant status changes only through tenant_lifecycle_event');
    END IF;
  END IF;
  IF NEW.deployment IS DISTINCT FROM OLD.deployment AND NOT platform.is_nested() THEN
    PERFORM platform.fail('HK_PLT_DEPLOYMENT_VIA_PLACEMENT', 'deployment changes only through tenant_placement');
  END IF;
  IF NEW.is_house <> OLD.is_house AND current_user IN ('hk_platform_app','hk_platform_ingest','hk_partner_app') THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'house tenant flag is set by migration only');
  END IF;
  IF OLD.status = 'purged' THEN
    PERFORM platform.fail('HK_PLT_TENANT_PURGED', 'purged tenant record is frozen');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.tenant;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.tenant FOR EACH ROW EXECUTE FUNCTION platform.tenant_guard();

CREATE OR REPLACE FUNCTION platform.tenant_created() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO platform.tenant_lifecycle_event (tenant_id, seq, to_status, actor_kind, actor_staff_id, reason_code)
  VALUES (NEW.id, 1, 'provisioning', 'system', NULL, 'created');
  INSERT INTO platform.tenant_runtime (tenant_id) VALUES (NEW.id);
  RETURN NULL;
END $$;

CREATE TABLE IF NOT EXISTS platform.tenant_placement (
  tenant_id            uuid PRIMARY KEY,
  slug                 text NOT NULL UNIQUE,
  cell_id              text REFERENCES platform.cell(id),
  mode                 text NOT NULL CHECK (mode IN ('pooled','dedicated','onprem')),
  state                text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','active','moving','frozen','retired')),
  since                timestamptz NOT NULL DEFAULT now(),
  move_target_cell_id  text REFERENCES platform.cell(id),
  move_target_mode     text CHECK (move_target_mode IN ('pooled','dedicated','onprem')),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  FOREIGN KEY (tenant_id, slug) REFERENCES platform.tenant(id, slug) ON UPDATE CASCADE,
  CONSTRAINT placement_onprem_no_cell CHECK ((mode = 'onprem') = (cell_id IS NULL)),
  CONSTRAINT placement_moving_target CHECK ((state = 'moving') = (move_target_mode IS NOT NULL)),
  CONSTRAINT placement_target_cell CHECK (move_target_mode IS NULL AND move_target_cell_id IS NULL
                                          OR move_target_mode IS NOT NULL AND (move_target_mode = 'onprem') = (move_target_cell_id IS NULL)),
  CHECK (move_target_cell_id IS NULL OR move_target_cell_id IS DISTINCT FROM cell_id)
);
SELECT platform.add_touch('platform.tenant_placement');

CREATE OR REPLACE FUNCTION platform.placement_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  c platform.cell%ROWTYPE;
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE', 'placements are retired, never deleted');
  END IF;
  IF TG_OP = 'INSERT' AND NEW.state <> 'pending' THEN
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'placement starts as pending');
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.state IS DISTINCT FROM OLD.state AND NOT (
       (OLD.state = 'pending' AND NEW.state IN ('active','retired'))
    OR (OLD.state = 'active'  AND NEW.state IN ('moving','frozen','retired'))
    OR (OLD.state = 'moving'  AND NEW.state IN ('active','frozen'))
    OR (OLD.state = 'frozen'  AND NEW.state IN ('active','moving','retired'))) THEN
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', format('placement %s -> %s', OLD.state, NEW.state));
  END IF;
  IF TG_OP = 'UPDATE' AND (NEW.cell_id IS DISTINCT FROM OLD.cell_id OR NEW.mode <> OLD.mode) THEN
    -- پایان جابه‌جایی: فقط moving → active و فقط به همان مقصد اعلام‌شده
    IF NOT (OLD.state = 'moving' AND NEW.state = 'active' AND NEW.mode = OLD.move_target_mode
            AND NEW.cell_id IS NOT DISTINCT FROM OLD.move_target_cell_id) THEN
      PERFORM platform.fail('HK_PLT_PLACEMENT_MOVE', 'cell/mode changes only by completing a declared move');
    END IF;
  END IF;
  IF NEW.state = 'active' AND (TG_OP = 'INSERT' OR OLD.state <> 'active') THEN
    NEW.move_target_cell_id := NULL; NEW.move_target_mode := NULL; NEW.since := now();
  END IF;
  IF NEW.cell_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.cell_id IS DISTINCT FROM OLD.cell_id) THEN
    SELECT * INTO c FROM platform.cell WHERE id = NEW.cell_id;
    IF c.kind <> (CASE NEW.mode WHEN 'pooled' THEN 'pooled' ELSE 'dedicated' END) THEN
      PERFORM platform.fail('HK_PLT_PLACEMENT_CELL_KIND', format('mode %s cannot use %s cell', NEW.mode, c.kind));
    END IF;
    IF c.status NOT IN ('active','provisioning') THEN
      PERFORM platform.fail('HK_PLT_CELL_NOT_ACCEPTING', format('cell %s is %s', c.id, c.status));
    END IF;
    IF c.kind = 'dedicated' AND c.dedicated_tenant_id IS DISTINCT FROM NEW.tenant_id THEN
      PERFORM platform.fail('HK_PLT_PLACEMENT_CELL_KIND', 'dedicated cell belongs to another tenant');
    END IF;
  END IF;
  IF NEW.move_target_cell_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.move_target_cell_id IS DISTINCT FROM OLD.move_target_cell_id) THEN
    SELECT * INTO c FROM platform.cell WHERE id = NEW.move_target_cell_id;
    IF c.kind <> (CASE NEW.move_target_mode WHEN 'pooled' THEN 'pooled' ELSE 'dedicated' END)
       OR c.status NOT IN ('active','provisioning')
       OR (c.kind = 'dedicated' AND c.dedicated_tenant_id IS DISTINCT FROM NEW.tenant_id) THEN
      PERFORM platform.fail('HK_PLT_PLACEMENT_CELL_KIND', 'move target cell does not accept this tenant');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.tenant_placement;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.tenant_placement FOR EACH ROW EXECUTE FUNCTION platform.placement_guard();

-- tenant.deployment همیشه هم‌راستای mode جای‌گذاری است (فقط از این مسیر تغییر می‌کند)
CREATE OR REPLACE FUNCTION platform.placement_sync_deployment() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v text := CASE NEW.mode WHEN 'pooled' THEN 'saas_shared' WHEN 'dedicated' THEN 'saas_dedicated' ELSE 'onprem' END;
BEGIN
  UPDATE platform.tenant SET deployment = v WHERE id = NEW.tenant_id AND deployment IS DISTINCT FROM v;
  PERFORM platform.enqueue('control.routing_snapshot.build', 'sync', jsonb_build_object('tenant_id', NEW.tenant_id),
                           'placement:' || NEW.tenant_id::text || ':' || NEW.row_version::text);
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_sync ON platform.tenant_placement;
CREATE TRIGGER trg_sync AFTER INSERT OR UPDATE ON platform.tenant_placement FOR EACH ROW EXECUTE FUNCTION platform.placement_sync_deployment();

CREATE TABLE IF NOT EXISTS platform.tenant_runtime (
  tenant_id          uuid PRIMARY KEY REFERENCES platform.tenant(id),
  desired_version    bigint NOT NULL DEFAULT 0 CHECK (desired_version >= 0),
  applied_version    bigint NOT NULL DEFAULT 0 CHECK (applied_version >= 0),
  applied_at         timestamptz,
  last_uplink_at     timestamptz,
  last_activity_at   timestamptz,
  active_users       integer CHECK (active_users >= 0),
  companies          integer CHECK (companies >= 0),
  branches           integer CHECK (branches >= 0),
  pos_devices        integer CHECK (pos_devices >= 0),
  storage_bytes      bigint CHECK (storage_bytes >= 0),
  data_plane_status  text CHECK (data_plane_status IN ('provisioning','active','read_only','suspended','exporting','archived')),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT runtime_applied_le_desired CHECK (applied_version <= desired_version)
);

CREATE OR REPLACE FUNCTION platform.runtime_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.desired_version IS DISTINCT FROM OLD.desired_version AND NOT platform.is_nested() THEN
    PERFORM platform.fail('HK_PLT_DERIVED_COLUMN', 'desired_version follows platform.desired_state');
  END IF;
  IF NEW.applied_version < OLD.applied_version THEN
    PERFORM platform.fail('HK_PLT_STALE_ACK', 'applied_version never decreases');
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.tenant_runtime;
CREATE TRIGGER trg_guard BEFORE UPDATE ON platform.tenant_runtime FOR EACH ROW EXECUTE FUNCTION platform.runtime_guard();

DROP TRIGGER IF EXISTS trg_created ON platform.tenant;
CREATE TRIGGER trg_created AFTER INSERT ON platform.tenant FOR EACH ROW EXECUTE FUNCTION platform.tenant_created();

-- «فضای کاری من کجاست؟» (D-04 بخش ۰۱): HMAC موبایل ← مستأجرها؛ از uplink
CREATE TABLE IF NOT EXISTS platform.login_directory (
  mobile_hmac  bytea NOT NULL CHECK (octet_length(mobile_hmac) = 32),
  tenant_id    uuid NOT NULL REFERENCES platform.tenant(id),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (mobile_hmac, tenant_id)
);

-- =====================================================================
-- ۸. کانال کنترل: نمای مسیریابی، حالت مطلوب مستأجر و سلول، فرمان سلول، uplink
-- =====================================================================
CREATE TABLE IF NOT EXISTS platform.routing_snapshot (
  version       bigint PRIMARY KEY CHECK (version >= 1),
  generated_at  timestamptz NOT NULL DEFAULT now(),
  entries       integer NOT NULL CHECK (entries >= 0),
  document      jsonb NOT NULL,
  sha256        bytea NOT NULL CHECK (octet_length(sha256) = 32),
  signature     bytea NOT NULL CHECK (octet_length(signature) = 64),
  kid           text NOT NULL,
  CHECK (document->>'format' = 'hkroute/1' AND (document->>'version')::bigint = version
         AND jsonb_typeof(document->'entries') = 'object')
);

-- نسخهٔ یکنوا و بی‌فاصله (version = بیشینه + ۱)
CREATE OR REPLACE FUNCTION platform.routing_snapshot_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  -- هم‌روندی: دو درج هم‌زمان با «بیشینه + ۱» یکسان روی کلید اصلی به هم می‌خورند و یکی رد می‌شود (بدون شکاف)
  IF NEW.version <> coalesce((SELECT max(version) FROM platform.routing_snapshot), 0) + 1 THEN
    PERFORM platform.fail('HK_PLT_VERSION_SEQUENCE', 'routing snapshot version must be max + 1');
  END IF;
  IF NEW.entries <> (SELECT count(*) FROM jsonb_object_keys(NEW.document->'entries')) THEN
    PERFORM platform.fail('HK_PLT_DOCUMENT_MISMATCH', 'entries count does not match document');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.routing_snapshot;
CREATE TRIGGER trg_guard BEFORE INSERT ON platform.routing_snapshot FOR EACH ROW EXECUTE FUNCTION platform.routing_snapshot_guard();
SELECT platform.make_append_only('platform.routing_snapshot');

CREATE TABLE IF NOT EXISTS platform.desired_state (
  tenant_id        uuid NOT NULL REFERENCES platform.tenant(id),
  version          bigint NOT NULL CHECK (version >= 1),
  document         jsonb NOT NULL,
  document_sha256  bytea NOT NULL CHECK (octet_length(document_sha256) = 32),
  signature        bytea NOT NULL CHECK (octet_length(signature) = 64),
  kid              text NOT NULL,
  cause            text NOT NULL CHECK (cause IN ('lifecycle','subscription','override','flag','support','pack','license',
                                                  'announcement','credit','placement','manual')),
  effective_at     timestamptz NOT NULL DEFAULT now(),
  created_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, version),
  CONSTRAINT desired_state_document_shape CHECK (
    document->>'format' = 'hkstate/1' AND (document->>'version')::bigint = version
    AND document->>'tenant_id' = tenant_id::text
    AND document ? 'status' AND jsonb_typeof(document->'entitlements') = 'object')
);

CREATE OR REPLACE FUNCTION platform.desired_state_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_cur bigint;
BEGIN
  SELECT desired_version INTO v_cur FROM platform.tenant_runtime WHERE tenant_id = NEW.tenant_id FOR UPDATE;
  IF NEW.version <> coalesce(v_cur, 0) + 1 THEN
    PERFORM platform.fail('HK_PLT_VERSION_SEQUENCE', 'desired state version must be current + 1');
  END IF;
  IF NEW.document->>'status' NOT IN ('provisioning','active','read_only','suspended','exporting','archived','purge') THEN
    PERFORM platform.fail('HK_PLT_DOCUMENT_MISMATCH', 'desired status must be a data-plane status');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.desired_state;
CREATE TRIGGER trg_guard BEFORE INSERT ON platform.desired_state FOR EACH ROW EXECUTE FUNCTION platform.desired_state_guard();
SELECT platform.make_append_only('platform.desired_state');

CREATE OR REPLACE FUNCTION platform.desired_state_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE platform.tenant_runtime SET desired_version = NEW.version WHERE tenant_id = NEW.tenant_id;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_apply ON platform.desired_state;
CREATE TRIGGER trg_apply AFTER INSERT ON platform.desired_state FOR EACH ROW EXECUTE FUNCTION platform.desired_state_apply();

-- نگاشت وضعیت چرخهٔ عمر به core.tenant.status صفحهٔ داده (سازندهٔ حالت مطلوب و آزمون‌ها از همین استفاده می‌کنند)
CREATE OR REPLACE FUNCTION platform.data_plane_status(p_status text, p_placement_state text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_placement_state IN ('moving','frozen') AND p_status NOT IN ('provisioning','purging','purged') THEN 'exporting'
    WHEN p_status = 'provisioning' THEN 'provisioning'
    WHEN p_status IN ('trial','active','past_due') THEN 'active'
    WHEN p_status IN ('read_only','cancelled') THEN 'read_only'
    WHEN p_status = 'suspended' THEN 'suspended'
    WHEN p_status = 'archived' THEN 'archived'
    WHEN p_status IN ('purging','purged') THEN 'purge'
  END
$$;

-- حالت مطلوب سراسری هر سلول: بسته‌های قواعد، snapshot مرجع، فرهنگ مهاجرت، بستهٔ صنفی، پرچم سراسری، CRL، ارائه‌دهندهٔ AI
CREATE TABLE IF NOT EXISTS platform.cell_state (
  cell_id          text NOT NULL REFERENCES platform.cell(id),
  version          bigint NOT NULL CHECK (version >= 1),
  document         jsonb NOT NULL,
  document_sha256  bytea NOT NULL CHECK (octet_length(document_sha256) = 32),
  signature        bytea NOT NULL CHECK (octet_length(signature) = 64),
  kid              text NOT NULL,
  effective_at     timestamptz NOT NULL DEFAULT now(),
  created_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (cell_id, version),
  CHECK (document->>'format' = 'hkcellstate/1' AND (document->>'version')::bigint = version AND document->>'cell_id' = cell_id)
);

CREATE OR REPLACE FUNCTION platform.cell_state_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM platform.cell WHERE id = NEW.cell_id FOR UPDATE;
  IF NEW.version <> coalesce((SELECT max(version) FROM platform.cell_state WHERE cell_id = NEW.cell_id), 0) + 1 THEN
    PERFORM platform.fail('HK_PLT_VERSION_SEQUENCE', 'cell state version must be max + 1');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.cell_state;
CREATE TRIGGER trg_guard BEFORE INSERT ON platform.cell_state FOR EACH ROW EXECUTE FUNCTION platform.cell_state_guard();
SELECT platform.make_append_only('platform.cell_state');

CREATE TABLE IF NOT EXISTS platform.cell_command (
  id            uuid PRIMARY KEY DEFAULT uuidv7(),
  cell_id       text NOT NULL REFERENCES platform.cell(id),
  tenant_id     uuid REFERENCES platform.tenant(id),
  kind          text NOT NULL CHECK (kind IN ('tenant.provision','tenant.export','tenant.import','tenant.purge',
                                              'tenant.freeze','tenant.unfreeze','tenant.rotate_kek',
                                              'support.revoke_sessions','cell.rules_apply','cell.reference_apply')),
  payload       jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(payload) = 'object'),
  signature     bytea NOT NULL CHECK (octet_length(signature) = 64),
  kid           text NOT NULL,
  status        text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','delivered','succeeded','failed','expired','cancelled')),
  attempts      integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  delivered_at  timestamptz,
  finished_at   timestamptz,
  result        jsonb,
  error         text,
  expires_at    timestamptz NOT NULL,
  created_by    uuid REFERENCES platform.staff(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK ((kind LIKE 'tenant.%' OR kind LIKE 'support.%') = (tenant_id IS NOT NULL)),
  CHECK ((status IN ('succeeded','failed','expired','cancelled')) = (finished_at IS NOT NULL)),
  CHECK (status <> 'failed' OR error IS NOT NULL),
  CHECK (expires_at > created_at)
);
CREATE UNIQUE INDEX IF NOT EXISTS cell_command_one_open ON platform.cell_command (tenant_id, kind)
  WHERE status IN ('queued','delivered') AND tenant_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS cell_command_pull ON platform.cell_command (cell_id, status, created_at) WHERE status IN ('queued','delivered');

CREATE OR REPLACE FUNCTION platform.cell_command_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  p platform.tenant_placement%ROWTYPE;
  v_status text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE', 'commands are never deleted');
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'queued' THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'commands start queued');
    END IF;
    IF NEW.tenant_id IS NOT NULL THEN
      SELECT * INTO p FROM platform.tenant_placement WHERE tenant_id = NEW.tenant_id;
      IF NOT FOUND OR NOT (NEW.cell_id = p.cell_id OR (NEW.kind = 'tenant.import' AND NEW.cell_id = p.move_target_cell_id)) THEN
        PERFORM platform.fail('HK_PLT_COMMAND_WRONG_CELL', 'command must target the tenant''s cell (or move target for import)');
      END IF;
      SELECT status INTO v_status FROM platform.tenant WHERE id = NEW.tenant_id;
      IF NEW.kind = 'tenant.purge' AND v_status <> 'purging' THEN
        PERFORM platform.fail('HK_PLT_PURGE_PRECONDITION', 'purge command requires tenant status purging');
      END IF;
      IF NEW.kind = 'tenant.provision' AND v_status <> 'provisioning' THEN
        PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'provision command requires tenant status provisioning');
      END IF;
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.cell_id <> OLD.cell_id OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id OR NEW.kind <> OLD.kind
     OR NEW.payload <> OLD.payload OR NEW.signature <> OLD.signature OR NEW.created_at <> OLD.created_at THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'signed command content is immutable');
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
       (OLD.status = 'queued'    AND NEW.status IN ('delivered','expired','cancelled'))
    OR (OLD.status = 'delivered' AND NEW.status IN ('delivered','succeeded','failed','expired'))) THEN
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', format('command %s -> %s', OLD.status, NEW.status));
  END IF;
  IF NEW.status = 'delivered' AND OLD.status = 'queued' THEN
    NEW.delivered_at := now();
  END IF;
  IF NEW.status IN ('succeeded','failed','expired','cancelled') AND OLD.status NOT IN ('succeeded','failed','expired','cancelled') THEN
    NEW.finished_at := now();
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.cell_command;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.cell_command FOR EACH ROW EXECUTE FUNCTION platform.cell_command_guard();

CREATE TABLE IF NOT EXISTS platform.uplink_batch (
  batch_id        uuid PRIMARY KEY,
  source_kind     text NOT NULL CHECK (source_kind IN ('cell','installation')),
  source_id       text NOT NULL,
  tenant_id       uuid REFERENCES platform.tenant(id),
  kind            text NOT NULL CHECK (kind IN ('events','usage','health','moadian_stats','login_directory','ack','usage_report_file')),
  item_count      integer NOT NULL CHECK (item_count BETWEEN 0 AND 5000),
  payload_sha256  bytea NOT NULL CHECK (octet_length(payload_sha256) = 32),
  received_at     timestamptz NOT NULL DEFAULT now(),
  processed_at    timestamptz,
  process_error   text
);

-- تکرار با همان batch_id و همان محتوا = بی‌اثر (ON CONFLICT DO NOTHING)؛ همان batch_id با محتوای دیگر = خطا
CREATE OR REPLACE FUNCTION platform.uplink_batch_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF EXISTS (SELECT 1 FROM platform.uplink_batch b WHERE b.batch_id = NEW.batch_id AND b.payload_sha256 <> NEW.payload_sha256) THEN
      PERFORM platform.fail('HK_PLT_UPLINK_BATCH_CONFLICT', 'same batch_id with a different payload');
    END IF;
    RETURN NEW;
  END IF;
  IF TG_OP = 'DELETE' THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE', 'uplink batches are kept for dedupe');
  END IF;
  IF (to_jsonb(NEW) - 'processed_at' - 'process_error') <> (to_jsonb(OLD) - 'processed_at' - 'process_error') THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'uplink batch identity is immutable');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.uplink_batch;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.uplink_batch FOR EACH ROW EXECUTE FUNCTION platform.uplink_batch_guard();

-- =====================================================================
-- ۹. انتشار نسخه، rollout سلول‌ها، نسخهٔ کلاینت‌ها، پشتیبان و تمرین بازیابی (قرارداد بخش ۰۱ §۴-۸)
-- =====================================================================
CREATE TABLE IF NOT EXISTS platform.release (
  version                  text PRIMARY KEY CHECK (version ~ '^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$'),
  channel                  text NOT NULL CHECK (channel IN ('stable','lts','beta')),
  release_date             date NOT NULL,                    -- با license.updates_until مقایسه می‌شود
  released_at              timestamptz,
  min_from_version         text NOT NULL CHECK (min_from_version ~ '^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$'),
  schema_heads             jsonb NOT NULL CHECK (jsonb_typeof(schema_heads) = 'object' AND schema_heads ? 'data_plane' AND schema_heads ? 'control_plane'),
  has_contract_migrations  boolean NOT NULL DEFAULT false,
  contract_floor           text CHECK (contract_floor ~ '^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$'),
  manifest_sha256          bytea NOT NULL CHECK (octet_length(manifest_sha256) = 32),
  signature                bytea CHECK (octet_length(signature) = 64),
  kid                      text,
  status                   text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','published','withdrawn')),
  support_status           text NOT NULL DEFAULT 'supported' CHECK (support_status IN ('supported','security_only','unsupported')),
  lts_until                date,
  notes_key                text,
  created_at               timestamptz NOT NULL DEFAULT now(),
  CHECK (status = 'draft' OR (released_at IS NOT NULL AND signature IS NOT NULL AND kid IS NOT NULL)),
  CHECK (NOT has_contract_migrations OR contract_floor IS NOT NULL),
  CHECK (channel <> 'lts' OR lts_until IS NOT NULL),
  CONSTRAINT release_min_from_le_version CHECK (platform.calver_key(min_from_version) <= platform.calver_key(version))
);

CREATE TABLE IF NOT EXISTS platform.cell_rollout (
  release_version     text NOT NULL REFERENCES platform.release(version),
  cell_id             text NOT NULL REFERENCES platform.cell(id),
  ring                smallint NOT NULL CHECK (ring BETWEEN 0 AND 2),
  state               text NOT NULL DEFAULT 'pending'
                      CHECK (state IN ('pending','expanding','expanded','rolling','rolled','verifying','done','paused','failed')),
  paused_from         text CHECK (paused_from IN ('pending','expanding','expanded','rolling','rolled','verifying')),
  manual_approved_by  uuid REFERENCES platform.staff(id),
  started_at          timestamptz,
  finished_at         timestamptz,
  last_error          text,
  updated_at          timestamptz NOT NULL DEFAULT now(),
  row_version         integer NOT NULL DEFAULT 1,
  PRIMARY KEY (release_version, cell_id),
  CHECK ((state = 'paused') = (paused_from IS NOT NULL)),
  CHECK (state <> 'failed' OR last_error IS NOT NULL)
);
SELECT platform.add_touch('platform.cell_rollout');

-- ماشین حالت ۵-۱۴-۲ بخش ۰۱: expand در همهٔ سلول‌ها پیش از rolling هر سلول؛ rolling به ترتیب حلقه؛ حلقهٔ ۲ تأیید دستی
CREATE OR REPLACE FUNCTION platform.cell_rollout_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  ok boolean;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.state <> 'pending' THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'rollout starts pending');
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.release_version <> OLD.release_version OR NEW.cell_id <> OLD.cell_id OR NEW.ring <> OLD.ring THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'rollout identity is immutable');
  END IF;
  IF NEW.state = OLD.state THEN
    RETURN NEW;
  END IF;
  ok := (NEW.state = 'paused' AND OLD.state NOT IN ('done','failed','paused'))
     OR (OLD.state = 'paused' AND NEW.state = OLD.paused_from)
     OR (OLD.state = 'pending'   AND NEW.state = 'expanding')
     OR (OLD.state = 'expanding' AND NEW.state IN ('expanded','failed'))
     OR (OLD.state = 'expanded'  AND NEW.state = 'rolling')
     OR (OLD.state = 'rolling'   AND NEW.state IN ('rolled','failed'))
     OR (OLD.state = 'rolled'    AND NEW.state = 'verifying')
     OR (OLD.state = 'verifying' AND NEW.state IN ('done','failed'));
  IF NOT ok THEN
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', format('rollout %s -> %s', OLD.state, NEW.state));
  END IF;
  IF NEW.state = 'paused' THEN
    NEW.paused_from := OLD.state;
  ELSIF OLD.state = 'paused' THEN
    NEW.paused_from := NULL;
  END IF;
  IF OLD.state = 'pending' AND NEW.state = 'expanding' THEN
    IF NOT EXISTS (SELECT 1 FROM platform.release WHERE version = NEW.release_version AND status = 'published') THEN
      PERFORM platform.fail('HK_PLT_RELEASE_NOT_PUBLISHED', 'only published releases roll out');
    END IF;
    NEW.started_at := now();
  END IF;
  IF OLD.state = 'expanded' AND NEW.state = 'rolling' THEN
    IF EXISTS (SELECT 1 FROM platform.cell_rollout r WHERE r.release_version = NEW.release_version
               AND (r.state IN ('pending','expanding','failed') OR (r.state = 'paused' AND r.paused_from IN ('pending','expanding')))) THEN
      PERFORM platform.fail('HK_PLT_ROLLOUT_ORDER', 'every cell must be expanded before any cell rolls');
    END IF;
    IF EXISTS (SELECT 1 FROM platform.cell_rollout r WHERE r.release_version = NEW.release_version
               AND r.ring < NEW.ring AND r.state <> 'done') THEN
      PERFORM platform.fail('HK_PLT_ROLLOUT_ORDER', 'lower rings must be done first');
    END IF;
  END IF;
  IF OLD.state = 'verifying' AND NEW.state = 'done' AND NEW.ring = 2 THEN
    IF NEW.manual_approved_by IS NULL OR NEW.manual_approved_by IS DISTINCT FROM platform.current_staff_id()
       OR NOT platform.staff_has_permission(NEW.manual_approved_by, 'platform.release.approve') THEN
      PERFORM platform.fail('HK_PLT_ROLLOUT_MANUAL_APPROVAL', 'ring 2 needs a manual approval by a release approver');
    END IF;
  END IF;
  IF NEW.state IN ('done','failed') THEN
    NEW.finished_at := now();
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.cell_rollout;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON platform.cell_rollout FOR EACH ROW EXECUTE FUNCTION platform.cell_rollout_guard();

CREATE TABLE IF NOT EXISTS platform.client_release (
  id                     uuid PRIMARY KEY DEFAULT uuidv7(),
  app                    text NOT NULL CHECK (app IN ('pos','web','partner_agent','migration_agent','hk_bridge')),
  platform               text NOT NULL CHECK (platform IN ('windows','android','web')),
  flavor                 text NOT NULL DEFAULT 'default' CHECK (flavor ~ '^[a-z0-9_-]{2,30}$'),
  channel                text NOT NULL CHECK (channel IN ('stable','lts','beta')),
  version                text NOT NULL CHECK (version ~ '^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$'),
  min_supported_version  text NOT NULL CHECK (min_supported_version ~ '^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$'),
  released_at            timestamptz,
  artifact_ref           text NOT NULL,
  sha256                 bytea NOT NULL CHECK (octet_length(sha256) = 32),
  size_bytes             bigint NOT NULL CHECK (size_bytes > 0),
  signature              bytea NOT NULL CHECK (octet_length(signature) = 64),
  kid                    text NOT NULL,
  rollout_percent        smallint NOT NULL DEFAULT 0 CHECK (rollout_percent BETWEEN 0 AND 100),
  status                 text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','published','paused','withdrawn')),
  notes_key              text,
  created_at             timestamptz NOT NULL DEFAULT now(),
  UNIQUE (app, platform, flavor, channel, version),
  CHECK (platform.calver_key(min_supported_version) <= platform.calver_key(version)),
  CHECK (status = 'draft' OR released_at IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS platform.cell_backup_status (
  cell_id           text NOT NULL REFERENCES platform.cell(id),
  repo              text NOT NULL CHECK (repo IN ('repo1','repo2')),
  last_full_at      timestamptz,
  last_diff_at      timestamptz,
  last_incr_at      timestamptz,
  wal_archive_age_s integer CHECK (wal_archive_age_s >= 0),
  repo_size_bytes   bigint CHECK (repo_size_bytes >= 0),
  last_error        text,
  reported_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (cell_id, repo)
);

-- =====================================================================
-- ۱۰. کاتالوگ فروش: ویژگی (حق استفاده)، محصول/پلن/افزونه، نسخه، قیمت، مؤلفهٔ قیمت (مبنای قیمت Q-H)
-- =====================================================================
CREATE TABLE IF NOT EXISTS platform.feature (
  key             text PRIMARY KEY CHECK (key ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){1,3}$'),
  kind            text NOT NULL CHECK (kind IN ('flag','limit','meter')),
  unit            text CHECK (unit IN ('count','per_month','gb','parts','calls','hours','tokens','irr')),
  enforcement     text NOT NULL CHECK (enforcement IN ('data_plane','control_plane','both')),
  data_plane_key  text CHECK (data_plane_key ~ '^[a-z][a-z0-9_.]*$'),   -- کلید در entitlements حالت مطلوب
  description_fa  text NOT NULL,
  introduced_in   text NOT NULL,
  CHECK ((kind = 'flag') = (unit IS NULL))
);

CREATE TABLE IF NOT EXISTS platform.product (
  code        text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  kind        text NOT NULL CHECK (kind IN ('plan','addon','service','credit_pack','license')),
  name_fa     text NOT NULL,
  name_en     text,
  deployment  text NOT NULL CHECK (deployment IN ('saas','onprem','any')),
  sstid       text CHECK (sstid ~ '^[0-9]{13}$'),          -- شناسهٔ خدمت مؤدیان برای سطر صورتحساب
  status      text NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired')),
  sort_order  smallint NOT NULL DEFAULT 100,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CHECK (kind <> 'license' OR deployment = 'onprem')
);
ALTER TABLE platform.commission_rule DROP CONSTRAINT IF EXISTS commission_rule_product_fk;
ALTER TABLE platform.commission_rule ADD CONSTRAINT commission_rule_product_fk FOREIGN KEY (product_code) REFERENCES platform.product(code);

CREATE TABLE IF NOT EXISTS platform.product_version (
  id                    uuid PRIMARY KEY DEFAULT uuidv7(),
  product_code          text NOT NULL REFERENCES platform.product(code),
  version               integer NOT NULL CHECK (version >= 1),
  status                text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','in_review','published','retired')),
  available_from        date NOT NULL,
  available_to          date,
  trial_days            smallint NOT NULL DEFAULT 0 CHECK (trial_days BETWEEN 0 AND 90),
  grace_days            smallint NOT NULL DEFAULT 7 CHECK (grace_days BETWEEN 0 AND 60),        -- past_due ← → read_only
  read_only_days        smallint NOT NULL DEFAULT 30 CHECK (read_only_days BETWEEN 0 AND 365),   -- read_only ← → cancelled
  export_window_days    smallint NOT NULL DEFAULT 90 CHECK (export_window_days BETWEEN 30 AND 365),
  license_model         text CHECK (license_model IN ('perpetual','subscription')),
  license_term_months   smallint CHECK (license_term_months BETWEEN 1 AND 60),
  updates_months        smallint CHECK (updates_months BETWEEN 0 AND 60),
  notes_fa              text,
  created_by            uuid REFERENCES platform.staff(id),
  published_by          uuid REFERENCES platform.staff(id),
  published_at          timestamptz,
  approval_id           uuid REFERENCES platform.approval_request(id),
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  row_version           integer NOT NULL DEFAULT 1,
  UNIQUE (product_code, version),
  CHECK (available_to IS NULL OR available_to > available_from),
  CONSTRAINT product_version_published_fields CHECK (status NOT IN ('published','retired') OR (published_at IS NOT NULL AND published_by IS NOT NULL AND approval_id IS NOT NULL)),
  CHECK ((license_model = 'subscription') = (license_term_months IS NOT NULL))
);
SELECT platform.add_touch('platform.product_version');

CREATE TABLE IF NOT EXISTS platform.price (
  id                  uuid PRIMARY KEY DEFAULT uuidv7(),
  product_version_id  uuid NOT NULL REFERENCES platform.product_version(id),
  billing_period      text NOT NULL CHECK (billing_period IN ('P1M','P3M','P6M','P1Y','P2Y','ONCE')),
  currency            char(3) NOT NULL DEFAULT 'IRR' CHECK (currency = 'IRR'),
  UNIQUE (product_version_id, billing_period)
);

CREATE TABLE IF NOT EXISTS platform.price_component (
  id            uuid PRIMARY KEY DEFAULT uuidv7(),
  price_id      uuid NOT NULL REFERENCES platform.price(id),
  line_no       smallint NOT NULL CHECK (line_no BETWEEN 1 AND 50),
  kind          text NOT NULL CHECK (kind IN ('flat','per_unit','tiered','volume','package')),
  metric_key    text REFERENCES platform.feature(key),
  included_qty  numeric(18,0) NOT NULL DEFAULT 0 CHECK (included_qty >= 0),
  unit_amount   numeric(24,0) CHECK (unit_amount >= 0),             -- ریال صحیح
  package_size  integer CHECK (package_size > 0),
  tiers         jsonb,                                              -- [{"up_to": 10, "unit_amount": "5000000"}, {"up_to": null, ...}]
  min_qty       numeric(18,0) CHECK (min_qty >= 0),
  max_qty       numeric(18,0) CHECK (max_qty >= 0),
  UNIQUE (price_id, line_no),
  CHECK ((kind = 'flat') = (metric_key IS NULL)),
  CHECK (kind NOT IN ('flat','per_unit','package') OR unit_amount IS NOT NULL),
  CHECK ((kind IN ('tiered','volume')) = (tiers IS NOT NULL)),
  CHECK ((kind = 'package') = (package_size IS NOT NULL)),
  CHECK (max_qty IS NULL OR min_qty IS NULL OR max_qty >= min_qty)
);

CREATE TABLE IF NOT EXISTS platform.product_entitlement (
  product_version_id  uuid NOT NULL REFERENCES platform.product_version(id),
  feature_key         text NOT NULL REFERENCES platform.feature(key),
  enabled             boolean,
  limit_value         numeric(18,0) CHECK (limit_value >= 0),          -- NULL در combine='set' = نامحدود
  combine             text NOT NULL DEFAULT 'set' CHECK (combine IN ('set','add','add_per_unit')),
  enforcement         text NOT NULL DEFAULT 'hard' CHECK (enforcement IN ('hard','soft')),
  overage_pct         smallint NOT NULL DEFAULT 0 CHECK (overage_pct BETWEEN 0 AND 100),
  PRIMARY KEY (product_version_id, feature_key),
  CHECK (combine = 'set' OR enabled IS NOT NULL OR limit_value IS NOT NULL)
);

-- نسخهٔ محصول: پیش‌نویس → بازبینی (محتوا منجمد) → انتشار با تأیید دونفرهٔ «تغییر قیمت» → بازنشسته
CREATE OR REPLACE FUNCTION platform.product_version_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_kind text;
  v_allowed text[] := ARRAY['status','published_by','published_at','approval_id','updated_at','row_version','available_to'];
  k text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN
      PERFORM platform.fail('HK_PLT_IMMUTABLE', 'only draft product versions can be deleted');
    END IF;
    RETURN OLD;
  END IF;
  SELECT kind INTO v_kind FROM platform.product WHERE code = NEW.product_code;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' OR NEW.published_at IS NOT NULL OR NEW.approval_id IS NOT NULL THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'product versions start as draft');
    END IF;
    IF (v_kind = 'license') <> (NEW.license_model IS NOT NULL) THEN
      PERFORM platform.fail('HK_PLT_PRODUCT_SHAPE', 'license_model is required exactly for license products');
    END IF;
    IF v_kind <> 'plan' AND NEW.trial_days <> 0 THEN
      PERFORM platform.fail('HK_PLT_PRODUCT_SHAPE', 'only plans have trial days');
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.status <> 'draft' THEN
    FOR k IN SELECT jsonb_object_keys(to_jsonb(NEW)) LOOP
      IF NOT (k = ANY (v_allowed)) AND (to_jsonb(NEW)->k) IS DISTINCT FROM (to_jsonb(OLD)->k) THEN
        PERFORM platform.fail('HK_PLT_PRODUCT_FROZEN', format('column %s is frozen after draft', k));
      END IF;
    END LOOP;
    IF NEW.available_to IS DISTINCT FROM OLD.available_to AND NEW.status <> 'retired' THEN
      PERFORM platform.fail('HK_PLT_PRODUCT_FROZEN', 'availability end is set when retiring');
    END IF;
  END IF;
  IF NEW.status = OLD.status THEN
    IF NEW.published_at IS DISTINCT FROM OLD.published_at OR NEW.approval_id IS DISTINCT FROM OLD.approval_id THEN
      PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'publication fields change only when publishing');
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.status = 'draft' AND NEW.status = 'in_review' THEN
    IF NOT EXISTS (SELECT 1 FROM platform.price p WHERE p.product_version_id = NEW.id) THEN
      PERFORM platform.fail('HK_PLT_PRODUCT_SHAPE', 'a product version needs at least one price');
    END IF;
    IF EXISTS (SELECT 1 FROM platform.price p WHERE p.product_version_id = NEW.id
               AND NOT EXISTS (SELECT 1 FROM platform.price_component c WHERE c.price_id = p.id)) THEN
      PERFORM platform.fail('HK_PLT_PRODUCT_SHAPE', 'every price needs at least one component');
    END IF;
    IF v_kind IN ('plan','license') AND NOT EXISTS (SELECT 1 FROM platform.product_entitlement e WHERE e.product_version_id = NEW.id) THEN
      PERFORM platform.fail('HK_PLT_PRODUCT_SHAPE', 'plans and licenses need entitlements');
    END IF;
  ELSIF OLD.status = 'in_review' AND NEW.status = 'draft' THEN
    NULL;
  ELSIF OLD.status = 'in_review' AND NEW.status = 'published' THEN
    IF NEW.published_by IS DISTINCT FROM platform.current_staff_id() THEN
      PERFORM platform.fail('HK_PLT_ACTOR_MISMATCH', 'published_by must be the acting staff member');
    END IF;
    PERFORM platform.consume_approval(NEW.approval_id, 'price.publish', 'product_version', NEW.id, 'product_version:' || NEW.id::text);
    NEW.published_at := now();
  ELSIF OLD.status = 'published' AND NEW.status = 'retired' THEN
    NULL;
  ELSE
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', format('product version %s -> %s', OLD.status, NEW.status));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.product_version;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.product_version FOR EACH ROW EXECUTE FUNCTION platform.product_version_guard();

-- قیمت، مؤلفه و حق استفاده فقط در پیش‌نویس تغییر می‌کنند
CREATE OR REPLACE FUNCTION platform.product_child_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_pv uuid;
  v_status text;
  r record;
BEGIN
  r := CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  IF TG_TABLE_NAME = 'price_component' THEN
    SELECT product_version_id INTO v_pv FROM platform.price WHERE id = r.price_id;
  ELSE
    v_pv := r.product_version_id;
  END IF;
  SELECT status INTO v_status FROM platform.product_version WHERE id = v_pv;
  IF v_status IS DISTINCT FROM 'draft' THEN
    PERFORM platform.fail('HK_PLT_PRODUCT_FROZEN', format('%s of a %s product version is frozen', TG_TABLE_NAME, v_status));
  END IF;
  IF TG_OP = 'UPDATE' AND TG_TABLE_NAME = 'price_component' THEN
    IF OLD.price_id <> NEW.price_id THEN
      PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'component cannot move between prices');
    END IF;
  ELSIF TG_OP = 'UPDATE' AND TG_TABLE_NAME IN ('price','product_entitlement') THEN
    IF OLD.product_version_id <> NEW.product_version_id THEN
      PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'child rows cannot move between product versions');
    END IF;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_frozen ON platform.price;
CREATE TRIGGER trg_frozen BEFORE INSERT OR UPDATE OR DELETE ON platform.price FOR EACH ROW EXECUTE FUNCTION platform.product_child_guard();
DROP TRIGGER IF EXISTS trg_frozen ON platform.price_component;
CREATE TRIGGER trg_frozen BEFORE INSERT OR UPDATE OR DELETE ON platform.price_component FOR EACH ROW EXECUTE FUNCTION platform.product_child_guard();
DROP TRIGGER IF EXISTS trg_frozen ON platform.product_entitlement;
CREATE TRIGGER trg_frozen BEFORE INSERT OR UPDATE OR DELETE ON platform.product_entitlement FOR EACH ROW EXECUTE FUNCTION platform.product_child_guard();

-- پله‌های قیمت: آرایه‌ای صعودی از {up_to, unit_amount}؛ فقط آخری up_to=null
CREATE OR REPLACE FUNCTION platform.price_component_shape() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  n int; i int; prev numeric := -1; t jsonb;
  v_mkind text;
BEGIN
  IF NEW.metric_key IS NOT NULL THEN
    SELECT kind INTO v_mkind FROM platform.feature WHERE key = NEW.metric_key;
    IF v_mkind = 'flag' THEN
      PERFORM platform.fail('HK_PLT_PRICE_SHAPE', 'pricing metric must be a limit or meter feature');
    END IF;
  END IF;
  IF NEW.tiers IS NULL THEN RETURN NEW; END IF;
  IF jsonb_typeof(NEW.tiers) <> 'array' OR jsonb_array_length(NEW.tiers) = 0 THEN
    PERFORM platform.fail('HK_PLT_PRICE_SHAPE', 'tiers must be a non-empty array');
  END IF;
  n := jsonb_array_length(NEW.tiers);
  FOR i IN 0 .. n - 1 LOOP
    t := NEW.tiers->i;
    IF jsonb_typeof(t) <> 'object' OR NOT (t ? 'up_to' AND t ? 'unit_amount')
       OR (SELECT count(*) FROM jsonb_object_keys(t)) <> 2
       OR jsonb_typeof(t->'unit_amount') <> 'string' OR (t->>'unit_amount') !~ '^[0-9]{1,24}$' THEN
      PERFORM platform.fail('HK_PLT_PRICE_SHAPE', format('tier %s must be {up_to, unit_amount:"<integer rial>"}', i));
    END IF;
    IF i < n - 1 THEN
      IF jsonb_typeof(t->'up_to') <> 'number' OR (t->>'up_to')::numeric <= prev OR (t->>'up_to')::numeric <> trunc((t->>'up_to')::numeric) THEN
        PERFORM platform.fail('HK_PLT_PRICE_SHAPE', 'tier up_to must be strictly ascending integers');
      END IF;
      prev := (t->>'up_to')::numeric;
    ELSIF jsonb_typeof(t->'up_to') <> 'null' THEN
      PERFORM platform.fail('HK_PLT_PRICE_SHAPE', 'last tier must be open-ended (up_to null)');
    END IF;
  END LOOP;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_shape ON platform.price_component;
CREATE TRIGGER trg_shape BEFORE INSERT OR UPDATE ON platform.price_component FOR EACH ROW EXECUTE FUNCTION platform.price_component_shape();

CREATE OR REPLACE FUNCTION platform.entitlement_shape() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_fkind text;
  v_pkind text;
BEGIN
  SELECT kind INTO v_fkind FROM platform.feature WHERE key = NEW.feature_key;
  SELECT p.kind INTO v_pkind FROM platform.product_version pv JOIN platform.product p ON p.code = pv.product_code
   WHERE pv.id = NEW.product_version_id;
  IF v_fkind = 'flag' AND (NEW.enabled IS NULL OR NEW.limit_value IS NOT NULL) THEN
    PERFORM platform.fail('HK_PLT_ENTITLEMENT_SHAPE', 'flag entitlements set enabled only');
  END IF;
  IF v_fkind <> 'flag' AND NEW.enabled IS NOT NULL THEN
    PERFORM platform.fail('HK_PLT_ENTITLEMENT_SHAPE', 'limit/meter entitlements set limit_value only');
  END IF;
  IF v_pkind IN ('plan','license') AND NEW.combine <> 'set' THEN
    PERFORM platform.fail('HK_PLT_ENTITLEMENT_SHAPE', 'plan/license entitlements use combine=set');
  END IF;
  IF v_pkind = 'addon' AND v_fkind <> 'flag' AND NEW.combine = 'set' THEN
    PERFORM platform.fail('HK_PLT_ENTITLEMENT_SHAPE', 'addon limits add to the plan (combine add/add_per_unit)');
  END IF;
  IF v_pkind IN ('service','credit_pack') THEN
    PERFORM platform.fail('HK_PLT_ENTITLEMENT_SHAPE', 'services and credit packs carry no entitlements');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_shape ON platform.product_entitlement;
CREATE TRIGGER trg_shape BEFORE INSERT OR UPDATE ON platform.product_entitlement FOR EACH ROW EXECUTE FUNCTION platform.entitlement_shape();

CREATE TABLE IF NOT EXISTS platform.tenant_entitlement_override (
  id           uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id    uuid NOT NULL REFERENCES platform.tenant(id),
  feature_key  text NOT NULL REFERENCES platform.feature(key),
  mode         text NOT NULL CHECK (mode IN ('set','add')),
  enabled      boolean,
  limit_value  numeric(18,0) CHECK (limit_value >= 0),
  valid_from   timestamptz NOT NULL DEFAULT now(),
  valid_to     timestamptz NOT NULL,
  reason       text NOT NULL CHECK (char_length(btrim(reason)) >= 10),
  granted_by   uuid NOT NULL REFERENCES platform.staff(id),
  revoked_at   timestamptz,
  revoked_by   uuid REFERENCES platform.staff(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  CHECK (valid_to > valid_from AND valid_to <= valid_from + interval '400 days'),
  CHECK ((revoked_at IS NULL) = (revoked_by IS NULL)),
  CHECK (mode = 'set' OR limit_value IS NOT NULL),
  CONSTRAINT override_no_overlap EXCLUDE USING gist (tenant_id WITH =, feature_key WITH =, tstzrange(valid_from, valid_to) WITH &&)
    WHERE (revoked_at IS NULL)
);

CREATE OR REPLACE FUNCTION platform.override_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_fkind text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE', 'overrides are revoked, never deleted');
  END IF;
  IF TG_OP = 'INSERT' THEN
    SELECT kind INTO v_fkind FROM platform.feature WHERE key = NEW.feature_key;
    IF (v_fkind = 'flag') <> (NEW.enabled IS NOT NULL) OR (v_fkind = 'flag' AND NEW.limit_value IS NOT NULL) THEN
      PERFORM platform.fail('HK_PLT_ENTITLEMENT_SHAPE', 'override shape does not match feature kind');
    END IF;
    IF NEW.granted_by IS DISTINCT FROM platform.current_staff_id() THEN
      PERFORM platform.fail('HK_PLT_ACTOR_MISMATCH', 'granted_by must be the acting staff member');
    END IF;
    IF NEW.revoked_at IS NOT NULL THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'override cannot be created revoked');
    END IF;
    RETURN NEW;
  END IF;
  IF (to_jsonb(NEW) - 'revoked_at' - 'revoked_by') <> (to_jsonb(OLD) - 'revoked_at' - 'revoked_by') OR OLD.revoked_at IS NOT NULL THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'overrides change only by revocation');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.tenant_entitlement_override;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.tenant_entitlement_override FOR EACH ROW EXECUTE FUNCTION platform.override_guard();

-- پرچم ویژگی برای rollout تدریجی و kill switch (P1)
CREATE TABLE IF NOT EXISTS platform.feature_flag (
  key              text PRIMARY KEY CHECK (key ~ '^ff\.[a-z][a-z0-9_.]{2,60}$'),
  description      text NOT NULL,
  kind             text NOT NULL CHECK (kind IN ('release','ops_kill_switch','experiment')),
  default_on       boolean NOT NULL DEFAULT false,
  rollout_percent  smallint NOT NULL DEFAULT 0 CHECK (rollout_percent BETWEEN 0 AND 100),
  kill_switch      boolean NOT NULL DEFAULT false,      -- true = همه‌جا خاموش، بر هر هدف مقدم است
  status           text NOT NULL DEFAULT 'active' CHECK (status IN ('active','archived')),
  created_by       uuid REFERENCES platform.staff(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  row_version      integer NOT NULL DEFAULT 1
);
SELECT platform.add_touch('platform.feature_flag');

CREATE TABLE IF NOT EXISTS platform.feature_flag_target (
  flag_key     text NOT NULL REFERENCES platform.feature_flag(key),
  target_kind  text NOT NULL CHECK (target_kind IN ('tenant','plan','cell','reseller','deployment')),
  target_id    text NOT NULL,
  is_on        boolean NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (flag_key, target_kind, target_id)
);

-- ارزیابی قطعی پرچم برای مستأجر: kill سراسری > (فقط ops_kill_switch: خاموشی هر هدف منطبق غالب است)
--   > هدف tenant > هدف plan > هدف cell > درصد (hash پایدار) > پیش‌فرض
DROP FUNCTION IF EXISTS platform.flag_on_for_tenant(text, uuid, text);
CREATE OR REPLACE FUNCTION platform.flag_on_for_tenant(p_flag text, p_tenant uuid, p_plan text, p_cell text DEFAULT NULL) RETURNS boolean
LANGUAGE sql STABLE AS $$
  WITH t AS (
    SELECT g.target_kind, g.is_on FROM platform.feature_flag_target g
     WHERE g.flag_key = p_flag
       AND ((g.target_kind = 'tenant' AND g.target_id = p_tenant::text)
         OR (g.target_kind = 'plan' AND g.target_id = p_plan)
         OR (g.target_kind = 'cell' AND g.target_id = p_cell)))
  SELECT CASE
    WHEN f.kill_switch OR f.status <> 'active' THEN false
    WHEN f.kind = 'ops_kill_switch' AND EXISTS (SELECT 1 FROM t WHERE NOT t.is_on) THEN false
    WHEN EXISTS (SELECT 1 FROM t WHERE t.target_kind = 'tenant') THEN (SELECT t.is_on FROM t WHERE t.target_kind = 'tenant')
    WHEN EXISTS (SELECT 1 FROM t WHERE t.target_kind = 'plan')   THEN (SELECT t.is_on FROM t WHERE t.target_kind = 'plan')
    WHEN EXISTS (SELECT 1 FROM t WHERE t.target_kind = 'cell')   THEN (SELECT t.is_on FROM t WHERE t.target_kind = 'cell')
    WHEN f.rollout_percent > 0
      THEN (('x' || substr(encode(sha256(convert_to(f.key || ':' || p_tenant::text, 'UTF8')), 'hex'), 1, 8))::bit(32)::bigint % 100) < f.rollout_percent
    ELSE f.default_on
  END
  FROM platform.feature_flag f WHERE f.key = p_flag
$$;

-- هر تغییر پرچم یا هدف آن بازسازی حالت مطلوب را صف می‌کند (cause = 'flag')؛ kill switch دستیار در hkcellstate/1 هم می‌رود
CREATE OR REPLACE FUNCTION platform.feature_flag_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_row jsonb := to_jsonb(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);
  v_key text := coalesce(v_row->>'flag_key', v_row->>'key');
BEGIN
  PERFORM platform.enqueue('control.flag.propagate', 'sync', jsonb_build_object('flag_key', v_key, 'cause', 'flag'),
                           'flag:' || v_key || ':' || txid_current()::text);
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_apply ON platform.feature_flag;
CREATE TRIGGER trg_apply AFTER INSERT OR UPDATE ON platform.feature_flag FOR EACH ROW EXECUTE FUNCTION platform.feature_flag_apply();
DROP TRIGGER IF EXISTS trg_apply ON platform.feature_flag_target;
CREATE TRIGGER trg_apply AFTER INSERT OR UPDATE OR DELETE ON platform.feature_flag_target FOR EACH ROW EXECUTE FUNCTION platform.feature_flag_apply();

-- تعرفهٔ خدمات مصرفی (پیامک خط پلتفرم، استعلام)
CREATE TABLE IF NOT EXISTS platform.service_tariff (
  service_key  text NOT NULL REFERENCES platform.feature(key),
  unit_amount  numeric(24,0) NOT NULL CHECK (unit_amount >= 0),
  valid_from   timestamptz NOT NULL,
  valid_to     timestamptz,
  created_by   uuid REFERENCES platform.staff(id),
  PRIMARY KEY (service_key, valid_from),
  CHECK (valid_to IS NULL OR valid_to > valid_from),
  CONSTRAINT tariff_no_overlap EXCLUDE USING gist (service_key WITH =, tstzrange(valid_from, valid_to) WITH &&)
);

CREATE OR REPLACE FUNCTION platform.tariff_at(p_service text, p_at timestamptz) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT unit_amount FROM platform.service_tariff
   WHERE service_key = p_service AND valid_from <= p_at AND (valid_to IS NULL OR valid_to > p_at)
$$;

-- ---------- دستیار هوشمند (Q-F؛ قرارداد C-AS-07 بخش ۱۰ §۵-۱۹) ----------
-- ارائه‌دهندهٔ مدل: تنها فراخوانی بیرونی مجاز محصول؛ کلید فقط به‌صورت ارجاع OpenBao.
-- اثرانگشت مقصد داده = همان فرمول assistant.provider_fingerprint (بردار مشترک tests/assistant_fingerprint_v1.json).
CREATE OR REPLACE FUNCTION platform.url_host(p_url text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT lower(substring(p_url FROM '^[A-Za-z][A-Za-z0-9+.-]*://([^/:?#@]+)'))
$$;

CREATE OR REPLACE FUNCTION platform.ai_provider_fingerprint(p_operator text, p_base_url text, p_data_location text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT encode(sha256(convert_to('hkllm1|' || lower(btrim(p_operator)) || '|' || coalesce(platform.url_host(p_base_url), '')
                                  || '|' || p_data_location, 'UTF8')), 'hex')
$$;

CREATE TABLE IF NOT EXISTS platform.ai_provider (
  id                      uuid PRIMARY KEY DEFAULT uuidv7(),
  code                    text NOT NULL UNIQUE CHECK (code ~ '^[a-z][a-z0-9_.-]{1,60}$'),
  version                 integer NOT NULL DEFAULT 1 CHECK (version >= 1),     -- +۱ با هر تغییر محتوا (تریگر)
  name                    text NOT NULL CHECK (char_length(btrim(name)) >= 2),
  operator                text NOT NULL CHECK (char_length(btrim(operator)) >= 2),   -- نام حقوقی اپراتور (در متن رضایت مستأجر)
  data_location           text NOT NULL CHECK (data_location IN ('iran','cell_private','other')),
  network                 text NOT NULL CHECK (network IN ('public','cell_private')),
  -- بدون اعتبارنامه، query یا fragment در URL
  base_url                text NOT NULL CHECK (base_url ~ '^https?://[A-Za-z0-9.-]+(:[0-9]{2,5})?(/[A-Za-z0-9._~/-]*)?$'),
  model                   text NOT NULL CHECK (model ~ '^[A-Za-z0-9._:/@+-]{1,120}$'),
  auth_header             text NOT NULL DEFAULT 'authorization_bearer' CHECK (auth_header IN ('authorization_bearer','x_api_key','none')),
  secret_ref              text CHECK (secret_ref ~ '^openbao://[A-Za-z0-9/_.-]+$'),
  connect_timeout_ms      integer NOT NULL DEFAULT 5000   CHECK (connect_timeout_ms BETWEEN 100 AND 60000),
  first_token_timeout_ms  integer NOT NULL DEFAULT 30000  CHECK (first_token_timeout_ms BETWEEN 1000 AND 300000),
  total_timeout_ms        integer NOT NULL DEFAULT 120000 CHECK (total_timeout_ms BETWEEN 1000 AND 600000),
  max_output_tokens       integer NOT NULL DEFAULT 2048   CHECK (max_output_tokens BETWEEN 64 AND 32768),
  max_context_tokens      integer NOT NULL DEFAULT 32768  CHECK (max_context_tokens BETWEEN 1024 AND 2000000),
  capabilities            jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(capabilities) = 'object'),   -- از probe
  rpm                     integer NOT NULL DEFAULT 60     CHECK (rpm BETWEEN 1 AND 100000),
  tpm                     integer NOT NULL DEFAULT 100000 CHECK (tpm BETWEEN 1000 AND 100000000),
  max_concurrency         integer NOT NULL DEFAULT 4      CHECK (max_concurrency BETWEEN 1 AND 1000),
  fingerprint             text GENERATED ALWAYS AS (platform.ai_provider_fingerprint(operator, base_url, data_location)) STORED,
  status                  text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','validated','active','disabled','retired')),
  is_default              boolean NOT NULL DEFAULT false,
  last_probe_at           timestamptz,
  last_probe_ok           boolean,
  last_probe_error        text,
  last_eval_run_id        uuid,                                             -- FK پس از ساخت ai_eval_run
  activation_approval_id  uuid REFERENCES platform.approval_request(id),
  disabled_reason         text,
  created_by              uuid REFERENCES platform.staff(id),
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  row_version             integer NOT NULL DEFAULT 1,
  -- http فقط برای سرور مدل داخل شبکهٔ سلول؛ شبکهٔ خصوصی سلول ⇔ محل داده «درون سلول»
  CONSTRAINT ai_provider_http_private CHECK (base_url ~ '^https://' OR network = 'cell_private'),
  CONSTRAINT ai_provider_private_location CHECK ((network = 'cell_private') = (data_location = 'cell_private')),
  CONSTRAINT ai_provider_auth_secret CHECK ((auth_header = 'none') = (secret_ref IS NULL)),
  CONSTRAINT ai_provider_default_active CHECK (NOT is_default OR status = 'active'),
  CONSTRAINT ai_provider_validated_fields CHECK (status NOT IN ('validated','active','disabled')
                                                 OR (last_probe_ok IS TRUE AND last_eval_run_id IS NOT NULL)),
  CHECK ((last_probe_at IS NULL) = (last_probe_ok IS NULL)),
  CHECK ((status = 'disabled') = (disabled_reason IS NOT NULL)),
  CHECK (first_token_timeout_ms <= total_timeout_ms)
);
CREATE UNIQUE INDEX IF NOT EXISTS ai_provider_one_default ON platform.ai_provider ((true)) WHERE is_default;
SELECT platform.add_touch('platform.ai_provider');

-- اجرای ارزیابی (suite طلایی دستیار) روی یک نسخهٔ ارائه‌دهنده؛ فقط‌افزودنی
CREATE TABLE IF NOT EXISTS platform.ai_eval_run (
  id                 uuid PRIMARY KEY DEFAULT uuidv7(),
  provider_id        uuid NOT NULL REFERENCES platform.ai_provider(id),
  provider_version   integer NOT NULL CHECK (provider_version >= 1),
  prompt_version     text NOT NULL CHECK (char_length(prompt_version) BETWEEN 1 AND 40),
  toolset_sha256     bytea NOT NULL CHECK (octet_length(toolset_sha256) = 32),
  suite              text NOT NULL CHECK (suite ~ '^[a-z][a-z0-9_.-]{1,60}$'),
  suite_version      text NOT NULL CHECK (char_length(suite_version) BETWEEN 1 AND 40),
  started_at         timestamptz NOT NULL,
  finished_at        timestamptz NOT NULL,
  cases              integer NOT NULL CHECK (cases > 0),
  passed_cases       integer NOT NULL CHECK (passed_cases >= 0),
  metrics            jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metrics) = 'object'),
  threshold_version  text NOT NULL CHECK (char_length(threshold_version) BETWEEN 1 AND 40),
  passed             boolean NOT NULL,
  report_ref         text,
  executed_by_kind   text NOT NULL CHECK (executed_by_kind IN ('staff','system')),
  executed_by        uuid REFERENCES platform.staff(id),
  created_at         timestamptz NOT NULL DEFAULT now(),
  CHECK (finished_at >= started_at),
  CHECK (passed_cases <= cases),
  CHECK (NOT passed OR passed_cases > 0),
  CHECK ((executed_by_kind = 'staff') = (executed_by IS NOT NULL))
);

CREATE OR REPLACE FUNCTION platform.ai_eval_run_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.provider_version IS DISTINCT FROM (SELECT version FROM platform.ai_provider WHERE id = NEW.provider_id) THEN
    PERFORM platform.fail('HK_PLT_AI_EVAL_MISMATCH', 'an eval run belongs to the current version of its provider');
  END IF;
  IF NEW.executed_by_kind = 'staff' AND NEW.executed_by IS DISTINCT FROM platform.current_staff_id() THEN
    PERFORM platform.fail('HK_PLT_ACTOR_MISMATCH', 'executed_by must be the acting staff member');
  END IF;
  NEW.created_at := now();
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.ai_eval_run;
CREATE TRIGGER trg_guard BEFORE INSERT ON platform.ai_eval_run FOR EACH ROW EXECUTE FUNCTION platform.ai_eval_run_guard();
SELECT platform.make_append_only('platform.ai_eval_run');

ALTER TABLE platform.ai_provider DROP CONSTRAINT IF EXISTS ai_provider_last_eval_fk;
ALTER TABLE platform.ai_provider ADD CONSTRAINT ai_provider_last_eval_fk FOREIGN KEY (last_eval_run_id) REFERENCES platform.ai_eval_run(id);

-- چرخهٔ عمر: draft → validated (probe موفق + ارزیابی قبول‌شدهٔ همین نسخه) → active (تأیید دونفره) ⇄ disabled → retired.
-- مقصد (اپراتور، URL، محل داده، شبکه، مدل، احراز، کلید) در active منجمد است؛ تغییرش در حالت‌های دیگر وضعیت را به draft
-- برمی‌گرداند و probe/ارزیابی را پاک می‌کند. هر تغییر محتوا version را +۱ می‌کند (سند حالت مطلوب نسخهٔ پروفایل را دارد).
CREATE OR REPLACE FUNCTION platform.ai_provider_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_dest_changed boolean;
  v_ops_changed  boolean;
  e platform.ai_eval_run%ROWTYPE;
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE', 'AI providers are retired, never deleted');
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' OR NEW.is_default OR NEW.version <> 1 OR NEW.last_eval_run_id IS NOT NULL
       OR NEW.last_probe_at IS NOT NULL OR NEW.activation_approval_id IS NOT NULL THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'AI providers start as unvalidated version-1 drafts');
    END IF;
    IF NEW.created_by IS DISTINCT FROM platform.current_staff_id() THEN
      PERFORM platform.fail('HK_PLT_ACTOR_MISMATCH', 'created_by must be the acting staff member');
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.code <> OLD.code OR NEW.created_at <> OLD.created_at OR NEW.created_by IS DISTINCT FROM OLD.created_by THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'provider identity is immutable');
  END IF;
  IF NEW.version <> OLD.version THEN
    PERFORM platform.fail('HK_PLT_DERIVED_COLUMN', 'provider version follows content changes');
  END IF;
  IF OLD.status = 'retired' THEN
    PERFORM platform.fail('HK_PLT_AI_PROVIDER_FROZEN', 'a retired provider is frozen');
  END IF;
  v_dest_changed := NEW.operator <> OLD.operator OR NEW.base_url <> OLD.base_url OR NEW.data_location <> OLD.data_location
                 OR NEW.network <> OLD.network OR NEW.model <> OLD.model OR NEW.auth_header <> OLD.auth_header
                 OR NEW.secret_ref IS DISTINCT FROM OLD.secret_ref;
  v_ops_changed  := NEW.name <> OLD.name OR NEW.connect_timeout_ms <> OLD.connect_timeout_ms
                 OR NEW.first_token_timeout_ms <> OLD.first_token_timeout_ms OR NEW.total_timeout_ms <> OLD.total_timeout_ms
                 OR NEW.max_output_tokens <> OLD.max_output_tokens OR NEW.max_context_tokens <> OLD.max_context_tokens
                 OR NEW.rpm <> OLD.rpm OR NEW.tpm <> OLD.tpm OR NEW.max_concurrency <> OLD.max_concurrency;
  IF v_dest_changed THEN
    IF OLD.status = 'active' THEN
      PERFORM platform.fail('HK_PLT_AI_PROVIDER_FROZEN', 'the destination of an active provider is frozen; disable it first');
    END IF;
    IF NEW.status <> OLD.status THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'change the destination and the status in separate steps');
    END IF;
    NEW.status := 'draft'; NEW.disabled_reason := NULL; NEW.is_default := false;
    NEW.last_probe_at := NULL; NEW.last_probe_ok := NULL; NEW.last_probe_error := NULL;
    NEW.last_eval_run_id := NULL; NEW.capabilities := '{}'::jsonb;
    NEW.version := OLD.version + 1;
    RETURN NEW;                                -- بازگشت به draft خودش گذار است
  END IF;
  IF v_ops_changed THEN
    NEW.version := OLD.version + 1;
  END IF;
  IF NEW.last_eval_run_id IS DISTINCT FROM OLD.last_eval_run_id AND NEW.last_eval_run_id IS NOT NULL THEN
    SELECT * INTO e FROM platform.ai_eval_run WHERE id = NEW.last_eval_run_id;
    IF e.provider_id <> NEW.id OR e.provider_version <> NEW.version THEN
      PERFORM platform.fail('HK_PLT_AI_EVAL_MISMATCH', 'the eval run must belong to this provider version');
    END IF;
  END IF;
  IF NEW.status = OLD.status THEN RETURN NEW; END IF;
  IF OLD.status = 'draft' AND NEW.status = 'validated' THEN
    SELECT * INTO e FROM platform.ai_eval_run WHERE id = NEW.last_eval_run_id;
    IF NEW.last_probe_ok IS NOT TRUE OR e.id IS NULL OR NOT e.passed OR e.provider_version <> NEW.version
       OR e.provider_id <> NEW.id THEN
      PERFORM platform.fail('HK_PLT_AI_EVAL_REQUIRED', 'validation needs a successful probe and a passed eval of this version');
    END IF;
  ELSIF OLD.status = 'validated' AND NEW.status = 'draft' THEN
    NULL;
  ELSIF OLD.status IN ('validated','disabled') AND NEW.status = 'active' THEN
    PERFORM platform.consume_approval(NEW.activation_approval_id, 'ai_provider.activate', 'ai_provider', NEW.id,
                                      'ai_provider:' || NEW.id::text || ':v' || NEW.version::text);
    NEW.disabled_reason := NULL;
  ELSIF OLD.status = 'active' AND NEW.status = 'disabled' THEN
    NULL;
  ELSIF OLD.status IN ('draft','validated','disabled') AND NEW.status = 'retired' THEN
    NULL;
  ELSE
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', format('AI provider %s -> %s', OLD.status, NEW.status));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.ai_provider;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.ai_provider FOR EACH ROW EXECUTE FUNCTION platform.ai_provider_guard();

-- هر تغییر ارائه‌دهندهٔ فعال یا پیش‌فرض در همان تراکنش بازسازی حالت مطلوب سلول‌ها را صف می‌کند
CREATE OR REPLACE FUNCTION platform.ai_provider_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status = 'active' OR OLD.status = 'active' THEN
    PERFORM platform.enqueue('control.cell_state.build', 'sync',
                             jsonb_build_object('cause', 'ai_provider', 'provider_id', NEW.id, 'version', NEW.version),
                             'ai_provider:' || NEW.id::text || ':' || NEW.row_version::text);
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_apply ON platform.ai_provider;
CREATE TRIGGER trg_apply AFTER UPDATE ON platform.ai_provider FOR EACH ROW EXECUTE FUNCTION platform.ai_provider_apply();

-- قیمت خرید توکن از ارائه‌دهنده (هزینهٔ تمام‌شده؛ نه قیمت فروش به مستأجر). قیمتِ رفته در حالت مطلوب = قیمت جاری
CREATE TABLE IF NOT EXISTS platform.ai_provider_price (
  provider_id      uuid NOT NULL REFERENCES platform.ai_provider(id),
  valid_from       timestamptz NOT NULL,
  valid_to         timestamptz,
  unit             text NOT NULL DEFAULT 'IRR' CHECK (unit IN ('IRR','IRT','IRR_NEW')),
  input_per_mtok   numeric(24,4) NOT NULL CHECK (input_per_mtok >= 0),
  output_per_mtok  numeric(24,4) NOT NULL CHECK (output_per_mtok >= 0),
  created_by       uuid REFERENCES platform.staff(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (provider_id, valid_from),
  CHECK (valid_to IS NULL OR valid_to > valid_from),
  CONSTRAINT ai_price_no_overlap EXCLUDE USING gist (provider_id WITH =, tstzrange(valid_from, valid_to) WITH &&)
);

-- قیمت تغییر نمی‌کند؛ فقط بستن آن از اکنون به بعد، یا حذف قیمتی که هنوز شروع نشده
CREATE OR REPLACE FUNCTION platform.ai_price_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.valid_from <= now() THEN
      PERFORM platform.fail('HK_PLT_IMMUTABLE', 'an effective AI price cannot be deleted');
    END IF;
    RETURN OLD;
  END IF;
  IF (to_jsonb(NEW) - 'valid_to') <> (to_jsonb(OLD) - 'valid_to') THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'AI prices change only by closing them');
  END IF;
  IF NEW.valid_to IS NULL OR NEW.valid_to < now() OR (OLD.valid_to IS NOT NULL AND NEW.valid_to > OLD.valid_to) THEN
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'an AI price can only be closed from now on');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.ai_provider_price;
CREATE TRIGGER trg_guard BEFORE UPDATE OR DELETE ON platform.ai_provider_price FOR EACH ROW EXECUTE FUNCTION platform.ai_price_guard();

CREATE OR REPLACE FUNCTION platform.ai_price_at(p_provider uuid, p_at timestamptz)
RETURNS TABLE (unit text, input_per_mtok numeric, output_per_mtok numeric)
LANGUAGE sql STABLE AS $$
  SELECT p.unit, p.input_per_mtok, p.output_per_mtok FROM platform.ai_provider_price p
   WHERE p.provider_id = p_provider AND p.valid_from <= p_at AND (p.valid_to IS NULL OR p.valid_to > p_at)
$$;

-- سیاست دستیار برای هر نسخهٔ پلن یا افزونه (همراه نسخهٔ محصول منجمد می‌شود)
CREATE TABLE IF NOT EXISTS platform.ai_plan_policy (
  product_version_id      uuid PRIMARY KEY REFERENCES platform.product_version(id),
  features                text[] NOT NULL CHECK (cardinality(features) >= 1
                            AND features <@ ARRAY['chat','proposals','migration_mapping','voice','ocr','insights']::text[]),
  provider_id             uuid REFERENCES platform.ai_provider(id),        -- NULL = ارائه‌دهندهٔ پیش‌فرض
  secondary_provider_ids  uuid[] NOT NULL DEFAULT '{}' CHECK (cardinality(secondary_provider_ids) <= 4),
  tenant_monthly_tokens   bigint CHECK (tenant_monthly_tokens > 0),
  tenant_monthly_cost     numeric(24,0) CHECK (tenant_monthly_cost > 0),
  cost_unit               text NOT NULL DEFAULT 'IRR' CHECK (cost_unit IN ('IRR','IRT','IRR_NEW')),
  user_monthly_tokens     bigint CHECK (user_monthly_tokens > 0),
  max_concurrent_runs     smallint NOT NULL DEFAULT 3  CHECK (max_concurrent_runs BETWEEN 1 AND 100),
  max_rounds              smallint NOT NULL DEFAULT 6  CHECK (max_rounds BETWEEN 1 AND 16),
  max_tool_calls          smallint NOT NULL DEFAULT 12 CHECK (max_tool_calls BETWEEN 1 AND 32),
  allow_tenant_provider   boolean NOT NULL DEFAULT false,
  period_anchor           text NOT NULL DEFAULT 'jalali_month' CHECK (period_anchor IN ('jalali_month','billing_anchor')),
  billing_anchor_day      smallint CHECK (billing_anchor_day BETWEEN 1 AND 28),
  CHECK ((period_anchor = 'billing_anchor') = (billing_anchor_day IS NOT NULL)),
  CHECK (user_monthly_tokens IS NULL OR tenant_monthly_tokens IS NULL OR user_monthly_tokens <= tenant_monthly_tokens),
  CHECK (provider_id IS NULL OR NOT (provider_id = ANY (secondary_provider_ids)))
);
DROP TRIGGER IF EXISTS trg_frozen ON platform.ai_plan_policy;
CREATE TRIGGER trg_frozen BEFORE INSERT OR UPDATE OR DELETE ON platform.ai_plan_policy FOR EACH ROW EXECUTE FUNCTION platform.product_child_guard();

CREATE OR REPLACE FUNCTION platform.ai_plan_policy_shape() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_kind text;
  v_missing int;
BEGIN
  SELECT p.kind INTO v_kind FROM platform.product_version pv JOIN platform.product p ON p.code = pv.product_code
   WHERE pv.id = NEW.product_version_id;
  IF v_kind NOT IN ('plan','addon') THEN
    PERFORM platform.fail('HK_PLT_AI_POLICY_SHAPE', 'assistant policies belong to plans or addons');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM platform.product_entitlement e WHERE e.product_version_id = NEW.product_version_id
                 AND e.feature_key = 'ai.assistant' AND e.enabled) THEN
    PERFORM platform.fail('HK_PLT_AI_POLICY_SHAPE', 'the product version must grant the ai.assistant entitlement');
  END IF;
  SELECT count(*) INTO v_missing FROM unnest(NEW.secondary_provider_ids) s(id)
   WHERE NOT EXISTS (SELECT 1 FROM platform.ai_provider p WHERE p.id = s.id AND p.status <> 'retired');
  IF v_missing > 0 OR (SELECT count(DISTINCT x) FROM unnest(NEW.secondary_provider_ids) x) <> cardinality(NEW.secondary_provider_ids) THEN
    PERFORM platform.fail('HK_PLT_AI_POLICY_SHAPE', 'secondary providers must be distinct, existing and not retired');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_shape ON platform.ai_plan_policy;
CREATE TRIGGER trg_shape BEFORE INSERT OR UPDATE ON platform.ai_plan_policy FOR EACH ROW EXECUTE FUNCTION platform.ai_plan_policy_shape();

-- استثنای دستیار برای یک مستأجر: خاموش‌کردن فوری است؛ روشن‌کردن یا افزایش سقف تأیید دونفره می‌خواهد
CREATE TABLE IF NOT EXISTS platform.ai_tenant_override (
  id                     uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id              uuid NOT NULL REFERENCES platform.tenant(id),
  enabled                boolean,                                   -- false = قطع؛ NULL = بدون تغییر
  kill_reason            text,
  features               text[] CHECK (features <@ ARRAY['chat','proposals','migration_mapping','voice','ocr','insights']::text[]),
  provider_id            uuid REFERENCES platform.ai_provider(id),
  tenant_monthly_tokens  bigint CHECK (tenant_monthly_tokens > 0),
  tenant_monthly_cost    numeric(24,0) CHECK (tenant_monthly_cost > 0),
  user_monthly_tokens    bigint CHECK (user_monthly_tokens > 0),
  max_concurrent_runs    smallint CHECK (max_concurrent_runs BETWEEN 1 AND 100),
  allow_tenant_provider  boolean,
  reason                 text NOT NULL CHECK (char_length(btrim(reason)) >= 10),
  created_by             uuid NOT NULL REFERENCES platform.staff(id),
  approval_id            uuid REFERENCES platform.approval_request(id),
  valid_from             timestamptz NOT NULL DEFAULT now(),
  expires_at             timestamptz,
  revoked_at             timestamptz,
  revoked_by             uuid REFERENCES platform.staff(id),
  CONSTRAINT ai_override_kill_reason CHECK ((enabled IS FALSE) = (kill_reason IS NOT NULL)),
  CONSTRAINT ai_override_not_empty CHECK (enabled IS NOT NULL OR features IS NOT NULL OR provider_id IS NOT NULL
                                          OR tenant_monthly_tokens IS NOT NULL OR tenant_monthly_cost IS NOT NULL
                                          OR user_monthly_tokens IS NOT NULL OR max_concurrent_runs IS NOT NULL
                                          OR allow_tenant_provider IS NOT NULL),
  CHECK ((revoked_at IS NULL) = (revoked_by IS NULL)),
  CHECK (expires_at IS NULL OR expires_at > valid_from),
  -- یک استثنای زنده برای هر مستأجر در هر لحظه (جایگزینی = لغو + ثبت تازه)
  CONSTRAINT ai_override_one_live EXCLUDE USING gist (tenant_id WITH =, tstzrange(valid_from, expires_at) WITH &&)
    WHERE (revoked_at IS NULL)
);

CREATE OR REPLACE FUNCTION platform.ai_tenant_override_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE', 'AI overrides are revoked, never deleted');
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.created_by IS DISTINCT FROM platform.current_staff_id()
       OR NOT platform.staff_has_permission(NEW.created_by, 'platform.ai.manage') THEN
      PERFORM platform.fail('HK_PLT_PERMISSION', 'creator must be the acting staff member with platform.ai.manage');
    END IF;
    IF NEW.revoked_at IS NOT NULL THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'override cannot be created revoked');
    END IF;
    NEW.valid_from := now();
    -- فقط «خاموش‌کردن خالص» بی‌تأیید است؛ هر چیز دیگری مصرف یا دسترسی را باز می‌کند
    IF NOT (NEW.enabled IS FALSE AND NEW.features IS NULL AND NEW.provider_id IS NULL AND NEW.tenant_monthly_tokens IS NULL
            AND NEW.tenant_monthly_cost IS NULL AND NEW.user_monthly_tokens IS NULL AND NEW.max_concurrent_runs IS NULL
            AND NEW.allow_tenant_provider IS NULL) THEN
      PERFORM platform.consume_approval(NEW.approval_id, 'ai.tenant_override', 'tenant', NEW.tenant_id,
                                        'ai_tenant_override:' || NEW.id::text);
    ELSIF NEW.approval_id IS NOT NULL THEN
      PERFORM platform.fail('HK_PLT_APPROVAL_MISMATCH', 'a pure kill takes no approval');
    END IF;
    RETURN NEW;
  END IF;
  IF (to_jsonb(NEW) - 'revoked_at' - 'revoked_by') <> (to_jsonb(OLD) - 'revoked_at' - 'revoked_by') OR OLD.revoked_at IS NOT NULL THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'AI overrides change only by revocation');
  END IF;
  IF NEW.revoked_by IS DISTINCT FROM platform.current_staff_id() THEN
    PERFORM platform.fail('HK_PLT_ACTOR_MISMATCH', 'revoked_by must be the acting staff member');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.ai_tenant_override;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.ai_tenant_override FOR EACH ROW EXECUTE FUNCTION platform.ai_tenant_override_guard();

CREATE OR REPLACE FUNCTION platform.ai_tenant_override_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM platform.enqueue('control.desired_state.build', 'sync',
                           jsonb_build_object('tenant_id', NEW.tenant_id, 'cause', 'override', 'ai_override_id', NEW.id),
                           'ai_override:' || NEW.id::text || ':' || CASE WHEN NEW.revoked_at IS NULL THEN 'set' ELSE 'revoked' END);
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_apply ON platform.ai_tenant_override;
CREATE TRIGGER trg_apply AFTER INSERT OR UPDATE ON platform.ai_tenant_override FOR EACH ROW EXECUTE FUNCTION platform.ai_tenant_override_apply();

-- ---------- پیامک خط پلتفرم: حساب‌های سرویس‌دهنده و الگوها (پژوهش ۰۵ §۳-۶ و §۳-۷) ----------
-- کلید الگو همان core.notification_template_def.sms_pattern_code صفحهٔ داده است (مثلاً hk-otp)؛ کد هر سرویس‌دهنده این‌جا نگاشت می‌شود
CREATE TABLE IF NOT EXISTS platform.sms_provider_account (
  id                     uuid PRIMARY KEY DEFAULT uuidv7(),
  provider               text NOT NULL CHECK (provider IN ('kavenegar','melipayamak','smsir','ippanel','ghasedak','magfa','other')),
  role                   text NOT NULL CHECK (role IN ('primary','fallback')),
  priority               smallint NOT NULL DEFAULT 100,
  sender_line            text NOT NULL CHECK (sender_line ~ '^\+?[0-9]{3,20}$'),
  secret_ref             text NOT NULL CHECK (secret_ref ~ '^openbao://[A-Za-z0-9/_.-]+$'),
  single_part_chars      smallint NOT NULL DEFAULT 70 CHECK (single_part_chars BETWEEN 60 AND 160),   -- UCS-2: ۷۰
  multi_part_chars       smallint NOT NULL DEFAULT 67 CHECK (multi_part_chars BETWEEN 60 AND 153),    -- ۶۷ (یا ۶۶ با مرجع ۱۶ بیتی)
  status                 text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
  reported_balance       numeric(24,0),
  balance_reported_at    timestamptz,
  low_balance_threshold  numeric(24,0) CHECK (low_balance_threshold >= 0),
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  row_version            integer NOT NULL DEFAULT 1,
  UNIQUE (provider, sender_line),
  CHECK (multi_part_chars <= single_part_chars),
  CHECK ((reported_balance IS NULL) = (balance_reported_at IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS sms_one_primary ON platform.sms_provider_account ((true)) WHERE role = 'primary' AND status = 'active';
SELECT platform.add_touch('platform.sms_provider_account');

CREATE TABLE IF NOT EXISTS platform.sms_template (
  key         text PRIMARY KEY CHECK (key ~ '^hk-[a-z0-9-]{2,40}$'),
  purpose     text NOT NULL CHECK (purpose IN ('otp','transactional','billing','marketing')),
  body_fa     text NOT NULL CHECK (char_length(body_fa) BETWEEN 1 AND 1000),
  variables   text[] NOT NULL DEFAULT '{}',
  status      text NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired')),
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- هر {متغیر} متن باید اعلام شده باشد و هر متغیر اعلام‌شده در متن بیاید (همان قاعدهٔ رندر core: فقط {var})
CREATE OR REPLACE FUNCTION platform.sms_template_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_used text[];
BEGIN
  SELECT coalesce(array_agg(DISTINCT m[1]), '{}') INTO v_used FROM regexp_matches(NEW.body_fa, '\{([a-z][a-z0-9_]{0,30})\}', 'g') m;
  IF NOT (v_used <@ NEW.variables AND NEW.variables <@ v_used) THEN
    PERFORM platform.fail('HK_PLT_SMS_TEMPLATE_VARS', 'template variables must match the {placeholders} of the body');
  END IF;
  IF TG_OP = 'UPDATE' AND (NEW.key <> OLD.key OR NEW.purpose <> OLD.purpose) THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'template key and purpose are immutable');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.sms_template;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON platform.sms_template FOR EACH ROW EXECUTE FUNCTION platform.sms_template_guard();

CREATE TABLE IF NOT EXISTS platform.sms_template_code (
  template_key         text NOT NULL REFERENCES platform.sms_template(key),
  provider_account_id  uuid NOT NULL REFERENCES platform.sms_provider_account(id),
  provider_code        text NOT NULL CHECK (char_length(provider_code) BETWEEN 1 AND 64),   -- template / bodyId / TemplateId / pattern_code
  approval_status      text NOT NULL DEFAULT 'pending' CHECK (approval_status IN ('pending','approved','rejected')),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (template_key, provider_account_id)
);

-- =====================================================================
-- ۱۱. حساب صورتحساب، اشتراک، صورتحساب و سطر آن
-- =====================================================================
CREATE TABLE IF NOT EXISTS platform.billing_account (
  id              uuid PRIMARY KEY DEFAULT uuidv7(),
  owner_kind      text NOT NULL CHECK (owner_kind IN ('tenant','reseller')),
  tenant_id       uuid UNIQUE REFERENCES platform.tenant(id),
  reseller_id     uuid UNIQUE REFERENCES platform.reseller(id),
  buyer_type      text NOT NULL CHECK (buyer_type IN ('natural','legal','unregistered')),  -- unregistered ← صورتحساب نوع ۲
  legal_name      text NOT NULL,
  national_id     text,
  economic_code   text CHECK (economic_code ~ '^[0-9]{11,14}$'),
  postal_code     text CHECK (postal_code ~ '^[0-9]{10}$'),
  address         text,
  province_code   text REFERENCES platform.geo_province(code),
  billing_mobile  text NOT NULL CHECK (billing_mobile ~ '^09[0-9]{9}$'),
  billing_email   text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  row_version     integer NOT NULL DEFAULT 1,
  CHECK ((owner_kind = 'tenant') = (tenant_id IS NOT NULL AND reseller_id IS NULL)),
  CHECK ((owner_kind = 'reseller') = (reseller_id IS NOT NULL AND tenant_id IS NULL)),
  CONSTRAINT billing_buyer_identity CHECK (
       buyer_type = 'unregistered'
    OR buyer_type = 'natural' AND national_id ~ '^[0-9]{10}$'
    OR buyer_type = 'legal'   AND national_id ~ '^[0-9]{11}$')
);
SELECT platform.add_touch('platform.billing_account');

CREATE TABLE IF NOT EXISTS platform.subscription (
  id                      uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id               uuid NOT NULL REFERENCES platform.tenant(id),
  billing_account_id      uuid NOT NULL REFERENCES platform.billing_account(id),
  plan_version_id         uuid NOT NULL REFERENCES platform.product_version(id),   -- grandfathering: نسخهٔ منتشرشدهٔ زمان خرید
  billing_period          text NOT NULL CHECK (billing_period IN ('P1M','P3M','P6M','P1Y','P2Y')),
  status                  text NOT NULL DEFAULT 'trialing' CHECK (status IN ('trialing','active','cancelled')),
  trial_ends_on           date,
  covered_through         date,                           -- مشتق: پایان آخرین دورهٔ فعال (فقط از تریگر دوره)
  cancel_at_period_end    boolean NOT NULL DEFAULT false,
  auto_renew_from_wallet  boolean NOT NULL DEFAULT false,
  next_plan_version_id    uuid REFERENCES platform.product_version(id),  -- تنزل یا تغییر پلن از دورهٔ بعد (NULL = همان)
  next_billing_period     text CHECK (next_billing_period IN ('P1M','P3M','P6M','P1Y','P2Y')),
  reseller_id             uuid REFERENCES platform.reseller(id),   -- انتساب (RLS نماینده و کمیسیون)
  started_at              timestamptz NOT NULL DEFAULT now(),
  cancelled_at            timestamptz,
  cancel_reason           text,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  row_version             integer NOT NULL DEFAULT 1,
  CHECK (status <> 'trialing' OR trial_ends_on IS NOT NULL),
  CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS subscription_one_live ON platform.subscription (tenant_id) WHERE status <> 'cancelled';
SELECT platform.add_touch('platform.subscription');

CREATE OR REPLACE FUNCTION platform.subscription_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_ok boolean;
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE', 'subscriptions are cancelled, never deleted');
  END IF;
  IF TG_OP = 'INSERT' OR NEW.plan_version_id IS DISTINCT FROM OLD.plan_version_id THEN
    SELECT p.kind = 'plan' AND pv.status = 'published' AND pv.available_from <= current_date
           AND (pv.available_to IS NULL OR pv.available_to > current_date)
      INTO v_ok
      FROM platform.product_version pv JOIN platform.product p ON p.code = pv.product_code WHERE pv.id = NEW.plan_version_id;
    IF NOT coalesce(v_ok, false) THEN
      PERFORM platform.fail('HK_PLT_PLAN_NOT_AVAILABLE', 'subscription needs a published, currently available plan version');
    END IF;
  END IF;
  -- پلن دورهٔ بعد: منتشرشده و در دسترس در آغاز دورهٔ بعد (یا امروز اگر هنوز پوششی نیست)
  IF NEW.next_plan_version_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.next_plan_version_id IS DISTINCT FROM OLD.next_plan_version_id) THEN
    SELECT p.kind = 'plan' AND pv.status = 'published'
           AND (pv.available_to IS NULL OR pv.available_to > coalesce(NEW.covered_through, current_date))
      INTO v_ok
      FROM platform.product_version pv JOIN platform.product p ON p.code = pv.product_code WHERE pv.id = NEW.next_plan_version_id;
    IF NOT coalesce(v_ok, false) THEN
      PERFORM platform.fail('HK_PLT_PLAN_NOT_AVAILABLE', 'next plan must be a published plan available at the next period');
    END IF;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status = 'cancelled' OR NEW.covered_through IS NOT NULL THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'subscription starts trialing/active without coverage');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM platform.billing_account b WHERE b.id = NEW.billing_account_id AND b.tenant_id = NEW.tenant_id) THEN
      PERFORM platform.fail('HK_PLT_BILLING_ACCOUNT_MISMATCH', 'billing account belongs to another owner');
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.tenant_id <> OLD.tenant_id OR NEW.billing_account_id <> OLD.billing_account_id OR NEW.started_at <> OLD.started_at THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'subscription owner is immutable');
  END IF;
  IF NEW.covered_through IS DISTINCT FROM OLD.covered_through AND NOT platform.is_nested() THEN
    PERFORM platform.fail('HK_PLT_DERIVED_COLUMN', 'covered_through follows subscription_term');
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
       (OLD.status = 'trialing' AND NEW.status IN ('active','cancelled'))
    OR (OLD.status = 'active'   AND NEW.status = 'cancelled')) THEN
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', format('subscription %s -> %s', OLD.status, NEW.status));
  END IF;
  IF OLD.status = 'cancelled' THEN
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'cancelled subscription is final');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.subscription;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.subscription FOR EACH ROW EXECUTE FUNCTION platform.subscription_guard();

CREATE TABLE IF NOT EXISTS platform.subscription_item (
  id                  uuid PRIMARY KEY DEFAULT uuidv7(),
  subscription_id     uuid NOT NULL REFERENCES platform.subscription(id),
  product_version_id  uuid NOT NULL REFERENCES platform.product_version(id),
  metric_key          text REFERENCES platform.feature(key),   -- برای واحد اضافهٔ پلن (مثلاً limit.users)؛ NULL برای افزونه
  quantity            integer NOT NULL CHECK (quantity > 0),
  valid_from          date NOT NULL,
  valid_to            date,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (valid_to IS NULL OR valid_to > valid_from),
  CONSTRAINT subscription_item_no_overlap EXCLUDE USING gist (
    subscription_id WITH =, product_version_id WITH =, (coalesce(metric_key, '')) WITH =,
    daterange(valid_from, valid_to, '[)') WITH &&)
);

CREATE OR REPLACE FUNCTION platform.subscription_item_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_kind text; v_status text; v_plan uuid; v_mkind text;
BEGIN
  SELECT p.kind, pv.status INTO v_kind, v_status
    FROM platform.product_version pv JOIN platform.product p ON p.code = pv.product_code WHERE pv.id = NEW.product_version_id;
  SELECT plan_version_id INTO v_plan FROM platform.subscription WHERE id = NEW.subscription_id;
  IF TG_OP = 'INSERT' AND v_status <> 'published' THEN
    PERFORM platform.fail('HK_PLT_PLAN_NOT_AVAILABLE', 'items use published product versions');
  END IF;
  IF NEW.metric_key IS NOT NULL THEN
    SELECT kind INTO v_mkind FROM platform.feature WHERE key = NEW.metric_key;
    IF NEW.product_version_id <> v_plan OR v_mkind <> 'limit' THEN
      PERFORM platform.fail('HK_PLT_ITEM_SHAPE', 'metric items are extra limit units of the subscription''s own plan');
    END IF;
  ELSIF v_kind <> 'addon' THEN
    PERFORM platform.fail('HK_PLT_ITEM_SHAPE', 'non-metric items must be addons');
  END IF;
  IF TG_OP = 'UPDATE' AND ((to_jsonb(NEW) - 'valid_to') <> (to_jsonb(OLD) - 'valid_to')) THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'subscription items change only by closing them');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.subscription_item;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON platform.subscription_item FOR EACH ROW EXECUTE FUNCTION platform.subscription_item_guard();

CREATE TABLE IF NOT EXISTS platform.coupon (
  id                   uuid PRIMARY KEY DEFAULT uuidv7(),
  code                 text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9][A-Z0-9_-]{3,31}$'),
  kind                 text NOT NULL CHECK (kind IN ('percent','amount')),
  percent_off          numeric(5,2) CHECK (percent_off > 0 AND percent_off <= 100),
  amount_off           numeric(24,0) CHECK (amount_off > 0),
  duration             text NOT NULL CHECK (duration IN ('once','repeating','forever')),
  duration_periods     smallint CHECK (duration_periods BETWEEN 1 AND 36),
  max_redemptions      integer CHECK (max_redemptions > 0),
  redemptions_count    integer NOT NULL DEFAULT 0 CHECK (redemptions_count >= 0),
  per_tenant_limit     smallint NOT NULL DEFAULT 1 CHECK (per_tenant_limit BETWEEN 1 AND 100),
  valid_from           timestamptz NOT NULL DEFAULT now(),
  valid_to             timestamptz,
  applies_to_products  text[] NOT NULL DEFAULT '{}',          -- خالی = همه
  first_purchase_only  boolean NOT NULL DEFAULT false,
  reseller_id          uuid REFERENCES platform.reseller(id),
  campaign             text,
  status               text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
  created_by           uuid REFERENCES platform.staff(id),
  created_at           timestamptz NOT NULL DEFAULT now(),
  CHECK ((kind = 'percent') = (percent_off IS NOT NULL AND amount_off IS NULL)),
  CHECK ((kind = 'amount') = (amount_off IS NOT NULL AND percent_off IS NULL)),
  CHECK ((duration = 'repeating') = (duration_periods IS NOT NULL)),
  CHECK (valid_to IS NULL OR valid_to > valid_from),
  CONSTRAINT coupon_redemption_cap CHECK (max_redemptions IS NULL OR redemptions_count <= max_redemptions)
);

CREATE OR REPLACE FUNCTION platform.coupon_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.redemptions_count IS DISTINCT FROM OLD.redemptions_count AND NOT platform.is_nested() THEN
    PERFORM platform.fail('HK_PLT_DERIVED_COLUMN', 'redemptions_count follows coupon_redemption');
  END IF;
  IF (to_jsonb(NEW) - 'redemptions_count' - 'status' - 'valid_to') <> (to_jsonb(OLD) - 'redemptions_count' - 'status' - 'valid_to') THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'coupon terms are immutable (disable or end it instead)');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.coupon;
CREATE TRIGGER trg_guard BEFORE UPDATE ON platform.coupon FOR EACH ROW EXECUTE FUNCTION platform.coupon_guard();

CREATE TABLE IF NOT EXISTS platform.invoice (
  id                   uuid PRIMARY KEY DEFAULT uuidv7(),
  kind                 text NOT NULL DEFAULT 'invoice' CHECK (kind IN ('invoice','credit_note')),
  billing_account_id   uuid NOT NULL REFERENCES platform.billing_account(id),
  tenant_id            uuid REFERENCES platform.tenant(id),
  reseller_id          uuid REFERENCES platform.reseller(id),   -- انتساب نماینده (snapshot هنگام صدور) یا خود نمایندهٔ خریدار
  number               text UNIQUE,
  period_key           text CHECK (period_key ~ '^jy:[0-9]{4}$'),   -- سال جلالی صدور (محاسبه در پایتون)
  status               text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','issued','paid','void')),
  original_invoice_id  uuid REFERENCES platform.invoice(id),
  issue_date           date,
  due_date             date,
  currency             char(3) NOT NULL DEFAULT 'IRR' CHECK (currency = 'IRR'),
  subtotal             numeric(24,0) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
  discount_total       numeric(24,0) NOT NULL DEFAULT 0 CHECK (discount_total >= 0),
  vat_total            numeric(24,0) NOT NULL DEFAULT 0 CHECK (vat_total >= 0),
  total                numeric(24,0) NOT NULL DEFAULT 0 CHECK (total >= 0),
  paid_amount          numeric(24,0) NOT NULL DEFAULT 0,
  vat_rule_ref         text,                                  -- مثل ir.tax@1405.2#tax.vat.standard_rate (snapshot نسخهٔ قاعده)
  buyer_snapshot       jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(buyer_snapshot) = 'object'),
  moadian_mode         text NOT NULL DEFAULT 'house_tenant' CHECK (moadian_mode IN ('house_tenant','export_only','not_required')),
  issued_by            uuid REFERENCES platform.staff(id),
  issued_at            timestamptz,
  voided_at            timestamptz,
  void_reason          text,
  void_approval_id     uuid REFERENCES platform.approval_request(id),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  CONSTRAINT invoice_totals CHECK (total = subtotal - discount_total + vat_total AND discount_total <= subtotal),
  CONSTRAINT invoice_paid_range CHECK (paid_amount >= 0 AND paid_amount <= total),
  CONSTRAINT invoice_issued_fields CHECK ((status IN ('issued','paid','void')) = (number IS NOT NULL AND issued_at IS NOT NULL AND issue_date IS NOT NULL AND period_key IS NOT NULL)),
  CONSTRAINT invoice_paid_iff_settled CHECK (status <> 'paid' OR paid_amount = total),
  CONSTRAINT invoice_issued_unpaid CHECK (status <> 'issued' OR kind = 'credit_note' OR paid_amount < total),
  CONSTRAINT invoice_credit_note_ref CHECK ((kind = 'credit_note') = (original_invoice_id IS NOT NULL)),
  CONSTRAINT invoice_credit_note_states CHECK (kind = 'invoice' OR status IN ('draft','issued')),
  CONSTRAINT invoice_void_fields CHECK ((status = 'void') = (voided_at IS NOT NULL AND void_reason IS NOT NULL AND void_approval_id IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS invoice_tenant ON platform.invoice (tenant_id, status);
CREATE INDEX IF NOT EXISTS invoice_reseller ON platform.invoice (reseller_id) WHERE reseller_id IS NOT NULL;
SELECT platform.add_touch('platform.invoice');

CREATE TABLE IF NOT EXISTS platform.invoice_line (
  id                    uuid PRIMARY KEY DEFAULT uuidv7(),
  invoice_id            uuid NOT NULL REFERENCES platform.invoice(id),
  line_no               smallint NOT NULL CHECK (line_no BETWEEN 1 AND 500),
  line_kind             text NOT NULL CHECK (line_kind IN ('subscription','addon','extra_units','usage','service','credit_pack','license','adjustment')),
  product_version_id    uuid REFERENCES platform.product_version(id),
  original_line_id      uuid REFERENCES platform.invoice_line(id),
  description           text NOT NULL,
  sstid                 text CHECK (sstid ~ '^[0-9]{13}$'),
  period_start          date,
  period_end            date,
  quantity              numeric(18,6) NOT NULL CHECK (quantity > 0),
  unit_amount           numeric(24,0) NOT NULL CHECK (unit_amount >= 0),
  amount                numeric(24,0) NOT NULL,
  discount              numeric(24,0) NOT NULL DEFAULT 0 CHECK (discount >= 0),
  coupon_id             uuid REFERENCES platform.coupon(id),
  vat_rate_pct          numeric(7,4) NOT NULL CHECK (vat_rate_pct >= 0 AND vat_rate_pct <= 100),   -- snapshot از موتور قواعد
  vat_amount            numeric(24,0) NOT NULL,
  total                 numeric(24,0) NOT NULL,
  UNIQUE (invoice_id, line_no),
  -- قطع ارقام (D-CMP-14 بخش ۰۷): مبلغ = trunc(مقدار × فی)، مالیات = trunc((مبلغ − تخفیف) × نرخ / ۱۰۰)
  CONSTRAINT invoice_line_amount CHECK (amount = trunc(quantity * unit_amount)),
  CONSTRAINT invoice_line_discount CHECK (discount <= amount),
  CONSTRAINT invoice_line_vat CHECK (vat_amount = trunc((amount - discount) * vat_rate_pct / 100)),
  CONSTRAINT invoice_line_total CHECK (total = amount - discount + vat_amount),
  CHECK (period_end IS NULL OR period_start IS NULL OR period_end > period_start),
  CHECK ((coupon_id IS NOT NULL) <= (discount > 0))
);

-- سطر صورتحساب فقط در پیش‌نویس؛ سطر یادداشت اعتباری به سطر صورتحساب اصلی ارجاع می‌دهد و از آن بیشتر نمی‌شود
CREATE OR REPLACE FUNCTION platform.invoice_line_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  inv platform.invoice%ROWTYPE;
  ol  platform.invoice_line%ROWTYPE;
  r   record;
BEGIN
  r := CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  SELECT * INTO inv FROM platform.invoice WHERE id = r.invoice_id;
  IF inv.status <> 'draft' THEN
    PERFORM platform.fail('HK_PLT_INVOICE_FROZEN', 'lines of an issued invoice are immutable');
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  IF TG_OP = 'UPDATE' AND NEW.invoice_id <> OLD.invoice_id THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'line cannot move between invoices');
  END IF;
  IF inv.kind = 'credit_note' THEN
    SELECT * INTO ol FROM platform.invoice_line WHERE id = NEW.original_line_id;
    IF NOT FOUND OR ol.invoice_id <> inv.original_invoice_id THEN
      PERFORM platform.fail('HK_PLT_CREDIT_NOTE_LINE', 'credit note lines must reference a line of the original invoice');
    END IF;
    IF NEW.total > ol.total - coalesce((SELECT sum(l.total) FROM platform.invoice_line l JOIN platform.invoice i ON i.id = l.invoice_id
                                        WHERE l.original_line_id = ol.id AND l.id <> NEW.id AND i.status <> 'void'), 0) THEN
      PERFORM platform.fail('HK_PLT_CREDIT_EXCEEDS_ORIGINAL', 'credited amount exceeds the original line');
    END IF;
    IF NEW.vat_rate_pct <> ol.vat_rate_pct THEN
      PERFORM platform.fail('HK_PLT_CREDIT_NOTE_LINE', 'credit note line keeps the original VAT rate');
    END IF;
  ELSIF NEW.original_line_id IS NOT NULL THEN
    PERFORM platform.fail('HK_PLT_CREDIT_NOTE_LINE', 'only credit notes reference original lines');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.invoice_line;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.invoice_line FOR EACH ROW EXECUTE FUNCTION platform.invoice_line_guard();

CREATE TABLE IF NOT EXISTS platform.house_sync (
  doc_type        text NOT NULL CHECK (doc_type IN ('invoice','credit_note','payment','refund','payout','commission_batch')),
  doc_id          uuid NOT NULL,
  status          text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','sent','confirmed','failed','not_required')),
  house_tenant_id uuid REFERENCES platform.tenant(id),
  house_ref       text,                                  -- شناسهٔ سند در مستأجر خانه (sales.invoice و ...)
  moadian_status  text CHECK (moadian_status IN ('pending','sent','accepted','rejected','not_applicable')),
  moadian_taxid   text CHECK (moadian_taxid ~ '^[A-Z0-9]{22}$'),
  attempts        integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  last_error      text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (doc_type, doc_id),
  CHECK (status NOT IN ('sent','confirmed') OR house_tenant_id IS NOT NULL),
  CHECK (status <> 'confirmed' OR house_ref IS NOT NULL),
  CHECK (status <> 'failed' OR last_error IS NOT NULL)
);

CREATE OR REPLACE FUNCTION platform.house_sync_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE', 'house sync records are kept');
  END IF;
  IF NEW.doc_type <> OLD.doc_type OR NEW.doc_id <> OLD.doc_id THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'house sync identity is immutable');
  END IF;
  IF OLD.house_ref IS NOT NULL AND NEW.house_ref IS DISTINCT FROM OLD.house_ref THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'house_ref is set once');
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
       (OLD.status = 'pending' AND NEW.status IN ('sent','failed','not_required'))
    OR (OLD.status = 'sent'    AND NEW.status IN ('confirmed','failed'))
    OR (OLD.status = 'failed'  AND NEW.status = 'pending')) THEN
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', format('house sync %s -> %s', OLD.status, NEW.status));
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.house_sync;
CREATE TRIGGER trg_guard BEFORE UPDATE OR DELETE ON platform.house_sync FOR EACH ROW EXECUTE FUNCTION platform.house_sync_guard();

-- =====================================================================
-- ۱۲. کیف پول (دفتر فقط‌افزودنی با seq و ماندهٔ پس از هر ردیف)
-- =====================================================================
CREATE TABLE IF NOT EXISTS platform.wallet (
  id                     uuid PRIMARY KEY DEFAULT uuidv7(),
  owner_kind             text NOT NULL CHECK (owner_kind IN ('tenant','reseller')),
  tenant_id              uuid UNIQUE REFERENCES platform.tenant(id),
  reseller_id            uuid UNIQUE REFERENCES platform.reseller(id),
  currency               char(3) NOT NULL DEFAULT 'IRR' CHECK (currency = 'IRR'),
  balance                numeric(24,0) NOT NULL DEFAULT 0,
  credit_limit           numeric(24,0) NOT NULL DEFAULT 0 CHECK (credit_limit >= 0),
  last_seq               bigint NOT NULL DEFAULT 0 CHECK (last_seq >= 0),
  low_balance_threshold  numeric(24,0) CHECK (low_balance_threshold >= 0),
  status                 text NOT NULL DEFAULT 'active' CHECK (status IN ('active','frozen','closed')),
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  row_version            integer NOT NULL DEFAULT 1,
  CHECK ((owner_kind = 'tenant') = (tenant_id IS NOT NULL AND reseller_id IS NULL)),
  CHECK ((owner_kind = 'reseller') = (reseller_id IS NOT NULL AND tenant_id IS NULL)),
  -- ماندهٔ منفی فقط تا سقف اعتبار مستأجر؛ کیف پول نماینده فقط با «بازپس‌گیری کمیسیون» منفی می‌شود (بدهی به پلتفرم)
  CONSTRAINT wallet_credit_limit CHECK (owner_kind = 'reseller' OR balance >= -credit_limit),
  CHECK (owner_kind = 'tenant' OR credit_limit = 0)
);
SELECT platform.add_touch('platform.wallet');

CREATE OR REPLACE FUNCTION platform.wallet_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE', 'wallets are closed, never deleted');
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.balance <> 0 OR NEW.last_seq <> 0 THEN
      PERFORM platform.fail('HK_PLT_DERIVED_COLUMN', 'wallets start empty');
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.balance IS DISTINCT FROM OLD.balance OR NEW.last_seq IS DISTINCT FROM OLD.last_seq) AND NOT platform.is_nested() THEN
    PERFORM platform.fail('HK_PLT_DERIVED_COLUMN', 'wallet balance changes only through wallet_entry');
  END IF;
  IF NEW.owner_kind <> OLD.owner_kind OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id OR NEW.reseller_id IS DISTINCT FROM OLD.reseller_id THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'wallet owner is immutable');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.wallet;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.wallet FOR EACH ROW EXECUTE FUNCTION platform.wallet_guard();

CREATE OR REPLACE FUNCTION platform.wallet_for(p_owner_kind text, p_owner uuid) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v uuid;
BEGIN
  IF p_owner_kind = 'tenant' THEN
    INSERT INTO platform.wallet (owner_kind, tenant_id) VALUES ('tenant', p_owner) ON CONFLICT (tenant_id) DO NOTHING;
    SELECT id INTO v FROM platform.wallet WHERE tenant_id = p_owner;
  ELSE
    INSERT INTO platform.wallet (owner_kind, reseller_id) VALUES ('reseller', p_owner) ON CONFLICT (reseller_id) DO NOTHING;
    SELECT id INTO v FROM platform.wallet WHERE reseller_id = p_owner;
  END IF;
  RETURN v;
END $$;

CREATE TABLE IF NOT EXISTS platform.gateway_account (
  id                   uuid PRIMARY KEY DEFAULT uuidv7(),
  provider             text NOT NULL CHECK (provider IN ('zarinpal','zibal','vandar','sep','mellat','sadad')),
  role                 text NOT NULL CHECK (role IN ('primary','fallback')),
  priority             smallint NOT NULL DEFAULT 100,
  merchant_secret_ref  text NOT NULL CHECK (merchant_secret_ref ~ '^openbao://[A-Za-z0-9/_.-]+$'),
  callback_base_url    text NOT NULL CHECK (callback_base_url ~ '^https://'),
  api_amount_unit      text NOT NULL CHECK (api_amount_unit IN ('IRR','IRT')),
  status               text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  UNIQUE (provider, merchant_secret_ref)
);
CREATE UNIQUE INDEX IF NOT EXISTS gateway_one_primary ON platform.gateway_account ((true)) WHERE role = 'primary' AND status = 'active';
SELECT platform.add_touch('platform.gateway_account');

CREATE TABLE IF NOT EXISTS platform.payment (
  id                   uuid PRIMARY KEY DEFAULT uuidv7(),
  payer_kind           text NOT NULL CHECK (payer_kind IN ('tenant','reseller')),
  billing_account_id   uuid NOT NULL REFERENCES platform.billing_account(id),
  tenant_id            uuid REFERENCES platform.tenant(id),
  reseller_id          uuid REFERENCES platform.reseller(id),
  purpose              text NOT NULL CHECK (purpose IN ('invoice','wallet_topup')),
  invoice_id           uuid REFERENCES platform.invoice(id),
  wallet_id            uuid REFERENCES platform.wallet(id),
  method               text NOT NULL CHECK (method IN ('gateway','bank_transfer')),
  gateway_account_id   uuid REFERENCES platform.gateway_account(id),
  provider             text CHECK (provider IN ('zarinpal','zibal','vandar','sep','mellat','sadad')),
  order_id             text NOT NULL UNIQUE CHECK (order_id ~ '^[A-Za-z0-9_-]{6,64}$'),
  amount               numeric(24,0) NOT NULL CHECK (amount > 0),                -- ریال
  api_amount           numeric(24,0) NOT NULL CHECK (api_amount > 0),
  api_amount_unit      text NOT NULL CHECK (api_amount_unit IN ('IRR','IRT')),
  state                text NOT NULL DEFAULT 'created'
                       CHECK (state IN ('created','redirected','callback_received','verified','failed','expired',
                                        'reversed','partially_refunded','refunded')),
  provider_ref         text CHECK (char_length(provider_ref) BETWEEN 1 AND 100),
  provider_txn_ref     text CHECK (char_length(provider_txn_ref) BETWEEN 1 AND 64),
  card_masked          text CHECK (card_masked ~ '^[0-9]{6}\*{2,6}[0-9]{4}$'),
  card_hash            bytea CHECK (octet_length(card_hash) = 32),
  verified_amount      numeric(24,0),
  fee_amount           numeric(24,0) CHECK (fee_amount >= 0),
  refunded_amount      numeric(24,0) NOT NULL DEFAULT 0 CHECK (refunded_amount >= 0),
  last_response_code   text CHECK (char_length(last_response_code) <= 32),
  failure_reason       text,
  bank_ref             text,
  late_verification    boolean NOT NULL DEFAULT false,
  expires_at           timestamptz NOT NULL,
  redirected_at        timestamptz,
  callback_at          timestamptz,
  verified_at          timestamptz,
  attempts             integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  next_inquiry_at      timestamptz,
  created_by_staff     uuid REFERENCES platform.staff(id),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  -- کلید یکتا روی (درگاه، شناسهٔ درگاه) برای جلوگیری از اعتبار دوباره (پژوهش ۰۵ §۳-۵)
  CONSTRAINT payment_provider_ref_unique UNIQUE (provider, provider_ref),
  CHECK ((payer_kind = 'tenant') = (tenant_id IS NOT NULL AND reseller_id IS NULL)),
  CHECK ((payer_kind = 'reseller') = (reseller_id IS NOT NULL AND tenant_id IS NULL)),
  CHECK ((purpose = 'invoice') = (invoice_id IS NOT NULL AND wallet_id IS NULL)),
  CHECK ((purpose = 'wallet_topup') = (wallet_id IS NOT NULL AND invoice_id IS NULL)),
  CHECK ((method = 'gateway') = (gateway_account_id IS NOT NULL AND provider IS NOT NULL)),
  CONSTRAINT payment_api_unit CHECK (api_amount_unit = 'IRR' AND api_amount = amount OR api_amount_unit = 'IRT' AND api_amount * 10 = amount),
  CONSTRAINT payment_verified_fields CHECK (state NOT IN ('verified','partially_refunded','refunded') OR
             (verified_amount = amount AND verified_at IS NOT NULL AND (method = 'bank_transfer' OR provider_txn_ref IS NOT NULL))),
  -- کد ۴۸ ملت = Reverse شده: هرگز «پرداخت‌شده» نیست
  CONSTRAINT payment_mellat_48 CHECK (NOT (provider = 'mellat' AND last_response_code = '48' AND state IN ('verified','partially_refunded','refunded'))),
  CONSTRAINT payment_refund_range CHECK (refunded_amount <= coalesce(verified_amount, 0)),
  CHECK (state <> 'refunded' OR refunded_amount = verified_amount),
  CHECK (state <> 'partially_refunded' OR (refunded_amount > 0 AND refunded_amount < verified_amount)),
  CHECK (method <> 'bank_transfer' OR state NOT IN ('verified','partially_refunded','refunded') OR bank_ref IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS payment_pending ON platform.payment (next_inquiry_at) WHERE state IN ('created','redirected','callback_received');
SELECT platform.add_touch('platform.payment');

CREATE TABLE IF NOT EXISTS platform.wallet_entry (
  id                uuid PRIMARY KEY DEFAULT uuidv7(),
  wallet_id         uuid NOT NULL REFERENCES platform.wallet(id),
  seq               bigint NOT NULL CHECK (seq >= 1),
  kind              text NOT NULL CHECK (kind IN ('topup','overpayment','invoice_payment','credit_reservation','reservation_release',
                                                   'refund_out','credit_note','commission','commission_reversal','payout','adjustment')),
  amount            numeric(24,0) NOT NULL CHECK (amount <> 0),
  balance_after     numeric(24,0) NOT NULL,
  payment_id        uuid REFERENCES platform.payment(id),
  invoice_id        uuid REFERENCES platform.invoice(id),
  approval_id       uuid REFERENCES platform.approval_request(id),
  idempotency_key   text NOT NULL CHECK (char_length(idempotency_key) BETWEEN 8 AND 200),
  memo              text,
  created_by_staff  uuid REFERENCES platform.staff(id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (wallet_id, seq),
  UNIQUE (wallet_id, idempotency_key),
  CONSTRAINT wallet_entry_sign CHECK (
       kind IN ('topup','overpayment','reservation_release','credit_note','commission') AND amount > 0
    OR kind IN ('invoice_payment','credit_reservation','refund_out','commission_reversal','payout') AND amount < 0
    OR kind = 'adjustment'),
  CONSTRAINT wallet_entry_refs CHECK (
       (kind IN ('topup','overpayment') AND payment_id IS NOT NULL)
    OR (kind IN ('invoice_payment','credit_note') AND invoice_id IS NOT NULL)
    OR (kind = 'adjustment' AND approval_id IS NOT NULL)
    OR kind IN ('credit_reservation','reservation_release','refund_out','commission','commission_reversal','payout'))
);

CREATE OR REPLACE FUNCTION platform.wallet_entry_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  w platform.wallet%ROWTYPE;
BEGIN
  SELECT * INTO w FROM platform.wallet WHERE id = NEW.wallet_id FOR UPDATE;
  IF w.status = 'closed' OR (w.status = 'frozen' AND NEW.amount < 0) THEN
    PERFORM platform.fail('HK_PLT_WALLET_NOT_ACTIVE', format('wallet is %s', w.status));
  END IF;
  IF NEW.kind = 'adjustment' THEN
    PERFORM platform.consume_approval(NEW.approval_id, 'wallet.manual_adjustment', 'wallet', NEW.wallet_id,
                                      'wallet_entry:' || NEW.id::text);
  END IF;
  NEW.seq := w.last_seq + 1;
  NEW.balance_after := w.balance + NEW.amount;
  NEW.created_at := now();
  IF NEW.balance_after < -w.credit_limit AND NOT (w.owner_kind = 'reseller' AND NEW.kind = 'commission_reversal') THEN
    PERFORM platform.fail('HK_PLT_INSUFFICIENT_BALANCE', format('wallet balance %s + %s below -%s', w.balance, NEW.amount, w.credit_limit));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.wallet_entry;
CREATE TRIGGER trg_guard BEFORE INSERT ON platform.wallet_entry FOR EACH ROW EXECUTE FUNCTION platform.wallet_entry_guard();
SELECT platform.make_append_only('platform.wallet_entry');

CREATE TABLE IF NOT EXISTS platform.invoice_settlement (
  id              uuid PRIMARY KEY DEFAULT uuidv7(),
  invoice_id      uuid NOT NULL REFERENCES platform.invoice(id),
  source_kind     text NOT NULL CHECK (source_kind IN ('payment','wallet')),
  payment_id      uuid REFERENCES platform.payment(id),
  wallet_entry_id uuid REFERENCES platform.wallet_entry(id),
  amount          numeric(24,0) NOT NULL CHECK (amount > 0),
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK ((source_kind = 'payment') = (payment_id IS NOT NULL AND wallet_entry_id IS NULL)),
  CHECK ((source_kind = 'wallet') = (wallet_entry_id IS NOT NULL AND payment_id IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS invoice_settlement_one_per_payment ON platform.invoice_settlement (payment_id) WHERE payment_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS invoice_settlement_one_per_entry ON platform.invoice_settlement (wallet_entry_id) WHERE wallet_entry_id IS NOT NULL;

CREATE OR REPLACE FUNCTION platform.wallet_entry_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE platform.wallet SET balance = NEW.balance_after, last_seq = NEW.seq WHERE id = NEW.wallet_id;
  IF NEW.kind = 'invoice_payment' THEN
    INSERT INTO platform.invoice_settlement (invoice_id, source_kind, wallet_entry_id, amount)
    VALUES (NEW.invoice_id, 'wallet', NEW.id, -NEW.amount);
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_apply ON platform.wallet_entry;
CREATE TRIGGER trg_apply AFTER INSERT ON platform.wallet_entry FOR EACH ROW EXECUTE FUNCTION platform.wallet_entry_apply();

CREATE TABLE IF NOT EXISTS platform.subscription_term (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  subscription_id  uuid NOT NULL REFERENCES platform.subscription(id),
  kind             text NOT NULL CHECK (kind IN ('trial','paid','comp')),
  period_start     date NOT NULL,
  period_end       date NOT NULL,                       -- [start, end)
  invoice_id       uuid REFERENCES platform.invoice(id),
  approval_id      uuid REFERENCES platform.approval_request(id),
  status           text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','active','void')),
  activated_at     timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CHECK (period_end > period_start),
  CHECK ((kind = 'paid') = (invoice_id IS NOT NULL)),
  CHECK ((kind = 'comp') = (approval_id IS NOT NULL)),
  CHECK (status <> 'active' OR activated_at IS NOT NULL),
  -- پیش‌پرداخت: دوره‌های غیرباطل یک اشتراک هم‌پوشانی ندارند
  CONSTRAINT term_no_overlap EXCLUDE USING gist (subscription_id WITH =, daterange(period_start, period_end, '[)') WITH &&)
    WHERE (status <> 'void')
);

CREATE TABLE IF NOT EXISTS platform.trial_claim (
  identity_kind  text NOT NULL CHECK (identity_kind IN ('mobile','national_id')),
  identity_hmac  bytea NOT NULL CHECK (octet_length(identity_hmac) = 32),
  tenant_id      uuid NOT NULL REFERENCES platform.tenant(id),
  claimed_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (identity_kind, identity_hmac)
);
SELECT platform.make_append_only('platform.trial_claim');

CREATE OR REPLACE FUNCTION platform.subscription_term_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  s   platform.subscription%ROWTYPE;
  inv platform.invoice%ROWTYPE;
  v_trial_days smallint;
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE', 'terms are voided, never deleted');
  END IF;
  SELECT * INTO s FROM platform.subscription WHERE id = NEW.subscription_id;
  IF TG_OP = 'INSERT' THEN
    IF s.status = 'cancelled' THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'cancelled subscription takes no terms');
    END IF;
    IF NEW.kind = 'trial' THEN
      SELECT pv.trial_days INTO v_trial_days FROM platform.product_version pv WHERE pv.id = s.plan_version_id;
      IF NOT EXISTS (SELECT 1 FROM platform.trial_claim c WHERE c.tenant_id = s.tenant_id) THEN
        PERFORM platform.fail('HK_PLT_TRIAL_CLAIM_REQUIRED', 'a trial needs a trial claim (one per mobile/national id)');
      END IF;
      IF EXISTS (SELECT 1 FROM platform.subscription_term t JOIN platform.subscription s2 ON s2.id = t.subscription_id
                 WHERE s2.tenant_id = s.tenant_id AND t.kind = 'trial') THEN
        PERFORM platform.fail('HK_PLT_TRIAL_USED', 'tenant already had a trial');
      END IF;
      IF NEW.period_end - NEW.period_start > v_trial_days THEN
        PERFORM platform.fail('HK_PLT_TRIAL_TOO_LONG', format('trial longer than %s days', v_trial_days));
      END IF;
      NEW.status := 'active';
    ELSIF NEW.kind = 'comp' THEN
      PERFORM platform.consume_approval(NEW.approval_id, 'subscription.comp_term', 'subscription', NEW.subscription_id,
                                        'subscription_term:' || NEW.id::text);
      NEW.status := 'active';
    ELSE
      SELECT * INTO inv FROM platform.invoice WHERE id = NEW.invoice_id;
      IF inv.kind <> 'invoice' OR inv.tenant_id IS DISTINCT FROM s.tenant_id OR inv.status = 'void' THEN
        PERFORM platform.fail('HK_PLT_TERM_INVOICE', 'paid term needs a live invoice of the same tenant');
      END IF;
      NEW.status := CASE WHEN inv.status = 'paid' THEN 'active' ELSE 'pending' END;
    END IF;
    NEW.activated_at := CASE WHEN NEW.status = 'active' THEN now() END;
    RETURN NEW;
  END IF;
  IF (to_jsonb(NEW) - 'status' - 'activated_at') <> (to_jsonb(OLD) - 'status' - 'activated_at') THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'term content is immutable');
  END IF;
  IF NEW.status = OLD.status THEN RETURN NEW; END IF;
  IF OLD.status = 'pending' AND NEW.status = 'active' THEN
    IF NOT EXISTS (SELECT 1 FROM platform.invoice WHERE id = NEW.invoice_id AND status = 'paid') THEN
      PERFORM platform.fail('HK_PLT_PREPAID_ONLY', 'a paid term activates only when its invoice is paid');
    END IF;
    NEW.activated_at := now();
  ELSIF OLD.status = 'pending' AND NEW.status = 'void' THEN
    NULL;
  ELSIF OLD.status = 'active' AND NEW.status = 'void' THEN
    IF NEW.kind = 'paid' AND NOT EXISTS (SELECT 1 FROM platform.invoice c WHERE c.original_invoice_id = NEW.invoice_id AND c.status = 'issued') THEN
      PERFORM platform.fail('HK_PLT_TERM_VOID', 'an active paid term is voided only after a credit note');
    END IF;
  ELSE
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', format('term %s -> %s', OLD.status, NEW.status));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.subscription_term;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.subscription_term FOR EACH ROW EXECUTE FUNCTION platform.subscription_term_guard();

-- پس از تغییر دوره: covered_through، تبدیل آزمایشی به فعال، و بازگشت دسترسی مستأجر (همه در همان تراکنش)
CREATE OR REPLACE FUNCTION platform.subscription_term_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  s platform.subscription%ROWTYPE;
  v_status text;
BEGIN
  SELECT * INTO s FROM platform.subscription WHERE id = NEW.subscription_id FOR UPDATE;
  UPDATE platform.subscription
     SET covered_through = (SELECT max(t.period_end) FROM platform.subscription_term t
                             WHERE t.subscription_id = s.id AND t.status = 'active'),
         status = CASE WHEN s.status = 'trialing' AND NEW.kind IN ('paid','comp') AND NEW.status = 'active' THEN 'active' ELSE s.status END
   WHERE id = s.id;
  IF NEW.status = 'active' AND NEW.kind IN ('paid','comp') AND NEW.period_start <= current_date AND NEW.period_end > current_date THEN
    SELECT status INTO v_status FROM platform.tenant WHERE id = s.tenant_id;
    IF v_status IN ('trial','past_due','read_only','cancelled') THEN
      INSERT INTO platform.tenant_lifecycle_event (tenant_id, seq, to_status, actor_kind, reason_code)
      VALUES (s.tenant_id, 0, 'active', 'system', 'payment_received');
    END IF;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_apply ON platform.subscription_term;
CREATE TRIGGER trg_apply AFTER INSERT OR UPDATE ON platform.subscription_term FOR EACH ROW EXECUTE FUNCTION platform.subscription_term_apply();

-- صورتحساب: صدور (شماره در همان تراکنش، جمع‌ها = سطرها)، تغییرناپذیری پس از صدور، ابطال با تأیید دونفره
CREATE OR REPLACE FUNCTION platform.invoice_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_sub numeric; v_disc numeric; v_vat numeric; v_tot numeric; v_cnt int;
  orig platform.invoice%ROWTYPE;
  k text;
  v_allowed text[] := ARRAY['status','paid_amount','voided_at','void_reason','void_approval_id','updated_at','row_version'];
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN
      PERFORM platform.fail('HK_PLT_IMMUTABLE', 'only draft invoices can be deleted');
    END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' OR NEW.number IS NOT NULL OR NEW.paid_amount <> 0 THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'invoices start as unnumbered drafts');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM platform.billing_account b WHERE b.id = NEW.billing_account_id
                   AND (b.tenant_id IS NOT DISTINCT FROM NEW.tenant_id) AND (b.owner_kind = 'tenant' OR b.reseller_id = NEW.reseller_id)) THEN
      PERFORM platform.fail('HK_PLT_BILLING_ACCOUNT_MISMATCH', 'billing account does not match invoice owner');
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.paid_amount IS DISTINCT FROM OLD.paid_amount AND NOT platform.is_nested() THEN
    PERFORM platform.fail('HK_PLT_DERIVED_COLUMN', 'paid_amount follows invoice_settlement');
  END IF;
  IF OLD.status <> 'draft' THEN
    FOR k IN SELECT jsonb_object_keys(to_jsonb(NEW)) LOOP
      IF NOT (k = ANY (v_allowed)) AND (to_jsonb(NEW)->k) IS DISTINCT FROM (to_jsonb(OLD)->k) THEN
        PERFORM platform.fail('HK_PLT_INVOICE_FROZEN', format('column %s of an issued invoice is immutable', k));
      END IF;
    END LOOP;
  END IF;
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;
  IF OLD.status = 'draft' AND NEW.status = 'issued' THEN
    SELECT count(*), coalesce(sum(amount), 0), coalesce(sum(discount), 0), coalesce(sum(vat_amount), 0), coalesce(sum(total), 0)
      INTO v_cnt, v_sub, v_disc, v_vat, v_tot FROM platform.invoice_line WHERE invoice_id = NEW.id;
    IF v_cnt = 0 THEN
      PERFORM platform.fail('HK_PLT_INVOICE_EMPTY', 'an invoice needs at least one line');
    END IF;
    IF NEW.subtotal <> v_sub OR NEW.discount_total <> v_disc OR NEW.vat_total <> v_vat OR NEW.total <> v_tot THEN
      PERFORM platform.fail('HK_PLT_INVOICE_TOTALS', 'header totals must equal the sum of lines');
    END IF;
    IF NEW.period_key IS NULL THEN
      PERFORM platform.fail('HK_PLT_INVOICE_PERIOD', 'period_key (Jalali year) is required to number the invoice');
    END IF;
    IF NEW.kind = 'credit_note' THEN
      SELECT * INTO orig FROM platform.invoice WHERE id = NEW.original_invoice_id;
      IF orig.status NOT IN ('issued','paid') OR orig.kind <> 'invoice' OR orig.billing_account_id <> NEW.billing_account_id THEN
        PERFORM platform.fail('HK_PLT_CREDIT_NOTE_ORIGINAL', 'credit note needs an issued invoice of the same billing account');
      END IF;
      IF NEW.total <= 0 THEN
        PERFORM platform.fail('HK_PLT_INVOICE_TOTALS', 'credit note total must be positive');
      END IF;
    END IF;
    NEW.number := platform.number_next(CASE NEW.kind WHEN 'invoice' THEN 'invoice' ELSE 'credit_note' END,
                                       NEW.period_key,
                                       CASE NEW.kind WHEN 'invoice' THEN 'INV-' ELSE 'CN-' END || substr(NEW.period_key, 4) || '-');
    NEW.issued_at := now();
    NEW.issue_date := coalesce(NEW.issue_date, current_date);
    IF NEW.issued_by IS NOT NULL AND NEW.issued_by IS DISTINCT FROM platform.current_staff_id() THEN
      PERFORM platform.fail('HK_PLT_ACTOR_MISMATCH', 'issued_by must be the acting staff member');
    END IF;
    IF NEW.tenant_id IS NOT NULL THEN
      NEW.reseller_id := (SELECT reseller_id FROM platform.tenant WHERE id = NEW.tenant_id);
    END IF;
    NEW.buyer_snapshot := (SELECT to_jsonb(b) - 'created_at' - 'updated_at' - 'row_version' FROM platform.billing_account b WHERE b.id = NEW.billing_account_id);
    IF NEW.kind = 'invoice' AND NEW.total = 0 THEN
      NEW.status := 'paid';
    END IF;
  ELSIF OLD.status = 'issued' AND NEW.status = 'paid' THEN
    IF NOT platform.is_nested() THEN
      PERFORM platform.fail('HK_PLT_DERIVED_COLUMN', 'invoices become paid only through settlement');
    END IF;
  ELSIF OLD.status = 'issued' AND NEW.status = 'void' THEN
    IF NEW.kind <> 'invoice' OR OLD.paid_amount <> 0 THEN
      PERFORM platform.fail('HK_PLT_INVOICE_VOID', 'only unpaid invoices can be voided; use a credit note');
    END IF;
    PERFORM platform.consume_approval(NEW.void_approval_id, 'invoice.void', 'invoice', NEW.id, 'invoice_void:' || NEW.id::text);
    NEW.voided_at := now();
  ELSE
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', format('invoice %s -> %s', OLD.status, NEW.status));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.invoice;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.invoice FOR EACH ROW EXECUTE FUNCTION platform.invoice_guard();

CREATE OR REPLACE FUNCTION platform.invoice_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_house uuid;
  v_wallet uuid;
BEGIN
  IF OLD.status = 'draft' AND NEW.status IN ('issued','paid') THEN
    -- همگام‌سازی با مستأجر خانه (صدور صورتحساب الکترونیکی مؤدیان با حافظهٔ صاحب پلتفرم)
    SELECT id INTO v_house FROM platform.tenant WHERE is_house;
    INSERT INTO platform.house_sync (doc_type, doc_id, status, house_tenant_id)
    VALUES (CASE NEW.kind WHEN 'invoice' THEN 'invoice' ELSE 'credit_note' END, NEW.id,
            CASE WHEN NEW.moadian_mode = 'house_tenant' THEN 'pending' ELSE 'not_required' END, v_house);
    IF NEW.moadian_mode = 'house_tenant' THEN
      PERFORM platform.enqueue('billing.house_sync', 'house_sync', jsonb_build_object('doc_id', NEW.id), 'house:' || NEW.id::text);
    END IF;
    -- یادداشت اعتباری: مبلغ به کیف پول مشتری برمی‌گردد (بازپرداخت بانکی بعداً از کیف پول)
    IF NEW.kind = 'credit_note' THEN
      v_wallet := CASE WHEN NEW.tenant_id IS NOT NULL THEN platform.wallet_for('tenant', NEW.tenant_id)
                       ELSE platform.wallet_for('reseller', NEW.reseller_id) END;
      INSERT INTO platform.wallet_entry (wallet_id, seq, kind, amount, balance_after, invoice_id, idempotency_key, memo)
      VALUES (v_wallet, 0, 'credit_note', NEW.total, 0, NEW.id, 'credit_note:' || NEW.id::text, NEW.number);
    END IF;
  END IF;
  IF NEW.status = 'paid' AND OLD.status <> 'paid' THEN
    UPDATE platform.subscription_term SET status = 'active' WHERE invoice_id = NEW.id AND status = 'pending';
  END IF;
  IF OLD.status = 'issued' AND NEW.status = 'void' THEN
    UPDATE platform.subscription_term SET status = 'void' WHERE invoice_id = NEW.id AND status = 'pending';
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_apply ON platform.invoice;
CREATE TRIGGER trg_apply AFTER UPDATE ON platform.invoice FOR EACH ROW EXECUTE FUNCTION platform.invoice_apply();

CREATE OR REPLACE FUNCTION platform.invoice_settlement_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  inv platform.invoice%ROWTYPE;
BEGIN
  SELECT * INTO inv FROM platform.invoice WHERE id = NEW.invoice_id FOR UPDATE;
  IF inv.status <> 'issued' OR inv.kind <> 'invoice' THEN
    PERFORM platform.fail('HK_PLT_SETTLEMENT_STATE', format('cannot settle a %s %s', inv.status, inv.kind));
  END IF;
  IF inv.paid_amount + NEW.amount > inv.total THEN
    PERFORM platform.fail('HK_PLT_OVERPAYMENT', 'settlement exceeds the outstanding amount');
  END IF;
  UPDATE platform.invoice
     SET paid_amount = inv.paid_amount + NEW.amount,
         status = CASE WHEN inv.paid_amount + NEW.amount = inv.total THEN 'paid' ELSE 'issued' END
   WHERE id = inv.id;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_apply ON platform.invoice_settlement;
CREATE TRIGGER trg_apply AFTER INSERT ON platform.invoice_settlement FOR EACH ROW EXECUTE FUNCTION platform.invoice_settlement_apply();
SELECT platform.make_append_only('platform.invoice_settlement');

-- پرداخت: ماشین حالت (پژوهش ۰۵ §۳-۵)؛ «تأییدشده» در همان تراکنش تسویه یا کیف پول می‌سازد
CREATE OR REPLACE FUNCTION platform.payment_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  inv platform.invoice%ROWTYPE;
  ok boolean;
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE', 'payments are never deleted');
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.state <> 'created' OR NEW.refunded_amount <> 0 OR NEW.verified_amount IS NOT NULL THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'payments start as created');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM platform.billing_account b WHERE b.id = NEW.billing_account_id
                   AND b.tenant_id IS NOT DISTINCT FROM NEW.tenant_id AND b.reseller_id IS NOT DISTINCT FROM NEW.reseller_id) THEN
      PERFORM platform.fail('HK_PLT_BILLING_ACCOUNT_MISMATCH', 'billing account does not belong to payer');
    END IF;
    IF NEW.purpose = 'invoice' THEN
      SELECT * INTO inv FROM platform.invoice WHERE id = NEW.invoice_id;
      IF inv.status <> 'issued' OR inv.kind <> 'invoice' OR inv.billing_account_id <> NEW.billing_account_id THEN
        PERFORM platform.fail('HK_PLT_PAYMENT_TARGET', 'payment needs an issued, unpaid invoice of the payer');
      END IF;
      IF NEW.amount <> inv.total - inv.paid_amount THEN
        PERFORM platform.fail('HK_PLT_PAYMENT_AMOUNT', 'payment amount must equal the outstanding amount');
      END IF;
    ELSIF NOT EXISTS (SELECT 1 FROM platform.wallet w WHERE w.id = NEW.wallet_id
                      AND w.tenant_id IS NOT DISTINCT FROM NEW.tenant_id AND w.reseller_id IS NOT DISTINCT FROM NEW.reseller_id) THEN
      PERFORM platform.fail('HK_PLT_PAYMENT_TARGET', 'top-up wallet does not belong to payer');
    END IF;
    IF NEW.method = 'gateway' AND NOT EXISTS (SELECT 1 FROM platform.gateway_account g WHERE g.id = NEW.gateway_account_id
                                              AND g.provider = NEW.provider AND g.status = 'active' AND g.api_amount_unit = NEW.api_amount_unit) THEN
      PERFORM platform.fail('HK_PLT_GATEWAY_MISMATCH', 'gateway account/provider/unit mismatch or disabled');
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.payer_kind <> OLD.payer_kind OR NEW.billing_account_id <> OLD.billing_account_id OR NEW.purpose <> OLD.purpose
     OR NEW.invoice_id IS DISTINCT FROM OLD.invoice_id OR NEW.wallet_id IS DISTINCT FROM OLD.wallet_id
     OR NEW.method <> OLD.method OR NEW.gateway_account_id IS DISTINCT FROM OLD.gateway_account_id
     OR NEW.provider IS DISTINCT FROM OLD.provider OR NEW.order_id <> OLD.order_id OR NEW.amount <> OLD.amount
     OR NEW.api_amount <> OLD.api_amount OR NEW.created_at <> OLD.created_at THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'payment identity and amount are immutable');
  END IF;
  IF OLD.provider_ref IS NOT NULL AND NEW.provider_ref IS DISTINCT FROM OLD.provider_ref THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'provider_ref is set once');
  END IF;
  IF OLD.provider_txn_ref IS NOT NULL AND NEW.provider_txn_ref IS DISTINCT FROM OLD.provider_txn_ref THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'provider_txn_ref is set once');
  END IF;
  IF NEW.refunded_amount IS DISTINCT FROM OLD.refunded_amount AND NOT platform.is_nested() THEN
    PERFORM platform.fail('HK_PLT_DERIVED_COLUMN', 'refunded_amount follows platform.refund');
  END IF;
  IF NEW.state = OLD.state THEN RETURN NEW; END IF;
  ok := (OLD.state = 'created'           AND NEW.state IN ('redirected','failed','expired'))
     OR (OLD.state = 'created'           AND NEW.state = 'verified' AND NEW.method = 'bank_transfer')
     OR (OLD.state = 'redirected'        AND NEW.state IN ('callback_received','verified','failed','expired','reversed'))
     OR (OLD.state = 'callback_received' AND NEW.state IN ('verified','failed','reversed','expired'))
     OR (OLD.state IN ('failed','expired') AND NEW.state = 'verified' AND NEW.late_verification)
     OR (OLD.state IN ('verified','partially_refunded') AND NEW.state IN ('partially_refunded','refunded') AND platform.is_nested());
  IF NOT ok THEN
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', format('payment %s -> %s', OLD.state, NEW.state));
  END IF;
  IF NEW.state = 'verified' THEN
    IF NEW.verified_amount IS DISTINCT FROM NEW.amount THEN
      PERFORM platform.fail('HK_PLT_AMOUNT_MISMATCH', 'verified amount differs from the requested amount (reverse it)');
    END IF;
    IF NEW.method = 'bank_transfer' AND (platform.current_staff_id() IS NULL
         OR NOT platform.staff_has_permission(platform.current_staff_id(), 'platform.billing.payment.record')) THEN
      PERFORM platform.fail('HK_PLT_PERMISSION', 'bank transfers are recorded by finance staff');
    END IF;
    NEW.verified_at := now();
  END IF;
  IF NEW.state = 'redirected' THEN NEW.redirected_at := now(); END IF;
  IF NEW.state = 'callback_received' THEN NEW.callback_at := now(); END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.payment;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.payment FOR EACH ROW EXECUTE FUNCTION platform.payment_guard();

CREATE OR REPLACE FUNCTION platform.payment_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  inv platform.invoice%ROWTYPE;
  v_out numeric;
  v_settle numeric := 0;
  v_wallet uuid;
BEGIN
  IF NEW.state = 'verified' AND OLD.state <> 'verified' THEN
    IF NEW.purpose = 'invoice' THEN
      SELECT * INTO inv FROM platform.invoice WHERE id = NEW.invoice_id FOR UPDATE;
      v_out := CASE WHEN inv.status = 'issued' THEN inv.total - inv.paid_amount ELSE 0 END;
      v_settle := least(v_out, NEW.amount);
      IF v_settle > 0 THEN
        INSERT INTO platform.invoice_settlement (invoice_id, source_kind, payment_id, amount)
        VALUES (inv.id, 'payment', NEW.id, v_settle);
      END IF;
      -- پول تأییدشده هرگز گم نمی‌شود: مازاد (صورتحساب قبلاً پرداخت یا باطل شده) به کیف پول پرداخت‌کننده می‌رود
      IF NEW.amount > v_settle THEN
        v_wallet := CASE WHEN NEW.payer_kind = 'tenant' THEN platform.wallet_for('tenant', NEW.tenant_id)
                         ELSE platform.wallet_for('reseller', NEW.reseller_id) END;
        INSERT INTO platform.wallet_entry (wallet_id, seq, kind, amount, balance_after, payment_id, idempotency_key)
        VALUES (v_wallet, 0, 'overpayment', NEW.amount - v_settle, 0, NEW.id, 'payment:' || NEW.id::text);
      END IF;
    ELSE
      INSERT INTO platform.wallet_entry (wallet_id, seq, kind, amount, balance_after, payment_id, idempotency_key)
      VALUES (NEW.wallet_id, 0, 'topup', NEW.amount, 0, NEW.id, 'payment:' || NEW.id::text);
    END IF;
    PERFORM platform.enqueue('billing.house_sync', 'house_sync', jsonb_build_object('payment_id', NEW.id), 'house-pay:' || NEW.id::text);
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_apply ON platform.payment;
CREATE TRIGGER trg_apply AFTER UPDATE ON platform.payment FOR EACH ROW EXECUTE FUNCTION platform.payment_apply();

CREATE TABLE IF NOT EXISTS platform.payment_event (
  id             uuid PRIMARY KEY DEFAULT uuidv7(),
  payment_id     uuid NOT NULL REFERENCES platform.payment(id),
  kind           text NOT NULL CHECK (kind IN ('request','redirect','callback','verify','settle','inquiry','reverse','refund','note')),
  response_code  text,
  outcome        text CHECK (outcome IN ('success','duplicate_success','failed','reversed','pending','error')),
  detail         jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(detail) = 'object'),   -- بدون راز و PAN کامل (INV-SEC-02)
  occurred_at    timestamptz NOT NULL DEFAULT now()
);
SELECT platform.make_append_only('platform.payment_event');

CREATE TABLE IF NOT EXISTS platform.refund (
  id                uuid PRIMARY KEY DEFAULT uuidv7(),
  wallet_id         uuid NOT NULL REFERENCES platform.wallet(id),       -- منبع وجه: همیشه کیف پول (یادداشت اعتباری یا مازاد آن را پر کرده)
  payment_id        uuid REFERENCES platform.payment(id),               -- برای بازپرداخت از راه درگاه
  amount            numeric(24,0) NOT NULL CHECK (amount > 0),
  method            text NOT NULL CHECK (method IN ('gateway_refund','paya','card')),
  destination_sheba text CHECK (destination_sheba ~ '^IR[0-9]{24}$'),
  status            text NOT NULL DEFAULT 'requested' CHECK (status IN ('requested','approved','completed','failed','cancelled')),
  approval_id       uuid REFERENCES platform.approval_request(id),
  requested_by      uuid NOT NULL REFERENCES platform.staff(id),
  bank_ref          text,
  completed_at      timestamptz,
  failure_reason    text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  row_version       integer NOT NULL DEFAULT 1,
  CHECK ((method = 'gateway_refund') = (payment_id IS NOT NULL)),
  CHECK (method <> 'paya' OR destination_sheba IS NOT NULL),
  CONSTRAINT refund_approved_fields CHECK (status NOT IN ('approved','completed') OR approval_id IS NOT NULL),
  CHECK ((status = 'completed') = (completed_at IS NOT NULL AND bank_ref IS NOT NULL)),
  CHECK (status <> 'failed' OR failure_reason IS NOT NULL)
);
SELECT platform.add_touch('platform.refund');

CREATE OR REPLACE FUNCTION platform.refund_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  p platform.payment%ROWTYPE;
  w platform.wallet%ROWTYPE;
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE', 'refunds are cancelled, never deleted');
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'requested' THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'refunds start as requested');
    END IF;
    IF NEW.requested_by IS DISTINCT FROM platform.current_staff_id() THEN
      PERFORM platform.fail('HK_PLT_ACTOR_MISMATCH', 'requested_by must be the acting staff member');
    END IF;
    IF NEW.payment_id IS NOT NULL THEN
      SELECT * INTO p FROM platform.payment WHERE id = NEW.payment_id;
      SELECT * INTO w FROM platform.wallet WHERE id = NEW.wallet_id;
      IF p.state NOT IN ('verified','partially_refunded') OR p.tenant_id IS DISTINCT FROM w.tenant_id OR p.reseller_id IS DISTINCT FROM w.reseller_id THEN
        PERFORM platform.fail('HK_PLT_REFUND_SOURCE', 'gateway refund needs a verified payment of the wallet owner');
      END IF;
      IF NEW.amount > p.verified_amount - p.refunded_amount - coalesce((SELECT sum(r.amount) FROM platform.refund r
             WHERE r.payment_id = p.id AND r.status IN ('requested','approved')), 0) THEN
        PERFORM platform.fail('HK_PLT_REFUND_EXCEEDS', 'refund exceeds the refundable amount of the payment');
      END IF;
    END IF;
    RETURN NEW;
  END IF;
  IF (to_jsonb(NEW) - 'status' - 'approval_id' - 'bank_ref' - 'completed_at' - 'failure_reason' - 'updated_at' - 'row_version')
     <> (to_jsonb(OLD) - 'status' - 'approval_id' - 'bank_ref' - 'completed_at' - 'failure_reason' - 'updated_at' - 'row_version') THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'refund content is immutable');
  END IF;
  IF NEW.status = OLD.status THEN RETURN NEW; END IF;
  IF OLD.status = 'requested' AND NEW.status = 'approved' THEN
    PERFORM platform.consume_approval(NEW.approval_id, 'refund.execute', 'refund', NEW.id, 'refund:' || NEW.id::text);
  ELSIF OLD.status = 'approved' AND NEW.status IN ('completed','failed') THEN
    IF NEW.status = 'completed' THEN
      NEW.completed_at := now();
    END IF;
  ELSIF OLD.status IN ('requested','approved') AND NEW.status = 'cancelled' THEN
    NULL;
  ELSE
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', format('refund %s -> %s', OLD.status, NEW.status));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.refund;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.refund FOR EACH ROW EXECUTE FUNCTION platform.refund_guard();

CREATE OR REPLACE FUNCTION platform.refund_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  p platform.payment%ROWTYPE;
BEGIN
  IF NEW.status = 'completed' AND OLD.status <> 'completed' THEN
    INSERT INTO platform.wallet_entry (wallet_id, seq, kind, amount, balance_after, payment_id, idempotency_key, memo)
    VALUES (NEW.wallet_id, 0, 'refund_out', -NEW.amount, 0, NEW.payment_id, 'refund:' || NEW.id::text, NEW.bank_ref);
    IF NEW.payment_id IS NOT NULL THEN
      SELECT * INTO p FROM platform.payment WHERE id = NEW.payment_id FOR UPDATE;
      IF p.refunded_amount + NEW.amount > p.verified_amount THEN
        PERFORM platform.fail('HK_PLT_REFUND_EXCEEDS', 'refund exceeds the verified amount');
      END IF;
      UPDATE platform.payment
         SET refunded_amount = p.refunded_amount + NEW.amount,
             state = CASE WHEN p.refunded_amount + NEW.amount = p.verified_amount THEN 'refunded' ELSE 'partially_refunded' END
       WHERE id = p.id;
    END IF;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_apply ON platform.refund;
CREATE TRIGGER trg_apply AFTER UPDATE ON platform.refund FOR EACH ROW EXECUTE FUNCTION platform.refund_apply();

CREATE TABLE IF NOT EXISTS platform.reconciliation_item (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  run_date         date NOT NULL,
  provider         text NOT NULL,
  kind             text NOT NULL CHECK (kind IN ('pending_unverified','amount_mismatch','missing_in_gateway','missing_in_platform',
                                                 'late_success','settlement_mismatch')),
  payment_id       uuid REFERENCES platform.payment(id),
  provider_ref     text,
  expected_amount  numeric(24,0),
  observed_amount  numeric(24,0),
  status           text NOT NULL DEFAULT 'open' CHECK (status IN ('open','resolved','ignored')),
  resolution       text,
  resolved_by      uuid REFERENCES platform.staff(id),
  resolved_at      timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CHECK (payment_id IS NOT NULL OR provider_ref IS NOT NULL),
  CHECK ((status = 'open') = (resolved_at IS NULL)),
  CHECK (status = 'open' OR (resolved_by IS NOT NULL AND char_length(btrim(coalesce(resolution, ''))) >= 5))
);
CREATE UNIQUE INDEX IF NOT EXISTS reconciliation_item_once ON platform.reconciliation_item
  (run_date, provider, kind, coalesce(payment_id::text, provider_ref));

-- رزرو اعتبار خدمات مصرفی از کیف پول (پیامک خط پلتفرم، استعلام)؛ سلول فقط تا سقف تجمعی رزروشده مصرف می‌کند
CREATE TABLE IF NOT EXISTS platform.credit_reservation (
  id                uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id         uuid NOT NULL REFERENCES platform.tenant(id),
  service_key       text NOT NULL REFERENCES platform.feature(key),
  seq               integer NOT NULL CHECK (seq >= 1),
  kind              text NOT NULL CHECK (kind IN ('reserve','release')),
  units             bigint NOT NULL CHECK (units > 0),
  unit_amount       numeric(24,0) NOT NULL CHECK (unit_amount >= 0),
  cumulative_units  bigint NOT NULL CHECK (cumulative_units >= 0),
  wallet_entry_id   uuid UNIQUE REFERENCES platform.wallet_entry(id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, service_key, seq)
);

CREATE OR REPLACE FUNCTION platform.credit_reservation_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_prev bigint;
  v_used numeric;
  v_tariff numeric;
  v_wallet uuid;
  v_entry uuid;
BEGIN
  IF (SELECT kind FROM platform.feature WHERE key = NEW.service_key) <> 'meter' THEN
    PERFORM platform.fail('HK_PLT_RESERVATION_SHAPE', 'credit reservations are for meter features');
  END IF;
  v_wallet := platform.wallet_for('tenant', NEW.tenant_id);
  PERFORM 1 FROM platform.wallet WHERE id = v_wallet FOR UPDATE;
  SELECT coalesce(max(cumulative_units), 0), coalesce(max(seq), 0) + 1 INTO v_prev, NEW.seq
    FROM platform.credit_reservation WHERE tenant_id = NEW.tenant_id AND service_key = NEW.service_key;
  IF NEW.kind = 'reserve' THEN
    v_tariff := platform.tariff_at(NEW.service_key, now());
    IF v_tariff IS NULL OR NEW.unit_amount <> v_tariff THEN
      PERFORM platform.fail('HK_PLT_TARIFF_MISMATCH', 'reservation unit price must equal the current tariff');
    END IF;
    NEW.cumulative_units := v_prev + NEW.units;
  ELSE
    v_used := coalesce((SELECT sum(quantity) FROM platform.usage_daily WHERE tenant_id = NEW.tenant_id AND metric = NEW.service_key), 0);
    IF NEW.units > v_prev - v_used THEN
      PERFORM platform.fail('HK_PLT_RELEASE_EXCEEDS', 'cannot release more than the unused reserved units');
    END IF;
    NEW.cumulative_units := v_prev - NEW.units;
  END IF;
  NEW.id := coalesce(NEW.id, uuidv7());
  INSERT INTO platform.wallet_entry (wallet_id, seq, kind, amount, balance_after, idempotency_key, memo)
  VALUES (v_wallet, 0, CASE NEW.kind WHEN 'reserve' THEN 'credit_reservation' ELSE 'reservation_release' END,
          CASE NEW.kind WHEN 'reserve' THEN -1 ELSE 1 END * NEW.units * NEW.unit_amount, 0,
          'reservation:' || NEW.id::text, NEW.service_key)
  RETURNING id INTO v_entry;
  NEW.wallet_entry_id := v_entry;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.credit_reservation;
CREATE TRIGGER trg_guard BEFORE INSERT ON platform.credit_reservation FOR EACH ROW EXECUTE FUNCTION platform.credit_reservation_guard();
SELECT platform.make_append_only('platform.credit_reservation');

CREATE TABLE IF NOT EXISTS platform.reminder (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  subject_type     text NOT NULL CHECK (subject_type IN ('subscription','license','wallet','invoice')),
  subject_id       uuid NOT NULL,
  tenant_id        uuid REFERENCES platform.tenant(id),
  kind             text NOT NULL CHECK (kind IN ('renewal_7d','renewal_3d','renewal_1d','grace_started','read_only','cancel_warning',
                                                 'low_wallet','license_expiry_30d','license_expiry_7d','support_expiry_30d','invoice_due')),
  anchor_date      date NOT NULL,
  channel          text NOT NULL CHECK (channel IN ('sms','in_app','email')),
  scheduled_for    timestamptz NOT NULL,
  status           text NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled','sent','skipped','failed')),
  sent_at          timestamptz,
  provider_msg_id  text,
  last_error       text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  -- هر یادآور برای هر (موضوع، نوع، تاریخ مرجع، کانال) حداکثر یک بار
  CONSTRAINT reminder_once UNIQUE (subject_type, subject_id, kind, anchor_date, channel),
  CHECK ((status = 'sent') = (sent_at IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS platform.coupon_redemption (
  id                 uuid PRIMARY KEY DEFAULT uuidv7(),
  coupon_id          uuid NOT NULL REFERENCES platform.coupon(id),
  tenant_id          uuid NOT NULL REFERENCES platform.tenant(id),
  invoice_id         uuid NOT NULL REFERENCES platform.invoice(id),
  subscription_id    uuid REFERENCES platform.subscription(id),
  periods_remaining  smallint CHECK (periods_remaining >= 0),
  redeemed_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (coupon_id, invoice_id)
);

CREATE OR REPLACE FUNCTION platform.coupon_redemption_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  c platform.coupon%ROWTYPE;
BEGIN
  SELECT * INTO c FROM platform.coupon WHERE id = NEW.coupon_id FOR UPDATE;
  IF c.status <> 'active' OR now() < c.valid_from OR (c.valid_to IS NOT NULL AND now() >= c.valid_to) THEN
    PERFORM platform.fail('HK_PLT_COUPON_INVALID', 'coupon is not active');
  END IF;
  IF c.max_redemptions IS NOT NULL AND c.redemptions_count >= c.max_redemptions THEN
    PERFORM platform.fail('HK_PLT_COUPON_EXHAUSTED', 'coupon redemption cap reached');
  END IF;
  IF (SELECT count(*) FROM platform.coupon_redemption r WHERE r.coupon_id = c.id AND r.tenant_id = NEW.tenant_id) >= c.per_tenant_limit THEN
    PERFORM platform.fail('HK_PLT_COUPON_PER_TENANT', 'coupon already used by this tenant');
  END IF;
  IF c.reseller_id IS NOT NULL AND c.reseller_id IS DISTINCT FROM (SELECT reseller_id FROM platform.tenant WHERE id = NEW.tenant_id) THEN
    PERFORM platform.fail('HK_PLT_COUPON_INVALID', 'coupon belongs to another reseller');
  END IF;
  IF c.first_purchase_only AND EXISTS (SELECT 1 FROM platform.invoice i WHERE i.tenant_id = NEW.tenant_id AND i.kind = 'invoice'
                                       AND i.status = 'paid' AND i.id <> NEW.invoice_id) THEN
    PERFORM platform.fail('HK_PLT_COUPON_INVALID', 'coupon is for the first purchase only');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM platform.invoice i WHERE i.id = NEW.invoice_id AND i.tenant_id = NEW.tenant_id AND i.status = 'draft') THEN
    PERFORM platform.fail('HK_PLT_COUPON_INVALID', 'coupons apply to draft invoices of the same tenant');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.coupon_redemption;
CREATE TRIGGER trg_guard BEFORE INSERT ON platform.coupon_redemption FOR EACH ROW EXECUTE FUNCTION platform.coupon_redemption_guard();

CREATE OR REPLACE FUNCTION platform.coupon_redemption_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE platform.coupon SET redemptions_count = redemptions_count + 1 WHERE id = NEW.coupon_id;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_apply ON platform.coupon_redemption;
CREATE TRIGGER trg_apply AFTER INSERT ON platform.coupon_redemption FOR EACH ROW EXECUTE FUNCTION platform.coupon_redemption_apply();
SELECT platform.make_append_only('platform.coupon_redemption');

-- =====================================================================
-- ۱۳. پول نماینده: کمیسیون، تسویه، سهمیهٔ لایسنس، سفارش خدمت (نصب، مهاجرت همراه)
-- =====================================================================
-- انتخاب قاعدهٔ کمیسیون: قاعدهٔ اختصاصی نماینده بر قاعدهٔ سطح، و قاعدهٔ محصول‌محور بر قاعدهٔ عمومی مقدم است
CREATE OR REPLACE FUNCTION platform.commission_rule_for(p_reseller uuid, p_event text, p_product text, p_on date) RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT r.id
  FROM platform.commission_rule r
  JOIN platform.reseller s ON s.id = p_reseller
  WHERE r.event = p_event
    AND (r.scope = 'reseller' AND r.reseller_id = s.id OR r.scope = 'tier' AND r.tier_code = s.tier_code)
    AND (r.product_code IS NULL OR r.product_code = p_product)
    AND r.valid_from <= p_on AND (r.valid_to IS NULL OR r.valid_to > p_on)
  ORDER BY (r.scope = 'reseller') DESC, (r.product_code IS NOT NULL) DESC
  LIMIT 1
$$;

CREATE TABLE IF NOT EXISTS platform.commission_entry (
  id                 uuid PRIMARY KEY DEFAULT uuidv7(),
  reseller_id        uuid NOT NULL REFERENCES platform.reseller(id),
  event              text NOT NULL CHECK (event IN ('first_sale','renewal','addon','service','license_new','license_renewal',
                                                    'reversal','adjustment')),
  invoice_id         uuid REFERENCES platform.invoice(id),
  invoice_line_id    uuid REFERENCES platform.invoice_line(id),
  rule_id            uuid REFERENCES platform.commission_rule(id),
  basis_amount       numeric(24,0) CHECK (basis_amount >= 0),
  rate_pct           numeric(5,2),
  amount             numeric(24,0) NOT NULL CHECK (amount <> 0),
  reverses_entry_id  uuid REFERENCES platform.commission_entry(id),
  approval_id        uuid REFERENCES platform.approval_request(id),
  reason             text,
  wallet_entry_id    uuid UNIQUE REFERENCES platform.wallet_entry(id),
  created_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT commission_accrual_shape CHECK (event IN ('reversal','adjustment') OR
             (invoice_line_id IS NOT NULL AND invoice_id IS NOT NULL AND rule_id IS NOT NULL AND basis_amount IS NOT NULL
              AND rate_pct IS NOT NULL AND amount = trunc(basis_amount * rate_pct / 100) AND amount > 0)),
  CONSTRAINT commission_reversal_shape CHECK ((event = 'reversal') = (reverses_entry_id IS NOT NULL)),
  CHECK (event <> 'reversal' OR amount < 0),
  CONSTRAINT commission_adjustment_shape CHECK (event <> 'adjustment' OR (approval_id IS NOT NULL AND char_length(btrim(coalesce(reason, ''))) >= 10))
);
CREATE UNIQUE INDEX IF NOT EXISTS commission_one_accrual_per_line ON platform.commission_entry (invoice_line_id)
  WHERE event NOT IN ('reversal','adjustment');

CREATE OR REPLACE FUNCTION platform.commission_entry_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  inv  platform.invoice%ROWTYPE;
  ln   platform.invoice_line%ROWTYPE;
  orig platform.commission_entry%ROWTYPE;
  v_product text;
  v_wallet uuid;
  v_entry uuid;
BEGIN
  IF NEW.event NOT IN ('reversal','adjustment') THEN
    SELECT * INTO ln FROM platform.invoice_line WHERE id = NEW.invoice_line_id;
    SELECT * INTO inv FROM platform.invoice WHERE id = ln.invoice_id;
    IF inv.id IS DISTINCT FROM NEW.invoice_id OR inv.status <> 'paid' OR inv.kind <> 'invoice' THEN
      PERFORM platform.fail('HK_PLT_COMMISSION_BASIS', 'commission accrues only on lines of paid invoices');
    END IF;
    IF inv.reseller_id IS DISTINCT FROM NEW.reseller_id OR inv.tenant_id IS NULL THEN
      PERFORM platform.fail('HK_PLT_COMMISSION_BASIS', 'invoice is not attributed to this reseller');
    END IF;
    SELECT pv.product_code INTO v_product FROM platform.product_version pv WHERE pv.id = ln.product_version_id;
    IF NEW.rule_id IS DISTINCT FROM platform.commission_rule_for(NEW.reseller_id, NEW.event, v_product, inv.issue_date) THEN
      PERFORM platform.fail('HK_PLT_COMMISSION_RULE', 'rule is not the applicable commission rule for this sale');
    END IF;
    NEW.rate_pct := (SELECT rate_pct FROM platform.commission_rule WHERE id = NEW.rule_id);
    NEW.basis_amount := ln.amount - ln.discount;          -- خالص بدون مالیات بر ارزش افزوده
    NEW.amount := trunc(NEW.basis_amount * NEW.rate_pct / 100);
  ELSIF NEW.event = 'reversal' THEN
    SELECT * INTO orig FROM platform.commission_entry WHERE id = NEW.reverses_entry_id;
    IF orig.event IN ('reversal','adjustment') OR orig.reseller_id <> NEW.reseller_id THEN
      PERFORM platform.fail('HK_PLT_COMMISSION_REVERSAL', 'reversals target an accrual of the same reseller');
    END IF;
    IF -NEW.amount + coalesce((SELECT -sum(c.amount) FROM platform.commission_entry c WHERE c.reverses_entry_id = orig.id), 0) > orig.amount THEN
      PERFORM platform.fail('HK_PLT_COMMISSION_REVERSAL', 'reversals exceed the original commission');
    END IF;
  ELSE
    PERFORM platform.consume_approval(NEW.approval_id, 'commission.adjustment', 'reseller', NEW.reseller_id,
                                      'commission_entry:' || NEW.id::text);
  END IF;
  v_wallet := platform.wallet_for('reseller', NEW.reseller_id);
  INSERT INTO platform.wallet_entry (wallet_id, seq, kind, amount, balance_after, invoice_id, idempotency_key, memo)
  VALUES (v_wallet, 0, CASE WHEN NEW.amount > 0 THEN 'commission' ELSE 'commission_reversal' END, NEW.amount, 0,
          NEW.invoice_id, 'commission:' || NEW.id::text, NEW.event)
  RETURNING id INTO v_entry;
  NEW.wallet_entry_id := v_entry;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.commission_entry;
CREATE TRIGGER trg_guard BEFORE INSERT ON platform.commission_entry FOR EACH ROW EXECUTE FUNCTION platform.commission_entry_guard();
SELECT platform.make_append_only('platform.commission_entry');

CREATE TABLE IF NOT EXISTS platform.payout (
  id                      uuid PRIMARY KEY DEFAULT uuidv7(),
  reseller_id             uuid NOT NULL REFERENCES platform.reseller(id),
  wallet_id               uuid NOT NULL REFERENCES platform.wallet(id),
  amount                  numeric(24,0) NOT NULL CHECK (amount > 0),
  sheba                   text NOT NULL CHECK (sheba ~ '^IR[0-9]{24}$'),
  status                  text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','submitted','approved','paid','failed','cancelled')),
  approval_id             uuid REFERENCES platform.approval_request(id),
  reseller_invoice_taxid  text CHECK (reseller_invoice_taxid ~ '^[A-Z0-9]{22}$'),   -- صورتحساب الکترونیکی نماینده برای کمیسیون
  bank_ref                text,
  paid_at                 timestamptz,
  wallet_entry_id         uuid UNIQUE REFERENCES platform.wallet_entry(id),
  failure_reason          text,
  requested_by_kind       text NOT NULL CHECK (requested_by_kind IN ('reseller_user','staff')),
  requested_by_id         uuid NOT NULL,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  row_version             integer NOT NULL DEFAULT 1,
  CONSTRAINT payout_approved_fields CHECK (status NOT IN ('approved','paid') OR approval_id IS NOT NULL),
  CONSTRAINT payout_paid_fields CHECK ((status = 'paid') = (paid_at IS NOT NULL AND bank_ref IS NOT NULL AND wallet_entry_id IS NOT NULL)),
  CHECK (status <> 'failed' OR failure_reason IS NOT NULL)
);
SELECT platform.add_touch('platform.payout');

CREATE OR REPLACE FUNCTION platform.payout_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  w platform.wallet%ROWTYPE;
  v_entry uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE', 'payouts are cancelled, never deleted');
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'payouts start as draft');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM platform.wallet WHERE id = NEW.wallet_id AND reseller_id = NEW.reseller_id) THEN
      PERFORM platform.fail('HK_PLT_PAYOUT_WALLET', 'payout wallet must be the reseller wallet');
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.status <> 'draft' AND (NEW.amount <> OLD.amount OR NEW.sheba <> OLD.sheba) THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'payout amount and destination freeze when submitted');
  END IF;
  IF NEW.reseller_id <> OLD.reseller_id OR NEW.wallet_id <> OLD.wallet_id THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'payout owner is immutable');
  END IF;
  IF NEW.status = OLD.status THEN RETURN NEW; END IF;
  IF OLD.status = 'draft' AND NEW.status = 'submitted' THEN
    SELECT * INTO w FROM platform.wallet WHERE id = NEW.wallet_id;
    IF NEW.amount > w.balance - coalesce((SELECT sum(p.amount) FROM platform.payout p WHERE p.wallet_id = NEW.wallet_id
                                          AND p.id <> NEW.id AND p.status IN ('submitted','approved')), 0) THEN
      PERFORM platform.fail('HK_PLT_INSUFFICIENT_BALANCE', 'payout exceeds the available commission balance');
    END IF;
  ELSIF OLD.status = 'submitted' AND NEW.status = 'approved' THEN
    PERFORM platform.consume_approval(NEW.approval_id, 'payout.approve', 'payout', NEW.id, 'payout:' || NEW.id::text);
  ELSIF OLD.status = 'approved' AND NEW.status = 'paid' THEN
    IF (SELECT is_taxpayer FROM platform.reseller WHERE id = NEW.reseller_id) AND NEW.reseller_invoice_taxid IS NULL THEN
      PERFORM platform.fail('HK_PLT_PAYOUT_TAX_INVOICE', 'a taxpayer reseller must issue an e-invoice before payment');
    END IF;
    NEW.paid_at := now();
    INSERT INTO platform.wallet_entry (wallet_id, seq, kind, amount, balance_after, idempotency_key, memo)
    VALUES (NEW.wallet_id, 0, 'payout', -NEW.amount, 0, 'payout:' || NEW.id::text, NEW.bank_ref)
    RETURNING id INTO v_entry;
    NEW.wallet_entry_id := v_entry;
  ELSIF OLD.status = 'approved' AND NEW.status = 'failed' THEN
    NULL;
  ELSIF OLD.status IN ('draft','submitted') AND NEW.status = 'cancelled' THEN
    NULL;
  ELSE
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', format('payout %s -> %s', OLD.status, NEW.status));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.payout;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.payout FOR EACH ROW EXECUTE FUNCTION platform.payout_guard();

CREATE TABLE IF NOT EXISTS platform.reseller_quota_entry (
  id             uuid PRIMARY KEY DEFAULT uuidv7(),
  reseller_id    uuid NOT NULL REFERENCES platform.reseller(id),
  product_code   text NOT NULL REFERENCES platform.product(code),
  seq            integer NOT NULL CHECK (seq >= 1),
  kind           text NOT NULL CHECK (kind IN ('purchase','issue','return','adjustment')),
  delta          integer NOT NULL CHECK (delta <> 0),
  balance_after  integer NOT NULL CONSTRAINT quota_non_negative CHECK (balance_after >= 0),
  invoice_id     uuid REFERENCES platform.invoice(id),
  license_id     uuid,                                     -- FK پس از ساخت license
  approval_id    uuid REFERENCES platform.approval_request(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (reseller_id, product_code, seq),
  CHECK (kind IN ('purchase','return') AND delta > 0 OR kind = 'issue' AND delta = -1 OR kind = 'adjustment'),
  CHECK ((kind = 'purchase') = (invoice_id IS NOT NULL)),
  CHECK ((kind IN ('issue','return')) = (license_id IS NOT NULL)),
  CHECK ((kind = 'adjustment') = (approval_id IS NOT NULL))
);

CREATE OR REPLACE FUNCTION platform.quota_entry_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_prev integer;
BEGIN
  PERFORM 1 FROM platform.reseller WHERE id = NEW.reseller_id FOR UPDATE;
  IF (SELECT kind FROM platform.product WHERE code = NEW.product_code) <> 'license' THEN
    PERFORM platform.fail('HK_PLT_QUOTA_SHAPE', 'quota is kept per license product');
  END IF;
  SELECT balance_after, seq INTO v_prev, NEW.seq FROM platform.reseller_quota_entry
   WHERE reseller_id = NEW.reseller_id AND product_code = NEW.product_code ORDER BY seq DESC LIMIT 1;
  NEW.seq := coalesce(NEW.seq, 0) + 1;
  NEW.balance_after := coalesce(v_prev, 0) + NEW.delta;
  IF NEW.balance_after < 0 THEN
    PERFORM platform.fail('HK_PLT_QUOTA_EXHAUSTED', 'reseller has no license quota left');
  END IF;
  IF NEW.kind = 'purchase' AND NOT EXISTS (SELECT 1 FROM platform.invoice i WHERE i.id = NEW.invoice_id AND i.status = 'paid'
                                           AND i.tenant_id IS NULL AND i.reseller_id = NEW.reseller_id) THEN
    PERFORM platform.fail('HK_PLT_QUOTA_SHAPE', 'quota purchase needs a paid invoice of the reseller');
  END IF;
  IF NEW.kind = 'adjustment' THEN
    PERFORM platform.consume_approval(NEW.approval_id, 'reseller.quota_adjustment', 'reseller', NEW.reseller_id,
                                      'quota_entry:' || NEW.id::text);
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.reseller_quota_entry;
CREATE TRIGGER trg_guard BEFORE INSERT ON platform.reseller_quota_entry FOR EACH ROW EXECUTE FUNCTION platform.quota_entry_guard();
SELECT platform.make_append_only('platform.reseller_quota_entry');

CREATE TABLE IF NOT EXISTS platform.service_order (
  id                    uuid PRIMARY KEY DEFAULT uuidv7(),
  number                text NOT NULL UNIQUE,
  tenant_id             uuid NOT NULL REFERENCES platform.tenant(id),
  kind                  text NOT NULL CHECK (kind IN ('assisted_migration','onprem_install','training','data_conversion')),
  product_version_id    uuid REFERENCES platform.product_version(id),
  source_system         text CHECK (source_system IN ('holoo','sepidar','hesabfa','mahak','excel','paper','other')),
  assignee_kind         text CHECK (assignee_kind IN ('staff','reseller')),
  assignee_staff_id     uuid REFERENCES platform.staff(id),
  assignee_reseller_id  uuid REFERENCES platform.reseller(id),
  status                text NOT NULL DEFAULT 'requested'
                        CHECK (status IN ('requested','quoted','accepted','scheduled','in_progress','delivered','completed','cancelled')),
  quote_amount          numeric(24,0) CHECK (quote_amount >= 0),
  invoice_id            uuid REFERENCES platform.invoice(id),
  sla_due_at            timestamptz,
  consent_ref           uuid,          -- core.support_access_grant.id در سلول (رضایت دسترسی همراه)
  migration_job_ref     uuid,          -- migration.job.id در سلول
  notes                 text,
  created_by            uuid REFERENCES platform.staff(id),
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  row_version           integer NOT NULL DEFAULT 1,
  CHECK (assignee_kind IS NULL AND assignee_staff_id IS NULL AND assignee_reseller_id IS NULL
      OR assignee_kind = 'staff' AND assignee_staff_id IS NOT NULL AND assignee_reseller_id IS NULL
      OR assignee_kind = 'reseller' AND assignee_reseller_id IS NOT NULL AND assignee_staff_id IS NULL),
  CHECK (kind <> 'assisted_migration' OR source_system IS NOT NULL),
  CONSTRAINT service_order_consent CHECK (kind NOT IN ('assisted_migration','data_conversion')
                                          OR status NOT IN ('in_progress','delivered','completed') OR consent_ref IS NOT NULL),
  CHECK (status NOT IN ('scheduled','in_progress','delivered','completed') OR assignee_kind IS NOT NULL)
);
SELECT platform.add_touch('platform.service_order');

CREATE OR REPLACE FUNCTION platform.service_order_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  r platform.reseller%ROWTYPE;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'requested' THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'service orders start as requested');
    END IF;
    NEW.number := platform.number_next('service_order', 'all', 'SO-');
  ELSIF NEW.status IS DISTINCT FROM OLD.status AND NOT (
       (OLD.status = 'requested'   AND NEW.status IN ('quoted','cancelled'))
    OR (OLD.status = 'quoted'      AND NEW.status IN ('accepted','cancelled'))
    OR (OLD.status = 'accepted'    AND NEW.status IN ('scheduled','cancelled'))
    OR (OLD.status = 'scheduled'   AND NEW.status IN ('in_progress','cancelled'))
    OR (OLD.status = 'in_progress' AND NEW.status IN ('delivered','cancelled'))
    OR (OLD.status = 'delivered'   AND NEW.status IN ('completed','in_progress'))) THEN
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', format('service order %s -> %s', OLD.status, NEW.status));
  END IF;
  IF TG_OP = 'UPDATE' AND (NEW.number <> OLD.number OR NEW.tenant_id <> OLD.tenant_id OR NEW.kind <> OLD.kind) THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'service order identity is immutable');
  END IF;
  IF NEW.assignee_reseller_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.assignee_reseller_id IS DISTINCT FROM OLD.assignee_reseller_id) THEN
    SELECT * INTO r FROM platform.reseller WHERE id = NEW.assignee_reseller_id;
    IF r.status <> 'active' OR NOT (CASE NEW.kind WHEN 'onprem_install' THEN 'onprem_install' WHEN 'training' THEN 'training'
                                                  ELSE 'migration' END = ANY (r.kinds)) THEN
      PERFORM platform.fail('HK_PLT_RESELLER_NOT_QUALIFIED', 'reseller is not active or not qualified for this service');
    END IF;
  END IF;
  IF NEW.quote_amount IS NULL AND NEW.status IN ('quoted','accepted') THEN
    PERFORM platform.fail('HK_PLT_SERVICE_ORDER_QUOTE', 'a quoted order needs a price');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.service_order;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON platform.service_order FOR EACH ROW EXECUTE FUNCTION platform.service_order_guard();
DROP TRIGGER IF EXISTS trg_no_delete ON platform.service_order;
CREATE TRIGGER trg_no_delete BEFORE DELETE ON platform.service_order FOR EACH ROW EXECUTE FUNCTION platform.forbid_mutation();

-- =====================================================================
-- ۱۴. سنجش مصرف (از uplink؛ idempotent بر (tenant_id, event_id))
-- =====================================================================
CREATE TABLE IF NOT EXISTS platform.usage_daily (
  tenant_id    uuid NOT NULL REFERENCES platform.tenant(id),
  metric       text NOT NULL REFERENCES platform.feature(key),
  day          date NOT NULL,
  quantity     numeric(20,0) NOT NULL DEFAULT 0 CHECK (quantity >= 0),
  event_count  integer NOT NULL DEFAULT 0 CHECK (event_count >= 0),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, metric, day)
);

CREATE TABLE IF NOT EXISTS platform.usage_event (
  tenant_id    uuid NOT NULL REFERENCES platform.tenant(id),
  event_id     uuid NOT NULL,                     -- شناسهٔ رویداد outbox سلول
  metric       text NOT NULL REFERENCES platform.feature(key),
  quantity     numeric(20,0) NOT NULL CHECK (quantity >= 0),
  occurred_at  timestamptz NOT NULL,
  day          date NOT NULL,                     -- روز محلی (Asia/Tehran) که سلول حساب کرده
  batch_id     uuid NOT NULL REFERENCES platform.uplink_batch(batch_id),
  received_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, event_id),
  CHECK (day BETWEEN (occurred_at AT TIME ZONE 'UTC')::date - 1 AND (occurred_at AT TIME ZONE 'UTC')::date + 1)
);

CREATE OR REPLACE FUNCTION platform.usage_daily_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT platform.is_nested() THEN
    PERFORM platform.fail('HK_PLT_DERIVED_COLUMN', 'usage_daily is maintained from usage_event only');
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.usage_daily;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.usage_daily FOR EACH ROW EXECUTE FUNCTION platform.usage_daily_guard();

CREATE OR REPLACE FUNCTION platform.usage_event_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_kind text;
BEGIN
  SELECT kind INTO v_kind FROM platform.feature WHERE key = NEW.metric;
  IF v_kind = 'flag' THEN
    PERFORM platform.fail('HK_PLT_USAGE_METRIC', 'usage metrics are meter (summed) or limit (gauge, max) features');
  END IF;
  INSERT INTO platform.usage_daily (tenant_id, metric, day, quantity, event_count)
  VALUES (NEW.tenant_id, NEW.metric, NEW.day, NEW.quantity, 1)
  ON CONFLICT (tenant_id, metric, day) DO UPDATE
    SET quantity = CASE WHEN v_kind = 'meter' THEN platform.usage_daily.quantity + EXCLUDED.quantity
                        ELSE greatest(platform.usage_daily.quantity, EXCLUDED.quantity) END,
        event_count = platform.usage_daily.event_count + 1,
        updated_at = now();
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_apply ON platform.usage_event;
CREATE TRIGGER trg_apply AFTER INSERT ON platform.usage_event FOR EACH ROW EXECUTE FUNCTION platform.usage_event_apply();
SELECT platform.make_append_only('platform.usage_event');

-- =====================================================================
-- ۱۵. پشتیبانی: آینهٔ رضایت مستأجر، درخواست ورود به‌جای کاربر، تیکت، اطلاعیه
-- =====================================================================
CREATE TABLE IF NOT EXISTS platform.support_consent (
  tenant_id            uuid NOT NULL REFERENCES platform.tenant(id),
  grant_id             uuid NOT NULL,                  -- core.support_access_grant.id (مرجع معتبر: سلول)
  grantee_kind         text NOT NULL CHECK (grantee_kind IN ('platform_support','reseller')),
  reseller_id          uuid REFERENCES platform.reseller(id),
  access_mode          text NOT NULL CHECK (access_mode IN ('read_only','read_write')),
  max_session_minutes  smallint NOT NULL CHECK (max_session_minutes BETWEEN 5 AND 480),
  starts_at            timestamptz NOT NULL,
  expires_at           timestamptz NOT NULL,
  revoked_at           timestamptz,
  reported_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, grant_id),
  CHECK (expires_at > starts_at AND expires_at <= starts_at + interval '7 days'),
  CHECK ((grantee_kind = 'reseller') = (reseller_id IS NOT NULL))
);

-- آینه همان قاعدهٔ سلول را دارد: فقط کوتاه‌شدن یا لغو
CREATE OR REPLACE FUNCTION platform.support_consent_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE', 'consent mirror rows are kept');
  END IF;
  IF (to_jsonb(NEW) - 'expires_at' - 'revoked_at' - 'reported_at') <> (to_jsonb(OLD) - 'expires_at' - 'revoked_at' - 'reported_at') THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'consent content is immutable');
  END IF;
  IF NEW.expires_at > OLD.expires_at OR (OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at) THEN
    PERFORM platform.fail('HK_PLT_CONSENT_EXTEND', 'consent can only be shortened or revoked');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.support_consent;
CREATE TRIGGER trg_guard BEFORE UPDATE OR DELETE ON platform.support_consent FOR EACH ROW EXECUTE FUNCTION platform.support_consent_guard();

CREATE TABLE IF NOT EXISTS platform.ticket (
  id                    uuid PRIMARY KEY DEFAULT uuidv7(),
  number                text NOT NULL UNIQUE,
  tenant_id             uuid REFERENCES platform.tenant(id),
  opened_by_kind        text NOT NULL CHECK (opened_by_kind IN ('tenant_user','staff','reseller_user','system','billing_contact')),
  opener_ref            uuid,
  opener_name           text,
  subject               text NOT NULL CHECK (char_length(btrim(subject)) BETWEEN 3 AND 200),
  category              text NOT NULL CHECK (category IN ('billing','technical','moadian','migration','onprem','license',
                                                          'commission','feature_request','data_request','other')),
  priority              text NOT NULL DEFAULT 'normal' CHECK (priority IN ('low','normal','high','urgent')),
  status                text NOT NULL DEFAULT 'new' CHECK (status IN ('new','open','pending_customer','pending_internal','resolved','closed')),
  sla_hours             smallint CHECK (sla_hours BETWEEN 1 AND 720),
  sla_due_at            timestamptz,
  first_response_at     timestamptz,
  assigned_level        text NOT NULL DEFAULT 'l2' CHECK (assigned_level IN ('l1_reseller','l2','l3')),
  assigned_staff_id     uuid REFERENCES platform.staff(id),
  assigned_reseller_id  uuid REFERENCES platform.reseller(id),
  client_context        jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(client_context) = 'object'),  -- نسخه، صفحه، کد خطا، request_id
  resolved_at           timestamptz,
  closed_at             timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  row_version           integer NOT NULL DEFAULT 1,
  CHECK ((assigned_level = 'l1_reseller') = (assigned_reseller_id IS NOT NULL)),
  CHECK ((sla_hours IS NULL) = (sla_due_at IS NULL)),
  CHECK (status NOT IN ('resolved','closed') OR resolved_at IS NOT NULL),
  CHECK ((status = 'closed') = (closed_at IS NOT NULL))
);
SELECT platform.add_touch('platform.ticket');

CREATE OR REPLACE FUNCTION platform.ticket_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.number := platform.number_next('ticket', 'all', 'T-');
    IF NEW.sla_hours IS NOT NULL THEN
      NEW.sla_due_at := NEW.created_at + make_interval(hours => NEW.sla_hours);
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.number <> OLD.number OR NEW.created_at <> OLD.created_at OR NEW.opened_by_kind <> OLD.opened_by_kind
     OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id OR NEW.sla_due_at IS DISTINCT FROM OLD.sla_due_at THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'ticket identity and SLA deadline are immutable');
  END IF;
  IF OLD.status = 'closed' AND NEW.status <> 'closed' THEN
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'closed tickets are final (open a new one)');
  END IF;
  IF NEW.first_response_at IS DISTINCT FROM OLD.first_response_at AND (OLD.first_response_at IS NOT NULL OR NOT platform.is_nested()) THEN
    PERFORM platform.fail('HK_PLT_DERIVED_COLUMN', 'first_response_at follows the first public staff message');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.ticket;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON platform.ticket FOR EACH ROW EXECUTE FUNCTION platform.ticket_guard();
DROP TRIGGER IF EXISTS trg_no_delete ON platform.ticket;
CREATE TRIGGER trg_no_delete BEFORE DELETE ON platform.ticket FOR EACH ROW EXECUTE FUNCTION platform.forbid_mutation();

CREATE TABLE IF NOT EXISTS platform.ticket_message (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  ticket_id        uuid NOT NULL REFERENCES platform.ticket(id),
  seq              integer NOT NULL CHECK (seq >= 1),
  author_kind      text NOT NULL CHECK (author_kind IN ('tenant_user','staff','reseller_user','system','billing_contact')),
  author_ref       uuid,
  author_name      text,
  visibility       text NOT NULL DEFAULT 'public' CHECK (visibility IN ('public','partner','internal')),
  body             text NOT NULL CHECK (char_length(body) BETWEEN 1 AND 20000),
  attachment_refs  jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(attachment_refs) = 'array'),
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (ticket_id, seq),
  -- مستأجر و نماینده یادداشت داخلی نمی‌نویسند
  CHECK (author_kind IN ('staff','system') OR visibility <> 'internal')
);

CREATE OR REPLACE FUNCTION platform.ticket_message_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM platform.ticket WHERE id = NEW.ticket_id FOR UPDATE;
  NEW.seq := coalesce((SELECT max(seq) FROM platform.ticket_message WHERE ticket_id = NEW.ticket_id), 0) + 1;
  NEW.created_at := now();
  IF (SELECT status FROM platform.ticket WHERE id = NEW.ticket_id) = 'closed' THEN
    PERFORM platform.fail('HK_PLT_TICKET_CLOSED', 'closed ticket takes no messages');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.ticket_message;
CREATE TRIGGER trg_guard BEFORE INSERT ON platform.ticket_message FOR EACH ROW EXECUTE FUNCTION platform.ticket_message_guard();

CREATE OR REPLACE FUNCTION platform.ticket_message_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.author_kind = 'staff' AND NEW.visibility = 'public' THEN
    UPDATE platform.ticket SET first_response_at = NEW.created_at WHERE id = NEW.ticket_id AND first_response_at IS NULL;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_apply ON platform.ticket_message;
CREATE TRIGGER trg_apply AFTER INSERT ON platform.ticket_message FOR EACH ROW EXECUTE FUNCTION platform.ticket_message_apply();
SELECT platform.make_append_only('platform.ticket_message');

CREATE TABLE IF NOT EXISTS platform.impersonation_request (
  id                    uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id             uuid NOT NULL,
  grant_id              uuid NOT NULL,
  requester_kind        text NOT NULL CHECK (requester_kind IN ('staff','reseller_user')),
  staff_id              uuid REFERENCES platform.staff(id),
  reseller_user_id      uuid REFERENCES platform.reseller_user(id),
  reseller_id           uuid REFERENCES platform.reseller(id),
  mode                  text NOT NULL CHECK (mode IN ('read_only','read_write')),
  target_user_id        uuid,                         -- عضو مستأجر (NULL = هویت «پشتیبان» فقط‌خواندنی)
  reason                text NOT NULL CHECK (char_length(btrim(reason)) >= 10),
  ticket_id             uuid REFERENCES platform.ticket(id),
  ticket_ref            text NOT NULL CHECK (char_length(btrim(ticket_ref)) >= 1),
  max_minutes           smallint NOT NULL CHECK (max_minutes BETWEEN 5 AND 480),
  status                text NOT NULL DEFAULT 'requested'
                        CHECK (status IN ('requested','approved','issued','used','expired','rejected','cancelled')),
  write_approval_id     uuid REFERENCES platform.approval_request(id),
  assertion_jti         uuid UNIQUE,
  issued_at             timestamptz,
  assertion_expires_at  timestamptz,
  session_started_at    timestamptz,
  session_ended_at      timestamptz,
  end_reason            text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  row_version           integer NOT NULL DEFAULT 1,
  FOREIGN KEY (tenant_id, grant_id) REFERENCES platform.support_consent(tenant_id, grant_id),
  CHECK ((requester_kind = 'staff') = (staff_id IS NOT NULL AND reseller_user_id IS NULL AND reseller_id IS NULL)),
  CHECK ((requester_kind = 'reseller_user') = (reseller_user_id IS NOT NULL AND reseller_id IS NOT NULL AND staff_id IS NULL)),
  -- نوشتن: تأیید دوم + کاربر هدف مشخص (همان قید سلول)
  CONSTRAINT impersonation_write_needs_approval CHECK (mode = 'read_only' OR status IN ('requested','rejected','cancelled','expired')
                                                       OR (write_approval_id IS NOT NULL AND target_user_id IS NOT NULL)),
  CONSTRAINT impersonation_assertion_fields CHECK ((status IN ('issued','used')) <= (assertion_jti IS NOT NULL AND issued_at IS NOT NULL AND assertion_expires_at IS NOT NULL)),
  -- ادعای امضاشده یک‌بارمصرف و کوتاه‌عمر است (≤ ۲ دقیقه)
  CONSTRAINT impersonation_assertion_ttl CHECK (assertion_expires_at IS NULL OR assertion_expires_at <= issued_at + interval '2 minutes')
);
SELECT platform.add_touch('platform.impersonation_request');

CREATE OR REPLACE FUNCTION platform.impersonation_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  c platform.support_consent%ROWTYPE;
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE', 'impersonation requests are kept');
  END IF;
  SELECT * INTO c FROM platform.support_consent WHERE tenant_id = NEW.tenant_id AND grant_id = NEW.grant_id;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status NOT IN ('requested','approved') OR NEW.assertion_jti IS NOT NULL THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'impersonation starts as requested (write) or approved (read-only)');
    END IF;
    IF c.revoked_at IS NOT NULL OR now() < c.starts_at OR now() >= c.expires_at THEN
      PERFORM platform.fail('HK_PLT_CONSENT_INACTIVE', 'tenant consent is not active');
    END IF;
    IF NEW.requester_kind = 'staff' THEN
      IF c.grantee_kind <> 'platform_support' THEN
        PERFORM platform.fail('HK_PLT_CONSENT_GRANTEE', 'consent was given to a reseller, not platform support');
      END IF;
      IF NEW.staff_id IS DISTINCT FROM platform.current_staff_id() OR NOT platform.staff_has_permission(NEW.staff_id, 'platform.support.impersonate') THEN
        PERFORM platform.fail('HK_PLT_PERMISSION', 'staff lacks platform.support.impersonate');
      END IF;
    ELSE
      IF c.grantee_kind <> 'reseller' OR c.reseller_id IS DISTINCT FROM NEW.reseller_id
         OR NOT EXISTS (SELECT 1 FROM platform.reseller_user u WHERE u.id = NEW.reseller_user_id AND u.reseller_id = NEW.reseller_id AND u.status = 'active') THEN
        PERFORM platform.fail('HK_PLT_CONSENT_GRANTEE', 'consent does not cover this reseller user');
      END IF;
    END IF;
    IF NEW.mode = 'read_write' AND c.access_mode <> 'read_write' THEN
      PERFORM platform.fail('HK_PLT_CONSENT_MODE', 'tenant consented to read-only access');
    END IF;
    IF NEW.max_minutes > c.max_session_minutes THEN
      PERFORM platform.fail('HK_PLT_CONSENT_DURATION', 'requested session exceeds the consented duration');
    END IF;
    IF NEW.mode = 'read_write' AND NEW.status <> 'requested' THEN
      PERFORM platform.fail('HK_PLT_APPROVAL_REQUIRED', 'write impersonation needs a second approver');
    END IF;
    IF NEW.mode = 'read_only' THEN
      NEW.status := 'approved';
    END IF;
    RETURN NEW;
  END IF;
  IF (to_jsonb(NEW) - 'status' - 'write_approval_id' - 'assertion_jti' - 'issued_at' - 'assertion_expires_at'
      - 'session_started_at' - 'session_ended_at' - 'end_reason' - 'updated_at' - 'row_version')
     <> (to_jsonb(OLD) - 'status' - 'write_approval_id' - 'assertion_jti' - 'issued_at' - 'assertion_expires_at'
      - 'session_started_at' - 'session_ended_at' - 'end_reason' - 'updated_at' - 'row_version') THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'impersonation request content is immutable');
  END IF;
  IF OLD.assertion_jti IS NOT NULL AND NEW.assertion_jti IS DISTINCT FROM OLD.assertion_jti THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'assertion is issued once');
  END IF;
  IF NEW.status = OLD.status THEN RETURN NEW; END IF;
  IF OLD.status = 'requested' AND NEW.status = 'approved' THEN
    PERFORM platform.consume_approval(NEW.write_approval_id, 'impersonation.write', 'impersonation_request', NEW.id,
                                      'impersonation:' || NEW.id::text);
  ELSIF OLD.status = 'approved' AND NEW.status = 'issued' THEN
    IF c.revoked_at IS NOT NULL OR now() >= c.expires_at THEN
      PERFORM platform.fail('HK_PLT_CONSENT_INACTIVE', 'tenant consent ended before the assertion was issued');
    END IF;
    NEW.issued_at := now();
  ELSIF OLD.status = 'issued' AND NEW.status IN ('used','expired') THEN
    NULL;
  ELSIF OLD.status IN ('requested','approved') AND NEW.status IN ('rejected','cancelled','expired') THEN
    NULL;
  ELSE
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', format('impersonation %s -> %s', OLD.status, NEW.status));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.impersonation_request;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.impersonation_request FOR EACH ROW EXECUTE FUNCTION platform.impersonation_guard();

CREATE TABLE IF NOT EXISTS platform.announcement (
  id                uuid PRIMARY KEY DEFAULT uuidv7(),
  kind              text NOT NULL CHECK (kind IN ('banner','release_note','legal_notice','maintenance')),
  severity          text NOT NULL DEFAULT 'info' CHECK (severity IN ('info','warning','critical')),
  title_fa          text NOT NULL,
  body_fa           text NOT NULL,
  title_en          text,
  body_en           text,
  link_url          text CHECK (link_url ~ '^(https://|/)'),
  targeting         jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(targeting) = 'object'),
  starts_at         timestamptz NOT NULL,
  ends_at           timestamptz NOT NULL,
  status            text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','published','withdrawn')),
  sms_broadcast     boolean NOT NULL DEFAULT false,
  sms_pattern_code  text,
  sms_approval_id   uuid REFERENCES platform.approval_request(id),
  created_by        uuid REFERENCES platform.staff(id),
  published_by      uuid REFERENCES platform.staff(id),
  published_at      timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  row_version       integer NOT NULL DEFAULT 1,
  CHECK (ends_at > starts_at),
  CHECK (NOT sms_broadcast OR sms_pattern_code IS NOT NULL),
  CHECK (status = 'draft' OR (published_at IS NOT NULL AND published_by IS NOT NULL)),
  CONSTRAINT announcement_sms_approval CHECK (NOT (sms_broadcast AND status <> 'draft') OR sms_approval_id IS NOT NULL)
);
SELECT platform.add_touch('platform.announcement');

CREATE OR REPLACE FUNCTION platform.announcement_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  k text;
BEGIN
  IF TG_OP = 'INSERT' AND NEW.status <> 'draft' THEN
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'announcements start as draft');
  END IF;
  FOR k IN SELECT jsonb_object_keys(NEW.targeting) LOOP
    IF k NOT IN ('plans','deployments','provinces','min_app_version','max_app_version','tenant_ids','reseller_ids','cells') THEN
      PERFORM platform.fail('HK_PLT_ANNOUNCEMENT_TARGETING', format('unknown targeting key %s', k));
    END IF;
  END LOOP;
  IF TG_OP = 'INSERT' THEN RETURN NEW; END IF;
  IF OLD.status <> 'draft' AND ((to_jsonb(NEW) - 'status' - 'ends_at' - 'updated_at' - 'row_version')
                                 <> (to_jsonb(OLD) - 'status' - 'ends_at' - 'updated_at' - 'row_version')
                                OR NEW.ends_at > OLD.ends_at) THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'published announcements can only be withdrawn or ended earlier');
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF OLD.status = 'draft' AND NEW.status = 'published' THEN
      IF NEW.published_by IS DISTINCT FROM platform.current_staff_id() THEN
        PERFORM platform.fail('HK_PLT_ACTOR_MISMATCH', 'published_by must be the acting staff member');
      END IF;
      IF NEW.sms_broadcast THEN
        PERFORM platform.consume_approval(NEW.sms_approval_id, 'announcement.sms_broadcast', 'announcement', NEW.id,
                                          'announcement:' || NEW.id::text);
      END IF;
      NEW.published_at := now();
    ELSIF NOT (OLD.status = 'published' AND NEW.status = 'withdrawn') THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', format('announcement %s -> %s', OLD.status, NEW.status));
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.announcement;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON platform.announcement FOR EACH ROW EXECUTE FUNCTION platform.announcement_guard();

-- =====================================================================
-- ۱۶. لایسنس On-prem: نصب، لایسنس، فعال‌سازی آفلاین، ابطال و CRL، گزارش مصرف
-- =====================================================================
CREATE TABLE IF NOT EXISTS platform.installation (
  id                    uuid PRIMARY KEY,                 -- install_id ساخته‌شده هنگام نصب (core.deployment_info.install_id)
  tenant_id             uuid NOT NULL REFERENCES platform.tenant(id),
  reseller_id           uuid REFERENCES platform.reseller(id),
  status                text NOT NULL DEFAULT 'pending_activation'
                        CHECK (status IN ('pending_activation','active','replaced','deactivated','revoked')),
  install_pubkey        bytea NOT NULL UNIQUE CHECK (octet_length(install_pubkey) = 32),   -- Ed25519 نصب: امضای درخواست و گزارش مصرف
  fingerprint_version   smallint NOT NULL DEFAULT 1 CHECK (fingerprint_version = 1),
  fingerprint           jsonb NOT NULL,                   -- {"dmi_uuid": "<hmac hex>", "machine_id": ..., "pg_sysid": ..., "rootfs_uuid": ..., "primary_mac": ...}
  min_match             smallint NOT NULL DEFAULT 3 CHECK (min_match BETWEEN 2 AND 5),
  os_family             text NOT NULL DEFAULT 'linux' CHECK (os_family IN ('linux','windows')),
  app_version           text CHECK (app_version ~ '^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$'),
  schema_head           text,
  replaced_by           uuid REFERENCES platform.installation(id),
  first_activated_at    timestamptz,
  last_checkin_at       timestamptz,
  last_usage_period     text,
  last_backup_at        timestamptz,
  last_drill_at         timestamptz,
  last_drill_ok         boolean,
  max_seen_at           timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  row_version           integer NOT NULL DEFAULT 1,
  CHECK ((status = 'replaced') = (replaced_by IS NOT NULL)),
  CHECK (replaced_by IS NULL OR replaced_by <> id)
);
SELECT platform.add_touch('platform.installation');

CREATE OR REPLACE FUNCTION platform.installation_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  k text; n int := 0;
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE', 'installations are deactivated, never deleted');
  END IF;
  IF jsonb_typeof(NEW.fingerprint) <> 'object' THEN
    PERFORM platform.fail('HK_PLT_FINGERPRINT_SHAPE', 'fingerprint must be an object');
  END IF;
  FOR k IN SELECT jsonb_object_keys(NEW.fingerprint) LOOP
    IF k NOT IN ('dmi_uuid','machine_id','pg_sysid','rootfs_uuid','primary_mac')
       OR jsonb_typeof(NEW.fingerprint->k) <> 'string' OR (NEW.fingerprint->>k) !~ '^[0-9a-f]{64}$' THEN
      PERFORM platform.fail('HK_PLT_FINGERPRINT_SHAPE', format('fingerprint component %s must be an HMAC-SHA256 hex of an allowed attribute', k));
    END IF;
    n := n + 1;
  END LOOP;
  IF n < NEW.min_match THEN
    PERFORM platform.fail('HK_PLT_FINGERPRINT_SHAPE', format('fingerprint has %s components, needs at least min_match=%s', n, NEW.min_match));
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF (SELECT deployment FROM platform.tenant WHERE id = NEW.tenant_id) <> 'onprem' THEN
      PERFORM platform.fail('HK_PLT_NOT_ONPREM', 'installations belong to on-prem tenants');
    END IF;
    IF NEW.status <> 'pending_activation' THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'installations start pending activation');
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.tenant_id <> OLD.tenant_id OR NEW.install_pubkey <> OLD.install_pubkey OR NEW.created_at <> OLD.created_at THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'installation identity is immutable');
  END IF;
  IF NEW.max_seen_at < OLD.max_seen_at THEN
    PERFORM platform.fail('HK_PLT_CLOCK_ROLLBACK', 'reported max_seen_at went backwards (clock tampering)');
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
       (OLD.status = 'pending_activation' AND NEW.status IN ('active','deactivated'))
    OR (OLD.status = 'active' AND NEW.status IN ('replaced','deactivated','revoked'))) THEN
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', format('installation %s -> %s', OLD.status, NEW.status));
  END IF;
  IF NEW.status = 'active' AND OLD.status = 'pending_activation' THEN
    IF NOT platform.is_nested() THEN
      PERFORM platform.fail('HK_PLT_DERIVED_COLUMN', 'installations activate by issuing their first license');
    END IF;
    NEW.first_activated_at := now();
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.installation;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.installation FOR EACH ROW EXECUTE FUNCTION platform.installation_guard();

CREATE TABLE IF NOT EXISTS platform.license (
  id                    uuid PRIMARY KEY DEFAULT uuidv7(),
  number                text NOT NULL UNIQUE,
  tenant_id             uuid NOT NULL REFERENCES platform.tenant(id),
  installation_id       uuid REFERENCES platform.installation(id),
  product_version_id    uuid NOT NULL REFERENCES platform.product_version(id),
  license_model         text NOT NULL CHECK (license_model IN ('perpetual','subscription','trial','nfr')),
  edition               text NOT NULL CHECK (edition ~ '^[a-z][a-z0-9_]{1,30}$'),
  modules               text[] NOT NULL CHECK (cardinality(modules) >= 1),
  limits                jsonb NOT NULL,
  overage_pct           smallint NOT NULL DEFAULT 10 CHECK (overage_pct BETWEEN 0 AND 50),
  not_before            date NOT NULL,
  valid_until           date,                             -- NULL = دائمی
  updates_until         date NOT NULL,                    -- کانال به‌روزرسانی و بستهٔ قواعد (INV-OPS-08)
  support_until         date NOT NULL,
  grace_days            smallint NOT NULL DEFAULT 30 CHECK (grace_days BETWEEN 0 AND 90),
  channel               text NOT NULL DEFAULT 'stable' CHECK (channel IN ('stable','lts','beta')),
  online_checkin        text NOT NULL DEFAULT 'optional' CHECK (online_checkin IN ('optional','required_30d','never')),
  reseller_id           uuid REFERENCES platform.reseller(id),
  issued_via            text NOT NULL DEFAULT 'staff' CHECK (issued_via IN ('staff','reseller_quota','renewal_auto','rehost')),
  activation_code_hash  bytea UNIQUE CHECK (octet_length(activation_code_hash) = 32),
  status                text NOT NULL DEFAULT 'draft'
                        CHECK (status IN ('draft','pending_approval','issued','superseded','revoked','expired','cancelled')),
  supersedes_license_id uuid UNIQUE REFERENCES platform.license(id),
  issue_seq             integer CHECK (issue_seq >= 1),   -- یکنوا برای هر نصب؛ نصب لایسنس با seq کمتر را نمی‌پذیرد
  binding_fingerprint   jsonb,
  binding_min_match     smallint,
  approval_id           uuid REFERENCES platform.approval_request(id),
  payload               jsonb,
  payload_sha256        bytea CHECK (octet_length(payload_sha256) = 32),
  file_sha256           bytea CHECK (octet_length(file_sha256) = 32),
  signature             bytea CHECK (octet_length(signature) = 64),
  kid                   text,
  issued_by_kind        text CHECK (issued_by_kind IN ('staff','reseller_user','system')),
  issued_by_id          uuid,
  issued_at             timestamptz,
  revoked_at            timestamptz,
  revoke_reason         text,
  revoke_approval_id    uuid REFERENCES platform.approval_request(id),
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  row_version           integer NOT NULL DEFAULT 1,
  CONSTRAINT license_perpetual_no_expiry CHECK ((license_model IN ('perpetual','nfr') AND valid_until IS NULL)
                                                OR (license_model IN ('subscription','trial') AND valid_until IS NOT NULL)),
  CHECK (valid_until IS NULL OR valid_until > not_before),
  CONSTRAINT license_trial_short CHECK (license_model <> 'trial' OR valid_until <= not_before + 60),
  CHECK (updates_until >= not_before AND support_until >= not_before),
  CONSTRAINT license_issued_fields CHECK (status IN ('draft','pending_approval','cancelled') OR
             (installation_id IS NOT NULL AND issued_at IS NOT NULL AND issue_seq IS NOT NULL AND payload IS NOT NULL
              AND payload_sha256 IS NOT NULL AND file_sha256 IS NOT NULL AND signature IS NOT NULL AND kid IS NOT NULL
              AND binding_fingerprint IS NOT NULL AND issued_by_kind IS NOT NULL)),
  -- بار امضاشده دقیقاً همان ستون‌هاست (هیچ اختلافی بین فایل .lic و رجیستری نیست)
  CONSTRAINT license_payload_matches CHECK (payload IS NULL OR (
        payload->>'format' = 'lic/1' AND payload->>'license_id' = id::text
    AND payload->>'install_id' = installation_id::text AND payload->>'tenant_id' = tenant_id::text
    AND payload->'limits' = limits AND payload->>'license_model' = license_model
    AND (payload->>'updates_until')::date = updates_until
    AND (payload->>'valid_until')::date IS NOT DISTINCT FROM valid_until
    AND payload->'binding'->'fingerprint' = binding_fingerprint)),
  CONSTRAINT license_revoked_fields CHECK ((status = 'revoked') = (revoked_at IS NOT NULL AND revoke_reason IS NOT NULL)),
  CHECK (issued_via <> 'reseller_quota' OR reseller_id IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS license_one_issued_per_installation ON platform.license (installation_id) WHERE status = 'issued';
CREATE UNIQUE INDEX IF NOT EXISTS license_issue_seq ON platform.license (installation_id, issue_seq) WHERE issue_seq IS NOT NULL;
SELECT platform.add_touch('platform.license');

ALTER TABLE platform.reseller_quota_entry DROP CONSTRAINT IF EXISTS reseller_quota_entry_license_fk;
ALTER TABLE platform.reseller_quota_entry ADD CONSTRAINT reseller_quota_entry_license_fk FOREIGN KEY (license_id) REFERENCES platform.license(id);

CREATE TABLE IF NOT EXISTS platform.license_revocation (
  license_id   uuid PRIMARY KEY REFERENCES platform.license(id),
  reason       text NOT NULL CHECK (reason IN ('fraud','chargeback','rehost','contract_terminated','key_compromise','other')),
  note         text,
  revoked_at   timestamptz NOT NULL DEFAULT now()
);
SELECT platform.make_append_only('platform.license_revocation');

CREATE OR REPLACE FUNCTION platform.license_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  inst platform.installation%ROWTYPE;
  prev platform.license%ROWTYPE;
  v_kind text;
  v_exempt boolean;
  v_rehost boolean := false;
  v_rehosts int;
  k text;
  v_allowed text[] := ARRAY['status','approval_id','payload','payload_sha256','file_sha256','signature','kid','issued_by_kind',
                            'issued_by_id','issued_at','issue_seq','binding_fingerprint','binding_min_match','revoked_at',
                            'revoke_reason','revoke_approval_id','updated_at','row_version','installation_id'];
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE', 'licenses are cancelled or revoked, never deleted');
  END IF;
  IF TG_OP = 'INSERT' THEN
    SELECT p.kind INTO v_kind FROM platform.product_version pv JOIN platform.product p ON p.code = pv.product_code WHERE pv.id = NEW.product_version_id;
    IF v_kind <> 'license' THEN
      PERFORM platform.fail('HK_PLT_LICENSE_SHAPE', 'license must reference a license product version');
    END IF;
    IF NEW.status <> 'draft' OR NEW.payload IS NOT NULL OR NEW.issued_at IS NOT NULL THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'licenses start as unsigned drafts');
    END IF;
    IF jsonb_typeof(NEW.limits) <> 'object' THEN
      PERFORM platform.fail('HK_PLT_LICENSE_SHAPE', 'limits must be an object');
    END IF;
    FOR k IN SELECT jsonb_object_keys(NEW.limits) LOOP
      IF k NOT IN ('users','companies','branches','pos_devices','warehouses','invoices_per_month','storage_gb')
         OR jsonb_typeof(NEW.limits->k) <> 'number' OR (NEW.limits->>k)::numeric < 0 OR (NEW.limits->>k)::numeric <> trunc((NEW.limits->>k)::numeric) THEN
        PERFORM platform.fail('HK_PLT_LICENSE_SHAPE', format('invalid license limit %s', k));
      END IF;
    END LOOP;
    IF (SELECT deployment FROM platform.tenant WHERE id = NEW.tenant_id) <> 'onprem' THEN
      PERFORM platform.fail('HK_PLT_NOT_ONPREM', 'licenses are for on-prem tenants');
    END IF;
    NEW.number := platform.number_next('license', 'all', 'LIC-');
    RETURN NEW;
  END IF;
  IF OLD.status NOT IN ('draft') THEN
    FOR k IN SELECT jsonb_object_keys(to_jsonb(NEW)) LOOP
      IF NOT (k = ANY (v_allowed)) AND (to_jsonb(NEW)->k) IS DISTINCT FROM (to_jsonb(OLD)->k) THEN
        PERFORM platform.fail('HK_PLT_LICENSE_FROZEN', format('column %s is frozen after draft', k));
      END IF;
    END LOOP;
  END IF;
  IF OLD.status IN ('issued','superseded','revoked','expired') AND (
       NEW.payload IS DISTINCT FROM OLD.payload OR NEW.signature IS DISTINCT FROM OLD.signature
    OR NEW.installation_id IS DISTINCT FROM OLD.installation_id OR NEW.issued_at IS DISTINCT FROM OLD.issued_at) THEN
    PERFORM platform.fail('HK_PLT_LICENSE_FROZEN', 'issued license file is immutable');
  END IF;
  IF NEW.status = OLD.status THEN RETURN NEW; END IF;

  IF OLD.status = 'draft' AND NEW.status = 'pending_approval' THEN
    RETURN NEW;
  ELSIF OLD.status = 'pending_approval' AND NEW.status = 'draft' THEN
    RETURN NEW;
  ELSIF OLD.status IN ('draft','pending_approval') AND NEW.status = 'cancelled' THEN
    RETURN NEW;
  ELSIF OLD.status IN ('draft','pending_approval') AND NEW.status = 'issued' THEN
    SELECT * INTO inst FROM platform.installation WHERE id = NEW.installation_id FOR UPDATE;
    IF NOT FOUND OR inst.tenant_id <> NEW.tenant_id OR inst.status NOT IN ('pending_activation','active') THEN
      PERFORM platform.fail('HK_PLT_LICENSE_BINDING', 'license must bind to a live installation of the same tenant');
    END IF;
    -- binding از ثبت فعلی نصب برداشته می‌شود؛ بار امضاشده باید با آن برابر باشد (CHECK license_payload_matches)
    IF NEW.binding_fingerprint IS DISTINCT FROM inst.fingerprint OR NEW.binding_min_match IS DISTINCT FROM inst.min_match THEN
      PERFORM platform.fail('HK_PLT_LICENSE_BINDING', 'binding must equal the installation fingerprint');
    END IF;
    IF NEW.supersedes_license_id IS NOT NULL THEN
      SELECT * INTO prev FROM platform.license WHERE id = NEW.supersedes_license_id FOR UPDATE;
      IF prev.status <> 'issued' OR prev.tenant_id <> NEW.tenant_id OR prev.installation_id <> NEW.installation_id THEN
        PERFORM platform.fail('HK_PLT_LICENSE_SUPERSEDE', 'successor must replace the issued license of the same installation');
      END IF;
      v_rehost := prev.binding_fingerprint IS DISTINCT FROM NEW.binding_fingerprint;
    ELSIF EXISTS (SELECT 1 FROM platform.license l WHERE l.installation_id = NEW.installation_id AND l.status = 'issued') THEN
      PERFORM platform.fail('HK_PLT_LICENSE_SUPERSEDE', 'installation already has an issued license; supersede it');
    END IF;
    IF (NEW.issued_via = 'rehost') <> v_rehost THEN
      PERFORM platform.fail('HK_PLT_LICENSE_REHOST', 'issued_via=rehost exactly when the binding changes');
    END IF;
    SELECT count(*) INTO v_rehosts FROM platform.license l
     WHERE l.installation_id = NEW.installation_id AND l.issued_via = 'rehost' AND l.issued_at > now() - interval '365 days';
    v_exempt := coalesce(NEW.issued_via = 'reseller_quota'
             OR (NEW.license_model = 'trial' AND NEW.valid_until <= NEW.not_before + 30)
             OR (NEW.issued_via IN ('renewal_auto','rehost') AND prev.id IS NOT NULL
                 AND prev.limits = NEW.limits AND prev.modules = NEW.modules AND prev.edition = NEW.edition
                 AND prev.license_model = NEW.license_model
                 AND (NEW.issued_via = 'renewal_auto' OR v_rehosts < 2)), false);
    IF NOT v_exempt THEN
      PERFORM platform.consume_approval(NEW.approval_id, 'license.issue', 'license', NEW.id, 'license:' || NEW.id::text);
    END IF;
    IF NEW.issued_via = 'reseller_quota' THEN
      INSERT INTO platform.reseller_quota_entry (reseller_id, product_code, seq, kind, delta, balance_after, license_id)
      SELECT NEW.reseller_id, pv.product_code, 0, 'issue', -1, 0, NEW.id FROM platform.product_version pv WHERE pv.id = NEW.product_version_id;
    END IF;
    IF NEW.issued_by_kind = 'staff' AND NEW.issued_by_id IS DISTINCT FROM platform.current_staff_id() THEN
      PERFORM platform.fail('HK_PLT_ACTOR_MISMATCH', 'issued_by must be the acting staff member');
    END IF;
    NEW.issue_seq := coalesce((SELECT max(issue_seq) FROM platform.license WHERE installation_id = NEW.installation_id), 0) + 1;
    NEW.issued_at := now();
    IF prev.id IS NOT NULL THEN
      IF v_rehost THEN
        INSERT INTO platform.license_revocation (license_id, reason, note) VALUES (prev.id, 'rehost', 'superseded by ' || NEW.number);
        UPDATE platform.license SET status = 'revoked', revoked_at = now(), revoke_reason = 'rehost' WHERE id = prev.id;
      ELSE
        UPDATE platform.license SET status = 'superseded' WHERE id = prev.id;
      END IF;
    END IF;
    IF inst.status = 'pending_activation' THEN
      UPDATE platform.installation SET status = 'active' WHERE id = inst.id;
    END IF;
    RETURN NEW;
  ELSIF OLD.status = 'issued' AND NEW.status = 'superseded' THEN
    IF NOT platform.is_nested() THEN
      PERFORM platform.fail('HK_PLT_DERIVED_COLUMN', 'licenses are superseded by issuing a successor');
    END IF;
  ELSIF OLD.status = 'issued' AND NEW.status = 'revoked' THEN
    IF NOT platform.is_nested() THEN
      PERFORM platform.consume_approval(NEW.revoke_approval_id, 'license.revoke', 'license', NEW.id, 'license_revoke:' || NEW.id::text);
      INSERT INTO platform.license_revocation (license_id, reason, note) VALUES (NEW.id, NEW.revoke_reason, NULL);
    END IF;
    NEW.revoked_at := coalesce(NEW.revoked_at, now());
  ELSIF OLD.status = 'issued' AND NEW.status = 'expired' THEN
    IF NEW.valid_until IS NULL OR NEW.valid_until + NEW.grace_days > current_date THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'license is not past its validity and grace');
    END IF;
  ELSE
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', format('license %s -> %s', OLD.status, NEW.status));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.license;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.license FOR EACH ROW EXECUTE FUNCTION platform.license_guard();

-- فهرست ابطال امضاشده: نسخهٔ یکنوا و کامل (هر ابطال ثبت‌شده در سند هست)
CREATE TABLE IF NOT EXISTS platform.license_crl (
  version     bigint PRIMARY KEY CHECK (version >= 1),
  issued_at   timestamptz NOT NULL DEFAULT now(),
  entries     integer NOT NULL CHECK (entries >= 0),
  document    jsonb NOT NULL,
  sha256      bytea NOT NULL CHECK (octet_length(sha256) = 32),
  signature   bytea NOT NULL CHECK (octet_length(signature) = 64),
  kid         text NOT NULL,
  CHECK (document->>'format' = 'hkcrl/1' AND (document->>'version')::bigint = version
         AND jsonb_typeof(document->'revoked') = 'array' AND jsonb_array_length(document->'revoked') = entries)
);

CREATE OR REPLACE FUNCTION platform.license_crl_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  -- هم‌روندی: دو درج هم‌زمان با «بیشینه + ۱» یکسان روی کلید اصلی به هم می‌خورند و یکی رد می‌شود (بدون شکاف)
  IF NEW.version <> coalesce((SELECT max(version) FROM platform.license_crl), 0) + 1 THEN
    PERFORM platform.fail('HK_PLT_VERSION_SEQUENCE', 'CRL version must be max + 1');
  END IF;
  IF EXISTS (SELECT 1 FROM platform.license_revocation r WHERE NOT (NEW.document->'revoked') ? r.license_id::text) THEN
    PERFORM platform.fail('HK_PLT_CRL_INCOMPLETE', 'CRL must list every recorded revocation');
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(NEW.document->'revoked') e(v)
             WHERE NOT EXISTS (SELECT 1 FROM platform.license_revocation r WHERE r.license_id::text = e.v)) THEN
    PERFORM platform.fail('HK_PLT_CRL_INCOMPLETE', 'CRL lists a license that is not revoked');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.license_crl;
CREATE TRIGGER trg_guard BEFORE INSERT ON platform.license_crl FOR EACH ROW EXECUTE FUNCTION platform.license_crl_guard();
SELECT platform.make_append_only('platform.license_crl');

CREATE TABLE IF NOT EXISTS platform.license_activation (
  id                       uuid PRIMARY KEY DEFAULT uuidv7(),
  installation_id          uuid NOT NULL,                     -- از فایل درخواست (ممکن است هنوز ثبت نشده باشد)
  tenant_id                uuid REFERENCES platform.tenant(id),
  reseller_id              uuid REFERENCES platform.reseller(id),
  request                  jsonb NOT NULL,
  request_sha256           bytea NOT NULL UNIQUE CHECK (octet_length(request_sha256) = 32),
  activation_code_hash     bytea CHECK (octet_length(activation_code_hash) = 32),
  received_via             text NOT NULL CHECK (received_via IN ('panel_upload','partner_portal','online','phone')),
  received_by_staff        uuid REFERENCES platform.staff(id),
  received_by_reseller_user uuid REFERENCES platform.reseller_user(id),
  status                   text NOT NULL DEFAULT 'received' CHECK (status IN ('received','verified','issued','rejected')),
  reject_reason            text,
  license_id               uuid REFERENCES platform.license(id),
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  row_version              integer NOT NULL DEFAULT 1,
  CONSTRAINT activation_request_shape CHECK (request->>'format' = 'actreq/1' AND request->>'install_id' = installation_id::text
                                             AND request ? 'install_pubkey' AND jsonb_typeof(request->'fingerprint') = 'object'
                                             AND request ? 'nonce'),
  CHECK ((status = 'issued') = (license_id IS NOT NULL)),
  CHECK (status <> 'rejected' OR reject_reason IS NOT NULL),
  CHECK (received_by_staff IS NULL OR received_by_reseller_user IS NULL)
);
SELECT platform.add_touch('platform.license_activation');

CREATE OR REPLACE FUNCTION platform.license_activation_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE', 'activation requests are kept');
  END IF;
  IF NEW.request <> OLD.request OR NEW.request_sha256 <> OLD.request_sha256 OR NEW.installation_id <> OLD.installation_id THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'activation request is immutable');
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
       (OLD.status = 'received' AND NEW.status IN ('verified','rejected'))
    OR (OLD.status = 'verified' AND NEW.status IN ('issued','rejected'))) THEN
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', format('activation %s -> %s', OLD.status, NEW.status));
  END IF;
  IF NEW.status = 'issued' AND NOT EXISTS (SELECT 1 FROM platform.license l WHERE l.id = NEW.license_id
                                           AND l.installation_id = NEW.installation_id AND l.status = 'issued') THEN
    PERFORM platform.fail('HK_PLT_LICENSE_BINDING', 'activation answers with an issued license of the same installation');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.license_activation;
CREATE TRIGGER trg_guard BEFORE UPDATE OR DELETE ON platform.license_activation FOR EACH ROW EXECUTE FUNCTION platform.license_activation_guard();

CREATE TABLE IF NOT EXISTS platform.license_usage_report (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  installation_id  uuid NOT NULL REFERENCES platform.installation(id),
  period           text NOT NULL CHECK (period ~ '^jy:[0-9]{4}-(0[1-9]|1[0-2])$'),
  report           jsonb NOT NULL CHECK (report->>'format' = 'usage/1'),
  report_sha256    bytea NOT NULL UNIQUE CHECK (octet_length(report_sha256) = 32),
  signature_ok     boolean NOT NULL CONSTRAINT usage_report_signed CHECK (signature_ok),   -- امضای کلید نصب در پایتون بررسی شده
  users_active     integer CHECK (users_active >= 0),
  companies        integer CHECK (companies >= 0),
  branches         integer CHECK (branches >= 0),
  pos_devices      integer CHECK (pos_devices >= 0),
  invoices         integer CHECK (invoices >= 0),
  max_seen_at      timestamptz,
  app_version      text,
  over_limit       jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(over_limit) = 'object'),
  received_via     text NOT NULL CHECK (received_via IN ('panel_upload','partner_portal','online')),
  received_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (installation_id, period)
);
SELECT platform.make_append_only('platform.license_usage_report');

CREATE TABLE IF NOT EXISTS platform.backup_drill (
  id                    uuid PRIMARY KEY DEFAULT uuidv7(),
  cell_id               text REFERENCES platform.cell(id),
  installation_id       uuid REFERENCES platform.installation(id),
  repo                  text NOT NULL CHECK (repo IN ('repo1','repo2','local','offsite')),
  backup_label          text NOT NULL,
  started_at            timestamptz NOT NULL,
  finished_at           timestamptz,
  outcome               text CHECK (outcome IN ('succeeded','failed')),
  restored_lsn          pg_lsn,
  control_totals_match  boolean,
  report                jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(report) = 'object'),
  CHECK ((cell_id IS NULL) <> (installation_id IS NULL)),
  CHECK ((finished_at IS NULL) = (outcome IS NULL)),
  -- تمرین «موفق» یعنی بازیابی + برابری مقادیر کنترلی (INV-OPS-09)
  CONSTRAINT drill_success_requires_totals CHECK (outcome IS DISTINCT FROM 'succeeded' OR control_totals_match IS TRUE)
);

CREATE OR REPLACE FUNCTION platform.backup_drill_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' OR OLD.finished_at IS NOT NULL
     OR (to_jsonb(NEW) - 'finished_at' - 'outcome' - 'restored_lsn' - 'control_totals_match' - 'report')
        <> (to_jsonb(OLD) - 'finished_at' - 'outcome' - 'restored_lsn' - 'control_totals_match' - 'report') THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE', 'a finished drill is immutable; a running drill only finishes');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.backup_drill;
CREATE TRIGGER trg_guard BEFORE UPDATE OR DELETE ON platform.backup_drill FOR EACH ROW EXECUTE FUNCTION platform.backup_drill_guard();

-- =====================================================================
-- ۱۷. انتشار قواعد قانونی (طرف صفحهٔ کنترل؛ طرف داده: rules.* در 50_compliance.sql)
-- =====================================================================
CREATE TABLE IF NOT EXISTS platform.rules_param_catalog (
  key             text PRIMARY KEY CHECK (key ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,5}$'),
  value_type      text NOT NULL CHECK (value_type IN ('money','decimal','integer','percent','ratio','boolean','text','enum','date','table','json')),
  unit            text,
  package_code    text NOT NULL CHECK (package_code ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,3}$'),
  qualifier_kind  text NOT NULL,
  enum_values     text[],
  introduced_in   text NOT NULL,
  deprecated_in   text,
  CHECK ((value_type = 'enum') = (enum_values IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS platform.rules_package (
  id                   uuid PRIMARY KEY DEFAULT uuidv7(),       -- همان rules.package.id در همهٔ سلول‌ها و نصب‌ها
  code                 text NOT NULL CHECK (code ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,3}$'),
  jurisdiction         text NOT NULL DEFAULT 'IR',
  version              text NOT NULL CHECK (version ~ '^[0-9]{4}\.[0-9]{1,4}$'),
  seq                  integer NOT NULL CHECK (seq >= 1),
  based_on_package_id  uuid REFERENCES platform.rules_package(id),
  covers_from          date NOT NULL,
  covers_to            date,
  min_engine_version   text NOT NULL CHECK (min_engine_version ~ '^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$'),
  changelog_fa         text NOT NULL CHECK (char_length(changelog_fa) BETWEEN 1 AND 20000),
  status               text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','in_review','approved','published','withdrawn','abandoned')),
  review_round         smallint NOT NULL DEFAULT 0 CHECK (review_round >= 0),
  authored_by          uuid NOT NULL REFERENCES platform.staff(id),
  review_due_on        date,
  activate_at          timestamptz,
  distribution         text NOT NULL DEFAULT 'support_required' CHECK (distribution IN ('support_required','all_installations')),
  payload_sha256       bytea CHECK (octet_length(payload_sha256) = 32),
  hksb_sha256          bytea CHECK (octet_length(hksb_sha256) = 32),
  signer_kid           text,
  published_at         timestamptz,
  published_by         uuid REFERENCES platform.staff(id),
  withdrawn_at         timestamptz,
  withdraw_reason      text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  UNIQUE (code, version),
  UNIQUE (code, seq),
  CHECK (covers_to IS NULL OR covers_to > covers_from),
  CONSTRAINT rules_package_published_fields CHECK (status NOT IN ('published','withdrawn') OR
             (payload_sha256 IS NOT NULL AND hksb_sha256 IS NOT NULL AND signer_kid IS NOT NULL AND published_at IS NOT NULL AND published_by IS NOT NULL)),
  CHECK ((status = 'withdrawn') = (withdrawn_at IS NOT NULL AND withdraw_reason IS NOT NULL))
);
SELECT platform.add_touch('platform.rules_package');

CREATE TABLE IF NOT EXISTS platform.rules_value (
  id                  uuid PRIMARY KEY DEFAULT uuidv7(),
  package_id          uuid NOT NULL REFERENCES platform.rules_package(id),
  key                 text NOT NULL REFERENCES platform.rules_param_catalog(key),
  qualifier           text NOT NULL DEFAULT '',
  effective_from      date NOT NULL,
  effective_to        date,
  value               jsonb NOT NULL,
  approved_on         date,
  source_ref          text NOT NULL CHECK (char_length(btrim(source_ref)) >= 3),
  source_url          text,
  source_doc_sha256   bytea CHECK (octet_length(source_doc_sha256) = 32),
  confidence          text NOT NULL CHECK (confidence IN ('high','medium','low','unverified')),
  verified_official   boolean NOT NULL DEFAULT false,
  unit_check_ack_by   uuid REFERENCES platform.staff(id),     -- تأیید هشدار ۱۰× / ۰٫۱× (دام ریال و تومان)
  CHECK (effective_to IS NULL OR effective_to > effective_from),
  CHECK (NOT verified_official OR source_doc_sha256 IS NOT NULL),
  CONSTRAINT rules_value_no_overlap EXCLUDE USING gist (package_id WITH =, key WITH =, qualifier WITH =,
                                                        daterange(effective_from, effective_to, '[)') WITH &&)
);

CREATE TABLE IF NOT EXISTS platform.rules_golden_test (
  id          uuid PRIMARY KEY DEFAULT uuidv7(),
  package_id  uuid NOT NULL REFERENCES platform.rules_package(id),
  code        text NOT NULL CHECK (code ~ '^[a-z0-9][a-z0-9_.-]{1,60}$'),
  calculator  text NOT NULL CHECK (calculator ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_.]*$'),
  as_of       date NOT NULL,
  input       jsonb NOT NULL CHECK (jsonb_typeof(input) = 'object'),
  expected    jsonb NOT NULL CHECK (jsonb_typeof(expected) = 'object'),
  signed_by   text NOT NULL,
  UNIQUE (package_id, code)
);

-- مقدار و آزمون فقط در پیش‌نویس؛ شکل مقدار با نوع کلید (پول = رشتهٔ دهدهی + واحد صریح)
CREATE OR REPLACE FUNCTION platform.rules_content_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  r record;
  v_status text;
  c platform.rules_param_catalog%ROWTYPE;
  v_code text;
BEGIN
  r := CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  SELECT status, code INTO v_status, v_code FROM platform.rules_package WHERE id = r.package_id;
  IF v_status <> 'draft' THEN
    PERFORM platform.fail('HK_PLT_RULES_FROZEN', format('%s of a %s package is frozen', TG_TABLE_NAME, v_status));
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  IF TG_OP = 'UPDATE' AND NEW.package_id <> OLD.package_id THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'content cannot move between packages');
  END IF;
  IF TG_TABLE_NAME = 'rules_value' THEN
    SELECT * INTO c FROM platform.rules_param_catalog WHERE key = NEW.key;
    IF c.package_code <> v_code THEN
      PERFORM platform.fail('HK_PLT_RULES_KEY_OWNER', format('key %s belongs to package %s', NEW.key, c.package_code));
    END IF;
    IF c.deprecated_in IS NOT NULL THEN
      PERFORM platform.fail('HK_PLT_RULES_KEY_DEPRECATED', format('key %s is deprecated', NEW.key));
    END IF;
    IF NOT (CASE c.value_type
         WHEN 'money' THEN jsonb_typeof(NEW.value) = 'object' AND jsonb_typeof(NEW.value->'amount') = 'string'
                           AND (NEW.value->>'amount') ~ '^-?[0-9]{1,20}(\.[0-9]{1,4})?$'
                           AND NEW.value->>'unit' IN ('IRR','IRT','IRR_NEW')
                           AND (SELECT count(*) FROM jsonb_object_keys(NEW.value)) = 2
         WHEN 'decimal' THEN jsonb_typeof(NEW.value) = 'string' AND (NEW.value #>> '{}') ~ '^-?[0-9]{1,20}(\.[0-9]{1,12})?$'
         WHEN 'percent' THEN jsonb_typeof(NEW.value) = 'string' AND (NEW.value #>> '{}') ~ '^[0-9]{1,3}(\.[0-9]{1,6})?$'
         WHEN 'ratio' THEN jsonb_typeof(NEW.value) = 'string' AND (NEW.value #>> '{}') ~ '^[0-9]{1,6}(\.[0-9]{1,12})?$'
         WHEN 'integer' THEN jsonb_typeof(NEW.value) = 'number' AND (NEW.value #>> '{}') ~ '^-?[0-9]+$'
         WHEN 'boolean' THEN jsonb_typeof(NEW.value) = 'boolean'
         WHEN 'text' THEN jsonb_typeof(NEW.value) = 'string'
         WHEN 'enum' THEN jsonb_typeof(NEW.value) = 'string' AND (NEW.value #>> '{}') = ANY (c.enum_values)
         WHEN 'date' THEN jsonb_typeof(NEW.value) = 'string' AND (NEW.value #>> '{}') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
         WHEN 'table' THEN jsonb_typeof(NEW.value) = 'array'
         ELSE jsonb_typeof(NEW.value) IN ('object','array')
       END) THEN
      PERFORM platform.fail('HK_PLT_RULES_VALUE_SHAPE', format('value of %s does not match type %s', NEW.key, c.value_type));
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.rules_value;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.rules_value FOR EACH ROW EXECUTE FUNCTION platform.rules_content_guard();
DROP TRIGGER IF EXISTS trg_guard ON platform.rules_golden_test;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.rules_golden_test FOR EACH ROW EXECUTE FUNCTION platform.rules_content_guard();

CREATE TABLE IF NOT EXISTS platform.rules_review (
  id                  uuid PRIMARY KEY DEFAULT uuidv7(),
  package_id          uuid NOT NULL REFERENCES platform.rules_package(id),
  round               smallint NOT NULL CHECK (round >= 1),
  reviewer_staff_id   uuid NOT NULL REFERENCES platform.staff(id),
  qualification_role  text NOT NULL CHECK (qualification_role IN ('compliance_tax','compliance_payroll')),
  decision            text NOT NULL CHECK (decision IN ('approve','reject')),
  comment             text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (package_id, round, reviewer_staff_id),
  CHECK (decision <> 'reject' OR char_length(btrim(coalesce(comment, ''))) >= 10)
);

CREATE OR REPLACE FUNCTION platform.rules_review_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  p platform.rules_package%ROWTYPE;
BEGIN
  SELECT * INTO p FROM platform.rules_package WHERE id = NEW.package_id;
  IF p.status <> 'in_review' OR NEW.round <> p.review_round THEN
    PERFORM platform.fail('HK_PLT_RULES_REVIEW_STATE', 'reviews belong to the current review round of an in-review package');
  END IF;
  IF NEW.reviewer_staff_id = p.authored_by THEN
    PERFORM platform.fail('HK_PLT_FOUR_EYES', 'the author cannot review own rules package');
  END IF;
  IF NEW.reviewer_staff_id IS DISTINCT FROM platform.current_staff_id() THEN
    PERFORM platform.fail('HK_PLT_ACTOR_MISMATCH', 'reviewer must be the acting staff member');
  END IF;
  IF NOT platform.staff_has_role(NEW.reviewer_staff_id, NEW.qualification_role) THEN
    PERFORM platform.fail('HK_PLT_APPROVER_NOT_ELIGIBLE', format('reviewer does not hold %s', NEW.qualification_role));
  END IF;
  -- قانون مالیات را کارشناس مالیات و قانون حقوق/بیمه را کارشناس حقوق بازبینی می‌کند
  IF (p.code LIKE 'ir.tax%' AND NEW.qualification_role <> 'compliance_tax')
     OR ((p.code LIKE 'ir.payroll%' OR p.code LIKE 'ir.insurance%') AND NEW.qualification_role <> 'compliance_payroll') THEN
    PERFORM platform.fail('HK_PLT_APPROVER_NOT_ELIGIBLE', 'qualification does not match the package domain');
  END IF;
  NEW.created_at := now();
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.rules_review;
CREATE TRIGGER trg_guard BEFORE INSERT ON platform.rules_review FOR EACH ROW EXECUTE FUNCTION platform.rules_review_guard();
SELECT platform.make_append_only('platform.rules_review');

CREATE TABLE IF NOT EXISTS platform.rules_golden_ci_run (
  id              uuid PRIMARY KEY DEFAULT uuidv7(),
  package_id      uuid NOT NULL REFERENCES platform.rules_package(id),
  engine_version  text NOT NULL CHECK (engine_version ~ '^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$'),
  total           integer NOT NULL CHECK (total >= 0),
  passed          integer NOT NULL CHECK (passed >= 0),
  failed          integer NOT NULL CHECK (failed >= 0),
  outcome         text NOT NULL CHECK (outcome IN ('passed','failed')),
  log_ref         text,
  run_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (total = passed + failed),
  CONSTRAINT golden_ci_outcome CHECK ((outcome = 'passed') = (failed = 0 AND total > 0))
);

CREATE OR REPLACE FUNCTION platform.golden_ci_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.total <> (SELECT count(*) FROM platform.rules_golden_test WHERE package_id = NEW.package_id) THEN
    PERFORM platform.fail('HK_PLT_GOLDEN_INCOMPLETE', 'a CI run must execute every golden test of the package');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.rules_golden_ci_run;
CREATE TRIGGER trg_guard BEFORE INSERT ON platform.rules_golden_ci_run FOR EACH ROW EXECUTE FUNCTION platform.golden_ci_guard();
SELECT platform.make_append_only('platform.rules_golden_ci_run');

CREATE OR REPLACE VIEW platform.v_supported_engine_version WITH (security_invoker = true) AS
  SELECT app_version AS engine_version FROM platform.cell WHERE status <> 'retired' AND app_version IS NOT NULL
  UNION
  SELECT version FROM platform.release WHERE status = 'published' AND support_status <> 'unsupported'
  UNION
  SELECT app_version FROM platform.installation WHERE status = 'active' AND app_version IS NOT NULL;

CREATE OR REPLACE FUNCTION platform.rules_package_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_missing text;
  k text;
  v_allowed text[] := ARRAY['status','review_round','payload_sha256','hksb_sha256','signer_kid','published_at','published_by',
                            'withdrawn_at','withdraw_reason','activate_at','updated_at','row_version'];
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE', 'rules packages are abandoned, never deleted');
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' OR NEW.published_at IS NOT NULL THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'rules packages start as draft');
    END IF;
    IF NEW.authored_by IS DISTINCT FROM platform.current_staff_id() OR NOT platform.staff_has_permission(NEW.authored_by, 'platform.rules.author') THEN
      PERFORM platform.fail('HK_PLT_PERMISSION', 'author must be the acting staff member with platform.rules.author');
    END IF;
    PERFORM 1 FROM platform.rules_package WHERE code = NEW.code FOR UPDATE;
    IF NEW.seq <= coalesce((SELECT max(seq) FROM platform.rules_package WHERE code = NEW.code), 0) THEN
      PERFORM platform.fail('HK_PLT_RULES_SEQ', 'package seq must exceed every earlier package of the code');
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.status <> 'draft' THEN
    FOR k IN SELECT jsonb_object_keys(to_jsonb(NEW)) LOOP
      IF NOT (k = ANY (v_allowed)) AND (to_jsonb(NEW)->k) IS DISTINCT FROM (to_jsonb(OLD)->k) THEN
        PERFORM platform.fail('HK_PLT_RULES_FROZEN', format('column %s is frozen after draft', k));
      END IF;
    END LOOP;
  END IF;
  IF OLD.status IN ('published','withdrawn') AND (NEW.payload_sha256 IS DISTINCT FROM OLD.payload_sha256
       OR NEW.hksb_sha256 IS DISTINCT FROM OLD.hksb_sha256 OR NEW.published_at IS DISTINCT FROM OLD.published_at) THEN
    PERFORM platform.fail('HK_PLT_RULES_FROZEN', 'a published package is immutable');
  END IF;
  IF NEW.review_round <> OLD.review_round AND NOT (OLD.status = 'draft' AND NEW.status = 'in_review') THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'review round advances only on submission');
  END IF;
  IF NEW.status = OLD.status THEN RETURN NEW; END IF;
  IF OLD.status = 'draft' AND NEW.status = 'in_review' THEN
    IF NOT EXISTS (SELECT 1 FROM platform.rules_value WHERE package_id = NEW.id)
       OR NOT EXISTS (SELECT 1 FROM platform.rules_golden_test WHERE package_id = NEW.id) THEN
      PERFORM platform.fail('HK_PLT_RULES_INCOMPLETE', 'a package needs at least one value and one golden test');
    END IF;
    NEW.review_round := OLD.review_round + 1;
  ELSIF OLD.status = 'in_review' AND NEW.status = 'draft' THEN
    NULL;
  ELSIF OLD.status = 'in_review' AND NEW.status = 'approved' THEN
    IF NOT EXISTS (SELECT 1 FROM platform.rules_review r WHERE r.package_id = NEW.id AND r.round = OLD.review_round AND r.decision = 'approve')
       OR EXISTS (SELECT 1 FROM platform.rules_review r WHERE r.package_id = NEW.id AND r.round = OLD.review_round AND r.decision = 'reject') THEN
      PERFORM platform.fail('HK_PLT_RULES_NOT_REVIEWED', 'needs an approving qualified review and no rejection in this round');
    END IF;
  ELSIF OLD.status = 'approved' AND NEW.status = 'published' THEN
    SELECT string_agg(e.engine_version, ', ') INTO v_missing
      FROM platform.v_supported_engine_version e
     WHERE platform.calver_key(e.engine_version) >= platform.calver_key(NEW.min_engine_version)
       AND NOT EXISTS (SELECT 1 FROM platform.rules_golden_ci_run g WHERE g.package_id = NEW.id
                         AND g.engine_version = e.engine_version AND g.outcome = 'passed');
    IF v_missing IS NOT NULL THEN
      PERFORM platform.fail('HK_PLT_GOLDEN_NOT_PASSED', format('golden tests have not passed on engine %s', v_missing));
    END IF;
    IF NEW.published_by IS DISTINCT FROM platform.current_staff_id() OR NOT platform.staff_has_permission(NEW.published_by, 'platform.rules.publish') THEN
      PERFORM platform.fail('HK_PLT_PERMISSION', 'publisher must be the acting staff member with platform.rules.publish');
    END IF;
    NEW.published_at := now();
  ELSIF OLD.status = 'published' AND NEW.status = 'withdrawn' THEN
    NEW.withdrawn_at := coalesce(NEW.withdrawn_at, now());
  ELSIF OLD.status IN ('draft','in_review','approved') AND NEW.status = 'abandoned' THEN
    NULL;
  ELSE
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', format('rules package %s -> %s', OLD.status, NEW.status));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.rules_package;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.rules_package FOR EACH ROW EXECUTE FUNCTION platform.rules_package_guard();

CREATE TABLE IF NOT EXISTS platform.rules_distribution (
  package_id   uuid NOT NULL REFERENCES platform.rules_package(id),
  target_kind  text NOT NULL CHECK (target_kind IN ('cell','installation')),
  target_id    text NOT NULL,
  status       text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','delivered','installed','active','rejected','failed')),
  golden_ok    boolean,
  detail       text,
  reported_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (package_id, target_kind, target_id)
);

-- =====================================================================
-- ۱۸. بستهٔ صنفی (کاتالوگ منتشرشده؛ طرف داده: rules.industry_pack*)
-- =====================================================================
CREATE TABLE IF NOT EXISTS platform.industry_pack (
  code           text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  name_fa        text NOT NULL,
  kind           text NOT NULL CHECK (kind IN ('base','industry','addon')),
  status         text NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired')),
  introduced_in  text NOT NULL
);

CREATE TABLE IF NOT EXISTS platform.industry_pack_version (
  pack_code         text NOT NULL REFERENCES platform.industry_pack(code),
  version           text NOT NULL CHECK (version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
  manifest          jsonb NOT NULL,
  manifest_sha256   bytea NOT NULL CHECK (octet_length(manifest_sha256) = 32),
  hksb_sha256       bytea CHECK (octet_length(hksb_sha256) = 32),
  min_app_version   text NOT NULL,
  confidence        text NOT NULL DEFAULT 'low' CHECK (confidence IN ('high','medium','low')),
  status            text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','in_review','published','retired')),
  authored_by       uuid NOT NULL REFERENCES platform.staff(id),
  reviewed_by       uuid REFERENCES platform.staff(id),
  gate_report       jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(gate_report) = 'object'),   -- report_coverage + ردیف‌های کنترلی (C-L11)
  gate_passed       boolean NOT NULL DEFAULT false,
  published_at      timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  row_version       integer NOT NULL DEFAULT 1,
  PRIMARY KEY (pack_code, version),
  CHECK (manifest->>'format' = 'hkpack/1' AND manifest->>'pack' = pack_code AND manifest->>'version' = version),
  CONSTRAINT pack_reviewer_not_author CHECK (reviewed_by IS NULL OR reviewed_by <> authored_by),
  CONSTRAINT pack_published_fields CHECK (status NOT IN ('published','retired') OR
             (reviewed_by IS NOT NULL AND gate_passed AND hksb_sha256 IS NOT NULL AND published_at IS NOT NULL))
);
SELECT platform.add_touch('platform.industry_pack_version');

CREATE OR REPLACE FUNCTION platform.pack_version_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN
      PERFORM platform.fail('HK_PLT_IMMUTABLE', 'only draft pack versions can be deleted');
    END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'pack versions start as draft');
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.status <> 'draft' AND (NEW.manifest <> OLD.manifest OR NEW.manifest_sha256 <> OLD.manifest_sha256
       OR NEW.min_app_version <> OLD.min_app_version OR NEW.confidence <> OLD.confidence) THEN
    PERFORM platform.fail('HK_PLT_PACK_FROZEN', 'pack content is frozen after draft');
  END IF;
  IF OLD.status IN ('published','retired') AND (NEW.hksb_sha256 IS DISTINCT FROM OLD.hksb_sha256 OR NEW.reviewed_by IS DISTINCT FROM OLD.reviewed_by) THEN
    PERFORM platform.fail('HK_PLT_PACK_FROZEN', 'published pack is immutable');
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF OLD.status = 'draft' AND NEW.status = 'in_review' THEN
      NULL;
    ELSIF OLD.status = 'in_review' AND NEW.status = 'draft' THEN
      NULL;
    ELSIF OLD.status = 'in_review' AND NEW.status = 'published' THEN
      IF NEW.reviewed_by IS DISTINCT FROM platform.current_staff_id() OR NOT platform.staff_has_permission(NEW.reviewed_by, 'platform.pack.review') THEN
        PERFORM platform.fail('HK_PLT_APPROVER_NOT_ELIGIBLE', 'reviewer must be the acting staff member with platform.pack.review');
      END IF;
      NEW.published_at := now();
    ELSIF OLD.status = 'published' AND NEW.status = 'retired' THEN
      NULL;
    ELSE
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', format('pack version %s -> %s', OLD.status, NEW.status));
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.industry_pack_version;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON platform.industry_pack_version FOR EACH ROW EXECUTE FUNCTION platform.pack_version_guard();

-- =====================================================================
-- ۱۹. مرکز مهاجرت (CR-MG10 بخش ۰۸)
-- =====================================================================
CREATE TABLE IF NOT EXISTS platform.migration_job_stat (
  tenant_id         uuid NOT NULL REFERENCES platform.tenant(id),
  job_id            uuid NOT NULL,                       -- migration.job.id در سلول
  source_system     text NOT NULL CHECK (source_system IN ('holoo','sepidar','hesabfa','mahak','excel','paper','other')),
  profile_code      text,
  profile_version   text,
  channel           text NOT NULL CHECK (channel IN ('file','api','agent','assisted')),
  status            text NOT NULL,
  rows_total        bigint CHECK (rows_total >= 0),
  rows_failed       bigint CHECK (rows_failed >= 0),
  issues_by_code    jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(issues_by_code) = 'object'),
  started_at        timestamptz,
  finished_at       timestamptz,
  service_order_id  uuid REFERENCES platform.service_order(id),
  source_event_at   timestamptz NOT NULL,                -- زمان رویداد در سلول؛ رویداد کهنه‌تر نادیده
  updated_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, job_id)
);

-- uplink ممکن است نامرتب برسد: به‌روزرسانی کهنه‌تر از وضعیت ذخیره‌شده بی‌اثر است
CREATE OR REPLACE FUNCTION platform.migration_job_stat_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.source_event_at < OLD.source_event_at THEN
    RETURN OLD;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.migration_job_stat;
CREATE TRIGGER trg_guard BEFORE UPDATE ON platform.migration_job_stat FOR EACH ROW EXECUTE FUNCTION platform.migration_job_stat_guard();

CREATE TABLE IF NOT EXISTS platform.migration_dictionary_candidate (
  id                 uuid PRIMARY KEY DEFAULT uuidv7(),
  source_system      text NOT NULL,
  dict_kind          text NOT NULL CHECK (dict_kind IN ('header_synonym','account_mapping','unit_alias','value_alias')),
  source_text_norm   text NOT NULL,                      -- پس از fa-norm-v1
  target_key         text NOT NULL,
  distinct_tenants   integer NOT NULL DEFAULT 0 CHECK (distinct_tenants >= 0),
  threshold          smallint NOT NULL DEFAULT 3 CHECK (threshold >= 2),
  status             text NOT NULL DEFAULT 'collecting' CHECK (status IN ('collecting','eligible','approved','rejected','published')),
  decided_by         uuid REFERENCES platform.staff(id),
  release_version    integer,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_system, dict_kind, source_text_norm, target_key),
  -- ارتقا به فرهنگ سراسری فقط با دست‌کم «آستانه» مستأجر متمایز
  CONSTRAINT dictionary_threshold CHECK (status NOT IN ('eligible','approved','published') OR distinct_tenants >= threshold),
  CHECK (status NOT IN ('approved','rejected','published') OR decided_by IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS platform.migration_dictionary_vote (
  candidate_id   uuid NOT NULL REFERENCES platform.migration_dictionary_candidate(id),
  tenant_id      uuid NOT NULL REFERENCES platform.tenant(id),
  first_seen_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (candidate_id, tenant_id)
);

CREATE OR REPLACE FUNCTION platform.dictionary_vote_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE platform.migration_dictionary_candidate c
     SET distinct_tenants = c.distinct_tenants + 1,
         status = CASE WHEN c.status = 'collecting' AND c.distinct_tenants + 1 >= c.threshold THEN 'eligible' ELSE c.status END,
         updated_at = now()
   WHERE c.id = NEW.candidate_id;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_apply ON platform.migration_dictionary_vote;
CREATE TRIGGER trg_apply AFTER INSERT ON platform.migration_dictionary_vote FOR EACH ROW EXECUTE FUNCTION platform.dictionary_vote_apply();
SELECT platform.make_append_only('platform.migration_dictionary_vote');

CREATE OR REPLACE FUNCTION platform.dictionary_candidate_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.distinct_tenants IS DISTINCT FROM OLD.distinct_tenants AND NOT platform.is_nested() THEN
    PERFORM platform.fail('HK_PLT_DERIVED_COLUMN', 'distinct_tenants follows migration_dictionary_vote');
  END IF;
  IF NEW.status IN ('approved','rejected') AND OLD.status IS DISTINCT FROM NEW.status THEN
    IF NEW.decided_by IS DISTINCT FROM platform.current_staff_id() OR NOT platform.staff_has_permission(NEW.decided_by, 'platform.migration.dictionary.publish') THEN
      PERFORM platform.fail('HK_PLT_PERMISSION', 'decision needs platform.migration.dictionary.publish');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.migration_dictionary_candidate;
CREATE TRIGGER trg_guard BEFORE UPDATE ON platform.migration_dictionary_candidate FOR EACH ROW EXECUTE FUNCTION platform.dictionary_candidate_guard();

CREATE TABLE IF NOT EXISTS platform.migration_dictionary_release (
  version          integer PRIMARY KEY CHECK (version >= 1),
  status           text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','published','withdrawn')),
  entries          integer NOT NULL CHECK (entries >= 0),
  payload_sha256   bytea CHECK (octet_length(payload_sha256) = 32),
  hksb_sha256      bytea CHECK (octet_length(hksb_sha256) = 32),
  created_by       uuid NOT NULL REFERENCES platform.staff(id),
  approved_by      uuid REFERENCES platform.staff(id),
  published_at     timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT dictionary_release_four_eyes CHECK (approved_by IS NULL OR approved_by <> created_by),
  CHECK (status = 'draft' OR (approved_by IS NOT NULL AND hksb_sha256 IS NOT NULL AND published_at IS NOT NULL))
);
ALTER TABLE platform.migration_dictionary_candidate DROP CONSTRAINT IF EXISTS dictionary_candidate_release_fk;
ALTER TABLE platform.migration_dictionary_candidate ADD CONSTRAINT dictionary_candidate_release_fk
  FOREIGN KEY (release_version) REFERENCES platform.migration_dictionary_release(version);

CREATE TABLE IF NOT EXISTS platform.migration_profile_release (
  profile_code           text NOT NULL CHECK (profile_code ~ '^[a-z][a-z0-9_.-]{2,60}$'),
  version                text NOT NULL CHECK (version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
  source_system          text NOT NULL,
  status                 text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','beta','published','retired')),
  golden_dataset_passed  boolean NOT NULL DEFAULT false,
  real_sample_passed     boolean NOT NULL DEFAULT false,
  sample_consent_ref     text,                             -- رضایت کتبی صاحب داده برای نمونهٔ واقعی (Q-G2)
  hksb_sha256            bytea CHECK (octet_length(hksb_sha256) = 32),
  published_by           uuid REFERENCES platform.staff(id),
  published_at           timestamptz,
  created_at             timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (profile_code, version),
  CONSTRAINT profile_beta_gate CHECK (status NOT IN ('beta','published') OR (golden_dataset_passed AND hksb_sha256 IS NOT NULL)),
  CONSTRAINT profile_published_gate CHECK (status <> 'published' OR (real_sample_passed AND published_by IS NOT NULL AND published_at IS NOT NULL)),
  CONSTRAINT profile_sample_consent CHECK (NOT real_sample_passed OR sample_consent_ref IS NOT NULL)
);

-- =====================================================================
-- ۲۰. پایش: وابستگی‌های بیرونی، مؤدیان همهٔ مستأجران، لنگر ممیزی سلول‌ها
-- =====================================================================
CREATE TABLE IF NOT EXISTS platform.dependency_status (
  target      text PRIMARY KEY CHECK (target ~ '^[a-z][a-z0-9_.:-]{2,80}$'),   -- moadian.tp، gateway.zarinpal، sms.kavenegar، ai.provider:<id>
  status      text NOT NULL CHECK (status IN ('up','degraded','down','unknown')),
  latency_ms  integer CHECK (latency_ms >= 0),
  last_ok_at  timestamptz,
  last_error  text,
  checked_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS platform.moadian_tenant_stat (
  tenant_id                 uuid NOT NULL REFERENCES platform.tenant(id),
  day                       date NOT NULL,
  memory_count              integer NOT NULL DEFAULT 0 CHECK (memory_count >= 0),
  sent                      integer NOT NULL DEFAULT 0 CHECK (sent >= 0),
  accepted                  integer NOT NULL DEFAULT 0 CHECK (accepted >= 0),
  rejected                  integer NOT NULL DEFAULT 0 CHECK (rejected >= 0),
  pending                   integer NOT NULL DEFAULT 0 CHECK (pending >= 0),
  near_deadline             integer NOT NULL DEFAULT 0 CHECK (near_deadline >= 0),   -- مهلت ۷ روزه: روز ۶ به بعد
  overdue                   integer NOT NULL DEFAULT 0 CHECK (overdue >= 0),
  oldest_pending_issued_at  timestamptz,
  top_error_codes           jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(top_error_codes) = 'object'),
  cert_expires_on           date,
  signer_mode               text CHECK (signer_mode IN ('server_kms','device_agent','tsp_held')),
  signer_online             boolean,
  updated_at                timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, day)
);

CREATE TABLE IF NOT EXISTS platform.tenant_audit_anchor (
  tenant_id       uuid NOT NULL REFERENCES platform.tenant(id),
  chain_no        smallint NOT NULL CHECK (chain_no BETWEEN 0 AND 63),
  seq             bigint NOT NULL CHECK (seq >= 0),
  hash            bytea NOT NULL CHECK (octet_length(hash) = 32),
  checkpoint_id   uuid NOT NULL,
  checkpoint_at   timestamptz NOT NULL,
  received_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, chain_no, seq)
);

-- لنگر بیرونی زنجیرهٔ ممیزی مستأجر: عقب‌گرد seq یا hash دیگر برای seq ثبت‌شده = بازنویسی تاریخچه در سلول
CREATE OR REPLACE FUNCTION platform.tenant_audit_anchor_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_max bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM platform.tenant_audit_anchor a WHERE a.tenant_id = NEW.tenant_id AND a.chain_no = NEW.chain_no
             AND a.seq = NEW.seq AND a.hash <> NEW.hash) THEN
    PERFORM platform.fail('HK_PLT_AUDIT_FORK', 'tenant audit chain fork: same seq with a different hash');
  END IF;
  SELECT max(seq) INTO v_max FROM platform.tenant_audit_anchor WHERE tenant_id = NEW.tenant_id AND chain_no = NEW.chain_no;
  IF v_max IS NOT NULL AND NEW.seq < v_max THEN
    PERFORM platform.fail('HK_PLT_AUDIT_ROLLBACK', 'tenant audit anchor went backwards');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.tenant_audit_anchor;
CREATE TRIGGER trg_guard BEFORE INSERT ON platform.tenant_audit_anchor FOR EACH ROW EXECUTE FUNCTION platform.tenant_audit_anchor_guard();
SELECT platform.make_append_only('platform.tenant_audit_anchor');

-- =====================================================================
-- ۲۱. درخواست‌های داده (صدور کامل، حذف/بی‌نام‌سازی دادهٔ شخصی، پاک‌سازی)
-- =====================================================================
CREATE TABLE IF NOT EXISTS platform.data_request (
  id                     uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id              uuid NOT NULL REFERENCES platform.tenant(id),
  kind                   text NOT NULL CHECK (kind IN ('full_export','offboarding_export','personal_data_export','personal_data_erasure')),
  requested_via          text NOT NULL CHECK (requested_via IN ('tenant_owner','data_subject','legal_order','staff')),
  requester_name         text NOT NULL,
  requester_contact      text,
  legal_basis            text,
  status                 text NOT NULL DEFAULT 'received' CHECK (status IN ('received','in_review','approved','in_progress','completed','rejected')),
  created_by_staff       uuid NOT NULL REFERENCES platform.staff(id),
  reviewer_staff_id      uuid REFERENCES platform.staff(id),
  approval_id            uuid REFERENCES platform.approval_request(id),
  due_by                 date NOT NULL,
  data_plane_request_id  uuid,                             -- core.data_subject_request / core.tenant_export در سلول
  cell_command_id        uuid REFERENCES platform.cell_command(id),
  result_ref             text,
  result_sha256          bytea CHECK (octet_length(result_sha256) = 32),
  rejection_reason       text,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  row_version            integer NOT NULL DEFAULT 1,
  CONSTRAINT data_request_reviewer_distinct CHECK (reviewer_staff_id IS NULL OR reviewer_staff_id <> created_by_staff),
  CHECK (status NOT IN ('approved','in_progress','completed') OR reviewer_staff_id IS NOT NULL),
  CONSTRAINT data_request_erasure_approval CHECK (kind <> 'personal_data_erasure' OR status NOT IN ('approved','in_progress','completed') OR approval_id IS NOT NULL),
  CHECK (status <> 'rejected' OR char_length(btrim(coalesce(rejection_reason, ''))) >= 10),
  CHECK (status <> 'completed' OR result_sha256 IS NOT NULL)
);
SELECT platform.add_touch('platform.data_request');

CREATE OR REPLACE FUNCTION platform.data_request_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'received' OR NEW.created_by_staff IS DISTINCT FROM platform.current_staff_id() THEN
      PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', 'data requests start as received by the acting staff member');
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
       (OLD.status = 'received'    AND NEW.status IN ('in_review','rejected'))
    OR (OLD.status = 'in_review'   AND NEW.status IN ('approved','rejected'))
    OR (OLD.status = 'approved'    AND NEW.status = 'in_progress')
    OR (OLD.status = 'in_progress' AND NEW.status = 'completed')) THEN
    PERFORM platform.fail('HK_PLT_INVALID_TRANSITION', format('data request %s -> %s', OLD.status, NEW.status));
  END IF;
  IF OLD.status = 'in_review' AND NEW.status = 'approved' THEN
    IF NEW.reviewer_staff_id IS DISTINCT FROM platform.current_staff_id() THEN
      PERFORM platform.fail('HK_PLT_ACTOR_MISMATCH', 'reviewer must be the acting staff member');
    END IF;
    IF NEW.kind = 'personal_data_erasure' THEN
      PERFORM platform.consume_approval(NEW.approval_id, 'data_request.erasure', 'data_request', NEW.id, 'data_request:' || NEW.id::text);
    END IF;
  END IF;
  IF NEW.tenant_id <> OLD.tenant_id OR NEW.kind <> OLD.kind OR NEW.created_by_staff <> OLD.created_by_staff THEN
    PERFORM platform.fail('HK_PLT_IMMUTABLE_FIELD', 'data request identity is immutable');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON platform.data_request;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON platform.data_request FOR EACH ROW EXECUTE FUNCTION platform.data_request_guard();

-- =====================================================================
-- ۲۲. حق استفادهٔ مؤثر هر مستأجر (ورودی سازندهٔ «حالت مطلوب» و فایل لایسنس)
-- قاعده: پایهٔ پلن (set؛ NULL = نامحدود) + افزونه‌ها (add / add_per_unit × تعداد) + واحد اضافهٔ پلن (add)؛
-- جایگزین مستأجر: set پایهٔ پلن را عوض می‌کند (افزوده‌ها همچنان جمع می‌شوند)، add جمع می‌شود؛ پرچم = OR (جایگزین set مقدم).
-- =====================================================================
CREATE OR REPLACE FUNCTION platform.effective_entitlements(p_tenant uuid, p_on date DEFAULT current_date)
RETURNS TABLE (feature_key text, kind text, enabled boolean, limit_value numeric, unlimited boolean, enforcement text, overage_pct smallint)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  s platform.subscription%ROWTYPE;
BEGIN
  SELECT * INTO s FROM platform.subscription x WHERE x.tenant_id = p_tenant AND x.status <> 'cancelled';
  RETURN QUERY
  WITH contrib AS (
    SELECT e.feature_key AS fk, e.enabled AS en, e.limit_value AS lv, 'base'::text AS src, e.enforcement AS enf, e.overage_pct AS ov
      FROM platform.product_entitlement e WHERE e.product_version_id = s.plan_version_id
    UNION ALL
    SELECT e.feature_key, e.enabled,
           CASE WHEN e.combine = 'add_per_unit' THEN e.limit_value * i.quantity ELSE e.limit_value END,
           CASE WHEN e.combine = 'set' THEN 'base' ELSE 'add' END, e.enforcement, e.overage_pct
      FROM platform.subscription_item i JOIN platform.product_entitlement e ON e.product_version_id = i.product_version_id
     WHERE i.subscription_id = s.id AND i.metric_key IS NULL AND i.valid_from <= p_on AND (i.valid_to IS NULL OR i.valid_to > p_on)
    UNION ALL
    SELECT i.metric_key, NULL::boolean, i.quantity::numeric, 'add', NULL::text, NULL::smallint
      FROM platform.subscription_item i
     WHERE i.subscription_id = s.id AND i.metric_key IS NOT NULL AND i.valid_from <= p_on AND (i.valid_to IS NULL OR i.valid_to > p_on)
    UNION ALL
    SELECT o.feature_key, o.enabled, o.limit_value, CASE o.mode WHEN 'set' THEN 'override_set' ELSE 'add' END, NULL::text, NULL::smallint
      FROM platform.tenant_entitlement_override o
     WHERE o.tenant_id = p_tenant AND o.revoked_at IS NULL
       AND o.valid_from <= p_on::timestamptz AND o.valid_to > p_on::timestamptz
  ), agg AS (
    SELECT c.fk,
           bool_or(c.en) FILTER (WHERE c.src IN ('base','add'))            AS en_base,
           bool_or(c.en) FILTER (WHERE c.src = 'override_set')            AS en_ovr,
           coalesce(bool_or(c.src = 'base' AND c.lv IS NULL), false)       AS base_unl,
           max(c.lv) FILTER (WHERE c.src = 'base')                         AS base_lv,
           coalesce(bool_or(c.src = 'override_set'), false)                AS has_ovr,
           coalesce(bool_or(c.src = 'override_set' AND c.lv IS NULL), false) AS ovr_unl,
           max(c.lv) FILTER (WHERE c.src = 'override_set')                 AS ovr_lv,
           coalesce(sum(c.lv) FILTER (WHERE c.src = 'add'), 0)             AS add_lv,
           min(c.enf)                                                       AS enf,     -- 'hard' < 'soft'
           max(c.ov)                                                        AS ov
      FROM contrib c GROUP BY c.fk
  )
  SELECT f.key, f.kind,
         CASE WHEN f.kind = 'flag' THEN coalesce(CASE WHEN a.has_ovr THEN a.en_ovr END, a.en_base, false) END,
         CASE WHEN f.kind <> 'flag' THEN
              CASE WHEN a.has_ovr THEN CASE WHEN a.ovr_unl THEN NULL ELSE a.ovr_lv + a.add_lv END
                   WHEN a.base_unl THEN NULL
                   ELSE coalesce(a.base_lv, 0) + a.add_lv END END,
         f.kind <> 'flag' AND ((a.has_ovr AND a.ovr_unl) OR (NOT a.has_ovr AND a.base_unl)),
         coalesce(a.enf, 'hard'), coalesce(a.ov, 0::smallint)
    FROM agg a JOIN platform.feature f ON f.key = a.fk;
END $$;

-- =====================================================================
-- ۲۳. ویوها (همه security_invoker)
-- =====================================================================
CREATE OR REPLACE VIEW platform.v_tenant_overview WITH (security_invoker = true) AS
SELECT t.id AS tenant_id, t.slug, t.display_name, t.status, t.deployment, t.province_code, t.city_code, t.reseller_id,
       t.is_internal, t.created_at, t.status_changed_at,
       p.cell_id, p.mode, p.state AS placement_state,
       platform.data_plane_status(t.status, p.state) AS data_plane_status,
       r.desired_version, r.applied_version, r.last_uplink_at, r.last_activity_at, r.active_users, r.companies, r.branches, r.pos_devices,
       s.id AS subscription_id, pv.product_code AS plan_code, pv.version AS plan_version, s.billing_period,
       s.status AS subscription_status, s.covered_through
  FROM platform.tenant t
  LEFT JOIN platform.tenant_placement p ON p.tenant_id = t.id
  LEFT JOIN platform.tenant_runtime r ON r.tenant_id = t.id
  LEFT JOIN platform.subscription s ON s.tenant_id = t.id AND s.status <> 'cancelled'
  LEFT JOIN platform.product_version pv ON pv.id = s.plan_version_id;

CREATE OR REPLACE VIEW platform.v_tenant_backup_status WITH (security_invoker = true) AS
SELECT t.id AS tenant_id, t.slug, t.deployment, p.cell_id,
       (SELECT max(b.last_full_at) FROM platform.cell_backup_status b WHERE b.cell_id = p.cell_id)         AS cell_last_full_at,
       (SELECT max(b.wal_archive_age_s) FROM platform.cell_backup_status b WHERE b.cell_id = p.cell_id)    AS cell_wal_archive_age_s,
       coalesce(cd.finished_at, i.last_drill_at)                                                         AS last_drill_at,
       coalesce(cd.outcome = 'succeeded' AND cd.control_totals_match, i.last_drill_ok)                   AS last_drill_ok,
       i.last_backup_at                                                                                  AS onprem_last_backup_at,
       o.export_delivered_at, o.archive_verified_at
  FROM platform.tenant t
  LEFT JOIN platform.tenant_placement p ON p.tenant_id = t.id
  LEFT JOIN LATERAL (SELECT d.* FROM platform.backup_drill d WHERE d.cell_id = p.cell_id AND d.finished_at IS NOT NULL
                     ORDER BY d.finished_at DESC LIMIT 1) cd ON true
  LEFT JOIN platform.installation i ON i.tenant_id = t.id AND i.status = 'active'
  LEFT JOIN platform.tenant_offboarding o ON o.tenant_id = t.id;

CREATE OR REPLACE VIEW platform.v_invoice_outstanding WITH (security_invoker = true) AS
SELECT i.id AS invoice_id, i.number, i.tenant_id, i.reseller_id, i.billing_account_id, i.issue_date, i.due_date,
       i.total, i.paid_amount, i.total - i.paid_amount AS outstanding,
       greatest(current_date - i.due_date, 0) AS days_overdue
  FROM platform.invoice i
 WHERE i.kind = 'invoice' AND i.status = 'issued';

-- MRR (ریال، ماهانه‌شده) از دورهٔ پرداخت‌شدهٔ جاری؛ ماه جلالی در لایهٔ پایتون ساخته می‌شود
CREATE OR REPLACE VIEW platform.v_subscription_mrr WITH (security_invoker = true) AS
SELECT s.id AS subscription_id, s.tenant_id, s.reseller_id, pv.product_code AS plan_code, t.period_start, t.period_end,
       sum(l.amount - l.discount) AS term_net,
       round(sum(l.amount - l.discount) / greatest(round((t.period_end - t.period_start) / 30.4375), 1)) AS mrr
  FROM platform.subscription s
  JOIN platform.product_version pv ON pv.id = s.plan_version_id
  JOIN platform.subscription_term t ON t.subscription_id = s.id AND t.kind = 'paid' AND t.status = 'active'
                                   AND t.period_start <= current_date AND t.period_end > current_date
  JOIN platform.invoice_line l ON l.invoice_id = t.invoice_id AND l.line_kind IN ('subscription','addon','extra_units')
  JOIN platform.tenant tn ON tn.id = s.tenant_id AND NOT tn.is_internal
 WHERE s.status <> 'cancelled'
 GROUP BY s.id, s.tenant_id, s.reseller_id, pv.product_code, t.period_start, t.period_end;

CREATE OR REPLACE VIEW platform.v_revenue_daily WITH (security_invoker = true) AS
SELECT i.issue_date,
       sum(CASE i.kind WHEN 'invoice' THEN i.subtotal - i.discount_total ELSE -(i.subtotal - i.discount_total) END) AS net_revenue,
       sum(CASE i.kind WHEN 'invoice' THEN i.vat_total ELSE -i.vat_total END) AS vat,
       count(*) FILTER (WHERE i.kind = 'invoice') AS invoices,
       count(*) FILTER (WHERE i.kind = 'credit_note') AS credit_notes
  FROM platform.invoice i
  LEFT JOIN platform.tenant t ON t.id = i.tenant_id
 WHERE i.status IN ('issued','paid') AND NOT coalesce(t.is_internal, false)
 GROUP BY i.issue_date;

-- باید همیشه خالی باشد (ماندهٔ کیف پول = جمع دفتر آن)
CREATE OR REPLACE VIEW platform.v_wallet_integrity WITH (security_invoker = true) AS
SELECT w.id AS wallet_id, w.balance, coalesce(sum(e.amount), 0) AS ledger_sum, w.last_seq, count(e.id) AS entries
  FROM platform.wallet w LEFT JOIN platform.wallet_entry e ON e.wallet_id = w.id
 GROUP BY w.id, w.balance, w.last_seq
HAVING w.balance <> coalesce(sum(e.amount), 0) OR w.last_seq <> count(e.id);

CREATE OR REPLACE VIEW platform.v_moadian_attention WITH (security_invoker = true) AS
SELECT DISTINCT ON (m.tenant_id) m.tenant_id, t.slug, m.day, m.pending, m.near_deadline, m.overdue, m.rejected,
       m.oldest_pending_issued_at, m.cert_expires_on, m.signer_mode, m.signer_online, m.top_error_codes
  FROM platform.moadian_tenant_stat m JOIN platform.tenant t ON t.id = m.tenant_id
 WHERE m.near_deadline > 0 OR m.overdue > 0 OR m.rejected > 0 OR m.signer_online IS FALSE
    OR (m.cert_expires_on IS NOT NULL AND m.cert_expires_on < m.day + 30)
 ORDER BY m.tenant_id, m.day DESC;

CREATE OR REPLACE VIEW platform.v_migration_top_issues WITH (security_invoker = true) AS
SELECT s.source_system, i.key AS issue_code, sum(i.value::bigint) AS occurrences, count(DISTINCT s.tenant_id) AS tenants
  FROM platform.migration_job_stat s CROSS JOIN LATERAL jsonb_each_text(s.issues_by_code) i
 WHERE s.updated_at > now() - interval '30 days' AND i.value ~ '^[0-9]+$'
 GROUP BY s.source_system, i.key;

CREATE OR REPLACE VIEW platform.v_reseller_balance WITH (security_invoker = true) AS
SELECT r.id AS reseller_id, r.code, coalesce(w.balance, 0) AS balance,
       coalesce((SELECT sum(p.amount) FROM platform.payout p WHERE p.reseller_id = r.id AND p.status IN ('submitted','approved')), 0) AS pending_payouts
  FROM platform.reseller r LEFT JOIN platform.wallet w ON w.reseller_id = r.id;

-- آخرین نسخه‌ای که هر نصب On-prem مجاز است نصب کند (release_date ≤ updates_until، همان قاعدهٔ hkctl؛ INV-OPS-08)
CREATE OR REPLACE VIEW platform.v_installation_update_eligibility WITH (security_invoker = true) AS
SELECT i.id AS installation_id, i.tenant_id, i.app_version, l.id AS license_id, l.updates_until, l.channel,
       (SELECT r.version FROM platform.release r
         WHERE r.status = 'published' AND r.release_date <= l.updates_until
           AND (r.channel = l.channel OR (l.channel = 'stable' AND r.channel = 'lts'))
         ORDER BY platform.calver_key(r.version) DESC LIMIT 1) AS latest_allowed_version
  FROM platform.installation i
  JOIN platform.license l ON l.installation_id = i.id AND l.status = 'issued'
 WHERE i.status = 'active';

-- الگوی فعال بدون کد تأییدشده نزد یک حساب فعال (داشبورد سلامت پیامک؛ خالی = failover آماده)
CREATE OR REPLACE VIEW platform.v_sms_template_coverage WITH (security_invoker = true) AS
SELECT t.key AS template_key, t.purpose, a.id AS provider_account_id, a.provider, a.role,
       coalesce(c.approval_status, 'missing') AS approval_status
  FROM platform.sms_template t
 CROSS JOIN platform.sms_provider_account a
  LEFT JOIN platform.sms_template_code c ON c.template_key = t.key AND c.provider_account_id = a.id
 WHERE t.status = 'active' AND a.status = 'active' AND coalesce(c.approval_status, 'missing') <> 'approved';

-- مصرف روزانهٔ دستیار هر مستأجر (داشبورد هزینه در برابر درآمد افزونه)
CREATE OR REPLACE VIEW platform.v_ai_usage_daily WITH (security_invoker = true) AS
SELECT u.day, u.tenant_id,
       coalesce(sum(u.quantity) FILTER (WHERE u.metric = 'ai.tokens'), 0) AS tokens,
       coalesce(sum(u.quantity) FILTER (WHERE u.metric = 'ai.cost'), 0)   AS cost_irr,
       coalesce(sum(u.quantity) FILTER (WHERE u.metric = 'ai.runs'), 0)   AS runs
  FROM platform.usage_daily u
 WHERE u.metric IN ('ai.tokens','ai.cost','ai.runs')
 GROUP BY u.day, u.tenant_id;

-- =====================================================================
-- ۲۴. نگهبان کنشگر ممیزی و مسیرهای نوشتن نقش‌های محدود
-- =====================================================================
CREATE OR REPLACE FUNCTION platform.audit_actor_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF current_user = 'hk_partner_app' AND (NEW.actor_kind <> 'reseller_user' OR NEW.actor_id IS DISTINCT FROM platform.current_reseller_user_id()
                                          OR NEW.reseller_id IS DISTINCT FROM platform.current_reseller_id()) THEN
    PERFORM platform.fail('HK_PLT_AUDIT_ACTOR', 'partner audit rows describe the acting reseller user');
  END IF;
  IF current_user = 'hk_platform_ingest' AND NEW.actor_kind NOT IN ('cell','installation','system') THEN
    PERFORM platform.fail('HK_PLT_AUDIT_ACTOR', 'ingest audit rows describe a cell or installation');
  END IF;
  IF current_user = 'hk_platform_app' AND NEW.actor_kind = 'staff' AND NEW.actor_id IS DISTINCT FROM platform.current_staff_id() THEN
    PERFORM platform.fail('HK_PLT_AUDIT_ACTOR', 'staff audit rows describe the acting staff member');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_actor ON platform.audit_log;    -- نام trg_actor پیش از trg_seal اجرا می‌شود (ترتیب الفبایی)
CREATE TRIGGER trg_actor BEFORE INSERT ON platform.audit_log FOR EACH ROW EXECUTE FUNCTION platform.audit_actor_guard();

CREATE OR REPLACE FUNCTION platform.restricted_writer_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF current_user <> 'hk_partner_app' THEN
    RETURN NEW;
  END IF;
  -- (هر جدول ستون‌های خودش را دارد؛ شرط‌ها تودرتو تا فیلد جدول دیگر خوانده نشود)
  IF TG_TABLE_NAME = 'job' THEN
    IF NEW.kind !~ '^partner\.' AND NOT platform.is_nested() THEN
      PERFORM platform.fail('HK_PLT_PARTNER_SCOPE', 'partner may only enqueue partner.* jobs');
    END IF;
  ELSIF TG_TABLE_NAME = 'license_activation' THEN
    IF NEW.received_via <> 'partner_portal' OR NEW.received_by_staff IS NOT NULL
       OR NEW.received_by_reseller_user IS DISTINCT FROM platform.current_reseller_user_id() THEN
      PERFORM platform.fail('HK_PLT_PARTNER_SCOPE', 'partner activations are received by the acting reseller user');
    END IF;
  ELSIF TG_TABLE_NAME = 'impersonation_request' THEN
    IF NEW.reseller_user_id IS DISTINCT FROM platform.current_reseller_user_id() THEN
      PERFORM platform.fail('HK_PLT_PARTNER_SCOPE', 'partner impersonation is requested by the acting reseller user');
    END IF;
  ELSIF TG_TABLE_NAME = 'ticket_message' THEN
    IF NEW.author_kind <> 'reseller_user' OR NEW.author_ref IS DISTINCT FROM platform.current_reseller_user_id() THEN
      PERFORM platform.fail('HK_PLT_PARTNER_SCOPE', 'partner messages are authored by the acting reseller user');
    END IF;
  ELSIF TG_TABLE_NAME = 'payout' THEN
    IF TG_OP = 'INSERT' THEN
      IF NEW.requested_by_kind <> 'reseller_user' OR NEW.requested_by_id IS DISTINCT FROM platform.current_reseller_user_id() THEN
        PERFORM platform.fail('HK_PLT_PARTNER_SCOPE', 'partner payouts are requested by the acting reseller user');
      END IF;
    ELSIF NEW.status NOT IN ('draft','submitted','cancelled') THEN
      PERFORM platform.fail('HK_PLT_PARTNER_SCOPE', 'partner may only submit or cancel payouts');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_a_scope ON platform.job;
CREATE TRIGGER trg_a_scope BEFORE INSERT ON platform.job FOR EACH ROW EXECUTE FUNCTION platform.restricted_writer_guard();
DROP TRIGGER IF EXISTS trg_a_scope ON platform.license_activation;
CREATE TRIGGER trg_a_scope BEFORE INSERT ON platform.license_activation FOR EACH ROW EXECUTE FUNCTION platform.restricted_writer_guard();
DROP TRIGGER IF EXISTS trg_a_scope ON platform.impersonation_request;
CREATE TRIGGER trg_a_scope BEFORE INSERT ON platform.impersonation_request FOR EACH ROW EXECUTE FUNCTION platform.restricted_writer_guard();
DROP TRIGGER IF EXISTS trg_a_scope ON platform.ticket_message;
CREATE TRIGGER trg_a_scope BEFORE INSERT ON platform.ticket_message FOR EACH ROW EXECUTE FUNCTION platform.restricted_writer_guard();
DROP TRIGGER IF EXISTS trg_a_scope ON platform.payout;
CREATE TRIGGER trg_a_scope BEFORE INSERT OR UPDATE ON platform.payout FOR EACH ROW EXECUTE FUNCTION platform.restricted_writer_guard();

-- =====================================================================
-- ۲۵. کاتالوگ‌های کدی (با migration؛ برنامه فقط می‌خواند)
-- =====================================================================
INSERT INTO platform.staff_role (code, name_fa, name_en, is_privileged, grants_all) VALUES
  ('owner',                'مالک',                      'Owner',               true,  true),
  ('admin',                'مدیر',                      'Admin',               true,  false),
  ('support',              'پشتیبانی',                  'Support',             false, false),
  ('finance',              'مالی',                      'Finance',             false, false),
  ('sales',                'فروش',                      'Sales',               false, false),
  ('reseller_manager',     'مدیر نمایندگان',             'Reseller manager',    false, false),
  ('read_only',            'فقط‌خواندنی',               'Read-only',           false, false),
  ('compliance_tax',       'کارشناس مالیات',             'Tax compliance',      false, false),
  ('compliance_payroll',   'کارشناس حقوق و دستمزد',      'Payroll compliance',  false, false),
  ('migration_specialist', 'کارشناس انتقال داده',        'Migration specialist',false, false),
  ('release_manager',      'مدیر انتشار',               'Release manager',     false, false)
ON CONFLICT (code) DO NOTHING;

INSERT INTO platform.staff_permission (code, risk, description) VALUES
  ('platform.staff.read', 'normal', 'دیدن کارکنان'),
  ('platform.staff.manage', 'sensitive', 'دعوت، تعلیق و انتساب نقش'),
  ('platform.staff.role.approve', 'critical', 'تأیید اعطای نقش ممتاز'),
  ('platform.tenant.read', 'normal', 'دیدن مستأجران'),
  ('platform.tenant.manage', 'sensitive', 'ساخت و ویرایش مستأجر'),
  ('platform.tenant.lifecycle', 'sensitive', 'تغییر وضعیت چرخهٔ عمر'),
  ('platform.tenant.placement', 'sensitive', 'جای‌گذاری و جابه‌جایی'),
  ('platform.tenant.legal_hold', 'sensitive', 'گذاشتن توقیف قانونی'),
  ('platform.tenant.legal_hold.release.approve', 'critical', 'تأیید آزادسازی توقیف قانونی'),
  ('platform.tenant.purge.approve', 'critical', 'تأیید پاک‌سازی مستأجر'),
  ('platform.tenant.restore.approve', 'critical', 'تأیید بازگردانی از بایگانی'),
  ('platform.catalog.read', 'normal', 'دیدن پلن و قیمت'),
  ('platform.catalog.manage', 'sensitive', 'ساخت پیش‌نویس پلن و قیمت'),
  ('platform.price.publish.approve', 'critical', 'تأیید انتشار قیمت'),
  ('platform.billing.read', 'normal', 'دیدن صورتحساب و پرداخت'),
  ('platform.billing.manage', 'sensitive', 'صدور صورتحساب و یادداشت اعتباری'),
  ('platform.billing.payment.record', 'sensitive', 'ثبت واریز بانکی'),
  ('platform.billing.coupon.manage', 'sensitive', 'مدیریت کوپن'),
  ('platform.billing.refund.request', 'sensitive', 'درخواست بازپرداخت'),
  ('platform.billing.refund.approve', 'critical', 'تأیید بازپرداخت'),
  ('platform.billing.invoice.void.approve', 'critical', 'تأیید ابطال صورتحساب'),
  ('platform.billing.wallet.adjust.approve', 'critical', 'تأیید اصلاح دستی کیف پول'),
  ('platform.billing.comp.approve', 'critical', 'تأیید دورهٔ هدیه'),
  ('platform.support.read', 'normal', 'دیدن رضایت‌ها و تیکت‌ها'),
  ('platform.support.impersonate', 'sensitive', 'ورود به‌جای کاربر با رضایت'),
  ('platform.support.impersonate_write.approve', 'critical', 'تأیید ورود نوشتنی'),
  ('platform.ticket.manage', 'normal', 'پاسخ و ارجاع تیکت'),
  ('platform.announcement.manage', 'normal', 'اطلاعیه'),
  ('platform.announcement.sms.approve', 'critical', 'تأیید پیامک انبوه'),
  ('platform.reseller.read', 'normal', 'دیدن نمایندگان'),
  ('platform.reseller.manage', 'sensitive', 'مدیریت نماینده، قلمرو و کمیسیون'),
  ('platform.reseller.payout.approve', 'critical', 'تأیید تسویهٔ نماینده'),
  ('platform.reseller.commission.adjust.approve', 'critical', 'تأیید اصلاح کمیسیون'),
  ('platform.reseller.quota.adjust.approve', 'critical', 'تأیید اصلاح سهمیهٔ لایسنس'),
  ('platform.license.read', 'normal', 'دیدن لایسنس و نصب'),
  ('platform.license.manage', 'sensitive', 'پیش‌نویس و پاسخ فعال‌سازی'),
  ('platform.license.issue.approve', 'critical', 'تأیید صدور لایسنس'),
  ('platform.license.revoke.approve', 'critical', 'تأیید ابطال لایسنس'),
  ('platform.rules.read', 'normal', 'دیدن بسته‌های قواعد'),
  ('platform.rules.author', 'sensitive', 'تألیف بستهٔ قواعد'),
  ('platform.rules.publish', 'critical', 'انتشار بستهٔ قواعد'),
  ('platform.pack.read', 'normal', 'دیدن بستهٔ صنفی'),
  ('platform.pack.author', 'sensitive', 'تألیف بستهٔ صنفی'),
  ('platform.pack.review', 'critical', 'بازبینی و انتشار بستهٔ صنفی'),
  ('platform.migration.read', 'normal', 'مرکز مهاجرت'),
  ('platform.migration.dictionary.publish', 'sensitive', 'تأیید و انتشار فرهنگ نگاشت'),
  ('platform.migration.profile.publish', 'sensitive', 'انتشار پروفایل مهاجرت'),
  ('platform.migration.service_order.manage', 'normal', 'سفارش خدمت مهاجرت و نصب'),
  ('platform.release.read', 'normal', 'دیدن انتشارها'),
  ('platform.release.manage', 'sensitive', 'مدیریت انتشار و rollout'),
  ('platform.release.approve', 'critical', 'تأیید دستی حلقهٔ ۲'),
  ('platform.ops.read', 'normal', 'سلامت، پشتیبان، پایش مؤدیان'),
  ('platform.ops.command', 'sensitive', 'فرمان به سلول'),
  ('platform.data_request.manage', 'sensitive', 'ثبت و بررسی درخواست داده'),
  ('platform.data_request.approve', 'critical', 'تأیید حذف دادهٔ شخصی'),
  ('platform.audit.read', 'normal', 'ممیزی پلتفرم'),
  ('platform.analytics.read', 'normal', 'تحلیل درآمد و مصرف'),
  ('platform.flag.manage', 'sensitive', 'پرچم ویژگی و kill switch'),
  ('platform.ai.manage', 'sensitive', 'ارائه‌دهندهٔ مدل دستیار، سیاست و استثنای مستأجر'),
  ('platform.ai.approve', 'critical', 'تأیید فعال‌سازی ارائه‌دهنده و استثنای بازکنندهٔ دستیار'),
  ('platform.sms.manage', 'sensitive', 'حساب سرویس‌دهندهٔ پیامک و نگاشت الگو')
ON CONFLICT (code) DO NOTHING;

INSERT INTO platform.staff_role_permission (role_code, permission_code)
SELECT 'admin', code FROM platform.staff_permission WHERE code <> 'platform.staff.role.approve'
UNION ALL
SELECT 'read_only', code FROM platform.staff_permission WHERE code LIKE '%.read' OR code = 'platform.analytics.read'
UNION ALL
SELECT r, p FROM (VALUES
  ('support','platform.tenant.read'), ('support','platform.support.read'), ('support','platform.support.impersonate'),
  ('support','platform.ticket.manage'), ('support','platform.ops.read'), ('support','platform.license.read'),
  ('support','platform.migration.read'), ('support','platform.billing.read'), ('support','platform.data_request.manage'),
  ('support','platform.reseller.read'),
  ('finance','platform.tenant.read'), ('finance','platform.catalog.read'), ('finance','platform.billing.read'),
  ('finance','platform.billing.manage'), ('finance','platform.billing.payment.record'), ('finance','platform.billing.refund.request'),
  ('finance','platform.billing.refund.approve'), ('finance','platform.billing.invoice.void.approve'),
  ('finance','platform.billing.wallet.adjust.approve'), ('finance','platform.billing.comp.approve'),
  ('finance','platform.reseller.read'), ('finance','platform.reseller.payout.approve'),
  ('finance','platform.reseller.commission.adjust.approve'), ('finance','platform.analytics.read'), ('finance','platform.license.read'),
  ('sales','platform.tenant.read'), ('sales','platform.tenant.manage'), ('sales','platform.catalog.read'), ('sales','platform.catalog.manage'),
  ('sales','platform.billing.read'), ('sales','platform.billing.coupon.manage'), ('sales','platform.reseller.read'),
  ('sales','platform.license.read'), ('sales','platform.license.manage'), ('sales','platform.analytics.read'),
  ('reseller_manager','platform.reseller.read'), ('reseller_manager','platform.reseller.manage'),
  ('reseller_manager','platform.reseller.quota.adjust.approve'), ('reseller_manager','platform.tenant.read'),
  ('reseller_manager','platform.license.read'), ('reseller_manager','platform.license.manage'),
  ('reseller_manager','platform.migration.service_order.manage'), ('reseller_manager','platform.analytics.read'),
  ('compliance_tax','platform.rules.read'), ('compliance_tax','platform.rules.author'), ('compliance_tax','platform.pack.read'),
  ('compliance_tax','platform.pack.author'), ('compliance_tax','platform.pack.review'), ('compliance_tax','platform.ops.read'),
  ('compliance_tax','platform.tenant.read'),
  ('compliance_payroll','platform.rules.read'), ('compliance_payroll','platform.rules.author'), ('compliance_payroll','platform.pack.read'),
  ('migration_specialist','platform.migration.read'), ('migration_specialist','platform.migration.dictionary.publish'),
  ('migration_specialist','platform.migration.profile.publish'), ('migration_specialist','platform.migration.service_order.manage'),
  ('migration_specialist','platform.tenant.read'), ('migration_specialist','platform.support.read'),
  ('migration_specialist','platform.support.impersonate'), ('migration_specialist','platform.ticket.manage'),
  ('release_manager','platform.release.read'), ('release_manager','platform.release.manage'), ('release_manager','platform.release.approve'),
  ('release_manager','platform.ops.read'), ('release_manager','platform.ops.command')
) v(r, p)
ON CONFLICT DO NOTHING;

INSERT INTO platform.approval_action (code, subject_type, approver_permission, ttl, description_fa) VALUES
  ('tenant.purge',               'tenant',                'platform.tenant.purge.approve',              interval '24 hours', 'پاک‌سازی دادهٔ مستأجر از سلول'),
  ('tenant.restore_archive',     'tenant',                'platform.tenant.restore.approve',            interval '24 hours', 'بازگردانی مستأجر بایگانی‌شده'),
  ('tenant.legal_hold_release',  'legal_hold',            'platform.tenant.legal_hold.release.approve', interval '24 hours', 'آزادسازی توقیف قانونی'),
  ('staff.grant_privileged_role','staff',                 'platform.staff.role.approve',                interval '24 hours', 'اعطای نقش مالک/مدیر'),
  ('price.publish',              'product_version',       'platform.price.publish.approve',             interval '72 hours', 'انتشار قیمت و پلن'),
  ('invoice.void',               'invoice',               'platform.billing.invoice.void.approve',      interval '24 hours', 'ابطال صورتحساب پرداخت‌نشده'),
  ('refund.execute',             'refund',                'platform.billing.refund.approve',            interval '24 hours', 'بازپرداخت وجه'),
  ('wallet.manual_adjustment',   'wallet',                'platform.billing.wallet.adjust.approve',     interval '24 hours', 'اصلاح دستی کیف پول'),
  ('subscription.comp_term',     'subscription',          'platform.billing.comp.approve',              interval '72 hours', 'دورهٔ هدیه'),
  ('payout.approve',             'payout',                'platform.reseller.payout.approve',           interval '72 hours', 'تسویهٔ کمیسیون نماینده'),
  ('commission.adjustment',      'reseller',              'platform.reseller.commission.adjust.approve',interval '72 hours', 'اصلاح دستی کمیسیون'),
  ('reseller.quota_adjustment',  'reseller',              'platform.reseller.quota.adjust.approve',     interval '72 hours', 'اصلاح سهمیهٔ لایسنس'),
  ('license.issue',              'license',               'platform.license.issue.approve',             interval '72 hours', 'صدور لایسنس On-prem'),
  ('license.revoke',             'license',               'platform.license.revoke.approve',            interval '24 hours', 'ابطال لایسنس'),
  ('impersonation.write',        'impersonation_request', 'platform.support.impersonate_write.approve', interval '30 minutes','ورود نوشتنی به‌جای کاربر'),
  ('announcement.sms_broadcast', 'announcement',          'platform.announcement.sms.approve',          interval '24 hours', 'پیامک انبوه'),
  ('data_request.erasure',       'data_request',          'platform.data_request.approve',              interval '72 hours', 'حذف/بی‌نام‌سازی دادهٔ شخصی'),
  ('ai_provider.activate',       'ai_provider',           'platform.ai.approve',                        interval '24 hours', 'فعال‌سازی ارائه‌دهندهٔ مدل دستیار'),
  ('ai.tenant_override',         'tenant',                'platform.ai.approve',                        interval '24 hours', 'روشن‌کردن یا افزایش سقف دستیار برای مستأجر')
ON CONFLICT (code) DO NOTHING;

INSERT INTO platform.tenant_lifecycle_transition (from_status, to_status, actor_kinds, approval_action) VALUES
  ('provisioning','trial',     '{system}',               NULL),
  ('provisioning','active',    '{system,staff}',         NULL),
  ('provisioning','purged',    '{system,staff}',         NULL),
  ('trial',       'active',    '{system,staff}',         NULL),
  ('trial',       'read_only', '{system}',               NULL),
  ('trial',       'cancelled', '{system,staff,tenant}',  NULL),
  ('trial',       'suspended', '{staff}',                NULL),
  ('active',      'past_due',  '{system}',               NULL),
  ('active',      'read_only', '{system,staff}',         NULL),
  ('active',      'cancelled', '{system,staff,tenant}',  NULL),
  ('active',      'suspended', '{staff}',                NULL),
  ('past_due',    'active',    '{system,staff}',         NULL),
  ('past_due',    'read_only', '{system}',               NULL),
  ('past_due',    'cancelled', '{system,staff,tenant}',  NULL),
  ('past_due',    'suspended', '{staff}',                NULL),
  ('read_only',   'active',    '{system,staff}',         NULL),
  ('read_only',   'cancelled', '{system,staff,tenant}',  NULL),
  ('read_only',   'suspended', '{staff}',                NULL),
  ('suspended',   'active',    '{staff}',                NULL),
  ('suspended',   'read_only', '{staff}',                NULL),
  ('suspended',   'cancelled', '{staff}',                NULL),
  ('cancelled',   'active',    '{system,staff}',         NULL),
  ('cancelled',   'archived',  '{system,staff}',         NULL),
  ('archived',    'active',    '{staff}',                'tenant.restore_archive'),
  ('archived',    'purging',   '{staff}',                'tenant.purge'),
  ('purging',     'purged',    '{system}',               NULL)
ON CONFLICT DO NOTHING;

INSERT INTO platform.feature (key, kind, unit, enforcement, data_plane_key, description_fa, introduced_in) VALUES
  ('module.accounting',          'flag',  NULL,        'data_plane',    'modules.accounting',   'حسابداری و دفتر کل', '2026.11.0'),
  ('module.inventory',           'flag',  NULL,        'data_plane',    'modules.inventory',    'انبار', '2026.11.0'),
  ('module.sales',               'flag',  NULL,        'data_plane',    'modules.sales',        'فروش', '2026.11.0'),
  ('module.purchase',            'flag',  NULL,        'data_plane',    'modules.purchase',     'خرید', '2026.11.0'),
  ('module.treasury',            'flag',  NULL,        'data_plane',    'modules.treasury',     'خزانه و بانک', '2026.11.0'),
  ('module.cheque',              'flag',  NULL,        'data_plane',    'modules.cheque',       'چک', '2026.11.0'),
  ('module.pos',                 'flag',  NULL,        'data_plane',    'modules.pos',          'صندوق فروشگاهی', '2026.11.0'),
  ('module.payroll',             'flag',  NULL,        'data_plane',    'modules.payroll',      'حقوق و دستمزد', '2026.11.0'),
  ('module.assets',              'flag',  NULL,        'data_plane',    'modules.assets',       'دارایی ثابت', '2026.11.0'),
  ('module.moadian',             'flag',  NULL,        'data_plane',    'modules.moadian',      'سامانهٔ مؤدیان', '2026.11.0'),
  ('module.multi_currency',      'flag',  NULL,        'data_plane',    'modules.multi_currency','چندارزی', '2026.11.0'),
  ('module.migration',           'flag',  NULL,        'data_plane',    'modules.migration',    'انتقال داده', '2026.11.0'),
  ('ai.assistant',               'flag',  NULL,        'data_plane',    'ai.assistant',         'دستیار هوشمند (Q-F)', '2026.11.0'),
  ('sms.platform_line',          'flag',  NULL,        'data_plane',    'sms.platform_line',    'پیامک با خط پلتفرم', '2026.11.0'),
  ('sms.byo',                    'flag',  NULL,        'data_plane',    'sms.byo',              'پنل پیامک خود مستأجر', '2026.11.0'),
  ('pack.general',               'flag',  NULL,        'data_plane',    'packs.general',        'بستهٔ عمومی', '2026.11.0'),
  ('pack.cafe',                  'flag',  NULL,        'data_plane',    'packs.cafe',           'بستهٔ کافه و رستوران', '2026.11.0'),
  ('pack.retail_apparel',        'flag',  NULL,        'data_plane',    'packs.retail_apparel', 'بستهٔ کفش و پوشاک', '2026.11.0'),
  ('pack.retail_electrical',     'flag',  NULL,        'data_plane',    'packs.retail_electrical','بستهٔ کالای برق', '2026.11.0'),
  ('catalog.variants',           'flag',  NULL,        'data_plane',    'catalog.variants',     'کالای چندمتغیره', '2026.11.0'),
  ('catalog.scale_barcode',      'flag',  NULL,        'data_plane',    'catalog.scale_barcode','بارکد ترازو', '2026.11.0'),
  ('catalog.bom',                'flag',  NULL,        'data_plane',    'catalog.bom',          'دستور ساخت', '2026.11.0'),
  ('catalog.price_lists.multi',  'flag',  NULL,        'data_plane',    'catalog.price_lists.multi','چند فهرست قیمت', '2026.11.0'),
  ('parties.bank_inquiry',       'flag',  NULL,        'data_plane',    'parties.bank_inquiry', 'استعلام شبا', '2026.11.0'),
  ('export.scheduled',           'flag',  NULL,        'control_plane', NULL,                   'بستهٔ صادراتی زمان‌بندی‌شده', '2026.11.0'),
  ('limit.users',                'limit', 'count',     'data_plane',    'users',                'کاربر فعال', '2026.11.0'),
  ('limit.companies',            'limit', 'count',     'data_plane',    'companies',            'شرکت', '2026.11.0'),
  ('limit.branches',             'limit', 'count',     'data_plane',    'branches',             'شعبه', '2026.11.0'),
  ('limit.pos_devices',          'limit', 'count',     'data_plane',    'pos_devices',          'دستگاه صندوق', '2026.11.0'),
  ('limit.warehouses',           'limit', 'count',     'data_plane',    'warehouses',           'انبار', '2026.11.0'),
  ('limit.invoices_per_month',   'limit', 'per_month', 'data_plane',    'invoices_per_month',   'فاکتور در ماه', '2026.11.0'),
  ('limit.storage_gb',           'limit', 'gb',        'data_plane',    'storage_gb',           'فضای ذخیره', '2026.11.0'),
  ('limit.support_sla_hours',    'limit', 'hours',     'control_plane', NULL,                   'SLA پاسخ تیکت', '2026.11.0'),
  ('meter.sms_parts',            'meter', 'parts',     'both',          'credit.sms_parts',     'بخش پیامک خط پلتفرم', '2026.11.0'),
  ('meter.inquiry_calls',        'meter', 'calls',     'both',          'credit.inquiry_calls', 'استعلام پولی', '2026.11.0'),
  ('meter.invoices_issued',      'meter', 'count',     'control_plane', NULL,                   'فاکتور صادره (مصرف)', '2026.11.0'),
  ('meter.moadian_sent',         'meter', 'count',     'control_plane', NULL,                   'ارسال به مؤدیان', '2026.11.0'),
  -- دستیار (C-AS-07): از رویداد assistant.run.metered؛ idempotent بر (tenant_id, event_id)
  ('ai.tokens',                  'meter', 'tokens',    'both',          'ai.tokens',            'توکن مصرفی دستیار', '2026.11.0'),
  ('ai.cost',                    'meter', 'irr',       'control_plane', NULL,                   'هزینهٔ تمام‌شدهٔ دستیار (ریال صحیح)', '2026.11.0'),
  ('ai.runs',                    'meter', 'count',     'control_plane', NULL,                   'اجرای دستیار', '2026.11.0')
ON CONFLICT (key) DO NOTHING;

-- پرچم سراسری دستیار (ops_kill_switch؛ اهداف cell/plan/tenant). جدول feature_flag کاتالوگ کدی نیست؛ این فقط بذر اولیه است
INSERT INTO platform.feature_flag (key, description, kind, default_on, rollout_percent, kill_switch)
VALUES ('ff.ai.assistant', 'کلید قطع سراسری دستیار هوشمند (Q-F)', 'ops_kill_switch', true, 0, false)
ON CONFLICT (key) DO NOTHING;

-- =====================================================================
-- ۲۶. دسترسی نقش‌ها (کمینه) و RLS نماینده
-- =====================================================================
GRANT SELECT ON ALL TABLES IN SCHEMA platform TO hk_platform_app, hk_platform_readonly;
REVOKE SELECT ON platform.staff_session, platform.idempotency_key FROM hk_platform_readonly;
GRANT SELECT (id, staff_id, amr, mfa_at, ip, user_agent, created_at, expires_at, last_seen_at, revoked_at, revoke_reason)
  ON platform.staff_session TO hk_platform_readonly;
GRANT SELECT (principal_kind, principal_id, key, method, path, response_status, created_at, expires_at)
  ON platform.idempotency_key TO hk_platform_readonly;
GRANT SELECT, UPDATE ON platform.audit_chain_head TO hk_platform_audit_writer;

-- hk_platform_app: نوشتن صریح جدول‌به‌جدول (فقط‌افزودنی‌ها فقط INSERT؛ کاتالوگ‌ها هیچ)
GRANT INSERT, UPDATE ON
  platform.staff, platform.staff_role_assignment, platform.staff_session, platform.approval_request,
  platform.number_counter, platform.reseller_tier, platform.reseller, platform.reseller_user,
  platform.cell, platform.tenant, platform.tenant_legal_hold, platform.tenant_offboarding, platform.tenant_placement,
  platform.tenant_runtime, platform.cell_command, platform.release, platform.cell_rollout, platform.client_release,
  platform.product, platform.tenant_entitlement_override, platform.feature_flag, platform.service_tariff, platform.ai_provider,
  platform.billing_account, platform.subscription, platform.subscription_item, platform.coupon, platform.house_sync,
  platform.wallet, platform.gateway_account, platform.payment, platform.subscription_term, platform.refund,
  platform.reconciliation_item, platform.reminder, platform.payout, platform.service_order, platform.ticket,
  platform.impersonation_request, platform.announcement, platform.installation, platform.license, platform.license_activation,
  platform.rules_package, platform.rules_distribution, platform.industry_pack, platform.migration_dictionary_release,
  platform.migration_profile_release, platform.dependency_status, platform.data_request, platform.usage_daily,
  platform.migration_dictionary_candidate, platform.ai_tenant_override, platform.sms_provider_account, platform.sms_template,
  platform.sms_template_code
TO hk_platform_app;
GRANT INSERT, UPDATE, DELETE ON
  platform.job, platform.idempotency_key, platform.reseller_territory, platform.commission_rule,
  platform.product_version, platform.price, platform.price_component, platform.product_entitlement,
  platform.feature_flag_target, platform.invoice, platform.invoice_line, platform.rules_value, platform.rules_golden_test,
  platform.industry_pack_version, platform.ai_provider_price, platform.ai_plan_policy
TO hk_platform_app;
GRANT INSERT ON
  platform.audit_log, platform.audit_checkpoint, platform.tenant_lifecycle_event, platform.routing_snapshot,
  platform.desired_state, platform.cell_state, platform.wallet_entry, platform.invoice_settlement, platform.payment_event,
  platform.credit_reservation, platform.trial_claim, platform.coupon_redemption, platform.commission_entry,
  platform.reseller_quota_entry, platform.license_revocation, platform.license_crl, platform.license_usage_report,
  platform.rules_review, platform.rules_golden_ci_run, platform.ticket_message, platform.ai_eval_run
TO hk_platform_app;
GRANT UPDATE ON platform.uplink_batch TO hk_platform_app;

-- hk_platform_ingest: فقط آنچه کانال کنترل و uplink لازم دارد
GRANT SELECT ON platform.cell, platform.tenant, platform.tenant_placement, platform.routing_snapshot, platform.desired_state,
  platform.cell_state, platform.cell_command, platform.client_release, platform.license, platform.license_crl, platform.uplink_batch,
  platform.tenant_runtime, platform.installation, platform.support_consent, platform.feature, platform.usage_daily,
  platform.migration_job_stat, platform.migration_dictionary_candidate, platform.moadian_tenant_stat, platform.tenant_audit_anchor,
  platform.cell_backup_status, platform.backup_drill, platform.rules_distribution, platform.impersonation_request,
  platform.ticket, platform.number_counter, platform.job, platform.reseller_user, platform.reseller, platform.release
TO hk_platform_ingest;
GRANT INSERT ON platform.uplink_batch, platform.usage_event, platform.tenant_audit_anchor, platform.backup_drill,
  platform.license_usage_report, platform.migration_dictionary_vote, platform.audit_log, platform.ticket_message, platform.job,
  platform.license_activation
TO hk_platform_ingest;
GRANT INSERT, UPDATE ON platform.usage_daily, platform.migration_job_stat, platform.migration_dictionary_candidate,
  platform.moadian_tenant_stat, platform.cell_backup_status, platform.support_consent, platform.rules_distribution,
  platform.ticket, platform.number_counter
TO hk_platform_ingest;
GRANT INSERT, UPDATE, DELETE ON platform.login_directory TO hk_platform_ingest;
GRANT UPDATE (last_seen_at, app_version, schema_head, state_applied_version) ON platform.cell TO hk_platform_ingest;
GRANT UPDATE (status, attempts) ON platform.cell_command TO hk_platform_ingest;
GRANT UPDATE (applied_version, applied_at, last_uplink_at, last_activity_at, active_users, companies, branches, pos_devices,
              storage_bytes, data_plane_status) ON platform.tenant_runtime TO hk_platform_ingest;
GRANT UPDATE (finished_at, outcome, restored_lsn, control_totals_match, report) ON platform.backup_drill TO hk_platform_ingest;
GRANT UPDATE (status, session_started_at, session_ended_at, end_reason) ON platform.impersonation_request TO hk_platform_ingest;
GRANT UPDATE (app_version, schema_head, last_checkin_at, last_usage_period, last_backup_at, last_drill_at, last_drill_ok, max_seen_at)
  ON platform.installation TO hk_platform_ingest;
GRANT SELECT, INSERT, UPDATE ON platform.idempotency_key TO hk_platform_ingest;

-- hk_partner_app: خواندن با RLS + چند نوشتن محدود (پرتال v1.1؛ Q-E)
GRANT SELECT ON platform.geo_province, platform.geo_city, platform.feature, platform.product, platform.product_version,
  platform.price, platform.price_component, platform.product_entitlement, platform.industry_pack, platform.industry_pack_version,
  platform.reseller, platform.reseller_user, platform.reseller_territory, platform.commission_rule, platform.tenant,
  platform.billing_account, platform.subscription, platform.invoice, platform.invoice_line, platform.wallet, platform.wallet_entry,
  platform.payment, platform.commission_entry, platform.payout, platform.reseller_quota_entry, platform.service_order,
  platform.ticket, platform.ticket_message, platform.support_consent, platform.impersonation_request, platform.installation,
  platform.license, platform.license_activation
TO hk_partner_app;
GRANT INSERT ON platform.audit_log, platform.license_activation, platform.ticket_message, platform.impersonation_request, platform.job
TO hk_partner_app;
GRANT INSERT, UPDATE ON platform.payout TO hk_partner_app;
GRANT UPDATE (status, priority) ON platform.ticket TO hk_partner_app;
GRANT UPDATE (status, notes) ON platform.service_order TO hk_partner_app;
GRANT SELECT, INSERT, UPDATE ON platform.idempotency_key TO hk_partner_app;

-- RLS نماینده
SELECT platform.enable_partner_rls('platform.reseller',               'id = platform.current_reseller_id()');
SELECT platform.enable_partner_rls('platform.reseller_user',          'reseller_id = platform.current_reseller_id()');
SELECT platform.enable_partner_rls('platform.reseller_territory',     'reseller_id = platform.current_reseller_id()');
SELECT platform.enable_partner_rls('platform.commission_rule',
  'reseller_id = platform.current_reseller_id() OR tier_code = (SELECT r.tier_code FROM platform.reseller r WHERE r.id = platform.current_reseller_id())');
SELECT platform.enable_partner_rls('platform.tenant',                 'reseller_id = platform.current_reseller_id()');
SELECT platform.enable_partner_rls('platform.billing_account',
  'reseller_id = platform.current_reseller_id() OR tenant_id IN (SELECT t.id FROM platform.tenant t WHERE t.reseller_id = platform.current_reseller_id())');
SELECT platform.enable_partner_rls('platform.subscription',           'reseller_id = platform.current_reseller_id()');
SELECT platform.enable_partner_rls('platform.invoice',                'reseller_id = platform.current_reseller_id()');
SELECT platform.enable_partner_rls('platform.invoice_line',           'EXISTS (SELECT 1 FROM platform.invoice i WHERE i.id = invoice_id)');
SELECT platform.enable_partner_rls('platform.wallet',                 'reseller_id = platform.current_reseller_id()');
SELECT platform.enable_partner_rls('platform.wallet_entry',           'EXISTS (SELECT 1 FROM platform.wallet w WHERE w.id = wallet_id)');
SELECT platform.enable_partner_rls('platform.payment',                'reseller_id = platform.current_reseller_id()');
SELECT platform.enable_partner_rls('platform.commission_entry',       'reseller_id = platform.current_reseller_id()');
SELECT platform.enable_partner_rls('platform.payout',                 'reseller_id = platform.current_reseller_id()');
SELECT platform.enable_partner_rls('platform.reseller_quota_entry',   'reseller_id = platform.current_reseller_id()');
SELECT platform.enable_partner_rls('platform.service_order',          'assignee_reseller_id = platform.current_reseller_id()');
SELECT platform.enable_partner_rls('platform.ticket',                 'assigned_reseller_id = platform.current_reseller_id()');
SELECT platform.enable_partner_rls('platform.ticket_message',
  'visibility <> ''internal'' AND EXISTS (SELECT 1 FROM platform.ticket t WHERE t.id = ticket_id)');
SELECT platform.enable_partner_rls('platform.support_consent',        'reseller_id = platform.current_reseller_id()');
SELECT platform.enable_partner_rls('platform.impersonation_request',  'reseller_id = platform.current_reseller_id()');
SELECT platform.enable_partner_rls('platform.installation',           'reseller_id = platform.current_reseller_id()');
SELECT platform.enable_partner_rls('platform.license',                'reseller_id = platform.current_reseller_id()');
SELECT platform.enable_partner_rls('platform.license_activation',     'reseller_id = platform.current_reseller_id()');

-- idempotency: هر اصل فقط کلیدهای خودش را می‌بیند
ALTER TABLE platform.idempotency_key ENABLE ROW LEVEL SECURITY;
ALTER TABLE platform.idempotency_key FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS staff_all ON platform.idempotency_key;
CREATE POLICY staff_all ON platform.idempotency_key FOR ALL TO hk_platform_app, hk_platform_readonly USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS partner_own ON platform.idempotency_key;
CREATE POLICY partner_own ON platform.idempotency_key FOR ALL TO hk_partner_app
  USING (principal_kind = 'reseller_user' AND principal_id = platform.current_reseller_user_id())
  WITH CHECK (principal_kind = 'reseller_user' AND principal_id = platform.current_reseller_user_id());
DROP POLICY IF EXISTS ingest_own ON platform.idempotency_key;
CREATE POLICY ingest_own ON platform.idempotency_key FOR ALL TO hk_platform_ingest
  USING (principal_kind IN ('cell','installation')) WITH CHECK (principal_kind IN ('cell','installation'));

-- =====================================================================
-- ۲۷. lint امنیتی ساختاری (CI و پس از هر migration؛ باید خالی باشد)
-- =====================================================================
CREATE OR REPLACE FUNCTION platform.security_lint() RETURNS TABLE (problem text, object text)
LANGUAGE sql STABLE AS $$
  WITH rt(rolname) AS (VALUES ('hk_platform_app'), ('hk_platform_ingest'), ('hk_partner_app'), ('hk_platform_readonly')),
  tbl AS (SELECT c.oid, c.relname, c.relkind, c.relrowsecurity, c.relforcerowsecurity, c.reloptions, c.relowner
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'platform')
  SELECT 'runtime role is superuser/bypassrls/createrole/createdb', r.rolname::text
    FROM pg_roles r WHERE r.rolname IN ('hk_platform_app','hk_platform_ingest','hk_partner_app','hk_platform_readonly','hk_platform_audit_writer')
     AND (r.rolsuper OR r.rolbypassrls OR r.rolcreaterole OR r.rolcreatedb)
  UNION ALL
  SELECT 'audit writer can log in', 'hk_platform_audit_writer' FROM pg_roles WHERE rolname = 'hk_platform_audit_writer' AND rolcanlogin
  UNION ALL
  SELECT 'runtime role owns an object', 'platform.' || t.relname FROM tbl t
   WHERE pg_get_userbyid(t.relowner) IN ('hk_platform_app','hk_platform_ingest','hk_partner_app','hk_platform_readonly','hk_platform_audit_writer')
  UNION ALL
  SELECT 'partner reads a table without forced RLS', 'platform.' || t.relname FROM tbl t
   WHERE t.relkind = 'r' AND has_table_privilege('hk_partner_app', t.oid, 'SELECT') AND NOT (t.relrowsecurity AND t.relforcerowsecurity)
     AND t.relname NOT IN ('geo_province','geo_city','feature','product','product_version','price','price_component',
                           'product_entitlement','industry_pack','industry_pack_version')
  UNION ALL
  SELECT 'RLS table lacks a partner policy', 'platform.' || t.relname FROM tbl t
   WHERE t.relkind = 'r' AND t.relrowsecurity AND has_table_privilege('hk_partner_app', t.oid, 'SELECT')
     AND NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = t.oid AND p.polname = 'partner_own')
  UNION ALL
  SELECT 'unexpected SECURITY DEFINER', p.oid::regprocedure::text
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'platform' AND p.prosecdef AND p.proname <> 'audit_seal'
  UNION ALL
  SELECT 'SECURITY DEFINER not hardened', p.oid::regprocedure::text
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'platform' AND p.prosecdef
     AND (pg_get_userbyid(p.proowner) <> 'hk_platform_audit_writer'
          OR NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig, '{}')) cfg WHERE cfg LIKE 'search_path=%')
          OR has_function_privilege('public', p.oid, 'EXECUTE'))
  UNION ALL
  SELECT 'view without security_invoker', 'platform.' || t.relname FROM tbl t
   WHERE t.relkind = 'v' AND NOT coalesce(t.reloptions @> ARRAY['security_invoker=true'], false)
  UNION ALL
  SELECT 'materialized view in platform', 'platform.' || t.relname FROM tbl t WHERE t.relkind = 'm'
  UNION ALL
  SELECT 'append-only table writable by ' || r.rolname, 'platform.' || t.relname
    FROM tbl t JOIN pg_trigger g ON g.tgrelid = t.oid AND g.tgname = 'trg_immutable' CROSS JOIN rt r
   WHERE has_table_privilege(r.rolname, t.oid, 'UPDATE') OR has_table_privilege(r.rolname, t.oid, 'DELETE')
  UNION ALL
  SELECT 'runtime role may TRUNCATE', 'platform.' || t.relname || ' by ' || r.rolname
    FROM tbl t CROSS JOIN rt r WHERE t.relkind = 'r' AND has_table_privilege(r.rolname, t.oid, 'TRUNCATE')
  UNION ALL
  SELECT 'table without primary key', 'platform.' || t.relname FROM tbl t
   WHERE t.relkind = 'r' AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = t.oid AND k.contype = 'p')
  UNION ALL
  SELECT 'readonly reads a secret column', 'platform.staff_session.token_hash'
   WHERE has_column_privilege('hk_platform_readonly', 'platform.staff_session', 'token_hash', 'SELECT')
  UNION ALL
  SELECT 'readonly reads a secret column', 'platform.idempotency_key.response_body'
   WHERE has_column_privilege('hk_platform_readonly', 'platform.idempotency_key', 'response_body', 'SELECT')
  UNION ALL
  SELECT 'app role writes a code catalog', 'platform.' || t.relname
    FROM tbl t
   WHERE t.relname IN ('staff_role','staff_permission','staff_role_permission','approval_action','tenant_lifecycle_transition',
                       'feature','rules_param_catalog','geo_province','geo_city','audit_chain_head')
     AND (has_table_privilege('hk_platform_app', t.oid, 'INSERT') OR has_table_privilege('hk_platform_app', t.oid, 'UPDATE')
          OR has_table_privilege('hk_platform_app', t.oid, 'DELETE'))
$$;
