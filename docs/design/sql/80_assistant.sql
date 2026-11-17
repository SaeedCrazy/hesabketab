-- =====================================================================
-- حساب‌کتاب — 80_assistant.sql
-- اسکیمای assistant: دستیار هوشمند با ارائه‌دهندهٔ مدل قابل تنظیم (سند: docs/design/10-assistant.md)
--
-- پیش‌نیاز (به همین ترتیب): 00_foundation.sql، 10_core.sql، 20_ledger.sql، 25_masterdata.sql
-- اجرا با نقش migrator/superuser. برنامه با hk_app (نه مالک، NOBYPASSRLS) کار می‌کند.
--
-- اصل‌های ساختاری این فایل:
--   ۱. دستیار هیچ دادهٔ تجاری بیرون از اسکیمای خودش نمی‌نویسد؛ هر فراخوانی ابزارِ آغازشده با مدل در تراکنش
--      READ ONLY و با app.actor_via='assistant' اجرا می‌شود و این اسکیما هر نوشتنی را در آن حالت رد می‌کند.
--   ۲. هیچ اجرایی (run) و هیچ فراخوانی مدلی (llm_call) بدون سیاست فعال مستأجر، رضایت فعال پردازش داده
--      و بودجهٔ کافی درج نمی‌شود (تریگر؛ کلید قطع مستأجر در پایگاه داده اثر دارد).
--   ۳. مصرف توکن و هزینه مشتق است (جمع llm_call)، نه شمارندهٔ قابل‌انحراف.
--   ۴. محتوای گفت‌وگو فقط برای صاحبش دیده می‌شود (policy محدودکننده) و حذف رشته همهٔ محتوا را می‌برد،
--      ولی ردیف‌های سنجش مصرف (run، llm_call) می‌مانند.
-- =====================================================================

DO $$
BEGIN
  IF current_setting('server_encoding') <> 'UTF8' THEN
    RAISE EXCEPTION 'HK_ENCODING: data-plane database must be UTF8 (found %)', current_setting('server_encoding');
  END IF;
  IF to_regprocedure('core.raise_hk(text,text)') IS NULL OR to_regclass('core.tenant_membership') IS NULL THEN
    RAISE EXCEPTION 'HK_PREREQ: 10_core.sql must be applied before 80_assistant.sql';
  END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS assistant;
GRANT USAGE ON SCHEMA assistant TO hk_app, hk_readonly;

-- =====================================================================
-- ۱. توابع کمکی
-- =====================================================================

-- حالت منشأ تراکنش: 'direct' (کاربر یا سیستم)، 'assistant' (فراخوانی ابزار به درخواست مدل)،
-- 'assistant_confirm' (تأیید انسانی یک پیشنهاد). UoW آن را با set_config('app.actor_via', ..., true) می‌گذارد.
CREATE OR REPLACE FUNCTION assistant.actor_via() RETURNS text
LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT coalesce(nullif(current_setting('app.actor_via', true), ''), 'direct')
$$;

-- تراکنش زیر ورود به‌جای کاربر (درخواست تغییر C-AS-03: هسته app.impersonation_session_id را می‌گذارد)
CREATE OR REPLACE FUNCTION assistant.impersonating() RETURNS boolean
LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT coalesce(current_setting('app.impersonation_session_id', true), '') <> ''
$$;

-- میزبان یک URL (حروف کوچک)؛ برای اثرانگشت ارائه‌دهنده
CREATE OR REPLACE FUNCTION assistant.url_host(p_url text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT lower(substring(p_url FROM '^[A-Za-z][A-Za-z0-9+.-]*://([^/:?#@]+)'))
$$;

-- اثرانگشت مقصد داده (اپراتور + میزبان + محل داده). مدل در آن نیست: عوض شدن مدلِ همان اپراتور رضایت تازه نمی‌خواهد،
-- عوض شدن مقصد داده می‌خواهد. همتای پایتون: hesabketab.assistant.domain.provider.fingerprint (بردار در آزمون).
CREATE OR REPLACE FUNCTION assistant.provider_fingerprint(p_operator text, p_base_url text, p_data_location text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT encode(sha256(convert_to('hkllm1|' || lower(btrim(p_operator)) || '|' || coalesce(assistant.url_host(p_base_url), '')
                                  || '|' || p_data_location, 'UTF8')), 'hex')
$$;

-- تاریخ امروز مستأجر (منطقهٔ زمانی core.tenant)
CREATE OR REPLACE FUNCTION assistant.tenant_today(p_tenant uuid) RETURNS date
LANGUAGE sql STABLE AS $$
  SELECT (now() AT TIME ZONE coalesce((SELECT t.timezone FROM core.tenant t WHERE t.id = p_tenant), 'Asia/Tehran'))::date
$$;

-- هر عضو آرایه با الگوی اثرانگشت می‌خواند
CREATE OR REPLACE FUNCTION assistant.all_hex64(p text[]) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT p IS NOT NULL AND NOT EXISTS (SELECT 1 FROM unnest(p) x WHERE x IS NULL OR x !~ '^[0-9a-f]{64}$')
$$;

-- hash متن jsonb (پایگاه داده UTF8 است؛ پس تبدیل رمزگذاری ثابت است)
CREATE OR REPLACE FUNCTION assistant.jsonb_sha256(p jsonb) RETURNS bytea
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT sha256(convert_to(p::text, 'UTF8'))
$$;

-- تریگر عمومی: در تراکنشی که از مدل آغاز شده (app.actor_via='assistant') هیچ نوشتنی در این اسکیما مجاز نیست.
-- TG_ARGV[0] = 'allow_confirm' یعنی حالت 'assistant_confirm' (تأیید انسانی پیشنهاد) مجاز است.
CREATE OR REPLACE FUNCTION assistant.forbid_via_assistant() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v text := assistant.actor_via();
BEGIN
  IF v = 'assistant' OR (v = 'assistant_confirm' AND coalesce(TG_ARGV[0], '') <> 'allow_confirm')
     OR v NOT IN ('direct', 'assistant', 'assistant_confirm') THEN
    PERFORM core.raise_hk('HK_AST_VIA_ASSISTANT',
      format('%s on %s.%s is not allowed in an assistant-originated transaction (actor_via=%s)', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME, v));
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;

-- =====================================================================
-- ۲. کاتالوگ‌ها (سراسری، بدون tenant_id؛ نویسنده: migration؛ hk_app فقط SELECT)
-- =====================================================================

-- ردهٔ داده‌ای که ممکن است به ارائه‌دهندهٔ مدل برود. 'prohibited' هرگز قابل رضایت نیست.
CREATE TABLE IF NOT EXISTS assistant.data_class (
  code             text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{2,40}$'),
  sensitivity      text NOT NULL CHECK (sensitivity IN ('low','medium','high','prohibited')),
  grantable        boolean NOT NULL,
  description_key  text NOT NULL,
  CHECK (grantable = (sensitivity <> 'prohibited'))
);

-- هدف پردازش (رضایت برای هر هدف جداست)
CREATE TABLE IF NOT EXISTS assistant.purpose (
  code             text PRIMARY KEY CHECK (code IN ('chat','migration_mapping','voice_transcription','document_ocr','insight_narration')),
  phase            text NOT NULL CHECK (phase IN ('v1','v2','later')),
  feature          text NOT NULL CHECK (feature IN ('chat','migration_mapping','voice','ocr','insights')),
  description_key  text NOT NULL
);

-- نوع پیشنهاد و شیوهٔ تحقق آن با تأیید انسان
CREATE TABLE IF NOT EXISTS assistant.proposal_kind (
  code             text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{2,40}$'),
  target_module    text NOT NULL CHECK (target_module ~ '^[a-z][a-z0-9_]*$'),
  materialization  text NOT NULL CHECK (materialization IN ('server_draft','human_send','client_prefill')),
  ttl              interval NOT NULL CHECK (ttl BETWEEN interval '1 hour' AND interval '30 days'),
  phase            text NOT NULL CHECK (phase IN ('v1','v2','later')),
  description_key  text NOT NULL
);

-- رجیستری ابزارهای مجاز (همتای رجیستری پایتون؛ «catalog diff» آن‌ها را برابر نگه می‌دارد)
CREATE TABLE IF NOT EXISTS assistant.tool (
  code                   text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  version                integer NOT NULL CHECK (version >= 1),
  kind                   text NOT NULL CHECK (kind IN ('query','proposal','utility')),
  module                 text NOT NULL CHECK (module ~ '^[a-z][a-z0-9_]*$'),
  service_ref            text NOT NULL CHECK (service_ref ~ '^hesabketab(\.[a-z_][a-z0-9_]*)+:[A-Z][A-Za-z0-9]*\.[a-z_][a-z0-9_]*$'),
  data_classes           text[] NOT NULL DEFAULT '{}',
  optional_data_classes  text[] NOT NULL DEFAULT '{}',
  proposal_kind          text REFERENCES assistant.proposal_kind(code),
  max_result_bytes       integer NOT NULL DEFAULT 16384 CHECK (max_result_bytes BETWEEN 256 AND 65536),
  max_rows               smallint NOT NULL DEFAULT 20 CHECK (max_rows BETWEEN 0 AND 100),
  phase                  text NOT NULL CHECK (phase IN ('v1','v2','later')),
  introduced_in          text NOT NULL,
  deprecated_at          timestamptz,
  CHECK ((kind = 'proposal') = (proposal_kind IS NOT NULL)),
  CHECK (kind <> 'utility' OR (cardinality(data_classes) = 0 AND cardinality(optional_data_classes) = 0 AND module = 'assistant')),
  CHECK (kind = 'utility' OR split_part(code, '.', 1) = module)
);

-- مجوزهای هر ابزار. requirement:
--   read           در فراخوانی مدل بررسی و اعمال می‌شود (فقط فعل read)
--   read_optional  فیلدهای اضافه (مثلاً بها) فقط اگر کاربر دارد؛ وگرنه پوشانده می‌شوند (فقط فعل read)
--   materialize    فقط هنگام تأیید انسانی پیشنهاد اعمال می‌شود (فعل create یا send؛ فقط ابزار پیشنهاد)
-- بدون FK به core.permission: مجوز ماژول‌های دیگر با همگام‌سازی کاتالوگ می‌آید؛ catalog_lint نبودش را گزارش می‌کند
-- و در زمان اجرا مجوزِ نبوده یعنی ابزار در دسترس نیست (fail-closed).
CREATE TABLE IF NOT EXISTS assistant.tool_permission (
  tool_code        text NOT NULL REFERENCES assistant.tool(code),
  permission_code  text NOT NULL CHECK (permission_code ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){2,3}$'),
  requirement      text NOT NULL CHECK (requirement IN ('read','read_optional','materialize')),
  PRIMARY KEY (tool_code, permission_code),
  CHECK (requirement = 'materialize' OR permission_code ~ '\.read$'),
  CHECK (requirement <> 'materialize' OR permission_code ~ '\.(create|send)$')
);

-- پیشنهادهای آغاز گفت‌وگو (عمومی یا برای بستهٔ صنفی). FK به rules.industry_pack در §۱۲ سند.
CREATE TABLE IF NOT EXISTS assistant.prompt_suggestion (
  id              uuid PRIMARY KEY DEFAULT uuidv7(),
  code            text NOT NULL UNIQUE CHECK (code ~ '^[a-z][a-z0-9_.]{2,80}$'),
  pack_code       text CHECK (pack_code ~ '^[a-z][a-z0-9_]{1,40}$'),
  page_context    text NOT NULL DEFAULT 'dock' CHECK (page_context ~ '^[a-z][a-z0-9_.]{1,60}$'),
  locale          text NOT NULL DEFAULT 'fa-IR' CHECK (locale IN ('fa-IR','en-US')),
  text            text NOT NULL CHECK (char_length(text) BETWEEN 4 AND 200),
  required_tools  text[] NOT NULL CHECK (cardinality(required_tools) BETWEEN 1 AND 4),
  sort_order      smallint NOT NULL DEFAULT 100,
  active          boolean NOT NULL DEFAULT true,
  CHECK (text = core.fa_normalize_text(text))
);

CREATE OR REPLACE FUNCTION assistant.tool_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE k assistant.proposal_kind;
BEGIN
  IF EXISTS (SELECT 1 FROM unnest(NEW.data_classes || NEW.optional_data_classes) c
              WHERE NOT EXISTS (SELECT 1 FROM assistant.data_class d WHERE d.code = c AND d.grantable)) THEN
    PERFORM core.raise_hk('HK_AST_CATALOG', format('tool %s uses an unknown or prohibited data class', NEW.code));
  END IF;
  IF NEW.data_classes && NEW.optional_data_classes THEN
    PERFORM core.raise_hk('HK_AST_CATALOG', format('tool %s: required and optional data classes overlap', NEW.code));
  END IF;
  IF NEW.kind = 'proposal' THEN
    SELECT * INTO k FROM assistant.proposal_kind WHERE code = NEW.proposal_kind;
    IF k.target_module <> NEW.module THEN
      PERFORM core.raise_hk('HK_AST_CATALOG', format('proposal tool %s must belong to the target module %s', NEW.code, k.target_module));
    END IF;
  END IF;
  IF TG_OP = 'UPDATE' AND (NEW.kind <> OLD.kind OR NEW.module <> OLD.module) THEN
    PERFORM core.raise_hk('HK_AST_CATALOG', format('tool %s: kind and module are immutable (create a new code)', NEW.code));
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.version < OLD.version THEN
    PERFORM core.raise_hk('HK_AST_CATALOG', format('tool %s: version must not decrease', NEW.code));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS tool_guard ON assistant.tool;
CREATE TRIGGER tool_guard BEFORE INSERT OR UPDATE ON assistant.tool FOR EACH ROW EXECUTE FUNCTION assistant.tool_guard();

-- سقف مجوز دستیار: هیچ مجوز critical؛ ابزار utility هیچ مجوزی ندارد؛ materialize فقط برای ابزار پیشنهاد
CREATE OR REPLACE FUNCTION assistant.tool_permission_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE t assistant.tool; v_risk text;
BEGIN
  SELECT * INTO t FROM assistant.tool WHERE code = NEW.tool_code;
  IF t.kind = 'utility' THEN
    PERFORM core.raise_hk('HK_AST_CEILING_VERB', format('utility tool %s must not hold permissions', NEW.tool_code));
  END IF;
  IF NEW.requirement = 'materialize' AND t.kind <> 'proposal' THEN
    PERFORM core.raise_hk('HK_AST_CEILING_VERB', format('only proposal tools may declare materialize permissions (%s)', NEW.tool_code));
  END IF;
  SELECT p.risk INTO v_risk FROM core.permission p WHERE p.code = NEW.permission_code;
  IF v_risk = 'critical' THEN
    PERFORM core.raise_hk('HK_AST_CEILING_CRITICAL', format('critical permission %s can never be in the assistant ceiling', NEW.permission_code));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS tool_permission_guard ON assistant.tool_permission;
CREATE TRIGGER tool_permission_guard BEFORE INSERT OR UPDATE ON assistant.tool_permission
  FOR EACH ROW EXECUTE FUNCTION assistant.tool_permission_guard();

CREATE OR REPLACE FUNCTION assistant.prompt_suggestion_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM unnest(NEW.required_tools) x WHERE NOT EXISTS (SELECT 1 FROM assistant.tool t WHERE t.code = x)) THEN
    PERFORM core.raise_hk('HK_AST_CATALOG', format('suggestion %s references an unknown tool', NEW.code));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS prompt_suggestion_guard ON assistant.prompt_suggestion;
CREATE TRIGGER prompt_suggestion_guard BEFORE INSERT OR UPDATE ON assistant.prompt_suggestion
  FOR EACH ROW EXECUTE FUNCTION assistant.prompt_suggestion_guard();

-- =====================================================================
-- ۳. سیاست مستأجر (از حالت مطلوب امضاشدهٔ صفحهٔ کنترل یا فایل لایسنس On-prem)
-- =====================================================================
CREATE TABLE IF NOT EXISTS assistant.tenant_policy (
  tenant_id               uuid NOT NULL REFERENCES core.tenant(id),
  id                      uuid NOT NULL DEFAULT uuidv7(),
  policy_version          bigint NOT NULL CHECK (policy_version >= 1),
  source                  text NOT NULL CHECK (source IN ('desired_state','license','dev_fixture')),
  document                jsonb NOT NULL CHECK (jsonb_typeof(document) = 'object'),
  document_sha256         bytea GENERATED ALWAYS AS (assistant.jsonb_sha256(document)) STORED,
  signature               bytea NOT NULL CHECK (octet_length(signature) = 64),          -- Ed25519 روی سند متعارف
  signer_kid              text NOT NULL CHECK (char_length(signer_kid) BETWEEN 3 AND 80),
  entitled                boolean NOT NULL,                                               -- پلن یا لایسنس
  platform_enabled        boolean NOT NULL,                                               -- کلید قطع مستأجر در پنل مالک
  kill_reason             text CHECK (kill_reason IS NULL OR char_length(kill_reason) BETWEEN 3 AND 300),
  features                text[] NOT NULL DEFAULT '{}'
                          CHECK (features <@ ARRAY['chat','proposals','migration_mapping','voice','ocr','insights']::text[]),
  profile_code            text CHECK (profile_code ~ '^[a-z][a-z0-9_.-]{1,60}$'),
  profile_version         integer CHECK (profile_version >= 1),
  profile_fingerprint     text CHECK (profile_fingerprint ~ '^[0-9a-f]{64}$'),
  secondary_fingerprints  text[] NOT NULL DEFAULT '{}' CHECK (assistant.all_hex64(secondary_fingerprints) AND cardinality(secondary_fingerprints) <= 4),
  allow_tenant_provider   boolean NOT NULL DEFAULT false,
  tenant_monthly_tokens   bigint CHECK (tenant_monthly_tokens > 0),                       -- NULL = نامحدود
  tenant_monthly_cost     core.amount CHECK (tenant_monthly_cost > 0),
  cost_unit               core.amount_unit NOT NULL DEFAULT 'IRR',
  user_monthly_tokens     bigint CHECK (user_monthly_tokens > 0),
  max_concurrent_runs     smallint NOT NULL DEFAULT 3 CHECK (max_concurrent_runs BETWEEN 1 AND 100),
  max_rounds              smallint NOT NULL DEFAULT 6 CHECK (max_rounds BETWEEN 1 AND 16),
  max_tool_calls          smallint NOT NULL DEFAULT 12 CHECK (max_tool_calls BETWEEN 1 AND 32),
  applied_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  row_version             integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id),
  CHECK ((profile_code IS NULL) = (profile_fingerprint IS NULL)),
  CHECK ((profile_code IS NULL) = (profile_version IS NULL)),
  CHECK (platform_enabled OR kill_reason IS NOT NULL),
  CHECK (NOT (entitled AND platform_enabled) OR profile_fingerprint IS NOT NULL OR allow_tenant_provider)
);
SELECT core.enable_tenant_rls('assistant.tenant_policy');

