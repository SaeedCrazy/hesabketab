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

-- ---------- نقش‌های بدون ورود (مالک توابع SECURITY DEFINER؛ هیچ‌کدام BYPASSRLS ندارند) ----------
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hk_audit_writer') THEN
    CREATE ROLE hk_audit_writer NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hk_core_definer') THEN
    CREATE ROLE hk_core_definer NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
  END IF;
  -- نقش فرایند dispatcher/scheduler (قرارداد بخش ۰۱ §۴-۳): دید سراسری فقط روی جدول‌های صف؛ گذرواژهٔ توسعه مثل پایه
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hk_dispatcher') THEN
    CREATE ROLE hk_dispatcher LOGIN PASSWORD 'hk_dispatcher' NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
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
  security_epoch      integer NOT NULL DEFAULT 1 CHECK (security_epoch >= 1),
  mfa_required        boolean NOT NULL DEFAULT false,
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
  UNIQUE (kind, value),
  CHECK (   (kind = 'phone'    AND value ~ '^09[0-9]{9}$')
         OR (kind = 'email'    AND value = lower(value) AND value ~ '^[^@ ]+@[^@ ]+\.[^@ ]+$' AND char_length(value) <= 254)
         OR (kind = 'username' AND value ~ '^[a-z0-9][a-z0-9._-]{2,62}$'))
);
CREATE INDEX IF NOT EXISTS user_login_identifier_user_idx ON core.user_login_identifier (user_id);

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
  FOREIGN KEY (active_tenant_id, device_id) REFERENCES core.device(tenant_id, id),
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
                             CHECK (scope_dimensions <@ ARRAY['company','branch','warehouse','cash_box','pos_terminal','cost_center']::text[]),
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
  dimension        text NOT NULL CHECK (dimension IN ('company','branch','warehouse','cash_box','pos_terminal','cost_center')),
  company_id       uuid,
  branch_id        uuid,
  warehouse_id     uuid,   -- FK بین‌ماژولی: inventory.warehouse (بخش ۱۲)
  cash_box_id      uuid,   -- FK بین‌ماژولی: treasury.cash_box
  pos_terminal_id  uuid,   -- FK بین‌ماژولی: pos.terminal
  cost_center_id   uuid,   -- FK بین‌ماژولی: ledger.dimension_value
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, assignment_id) REFERENCES core.role_assignment(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, branch_id) REFERENCES core.branch(tenant_id, id),
  CHECK (num_nonnulls(company_id, branch_id, warehouse_id, cash_box_id, pos_terminal_id, cost_center_id) = 1),
  CHECK ((dimension = 'company')      = (company_id IS NOT NULL)),
  CHECK ((dimension = 'branch')       = (branch_id IS NOT NULL)),
  CHECK ((dimension = 'warehouse')    = (warehouse_id IS NOT NULL)),
  CHECK ((dimension = 'cash_box')     = (cash_box_id IS NOT NULL)),
  CHECK ((dimension = 'pos_terminal') = (pos_terminal_id IS NOT NULL)),
  CHECK ((dimension = 'cost_center')  = (cost_center_id IS NOT NULL))
);
SELECT core.enable_tenant_rls('core.role_assignment_scope');
CREATE UNIQUE INDEX IF NOT EXISTS role_assignment_scope_uniq ON core.role_assignment_scope
  (tenant_id, assignment_id, dimension, coalesce(company_id, branch_id, warehouse_id, cash_box_id, pos_terminal_id, cost_center_id));

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
  expires_after       interval,
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
  chain_no                  smallint NOT NULL DEFAULT 0,
  seq                       bigint NOT NULL,
  occurred_at               timestamptz NOT NULL DEFAULT now(),
  recorded_at               timestamptz NOT NULL,
  actor_kind                text NOT NULL CHECK (actor_kind IN ('user','service','device','system','platform_staff')),
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
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, chain_no, seq),
  FOREIGN KEY (tenant_id, chain_no) REFERENCES core.audit_chain_head(tenant_id, chain_no),
  CHECK (seq >= 1),
  CHECK (actor_kind NOT IN ('user','service') OR actor_user_id IS NOT NULL),
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
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, series_id, period_key, value),
  UNIQUE (tenant_id, series_id, period_key, formatted),
  FOREIGN KEY (tenant_id, series_id, period_key) REFERENCES core.number_counter(tenant_id, series_id, period_key),
  FOREIGN KEY (tenant_id, reservation_id) REFERENCES core.number_reservation(tenant_id, id),
  FOREIGN KEY (tenant_id, device_id) REFERENCES core.device(tenant_id, id),
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
  UNIQUE (tenant_id, id)
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
  UNIQUE (seq)
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
  UNIQUE (tenant_id, code)
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
  tenant_overridable boolean NOT NULL DEFAULT true,
  UNIQUE (code, channel, locale),
  CHECK (sms_pattern_code IS NULL OR channel = 'sms'),
  CHECK (sms_pattern_code IS NULL OR NOT tenant_overridable)
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
                                   AND signature IS NOT NULL AND signing_key_id IS NOT NULL AND completed_at IS NOT NULL)),
  CHECK (object_key IS NULL OR object_key LIKE 't/' || tenant_id::text || '/exports/%')
);
SELECT core.enable_tenant_rls('core.tenant_export');

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
  response_status  smallint CHECK (response_status BETWEEN 200 AND 599),    -- NULL فقط درون تراکنش
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
-- عضو بودن: کاربر عضویت‌های خودش را در همهٔ مستأجرها می‌بیند (انتخاب مستأجر)
DROP POLICY IF EXISTS member_self_select ON core.tenant_membership;
CREATE POLICY member_self_select ON core.tenant_membership FOR SELECT
  USING (user_id = core.current_user_id());
