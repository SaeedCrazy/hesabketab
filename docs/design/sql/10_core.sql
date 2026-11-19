-- =====================================================================
-- حساب‌کتاب — 10_core.sql   (سند طراحی: docs/design/02-core-platform.md)
-- هستهٔ سکو: هویت، دسترسی، تفکیک وظایف، گردش تأیید، ورود به‌جای کاربر،
-- ممیزی زنجیره‌ای، شماره‌گذاری بی‌فاصله، تنظیمات، فیلد سفارشی، پیوست،
-- outbox + صف job + زمان‌بند، اعلان، بستهٔ صادراتی، نگهداری/حذف، idempotency.
--
-- پیش‌نیاز: 00_foundation.sql. اجرا با نقش migrator/superuser روی پایگاه دادهٔ UTF8.
-- قواعد: PK = id uuid DEFAULT uuidv7()؛ هر جدول مستأجری tenant_id NOT NULL،
-- UNIQUE (tenant_id, id) و core.enable_tenant_rls؛ ارجاع بین جدول‌های مستأجری
-- همیشه FK ترکیبی (tenant_id, x_id). جدول‌های «کاتالوگ» (بدون tenant_id) را
-- migration هر ماژول پر می‌کند و hk_app فقط SELECT دارد.
-- جدول‌های «سطح کاربر» (هویت سراسریِ همین پایگاه داده) tenant_id ندارند و
-- RLS آن‌ها بر پایهٔ core.current_user_id() است.
-- =====================================================================

-- ---------- پیش‌شرط: رمزگذاری UTF8 (نرمال‌سازی فارسی و normalize() به آن نیاز دارد) ----------
DO $$
BEGIN
  IF current_setting('server_encoding') <> 'UTF8' THEN
    RAISE EXCEPTION 'HK_ENCODING: data-plane database must be UTF8 (found %)', current_setting('server_encoding');
  END IF;
END $$;

-- ---------- نقش‌ها: فقط در 00_foundation.sql ساخته می‌شوند (R-ROLE؛ RV-IT-15). این فایل هیچ نقشی نمی‌سازد ----------
DO $$
BEGIN
  IF (SELECT count(*) FROM pg_roles
       WHERE rolname IN ('hk_app','hk_readonly','hk_dispatcher','hk_audit_writer','hk_core_definer','hk_migrator')) <> 6 THEN
    RAISE EXCEPTION 'HK_PREREQ: 10_core.sql needs the roles created by 00_foundation.sql';
  END IF;
END $$;
GRANT USAGE ON SCHEMA core TO hk_audit_writer, hk_core_definer, hk_dispatcher;

-- EXCLUDE روی بازهٔ رزرو شماره‌ها
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- قید کمکی روی جدول پایه (مالک: core) تا FK ترکیبی (tenant_id, company_id, branch_id) ممکن شود
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_constraint WHERE conname = 'branch_tenant_company_id_key') THEN
    ALTER TABLE core.branch ADD CONSTRAINT branch_tenant_company_id_key UNIQUE (tenant_id, company_id, id);
  END IF;
END $$;

-- =====================================================================
-- ۱. نرمال‌سازی متن فارسی (fa-norm-v1). همتای پایتون: hesabketab.core.text
--    هر تغییر = نسخهٔ جدید (fa-norm-v2) + بازتولید ستون‌های جست‌وجو.
-- =====================================================================
-- متن آزاد (نام، شرح): NFKC؛ ي ى ك ہ → ی ی ک ه؛ ارقام عربی → فارسی؛ حذف کشیده و
-- نویسه‌های کنترل جهت؛ فاصله‌های گوناگون → فاصله؛ ZWNJ حفظ (تکراری/کنار فاصله حذف).
CREATE OR REPLACE FUNCTION core.fa_normalize_text(p text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $fn$
SELECT btrim(
  regexp_replace(
   regexp_replace(
    regexp_replace(
     regexp_replace(
      regexp_replace(
       translate(
         replace(normalize(p, NFKC), U&'\000D\000A', U&'\000A'),
         U&'\064A\0649\0643\06C1\0660\0661\0662\0663\0664\0665\0666\0667\0668\0669\0009\000B\000C\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\202F\205F\3000\000D\0085\2028\2029\0640\061C\200B\200E\200F\202A\202B\202C\202D\202E\2066\2067\2068\2069\FEFF\00AD',
         U&'\06CC\06CC\06A9\0647\06F0\06F1\06F2\06F3\06F4\06F5\06F6\06F7\06F8\06F9\0020\0020\0020\0020\0020\0020\0020\0020\0020\0020\0020\0020\0020\0020\0020\0020\0020\0020\0020\000A\000A\000A\000A'),
       U&'\200C{2,}', U&'\200C', 'g'),
      U&'\200C*([ \000A])\200C*', '\1', 'g'),
     ' {2,}', ' ', 'g'),
    U&' ?\000A ?', U&'\000A', 'g'),
   U&'\000A{3,}', U&'\000A\000A', 'g'),
  U&' \000A\200C')
$fn$;

-- شناسه (کد، شماره، کد ملی، بارکد): متن نرمال + همهٔ ارقام → ASCII، بدون ZWNJ و خط جدید
CREATE OR REPLACE FUNCTION core.fa_normalize_ident(p text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $fn$
SELECT btrim(
  regexp_replace(
    translate(core.fa_normalize_text(p),
      U&'\06F0\06F1\06F2\06F3\06F4\06F5\06F6\06F7\06F8\06F9\000A\200C',
      '0123456789 '),
    ' {2,}', ' ', 'g'),
  ' ')
$fn$;

-- کلید جست‌وجو: شناسهٔ نرمال + حذف اعراب + یکسان‌سازی الف/همزه/ة + حروف کوچک ASCII
CREATE OR REPLACE FUNCTION core.fa_search_key(p text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $fn$
SELECT btrim(
  regexp_replace(
    translate(core.fa_normalize_ident(p),
      U&'\0622\0623\0625\0671\0624\0626\06C0\0629ABCDEFGHIJKLMNOPQRSTUVWXYZ'
      || U&'\064B\064C\064D\064E\064F\0650\0651\0652\0653\0654\0655\0656\0657\0658\0659\065A\065B\065C\065D\065E\065F\0670'
      || U&'\06D6\06D7\06D8\06D9\06DA\06DB\06DC\06DF\06E0\06E1\06E2\06E3\06E4\06E5\06E6\06E7\06E8\06EA\06EB\06EC\06ED',
      U&'\0627\0627\0627\0627\0648\06CC\0647\0647abcdefghijklmnopqrstuvwxyz'),
    ' {2,}', ' ', 'g'),
  ' ')
$fn$;

-- =====================================================================
-- ۲. هویت (سطح «قلمرو» = همین پایگاه داده؛ بدون tenant_id)
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.app_user (
  id                  uuid PRIMARY KEY DEFAULT uuidv7(),
  kind                text NOT NULL DEFAULT 'human' CHECK (kind IN ('human','service')),
  home_tenant_id      uuid REFERENCES core.tenant(id),          -- فقط حساب سرویس
  display_name        text NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 200
                                           AND display_name = core.fa_normalize_text(display_name)),
  display_name_search text GENERATED ALWAYS AS (core.fa_search_key(display_name)) STORED,
  status              text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled','anonymized')),
  locale              text NOT NULL DEFAULT 'fa-IR' CHECK (locale IN ('fa-IR','en-US')),
  security_epoch      integer NOT NULL DEFAULT 1 CHECK (security_epoch >= 1),   -- فقط +۱ (app_user_guard)؛ هر نشست نسخهٔ خود را دارد
  mfa_required        boolean NOT NULL DEFAULT false,                           -- انتخاب خود کاربر؛ الزام مستأجر در عضویت/تنظیم است
  created_via         text NOT NULL DEFAULT 'self'
                      CHECK (created_via IN ('self','invitation','provisioning','service','import')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  row_version         integer NOT NULL DEFAULT 1,
  CHECK ((kind = 'service') = (home_tenant_id IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS core.user_login_identifier (
  id           uuid PRIMARY KEY DEFAULT uuidv7(),
  user_id      uuid NOT NULL REFERENCES core.app_user(id),
  kind         text NOT NULL CHECK (kind IN ('phone','email','username')),
  value        text NOT NULL,
  verified_at  timestamptz,
  is_primary   boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, kind, value),
  CHECK (   (kind = 'phone'    AND value ~ '^09[0-9]{9}$')
         OR (kind = 'email'    AND value = lower(value) AND value ~ '^[^@ ]+@[^@ ]+\.[^@ ]+$' AND char_length(value) <= 254)
         OR (kind = 'username' AND value ~ '^[a-z0-9][a-z0-9._-]{2,62}$'))
);
CREATE INDEX IF NOT EXISTS user_login_identifier_user_idx ON core.user_login_identifier (user_id);
-- یکتایی قلمرو فقط برای شناسهٔ «تأییدشده» (RV-CORE-25): شناسهٔ تأییدنشده کسی را از شمارهٔ خودش بیرون نمی‌کند،
-- به ورود حل نمی‌شود (auth_resolve_login) و فقط با OTP مصرف‌شدهٔ همان مقصد تأیید می‌شود (uli_guard).
ALTER TABLE core.user_login_identifier DROP CONSTRAINT IF EXISTS user_login_identifier_kind_value_key;
CREATE UNIQUE INDEX IF NOT EXISTS user_login_identifier_verified_uniq ON core.user_login_identifier (kind, value)
  WHERE verified_at IS NOT NULL;

CREATE TABLE IF NOT EXISTS core.user_credential (
  user_id              uuid PRIMARY KEY REFERENCES core.app_user(id),
  password_hash        text CHECK (password_hash IS NULL OR password_hash LIKE '$argon2id$%'),
  password_changed_at  timestamptz,
  must_change_password boolean NOT NULL DEFAULT false,
  failed_count         integer NOT NULL DEFAULT 0 CHECK (failed_count >= 0),
  locked_until         timestamptz,
  totp_secret_enc      bytea,                 -- رمزشدهٔ پاکتی (KEK در OpenBao / فایل کلید On-prem)
  totp_key_ref         text,
  totp_enabled_at      timestamptz,
  totp_last_step       bigint,                -- ضد تکرار کد TOTP
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  CHECK (totp_enabled_at IS NULL OR (totp_secret_enc IS NOT NULL AND totp_key_ref IS NOT NULL)),
  CHECK ((password_hash IS NULL) = (password_changed_at IS NULL))
);

CREATE TABLE IF NOT EXISTS core.user_recovery_code (
  id          uuid PRIMARY KEY DEFAULT uuidv7(),
  user_id     uuid NOT NULL REFERENCES core.app_user(id),
  generation  integer NOT NULL CHECK (generation >= 1),
  code_hash   bytea NOT NULL CHECK (octet_length(code_hash) = 32),   -- SHA-256 کد ۸۰ بیتی
  used_at     timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, code_hash)
);

-- =====================================================================
-- ۳. مستأجر: عضویت، دعوت، دستگاه، PIN، کلید API
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.tenant_membership (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL DEFAULT uuidv7(),
  user_id            uuid NOT NULL REFERENCES core.app_user(id),
  status             text NOT NULL DEFAULT 'invited' CHECK (status IN ('invited','active','suspended','removed')),
  is_owner           boolean NOT NULL DEFAULT false,
  title              text,
  default_company_id uuid,
  mfa_required       boolean NOT NULL DEFAULT false,
  invited_by         uuid,
  joined_at          timestamptz,
  status_changed_at  timestamptz NOT NULL DEFAULT now(),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  row_version        integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, user_id),
  FOREIGN KEY (tenant_id, default_company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, invited_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (NOT is_owner OR status = 'active'),
  CHECK (status <> 'active' OR joined_at IS NOT NULL)
);
SELECT core.enable_tenant_rls('core.tenant_membership');
CREATE INDEX IF NOT EXISTS tenant_membership_user_idx ON core.tenant_membership (user_id);

CREATE TABLE IF NOT EXISTS core.membership_invitation (
  tenant_id      uuid NOT NULL REFERENCES core.tenant(id),
  id             uuid NOT NULL DEFAULT uuidv7(),
  membership_id  uuid NOT NULL,
  channel        text NOT NULL CHECK (channel IN ('sms','email','link')),
  destination    text,
  token_hash     bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),
  role_ids       uuid[] NOT NULL DEFAULT '{}',
  created_by     uuid NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  expires_at     timestamptz NOT NULL,
  accepted_at    timestamptz,
  revoked_at     timestamptz,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, membership_id) REFERENCES core.tenant_membership(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (expires_at > created_at AND expires_at <= created_at + interval '30 days'),
  CHECK (accepted_at IS NULL OR revoked_at IS NULL)
);
SELECT core.enable_tenant_rls('core.membership_invitation');

-- دستگاه ثبت‌شده (صندوق، اپ ویندوز/اندروید). پیکربندی صندوق در pos.terminal است.
CREATE TABLE IF NOT EXISTS core.device (
  tenant_id             uuid NOT NULL REFERENCES core.tenant(id),
  id                    uuid NOT NULL DEFAULT uuidv7(),
  company_id            uuid NOT NULL,
  branch_id             uuid,
  kind                  text NOT NULL CHECK (kind IN ('pos','windows','android','browser')),
  name                  text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 100),
  key_alg               text NOT NULL DEFAULT 'ed25519' CHECK (key_alg IN ('ed25519','ecdsa_p256')),
  public_key            bytea UNIQUE,   -- ed25519: ۳۲ بایت خام؛ ecdsa_p256: ۶۵ بایت SEC1 فشرده‌نشده
  status                text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','active','revoked','lost')),
  enrollment_code_hash  bytea CHECK (enrollment_code_hash IS NULL OR octet_length(enrollment_code_hash) = 32),
  enrollment_expires_at timestamptz,
  registered_by         uuid NOT NULL,
  activated_at          timestamptz,
  last_seen_at          timestamptz,
  app_version           text,
  revoked_at            timestamptz,
  revoke_reason         text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  row_version           integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, registered_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (status <> 'pending' OR (enrollment_code_hash IS NOT NULL AND enrollment_expires_at IS NOT NULL)),
  CHECK (status <> 'active'  OR (public_key IS NOT NULL AND activated_at IS NOT NULL)),
  CHECK (status NOT IN ('revoked','lost') OR (revoked_at IS NOT NULL AND revoke_reason IS NOT NULL)),
  CHECK (kind <> 'pos' OR branch_id IS NOT NULL),
  CHECK (public_key IS NULL OR (key_alg = 'ed25519' AND octet_length(public_key) = 32)
                            OR (key_alg = 'ecdsa_p256' AND octet_length(public_key) = 65 AND get_byte(public_key, 0) = 4))
);
SELECT core.enable_tenant_rls('core.device');

CREATE TABLE IF NOT EXISTS core.member_pin (
  tenant_id      uuid NOT NULL REFERENCES core.tenant(id),
  id             uuid NOT NULL DEFAULT uuidv7(),
  membership_id  uuid NOT NULL,
  pin_hash       text NOT NULL CHECK (pin_hash LIKE '$argon2id$%'),
  failed_count   integer NOT NULL DEFAULT 0 CHECK (failed_count >= 0),
  locked_until   timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  row_version    integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, membership_id),
  FOREIGN KEY (tenant_id, membership_id) REFERENCES core.tenant_membership(tenant_id, id)
);
SELECT core.enable_tenant_rls('core.member_pin');

-- توکن یک‌ساعتهٔ دستگاه که با امضای challenge گرفته می‌شود (قرارداد ۰۱ D-21)
CREATE TABLE IF NOT EXISTS core.device_token (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  device_id    uuid NOT NULL,
  token_hash   bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),
  issued_at    timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL,
  revoked_at   timestamptz,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, device_id) REFERENCES core.device(tenant_id, id),
  CHECK (expires_at > issued_at AND expires_at <= issued_at + interval '1 hour')
);
SELECT core.enable_tenant_rls('core.device_token');

-- =====================================================================
-- ۲-ب. نشست (توکن کدر)، OTP، رخداد احراز هویت (سطح کاربر)
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.user_session (
  id                    uuid PRIMARY KEY DEFAULT uuidv7(),
  user_id               uuid NOT NULL REFERENCES core.app_user(id),
  token_hash            bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),   -- sha256 توکن کدر ۲۵۶ بیتی (کوکی __Host-hk_session یا Bearer)
  token_rotated_at      timestamptz NOT NULL DEFAULT now(),
  active_tenant_id      uuid REFERENCES core.tenant(id),
  device_id             uuid,
  client_kind           text NOT NULL CHECK (client_kind IN ('web','pwa','windows','android','pos','cli')),
  amr                   text[] NOT NULL CHECK (cardinality(amr) >= 1
                          AND amr <@ ARRAY['pwd','otp_sms','totp','recovery','pin','device_key','webauthn']::text[]),
  auth_time             timestamptz NOT NULL DEFAULT now(),
  mfa_at                timestamptz,
  ip                    inet,
  user_agent            text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  last_seen_at          timestamptz NOT NULL DEFAULT now(),
  idle_timeout_seconds  integer NOT NULL CHECK (idle_timeout_seconds BETWEEN 60 AND 604800),
  absolute_expires_at   timestamptz NOT NULL,
  revoked_at            timestamptz,
  revoke_reason         text,
  security_epoch        integer NOT NULL DEFAULT 1,   -- نسخهٔ app_user.security_epoch هنگام صدور (تریگر user_session_guard)
  FOREIGN KEY (active_tenant_id, device_id) REFERENCES core.device(tenant_id, id),
  -- مستأجر فعال نشست باید مستأجری باشد که کاربر در آن عضویت دارد (RV-CORE-29)
  CONSTRAINT user_session_membership_fk FOREIGN KEY (active_tenant_id, user_id) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (absolute_expires_at > created_at),
  CHECK ((revoked_at IS NULL) = (revoke_reason IS NULL)),
  CHECK (device_id IS NULL OR active_tenant_id IS NOT NULL),
  CHECK (NOT ('pin' = ANY (amr)) OR (device_id IS NOT NULL AND client_kind = 'pos'))
);
CREATE INDEX IF NOT EXISTS user_session_user_idx ON core.user_session (user_id) WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS core.otp_challenge (
  id            uuid PRIMARY KEY DEFAULT uuidv7(),
  user_id       uuid NOT NULL REFERENCES core.app_user(id),
  purpose       text NOT NULL CHECK (purpose IN ('login','verify_phone','verify_email','password_reset','step_up')),
  channel       text NOT NULL CHECK (channel IN ('sms','email')),
  destination   text NOT NULL,
  code_hash     bytea NOT NULL CHECK (octet_length(code_hash) = 32),   -- HMAC-SHA256(server_key, id||code)
  attempts      smallint NOT NULL DEFAULT 0,
  max_attempts  smallint NOT NULL DEFAULT 5 CHECK (max_attempts BETWEEN 1 AND 10),
  created_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL,
  consumed_at   timestamptz,
  ip            inet,
  CHECK (attempts BETWEEN 0 AND max_attempts),
  CHECK (expires_at > created_at AND expires_at <= created_at + interval '15 minutes')
);
CREATE INDEX IF NOT EXISTS otp_challenge_user_idx ON core.otp_challenge (user_id, created_at);

CREATE TABLE IF NOT EXISTS core.auth_event (
  id                 uuid PRIMARY KEY DEFAULT uuidv7(),
  occurred_at        timestamptz NOT NULL DEFAULT now(),
  user_id            uuid REFERENCES core.app_user(id),
  context_tenant_id  uuid,
  event              text NOT NULL CHECK (event IN (
                       'login_succeeded','login_failed','mfa_succeeded','mfa_failed','pin_succeeded','pin_failed',
                       'password_changed','password_reset','totp_enabled','totp_disabled','recovery_used',
                       'session_revoked','all_sessions_revoked','refresh_reuse_detected','account_locked',
                       'tenant_selected','otp_sent')),
  session_id         uuid,
  device_id          uuid,
  login_hint_hash    bytea,
  ip                 inet,
  user_agent         text,
  details            jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(details) = 'object')
);
CREATE INDEX IF NOT EXISTS auth_event_user_idx ON core.auth_event (user_id, occurred_at);

-- شمارندهٔ محدودیت نرخ (پشتوانهٔ PostgreSQL وقتی Valkey نیست). کلیدها hash شده‌اند؛ دادهٔ مستأجر ندارد.
CREATE UNLOGGED TABLE IF NOT EXISTS core.rate_limit_counter (
  bucket_key    text NOT NULL CHECK (bucket_key ~ '^[a-z_]+:[0-9a-f]{64}$'),
  window_start  timestamptz NOT NULL,
  hits          integer NOT NULL DEFAULT 0 CHECK (hits >= 0),
  PRIMARY KEY (bucket_key, window_start)
);

-- =====================================================================
-- ۴. RBAC: کاتالوگ مجوزها و قالب نقش‌ها (سراسری) + نقش‌ها و انتساب‌های مستأجر
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.permission (
  code                       text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){2,3}$'),
  module                     text NOT NULL,
  scope_dimensions           text[] NOT NULL DEFAULT '{}'
                             CHECK (scope_dimensions <@ ARRAY['company','branch','warehouse','cash_box','pos_terminal','cost_center','project']::text[]),
  risk                       text NOT NULL DEFAULT 'normal' CHECK (risk IN ('normal','sensitive','critical')),
  allow_service_account      boolean NOT NULL DEFAULT true,
  allow_impersonation_write  boolean NOT NULL DEFAULT false,
  description_key            text NOT NULL,
  introduced_in              text NOT NULL,
  deprecated_at              timestamptz,
  CHECK (split_part(code, '.', 1) = module)
);

CREATE TABLE IF NOT EXISTS core.role_template (
  code             text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{1,62}$'),
  name_key         text NOT NULL,
  grants_all       boolean NOT NULL DEFAULT false,
  for_service      boolean NOT NULL DEFAULT false,
  introduced_in    text NOT NULL
);

CREATE TABLE IF NOT EXISTS core.role_template_permission (
  template_code    text NOT NULL REFERENCES core.role_template(code),
  permission_code  text NOT NULL REFERENCES core.permission(code),
  PRIMARY KEY (template_code, permission_code)
);

CREATE TABLE IF NOT EXISTS core.role (
  tenant_id      uuid NOT NULL REFERENCES core.tenant(id),
  id             uuid NOT NULL DEFAULT uuidv7(),
  code           text NOT NULL CHECK (code ~ '^[a-z][a-z0-9_]{1,62}$'),
  name           text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 100),
  description    text,
  template_code  text REFERENCES core.role_template(code),
  is_system      boolean NOT NULL DEFAULT false,
  grants_all     boolean NOT NULL DEFAULT false,
  is_active      boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  row_version    integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  CHECK (NOT grants_all OR is_system),
  CHECK (NOT is_system OR template_code IS NOT NULL)
);
SELECT core.enable_tenant_rls('core.role');

CREATE TABLE IF NOT EXISTS core.role_permission (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  role_id          uuid NOT NULL,
  permission_code  text NOT NULL REFERENCES core.permission(code),
  granted_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, role_id, permission_code),
  FOREIGN KEY (tenant_id, role_id) REFERENCES core.role(tenant_id, id)
);
SELECT core.enable_tenant_rls('core.role_permission');

CREATE TABLE IF NOT EXISTS core.role_assignment (
  tenant_id      uuid NOT NULL REFERENCES core.tenant(id),
  id             uuid NOT NULL DEFAULT uuidv7(),
  membership_id  uuid NOT NULL,
  role_id        uuid NOT NULL,
  valid_from     timestamptz NOT NULL DEFAULT now(),
  valid_to       timestamptz,
  granted_by     uuid,
  revoked_at     timestamptz,
  revoked_by     uuid,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  row_version    integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, membership_id) REFERENCES core.tenant_membership(tenant_id, id),
  FOREIGN KEY (tenant_id, role_id) REFERENCES core.role(tenant_id, id),
  FOREIGN KEY (tenant_id, granted_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, revoked_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (valid_to IS NULL OR valid_to > valid_from),
  CHECK ((revoked_at IS NULL) = (revoked_by IS NULL))
);
SELECT core.enable_tenant_rls('core.role_assignment');
CREATE INDEX IF NOT EXISTS role_assignment_member_idx ON core.role_assignment (tenant_id, membership_id) WHERE revoked_at IS NULL;

-- دامنهٔ رکورد هر انتساب: برای هر بُعد، نبودِ ردیف = «همه»؛ وجود ردیف = فقط همین‌ها.
CREATE TABLE IF NOT EXISTS core.role_assignment_scope (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  assignment_id    uuid NOT NULL,
  dimension        text NOT NULL CHECK (dimension IN ('company','branch','warehouse','cash_box','pos_terminal','cost_center','project')),
  company_id       uuid,
  branch_id        uuid,
  warehouse_id     uuid,   -- FK بین‌ماژولی: inventory.warehouse (بخش ۱۲)
  cash_box_id      uuid,   -- FK بین‌ماژولی: treasury.cash_box
  pos_terminal_id  uuid,   -- FK بین‌ماژولی: pos.terminal
  cost_center_id   uuid,   -- FK بین‌ماژولی: ledger.dimension_value
  project_id       uuid,   -- FK بین‌ماژولی: ledger.dimension_value (بُعد project؛ 03:C-L13)
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, assignment_id) REFERENCES core.role_assignment(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, branch_id) REFERENCES core.branch(tenant_id, id),
  CHECK (num_nonnulls(company_id, branch_id, warehouse_id, cash_box_id, pos_terminal_id, cost_center_id, project_id) = 1),
  CHECK ((dimension = 'company')      = (company_id IS NOT NULL)),
  CHECK ((dimension = 'branch')       = (branch_id IS NOT NULL)),
  CHECK ((dimension = 'warehouse')    = (warehouse_id IS NOT NULL)),
  CHECK ((dimension = 'cash_box')     = (cash_box_id IS NOT NULL)),
  CHECK ((dimension = 'pos_terminal') = (pos_terminal_id IS NOT NULL)),
  CHECK ((dimension = 'cost_center')  = (cost_center_id IS NOT NULL)),
  CHECK ((dimension = 'project')      = (project_id IS NOT NULL))
);
SELECT core.enable_tenant_rls('core.role_assignment_scope');
CREATE UNIQUE INDEX IF NOT EXISTS role_assignment_scope_uniq ON core.role_assignment_scope
  (tenant_id, assignment_id, dimension, coalesce(company_id, branch_id, warehouse_id, cash_box_id, pos_terminal_id, cost_center_id, project_id));

-- محافظ فیلد (کاتالوگ): فیلد حساس هر منبع با مجوز خواندن/نوشتن جدا محافظت می‌شود.
CREATE TABLE IF NOT EXISTS core.field_guard (
  resource          text NOT NULL CHECK (resource ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  field             text NOT NULL CHECK (field ~ '^[a-z][a-z0-9_]*$'),
  read_permission   text NOT NULL REFERENCES core.permission(code),
  write_permission  text REFERENCES core.permission(code),
  mask_style        text NOT NULL DEFAULT 'omit' CHECK (mask_style IN ('omit','null','partial_last4','redact')),
  is_secret         boolean NOT NULL DEFAULT false,      -- همیشه در ورود به‌جای کاربر پوشانده می‌شود
  PRIMARY KEY (resource, field)
);

-- =====================================================================
-- ۵. تفکیک وظایف و گردش تأیید
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.sod_rule (
  tenant_id      uuid NOT NULL REFERENCES core.tenant(id),
  id             uuid NOT NULL DEFAULT uuidv7(),
  code           text NOT NULL CHECK (code ~ '^[a-z][a-z0-9_.]{1,80}$'),
  name           text NOT NULL,
  kind           text NOT NULL CHECK (kind IN ('static_conflict','distinct_actor')),
  permission_a   text REFERENCES core.permission(code),
  permission_b   text REFERENCES core.permission(code),
  subject_type   text CHECK (subject_type ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  action_a       text CHECK (action_a ~ '^[a-z][a-z0-9_]*$'),
  action_b       text CHECK (action_b ~ '^[a-z][a-z0-9_]*$'),
  enforcement    text NOT NULL DEFAULT 'block' CHECK (enforcement IN ('block','warn')),
  exempt_owner   boolean NOT NULL DEFAULT false,
  company_id     uuid,
  is_active      boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  row_version    integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  CHECK (   (kind = 'static_conflict' AND permission_a IS NOT NULL AND permission_b IS NOT NULL
             AND permission_a <> permission_b AND subject_type IS NULL AND action_a IS NULL AND action_b IS NULL)
         OR (kind = 'distinct_actor' AND subject_type IS NOT NULL AND action_a IS NOT NULL AND action_b IS NOT NULL
             AND action_a <> action_b AND permission_a IS NULL AND permission_b IS NULL))
);
SELECT core.enable_tenant_rls('core.sod_rule');

CREATE TABLE IF NOT EXISTS core.approval_policy (
  tenant_id           uuid NOT NULL REFERENCES core.tenant(id),
  id                  uuid NOT NULL DEFAULT uuidv7(),
  subject_type        text NOT NULL CHECK (subject_type ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  company_id          uuid,
  name                text NOT NULL,
  priority            integer NOT NULL DEFAULT 100,
  min_amount          core.amount,          -- به ارز پایهٔ شرکت؛ NULL = بدون کف
  max_amount          core.amount,          -- NULL = بدون سقف
  condition           jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(condition) = 'object'),
  enforce_sod         boolean NOT NULL DEFAULT true,
  distinct_approvers  boolean NOT NULL DEFAULT true,
  expires_after       interval CHECK (expires_after IS NULL OR expires_after > interval '0'),
  is_active           boolean NOT NULL DEFAULT true,
  version             integer NOT NULL DEFAULT 1,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  row_version         integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  CHECK (min_amount IS NULL OR min_amount >= 0),
  CHECK (max_amount IS NULL OR min_amount IS NULL OR max_amount > min_amount)
);
SELECT core.enable_tenant_rls('core.approval_policy');

CREATE TABLE IF NOT EXISTS core.approval_policy_step (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  policy_id        uuid NOT NULL,
  step_no          smallint NOT NULL CHECK (step_no BETWEEN 1 AND 10),
  approver_kind    text NOT NULL CHECK (approver_kind IN ('role','user','permission')),
  role_id          uuid,
  user_id          uuid,
  permission_code  text REFERENCES core.permission(code),
  min_approvals    smallint NOT NULL DEFAULT 1 CHECK (min_approvals BETWEEN 1 AND 10),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, policy_id, step_no),
  FOREIGN KEY (tenant_id, policy_id) REFERENCES core.approval_policy(tenant_id, id),
  FOREIGN KEY (tenant_id, role_id) REFERENCES core.role(tenant_id, id),
  FOREIGN KEY (tenant_id, user_id) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK ((approver_kind = 'role')       = (role_id IS NOT NULL)),
  CHECK ((approver_kind = 'user')       = (user_id IS NOT NULL)),
  CHECK ((approver_kind = 'permission') = (permission_code IS NOT NULL)),
  CHECK (approver_kind <> 'user' OR min_approvals = 1)
);
SELECT core.enable_tenant_rls('core.approval_policy_step');

CREATE TABLE IF NOT EXISTS core.approval_request (
  tenant_id           uuid NOT NULL REFERENCES core.tenant(id),
  id                  uuid NOT NULL DEFAULT uuidv7(),
  company_id          uuid NOT NULL,
  subject_type        text NOT NULL CHECK (subject_type ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  subject_id          uuid NOT NULL,
  subject_ref         text,
  amount              core.amount,
  currency            char(3) REFERENCES ref.currency(code),
  requested_by        uuid NOT NULL,
  subject_created_by  uuid,
  policy_id           uuid NOT NULL,
  policy_version      integer NOT NULL,
  steps_snapshot      jsonb NOT NULL CHECK (jsonb_typeof(steps_snapshot) = 'array' AND jsonb_array_length(steps_snapshot) BETWEEN 1 AND 10),
  enforce_sod         boolean NOT NULL,
  distinct_approvers  boolean NOT NULL,
  status              text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','cancelled','expired')),
  current_step        smallint NOT NULL DEFAULT 1 CHECK (current_step >= 1),
  expires_at          timestamptz,
  cancel_reason       text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  decided_at          timestamptz,
  updated_at          timestamptz NOT NULL DEFAULT now(),
  row_version         integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  -- قرارداد مصرف‌کننده (RV-CORE-26): سند ماژول دیگر با FK چهارستونی (tenant_id, approval_request_id, '<type>', id)
  -- فقط به درخواست تأیید «همان سند» اشاره می‌کند؛ وضعیت approved در لحظهٔ قطعی‌شدن با approval_assert_approved
  CONSTRAINT approval_request_subject_key UNIQUE (tenant_id, id, subject_type, subject_id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, policy_id) REFERENCES core.approval_policy(tenant_id, id),
  FOREIGN KEY (tenant_id, requested_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, subject_created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK ((amount IS NULL) = (currency IS NULL)),
  CHECK ((status = 'pending') = (decided_at IS NULL)),
  CHECK (status <> 'cancelled' OR cancel_reason IS NOT NULL)
);
SELECT core.enable_tenant_rls('core.approval_request');
CREATE UNIQUE INDEX IF NOT EXISTS approval_request_one_pending ON core.approval_request (tenant_id, subject_type, subject_id) WHERE status = 'pending';

CREATE TABLE IF NOT EXISTS core.approval_decision (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  request_id   uuid NOT NULL,
  step_no      smallint NOT NULL,
  decided_by   uuid NOT NULL,
  decision     text NOT NULL CHECK (decision IN ('approve','reject')),
  comment      text,
  decided_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, request_id, step_no, decided_by),
  FOREIGN KEY (tenant_id, request_id) REFERENCES core.approval_request(tenant_id, id),
  FOREIGN KEY (tenant_id, decided_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (decision <> 'reject' OR comment IS NOT NULL)
);
SELECT core.enable_tenant_rls('core.approval_decision');

-- =====================================================================
-- ۶. رضایت پشتیبانی و ورود به‌جای کاربر
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.support_access_grant (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  granted_by           uuid NOT NULL,
  grantee_kind         text NOT NULL DEFAULT 'platform_support' CHECK (grantee_kind IN ('platform_support','reseller')),
  access_mode          text NOT NULL DEFAULT 'read_only' CHECK (access_mode IN ('read_only','read_write')),
  reason               text,
  ticket_ref           text,
  max_session_minutes  smallint NOT NULL DEFAULT 60 CHECK (max_session_minutes BETWEEN 5 AND 480),
  starts_at            timestamptz NOT NULL DEFAULT now(),
  expires_at           timestamptz NOT NULL,
  revoked_at           timestamptz,
  revoked_by           uuid,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, granted_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, revoked_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (expires_at > starts_at AND expires_at <= starts_at + interval '7 days'),
  CHECK ((revoked_at IS NULL) = (revoked_by IS NULL))
);
SELECT core.enable_tenant_rls('core.support_access_grant');

CREATE TABLE IF NOT EXISTS core.impersonation_session (
  tenant_id                uuid NOT NULL REFERENCES core.tenant(id),
  id                       uuid NOT NULL DEFAULT uuidv7(),
  grant_id                 uuid NOT NULL,
  grantee_kind             text NOT NULL DEFAULT 'platform_support' CHECK (grantee_kind IN ('platform_support','reseller')),
  staff_id                 uuid NOT NULL,          -- platform.staff یا کاربر نماینده (پایگاه دادهٔ کنترل؛ بدون FK)
  staff_display_name       text NOT NULL,
  assertion_jti            text NOT NULL,          -- شناسهٔ ادعای امضاشدهٔ پنل مالک (ضد تکرار)
  token_hash               bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),   -- توکن کدر نشست کارمند
  reason                   text NOT NULL CHECK (char_length(btrim(reason)) >= 10),
  ticket_ref               text NOT NULL CHECK (char_length(btrim(ticket_ref)) >= 1),
  mode                     text NOT NULL CHECK (mode IN ('read_only','read_write')),
  write_approver_staff_id  uuid,
  target_user_id           uuid,                   -- NULL = هویت «پشتیبان» با نقش support_readonly
  started_at               timestamptz NOT NULL DEFAULT now(),
  expires_at               timestamptz NOT NULL,
  ended_at                 timestamptz,
  end_reason               text,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, assertion_jti),
  FOREIGN KEY (tenant_id, grant_id) REFERENCES core.support_access_grant(tenant_id, id),
  FOREIGN KEY (tenant_id, target_user_id) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (expires_at > started_at),
  CHECK (mode = 'read_only' OR (write_approver_staff_id IS NOT NULL AND write_approver_staff_id <> staff_id AND target_user_id IS NOT NULL)),
  CHECK ((ended_at IS NULL) = (end_reason IS NULL))
);
SELECT core.enable_tenant_rls('core.impersonation_session');

-- =====================================================================
-- ۷. ممیزی فقط‌افزودنی با زنجیرهٔ hash برای هر مستأجر
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.audit_chain_head (
  tenant_id   uuid NOT NULL REFERENCES core.tenant(id),
  id          uuid NOT NULL DEFAULT uuidv7(),
  chain_no    smallint NOT NULL DEFAULT 0 CHECK (chain_no BETWEEN 0 AND 63),
  last_seq    bigint NOT NULL DEFAULT 0 CHECK (last_seq >= 0),
  last_hash   bytea NOT NULL CHECK (octet_length(last_hash) = 32),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, chain_no)
);
SELECT core.enable_tenant_rls('core.audit_chain_head');

CREATE TABLE IF NOT EXISTS core.audit_log (
  tenant_id                 uuid NOT NULL REFERENCES core.tenant(id),
  id                        uuid NOT NULL DEFAULT uuidv7(),
  chain_no                  smallint NOT NULL DEFAULT 0 CHECK (chain_no = 0),   -- v1 یک زنجیره؛ تکه‌کردن (۱..۶۳) در v2
  seq                       bigint NOT NULL,
  occurred_at               timestamptz NOT NULL DEFAULT now(),
  recorded_at               timestamptz NOT NULL,
  -- 'assistant' = اصل دستیار به نیابت کاربر (R-AI-PRINCIPAL)؛ actor_user_id همان کاربر نیابت‌دهنده است
  actor_kind                text NOT NULL CHECK (actor_kind IN ('user','service','device','system','platform_staff','assistant')),
  actor_user_id             uuid,
  act_staff_id              uuid,
  impersonation_session_id  uuid,
  session_id                uuid,
  api_key_id                uuid,
  device_id                 uuid,
  request_id                text,
  ip                        inet,
  user_agent                text,
  action                    text NOT NULL CHECK (action ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){1,4}$'),
  resource_type             text,
  resource_id               uuid,
  company_id                uuid,
  branch_id                 uuid,
  outcome                   text NOT NULL DEFAULT 'success' CHECK (outcome IN ('success','denied','failed')),
  reason                    text,
  details                   text NOT NULL DEFAULT '{}' CHECK (details IS JSON OBJECT),
  details_sha256            bytea NOT NULL CHECK (octet_length(details_sha256) = 32),
  prev_hash                 bytea NOT NULL CHECK (octet_length(prev_hash) = 32),
  row_hash                  bytea NOT NULL CHECK (octet_length(row_hash) = 32),
  -- R-PK (RV-CORE-32): کلید (tenant_id, id) تا پارتیشن HASH(tenant_id) بی‌تغییر قرارداد ممکن باشد
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, chain_no, seq),
  FOREIGN KEY (tenant_id, chain_no) REFERENCES core.audit_chain_head(tenant_id, chain_no),
  FOREIGN KEY (tenant_id, actor_user_id) REFERENCES core.tenant_membership(tenant_id, user_id),   -- R-ACTOR (RV-CORE-22)
  CHECK (seq >= 1),
  CHECK (actor_kind NOT IN ('user','service','assistant') OR actor_user_id IS NOT NULL),
  CHECK ((act_staff_id IS NULL) = (impersonation_session_id IS NULL)),
  CHECK (actor_kind <> 'platform_staff' OR act_staff_id IS NOT NULL)
);
SELECT core.enable_tenant_rls('core.audit_log');
CREATE INDEX IF NOT EXISTS audit_log_resource_idx ON core.audit_log (tenant_id, resource_type, resource_id);
CREATE INDEX IF NOT EXISTS audit_log_actor_idx ON core.audit_log (tenant_id, actor_user_id, occurred_at);
CREATE INDEX IF NOT EXISTS audit_log_time_idx ON core.audit_log (tenant_id, occurred_at);

CREATE TABLE IF NOT EXISTS core.audit_checkpoint (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL DEFAULT uuidv7(),
  chain_no           smallint NOT NULL,
  seq                bigint NOT NULL,
  row_hash           bytea NOT NULL CHECK (octet_length(row_hash) = 32),
  verified_from_seq  bigint NOT NULL CHECK (verified_from_seq >= 1),
  result             text NOT NULL CHECK (result IN ('ok','broken')),
  problems           jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(problems) = 'array'),
  verified_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, chain_no, seq) REFERENCES core.audit_log(tenant_id, chain_no, seq),
  CHECK (verified_from_seq <= seq),
  CHECK ((result = 'ok') = (jsonb_array_length(problems) = 0))
);
SELECT core.enable_tenant_rls('core.audit_checkpoint');
CREATE INDEX IF NOT EXISTS audit_checkpoint_seq_idx ON core.audit_checkpoint (tenant_id, chain_no, seq);

CREATE TABLE IF NOT EXISTS core.audit_anchor (
  tenant_id      uuid NOT NULL REFERENCES core.tenant(id),
  id             uuid NOT NULL DEFAULT uuidv7(),
  checkpoint_id  uuid NOT NULL,
  target         text NOT NULL CHECK (target IN ('control_plane','license_report','tenant_admin_notice','printed_report')),
  anchor_ref     text NOT NULL,
  published_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, checkpoint_id, target),
  FOREIGN KEY (tenant_id, checkpoint_id) REFERENCES core.audit_checkpoint(tenant_id, id)
);
SELECT core.enable_tenant_rls('core.audit_anchor');

-- =====================================================================
-- ۸. شماره‌گذاری بی‌فاصله
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.number_series (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  company_id    uuid NOT NULL,
  code          text NOT NULL CHECK (code ~ '^[a-z0-9][a-z0-9_.-]{0,62}$'),
  name          text NOT NULL,
  doc_type      text NOT NULL CHECK (doc_type ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),
  scope         text NOT NULL CHECK (scope IN ('company','branch','device')),
  branch_id     uuid,
  device_id     uuid,
  allocation    text NOT NULL DEFAULT 'server' CHECK (allocation IN ('server','device','reserved_ranges')),
  pattern       text NOT NULL,
  prefix        text NOT NULL DEFAULT '',
  reset_policy  text NOT NULL CHECK (reset_policy IN ('never','fiscal_year','jalali_year','jalali_month')),
  start_value   bigint NOT NULL DEFAULT 1 CHECK (start_value >= 1),
  is_default    boolean NOT NULL DEFAULT true,
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  row_version   integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, code),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, device_id) REFERENCES core.device(tenant_id, id),
  CHECK (   (scope = 'company' AND branch_id IS NULL AND device_id IS NULL)
         OR (scope = 'branch'  AND branch_id IS NOT NULL AND device_id IS NULL)
         OR (scope = 'device'  AND device_id IS NOT NULL)),
  CHECK ((allocation = 'device') = (scope = 'device')),
  -- دقیقاً یک توکن {seq} یا {seq:N}، و فقط توکن‌های مجاز
  CHECK (array_length(regexp_split_to_array(pattern, '\{seq(:[1-9][0-9]?)?\}'), 1) = 2),
  CHECK (regexp_replace(pattern, '\{(seq(:[1-9][0-9]?)?|prefix|company|branch|device|fy|jy|jy2|jm|gy)\}', '', 'g') !~ '[{}]'),
  CHECK (char_length(pattern) <= 80)
);
SELECT core.enable_tenant_rls('core.number_series');
CREATE UNIQUE INDEX IF NOT EXISTS number_series_one_default ON core.number_series
  (tenant_id, company_id, doc_type, branch_id, device_id) NULLS NOT DISTINCT WHERE is_default AND is_active;

CREATE TABLE IF NOT EXISTS core.number_counter (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  series_id    uuid NOT NULL,
  period_key   text NOT NULL CHECK (period_key ~ '^(all|fy:[0-9a-f-]{36}|jy:[0-9]{4}|jm:[0-9]{4}-(0[1-9]|1[0-2]))$'),
  next_value   bigint NOT NULL CHECK (next_value >= 1),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, series_id, period_key),
  FOREIGN KEY (tenant_id, series_id) REFERENCES core.number_series(tenant_id, id)
);
SELECT core.enable_tenant_rls('core.number_counter');

CREATE TABLE IF NOT EXISTS core.number_reservation (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  series_id     uuid NOT NULL,
  period_key    text NOT NULL,
  device_id     uuid NOT NULL,
  range_start   bigint NOT NULL CHECK (range_start >= 1),
  range_end     bigint NOT NULL,
  status        text NOT NULL DEFAULT 'active' CHECK (status IN ('active','closed')),
  reserved_by   uuid,
  reserved_at   timestamptz NOT NULL DEFAULT now(),
  closed_at     timestamptz,
  close_reason  text,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, series_id, period_key) REFERENCES core.number_counter(tenant_id, series_id, period_key),
  FOREIGN KEY (tenant_id, device_id) REFERENCES core.device(tenant_id, id),
  FOREIGN KEY (tenant_id, reserved_by) REFERENCES core.tenant_membership(tenant_id, user_id),   -- R-ACTOR
  CHECK (range_end >= range_start AND range_end - range_start < 100000),
  CHECK ((status = 'closed') = (closed_at IS NOT NULL AND close_reason IS NOT NULL)),
  EXCLUDE USING gist (tenant_id WITH =, series_id WITH =, period_key WITH =, int8range(range_start, range_end, '[]') WITH &&)
);
SELECT core.enable_tenant_rls('core.number_reservation');

CREATE TABLE IF NOT EXISTS core.number_issued (
  tenant_id       uuid NOT NULL REFERENCES core.tenant(id),
  id              uuid NOT NULL DEFAULT uuidv7(),
  series_id       uuid NOT NULL,
  period_key      text NOT NULL,
  value           bigint NOT NULL CHECK (value >= 1),
  formatted       text NOT NULL CHECK (char_length(formatted) BETWEEN 1 AND 100),
  status          text NOT NULL CHECK (status IN ('used','voided')),
  doc_type        text,
  doc_id          uuid,
  reservation_id  uuid,
  device_id       uuid,
  void_reason     text,
  issued_by       uuid,
  issued_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),                              -- R-PK (RV-CORE-32)
  UNIQUE (tenant_id, series_id, period_key, value),
  UNIQUE (tenant_id, series_id, period_key, formatted),
  FOREIGN KEY (tenant_id, series_id, period_key) REFERENCES core.number_counter(tenant_id, series_id, period_key),
  FOREIGN KEY (tenant_id, reservation_id) REFERENCES core.number_reservation(tenant_id, id),
  FOREIGN KEY (tenant_id, device_id) REFERENCES core.device(tenant_id, id),
  FOREIGN KEY (tenant_id, issued_by) REFERENCES core.tenant_membership(tenant_id, user_id),       -- R-ACTOR
  CHECK ((status = 'used') = (doc_id IS NOT NULL AND doc_type IS NOT NULL)),
  CHECK ((status = 'voided') = (void_reason IS NOT NULL))
);
SELECT core.enable_tenant_rls('core.number_issued');
CREATE UNIQUE INDEX IF NOT EXISTS number_issued_one_per_doc ON core.number_issued (tenant_id, series_id, doc_id) WHERE status = 'used';

-- =====================================================================
-- ۹. تنظیمات (تعریف سراسری + مقدار سطح‌دار نسخه‌دار + تاریخچه)
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.setting_def (
  key               text PRIMARY KEY CHECK (key ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),
  module            text NOT NULL,
  value_type        text NOT NULL CHECK (value_type IN ('bool','int','decimal','text','enum','date','duration_s','json','secret_ref')),
  enum_values       text[],
  min_value         numeric,
  max_value         numeric,
  max_length        integer CHECK (max_length IS NULL OR max_length BETWEEN 1 AND 10000),
  json_schema       jsonb,
  allowed_levels    text[] NOT NULL CHECK (cardinality(allowed_levels) >= 1
                      AND allowed_levels <@ ARRAY['tenant','company','branch','user']::text[]),
  default_value     jsonb NOT NULL,
  read_permission   text REFERENCES core.permission(code),
  write_permission  text NOT NULL REFERENCES core.permission(code),
  description_key   text NOT NULL,
  introduced_in     text NOT NULL,
  deprecated_at     timestamptz,
  CHECK (split_part(key, '.', 1) = module),
  CHECK ((value_type = 'enum') = (enum_values IS NOT NULL)),
  CHECK (value_type = 'json' OR json_schema IS NULL)
);

CREATE TABLE IF NOT EXISTS core.setting_value (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  setting_key   text NOT NULL REFERENCES core.setting_def(key),
  level         text NOT NULL CHECK (level IN ('tenant','company','branch','user')),
  company_id    uuid,
  branch_id     uuid,
  user_id       uuid,
  value         jsonb NOT NULL,
  updated_by    uuid,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  row_version   integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, user_id) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, updated_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (   (level = 'tenant'  AND company_id IS NULL     AND branch_id IS NULL     AND user_id IS NULL)
         OR (level = 'company' AND company_id IS NOT NULL AND branch_id IS NULL     AND user_id IS NULL)
         OR (level = 'branch'  AND company_id IS NOT NULL AND branch_id IS NOT NULL AND user_id IS NULL)
         OR (level = 'user'    AND company_id IS NULL     AND branch_id IS NULL     AND user_id IS NOT NULL))
);
SELECT core.enable_tenant_rls('core.setting_value');
CREATE UNIQUE INDEX IF NOT EXISTS setting_value_uniq ON core.setting_value
  (tenant_id, setting_key, level, company_id, branch_id, user_id) NULLS NOT DISTINCT;

CREATE TABLE IF NOT EXISTS core.setting_history (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  setting_id   uuid NOT NULL,                -- بدون FK: ردیف مقدار ممکن است حذف (بازگشت به ارث) شود
  setting_key  text NOT NULL,
  level        text NOT NULL,
  company_id   uuid,
  branch_id    uuid,
  user_id      uuid,
  op           text NOT NULL CHECK (op IN ('insert','update','delete')),
  old_value    jsonb,
  new_value    jsonb,
  version      integer NOT NULL,
  changed_by   uuid,
  changed_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, changed_by) REFERENCES core.tenant_membership(tenant_id, user_id)       -- R-ACTOR
);
SELECT core.enable_tenant_rls('core.setting_history');
CREATE INDEX IF NOT EXISTS setting_history_key_idx ON core.setting_history (tenant_id, setting_key, changed_at);

-- =====================================================================
-- ۱۰. فیلد سفارشی
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.custom_field_entity (
  entity_type      text PRIMARY KEY CHECK (entity_type ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  module           text NOT NULL,
  table_name       text NOT NULL,                 -- 'schema.table' جدول مالک
  json_column      text NOT NULL DEFAULT 'custom',
  max_fields       smallint NOT NULL DEFAULT 50 CHECK (max_fields BETWEEN 1 AND 200),
  description_key  text NOT NULL,
  CHECK (split_part(entity_type, '.', 1) = module)
);

CREATE TABLE IF NOT EXISTS core.custom_field_def (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  entity_type       text NOT NULL REFERENCES core.custom_field_entity(entity_type),
  code              text NOT NULL CHECK (code ~ '^[a-z][a-z0-9_]{0,62}$'),
  label_fa          text NOT NULL CHECK (label_fa = core.fa_normalize_text(label_fa) AND char_length(label_fa) BETWEEN 1 AND 100),
  label_en          text,
  data_type         text NOT NULL CHECK (data_type IN ('text','long_text','int','decimal','bool','date','enum','multi_enum','ref')),
  ref_entity        text,
  options           jsonb,
  is_required       boolean NOT NULL DEFAULT false,
  default_value     jsonb,
  max_length        integer CHECK (max_length IS NULL OR max_length BETWEEN 1 AND 4000),
  min_value         numeric,
  max_value         numeric,
  is_indexed        boolean NOT NULL DEFAULT false,
  read_permission   text REFERENCES core.permission(code),
  write_permission  text REFERENCES core.permission(code),
  position          integer NOT NULL DEFAULT 0,
  status            text NOT NULL DEFAULT 'active' CHECK (status IN ('active','deprecated')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  row_version       integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, entity_type, code),
  CHECK ((data_type IN ('enum','multi_enum')) = (options IS NOT NULL)),
  CHECK (options IS NULL OR (jsonb_typeof(options) = 'array' AND jsonb_array_length(options) BETWEEN 1 AND 500)),
  CHECK ((data_type = 'ref') = (ref_entity IS NOT NULL)),
  CHECK (NOT is_required OR default_value IS NOT NULL),
  CHECK (NOT is_indexed OR data_type <> 'long_text'),
  CHECK (min_value IS NULL OR max_value IS NULL OR max_value >= min_value)
);
SELECT core.enable_tenant_rls('core.custom_field_def');

CREATE TABLE IF NOT EXISTS core.custom_field_index (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  entity_type  text NOT NULL,
  field_id     uuid NOT NULL,
  entity_id    uuid NOT NULL,
  value_text   text,
  value_num    numeric,
  value_date   date,
  value_bool   boolean,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, field_id) REFERENCES core.custom_field_def(tenant_id, id),
  CHECK (num_nonnulls(value_text, value_num, value_date, value_bool) = 1)
);
SELECT core.enable_tenant_rls('core.custom_field_index');
CREATE INDEX IF NOT EXISTS cfi_text_idx ON core.custom_field_index (tenant_id, field_id, value_text) WHERE value_text IS NOT NULL;
CREATE INDEX IF NOT EXISTS cfi_num_idx  ON core.custom_field_index (tenant_id, field_id, value_num)  WHERE value_num  IS NOT NULL;
CREATE INDEX IF NOT EXISTS cfi_date_idx ON core.custom_field_index (tenant_id, field_id, value_date) WHERE value_date IS NOT NULL;
CREATE INDEX IF NOT EXISTS cfi_entity_idx ON core.custom_field_index (tenant_id, entity_type, entity_id);

-- =====================================================================
-- ۱۱. پیوست (فرادادهٔ شیء در ذخیره‌ساز S3-سازگار یا فایل‌سیستم)
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.attachment (
  tenant_id             uuid NOT NULL REFERENCES core.tenant(id),
  id                    uuid NOT NULL DEFAULT uuidv7(),
  company_id            uuid,
  storage_backend       text NOT NULL CHECK (storage_backend IN ('s3','fs')),
  bucket                text NOT NULL,
  object_key            text NOT NULL,
  file_name             text NOT NULL CHECK (char_length(file_name) BETWEEN 1 AND 255 AND file_name !~ '[/\\]'
                                             AND file_name = core.fa_normalize_text(file_name)),
  declared_content_type text,
  sniffed_content_type  text,
  size_bytes            bigint CHECK (size_bytes IS NULL OR size_bytes BETWEEN 1 AND 1073741824),
  sha256                bytea CHECK (sha256 IS NULL OR octet_length(sha256) = 32),
  encryption_key_ref    text NOT NULL,
  status                text NOT NULL DEFAULT 'pending_upload'
                        CHECK (status IN ('pending_upload','uploaded','scanning','clean','infected','scan_failed','deleted')),
  av_engine             text,
  av_signature_version  text,
  av_result             text,
  scanned_at            timestamptz,
  retention_class       text NOT NULL DEFAULT 'attachment',
  -- هدف بارگذاری (۰۱ §۶ /api/v1/uploads: purpose): attachment، migration، update_package، diagnostics، print_logo، ...
  purpose               text NOT NULL DEFAULT 'attachment' CHECK (purpose ~ '^[a-z][a-z0-9_.]{1,60}$'),
  uploaded_by           uuid,
  created_at            timestamptz NOT NULL DEFAULT now(),
  uploaded_at           timestamptz,
  deleted_at            timestamptz,
  updated_at            timestamptz NOT NULL DEFAULT now(),
  row_version           integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (storage_backend, bucket, object_key),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, uploaded_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  -- فضای نام شیء هر مستأجر جداست: t/<tenant_id>/<yyyy>/<mm>/<attachment_id>
  CHECK (object_key ~ ('^t/' || tenant_id::text || '/[0-9]{4}/[0-9]{2}/' || id::text || '$')),
  CHECK (status = 'pending_upload' OR status = 'deleted' OR (size_bytes IS NOT NULL AND sha256 IS NOT NULL AND uploaded_at IS NOT NULL)),
  CHECK (status NOT IN ('clean','infected','scan_failed') OR (scanned_at IS NOT NULL AND av_engine IS NOT NULL)),
  CHECK ((status = 'deleted') = (deleted_at IS NOT NULL))
);
SELECT core.enable_tenant_rls('core.attachment');

CREATE TABLE IF NOT EXISTS core.attachment_link (
  tenant_id      uuid NOT NULL REFERENCES core.tenant(id),
  id             uuid NOT NULL DEFAULT uuidv7(),
  attachment_id  uuid NOT NULL,
  owner_module   text NOT NULL,
  owner_type     text NOT NULL CHECK (owner_type ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  owner_id       uuid NOT NULL,
  role           text NOT NULL DEFAULT 'attachment' CHECK (role ~ '^[a-z][a-z0-9_]{0,40}$'),
  is_locked      boolean NOT NULL DEFAULT false,
  created_by     uuid,
  created_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, attachment_id, owner_type, owner_id, role),
  FOREIGN KEY (tenant_id, attachment_id) REFERENCES core.attachment(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (split_part(owner_type, '.', 1) = owner_module)
);
SELECT core.enable_tenant_rls('core.attachment_link');
CREATE INDEX IF NOT EXISTS attachment_link_owner_idx ON core.attachment_link (tenant_id, owner_type, owner_id);

-- =====================================================================
-- ۱۲. Outbox، تحویل به مشترکان، webhook، صف job، زمان‌بند، کارهای سیستمی
--     پیاده‌سازی قرارداد بخش ۰۱ (§۴-۱ تا ۴-۵) به‌اضافهٔ افزوده‌های این بخش که با «افزوده» مشخص‌اند.
-- =====================================================================
-- کاتالوگ مشترکان و اشتراک‌ها (migration از رجیستری پایتون همگام می‌کند). افزوده: fan-out در پایگاه داده.
CREATE TABLE IF NOT EXISTS core.event_subscriber (
  subscriber                 text PRIMARY KEY CHECK (subscriber ~ '^[a-z][a-z0-9_.:-]{2,120}$'),
  ordered                    boolean NOT NULL DEFAULT false,      -- ترتیب سخت برای هر (مستأجر، aggregate)
  max_attempts               integer NOT NULL DEFAULT 25 CHECK (max_attempts BETWEEN 1 AND 100),
  requires_webhook_endpoint  boolean NOT NULL DEFAULT false,      -- فقط اگر مستأجر webhook فعال منطبق دارد
  enabled                    boolean NOT NULL DEFAULT true,
  introduced_in              text NOT NULL
);

CREATE TABLE IF NOT EXISTS core.event_subscription (
  event_type  text NOT NULL CHECK (event_type = '*'
                                   OR event_type ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'
                                   OR event_type ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)?\.\*$'),
  subscriber  text NOT NULL REFERENCES core.event_subscriber(subscriber),
  PRIMARY KEY (event_type, subscriber)
);

CREATE TABLE IF NOT EXISTS core.outbox_event (
  tenant_id      uuid NOT NULL REFERENCES core.tenant(id),
  id             uuid NOT NULL DEFAULT uuidv7(),          -- همان webhook-id
  seq            bigint GENERATED ALWAYS AS IDENTITY,     -- ترتیب تخصیص، نه ترتیب commit
  event_type     text NOT NULL CHECK (event_type ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  event_version  smallint NOT NULL DEFAULT 1 CHECK (event_version >= 1),
  aggregate_type text NOT NULL,
  aggregate_id   uuid NOT NULL,
  company_id     uuid,
  payload        jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
  headers        jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(headers) = 'object'),   -- افزوده: correlation_id، causation_id
  occurred_at    timestamptz NOT NULL DEFAULT now(),
  tx_id          xid8 NOT NULL DEFAULT pg_current_xact_id(),
  actor_user_id  uuid,
  request_id     text,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (seq),
  FOREIGN KEY (tenant_id, actor_user_id) REFERENCES core.tenant_membership(tenant_id, user_id)    -- R-ACTOR
);
SELECT core.enable_tenant_rls('core.outbox_event');
CREATE INDEX IF NOT EXISTS outbox_event_time_idx ON core.outbox_event (occurred_at);

CREATE TABLE IF NOT EXISTS core.outbox_delivery (
  tenant_id        uuid NOT NULL,
  id               uuid NOT NULL DEFAULT uuidv7(),          -- افزوده: کلید قراردادی id
  event_id         uuid NOT NULL,
  subscriber       text NOT NULL CHECK (subscriber ~ '^[a-z][a-z0-9_.:-]{2,120}$'),
  event_seq        bigint NOT NULL,
  aggregate_id     uuid NOT NULL,
  status           text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','running','done','dead')),
  attempts         integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  next_attempt_at  timestamptz NOT NULL DEFAULT now(),
  lease_owner      text,
  lease_expires_at timestamptz,
  last_error       jsonb,
  done_at          timestamptz,
  PRIMARY KEY (tenant_id, event_id, subscriber),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, event_id) REFERENCES core.outbox_event(tenant_id, id),
  FOREIGN KEY (subscriber) REFERENCES core.event_subscriber(subscriber),
  CHECK ((status = 'running') = (lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL)),
  CHECK ((status = 'done') = (done_at IS NOT NULL))
);
SELECT core.enable_tenant_rls('core.outbox_delivery');
CREATE INDEX IF NOT EXISTS outbox_delivery_claim ON core.outbox_delivery (subscriber, next_attempt_at, event_seq) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS outbox_delivery_order ON core.outbox_delivery (subscriber, tenant_id, aggregate_id, event_seq) WHERE status <> 'done';
CREATE INDEX IF NOT EXISTS outbox_delivery_lease ON core.outbox_delivery (lease_expires_at) WHERE status = 'running';
-- برداشتن مقیاس‌پذیر (RV-X4-06): پرش روی مستأجرها و سپس LIMIT برای هر مستأجر، هر دو با همین نمایه
CREATE INDEX IF NOT EXISTS outbox_delivery_tenant_due ON core.outbox_delivery (subscriber, tenant_id, next_attempt_at, event_seq)
  WHERE status = 'pending';

-- مکان نوبت‌گردشی رله‌گر برای هر مشترک (سراسری؛ فقط hk_dispatcher؛ دادهٔ مستأجر ندارد)
CREATE TABLE IF NOT EXISTS core.outbox_claim_cursor (
  subscriber      text PRIMARY KEY REFERENCES core.event_subscriber(subscriber),
  last_tenant_id  uuid,
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS core.webhook_endpoint (
  tenant_id              uuid NOT NULL REFERENCES core.tenant(id),
  id                     uuid NOT NULL DEFAULT uuidv7(),
  url                    text NOT NULL CHECK (url ~ '^https?://' AND length(url) <= 2048),
  description            text,
  event_types            text[] NOT NULL CHECK (cardinality(event_types) BETWEEN 1 AND 100),
  api_version            text NOT NULL CHECK (api_version ~ '^[0-9]{4}-[0-9]{2}$'),
  status                 text NOT NULL DEFAULT 'active' CHECK (status IN ('active','paused','disabled')),
  disabled_reason        text,
  secret_sealed          bytea NOT NULL,
  secret_prev_sealed     bytea,
  secret_prev_expires_at timestamptz,
  failure_streak         integer NOT NULL DEFAULT 0 CHECK (failure_streak >= 0),
  first_failure_at       timestamptz,
  allow_private_network  boolean NOT NULL DEFAULT false,
  created_by             uuid NOT NULL,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  row_version            integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),   -- افزوده
  CHECK ((status = 'disabled') = (disabled_reason IS NOT NULL)),
  CHECK ((secret_prev_sealed IS NULL) = (secret_prev_expires_at IS NULL)),
  CHECK (url ~ '^https://' OR allow_private_network)                                         -- افزوده: http فقط در شبکهٔ خصوصی On-prem
);
SELECT core.enable_tenant_rls('core.webhook_endpoint');

CREATE TABLE IF NOT EXISTS core.webhook_delivery (
  tenant_id            uuid NOT NULL,
  id                   uuid NOT NULL DEFAULT uuidv7(),
  endpoint_id          uuid NOT NULL,
  event_id             uuid NOT NULL,
  status               text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','running','succeeded','dead')),
  attempts             integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  next_attempt_at      timestamptz NOT NULL DEFAULT now(),
  lease_owner          text,
  lease_expires_at     timestamptz,
  last_response_status smallint,
  last_response_ms     integer,
  last_error           text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  succeeded_at         timestamptz,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, endpoint_id, event_id),
  FOREIGN KEY (tenant_id, endpoint_id) REFERENCES core.webhook_endpoint(tenant_id, id),
  FOREIGN KEY (tenant_id, event_id)    REFERENCES core.outbox_event(tenant_id, id),
  CHECK ((status = 'running') = (lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL)),
  CHECK ((status = 'succeeded') = (succeeded_at IS NOT NULL))
);
SELECT core.enable_tenant_rls('core.webhook_delivery');
CREATE INDEX IF NOT EXISTS webhook_delivery_claim ON core.webhook_delivery (next_attempt_at) WHERE status = 'pending';
-- FK و پاک‌سازی رویداد بر پایهٔ (tenant_id, event_id) جست‌وجو می‌کنند (RV-CORE-13)
CREATE INDEX IF NOT EXISTS webhook_delivery_event_idx ON core.webhook_delivery (tenant_id, event_id);

-- کاتالوگ صف‌ها و سقف پیش‌فرض اجرای هم‌زمان هر مستأجر (جدول بخش ۰۱ §۵-۶). افزوده.
CREATE TABLE IF NOT EXISTS core.job_queue (
  queue           text PRIMARY KEY CHECK (queue IN ('default','heavy','report','moadian','notify','sync','migration','webhook','maintenance')),
  per_tenant_cap  smallint NOT NULL CHECK (per_tenant_cap BETWEEN 1 AND 64),
  description     text NOT NULL
);

CREATE TABLE IF NOT EXISTS core.job (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  queue            text NOT NULL CHECK (queue IN ('default','heavy','report','moadian','notify','sync','migration','webhook','maintenance'))
                   REFERENCES core.job_queue(queue),
  kind             text NOT NULL CHECK (kind ~ '^[a-z][a-z0-9_]*\.[a-z0-9_.]+$'),
  payload          jsonb NOT NULL DEFAULT '{}'::jsonb,
  status           text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','running','succeeded','failed','dead','cancelled')),
  priority         smallint NOT NULL DEFAULT 100 CHECK (priority BETWEEN 0 AND 1000),
  run_after        timestamptz NOT NULL DEFAULT now(),
  attempts         integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  max_attempts     integer NOT NULL DEFAULT 10 CHECK (max_attempts BETWEEN 1 AND 100),
  lease_owner      text,
  lease_expires_at timestamptz,
  dedupe_key       text,
  concurrency_key  text,
  last_error       jsonb,
  result           jsonb,
  created_at       timestamptz NOT NULL DEFAULT now(),
  started_at       timestamptz,
  finished_at      timestamptz,
  created_by       uuid,
  request_id       text,
  row_version      integer NOT NULL DEFAULT 1,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  -- افزوده‌های این بخش
  lock_token       uuid,                                  -- توکن fencing هر claim
  backoff_base_s   integer NOT NULL DEFAULT 15 CHECK (backoff_base_s BETWEEN 1 AND 3600),
  backoff_cap_s    integer NOT NULL DEFAULT 21600 CHECK (backoff_cap_s BETWEEN 1 AND 86400),
  schedule_id      uuid,
  correlation_id   text,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),       -- R-ACTOR
  CHECK ((status = 'running') = (lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL)),
  CHECK ((status = 'running') = (lock_token IS NOT NULL)),
  CHECK (attempts <= max_attempts),
  CHECK ((status IN ('succeeded','failed','dead','cancelled')) = (finished_at IS NOT NULL)),
  CHECK (backoff_cap_s >= backoff_base_s)
);
SELECT core.enable_tenant_rls('core.job');
CREATE UNIQUE INDEX IF NOT EXISTS job_dedupe_active       ON core.job (tenant_id, kind, dedupe_key) WHERE dedupe_key IS NOT NULL AND status IN ('queued','running');
CREATE UNIQUE INDEX IF NOT EXISTS job_concurrency_running ON core.job (tenant_id, concurrency_key) WHERE concurrency_key IS NOT NULL AND status = 'running';
CREATE INDEX IF NOT EXISTS job_claim ON core.job (queue, priority, run_after, id) WHERE status = 'queued';
CREATE INDEX IF NOT EXISTS job_ready_tenant_idx ON core.job (queue, tenant_id, priority, run_after, id) WHERE status = 'queued';
CREATE INDEX IF NOT EXISTS job_running_idx  ON core.job (tenant_id, queue) WHERE status = 'running';
CREATE INDEX IF NOT EXISTS job_lease_idx    ON core.job (lease_expires_at) WHERE status = 'running';
CREATE INDEX IF NOT EXISTS job_finished_idx ON core.job (finished_at) WHERE finished_at IS NOT NULL;

-- افزوده: سقف و نوبت‌گردشی هر (مستأجر، صف)
CREATE TABLE IF NOT EXISTS core.job_tenant_state (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  queue            text NOT NULL REFERENCES core.job_queue(queue),
  max_running      smallint CHECK (max_running IS NULL OR max_running BETWEEN 1 AND 64),   -- NULL = سقف پیش‌فرض صف
  last_claimed_at  timestamptz,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, queue)
);
SELECT core.enable_tenant_rls('core.job_tenant_state');

CREATE TABLE IF NOT EXISTS core.job_schedule (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  kind          text NOT NULL CHECK (kind ~ '^[a-z][a-z0-9_]*\.[a-z0-9_.]+$'),
  queue         text NOT NULL DEFAULT 'default' REFERENCES core.job_queue(queue),
  cron          text NOT NULL CHECK (array_length(regexp_split_to_array(btrim(cron), ' +'), 1) = 5),
  timezone      text NOT NULL DEFAULT 'Asia/Tehran',
  payload       jsonb NOT NULL DEFAULT '{}'::jsonb,
  next_fire_at  timestamptz NOT NULL,
  is_enabled    boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  row_version   integer NOT NULL DEFAULT 1,
  -- افزوده‌های این بخش
  code          text CHECK (code ~ '^[a-z][a-z0-9_.]{1,80}$'),
  jalali_filter text CHECK (jalali_filter IN ('month_start','month_end','year_start','year_end')),  -- فقط روزهای منطبق جلالی اجرا شود
  max_attempts  integer NOT NULL DEFAULT 5 CHECK (max_attempts BETWEEN 1 AND 100),
  last_fired_at timestamptz,
  is_system     boolean NOT NULL DEFAULT false,
  created_by    uuid,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id)        -- R-ACTOR
);
SELECT core.enable_tenant_rls('core.job_schedule');
CREATE INDEX IF NOT EXISTS job_schedule_due_idx ON core.job_schedule (next_fire_at) WHERE is_enabled;

-- جدول‌های سراسری صفحهٔ داده (بدون tenant_id؛ قرارداد بخش ۰۱ §۴-۵)
CREATE TABLE IF NOT EXISTS core.system_task_run (
  task        text NOT NULL CHECK (task ~ '^[a-z][a-z0-9_.]+$'),
  fire_at     timestamptz NOT NULL,
  claimed_by  text NOT NULL,
  claimed_at  timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  outcome     text CHECK (outcome IN ('succeeded','failed')),
  detail      jsonb,
  PRIMARY KEY (task, fire_at),
  CHECK ((finished_at IS NULL) = (outcome IS NULL))
);

CREATE TABLE IF NOT EXISTS core.deployment_info (
  singleton       boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  install_id      uuid NOT NULL DEFAULT uuidv7(),
  profile         text NOT NULL CHECK (profile IN ('saas','onprem','edge','dev','test')),
  cell_id         text,
  app_version     text NOT NULL CHECK (app_version ~ '^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$'),
  schema_head     text NOT NULL,
  last_upgrade_at timestamptz,
  max_seen_at     timestamptz NOT NULL DEFAULT now(),
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK ((profile = 'saas') = (cell_id IS NOT NULL))
);

-- =====================================================================
-- ۱۳. اعلان
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.notification_category (
  code              text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_.]*$'),
  module            text NOT NULL,
  is_mandatory      boolean NOT NULL DEFAULT false,
  default_channels  text[] NOT NULL CHECK (default_channels <@ ARRAY['in_app','sms','email']::text[]),
  description_key   text NOT NULL,
  CHECK (split_part(code, '.', 1) = module)
);

CREATE TABLE IF NOT EXISTS core.notification_template_def (
  id                uuid PRIMARY KEY DEFAULT uuidv7(),
  code              text NOT NULL CHECK (code ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),
  category          text NOT NULL REFERENCES core.notification_category(code),
  channel           text NOT NULL CHECK (channel IN ('in_app','sms','email')),
  locale            text NOT NULL CHECK (locale IN ('fa-IR','en-US')),
  subject           text,
  body              text NOT NULL,
  sms_pattern_code  text,                -- الگوی تأییدشدهٔ سرویس‌دهنده (OTP فقط با الگو)
  variables         text[] NOT NULL DEFAULT '{}',
  -- متغیرهایی که فقط هنگام ارسال (در حافظه) پر می‌شوند و هرگز در core.notification ذخیره نمی‌شوند؛ مثلاً code در OTP
  -- که job ارسال از core.otp_challenge.id با کلید OTP بیرون از پایگاه داده بازمی‌سازد (RV-CORE-03)
  runtime_variables text[] NOT NULL DEFAULT '{}',
  tenant_overridable boolean NOT NULL DEFAULT true,
  UNIQUE (code, channel, locale),
  CHECK (sms_pattern_code IS NULL OR channel = 'sms'),
  CHECK (sms_pattern_code IS NULL OR NOT tenant_overridable),
  CHECK (runtime_variables <@ variables)
);

CREATE TABLE IF NOT EXISTS core.notification_template (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  code         text NOT NULL,
  channel      text NOT NULL,
  locale       text NOT NULL,
  subject      text,
  body         text NOT NULL CHECK (char_length(body) BETWEEN 1 AND 4000),
  is_active    boolean NOT NULL DEFAULT true,
  updated_by   uuid,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  row_version  integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code, channel, locale),
  FOREIGN KEY (code, channel, locale) REFERENCES core.notification_template_def(code, channel, locale),
  FOREIGN KEY (tenant_id, updated_by) REFERENCES core.tenant_membership(tenant_id, user_id)
);
SELECT core.enable_tenant_rls('core.notification_template');

CREATE TABLE IF NOT EXISTS core.notification (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  category             text NOT NULL REFERENCES core.notification_category(code),
  template_code        text NOT NULL,
  channel              text NOT NULL CHECK (channel IN ('in_app','sms','email')),
  locale               text NOT NULL DEFAULT 'fa-IR',
  recipient_user_id    uuid,
  recipient_address    text,
  params               jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(params) = 'object'),
  rendered_subject     text,
  rendered_body        text,
  status               text NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending','sending','sent','delivered','failed','read','cancelled')),
  priority             smallint NOT NULL DEFAULT 100,
  dedupe_key           text,
  provider             text,
  provider_message_id  text,
  attempts             smallint NOT NULL DEFAULT 0,
  last_error           jsonb,
  resource_type        text,
  resource_id          uuid,
  created_at           timestamptz NOT NULL DEFAULT now(),
  sent_at              timestamptz,
  delivered_at         timestamptz,
  read_at              timestamptz,
  expires_at           timestamptz,
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, dedupe_key),
  FOREIGN KEY (tenant_id, recipient_user_id) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (recipient_user_id IS NOT NULL OR recipient_address IS NOT NULL),
  CHECK (channel <> 'in_app' OR recipient_user_id IS NOT NULL),
  CHECK ((status = 'read') = (read_at IS NOT NULL)),
  CHECK (status <> 'read' OR channel = 'in_app')
);
SELECT core.enable_tenant_rls('core.notification');
CREATE INDEX IF NOT EXISTS notification_inbox_idx ON core.notification (tenant_id, recipient_user_id, created_at) WHERE channel = 'in_app';

CREATE TABLE IF NOT EXISTS core.notification_preference (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  user_id      uuid NOT NULL,
  category     text NOT NULL REFERENCES core.notification_category(code),
  channel      text NOT NULL CHECK (channel IN ('in_app','sms','email')),
  enabled      boolean NOT NULL,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  row_version  integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, user_id, category, channel),
  FOREIGN KEY (tenant_id, user_id) REFERENCES core.tenant_membership(tenant_id, user_id)
);
SELECT core.enable_tenant_rls('core.notification_preference');

-- =====================================================================
-- ۱۴. بستهٔ صادراتی مستأجر (.hkx): رجیستری جدول‌ها، صدور، درون‌ریزی
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.export_table_registry (
  schema_name     text NOT NULL,
  table_name      text NOT NULL,
  module          text NOT NULL,
  mode            text NOT NULL CHECK (mode IN ('rows','hook','skip')),
  export_order    integer NOT NULL,
  pii_columns     text[] NOT NULL DEFAULT '{}',
  secret_columns  text[] NOT NULL DEFAULT '{}',
  note            text,
  PRIMARY KEY (schema_name, table_name),
  CHECK (mode <> 'skip' OR note IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS core.tenant_export (
  tenant_id                  uuid NOT NULL REFERENCES core.tenant(id),
  id                         uuid NOT NULL DEFAULT uuidv7(),
  purpose                    text NOT NULL CHECK (purpose IN ('backup','move_to_onprem','move_to_saas','move_placement','offboarding','archive','restore_point')),
  status                     text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','running','completed','failed','expired')),
  requested_by               uuid,
  requested_by_staff_id      uuid,
  include_secrets            boolean NOT NULL DEFAULT false,
  recipient_key_fingerprint  text,
  format_version             text NOT NULL DEFAULT 'hkx/1',
  schema_version             text,
  app_version                text,
  object_key                 text,
  sha256                     bytea CHECK (sha256 IS NULL OR octet_length(sha256) = 32),
  size_bytes                 bigint,
  manifest                   jsonb,
  signature                  bytea,
  signing_key_id             text,
  -- بستهٔ ذخیره‌شده با DEK مستأجر (AES-256-GCM جریانی) رمز می‌شود؛ نابودی DEK بسته‌های نگه‌داشته را ناخوانا می‌کند (RV-CORE-28)
  encryption_key_ref         text,
  error                      jsonb,
  created_at                 timestamptz NOT NULL DEFAULT now(),
  started_at                 timestamptz,
  completed_at               timestamptz,
  expires_at                 timestamptz,
  updated_at                 timestamptz NOT NULL DEFAULT now(),
  row_version                integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, requested_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (requested_by IS NOT NULL OR requested_by_staff_id IS NOT NULL),
  CHECK (NOT include_secrets OR recipient_key_fingerprint IS NOT NULL),
  CHECK (status <> 'completed' OR (object_key IS NOT NULL AND sha256 IS NOT NULL AND manifest IS NOT NULL
                                   AND signature IS NOT NULL AND signing_key_id IS NOT NULL AND completed_at IS NOT NULL
                                   AND encryption_key_ref IS NOT NULL)),
  CHECK (object_key IS NULL OR object_key LIKE 't/' || tenant_id::text || '/exports/%')
);
SELECT core.enable_tenant_rls('core.tenant_export');

-- مانع صدور (08:CR-MG05 با سازوکار عمومی): هر ماژول (مثلاً migration هنگام committing/rolling_back) مانع فعال ثبت
-- می‌کند؛ core نمی‌داند مانع چیست (جهت DAG)، فقط ساخت صدور تازه را تا آزاد شدن همهٔ مانع‌ها رد می‌کند.
CREATE TABLE IF NOT EXISTS core.export_blocker (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  module        text NOT NULL CHECK (module ~ '^[a-z][a-z0-9_]*$'),
  reason_code   text NOT NULL CHECK (reason_code ~ '^[a-z][a-z0-9_.]{1,80}$'),
  resource_id   uuid,
  created_at    timestamptz NOT NULL DEFAULT now(),
  released_at   timestamptz,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  CHECK (released_at IS NULL OR released_at >= created_at)
);
SELECT core.enable_tenant_rls('core.export_blocker');
CREATE INDEX IF NOT EXISTS export_blocker_active_idx ON core.export_blocker (tenant_id) WHERE released_at IS NULL;

CREATE TABLE IF NOT EXISTS core.tenant_import (
  tenant_id              uuid NOT NULL REFERENCES core.tenant(id),
  id                     uuid NOT NULL DEFAULT uuidv7(),
  source_tenant_id       uuid NOT NULL,
  source_export_id       uuid NOT NULL,
  source_deployment      text NOT NULL CHECK (source_deployment IN ('saas_shared','saas_dedicated','onprem')),
  mode                   text NOT NULL CHECK (mode IN ('new_tenant','replace')),
  manifest               jsonb NOT NULL,
  manifest_sha256        bytea NOT NULL CHECK (octet_length(manifest_sha256) = 32),
  signing_key_id         text NOT NULL,
  signature_verified_at  timestamptz NOT NULL,
  status                 text NOT NULL CHECK (status IN ('verifying','completed','failed')),
  verification           jsonb NOT NULL DEFAULT '{}',
  performed_by_staff_id  uuid,
  started_at             timestamptz NOT NULL DEFAULT now(),
  completed_at           timestamptz,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  CHECK (source_tenant_id = tenant_id)
);
SELECT core.enable_tenant_rls('core.tenant_import');

-- =====================================================================
-- ۱۵. نگهداری، توقیف قانونی، درخواست دادهٔ شخصی
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.retention_class (
  code             text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{1,60}$'),
  basis            text NOT NULL CHECK (basis IN ('created_at','fiscal_year_end','closed_at','last_activity','expires_at')),
  default_period   interval,
  rules_param_key  text,                 -- دورهٔ قانونی از موتور قواعد (rules) خوانده می‌شود
  min_period       interval,
  action           text NOT NULL CHECK (action IN ('delete','anonymize','archive_then_delete')),
  description_key  text NOT NULL,
  CHECK (default_period IS NOT NULL OR rules_param_key IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS core.retention_override (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  class_code   text NOT NULL REFERENCES core.retention_class(code),
  period       interval NOT NULL,
  set_by       uuid NOT NULL,
  set_at       timestamptz NOT NULL DEFAULT now(),
  row_version  integer NOT NULL DEFAULT 1,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, class_code),
  FOREIGN KEY (tenant_id, set_by) REFERENCES core.tenant_membership(tenant_id, user_id)
);
SELECT core.enable_tenant_rls('core.retention_override');

CREATE TABLE IF NOT EXISTS core.legal_hold (
  tenant_id      uuid NOT NULL REFERENCES core.tenant(id),
  id             uuid NOT NULL DEFAULT uuidv7(),
  scope          text NOT NULL CHECK (scope IN ('tenant','company','resource','subject')),
  company_id     uuid,
  resource_type  text,
  resource_id    uuid,
  subject_type   text,
  subject_id     uuid,
  reason         text NOT NULL CHECK (char_length(btrim(reason)) >= 5),
  placed_by      uuid,
  placed_by_staff_id uuid,
  placed_at      timestamptz NOT NULL DEFAULT now(),
  released_at    timestamptz,
  released_by    uuid,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, placed_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, released_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (placed_by IS NOT NULL OR placed_by_staff_id IS NOT NULL),
  CHECK (   (scope = 'tenant'   AND company_id IS NULL AND resource_id IS NULL AND subject_id IS NULL)
         OR (scope = 'company'  AND company_id IS NOT NULL)
         OR (scope = 'resource' AND resource_type IS NOT NULL AND resource_id IS NOT NULL)
         OR (scope = 'subject'  AND subject_type IS NOT NULL AND subject_id IS NOT NULL)),
  CHECK ((released_at IS NULL) OR (released_by IS NOT NULL))
);
SELECT core.enable_tenant_rls('core.legal_hold');

CREATE TABLE IF NOT EXISTS core.data_subject_request (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  subject_type  text NOT NULL CHECK (subject_type IN ('party','user','employee')),
  subject_id    uuid NOT NULL,
  request_type  text NOT NULL CHECK (request_type IN ('access','export','erase','rectify')),
  status        text NOT NULL DEFAULT 'received' CHECK (status IN ('received','in_review','approved','rejected','completed')),
  requested_via text NOT NULL CHECK (requested_via IN ('tenant_admin','data_subject','platform_support')),
  requested_by  uuid NOT NULL,
  approved_by   uuid,
  decision_note text,
  plan          jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(plan) = 'array'),
  result        jsonb,
  received_at   timestamptz NOT NULL DEFAULT now(),
  decided_at    timestamptz,
  completed_at  timestamptz,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  row_version   integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, requested_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, approved_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (approved_by IS NULL OR approved_by <> requested_by),
  CHECK (status NOT IN ('approved','completed') OR approved_by IS NOT NULL),
  CHECK (status NOT IN ('approved','rejected','completed') OR decided_at IS NOT NULL),
  CHECK ((status = 'completed') = (completed_at IS NOT NULL))
);
SELECT core.enable_tenant_rls('core.data_subject_request');

-- =====================================================================
-- ۱۶. کلید idempotency — درج کلید اولین نوشتن تراکنش است؛ پاسخ پیش از COMMIT پر می‌شود
--     (قرارداد بخش ۰۱ §۴-۱ و §۵-۸)
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.idempotency_key (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  principal_id     uuid NOT NULL,                       -- کاربر، کلید API یا دستگاه
  idem_key         text NOT NULL CHECK (idem_key ~ '^[A-Za-z0-9._:-]{16,255}$'),
  method           text NOT NULL CHECK (method IN ('POST','PUT','PATCH','DELETE')),
  route            text NOT NULL,
  request_hash     bytea NOT NULL CHECK (octet_length(request_hash) = 32),
  -- NULL فقط درون تراکنش. پاسخ خطا هرگز ذخیره نمی‌شود: خطا تراکنش را برمی‌گرداند (۰۱ §۵-۸؛ RV-CORE-24)
  response_status  smallint CHECK (response_status BETWEEN 200 AND 399),
  response_body    jsonb,
  response_headers jsonb NOT NULL DEFAULT '{}'::jsonb,
  resource_type    text,
  resource_id      uuid,
  created_at       timestamptz NOT NULL DEFAULT now(),
  expires_at       timestamptz NOT NULL,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, principal_id, idem_key),
  CHECK (expires_at > created_at)
);
SELECT core.enable_tenant_rls('core.idempotency_key');
CREATE INDEX IF NOT EXISTS idempotency_key_expiry_idx ON core.idempotency_key (expires_at);

CREATE OR REPLACE FUNCTION core.idem_guard_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.response_status IS NOT NULL
     OR (NEW.tenant_id, NEW.principal_id, NEW.idem_key, NEW.request_hash, NEW.method, NEW.route)
        IS DISTINCT FROM (OLD.tenant_id, OLD.principal_id, OLD.idem_key, OLD.request_hash, OLD.method, OLD.route) THEN
    RAISE EXCEPTION 'HK_IMMUTABLE: completed or identity columns of core.idempotency_key cannot change' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_idem_guard_update ON core.idempotency_key;
CREATE TRIGGER trg_idem_guard_update BEFORE UPDATE ON core.idempotency_key
  FOR EACH ROW EXECUTE FUNCTION core.idem_guard_update();

CREATE OR REPLACE FUNCTION core.idem_assert_completed() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM core.idempotency_key k WHERE k.id = NEW.id AND k.response_status IS NULL) THEN
    RAISE EXCEPTION 'HK_IDEMPOTENCY_INCOMPLETE: idempotency key % committed without a stored response', NEW.idem_key
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_idem_completed ON core.idempotency_key;
CREATE CONSTRAINT TRIGGER trg_idem_completed AFTER INSERT ON core.idempotency_key
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION core.idem_assert_completed();

-- =====================================================================
-- ۱۷. سیاست‌های RLS ویژه (فراتر از tenant_isolation)
-- =====================================================================
-- عضو بودن: کاربر عضویت‌های خودش را در همهٔ مستأجرها می‌بیند (انتخاب مستأجر) — فقط **بدون** زمینهٔ مستأجر.
-- در زمینهٔ مستأجر X هیچ ردیف مستأجر دیگری دیده نمی‌شود، حتی برای حسابدار مشترک (INV-TEN-03؛ RV-CORE-15).
DROP POLICY IF EXISTS member_self_select ON core.tenant_membership;
CREATE POLICY member_self_select ON core.tenant_membership FOR SELECT
  USING (core.current_tenant_id() IS NULL AND user_id = core.current_user_id());
-- پذیرش دعوت با app.tenant_id همان مستأجر انجام می‌شود؛ سیاست بالا فقط خواندن است.

-- مستأجرهایی که کاربر عضو فعال/دعوت‌شدهٔ آن‌هاست (نام و slug برای انتخاب‌گر مستأجر) — فقط بدون زمینهٔ مستأجر
DROP POLICY IF EXISTS tenant_member_read ON core.tenant;
CREATE POLICY tenant_member_read ON core.tenant FOR SELECT
  USING (core.current_tenant_id() IS NULL AND EXISTS (SELECT 1 FROM core.tenant_membership m
                  WHERE m.tenant_id = tenant.id AND m.user_id = core.current_user_id()
                    AND m.status IN ('active','invited')));

-- زمینهٔ ممتاز: ابرکاربر/hk_migrator (BYPASSRLS؛ ابزار نگهداری، fixture آزمون) یا تابع definer بازبینی‌شدهٔ هسته.
-- نگهبان‌های هویت و عضویت مسیرهای بوت‌استرپ (provisioning، دعوت، درون‌ریزی) را فقط از همین راه می‌پذیرند.
CREATE OR REPLACE FUNCTION core.privileged_context() RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT coalesce((SELECT r.rolsuper OR r.rolbypassrls OR r.rolname = 'hk_core_definer'
                     FROM pg_catalog.pg_roles r WHERE r.rolname = current_user), false)
$$;

-- app_user: خود کاربر، حساب‌های سرویس مستأجر جاری، و اعضای **فعال/معلق** مستأجر جاری.
-- عضویت invited/removed هیچ هویتی را افشا نمی‌کند (RV-CORE-04؛ دعوت فقط مقصد دعوت را دارد).
ALTER TABLE core.app_user ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.app_user FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS user_select ON core.app_user;
CREATE POLICY user_select ON core.app_user FOR SELECT USING (
  id = core.current_user_id()
  OR home_tenant_id = core.current_tenant_id()
  OR EXISTS (SELECT 1 FROM core.tenant_membership m
              WHERE m.user_id = app_user.id AND m.tenant_id = core.current_tenant_id()
                AND m.status IN ('active','suspended')));
-- درج: خودثبت‌نامی انسان (id = app.user_id) یا حساب سرویس مستأجر جاری. کاربر دعوت‌شده فقط با core.member_invite
-- (definer) ساخته می‌شود؛ پس مستأجر A نمی‌تواند برای مستأجر B حساب سرویس یا کاربر بکارد (RV-CORE-01).
DROP POLICY IF EXISTS user_insert ON core.app_user;
CREATE POLICY user_insert ON core.app_user FOR INSERT WITH CHECK (
     (kind = 'human' AND id = core.current_user_id() AND home_tenant_id IS NULL)
  OR (kind = 'service' AND core.current_tenant_id() IS NOT NULL AND home_tenant_id = core.current_tenant_id()));
DROP POLICY IF EXISTS user_update ON core.app_user;
CREATE POLICY user_update ON core.app_user FOR UPDATE
  USING (id = core.current_user_id() OR home_tenant_id = core.current_tenant_id())
  WITH CHECK (id = core.current_user_id() OR home_tenant_id = core.current_tenant_id());
DROP POLICY IF EXISTS definer_read ON core.app_user;
CREATE POLICY definer_read ON core.app_user FOR SELECT TO hk_core_definer USING (true);
DROP POLICY IF EXISTS definer_insert ON core.app_user;
CREATE POLICY definer_insert ON core.app_user FOR INSERT TO hk_core_definer
  WITH CHECK (kind = 'human' AND created_via IN ('invitation','provisioning'));

-- user_login_identifier: خود کاربر همه؛ مستأجر جاری فقط شناسه‌های **تأییدشدهٔ** اعضای فعال/معلق خود.
ALTER TABLE core.user_login_identifier ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.user_login_identifier FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS uli_select ON core.user_login_identifier;
CREATE POLICY uli_select ON core.user_login_identifier FOR SELECT USING (
  user_id = core.current_user_id()
  OR (verified_at IS NOT NULL AND EXISTS (SELECT 1 FROM core.tenant_membership m
              WHERE m.user_id = user_login_identifier.user_id AND m.tenant_id = core.current_tenant_id()
                AND m.status IN ('active','suspended'))));
-- درج فقط برای خود کاربر (RV-IT2-07/RV-CORE-01)؛ دعوت از راه core.member_invite (definer، فقط تأییدنشده)
DROP POLICY IF EXISTS uli_insert ON core.user_login_identifier;
CREATE POLICY uli_insert ON core.user_login_identifier FOR INSERT WITH CHECK (user_id = core.current_user_id());
DROP POLICY IF EXISTS uli_update ON core.user_login_identifier;
CREATE POLICY uli_update ON core.user_login_identifier FOR UPDATE
  USING (user_id = core.current_user_id()) WITH CHECK (user_id = core.current_user_id());
DROP POLICY IF EXISTS uli_delete ON core.user_login_identifier;
CREATE POLICY uli_delete ON core.user_login_identifier FOR DELETE USING (user_id = core.current_user_id());
DROP POLICY IF EXISTS definer_read ON core.user_login_identifier;
CREATE POLICY definer_read ON core.user_login_identifier FOR SELECT TO hk_core_definer USING (true);
DROP POLICY IF EXISTS definer_insert ON core.user_login_identifier;
CREATE POLICY definer_insert ON core.user_login_identifier FOR INSERT TO hk_core_definer WITH CHECK (true);

-- جدول‌های کاملاً خصوصی کاربر
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['core.user_credential','core.user_recovery_code','core.user_session',
                           'core.otp_challenge']
  LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS user_self ON %s', t);
    EXECUTE format('CREATE POLICY user_self ON %s FOR ALL USING (user_id = core.current_user_id()) '
                   'WITH CHECK (user_id = core.current_user_id())', t);
  END LOOP;
END $$;

-- auth_event: درج آزاد (لاگ امنیتی، حتی بدون کاربر)، خواندن فقط رخدادهای خود کاربر
ALTER TABLE core.auth_event ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.auth_event FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS auth_event_insert ON core.auth_event;
CREATE POLICY auth_event_insert ON core.auth_event FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS auth_event_select ON core.auth_event;
CREATE POLICY auth_event_select ON core.auth_event FOR SELECT USING (user_id = core.current_user_id());

-- نقش dispatcher: دید سراسری فقط روی جدول‌های صف (قرارداد بخش ۰۱ §۴-۳) + افزوده‌ها
DROP POLICY IF EXISTS dispatcher_all ON core.job;
CREATE POLICY dispatcher_all ON core.job AS PERMISSIVE FOR ALL TO hk_dispatcher USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS dispatcher_all ON core.job_schedule;
CREATE POLICY dispatcher_all ON core.job_schedule AS PERMISSIVE FOR ALL TO hk_dispatcher USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS dispatcher_all ON core.outbox_delivery;
CREATE POLICY dispatcher_all ON core.outbox_delivery AS PERMISSIVE FOR ALL TO hk_dispatcher USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS dispatcher_all ON core.job_tenant_state;
CREATE POLICY dispatcher_all ON core.job_tenant_state AS PERMISSIVE FOR ALL TO hk_dispatcher USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS dispatcher_purge ON core.outbox_event;
CREATE POLICY dispatcher_purge ON core.outbox_event AS PERMISSIVE FOR ALL TO hk_dispatcher USING (true) WITH CHECK (false);
DROP POLICY IF EXISTS dispatcher_purge ON core.idempotency_key;
CREATE POLICY dispatcher_purge ON core.idempotency_key AS PERMISSIVE FOR ALL TO hk_dispatcher USING (true) WITH CHECK (false);
DROP POLICY IF EXISTS dispatcher_purge ON core.webhook_delivery;
CREATE POLICY dispatcher_purge ON core.webhook_delivery AS PERMISSIVE FOR ALL TO hk_dispatcher USING (true) WITH CHECK (false);
DROP POLICY IF EXISTS dispatcher_purge ON core.auth_event;
CREATE POLICY dispatcher_purge ON core.auth_event AS PERMISSIVE FOR ALL TO hk_dispatcher USING (true) WITH CHECK (false);
DROP POLICY IF EXISTS dispatcher_purge ON core.otp_challenge;
CREATE POLICY dispatcher_purge ON core.otp_challenge AS PERMISSIVE FOR ALL TO hk_dispatcher USING (true) WITH CHECK (false);
DROP POLICY IF EXISTS dispatcher_purge ON core.device_token;
CREATE POLICY dispatcher_purge ON core.device_token AS PERMISSIVE FOR ALL TO hk_dispatcher USING (true) WITH CHECK (false);
DROP POLICY IF EXISTS dispatcher_read ON core.tenant;
CREATE POLICY dispatcher_read ON core.tenant AS PERMISSIVE FOR SELECT TO hk_dispatcher USING (true);
-- پاک‌سازی باید توقیف و دورهٔ مستأجر را ببیند (RV-CORE-12)؛ فقط ستون‌های لازم (GRANT ستونی)
DROP POLICY IF EXISTS dispatcher_read ON core.legal_hold;
CREATE POLICY dispatcher_read ON core.legal_hold AS PERMISSIVE FOR SELECT TO hk_dispatcher USING (true);
DROP POLICY IF EXISTS dispatcher_read ON core.retention_override;
CREATE POLICY dispatcher_read ON core.retention_override AS PERMISSIVE FOR SELECT TO hk_dispatcher USING (true);

-- حل توکن (definer): فقط خواندن ردیف‌های لازم؛ و ابطال نشست دستگاه ابطال‌شده (device_revoke_sessions)
DROP POLICY IF EXISTS definer_read ON core.user_session;
CREATE POLICY definer_read ON core.user_session FOR SELECT TO hk_core_definer USING (true);
DROP POLICY IF EXISTS definer_revoke ON core.user_session;
CREATE POLICY definer_revoke ON core.user_session FOR UPDATE TO hk_core_definer USING (true) WITH CHECK (revoked_at IS NOT NULL);
DROP POLICY IF EXISTS definer_read ON core.tenant_membership;
CREATE POLICY definer_read ON core.tenant_membership FOR SELECT TO hk_core_definer USING (true);
DROP POLICY IF EXISTS definer_read ON core.device_token;
CREATE POLICY definer_read ON core.device_token FOR SELECT TO hk_core_definer USING (true);
DROP POLICY IF EXISTS definer_read ON core.device;
CREATE POLICY definer_read ON core.device FOR SELECT TO hk_core_definer USING (true);
DROP POLICY IF EXISTS definer_read ON core.impersonation_session;
CREATE POLICY definer_read ON core.impersonation_session FOR SELECT TO hk_core_definer USING (true);

-- =====================================================================
-- ۱۸. کلید API (پس از سیاست‌ها چون definer به آن نیاز دارد)
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.api_key (
  tenant_id      uuid NOT NULL REFERENCES core.tenant(id),
  id             uuid NOT NULL DEFAULT uuidv7(),
  user_id        uuid NOT NULL,                 -- حساب سرویس یا کاربر انسانی (توکن شخصی)
  name           text NOT NULL,
  prefix         text NOT NULL UNIQUE CHECK (prefix ~ '^hk_[a-z]{2,10}_[a-z2-7]{16}$'),
  secret_hash    bytea NOT NULL CHECK (octet_length(secret_hash) = 32),   -- SHA-256 راز ۲۵۶ بیتی
  permissions    text[],                        -- NULL = همهٔ مجوزهای مؤثر صاحب کلید؛ وگرنه زیرمجموعه
  allowed_cidrs  cidr[],
  expires_at     timestamptz NOT NULL,
  created_by     uuid NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  last_used_at   timestamptz,
  revoked_at     timestamptz,
  revoked_by     uuid,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  row_version    integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, user_id) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, revoked_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (expires_at > created_at AND expires_at <= created_at + interval '400 days'),
  CHECK ((revoked_at IS NULL) = (revoked_by IS NULL))
);
SELECT core.enable_tenant_rls('core.api_key');
DROP POLICY IF EXISTS definer_read ON core.api_key;
CREATE POLICY definer_read ON core.api_key FOR SELECT TO hk_core_definer USING (true);

-- =====================================================================
-- ۱۹. توابع و تریگرها
-- =====================================================================

-- ---------- touch_row برای همهٔ جدول‌های تغییرپذیر ----------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'core.app_user','core.user_credential','core.tenant_membership','core.device','core.member_pin',
    'core.role','core.role_assignment','core.sod_rule','core.approval_policy','core.approval_request',
    'core.support_access_grant','core.number_series','core.setting_value','core.custom_field_def',
    'core.attachment','core.webhook_endpoint','core.job','core.job_schedule','core.notification_template',
    'core.notification','core.notification_preference','core.tenant_export','core.retention_override',
    'core.data_subject_request','core.api_key']
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_touch ON %s', t);
    EXECUTE format('CREATE TRIGGER trg_touch BEFORE UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION core.touch_row()', t);
  END LOOP;
END $$;

-- ---------- جدول‌های فقط‌افزودنی ----------
DO $$
DECLARE t text;
BEGIN
  -- هرگز UPDATE و DELETE (فقط پاک‌سازی کامل مستأجر با session_replication_role=replica)
  FOREACH t IN ARRAY ARRAY['core.audit_log','core.audit_checkpoint','core.audit_anchor','core.number_issued',
                           'core.approval_decision','core.setting_history']
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_immutable ON %s', t);
    EXECUTE format('CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation()', t);
  END LOOP;
  -- هرگز UPDATE؛ DELETE فقط با تابع پاک‌سازی بازبینی‌شده (hk_app امتیاز DELETE ندارد)
  FOREACH t IN ARRAY ARRAY['core.auth_event','core.tenant_import']
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_immutable ON %s', t);
    EXECUTE format('CREATE TRIGGER trg_immutable BEFORE UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation()', t);
  END LOOP;
END $$;

-- ---------- خطای استاندارد ----------
CREATE OR REPLACE FUNCTION core.raise_hk(p_code text, p_message text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '%: %', p_code, p_message USING ERRCODE = 'P0001';
END $$;

-- ---------- هویت: ستون‌های امنیتی app_user و تأیید شناسهٔ ورود (RV-CORE-29، RV-CORE-25) ----------
CREATE OR REPLACE FUNCTION core.app_user_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.kind = 'service' THEN
      NEW.created_via := 'service';
    ELSIF NOT core.privileged_context() THEN
      NEW.created_via := 'self';          -- invitation/provisioning/import فقط از مسیر ممتاز
    END IF;
    IF NOT core.privileged_context() AND (NEW.security_epoch <> 1 OR NEW.status <> 'active') THEN
      PERFORM core.raise_hk('HK_CORE_USER_INSERT', 'a new user starts active at security_epoch 1');
    END IF;
    RETURN NEW;
  END IF;
  -- نوع حساب و مستأجر خانهٔ حساب سرویس هرگز عوض نمی‌شوند (نه حتی با نقش ممتاز)
  IF (NEW.id, NEW.kind, NEW.home_tenant_id, NEW.created_at, NEW.created_via)
     IS DISTINCT FROM (OLD.id, OLD.kind, OLD.home_tenant_id, OLD.created_at, OLD.created_via) THEN
    PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'app_user identity columns (kind, home tenant) are immutable');
  END IF;
  -- خروج از همه‌جا / تغییر رمز: فقط یک واحد بالا؛ هرگز پایین (توکن‌های کهنه زنده نمی‌شوند)
  IF NEW.security_epoch < OLD.security_epoch OR NEW.security_epoch > OLD.security_epoch + 1 THEN
    PERFORM core.raise_hk('HK_CORE_SECURITY_EPOCH', 'security_epoch only moves forward by one');
  END IF;
  IF NOT core.privileged_context() THEN
    -- وضعیت انسان را فقط ابزار پلتفرم/حذف دادهٔ شخصی (نقش ممتاز) عوض می‌کند؛ حساب سرویس را مدیر مستأجر خانه
    IF NEW.status IS DISTINCT FROM OLD.status
       AND NOT (OLD.kind = 'service' AND OLD.home_tenant_id = core.current_tenant_id() AND NEW.status IN ('active','disabled')) THEN
      PERFORM core.raise_hk('HK_CORE_USER_STATUS', format('user status %s -> %s is not allowed here', OLD.status, NEW.status));
    END IF;
    IF NEW.mfa_required IS DISTINCT FROM OLD.mfa_required AND OLD.id IS DISTINCT FROM core.current_user_id() THEN
      PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'only the user changes their own mfa_required');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.app_user;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON core.app_user FOR EACH ROW EXECUTE FUNCTION core.app_user_guard();

-- شناسهٔ ورود: (کاربر، نوع، مقدار) تغییرناپذیر؛ verified_at فقط با OTP مصرف‌شدهٔ همان مقصد برای همان کاربر
-- (یا نام کاربری که خود کاربر برمی‌گزیند)، یا در زمینهٔ ممتاز (provisioning امضاشده، درون‌ریزی).
CREATE OR REPLACE FUNCTION core.uli_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  -- فقط خود کاربر (RLS uli_insert/uli_update هم همین است)؛ پیش از هر بررسی دیگر با 42501 روشن
  IF NEW.user_id IS DISTINCT FROM core.current_user_id() AND NOT core.privileged_context() THEN
    RAISE EXCEPTION 'HK_CORE_NOT_SELF: login identifiers are written only by their user' USING ERRCODE = '42501';
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF (NEW.user_id, NEW.kind, NEW.value) IS DISTINCT FROM (OLD.user_id, OLD.kind, OLD.value) THEN
      PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'login identifier (user, kind, value) is immutable; delete and add a new one');
    END IF;
    IF OLD.verified_at IS NOT NULL AND NEW.verified_at IS NOT NULL AND NEW.verified_at <> OLD.verified_at THEN
      PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'verified_at cannot be rewritten');
    END IF;
  END IF;
  IF NEW.verified_at IS NOT NULL AND (TG_OP = 'INSERT' OR OLD.verified_at IS NULL) AND NOT core.privileged_context() THEN
    -- نام کاربری را خود کاربر برمی‌گزیند (نوشتن غیرخود بالاتر با 42501 رد شده است)؛ تلفن/ایمیل فقط با OTP مصرف‌شده
    IF NEW.kind <> 'username' AND NOT EXISTS (
        SELECT 1 FROM core.otp_challenge c
         WHERE c.user_id = NEW.user_id AND c.destination = NEW.value
           AND c.channel = CASE NEW.kind WHEN 'phone' THEN 'sms' ELSE 'email' END
           AND c.purpose IN ('verify_phone','verify_email','login','password_reset','step_up')
           AND c.consumed_at IS NOT NULL AND c.consumed_at >= now() - interval '15 minutes') THEN
      PERFORM core.raise_hk('HK_CORE_UNVERIFIED', 'verified_at needs a consumed OTP challenge for this destination');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.user_login_identifier;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON core.user_login_identifier FOR EACH ROW EXECUTE FUNCTION core.uli_guard();

-- چالش OTP (پایهٔ تأیید شناسه در uli_guard): مصرف‌نشده ساخته می‌شود؛ مقصد و hash تغییرناپذیر؛ تلاش فقط بالا؛
-- مصرف یک‌بار و فقط پیش از انقضا و پیش از پایان تلاش‌ها. پس «OTP مصرف‌شده» را برنامه نمی‌تواند جعل کند.
CREATE OR REPLACE FUNCTION core.otp_challenge_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.consumed_at IS NOT NULL OR NEW.attempts <> 0 OR NEW.created_at > now() + interval '1 minute'
       OR NEW.created_at < now() - interval '1 minute' THEN
      PERFORM core.raise_hk('HK_CORE_OTP', 'an OTP challenge starts unconsumed, with 0 attempts, now');
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.id, NEW.user_id, NEW.purpose, NEW.channel, NEW.destination, NEW.code_hash, NEW.max_attempts, NEW.created_at, NEW.expires_at)
     IS DISTINCT FROM
     (OLD.id, OLD.user_id, OLD.purpose, OLD.channel, OLD.destination, OLD.code_hash, OLD.max_attempts, OLD.created_at, OLD.expires_at)
     OR NEW.attempts < OLD.attempts THEN
    PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'OTP challenge is immutable except attempts (up) and consumption');
  END IF;
  IF OLD.consumed_at IS NOT NULL AND NEW.consumed_at IS DISTINCT FROM OLD.consumed_at THEN
    PERFORM core.raise_hk('HK_CORE_OTP', 'an OTP challenge is consumed once');
  END IF;
  IF OLD.consumed_at IS NULL AND NEW.consumed_at IS NOT NULL
     AND (OLD.expires_at <= now() OR OLD.attempts >= OLD.max_attempts) THEN
    PERFORM core.raise_hk('HK_CORE_OTP', 'an expired or exhausted OTP challenge cannot be consumed');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.otp_challenge;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON core.otp_challenge FOR EACH ROW EXECUTE FUNCTION core.otp_challenge_guard();

-- ---------- عضویت: ماشین حالت + درج فقط «دعوت» + پذیرش فقط توسط خود کاربر + حداقل یک مالک فعال ----------
CREATE OR REPLACE FUNCTION core.membership_transition_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- RV-IT2-08: عضویت تازه در زمینهٔ عادی فقط «دعوت» است (بدون مالکیت و joined_at). استثناها: زمینهٔ ممتاز
    -- (provisioning مالک، core.member_invite، ابزار نگهداری) و حساب سرویسِ خانهٔ همین مستأجر (پذیرش ندارد).
    IF NOT core.privileged_context() AND (NEW.status <> 'invited' OR NEW.is_owner OR NEW.joined_at IS NOT NULL) THEN
      IF NOT (NEW.status = 'active' AND NOT NEW.is_owner
              AND EXISTS (SELECT 1 FROM core.app_user u
                           WHERE u.id = NEW.user_id AND u.kind = 'service' AND u.home_tenant_id = NEW.tenant_id)) THEN
        PERFORM core.raise_hk('HK_CORE_MEMBERSHIP_INSERT', 'a new membership must be an invitation (status invited, not owner)');
      END IF;
    END IF;
    IF NEW.status = 'active' AND NEW.joined_at IS NULL THEN NEW.joined_at := now(); END IF;
    RETURN NEW;
  END IF;
  IF NEW.tenant_id <> OLD.tenant_id OR NEW.user_id <> OLD.user_id OR NEW.id <> OLD.id THEN
    PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'membership identity columns are immutable');
  END IF;
  IF NEW.status <> OLD.status THEN
    IF NOT ((OLD.status, NEW.status) IN (('invited','active'),('invited','removed'),('active','suspended'),
             ('suspended','active'),('active','removed'),('suspended','removed'),('removed','invited'))) THEN
      PERFORM core.raise_hk('HK_CORE_INVALID_TRANSITION', format('membership %s -> %s', OLD.status, NEW.status));
    END IF;
    -- پذیرش دعوت فقط توسط خود کاربر دعوت‌شده (یا زمینهٔ ممتاز)
    IF OLD.status = 'invited' AND NEW.status = 'active'
       AND NEW.user_id IS DISTINCT FROM core.current_user_id() AND NOT core.privileged_context() THEN
      PERFORM core.raise_hk('HK_CORE_NOT_INVITEE', 'only the invited user can accept the invitation');
    END IF;
    NEW.status_changed_at := now();
    IF NEW.status = 'active' AND NEW.joined_at IS NULL THEN NEW.joined_at := now(); END IF;
  END IF;
  -- مالک شدن فقط با تصمیم یک مالک فعال همین مستأجر (انتقال مالکیت) یا زمینهٔ ممتاز
  IF NEW.is_owner AND NOT OLD.is_owner AND NOT core.privileged_context()
     AND NOT EXISTS (SELECT 1 FROM core.tenant_membership o
                      WHERE o.tenant_id = NEW.tenant_id AND o.user_id = core.current_user_id()
                        AND o.is_owner AND o.status = 'active') THEN
    PERFORM core.raise_hk('HK_CORE_OWNER_GRANT', 'only an active owner can make another member an owner');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_transition ON core.tenant_membership;
CREATE TRIGGER trg_transition BEFORE INSERT OR UPDATE ON core.tenant_membership
  FOR EACH ROW EXECUTE FUNCTION core.membership_transition_guard();

CREATE OR REPLACE FUNCTION core.membership_owner_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  -- قفل ردیف مستأجر: تغییرهای هم‌زمان مالکیت سریالی می‌شوند (جلوگیری از write skew)
  PERFORM 1 FROM core.tenant WHERE id = NEW.tenant_id FOR NO KEY UPDATE;
  IF NOT EXISTS (SELECT 1 FROM core.tenant_membership
                  WHERE tenant_id = NEW.tenant_id AND is_owner AND status = 'active') THEN
    PERFORM core.raise_hk('HK_CORE_LAST_OWNER', format('tenant %s must keep at least one active owner', NEW.tenant_id));
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_owner_guard ON core.tenant_membership;
CREATE CONSTRAINT TRIGGER trg_owner_guard AFTER INSERT OR UPDATE ON core.tenant_membership
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION core.membership_owner_guard();

-- ---------- دستگاه: ماشین حالت ----------
CREATE OR REPLACE FUNCTION core.device_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status <> OLD.status AND NOT ((OLD.status, NEW.status) IN
       (('pending','active'),('pending','revoked'),('active','revoked'),('active','lost'))) THEN
    PERFORM core.raise_hk('HK_CORE_INVALID_TRANSITION', format('device %s -> %s', OLD.status, NEW.status));
  END IF;
  IF OLD.public_key IS NOT NULL AND NEW.public_key IS DISTINCT FROM OLD.public_key THEN
    PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'device public key cannot change; enroll a new device');
  END IF;
  IF NEW.status = 'active' AND OLD.status = 'pending' THEN
    IF OLD.enrollment_expires_at < now() THEN
      PERFORM core.raise_hk('HK_CORE_ENROLLMENT_EXPIRED', 'device enrollment code expired');
    END IF;
    NEW.enrollment_code_hash := NULL;     -- یک‌بارمصرف
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.device;
CREATE TRIGGER trg_guard BEFORE UPDATE ON core.device FOR EACH ROW EXECUTE FUNCTION core.device_guard();

-- ---------- توکن دستگاه: فقط ابطال ----------
CREATE OR REPLACE FUNCTION core.device_token_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.tenant_id, NEW.device_id, NEW.token_hash, NEW.issued_at, NEW.expires_at)
     IS DISTINCT FROM (OLD.tenant_id, OLD.device_id, OLD.token_hash, OLD.issued_at, OLD.expires_at)
     OR (OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at) THEN
    PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'device token can only be revoked once');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.device_token;
CREATE TRIGGER trg_guard BEFORE UPDATE ON core.device_token FOR EACH ROW EXECUTE FUNCTION core.device_token_guard();

-- ---------- نشست: نسخهٔ security_epoch، دستگاه فعال، ابطال یک‌طرفه (RV-CORE-02، RV-X4-05) ----------
-- (نسخهٔ پیشین تابع definer core.session_device_active(p_tenant, …) داشت که وضعیت دستگاه هر مستأجری را برای hk_app
--  آشکار می‌کرد؛ حذف شد: نشست دستگاه‌دار فقط در زمینهٔ همان مستأجر ساخته می‌شود و دستگاه با RLS عادی خوانده می‌شود.)
DROP FUNCTION IF EXISTS core.session_device_active(uuid, uuid);

CREATE OR REPLACE FUNCTION core.user_session_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_epoch integer;
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- نشست فقط برای خود کاربر احرازشده (RLS user_self هم همین را می‌گوید؛ این‌جا پیش از جست‌وجوی کاربر با پیام روشن)
    IF NEW.user_id IS DISTINCT FROM core.current_user_id() AND NOT core.privileged_context() THEN
      RAISE EXCEPTION 'HK_CORE_NOT_SELF: a session is created only for the current user' USING ERRCODE = '42501';
    END IF;
    SELECT u.security_epoch INTO v_epoch FROM core.app_user u WHERE u.id = NEW.user_id AND u.status = 'active';
    IF NOT FOUND THEN
      PERFORM core.raise_hk('HK_CORE_USER_INACTIVE', 'a session needs an active user');
    END IF;
    NEW.security_epoch := v_epoch;          -- هر مقدار ارسالی برنامه نادیده گرفته می‌شود
    -- نشست دستگاه‌دار (PIN صندوق) فقط در زمینهٔ همان مستأجر (ورود PIN پس از احراز دستگاه با توکن دستگاه) و با دستگاه active
    IF NEW.device_id IS NOT NULL AND (
         (core.current_tenant_id() IS DISTINCT FROM NEW.active_tenant_id AND NOT core.privileged_context())
         OR NOT EXISTS (SELECT 1 FROM core.device d
                         WHERE d.tenant_id = NEW.active_tenant_id AND d.id = NEW.device_id AND d.status = 'active')) THEN
      PERFORM core.raise_hk('HK_CORE_DEVICE_INACTIVE', 'a device-bound session needs an active device of the current (session) tenant');
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.id, NEW.user_id, NEW.device_id, NEW.client_kind, NEW.security_epoch, NEW.created_at)
     IS DISTINCT FROM (OLD.id, OLD.user_id, OLD.device_id, OLD.client_kind, OLD.security_epoch, OLD.created_at)
     OR NEW.absolute_expires_at > OLD.absolute_expires_at THEN
    PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'session identity is immutable and its lifetime can only shrink');
  END IF;
  IF OLD.revoked_at IS NOT NULL AND (NEW.revoked_at IS DISTINCT FROM OLD.revoked_at OR NEW.token_hash IS DISTINCT FROM OLD.token_hash) THEN
    PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'a revoked session is final');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.user_session;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON core.user_session FOR EACH ROW EXECUTE FUNCTION core.user_session_guard();

-- ابطال/گم شدن دستگاه ← نشست‌های PIN و توکن‌های همان دستگاه فوراً ابطال می‌شوند. مدیر مستأجر به نشست کاربر دیگر
-- (RLS کاربرمحور) دسترسی ندارد، پس این تریگر definer است و فقط همین ستون‌ها را می‌نویسد (§۸ بند ۷).
CREATE OR REPLACE FUNCTION core.device_revoke_sessions() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.status IN ('revoked','lost') AND OLD.status NOT IN ('revoked','lost') THEN
    UPDATE core.user_session SET revoked_at = now(), revoke_reason = 'device_' || NEW.status
     WHERE active_tenant_id = NEW.tenant_id AND device_id = NEW.id AND revoked_at IS NULL;
    UPDATE core.device_token SET revoked_at = now()
     WHERE tenant_id = NEW.tenant_id AND device_id = NEW.id AND revoked_at IS NULL;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_revoke_sessions ON core.device;
CREATE TRIGGER trg_revoke_sessions AFTER UPDATE OF status ON core.device
  FOR EACH ROW EXECUTE FUNCTION core.device_revoke_sessions();

-- ---------- کلید API: راز و پیشوند تغییرناپذیر؛ مجوزها از کاتالوگ ----------
CREATE OR REPLACE FUNCTION core.api_key_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.prefix <> OLD.prefix OR NEW.secret_hash <> OLD.secret_hash OR NEW.user_id <> OLD.user_id
       OR NEW.created_at <> OLD.created_at OR NEW.expires_at > OLD.expires_at THEN
      PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'api key identity/secret is immutable; expiry can only shrink');
    END IF;
    IF OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at THEN
      PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'revocation is final');
    END IF;
  END IF;
  IF NEW.permissions IS NOT NULL AND EXISTS (
       SELECT 1 FROM unnest(NEW.permissions) p WHERE NOT EXISTS (SELECT 1 FROM core.permission c WHERE c.code = p)) THEN
    PERFORM core.raise_hk('HK_CORE_UNKNOWN_PERMISSION', 'api key lists an unknown permission');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.api_key;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON core.api_key FOR EACH ROW EXECUTE FUNCTION core.api_key_guard();

-- ---------- نقش سیستمی: مجوزها فقط با همگام‌سازی رسمی ارتقا ----------
CREATE OR REPLACE FUNCTION core.role_permission_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_system boolean;
BEGIN
  SELECT is_system INTO v_system FROM core.role
   WHERE tenant_id = COALESCE(NEW.tenant_id, OLD.tenant_id) AND id = COALESCE(NEW.role_id, OLD.role_id);
  IF v_system AND coalesce(current_setting('app.system_role_sync', true), '') <> 'on' THEN
    PERFORM core.raise_hk('HK_CORE_SYSTEM_ROLE_LOCKED', 'permissions of system roles are managed by the platform');
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.role_permission;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON core.role_permission
  FOR EACH ROW EXECUTE FUNCTION core.role_permission_guard();

-- ---------- گردش تأیید ----------
CREATE OR REPLACE FUNCTION core.approval_step_approvals(p_tenant uuid, p_request uuid, p_step smallint) RETURNS integer
LANGUAGE sql STABLE AS $$
  SELECT count(*)::int FROM core.approval_decision
   WHERE tenant_id = p_tenant AND request_id = p_request AND step_no = p_step AND decision = 'approve'
$$;

CREATE OR REPLACE FUNCTION core.approval_request_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE s record; v_max smallint; p core.approval_policy; v_steps jsonb;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'pending' OR NEW.current_step <> 1 THEN
      PERFORM core.raise_hk('HK_APPROVAL_INVALID', 'new approval request must start pending at step 1');
    END IF;
    -- RV-CORE-06: سیاست باید فعال و با نوع موضوع و شرکت همین درخواست بخواند؛ snapshot، نسخه، پرچم‌ها و انقضا
    -- را **پایگاه داده** از خود سیاست می‌سازد و هر مقدار ارسالی برنامه جایگزین می‌شود.
    SELECT * INTO p FROM core.approval_policy x WHERE x.tenant_id = NEW.tenant_id AND x.id = NEW.policy_id;
    IF NOT FOUND OR NOT p.is_active OR p.subject_type <> NEW.subject_type
       OR (p.company_id IS NOT NULL AND p.company_id <> NEW.company_id) THEN
      PERFORM core.raise_hk('HK_APPROVAL_POLICY_MISMATCH', 'approval policy is inactive or does not cover this subject/company');
    END IF;
    SELECT jsonb_agg(jsonb_build_object('step_no', st.step_no, 'approver_kind', st.approver_kind, 'role_id', st.role_id,
                                        'user_id', st.user_id, 'permission_code', st.permission_code,
                                        'min_approvals', st.min_approvals) ORDER BY st.step_no)
      INTO v_steps
      FROM core.approval_policy_step st WHERE st.tenant_id = NEW.tenant_id AND st.policy_id = p.id;
    IF v_steps IS NULL
       OR (SELECT array_agg(x.step_no ORDER BY x.step_no) FROM jsonb_to_recordset(v_steps) AS x(step_no smallint))
          <> (SELECT array_agg(g::smallint) FROM generate_series(1, jsonb_array_length(v_steps)) g) THEN
      PERFORM core.raise_hk('HK_APPROVAL_INVALID', 'policy steps must be exactly 1..n');
    END IF;
    NEW.steps_snapshot     := v_steps;
    NEW.policy_version     := p.version;
    NEW.enforce_sod        := p.enforce_sod;
    NEW.distinct_approvers := p.distinct_approvers;
    -- مهلت از زمان پایگاه داده (نه created_at ارسالی برنامه که می‌توانست انقضا را به آینده ببرد)
    NEW.created_at         := now();
    NEW.expires_at         := CASE WHEN p.expires_after IS NOT NULL THEN now() + p.expires_after END;
    RETURN NEW;
  END IF;

  IF OLD.status <> 'pending' THEN
    PERFORM core.raise_hk('HK_APPROVAL_CLOSED', 'approval request is closed');
  END IF;
  IF (NEW.subject_type, NEW.subject_id, NEW.requested_by, NEW.policy_id, NEW.policy_version, NEW.steps_snapshot,
      NEW.enforce_sod, NEW.distinct_approvers, NEW.company_id, NEW.created_at)
     IS DISTINCT FROM
     (OLD.subject_type, OLD.subject_id, OLD.requested_by, OLD.policy_id, OLD.policy_version, OLD.steps_snapshot,
      OLD.enforce_sod, OLD.distinct_approvers, OLD.company_id, OLD.created_at)
     OR NEW.subject_created_by IS DISTINCT FROM OLD.subject_created_by
     OR NEW.amount IS DISTINCT FROM OLD.amount OR NEW.currency IS DISTINCT FROM OLD.currency
     OR NEW.expires_at IS DISTINCT FROM OLD.expires_at THEN
    PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'approval request subject/snapshot/expiry is immutable');
  END IF;
  v_max := jsonb_array_length(OLD.steps_snapshot);

  IF NEW.status = 'pending' THEN
    IF NEW.cancel_reason IS NOT NULL THEN
      PERFORM core.raise_hk('HK_APPROVAL_INVALID', 'cancel_reason only with status cancelled');
    END IF;
    IF NEW.current_step = OLD.current_step THEN RETURN NEW; END IF;
    IF NEW.current_step <> OLD.current_step + 1 OR NEW.current_step > v_max THEN
      PERFORM core.raise_hk('HK_APPROVAL_INVALID', 'current_step may only advance by one');
    END IF;
    SELECT * INTO s FROM jsonb_to_recordset(OLD.steps_snapshot) AS x(step_no smallint, min_approvals smallint)
     WHERE x.step_no = OLD.current_step;
    IF core.approval_step_approvals(OLD.tenant_id, OLD.id, OLD.current_step) < s.min_approvals THEN
      PERFORM core.raise_hk('HK_APPROVAL_QUORUM', 'step quorum not reached');
    END IF;
  ELSIF NEW.status = 'approved' THEN
    IF EXISTS (SELECT 1 FROM core.approval_decision WHERE tenant_id = OLD.tenant_id AND request_id = OLD.id AND decision = 'reject')
       OR EXISTS (SELECT 1 FROM jsonb_to_recordset(OLD.steps_snapshot) AS x(step_no smallint, min_approvals smallint)
                   WHERE core.approval_step_approvals(OLD.tenant_id, OLD.id, x.step_no) < x.min_approvals) THEN
      PERFORM core.raise_hk('HK_APPROVAL_QUORUM', 'not every step reached its quorum');
    END IF;
    IF OLD.expires_at IS NOT NULL AND OLD.expires_at <= now() THEN
      PERFORM core.raise_hk('HK_APPROVAL_EXPIRED', 'approval request expired');
    END IF;
    NEW.decided_at := now();
  ELSIF NEW.status = 'rejected' THEN
    IF NOT EXISTS (SELECT 1 FROM core.approval_decision WHERE tenant_id = OLD.tenant_id AND request_id = OLD.id AND decision = 'reject') THEN
      PERFORM core.raise_hk('HK_APPROVAL_INVALID', 'rejection requires a reject decision');
    END IF;
    NEW.decided_at := now();
  ELSIF NEW.status = 'expired' THEN
    -- RV-CORE-07: «منقضی» فقط وقتی مهلت واقعاً گذشته است
    IF OLD.expires_at IS NULL OR OLD.expires_at > now() THEN
      PERFORM core.raise_hk('HK_APPROVAL_INVALID', 'only a request past its expires_at can expire');
    END IF;
    NEW.decided_at := now();
  ELSE  -- cancelled (cancel_reason اجباری با CHECK)
    NEW.decided_at := now();
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.approval_request;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON core.approval_request
  FOR EACH ROW EXECUTE FUNCTION core.approval_request_guard();

-- تغییر گام‌های سیاست ← نسخهٔ سیاست بالا می‌رود (درخواست‌های باز snapshot خود را دارند)
CREATE OR REPLACE FUNCTION core.approval_policy_step_bump() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE core.approval_policy SET version = version + 1
   WHERE tenant_id = COALESCE(NEW.tenant_id, OLD.tenant_id) AND id = COALESCE(NEW.policy_id, OLD.policy_id);
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_bump ON core.approval_policy_step;
CREATE TRIGGER trg_bump AFTER INSERT OR UPDATE OR DELETE ON core.approval_policy_step
  FOR EACH ROW EXECUTE FUNCTION core.approval_policy_step_bump();

-- آیا عضو مجوز را از راه یک انتساب فعال دارد؟ (بدون دامنه؛ دامنه در AuthzService)
CREATE OR REPLACE FUNCTION core.member_holds_permission(p_tenant uuid, p_user uuid, p_permission text) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM core.role_assignment ra
      JOIN core.tenant_membership m ON m.tenant_id = ra.tenant_id AND m.id = ra.membership_id
      JOIN core.role r ON r.tenant_id = ra.tenant_id AND r.id = ra.role_id AND r.is_active
     WHERE ra.tenant_id = p_tenant AND m.user_id = p_user AND m.status = 'active'
       AND ra.revoked_at IS NULL AND ra.valid_from <= now() AND (ra.valid_to IS NULL OR ra.valid_to > now())
       AND (r.grants_all OR EXISTS (SELECT 1 FROM core.role_permission rp
                                     WHERE rp.tenant_id = ra.tenant_id AND rp.role_id = r.id AND rp.permission_code = p_permission)))
$$;

CREATE OR REPLACE FUNCTION core.approval_decision_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE r core.approval_request; s record;
BEGIN
  SELECT * INTO r FROM core.approval_request WHERE tenant_id = NEW.tenant_id AND id = NEW.request_id FOR UPDATE;
  IF NOT FOUND THEN PERFORM core.raise_hk('HK_APPROVAL_NOT_FOUND', 'approval request not found'); END IF;
  IF r.status <> 'pending' THEN PERFORM core.raise_hk('HK_APPROVAL_CLOSED', 'approval request is closed'); END IF;
  IF r.expires_at IS NOT NULL AND r.expires_at <= now() THEN
    PERFORM core.raise_hk('HK_APPROVAL_EXPIRED', 'approval request expired');
  END IF;
  IF NEW.step_no <> r.current_step THEN
    PERFORM core.raise_hk('HK_APPROVAL_WRONG_STEP', format('expected step %s', r.current_step));
  END IF;
  IF r.enforce_sod AND (NEW.decided_by = r.requested_by OR NEW.decided_by = r.subject_created_by) THEN
    PERFORM core.raise_hk('HK_SOD_VIOLATION', 'requester/creator cannot decide their own request');
  END IF;
  IF r.distinct_approvers AND EXISTS (SELECT 1 FROM core.approval_decision d
       WHERE d.tenant_id = NEW.tenant_id AND d.request_id = NEW.request_id AND d.decided_by = NEW.decided_by) THEN
    PERFORM core.raise_hk('HK_APPROVAL_DUPLICATE_APPROVER', 'one person may decide only once per request');
  END IF;
  -- تصمیم‌گیرنده همیشه عضو فعال است (RV-CORE-07)
  IF NOT EXISTS (SELECT 1 FROM core.tenant_membership m
                  WHERE m.tenant_id = NEW.tenant_id AND m.user_id = NEW.decided_by AND m.status = 'active') THEN
    PERFORM core.raise_hk('HK_APPROVAL_NOT_ELIGIBLE', 'decider is not an active member');
  END IF;
  SELECT * INTO s FROM jsonb_to_recordset(r.steps_snapshot)
         AS x(step_no smallint, approver_kind text, role_id uuid, user_id uuid, permission_code text, min_approvals smallint)
   WHERE x.step_no = NEW.step_no;
  IF s.approver_kind = 'user' THEN
    IF NEW.decided_by IS DISTINCT FROM s.user_id THEN
      PERFORM core.raise_hk('HK_APPROVAL_NOT_ELIGIBLE', 'decider is not the designated approver');
    END IF;
  ELSIF s.approver_kind = 'role' THEN
    IF NOT EXISTS (
          SELECT 1 FROM core.role_assignment ra
            JOIN core.tenant_membership m ON m.tenant_id = ra.tenant_id AND m.id = ra.membership_id
           WHERE ra.tenant_id = NEW.tenant_id AND m.user_id = NEW.decided_by AND m.status = 'active'
             AND ra.role_id = s.role_id AND ra.revoked_at IS NULL
             AND ra.valid_from <= now() AND (ra.valid_to IS NULL OR ra.valid_to > now())) THEN
      PERFORM core.raise_hk('HK_APPROVAL_NOT_ELIGIBLE', 'decider does not hold the approver role');
    END IF;
  ELSIF s.approver_kind = 'permission' THEN
    -- دامنهٔ شرکت را AuthzService می‌سنجد؛ پایگاه داده دست‌کم داشتن مجوز از راه انتساب فعال را اجبار می‌کند
    IF NOT core.member_holds_permission(NEW.tenant_id, NEW.decided_by, s.permission_code) THEN
      PERFORM core.raise_hk('HK_APPROVAL_NOT_ELIGIBLE', 'decider does not hold the approver permission');
    END IF;
  ELSE
    PERFORM core.raise_hk('HK_APPROVAL_INVALID', 'snapshot step has no approver kind');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.approval_decision;
CREATE TRIGGER trg_guard BEFORE INSERT ON core.approval_decision
  FOR EACH ROW EXECUTE FUNCTION core.approval_decision_guard();

-- قرارداد مصرف‌کننده (RV-CORE-26): ماژول پیش از قطعی‌کردن سند (در همان تراکنش) صدا می‌زند؛ درخواست باید approved
-- و مال همان موضوع باشد. تابع تغییرناپذیر نیست چون وضعیت را می‌خواند؛ STABLE و با RLS مستأجر جاری.
CREATE OR REPLACE FUNCTION core.approval_assert_approved(p_request uuid, p_subject_type text, p_subject_id uuid)
RETURNS void
LANGUAGE plpgsql STABLE AS $$
DECLARE r core.approval_request;
BEGIN
  SELECT * INTO r FROM core.approval_request x WHERE x.id = p_request;
  IF NOT FOUND OR r.subject_type <> p_subject_type OR r.subject_id <> p_subject_id THEN
    PERFORM core.raise_hk('HK_APPROVAL_NOT_FOUND', 'approval request does not belong to this subject');
  END IF;
  IF r.status <> 'approved' THEN
    PERFORM core.raise_hk('HK_APPROVAL_REQUIRED', format('approval request is %s, not approved', r.status));
  END IF;
END $$;

-- ---------- رضایت پشتیبانی و ورود به‌جای کاربر ----------
CREATE OR REPLACE FUNCTION core.support_grant_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF (NEW.granted_by, NEW.grantee_kind, NEW.access_mode, NEW.max_session_minutes, NEW.starts_at, NEW.created_at)
       IS DISTINCT FROM (OLD.granted_by, OLD.grantee_kind, OLD.access_mode, OLD.max_session_minutes, OLD.starts_at, OLD.created_at)
       OR NEW.expires_at > OLD.expires_at THEN
      PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'support grant may only be shortened or revoked');
    END IF;
    IF OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at THEN
      PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'revocation is final');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.support_access_grant;
CREATE TRIGGER trg_guard BEFORE UPDATE ON core.support_access_grant
  FOR EACH ROW EXECUTE FUNCTION core.support_grant_guard();

-- لغو یا کوتاه‌کردن رضایت ← پایان/کوتاه‌شدن فوری نشست‌های باز
CREATE OR REPLACE FUNCTION core.support_grant_cascade() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.revoked_at IS NOT NULL AND OLD.revoked_at IS NULL THEN
    UPDATE core.impersonation_session SET ended_at = now(), end_reason = 'grant_revoked'
     WHERE tenant_id = NEW.tenant_id AND grant_id = NEW.id AND ended_at IS NULL;
  ELSIF NEW.expires_at < OLD.expires_at THEN
    UPDATE core.impersonation_session SET expires_at = NEW.expires_at
     WHERE tenant_id = NEW.tenant_id AND grant_id = NEW.id AND ended_at IS NULL AND expires_at > NEW.expires_at;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_cascade ON core.support_access_grant;
CREATE TRIGGER trg_cascade AFTER UPDATE ON core.support_access_grant
  FOR EACH ROW EXECUTE FUNCTION core.support_grant_cascade();

CREATE OR REPLACE FUNCTION core.impersonation_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE g core.support_access_grant;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.started_at > now() + interval '1 minute' OR NEW.started_at < now() - interval '5 minutes' THEN
      PERFORM core.raise_hk('HK_IMP_CLOCK', 'impersonation session must start now');
    END IF;
    SELECT * INTO g FROM core.support_access_grant WHERE tenant_id = NEW.tenant_id AND id = NEW.grant_id;
    IF NOT FOUND OR g.revoked_at IS NOT NULL OR NEW.started_at < g.starts_at OR NEW.started_at >= g.expires_at
       OR NEW.grantee_kind <> g.grantee_kind THEN
      PERFORM core.raise_hk('HK_IMP_NO_CONSENT', 'no active tenant consent covers this session');
    END IF;
    IF NEW.expires_at > g.expires_at OR NEW.expires_at > NEW.started_at + make_interval(mins => g.max_session_minutes) THEN
      PERFORM core.raise_hk('HK_IMP_TOO_LONG', 'session exceeds the consented window or max duration');
    END IF;
    IF NEW.mode = 'read_write' AND g.access_mode <> 'read_write' THEN
      PERFORM core.raise_hk('HK_IMP_WRITE_NOT_CONSENTED', 'tenant consented to read-only access');
    END IF;
    IF NEW.ended_at IS NOT NULL THEN
      PERFORM core.raise_hk('HK_IMP_INVALID', 'session cannot be created already ended');
    END IF;
    RETURN NEW;
  END IF;
  -- UPDATE: فقط پایان دادن (یک‌بار) یا کوتاه‌کردن
  IF (NEW.grant_id, NEW.grantee_kind, NEW.staff_id, NEW.assertion_jti, NEW.reason, NEW.ticket_ref, NEW.mode, NEW.target_user_id,
      NEW.write_approver_staff_id, NEW.started_at, NEW.staff_display_name)
     IS DISTINCT FROM
     (OLD.grant_id, OLD.grantee_kind, OLD.staff_id, OLD.assertion_jti, OLD.reason, OLD.ticket_ref, OLD.mode, OLD.target_user_id,
      OLD.write_approver_staff_id, OLD.started_at, OLD.staff_display_name)
     OR NEW.expires_at > OLD.expires_at
     OR (OLD.ended_at IS NOT NULL AND (NEW.ended_at IS DISTINCT FROM OLD.ended_at OR NEW.end_reason IS DISTINCT FROM OLD.end_reason)) THEN
    PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'impersonation session can only be ended or shortened');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.impersonation_session;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON core.impersonation_session
  FOR EACH ROW EXECUTE FUNCTION core.impersonation_guard();

-- UnitOfWork در آغاز هر تراکنش تحت ورود به‌جای کاربر صدا می‌زند؛ حالت را برمی‌گرداند یا خطا می‌دهد.
CREATE OR REPLACE FUNCTION core.impersonation_check(p_session_id uuid) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE s core.impersonation_session;
BEGIN
  SELECT * INTO s FROM core.impersonation_session WHERE id = p_session_id;
  IF NOT FOUND OR s.ended_at IS NOT NULL OR s.expires_at <= now() THEN
    PERFORM core.raise_hk('HK_IMP_NOT_ACTIVE', 'impersonation session is not active');
  END IF;
  RETURN s.mode;
END $$;

-- ---------- ممیزی: زنجیرهٔ hash ----------
CREATE OR REPLACE FUNCTION core.audit_genesis_hash(p_tenant uuid, p_chain smallint) RETURNS bytea
LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT sha256(convert_to('hk-audit-genesis:' || p_tenant::text || ':' || p_chain::text, 'UTF8'))
$$;

-- رمزگذاری فیلد با پیشوند طول: NULL → "~;"؛ مقدار → "<طول نویسه‌ای>:<مقدار>;" (بدون ابهام)
CREATE OR REPLACE FUNCTION core.audit_field(v text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE WHEN v IS NULL THEN '~;' ELSE char_length(v)::text || ':' || v || ';' END
$$;

-- رشتهٔ متعارف ردیف (قالب hkaudit1). همتای پایتون در سند §۵.۷.
CREATE OR REPLACE FUNCTION core.audit_canonical(a core.audit_log) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
SELECT 'hkaudit1;'
  || core.audit_field(a.tenant_id::text) || core.audit_field(a.chain_no::text) || core.audit_field(a.seq::text)
  || core.audit_field(a.id::text)
  || core.audit_field(((extract(epoch FROM a.occurred_at) * 1000000)::bigint)::text)
  || core.audit_field(a.actor_kind) || core.audit_field(a.actor_user_id::text) || core.audit_field(a.act_staff_id::text)
  || core.audit_field(a.impersonation_session_id::text) || core.audit_field(a.session_id::text)
  || core.audit_field(a.api_key_id::text) || core.audit_field(a.device_id::text) || core.audit_field(a.request_id)
  || core.audit_field(host(a.ip)) || core.audit_field(a.user_agent) || core.audit_field(a.action)
  || core.audit_field(a.resource_type) || core.audit_field(a.resource_id::text) || core.audit_field(a.company_id::text)
  || core.audit_field(a.branch_id::text) || core.audit_field(a.outcome) || core.audit_field(a.reason)
  || core.audit_field(encode(a.details_sha256, 'hex'))
$$;

-- مهر کردن ردیف: قفل سر زنجیرهٔ مستأجر، seq بعدی، prev_hash و row_hash.
-- SECURITY DEFINER با مالک hk_audit_writer: hk_app هیچ امتیازی روی audit_chain_head جز SELECT ندارد.
CREATE OR REPLACE FUNCTION core.audit_seal() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_seq bigint; v_prev bytea;
BEGIN
  INSERT INTO core.audit_chain_head (tenant_id, chain_no, last_seq, last_hash)
  VALUES (NEW.tenant_id, NEW.chain_no, 0, core.audit_genesis_hash(NEW.tenant_id, NEW.chain_no))
  ON CONFLICT (tenant_id, chain_no) DO NOTHING;
  SELECT h.last_seq, h.last_hash INTO v_seq, v_prev
    FROM core.audit_chain_head h
   WHERE h.tenant_id = NEW.tenant_id AND h.chain_no = NEW.chain_no
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'HK_AUDIT_TENANT_CONTEXT: audit row tenant does not match app.tenant_id' USING ERRCODE = 'P0001';
  END IF;
  NEW.seq            := v_seq + 1;
  NEW.prev_hash      := v_prev;
  NEW.recorded_at    := clock_timestamp();
  NEW.details_sha256 := sha256(convert_to(NEW.details, 'UTF8'));
  NEW.row_hash       := sha256(v_prev || convert_to(core.audit_canonical(NEW), 'UTF8'));
  UPDATE core.audit_chain_head SET last_seq = NEW.seq, last_hash = NEW.row_hash, updated_at = now()
   WHERE tenant_id = NEW.tenant_id AND chain_no = NEW.chain_no;
  RETURN NEW;
END $$;
ALTER FUNCTION core.audit_seal() OWNER TO hk_audit_writer;
COMMENT ON FUNCTION core.audit_seal() IS
  'HK_DEFINER_REVIEWED: 2026-11-17 section 02; touches only core.audit_chain_head of the row tenant under normal tenant RLS';
DROP TRIGGER IF EXISTS trg_seal ON core.audit_log;
CREATE TRIGGER trg_seal BEFORE INSERT ON core.audit_log FOR EACH ROW EXECUTE FUNCTION core.audit_seal();

CREATE OR REPLACE FUNCTION core.audit_head_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.tenant_id <> OLD.tenant_id OR NEW.chain_no <> OLD.chain_no OR NEW.last_seq <> OLD.last_seq + 1 THEN
    PERFORM core.raise_hk('HK_AUDIT_HEAD', 'audit chain head may only advance by one');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.audit_chain_head;
CREATE TRIGGER trg_guard BEFORE UPDATE ON core.audit_chain_head FOR EACH ROW EXECUTE FUNCTION core.audit_head_guard();
DROP TRIGGER IF EXISTS trg_nodelete ON core.audit_chain_head;
CREATE TRIGGER trg_nodelete BEFORE DELETE ON core.audit_chain_head FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

-- راستی‌آزمایی زنجیره (با نقش برنامه و مستأجر تنظیم‌شده). خروجی خالی = سالم.
-- RV-CORE-09: هر checkpoint درون بازه (و checkpoint درست پیش از p_from_seq) با row_hash ردیف همان seq مقایسه می‌شود؛
-- پس بازنویسی زنجیره از پیش از checkpoint هم در راستی‌آزمایی افزایشی روزانه آشکار است ('checkpoint_mismatch').
CREATE OR REPLACE FUNCTION core.audit_verify(p_chain_no smallint DEFAULT 0, p_from_seq bigint DEFAULT 1, p_to_seq bigint DEFAULT NULL)
RETURNS TABLE (seq bigint, problem text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_tenant uuid := core.current_tenant_id();
  r core.audit_log;
  v_prev bytea;
  v_expected bigint := p_from_seq;
  h record;
BEGIN
  IF v_tenant IS NULL THEN PERFORM core.raise_hk('HK_TENANT_CONTEXT_MISSING', 'set app.tenant_id'); END IF;
  IF p_from_seq < 1 THEN PERFORM core.raise_hk('HK_AUDIT_ARGS', 'p_from_seq starts at 1'); END IF;
  IF p_from_seq = 1 THEN
    v_prev := core.audit_genesis_hash(v_tenant, p_chain_no);
  ELSE
    SELECT a.row_hash INTO v_prev FROM core.audit_log a
     WHERE a.tenant_id = v_tenant AND a.chain_no = p_chain_no AND a.seq = p_from_seq - 1;
    IF NOT FOUND THEN seq := p_from_seq - 1; problem := 'missing_predecessor'; RETURN NEXT; RETURN; END IF;
  END IF;
  -- checkpointهای ثبت‌شده از (p_from_seq - 1) تا انتهای بازه باید با row_hash همان seq بخوانند
  FOR h IN SELECT c.seq FROM core.audit_checkpoint c
             JOIN core.audit_log a ON a.tenant_id = c.tenant_id AND a.chain_no = c.chain_no AND a.seq = c.seq
            WHERE c.tenant_id = v_tenant AND c.chain_no = p_chain_no AND c.seq >= p_from_seq - 1
              AND (p_to_seq IS NULL OR c.seq <= p_to_seq) AND c.row_hash <> a.row_hash
            ORDER BY c.seq
  LOOP
    seq := h.seq; problem := 'checkpoint_mismatch'; RETURN NEXT;
  END LOOP;
  FOR r IN SELECT * FROM core.audit_log a
            WHERE a.tenant_id = v_tenant AND a.chain_no = p_chain_no AND a.seq >= p_from_seq
              AND (p_to_seq IS NULL OR a.seq <= p_to_seq)
            ORDER BY a.seq
  LOOP
    IF r.seq <> v_expected THEN seq := v_expected; problem := 'gap'; RETURN NEXT; END IF;
    IF r.prev_hash <> v_prev THEN seq := r.seq; problem := 'prev_hash_mismatch'; RETURN NEXT; END IF;
    IF r.details_sha256 <> sha256(convert_to(r.details, 'UTF8')) THEN seq := r.seq; problem := 'details_hash_mismatch'; RETURN NEXT; END IF;
    IF r.row_hash <> sha256(r.prev_hash || convert_to(core.audit_canonical(r), 'UTF8')) THEN
      seq := r.seq; problem := 'row_hash_mismatch'; RETURN NEXT;
    END IF;
    v_prev := r.row_hash;
    v_expected := r.seq + 1;
  END LOOP;
  IF p_to_seq IS NULL THEN
    SELECT * INTO h FROM core.audit_chain_head x WHERE x.tenant_id = v_tenant AND x.chain_no = p_chain_no;
    IF FOUND AND (h.last_seq <> v_expected - 1 OR h.last_hash <> v_prev) THEN
      seq := h.last_seq; problem := 'head_mismatch'; RETURN NEXT;
    END IF;
  END IF;
END $$;

-- checkpoint فقط از این تابع (definer با مالک hk_audit_writer؛ hk_app امتیاز INSERT ندارد): از seq پس از آخرین
-- checkpoint سالم (یا از ۱ با p_full؛ job هفتگی) تا سر زنجیره راستی‌آزمایی و نتیجه ثبت می‌شود. checkpoint ساختگی
-- با row_hash دلخواه ممکن نیست (audit_checkpoint_guard).
CREATE OR REPLACE FUNCTION core.audit_checkpoint_create(p_full boolean DEFAULT false)
RETURNS core.audit_checkpoint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_tenant uuid := core.current_tenant_id(); v_from bigint := 1; v_head bigint; v_hash bytea;
        v_problems jsonb; c core.audit_checkpoint;
BEGIN
  IF v_tenant IS NULL THEN PERFORM core.raise_hk('HK_TENANT_CONTEXT_MISSING', 'set app.tenant_id'); END IF;
  SELECT h.last_seq INTO v_head FROM core.audit_chain_head h WHERE h.tenant_id = v_tenant AND h.chain_no = 0;
  IF NOT FOUND OR v_head = 0 THEN RETURN NULL; END IF;
  IF NOT p_full THEN
    SELECT coalesce(max(x.seq) + 1, 1) INTO v_from FROM core.audit_checkpoint x
     WHERE x.tenant_id = v_tenant AND x.chain_no = 0 AND x.result = 'ok';
    IF v_from > v_head THEN v_from := v_head; END IF;
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('seq', v.seq, 'problem', v.problem) ORDER BY v.seq, v.problem), '[]'::jsonb)
    INTO v_problems FROM core.audit_verify(0::smallint, v_from, v_head) v;
  SELECT a.row_hash INTO v_hash FROM core.audit_log a WHERE a.tenant_id = v_tenant AND a.chain_no = 0 AND a.seq = v_head;
  INSERT INTO core.audit_checkpoint (tenant_id, chain_no, seq, row_hash, verified_from_seq, result, problems)
  VALUES (v_tenant, 0, v_head, v_hash, v_from, CASE WHEN jsonb_array_length(v_problems) = 0 THEN 'ok' ELSE 'broken' END, v_problems)
  RETURNING * INTO c;
  RETURN c;
END $$;

CREATE OR REPLACE FUNCTION core.audit_checkpoint_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM core.audit_log a
                  WHERE a.tenant_id = NEW.tenant_id AND a.chain_no = NEW.chain_no AND a.seq = NEW.seq AND a.row_hash = NEW.row_hash) THEN
    PERFORM core.raise_hk('HK_AUDIT_CHECKPOINT', 'checkpoint row_hash does not match the audit row');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.audit_checkpoint;
CREATE TRIGGER trg_guard BEFORE INSERT ON core.audit_checkpoint FOR EACH ROW EXECUTE FUNCTION core.audit_checkpoint_guard();

-- ---------- شماره‌گذاری ----------
CREATE OR REPLACE FUNCTION core.number_period_matches(p_reset text, p_period text) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE p_reset
    WHEN 'never'        THEN p_period = 'all'
    WHEN 'fiscal_year'  THEN p_period ~ '^fy:[0-9a-f-]{36}$'
    WHEN 'jalali_year'  THEN p_period ~ '^jy:[0-9]{4}$'
    WHEN 'jalali_month' THEN p_period ~ '^jm:[0-9]{4}-(0[1-9]|1[0-2])$'
    ELSE false END
$$;

-- قالب با همهٔ توکن‌ها به‌جز {seq} (که پایتون جای‌گذاری کرده) → رشتهٔ نهایی
CREATE OR REPLACE FUNCTION core.number_render(p_template text, p_value bigint) RETURNS text
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE m text[]; v_pad int; v_txt text := p_value::text;
BEGIN
  IF array_length(regexp_split_to_array(p_template, '\{seq(:[1-9][0-9]?)?\}'), 1) <> 2
     OR regexp_replace(p_template, '\{seq(:[1-9][0-9]?)?\}', '', 'g') ~ '[{}]' THEN
    PERFORM core.raise_hk('HK_NUM_BAD_TEMPLATE', 'template must contain exactly one {seq} token and no other tokens');
  END IF;
  m := regexp_match(p_template, '\{seq(?::([1-9][0-9]?))?\}');
  v_pad := COALESCE(m[1]::int, 0);
  IF char_length(v_txt) < v_pad THEN v_txt := lpad(v_txt, v_pad, '0'); END IF;
  RETURN regexp_replace(p_template, '\{seq(:[1-9][0-9]?)?\}', v_txt);
END $$;

CREATE OR REPLACE FUNCTION core.number_issued_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_next bigint; v_start bigint; v_alloc text;
BEGIN
  SELECT c.next_value, s.start_value, s.allocation INTO v_next, v_start, v_alloc
    FROM core.number_counter c JOIN core.number_series s ON s.tenant_id = c.tenant_id AND s.id = c.series_id
   WHERE c.tenant_id = NEW.tenant_id AND c.series_id = NEW.series_id AND c.period_key = NEW.period_key;
  IF NEW.value < v_start OR NEW.value >= v_next THEN
    PERFORM core.raise_hk('HK_NUM_OUT_OF_RANGE', format('value %s outside allocated range [%s,%s)', NEW.value, v_start, v_next));
  END IF;
  -- INV-NUM-06: سری سرور هرگز شمارهٔ ابطالی ندارد (دفاع لایهٔ دوم؛ hk_app اصلاً INSERT ندارد — RV-CORE-05)
  IF NEW.status = 'voided' AND v_alloc = 'server' THEN
    PERFORM core.raise_hk('HK_NUM_SERVER_ALLOCATED', 'server-allocated numbers are never voided');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.number_issued;
CREATE TRIGGER trg_guard BEFORE INSERT ON core.number_issued FOR EACH ROW EXECUTE FUNCTION core.number_issued_guard();

CREATE OR REPLACE FUNCTION core.number_counter_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE s core.number_series;
BEGIN
  SELECT * INTO s FROM core.number_series WHERE tenant_id = NEW.tenant_id AND id = NEW.series_id;
  IF TG_OP = 'INSERT' THEN
    IF NOT core.number_period_matches(s.reset_policy, NEW.period_key) THEN
      PERFORM core.raise_hk('HK_NUM_BAD_PERIOD', format('period %s does not match reset policy %s', NEW.period_key, s.reset_policy));
    END IF;
    IF NEW.next_value <> s.start_value THEN
      PERFORM core.raise_hk('HK_NUM_COUNTER', 'counter must start at series.start_value');
    END IF;
  ELSE
    IF NEW.series_id <> OLD.series_id OR NEW.period_key <> OLD.period_key OR NEW.next_value < OLD.next_value THEN
      PERFORM core.raise_hk('HK_NUM_COUNTER', 'counter can only move forward');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.number_counter;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON core.number_counter FOR EACH ROW EXECUTE FUNCTION core.number_counter_guard();
DROP TRIGGER IF EXISTS trg_nodelete ON core.number_counter;
CREATE TRIGGER trg_nodelete BEFORE DELETE ON core.number_counter FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

CREATE OR REPLACE FUNCTION core.number_series_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.company_id, NEW.doc_type, NEW.scope, NEW.branch_id, NEW.device_id, NEW.allocation, NEW.reset_policy, NEW.start_value)
     IS DISTINCT FROM
     (OLD.company_id, OLD.doc_type, OLD.scope, OLD.branch_id, OLD.device_id, OLD.allocation, OLD.reset_policy, OLD.start_value)
     AND EXISTS (SELECT 1 FROM core.number_counter WHERE tenant_id = OLD.tenant_id AND series_id = OLD.id) THEN
    PERFORM core.raise_hk('HK_NUM_SERIES_IN_USE', 'structural fields of a used series are immutable; create a new series');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.number_series;
CREATE TRIGGER trg_guard BEFORE UPDATE ON core.number_series FOR EACH ROW EXECUTE FUNCTION core.number_series_guard();

-- همهٔ نوشتن‌ها در شمارنده، رزرو و دفتر شماره فقط از این توابع می‌گذرند (RV-CORE-05): SECURITY DEFINER با مالک
-- بدون BYPASSRLS (hk_core_definer)، پس RLS مستأجر جاری همچنان برقرار است؛ hk_app روی این سه جدول فقط SELECT دارد.
-- گرفتن شمارهٔ بعدی در همان تراکنش ثبت سند (قفل ردیف شمارنده تا پایان تراکنش)
CREATE OR REPLACE FUNCTION core.number_next(p_series_id uuid, p_period_key text, p_template text,
                                            p_doc_type text, p_doc_id uuid)
RETURNS TABLE (number_id uuid, value bigint, formatted text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE s core.number_series; v bigint; f text; nid uuid;
BEGIN
  SELECT * INTO s FROM core.number_series x WHERE x.id = p_series_id;
  IF NOT FOUND THEN PERFORM core.raise_hk('HK_NUM_SERIES_NOT_FOUND', 'number series not found'); END IF;
  IF NOT s.is_active THEN PERFORM core.raise_hk('HK_NUM_SERIES_INACTIVE', 'number series is inactive'); END IF;
  IF s.allocation <> 'server' THEN PERFORM core.raise_hk('HK_NUM_NOT_SERVER_ALLOCATED', 'series is allocated by device/ranges'); END IF;
  IF s.doc_type <> p_doc_type THEN PERFORM core.raise_hk('HK_NUM_DOC_TYPE', 'doc_type does not match the series'); END IF;
  INSERT INTO core.number_counter (tenant_id, series_id, period_key, next_value)
  VALUES (s.tenant_id, s.id, p_period_key, s.start_value)
  ON CONFLICT (tenant_id, series_id, period_key) DO NOTHING;
  UPDATE core.number_counter c SET next_value = c.next_value + 1, updated_at = now()
   WHERE c.tenant_id = s.tenant_id AND c.series_id = s.id AND c.period_key = p_period_key
  RETURNING c.next_value - 1 INTO v;
  f := core.number_render(p_template, v);
  INSERT INTO core.number_issued (tenant_id, series_id, period_key, value, formatted, status, doc_type, doc_id, issued_by)
  VALUES (s.tenant_id, s.id, p_period_key, v, f, 'used', p_doc_type, p_doc_id, core.current_user_id())
  RETURNING id INTO nid;
  number_id := nid; value := v; formatted := f;
  RETURN NEXT;
END $$;

-- رزرو بازه برای دستگاه آفلاین (دستگاه فعال همین مستأجر)
CREATE OR REPLACE FUNCTION core.number_reserve_range(p_series_id uuid, p_period_key text, p_device_id uuid, p_size integer)
RETURNS core.number_reservation
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE s core.number_series; v_start bigint; r core.number_reservation;
BEGIN
  IF p_size IS NULL OR p_size < 1 OR p_size > 100000 THEN PERFORM core.raise_hk('HK_NUM_RANGE_SIZE', 'range size must be 1..100000'); END IF;
  SELECT * INTO s FROM core.number_series x WHERE x.id = p_series_id;
  IF NOT FOUND OR NOT s.is_active THEN PERFORM core.raise_hk('HK_NUM_SERIES_NOT_FOUND', 'active series not found'); END IF;
  IF s.allocation <> 'reserved_ranges' THEN PERFORM core.raise_hk('HK_NUM_NOT_RANGE_ALLOCATED', 'series does not use reserved ranges'); END IF;
  IF NOT EXISTS (SELECT 1 FROM core.device d WHERE d.tenant_id = s.tenant_id AND d.id = p_device_id AND d.status = 'active') THEN
    PERFORM core.raise_hk('HK_NUM_DEVICE', 'reservations go only to an active device of this tenant');
  END IF;
  INSERT INTO core.number_counter (tenant_id, series_id, period_key, next_value)
  VALUES (s.tenant_id, s.id, p_period_key, s.start_value)
  ON CONFLICT (tenant_id, series_id, period_key) DO NOTHING;
  UPDATE core.number_counter c SET next_value = c.next_value + p_size, updated_at = now()
   WHERE c.tenant_id = s.tenant_id AND c.series_id = s.id AND c.period_key = p_period_key
  RETURNING c.next_value - p_size INTO v_start;
  INSERT INTO core.number_reservation (tenant_id, series_id, period_key, device_id, range_start, range_end, reserved_by)
  VALUES (s.tenant_id, s.id, p_period_key, p_device_id, v_start, v_start + p_size - 1, core.current_user_id())
  RETURNING * INTO r;
  RETURN r;
END $$;

-- ثبت شمارهٔ صادرشده روی دستگاه (سری دستگاه یا بازهٔ رزرو). دستگاه اجباری است و با IS DISTINCT FROM سنجیده
-- می‌شود (RV-CORE-05)؛ مقدار سری دستگاه حداکثر core.numbering.device_window جلوتر از شمارنده است (RV-CORE-30).
CREATE OR REPLACE FUNCTION core.number_record_external(p_series_id uuid, p_period_key text, p_value bigint, p_formatted text,
                                                       p_doc_type text, p_doc_id uuid, p_device_id uuid,
                                                       p_reservation_id uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE s core.number_series; r core.number_reservation; nid uuid; v_next bigint; v_window bigint;
BEGIN
  IF p_device_id IS NULL THEN PERFORM core.raise_hk('HK_NUM_DEVICE', 'device-issued numbers need the issuing device'); END IF;
  SELECT * INTO s FROM core.number_series x WHERE x.id = p_series_id;
  IF NOT FOUND THEN PERFORM core.raise_hk('HK_NUM_SERIES_NOT_FOUND', 'number series not found'); END IF;
  IF s.doc_type <> p_doc_type THEN PERFORM core.raise_hk('HK_NUM_DOC_TYPE', 'doc_type does not match the series'); END IF;
  IF s.allocation = 'device' THEN
    IF s.device_id IS DISTINCT FROM p_device_id THEN PERFORM core.raise_hk('HK_NUM_DEVICE', 'series belongs to another device'); END IF;
    INSERT INTO core.number_counter (tenant_id, series_id, period_key, next_value)
    VALUES (s.tenant_id, s.id, p_period_key, s.start_value)
    ON CONFLICT (tenant_id, series_id, period_key) DO NOTHING;
    SELECT c.next_value INTO v_next FROM core.number_counter c
     WHERE c.tenant_id = s.tenant_id AND c.series_id = s.id AND c.period_key = p_period_key FOR UPDATE;
    v_window := coalesce((core.setting_effective('core.numbering.device_window', s.company_id, s.branch_id) #>> '{}')::bigint, 10000);
    IF p_value >= v_next + v_window THEN
      PERFORM core.raise_hk('HK_NUM_OUT_OF_WINDOW', format('device value %s is more than %s ahead of the counter (%s)', p_value, v_window, v_next));
    END IF;
    UPDATE core.number_counter c SET next_value = greatest(c.next_value, p_value + 1), updated_at = now()
     WHERE c.tenant_id = s.tenant_id AND c.series_id = s.id AND c.period_key = p_period_key;
  ELSIF s.allocation = 'reserved_ranges' THEN
    SELECT * INTO r FROM core.number_reservation x WHERE x.id = p_reservation_id FOR SHARE;
    IF NOT FOUND OR r.series_id <> s.id OR r.period_key <> p_period_key OR r.device_id IS DISTINCT FROM p_device_id
       OR r.status <> 'active' OR p_value NOT BETWEEN r.range_start AND r.range_end THEN
      PERFORM core.raise_hk('HK_NUM_NOT_IN_RESERVATION', 'value is not inside an active reservation of this device');
    END IF;
  ELSE
    PERFORM core.raise_hk('HK_NUM_SERVER_ALLOCATED', 'server-allocated series cannot accept external numbers');
  END IF;
  INSERT INTO core.number_issued (tenant_id, series_id, period_key, value, formatted, status, doc_type, doc_id,
                                  reservation_id, device_id, issued_by)
  VALUES (s.tenant_id, s.id, p_period_key, p_value, p_formatted, 'used', p_doc_type, p_doc_id,
          p_reservation_id, p_device_id, core.current_user_id())
  RETURNING id INTO nid;
  RETURN nid;
END $$;

-- ابطال بازهٔ مصرف‌نشده (فقط سری دستگاه/بازه؛ سری سرور هرگز شمارهٔ بی‌سند ندارد). عدد درون رزرو فعال
-- ابطال نمی‌شود (RV-CORE-05: دستگاه صاحب رزرو هنوز ممکن است آن را همگام کند) و عدد ثبت‌شده رد می‌شود.
CREATE OR REPLACE FUNCTION core.number_void_range(p_series_id uuid, p_period_key text, p_from bigint, p_to bigint, p_reason text)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE s core.number_series; n integer;
BEGIN
  SELECT * INTO s FROM core.number_series x WHERE x.id = p_series_id;
  IF NOT FOUND THEN PERFORM core.raise_hk('HK_NUM_SERIES_NOT_FOUND', 'number series not found'); END IF;
  IF s.allocation = 'server' THEN PERFORM core.raise_hk('HK_NUM_SERVER_ALLOCATED', 'server-allocated numbers are never voided'); END IF;
  IF p_reason IS NULL OR char_length(btrim(p_reason)) < 5 THEN PERFORM core.raise_hk('HK_NUM_VOID_REASON', 'reason required'); END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to - p_from >= 100000 THEN
    PERFORM core.raise_hk('HK_NUM_RANGE_SIZE', 'void range must be 1..100000 values');
  END IF;
  IF EXISTS (SELECT 1 FROM core.number_reservation r
              WHERE r.tenant_id = s.tenant_id AND r.series_id = s.id AND r.period_key = p_period_key
                AND r.status = 'active' AND int8range(r.range_start, r.range_end, '[]') && int8range(p_from, p_to, '[]')) THEN
    PERFORM core.raise_hk('HK_NUM_RESERVED', 'values inside an active reservation are voided only by closing the reservation');
  END IF;
  IF EXISTS (SELECT 1 FROM core.number_issued i
              WHERE i.tenant_id = s.tenant_id AND i.series_id = s.id AND i.period_key = p_period_key
                AND i.value BETWEEN p_from AND p_to) THEN
    PERFORM core.raise_hk('HK_NUM_ALREADY_ISSUED', 'range contains values that are already used or voided');
  END IF;
  INSERT INTO core.number_issued (tenant_id, series_id, period_key, value, formatted, status, void_reason, issued_by)
  SELECT s.tenant_id, s.id, p_period_key, g, '#void:' || g::text, 'voided', p_reason, core.current_user_id()
    FROM generate_series(p_from, p_to) g;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- ابطال یک شماره (پوستهٔ number_void_range برای سازگاری قرارداد 07:CR-CMP-06)
CREATE OR REPLACE FUNCTION core.number_void(p_series_id uuid, p_period_key text, p_value bigint, p_reason text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE nid uuid;
BEGIN
  PERFORM core.number_void_range(p_series_id, p_period_key, p_value, p_value, p_reason);
  SELECT i.id INTO nid FROM core.number_issued i
   WHERE i.series_id = p_series_id AND i.period_key = p_period_key AND i.value = p_value;
  RETURN nid;
END $$;

-- بستن رزرو: همهٔ شماره‌های مصرف‌نشدهٔ بازه ابطال می‌شوند تا هیچ عددی بی‌حساب نماند
CREATE OR REPLACE FUNCTION core.number_close_reservation(p_reservation_id uuid, p_reason text)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE r core.number_reservation; n integer;
BEGIN
  SELECT * INTO r FROM core.number_reservation x WHERE x.id = p_reservation_id FOR UPDATE;
  IF NOT FOUND OR r.status <> 'active' THEN PERFORM core.raise_hk('HK_NUM_RESERVATION', 'active reservation not found'); END IF;
  IF p_reason IS NULL OR char_length(btrim(p_reason)) < 5 THEN PERFORM core.raise_hk('HK_NUM_VOID_REASON', 'reason required'); END IF;
  INSERT INTO core.number_issued (tenant_id, series_id, period_key, value, formatted, status, void_reason,
                                  reservation_id, device_id, issued_by)
  SELECT r.tenant_id, r.series_id, r.period_key, g, '#void:' || g::text, 'voided', p_reason, r.id, r.device_id, core.current_user_id()
    FROM generate_series(r.range_start, r.range_end) g
   WHERE NOT EXISTS (SELECT 1 FROM core.number_issued i
                      WHERE i.tenant_id = r.tenant_id AND i.series_id = r.series_id
                        AND i.period_key = r.period_key AND i.value = g);
  GET DIAGNOSTICS n = ROW_COUNT;
  UPDATE core.number_reservation SET status = 'closed', closed_at = now(), close_reason = p_reason WHERE id = r.id;
  RETURN n;
END $$;

-- رزرو: فقط active → closed (با number_close_reservation)؛ بازه، دستگاه و سری تغییرناپذیر
CREATE OR REPLACE FUNCTION core.number_reservation_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.tenant_id, NEW.series_id, NEW.period_key, NEW.device_id, NEW.range_start, NEW.range_end, NEW.reserved_at)
     IS DISTINCT FROM (OLD.tenant_id, OLD.series_id, OLD.period_key, OLD.device_id, OLD.range_start, OLD.range_end, OLD.reserved_at)
     OR OLD.status = 'closed' THEN
    PERFORM core.raise_hk('HK_NUM_RESERVATION', 'reservation range is immutable and closing is final');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.number_reservation;
CREATE TRIGGER trg_guard BEFORE UPDATE ON core.number_reservation FOR EACH ROW EXECUTE FUNCTION core.number_reservation_guard();
DROP TRIGGER IF EXISTS trg_nodelete ON core.number_reservation;
CREATE TRIGGER trg_nodelete BEFORE DELETE ON core.number_reservation FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

-- بازه‌های بی‌حساب (gaps-and-islands) در بازهٔ تخصیص‌یافته؛ O(n log n) روی شماره‌های ثبت‌شده، بدون باز کردن
-- عدد به عدد (RV-CORE-30). برای سری سرور همیشه خالی است.
CREATE OR REPLACE FUNCTION core.number_gap_ranges(p_series_id uuid, p_period_key text)
RETURNS TABLE (gap_start bigint, gap_end bigint)
LANGUAGE sql STABLE AS $$
  WITH c AS (
    SELECT cn.tenant_id, cn.series_id, cn.period_key, s.start_value, cn.next_value
      FROM core.number_counter cn JOIN core.number_series s ON s.tenant_id = cn.tenant_id AND s.id = cn.series_id
     WHERE cn.series_id = p_series_id AND cn.period_key = p_period_key),
  cov AS (
    SELECT i.value AS lo, i.value AS hi
      FROM core.number_issued i JOIN c ON i.tenant_id = c.tenant_id AND i.series_id = c.series_id AND i.period_key = c.period_key
    UNION ALL
    SELECT r.range_start, r.range_end
      FROM core.number_reservation r JOIN c ON r.tenant_id = c.tenant_id AND r.series_id = c.series_id AND r.period_key = c.period_key
     WHERE r.status = 'active'
    UNION ALL SELECT c.start_value - 1, c.start_value - 1 FROM c
    UNION ALL SELECT c.next_value, c.next_value FROM c),
  w AS (SELECT lo, max(hi) OVER (ORDER BY lo, hi ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_hi FROM cov)
  SELECT w.prev_hi + 1, w.lo - 1 FROM w WHERE w.lo > w.prev_hi + 1 ORDER BY 1
$$;

-- اعداد بی‌حساب، یکی‌یکی (سازگاری؛ برای کسری بزرگ number_gap_ranges)
CREATE OR REPLACE FUNCTION core.number_gaps(p_series_id uuid, p_period_key text)
RETURNS SETOF bigint
LANGUAGE sql STABLE AS $$
  SELECT g FROM core.number_gap_ranges(p_series_id, p_period_key) r CROSS JOIN LATERAL generate_series(r.gap_start, r.gap_end) g
   ORDER BY g
$$;

-- ---------- تنظیمات: اعتبارسنجی نوع + تاریخچه ----------
CREATE OR REPLACE FUNCTION core.setting_value_valid(d core.setting_def, v jsonb) RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
DECLARE n numeric;
BEGIN
  CASE d.value_type
    WHEN 'bool' THEN RETURN jsonb_typeof(v) = 'boolean';
    WHEN 'int', 'duration_s' THEN
      IF jsonb_typeof(v) <> 'number' OR v::text !~ '^-?[0-9]+$' THEN RETURN false; END IF;
      n := v::text::numeric;
      IF d.value_type = 'duration_s' AND n < 0 THEN RETURN false; END IF;
    WHEN 'decimal' THEN
      IF jsonb_typeof(v) <> 'string' OR (v #>> '{}') !~ '^-?[0-9]{1,20}(\.[0-9]{1,12})?$' THEN RETURN false; END IF;
      n := (v #>> '{}')::numeric;
    WHEN 'text' THEN
      RETURN jsonb_typeof(v) = 'string' AND char_length(v #>> '{}') <= coalesce(d.max_length, 1000);
    WHEN 'enum' THEN
      RETURN jsonb_typeof(v) = 'string' AND (v #>> '{}') = ANY (d.enum_values);
    WHEN 'date' THEN
      RETURN jsonb_typeof(v) = 'string' AND (v #>> '{}') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
             AND pg_input_is_valid(v #>> '{}', 'date');
    WHEN 'secret_ref' THEN
      RETURN jsonb_typeof(v) = 'string' AND (v #>> '{}') ~ '^secret://[a-z0-9/_.-]{1,200}$';
    WHEN 'json' THEN RETURN true;   -- طرح JSON در سرویس پایتون اعتبارسنجی می‌شود
  END CASE;
  RETURN (d.min_value IS NULL OR n >= d.min_value) AND (d.max_value IS NULL OR n <= d.max_value);
END $$;

CREATE OR REPLACE FUNCTION core.setting_value_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE d core.setting_def;
BEGIN
  SELECT * INTO d FROM core.setting_def WHERE key = NEW.setting_key;
  IF d.deprecated_at IS NOT NULL THEN PERFORM core.raise_hk('HK_SETTING_DEPRECATED', NEW.setting_key); END IF;
  IF NOT (NEW.level = ANY (d.allowed_levels)) THEN
    PERFORM core.raise_hk('HK_SETTING_LEVEL', format('%s cannot be set at level %s', NEW.setting_key, NEW.level));
  END IF;
  IF NOT core.setting_value_valid(d, NEW.value) THEN
    PERFORM core.raise_hk('HK_SETTING_TYPE', format('invalid value for %s (%s)', NEW.setting_key, d.value_type));
  END IF;
  IF TG_OP = 'UPDATE' AND (NEW.setting_key, NEW.level, NEW.company_id, NEW.branch_id, NEW.user_id)
                          IS DISTINCT FROM (OLD.setting_key, OLD.level, OLD.company_id, OLD.branch_id, OLD.user_id) THEN
    PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'setting scope is immutable');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.setting_value;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON core.setting_value FOR EACH ROW EXECUTE FUNCTION core.setting_value_guard();

CREATE OR REPLACE FUNCTION core.setting_value_history() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    INSERT INTO core.setting_history (tenant_id, setting_id, setting_key, level, company_id, branch_id, user_id,
                                      op, old_value, new_value, version, changed_by)
    VALUES (OLD.tenant_id, OLD.id, OLD.setting_key, OLD.level, OLD.company_id, OLD.branch_id, OLD.user_id,
            'delete', OLD.value, NULL, OLD.row_version + 1, core.current_user_id());
    RETURN OLD;
  END IF;
  INSERT INTO core.setting_history (tenant_id, setting_id, setting_key, level, company_id, branch_id, user_id,
                                    op, old_value, new_value, version, changed_by)
  VALUES (NEW.tenant_id, NEW.id, NEW.setting_key, NEW.level, NEW.company_id, NEW.branch_id, NEW.user_id,
          lower(TG_OP), CASE WHEN TG_OP = 'UPDATE' THEN OLD.value END, NEW.value, NEW.row_version, core.current_user_id());
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_history ON core.setting_value;
CREATE TRIGGER trg_history AFTER INSERT OR UPDATE OR DELETE ON core.setting_value
  FOR EACH ROW EXECUTE FUNCTION core.setting_value_history();

-- مقدار مؤثر: user > branch > company > tenant > پیش‌فرض تعریف
CREATE OR REPLACE FUNCTION core.setting_effective(p_key text, p_company_id uuid DEFAULT NULL, p_branch_id uuid DEFAULT NULL,
                                                  p_user_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    (SELECT v.value FROM core.setting_value v
      WHERE v.setting_key = p_key
        AND (   (v.level = 'user'    AND v.user_id = p_user_id)
             OR (v.level = 'branch'  AND v.branch_id = p_branch_id)
             OR (v.level = 'company' AND v.company_id = p_company_id)
             OR  v.level = 'tenant')
      ORDER BY CASE v.level WHEN 'user' THEN 1 WHEN 'branch' THEN 2 WHEN 'company' THEN 3 ELSE 4 END
      LIMIT 1),
    (SELECT d.default_value FROM core.setting_def d WHERE d.key = p_key))
$$;

-- ---------- فیلد سفارشی ----------
CREATE OR REPLACE FUNCTION core.custom_field_def_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.entity_type, NEW.code, NEW.data_type, NEW.ref_entity) IS DISTINCT FROM (OLD.entity_type, OLD.code, OLD.data_type, OLD.ref_entity) THEN
    PERFORM core.raise_hk('HK_CF_IMMUTABLE', 'entity_type, code, data_type and ref_entity are immutable');
  END IF;
  IF OLD.options IS NOT NULL AND EXISTS (
       SELECT 1 FROM jsonb_array_elements(OLD.options) o
        WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(NEW.options) n WHERE n->>'code' = o->>'code')) THEN
    PERFORM core.raise_hk('HK_CF_OPTION_REMOVED', 'enum options cannot be removed, only deactivated');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.custom_field_def;
CREATE TRIGGER trg_guard BEFORE UPDATE ON core.custom_field_def FOR EACH ROW EXECUTE FUNCTION core.custom_field_def_guard();

CREATE OR REPLACE FUNCTION core.custom_field_value_valid(d core.custom_field_def, v jsonb) RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
DECLARE n numeric; e jsonb;
BEGIN
  CASE d.data_type
    WHEN 'text', 'long_text' THEN
      RETURN jsonb_typeof(v) = 'string'
             AND char_length(v #>> '{}') <= coalesce(d.max_length, CASE d.data_type WHEN 'text' THEN 200 ELSE 4000 END);
    WHEN 'int' THEN
      IF jsonb_typeof(v) <> 'number' OR v::text !~ '^-?[0-9]{1,18}$' THEN RETURN false; END IF;
      n := v::text::numeric;
    WHEN 'decimal' THEN
      IF jsonb_typeof(v) <> 'string' OR (v #>> '{}') !~ '^-?[0-9]{1,18}(\.[0-9]{1,6})?$' THEN RETURN false; END IF;
      n := (v #>> '{}')::numeric;
    WHEN 'bool' THEN RETURN jsonb_typeof(v) = 'boolean';
    WHEN 'date' THEN
      RETURN jsonb_typeof(v) = 'string' AND (v #>> '{}') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' AND pg_input_is_valid(v #>> '{}', 'date');
    WHEN 'enum' THEN
      RETURN jsonb_typeof(v) = 'string'
             AND EXISTS (SELECT 1 FROM jsonb_array_elements(d.options) o WHERE o->>'code' = v #>> '{}');
    WHEN 'multi_enum' THEN
      IF jsonb_typeof(v) <> 'array' THEN RETURN false; END IF;
      FOR e IN SELECT * FROM jsonb_array_elements(v) LOOP
        IF jsonb_typeof(e) <> 'string' OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(d.options) o WHERE o->>'code' = e #>> '{}') THEN
          RETURN false;
        END IF;
      END LOOP;
      RETURN (SELECT count(*) = count(DISTINCT x) FROM jsonb_array_elements_text(v) x);
    WHEN 'ref' THEN
      RETURN jsonb_typeof(v) = 'string' AND pg_input_is_valid(v #>> '{}', 'uuid');
  END CASE;
  RETURN (d.min_value IS NULL OR n >= d.min_value) AND (d.max_value IS NULL OR n <= d.max_value);
END $$;

-- تریگر عمومی BEFORE INSERT/UPDATE روی جدول مالک. TG_ARGV[0]=entity_type، TG_ARGV[1]=ستون JSONB.
CREATE OR REPLACE FUNCTION core.custom_fields_check() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_entity text := TG_ARGV[0];
  v_col    text := coalesce(TG_ARGV[1], 'custom');
  v_row    jsonb := to_jsonb(NEW);
  v_tenant uuid := (v_row ->> 'tenant_id')::uuid;
  v_doc    jsonb := v_row -> v_col;
  k text; v jsonb; d core.custom_field_def;
BEGIN
  IF v_doc IS NULL OR jsonb_typeof(v_doc) <> 'object' THEN
    PERFORM core.raise_hk('HK_CF_NOT_OBJECT', format('%s.%s must be a JSON object', TG_TABLE_NAME, v_col));
  END IF;
  IF TG_OP = 'UPDATE' AND v_doc = (to_jsonb(OLD) -> v_col) THEN RETURN NEW; END IF;
  FOR k, v IN SELECT * FROM jsonb_each(v_doc) LOOP
    SELECT * INTO d FROM core.custom_field_def x WHERE x.tenant_id = v_tenant AND x.entity_type = v_entity AND x.code = k;
    IF NOT FOUND THEN PERFORM core.raise_hk('HK_CF_UNKNOWN_FIELD', k); END IF;
    IF jsonb_typeof(v) = 'null' THEN
      v_doc := v_doc - k;          -- null = نبودِ مقدار
      CONTINUE;
    END IF;
    IF NOT core.custom_field_value_valid(d, v) THEN
      PERFORM core.raise_hk('HK_CF_INVALID_VALUE', format('%s (%s)', k, d.data_type));
    END IF;
  END LOOP;
  -- فیلد اجباری غایب ← مقدار پیش‌فرض
  FOR d IN SELECT * FROM core.custom_field_def x
            WHERE x.tenant_id = v_tenant AND x.entity_type = v_entity AND x.is_required AND x.status = 'active'
  LOOP
    IF NOT (v_doc ? d.code) THEN v_doc := v_doc || jsonb_build_object(d.code, d.default_value); END IF;
  END LOOP;
  NEW := jsonb_populate_record(NEW, jsonb_build_object(v_col, v_doc));
  RETURN NEW;
END $$;

-- تریگر عمومی AFTER: نگه‌داشت جدول نمایهٔ فیلدهای is_indexed
CREATE OR REPLACE FUNCTION core.custom_fields_index_sync() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_entity text := TG_ARGV[0];
  v_col    text := coalesce(TG_ARGV[1], 'custom');
  v_new    jsonb; v_old jsonb; v_tenant uuid; v_id uuid; d core.custom_field_def; v jsonb;
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN
    v_old := to_jsonb(OLD);
    IF TG_OP = 'UPDATE' AND (v_old -> v_col) = (to_jsonb(NEW) -> v_col) THEN RETURN NULL; END IF;
    DELETE FROM core.custom_field_index
     WHERE tenant_id = (v_old ->> 'tenant_id')::uuid AND entity_type = v_entity AND entity_id = (v_old ->> 'id')::uuid;
  END IF;
  IF TG_OP IN ('INSERT','UPDATE') THEN
    v_new := to_jsonb(NEW);
    v_tenant := (v_new ->> 'tenant_id')::uuid;
    v_id := (v_new ->> 'id')::uuid;
    FOR d IN SELECT * FROM core.custom_field_def x
              WHERE x.tenant_id = v_tenant AND x.entity_type = v_entity AND x.is_indexed
    LOOP
      v := v_new -> v_col -> d.code;
      CONTINUE WHEN v IS NULL OR jsonb_typeof(v) = 'null';
      IF d.data_type = 'multi_enum' THEN
        INSERT INTO core.custom_field_index (tenant_id, entity_type, field_id, entity_id, value_text)
        SELECT v_tenant, v_entity, d.id, v_id, x FROM jsonb_array_elements_text(v) x;
      ELSE
        INSERT INTO core.custom_field_index (tenant_id, entity_type, field_id, entity_id, value_text, value_num, value_date, value_bool)
        VALUES (v_tenant, v_entity, d.id, v_id,
                CASE WHEN d.data_type IN ('text','enum','ref') THEN core.fa_search_key(v #>> '{}') END,
                CASE WHEN d.data_type IN ('int','decimal') THEN (v #>> '{}')::numeric END,
                CASE WHEN d.data_type = 'date' THEN (v #>> '{}')::date END,
                CASE WHEN d.data_type = 'bool' THEN (v #>> '{}')::boolean END);
      END IF;
    END LOOP;
  END IF;
  RETURN NULL;
END $$;

-- کمکی برای migration ماژول‌ها: اتصال فیلد سفارشی به جدول مالک
CREATE OR REPLACE FUNCTION core.attach_custom_fields(p_table regclass, p_entity_type text, p_column text DEFAULT 'custom')
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('DROP TRIGGER IF EXISTS trg_custom_fields_check ON %s', p_table);
  EXECUTE format('CREATE TRIGGER trg_custom_fields_check BEFORE INSERT OR UPDATE ON %s FOR EACH ROW '
                 'EXECUTE FUNCTION core.custom_fields_check(%L, %L)', p_table, p_entity_type, p_column);
  EXECUTE format('DROP TRIGGER IF EXISTS trg_custom_fields_index ON %s', p_table);
  EXECUTE format('CREATE TRIGGER trg_custom_fields_index AFTER INSERT OR UPDATE OR DELETE ON %s FOR EACH ROW '
                 'EXECUTE FUNCTION core.custom_fields_index_sync(%L, %L)', p_table, p_entity_type, p_column);
  EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %s USING gin (%I jsonb_path_ops)',
                 replace(p_table::text, '.', '_') || '_' || p_column || '_gin', p_table, p_column);
END $$;

-- ---------- پیوست ----------
CREATE OR REPLACE FUNCTION core.attachment_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'pending_upload' THEN PERFORM core.raise_hk('HK_ATT_STATE', 'attachment must start pending_upload'); END IF;
    RETURN NEW;
  END IF;
  IF (NEW.object_key, NEW.bucket, NEW.storage_backend, NEW.created_at) IS DISTINCT FROM
     (OLD.object_key, OLD.bucket, OLD.storage_backend, OLD.created_at)
     OR (OLD.sha256 IS NOT NULL AND NEW.sha256 IS DISTINCT FROM OLD.sha256)
     OR (OLD.size_bytes IS NOT NULL AND NEW.size_bytes IS DISTINCT FROM OLD.size_bytes) THEN
    PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'attachment object identity/content is immutable');
  END IF;
  IF NEW.status <> OLD.status AND NOT ((OLD.status, NEW.status) IN (
       ('pending_upload','uploaded'),('uploaded','scanning'),('scanning','clean'),('scanning','infected'),
       ('scanning','scan_failed'),('scan_failed','scanning'),('pending_upload','deleted'),('uploaded','deleted'),
       ('clean','deleted'),('infected','deleted'),('scan_failed','deleted'))) THEN
    PERFORM core.raise_hk('HK_CORE_INVALID_TRANSITION', format('attachment %s -> %s', OLD.status, NEW.status));
  END IF;
  IF NEW.status = 'deleted' AND OLD.status <> 'deleted' AND EXISTS (
       SELECT 1 FROM core.attachment_link l WHERE l.tenant_id = OLD.tenant_id AND l.attachment_id = OLD.id AND l.is_locked) THEN
    PERFORM core.raise_hk('HK_ATT_LOCKED', 'attachment is linked to a posted document');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.attachment;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON core.attachment FOR EACH ROW EXECUTE FUNCTION core.attachment_guard();

CREATE OR REPLACE FUNCTION core.attachment_link_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_status text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.is_locked THEN PERFORM core.raise_hk('HK_ATT_LOCKED', 'locked attachment link cannot be removed'); END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF (NEW.attachment_id, NEW.owner_type, NEW.owner_id, NEW.role, NEW.owner_module) IS DISTINCT FROM
       (OLD.attachment_id, OLD.owner_type, OLD.owner_id, OLD.role, OLD.owner_module)
       OR (OLD.is_locked AND NOT NEW.is_locked) THEN
      PERFORM core.raise_hk('HK_ATT_LOCKED', 'link identity is immutable and locking is one-way');
    END IF;
    RETURN NEW;
  END IF;
  SELECT status INTO v_status FROM core.attachment WHERE tenant_id = NEW.tenant_id AND id = NEW.attachment_id;
  IF v_status IN ('infected','deleted') THEN
    PERFORM core.raise_hk('HK_ATT_STATE', format('cannot link an attachment in state %s', v_status));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.attachment_link;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON core.attachment_link FOR EACH ROW EXECUTE FUNCTION core.attachment_link_guard();

-- ---------- صف job ----------
CREATE OR REPLACE FUNCTION core.job_backoff_seconds(p_attempt integer, p_base integer, p_cap integer) RETURNS integer
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT least(p_cap::numeric, p_base::numeric * power(2::numeric, greatest(p_attempt - 1, 0)))::integer
$$;

CREATE OR REPLACE FUNCTION core.job_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'queued' OR NEW.attempts <> 0 OR NEW.lock_token IS NOT NULL THEN
      PERFORM core.raise_hk('HK_JOB_STATE', 'new job must be queued with attempts = 0');
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.tenant_id, NEW.id, NEW.kind, NEW.queue, NEW.payload, NEW.dedupe_key, NEW.concurrency_key, NEW.created_at)
     IS DISTINCT FROM
     (OLD.tenant_id, OLD.id, OLD.kind, OLD.queue, OLD.payload, OLD.dedupe_key, OLD.concurrency_key, OLD.created_at) THEN
    PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'job identity and payload are immutable');
  END IF;
  IF NEW.status = OLD.status THEN
    -- فقط تمدید lease (heartbeat) با همان توکن
    IF OLD.status = 'running' AND (NEW.lock_token IS DISTINCT FROM OLD.lock_token OR NEW.attempts <> OLD.attempts) THEN
      PERFORM core.raise_hk('HK_JOB_STATE', 'running job lock cannot be reassigned');
    END IF;
    RETURN NEW;
  END IF;
  IF NOT ((OLD.status, NEW.status) IN (('queued','running'),('queued','cancelled'),('running','succeeded'),
           ('running','queued'),('running','failed'),('running','dead'),
           ('dead','queued'),('failed','queued'),('dead','cancelled'),('failed','cancelled'))) THEN
    PERFORM core.raise_hk('HK_CORE_INVALID_TRANSITION', format('job %s -> %s', OLD.status, NEW.status));
  END IF;
  IF OLD.status = 'running' THEN
    -- fencing: خروج از running فقط با توکن قفل جاری، یا پس از انقضای lease (reaper)
    IF coalesce(current_setting('app.job_lock_token', true), '') <> OLD.lock_token::text AND OLD.lease_expires_at >= now() THEN
      PERFORM core.raise_hk('HK_JOB_LEASE_LOST', 'job lock token mismatch');
    END IF;
  END IF;
  IF NEW.status = 'running' AND NEW.attempts <> OLD.attempts + 1 THEN
    PERFORM core.raise_hk('HK_JOB_STATE', 'claim must increment attempts by one');
  END IF;
  IF OLD.status IN ('dead','failed') AND NEW.status = 'queued' AND NEW.attempts <> 0 THEN
    PERFORM core.raise_hk('HK_JOB_STATE', 'manual requeue resets attempts to 0');
  END IF;
  IF OLD.status = 'running' AND NEW.status = 'queued' AND NEW.attempts >= NEW.max_attempts THEN
    PERFORM core.raise_hk('HK_JOB_STATE', 'attempts exhausted: job must go dead');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.job;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON core.job FOR EACH ROW EXECUTE FUNCTION core.job_guard();

-- صف مرده هرگز بی‌صدا نیست (RV-CORE-14): هر گذار به dead (در handler با hk_app یا در reaper با hk_dispatcher)
-- در همان تراکنش یک job «اعلان صف مرده» می‌سازد؛ handler آن در UoW مستأجر رویداد core.job.dead_lettered، اعلان
-- core.job_dead و هشدار عملیاتی را می‌سازد. خود این نوع job دوباره اعلان نمی‌سازد (بی‌حلقه).
CREATE OR REPLACE FUNCTION core.job_dead_letter_notice() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status = 'dead' AND OLD.status <> 'dead' AND NEW.kind <> 'core.job.dead_letter_notify' THEN
    INSERT INTO core.job (tenant_id, queue, kind, payload, dedupe_key, max_attempts)
    VALUES (NEW.tenant_id, 'maintenance', 'core.job.dead_letter_notify',
            jsonb_build_object('job_id', NEW.id, 'kind', NEW.kind, 'attempts', NEW.attempts,
                               'error_code', NEW.last_error ->> 'code'),
            'dead:' || NEW.id::text, 10)
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_dead_letter ON core.job;
CREATE TRIGGER trg_dead_letter AFTER UPDATE OF status ON core.job FOR EACH ROW EXECUTE FUNCTION core.job_dead_letter_notice();

-- برداشتن job (روی اتصال hk_dispatcher): نوبت‌گردشی بین (مستأجر، صف) با last_claimed_at، سقف هم‌روندی
-- هر مستأجر (job_tenant_state یا پیش‌فرض صف)، حذف نامزد دارای concurrency_key در حال اجرا،
-- و قفل ردیف وضعیت با SKIP LOCKED تا سقف دقیق بماند.
CREATE OR REPLACE FUNCTION core.job_claim(p_queues text[], p_worker text, p_max integer,
                                          p_lease_seconds integer DEFAULT 60, p_per_tenant integer DEFAULT 1)
RETURNS SETOF core.job
LANGUAGE plpgsql AS $$
DECLARE t record; j core.job; n integer := 0; v_running integer; v_taken integer;
BEGIN
  IF p_max < 1 OR p_per_tenant < 1 OR p_lease_seconds NOT BETWEEN 10 AND 3600 THEN
    PERFORM core.raise_hk('HK_JOB_ARGS', 'invalid claim arguments');
  END IF;
  FOR t IN
    SELECT q.tenant_id, q.queue, coalesce(s.max_running, jq.per_tenant_cap) AS cap
      FROM (SELECT DISTINCT x.tenant_id, x.queue FROM core.job x
             WHERE x.queue = ANY (p_queues) AND x.status = 'queued' AND x.run_after <= now()) q
      JOIN core.job_queue jq ON jq.queue = q.queue
      LEFT JOIN core.job_tenant_state s ON s.tenant_id = q.tenant_id AND s.queue = q.queue
     ORDER BY s.last_claimed_at NULLS FIRST, q.tenant_id, q.queue
  LOOP
    EXIT WHEN n >= p_max;
    INSERT INTO core.job_tenant_state (tenant_id, queue) VALUES (t.tenant_id, t.queue)
    ON CONFLICT (tenant_id, queue) DO NOTHING;
    PERFORM 1 FROM core.job_tenant_state WHERE tenant_id = t.tenant_id AND queue = t.queue FOR UPDATE SKIP LOCKED;
    CONTINUE WHEN NOT FOUND;
    SELECT count(*) INTO v_running FROM core.job WHERE tenant_id = t.tenant_id AND queue = t.queue AND status = 'running';
    v_taken := 0;
    WHILE n < p_max AND v_taken < p_per_tenant AND v_running + v_taken < t.cap LOOP
      UPDATE core.job SET status = 'running', lock_token = gen_random_uuid(), lease_owner = p_worker,
                          lease_expires_at = now() + make_interval(secs => p_lease_seconds),
                          attempts = attempts + 1, started_at = now()
       WHERE id = (SELECT j2.id FROM core.job j2
                    WHERE j2.tenant_id = t.tenant_id AND j2.queue = t.queue AND j2.status = 'queued' AND j2.run_after <= now()
                      AND (j2.concurrency_key IS NULL OR NOT EXISTS (
                             SELECT 1 FROM core.job r WHERE r.tenant_id = j2.tenant_id
                                AND r.concurrency_key = j2.concurrency_key AND r.status = 'running'))
                    ORDER BY j2.priority, j2.run_after, j2.id
                    LIMIT 1 FOR UPDATE SKIP LOCKED)
      RETURNING * INTO j;
      EXIT WHEN NOT FOUND;
      n := n + 1; v_taken := v_taken + 1;
      RETURN NEXT j;
    END LOOP;
    IF v_taken > 0 THEN
      UPDATE core.job_tenant_state SET last_claimed_at = clock_timestamp() WHERE tenant_id = t.tenant_id AND queue = t.queue;
    END IF;
  END LOOP;
END $$;

-- بازگرداندن jobها و تحویل‌هایی که lease آن‌ها گذشته (کارگر مرده) — hk_dispatcher
CREATE OR REPLACE FUNCTION core.job_reap_expired(p_limit integer DEFAULT 500) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE n integer; m integer;
BEGIN
  UPDATE core.job j
     SET status = CASE WHEN j.attempts >= j.max_attempts THEN 'dead' ELSE 'queued' END,
         run_after = now() + make_interval(secs => core.job_backoff_seconds(j.attempts, j.backoff_base_s, j.backoff_cap_s)),
         finished_at = CASE WHEN j.attempts >= j.max_attempts THEN now() END,
         lock_token = NULL, lease_owner = NULL, lease_expires_at = NULL,
         last_error = jsonb_build_object('code', 'lease_expired', 'worker', j.lease_owner, 'at', now())
   WHERE j.id IN (SELECT x.id FROM core.job x WHERE x.status = 'running' AND x.lease_expires_at < now()
                   ORDER BY x.lease_expires_at LIMIT p_limit FOR UPDATE SKIP LOCKED);
  GET DIAGNOSTICS n = ROW_COUNT;
  UPDATE core.outbox_delivery d
     SET status = CASE WHEN d.attempts >= s.max_attempts THEN 'dead' ELSE 'pending' END,
         next_attempt_at = now() + make_interval(secs => core.job_backoff_seconds(d.attempts, 15, 21600)),
         lease_owner = NULL, lease_expires_at = NULL,
         last_error = jsonb_build_object('code', 'lease_expired', 'worker', d.lease_owner, 'at', now())
    FROM core.event_subscriber s
   WHERE s.subscriber = d.subscriber
     AND (d.tenant_id, d.event_id, d.subscriber) IN (
           SELECT x.tenant_id, x.event_id, x.subscriber FROM core.outbox_delivery x
            WHERE x.status = 'running' AND x.lease_expires_at < now()
            ORDER BY x.lease_expires_at LIMIT p_limit FOR UPDATE SKIP LOCKED);
  GET DIAGNOSTICS m = ROW_COUNT;
  RETURN n + m;
END $$;

-- ---------- outbox: fan-out هم‌تراکنش و رله‌گر ----------
-- هر رویداد در همان تراکنش برای هر مشترک فعال منطبق یک ردیف تحویل می‌گیرد (قرارداد ۰۱ §۴-۲؛
-- اجرای آن در پایگاه داده افزودهٔ این بخش است تا «رویداد بدون تحویل» حتی با باگ پایتون ممکن نباشد).
CREATE OR REPLACE FUNCTION core.outbox_fanout() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO core.outbox_delivery (tenant_id, event_id, subscriber, event_seq, aggregate_id)
  SELECT DISTINCT NEW.tenant_id, NEW.id, r.subscriber, NEW.seq, NEW.aggregate_id
    FROM core.event_subscription s
    JOIN core.event_subscriber r ON r.subscriber = s.subscriber
   WHERE r.enabled
     AND (s.event_type = '*' OR s.event_type = NEW.event_type
          OR (right(s.event_type, 2) = '.*' AND starts_with(NEW.event_type, left(s.event_type, -1))))
     AND (NOT r.requires_webhook_endpoint OR EXISTS (
            SELECT 1 FROM core.webhook_endpoint w
             WHERE w.tenant_id = NEW.tenant_id AND w.status = 'active' AND NEW.event_type = ANY (w.event_types)))
  ON CONFLICT DO NOTHING;
  RETURN NULL;
END $$;
-- ترتیب commit-safe برای هر (مستأجر، aggregate) (RV-CORE-08): پیش از گرفتن seq قفل advisory تراکنشی همان aggregate
-- گرفته و seq پس از قفل از نو تخصیص می‌شود. پس تولیدکنندهٔ دوم همان aggregate تا commit/rollback اولی منتظر می‌ماند و
-- هر رویداد commit‌شده با seq = s تضمین می‌کند همهٔ رویدادهای کوچک‌تر همان aggregate پیش‌تر commit (یا rollback) شده‌اند.
-- UoW رویدادهای بافرشده را (پایدار) بر پایهٔ aggregate مرتب درج می‌کند تا ترتیب قفل‌ها ثابت و بن‌بست نادر بماند.
CREATE OR REPLACE FUNCTION core.outbox_order_lock_key(p_tenant uuid, p_aggregate uuid) RETURNS integer
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT hashtext(p_tenant::text || ':' || p_aggregate::text)
$$;
CREATE OR REPLACE FUNCTION core.outbox_event_order() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(1330597960, core.outbox_order_lock_key(NEW.tenant_id, NEW.aggregate_id));   -- کلاس 'OUTH'
  NEW.seq := nextval('core.outbox_event_seq_seq'::regclass);
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_order ON core.outbox_event;
CREATE TRIGGER trg_order BEFORE INSERT ON core.outbox_event FOR EACH ROW EXECUTE FUNCTION core.outbox_event_order();

DROP TRIGGER IF EXISTS trg_fanout ON core.outbox_event;
CREATE TRIGGER trg_fanout AFTER INSERT ON core.outbox_event FOR EACH ROW EXECUTE FUNCTION core.outbox_fanout();

DROP TRIGGER IF EXISTS trg_outbox_event_no_update ON core.outbox_event;
CREATE TRIGGER trg_outbox_event_no_update BEFORE UPDATE ON core.outbox_event FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

CREATE OR REPLACE FUNCTION core.outbox_event_guard_delete() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF current_user <> 'hk_dispatcher' OR EXISTS (
       SELECT 1 FROM core.outbox_delivery d WHERE d.tenant_id = OLD.tenant_id AND d.event_id = OLD.id AND d.status <> 'done') THEN
    RAISE EXCEPTION 'HK_IMMUTABLE: DELETE on core.outbox_event is not allowed' USING ERRCODE = 'P0001';
  END IF;
  RETURN OLD;
END $$;
DROP TRIGGER IF EXISTS trg_outbox_event_guard_delete ON core.outbox_event;
CREATE TRIGGER trg_outbox_event_guard_delete BEFORE DELETE ON core.outbox_event FOR EACH ROW EXECUTE FUNCTION core.outbox_event_guard_delete();

CREATE OR REPLACE FUNCTION core.outbox_delivery_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'pending' OR NEW.attempts <> 0 THEN
      PERFORM core.raise_hk('HK_OUTBOX_STATE', 'delivery must start pending with attempts = 0');
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.tenant_id, NEW.event_id, NEW.subscriber, NEW.event_seq, NEW.aggregate_id, NEW.id)
     IS DISTINCT FROM (OLD.tenant_id, OLD.event_id, OLD.subscriber, OLD.event_seq, OLD.aggregate_id, OLD.id) THEN
    PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'delivery identity is immutable');
  END IF;
  IF NEW.status <> OLD.status AND NOT ((OLD.status, NEW.status) IN
       (('pending','running'),('running','done'),('running','pending'),('running','dead'),('dead','pending'))) THEN
    PERFORM core.raise_hk('HK_CORE_INVALID_TRANSITION', format('delivery %s -> %s', OLD.status, NEW.status));
  END IF;
  IF OLD.status = 'done' AND NEW IS DISTINCT FROM OLD THEN
    PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'done delivery is final');
  END IF;
  IF OLD.status = 'dead' AND NEW.status = 'pending' AND NEW.attempts <> 0 THEN
    PERFORM core.raise_hk('HK_OUTBOX_STATE', 'manual requeue resets attempts to 0');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.outbox_delivery;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON core.outbox_delivery FOR EACH ROW EXECUTE FUNCTION core.outbox_delivery_guard();

-- رله‌گر (hk_dispatcher). RV-X4-06: هزینهٔ هر claim به اندازهٔ صف انباشته نیست: برای هر مشترک از مکان نوبت‌گردشی
-- (outbox_claim_cursor) روی نمایهٔ outbox_delivery_tenant_due از مستأجری به مستأجر بعدی می‌پرد (هر پرش یک seek) و از هر
-- مستأجر حداکثر p_per_tenant تحویلِ سررسیده را به ترتیب (next_attempt_at, event_seq) با SKIP LOCKED برمی‌دارد.
-- مشترک ordered: تحویلی برداشته می‌شود که هیچ تحویل نا-done با event_seq کوچک‌تر در همان (مشترک، مستأجر، aggregate)
-- ندارد؛ با قفل ترتیب outbox_event_order این شرط commit-safe است (RV-CORE-08).
CREATE OR REPLACE FUNCTION core.outbox_claim(p_subscribers text[], p_worker text, p_n integer,
                                             p_lease_seconds integer DEFAULT 60, p_per_tenant integer DEFAULT 10)
RETURNS TABLE (tenant_id uuid, event_id uuid, subscriber text, event_seq bigint, attempts integer)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
  v_sub text; v_ordered boolean; v_start uuid; v_t uuid; v_last uuid; v_wrapped boolean;
  v_taken integer := 0; v_probes integer; d record; v_now timestamptz := now();
BEGIN
  IF p_n IS NULL OR p_n < 1 OR p_per_tenant IS NULL OR p_per_tenant < 1 OR p_lease_seconds NOT BETWEEN 10 AND 3600 THEN
    PERFORM core.raise_hk('HK_OUTBOX_ARGS', 'invalid claim arguments');
  END IF;
  FOR v_sub, v_ordered IN
    SELECT es.subscriber, es.ordered FROM core.event_subscriber es
     WHERE es.subscriber = ANY (p_subscribers) AND es.enabled ORDER BY es.subscriber
  LOOP
    EXIT WHEN v_taken >= p_n;
    INSERT INTO core.outbox_claim_cursor AS cc (subscriber) VALUES (v_sub) ON CONFLICT DO NOTHING;
    SELECT cc.last_tenant_id INTO v_start FROM core.outbox_claim_cursor cc WHERE cc.subscriber = v_sub FOR UPDATE;
    v_t := v_start; v_last := v_start; v_wrapped := false; v_probes := 0;
    LOOP
      EXIT WHEN v_taken >= p_n OR v_probes >= 1000;
      v_probes := v_probes + 1;
      SELECT x.tenant_id INTO v_t FROM core.outbox_delivery x
       WHERE x.subscriber = v_sub AND x.status = 'pending' AND (v_t IS NULL OR x.tenant_id > v_t)
       ORDER BY x.tenant_id LIMIT 1;
      IF NOT FOUND THEN
        EXIT WHEN v_wrapped OR v_start IS NULL;
        v_wrapped := true; v_t := NULL;
        CONTINUE;
      END IF;
      EXIT WHEN v_wrapped AND v_t > v_start;          -- یک دور کامل
      v_last := v_t;
      FOR d IN
        SELECT x.tenant_id AS t_id, x.event_id AS e_id FROM core.outbox_delivery x
         WHERE x.subscriber = v_sub AND x.tenant_id = v_t AND x.status = 'pending' AND x.next_attempt_at <= v_now
           AND (NOT v_ordered OR NOT EXISTS (
                 SELECT 1 FROM core.outbox_delivery y
                  WHERE y.subscriber = x.subscriber AND y.tenant_id = x.tenant_id
                    AND y.aggregate_id = x.aggregate_id AND y.event_seq < x.event_seq AND y.status <> 'done'))
         ORDER BY x.next_attempt_at, x.event_seq
         LIMIT least(p_per_tenant, p_n - v_taken)
         FOR UPDATE OF x SKIP LOCKED
      LOOP
        UPDATE core.outbox_delivery u
           SET status = 'running', lease_owner = p_worker,
               lease_expires_at = v_now + make_interval(secs => p_lease_seconds), attempts = u.attempts + 1
         WHERE u.tenant_id = d.t_id AND u.event_id = d.e_id AND u.subscriber = v_sub
        RETURNING u.tenant_id, u.event_id, u.subscriber, u.event_seq, u.attempts
             INTO tenant_id, event_id, subscriber, event_seq, attempts;
        RETURN NEXT;
        v_taken := v_taken + 1;
      END LOOP;
    END LOOP;
    -- مکان نوبت همیشه جلو می‌رود (حتی بی‌برداشت) تا مستأجرهای پس از ۱۰۰۰ پرش گرسنه نمانند
    UPDATE core.outbox_claim_cursor cc SET last_tenant_id = v_last, updated_at = now() WHERE cc.subscriber = v_sub;
  END LOOP;
END $$;

-- اعلان پیامکی/ایمیلی ← job ارسال در همان تراکنش
CREATE OR REPLACE FUNCTION core.notification_enqueue() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.channel IN ('sms','email') AND NEW.status = 'pending' THEN
    INSERT INTO core.job (tenant_id, queue, kind, payload, dedupe_key, max_attempts, created_by)
    VALUES (NEW.tenant_id, 'notify', 'core.notification.send', jsonb_build_object('notification_id', NEW.id),
            'ntf:' || NEW.id::text, 8, core.current_user_id());
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_enqueue ON core.notification;
CREATE TRIGGER trg_enqueue AFTER INSERT ON core.notification FOR EACH ROW EXECUTE FUNCTION core.notification_enqueue();

CREATE OR REPLACE FUNCTION core.notification_preference_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT NEW.enabled AND EXISTS (SELECT 1 FROM core.notification_category c WHERE c.code = NEW.category AND c.is_mandatory) THEN
    PERFORM core.raise_hk('HK_NTF_MANDATORY', format('category %s cannot be disabled', NEW.category));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.notification_preference;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON core.notification_preference
  FOR EACH ROW EXECUTE FUNCTION core.notification_preference_guard();

CREATE OR REPLACE FUNCTION core.notification_template_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM core.notification_template_def d
                  WHERE d.code = NEW.code AND d.channel = NEW.channel AND d.locale = NEW.locale AND d.tenant_overridable) THEN
    PERFORM core.raise_hk('HK_NTF_NOT_OVERRIDABLE', 'this template cannot be overridden by tenants');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.notification_template;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON core.notification_template
  FOR EACH ROW EXECUTE FUNCTION core.notification_template_guard();

-- نگهداری: دورهٔ مستأجر نمی‌تواند از حداقل کلاس کوتاه‌تر باشد
CREATE OR REPLACE FUNCTION core.retention_override_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE c core.retention_class;
BEGIN
  SELECT * INTO c FROM core.retention_class WHERE code = NEW.class_code;
  IF c.rules_param_key IS NOT NULL THEN
    PERFORM core.raise_hk('HK_RET_LEGAL', 'legal retention is set by the rules engine, not by tenants');
  END IF;
  IF c.min_period IS NOT NULL AND NEW.period < c.min_period THEN
    PERFORM core.raise_hk('HK_RET_TOO_SHORT', format('retention for %s must be >= %s', c.code, c.min_period));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.retention_override;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON core.retention_override
  FOR EACH ROW EXECUTE FUNCTION core.retention_override_guard();

-- ---------- فیلد سفارشی: بازسازی نمایه (RV-CORE-16) ----------
-- custom_field_index = تصویر دقیق فیلدهای is_indexed ردیف‌های مالک (INV-CF-03). روشن/خاموش شدن is_indexed و
-- درون‌ریزی .hkx (که در حالت replica تریگرها را اجرا نمی‌کند) با همین تابع بازسازی می‌شوند. جدول مالک از کاتالوگ
-- custom_field_entity (نوشتهٔ migration) خوانده و با regclass نقل‌قول می‌شود؛ RLS فقط مستأجر جاری را می‌دهد.
CREATE OR REPLACE FUNCTION core.custom_field_reindex(p_entity_type text, p_field_id uuid DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE e core.custom_field_entity; d core.custom_field_def; v_tenant uuid := core.current_tenant_id();
        n integer := 0; k integer; v_tbl regclass;
BEGIN
  IF v_tenant IS NULL THEN PERFORM core.raise_hk('HK_TENANT_CONTEXT_MISSING', 'set app.tenant_id'); END IF;
  SELECT * INTO e FROM core.custom_field_entity x WHERE x.entity_type = p_entity_type;
  IF NOT FOUND THEN PERFORM core.raise_hk('HK_CF_UNKNOWN_ENTITY', p_entity_type); END IF;
  v_tbl := e.table_name::regclass;
  DELETE FROM core.custom_field_index i
   WHERE i.tenant_id = v_tenant AND i.entity_type = p_entity_type AND (p_field_id IS NULL OR i.field_id = p_field_id);
  FOR d IN SELECT * FROM core.custom_field_def x
            WHERE x.tenant_id = v_tenant AND x.entity_type = p_entity_type AND x.is_indexed
              AND (p_field_id IS NULL OR x.id = p_field_id)
  LOOP
    IF d.data_type = 'multi_enum' THEN
      EXECUTE format($q$INSERT INTO core.custom_field_index (tenant_id, entity_type, field_id, entity_id, value_text)
                        SELECT t.tenant_id, $1, $2, t.id, x FROM %1$s t
                          CROSS JOIN LATERAL jsonb_array_elements_text(t.%2$I -> $3) x
                         WHERE t.tenant_id = $4 AND jsonb_typeof(t.%2$I -> $3) = 'array'$q$, v_tbl, e.json_column)
      USING p_entity_type, d.id, d.code, v_tenant;
    ELSE
      EXECUTE format($q$INSERT INTO core.custom_field_index (tenant_id, entity_type, field_id, entity_id,
                                                           value_text, value_num, value_date, value_bool)
                        SELECT t.tenant_id, $1, $2, t.id,
                               CASE WHEN $5 IN ('text','enum','ref') THEN core.fa_search_key(t.%2$I ->> $3) END,
                               CASE WHEN $5 IN ('int','decimal') THEN (t.%2$I ->> $3)::numeric END,
                               CASE WHEN $5 = 'date' THEN (t.%2$I ->> $3)::date END,
                               CASE WHEN $5 = 'bool' THEN (t.%2$I ->> $3)::boolean END
                          FROM %1$s t
                         WHERE t.tenant_id = $4 AND t.%2$I ? $3 AND jsonb_typeof(t.%2$I -> $3) <> 'null'$q$, v_tbl, e.json_column)
      USING p_entity_type, d.id, d.code, v_tenant, d.data_type;
    END IF;
    GET DIAGNOSTICS k = ROW_COUNT;
    n := n + k;
  END LOOP;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION core.custom_field_def_reindex() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.is_indexed IS DISTINCT FROM OLD.is_indexed THEN
    IF NEW.is_indexed THEN
      PERFORM core.custom_field_reindex(NEW.entity_type, NEW.id);
    ELSE
      DELETE FROM core.custom_field_index i WHERE i.tenant_id = NEW.tenant_id AND i.field_id = NEW.id;
    END IF;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_reindex ON core.custom_field_def;
CREATE TRIGGER trg_reindex AFTER UPDATE OF is_indexed ON core.custom_field_def
  FOR EACH ROW EXECUTE FUNCTION core.custom_field_def_reindex();

-- ---------- توقیف قانونی و درخواست دادهٔ شخصی: ماشین حالت در پایگاه داده (RV-CORE-27) ----------
CREATE OR REPLACE FUNCTION core.legal_hold_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.released_at IS NOT NULL OR NEW.released_by IS NOT NULL THEN
      PERFORM core.raise_hk('HK_RET_HOLD', 'a legal hold starts active');
    END IF;
    IF NOT core.privileged_context() AND (NEW.placed_at > now() + interval '1 minute' OR NEW.placed_at < now() - interval '5 minutes') THEN
      PERFORM core.raise_hk('HK_RET_HOLD', 'a legal hold is placed now (no backdating)');
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.tenant_id, NEW.id, NEW.scope, NEW.company_id, NEW.resource_type, NEW.resource_id, NEW.subject_type, NEW.subject_id,
      NEW.reason, NEW.placed_by, NEW.placed_by_staff_id, NEW.placed_at)
     IS DISTINCT FROM
     (OLD.tenant_id, OLD.id, OLD.scope, OLD.company_id, OLD.resource_type, OLD.resource_id, OLD.subject_type, OLD.subject_id,
      OLD.reason, OLD.placed_by, OLD.placed_by_staff_id, OLD.placed_at) THEN
    PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'a legal hold can only be released');
  END IF;
  IF OLD.released_at IS NOT NULL AND (NEW.released_at IS DISTINCT FROM OLD.released_at OR NEW.released_by IS DISTINCT FROM OLD.released_by) THEN
    PERFORM core.raise_hk('HK_RET_HOLD', 'release of a legal hold is final');
  END IF;
  IF NEW.released_at IS NOT NULL AND OLD.released_at IS NULL AND NEW.released_at > now() + interval '1 minute' THEN
    PERFORM core.raise_hk('HK_RET_HOLD', 'release time cannot be in the future');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.legal_hold;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON core.legal_hold FOR EACH ROW EXECUTE FUNCTION core.legal_hold_guard();

CREATE OR REPLACE FUNCTION core.data_subject_request_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'received' OR NEW.approved_by IS NOT NULL OR NEW.decided_at IS NOT NULL OR NEW.completed_at IS NOT NULL THEN
      PERFORM core.raise_hk('HK_RET_DSR_STATE', 'a data subject request starts received');
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.tenant_id, NEW.id, NEW.subject_type, NEW.subject_id, NEW.request_type, NEW.requested_via, NEW.requested_by, NEW.received_at)
     IS DISTINCT FROM
     (OLD.tenant_id, OLD.id, OLD.subject_type, OLD.subject_id, OLD.request_type, OLD.requested_via, OLD.requested_by, OLD.received_at) THEN
    PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'data subject request identity is immutable');
  END IF;
  IF OLD.status IN ('rejected','completed') THEN
    PERFORM core.raise_hk('HK_RET_DSR_STATE', format('data subject request is %s (final)', OLD.status));
  END IF;
  IF NEW.status <> OLD.status AND NOT ((OLD.status, NEW.status) IN
       (('received','in_review'),('received','rejected'),('in_review','approved'),('in_review','rejected'),('approved','completed'))) THEN
    PERFORM core.raise_hk('HK_CORE_INVALID_TRANSITION', format('data subject request %s -> %s', OLD.status, NEW.status));
  END IF;
  IF OLD.approved_by IS NOT NULL AND NEW.approved_by IS DISTINCT FROM OLD.approved_by THEN
    PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'approver of a data subject request is immutable');
  END IF;
  IF NEW.status <> OLD.status AND NEW.status IN ('approved','rejected') THEN NEW.decided_at := now(); END IF;
  IF NEW.status = 'completed' AND OLD.status <> 'completed' THEN NEW.completed_at := now(); END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.data_subject_request;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON core.data_subject_request
  FOR EACH ROW EXECUTE FUNCTION core.data_subject_request_guard();

-- ---------- ساعت سرور On-prem/لبه: max_seen_at فقط جلو می‌رود (RV-ARCH-17؛ ۰۱ سناریوی ۷) ----------
CREATE OR REPLACE FUNCTION core.deployment_info_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.max_seen_at < OLD.max_seen_at THEN
    PERFORM core.raise_hk('HK_CORE_CLOCK_ROLLBACK', format('max_seen_at cannot move back (%s -> %s)', OLD.max_seen_at, NEW.max_seen_at));
  END IF;
  IF NOT core.privileged_context()
     AND (NEW.singleton, NEW.install_id, NEW.profile, NEW.cell_id, NEW.app_version, NEW.schema_head, NEW.last_upgrade_at, NEW.created_at)
         IS DISTINCT FROM
         (OLD.singleton, OLD.install_id, OLD.profile, OLD.cell_id, OLD.app_version, OLD.schema_head, OLD.last_upgrade_at, OLD.created_at) THEN
    PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'only hk migrate changes deployment_info (runtime may advance max_seen_at)');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.deployment_info;
CREATE TRIGGER trg_guard BEFORE UPDATE ON core.deployment_info FOR EACH ROW EXECUTE FUNCTION core.deployment_info_guard();

-- ---------- راز یک‌بارمصرف هرگز ذخیره نمی‌شود (RV-CORE-03) ----------
-- مسیرهای کلید JSON که نام راز دارند (برای بدنهٔ بازپخش idempotency)
CREATE OR REPLACE FUNCTION core.jsonb_secret_paths(p jsonb) RETURNS SETOF text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  WITH RECURSIVE t(path, v, depth) AS (
    SELECT ''::text, p, 0
    UNION ALL
    SELECT t.path || c.k, c.v, t.depth + 1
      FROM t CROSS JOIN LATERAL (
        SELECT '.' || e.key AS k, e.value AS v
          FROM jsonb_each(CASE WHEN jsonb_typeof(t.v) = 'object' THEN t.v ELSE '{}'::jsonb END) e
        UNION ALL
        SELECT '[]', a.value FROM jsonb_array_elements(CASE WHEN jsonb_typeof(t.v) = 'array' THEN t.v ELSE '[]'::jsonb END) a
      ) c
     WHERE t.depth < 32)
  SELECT path FROM t
   WHERE path ~ '\.(secret|token|password|pin|otp|enrollment_code|api_key|private_key|[a-z0-9_]+_(secret|token|password))$'
$$;

CREATE OR REPLACE FUNCTION core.idem_no_secret() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_path text;
BEGIN
  IF NEW.response_body IS NOT NULL THEN
    SELECT p INTO v_path FROM core.jsonb_secret_paths(NEW.response_body) p LIMIT 1;
    IF v_path IS NOT NULL THEN
      PERFORM core.raise_hk('HK_IDEMPOTENCY_SECRET',
        format('replay body must not store a one-time secret (%s); store the redacted body (secret_shown_once)', v_path));
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_no_secret ON core.idempotency_key;
CREATE TRIGGER trg_no_secret BEFORE INSERT OR UPDATE OF response_body ON core.idempotency_key
  FOR EACH ROW EXECUTE FUNCTION core.idem_no_secret();

CREATE OR REPLACE FUNCTION core.notification_secret_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_runtime text[];
BEGIN
  SELECT d.runtime_variables INTO v_runtime FROM core.notification_template_def d
   WHERE d.code = NEW.template_code AND d.channel = NEW.channel AND d.locale = NEW.locale;
  IF cardinality(v_runtime) > 0 THEN
    IF NEW.params ?| v_runtime THEN
      PERFORM core.raise_hk('HK_NTF_SECRET_PARAM', format('template %s fills %s only at send time; never store it', NEW.template_code, v_runtime));
    END IF;
    IF NEW.rendered_body IS NOT NULL OR NEW.rendered_subject IS NOT NULL THEN
      PERFORM core.raise_hk('HK_NTF_SECRET_PARAM', format('template %s is never stored rendered', NEW.template_code));
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_secret_guard ON core.notification;
CREATE TRIGGER trg_secret_guard BEFORE INSERT OR UPDATE ON core.notification
  FOR EACH ROW EXECUTE FUNCTION core.notification_secret_guard();

-- ---------- صدور: مانع فعال (08:CR-MG05) ----------
CREATE OR REPLACE FUNCTION core.tenant_export_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM core.export_blocker b WHERE b.tenant_id = NEW.tenant_id AND b.released_at IS NULL) THEN
    PERFORM core.raise_hk('HK_EXPORT_BLOCKED', 'an export blocker is active (e.g. a migration is committing)');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.tenant_export;
CREATE TRIGGER trg_guard BEFORE INSERT ON core.tenant_export FOR EACH ROW EXECUTE FUNCTION core.tenant_export_guard();

CREATE OR REPLACE FUNCTION core.export_blocker_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.tenant_id, NEW.id, NEW.module, NEW.reason_code, NEW.resource_id, NEW.created_at)
     IS DISTINCT FROM (OLD.tenant_id, OLD.id, OLD.module, OLD.reason_code, OLD.resource_id, OLD.created_at)
     OR OLD.released_at IS NOT NULL THEN
    PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'an export blocker can only be released once');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.export_blocker;
CREATE TRIGGER trg_guard BEFORE UPDATE ON core.export_blocker FOR EACH ROW EXECUTE FUNCTION core.export_blocker_guard();

-- ---------- کمک‌تابع‌های عمومی برای ماژول‌ها ----------
-- ستون‌های نام‌برده در TG_ARGV پس از درج تغییرناپذیرند (06:CR-T12). روی ستون مولد (GENERATED) به کار نرود.
CREATE OR REPLACE FUNCTION core.freeze_columns() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE c text; o jsonb := to_jsonb(OLD); n jsonb := to_jsonb(NEW);
BEGIN
  FOREACH c IN ARRAY TG_ARGV LOOP
    IF NOT (o ? c) THEN
      PERFORM core.raise_hk('HK_CORE_FREEZE_ARGS', format('%s.%s has no column %s', TG_TABLE_SCHEMA, TG_TABLE_NAME, c));
    END IF;
    IF (o -> c) IS DISTINCT FROM (n -> c) THEN
      PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', format('%s.%s.%s cannot change after creation', TG_TABLE_SCHEMA, TG_TABLE_NAME, c));
    END IF;
  END LOOP;
  RETURN NEW;
END $$;

-- نگهبان لایهٔ دوم دستیار (10:C-AS-02؛ RV-AST-19/RV-X2-12): جدول ثبت قطعی در تراکنشی که app.actor_via آن از
-- دستیار است (assistant یا assistant_confirm) یا مقدارش ناشناخته است، درج نمی‌پذیرد. TG_ARGV اختیاری: فهرست صریح
-- مقادیر ممنوع. هر ماژول با core.attach_actor_via_guard روی جدول‌های ثبت قطعی خودش نصب می‌کند (نه پیش‌نویس‌ها).
CREATE OR REPLACE FUNCTION core.forbid_actor_via() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v text := coalesce(nullif(current_setting('app.actor_via', true), ''), 'direct');
BEGIN
  IF v NOT IN ('direct','assistant','assistant_confirm')
     OR (TG_NARGS = 0 AND v <> 'direct') OR (TG_NARGS > 0 AND v = ANY (TG_ARGV)) THEN
    PERFORM core.raise_hk('HK_CORE_ACTOR_VIA',
      format('%s on %s.%s is not allowed when app.actor_via = %s', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME, v));
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;

CREATE OR REPLACE FUNCTION core.attach_actor_via_guard(p_table regclass) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('DROP TRIGGER IF EXISTS "0_actor_via_guard" ON %s', p_table);
  EXECUTE format('CREATE TRIGGER "0_actor_via_guard" BEFORE INSERT ON %s FOR EACH ROW EXECUTE FUNCTION core.forbid_actor_via()', p_table);
END $$;

-- اسکیماهای صفحهٔ داده از کاتالوگ (RV-IT-05): هر اسکیمای غیرسیستمی جز public. اسکیمای ماژول تازه بی‌ثبت دستی پوشش می‌گیرد.
CREATE OR REPLACE FUNCTION core.data_plane_schemas() RETURNS TABLE (nspname name)
LANGUAGE sql STABLE AS $$
  SELECT n.nspname FROM pg_catalog.pg_namespace n
   WHERE n.nspname NOT IN ('public','information_schema') AND n.nspname NOT LIKE 'pg\_%'
$$;

-- =====================================================================
-- ۱۹-ب. چرخهٔ عمر مستأجر در صفحهٔ داده: provisioning، حالت مطلوب و حق استفاده، قالب چاپ،
--       راستی‌آزمایی درون‌ریزی .hkx و پاک‌سازی نهایی
-- =====================================================================

-- ---------- حالت مطلوب (RV-X4-03، RV-X2-10؛ ۰۱ §۵-۱۱، ۰۹ D-P07/D-P09) ----------
-- سند امضاشدهٔ hkstate/1 همان‌گونه که امضا شده (متن) نگه داشته می‌شود؛ نسخه فقط بالا می‌رود. امضای Ed25519 را
-- PlatformSync پیش از فراخوانی با بستهٔ اعتماد می‌سنجد؛ پایگاه داده sha256، امضا و kid را برای ممیزی نگه می‌دارد.
CREATE TABLE IF NOT EXISTS core.tenant_desired_state (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  version      bigint NOT NULL CHECK (version >= 1),
  document     text NOT NULL CHECK (document IS JSON OBJECT),
  doc_sha256   bytea NOT NULL CHECK (octet_length(doc_sha256) = 32),
  signature    bytea NOT NULL CHECK (octet_length(signature) BETWEEN 32 AND 512),
  kid          text NOT NULL CHECK (char_length(kid) BETWEEN 1 AND 200),
  applied_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id)
);
SELECT core.enable_tenant_rls('core.tenant_desired_state');

-- حق استفادهٔ اعمال‌شده (EntitlementGate پس از راه‌اندازی دوباره هم بدون صفحهٔ کنترل از همین‌جا می‌خواند)
CREATE TABLE IF NOT EXISTS core.tenant_entitlement (
  tenant_id       uuid NOT NULL REFERENCES core.tenant(id),
  id              uuid NOT NULL DEFAULT uuidv7(),
  feature_key     text NOT NULL CHECK (feature_key ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),
  enabled         boolean NOT NULL DEFAULT true,
  limit_value     bigint CHECK (limit_value IS NULL OR limit_value >= 0),
  enforcement     text NOT NULL DEFAULT 'hard' CHECK (enforcement IN ('hard','soft')),
  source_version  bigint NOT NULL CHECK (source_version >= 1),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, feature_key)
);
SELECT core.enable_tenant_rls('core.tenant_entitlement');

CREATE OR REPLACE FUNCTION core.tenant_desired_state_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.doc_sha256 <> sha256(convert_to(NEW.document, 'UTF8')) THEN
    PERFORM core.raise_hk('HK_CORE_DESIRED_STATE', 'doc_sha256 does not match the stored document');
  END IF;
  IF TG_OP = 'UPDATE' AND (NEW.tenant_id <> OLD.tenant_id OR NEW.version <= OLD.version) THEN
    PERFORM core.raise_hk('HK_CORE_DESIRED_STATE', 'desired-state version only moves forward');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.tenant_desired_state;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON core.tenant_desired_state
  FOR EACH ROW EXECUTE FUNCTION core.tenant_desired_state_guard();

-- اعمال سند در یک تراکنش سیستمی همان مستأجر (UoW بدون کاربر): وضعیت مستأجر (با گذار مجاز)، حق استفاده‌ها و ردیف
-- ممیزی. نسخهٔ ≤ نسخهٔ اعمال‌شده 'ignored' برمی‌گرداند (ضد بازپخش و عقب‌گرد). تنها مسیر زمان اجرا برای تغییر
-- core.tenant.status (R-GRANT: hk_app روی status امتیاز UPDATE ندارد).
CREATE OR REPLACE FUNCTION core.apply_desired_state(p_document text, p_signature bytea, p_kid text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_tenant uuid := core.current_tenant_id(); d jsonb; v_version bigint; v_status text; v_old text;
        cur core.tenant_desired_state; e jsonb;
BEGIN
  IF v_tenant IS NULL THEN PERFORM core.raise_hk('HK_TENANT_CONTEXT_MISSING', 'apply_desired_state needs app.tenant_id'); END IF;
  IF core.current_user_id() IS NOT NULL THEN
    PERFORM core.raise_hk('HK_CORE_SYSTEM_ONLY', 'desired state is applied only by the system UnitOfWork (no app.user_id)');
  END IF;
  d := p_document::jsonb;
  IF d->>'format' IS DISTINCT FROM 'hkstate/1' OR (d->>'tenant_id')::uuid IS DISTINCT FROM v_tenant THEN
    PERFORM core.raise_hk('HK_CORE_DESIRED_STATE', 'document is not hkstate/1 for this tenant');
  END IF;
  v_version := (d->>'version')::bigint;
  SELECT * INTO cur FROM core.tenant_desired_state x WHERE x.tenant_id = v_tenant FOR UPDATE;
  IF FOUND AND v_version <= cur.version THEN
    RETURN 'ignored';
  END IF;
  IF FOUND THEN
    UPDATE core.tenant_desired_state SET version = v_version, document = p_document,
           doc_sha256 = sha256(convert_to(p_document, 'UTF8')), signature = p_signature, kid = p_kid, applied_at = now()
     WHERE id = cur.id;
  ELSE
    INSERT INTO core.tenant_desired_state (tenant_id, version, document, doc_sha256, signature, kid)
    VALUES (v_tenant, v_version, p_document, sha256(convert_to(p_document, 'UTF8')), p_signature, p_kid);
  END IF;
  -- وضعیت: archived پایانی است و provisioning فقط وضعیت آغاز
  v_status := d->>'status';
  SELECT t.status INTO v_old FROM core.tenant t WHERE t.id = v_tenant FOR NO KEY UPDATE;
  IF v_status IS NOT NULL AND v_status IS DISTINCT FROM v_old THEN
    IF v_old = 'archived' OR v_status = 'provisioning'
       OR v_status NOT IN ('active','read_only','suspended','exporting','archived') THEN
      PERFORM core.raise_hk('HK_CORE_INVALID_TRANSITION', format('tenant %s -> %s', v_old, v_status));
    END IF;
    UPDATE core.tenant SET status = v_status WHERE id = v_tenant;
  END IF;
  -- حق استفاده: جایگزینی کامل با فهرست سند
  DELETE FROM core.tenant_entitlement x
   WHERE x.tenant_id = v_tenant
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(d->'entitlements', '[]'::jsonb)) j WHERE j->>'key' = x.feature_key);
  FOR e IN SELECT * FROM jsonb_array_elements(coalesce(d->'entitlements', '[]'::jsonb)) LOOP
    INSERT INTO core.tenant_entitlement (tenant_id, feature_key, enabled, limit_value, enforcement, source_version)
    VALUES (v_tenant, e->>'key', coalesce((e->>'enabled')::boolean, true), (e->>'limit')::bigint,
            coalesce(e->>'enforcement', 'hard'), v_version)
    ON CONFLICT (tenant_id, feature_key) DO UPDATE
      SET enabled = EXCLUDED.enabled, limit_value = EXCLUDED.limit_value, enforcement = EXCLUDED.enforcement,
          source_version = EXCLUDED.source_version, updated_at = now();
  END LOOP;
  INSERT INTO core.audit_log (tenant_id, actor_kind, action, resource_type, resource_id, details)
  VALUES (v_tenant, 'system', 'core.tenant.desired_state_applied', 'core.tenant', v_tenant,
          jsonb_build_object('version', v_version, 'status', coalesce(v_status, v_old), 'kid', p_kid,
                             'sha256', encode(sha256(convert_to(p_document, 'UTF8')), 'hex'))::text);
  RETURN 'applied';
END $$;

-- سقف سخت حق استفاده در خود پایگاه داده (D-P09): شمارش پس از قفل ردیف مستأجر در زمان commit؛ دو فعال‌سازی
-- هم‌زمان در ۵/۵ نمی‌توانند هر دو بگذرند. TG_ARGV[0] = feature_key؛ بدون ردیف حق استفاده یا soft ← بدون مانع.
CREATE OR REPLACE FUNCTION core.entitlement_limit_check() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_key text := TG_ARGV[0]; v_limit bigint; v_count bigint;
BEGIN
  SELECT e.limit_value INTO v_limit FROM core.tenant_entitlement e
   WHERE e.tenant_id = NEW.tenant_id AND e.feature_key = v_key AND e.enabled AND e.enforcement = 'hard';
  IF v_limit IS NULL THEN RETURN NULL; END IF;
  PERFORM 1 FROM core.tenant t WHERE t.id = NEW.tenant_id FOR NO KEY UPDATE;
  v_count := CASE v_key
    WHEN 'core.members.active' THEN (SELECT count(*) FROM core.tenant_membership m
                                       WHERE m.tenant_id = NEW.tenant_id AND m.status = 'active'
                                         AND NOT EXISTS (SELECT 1 FROM core.app_user u WHERE u.id = m.user_id AND u.kind = 'service'))
    WHEN 'core.devices.active' THEN (SELECT count(*) FROM core.device x WHERE x.tenant_id = NEW.tenant_id AND x.status = 'active')
    WHEN 'core.branches'       THEN (SELECT count(*) FROM core.branch x WHERE x.tenant_id = NEW.tenant_id AND x.is_active)
    WHEN 'core.companies'      THEN (SELECT count(*) FROM core.company x WHERE x.tenant_id = NEW.tenant_id AND x.is_active)
  END;
  IF v_count > v_limit THEN
    PERFORM core.raise_hk('HK_CORE_ENTITLEMENT_LIMIT', format('%s: %s exceeds the plan limit %s', v_key, v_count, v_limit));
  END IF;
  RETURN NULL;
END $$;
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES ('core.tenant_membership', 'core.members.active'), ('core.device', 'core.devices.active'),
                                 ('core.branch', 'core.branches'), ('core.company', 'core.companies')) v(tbl, key)
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_entitlement_limit ON %s', r.tbl);
    EXECUTE format('CREATE CONSTRAINT TRIGGER trg_entitlement_limit AFTER INSERT OR UPDATE ON %s '
                   'DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION core.entitlement_limit_check(%L)', r.tbl, r.key);
  END LOOP;
END $$;

-- ---------- provisioning داده‌ای مستأجر (RV-X2-11، RV-X3-13؛ فرمان tenant.provision بخش ۰۹) ----------
CREATE TABLE IF NOT EXISTS core.tenant_provisioning (
  tenant_id      uuid NOT NULL REFERENCES core.tenant(id),
  id             uuid NOT NULL DEFAULT uuidv7(),
  command_id     uuid NOT NULL UNIQUE,                    -- شناسهٔ cell_command (idempotent در تحویل دوباره)
  status         text NOT NULL DEFAULT 'core_done' CHECK (status IN ('core_done','modules_running','completed','failed')),
  steps          jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(steps) = 'object'),   -- قلاب هر ماژول: done/failed
  owner_user_id  uuid NOT NULL,
  company_id     uuid NOT NULL,
  error          jsonb,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  row_version    integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, owner_user_id) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK ((status = 'failed') = (error IS NOT NULL))
);
SELECT core.enable_tenant_rls('core.tenant_provisioning');

CREATE OR REPLACE FUNCTION core.tenant_provisioning_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.tenant_id, NEW.id, NEW.command_id, NEW.owner_user_id, NEW.company_id, NEW.created_at)
     IS DISTINCT FROM (OLD.tenant_id, OLD.id, OLD.command_id, OLD.owner_user_id, OLD.company_id, OLD.created_at)
     OR OLD.status = 'completed'
     OR (NEW.status <> OLD.status AND NOT ((OLD.status, NEW.status) IN
          (('core_done','modules_running'),('modules_running','completed'),('core_done','failed'),('modules_running','failed'),
           ('failed','modules_running')))) THEN
    PERFORM core.raise_hk('HK_CORE_INVALID_TRANSITION', format('provisioning %s -> %s', OLD.status, NEW.status));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.tenant_provisioning;
CREATE TRIGGER trg_guard BEFORE UPDATE ON core.tenant_provisioning FOR EACH ROW EXECUTE FUNCTION core.tenant_provisioning_guard();

-- گام هسته‌ای فرمان tenant.provision (definer؛ UoW سیستمی با app.tenant_id = مستأجر تازه و بدون کاربر): مستأجر
-- (provisioning)، شرکت و شعبهٔ مرکزی، کاربر مالک (شمارهٔ تأییدشده در ثبت‌نام پلتفرم؛ فرمان امضاشده است)، عضویت مالک،
-- نقش‌های سیستمی از قالب‌ها و انتساب مالک. تحویل دوبارهٔ همان command_id همان نتیجه را برمی‌گرداند.
CREATE OR REPLACE FUNCTION core.provision_tenant(p_command_id uuid, p_slug text, p_display_name text,
                                                 p_owner_mobile text, p_owner_name text,
                                                 p_company_code text, p_company_name text,
                                                 p_locale text DEFAULT 'fa-IR', p_timezone text DEFAULT 'Asia/Tehran',
                                                 p_deployment text DEFAULT 'saas_shared')
RETURNS TABLE (tenant_id uuid, owner_user_id uuid, company_id uuid, created boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
#variable_conflict use_column
DECLARE v_tenant uuid := core.current_tenant_id(); pr core.tenant_provisioning; v_user uuid; v_company uuid;
        v_member uuid; v_role uuid; t record;
BEGIN
  IF v_tenant IS NULL OR core.current_user_id() IS NOT NULL THEN
    PERFORM core.raise_hk('HK_CORE_SYSTEM_ONLY', 'provisioning runs in the system UnitOfWork of the new tenant');
  END IF;
  SELECT * INTO pr FROM core.tenant_provisioning x WHERE x.command_id = p_command_id;
  IF FOUND THEN
    tenant_id := pr.tenant_id; owner_user_id := pr.owner_user_id; company_id := pr.company_id; created := false;
    RETURN NEXT; RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM core.tenant x WHERE x.id = v_tenant) THEN
    PERFORM core.raise_hk('HK_CORE_TENANT_EXISTS', 'tenant already exists without this provisioning command');
  END IF;
  INSERT INTO core.tenant (id, slug, display_name, status, deployment, locale, timezone)
  VALUES (v_tenant, p_slug, core.fa_normalize_text(p_display_name), 'provisioning', p_deployment, p_locale, p_timezone);
  INSERT INTO core.company (tenant_id, code, name) VALUES (v_tenant, p_company_code, core.fa_normalize_text(p_company_name))
  RETURNING id INTO v_company;
  INSERT INTO core.branch (tenant_id, company_id, code, name) VALUES (v_tenant, v_company, 'main', 'شعبهٔ مرکزی');
  SELECT i.user_id INTO v_user FROM core.user_login_identifier i
   WHERE i.kind = 'phone' AND i.value = p_owner_mobile AND i.verified_at IS NOT NULL;
  IF v_user IS NULL THEN
    INSERT INTO core.app_user (kind, display_name, created_via) VALUES ('human', core.fa_normalize_text(p_owner_name), 'provisioning')
    RETURNING id INTO v_user;
    INSERT INTO core.user_login_identifier (user_id, kind, value, verified_at, is_primary) VALUES (v_user, 'phone', p_owner_mobile, now(), true);
  END IF;
  INSERT INTO core.tenant_membership (tenant_id, user_id, status, is_owner, joined_at)
  VALUES (v_tenant, v_user, 'active', true, now()) RETURNING id INTO v_member;
  PERFORM set_config('app.system_role_sync', 'on', true);
  FOR t IN SELECT * FROM core.role_template rt WHERE NOT rt.for_service ORDER BY rt.code LOOP
    INSERT INTO core.role (tenant_id, code, name, template_code, is_system, grants_all)
    VALUES (v_tenant, t.code, t.code, t.code, true, t.grants_all) RETURNING id INTO v_role;
    INSERT INTO core.role_permission (tenant_id, role_id, permission_code)
    SELECT v_tenant, v_role, tp.permission_code FROM core.role_template_permission tp WHERE tp.template_code = t.code;
    IF t.code = 'owner' THEN
      INSERT INTO core.role_assignment (tenant_id, membership_id, role_id) VALUES (v_tenant, v_member, v_role);
    END IF;
  END LOOP;
  PERFORM set_config('app.system_role_sync', '', true);
  INSERT INTO core.tenant_provisioning (tenant_id, command_id, owner_user_id, company_id)
  VALUES (v_tenant, p_command_id, v_user, v_company);
  tenant_id := v_tenant; owner_user_id := v_user; company_id := v_company; created := true;
  RETURN NEXT;
END $$;

-- ---------- قالب چاپ و سربرگ (RV-X3-05؛ پژوهش ۰۶ V1-17، ۰۳ §۲-۱۸) ----------
-- مدل چاپ نوع‌دار را هر ماژول منتشر می‌کند (فاکتور فروش: sales، رسید: pos، برچسب: catalog، کارت گارانتی: inventory،
-- صورت‌حساب شخص: treasury، چک: treasury)؛ هسته رجیستری، نسخه‌ها و موتور رندر امن (HTML/CSS بی‌اسکریپت) را دارد.
CREATE TABLE IF NOT EXISTS core.print_model (
  code             text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){1,3}$'),
  module           text NOT NULL,
  schema_version   integer NOT NULL CHECK (schema_version >= 1),
  json_schema      jsonb NOT NULL CHECK (jsonb_typeof(json_schema) = 'object'),
  allowed_papers   text[] NOT NULL CHECK (cardinality(allowed_papers) >= 1
                     AND allowed_papers <@ ARRAY['a4','a4_landscape','a5','receipt_80','receipt_58','label','card']::text[]),
  read_permission  text NOT NULL REFERENCES core.permission(code),
  description_key  text NOT NULL,
  CHECK (split_part(code, '.', 1) = module)
);

-- قالب سامانه‌ای (همراه کد یا بستهٔ قواعد). is_official = چیدمان رسمی (مثلاً صورتحساب الکترونیکی پیوست ۸ با نسخهٔ
-- دستورالعمل از پارامتر قواعد rules_param_key) که مستأجر بازنویسی نمی‌کند.
CREATE TABLE IF NOT EXISTS core.print_template_def (
  code             text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){1,4}$'),
  model_code       text NOT NULL REFERENCES core.print_model(code),
  paper            text NOT NULL CHECK (paper IN ('a4','a4_landscape','a5','receipt_80','receipt_58','label','card')),
  engine           text NOT NULL DEFAULT 'html_v1' CHECK (engine IN ('html_v1')),
  body             text NOT NULL CHECK (char_length(body) BETWEEN 1 AND 200000),
  is_official      boolean NOT NULL DEFAULT false,
  rules_param_key  text,
  introduced_in    text NOT NULL,
  CHECK (NOT is_official OR rules_param_key IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS core.print_template (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  company_id       uuid,
  model_code       text NOT NULL REFERENCES core.print_model(code),
  code             text NOT NULL CHECK (code ~ '^[a-z0-9][a-z0-9_.-]{0,62}$'),
  name             text NOT NULL CHECK (name = core.fa_normalize_text(name) AND char_length(name) BETWEEN 1 AND 100),
  paper            text NOT NULL CHECK (paper IN ('a4','a4_landscape','a5','receipt_80','receipt_58','label','card')),
  source           text NOT NULL CHECK (source IN ('system','pack','tenant')),
  base_def_code    text REFERENCES core.print_template_def(code),
  current_version  integer,
  is_default       boolean NOT NULL DEFAULT false,
  status           text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','active','archived')),
  created_by       uuid,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  row_version      integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (status <> 'active' OR current_version IS NOT NULL OR base_def_code IS NOT NULL),
  CHECK (source <> 'system' OR base_def_code IS NOT NULL)
);
SELECT core.enable_tenant_rls('core.print_template');
CREATE UNIQUE INDEX IF NOT EXISTS print_template_code_uniq ON core.print_template (tenant_id, company_id, code) NULLS NOT DISTINCT;
CREATE UNIQUE INDEX IF NOT EXISTS print_template_one_default ON core.print_template (tenant_id, company_id, model_code, paper)
  NULLS NOT DISTINCT WHERE is_default AND status = 'active';

-- نسخه‌های قالب (فقط‌افزودنی؛ شمارهٔ نسخه پیوسته)
CREATE TABLE IF NOT EXISTS core.print_template_version (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  template_id   uuid NOT NULL,
  version_no    integer NOT NULL CHECK (version_no >= 1),
  engine        text NOT NULL DEFAULT 'html_v1' CHECK (engine IN ('html_v1')),
  body          text NOT NULL CHECK (char_length(body) BETWEEN 1 AND 200000),
  body_sha256   bytea NOT NULL CHECK (octet_length(body_sha256) = 32),
  created_by    uuid,
  created_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, template_id, version_no),
  FOREIGN KEY (tenant_id, template_id) REFERENCES core.print_template(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id)
);
SELECT core.enable_tenant_rls('core.print_template_version');

-- سربرگ فروشنده (بلوک اجباری صورتحساب رسمی: نشانی، کد پستی، تلفن، شمارهٔ ثبت، لوگو) برای شرکت یا شعبه
CREATE TABLE IF NOT EXISTS core.letterhead (
  tenant_id           uuid NOT NULL REFERENCES core.tenant(id),
  id                  uuid NOT NULL DEFAULT uuidv7(),
  company_id          uuid NOT NULL,
  branch_id           uuid,
  address             text NOT NULL CHECK (address = core.fa_normalize_text(address) AND char_length(address) BETWEEN 5 AND 500),
  postal_code         text NOT NULL CHECK (postal_code ~ '^[0-9]{10}$'),
  phone               text CHECK (phone IS NULL OR phone ~ '^0[0-9]{9,10}$'),
  registration_no     text CHECK (registration_no IS NULL OR registration_no ~ '^[0-9]{1,12}$'),
  logo_attachment_id  uuid,
  website             text CHECK (website IS NULL OR website ~ '^https?://'),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  row_version         integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, logo_attachment_id) REFERENCES core.attachment(tenant_id, id)
);
SELECT core.enable_tenant_rls('core.letterhead');
CREATE UNIQUE INDEX IF NOT EXISTS letterhead_scope_uniq ON core.letterhead (tenant_id, company_id, branch_id) NULLS NOT DISTINCT;

CREATE OR REPLACE FUNCTION core.print_template_version_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE t core.print_template; v_official boolean;
BEGIN
  SELECT * INTO t FROM core.print_template x WHERE x.tenant_id = NEW.tenant_id AND x.id = NEW.template_id FOR UPDATE;
  SELECT d.is_official INTO v_official FROM core.print_template_def d WHERE d.code = t.base_def_code;
  IF coalesce(v_official, false) THEN
    PERFORM core.raise_hk('HK_PRINT_OFFICIAL', 'the official layout is versioned by the rules engine, not by tenants');
  END IF;
  IF NEW.version_no <> coalesce((SELECT max(v.version_no) FROM core.print_template_version v
                                  WHERE v.tenant_id = NEW.tenant_id AND v.template_id = NEW.template_id), 0) + 1 THEN
    PERFORM core.raise_hk('HK_PRINT_VERSION', 'template versions are numbered 1..n without gaps');
  END IF;
  NEW.body_sha256 := sha256(convert_to(NEW.body, 'UTF8'));
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.print_template_version;
CREATE TRIGGER trg_guard BEFORE INSERT ON core.print_template_version FOR EACH ROW EXECUTE FUNCTION core.print_template_version_guard();

CREATE OR REPLACE FUNCTION core.print_template_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND (NEW.model_code, NEW.source, NEW.base_def_code, NEW.paper)
                          IS DISTINCT FROM (OLD.model_code, OLD.source, OLD.base_def_code, OLD.paper) THEN
    PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'print template model, source and paper are immutable');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM core.print_model m WHERE m.code = NEW.model_code AND NEW.paper = ANY (m.allowed_papers)) THEN
    PERFORM core.raise_hk('HK_PRINT_PAPER', format('paper %s is not allowed for %s', NEW.paper, NEW.model_code));
  END IF;
  IF NEW.base_def_code IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.print_template_def d
                                                    WHERE d.code = NEW.base_def_code AND d.model_code = NEW.model_code) THEN
    PERFORM core.raise_hk('HK_PRINT_MODEL', 'base template belongs to another print model');
  END IF;
  IF NEW.current_version IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.print_template_version v
        WHERE v.tenant_id = NEW.tenant_id AND v.template_id = NEW.id AND v.version_no = NEW.current_version) THEN
    PERFORM core.raise_hk('HK_PRINT_VERSION', 'current_version must be an existing version');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.print_template;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON core.print_template FOR EACH ROW EXECUTE FUNCTION core.print_template_guard();

-- ---------- راستی‌آزمایی درون‌ریزی .hkx پیش از COMMIT (RV-X4-01؛ R-IMPORT) ----------
-- اجرا با hk_migrator در همان تراکنش replica و با app.tenant_id = مقصد. درون‌ریز tenant_id هر ردیف را از مانیفست
-- **بازنویسی** می‌کند؛ این تابع لایهٔ دوم است و هر ناسازگاری را برمی‌گرداند (خروجی خالی = سالم):
--   foreign_tenant_row: ردیفی که همین تراکنش با tenant_id دیگر نوشته است (xmin)؛
--   dangling_fk: هر FK از ردیف‌های مستأجر مقصد که ردیف مقصد ندارد (FKها در replica بررسی نشده‌اند)؛
--   audit:<problem>، number_gap، security_lint:<problem>.
-- قلاب‌های هر ماژول (ledger، inventory، tax، …؛ R-IMPORT) پس از این و پیش از COMMIT اجرا می‌شوند.
CREATE OR REPLACE FUNCTION core.import_verify(p_tenant uuid) RETURNS TABLE (object text, problem text)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE t record; n bigint; v_cond text; v_join text;
BEGIN
  IF NOT core.privileged_context() THEN
    PERFORM core.raise_hk('HK_CORE_PRIVILEGED_ONLY', 'import_verify runs inside the migrator import transaction');
  END IF;
  IF core.current_tenant_id() IS DISTINCT FROM p_tenant THEN
    PERFORM core.raise_hk('HK_TENANT_CONTEXT_MISSING', 'set app.tenant_id to the imported tenant');
  END IF;
  FOR t IN SELECT c.oid::regclass AS rel
             FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace ns ON ns.oid = c.relnamespace
             JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
            WHERE c.relkind = 'r' AND ns.nspname IN (SELECT s.nspname FROM core.data_plane_schemas() s)
  LOOP
    EXECUTE format('SELECT count(*) FROM %s x WHERE x.xmin = pg_catalog.xid(pg_catalog.pg_current_xact_id()) '
                   'AND x.tenant_id IS DISTINCT FROM $1', t.rel) INTO n USING p_tenant;
    IF n > 0 THEN object := t.rel::text; problem := 'foreign_tenant_row:' || n; RETURN NEXT; END IF;
  END LOOP;
  FOR t IN SELECT con.oid, con.conrelid::regclass AS src, con.confrelid::regclass AS dst, con.conname,
                  (SELECT array_agg(a.attname ORDER BY k.i) FROM unnest(con.conkey) WITH ORDINALITY k(attnum, i)
                     JOIN pg_catalog.pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum) AS scols,
                  (SELECT array_agg(a.attname ORDER BY k.i) FROM unnest(con.confkey) WITH ORDINALITY k(attnum, i)
                     JOIN pg_catalog.pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum) AS dcols
             FROM pg_catalog.pg_constraint con
             JOIN pg_catalog.pg_class c ON c.oid = con.conrelid AND c.relkind = 'r'
             JOIN pg_catalog.pg_namespace ns ON ns.oid = c.relnamespace
            WHERE con.contype = 'f' AND con.conparentid = 0
              AND ns.nspname IN (SELECT s.nspname FROM core.data_plane_schemas() s)
              AND EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a WHERE a.attrelid = con.conrelid AND a.attname = 'tenant_id' AND NOT a.attisdropped)
  LOOP
    SELECT string_agg(format('s.%I IS NOT NULL', c), ' AND '), string_agg(format('d.%I = s.%I', dc, c), ' AND ')
      INTO v_cond, v_join FROM unnest(t.scols, t.dcols) u(c, dc);
    EXECUTE format('SELECT count(*) FROM %s s WHERE s.tenant_id = $1 AND %s AND NOT EXISTS (SELECT 1 FROM %s d WHERE %s)',
                   t.src, v_cond, t.dst, v_join) INTO n USING p_tenant;
    IF n > 0 THEN object := t.src::text || ' / ' || t.conname; problem := 'dangling_fk:' || n; RETURN NEXT; END IF;
  END LOOP;
  FOR t IN SELECT v.seq, v.problem FROM core.audit_verify(0::smallint) v LOOP
    object := 'core.audit_log seq ' || t.seq; problem := 'audit:' || t.problem; RETURN NEXT;
  END LOOP;
  FOR t IN SELECT s.id, c.period_key FROM core.number_series s
             JOIN core.number_counter c ON c.tenant_id = s.tenant_id AND c.series_id = s.id
            WHERE s.tenant_id = p_tenant AND s.allocation = 'server'
  LOOP
    IF EXISTS (SELECT 1 FROM core.number_gap_ranges(t.id, t.period_key)) THEN
      object := 'core.number_series ' || t.id || ' ' || t.period_key; problem := 'number_gap'; RETURN NEXT;
    END IF;
  END LOOP;
  FOR t IN SELECT l.object AS o, l.problem AS p FROM core.security_lint() l LOOP
    object := t.o; problem := 'security_lint:' || t.p; RETURN NEXT;
  END LOOP;
END $$;

-- ---------- پاک‌سازی نهایی مستأجر (RV-CORE-17؛ §۵.۱۶ بند ۴) ----------
-- فقط ابزار نگهداری (hk_migrator، session_replication_role = replica، پس از تأیید دونفرهٔ پنل). همهٔ ردیف‌های مستأجر
-- در همهٔ جدول‌های دارای tenant_id، سپس دادهٔ سطح کاربرِ وابسته: حساب‌های سرویس خانهٔ همین مستأجر (با شناسه، اعتبارنامه،
-- کد بازیابی، نشست، OTP و رخداد امنیتی)، نشست‌های با active_tenant_id همین مستأجر، و هویت انسان‌هایی که دیگر هیچ
-- عضویتی ندارند (بی‌نام‌سازی). در پایان هر FK به مستأجر یا کاربران حذف‌شده با anti-join بررسی و در صورت ارجاع آویزان
-- خطا داده می‌شود (ROLLBACK کل پاک‌سازی).
CREATE OR REPLACE FUNCTION core.purge_tenant(p_tenant uuid, p_confirm_slug text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_slug text; t record; n bigint; v_rows bigint := 0; v_service uuid[]; v_members uuid[]; v_orphans uuid[];
        v_cond text; v_bad text := NULL;
BEGIN
  IF NOT core.privileged_context() OR current_user = 'hk_core_definer' THEN
    PERFORM core.raise_hk('HK_CORE_PRIVILEGED_ONLY', 'tenant purge runs only in the maintenance tool (hk_migrator)');
  END IF;
  IF current_setting('session_replication_role') <> 'replica' THEN
    PERFORM core.raise_hk('HK_CORE_PURGE_MODE', 'tenant purge needs session_replication_role = replica');
  END IF;
  SELECT x.slug INTO v_slug FROM core.tenant x WHERE x.id = p_tenant;
  IF v_slug IS NULL OR v_slug <> p_confirm_slug THEN
    PERFORM core.raise_hk('HK_CORE_PURGE_CONFIRM', 'tenant id and slug do not match');
  END IF;
  v_service := ARRAY(SELECT u.id FROM core.app_user u WHERE u.home_tenant_id = p_tenant);
  v_members := ARRAY(SELECT m.user_id FROM core.tenant_membership m WHERE m.tenant_id = p_tenant);
  FOR t IN SELECT c.oid::regclass AS rel
             FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace ns ON ns.oid = c.relnamespace
             JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
            WHERE c.relkind = 'r' AND ns.nspname IN (SELECT s.nspname FROM core.data_plane_schemas() s)
  LOOP
    EXECUTE format('DELETE FROM %s WHERE tenant_id = $1', t.rel) USING p_tenant;
    GET DIAGNOSTICS n = ROW_COUNT; v_rows := v_rows + n;
  END LOOP;
  v_orphans := ARRAY(SELECT u.id FROM core.app_user u
                      WHERE u.id = ANY (v_members) AND u.kind = 'human'
                        AND NOT EXISTS (SELECT 1 FROM core.tenant_membership m WHERE m.user_id = u.id));
  DELETE FROM core.user_session s WHERE s.active_tenant_id = p_tenant OR s.user_id = ANY (v_service || v_orphans);
  DELETE FROM core.otp_challenge o WHERE o.user_id = ANY (v_service || v_orphans);
  DELETE FROM core.user_recovery_code r WHERE r.user_id = ANY (v_service || v_orphans);
  DELETE FROM core.user_credential c WHERE c.user_id = ANY (v_service || v_orphans);
  DELETE FROM core.user_login_identifier i WHERE i.user_id = ANY (v_service || v_orphans);
  DELETE FROM core.auth_event e WHERE e.context_tenant_id = p_tenant OR e.user_id = ANY (v_service);
  DELETE FROM core.app_user u WHERE u.id = ANY (v_service);
  UPDATE core.app_user u SET status = 'anonymized', display_name = 'کاربر حذف‌شده', mfa_required = false,
                             security_epoch = u.security_epoch + 1
   WHERE u.id = ANY (v_orphans);
  DELETE FROM core.tenant x WHERE x.id = p_tenant;
  -- هیچ ارجاع آویزان به مستأجر یا حساب‌های سرویس حذف‌شده نماند
  FOR t IN SELECT con.conrelid::regclass AS src, con.conname, con.confrelid AS dst,
                  (SELECT array_agg(a.attname ORDER BY k.i) FROM unnest(con.conkey) WITH ORDINALITY k(attnum, i)
                     JOIN pg_catalog.pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum) AS scols
             FROM pg_catalog.pg_constraint con
            WHERE con.contype = 'f' AND con.conparentid = 0
              AND con.confrelid IN ('core.tenant'::regclass, 'core.app_user'::regclass) AND cardinality(con.conkey) = 1
  LOOP
    EXECUTE format('SELECT count(*) FROM %s s WHERE s.%I = ANY ($1)', t.src, t.scols[1])
      INTO n USING CASE WHEN t.dst = 'core.tenant'::regclass THEN ARRAY[p_tenant] ELSE v_service END;
    IF n > 0 THEN v_bad := concat_ws(', ', v_bad, t.src::text || '.' || t.scols[1] || '=' || n); END IF;
  END LOOP;
  IF v_bad IS NOT NULL THEN
    PERFORM core.raise_hk('HK_CORE_PURGE_DANGLING', 'dangling references after purge: ' || v_bad);
  END IF;
  RETURN jsonb_build_object('tenant_rows', v_rows, 'service_accounts', cardinality(v_service), 'anonymized_users', cardinality(v_orphans));
END $$;

-- =====================================================================
-- ۲۰. زمان‌بند، پاک‌سازی (اجرا با hk_dispatcher؛ SECURITY INVOKER) و حل توکن (SECURITY DEFINER)
-- =====================================================================
-- زمان‌بندی‌های سررسیده (قفل SKIP LOCKED تا پایان تراکنش زمان‌بند)
CREATE OR REPLACE FUNCTION core.schedule_due(p_limit integer DEFAULT 100) RETURNS SETOF core.job_schedule
LANGUAGE sql AS $$
  SELECT * FROM core.job_schedule WHERE is_enabled AND next_fire_at <= now()
   ORDER BY next_fire_at LIMIT p_limit FOR UPDATE SKIP LOCKED
$$;

-- یک نوبت: job با dedupe_key = '<schedule_id>:<fire_at به UTC با میکروثانیه>' (قرارداد ۰۱)، سپس پیشبرد next_fire_at.
-- p_fire = false وقتی jalali_filter با روز نوبت نمی‌خواند (پایتون تعیین می‌کند): فقط پیشبرد.
-- RV-CORE-11: نوبت فقط همان next_fire_at ردیف است و next_fire_at فقط جلو می‌رود؛ پس هر زمان نوبت دقیقاً یک بار
-- (حتی با چند زمان‌بند و TimeZone متفاوت نشست) و کلید dedupe مستقل از TimeZone است.
CREATE OR REPLACE FUNCTION core.schedule_fire(p_schedule_id uuid, p_fire_at timestamptz, p_next_fire_at timestamptz,
                                              p_fire boolean DEFAULT true)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE s core.job_schedule; jid uuid;
BEGIN
  SELECT * INTO s FROM core.job_schedule WHERE id = p_schedule_id FOR UPDATE;
  IF NOT FOUND THEN PERFORM core.raise_hk('HK_SCHEDULE_NOT_FOUND', 'schedule not found'); END IF;
  IF p_fire_at IS DISTINCT FROM s.next_fire_at THEN
    PERFORM core.raise_hk('HK_SCHEDULE_FIRE_MISMATCH', 'fire time must equal the schedule next_fire_at');
  END IF;
  IF p_next_fire_at IS NULL OR p_next_fire_at <= p_fire_at THEN
    PERFORM core.raise_hk('HK_SCHEDULE_NEXT', 'next_fire_at must be after the fire time');
  END IF;
  IF p_fire THEN
    INSERT INTO core.job (tenant_id, queue, kind, payload, run_after, dedupe_key, max_attempts, schedule_id, created_by)
    VALUES (s.tenant_id, s.queue, s.kind, s.payload || jsonb_build_object('scheduled_for', p_fire_at), p_fire_at,
            core.schedule_dedupe_key(s.id, p_fire_at), s.max_attempts, s.id, s.created_by)
    ON CONFLICT DO NOTHING
    RETURNING id INTO jid;
    UPDATE core.job_schedule SET last_fired_at = p_fire_at WHERE id = s.id;
  END IF;
  UPDATE core.job_schedule SET next_fire_at = p_next_fire_at WHERE id = s.id;
  RETURN jid;
END $$;

CREATE OR REPLACE FUNCTION core.schedule_dedupe_key(p_schedule_id uuid, p_fire_at timestamptz) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT p_schedule_id::text || ':' || to_char(p_fire_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
$$;

-- زمان‌بند: next_fire_at فقط جلو؛ last_fired_at یکنوا (دفاع لایهٔ دوم برای هر مسیر نوشتن)
CREATE OR REPLACE FUNCTION core.job_schedule_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.tenant_id <> OLD.tenant_id OR NEW.id <> OLD.id THEN
    PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'schedule identity is immutable');
  END IF;
  IF NEW.last_fired_at IS DISTINCT FROM OLD.last_fired_at
     AND (NEW.last_fired_at IS NULL OR (OLD.last_fired_at IS NOT NULL AND NEW.last_fired_at <= OLD.last_fired_at)) THEN
    PERFORM core.raise_hk('HK_SCHEDULE_NEXT', 'last_fired_at only moves forward');
  END IF;
  -- عقب بردن next_fire_at فقط هنگام ویرایش cron/منطقهٔ زمانی (برنامه‌ریزی دوباره) و نه پیش از آخرین نوبت
  IF NEW.next_fire_at < OLD.next_fire_at
     AND ((NEW.cron, NEW.timezone) IS NOT DISTINCT FROM (OLD.cron, OLD.timezone)
          OR (NEW.last_fired_at IS NOT NULL AND NEW.next_fire_at <= NEW.last_fired_at)) THEN
    PERFORM core.raise_hk('HK_SCHEDULE_NEXT', 'next_fire_at only moves forward');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.job_schedule;
CREATE TRIGGER trg_guard BEFORE UPDATE ON core.job_schedule FOR EACH ROW EXECUTE FUNCTION core.job_schedule_guard();

-- نگهداری (RV-CORE-12): توقیف قانونی فعال سطح مستأجر/شرکت هر پاک‌سازی دادهٔ آن مستأجر را متوقف می‌کند؛ دوره =
-- override مستأجر یا پیش‌فرض کلاس (override ≥ حداقل کلاس با retention_override_guard).
CREATE OR REPLACE FUNCTION core.purge_on_hold(p_tenant uuid) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT p_tenant IS NOT NULL AND EXISTS (SELECT 1 FROM core.legal_hold h
           WHERE h.tenant_id = p_tenant AND h.released_at IS NULL AND h.scope IN ('tenant','company'))
$$;
CREATE OR REPLACE FUNCTION core.retention_period(p_tenant uuid, p_class text) RETURNS interval
LANGUAGE sql STABLE AS $$
  SELECT coalesce((SELECT o.period FROM core.retention_override o WHERE o.tenant_id = p_tenant AND o.class_code = p_class),
                  (SELECT c.default_period FROM core.retention_class c WHERE c.code = p_class))
$$;

-- پاک‌سازی دوره‌ای دادهٔ گذرا (همهٔ مستأجرها؛ کار سیستمی maintenance.purge_ephemeral؛ hk_dispatcher).
-- پیش‌فیلتر «قدیمی‌تر از حداقل کلاس» نمایه‌پذیر است؛ دورهٔ دقیق هر مستأجر و توقیف سپس برای هر نامزد سنجیده می‌شود.
-- ترتیب (RV-CORE-13): تحویل‌های webhook پایان‌یافته ← تحویل‌های done ← رویدادهای بی‌تحویل.
CREATE OR REPLACE FUNCTION core.purge_ephemeral(p_limit integer DEFAULT 5000) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE r jsonb := '{}'; n integer;
        v_min_job interval; v_min_fail interval; v_min_outbox interval; v_min_tech interval;
BEGIN
  SELECT min_period INTO v_min_job    FROM core.retention_class WHERE code = 'job_finished';
  SELECT min_period INTO v_min_fail   FROM core.retention_class WHERE code = 'job_failed';
  SELECT min_period INTO v_min_outbox FROM core.retention_class WHERE code = 'outbox';
  SELECT min_period INTO v_min_tech   FROM core.retention_class WHERE code = 'technical_log';
  DELETE FROM core.idempotency_key WHERE id IN (
    SELECT k.id FROM core.idempotency_key k WHERE k.expires_at < now() AND NOT core.purge_on_hold(k.tenant_id) LIMIT p_limit);
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('idempotency_key', n);
  DELETE FROM core.job WHERE id IN (
    SELECT j.id FROM core.job j
     WHERE ((j.status = 'succeeded' AND j.finished_at < now() - v_min_job
             AND j.finished_at < now() - core.retention_period(j.tenant_id, 'job_finished'))
         OR (j.status IN ('failed','dead','cancelled') AND j.finished_at < now() - v_min_fail
             AND j.finished_at < now() - core.retention_period(j.tenant_id, 'job_failed')))
       AND NOT core.purge_on_hold(j.tenant_id)
     LIMIT p_limit);
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('job', n);
  DELETE FROM core.webhook_delivery WHERE id IN (
    SELECT w.id FROM core.webhook_delivery w
     WHERE w.status IN ('succeeded','dead') AND w.created_at < now() - v_min_outbox
       AND w.created_at < now() - core.retention_period(w.tenant_id, 'outbox')
       AND NOT core.purge_on_hold(w.tenant_id)
     LIMIT p_limit);
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('webhook_delivery', n);
  DELETE FROM core.outbox_delivery WHERE (tenant_id, event_id, subscriber) IN (
    SELECT d.tenant_id, d.event_id, d.subscriber FROM core.outbox_delivery d
     WHERE d.status = 'done' AND d.done_at < now() - v_min_outbox
       AND d.done_at < now() - core.retention_period(d.tenant_id, 'outbox')
       AND NOT core.purge_on_hold(d.tenant_id)
     LIMIT p_limit);
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('outbox_delivery', n);
  DELETE FROM core.outbox_event o WHERE o.id IN (
    SELECT x.id FROM core.outbox_event x
     WHERE x.occurred_at < now() - v_min_outbox
       AND x.occurred_at < now() - core.retention_period(x.tenant_id, 'outbox')
       AND NOT core.purge_on_hold(x.tenant_id)
       AND NOT EXISTS (SELECT 1 FROM core.outbox_delivery d WHERE d.tenant_id = x.tenant_id AND d.event_id = x.id)
       AND NOT EXISTS (SELECT 1 FROM core.webhook_delivery w WHERE w.tenant_id = x.tenant_id AND w.event_id = x.id)
     LIMIT p_limit);
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('outbox_event', n);
  -- OTP و توکن دستگاه «سابقه» نیستند (راز گذرا)؛ توقیف شامل آن‌ها نمی‌شود
  DELETE FROM core.otp_challenge WHERE id IN (SELECT id FROM core.otp_challenge WHERE expires_at < now() - interval '1 day' LIMIT p_limit);
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('otp_challenge', n);
  DELETE FROM core.device_token WHERE id IN (SELECT id FROM core.device_token WHERE expires_at < now() - interval '1 day' LIMIT p_limit);
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('device_token', n);
  DELETE FROM core.auth_event WHERE id IN (
    SELECT e.id FROM core.auth_event e
     WHERE e.occurred_at < now() - v_min_tech
       AND e.occurred_at < now() - coalesce(core.retention_period(e.context_tenant_id, 'technical_log'), interval '365 days')
       AND NOT core.purge_on_hold(e.context_tenant_id)
     LIMIT p_limit);
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('auth_event', n);
  DELETE FROM core.rate_limit_counter WHERE window_start < now() - interval '1 day';
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('rate_limit_counter', n);
  RETURN r;
END $$;

-- ورود: شناسهٔ نرمال‌شده → شناسهٔ کاربر (سرویس زمان پاسخ را یکسان می‌کند). فقط شناسهٔ **تأییدشده** (RV-IT2-07، RV-CORE-25).
CREATE OR REPLACE FUNCTION core.auth_resolve_login(p_kind text, p_value text) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT i.user_id FROM core.user_login_identifier i JOIN core.app_user u ON u.id = i.user_id
   WHERE i.kind = p_kind AND i.value = p_value AND i.verified_at IS NOT NULL
     AND u.status = 'active' AND u.kind = 'human'
$$;

-- کلید API: پیشوند عمومی → (مستأجر، کلید)؛ مقایسهٔ hash راز با RLS عادی در سرویس. صاحب کلید فعال و عضو فعال است.
CREATE OR REPLACE FUNCTION core.auth_resolve_api_key(p_prefix text)
RETURNS TABLE (tenant_id uuid, api_key_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT k.tenant_id, k.id FROM core.api_key k
    JOIN core.app_user u ON u.id = k.user_id AND u.status = 'active'
    JOIN core.tenant_membership m ON m.tenant_id = k.tenant_id AND m.user_id = k.user_id AND m.status = 'active'
   WHERE k.prefix = p_prefix AND k.revoked_at IS NULL AND k.expires_at > now()
$$;

-- توکن کدر (کوکی نشست، توکن دستگاه، توکن ورود به‌جای کاربر): sha256(token) → شناسه‌ها.
-- فقط شناسه برمی‌گرداند؛ سرویس سپس app.user_id/app.tenant_id را می‌گذارد و ردیف را با RLS عادی می‌خواند.
-- نشست (RV-CORE-02): کاربر active و security_epoch برابر نسخهٔ نشست؛ نشست دستگاه‌دار فقط با دستگاه active و عضویت
-- active؛ مستأجر فقط اگر عضویت active باشد برگردانده می‌شود (وگرنه NULL: نشست برای /me و تغییر مستأجر زنده است).
CREATE OR REPLACE FUNCTION core.auth_resolve_token(p_kind text, p_token_hash bytea)
RETURNS TABLE (ref_id uuid, user_id uuid, tenant_id uuid, expires_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT s.id, s.user_id, CASE WHEN m.status = 'active' THEN s.active_tenant_id END,
         least(s.absolute_expires_at, s.last_seen_at + make_interval(secs => s.idle_timeout_seconds))
    FROM core.user_session s
    JOIN core.app_user u ON u.id = s.user_id AND u.status = 'active' AND u.security_epoch = s.security_epoch
    LEFT JOIN core.tenant_membership m ON m.tenant_id = s.active_tenant_id AND m.user_id = s.user_id
    LEFT JOIN core.device d ON d.tenant_id = s.active_tenant_id AND d.id = s.device_id
   WHERE p_kind = 'session' AND s.token_hash = p_token_hash AND s.revoked_at IS NULL
     AND s.absolute_expires_at > now() AND s.last_seen_at + make_interval(secs => s.idle_timeout_seconds) > now()
     AND (s.device_id IS NULL OR (d.status = 'active' AND m.status = 'active'))
  UNION ALL
  SELECT t.device_id, NULL::uuid, t.tenant_id, t.expires_at
    FROM core.device_token t JOIN core.device d ON d.tenant_id = t.tenant_id AND d.id = t.device_id
   WHERE p_kind = 'device' AND t.token_hash = p_token_hash AND t.revoked_at IS NULL AND t.expires_at > now()
     AND d.status = 'active'
  UNION ALL
  SELECT i.id, i.target_user_id, i.tenant_id, i.expires_at
    FROM core.impersonation_session i
   WHERE p_kind = 'impersonation' AND i.token_hash = p_token_hash AND i.ended_at IS NULL AND i.expires_at > now()
$$;

-- دعوت عضو (definer؛ RV-IT2-07/RV-CORE-01/RV-CORE-04): تنها راه ساختن کاربر و شناسهٔ ورود برای «دیگری».
-- شناسهٔ تأییدشدهٔ موجود ← همان کاربر؛ وگرنه کاربر «سایه»ی قبلی همین شناسه (ساختهٔ دعوت، بدون شناسهٔ تأییدشده)؛
-- وگرنه کاربر انسانی تازه با شناسهٔ **تأییدنشده**. عضویت همیشه invited است؛ هیچ داده‌ای از کاربر برنمی‌گردد.
CREATE OR REPLACE FUNCTION core.member_invite(p_kind text, p_value text, p_display_name text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_tenant uuid := core.current_tenant_id(); v_inviter uuid := core.current_user_id();
        v_user uuid; m core.tenant_membership;
BEGIN
  IF v_tenant IS NULL OR v_inviter IS NULL THEN
    PERFORM core.raise_hk('HK_TENANT_CONTEXT_MISSING', 'member_invite needs app.tenant_id and app.user_id');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM core.tenant_membership x
                  WHERE x.tenant_id = v_tenant AND x.user_id = v_inviter AND x.status = 'active') THEN
    PERFORM core.raise_hk('HK_CORE_NOT_MEMBER', 'the inviter is not an active member of this tenant');
  END IF;
  SELECT i.user_id INTO v_user FROM core.user_login_identifier i
   WHERE i.kind = p_kind AND i.value = p_value AND i.verified_at IS NOT NULL;
  IF v_user IS NULL THEN
    SELECT i.user_id INTO v_user FROM core.user_login_identifier i JOIN core.app_user u ON u.id = i.user_id
     WHERE i.kind = p_kind AND i.value = p_value AND i.verified_at IS NULL
       AND u.created_via = 'invitation' AND u.status = 'active'
       AND NOT EXISTS (SELECT 1 FROM core.user_login_identifier v WHERE v.user_id = u.id AND v.verified_at IS NOT NULL)
     ORDER BY u.created_at LIMIT 1;
  END IF;
  IF v_user IS NULL THEN
    INSERT INTO core.app_user (kind, display_name, created_via)
    VALUES ('human', core.fa_normalize_text(p_display_name), 'invitation') RETURNING id INTO v_user;
    INSERT INTO core.user_login_identifier (user_id, kind, value) VALUES (v_user, p_kind, p_value);
  END IF;
  SELECT * INTO m FROM core.tenant_membership x WHERE x.tenant_id = v_tenant AND x.user_id = v_user FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO core.tenant_membership (tenant_id, user_id, status, invited_by)
    VALUES (v_tenant, v_user, 'invited', v_inviter) RETURNING * INTO m;
  ELSIF m.status = 'removed' THEN
    UPDATE core.tenant_membership SET status = 'invited', invited_by = v_inviter WHERE id = m.id RETURNING * INTO m;
  END IF;
  RETURN m.id;
END $$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['core.auth_resolve_login(text,text)', 'core.auth_resolve_api_key(text)',
                           'core.auth_resolve_token(text,bytea)']
  LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO hk_core_definer', f);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO hk_app', f);
    EXECUTE format('COMMENT ON FUNCTION %s IS %L', f,
      'HK_DEFINER_REVIEWED: 2026-11-18 section 02; returns identifiers only, fixed search_path, no dynamic SQL');
  END LOOP;
  -- توابع definer نوشتنی هسته (هر کدام فقط ستون‌ها/ردیف‌های مستأجر جاری را با RLS عادی می‌نویسد)
  FOREACH f IN ARRAY ARRAY['core.device_revoke_sessions()',
                           'core.member_invite(text,text,text)',
                           'core.number_next(uuid,text,text,text,uuid)', 'core.number_reserve_range(uuid,text,uuid,integer)',
                           'core.number_record_external(uuid,text,bigint,text,text,uuid,uuid,uuid)',
                           'core.number_void_range(uuid,text,bigint,bigint,text)', 'core.number_void(uuid,text,bigint,text)',
                           'core.number_close_reservation(uuid,text)',
                           'core.apply_desired_state(text,bytea,text)',
                           'core.provision_tenant(uuid,text,text,text,text,text,text,text,text,text)']
  LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO hk_core_definer', f);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO hk_app', f);
    EXECUTE format('COMMENT ON FUNCTION %s IS %L', f,
      'HK_DEFINER_REVIEWED: 2026-11-18 section 02; NOBYPASSRLS owner, tenant RLS still applies, fixed search_path, no dynamic SQL');
  END LOOP;
  -- توابع صف و پاک‌سازی فقط برای نقش dispatcher
  FOREACH f IN ARRAY ARRAY['core.job_claim(text[],text,integer,integer,integer)', 'core.job_reap_expired(integer)',
                           'core.outbox_claim(text[],text,integer,integer,integer)', 'core.schedule_due(integer)',
                           'core.schedule_fire(uuid,timestamptz,timestamptz,boolean)', 'core.purge_ephemeral(integer)']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO hk_dispatcher', f);
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION core.audit_seal() FROM PUBLIC;
ALTER FUNCTION core.audit_checkpoint_create(boolean) OWNER TO hk_audit_writer;
REVOKE ALL ON FUNCTION core.audit_checkpoint_create(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.audit_checkpoint_create(boolean) TO hk_app;
COMMENT ON FUNCTION core.audit_checkpoint_create(boolean) IS
  'HK_DEFINER_REVIEWED: 2026-11-18 section 02; NOBYPASSRLS owner hk_audit_writer, writes only audit_checkpoint of app.tenant_id, fixed search_path';

-- =====================================================================
-- ۲۱. بازرسی امنیتی ساختار (اجرا در CI؛ خروجی باید خالی باشد)
-- =====================================================================
-- فهرست اسکیماها و نقش‌ها از کاتالوگ می‌آید، نه فهرست ثابت (RV-IT-05): اسکیمای ماژول تازه (مثل assistant) و هر
-- نقش hk_% زمان اجرا (جز hk_migrator) خودکار پوشش می‌گیرد. افزوده‌های RV-ARCH-09: امتیاز hk_dispatcher فقط روی
-- جدول‌های صف و کاتالوگ (هرگز webhook_endpoint یا جدول تجاری)، بدون ستون راز؛ hk_app بدون UPDATE روی
-- core.tenant(status, slug, deployment).
CREATE OR REPLACE FUNCTION core.security_lint() RETURNS TABLE (object text, problem text)
LANGUAGE sql STABLE AS $$
WITH app_schemas AS (
  SELECT nspname FROM core.data_plane_schemas()
), tenant_tables AS (
  SELECT c.oid, c.oid::regclass::text AS name, c.relrowsecurity, c.relforcerowsecurity, n.nspname, c.relname
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN app_schemas s ON s.nspname = n.nspname
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
   WHERE c.relkind IN ('r','p')
), runtime_roles AS (
  SELECT r.oid, r.rolname, r.rolsuper, r.rolbypassrls, r.rolcreaterole, r.rolcreatedb FROM pg_roles r
   WHERE r.rolname LIKE 'hk\_%' AND r.rolname <> 'hk_migrator' AND r.rolname NOT LIKE 'hk\_platform\_%'
), dispatcher_allow(rel) AS (
  SELECT to_regclass(x) FROM unnest(ARRAY[
    'core.job','core.job_schedule','core.job_tenant_state','core.outbox_delivery','core.outbox_event','core.idempotency_key',
    'core.webhook_delivery','core.auth_event','core.otp_challenge','core.device_token','core.rate_limit_counter','core.tenant',
    'core.system_task_run','core.outbox_claim_cursor','core.legal_hold','core.retention_override','core.deployment_info',
    'core.permission','core.role_template','core.role_template_permission','core.field_guard','core.setting_def',
    'core.custom_field_entity','core.event_subscriber','core.event_subscription','core.job_queue','core.notification_category',
    'core.notification_template_def','core.export_table_registry','core.retention_class','core.print_model',
    'core.print_template_def']) x
)
SELECT name, 'rls_not_enabled_or_forced' FROM tenant_tables WHERE NOT relrowsecurity OR NOT relforcerowsecurity
UNION ALL
SELECT name, 'rls_no_policy' FROM tenant_tables t WHERE NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = t.oid)
UNION ALL
SELECT name, 'missing_unique_tenant_id_id' FROM tenant_tables t
 WHERE EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = t.oid AND a.attname = 'id' AND NOT a.attisdropped)
   AND NOT EXISTS (
     SELECT 1 FROM pg_index i
      WHERE i.indrelid = t.oid AND i.indisunique AND i.indnatts = 2
        AND (SELECT array_agg(a.attname::text ORDER BY a.attname)
               FROM pg_attribute a WHERE a.attrelid = t.oid AND a.attnum = ANY (i.indkey)) = ARRAY['id','tenant_id'])
UNION ALL
SELECT con.conrelid::regclass::text || ' / ' || con.conname, 'fk_between_tenant_tables_without_tenant_id'
  FROM pg_constraint con
  JOIN tenant_tables src ON src.oid = con.conrelid
  JOIN tenant_tables dst ON dst.oid = con.confrelid
 WHERE con.contype = 'f'
   AND NOT ((SELECT attnum FROM pg_attribute WHERE attrelid = con.conrelid AND attname = 'tenant_id') = ANY (con.conkey))
UNION ALL
SELECT c.oid::regclass::text, 'view_without_security_invoker'
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace JOIN app_schemas s ON s.nspname = n.nspname
 WHERE c.relkind = 'v'
   AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(c.reloptions, '{}')) o
                    WHERE lower(o) IN ('security_invoker=true','security_invoker=on','security_invoker=1'))
UNION ALL
SELECT c.oid::regclass::text, 'materialized_view_on_tenant_data'
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace JOIN app_schemas s ON s.nspname = n.nspname
 WHERE c.relkind = 'm'
UNION ALL
SELECT p.oid::regprocedure::text, 'security_definer_not_reviewed'
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace JOIN app_schemas s ON s.nspname = n.nspname
 WHERE p.prosecdef AND coalesce(obj_description(p.oid, 'pg_proc'), '') NOT LIKE 'HK_DEFINER_REVIEWED:%'
UNION ALL
SELECT p.oid::regprocedure::text, 'security_definer_without_search_path'
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace JOIN app_schemas s ON s.nspname = n.nspname
 WHERE p.prosecdef AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig, '{}')) c WHERE c LIKE 'search_path=%')
UNION ALL
SELECT p.oid::regprocedure::text, 'security_definer_owned_by_privileged_role'
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace JOIN app_schemas s ON s.nspname = n.nspname
  JOIN pg_roles r ON r.oid = p.proowner
 WHERE p.prosecdef AND (r.rolsuper OR r.rolbypassrls)
UNION ALL
SELECT r.rolname, 'app_role_privileged' FROM runtime_roles r
 WHERE r.rolsuper OR r.rolbypassrls OR r.rolcreaterole OR r.rolcreatedb
UNION ALL
SELECT c.oid::regclass::text, 'app_role_owns_relation'
  FROM pg_class c JOIN pg_roles r ON r.oid = c.relowner WHERE r.rolname IN ('hk_app','hk_readonly','hk_dispatcher','hk_reports')
UNION ALL
SELECT t.tgrelid::regclass::text, 'append_only_table_grants_update_or_delete'
  FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid AND p.proname = 'forbid_mutation'
 WHERE NOT t.tgisinternal
   AND (   ((t.tgtype & 16) <> 0 AND has_table_privilege('hk_app', t.tgrelid, 'UPDATE'))
        OR ((t.tgtype & 8)  <> 0 AND has_table_privilege('hk_app', t.tgrelid, 'DELETE')))
UNION ALL
SELECT name, 'tenant_table_not_in_export_registry' FROM tenant_tables t
 WHERE NOT EXISTS (SELECT 1 FROM core.export_table_registry r WHERE r.schema_name = t.nspname AND r.table_name = t.relname)
UNION ALL
SELECT c.oid::regclass::text, 'dispatcher_privilege_outside_allowlist'
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace JOIN app_schemas s ON s.nspname = n.nspname
 WHERE c.relkind IN ('r','p','v','m')
   AND c.oid NOT IN (SELECT rel FROM dispatcher_allow WHERE rel IS NOT NULL)
   AND (has_any_column_privilege('hk_dispatcher', c.oid, 'SELECT,INSERT,UPDATE,REFERENCES')
        OR has_table_privilege('hk_dispatcher', c.oid, 'DELETE,TRUNCATE,TRIGGER'))
UNION ALL
SELECT r.schema_name || '.' || r.table_name || '.' || x, 'dispatcher_reads_secret_column'
  FROM core.export_table_registry r CROSS JOIN LATERAL unnest(r.secret_columns) x
 WHERE to_regclass(quote_ident(r.schema_name) || '.' || quote_ident(r.table_name)) IS NOT NULL
   AND EXISTS (SELECT 1 FROM pg_attribute a
                WHERE a.attrelid = to_regclass(quote_ident(r.schema_name) || '.' || quote_ident(r.table_name))
                  AND a.attname = x AND NOT a.attisdropped)
   AND has_column_privilege('hk_dispatcher', to_regclass(quote_ident(r.schema_name) || '.' || quote_ident(r.table_name)), x, 'SELECT')
UNION ALL
SELECT 'core.tenant.' || col, 'app_can_update_tenant_control_column'
  FROM unnest(ARRAY['status','slug','deployment']) col
 WHERE has_column_privilege('hk_app', 'core.tenant', col, 'UPDATE')
$$;

-- =====================================================================
-- ۲۲. دادهٔ کاتالوگ هسته (migration هر ماژول کاتالوگ خودش را اضافه می‌کند)
-- =====================================================================
INSERT INTO core.permission (code, module, scope_dimensions, risk, allow_service_account, allow_impersonation_write, description_key, introduced_in) VALUES
  ('core.member.read',            'core', '{}', 'normal',    true,  false, 'perm.core.member.read',            '1.0'),
  ('core.member.invite',          'core', '{}', 'sensitive', false, false, 'perm.core.member.invite',          '1.0'),
  ('core.member.manage',          'core', '{}', 'critical',  false, false, 'perm.core.member.manage',          '1.0'),
  ('core.role.read',              'core', '{}', 'normal',    true,  false, 'perm.core.role.read',              '1.0'),
  ('core.role.manage',            'core', '{}', 'critical',  false, false, 'perm.core.role.manage',            '1.0'),
  ('core.role.assign',            'core', '{company,branch}', 'critical', false, false, 'perm.core.role.assign', '1.0'),
  ('core.sod.manage',             'core', '{}', 'critical',  false, false, 'perm.core.sod.manage',             '1.0'),
  ('core.approval.policy.manage', 'core', '{company}', 'critical', false, false, 'perm.core.approval.policy.manage', '1.0'),
  ('core.approval.request.read',  'core', '{company}', 'normal', true, false, 'perm.core.approval.request.read', '1.0'),
  ('core.approval.request.decide','core', '{company}', 'sensitive', false, false, 'perm.core.approval.request.decide', '1.0'),
  ('core.audit.read',             'core', '{company,branch}', 'sensitive', true, false, 'perm.core.audit.read', '1.0'),
  ('core.audit.verify',           'core', '{}', 'normal',    true,  false, 'perm.core.audit.verify',           '1.0'),
  ('core.audit.export',           'core', '{}', 'sensitive', false, false, 'perm.core.audit.export',           '1.0'),
  ('core.numbering.read',         'core', '{company,branch}', 'normal', true, false, 'perm.core.numbering.read', '1.0'),
  ('core.numbering.manage',       'core', '{company,branch}', 'critical', false, false, 'perm.core.numbering.manage', '1.0'),
  ('core.numbering.reserve',      'core', '{company,branch,pos_terminal}', 'sensitive', true, false, 'perm.core.numbering.reserve', '1.0'),
  ('core.numbering.void',         'core', '{company,branch}', 'critical', false, false, 'perm.core.numbering.void', '1.0'),
  ('core.setting.read',           'core', '{company,branch}', 'normal', true, false, 'perm.core.setting.read', '1.0'),
  ('core.setting.manage',         'core', '{company,branch}', 'sensitive', false, false, 'perm.core.setting.manage', '1.0'),
  ('core.setting.self',           'core', '{}', 'normal',    false, true,  'perm.core.setting.self',           '1.0'),
  ('core.security.manage',        'core', '{}', 'critical',  false, false, 'perm.core.security.manage',        '1.0'),
  ('core.custom_field.read',      'core', '{}', 'normal',    true,  false, 'perm.core.custom_field.read',      '1.0'),
  ('core.custom_field.manage',    'core', '{}', 'sensitive', false, false, 'perm.core.custom_field.manage',    '1.0'),
  ('core.attachment.read',        'core', '{company}', 'normal', true, false, 'perm.core.attachment.read',     '1.0'),
  ('core.attachment.upload',      'core', '{company}', 'normal', true, true,  'perm.core.attachment.upload',   '1.0'),
  ('core.attachment.delete',      'core', '{company}', 'sensitive', false, false, 'perm.core.attachment.delete', '1.0'),
  ('core.notification.self',      'core', '{}', 'normal',    false, true,  'perm.core.notification.self',      '1.0'),
  ('core.notification.template.manage', 'core', '{}', 'sensitive', false, false, 'perm.core.notification.template.manage', '1.0'),
  ('core.job.read',               'core', '{}', 'normal',    true,  false, 'perm.core.job.read',               '1.0'),
  ('core.job.manage',             'core', '{}', 'sensitive', false, false, 'perm.core.job.manage',             '1.0'),
  ('core.schedule.manage',        'core', '{}', 'sensitive', false, false, 'perm.core.schedule.manage',        '1.0'),
  ('core.export.create',          'core', '{}', 'critical',  false, false, 'perm.core.export.create',          '1.0'),
  ('core.export.download',        'core', '{}', 'critical',  false, false, 'perm.core.export.download',        '1.0'),
  ('core.support_access.grant',   'core', '{}', 'critical',  false, false, 'perm.core.support_access.grant',   '1.0'),
  ('core.impersonation.read',     'core', '{}', 'normal',    false, false, 'perm.core.impersonation.read',     '1.0'),
  ('core.api_key.manage',         'core', '{}', 'critical',  false, false, 'perm.core.api_key.manage',         '1.0'),
  ('core.device.manage',          'core', '{company,branch}', 'sensitive', false, false, 'perm.core.device.manage', '1.0'),
  ('core.webhook.manage',         'core', '{}', 'critical',  false, false, 'perm.core.webhook.manage',         '1.0'),
  ('core.data_request.manage',    'core', '{}', 'critical',  false, false, 'perm.core.data_request.manage',    '1.0'),
  ('core.legal_hold.manage',      'core', '{}', 'critical',  false, false, 'perm.core.legal_hold.manage',      '1.0'),
  ('core.retention.manage',       'core', '{}', 'critical',  false, false, 'perm.core.retention.manage',       '1.0'),
  ('core.company.manage',         'core', '{company}', 'critical', false, false, 'perm.core.company.manage',   '1.0'),
  ('core.branch.manage',          'core', '{company,branch}', 'sensitive', false, false, 'perm.core.branch.manage', '1.0'),
  ('core.member.contact.read', 'core', '{}', 'sensitive', true, false, 'perm.core.member.contact.read', '1.0'),
  -- مجوزهای endpointهای بخش ۰۱ §۶ (RV-CORE-19) و پرتال صورتحساب (09:CR-PLT-04)
  ('core.webhook.read',           'core', '{}', 'normal',    true,  false, 'perm.core.webhook.read',           '1.0'),
  ('core.job.read_all',           'core', '{}', 'normal',    true,  false, 'perm.core.job.read_all',           '1.0'),
  ('core.job.cancel',             'core', '{}', 'sensitive', false, false, 'perm.core.job.cancel',             '1.0'),
  ('core.file.upload',            'core', '{company}', 'normal', true, true, 'perm.core.file.upload',          '1.0'),
  ('core.update.read',            'core', '{}', 'normal',    false, false, 'perm.core.update.read',            '1.0'),
  ('core.update.manage',          'core', '{}', 'critical',  false, false, 'perm.core.update.manage',          '1.0'),
  ('core.update.apply',           'core', '{}', 'critical',  false, false, 'perm.core.update.apply',           '1.0'),
  ('core.backup.read',            'core', '{}', 'normal',    false, false, 'perm.core.backup.read',            '1.0'),
  ('core.backup.run',             'core', '{}', 'critical',  false, false, 'perm.core.backup.run',             '1.0'),
  ('core.diagnostics.create',     'core', '{}', 'sensitive', false, false, 'perm.core.diagnostics.create',     '1.0'),
  ('core.billing.manage',         'core', '{}', 'critical',  false, false, 'perm.core.billing.manage',         '1.0'),
  ('core.print.template.read',    'core', '{company}', 'normal', true, false, 'perm.core.print.template.read',  '1.0'),
  ('core.print.template.manage',  'core', '{company}', 'sensitive', false, false, 'perm.core.print.template.manage', '1.0'),
  ('core.support.ticket.create',  'core', '{}', 'normal',    false, false, 'perm.core.support.ticket.create',  '1.0')
ON CONFLICT (code) DO NOTHING;

INSERT INTO core.role_template (code, name_key, grants_all, for_service, introduced_in) VALUES
  ('owner',            'role.owner',            true,  false, '1.0'),
  ('admin',            'role.admin',            false, false, '1.0'),
  ('accountant',       'role.accountant',       false, false, '1.0'),
  ('cashier',          'role.cashier',          false, false, '1.0'),
  ('sales_clerk',      'role.sales_clerk',      false, false, '1.0'),
  ('purchaser',        'role.purchaser',        false, false, '1.0'),
  ('warehouse_keeper', 'role.warehouse_keeper', false, false, '1.0'),
  ('payroll_officer',  'role.payroll_officer',  false, false, '1.0'),
  ('auditor',          'role.auditor',          false, false, '1.0'),
  ('member',           'role.member',           false, false, '1.0'),
  ('support_readonly', 'role.support_readonly', false, false, '1.0'),
  ('integration',      'role.integration',      false, true,  '1.0')
ON CONFLICT (code) DO NOTHING;

INSERT INTO core.role_template_permission (template_code, permission_code)
SELECT 'admin', code FROM core.permission
 WHERE module = 'core' AND code NOT IN ('core.export.create','core.export.download','core.support_access.grant','core.legal_hold.manage',
                                        'core.billing.manage')
UNION ALL SELECT 'auditor', code FROM core.permission WHERE code IN
  ('core.member.read','core.role.read','core.audit.read','core.audit.verify','core.numbering.read','core.setting.read',
   'core.custom_field.read','core.attachment.read','core.approval.request.read','core.impersonation.read','core.job.read',
   'core.job.read_all','core.webhook.read','core.update.read','core.backup.read','core.print.template.read')
UNION ALL SELECT 'support_readonly', code FROM core.permission WHERE code IN
  ('core.member.read','core.role.read','core.audit.read','core.numbering.read','core.setting.read',
   'core.custom_field.read','core.attachment.read','core.approval.request.read','core.job.read')
UNION ALL SELECT t.code, p.code FROM core.role_template t CROSS JOIN core.permission p
 WHERE t.code IN ('member','accountant','cashier','sales_clerk','purchaser','warehouse_keeper','payroll_officer')
   AND p.code IN ('core.setting.self','core.notification.self','core.attachment.read','core.custom_field.read',
                  'core.print.template.read','core.support.ticket.create')
ON CONFLICT DO NOTHING;

INSERT INTO core.field_guard (resource, field, read_permission, write_permission, mask_style, is_secret) VALUES
  ('core.member', 'phone', 'core.member.contact.read', 'core.member.manage', 'partial_last4', false),
  ('core.member', 'email', 'core.member.contact.read', 'core.member.manage', 'partial_last4', false),
  ('core.webhook_endpoint', 'secret', 'core.webhook.manage', 'core.webhook.manage', 'omit', true)
ON CONFLICT DO NOTHING;

INSERT INTO core.setting_def (key, module, value_type, enum_values, min_value, max_value, allowed_levels, default_value,
                              read_permission, write_permission, description_key, introduced_in) VALUES
  ('core.locale',                       'core', 'enum', '{fa-IR,en-US}', NULL, NULL, '{tenant,user}', '"fa-IR"', NULL, 'core.setting.manage', 'setting.core.locale', '1.0'),
  ('core.calendar_display',             'core', 'enum', '{jalali,gregorian}', NULL, NULL, '{tenant,user}', '"jalali"', NULL, 'core.setting.manage', 'setting.core.calendar_display', '1.0'),
  ('core.amount_display_unit',          'core', 'enum', '{IRR,IRT}', NULL, NULL, '{tenant,company,user}', '"IRR"', NULL, 'core.setting.manage', 'setting.core.amount_display_unit', '1.0'),
  ('core.security.mfa_required',        'core', 'bool', NULL, NULL, NULL, '{tenant}', 'false', NULL, 'core.security.manage', 'setting.core.security.mfa_required', '1.0'),
  ('core.security.session_idle_s',      'core', 'duration_s', NULL, 300, 86400, '{tenant}', '1800', NULL, 'core.security.manage', 'setting.core.security.session_idle_s', '1.0'),
  ('core.security.session_absolute_s',  'core', 'duration_s', NULL, 3600, 2592000, '{tenant}', '43200', NULL, 'core.security.manage', 'setting.core.security.session_absolute_s', '1.0'),
  ('core.security.password_min_length', 'core', 'int', NULL, 8, 64, '{tenant}', '10', NULL, 'core.security.manage', 'setting.core.security.password_min_length', '1.0'),
  ('core.security.pin_max_failures',    'core', 'int', NULL, 3, 10, '{tenant}', '5', NULL, 'core.security.manage', 'setting.core.security.pin_max_failures', '1.0'),
  ('core.security.support_grant_max_h', 'core', 'int', NULL, 1, 168, '{tenant}', '24', NULL, 'core.security.manage', 'setting.core.security.support_grant_max_h', '1.0'),
  ('core.numbering.device_window',      'core', 'int', NULL, 100, 1000000, '{tenant,company,branch}', '10000', NULL, 'core.numbering.manage', 'setting.core.numbering.device_window', '1.0'),
  ('core.attachment.max_size_bytes',    'core', 'int', NULL, 1024, 1073741824, '{tenant}', '20971520', NULL, 'core.setting.manage', 'setting.core.attachment.max_size_bytes', '1.0'),
  ('core.attachment.allow_unscanned',   'core', 'bool', NULL, NULL, NULL, '{tenant}', 'false', NULL, 'core.security.manage', 'setting.core.attachment.allow_unscanned', '1.0'),
  ('core.idempotency.retention_s',      'core', 'duration_s', NULL, 86400, 7776000, '{tenant}', '604800', NULL, 'core.setting.manage', 'setting.core.idempotency.retention_s', '1.0'),
  ('core.notification.sms_enabled',     'core', 'bool', NULL, NULL, NULL, '{tenant,company,branch}', 'true', NULL, 'core.setting.manage', 'setting.core.notification.sms_enabled', '1.0'),
  ('core.audit.business_hours',         'core', 'json', NULL, NULL, NULL, '{tenant,company,branch}', '{"start":"08:00","end":"20:00","weekend":[5]}', NULL, 'core.setting.manage', 'setting.core.audit.business_hours', '1.0')
ON CONFLICT (key) DO NOTHING;

INSERT INTO core.notification_category (code, module, is_mandatory, default_channels, description_key) VALUES
  ('core.security',   'core', true,  '{in_app,sms}', 'ntf.core.security'),
  ('core.approval',   'core', false, '{in_app}',     'ntf.core.approval'),
  ('core.support',    'core', true,  '{in_app,sms}', 'ntf.core.support'),
  ('core.system',     'core', false, '{in_app}',     'ntf.core.system')
ON CONFLICT DO NOTHING;

INSERT INTO core.notification_template_def (code, category, channel, locale, subject, body, sms_pattern_code, variables, tenant_overridable) VALUES
  ('core.otp',                 'core.security', 'sms',    'fa-IR', NULL, 'کد ورود شما: {code}', 'hk-otp', '{code,otp_challenge_id}', false),
  ('core.new_login',           'core.security', 'in_app', 'fa-IR', 'ورود جدید', 'ورود جدید از {client} در {time}', NULL, '{client,time}', false),
  ('core.impersonation_start', 'core.support',  'in_app', 'fa-IR', 'دسترسی پشتیبانی', 'پشتیبان {staff} به دلیل «{reason}» تا {until} وارد حساب شد.', NULL, '{staff,reason,until}', false),
  ('core.approval_needed',     'core.approval', 'in_app', 'fa-IR', 'درخواست تأیید', '{subject} منتظر تأیید شماست.', NULL, '{subject}', true),
  ('core.job_dead',            'core.system',   'in_app', 'fa-IR', 'خطای پردازش', 'کار {kind} پس از {attempts} تلاش متوقف شد.', NULL, '{kind,attempts}', true)
ON CONFLICT DO NOTHING;
-- کد OTP فقط هنگام ارسال از otp_challenge_id (با کلید OTP بیرون از پایگاه داده) بازسازی می‌شود و ذخیره نمی‌شود (RV-CORE-03)
UPDATE core.notification_template_def SET runtime_variables = '{code}' WHERE code = 'core.otp' AND runtime_variables <> '{code}';

INSERT INTO core.event_subscriber (subscriber, ordered, max_attempts, requires_webhook_endpoint, introduced_in) VALUES
  ('core.webhooks',                          false, 25, true,  '1.0'),   -- برای هر endpoint منطبق webhook_delivery می‌سازد (۰۱ §۵-۷)
  ('uplink',                                 false, 25, false, '1.0'),   -- دسته‌های رویداد برای صفحهٔ کنترل
  ('platform_link.audit_anchor',             false, 25, false, '1.0'),
  ('core.notification.impersonation_notice', false, 10, false, '1.0'),
  ('core.authz.cache_invalidate',            false, 10, false, '1.0')
ON CONFLICT DO NOTHING;
INSERT INTO core.event_subscription (event_type, subscriber) VALUES
  ('*',                             'core.webhooks'),
  ('core.audit.checkpoint_created', 'platform_link.audit_anchor'),
  ('core.audit.checkpoint_created', 'uplink'),
  ('core.impersonation.started',    'core.notification.impersonation_notice'),
  ('core.authz.changed',            'core.authz.cache_invalidate'),
  -- آینهٔ رضایت پشتیبانی، ack ورود به‌جای کاربر و تیکت درون‌برنامه در صفحهٔ کنترل (RV-X1-05؛ 09:CR-PLT-05)
  ('core.support_access.*',         'uplink'),
  ('core.impersonation.*',          'uplink'),
  ('core.support_ticket.opened',    'uplink')
ON CONFLICT DO NOTHING;
INSERT INTO core.job_queue (queue, per_tenant_cap, description) VALUES
  ('default', 4, 'general'), ('heavy', 1, 'import/export/year close'), ('report', 2, 'async reports'),
  ('moadian', 1, 'tax submissions; plus one per concurrency_key'), ('notify', 8, 'sms/email'), ('sync', 2, 'pos sync'),
  ('migration', 1, 'data migration'), ('webhook', 8, 'webhook delivery'), ('maintenance', 1, 'per-tenant maintenance')
ON CONFLICT DO NOTHING;

INSERT INTO core.retention_class (code, basis, default_period, rules_param_key, min_period, action, description_key) VALUES
  ('accounting_records', 'fiscal_year_end', NULL, 'retention.accounting_records.years', NULL, 'archive_then_delete', 'ret.accounting_records'),
  ('audit_log',          'fiscal_year_end', NULL, 'retention.accounting_records.years', NULL, 'archive_then_delete', 'ret.audit_log'),
  ('attachment',         'created_at', interval '10 years', NULL, interval '1 year', 'delete', 'ret.attachment'),
  ('technical_log',      'created_at', interval '365 days', NULL, interval '90 days', 'delete', 'ret.technical_log'),
  ('idempotency',        'expires_at', interval '7 days', NULL, interval '1 day', 'delete', 'ret.idempotency'),
  ('job_finished',       'closed_at', interval '30 days', NULL, interval '7 days', 'delete', 'ret.job_finished'),
  ('job_failed',         'closed_at', interval '180 days', NULL, interval '30 days', 'delete', 'ret.job_failed'),
  ('outbox',             'closed_at', interval '90 days', NULL, interval '7 days', 'delete', 'ret.outbox'),
  ('notification',       'created_at', interval '365 days', NULL, interval '30 days', 'delete', 'ret.notification'),
  ('migration_upload',   'closed_at', interval '30 days', NULL, interval '1 day', 'delete', 'ret.migration_upload'),
  ('tenant_export',      'created_at', interval '30 days', NULL, interval '1 day', 'delete', 'ret.tenant_export'),
  ('offboarded_tenant',  'closed_at', interval '90 days', NULL, interval '30 days', 'archive_then_delete', 'ret.offboarded_tenant')
ON CONFLICT DO NOTHING;

INSERT INTO core.export_table_registry (schema_name, table_name, module, mode, export_order, pii_columns, secret_columns, note) VALUES
  ('core','company',               'core', 'rows', 100, '{}', '{}', NULL),
  ('core','branch',                'core', 'rows', 110, '{}', '{}', NULL),
  ('core','tenant_membership',     'core', 'hook', 120, '{}', '{}', 'with core.identity hook: member app_user, login identifiers, credentials'),
  ('core','membership_invitation', 'core', 'skip', 0,   '{destination}', '{token_hash}', 'ephemeral; invitations are re-issued'),
  ('core','device',                'core', 'rows', 130, '{}', '{enrollment_code_hash}', NULL),
  ('core','member_pin',            'core', 'rows', 140, '{}', '{pin_hash}', NULL),
  ('core','api_key',               'core', 'rows', 150, '{}', '{secret_hash}', 'keys stay valid after move only if target trusts source realm'),
  ('core','role',                  'core', 'rows', 160, '{}', '{}', NULL),
  ('core','role_permission',       'core', 'rows', 170, '{}', '{}', NULL),
  ('core','role_assignment',       'core', 'rows', 180, '{}', '{}', NULL),
  ('core','role_assignment_scope', 'core', 'rows', 190, '{}', '{}', NULL),
  ('core','sod_rule',              'core', 'rows', 200, '{}', '{}', NULL),
  ('core','approval_policy',       'core', 'rows', 210, '{}', '{}', NULL),
  ('core','approval_policy_step',  'core', 'rows', 220, '{}', '{}', NULL),
  ('core','approval_request',      'core', 'rows', 230, '{}', '{}', NULL),
  ('core','approval_decision',     'core', 'rows', 240, '{}', '{}', NULL),
  ('core','support_access_grant',  'core', 'rows', 250, '{}', '{}', NULL),
  ('core','impersonation_session', 'core', 'rows', 260, '{}', '{token_hash}', NULL),
  ('core','audit_chain_head',      'core', 'rows', 270, '{}', '{}', NULL),
  ('core','audit_log',             'core', 'rows', 280, '{ip,user_agent}', '{}', 'exported verbatim; chain re-verified on import'),
  ('core','audit_checkpoint',      'core', 'rows', 290, '{}', '{}', NULL),
  ('core','audit_anchor',          'core', 'rows', 300, '{}', '{}', NULL),
  ('core','number_series',         'core', 'rows', 310, '{}', '{}', NULL),
  ('core','number_counter',        'core', 'rows', 320, '{}', '{}', NULL),
  ('core','number_reservation',    'core', 'rows', 330, '{}', '{}', NULL),
  ('core','number_issued',         'core', 'rows', 340, '{}', '{}', NULL),
  ('core','setting_value',         'core', 'rows', 350, '{}', '{}', NULL),
  ('core','setting_history',       'core', 'rows', 360, '{}', '{}', NULL),
  ('core','custom_field_def',      'core', 'rows', 370, '{}', '{}', NULL),
  ('core','custom_field_index',    'core', 'skip', 0,   '{}', '{}', 'derived; rebuilt by core.custom_field_reindex() in the import hook'),
  ('core','attachment',            'core', 'hook', 380, '{file_name}', '{}', 'objects copied into files/ by core.attachment hook'),
  ('core','attachment_link',       'core', 'rows', 390, '{}', '{}', NULL),
  ('core','device_token',          'core', 'skip', 0,   '{}', '{token_hash}', 'ephemeral (1 hour)'),
  ('core','outbox_event',          'core', 'skip', 0,   '{}', '{}', 'transient delivery log'),
  ('core','outbox_delivery',       'core', 'skip', 0,   '{}', '{}', 'transient delivery state'),
  ('core','webhook_endpoint',      'core', 'rows', 400, '{}', '{secret_sealed,secret_prev_sealed}', NULL),
  ('core','webhook_delivery',      'core', 'skip', 0,   '{}', '{}', 'transient delivery state'),
  ('core','job',                   'core', 'skip', 0,   '{}', '{}', 'transient; schedules re-create jobs'),
  ('core','job_tenant_state',      'core', 'skip', 0,   '{}', '{}', 'placement-specific'),
  ('core','job_schedule',          'core', 'rows', 410, '{}', '{}', NULL),
  ('core','notification_template', 'core', 'rows', 420, '{}', '{}', NULL),
  ('core','notification',          'core', 'rows', 430, '{recipient_address}', '{}', NULL),
  ('core','notification_preference','core','rows', 440, '{}', '{}', NULL),
  ('core','tenant_export',         'core', 'skip', 0,   '{}', '{}', 'describes exports of the source placement'),
  ('core','tenant_import',         'core', 'skip', 0,   '{}', '{}', 'written by the importer on the target'),
  ('core','retention_override',    'core', 'rows', 450, '{}', '{}', NULL),
  ('core','legal_hold',            'core', 'rows', 460, '{}', '{}', NULL),
  ('core','data_subject_request',  'core', 'rows', 470, '{}', '{}', NULL),
  ('core','idempotency_key',       'core', 'skip', 0,   '{}', '{response_body,response_headers}', 'ephemeral (days)'),
  ('core','export_blocker',        'core', 'skip', 0,   '{}', '{}', 'runtime state of the source placement'),
  ('core','tenant_desired_state',  'core', 'skip', 0,   '{}', '{}', 're-applied from the control plane on the target'),
  ('core','tenant_entitlement',    'core', 'skip', 0,   '{}', '{}', 'derived from the desired state'),
  ('core','tenant_provisioning',   'core', 'skip', 0,   '{}', '{}', 'placement-specific provisioning log'),
  ('core','letterhead',            'core', 'rows', 105, '{phone}', '{}', NULL),
  ('core','print_template',        'core', 'rows', 480, '{}', '{}', NULL),
  ('core','print_template_version','core', 'rows', 490, '{}', '{}', NULL)
ON CONFLICT DO NOTHING;
-- اصلاح ردیف‌های موجود پایگاه‌های پیشین (اجرای دوبارهٔ فایل)
UPDATE core.export_table_registry SET secret_columns = '{token_hash}'
 WHERE schema_name = 'core' AND table_name = 'impersonation_session' AND secret_columns <> '{token_hash}';
UPDATE core.export_table_registry SET secret_columns = '{response_body,response_headers}'
 WHERE schema_name = 'core' AND table_name = 'idempotency_key' AND secret_columns <> '{response_body,response_headers}';

-- =====================================================================
-- ۲۳. دسترسی‌ها (کمینه)
-- =====================================================================
-- کاتالوگ‌ها: فقط خواندن
GRANT SELECT ON core.permission, core.role_template, core.role_template_permission, core.field_guard,
                core.setting_def, core.custom_field_entity, core.event_subscriber, core.event_subscription,
                core.job_queue, core.notification_category, core.notification_template_def,
                core.export_table_registry, core.retention_class, core.print_model, core.print_template_def
  TO hk_app, hk_readonly, hk_dispatcher;

-- فقط‌افزودنی: SELECT, INSERT
GRANT SELECT, INSERT ON core.audit_log, core.audit_anchor,
                        core.approval_decision, core.setting_history, core.auth_event, core.outbox_event,
                        core.tenant_import, core.print_template_version
  TO hk_app;
-- checkpoint فقط با core.audit_checkpoint_create (RV-CORE-09)
REVOKE INSERT, UPDATE, DELETE ON core.audit_checkpoint FROM hk_app;
GRANT SELECT ON core.audit_checkpoint TO hk_app;
-- شماره‌گذاری: hk_app فقط می‌خواند؛ نوشتن فقط از توابع definer هسته (RV-CORE-05؛ INV-NUM-01/06)
REVOKE INSERT, UPDATE, DELETE ON core.number_issued, core.number_counter, core.number_reservation FROM hk_app;
GRANT SELECT ON core.number_issued, core.number_counter, core.number_reservation TO hk_app;

-- تغییرپذیر بدون حذف
GRANT SELECT, INSERT, UPDATE ON core.app_user, core.user_credential, core.user_session,
                                core.otp_challenge, core.tenant_membership, core.membership_invitation, core.device,
                                core.member_pin, core.device_token, core.api_key, core.role, core.role_assignment,
                                core.sod_rule, core.approval_policy, core.approval_request, core.support_access_grant,
                                core.impersonation_session, core.number_series,
                                core.custom_field_def, core.attachment, core.webhook_endpoint,
                                core.webhook_delivery, core.job, core.job_tenant_state, core.job_schedule,
                                core.outbox_delivery, core.idempotency_key, core.notification,
                                core.notification_preference, core.tenant_export, core.retention_override,
                                core.legal_hold, core.data_subject_request, core.print_template, core.letterhead,
                                core.export_blocker
  TO hk_app;
-- حالت مطلوب و حق استفاده فقط با core.apply_desired_state؛ provisioning: گام‌های ماژول‌ها را خود برنامه ثبت می‌کند
GRANT SELECT ON core.tenant_desired_state, core.tenant_entitlement, core.tenant_provisioning TO hk_app;
GRANT UPDATE (status, steps, error) ON core.tenant_provisioning TO hk_app;
-- تغییرپذیر با حذف (بازگشت به ارث، حذف انتساب‌ها و پیوندها)
GRANT SELECT, INSERT, UPDATE, DELETE ON core.user_login_identifier, core.user_recovery_code, core.role_permission,
                                        core.role_assignment_scope, core.approval_policy_step, core.setting_value,
                                        core.custom_field_index, core.attachment_link, core.notification_template,
                                        core.rate_limit_counter
  TO hk_app;
GRANT SELECT ON core.audit_chain_head TO hk_app;
GRANT SELECT ON core.deployment_info TO hk_app, hk_dispatcher, hk_readonly;
GRANT UPDATE (max_seen_at) ON core.deployment_info TO hk_app;

-- نقش dispatcher (قرارداد بخش ۰۱ §۴-۳ + افزوده‌ها: DELETE روی job برای پاک‌سازی، صف وضعیت، ردیف‌های گذرای کاربر)
GRANT SELECT, INSERT, UPDATE, DELETE ON core.job TO hk_dispatcher;
GRANT SELECT, UPDATE ON core.job_schedule, core.outbox_delivery TO hk_dispatcher;
GRANT SELECT, INSERT, UPDATE ON core.job_tenant_state TO hk_dispatcher;
-- پاک‌سازی فقط ستون‌های کلید و زمان را می‌خواند (کمینه؛ RV-CORE-03/RV-ARCH-09: hash توکن، کد OTP و payload دیده نمی‌شوند)
GRANT SELECT (tenant_id, id, occurred_at), DELETE ON core.outbox_event TO hk_dispatcher;
GRANT SELECT (tenant_id, id, event_id, status, created_at), DELETE ON core.webhook_delivery TO hk_dispatcher;
GRANT SELECT (id, occurred_at, context_tenant_id), DELETE ON core.auth_event TO hk_dispatcher;
GRANT SELECT (id, expires_at), DELETE ON core.otp_challenge TO hk_dispatcher;
GRANT SELECT (tenant_id, id, expires_at), DELETE ON core.device_token TO hk_dispatcher;
-- idempotency: فقط ستون‌های لازم پاک‌سازی؛ بدنهٔ پاسخ (حتی پس از حذف راز) دیده نمی‌شود (RV-CORE-03)
GRANT SELECT (tenant_id, id, expires_at), DELETE ON core.idempotency_key TO hk_dispatcher;
GRANT DELETE ON core.outbox_delivery TO hk_dispatcher;
GRANT SELECT, INSERT, UPDATE, DELETE ON core.rate_limit_counter TO hk_dispatcher;
GRANT SELECT (id, slug, status) ON core.tenant TO hk_dispatcher;
GRANT SELECT, INSERT, UPDATE ON core.system_task_run TO hk_dispatcher;
GRANT SELECT, INSERT, UPDATE ON core.outbox_claim_cursor TO hk_dispatcher;
GRANT SELECT (tenant_id, scope, released_at) ON core.legal_hold TO hk_dispatcher;
GRANT SELECT (tenant_id, class_code, period) ON core.retention_override TO hk_dispatcher;
GRANT USAGE ON SEQUENCE core.outbox_event_seq_seq TO hk_app;

-- نقش‌های مالک توابع
GRANT SELECT, INSERT, UPDATE ON core.audit_chain_head TO hk_audit_writer;
GRANT SELECT ON core.audit_log TO hk_audit_writer;
GRANT SELECT, INSERT ON core.audit_checkpoint TO hk_audit_writer;
GRANT SELECT ON core.app_user, core.user_login_identifier, core.api_key, core.user_session, core.device_token,
                core.device, core.impersonation_session, core.tenant_membership, core.otp_challenge TO hk_core_definer;
-- نوشتن‌های definer هسته (دعوت، ابطال نشست دستگاه، provisioning، حالت مطلوب)؛ RLS مستأجری برقرار است
GRANT INSERT ON core.app_user, core.user_login_identifier TO hk_core_definer;
GRANT INSERT, UPDATE (status, invited_by, is_owner, joined_at) ON core.tenant_membership TO hk_core_definer;
GRANT UPDATE (revoked_at, revoke_reason) ON core.user_session TO hk_core_definer;
GRANT UPDATE (revoked_at) ON core.device_token TO hk_core_definer;
GRANT SELECT, INSERT, UPDATE (status, display_name, locale, timezone) ON core.tenant TO hk_core_definer;
GRANT SELECT ON core.number_series, core.setting_value, core.setting_def TO hk_core_definer;
GRANT SELECT, INSERT, UPDATE ON core.number_counter, core.number_reservation TO hk_core_definer;
GRANT SELECT, INSERT ON core.number_issued TO hk_core_definer;
GRANT SELECT, INSERT, UPDATE ON core.tenant_desired_state TO hk_core_definer;
GRANT SELECT, INSERT, UPDATE, DELETE ON core.tenant_entitlement TO hk_core_definer;
GRANT SELECT, INSERT ON core.tenant_provisioning, core.role, core.role_permission, core.role_assignment TO hk_core_definer;
GRANT SELECT ON core.role_template, core.role_template_permission, core.permission TO hk_core_definer;
GRANT SELECT, INSERT ON core.company, core.branch TO hk_core_definer;
GRANT INSERT ON core.audit_log TO hk_core_definer;

-- فقط‌خواندنی: همه‌چیز جز ستون‌های راز
GRANT SELECT ON ALL TABLES IN SCHEMA core TO hk_readonly;
REVOKE SELECT ON core.user_credential, core.user_recovery_code, core.user_session, core.otp_challenge,
                 core.member_pin, core.device_token, core.api_key, core.webhook_endpoint, core.membership_invitation,
                 core.device, core.impersonation_session, core.system_task_run, core.idempotency_key
  FROM hk_readonly;
-- بدنه و سرآیندهای بازپخش idempotency پاسخ کامل کاربر است؛ پشتیبانی و گزارش آن را نمی‌خوانند (RV-CORE-03)
GRANT SELECT (tenant_id, id, principal_id, idem_key, method, route, response_status, resource_type, resource_id,
              created_at, expires_at) ON core.idempotency_key TO hk_readonly;
GRANT SELECT (user_id, password_changed_at, must_change_password, failed_count, locked_until, totp_enabled_at, updated_at, row_version)
  ON core.user_credential TO hk_readonly;
GRANT SELECT (id, user_id, generation, used_at, created_at) ON core.user_recovery_code TO hk_readonly;
GRANT SELECT (id, user_id, token_rotated_at, active_tenant_id, device_id, client_kind, amr, auth_time, mfa_at, ip, user_agent,
              created_at, last_seen_at, idle_timeout_seconds, absolute_expires_at, revoked_at, revoke_reason)
  ON core.user_session TO hk_readonly;
GRANT SELECT (id, user_id, purpose, channel, attempts, max_attempts, created_at, expires_at, consumed_at) ON core.otp_challenge TO hk_readonly;
GRANT SELECT (tenant_id, id, membership_id, failed_count, locked_until, created_at, updated_at, row_version) ON core.member_pin TO hk_readonly;
GRANT SELECT (tenant_id, id, device_id, issued_at, expires_at, revoked_at) ON core.device_token TO hk_readonly;
GRANT SELECT (tenant_id, id, user_id, name, prefix, permissions, allowed_cidrs, expires_at, created_by, created_at,
              last_used_at, revoked_at, revoked_by, updated_at, row_version) ON core.api_key TO hk_readonly;
GRANT SELECT (tenant_id, id, url, description, event_types, api_version, status, disabled_reason, failure_streak,
              first_failure_at, allow_private_network, created_by, created_at, updated_at, row_version)
  ON core.webhook_endpoint TO hk_readonly;
GRANT SELECT (tenant_id, id, membership_id, channel, role_ids, created_by, created_at, expires_at, accepted_at, revoked_at)
  ON core.membership_invitation TO hk_readonly;
GRANT SELECT (tenant_id, id, company_id, branch_id, kind, name, key_alg, public_key, status, registered_by, activated_at,
              last_seen_at, app_version, revoked_at, revoke_reason, created_at, updated_at, row_version)
  ON core.device TO hk_readonly;
GRANT SELECT (tenant_id, id, grant_id, grantee_kind, staff_id, staff_display_name, assertion_jti, reason, ticket_ref, mode,
              write_approver_staff_id, target_user_id, started_at, expires_at, ended_at, end_reason)
  ON core.impersonation_session TO hk_readonly;

-- توابع: پیش‌فرض EXECUTE برای برنامه؛ سپس استثناها
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA core TO hk_app;
REVOKE EXECUTE ON FUNCTION core.audit_seal() FROM hk_app;
REVOKE EXECUTE ON FUNCTION core.attach_custom_fields(regclass, text, text) FROM PUBLIC, hk_app;
-- کمک‌تابع‌های DDL و ابزار نگهداری (فقط migrator)
REVOKE EXECUTE ON FUNCTION core.attach_actor_via_guard(regclass), core.purge_tenant(uuid, text), core.import_verify(uuid)
  FROM PUBLIC, hk_app;
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['core.job_claim(text[],text,integer,integer,integer)', 'core.job_reap_expired(integer)',
                           'core.outbox_claim(text[],text,integer,integer,integer)', 'core.schedule_due(integer)',
                           'core.schedule_fire(uuid,timestamptz,timestamptz,boolean)', 'core.purge_ephemeral(integer)']
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM hk_app, PUBLIC', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO hk_dispatcher', f);
  END LOOP;
END $$;
GRANT EXECUTE ON FUNCTION core.raise_hk(text, text), core.job_backoff_seconds(integer, integer, integer),
                          core.current_tenant_id(), core.current_user_id() TO hk_dispatcher;