CREATE OR REPLACE FUNCTION assistant.tenant_policy_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.tenant_id <> OLD.tenant_id OR NEW.id <> OLD.id THEN
      PERFORM core.raise_hk('HK_AST_POLICY_VERSION', 'tenant policy identity is immutable');
    END IF;
    IF NEW.policy_version <= OLD.policy_version THEN
      PERFORM core.raise_hk('HK_AST_POLICY_VERSION',
        format('policy_version must increase (%s -> %s); replayed or stale desired state', OLD.policy_version, NEW.policy_version));
    END IF;
    NEW.applied_at := now();
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS "0_via_assistant" ON assistant.tenant_policy;
CREATE TRIGGER "0_via_assistant" BEFORE INSERT OR UPDATE OR DELETE ON assistant.tenant_policy
  FOR EACH ROW EXECUTE FUNCTION assistant.forbid_via_assistant();
DROP TRIGGER IF EXISTS tenant_policy_guard ON assistant.tenant_policy;
CREATE TRIGGER tenant_policy_guard BEFORE INSERT OR UPDATE ON assistant.tenant_policy
  FOR EACH ROW EXECUTE FUNCTION assistant.tenant_policy_guard();
DROP TRIGGER IF EXISTS trg_touch ON assistant.tenant_policy;
CREATE TRIGGER trg_touch BEFORE UPDATE ON assistant.tenant_policy FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- =====================================================================
-- ۴. ارائه‌دهندهٔ مستأجر (On-prem یا BYO وقتی سیاست اجازه دهد)
-- =====================================================================
CREATE TABLE IF NOT EXISTS assistant.tenant_provider (
  tenant_id               uuid NOT NULL REFERENCES core.tenant(id),
  id                      uuid NOT NULL DEFAULT uuidv7(),
  display_name            text NOT NULL CHECK (char_length(display_name) BETWEEN 2 AND 80),
  operator                text NOT NULL CHECK (char_length(btrim(operator)) BETWEEN 2 AND 120),
  data_location           text NOT NULL CHECK (data_location IN ('lan','iran','other')),
  base_url                text NOT NULL CHECK (char_length(base_url) <= 300
                            AND base_url ~ '^https?://[A-Za-z0-9.-]+(:[0-9]{2,5})?(/[A-Za-z0-9._~/-]*)?$'),
  model                   text NOT NULL CHECK (model ~ '^[A-Za-z0-9._:/@+-]{1,120}$'),
  auth_header             text NOT NULL DEFAULT 'authorization_bearer' CHECK (auth_header IN ('authorization_bearer','x_api_key','none')),
  api_key_sealed          bytea CHECK (api_key_sealed IS NULL OR octet_length(api_key_sealed) BETWEEN 32 AND 4096),   -- SealedBlob
  allow_private_network   boolean NOT NULL DEFAULT false,
  connect_timeout_ms      integer NOT NULL DEFAULT 5000 CHECK (connect_timeout_ms BETWEEN 500 AND 30000),
  first_token_timeout_ms  integer NOT NULL DEFAULT 30000 CHECK (first_token_timeout_ms BETWEEN 1000 AND 120000),
  total_timeout_ms        integer NOT NULL DEFAULT 90000 CHECK (total_timeout_ms BETWEEN 5000 AND 300000),
  max_output_tokens       integer NOT NULL DEFAULT 1024 CHECK (max_output_tokens BETWEEN 64 AND 32768),
  max_context_tokens      integer NOT NULL DEFAULT 16384 CHECK (max_context_tokens BETWEEN 2048 AND 1048576),
  capabilities            jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(capabilities) = 'object'),
  price_unit              core.amount_unit NOT NULL DEFAULT 'IRR',
  input_price_per_mtok    core.amount NOT NULL DEFAULT 0 CHECK (input_price_per_mtok >= 0),
  output_price_per_mtok   core.amount NOT NULL DEFAULT 0 CHECK (output_price_per_mtok >= 0),
  fingerprint             text GENERATED ALWAYS AS (assistant.provider_fingerprint(operator, base_url, data_location)) STORED,
  status                  text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','active','disabled')),
  last_probe_at           timestamptz,
  last_probe_ok           boolean,
  last_probe_report       jsonb CHECK (last_probe_report IS NULL OR jsonb_typeof(last_probe_report) = 'object'),
  created_by              uuid NOT NULL,
  updated_by              uuid,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  row_version             integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, updated_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (base_url ~ '^https://' OR allow_private_network),
  CHECK (data_location <> 'lan' OR allow_private_network),
  CHECK ((auth_header = 'none') = (api_key_sealed IS NULL)),
  CHECK (total_timeout_ms >= first_token_timeout_ms),
  CHECK (status <> 'active' OR (last_probe_ok IS TRUE AND last_probe_at IS NOT NULL))
);
SELECT core.enable_tenant_rls('assistant.tenant_provider');
CREATE UNIQUE INDEX IF NOT EXISTS tenant_provider_one_active ON assistant.tenant_provider (tenant_id) WHERE status = 'active';

CREATE OR REPLACE FUNCTION assistant.tenant_provider_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_allowed boolean;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.tenant_id <> OLD.tenant_id OR NEW.id <> OLD.id OR NEW.created_by <> OLD.created_by OR NEW.created_at <> OLD.created_at THEN
      PERFORM core.raise_hk('HK_AST_PROVIDER_STATE', 'provider identity columns are immutable');
    END IF;
    IF (NEW.operator, NEW.base_url, NEW.data_location, NEW.model, NEW.auth_header, NEW.allow_private_network, NEW.api_key_sealed)
       IS DISTINCT FROM (OLD.operator, OLD.base_url, OLD.data_location, OLD.model, OLD.auth_header, OLD.allow_private_network, OLD.api_key_sealed) THEN
      IF OLD.status = 'active' THEN
        PERFORM core.raise_hk('HK_AST_PROVIDER_STATE', 'destination or credentials of an active provider cannot change; disable it first');
      END IF;
      -- هر تغییر مقصد یعنی آزمون اتصال دوباره
      NEW.last_probe_ok := NULL; NEW.last_probe_at := NULL; NEW.last_probe_report := NULL;
    END IF;
    IF NOT (OLD.status = NEW.status OR (OLD.status, NEW.status) IN (('draft','active'),('active','disabled'),('disabled','active'),('draft','disabled'))) THEN
      PERFORM core.raise_hk('HK_AST_PROVIDER_STATE', format('provider transition %s -> %s is not allowed', OLD.status, NEW.status));
    END IF;
    NEW.updated_by := core.current_user_id();
  END IF;
  IF NEW.status = 'active' AND (TG_OP = 'INSERT' OR OLD.status <> 'active') THEN
    SELECT p.allow_tenant_provider INTO v_allowed FROM assistant.tenant_policy p WHERE p.tenant_id = NEW.tenant_id;
    IF v_allowed IS NOT TRUE THEN
      PERFORM core.raise_hk('HK_AST_PROVIDER', 'tenant-managed providers are not allowed by the tenant policy (plan/license)');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS "0_via_assistant" ON assistant.tenant_provider;
CREATE TRIGGER "0_via_assistant" BEFORE INSERT OR UPDATE OR DELETE ON assistant.tenant_provider
  FOR EACH ROW EXECUTE FUNCTION assistant.forbid_via_assistant();
DROP TRIGGER IF EXISTS tenant_provider_guard ON assistant.tenant_provider;
CREATE TRIGGER tenant_provider_guard BEFORE INSERT OR UPDATE ON assistant.tenant_provider
  FOR EACH ROW EXECUTE FUNCTION assistant.tenant_provider_guard();
DROP TRIGGER IF EXISTS trg_touch ON assistant.tenant_provider;
CREATE TRIGGER trg_touch BEFORE UPDATE ON assistant.tenant_provider FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- =====================================================================
-- ۵. رضایت پردازش داده (opt-in مستأجر)
-- =====================================================================
CREATE TABLE IF NOT EXISTS assistant.consent (
  tenant_id              uuid NOT NULL REFERENCES core.tenant(id),
  id                     uuid NOT NULL DEFAULT uuidv7(),
  status                 text NOT NULL DEFAULT 'active' CHECK (status IN ('active','revoked','superseded')),
  purposes               text[] NOT NULL CHECK (cardinality(purposes) BETWEEN 1 AND 5),
  data_classes           text[] NOT NULL CHECK (cardinality(data_classes) BETWEEN 1 AND 12),
  provider_fingerprints  text[] NOT NULL CHECK (cardinality(provider_fingerprints) BETWEEN 1 AND 5 AND assistant.all_hex64(provider_fingerprints)),
  provider_summary       jsonb NOT NULL CHECK (jsonb_typeof(provider_summary) = 'array' AND jsonb_array_length(provider_summary) >= 1),
  consent_text_code      text NOT NULL CHECK (consent_text_code ~ '^assistant\.consent\.v[0-9]{1,3}$'),
  consent_text_sha256    bytea NOT NULL CHECK (octet_length(consent_text_sha256) = 32),
  granted_by             uuid NOT NULL,
  granted_at             timestamptz NOT NULL DEFAULT now(),
  signer_full_name       text NOT NULL CHECK (char_length(btrim(signer_full_name)) BETWEEN 3 AND 120),
  signer_capacity        text NOT NULL CHECK (signer_capacity IN ('owner','legal_representative','authorized_admin')),
  mfa_at                 timestamptz NOT NULL,
  ended_at               timestamptz,
  ended_by               uuid,
  end_reason             text,
  superseded_by          uuid,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, granted_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, ended_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, superseded_by) REFERENCES assistant.consent(tenant_id, id) DEFERRABLE INITIALLY DEFERRED,
  CHECK ((status = 'active') = (ended_at IS NULL)),
  CHECK (status <> 'revoked' OR (ended_by IS NOT NULL AND char_length(btrim(coalesce(end_reason, ''))) >= 3)),
  CHECK ((status = 'superseded') = (superseded_by IS NOT NULL)),
  CHECK (mfa_at <= granted_at AND mfa_at >= granted_at - interval '15 minutes')
);
SELECT core.enable_tenant_rls('assistant.consent');
CREATE UNIQUE INDEX IF NOT EXISTS consent_one_active ON assistant.consent (tenant_id) WHERE status = 'active';