-- پذیرش دعوت با app.tenant_id همان مستأجر انجام می‌شود؛ سیاست بالا فقط خواندن است.

-- مستأجرهایی که کاربر عضو فعال آن‌هاست (نام و slug برای انتخاب‌گر مستأجر)
DROP POLICY IF EXISTS tenant_member_read ON core.tenant;
CREATE POLICY tenant_member_read ON core.tenant FOR SELECT
  USING (EXISTS (SELECT 1 FROM core.tenant_membership m
                  WHERE m.tenant_id = tenant.id AND m.user_id = core.current_user_id()
                    AND m.status IN ('active','invited')));

-- app_user
ALTER TABLE core.app_user ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.app_user FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS user_select ON core.app_user;
CREATE POLICY user_select ON core.app_user FOR SELECT USING (
  id = core.current_user_id()
  OR home_tenant_id = core.current_tenant_id()
  OR EXISTS (SELECT 1 FROM core.tenant_membership m
              WHERE m.user_id = app_user.id AND m.tenant_id = core.current_tenant_id()));
DROP POLICY IF EXISTS user_insert ON core.app_user;
CREATE POLICY user_insert ON core.app_user FOR INSERT WITH CHECK (
  id = core.current_user_id() OR core.current_tenant_id() IS NOT NULL);
DROP POLICY IF EXISTS user_update ON core.app_user;
CREATE POLICY user_update ON core.app_user FOR UPDATE
  USING (id = core.current_user_id() OR home_tenant_id = core.current_tenant_id())
  WITH CHECK (id = core.current_user_id() OR home_tenant_id = core.current_tenant_id());
DROP POLICY IF EXISTS definer_read ON core.app_user;
CREATE POLICY definer_read ON core.app_user FOR SELECT TO hk_core_definer USING (true);

-- user_login_identifier
ALTER TABLE core.user_login_identifier ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.user_login_identifier FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS uli_select ON core.user_login_identifier;
CREATE POLICY uli_select ON core.user_login_identifier FOR SELECT USING (
  user_id = core.current_user_id()
  OR EXISTS (SELECT 1 FROM core.tenant_membership m
              WHERE m.user_id = user_login_identifier.user_id AND m.tenant_id = core.current_tenant_id()));
DROP POLICY IF EXISTS uli_insert ON core.user_login_identifier;
CREATE POLICY uli_insert ON core.user_login_identifier FOR INSERT WITH CHECK (
  user_id = core.current_user_id() OR core.current_tenant_id() IS NOT NULL);
DROP POLICY IF EXISTS uli_update ON core.user_login_identifier;
CREATE POLICY uli_update ON core.user_login_identifier FOR UPDATE
  USING (user_id = core.current_user_id()) WITH CHECK (user_id = core.current_user_id());
DROP POLICY IF EXISTS uli_delete ON core.user_login_identifier;
CREATE POLICY uli_delete ON core.user_login_identifier FOR DELETE USING (user_id = core.current_user_id());
DROP POLICY IF EXISTS definer_read ON core.user_login_identifier;
CREATE POLICY definer_read ON core.user_login_identifier FOR SELECT TO hk_core_definer USING (true);

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

-- حل توکن (definer): فقط خواندن ردیف‌های لازم
DROP POLICY IF EXISTS definer_read ON core.user_session;
CREATE POLICY definer_read ON core.user_session FOR SELECT TO hk_core_definer USING (true);
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

-- ---------- عضویت: ماشین حالت + حداقل یک مالک فعال ----------
CREATE OR REPLACE FUNCTION core.membership_transition_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.tenant_id <> OLD.tenant_id OR NEW.user_id <> OLD.user_id OR NEW.id <> OLD.id THEN
    PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'membership identity columns are immutable');
  END IF;
  IF NEW.status <> OLD.status THEN
    IF NOT ((OLD.status, NEW.status) IN (('invited','active'),('invited','removed'),('active','suspended'),
             ('suspended','active'),('active','removed'),('suspended','removed'),('removed','invited'))) THEN
      PERFORM core.raise_hk('HK_CORE_INVALID_TRANSITION', format('membership %s -> %s', OLD.status, NEW.status));
    END IF;
    NEW.status_changed_at := now();
    IF NEW.status = 'active' AND NEW.joined_at IS NULL THEN NEW.joined_at := now(); END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_transition ON core.tenant_membership;