CREATE OR REPLACE FUNCTION assistant.consent_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF assistant.impersonating() THEN
    PERFORM core.raise_hk('HK_AST_IMPERSONATION', 'consent cannot be granted or revoked under impersonation');
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'active' OR NEW.ended_at IS NOT NULL OR NEW.superseded_by IS NOT NULL THEN
      PERFORM core.raise_hk('HK_AST_CONSENT_STATE', 'a consent is created active');
    END IF;
    IF NEW.granted_by IS DISTINCT FROM core.current_user_id() THEN
      PERFORM core.raise_hk('HK_AST_CONSENT_STATE', 'consent must be granted by the current user');
    END IF;
    NEW.granted_at := now();
    IF EXISTS (SELECT 1 FROM unnest(NEW.purposes) x WHERE NOT EXISTS (SELECT 1 FROM assistant.purpose p WHERE p.code = x)) THEN
      PERFORM core.raise_hk('HK_AST_CONSENT_SCOPE', 'unknown purpose in consent');
    END IF;
    IF EXISTS (SELECT 1 FROM unnest(NEW.data_classes) x
                WHERE NOT EXISTS (SELECT 1 FROM assistant.data_class d WHERE d.code = x AND d.grantable)) THEN
      PERFORM core.raise_hk('HK_AST_CONSENT_SCOPE', 'consent names an unknown or prohibited data class');
    END IF;
    -- رضایت تازه رضایت فعال قبلی را جایگزین می‌کند (در همین تراکنش)
    UPDATE assistant.consent SET status = 'superseded', superseded_by = NEW.id, ended_at = now()
     WHERE tenant_id = NEW.tenant_id AND status = 'active';
    RETURN NEW;
  END IF;
  -- UPDATE
  IF OLD.status <> 'active' THEN
    PERFORM core.raise_hk('HK_AST_CONSENT_STATE', format('consent in state %s is final', OLD.status));
  END IF;
  IF (NEW.tenant_id, NEW.id, NEW.purposes, NEW.data_classes, NEW.provider_fingerprints, NEW.provider_summary, NEW.consent_text_code,
      NEW.consent_text_sha256, NEW.granted_by, NEW.granted_at, NEW.signer_full_name, NEW.signer_capacity, NEW.mfa_at)
     IS DISTINCT FROM
     (OLD.tenant_id, OLD.id, OLD.purposes, OLD.data_classes, OLD.provider_fingerprints, OLD.provider_summary, OLD.consent_text_code,
      OLD.consent_text_sha256, OLD.granted_by, OLD.granted_at, OLD.signer_full_name, OLD.signer_capacity, OLD.mfa_at) THEN
    PERFORM core.raise_hk('HK_AST_CONSENT_STATE', 'consent terms are immutable; grant a new consent instead');
  END IF;
  IF NEW.status = 'revoked' THEN
    IF NEW.ended_by IS DISTINCT FROM core.current_user_id() THEN
      PERFORM core.raise_hk('HK_AST_CONSENT_STATE', 'consent must be revoked by the current user');
    END IF;
    NEW.ended_at := now();
  ELSIF NEW.status = 'superseded' THEN
    IF pg_trigger_depth() < 2 THEN
      PERFORM core.raise_hk('HK_AST_CONSENT_STATE', 'consent is superseded only by granting a new consent');
    END IF;
  ELSIF NEW.status = 'active' THEN
    PERFORM core.raise_hk('HK_AST_CONSENT_STATE', 'an active consent can only be revoked or superseded');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS "0_via_assistant" ON assistant.consent;
CREATE TRIGGER "0_via_assistant" BEFORE INSERT OR UPDATE OR DELETE ON assistant.consent
  FOR EACH ROW EXECUTE FUNCTION assistant.forbid_via_assistant();
DROP TRIGGER IF EXISTS consent_guard ON assistant.consent;
CREATE TRIGGER consent_guard BEFORE INSERT OR UPDATE ON assistant.consent FOR EACH ROW EXECUTE FUNCTION assistant.consent_guard();

-- =====================================================================
-- ۶. دورهٔ مصرف (سقف توکن و هزینه برای مستأجر و هر کاربر). مقدار مصرف‌شده ستون نیست؛ از llm_call مشتق می‌شود.
-- =====================================================================
CREATE TABLE IF NOT EXISTS assistant.usage_period (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  scope         text NOT NULL CHECK (scope IN ('tenant','user')),
  user_id       uuid,
  period_start  date NOT NULL,
  period_end    date NOT NULL,                                 -- انحصاری
  token_limit   bigint CHECK (token_limit > 0),                -- NULL = بی‌سقف
  cost_limit    core.amount CHECK (cost_limit > 0),
  cost_unit     core.amount_unit NOT NULL DEFAULT 'IRR',
  limit_source  text NOT NULL CHECK (limit_source IN ('policy','setting','unlimited')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  row_version   integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE NULLS NOT DISTINCT (tenant_id, scope, user_id, period_start),
  FOREIGN KEY (tenant_id, user_id) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK ((scope = 'user') = (user_id IS NOT NULL)),
  CHECK (period_end > period_start AND period_end <= period_start + 62),
  CHECK ((limit_source = 'unlimited') = (token_limit IS NULL AND cost_limit IS NULL)),
  EXCLUDE USING gist (tenant_id WITH =, scope WITH =,
                      (coalesce(user_id, '00000000-0000-0000-0000-000000000000'::uuid)) WITH =,
                      daterange(period_start, period_end, '[)') WITH &&)
);
SELECT core.enable_tenant_rls('assistant.usage_period');

CREATE OR REPLACE FUNCTION assistant.usage_period_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.period_end >= current_date - 400 THEN
      PERFORM core.raise_hk('HK_AST_RETENTION', 'usage periods are kept at least 400 days after they end');
    END IF;
    RETURN OLD;
  END IF;
  IF (NEW.tenant_id, NEW.id, NEW.scope, NEW.user_id, NEW.period_start, NEW.period_end, NEW.cost_unit, NEW.created_at)
     IS DISTINCT FROM (OLD.tenant_id, OLD.id, OLD.scope, OLD.user_id, OLD.period_start, OLD.period_end, OLD.cost_unit, OLD.created_at) THEN
    PERFORM core.raise_hk('HK_AST_USAGE_IMMUTABLE', 'only the limits of a usage period may change');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS "0_via_assistant" ON assistant.usage_period;
CREATE TRIGGER "0_via_assistant" BEFORE INSERT OR UPDATE OR DELETE ON assistant.usage_period
  FOR EACH ROW EXECUTE FUNCTION assistant.forbid_via_assistant();
DROP TRIGGER IF EXISTS usage_period_guard ON assistant.usage_period;
CREATE TRIGGER usage_period_guard BEFORE UPDATE OR DELETE ON assistant.usage_period
  FOR EACH ROW EXECUTE FUNCTION assistant.usage_period_guard();
DROP TRIGGER IF EXISTS trg_touch ON assistant.usage_period;
CREATE TRIGGER trg_touch BEFORE UPDATE ON assistant.usage_period FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- =====================================================================
-- ۷. رشتهٔ گفت‌وگو (محتوا؛ فقط صاحب می‌بیند)
-- =====================================================================
CREATE TABLE IF NOT EXISTS assistant.thread (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  user_id           uuid NOT NULL,
  company_id        uuid NOT NULL,
  title             text NOT NULL DEFAULT 'گفت‌وگوی تازه' CHECK (char_length(title) BETWEEN 1 AND 120 AND title = core.fa_normalize_text(title)),
  status            text NOT NULL DEFAULT 'active' CHECK (status IN ('active','archived')),
  page_context      text CHECK (page_context ~ '^[a-z][a-z0-9_.]{1,60}$'),
  message_count     integer NOT NULL DEFAULT 0 CHECK (message_count BETWEEN 0 AND 2000),
  last_activity_at  timestamptz NOT NULL DEFAULT now(),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  row_version       integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, id, user_id),
  FOREIGN KEY (tenant_id, user_id) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id)
);
SELECT core.enable_tenant_rls('assistant.thread');
CREATE INDEX IF NOT EXISTS thread_owner_idx ON assistant.thread (tenant_id, user_id, last_activity_at DESC);
CREATE INDEX IF NOT EXISTS thread_created_idx ON assistant.thread (tenant_id, created_at);

-- فقط صاحب رشته (یا زمینهٔ سیستمی بدون کاربر: نگهداری، انقضا، حذف دادهٔ شخصی، صدور) ردیف را می‌بیند. ساختن فقط با صاحب.
CREATE OR REPLACE FUNCTION assistant.owner_visible(p_user uuid) RETURNS boolean
LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT p_user = core.current_user_id() OR core.current_user_id() IS NULL
$$;
-- policy محدودکنندهٔ «فقط صاحب» برای هر جدول محتوا: درج فقط با خود صاحب؛ خواندن، تغییر و حذف با صاحب یا زمینهٔ سیستمی
CREATE OR REPLACE FUNCTION assistant.enable_owner_only(tbl regclass) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('DROP POLICY IF EXISTS owner_select ON %s', tbl);
  EXECUTE format('DROP POLICY IF EXISTS owner_insert ON %s', tbl);
  EXECUTE format('DROP POLICY IF EXISTS owner_update ON %s', tbl);
  EXECUTE format('DROP POLICY IF EXISTS owner_delete ON %s', tbl);
  EXECUTE format('CREATE POLICY owner_select ON %s AS RESTRICTIVE FOR SELECT USING (assistant.owner_visible(user_id))', tbl);
  EXECUTE format('CREATE POLICY owner_insert ON %s AS RESTRICTIVE FOR INSERT WITH CHECK (user_id = core.current_user_id())', tbl);
  EXECUTE format('CREATE POLICY owner_update ON %s AS RESTRICTIVE FOR UPDATE USING (assistant.owner_visible(user_id)) '
                 'WITH CHECK (assistant.owner_visible(user_id))', tbl);
  EXECUTE format('CREATE POLICY owner_delete ON %s AS RESTRICTIVE FOR DELETE USING (assistant.owner_visible(user_id))', tbl);
END $$;
SELECT assistant.enable_owner_only('assistant.thread');

CREATE OR REPLACE FUNCTION assistant.thread_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.message_count <> 0 THEN
      PERFORM core.raise_hk('HK_AST_THREAD_IMMUTABLE', 'a new thread has no messages');
    END IF;
    NEW.created_at := now(); NEW.last_activity_at := now(); NEW.updated_at := now(); NEW.row_version := 1;
    RETURN NEW;
  END IF;
  IF (NEW.tenant_id, NEW.id, NEW.user_id, NEW.company_id, NEW.created_at)
     IS DISTINCT FROM (OLD.tenant_id, OLD.id, OLD.user_id, OLD.company_id, OLD.created_at) THEN
    PERFORM core.raise_hk('HK_AST_THREAD_IMMUTABLE', 'thread owner, company and creation time are immutable');
  END IF;
  IF pg_trigger_depth() >= 2 THEN
    -- از تریگر پیام: فقط شمارنده یکی بالا و زمان فعالیت
    IF NEW.message_count <> OLD.message_count + 1 OR (NEW.title, NEW.status, NEW.page_context) IS DISTINCT FROM (OLD.title, OLD.status, OLD.page_context) THEN
      PERFORM core.raise_hk('HK_AST_THREAD_IMMUTABLE', 'message bookkeeping may only advance the counter');
    END IF;
    NEW.row_version := OLD.row_version; NEW.updated_at := OLD.updated_at;
  ELSE
    IF NEW.message_count <> OLD.message_count OR NEW.last_activity_at <> OLD.last_activity_at THEN
      PERFORM core.raise_hk('HK_AST_THREAD_IMMUTABLE', 'message_count and last_activity_at are maintained by messages');
    END IF;
    NEW.row_version := OLD.row_version + 1; NEW.updated_at := now();
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS "0_via_assistant" ON assistant.thread;
CREATE TRIGGER "0_via_assistant" BEFORE INSERT OR UPDATE OR DELETE ON assistant.thread
  FOR EACH ROW EXECUTE FUNCTION assistant.forbid_via_assistant();
DROP TRIGGER IF EXISTS thread_guard ON assistant.thread;
CREATE TRIGGER thread_guard BEFORE INSERT OR UPDATE ON assistant.thread FOR EACH ROW EXECUTE FUNCTION assistant.thread_guard();

-- =====================================================================
-- ۸. اجرا (یک نوبت پرسش) — ردیف سنجش؛ پس از حذف رشته با thread_id = NULL می‌ماند
-- =====================================================================
CREATE TABLE IF NOT EXISTS assistant.run (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  thread_id            uuid,
  user_id              uuid NOT NULL,
  company_id           uuid NOT NULL,
  purpose              text NOT NULL REFERENCES assistant.purpose(code),
  status               text NOT NULL DEFAULT 'running' CHECK (status IN ('running','completed','failed','cancelled','blocked')),
  consent_id           uuid NOT NULL,
  provider_source      text NOT NULL CHECK (provider_source IN ('platform','tenant')),
  provider_code        text NOT NULL CHECK (provider_code ~ '^[a-z][a-z0-9_.-]{1,60}$'),
  provider_version     integer CHECK (provider_version >= 1),
  provider_fingerprint text NOT NULL CHECK (provider_fingerprint ~ '^[0-9a-f]{64}$'),
  tenant_provider_id   uuid,
  model                text NOT NULL CHECK (model ~ '^[A-Za-z0-9._:/@+-]{1,120}$'),
  policy_version       bigint NOT NULL,
  prompt_version       text NOT NULL CHECK (prompt_version ~ '^fa-[a-z0-9_]+-v[0-9]{1,4}$'),
  prompt_sha256        bytea NOT NULL CHECK (octet_length(prompt_sha256) = 32),
  toolset_sha256       bytea NOT NULL CHECK (octet_length(toolset_sha256) = 32),
  tenant_usage_id      uuid NOT NULL,
  user_usage_id        uuid NOT NULL,
  started_at           timestamptz NOT NULL DEFAULT now(),
  lease_expires_at     timestamptz NOT NULL,
  cancel_requested_at  timestamptz,
  finished_at          timestamptz,
  error_code           text CHECK (error_code ~ '^assistant\.[a-z_]+(\.[a-z_]+){1,3}$'),
  request_id           text CHECK (char_length(request_id) <= 80),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, id, user_id),
  FOREIGN KEY (tenant_id, thread_id, user_id) REFERENCES assistant.thread(tenant_id, id, user_id) ON DELETE SET NULL (thread_id),
  FOREIGN KEY (tenant_id, user_id) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, consent_id) REFERENCES assistant.consent(tenant_id, id),
  FOREIGN KEY (tenant_id, tenant_provider_id) REFERENCES assistant.tenant_provider(tenant_id, id),
  FOREIGN KEY (tenant_id, tenant_usage_id) REFERENCES assistant.usage_period(tenant_id, id),
  FOREIGN KEY (tenant_id, user_usage_id) REFERENCES assistant.usage_period(tenant_id, id),
  CHECK ((status = 'running') = (finished_at IS NULL)),
  CHECK (status NOT IN ('failed','blocked') OR error_code IS NOT NULL),
  CHECK ((provider_source = 'tenant') = (tenant_provider_id IS NOT NULL)),
  CHECK (lease_expires_at > started_at AND lease_expires_at <= started_at + interval '15 minutes'),
  CHECK (cancel_requested_at IS NULL OR cancel_requested_at >= started_at)
);
SELECT core.enable_tenant_rls('assistant.run');
CREATE UNIQUE INDEX IF NOT EXISTS run_one_running_per_user ON assistant.run (tenant_id, user_id) WHERE status = 'running';
CREATE INDEX IF NOT EXISTS run_thread_idx ON assistant.run (tenant_id, thread_id);
CREATE INDEX IF NOT EXISTS run_time_idx ON assistant.run (tenant_id, started_at);