CREATE TRIGGER trg_transition BEFORE UPDATE ON core.tenant_membership
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
DECLARE s record; v_max smallint;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'pending' OR NEW.current_step <> 1 THEN
      PERFORM core.raise_hk('HK_APPROVAL_INVALID', 'new approval request must start pending at step 1');
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(NEW.steps_snapshot) AS x(step_no smallint, min_approvals smallint)
                WHERE x.step_no IS NULL OR x.min_approvals IS NULL OR x.min_approvals < 1)
       OR (SELECT array_agg(x.step_no ORDER BY x.step_no) FROM jsonb_to_recordset(NEW.steps_snapshot) AS x(step_no smallint))
          <> (SELECT array_agg(g::smallint) FROM generate_series(1, jsonb_array_length(NEW.steps_snapshot)) g) THEN
      PERFORM core.raise_hk('HK_APPROVAL_INVALID', 'steps_snapshot must list steps 1..n with min_approvals >= 1');
    END IF;
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
     OR NEW.amount IS DISTINCT FROM OLD.amount OR NEW.currency IS DISTINCT FROM OLD.currency THEN
    PERFORM core.raise_hk('HK_CORE_IMMUTABLE_FIELD', 'approval request subject/snapshot is immutable');
  END IF;
  v_max := jsonb_array_length(OLD.steps_snapshot);

  IF NEW.status = 'pending' THEN
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
    NEW.decided_at := now();
  ELSIF NEW.status = 'rejected' THEN
    IF NOT EXISTS (SELECT 1 FROM core.approval_decision WHERE tenant_id = OLD.tenant_id AND request_id = OLD.id AND decision = 'reject') THEN
      PERFORM core.raise_hk('HK_APPROVAL_INVALID', 'rejection requires a reject decision');
    END IF;
    NEW.decided_at := now();
  ELSE  -- cancelled / expired
    NEW.decided_at := now();
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.approval_request;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON core.approval_request
  FOR EACH ROW EXECUTE FUNCTION core.approval_request_guard();

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
  SELECT * INTO s FROM jsonb_to_recordset(r.steps_snapshot)
         AS x(step_no smallint, approver_kind text, role_id uuid, user_id uuid, permission_code text, min_approvals smallint)
   WHERE x.step_no = NEW.step_no;
  IF s.approver_kind = 'user' AND NEW.decided_by <> s.user_id THEN
    PERFORM core.raise_hk('HK_APPROVAL_NOT_ELIGIBLE', 'decider is not the designated approver');
  ELSIF s.approver_kind = 'role' AND NOT EXISTS (
          SELECT 1 FROM core.role_assignment ra
            JOIN core.tenant_membership m ON m.tenant_id = ra.tenant_id AND m.id = ra.membership_id
           WHERE ra.tenant_id = NEW.tenant_id AND m.user_id = NEW.decided_by AND m.status = 'active'
             AND ra.role_id = s.role_id AND ra.revoked_at IS NULL
             AND ra.valid_from <= now() AND (ra.valid_to IS NULL OR ra.valid_to > now())) THEN
    PERFORM core.raise_hk('HK_APPROVAL_NOT_ELIGIBLE', 'decider does not hold the approver role');
  END IF;
  -- approver_kind = 'permission': بررسی در سرویس (AuthzService) با دامنهٔ شرکت
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON core.approval_decision;
CREATE TRIGGER trg_guard BEFORE INSERT ON core.approval_decision
  FOR EACH ROW EXECUTE FUNCTION core.approval_decision_guard();

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
  IF p_from_seq = 1 THEN
    v_prev := core.audit_genesis_hash(v_tenant, p_chain_no);
  ELSE
    SELECT a.row_hash INTO v_prev FROM core.audit_log a
     WHERE a.tenant_id = v_tenant AND a.chain_no = p_chain_no AND a.seq = p_from_seq - 1;
    IF NOT FOUND THEN seq := p_from_seq - 1; problem := 'missing_predecessor'; RETURN NEXT; RETURN; END IF;
  END IF;
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
DECLARE v_next bigint; v_start bigint;
BEGIN
  SELECT c.next_value, s.start_value INTO v_next, v_start
    FROM core.number_counter c JOIN core.number_series s ON s.tenant_id = c.tenant_id AND s.id = c.series_id
   WHERE c.tenant_id = NEW.tenant_id AND c.series_id = NEW.series_id AND c.period_key = NEW.period_key;
  IF NEW.value < v_start OR NEW.value >= v_next THEN
    PERFORM core.raise_hk('HK_NUM_OUT_OF_RANGE', format('value %s outside allocated range [%s,%s)', NEW.value, v_start, v_next));
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

-- گرفتن شمارهٔ بعدی در همان تراکنش ثبت سند (قفل ردیف شمارنده تا پایان تراکنش)
CREATE OR REPLACE FUNCTION core.number_next(p_series_id uuid, p_period_key text, p_template text,
                                            p_doc_type text, p_doc_id uuid)
RETURNS TABLE (number_id uuid, value bigint, formatted text)
LANGUAGE plpgsql AS $$
DECLARE s core.number_series; v bigint; f text; nid uuid;
BEGIN
  SELECT * INTO s FROM core.number_series WHERE id = p_series_id;
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

-- رزرو بازه برای دستگاه آفلاین
CREATE OR REPLACE FUNCTION core.number_reserve_range(p_series_id uuid, p_period_key text, p_device_id uuid, p_size integer)
RETURNS core.number_reservation
LANGUAGE plpgsql AS $$
DECLARE s core.number_series; v_start bigint; r core.number_reservation;
BEGIN
  IF p_size < 1 OR p_size > 100000 THEN PERFORM core.raise_hk('HK_NUM_RANGE_SIZE', 'range size must be 1..100000'); END IF;
  SELECT * INTO s FROM core.number_series WHERE id = p_series_id;
  IF NOT FOUND OR NOT s.is_active THEN PERFORM core.raise_hk('HK_NUM_SERIES_NOT_FOUND', 'active series not found'); END IF;
  IF s.allocation <> 'reserved_ranges' THEN PERFORM core.raise_hk('HK_NUM_NOT_RANGE_ALLOCATED', 'series does not use reserved ranges'); END IF;
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