CREATE OR REPLACE FUNCTION assistant.run_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  p assistant.tenant_policy; c assistant.consent; tp assistant.tenant_provider; ut assistant.usage_period; uu assistant.usage_period;
  v_feature text; v_today date; v_running integer;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status = 'running' OR OLD.finished_at >= now() - interval '400 days' THEN
      PERFORM core.raise_hk('HK_AST_RETENTION', 'runs are metering records kept at least 400 days after they finish');
    END IF;
    RETURN OLD;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF assistant.impersonating() THEN
      PERFORM core.raise_hk('HK_AST_IMPERSONATION', 'the assistant is not available under impersonation');
    END IF;
    IF NEW.status <> 'running' OR NEW.finished_at IS NOT NULL OR NEW.cancel_requested_at IS NOT NULL THEN
      PERFORM core.raise_hk('HK_AST_RUN_STATE', 'a run is created running');
    END IF;
    IF NEW.user_id IS DISTINCT FROM core.current_user_id() THEN
      PERFORM core.raise_hk('HK_AST_RUN_STATE', 'a run belongs to the current user');
    END IF;
    IF NEW.purpose = 'chat' AND NEW.thread_id IS NULL THEN
      PERFORM core.raise_hk('HK_AST_RUN_STATE', 'a chat run needs a thread');
    END IF;
    NEW.started_at := now();
    IF NEW.lease_expires_at <= now() THEN
      PERFORM core.raise_hk('HK_AST_RUN_STATE', 'run lease must be in the future');
    END IF;

    -- سیاست مستأجر (کلید قطع، حق پلن، ویژگی هدف)؛ قفل ردیف سیاست هم‌زمانی را سریالی می‌کند
    SELECT * INTO p FROM assistant.tenant_policy WHERE tenant_id = NEW.tenant_id FOR UPDATE;
    IF NOT FOUND OR NOT p.entitled OR NOT p.platform_enabled THEN
      PERFORM core.raise_hk('HK_AST_DISABLED', 'the assistant is disabled or not entitled for this tenant');
    END IF;
    SELECT feature INTO v_feature FROM assistant.purpose WHERE code = NEW.purpose;
    IF NOT (v_feature = ANY (p.features)) THEN
      PERFORM core.raise_hk('HK_AST_DISABLED', format('feature %s is not enabled for this tenant', v_feature));
    END IF;
    IF NEW.policy_version <> p.policy_version THEN
      PERFORM core.raise_hk('HK_AST_POLICY_STALE', format('run built on policy %s but current is %s', NEW.policy_version, p.policy_version));
    END IF;

    -- رضایت فعال، هدف و مقصد داده
    SELECT * INTO c FROM assistant.consent WHERE tenant_id = NEW.tenant_id AND id = NEW.consent_id;
    IF NOT FOUND OR c.status <> 'active' THEN
      PERFORM core.raise_hk('HK_AST_CONSENT', 'no active data-processing consent');
    END IF;
    IF NOT (NEW.purpose = ANY (c.purposes)) THEN
      PERFORM core.raise_hk('HK_AST_CONSENT', format('consent does not cover purpose %s', NEW.purpose));
    END IF;
    IF NOT (NEW.provider_fingerprint = ANY (c.provider_fingerprints)) THEN
      PERFORM core.raise_hk('HK_AST_CONSENT', 'consent does not cover this provider (data destination changed; re-consent required)');
    END IF;

    -- منبع ارائه‌دهنده با سیاست بخواند
    IF NEW.provider_source = 'tenant' THEN
      SELECT * INTO tp FROM assistant.tenant_provider WHERE tenant_id = NEW.tenant_id AND id = NEW.tenant_provider_id;
      IF NOT p.allow_tenant_provider OR tp.status IS DISTINCT FROM 'active' OR tp.fingerprint <> NEW.provider_fingerprint THEN
        PERFORM core.raise_hk('HK_AST_PROVIDER', 'tenant provider is not active, not allowed, or does not match the run');
      END IF;
    ELSIF NOT (NEW.provider_fingerprint = p.profile_fingerprint OR NEW.provider_fingerprint = ANY (p.secondary_fingerprints)) THEN
      PERFORM core.raise_hk('HK_AST_PROVIDER', 'platform provider does not match the tenant policy');
    END IF;

    -- ردیف‌های مصرف: یکی مستأجری و یکی برای همین کاربر، هر دو شامل امروز
    v_today := assistant.tenant_today(NEW.tenant_id);
    SELECT * INTO ut FROM assistant.usage_period WHERE tenant_id = NEW.tenant_id AND id = NEW.tenant_usage_id;
    SELECT * INTO uu FROM assistant.usage_period WHERE tenant_id = NEW.tenant_id AND id = NEW.user_usage_id;
    IF ut.scope IS DISTINCT FROM 'tenant' OR uu.scope IS DISTINCT FROM 'user' OR uu.user_id IS DISTINCT FROM NEW.user_id
       OR NOT (v_today >= ut.period_start AND v_today < ut.period_end)
       OR NOT (v_today >= uu.period_start AND v_today < uu.period_end) THEN
      PERFORM core.raise_hk('HK_AST_USAGE_ROW', 'usage rows must be the current tenant and user periods');
    END IF;

    -- سقف اجرای هم‌زمان مستأجر (lease منقضی شمرده نمی‌شود)
    SELECT count(*) INTO v_running FROM assistant.run
     WHERE tenant_id = NEW.tenant_id AND status = 'running' AND lease_expires_at > now();
    IF v_running >= p.max_concurrent_runs THEN
      PERFORM core.raise_hk('HK_AST_CONCURRENCY', format('tenant already has %s running assistant runs', v_running));
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE
  IF (NEW.tenant_id, NEW.id, NEW.user_id, NEW.company_id, NEW.purpose, NEW.consent_id, NEW.provider_source, NEW.provider_code,
      NEW.provider_version, NEW.provider_fingerprint, NEW.tenant_provider_id, NEW.model, NEW.policy_version, NEW.prompt_version,
      NEW.prompt_sha256, NEW.toolset_sha256, NEW.tenant_usage_id, NEW.user_usage_id, NEW.started_at, NEW.request_id)
     IS DISTINCT FROM
     (OLD.tenant_id, OLD.id, OLD.user_id, OLD.company_id, OLD.purpose, OLD.consent_id, OLD.provider_source, OLD.provider_code,
      OLD.provider_version, OLD.provider_fingerprint, OLD.tenant_provider_id, OLD.model, OLD.policy_version, OLD.prompt_version,
      OLD.prompt_sha256, OLD.toolset_sha256, OLD.tenant_usage_id, OLD.user_usage_id, OLD.started_at, OLD.request_id) THEN
    PERFORM core.raise_hk('HK_AST_RUN_STATE', 'run identity columns are immutable');
  END IF;
  IF NEW.thread_id IS DISTINCT FROM OLD.thread_id THEN
    -- تنها تغییر مجاز: SET NULL آبشاری کلید خارجی به‌دلیل حذف رشته (اقدام RI = عمق تریگر ≥ ۲)
    IF NEW.thread_id IS NOT NULL OR pg_trigger_depth() < 2
       OR (NEW.status, NEW.lease_expires_at, NEW.cancel_requested_at, NEW.finished_at, NEW.error_code)
       IS DISTINCT FROM (OLD.status, OLD.lease_expires_at, OLD.cancel_requested_at, OLD.finished_at, OLD.error_code) THEN
      PERFORM core.raise_hk('HK_AST_RUN_STATE', 'thread_id only becomes NULL when its thread is deleted');
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.status <> 'running' THEN
    PERFORM core.raise_hk('HK_AST_RUN_STATE', format('run in state %s is final', OLD.status));
  END IF;
  IF NEW.cancel_requested_at IS DISTINCT FROM OLD.cancel_requested_at AND OLD.cancel_requested_at IS NOT NULL THEN
    PERFORM core.raise_hk('HK_AST_RUN_STATE', 'cancel_requested_at is set once');
  END IF;
  IF NEW.status = 'running' THEN
    IF NEW.lease_expires_at < OLD.lease_expires_at OR NEW.error_code IS NOT NULL THEN
      PERFORM core.raise_hk('HK_AST_RUN_STATE', 'a running run may only extend its lease or record a cancel request');
    END IF;
    RETURN NEW;
  END IF;
  -- running → پایانی
  NEW.finished_at := now();
  IF EXISTS (SELECT 1 FROM assistant.llm_call l WHERE l.tenant_id = NEW.tenant_id AND l.run_id = NEW.id AND l.status = 'in_flight') THEN
    PERFORM core.raise_hk('HK_AST_RUN_OPEN_CALLS', 'a run cannot finish while a model call is in flight');
  END IF;
  IF NEW.status = 'completed' AND NEW.thread_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM assistant.message m WHERE m.tenant_id = NEW.tenant_id AND m.run_id = NEW.id AND m.role = 'assistant') THEN
    PERFORM core.raise_hk('HK_AST_RUN_NO_ANSWER', 'a completed chat run must have its assistant message');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS "0_via_assistant" ON assistant.run;
CREATE TRIGGER "0_via_assistant" BEFORE INSERT OR UPDATE OR DELETE ON assistant.run
  FOR EACH ROW EXECUTE FUNCTION assistant.forbid_via_assistant();
DROP TRIGGER IF EXISTS run_guard ON assistant.run;
CREATE TRIGGER run_guard BEFORE INSERT OR UPDATE OR DELETE ON assistant.run FOR EACH ROW EXECUTE FUNCTION assistant.run_guard();

-- =====================================================================
-- ۹. فراخوانی مدل (یک دور) — رزرو بودجه هنگام درج، تسویه هنگام پایان
-- =====================================================================
CREATE TABLE IF NOT EXISTS assistant.llm_call (
  tenant_id                   uuid NOT NULL REFERENCES core.tenant(id),
  id                          uuid NOT NULL DEFAULT uuidv7(),
  run_id                      uuid NOT NULL,
  round_no                    smallint NOT NULL CHECK (round_no BETWEEN 1 AND 16),
  user_id                     uuid NOT NULL,
  tenant_usage_id             uuid NOT NULL,
  user_usage_id               uuid NOT NULL,
  provider_fingerprint        text NOT NULL CHECK (provider_fingerprint ~ '^[0-9a-f]{64}$'),
  model                       text NOT NULL CHECK (model ~ '^[A-Za-z0-9._:/@+-]{1,120}$'),
  status                      text NOT NULL DEFAULT 'in_flight' CHECK (status IN ('in_flight','completed','failed','abandoned')),
  started_at                  timestamptz NOT NULL DEFAULT now(),
  lease_expires_at            timestamptz NOT NULL,
  finished_at                 timestamptz,
  reserved_prompt_tokens      integer NOT NULL CHECK (reserved_prompt_tokens BETWEEN 1 AND 1048576),
  reserved_completion_tokens  integer NOT NULL CHECK (reserved_completion_tokens BETWEEN 1 AND 32768),
  prompt_tokens               integer CHECK (prompt_tokens >= 0),
  completion_tokens           integer CHECK (completion_tokens >= 0),
  usage_estimated             boolean NOT NULL DEFAULT false,
  price_unit                  core.amount_unit NOT NULL,
  input_price_per_mtok        core.amount NOT NULL CHECK (input_price_per_mtok >= 0),
  output_price_per_mtok       core.amount NOT NULL CHECK (output_price_per_mtok >= 0),
  reserved_cost               core.amount GENERATED ALWAYS AS (
                                round((reserved_prompt_tokens::numeric * input_price_per_mtok
                                       + reserved_completion_tokens::numeric * output_price_per_mtok) / 1000000, 4)) STORED,
  charged_cost                core.amount GENERATED ALWAYS AS (
                                CASE WHEN status <> 'in_flight'
                                     THEN round((coalesce(prompt_tokens, 0)::numeric * input_price_per_mtok
                                                 + coalesce(completion_tokens, 0)::numeric * output_price_per_mtok) / 1000000, 4) END) STORED,
  finish_reason               text CHECK (finish_reason IN ('stop','tool_calls','length','content_filter','error','cancelled','timeout')),
  http_status                 smallint CHECK (http_status BETWEEN 100 AND 599),
  error_code                  text CHECK (error_code ~ '^assistant\.[a-z_]+(\.[a-z_]+){1,3}$'),
  first_token_ms              integer CHECK (first_token_ms >= 0),
  total_ms                    integer CHECK (total_ms >= 0),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, run_id, round_no),
  FOREIGN KEY (tenant_id, run_id, user_id) REFERENCES assistant.run(tenant_id, id, user_id),
  FOREIGN KEY (tenant_id, tenant_usage_id) REFERENCES assistant.usage_period(tenant_id, id),
  FOREIGN KEY (tenant_id, user_usage_id) REFERENCES assistant.usage_period(tenant_id, id),
  CHECK ((status = 'in_flight') = (finished_at IS NULL)),
  CHECK (status <> 'completed' OR (prompt_tokens IS NOT NULL AND completion_tokens IS NOT NULL AND finish_reason IS NOT NULL)),
  CHECK (status <> 'failed' OR error_code IS NOT NULL),
  CHECK (status <> 'abandoned' OR (usage_estimated AND prompt_tokens = reserved_prompt_tokens
                                   AND completion_tokens = reserved_completion_tokens)),
  CHECK (lease_expires_at > started_at AND lease_expires_at <= started_at + interval '10 minutes')
);
SELECT core.enable_tenant_rls('assistant.llm_call');
CREATE INDEX IF NOT EXISTS llm_call_tenant_usage_idx ON assistant.llm_call (tenant_id, tenant_usage_id);
CREATE INDEX IF NOT EXISTS llm_call_user_usage_idx ON assistant.llm_call (tenant_id, user_usage_id);
CREATE INDEX IF NOT EXISTS llm_call_inflight_idx ON assistant.llm_call (tenant_id, lease_expires_at) WHERE status = 'in_flight';

-- جمع مصرف یک ردیف دوره (تنها تعریف؛ تریگر بودجه و ویوی v_usage هر دو از آن استفاده می‌کنند)
-- committed = رزرو فراخوانی‌های در جریان + مصرف واقعی فراخوانی‌های پایان‌یافته
CREATE OR REPLACE FUNCTION assistant.usage_totals(p_tenant uuid, p_usage uuid)
RETURNS TABLE (tokens_committed bigint, tokens_charged bigint, cost_committed numeric, cost_charged numeric, calls bigint, in_flight bigint)
LANGUAGE sql STABLE AS $$
  SELECT coalesce(sum(CASE WHEN c.status = 'in_flight' THEN c.reserved_prompt_tokens + c.reserved_completion_tokens
                           ELSE coalesce(c.prompt_tokens, 0) + coalesce(c.completion_tokens, 0) END), 0)::bigint,
         coalesce(sum(CASE WHEN c.status = 'in_flight' THEN 0
                           ELSE coalesce(c.prompt_tokens, 0) + coalesce(c.completion_tokens, 0) END), 0)::bigint,
         coalesce(sum(CASE WHEN c.status = 'in_flight' THEN c.reserved_cost ELSE c.charged_cost END), 0),
         coalesce(sum(coalesce(c.charged_cost, 0)), 0),
         count(*), count(*) FILTER (WHERE c.status = 'in_flight')
    FROM assistant.llm_call c
   WHERE c.tenant_id = p_tenant AND (c.tenant_usage_id = p_usage OR c.user_usage_id = p_usage)
$$;

CREATE OR REPLACE FUNCTION assistant.llm_call_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  r assistant.run; p assistant.tenant_policy; c assistant.consent; u assistant.usage_period;
  v_tokens bigint; v_cost numeric; t record; v_new_cost numeric;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status = 'in_flight' OR OLD.finished_at >= now() - interval '400 days' THEN
      PERFORM core.raise_hk('HK_AST_RETENTION', 'model calls are metering records kept at least 400 days');
    END IF;
    RETURN OLD;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'in_flight' OR NEW.finished_at IS NOT NULL OR NEW.prompt_tokens IS NOT NULL OR NEW.completion_tokens IS NOT NULL
       OR NEW.usage_estimated THEN
      PERFORM core.raise_hk('HK_AST_LLM_STATE', 'a model call is created in_flight without usage');
    END IF;
    NEW.started_at := now();
    IF NEW.lease_expires_at <= now() THEN
      PERFORM core.raise_hk('HK_AST_LLM_STATE', 'model call lease must be in the future');
    END IF;
    SELECT * INTO r FROM assistant.run WHERE tenant_id = NEW.tenant_id AND id = NEW.run_id;
    IF r.status IS DISTINCT FROM 'running' THEN
      PERFORM core.raise_hk('HK_AST_RUN_NOT_RUNNING', 'model calls are only made for a running run');
    END IF;
    IF r.cancel_requested_at IS NOT NULL THEN
      PERFORM core.raise_hk('HK_AST_RUN_NOT_RUNNING', 'run was cancelled by the user');
    END IF;
    IF (NEW.tenant_usage_id, NEW.user_usage_id, NEW.provider_fingerprint, NEW.model)
       IS DISTINCT FROM (r.tenant_usage_id, r.user_usage_id, r.provider_fingerprint, r.model) THEN
      PERFORM core.raise_hk('HK_AST_LLM_STATE', 'model call must use the usage rows, provider and model of its run');
    END IF;
    -- کلید قطع و حق در لحظهٔ هر دور (نه فقط شروع اجرا)
    SELECT * INTO p FROM assistant.tenant_policy WHERE tenant_id = NEW.tenant_id;
    IF NOT FOUND OR NOT p.entitled OR NOT p.platform_enabled THEN
      PERFORM core.raise_hk('HK_AST_DISABLED', 'the assistant was disabled for this tenant');
    END IF;
    IF NEW.round_no > p.max_rounds THEN
      PERFORM core.raise_hk('HK_AST_ROUND_CAP', format('round %s exceeds the policy cap %s', NEW.round_no, p.max_rounds));
    END IF;
    -- لغو رضایت در دور بعد اثر دارد
    SELECT * INTO c FROM assistant.consent WHERE tenant_id = NEW.tenant_id AND id = r.consent_id;
    IF c.status IS DISTINCT FROM 'active' THEN
      PERFORM core.raise_hk('HK_AST_CONSENT', 'data-processing consent was revoked');
    END IF;

    -- بودجه: اول ردیف مستأجر، بعد ردیف کاربر (ترتیب ثابت قفل ⇒ بدون بن‌بست)
    v_new_cost := round((NEW.reserved_prompt_tokens::numeric * NEW.input_price_per_mtok
                         + NEW.reserved_completion_tokens::numeric * NEW.output_price_per_mtok) / 1000000, 4);
    FOR u IN SELECT * FROM assistant.usage_period
              WHERE tenant_id = NEW.tenant_id AND id IN (NEW.tenant_usage_id, NEW.user_usage_id)
              ORDER BY (scope = 'user'), id FOR UPDATE
    LOOP
      SELECT * INTO t FROM assistant.usage_totals(NEW.tenant_id, u.id);
      IF u.token_limit IS NOT NULL AND t.tokens_committed + NEW.reserved_prompt_tokens + NEW.reserved_completion_tokens > u.token_limit THEN
        PERFORM core.raise_hk('HK_AST_BUDGET_TOKENS',
          format('%s token budget exhausted (%s committed of %s)', u.scope, t.tokens_committed, u.token_limit));
      END IF;
      IF u.cost_limit IS NOT NULL THEN
        IF u.cost_unit <> NEW.price_unit THEN
          PERFORM core.raise_hk('HK_AST_BUDGET_UNIT', format('price unit %s differs from budget unit %s', NEW.price_unit, u.cost_unit));
        END IF;
        IF t.cost_committed + v_new_cost > u.cost_limit THEN
          PERFORM core.raise_hk('HK_AST_BUDGET_COST',
            format('%s cost budget exhausted (%s committed of %s)', u.scope, t.cost_committed, u.cost_limit));
        END IF;
      END IF;
    END LOOP;
    RETURN NEW;
  END IF;

  -- UPDATE
  IF (NEW.tenant_id, NEW.id, NEW.run_id, NEW.round_no, NEW.user_id, NEW.tenant_usage_id, NEW.user_usage_id, NEW.provider_fingerprint,
      NEW.model, NEW.started_at, NEW.reserved_prompt_tokens, NEW.reserved_completion_tokens, NEW.price_unit,
      NEW.input_price_per_mtok, NEW.output_price_per_mtok)
     IS DISTINCT FROM
     (OLD.tenant_id, OLD.id, OLD.run_id, OLD.round_no, OLD.user_id, OLD.tenant_usage_id, OLD.user_usage_id, OLD.provider_fingerprint,
      OLD.model, OLD.started_at, OLD.reserved_prompt_tokens, OLD.reserved_completion_tokens, OLD.price_unit,
      OLD.input_price_per_mtok, OLD.output_price_per_mtok) THEN
    PERFORM core.raise_hk('HK_AST_LLM_STATE', 'reservation and price snapshot are immutable');
  END IF;
  IF OLD.status <> 'in_flight' THEN
    PERFORM core.raise_hk('HK_AST_LLM_STATE', format('model call in state %s is final', OLD.status));
  END IF;
  IF NEW.status = 'in_flight' THEN
    IF NEW.lease_expires_at < OLD.lease_expires_at
       OR (NEW.prompt_tokens, NEW.completion_tokens, NEW.finish_reason, NEW.error_code) IS DISTINCT FROM (OLD.prompt_tokens, OLD.completion_tokens, OLD.finish_reason, OLD.error_code) THEN
      PERFORM core.raise_hk('HK_AST_LLM_STATE', 'an in-flight call may only extend its lease');
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.status = 'abandoned' THEN
    IF OLD.lease_expires_at >= now() THEN
      PERFORM core.raise_hk('HK_AST_LLM_STATE', 'only a call whose lease expired can be abandoned');
    END IF;
    -- مصرف ناشناخته: رزرو کامل برداشت می‌شود (محافظه‌کارانه، به سود سقف)
    NEW.prompt_tokens := OLD.reserved_prompt_tokens; NEW.completion_tokens := OLD.reserved_completion_tokens;
    NEW.usage_estimated := true; NEW.error_code := coalesce(NEW.error_code, 'assistant.llm.lease_expired');
  END IF;
  NEW.finished_at := now();
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS "0_via_assistant" ON assistant.llm_call;
CREATE TRIGGER "0_via_assistant" BEFORE INSERT OR UPDATE OR DELETE ON assistant.llm_call
  FOR EACH ROW EXECUTE FUNCTION assistant.forbid_via_assistant();
DROP TRIGGER IF EXISTS llm_call_guard ON assistant.llm_call;
CREATE TRIGGER llm_call_guard BEFORE INSERT OR UPDATE OR DELETE ON assistant.llm_call
  FOR EACH ROW EXECUTE FUNCTION assistant.llm_call_guard();

-- =====================================================================
-- ۱۰. پیام (فقط‌افزودنی؛ حذف فقط با حذف رشته)
-- =====================================================================
CREATE TABLE IF NOT EXISTS assistant.message (
  tenant_id   uuid NOT NULL REFERENCES core.tenant(id),
  id          uuid NOT NULL DEFAULT uuidv7(),
  thread_id   uuid NOT NULL,
  user_id     uuid NOT NULL,
  run_id      uuid NOT NULL,
  seq         integer NOT NULL CHECK (seq >= 1),
  role        text NOT NULL CHECK (role IN ('user','assistant')),
  content     text NOT NULL CHECK (char_length(content) BETWEEN 1 AND 8000 AND content = core.fa_normalize_text(content)),
  input_mode  text NOT NULL DEFAULT 'text' CHECK (input_mode IN ('text','suggestion','voice')),
  finish      text CHECK (finish IN ('complete','interrupted','refused','error','cancelled','budget')),
  blocks      jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(blocks) = 'array' AND jsonb_array_length(blocks) <= 16),
  grounding   jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(grounding) = 'object'),
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, id, user_id),
  UNIQUE (tenant_id, thread_id, seq),
  UNIQUE (tenant_id, run_id, role),
  FOREIGN KEY (tenant_id, thread_id, user_id) REFERENCES assistant.thread(tenant_id, id, user_id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, run_id, user_id) REFERENCES assistant.run(tenant_id, id, user_id),
  CHECK ((role = 'assistant') = (finish IS NOT NULL)),
  CHECK (role = 'assistant' OR char_length(content) <= 2000),
  CHECK (role = 'user' OR input_mode = 'text'),
  CHECK (role = 'assistant' OR (blocks = '[]'::jsonb AND grounding = '{}'::jsonb))
);
SELECT core.enable_tenant_rls('assistant.message');
SELECT assistant.enable_owner_only('assistant.message');

CREATE OR REPLACE FUNCTION assistant.message_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE r assistant.run;
BEGIN
  SELECT * INTO r FROM assistant.run WHERE tenant_id = NEW.tenant_id AND id = NEW.run_id;
  IF r.thread_id IS DISTINCT FROM NEW.thread_id THEN
    PERFORM core.raise_hk('HK_AST_MESSAGE_LINK', 'message run belongs to another thread');
  END IF;
  IF r.status IS DISTINCT FROM 'running' THEN
    PERFORM core.raise_hk('HK_AST_RUN_NOT_RUNNING', 'messages are appended only while their run is running');
  END IF;
  NEW.created_at := now();
  UPDATE assistant.thread SET message_count = message_count + 1, last_activity_at = now()
   WHERE tenant_id = NEW.tenant_id AND id = NEW.thread_id AND user_id = NEW.user_id
  RETURNING message_count INTO NEW.seq;
  IF NOT FOUND THEN
    PERFORM core.raise_hk('HK_AST_MESSAGE_LINK', 'thread not found for this user');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS "0_via_assistant" ON assistant.message;
CREATE TRIGGER "0_via_assistant" BEFORE INSERT OR UPDATE OR DELETE ON assistant.message
  FOR EACH ROW EXECUTE FUNCTION assistant.forbid_via_assistant();
DROP TRIGGER IF EXISTS message_guard ON assistant.message;
CREATE TRIGGER message_guard BEFORE INSERT ON assistant.message FOR EACH ROW EXECUTE FUNCTION assistant.message_guard();
DROP TRIGGER IF EXISTS message_immutable ON assistant.message;
CREATE TRIGGER message_immutable BEFORE UPDATE ON assistant.message FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

-- =====================================================================
-- ۱۱. فراخوانی ابزار (فقط‌افزودنی؛ رکورد کامل آنچه به مدل رفت)
-- =====================================================================
CREATE TABLE IF NOT EXISTS assistant.tool_call (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  run_id               uuid NOT NULL,
  llm_call_id          uuid NOT NULL,
  thread_id            uuid NOT NULL,
  user_id              uuid NOT NULL,
  seq                  smallint NOT NULL CHECK (seq BETWEEN 1 AND 32),
  provider_call_id     text CHECK (char_length(provider_call_id) <= 120),
  tool_code            text NOT NULL REFERENCES assistant.tool(code),
  tool_version         integer NOT NULL,
  status               text NOT NULL CHECK (status IN ('ok','denied','invalid_args','not_available','error','timeout')),
  args                 jsonb NOT NULL CHECK (jsonb_typeof(args) = 'object' AND octet_length(args::text) <= 8192),
  args_sha256          bytea GENERATED ALWAYS AS (assistant.jsonb_sha256(args)) STORED,
  result               jsonb CHECK (result IS NULL OR jsonb_typeof(result) = 'object'),
  result_bytes         integer GENERATED ALWAYS AS (octet_length(result::text)) STORED,
  result_rows          integer NOT NULL DEFAULT 0 CHECK (result_rows >= 0),
  truncated            boolean NOT NULL DEFAULT false,
  pseudonymized        integer NOT NULL DEFAULT 0 CHECK (pseudonymized >= 0),
  permissions_checked  text[] NOT NULL DEFAULT '{}',
  denied_permission    text,
  error_code           text CHECK (error_code ~ '^assistant\.[a-z_]+(\.[a-z_]+){1,3}$'),
  latency_ms           integer NOT NULL CHECK (latency_ms >= 0),
  created_at           timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, id, user_id),
  UNIQUE (tenant_id, run_id, seq),
  FOREIGN KEY (tenant_id, thread_id, user_id) REFERENCES assistant.thread(tenant_id, id, user_id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, run_id, user_id) REFERENCES assistant.run(tenant_id, id, user_id),
  FOREIGN KEY (tenant_id, llm_call_id) REFERENCES assistant.llm_call(tenant_id, id),
  CHECK ((status = 'ok') = (result IS NOT NULL)),
  CHECK ((status = 'denied') = (denied_permission IS NOT NULL)),
  CHECK (status IN ('ok','denied') OR error_code IS NOT NULL),
  CHECK (result_bytes IS NULL OR result_bytes <= 65536)
);
SELECT core.enable_tenant_rls('assistant.tool_call');
SELECT assistant.enable_owner_only('assistant.tool_call');