-- ثبت شمارهٔ صادرشده روی دستگاه (سری دستگاه یا بازهٔ رزرو)
CREATE OR REPLACE FUNCTION core.number_record_external(p_series_id uuid, p_period_key text, p_value bigint, p_formatted text,
                                                       p_doc_type text, p_doc_id uuid, p_device_id uuid,
                                                       p_reservation_id uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE s core.number_series; r core.number_reservation; nid uuid;
BEGIN
  SELECT * INTO s FROM core.number_series WHERE id = p_series_id;
  IF NOT FOUND THEN PERFORM core.raise_hk('HK_NUM_SERIES_NOT_FOUND', 'number series not found'); END IF;
  IF s.doc_type <> p_doc_type THEN PERFORM core.raise_hk('HK_NUM_DOC_TYPE', 'doc_type does not match the series'); END IF;
  IF s.allocation = 'device' THEN
    IF s.device_id <> p_device_id THEN PERFORM core.raise_hk('HK_NUM_DEVICE', 'series belongs to another device'); END IF;
    INSERT INTO core.number_counter (tenant_id, series_id, period_key, next_value)
    VALUES (s.tenant_id, s.id, p_period_key, s.start_value)
    ON CONFLICT (tenant_id, series_id, period_key) DO NOTHING;
    UPDATE core.number_counter c SET next_value = greatest(c.next_value, p_value + 1), updated_at = now()
     WHERE c.tenant_id = s.tenant_id AND c.series_id = s.id AND c.period_key = p_period_key;
  ELSIF s.allocation = 'reserved_ranges' THEN
    SELECT * INTO r FROM core.number_reservation WHERE id = p_reservation_id FOR SHARE;
    IF NOT FOUND OR r.series_id <> s.id OR r.period_key <> p_period_key OR r.device_id <> p_device_id
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

-- ابطال شمارهٔ مصرف‌نشده (فقط سری دستگاه/بازه؛ سری سرور هرگز شمارهٔ بی‌سند ندارد)
CREATE OR REPLACE FUNCTION core.number_void(p_series_id uuid, p_period_key text, p_value bigint, p_reason text)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE s core.number_series; nid uuid;
BEGIN
  SELECT * INTO s FROM core.number_series WHERE id = p_series_id;
  IF NOT FOUND THEN PERFORM core.raise_hk('HK_NUM_SERIES_NOT_FOUND', 'number series not found'); END IF;
  IF s.allocation = 'server' THEN PERFORM core.raise_hk('HK_NUM_SERVER_ALLOCATED', 'server-allocated numbers are never voided'); END IF;
  IF p_reason IS NULL OR char_length(btrim(p_reason)) < 5 THEN PERFORM core.raise_hk('HK_NUM_VOID_REASON', 'reason required'); END IF;
  INSERT INTO core.number_issued (tenant_id, series_id, period_key, value, formatted, status, void_reason, issued_by)
  VALUES (s.tenant_id, s.id, p_period_key, p_value, '#void:' || p_value::text, 'voided', p_reason, core.current_user_id())
  RETURNING id INTO nid;
  RETURN nid;
END $$;

-- بستن رزرو: همهٔ شماره‌های مصرف‌نشدهٔ بازه ابطال می‌شوند تا هیچ عددی بی‌حساب نماند
CREATE OR REPLACE FUNCTION core.number_close_reservation(p_reservation_id uuid, p_reason text)
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE r core.number_reservation; n integer;
BEGIN
  SELECT * INTO r FROM core.number_reservation WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND OR r.status <> 'active' THEN PERFORM core.raise_hk('HK_NUM_RESERVATION', 'active reservation not found'); END IF;
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

-- اعداد بی‌حساب در بازهٔ تخصیص‌یافته. برای سری سرور همیشه باید خالی باشد.
CREATE OR REPLACE FUNCTION core.number_gaps(p_series_id uuid, p_period_key text)
RETURNS SETOF bigint
LANGUAGE sql STABLE AS $$
  SELECT g FROM core.number_counter c
    JOIN core.number_series s ON s.tenant_id = c.tenant_id AND s.id = c.series_id
    CROSS JOIN LATERAL generate_series(s.start_value, c.next_value - 1) g
   WHERE c.series_id = p_series_id AND c.period_key = p_period_key
     AND NOT EXISTS (SELECT 1 FROM core.number_issued i
                      WHERE i.tenant_id = c.tenant_id AND i.series_id = c.series_id
                        AND i.period_key = c.period_key AND i.value = g)
     AND NOT EXISTS (SELECT 1 FROM core.number_reservation r
                      WHERE r.tenant_id = c.tenant_id AND r.series_id = c.series_id AND r.period_key = c.period_key
                        AND r.status = 'active' AND g BETWEEN r.range_start AND r.range_end)
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

-- رله‌گر (hk_dispatcher): انصاف بین مستأجرها با row_number؛ ترتیب سخت برای مشترک ordered
CREATE OR REPLACE FUNCTION core.outbox_claim(p_subscribers text[], p_worker text, p_n integer,
                                             p_lease_seconds integer DEFAULT 60, p_per_tenant integer DEFAULT 10)
RETURNS TABLE (tenant_id uuid, event_id uuid, subscriber text, event_seq bigint, attempts integer)
LANGUAGE sql AS $$
WITH cand AS (
  SELECT x.tenant_id, x.event_id, x.subscriber, x.next_attempt_at, x.event_seq FROM (
    SELECT d.tenant_id, d.event_id, d.subscriber, d.next_attempt_at, d.event_seq,
           row_number() OVER (PARTITION BY d.tenant_id ORDER BY d.next_attempt_at, d.event_seq) AS rn_tenant
      FROM core.outbox_delivery d
      JOIN core.event_subscriber s ON s.subscriber = d.subscriber AND s.enabled
     WHERE d.subscriber = ANY (p_subscribers) AND d.status = 'pending' AND d.next_attempt_at <= now()
       AND (NOT s.ordered OR NOT EXISTS (
             SELECT 1 FROM core.outbox_delivery y
              WHERE y.subscriber = d.subscriber AND y.tenant_id = d.tenant_id
                AND y.aggregate_id = d.aggregate_id AND y.event_seq < d.event_seq AND y.status <> 'done'))
  ) x
  WHERE x.rn_tenant <= p_per_tenant
  ORDER BY x.next_attempt_at, x.event_seq
  LIMIT p_n * 4
), locked AS (
  SELECT d.tenant_id, d.event_id, d.subscriber
    FROM core.outbox_delivery d
    JOIN cand c ON c.tenant_id = d.tenant_id AND c.event_id = d.event_id AND c.subscriber = d.subscriber
   WHERE d.status = 'pending'
   ORDER BY c.next_attempt_at, c.event_seq
   FOR UPDATE OF d SKIP LOCKED
   LIMIT p_n
)
UPDATE core.outbox_delivery d
   SET status = 'running', lease_owner = p_worker,
       lease_expires_at = now() + make_interval(secs => p_lease_seconds), attempts = d.attempts + 1
  FROM locked l
 WHERE d.tenant_id = l.tenant_id AND d.event_id = l.event_id AND d.subscriber = l.subscriber
RETURNING d.tenant_id, d.event_id, d.subscriber, d.event_seq, d.attempts
$$;

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

-- =====================================================================
-- ۲۰. زمان‌بند، پاک‌سازی (اجرا با hk_dispatcher؛ SECURITY INVOKER) و حل توکن (SECURITY DEFINER)
-- =====================================================================
-- زمان‌بندی‌های سررسیده (قفل SKIP LOCKED تا پایان تراکنش زمان‌بند)
CREATE OR REPLACE FUNCTION core.schedule_due(p_limit integer DEFAULT 100) RETURNS SETOF core.job_schedule
LANGUAGE sql AS $$
  SELECT * FROM core.job_schedule WHERE is_enabled AND next_fire_at <= now()
   ORDER BY next_fire_at LIMIT p_limit FOR UPDATE SKIP LOCKED
$$;

-- یک نوبت: job با dedupe_key = '<schedule_id>:<fire_at>' (قرارداد ۰۱)، سپس پیشبرد next_fire_at.
-- p_fire = false وقتی jalali_filter با روز نوبت نمی‌خواند (پایتون تعیین می‌کند): فقط پیشبرد.
CREATE OR REPLACE FUNCTION core.schedule_fire(p_schedule_id uuid, p_fire_at timestamptz, p_next_fire_at timestamptz,
                                              p_fire boolean DEFAULT true)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE s core.job_schedule; jid uuid;
BEGIN
  SELECT * INTO s FROM core.job_schedule WHERE id = p_schedule_id FOR UPDATE;
  IF NOT FOUND THEN PERFORM core.raise_hk('HK_SCHEDULE_NOT_FOUND', 'schedule not found'); END IF;
  IF p_next_fire_at <= p_fire_at THEN PERFORM core.raise_hk('HK_SCHEDULE_NEXT', 'next_fire_at must be after the fire time'); END IF;
  IF p_fire THEN
    INSERT INTO core.job (tenant_id, queue, kind, payload, run_after, dedupe_key, max_attempts, schedule_id, created_by)
    VALUES (s.tenant_id, s.queue, s.kind, s.payload || jsonb_build_object('scheduled_for', p_fire_at), p_fire_at,
            s.id::text || ':' || p_fire_at::text, s.max_attempts, s.id, s.created_by)
    ON CONFLICT DO NOTHING
    RETURNING id INTO jid;
    UPDATE core.job_schedule SET last_fired_at = p_fire_at WHERE id = s.id;
  END IF;
  UPDATE core.job_schedule SET next_fire_at = p_next_fire_at WHERE id = s.id;
  RETURN jid;
END $$;

-- پاک‌سازی دوره‌ای دادهٔ گذرا (همهٔ مستأجرها؛ کار سیستمی maintenance.*؛ دوره‌ها از قرارداد ۰۱)
CREATE OR REPLACE FUNCTION core.purge_ephemeral(p_limit integer DEFAULT 5000) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE r jsonb := '{}'; n integer;
BEGIN
  DELETE FROM core.idempotency_key WHERE id IN (SELECT id FROM core.idempotency_key WHERE expires_at < now() LIMIT p_limit);
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('idempotency_key', n);
  DELETE FROM core.job WHERE id IN (
    SELECT id FROM core.job
     WHERE (status = 'succeeded' AND finished_at < now() - interval '30 days')
        OR (status IN ('failed','dead','cancelled') AND finished_at < now() - interval '180 days')
     LIMIT p_limit);
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('job', n);
  DELETE FROM core.outbox_delivery WHERE (tenant_id, event_id, subscriber) IN (
    SELECT tenant_id, event_id, subscriber FROM core.outbox_delivery
     WHERE status = 'done' AND done_at < now() - interval '90 days' LIMIT p_limit);
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('outbox_delivery', n);
  DELETE FROM core.outbox_event o WHERE o.id IN (
    SELECT x.id FROM core.outbox_event x
     WHERE x.occurred_at < now() - interval '90 days'
       AND NOT EXISTS (SELECT 1 FROM core.outbox_delivery d WHERE d.tenant_id = x.tenant_id AND d.event_id = x.id)
       AND NOT EXISTS (SELECT 1 FROM core.webhook_delivery w WHERE w.tenant_id = x.tenant_id AND w.event_id = x.id)
     LIMIT p_limit);
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('outbox_event', n);
  DELETE FROM core.otp_challenge WHERE id IN (SELECT id FROM core.otp_challenge WHERE expires_at < now() - interval '1 day' LIMIT p_limit);
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('otp_challenge', n);
  DELETE FROM core.device_token WHERE id IN (SELECT id FROM core.device_token WHERE expires_at < now() - interval '1 day' LIMIT p_limit);
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('device_token', n);
  DELETE FROM core.auth_event WHERE id IN (SELECT id FROM core.auth_event WHERE occurred_at < now() - interval '365 days' LIMIT p_limit);
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('auth_event', n);
  DELETE FROM core.rate_limit_counter WHERE window_start < now() - interval '1 day';
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('rate_limit_counter', n);
  RETURN r;
END $$;

-- ورود: شناسهٔ نرمال‌شده → شناسهٔ کاربر (سرویس زمان پاسخ را یکسان می‌کند)
CREATE OR REPLACE FUNCTION core.auth_resolve_login(p_kind text, p_value text) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT i.user_id FROM core.user_login_identifier i JOIN core.app_user u ON u.id = i.user_id
   WHERE i.kind = p_kind AND i.value = p_value AND u.status = 'active' AND u.kind = 'human'
$$;

-- کلید API: پیشوند عمومی → (مستأجر، کلید)؛ مقایسهٔ hash راز با RLS عادی در سرویس
CREATE OR REPLACE FUNCTION core.auth_resolve_api_key(p_prefix text)
RETURNS TABLE (tenant_id uuid, api_key_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT k.tenant_id, k.id FROM core.api_key k
   WHERE k.prefix = p_prefix AND k.revoked_at IS NULL AND k.expires_at > now()
$$;

-- توکن کدر (کوکی نشست، توکن دستگاه، توکن ورود به‌جای کاربر): sha256(token) → شناسه‌ها.
-- فقط شناسه برمی‌گرداند؛ سرویس سپس app.user_id/app.tenant_id را می‌گذارد و ردیف را با RLS عادی می‌خواند.
CREATE OR REPLACE FUNCTION core.auth_resolve_token(p_kind text, p_token_hash bytea)
RETURNS TABLE (ref_id uuid, user_id uuid, tenant_id uuid, expires_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT s.id, s.user_id, s.active_tenant_id, least(s.absolute_expires_at, s.last_seen_at + make_interval(secs => s.idle_timeout_seconds))
    FROM core.user_session s
   WHERE p_kind = 'session' AND s.token_hash = p_token_hash AND s.revoked_at IS NULL
     AND s.absolute_expires_at > now() AND s.last_seen_at + make_interval(secs => s.idle_timeout_seconds) > now()
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
      'HK_DEFINER_REVIEWED: 2026-11-17 section 02; returns identifiers only, fixed search_path, no dynamic SQL');
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

-- =====================================================================
-- ۲۱. بازرسی امنیتی ساختار (اجرا در CI؛ خروجی باید خالی باشد)
-- =====================================================================
CREATE OR REPLACE FUNCTION core.security_lint() RETURNS TABLE (object text, problem text)
LANGUAGE sql STABLE AS $$
WITH app_schemas AS (
  SELECT unnest(ARRAY['ref','core','ledger','parties','catalog','inventory','sales','purchase','treasury',
                      'pos','tax','payroll','assets','rules','migration','reports']) AS nspname
), tenant_tables AS (
  SELECT c.oid, c.oid::regclass::text AS name, c.relrowsecurity, c.relforcerowsecurity, n.nspname, c.relname
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN app_schemas s ON s.nspname = n.nspname
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
   WHERE c.relkind IN ('r','p')
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
SELECT r.rolname, 'app_role_privileged' FROM pg_roles r
 WHERE r.rolname IN ('hk_app','hk_readonly','hk_audit_writer','hk_core_definer','hk_dispatcher') AND (r.rolsuper OR r.rolbypassrls)
UNION ALL
SELECT c.oid::regclass::text, 'app_role_owns_relation'
  FROM pg_class c JOIN pg_roles r ON r.oid = c.relowner WHERE r.rolname IN ('hk_app','hk_readonly','hk_dispatcher')
UNION ALL
SELECT t.tgrelid::regclass::text, 'append_only_table_grants_update_or_delete'
  FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid AND p.proname = 'forbid_mutation'
 WHERE NOT t.tgisinternal
   AND (   ((t.tgtype & 16) <> 0 AND has_table_privilege('hk_app', t.tgrelid, 'UPDATE'))
        OR ((t.tgtype & 8)  <> 0 AND has_table_privilege('hk_app', t.tgrelid, 'DELETE')))
UNION ALL
SELECT name, 'tenant_table_not_in_export_registry' FROM tenant_tables t
 WHERE NOT EXISTS (SELECT 1 FROM core.export_table_registry r WHERE r.schema_name = t.nspname AND r.table_name = t.relname)
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
  ('core.member.contact.read', 'core', '{}', 'sensitive', true, false, 'perm.core.member.contact.read', '1.0')
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
 WHERE module = 'core' AND code NOT IN ('core.export.create','core.export.download','core.support_access.grant','core.legal_hold.manage')
UNION ALL SELECT 'auditor', code FROM core.permission WHERE code IN
  ('core.member.read','core.role.read','core.audit.read','core.audit.verify','core.numbering.read','core.setting.read',
   'core.custom_field.read','core.attachment.read','core.approval.request.read','core.impersonation.read','core.job.read')
UNION ALL SELECT 'support_readonly', code FROM core.permission WHERE code IN
  ('core.member.read','core.role.read','core.audit.read','core.numbering.read','core.setting.read',
   'core.custom_field.read','core.attachment.read','core.approval.request.read','core.job.read')
UNION ALL SELECT t.code, p.code FROM core.role_template t CROSS JOIN core.permission p
 WHERE t.code IN ('member','accountant','cashier','sales_clerk','purchaser','warehouse_keeper','payroll_officer')
   AND p.code IN ('core.setting.self','core.notification.self','core.attachment.read','core.custom_field.read')
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
  ('core.otp',                 'core.security', 'sms',    'fa-IR', NULL, 'کد ورود شما: {code}', 'hk-otp', '{code}', false),
  ('core.new_login',           'core.security', 'in_app', 'fa-IR', 'ورود جدید', 'ورود جدید از {client} در {time}', NULL, '{client,time}', false),
  ('core.impersonation_start', 'core.support',  'in_app', 'fa-IR', 'دسترسی پشتیبانی', 'پشتیبان {staff} به دلیل «{reason}» تا {until} وارد حساب شد.', NULL, '{staff,reason,until}', false),
  ('core.approval_needed',     'core.approval', 'in_app', 'fa-IR', 'درخواست تأیید', '{subject} منتظر تأیید شماست.', NULL, '{subject}', true),
  ('core.job_dead',            'core.system',   'in_app', 'fa-IR', 'خطای پردازش', 'کار {kind} پس از {attempts} تلاش متوقف شد.', NULL, '{kind,attempts}', true)
ON CONFLICT DO NOTHING;

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
  ('core.authz.changed',            'core.authz.cache_invalidate')
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
  ('core','impersonation_session', 'core', 'rows', 260, '{}', '{}', NULL),
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
  ('core','custom_field_index',    'core', 'skip', 0,   '{}', '{}', 'derived; rebuilt by triggers on import'),
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
  ('core','idempotency_key',       'core', 'skip', 0,   '{}', '{}', 'ephemeral (days)')
ON CONFLICT DO NOTHING;

-- =====================================================================
-- ۲۳. دسترسی‌ها (کمینه)
-- =====================================================================
-- کاتالوگ‌ها: فقط خواندن
GRANT SELECT ON core.permission, core.role_template, core.role_template_permission, core.field_guard,
                core.setting_def, core.custom_field_entity, core.event_subscriber, core.event_subscription,
                core.job_queue, core.notification_category, core.notification_template_def,
                core.export_table_registry, core.retention_class
  TO hk_app, hk_readonly, hk_dispatcher;

-- فقط‌افزودنی: SELECT, INSERT
GRANT SELECT, INSERT ON core.audit_log, core.audit_checkpoint, core.audit_anchor, core.number_issued,
                        core.approval_decision, core.setting_history, core.auth_event, core.outbox_event,
                        core.tenant_import
  TO hk_app;

-- تغییرپذیر بدون حذف
GRANT SELECT, INSERT, UPDATE ON core.app_user, core.user_credential, core.user_session,
                                core.otp_challenge, core.tenant_membership, core.membership_invitation, core.device,
                                core.member_pin, core.device_token, core.api_key, core.role, core.role_assignment,
                                core.sod_rule, core.approval_policy, core.approval_request, core.support_access_grant,
                                core.impersonation_session, core.number_series, core.number_counter,
                                core.number_reservation, core.custom_field_def, core.attachment, core.webhook_endpoint,
                                core.webhook_delivery, core.job, core.job_tenant_state, core.job_schedule,
                                core.outbox_delivery, core.idempotency_key, core.notification,
                                core.notification_preference, core.tenant_export, core.retention_override,
                                core.legal_hold, core.data_subject_request
  TO hk_app;
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
GRANT SELECT, DELETE ON core.outbox_event, core.idempotency_key, core.webhook_delivery,
                        core.auth_event, core.otp_challenge, core.device_token TO hk_dispatcher;
GRANT DELETE ON core.outbox_delivery TO hk_dispatcher;
GRANT SELECT, INSERT, UPDATE, DELETE ON core.rate_limit_counter TO hk_dispatcher;
GRANT SELECT (id, slug, status) ON core.tenant TO hk_dispatcher;
GRANT SELECT, INSERT, UPDATE ON core.system_task_run TO hk_dispatcher;

-- نقش‌های مالک توابع
GRANT SELECT, INSERT, UPDATE ON core.audit_chain_head TO hk_audit_writer;
GRANT SELECT ON core.app_user, core.user_login_identifier, core.api_key, core.user_session, core.device_token,
                core.device, core.impersonation_session TO hk_core_definer;

-- فقط‌خواندنی: همه‌چیز جز ستون‌های راز
GRANT SELECT ON ALL TABLES IN SCHEMA core TO hk_readonly;
REVOKE SELECT ON core.user_credential, core.user_recovery_code, core.user_session, core.otp_challenge,
                 core.member_pin, core.device_token, core.api_key, core.webhook_endpoint, core.membership_invitation,
                 core.device, core.impersonation_session, core.system_task_run
  FROM hk_readonly;
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