CREATE OR REPLACE FUNCTION assistant.tool_call_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE r assistant.run; l assistant.llm_call; t assistant.tool; p assistant.tenant_policy; v_allowed text[];
BEGIN
  SELECT * INTO r FROM assistant.run WHERE tenant_id = NEW.tenant_id AND id = NEW.run_id;
  IF r.status IS DISTINCT FROM 'running' THEN
    PERFORM core.raise_hk('HK_AST_RUN_NOT_RUNNING', 'tool calls are recorded only while their run is running');
  END IF;
  IF r.thread_id IS DISTINCT FROM NEW.thread_id THEN
    PERFORM core.raise_hk('HK_AST_TOOL_LINK', 'tool call thread differs from its run');
  END IF;
  SELECT * INTO l FROM assistant.llm_call WHERE tenant_id = NEW.tenant_id AND id = NEW.llm_call_id;
  IF l.run_id IS DISTINCT FROM NEW.run_id OR l.status IS DISTINCT FROM 'completed' OR l.finish_reason IS DISTINCT FROM 'tool_calls' THEN
    PERFORM core.raise_hk('HK_AST_TOOL_LINK', 'a tool call must answer a completed model response of the same run that asked for tools');
  END IF;
  SELECT * INTO t FROM assistant.tool WHERE code = NEW.tool_code;
  IF NOT FOUND OR t.deprecated_at IS NOT NULL OR t.version <> NEW.tool_version THEN
    PERFORM core.raise_hk('HK_AST_TOOL_UNKNOWN', format('tool %s v%s is deprecated or not the catalog version', NEW.tool_code, NEW.tool_version));
  END IF;
  SELECT * INTO p FROM assistant.tenant_policy WHERE tenant_id = NEW.tenant_id;
  IF NEW.seq > p.max_tool_calls THEN
    PERFORM core.raise_hk('HK_AST_TOOL_CAP', format('tool call %s exceeds the policy cap %s', NEW.seq, p.max_tool_calls));
  END IF;
  -- فراخوانی آغازشده با مدل فقط مجوزهای خواندنیِ اعلام‌شدهٔ همان ابزار را به کار می‌برد (هرگز materialize)
  SELECT coalesce(array_agg(tp.permission_code), '{}') INTO v_allowed
    FROM assistant.tool_permission tp WHERE tp.tool_code = NEW.tool_code AND tp.requirement IN ('read','read_optional');
  IF NOT (NEW.permissions_checked <@ v_allowed) OR (NEW.denied_permission IS NOT NULL AND NOT (NEW.denied_permission = ANY (v_allowed))) THEN
    PERFORM core.raise_hk('HK_AST_TOOL_PERMISSION', format('tool %s exercised a permission outside its declared read ceiling', NEW.tool_code));
  END IF;
  IF NEW.result IS NOT NULL AND octet_length(NEW.result::text) > t.max_result_bytes THEN
    PERFORM core.raise_hk('HK_AST_TOOL_RESULT_CAP', format('result of %s exceeds %s bytes', NEW.tool_code, t.max_result_bytes));
  END IF;
  IF NEW.result_rows > t.max_rows THEN
    PERFORM core.raise_hk('HK_AST_TOOL_RESULT_CAP', format('result of %s exceeds %s rows', NEW.tool_code, t.max_rows));
  END IF;
  NEW.created_at := now();
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS "0_via_assistant" ON assistant.tool_call;
CREATE TRIGGER "0_via_assistant" BEFORE INSERT OR UPDATE OR DELETE ON assistant.tool_call
  FOR EACH ROW EXECUTE FUNCTION assistant.forbid_via_assistant();
DROP TRIGGER IF EXISTS tool_call_guard ON assistant.tool_call;
CREATE TRIGGER tool_call_guard BEFORE INSERT ON assistant.tool_call FOR EACH ROW EXECUTE FUNCTION assistant.tool_call_guard();
DROP TRIGGER IF EXISTS tool_call_immutable ON assistant.tool_call;
CREATE TRIGGER tool_call_immutable BEFORE UPDATE ON assistant.tool_call FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

-- =====================================================================
-- ۱۲. پیشنهاد (پیش‌نویسِ دستیار؛ تحقق فقط با تأیید انسانی صاحب رشته)
-- =====================================================================
CREATE TABLE IF NOT EXISTS assistant.proposal (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  tool_call_id  uuid NOT NULL,
  run_id        uuid NOT NULL,
  thread_id     uuid NOT NULL,
  user_id       uuid NOT NULL,
  company_id    uuid NOT NULL,
  kind          text NOT NULL REFERENCES assistant.proposal_kind(code),
  title         text NOT NULL CHECK (char_length(title) BETWEEN 1 AND 160 AND title = core.fa_normalize_text(title)),
  payload       jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object' AND octet_length(payload::text) <= 32768),
  payload_sha256 bytea GENERATED ALWAYS AS (assistant.jsonb_sha256(payload)) STORED,
  validation    jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(validation) = 'object'),
  valid         boolean NOT NULL,
  status        text NOT NULL DEFAULT 'proposed' CHECK (status IN ('proposed','materialized','dismissed','expired','failed')),
  expires_at    timestamptz NOT NULL,
  decided_at    timestamptz,
  decided_by    uuid,
  target_type   text CHECK (target_type ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  target_id     uuid,
  target_ref    text CHECK (char_length(target_ref) <= 120),
  failure_code  text CHECK (failure_code ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,4}$'),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  row_version   integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, tool_call_id),
  FOREIGN KEY (tenant_id, tool_call_id, user_id) REFERENCES assistant.tool_call(tenant_id, id, user_id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, thread_id, user_id) REFERENCES assistant.thread(tenant_id, id, user_id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, run_id, user_id) REFERENCES assistant.run(tenant_id, id, user_id),
  FOREIGN KEY (tenant_id, decided_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  CHECK ((status = 'proposed') = (decided_at IS NULL)),
  CHECK (status NOT IN ('materialized','dismissed','failed') OR decided_by IS NOT NULL),
  CHECK ((status = 'failed') = (failure_code IS NOT NULL)),
  CHECK (status <> 'materialized' OR valid),
  CHECK (expires_at > created_at AND expires_at <= created_at + interval '30 days')
);
SELECT core.enable_tenant_rls('assistant.proposal');
SELECT assistant.enable_owner_only('assistant.proposal');
CREATE INDEX IF NOT EXISTS proposal_open_idx ON assistant.proposal (tenant_id, user_id, expires_at) WHERE status = 'proposed';

CREATE OR REPLACE FUNCTION assistant.proposal_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE tc assistant.tool_call; t assistant.tool; k assistant.proposal_kind;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT * INTO tc FROM assistant.tool_call WHERE tenant_id = NEW.tenant_id AND id = NEW.tool_call_id;
    SELECT * INTO t FROM assistant.tool WHERE code = tc.tool_code;
    IF tc.status IS DISTINCT FROM 'ok' OR t.kind IS DISTINCT FROM 'proposal' OR t.proposal_kind IS DISTINCT FROM NEW.kind
       OR tc.run_id <> NEW.run_id OR tc.thread_id <> NEW.thread_id THEN
      PERFORM core.raise_hk('HK_AST_PROPOSAL_LINK', 'a proposal comes from a successful call of a proposal tool of the same kind and run');
    END IF;
    IF NEW.status <> 'proposed' OR NEW.decided_at IS NOT NULL OR NEW.target_id IS NOT NULL OR NEW.target_ref IS NOT NULL THEN
      PERFORM core.raise_hk('HK_AST_PROPOSAL_STATE', 'a proposal is created as proposed');
    END IF;
    SELECT * INTO k FROM assistant.proposal_kind WHERE code = NEW.kind;
    NEW.created_at := now();
    NEW.expires_at := now() + k.ttl;
    RETURN NEW;
  END IF;

  IF (NEW.tenant_id, NEW.id, NEW.tool_call_id, NEW.run_id, NEW.thread_id, NEW.user_id, NEW.company_id, NEW.kind, NEW.title,
      NEW.payload, NEW.validation, NEW.valid, NEW.expires_at, NEW.created_at)
     IS DISTINCT FROM
     (OLD.tenant_id, OLD.id, OLD.tool_call_id, OLD.run_id, OLD.thread_id, OLD.user_id, OLD.company_id, OLD.kind, OLD.title,
      OLD.payload, OLD.validation, OLD.valid, OLD.expires_at, OLD.created_at) THEN
    PERFORM core.raise_hk('HK_AST_PROPOSAL_STATE', 'proposal content is immutable; edit the draft after materializing');
  END IF;
  IF OLD.status <> 'proposed' THEN
    PERFORM core.raise_hk('HK_AST_PROPOSAL_STATE', format('proposal in state %s is final', OLD.status));
  END IF;
  IF NEW.status = 'proposed' THEN
    PERFORM core.raise_hk('HK_AST_PROPOSAL_STATE', 'a proposal update must decide it');
  END IF;
  NEW.decided_at := now();

  IF NEW.status = 'expired' THEN
    IF now() < OLD.expires_at THEN
      PERFORM core.raise_hk('HK_AST_PROPOSAL_STATE', 'a proposal expires only after expires_at');
    END IF;
    IF NEW.decided_by IS NOT NULL OR NEW.target_id IS NOT NULL OR NEW.target_ref IS NOT NULL THEN
      PERFORM core.raise_hk('HK_AST_PROPOSAL_STATE', 'expiry has no actor or target');
    END IF;
    RETURN NEW;
  END IF;

  -- materialized / dismissed / failed: فقط صاحب رشته، و تحقق فقط در تراکنش «تأیید انسانی»
  IF NEW.decided_by IS DISTINCT FROM core.current_user_id() OR NEW.decided_by IS DISTINCT FROM OLD.user_id THEN
    PERFORM core.raise_hk('HK_AST_PROPOSAL_ACTOR', 'only the human who asked may decide the proposal');
  END IF;
  IF NEW.status IN ('materialized','failed') THEN
    IF assistant.actor_via() <> 'assistant_confirm' THEN
      PERFORM core.raise_hk('HK_AST_PROPOSAL_ACTOR', 'materialization runs only in a human-confirm transaction');
    END IF;
    IF now() >= OLD.expires_at THEN
      PERFORM core.raise_hk('HK_AST_PROPOSAL_EXPIRED', 'proposal expired; ask the assistant again');
    END IF;
  END IF;
  IF NEW.status = 'materialized' THEN
    IF NOT OLD.valid THEN
      PERFORM core.raise_hk('HK_AST_PROPOSAL_INVALID', 'an invalid proposal cannot be materialized');
    END IF;
    SELECT * INTO k FROM assistant.proposal_kind WHERE code = OLD.kind;
    IF k.materialization = 'server_draft'
       AND (NEW.target_id IS NULL OR NEW.target_type IS NULL OR split_part(NEW.target_type, '.', 1) <> k.target_module) THEN
      PERFORM core.raise_hk('HK_AST_PROPOSAL_TARGET', format('a %s proposal needs the created draft in module %s', OLD.kind, k.target_module));
    END IF;
    IF k.materialization = 'human_send' AND (NEW.target_ref IS NULL OR NEW.target_type IS NULL) THEN
      PERFORM core.raise_hk('HK_AST_PROPOSAL_TARGET', 'a human_send proposal records what was sent');
    END IF;
    IF k.materialization = 'client_prefill' AND (NEW.target_id IS NOT NULL OR NEW.target_ref IS NOT NULL) THEN
      PERFORM core.raise_hk('HK_AST_PROPOSAL_TARGET', 'a client_prefill proposal creates nothing on the server');
    END IF;
  ELSIF NEW.target_id IS NOT NULL OR NEW.target_ref IS NOT NULL THEN
    PERFORM core.raise_hk('HK_AST_PROPOSAL_TARGET', 'only a materialized proposal has a target');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS "0_via_assistant" ON assistant.proposal;
CREATE TRIGGER "0_via_assistant" BEFORE INSERT OR UPDATE OR DELETE ON assistant.proposal
  FOR EACH ROW EXECUTE FUNCTION assistant.forbid_via_assistant('allow_confirm');
DROP TRIGGER IF EXISTS proposal_guard ON assistant.proposal;
CREATE TRIGGER proposal_guard BEFORE INSERT OR UPDATE ON assistant.proposal FOR EACH ROW EXECUTE FUNCTION assistant.proposal_guard();
DROP TRIGGER IF EXISTS trg_touch ON assistant.proposal;
CREATE TRIGGER trg_touch BEFORE UPDATE ON assistant.proposal FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- =====================================================================
-- ۱۳. بازخورد کاربر روی پاسخ دستیار
-- =====================================================================
CREATE TABLE IF NOT EXISTS assistant.feedback (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  message_id   uuid NOT NULL,
  user_id      uuid NOT NULL,
  rating       smallint NOT NULL CHECK (rating IN (-1, 1)),
  reason       text CHECK (reason IN ('wrong_numbers','wrong_tool','not_helpful','language','slow','unsafe','other')),
  comment      text CHECK (char_length(comment) <= 500 AND comment = core.fa_normalize_text(comment)),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  row_version  integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, message_id, user_id),
  FOREIGN KEY (tenant_id, message_id, user_id) REFERENCES assistant.message(tenant_id, id, user_id) ON DELETE CASCADE,
  CHECK (reason IS NULL OR rating = -1)
);
SELECT core.enable_tenant_rls('assistant.feedback');
SELECT assistant.enable_owner_only('assistant.feedback');

CREATE OR REPLACE FUNCTION assistant.feedback_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM assistant.message m WHERE m.tenant_id = NEW.tenant_id AND m.id = NEW.message_id AND m.role = 'assistant') THEN
    PERFORM core.raise_hk('HK_AST_FEEDBACK_ROLE', 'feedback is given on assistant messages only');
  END IF;
  IF TG_OP = 'UPDATE' AND (NEW.message_id, NEW.user_id, NEW.created_at) IS DISTINCT FROM (OLD.message_id, OLD.user_id, OLD.created_at) THEN
    PERFORM core.raise_hk('HK_AST_FEEDBACK_ROLE', 'feedback target is immutable');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS "0_via_assistant" ON assistant.feedback;
CREATE TRIGGER "0_via_assistant" BEFORE INSERT OR UPDATE OR DELETE ON assistant.feedback
  FOR EACH ROW EXECUTE FUNCTION assistant.forbid_via_assistant();
DROP TRIGGER IF EXISTS feedback_guard ON assistant.feedback;
CREATE TRIGGER feedback_guard BEFORE INSERT OR UPDATE ON assistant.feedback FOR EACH ROW EXECUTE FUNCTION assistant.feedback_guard();
DROP TRIGGER IF EXISTS trg_touch ON assistant.feedback;
CREATE TRIGGER trg_touch BEFORE UPDATE ON assistant.feedback FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- =====================================================================
-- ۱۴. ویوها (security_invoker)
-- =====================================================================
CREATE OR REPLACE VIEW assistant.v_usage WITH (security_invoker = true) AS
SELECT u.tenant_id, u.id, u.scope, u.user_id, u.period_start, u.period_end, u.token_limit, u.cost_limit, u.cost_unit, u.limit_source,
       s.tokens_committed, s.tokens_charged, s.cost_committed::core.amount AS cost_committed, s.cost_charged::core.amount AS cost_charged,
       s.calls AS llm_calls, s.in_flight,
       CASE WHEN u.token_limit IS NULL THEN NULL ELSE greatest(u.token_limit - s.tokens_committed, 0) END AS tokens_remaining,
       CASE WHEN u.cost_limit IS NULL THEN NULL ELSE greatest(u.cost_limit - s.cost_committed, 0)::core.amount END AS cost_remaining
  FROM assistant.usage_period u
  CROSS JOIN LATERAL assistant.usage_totals(u.tenant_id, u.id) s;

-- خلاصهٔ سنجش هر اجرا (مبنای رویداد assistant.run.metered و داشبورد مصرف مستأجر؛ بدون محتوا)
CREATE OR REPLACE VIEW assistant.v_run_usage WITH (security_invoker = true) AS
SELECT r.tenant_id, r.id AS run_id, r.user_id, r.company_id, r.purpose, r.status, r.provider_source, r.provider_code,
       r.provider_version, r.model, r.prompt_version, r.started_at, r.finished_at, r.error_code,
       count(c.id) AS llm_calls,
       coalesce(max(c.round_no), 0) AS rounds,
       coalesce(sum(c.prompt_tokens), 0)::bigint AS prompt_tokens,
       coalesce(sum(c.completion_tokens), 0)::bigint AS completion_tokens,
       coalesce(sum(c.charged_cost), 0)::core.amount AS cost,
       min(c.price_unit::text) AS cost_unit,
       coalesce(bool_or(c.usage_estimated), false) AS usage_estimated,
       max(c.first_token_ms) FILTER (WHERE c.round_no = 1) AS first_token_ms
  FROM assistant.run r
  LEFT JOIN assistant.llm_call c ON c.tenant_id = r.tenant_id AND c.run_id = r.id
 GROUP BY r.tenant_id, r.id;

-- سقف مجوز دستیار (مشتق از رجیستری ابزار؛ هیچ فهرست دستی دیگری نیست)
CREATE OR REPLACE VIEW assistant.v_permission_ceiling WITH (security_invoker = true) AS
SELECT tp.permission_code,
       bool_or(tp.requirement IN ('read','read_optional')) AS model_initiated,
       bool_or(tp.requirement = 'materialize') AS human_confirmed,
       array_agg(tp.tool_code ORDER BY tp.tool_code) AS tools
  FROM assistant.tool_permission tp
  JOIN assistant.tool t ON t.code = tp.tool_code AND t.deprecated_at IS NULL
 GROUP BY tp.permission_code;

-- =====================================================================
-- ۱۵. توابع نگهداری و lint
-- =====================================================================

-- رهاشده‌ها: فراخوانی مدلِ با lease منقضی → abandoned (رزرو کامل برداشت می‌شود)؛ اجرای با lease منقضی → failed.
-- در زمینهٔ مستأجر؛ سرویس پیش از ساخت اجرای تازه و job نگهداری صدا می‌زنند.
CREATE OR REPLACE FUNCTION assistant.reap_expired(p_limit integer DEFAULT 100) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE n1 integer; n2 integer;
BEGIN
  IF core.current_tenant_id() IS NULL THEN
    PERFORM core.raise_hk('HK_AST_CONTEXT', 'tenant context required');
  END IF;
  UPDATE assistant.llm_call SET status = 'abandoned'
   WHERE id IN (SELECT id FROM assistant.llm_call WHERE tenant_id = core.current_tenant_id() AND status = 'in_flight'
                   AND lease_expires_at < now() ORDER BY lease_expires_at LIMIT p_limit FOR UPDATE SKIP LOCKED);
  GET DIAGNOSTICS n1 = ROW_COUNT;
  UPDATE assistant.run r SET status = 'failed', error_code = 'assistant.run.lease_expired'
   WHERE r.id IN (SELECT x.id FROM assistant.run x WHERE x.tenant_id = core.current_tenant_id() AND x.status = 'running'
                     AND x.lease_expires_at < now()
                     AND NOT EXISTS (SELECT 1 FROM assistant.llm_call l WHERE l.tenant_id = x.tenant_id AND l.run_id = x.id
                                       AND l.status = 'in_flight')
                   ORDER BY x.lease_expires_at LIMIT p_limit FOR UPDATE SKIP LOCKED);
  GET DIAGNOSTICS n2 = ROW_COUNT;
  RETURN n1 + n2;
END $$;

-- پاک‌سازی نگهداری: فقط در زمینهٔ سیستمی (بدون app.user_id)، با توقیف قانونی مسدود می‌شود.
CREATE OR REPLACE FUNCTION assistant.purge_threads(p_created_before timestamptz, p_limit integer DEFAULT 500) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
  IF core.current_tenant_id() IS NULL OR core.current_user_id() IS NOT NULL THEN
    PERFORM core.raise_hk('HK_AST_SYSTEM_ONLY', 'purge runs only in a system tenant context');
  END IF;
  IF p_created_before > now() - interval '1 day' THEN
    PERFORM core.raise_hk('HK_AST_RETENTION', 'conversation retention is at least one day');
  END IF;
  IF EXISTS (SELECT 1 FROM core.legal_hold h WHERE h.tenant_id = core.current_tenant_id() AND h.released_at IS NULL
              AND (h.scope = 'tenant' OR (h.scope = 'resource' AND h.resource_type = 'assistant.thread'))) THEN
    PERFORM core.raise_hk('HK_AST_LEGAL_HOLD', 'a legal hold blocks conversation purge');
  END IF;
  DELETE FROM assistant.thread
   WHERE id IN (SELECT id FROM assistant.thread WHERE tenant_id = core.current_tenant_id() AND created_at < p_created_before
                 ORDER BY created_at LIMIT p_limit);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- سازگاری رجیستری ابزار با کاتالوگ مجوز (CI روی پایگاه دادهٔ یکپارچه باید خالی باشد)
CREATE OR REPLACE FUNCTION assistant.catalog_lint() RETURNS TABLE (object text, problem text)
LANGUAGE sql STABLE AS $$
  SELECT tp.tool_code || ' / ' || tp.permission_code, 'permission_not_in_core_catalog'
    FROM assistant.tool_permission tp WHERE NOT EXISTS (SELECT 1 FROM core.permission p WHERE p.code = tp.permission_code)
  UNION ALL
  SELECT tp.tool_code || ' / ' || tp.permission_code, 'permission_critical'
    FROM assistant.tool_permission tp JOIN core.permission p ON p.code = tp.permission_code WHERE p.risk = 'critical'
  UNION ALL
  SELECT tp.tool_code || ' / ' || tp.permission_code, 'permission_deprecated'
    FROM assistant.tool_permission tp JOIN core.permission p ON p.code = tp.permission_code WHERE p.deprecated_at IS NOT NULL
  UNION ALL
  SELECT t.code, 'proposal_tool_without_materialize_permission' FROM assistant.tool t
   WHERE t.kind = 'proposal' AND NOT EXISTS (SELECT 1 FROM assistant.tool_permission tp WHERE tp.tool_code = t.code AND tp.requirement = 'materialize')
  UNION ALL
  SELECT t.code, 'data_tool_without_read_permission' FROM assistant.tool t
   WHERE t.kind IN ('query','proposal') AND NOT EXISTS (SELECT 1 FROM assistant.tool_permission tp WHERE tp.tool_code = t.code AND tp.requirement = 'read')
  UNION ALL
  SELECT s.code, 'suggestion_uses_deprecated_tool' FROM assistant.prompt_suggestion s
   WHERE s.active AND EXISTS (SELECT 1 FROM unnest(s.required_tools) x JOIN assistant.tool t ON t.code = x WHERE t.deprecated_at IS NOT NULL)
$$;

-- =====================================================================
-- ۱۶. دادهٔ کاتالوگ
-- =====================================================================
INSERT INTO assistant.data_class (code, sensitivity, grantable, description_key) VALUES
  ('reference_names',     'low',        true,  'ast.dc.reference_names'),      -- نام حساب، انبار، صندوق، گروه
  ('item_name',           'low',        true,  'ast.dc.item_name'),
  ('financial_aggregate', 'medium',     true,  'ast.dc.financial_aggregate'),  -- جمع، مانده، تعداد
  ('document_detail',     'medium',     true,  'ast.dc.document_detail'),      -- سطرهای سند و کارت حساب (محدود)
  ('party_name',          'medium',     true,  'ast.dc.party_name'),           -- بدون رضایت: نام مستعار
  ('migration_schema',    'medium',     true,  'ast.dc.migration_schema'),     -- سرستون و نمونهٔ ماسک‌شده
  ('cost_margin',         'high',       true,  'ast.dc.cost_margin'),
  ('payroll_aggregate',   'high',       true,  'ast.dc.payroll_aggregate'),    -- جمع حقوق بدون فرد
  ('employee_personal',   'prohibited', false, 'ast.dc.employee_personal'),
  ('contact_pii',         'prohibited', false, 'ast.dc.contact_pii')           -- موبایل، کد ملی، نشانی، شبا، کارت
ON CONFLICT (code) DO NOTHING;

INSERT INTO assistant.purpose (code, phase, feature, description_key) VALUES
  ('chat',                'v1', 'chat',              'ast.purpose.chat'),
  ('migration_mapping',   'v1', 'migration_mapping', 'ast.purpose.migration_mapping'),
  ('voice_transcription', 'v2', 'voice',             'ast.purpose.voice_transcription'),
  ('document_ocr',        'v2', 'ocr',               'ast.purpose.document_ocr'),
  ('insight_narration',   'v2', 'insights',          'ast.purpose.insight_narration')
ON CONFLICT (code) DO NOTHING;

INSERT INTO assistant.proposal_kind (code, target_module, materialization, ttl, phase, description_key) VALUES
  ('journal_draft',        'ledger',    'server_draft',   interval '7 days', 'v1', 'ast.pk.journal_draft'),
  ('purchase_order_draft', 'purchase',  'server_draft',   interval '7 days', 'v1', 'ast.pk.purchase_order_draft'),
  ('payment_reminder_sms', 'treasury',  'human_send',     interval '2 days', 'v1', 'ast.pk.payment_reminder_sms'),
  ('party_form_prefill',   'parties',   'client_prefill', interval '1 day',  'v1', 'ast.pk.party_form_prefill'),
  ('purchase_invoice_ocr', 'purchase',  'server_draft',   interval '7 days', 'v2', 'ast.pk.purchase_invoice_ocr')
ON CONFLICT (code) DO NOTHING;

INSERT INTO assistant.tool (code, version, kind, module, service_ref, data_classes, optional_data_classes, proposal_kind,
                            max_result_bytes, max_rows, phase, introduced_in) VALUES
  ('sales.summary',              1, 'query', 'sales',     'hesabketab.sales.api.queries:SalesQuery.summary',
     '{financial_aggregate}', '{}', NULL, 8192, 31, 'v1', '1.0'),
  ('sales.top_items',            1, 'query', 'sales',     'hesabketab.sales.api.queries:SalesQuery.top_items',
     '{financial_aggregate,item_name}', '{cost_margin}', NULL, 16384, 20, 'v1', '1.0'),
  ('treasury.cash_position',     1, 'query', 'treasury',  'hesabketab.treasury.api.queries:FundQuery.position',
     '{financial_aggregate,reference_names}', '{}', NULL, 8192, 30, 'v1', '1.0'),
  ('treasury.receivables_aging', 1, 'query', 'treasury',  'hesabketab.treasury.api.queries:OpenItemQuery.aging',
     '{financial_aggregate}', '{party_name}', NULL, 16384, 20, 'v1', '1.0'),
  ('treasury.cheques_due',       1, 'query', 'treasury',  'hesabketab.treasury.api.queries:ChequeQuery.due',
     '{financial_aggregate,document_detail}', '{party_name}', NULL, 16384, 30, 'v1', '1.0'),
  ('inventory.low_stock',        1, 'query', 'inventory', 'hesabketab.inventory.api.queries:StockQuery.below_min',
     '{item_name}', '{}', NULL, 16384, 30, 'v1', '1.0'),
  ('ledger.trial_balance',       1, 'query', 'ledger',    'hesabketab.ledger.api.queries:LedgerReportQuery.trial_balance',
     '{financial_aggregate,reference_names}', '{}', NULL, 32768, 60, 'v1', '1.0'),
  ('ledger.account_statement',   1, 'query', 'ledger',    'hesabketab.ledger.api.queries:LedgerReportQuery.account_statement',
     '{financial_aggregate,document_detail,reference_names}', '{}', NULL, 32768, 40, 'v1', '1.0'),
  ('ledger.profit_and_loss',     1, 'query', 'ledger',    'hesabketab.ledger.api.queries:StatementQuery.evaluate',
     '{financial_aggregate,reference_names}', '{}', NULL, 16384, 40, 'v1', '1.0'),
  ('ledger.account_search',      1, 'query', 'ledger',    'hesabketab.ledger.api.queries:AccountQuery.search',
     '{reference_names}', '{}', NULL, 8192, 10, 'v1', '1.0'),
  ('tax.vat_position',           1, 'query', 'tax',       'hesabketab.tax.api.queries:TaxQuery.vat_return',
     '{financial_aggregate}', '{}', NULL, 8192, 12, 'v1', '1.0'),
  ('payroll.cost_summary',       1, 'query', 'payroll',   'hesabketab.payroll.api.queries:PayrollQuery.cost_summary',
     '{payroll_aggregate}', '{}', NULL, 8192, 12, 'v1', '1.0'),
  ('catalog.item_search',        1, 'query', 'catalog',   'hesabketab.catalog.api.queries:CatalogQuery.search',
     '{item_name}', '{}', NULL, 8192, 10, 'v1', '1.0'),
  ('parties.party_search',       1, 'query', 'parties',   'hesabketab.parties.api.queries:PartyQuery.search',
     '{party_name}', '{}', NULL, 8192, 10, 'v1', '1.0'),
  ('assistant.calculate',        1, 'utility', 'assistant', 'hesabketab.assistant.tools.calc:Calculator.evaluate',
     '{}', '{}', NULL, 1024, 0, 'v1', '1.0'),
  ('ledger.propose_journal',     1, 'proposal', 'ledger', 'hesabketab.ledger.api.services:ManualJournalService.validate',
     '{financial_aggregate,reference_names}', '{}', 'journal_draft', 16384, 0, 'v1', '1.0'),
  ('purchase.propose_order',     1, 'proposal', 'purchase', 'hesabketab.purchase.api.services:PurchaseOrderService.validate',
     '{item_name,party_name}', '{}', 'purchase_order_draft', 16384, 0, 'v1', '1.0'),
  ('treasury.propose_payment_reminder', 1, 'proposal', 'treasury', 'hesabketab.treasury.api.services:PartyReminderService.preview',
     '{financial_aggregate,party_name}', '{}', 'payment_reminder_sms', 8192, 0, 'v1', '1.0'),
  ('parties.propose_party',      1, 'proposal', 'parties', 'hesabketab.parties.api.services:PartyService.validate',
     '{party_name}', '{}', 'party_form_prefill', 8192, 0, 'v1', '1.0')
ON CONFLICT (code) DO NOTHING;

INSERT INTO assistant.tool_permission (tool_code, permission_code, requirement) VALUES
  ('sales.summary',                     'sales.report.read',        'read'),
  ('sales.summary',                     'pos.report.read',          'read_optional'),
  ('sales.top_items',                   'sales.report.read',        'read'),
  ('sales.top_items',                   'inventory.cost.read',      'read_optional'),
  ('treasury.cash_position',            'treasury.fund.read',       'read'),
  ('treasury.receivables_aging',        'treasury.document.read',   'read'),
  ('treasury.receivables_aging',        'parties.party.read',       'read_optional'),
  ('treasury.cheques_due',              'treasury.cheque.read',     'read'),
  ('treasury.cheques_due',              'parties.party.read',       'read_optional'),
  ('inventory.low_stock',               'inventory.stock.read',     'read'),
  ('ledger.trial_balance',              'ledger.report.read',       'read'),
  ('ledger.account_statement',          'ledger.report.read',       'read'),
  ('ledger.account_statement',          'ledger.account.read',      'read'),
  ('ledger.profit_and_loss',            'ledger.report.read',       'read'),
  ('ledger.account_search',             'ledger.account.read',      'read'),
  ('tax.vat_position',                  'tax.vat_return.read',      'read'),
  ('payroll.cost_summary',              'payroll.report.read',      'read'),
  ('catalog.item_search',               'catalog.item.read',        'read'),
  ('catalog.item_search',               'inventory.stock.read',     'read_optional'),
  ('parties.party_search',              'parties.party.read',       'read'),
  ('ledger.propose_journal',            'ledger.account.read',      'read'),
  ('ledger.propose_journal',            'ledger.journal.create',    'materialize'),
  ('purchase.propose_order',            'catalog.item.read',        'read'),
  ('purchase.propose_order',            'parties.party.read',       'read'),
  ('purchase.propose_order',            'purchase.order.create',    'materialize'),
  ('treasury.propose_payment_reminder', 'treasury.document.read',   'read'),
  ('treasury.propose_payment_reminder', 'parties.party.read',       'read'),
  ('treasury.propose_payment_reminder', 'treasury.reminder.send',   'materialize'),
  ('parties.propose_party',             'parties.party.read',       'read'),
  ('parties.propose_party',             'parties.party.create',     'materialize')
ON CONFLICT DO NOTHING;

INSERT INTO assistant.prompt_suggestion (code, pack_code, page_context, text, required_tools, sort_order) VALUES
  ('general.sales_today',    NULL, 'dock', 'فروش امروز چطور بود؟',                       '{sales.summary}',              10),
  ('general.top_items_week', NULL, 'dock', 'پرفروش‌ترین کالاهای این هفته کدام‌اند؟',      '{sales.top_items}',            20),
  ('general.cash_position',  NULL, 'dock', 'الان چقدر پول نقد و در بانک داریم؟',           '{treasury.cash_position}',     30),
  ('general.receivables',    NULL, 'dock', 'چه کسانی بیشترین بدهی را به ما دارند؟',        '{treasury.receivables_aging}', 40),
  ('general.cheques_week',   NULL, 'dock', 'چک‌های سررسید این هفته را نشان بده',           '{treasury.cheques_due}',       50),
  ('general.low_stock',      NULL, 'dock', 'چه کالاهایی رو به اتمام است؟',                '{inventory.low_stock}',        60),
  ('general.pnl_month',      NULL, 'dock', 'سود و زیان این ماه چقدر است؟',                '{ledger.profit_and_loss}',     70),
  ('general.vat_position',   NULL, 'dock', 'وضعیت مالیات بر ارزش افزوده این فصل چیست؟',   '{tax.vat_position}',           80),
  ('cheques.due_page',       NULL, 'treasury.cheques', 'کدام چک‌ها در هفتهٔ آینده سررسید می‌شوند؟', '{treasury.cheques_due}', 10),
  ('purchase.reorder',       NULL, 'inventory.stock', 'برای کالاهای رو به اتمام پیش‌نویس سفارش خرید پیشنهاد بده', '{inventory.low_stock,purchase.propose_order}', 10)
ON CONFLICT (code) DO NOTHING;

-- ---------- کاتالوگ‌های هسته (هر ماژول کاتالوگ خودش را اضافه می‌کند) ----------
INSERT INTO core.permission (code, module, scope_dimensions, risk, allow_service_account, allow_impersonation_write, description_key, introduced_in) VALUES
  ('assistant.chat.use',        'assistant', '{company}', 'normal',    false, false, 'perm.assistant.chat.use',        '1.0'),
  ('assistant.usage.read',      'assistant', '{}',        'normal',    false, false, 'perm.assistant.usage.read',      '1.0'),
  ('assistant.settings.manage', 'assistant', '{}',        'sensitive', false, false, 'perm.assistant.settings.manage', '1.0'),
  ('assistant.consent.manage',  'assistant', '{}',        'critical',  false, false, 'perm.assistant.consent.manage',  '1.0'),
  ('assistant.provider.manage', 'assistant', '{}',        'critical',  false, false, 'perm.assistant.provider.manage', '1.0')
ON CONFLICT (code) DO NOTHING;

INSERT INTO core.role_template_permission (template_code, permission_code)
SELECT t.code, 'assistant.chat.use' FROM core.role_template t
 WHERE t.code IN ('admin','accountant','sales_clerk','purchaser','warehouse_keeper','payroll_officer','auditor','member')
UNION ALL SELECT 'admin', 'assistant.usage.read'
UNION ALL SELECT 'admin', 'assistant.settings.manage'
UNION ALL SELECT 'auditor', 'assistant.usage.read'
ON CONFLICT DO NOTHING;

INSERT INTO core.field_guard (resource, field, read_permission, write_permission, mask_style, is_secret) VALUES
  ('assistant.tenant_provider', 'api_key', 'assistant.provider.manage', 'assistant.provider.manage', 'omit', true),
  ('assistant.consent', 'signer_full_name', 'assistant.consent.manage', NULL, 'redact', false)
ON CONFLICT DO NOTHING;

INSERT INTO core.setting_def (key, module, value_type, enum_values, min_value, max_value, json_schema, allowed_levels, default_value,
                              read_permission, write_permission, description_key, introduced_in) VALUES
  ('assistant.retention_days',        'assistant', 'int',  NULL, 1, 365, NULL, '{tenant}', '90', NULL, 'assistant.settings.manage', 'setting.assistant.retention_days', '1.0'),
  ('assistant.user_monthly_tokens',   'assistant', 'int',  NULL, 0, 100000000, NULL, '{tenant}', '0', NULL, 'assistant.settings.manage', 'setting.assistant.user_monthly_tokens', '1.0'),
  ('assistant.proposals_enabled',     'assistant', 'bool', NULL, NULL, NULL, NULL, '{tenant,company}', 'true', NULL, 'assistant.settings.manage', 'setting.assistant.proposals_enabled', '1.0'),
  ('assistant.disabled_tools',        'assistant', 'json', NULL, NULL, NULL,
     '{"type":"array","items":{"type":"string","pattern":"^[a-z][a-z0-9_]*\\.[a-z][a-z0-9_]*$"},"maxItems":64,"uniqueItems":true}',
     '{tenant,company}', '[]', NULL, 'assistant.settings.manage', 'setting.assistant.disabled_tools', '1.0'),
  ('assistant.dock_visible',          'assistant', 'bool', NULL, NULL, NULL, NULL, '{tenant,user}', 'true', NULL, 'assistant.settings.manage', 'setting.assistant.dock_visible', '1.0'),
  ('assistant.voice_enabled',         'assistant', 'bool', NULL, NULL, NULL, NULL, '{tenant,user}', 'false', NULL, 'assistant.settings.manage', 'setting.assistant.voice_enabled', '1.0')
ON CONFLICT (key) DO NOTHING;

INSERT INTO core.retention_class (code, basis, default_period, rules_param_key, min_period, action, description_key) VALUES
  ('assistant_conversation', 'created_at', interval '90 days',  NULL, interval '1 day',    'delete', 'ret.assistant_conversation'),
  ('assistant_metering',     'closed_at',  interval '400 days', NULL, interval '400 days', 'delete', 'ret.assistant_metering')
ON CONFLICT DO NOTHING;

INSERT INTO core.notification_category (code, module, is_mandatory, default_channels, description_key) VALUES
  ('assistant.system', 'assistant', false, '{in_app}', 'ntf.assistant.system')
ON CONFLICT DO NOTHING;
INSERT INTO core.notification_template_def (code, category, channel, locale, subject, body, sms_pattern_code, variables, tenant_overridable) VALUES
  ('assistant.budget_warning',   'assistant.system', 'in_app', 'fa-IR', 'بودجهٔ دستیار', '{percent} درصد بودجهٔ ماهانهٔ دستیار مصرف شده است.', NULL, '{percent}', true),
  ('assistant.consent_changed',  'assistant.system', 'in_app', 'fa-IR', 'رضایت دستیار', 'رضایت پردازش دادهٔ دستیار توسط {actor} {action} شد.', NULL, '{actor,action}', false),
  ('assistant.provider_changed', 'assistant.system', 'in_app', 'fa-IR', 'ارائه‌دهندهٔ مدل', 'مقصد دادهٔ دستیار تغییر کرده است؛ تا تأیید دوباره، دستیار خاموش است.', NULL, '{}', false)
ON CONFLICT DO NOTHING;

INSERT INTO core.event_subscription (event_type, subscriber) VALUES
  ('assistant.run.metered',     'uplink'),
  ('assistant.consent.changed', 'uplink')
ON CONFLICT DO NOTHING;

INSERT INTO core.export_table_registry (schema_name, table_name, module, mode, export_order, pii_columns, secret_columns, note) VALUES
  ('assistant','tenant_policy',   'assistant', 'skip', 0,    '{}', '{}', 'placement-specific; re-applied from signed desired state or license on the target'),
  ('assistant','tenant_provider', 'assistant', 'hook', 8000, '{}', '{api_key_sealed}', 'assistant.reseal hook re-seals the API key with the target KeyManager'),
  ('assistant','consent',         'assistant', 'rows', 8010, '{signer_full_name}', '{}', NULL),
  ('assistant','usage_period',    'assistant', 'rows', 8020, '{}', '{}', NULL),
  ('assistant','thread',          'assistant', 'rows', 8030, '{title}', '{}', NULL),
  ('assistant','run',             'assistant', 'rows', 8040, '{}', '{}', NULL),
  ('assistant','llm_call',        'assistant', 'rows', 8050, '{}', '{}', NULL),
  ('assistant','message',         'assistant', 'rows', 8060, '{content}', '{}', NULL),
  ('assistant','tool_call',       'assistant', 'rows', 8070, '{args,result}', '{}', NULL),
  ('assistant','proposal',        'assistant', 'rows', 8080, '{payload,validation}', '{}', NULL),
  ('assistant','feedback',        'assistant', 'rows', 8090, '{comment}', '{}', NULL)
ON CONFLICT DO NOTHING;

-- =====================================================================
-- ۱۷. دسترسی‌ها (کمینه)
-- =====================================================================
GRANT SELECT ON assistant.data_class, assistant.purpose, assistant.proposal_kind, assistant.tool, assistant.tool_permission,
                assistant.prompt_suggestion TO hk_app, hk_readonly;
GRANT SELECT, INSERT, UPDATE ON assistant.tenant_policy, assistant.tenant_provider, assistant.consent, assistant.proposal TO hk_app;
GRANT SELECT, INSERT, DELETE ON assistant.usage_period TO hk_app;
GRANT UPDATE (token_limit, cost_limit, limit_source) ON assistant.usage_period TO hk_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON assistant.thread, assistant.run, assistant.llm_call, assistant.feedback TO hk_app;
GRANT SELECT, INSERT ON assistant.message, assistant.tool_call TO hk_app;               -- فقط‌افزودنی؛ حذف فقط آبشاری از رشته
GRANT SELECT ON assistant.v_usage, assistant.v_run_usage, assistant.v_permission_ceiling TO hk_app, hk_readonly;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA assistant TO hk_app;

-- فقط‌خواندنی (گزارش و پشتیبانی): فراداده بله، محتوای گفت‌وگو و راز نه
GRANT SELECT ON assistant.tenant_policy, assistant.usage_period, assistant.run, assistant.llm_call TO hk_readonly;
GRANT SELECT (tenant_id, id, display_name, operator, data_location, base_url, model, auth_header, allow_private_network,
              connect_timeout_ms, first_token_timeout_ms, total_timeout_ms, max_output_tokens, max_context_tokens, capabilities,
              price_unit, input_price_per_mtok, output_price_per_mtok, fingerprint, status, last_probe_at, last_probe_ok,
              created_by, updated_by, created_at, updated_at, row_version) ON assistant.tenant_provider TO hk_readonly;
GRANT SELECT (tenant_id, id, status, purposes, data_classes, provider_fingerprints, provider_summary, consent_text_code,
              consent_text_sha256, granted_by, granted_at, signer_capacity, mfa_at, ended_at, ended_by, end_reason, superseded_by)
  ON assistant.consent TO hk_readonly;
GRANT SELECT (tenant_id, id, user_id, company_id, status, page_context, message_count, last_activity_at, created_at, updated_at, row_version)
  ON assistant.thread TO hk_readonly;
GRANT SELECT (tenant_id, id, thread_id, user_id, run_id, seq, role, input_mode, finish, created_at) ON assistant.message TO hk_readonly;
GRANT SELECT (tenant_id, id, run_id, llm_call_id, thread_id, user_id, seq, tool_code, tool_version, status, args_sha256, result_bytes,
              result_rows, truncated, pseudonymized, permissions_checked, denied_permission, error_code, latency_ms, created_at)
  ON assistant.tool_call TO hk_readonly;
GRANT SELECT (tenant_id, id, tool_call_id, run_id, thread_id, user_id, company_id, kind, payload_sha256, valid, status, expires_at,
              decided_at, decided_by, target_type, target_id, failure_code, created_at, updated_at, row_version)
  ON assistant.proposal TO hk_readonly;
GRANT SELECT (tenant_id, id, message_id, user_id, rating, reason, created_at, updated_at, row_version) ON assistant.feedback TO hk_readonly;
