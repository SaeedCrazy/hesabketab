-- =====================================================================
-- حساب‌کتاب — 50_compliance.sql   (سند طراحی: docs/design/07-compliance.md)
-- انطباق قانونی: موتور قواعد نسخه‌دار (rules)، ارزش افزوده و سامانهٔ مؤدیان (tax)،
-- حقوق و دستمزد و بیمه (payroll)، دارایی ثابت (assets)، تقویم انطباق.
--
-- پیش‌نیاز (به همین ترتیب): 00_foundation.sql → 10_core.sql → 20_ledger.sql → 25_masterdata.sql.
-- فایل‌های 30 (بازرگانی) و 40 (خزانه/صندوق) لازم نیستند: ارجاع به sales، purchase، treasury و pos
-- فقط ستون uuid است و FKهایشان در سند §۱۲ آمده‌اند (99_cross_fk.sql).
-- اجرا با نقش migrator/superuser روی پایگاه دادهٔ UTF8.
--
-- قواعد مشترک: PK = id uuid DEFAULT uuidv7()؛ هر جدول مستأجری tenant_id NOT NULL، UNIQUE (tenant_id, id)
-- و core.enable_tenant_rls؛ ارجاع بین جدول‌های مستأجری همیشه FK ترکیبی (tenant_id, x_id).
-- جدول‌های سراسری rules (بسته، مقدار پارامتر، آزمون طلایی) را فقط نصب‌کنندهٔ بستهٔ امضاشده با نقش migrator
-- می‌نویسد؛ hk_app فقط SELECT دارد. هیچ رقم قانونی در این فایل نیست: فقط «تعریف» کلیدها (param_def) و
-- کاتالوگ‌های کدی. مقدارها فقط از بستهٔ .hkrules امضاشده می‌آیند.
-- این فایل هیچ تابع SECURITY DEFINER ندارد.
-- =====================================================================

DO $$
BEGIN
  IF current_setting('server_encoding') <> 'UTF8' THEN
    RAISE EXCEPTION 'HK_ENCODING: data-plane database must be UTF8 (found %)', current_setting('server_encoding');
  END IF;
  IF to_regprocedure('core.number_next(uuid,text,text,text,uuid)') IS NULL
     OR to_regclass('ledger.journal') IS NULL OR to_regclass('parties.party') IS NULL OR to_regclass('ref.sstid') IS NULL THEN
    RAISE EXCEPTION 'HK_PREREQ: apply 10_core.sql, 20_ledger.sql and 25_masterdata.sql first';
  END IF;
END $$;

-- =====================================================================
-- ۰. کمکی‌های مشترک
-- =====================================================================
-- مقایسهٔ نسخهٔ CalVer (YYYY.M.P) به‌صورت عددی
CREATE OR REPLACE FUNCTION rules.version_ge(p_a text, p_b text) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT string_to_array(p_a, '.')::int[] >= string_to_array(p_b, '.')::int[]
$$;

-- رتبهٔ اطمینان (برای کمینه‌گیری): high > medium > low > unverified
CREATE OR REPLACE FUNCTION rules.confidence_rank(p text) RETURNS smallint
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE p WHEN 'high' THEN 4 WHEN 'medium' THEN 3 WHEN 'low' THEN 2 WHEN 'unverified' THEN 1 END::smallint
$$;

-- مقایسهٔ آرایهٔ ستون‌های تغییرکرده (برای نگهبان‌های «فقط این ستون‌ها قابل تغییرند»)
CREATE OR REPLACE FUNCTION rules.changed_columns(p_old jsonb, p_new jsonb) RETURNS text[]
LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(array_agg(k ORDER BY k), '{}')
    FROM jsonb_object_keys(p_new) k
   WHERE p_old -> k IS DISTINCT FROM p_new -> k
$$;

-- =====================================================================
-- ۱. rules — کاتالوگ تعریف پارامترها (کدی؛ با migration؛ بدون مقدار)
-- =====================================================================
CREATE TABLE IF NOT EXISTS rules.param_def (
  key              text PRIMARY KEY CHECK (key ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,6}$'),
  domain           text NOT NULL CHECK (domain IN ('tax','payroll','assets','calendar','currency','retention')),
  package_code     text NOT NULL CHECK (package_code ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,3}$'),  -- بستهٔ مالک مقدارها
  value_type       text NOT NULL CHECK (value_type IN ('money','decimal','integer','percent','ratio','boolean','text','enum','date','table','json')),
  unit             text CHECK (unit IN ('IRR','percent','ratio','days','months','hours','years','seconds','count')),
  enum_values      text[],
  qualifier_kind   text NOT NULL DEFAULT 'none' CHECK (qualifier_kind IN ('none','code','class','period','profile','obligation_period','year')),
  override_policy  text NOT NULL DEFAULT 'none' CHECK (override_policy IN ('none','any','floor','ceiling')),
  override_levels  text[] NOT NULL DEFAULT '{}' CHECK (override_levels <@ ARRAY['tenant','company','workshop']::text[]),
  description_key  text NOT NULL,
  introduced_in    text NOT NULL,
  deprecated_at    timestamptz,
  CHECK (split_part(key, '.', 1) = domain),
  CHECK ((value_type = 'enum') = (enum_values IS NOT NULL)),
  CHECK ((value_type = 'money') = (unit = 'IRR')),
  CHECK (value_type <> 'percent' OR unit = 'percent'),
  CHECK ((override_policy = 'none') = (cardinality(override_levels) = 0)),
  CHECK (override_policy NOT IN ('floor','ceiling') OR value_type IN ('money','decimal','integer','percent','ratio'))
);

-- اعتبار شکل مقدار JSON نسبت به نوع تعریف (همتای Python: hesabketab.rules.domain.values)
CREATE OR REPLACE FUNCTION rules.value_valid_raw(p_type text, p_enum text[], p_value jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v jsonb := p_value -> 'v'; s text;
BEGIN
  IF p_value IS NULL OR jsonb_typeof(p_value) <> 'object' THEN RETURN false; END IF;
  IF p_type = 'money' THEN
    RETURN jsonb_typeof(p_value -> 'amount') = 'string' AND (p_value ->> 'amount') ~ '^[0-9]+(\.[0-9]{1,4})?$'
           AND (p_value ->> 'unit') IN ('IRR','IRT','IRR_NEW');
  ELSIF p_type = 'table' THEN
    RETURN jsonb_typeof(p_value -> 'rows') = 'array' AND jsonb_array_length(p_value -> 'rows') >= 1;
  ELSIF v IS NULL THEN
    RETURN false;
  ELSIF p_type IN ('decimal','percent','ratio') THEN
    IF jsonb_typeof(v) <> 'string' THEN RETURN false; END IF;
    s := v #>> '{}';
    IF s !~ '^-?[0-9]+(\.[0-9]{1,12})?$' THEN RETURN false; END IF;
    RETURN CASE p_type WHEN 'percent' THEN s::numeric BETWEEN 0 AND 100
                       WHEN 'ratio'   THEN s::numeric >= 0
                       ELSE true END;
  ELSIF p_type = 'integer' THEN
    RETURN jsonb_typeof(v) = 'number' AND (v #>> '{}') ~ '^-?[0-9]+$';
  ELSIF p_type = 'boolean' THEN
    RETURN jsonb_typeof(v) = 'boolean';
  ELSIF p_type = 'text' THEN
    RETURN jsonb_typeof(v) = 'string' AND char_length(v #>> '{}') BETWEEN 1 AND 2000;
  ELSIF p_type = 'enum' THEN
    RETURN jsonb_typeof(v) = 'string' AND (v #>> '{}') = ANY (p_enum);
  ELSIF p_type = 'date' THEN
    IF jsonb_typeof(v) <> 'string' OR (v #>> '{}') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN RETURN false; END IF;
    BEGIN
      RETURN to_char((v #>> '{}')::date, 'YYYY-MM-DD') = (v #>> '{}');
    EXCEPTION WHEN datetime_field_overflow OR invalid_datetime_format THEN
      RETURN false;
    END;
  ELSIF p_type = 'json' THEN
    RETURN jsonb_typeof(v) IN ('object','array');
  END IF;
  RETURN false;
END $$;
-- NULL (مثلاً واحد غایب) همیشه «نامعتبر» است، نه «نامعلوم»
CREATE OR REPLACE FUNCTION rules.value_valid(p_type text, p_enum text[], p_value jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$ SELECT coalesce(rules.value_valid_raw(p_type, p_enum, p_value), false) $$;

-- مقدار عددی قابل مقایسه (برای سیاست کف/سقف)؛ NULL برای انواع غیرعددی
CREATE OR REPLACE FUNCTION rules.value_numeric(p_type text, p_value jsonb) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_type = 'money' AND p_value ->> 'unit' = 'IRR' THEN (p_value ->> 'amount')::numeric
              WHEN p_type IN ('decimal','percent','ratio') THEN (p_value ->> 'v')::numeric
              WHEN p_type = 'integer' THEN (p_value ->> 'v')::numeric END
$$;

-- =====================================================================
-- ۲. rules — بسته‌های قواعد نصب‌شده (سراسری؛ نویسنده: نصب‌کنندهٔ .hkrules با نقش migrator)
-- =====================================================================
CREATE TABLE IF NOT EXISTS rules.package (
  id                  uuid PRIMARY KEY,                     -- شناسهٔ پایدار صفحهٔ کنترل (در همهٔ سلول‌ها یکی)
  code                text NOT NULL CHECK (code ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,3}$'),   -- 'ir.tax', 'ir.payroll', ...
  jurisdiction        text NOT NULL DEFAULT 'IR' CHECK (jurisdiction ~ '^[A-Z]{2}(-[A-Z0-9]{1,10})?$'),
  version             text NOT NULL CHECK (version ~ '^[0-9]{4}\.[0-9]{1,4}$'),            -- '1405.3'
  seq                 integer NOT NULL CHECK (seq >= 1),                                     -- یکنوا برای هر code
  covers_from         date NOT NULL,
  covers_to           date,
  status              text NOT NULL DEFAULT 'installing'
                      CHECK (status IN ('installing','installed','active','superseded','withdrawn','rejected')),
  min_engine_version  text NOT NULL CHECK (min_engine_version ~ '^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$'),
  payload_sha256      bytea NOT NULL CHECK (octet_length(payload_sha256) = 32),
  hksb_sha256         bytea NOT NULL CHECK (octet_length(hksb_sha256) = 32),
  signer_kid          text NOT NULL CHECK (char_length(signer_kid) BETWEEN 3 AND 80),
  published_at        timestamptz NOT NULL,
  authored_by         text NOT NULL CHECK (char_length(authored_by) BETWEEN 2 AND 120),
  approved_by         text[] NOT NULL,
  review_due_on       date,                                  -- نقطهٔ بازبینی اجباری (مثلاً پایان اعتبار نوع ۳)
  changelog_fa        text NOT NULL CHECK (char_length(changelog_fa) BETWEEN 1 AND 20000),
  installed_via       text NOT NULL CHECK (installed_via IN ('desired_state','offline_file','migration','test_fixture')),
  installed_at        timestamptz NOT NULL DEFAULT now(),
  activated_at        timestamptz,
  superseded_at       timestamptz,
  superseded_by       uuid REFERENCES rules.package(id),
  ended_at            timestamptz,
  end_reason          text,
  UNIQUE (code, version),
  UNIQUE (code, seq),
  CHECK (covers_to IS NULL OR covers_to > covers_from),
  -- تأیید دونفره: دست‌کم یک تأییدکننده و نویسنده جزو تأییدکنندگان نیست
  CHECK (cardinality(approved_by) >= 1 AND NOT (authored_by = ANY (approved_by))),
  CHECK ((status IN ('active','superseded')) = (activated_at IS NOT NULL) OR status = 'withdrawn'),
  CHECK ((status = 'superseded') = (superseded_at IS NOT NULL AND superseded_by IS NOT NULL)),
  CHECK ((status IN ('withdrawn','rejected')) = (ended_at IS NOT NULL AND end_reason IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS package_one_active ON rules.package (code) WHERE status = 'active';

CREATE TABLE IF NOT EXISTS rules.param_value (
  id                 uuid PRIMARY KEY DEFAULT uuidv7(),
  package_id         uuid NOT NULL REFERENCES rules.package(id),
  key                text NOT NULL REFERENCES rules.param_def(key),
  qualifier          text NOT NULL DEFAULT '' CHECK (qualifier ~ '^[A-Za-z0-9_.:-]{0,120}$'),
  effective_from     date NOT NULL,
  effective_to       date,                                   -- انحصاری؛ NULL = باز
  value              jsonb NOT NULL,
  approved_on        date,                                   -- تاریخ تصویب/ابلاغ (اگر > effective_from ⇒ عطف به ماسبق)
  source_ref         text NOT NULL CHECK (char_length(source_ref) BETWEEN 2 AND 500),
  source_url         text,
  source_doc_sha256  bytea CHECK (source_doc_sha256 IS NULL OR octet_length(source_doc_sha256) = 32),
  confidence         text NOT NULL CHECK (confidence IN ('high','medium','low','unverified')),
  verified_official  boolean NOT NULL DEFAULT false,
  note_fa            text,
  UNIQUE (package_id, key, qualifier, effective_from),
  CHECK (effective_to IS NULL OR effective_to > effective_from),
  CHECK (NOT verified_official OR confidence IN ('high','medium')),
  EXCLUDE USING gist (package_id WITH =, key WITH =, qualifier WITH =, daterange(effective_from, effective_to, '[)') WITH &&)
);
CREATE INDEX IF NOT EXISTS param_value_lookup ON rules.param_value (key, qualifier, effective_from);

CREATE TABLE IF NOT EXISTS rules.golden_test (
  id           uuid PRIMARY KEY DEFAULT uuidv7(),
  package_id   uuid NOT NULL REFERENCES rules.package(id),
  code         text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$'),
  calculator   text NOT NULL CHECK (calculator ~ '^[a-z][a-z0-9_]*\.[a-z0-9_.]+$'),   -- 'payroll.payslip', 'tax.vat_line', ...
  as_of        date NOT NULL,
  input        jsonb NOT NULL CHECK (jsonb_typeof(input) = 'object'),
  expected     jsonb NOT NULL CHECK (jsonb_typeof(expected) = 'object'),
  signed_by    text NOT NULL CHECK (char_length(signed_by) BETWEEN 2 AND 120),   -- حسابدار امضاکنندهٔ ارقام مورد انتظار
  UNIQUE (package_id, code)
);

CREATE TABLE IF NOT EXISTS rules.golden_run (
  id              uuid PRIMARY KEY DEFAULT uuidv7(),
  package_id      uuid NOT NULL REFERENCES rules.package(id),
  engine_version  text NOT NULL CHECK (engine_version ~ '^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$'),
  runner          text NOT NULL CHECK (runner IN ('install','upgrade','manual','ci')),
  total           integer NOT NULL CHECK (total >= 0),
  passed          integer NOT NULL CHECK (passed >= 0),
  failed          integer NOT NULL CHECK (failed >= 0),
  outcome         text NOT NULL CHECK (outcome IN ('passed','failed')),
  failures        jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(failures) = 'array'),
  started_at      timestamptz NOT NULL,
  finished_at     timestamptz NOT NULL DEFAULT now(),
  CHECK (passed + failed = total),
  CHECK ((outcome = 'passed') = (failed = 0 AND total > 0)),
  CHECK (finished_at >= started_at)
);
CREATE INDEX IF NOT EXISTS golden_run_pkg ON rules.golden_run (package_id, engine_version, outcome);

-- ردپای سراسری چرخهٔ عمر بسته (فقط‌افزودنی؛ تریگر پر می‌کند)
CREATE TABLE IF NOT EXISTS rules.package_event (
  id           uuid PRIMARY KEY DEFAULT uuidv7(),
  package_id   uuid NOT NULL REFERENCES rules.package(id),
  from_status  text,
  to_status    text NOT NULL,
  details      jsonb NOT NULL DEFAULT '{}'::jsonb,
  occurred_at  timestamptz NOT NULL DEFAULT now()
);

-- تکلیف‌های قانونی دوره‌ای (کاتالوگ کدی). قاعدهٔ سررسید = مقدار 'calendar.due_rule' با qualifier = code
CREATE TABLE IF NOT EXISTS rules.obligation_def (
  code           text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,4}$'),
  domain         text NOT NULL CHECK (domain IN ('tax','payroll','ledger','core')),
  frequency      text NOT NULL CHECK (frequency IN ('monthly','quarterly','semiannual','annual','per_event')),
  applies_to     text NOT NULL CHECK (applies_to IN ('company','workshop','memory')),
  title_key      text NOT NULL,
  introduced_in  text NOT NULL,
  CHECK (split_part(code, '.', 1) = domain)
);

-- طبقهٔ مالیاتی کالا/خدمت (پاسخ CR-08 بخش ۰۴): فقط هویت طبقه؛ نرخ هر طبقه مقدار تاریخ‌دار rules است
-- (tax.vat.category_rate / tax.other_levy.rate با qualifier = code). catalog.item.tax_category_code به این جدول FK می‌گیرد (§۱۲).
CREATE TABLE IF NOT EXISTS rules.tax_category (
  code           text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_.]{1,63}$'),
  kind           text NOT NULL CHECK (kind IN ('vat','other_tax','other_levy')),
  title_key      text NOT NULL,
  introduced_in  text NOT NULL,
  deprecated_at  timestamptz
);

-- ---------- نگهبان‌های بسته ----------
CREATE OR REPLACE FUNCTION rules.package_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_changed text[]; v_engine text; v_tests int; v_values int; v_max_seq int;
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM core.raise_hk('HK_RULES_PACKAGE_IMMUTABLE', 'rule packages are never deleted');
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'installing' THEN
      PERFORM core.raise_hk('HK_RULES_PACKAGE_TRANSITION', 'packages are installed in status installing');
    END IF;
    RETURN NEW;
  END IF;
  v_changed := rules.changed_columns(to_jsonb(OLD), to_jsonb(NEW));
  IF NOT (v_changed <@ ARRAY['status','activated_at','superseded_at','superseded_by','ended_at','end_reason']) THEN
    PERFORM core.raise_hk('HK_RULES_PACKAGE_IMMUTABLE', format('cannot change %s', array_to_string(v_changed, ',')));
  END IF;
  IF NEW.status = OLD.status THEN RETURN NEW; END IF;
  IF NOT ((OLD.status, NEW.status) IN (('installing','installed'),('installing','rejected'),('installed','active'),
                                        ('installed','rejected'),('active','superseded'),('active','withdrawn'),
                                        ('superseded','withdrawn'))) THEN
    PERFORM core.raise_hk('HK_RULES_PACKAGE_TRANSITION', format('%s → %s is not allowed', OLD.status, NEW.status));
  END IF;
  IF NEW.status = 'installed' THEN
    SELECT count(*) INTO v_values FROM rules.param_value WHERE package_id = NEW.id;
    SELECT count(*) INTO v_tests FROM rules.golden_test WHERE package_id = NEW.id;
    IF v_values = 0 OR v_tests = 0 THEN
      PERFORM core.raise_hk('HK_RULES_PACKAGE_INCOMPLETE', 'a package needs at least one value and one golden test');
    END IF;
    IF EXISTS (SELECT 1 FROM rules.param_value v JOIN rules.param_def d ON d.key = v.key
                WHERE v.package_id = NEW.id AND d.package_code <> NEW.code) THEN
      PERFORM core.raise_hk('HK_RULES_KEY_NOT_OWNED', 'package carries values for keys owned by another package code');
    END IF;
  ELSIF NEW.status = 'active' THEN
    SELECT app_version INTO v_engine FROM core.deployment_info;
    IF v_engine IS NULL THEN
      PERFORM core.raise_hk('HK_RULES_ENGINE_VERSION_UNKNOWN', 'core.deployment_info has no app_version');
    END IF;
    IF NOT rules.version_ge(v_engine, NEW.min_engine_version) THEN
      PERFORM core.raise_hk('HK_RULES_ENGINE_TOO_OLD', format('package needs engine >= %s (running %s)', NEW.min_engine_version, v_engine));
    END IF;
    SELECT count(*) INTO v_tests FROM rules.golden_test WHERE package_id = NEW.id;
    IF NOT EXISTS (SELECT 1 FROM rules.golden_run r WHERE r.package_id = NEW.id AND r.engine_version = v_engine
                      AND r.outcome = 'passed' AND r.total = v_tests) THEN
      PERFORM core.raise_hk('HK_RULES_GOLDEN_NOT_PASSED', format('no passing golden run of all %s tests on engine %s', v_tests, v_engine));
    END IF;
    SELECT max(seq) INTO v_max_seq FROM rules.package WHERE code = NEW.code AND activated_at IS NOT NULL AND id <> NEW.id;
    IF v_max_seq IS NOT NULL AND NEW.seq <= v_max_seq THEN
      PERFORM core.raise_hk('HK_RULES_PACKAGE_OUTDATED', format('seq %s is not newer than an already activated seq %s', NEW.seq, v_max_seq));
    END IF;
    NEW.activated_at := coalesce(NEW.activated_at, now());
    -- جایگزینی بستهٔ فعال قبلی همان code (پیش از ثبت این ردیف تا ایندکس «یک فعال» نقض نشود)
    UPDATE rules.package SET status = 'superseded', superseded_at = now(), superseded_by = NEW.id
     WHERE code = NEW.code AND status = 'active' AND id <> NEW.id;
  ELSIF NEW.status = 'superseded' THEN
    IF NEW.superseded_by IS NULL OR NOT EXISTS (SELECT 1 FROM rules.package p WHERE p.id = NEW.superseded_by
                                                   AND p.code = NEW.code AND p.seq > NEW.seq) THEN
      PERFORM core.raise_hk('HK_RULES_PACKAGE_TRANSITION', 'superseded only by a newer package of the same code');
    END IF;
  ELSIF NEW.status IN ('withdrawn','rejected') THEN
    IF char_length(btrim(coalesce(NEW.end_reason, ''))) < 10 THEN
      PERFORM core.raise_hk('HK_RULES_REASON_REQUIRED', 'withdraw/reject needs a reason of at least 10 characters');
    END IF;
    NEW.ended_at := coalesce(NEW.ended_at, now());
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_package_guard ON rules.package;
CREATE TRIGGER trg_package_guard BEFORE INSERT OR UPDATE OR DELETE ON rules.package
  FOR EACH ROW EXECUTE FUNCTION rules.package_guard();

CREATE OR REPLACE FUNCTION rules.package_log() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' OR NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO rules.package_event (package_id, from_status, to_status, details)
    VALUES (NEW.id, CASE WHEN TG_OP = 'UPDATE' THEN OLD.status END, NEW.status,
            jsonb_build_object('version', NEW.version, 'seq', NEW.seq, 'reason', NEW.end_reason, 'superseded_by', NEW.superseded_by));
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_package_log ON rules.package;
CREATE TRIGGER trg_package_log AFTER INSERT OR UPDATE ON rules.package
  FOR EACH ROW EXECUTE FUNCTION rules.package_log();

-- محتوای بسته فقط در وضعیت installing درج می‌شود و پس از آن تغییرناپذیر است
CREATE OR REPLACE FUNCTION rules.package_content_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_status text; d rules.param_def;
BEGIN
  SELECT status INTO v_status FROM rules.package WHERE id = NEW.package_id;
  IF v_status IS DISTINCT FROM 'installing' THEN
    PERFORM core.raise_hk('HK_RULES_PACKAGE_SEALED', format('package content can only be added while installing (status %s)', v_status));
  END IF;
  IF TG_TABLE_NAME = 'param_value' THEN
    SELECT * INTO d FROM rules.param_def WHERE key = NEW.key;
    IF d.deprecated_at IS NOT NULL THEN
      PERFORM core.raise_hk('HK_RULES_KEY_DEPRECATED', format('key %s is deprecated', NEW.key));
    END IF;
    IF NOT rules.value_valid(d.value_type, d.enum_values, NEW.value) THEN
      PERFORM core.raise_hk('HK_RULES_VALUE_INVALID', format('value %s does not match type %s of %s', NEW.value, d.value_type, NEW.key));
    END IF;
    IF (d.qualifier_kind = 'none') <> (NEW.qualifier = '') THEN
      PERFORM core.raise_hk('HK_RULES_QUALIFIER', format('qualifier usage does not match definition of %s', NEW.key));
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_content_guard ON rules.param_value;
CREATE TRIGGER trg_content_guard BEFORE INSERT ON rules.param_value FOR EACH ROW EXECUTE FUNCTION rules.package_content_guard();
DROP TRIGGER IF EXISTS trg_content_guard ON rules.golden_test;
CREATE TRIGGER trg_content_guard BEFORE INSERT ON rules.golden_test FOR EACH ROW EXECUTE FUNCTION rules.package_content_guard();
DROP TRIGGER IF EXISTS trg_immutable ON rules.param_value;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON rules.param_value FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();
DROP TRIGGER IF EXISTS trg_immutable ON rules.golden_test;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON rules.golden_test FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();
DROP TRIGGER IF EXISTS trg_immutable ON rules.package_event;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON rules.package_event FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

CREATE OR REPLACE FUNCTION rules.golden_run_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_tests int; v_status text;
BEGIN
  SELECT status INTO v_status FROM rules.package WHERE id = NEW.package_id;
  IF v_status IN ('installing','withdrawn','rejected') THEN
    PERFORM core.raise_hk('HK_RULES_GOLDEN_RUN_STATE', format('cannot record a golden run for a package in status %s', v_status));
  END IF;
  SELECT count(*) INTO v_tests FROM rules.golden_test WHERE package_id = NEW.package_id;
  IF NEW.total <> v_tests THEN
    PERFORM core.raise_hk('HK_RULES_GOLDEN_RUN_PARTIAL', format('golden run must cover all %s tests (got %s)', v_tests, NEW.total));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_golden_run_guard ON rules.golden_run;
CREATE TRIGGER trg_golden_run_guard BEFORE INSERT ON rules.golden_run FOR EACH ROW EXECUTE FUNCTION rules.golden_run_guard();
DROP TRIGGER IF EXISTS trg_immutable ON rules.golden_run;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON rules.golden_run FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

CREATE OR REPLACE FUNCTION rules.param_def_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM core.raise_hk('HK_RULES_DEF_IMMUTABLE', 'parameter definitions are deprecated, never deleted');
  END IF;
  IF (OLD.value_type, OLD.unit, OLD.qualifier_kind, OLD.package_code, OLD.domain)
     IS DISTINCT FROM (NEW.value_type, NEW.unit, NEW.qualifier_kind, NEW.package_code, NEW.domain)
     OR OLD.enum_values IS DISTINCT FROM NEW.enum_values AND NOT (OLD.enum_values <@ NEW.enum_values) THEN
    PERFORM core.raise_hk('HK_RULES_DEF_IMMUTABLE', format('type/unit/qualifier/owner of %s cannot change; add a new key', OLD.key));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_def_guard ON rules.param_def;
CREATE TRIGGER trg_def_guard BEFORE UPDATE OR DELETE ON rules.param_def FOR EACH ROW EXECUTE FUNCTION rules.param_def_guard();

-- ---------- ارزیابی (همتای SQL موتور Python؛ برای گزارش، تریگرهای کف قانونی و آزمون) ----------
-- مقدار رسمی کلید در تاریخ: از بستهٔ فعالِ مالک کلید
CREATE OR REPLACE FUNCTION rules.value_at(p_key text, p_on date, p_qualifier text DEFAULT '') RETURNS rules.param_value
LANGUAGE plpgsql STABLE AS $$
DECLARE d rules.param_def; v rules.param_value; v_pkg uuid;
BEGIN
  SELECT * INTO d FROM rules.param_def WHERE key = p_key;
  IF NOT FOUND THEN PERFORM core.raise_hk('HK_RULES_KEY_UNKNOWN', format('unknown parameter %s', p_key)); END IF;
  SELECT id INTO v_pkg FROM rules.package WHERE code = d.package_code AND status = 'active';
  IF v_pkg IS NULL THEN
    PERFORM core.raise_hk('HK_RULES_NO_ACTIVE_PACKAGE', format('no active package %s for %s', d.package_code, p_key));
  END IF;
  SELECT * INTO v FROM rules.param_value pv
   WHERE pv.package_id = v_pkg AND pv.key = p_key AND pv.qualifier = coalesce(p_qualifier, '')
     AND pv.effective_from <= p_on AND (pv.effective_to IS NULL OR p_on < pv.effective_to);
  IF NOT FOUND THEN
    PERFORM core.raise_hk('HK_RULES_NO_VALUE', format('%s[%s] has no value on %s', p_key, coalesce(p_qualifier, ''), p_on));
  END IF;
  RETURN v;
END $$;

-- =====================================================================
-- ۳. rules — جدول‌های مستأجری: جایگزینی مجاز، snapshot محاسبه، پیشنهاد بازمحاسبه، تقویم انطباق
-- =====================================================================
CREATE TABLE IF NOT EXISTS rules.param_override (
  tenant_id       uuid NOT NULL REFERENCES core.tenant(id),
  id              uuid NOT NULL DEFAULT uuidv7(),
  scope_level     text NOT NULL CHECK (scope_level IN ('tenant','company','workshop')),
  company_id      uuid,
  workshop_ref    uuid,                       -- payroll.workshop (FK در 99_cross_fk)
  key             text NOT NULL REFERENCES rules.param_def(key),
  qualifier       text NOT NULL DEFAULT '' CHECK (qualifier ~ '^[A-Za-z0-9_.:-]{0,120}$'),
  effective_from  date NOT NULL,
  effective_to    date,
  value           jsonb NOT NULL,
  basis_kind      text NOT NULL CHECK (basis_kind IN ('company_policy','collective_agreement','tax_ruling','court_ruling','advisor_opinion')),
  basis_ref       text NOT NULL CHECK (char_length(basis_ref) BETWEEN 2 AND 200),
  attachment_id   uuid,
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active','revoked')),
  created_by      uuid NOT NULL,
  approved_by     uuid NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  revoked_by      uuid,
  revoked_at      timestamptz,
  revoke_reason   text,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, attachment_id) REFERENCES core.attachment(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, approved_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, revoked_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (effective_to IS NULL OR effective_to > effective_from),
  CHECK (   (scope_level = 'tenant'   AND company_id IS NULL AND workshop_ref IS NULL)
         OR (scope_level = 'company'  AND company_id IS NOT NULL AND workshop_ref IS NULL)
         OR (scope_level = 'workshop' AND company_id IS NOT NULL AND workshop_ref IS NOT NULL)),
  CHECK ((status = 'revoked') = (revoked_at IS NOT NULL AND revoked_by IS NOT NULL AND revoke_reason IS NOT NULL)),
  -- پایین‌تر از کف قانونی فقط با پیمان دسته‌جمعی و تأییدکنندهٔ دوم (تریگر)؛ این‌جا: تفکیک وظایف
  CHECK (basis_kind <> 'collective_agreement' OR approved_by <> created_by),
  EXCLUDE USING gist (tenant_id WITH =, scope_level WITH =, (coalesce(company_id, '00000000-0000-0000-0000-000000000000'::uuid)) WITH =,
                      (coalesce(workshop_ref, '00000000-0000-0000-0000-000000000000'::uuid)) WITH =, key WITH =, qualifier WITH =,
                      daterange(effective_from, effective_to, '[)') WITH &&) WHERE (status = 'active')
);
SELECT core.enable_tenant_rls('rules.param_override');

CREATE OR REPLACE FUNCTION rules.param_override_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE d rules.param_def; v_changed text[]; v_min numeric; v_max numeric; v_new numeric; v_pkg uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM core.raise_hk('HK_RULES_OVERRIDE_IMMUTABLE', 'overrides are revoked, never deleted');
  END IF;
  IF TG_OP = 'UPDATE' THEN
    v_changed := rules.changed_columns(to_jsonb(OLD), to_jsonb(NEW));
    IF NOT (OLD.status = 'active' AND NEW.status = 'revoked'
            AND v_changed <@ ARRAY['status','revoked_by','revoked_at','revoke_reason']) THEN
      PERFORM core.raise_hk('HK_RULES_OVERRIDE_IMMUTABLE', 'an override can only be revoked');
    END IF;
    RETURN NEW;
  END IF;
  SELECT * INTO d FROM rules.param_def WHERE key = NEW.key;
  IF d.override_policy = 'none' OR NOT (NEW.scope_level = ANY (d.override_levels)) THEN
    PERFORM core.raise_hk('HK_RULES_OVERRIDE_NOT_ALLOWED', format('%s cannot be overridden at %s level', NEW.key, NEW.scope_level));
  END IF;
  IF NOT rules.value_valid(d.value_type, d.enum_values, NEW.value) THEN
    PERFORM core.raise_hk('HK_RULES_VALUE_INVALID', format('override value does not match type %s', d.value_type));
  END IF;
  IF NEW.status <> 'active' THEN
    PERFORM core.raise_hk('HK_RULES_OVERRIDE_IMMUTABLE', 'overrides are created active');
  END IF;
  IF d.override_policy IN ('floor','ceiling') THEN
    v_new := rules.value_numeric(d.value_type, NEW.value);
    SELECT id INTO v_pkg FROM rules.package WHERE code = d.package_code AND status = 'active';
    SELECT min(rules.value_numeric(d.value_type, pv.value)), max(rules.value_numeric(d.value_type, pv.value)) INTO v_min, v_max
      FROM rules.param_value pv
     WHERE pv.package_id = v_pkg AND pv.key = NEW.key AND pv.qualifier = NEW.qualifier
       AND daterange(pv.effective_from, pv.effective_to, '[)') && daterange(NEW.effective_from, NEW.effective_to, '[)');
    IF v_new IS NULL OR v_max IS NULL THEN
      PERFORM core.raise_hk('HK_RULES_OVERRIDE_NO_STATUTORY', 'statutory value for the override range is unknown (no active package value)');
    END IF;
    IF d.override_policy = 'floor' AND v_new < v_max AND NEW.basis_kind <> 'collective_agreement' THEN
      PERFORM core.raise_hk('HK_RULES_OVERRIDE_BELOW_FLOOR', format('%s below the statutory floor %s needs a registered collective agreement', v_new, v_max));
    END IF;
    IF d.override_policy = 'ceiling' AND v_new > v_min THEN
      PERFORM core.raise_hk('HK_RULES_OVERRIDE_ABOVE_CEILING', format('%s is above the statutory ceiling %s', v_new, v_min));
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_override_guard ON rules.param_override;
CREATE TRIGGER trg_override_guard BEFORE INSERT OR UPDATE OR DELETE ON rules.param_override
  FOR EACH ROW EXECUTE FUNCTION rules.param_override_guard();

-- مقدار مؤثر برای مستأجر جاری: کارگاه > شرکت > مستأجر > رسمی (همتای RuleEvaluator.effective)
CREATE OR REPLACE FUNCTION rules.effective_value(p_key text, p_on date, p_qualifier text DEFAULT '',
                                                 p_company_id uuid DEFAULT NULL, p_workshop_ref uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE o rules.param_override;
BEGIN
  SELECT * INTO o FROM rules.param_override x
   WHERE x.status = 'active' AND x.key = p_key AND x.qualifier = coalesce(p_qualifier, '')
     AND x.effective_from <= p_on AND (x.effective_to IS NULL OR p_on < x.effective_to)
     AND (   (x.scope_level = 'workshop' AND x.workshop_ref = p_workshop_ref AND x.company_id = p_company_id)
          OR (x.scope_level = 'company'  AND x.company_id = p_company_id)
          OR  x.scope_level = 'tenant')
   ORDER BY CASE x.scope_level WHEN 'workshop' THEN 1 WHEN 'company' THEN 2 ELSE 3 END
   LIMIT 1;
  IF FOUND THEN RETURN o.value; END IF;
  RETURN (rules.value_at(p_key, p_on, p_qualifier)).value;
END $$;

-- snapshot قواعد مصرف‌شده در یک محاسبه (فقط‌افزودنی؛ با hash محتوا یکتا می‌شود تا میلیون‌ها فاکتور یک ردیف را بخوانند)
CREATE TABLE IF NOT EXISTS rules.calc_snapshot (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  company_id       uuid,
  calculator       text NOT NULL CHECK (calculator ~ '^[a-z][a-z0-9_]*\.[a-z0-9_.]+$'),
  engine_version   text NOT NULL CHECK (engine_version ~ '^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$'),
  as_of_from       date NOT NULL,
  as_of_to         date NOT NULL,
  package_ids      uuid[] NOT NULL CHECK (cardinality(package_ids) >= 1),
  value_ids        uuid[] NOT NULL CHECK (cardinality(value_ids) >= 1),
  override_ids     uuid[] NOT NULL DEFAULT '{}',
  content          jsonb NOT NULL CHECK (jsonb_typeof(content) = 'object'),
  min_confidence   text NOT NULL CHECK (min_confidence IN ('high','medium','low','unverified')),
  content_sha256   bytea NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, content_sha256),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  CHECK (as_of_to >= as_of_from)
);
SELECT core.enable_tenant_rls('rules.calc_snapshot');
CREATE INDEX IF NOT EXISTS calc_snapshot_packages ON rules.calc_snapshot USING gin (package_ids);

CREATE OR REPLACE FUNCTION rules.calc_snapshot_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_min smallint;
BEGIN
  IF EXISTS (SELECT 1 FROM unnest(NEW.package_ids) p WHERE NOT EXISTS
               (SELECT 1 FROM rules.package k WHERE k.id = p AND k.status = 'active')) THEN
    PERFORM core.raise_hk('HK_RULES_SNAPSHOT_PACKAGE', 'a new snapshot may only use currently active packages');
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(NEW.value_ids) v WHERE NOT EXISTS
               (SELECT 1 FROM rules.param_value pv WHERE pv.id = v AND pv.package_id = ANY (NEW.package_ids))) THEN
    PERFORM core.raise_hk('HK_RULES_SNAPSHOT_VALUE', 'every value must belong to one of the snapshot packages');
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(NEW.override_ids) o WHERE NOT EXISTS
               (SELECT 1 FROM rules.param_override x WHERE x.id = o AND x.tenant_id = NEW.tenant_id AND x.status = 'active')) THEN
    PERFORM core.raise_hk('HK_RULES_SNAPSHOT_OVERRIDE', 'every override must be an active override of this tenant');
  END IF;
  SELECT min(rules.confidence_rank(pv.confidence)) INTO v_min FROM rules.param_value pv WHERE pv.id = ANY (NEW.value_ids);
  IF rules.confidence_rank(NEW.min_confidence) IS DISTINCT FROM v_min THEN
    PERFORM core.raise_hk('HK_RULES_SNAPSHOT_CONFIDENCE', 'min_confidence must equal the lowest confidence of the values used');
  END IF;
  NEW.content_sha256 := sha256(convert_to(jsonb_build_object(
      'calculator', NEW.calculator, 'engine', NEW.engine_version, 'company', NEW.company_id,
      'from', NEW.as_of_from, 'to', NEW.as_of_to, 'packages', to_jsonb(NEW.package_ids),
      'values', to_jsonb(NEW.value_ids), 'overrides', to_jsonb(NEW.override_ids), 'content', NEW.content)::text, 'UTF8'));
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_snapshot_guard ON rules.calc_snapshot;
CREATE TRIGGER trg_snapshot_guard BEFORE INSERT ON rules.calc_snapshot FOR EACH ROW EXECUTE FUNCTION rules.calc_snapshot_guard();
DROP TRIGGER IF EXISTS trg_immutable ON rules.calc_snapshot;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON rules.calc_snapshot FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

-- آیا همهٔ بسته‌های یک snapshot روی نسخهٔ موتور داده‌شده آزمون طلایی موفق دارند؟ (دروازهٔ تأیید حقوق)
CREATE OR REPLACE FUNCTION rules.snapshot_golden_ok(p_snapshot_id uuid, p_engine text) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT NOT EXISTS (
    SELECT 1 FROM rules.calc_snapshot s CROSS JOIN LATERAL unnest(s.package_ids) p
     WHERE s.id = p_snapshot_id
       AND NOT EXISTS (SELECT 1 FROM rules.golden_run r
                        WHERE r.package_id = p AND r.engine_version = p_engine AND r.outcome = 'passed'
                          AND r.total = (SELECT count(*) FROM rules.golden_test t WHERE t.package_id = p)))
$$;

-- پیشنهاد بازمحاسبه (مابه‌التفاوت) پس از فعال شدن بسته‌ای که مقدارهای گذشته را تغییر داده است
CREATE TABLE IF NOT EXISTS rules.recalc_proposal (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  company_id           uuid NOT NULL,
  trigger_package_id   uuid NOT NULL REFERENCES rules.package(id),
  consumer             text NOT NULL CHECK (consumer IN ('payroll.run','assets.depreciation_run','tax.vat_return','tax.threshold','rules.compliance_item')),
  target_id            uuid NOT NULL,                  -- ارجاع نرم به محاسبهٔ متأثر (چندریختی؛ مصرف‌کننده با FK به این جدول برمی‌گردد)
  target_snapshot_id   uuid NOT NULL,
  changed_keys         text[] NOT NULL CHECK (cardinality(changed_keys) >= 1),
  affected_from        date NOT NULL,
  affected_to          date NOT NULL,
  estimated_delta      jsonb,
  status               text NOT NULL DEFAULT 'open' CHECK (status IN ('open','accepted','applied','dismissed','superseded')),
  decided_by           uuid,
  decided_at           timestamptz,
  decision_reason      text,
  resolution_ref       uuid,                            -- مثلاً payroll.run (اجرای مابه‌التفاوت)
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, trigger_package_id, consumer, target_id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, target_snapshot_id) REFERENCES rules.calc_snapshot(tenant_id, id),
  FOREIGN KEY (tenant_id, decided_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (affected_to >= affected_from),
  CHECK ((status IN ('accepted','applied','dismissed')) = (decided_at IS NOT NULL AND decided_by IS NOT NULL)),
  CHECK ((status = 'applied') = (resolution_ref IS NOT NULL)),
  CHECK (status <> 'dismissed' OR char_length(btrim(coalesce(decision_reason, ''))) >= 10)
);
SELECT core.enable_tenant_rls('rules.recalc_proposal');

CREATE OR REPLACE FUNCTION rules.recalc_proposal_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE p rules.package; v_changed text[];
BEGIN
  IF TG_OP = 'DELETE' THEN PERFORM core.raise_hk('HK_RULES_PROPOSAL_IMMUTABLE', 'proposals are dismissed, never deleted'); END IF;
  IF TG_OP = 'INSERT' THEN
    SELECT * INTO p FROM rules.package WHERE id = NEW.trigger_package_id;
    IF p.status <> 'active' THEN
      PERFORM core.raise_hk('HK_RULES_PROPOSAL_PACKAGE', 'proposals are created only for the active package');
    END IF;
    IF NEW.status <> 'open' THEN PERFORM core.raise_hk('HK_RULES_PROPOSAL_TRANSITION', 'proposals start open'); END IF;
    -- snapshot هدف باید نسخهٔ قدیمی‌ترِ همان بسته را مصرف کرده باشد
    IF NOT EXISTS (SELECT 1 FROM rules.calc_snapshot s JOIN rules.package k ON k.id = ANY (s.package_ids)
                    WHERE s.tenant_id = NEW.tenant_id AND s.id = NEW.target_snapshot_id AND k.code = p.code AND k.seq < p.seq) THEN
      PERFORM core.raise_hk('HK_RULES_PROPOSAL_IRRELEVANT', 'target snapshot did not use an older version of the trigger package');
    END IF;
    RETURN NEW;
  END IF;
  v_changed := rules.changed_columns(to_jsonb(OLD), to_jsonb(NEW));
  IF NOT (v_changed <@ ARRAY['status','decided_by','decided_at','decision_reason','resolution_ref','estimated_delta','updated_at','row_version']) THEN
    PERFORM core.raise_hk('HK_RULES_PROPOSAL_IMMUTABLE', format('cannot change %s', array_to_string(v_changed, ',')));
  END IF;
  IF NEW.status <> OLD.status AND NOT ((OLD.status, NEW.status) IN
       (('open','accepted'),('open','dismissed'),('accepted','applied'),('open','superseded'),('accepted','superseded'))) THEN
    PERFORM core.raise_hk('HK_RULES_PROPOSAL_TRANSITION', format('%s → %s is not allowed', OLD.status, NEW.status));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_proposal_guard ON rules.recalc_proposal;
CREATE TRIGGER trg_proposal_guard BEFORE INSERT OR UPDATE OR DELETE ON rules.recalc_proposal
  FOR EACH ROW EXECUTE FUNCTION rules.recalc_proposal_guard();
DROP TRIGGER IF EXISTS trg_touch ON rules.recalc_proposal;
CREATE TRIGGER trg_touch BEFORE UPDATE ON rules.recalc_proposal FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- تقویم انطباق: نمونهٔ هر تکلیف برای هر دوره (سررسید از قاعدهٔ تاریخ‌دار + تمدیدهای منتشرشده)
CREATE TABLE IF NOT EXISTS rules.compliance_item (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  company_id        uuid NOT NULL,
  obligation_code   text NOT NULL REFERENCES rules.obligation_def(code),
  subject_ref       uuid,                     -- کارگاه/حافظه برای تکلیف‌های غیرشرکتی (ارجاع نرم)
  period_key        text NOT NULL CHECK (period_key ~ '^(jy:[0-9]{4}|jh:[0-9]{4}H[12]|jq:[0-9]{4}Q[1-4]|jm:[0-9]{4}-(0[1-9]|1[0-2])|ev:[0-9a-f-]{36})$'),
  period_start      date NOT NULL,
  period_end        date NOT NULL,
  base_due_date     date NOT NULL,
  due_date          date NOT NULL,
  rule_snapshot_id  uuid NOT NULL,
  status            text NOT NULL DEFAULT 'open' CHECK (status IN ('open','done','not_applicable')),
  completed_at      timestamptz,
  completed_by      uuid,
  evidence_module   text CHECK (evidence_module ~ '^[a-z][a-z0-9_]{1,30}$'),
  evidence_ref      uuid,
  na_reason         text,
  last_reminded_at  timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  row_version       integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE NULLS NOT DISTINCT (tenant_id, company_id, obligation_code, subject_ref, period_key),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, rule_snapshot_id) REFERENCES rules.calc_snapshot(tenant_id, id),
  FOREIGN KEY (tenant_id, completed_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (period_end >= period_start),
  CHECK (base_due_date >= period_start),
  CHECK (due_date >= base_due_date),                     -- تمدید فقط به جلو
  CHECK ((status = 'done') = (completed_at IS NOT NULL)),
  CHECK ((status = 'done') = (evidence_module IS NOT NULL AND evidence_ref IS NOT NULL) OR status <> 'done'),
  CHECK ((status = 'not_applicable') = (na_reason IS NOT NULL))
);
SELECT core.enable_tenant_rls('rules.compliance_item');
CREATE INDEX IF NOT EXISTS compliance_item_due ON rules.compliance_item (tenant_id, status, due_date);

CREATE OR REPLACE FUNCTION rules.compliance_item_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_changed text[];
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'open' THEN PERFORM core.raise_hk('HK_RULES_COMPLIANCE_IMMUTABLE', 'closed items are kept'); END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'UPDATE' THEN
    v_changed := rules.changed_columns(to_jsonb(OLD), to_jsonb(NEW));
    IF OLD.status <> 'open' AND NOT (v_changed <@ ARRAY['last_reminded_at','updated_at','row_version']) THEN
      PERFORM core.raise_hk('HK_RULES_COMPLIANCE_IMMUTABLE', 'a done/not-applicable item cannot change');
    END IF;
    IF NEW.due_date < OLD.due_date THEN
      PERFORM core.raise_hk('HK_RULES_COMPLIANCE_DUE_BACKWARD', 'due dates only move forward (published extensions)');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_compliance_guard ON rules.compliance_item;
CREATE TRIGGER trg_compliance_guard BEFORE INSERT OR UPDATE OR DELETE ON rules.compliance_item
  FOR EACH ROW EXECUTE FUNCTION rules.compliance_item_guard();
DROP TRIGGER IF EXISTS trg_touch ON rules.compliance_item;
CREATE TRIGGER trg_touch BEFORE UPDATE ON rules.compliance_item FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- =====================================================================
-- ۴. rules — بستهٔ صنفی (پذیرش CR-C01 بخش ۰۵؛ مالک اسکیما: همین بخش)
-- =====================================================================
CREATE TABLE IF NOT EXISTS rules.industry_pack (
  code           text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  name_fa        text NOT NULL,
  kind           text NOT NULL CHECK (kind IN ('base','industry','addon')),
  status         text NOT NULL DEFAULT 'published' CHECK (status IN ('draft','published','retired')),
  introduced_in  text NOT NULL
);
CREATE TABLE IF NOT EXISTS rules.industry_pack_version (
  pack_code          text NOT NULL REFERENCES rules.industry_pack(code),
  version            text NOT NULL CHECK (version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
  manifest           jsonb NOT NULL CHECK (jsonb_typeof(manifest) = 'object' AND manifest->>'format' = 'hkpack/1'
                                           AND manifest->>'pack' IS NOT NULL AND manifest->>'version' IS NOT NULL),
  manifest_sha256    bytea NOT NULL CHECK (octet_length(manifest_sha256) = 32),
  hksb_sha256        bytea CHECK (octet_length(hksb_sha256) = 32),
  requires           jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(requires) = 'array'),
  conflicts          text[] NOT NULL DEFAULT '{}',
  min_app_version    text NOT NULL,
  status             text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','published','retired')),
  confidence         text NOT NULL DEFAULT 'low' CHECK (confidence IN ('high','medium','low')),
  source             text,
  reviewed_by        text,
  published_at       timestamptz,
  PRIMARY KEY (pack_code, version),
  CHECK (manifest->>'pack' = pack_code AND manifest->>'version' = version),
  CHECK (status = 'draft' OR (published_at IS NOT NULL AND reviewed_by IS NOT NULL AND hksb_sha256 IS NOT NULL))
);
CREATE TABLE IF NOT EXISTS rules.tenant_pack (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL DEFAULT uuidv7(),
  company_id         uuid,
  pack_code          text NOT NULL,
  installed_version  text NOT NULL,
  status             text NOT NULL DEFAULT 'installing' CHECK (status IN ('installing','active','upgrading','failed','uninstalled')),
  installed_by       uuid,
  installed_at       timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  row_version        integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE NULLS NOT DISTINCT (tenant_id, company_id, pack_code),
  FOREIGN KEY (pack_code, installed_version) REFERENCES rules.industry_pack_version(pack_code, version),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, installed_by) REFERENCES core.tenant_membership(tenant_id, user_id)
);
SELECT core.enable_tenant_rls('rules.tenant_pack');
DROP TRIGGER IF EXISTS trg_touch ON rules.tenant_pack;
CREATE TRIGGER trg_touch BEFORE UPDATE ON rules.tenant_pack FOR EACH ROW EXECUTE FUNCTION core.touch_row();
CREATE TABLE IF NOT EXISTS rules.tenant_pack_event (
  tenant_id       uuid NOT NULL REFERENCES core.tenant(id),
  id              uuid NOT NULL DEFAULT uuidv7(),
  tenant_pack_id  uuid NOT NULL,
  action          text NOT NULL CHECK (action IN ('install','upgrade','uninstall','repair')),
  from_version    text,
  to_version      text,
  outcome         text NOT NULL CHECK (outcome IN ('dry_run','succeeded','failed')),
  plan            jsonb NOT NULL CHECK (jsonb_typeof(plan) = 'object'),
  result          jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(result) = 'object'),
  actor_user_id   uuid,
  job_id          uuid,
  occurred_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, tenant_pack_id) REFERENCES rules.tenant_pack(tenant_id, id),
  FOREIGN KEY (tenant_id, actor_user_id) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK ((action = 'install') = (from_version IS NULL)),
  CHECK ((action = 'uninstall') = (to_version IS NULL))
);
SELECT core.enable_tenant_rls('rules.tenant_pack_event');
DROP TRIGGER IF EXISTS trg_immutable ON rules.tenant_pack_event;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON rules.tenant_pack_event FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();
CREATE TABLE IF NOT EXISTS rules.pack_artifact (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL DEFAULT uuidv7(),
  tenant_pack_id     uuid NOT NULL,
  module             text NOT NULL CHECK (module ~ '^[a-z][a-z0-9_]{1,30}$'),
  entity_type        text NOT NULL CHECK (entity_type ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  artifact_key       text NOT NULL CHECK (artifact_key ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,119}$'),
  entity_id          uuid NOT NULL,
  installed_version  text NOT NULL,
  content_sha256     bytea NOT NULL CHECK (octet_length(content_sha256) = 32),
  state              text NOT NULL DEFAULT 'managed' CHECK (state IN ('managed','modified','detached','removed')),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, tenant_pack_id, entity_type, artifact_key),
  FOREIGN KEY (tenant_id, tenant_pack_id) REFERENCES rules.tenant_pack(tenant_id, id),
  CHECK (split_part(entity_type, '.', 1) = module)
);
SELECT core.enable_tenant_rls('rules.pack_artifact');
CREATE UNIQUE INDEX IF NOT EXISTS pack_artifact_one_owner ON rules.pack_artifact (tenant_id, entity_type, entity_id)
  WHERE state IN ('managed','modified');

-- =====================================================================
-- ۵. ref — دادهٔ مرجع خارجی تازه (snapshot نسخه‌دار؛ فقط با بستهٔ امضاشده و نقش migrator به‌روز می‌شود)
-- =====================================================================
-- نرخ ارزش افزودهٔ ثبت‌شدهٔ هر شناسهٔ کالا/خدمت در stuffid (مبنای vra؛ خطای 0304401 در صورت ناهمخوانی)
CREATE TABLE IF NOT EXISTS ref.sstid_vat_rate (
  sstid             char(13) NOT NULL REFERENCES ref.sstid(sstid),
  effective_from    date NOT NULL,
  effective_to      date,
  vat_rate          numeric(7,4) NOT NULL CHECK (vat_rate >= 0 AND vat_rate <= 100),
  snapshot_version  text NOT NULL,
  synced_at         timestamptz NOT NULL,
  PRIMARY KEY (sstid, effective_from),
  CHECK (effective_to IS NULL OR effective_to > effective_from),
  EXCLUDE USING gist (sstid WITH =, daterange(effective_from, effective_to, '[)') WITH &&)
);

-- فهرست رسمی کدهای شغلی تأمین اجتماعی (DSW_JOB؛ حدود ۸۷ هزار کد؛ snapshot نسخه‌دار)
CREATE TABLE IF NOT EXISTS ref.ssi_job_code (
  code          text PRIMARY KEY CHECK (code ~ '^[0-9]{1,6}$'),
  title         text NOT NULL,
  list_version  text NOT NULL,
  is_active     boolean NOT NULL DEFAULT true
);

-- =====================================================================
-- ۶. tax — شمارهٔ مالیاتی (taxid) با جدول Verhoeff رسمی SDK (سطرهای ۴ و ۷ با جدول درسی فرق دارند)
-- =====================================================================
CREATE OR REPLACE FUNCTION tax.verhoeff_check_digit(p_digits text) RETURNS smallint
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
  d smallint[] := ARRAY[[0,1,2,3,4,5,6,7,8,9],[1,2,3,4,0,6,7,8,9,5],[2,3,4,0,1,7,8,9,5,6],[3,4,0,1,2,8,9,5,6,7],
                        [4,0,1,2,3,9,5,6,7,8],[5,9,8,7,6,0,4,3,2,1],[6,5,9,8,7,1,0,4,3,2],[7,6,5,9,8,2,1,0,4,3],
                        [8,7,6,5,9,3,2,1,0,4],[9,8,7,6,5,4,3,2,1,0]];
  -- جدول p مطابق ir.gov.tax.tpis.sdk.utils.VerhoeffAlgorithm (نه جدول استاندارد)
  p smallint[] := ARRAY[[0,1,2,3,4,5,6,7,8,9],[1,5,7,6,2,8,3,0,9,4],[5,8,0,3,7,9,6,1,4,2],[8,9,1,6,0,4,3,5,2,7],
                        [9,4,5,3,1,2,6,8,7,0],[4,2,8,6,5,7,3,9,0,1],[2,7,9,3,8,0,6,4,1,5],[7,0,4,6,9,1,3,2,5,8]];
  inv smallint[] := ARRAY[0,4,3,2,1,5,6,7,8,9];
  c int := 0; n int; i int;
BEGIN
  IF p_digits !~ '^[0-9]+$' THEN RETURN NULL; END IF;
  n := length(p_digits);
  FOR i IN 0 .. n - 1 LOOP
    c := d[c + 1][p[((i + 1) % 8) + 1][substr(p_digits, n - i, 1)::int + 1] + 1];
  END LOOP;
  RETURN inv[c + 1];
END $$;

CREATE OR REPLACE FUNCTION tax.hex_to_bigint(p text) RETURNS bigint
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT CASE WHEN p ~ '^[0-9A-Fa-f]{1,15}$' THEN ('x' || lpad(p, 16, '0'))::bit(64)::bigint END
$$;

-- رشتهٔ دهدهی ورودی Verhoeff: toDecimal(MEMORY_ID) + pad(day,6) + pad(serial,12)؛ حرف → کد ASCII
CREATE OR REPLACE FUNCTION tax.taxid_control_string(p_memory text, p_day integer, p_serial bigint) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT string_agg(CASE WHEN ch ~ '[0-9]' THEN ch ELSE ascii(ch)::text END, '' ORDER BY ord)
         || lpad(p_day::text, 6, '0') || lpad(p_serial::text, 12, '0')
    FROM unnest(string_to_array(upper(p_memory), NULL)) WITH ORDINALITY AS t(ch, ord)
$$;

CREATE OR REPLACE FUNCTION tax.taxid_build(p_memory text, p_day integer, p_serial bigint) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT upper(p_memory) || lpad(upper(to_hex(p_day)), 5, '0') || lpad(upper(to_hex(p_serial)), 10, '0')
         || tax.verhoeff_check_digit(tax.taxid_control_string(p_memory, p_day, p_serial))::text
$$;

CREATE OR REPLACE FUNCTION tax.taxid_valid(p text) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT p IS NOT NULL AND p ~ '^[0-9A-Z]{22}$'
         AND p = tax.taxid_build(substr(p, 1, 6), tax.hex_to_bigint(substr(p, 7, 5))::integer, tax.hex_to_bigint(substr(p, 12, 10)))
$$;

-- سهم مالیات/عوارض سطر مؤدیان: همیشه قطع (truncate)، نه گرد کردن (RC_IITP؛ خطای 0204501)
CREATE OR REPLACE FUNCTION tax.moadian_part(p_base numeric, p_rate numeric, p_scale smallint) RETURNS numeric
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$ SELECT trunc(p_base * p_rate / 100, p_scale) $$;

-- =====================================================================
-- ۷. tax — پروفایل مؤدی، وضعیت فراخوان ارزش افزوده، حافظهٔ مالیاتی و کلید
-- =====================================================================
CREATE TABLE IF NOT EXISTS tax.taxpayer_profile (
  tenant_id                   uuid NOT NULL REFERENCES core.tenant(id),
  id                          uuid NOT NULL DEFAULT uuidv7(),
  company_id                  uuid NOT NULL,
  moadian_enabled             boolean NOT NULL DEFAULT false,
  seller_branch_code          text CHECK (seller_branch_code ~ '^[0-9]{4}$'),         -- sbc پیش‌فرض
  art14m_policy               text NOT NULL DEFAULT 'auto' CHECK (art14m_policy IN ('auto','always_issue')),
  default_invoice_type        smallint NOT NULL DEFAULT 2 CHECK (default_invoice_type IN (1,2)),
  pos_type3_enabled           boolean NOT NULL DEFAULT false,                         -- رسید کارتخوان به‌عنوان نوع ۳ (تابع قاعدهٔ تاریخ‌دار)
  prior_year_sales            core.amount CHECK (prior_year_sales >= 0),             -- مبنای حد ماده ۶ برای شرکت تازه/منتقل‌شده
  prior_year_sales_unit       core.amount_unit,
  prior_year_sales_year       smallint CHECK (prior_year_sales_year BETWEEN 1390 AND 1500),
  auto_send                   boolean NOT NULL DEFAULT true,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  row_version                 integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  CHECK ((prior_year_sales IS NULL) = (prior_year_sales_unit IS NULL) AND (prior_year_sales IS NULL) = (prior_year_sales_year IS NULL))
);
SELECT core.enable_tenant_rls('tax.taxpayer_profile');
DROP TRIGGER IF EXISTS trg_touch ON tax.taxpayer_profile;
CREATE TRIGGER trg_touch BEFORE UPDATE ON tax.taxpayer_profile FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- وضعیت فراخوان فروشنده در ارزش افزوده (تاریخ‌دار؛ «فراخوان‌نشده» ⇒ vra = ۰ طبق قاعدهٔ ۷ جدول ۴۳)
CREATE TABLE IF NOT EXISTS tax.vat_registration (
  tenant_id       uuid NOT NULL REFERENCES core.tenant(id),
  id              uuid NOT NULL DEFAULT uuidv7(),
  company_id      uuid NOT NULL,
  effective_from  date NOT NULL,
  effective_to    date,
  call_status     text NOT NULL CHECK (call_status IN ('called_in','not_called_in')),
  basis_ref       text NOT NULL CHECK (char_length(basis_ref) BETWEEN 2 AND 200),   -- شمارهٔ ابلاغ/فراخوان یا «اعلام کارپوشه»
  attachment_id   uuid,
  created_by      uuid,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, attachment_id) REFERENCES core.attachment(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (effective_to IS NULL OR effective_to > effective_from),
  EXCLUDE USING gist (tenant_id WITH =, company_id WITH =, daterange(effective_from, effective_to, '[)') WITH &&)
);
SELECT core.enable_tenant_rls('tax.vat_registration');

CREATE OR REPLACE FUNCTION tax.vat_registration_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN PERFORM core.raise_hk('HK_TAX_REGISTRATION_IMMUTABLE', 'close the range instead of deleting'); END IF;
  -- فقط بستن بازهٔ باز مجاز است (effective_to از NULL به مقدار)
  IF rules.changed_columns(to_jsonb(OLD), to_jsonb(NEW)) <> ARRAY['effective_to'] OR OLD.effective_to IS NOT NULL THEN
    PERFORM core.raise_hk('HK_TAX_REGISTRATION_IMMUTABLE', 'only an open range can be closed');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON tax.vat_registration;
CREATE TRIGGER trg_guard BEFORE UPDATE OR DELETE ON tax.vat_registration FOR EACH ROW EXECUTE FUNCTION tax.vat_registration_guard();

-- شناسهٔ یکتای حافظهٔ مالیاتی (هر حافظه: حالت ارسال، آداپتر، امانت کلید، سری سریال)
CREATE TABLE IF NOT EXISTS tax.memory (
  tenant_id              uuid NOT NULL REFERENCES core.tenant(id),
  id                     uuid NOT NULL DEFAULT uuidv7(),
  company_id             uuid NOT NULL,
  memory_id              text NOT NULL CHECK (memory_id ~ '^[1-9ADEFGHKMNOPRTWXYZ]{6}$'),   -- 0 I J L Q V ممنوع؛ B C S U رزرو
  label                  text NOT NULL CHECK (char_length(label) BETWEEN 1 AND 100),
  send_mode              text NOT NULL CHECK (send_mode IN ('taxpayer','tsp_taxpayer_key','tsp_own_key')),
  adapter                text NOT NULL CHECK (adapter IN ('direct_v2_cert','direct_v1_self_tsp','tsp','mock','sandbox')),
  tsp_code               text CHECK (tsp_code ~ '^[A-Za-z0-9_.-]{2,40}$'),
  environment            text NOT NULL DEFAULT 'production' CHECK (environment IN ('production','sandbox','mock')),
  key_custody            text NOT NULL CHECK (key_custody IN ('server_kms','device_agent','tsp_held')),
  signer_device_id       uuid,                    -- امانت روی دستگاه مشتری (Q-C)
  allocation             text NOT NULL DEFAULT 'server' CHECK (allocation IN ('server','device','device_ranges')),
  device_id              uuid,                    -- حافظهٔ اختصاصی یک صندوق آفلاین
  serial_series_id       uuid NOT NULL,           -- core.number_series با doc_type = 'tax.moadian_serial'
  status                 text NOT NULL DEFAULT 'setup' CHECK (status IN ('setup','active','suspended','retired')),
  portal_fiscal_status   text,                    -- آخرین پاسخ fiscal-information (ACTIVE، …)
  portal_checked_at      timestamptz,
  activated_at           timestamptz,
  retired_at             timestamptz,
  created_by             uuid,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  row_version            integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, memory_id),
  UNIQUE (tenant_id, serial_series_id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, signer_device_id) REFERENCES core.device(tenant_id, id),
  FOREIGN KEY (tenant_id, device_id) REFERENCES core.device(tenant_id, id),
  FOREIGN KEY (tenant_id, serial_series_id) REFERENCES core.number_series(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT memory_tsp CHECK ((adapter = 'tsp') = (tsp_code IS NOT NULL)),
  CONSTRAINT memory_env CHECK (    (adapter = 'mock') = (environment = 'mock')
                               AND (adapter = 'sandbox') = (environment = 'sandbox')),
  CONSTRAINT memory_mode CHECK (send_mode = 'taxpayer' OR adapter IN ('tsp','mock')),
  CONSTRAINT memory_v1_mode CHECK (adapter <> 'direct_v1_self_tsp' OR send_mode = 'taxpayer'),
  CONSTRAINT memory_custody CHECK ((key_custody = 'tsp_held') = (send_mode = 'tsp_own_key')
                                   AND (key_custody = 'device_agent') = (signer_device_id IS NOT NULL)),
  CONSTRAINT memory_allocation CHECK ((allocation = 'device') = (device_id IS NOT NULL)),
  CONSTRAINT memory_status CHECK ((status IN ('active','suspended','retired')) = (activated_at IS NOT NULL OR status = 'retired')
                                  AND (status = 'retired') = (retired_at IS NOT NULL))
);
SELECT core.enable_tenant_rls('tax.memory');

CREATE OR REPLACE FUNCTION tax.memory_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE s core.number_series; v_changed text[];
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'setup' OR EXISTS (SELECT 1 FROM tax.invoice_issue i WHERE i.tenant_id = OLD.tenant_id AND i.memory_ref = OLD.id) THEN
      PERFORM core.raise_hk('HK_TAX_MEMORY_IMMUTABLE', 'a memory in use is retired, never deleted');
    END IF;
    RETURN OLD;
  END IF;
  SELECT * INTO s FROM core.number_series WHERE tenant_id = NEW.tenant_id AND id = NEW.serial_series_id;
  IF s.doc_type <> 'tax.moadian_serial' OR s.reset_policy <> 'never' OR s.company_id <> NEW.company_id THEN
    PERFORM core.raise_hk('HK_TAX_MEMORY_SERIES', 'serial series must be doc_type tax.moadian_serial, reset never, same company');
  END IF;
  IF NOT (   (NEW.allocation = 'server' AND s.allocation = 'server')
          OR (NEW.allocation = 'device' AND s.allocation = 'device' AND s.device_id = NEW.device_id)
          OR (NEW.allocation = 'device_ranges' AND s.allocation = 'reserved_ranges')) THEN
    PERFORM core.raise_hk('HK_TAX_MEMORY_SERIES', format('series allocation %s does not fit memory allocation %s', s.allocation, NEW.allocation));
  END IF;
  IF TG_OP = 'UPDATE' THEN
    v_changed := rules.changed_columns(to_jsonb(OLD), to_jsonb(NEW));
    IF OLD.status <> 'setup' AND v_changed && ARRAY['memory_id','company_id','serial_series_id','allocation','device_id'] THEN
      PERFORM core.raise_hk('HK_TAX_MEMORY_IMMUTABLE', 'identity, series and allocation are fixed after activation');
    END IF;
    IF OLD.status = 'retired' AND v_changed <> '{}' AND NOT (v_changed <@ ARRAY['portal_fiscal_status','portal_checked_at','updated_at','row_version']) THEN
      PERFORM core.raise_hk('HK_TAX_MEMORY_IMMUTABLE', 'a retired memory cannot change');
    END IF;
    IF NEW.status <> OLD.status AND NOT ((OLD.status, NEW.status) IN
         (('setup','active'),('active','suspended'),('suspended','active'),('active','retired'),('suspended','retired'),('setup','retired'))) THEN
      PERFORM core.raise_hk('HK_TAX_MEMORY_TRANSITION', format('%s → %s is not allowed', OLD.status, NEW.status));
    END IF;
  END IF;
  IF NEW.status = 'active' AND NEW.key_custody <> 'tsp_held'
     AND NOT EXISTS (SELECT 1 FROM tax.memory_key k WHERE k.tenant_id = NEW.tenant_id AND k.memory_ref = NEW.id AND k.status = 'active') THEN
    PERFORM core.raise_hk('HK_TAX_MEMORY_NO_KEY', 'an active memory needs an active signing key');
  END IF;
  RETURN NEW;
END $$;

CREATE TABLE IF NOT EXISTS tax.memory_key (
  tenant_id                      uuid NOT NULL REFERENCES core.tenant(id),
  id                             uuid NOT NULL DEFAULT uuidv7(),
  memory_ref                     uuid NOT NULL,
  kind                           text NOT NULL CHECK (kind IN ('rsa_key','certificate')),
  custody                        text NOT NULL CHECK (custody IN ('server_kms','device_agent')),
  public_key_spki                bytea NOT NULL CHECK (octet_length(public_key_spki) BETWEEN 200 AND 1200),
  key_bits                       integer NOT NULL CHECK (key_bits IN (2048, 3072, 4096)),
  fingerprint_sha256             bytea NOT NULL CHECK (octet_length(fingerprint_sha256) = 32),
  private_key_sealed             bytea,                    -- SealedBlob (KeyManager، AAD = tenant/table/row/column)
  kms_key_ref                    text,                     -- کلید واردشده در OpenBao Transit (جایگزین sealed)
  device_id                      uuid,                     -- دستگاه نگه‌دارندهٔ کلید (امضاکنندهٔ راه دور)
  certificate_der                bytea,
  cert_subject_serial            text,                     -- SERIALNUMBER = کد/شناسهٔ ملی صاحب حافظه
  cert_not_before                timestamptz,
  cert_not_after                 timestamptz,
  status                         text NOT NULL DEFAULT 'pending_registration'
                                 CHECK (status IN ('pending_registration','active','rotated','revoked')),
  registered_confirmed_at        timestamptz,              -- کاربر بارگذاری کلید عمومی در کارپوشه را تأیید کرد / آزمون اتصال موفق
  custody_contract_version       text,                     -- قرارداد مسئولیت امانت (فقط server_kms)
  custody_contract_accepted_by   uuid,
  custody_contract_accepted_at   timestamptz,
  activated_at                   timestamptz,
  retired_at                     timestamptz,
  retire_reason                  text,
  created_at                     timestamptz NOT NULL DEFAULT now(),
  updated_at                     timestamptz NOT NULL DEFAULT now(),
  row_version                    integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, fingerprint_sha256),
  FOREIGN KEY (tenant_id, memory_ref) REFERENCES tax.memory(tenant_id, id),
  FOREIGN KEY (tenant_id, device_id) REFERENCES core.device(tenant_id, id),
  FOREIGN KEY (tenant_id, custody_contract_accepted_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT key_server_custody CHECK ((custody = 'server_kms') = (num_nonnulls(private_key_sealed, kms_key_ref) = 1)),
  CONSTRAINT key_device_custody CHECK ((custody = 'device_agent') = (device_id IS NOT NULL)),
  CONSTRAINT key_contract CHECK ((custody = 'server_kms') = (custody_contract_accepted_at IS NOT NULL
                                  AND custody_contract_accepted_by IS NOT NULL AND custody_contract_version IS NOT NULL)),
  CONSTRAINT key_certificate CHECK ((kind = 'certificate') = (certificate_der IS NOT NULL AND cert_not_after IS NOT NULL
                                     AND cert_subject_serial IS NOT NULL)),
  CONSTRAINT key_cert_dates CHECK (cert_not_before IS NULL OR cert_not_after > cert_not_before),
  CONSTRAINT key_active CHECK (status IN ('pending_registration','revoked') OR (activated_at IS NOT NULL AND registered_confirmed_at IS NOT NULL)),
  CONSTRAINT key_retired CHECK ((status IN ('rotated','revoked')) = (retired_at IS NOT NULL AND retire_reason IS NOT NULL))
);
SELECT core.enable_tenant_rls('tax.memory_key');
CREATE UNIQUE INDEX IF NOT EXISTS memory_key_one_active ON tax.memory_key (tenant_id, memory_ref) WHERE status = 'active';

CREATE OR REPLACE FUNCTION tax.memory_key_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE m tax.memory; v_changed text[];
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'pending_registration' THEN PERFORM core.raise_hk('HK_TAX_KEY_IMMUTABLE', 'used keys are retired, never deleted'); END IF;
    RETURN OLD;
  END IF;
  SELECT * INTO m FROM tax.memory WHERE tenant_id = NEW.tenant_id AND id = NEW.memory_ref;
  IF m.key_custody <> NEW.custody THEN
    PERFORM core.raise_hk('HK_TAX_KEY_CUSTODY', format('memory custody is %s, key custody %s', m.key_custody, NEW.custody));
  END IF;
  IF m.adapter = 'direct_v2_cert' AND NEW.kind <> 'certificate' THEN
    PERFORM core.raise_hk('HK_TAX_KEY_CERT_REQUIRED', 'API v2 needs a certificate issued by an intermediate CA');
  END IF;
  IF NEW.custody = 'device_agent' AND NEW.device_id IS DISTINCT FROM m.signer_device_id THEN
    PERFORM core.raise_hk('HK_TAX_KEY_CUSTODY', 'device-held key must live on the memory signer device');
  END IF;
  IF TG_OP = 'UPDATE' THEN
    v_changed := rules.changed_columns(to_jsonb(OLD), to_jsonb(NEW));
    IF v_changed && ARRAY['memory_ref','kind','custody','public_key_spki','key_bits','fingerprint_sha256','private_key_sealed',
                          'kms_key_ref','device_id','certificate_der','cert_subject_serial','cert_not_before','cert_not_after'] THEN
      PERFORM core.raise_hk('HK_TAX_KEY_IMMUTABLE', 'key material is immutable; register a new key to rotate');
    END IF;
    IF NEW.status <> OLD.status AND NOT ((OLD.status, NEW.status) IN
         (('pending_registration','active'),('pending_registration','revoked'),('active','rotated'),('active','revoked'))) THEN
      PERFORM core.raise_hk('HK_TAX_KEY_TRANSITION', format('%s → %s is not allowed', OLD.status, NEW.status));
    END IF;
  ELSIF NEW.status <> 'pending_registration' THEN
    PERFORM core.raise_hk('HK_TAX_KEY_TRANSITION', 'keys start pending registration');
  END IF;
  IF NEW.status = 'active' AND NEW.kind = 'certificate' AND NEW.cert_not_after <= now() THEN
    PERFORM core.raise_hk('HK_TAX_KEY_CERT_EXPIRED', 'certificate has expired');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON tax.memory_key;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON tax.memory_key FOR EACH ROW EXECUTE FUNCTION tax.memory_key_guard();
DROP TRIGGER IF EXISTS trg_touch ON tax.memory_key;
CREATE TRIGGER trg_touch BEFORE UPDATE ON tax.memory_key FOR EACH ROW EXECUTE FUNCTION core.touch_row();
DROP TRIGGER IF EXISTS trg_guard ON tax.memory;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON tax.memory FOR EACH ROW EXECUTE FUNCTION tax.memory_guard();
DROP TRIGGER IF EXISTS trg_touch ON tax.memory;
CREATE TRIGGER trg_touch BEFORE UPDATE ON tax.memory FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- =====================================================================
-- ۸. tax — صورتحساب الکترونیکی: سند منطقی (invoice) و نسخهٔ صادرشده با taxid (invoice_issue)
-- =====================================================================
-- سند منطقی: یکی برای هر (سند فروش، موضوع). پس از رد شدن، صدور دوباره با سریال تازه در همین سند.
CREATE TABLE IF NOT EXISTS tax.invoice (
  tenant_id             uuid NOT NULL REFERENCES core.tenant(id),
  id                    uuid NOT NULL DEFAULT uuidv7(),
  company_id            uuid NOT NULL,
  memory_ref            uuid NOT NULL,
  source_kind           text NOT NULL CHECK (source_kind IN ('sales_invoice','sales_cancellation','migration')),
  sales_invoice_id      uuid,                 -- sales.invoice (FK در 99_cross_fk)
  source_doc_no         text CHECK (char_length(source_doc_no) <= 100),
  subject               smallint NOT NULL CHECK (subject IN (1,2,3,4)),                -- ins
  inv_type              smallint NOT NULL CHECK (inv_type IN (1,2,3)),                 -- inty
  pattern               smallint NOT NULL CHECK (pattern IN (1,2,3,4,5,6,7,8,9,11,13,14)), -- inp
  ref_invoice_id        uuid,                 -- ins ۲/۳/۴: نسخهٔ مرجع (سرِ زنجیره)
  root_invoice_id       uuid,                 -- صورتحساب اصلی (ins=1) زنجیره
  instruction_version   text NOT NULL CHECK (instruction_version ~ '^RC_IITP\.IS-[0-9]+(\.[0-9]+)?$'),
  status                text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','in_progress','registered','rejected','withdrawn')),
  registered_issue_id   uuid,
  withdrawn_reason      text,
  withdrawn_at          timestamptz,
  created_by            uuid,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  row_version           integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, memory_ref) REFERENCES tax.memory(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, ref_invoice_id) REFERENCES tax.invoice(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, root_invoice_id) REFERENCES tax.invoice(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT invoice_ref_shape CHECK ((subject = 1) = (ref_invoice_id IS NULL) AND (subject = 1) = (root_invoice_id IS NULL)),
  CONSTRAINT invoice_source_shape CHECK ((source_kind = 'migration') = (sales_invoice_id IS NULL)
                                         AND (source_kind <> 'sales_cancellation' OR subject = 3)),
  -- نوع ۲ فقط در الگوهای ۱، ۳، ۹ و ۱۳؛ نوع ۳ (رسید کارتخوان) فقط الگوی فروش
  CONSTRAINT invoice_type_pattern CHECK ((inv_type <> 2 OR pattern IN (1,3,9,13)) AND (inv_type <> 3 OR pattern = 1)),
  -- برگشت از فروش برای صادرات، بارنامه و بورس مجاز نیست
  CONSTRAINT invoice_return_pattern CHECK (subject <> 4 OR pattern NOT IN (7,8,11)),
  CONSTRAINT invoice_registered CHECK ((status = 'registered') = (registered_issue_id IS NOT NULL)),
  CONSTRAINT invoice_withdrawn CHECK ((status = 'withdrawn') = (withdrawn_at IS NOT NULL AND char_length(btrim(coalesce(withdrawn_reason, ''))) >= 5))
);
SELECT core.enable_tenant_rls('tax.invoice');
CREATE UNIQUE INDEX IF NOT EXISTS invoice_one_per_sales_subject ON tax.invoice (tenant_id, sales_invoice_id, subject) WHERE sales_invoice_id IS NOT NULL;
-- زنجیرهٔ اصلاحی خطی و یک ابطالی برای هر نسخه
CREATE UNIQUE INDEX IF NOT EXISTS invoice_one_successor ON tax.invoice (tenant_id, ref_invoice_id)
  WHERE subject IN (2,3) AND status <> 'withdrawn';
CREATE INDEX IF NOT EXISTS invoice_status_idx ON tax.invoice (tenant_id, company_id, status);

-- نسخهٔ صادرشده: taxid، سریال، payload امضاشدنی (تغییرناپذیر)، وضعیت ارسال
CREATE TABLE IF NOT EXISTS tax.invoice_issue (
  tenant_id                 uuid NOT NULL REFERENCES core.tenant(id),
  id                        uuid NOT NULL DEFAULT uuidv7(),
  company_id                uuid NOT NULL,
  invoice_id                uuid NOT NULL,
  issue_no                  smallint NOT NULL CHECK (issue_no BETWEEN 1 AND 100),
  memory_ref                uuid NOT NULL,
  memory_id                 text NOT NULL,
  serial                    bigint NOT NULL CHECK (serial BETWEEN 1 AND 1099511627775),   -- 16^10 − 1
  number_issued_id          uuid,                    -- core.number_issued (NULL فقط برای تاریخچهٔ منتقل‌شده)
  allocation                text NOT NULL CHECK (allocation IN ('server','device','device_range','migration')),
  device_id                 uuid,
  indatim_ms                bigint NOT NULL CHECK (indatim_ms > 0),
  issue_date                date NOT NULL,                                       -- تاریخ محلی تهران (گزارش/دوره)
  taxid                     char(22) NOT NULL,
  irtaxid                   char(22),
  subject                   smallint NOT NULL CHECK (subject IN (1,2,3,4)),
  inv_type                  smallint NOT NULL CHECK (inv_type IN (1,2,3)),
  pattern                   smallint NOT NULL,
  setm                      smallint NOT NULL CHECK (setm IN (1,2,3)),
  amount_scale              smallint NOT NULL DEFAULT 0 CHECK (amount_scale IN (0,4)),   -- ریال صحیح، ارز تا ۴ رقم
  tprdis                    core.amount NOT NULL CHECK (tprdis >= 0),
  tdis                      core.amount NOT NULL CHECK (tdis >= 0),
  tadis                     core.amount NOT NULL CHECK (tadis >= 0),
  tvam                      core.amount NOT NULL CHECK (tvam >= 0),
  todam                     core.amount NOT NULL CHECK (todam >= 0),
  tolam                     core.amount NOT NULL CHECK (tolam >= 0),
  tbill                     core.amount NOT NULL CHECK (tbill >= 0),
  cap                       core.amount CHECK (cap >= 0),
  insp                      core.amount CHECK (insp >= 0),
  seller_tin                text NOT NULL CHECK (seller_tin ~ '^([0-9]{11}|[0-9]{14})$'),
  seller_branch_code        text CHECK (seller_branch_code ~ '^[0-9]{4}$'),
  buyer_type                smallint CHECK (buyer_type IN (1,2,3,4)),                   -- tob
  buyer_national_id         text CHECK (buyer_national_id ~ '^[0-9]{10,12}$'),          -- bid
  buyer_tin                 text CHECK (buyer_tin ~ '^([0-9]{11}|[0-9]{14})$'),         -- tinb
  buyer_postal_code         text CHECK (buyer_postal_code ~ '^[0-9]{10}$'),             -- bpc
  buyer_branch_code         text CHECK (buyer_branch_code ~ '^[0-9]{4}$'),              -- bbc
  payload                   jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object' AND jsonb_typeof(payload -> 'header') = 'object'
                                                  AND jsonb_typeof(payload -> 'body') = 'array'),
  payload_sha256            bytea NOT NULL CHECK (octet_length(payload_sha256) = 32),
  rule_snapshot_id          uuid NOT NULL,
  send_deadline_at          timestamptz NOT NULL,
  status                    text NOT NULL DEFAULT 'prepared'
                            CHECK (status IN ('prepared','signed','sent','unknown','not_received','success','failed','abandoned')),
  signed_at                 timestamptz,
  signer                    text CHECK (signer IN ('server_kms','device_agent','tsp')),
  jws_sha256                bytea CHECK (octet_length(jws_sha256) = 32),
  jws_attachment_id         uuid,
  last_reference_number     text,
  success_reference_number  text,
  success_at                timestamptz,
  success_sign_jws          text,                                   -- رسید امضاشدهٔ سازمان (اثبات ثبت)
  failure_codes             text[],
  failed_at                 timestamptz,
  abandoned_reason          text,
  abandoned_at              timestamptz,
  buyer_reaction            text CHECK (buyer_reaction IN ('awaiting','approved','systemic_approved','rejected','impossible','no_need','canceled')),
  reaction_checked_at       timestamptz,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  row_version               integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, taxid),
  UNIQUE (tenant_id, invoice_id, issue_no),
  UNIQUE (tenant_id, memory_ref, serial),
  UNIQUE (tenant_id, number_issued_id),
  FOREIGN KEY (tenant_id, company_id, invoice_id) REFERENCES tax.invoice(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, memory_ref) REFERENCES tax.memory(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, number_issued_id) REFERENCES core.number_issued(tenant_id, id),
  FOREIGN KEY (tenant_id, device_id) REFERENCES core.device(tenant_id, id),
  FOREIGN KEY (tenant_id, rule_snapshot_id) REFERENCES rules.calc_snapshot(tenant_id, id),
  FOREIGN KEY (tenant_id, jws_attachment_id) REFERENCES core.attachment(tenant_id, id),
  -- taxid = حافظه + روز UTC (Hex ۵) + سریال (Hex ۱۰) + رقم کنترلی Verhoeff رسمی
  CONSTRAINT issue_taxid_valid CHECK (tax.taxid_valid(taxid)),
  CONSTRAINT issue_taxid_memory CHECK (substr(taxid, 1, 6) = memory_id),
  CONSTRAINT issue_taxid_day CHECK (substr(taxid, 7, 5) = lpad(upper(to_hex(indatim_ms / 86400000)), 5, '0')),
  CONSTRAINT issue_taxid_serial CHECK (substr(taxid, 12, 10) = lpad(upper(to_hex(serial)), 10, '0')),
  CONSTRAINT issue_irtaxid CHECK ((subject = 1) = (irtaxid IS NULL) AND (irtaxid IS NULL OR tax.taxid_valid(irtaxid))),
  CONSTRAINT issue_totals CHECK (tadis = tprdis - tdis AND tbill = tadis + tvam + todam + tolam),
  -- نوع ۲ و ۳ همیشه نقدی‌اند؛ setm=3 ⇒ cap + insp = tbill − tvam − todam
  CONSTRAINT issue_cash_types CHECK (inv_type = 1 OR setm = 1),
  CONSTRAINT issue_settlement CHECK ((setm = 3) = (cap IS NOT NULL AND insp IS NOT NULL)
                                     AND (setm <> 3 OR cap + insp = tbill - tvam - todam)),
  -- خریدار نوع ۱: حقوقی/مشارکت مدنی ⇒ tinb؛ حقیقی/اتباع ⇒ tinb یا (bid + bpc)
  CONSTRAINT issue_type1_buyer CHECK (inv_type <> 1 OR (buyer_type IS NOT NULL AND (
                                        (buyer_type IN (2,3) AND buyer_tin IS NOT NULL)
                                     OR (buyer_type IN (1,4) AND (buyer_tin IS NOT NULL
                                                                  OR (buyer_national_id IS NOT NULL AND buyer_postal_code IS NOT NULL)))))),
  CONSTRAINT issue_allocation CHECK ((allocation IN ('device','device_range')) = (device_id IS NOT NULL)
                                    AND (allocation = 'migration') = (number_issued_id IS NULL)),
  CONSTRAINT issue_deadline CHECK (send_deadline_at > to_timestamp(indatim_ms / 1000.0)),
  CONSTRAINT issue_signed CHECK ((status IN ('prepared','abandoned')) OR (signed_at IS NOT NULL AND signer IS NOT NULL AND jws_sha256 IS NOT NULL)
                                 OR (status = 'success' AND allocation = 'migration')),
  CONSTRAINT issue_success CHECK ((status = 'success') = (success_at IS NOT NULL AND success_reference_number IS NOT NULL)
                                  AND (status <> 'success' OR allocation = 'migration' OR success_sign_jws IS NOT NULL)),
  CONSTRAINT issue_failed CHECK ((status = 'failed') = (failed_at IS NOT NULL AND cardinality(failure_codes) >= 1)),
  CONSTRAINT issue_abandoned CHECK ((status = 'abandoned') = (abandoned_at IS NOT NULL AND abandoned_reason IS NOT NULL)),
  CONSTRAINT issue_reaction CHECK (buyer_reaction IS NULL OR status = 'success')
);
SELECT core.enable_tenant_rls('tax.invoice_issue');
-- حداکثر یک نسخهٔ در جریان و یک نسخهٔ موفق برای هر سند
CREATE UNIQUE INDEX IF NOT EXISTS issue_one_open ON tax.invoice_issue (tenant_id, invoice_id)
  WHERE status IN ('prepared','signed','sent','unknown','not_received');
CREATE UNIQUE INDEX IF NOT EXISTS issue_one_success ON tax.invoice_issue (tenant_id, invoice_id) WHERE status = 'success';
CREATE INDEX IF NOT EXISTS issue_queue_idx ON tax.invoice_issue (tenant_id, status, send_deadline_at) WHERE status NOT IN ('success','failed','abandoned');
CREATE INDEX IF NOT EXISTS issue_period_idx ON tax.invoice_issue (tenant_id, company_id, issue_date) WHERE status = 'success';

-- سطرهای body (اقلام) — حساب سطر عین دستورالعمل با قطع ارقام
CREATE TABLE IF NOT EXISTS tax.invoice_issue_line (
  tenant_id       uuid NOT NULL REFERENCES core.tenant(id),
  id              uuid NOT NULL DEFAULT uuidv7(),
  issue_id        uuid NOT NULL,
  line_no         integer NOT NULL CHECK (line_no BETWEEN 1 AND 100000),
  sstid           char(13) NOT NULL CHECK (sstid ~ '^[0-9]{13}$'),
  sstt            text NOT NULL CHECK (char_length(sstt) BETWEEN 1 AND 400),
  mu              text NOT NULL REFERENCES ref.moadian_unit(code),
  am              numeric(26,8) NOT NULL CHECK (am > 0),
  fee             numeric(28,4) NOT NULL CHECK (fee >= 0),
  amount_scale    smallint NOT NULL CHECK (amount_scale IN (0,4)),
  prdis           core.amount NOT NULL,
  dis             core.amount NOT NULL DEFAULT 0 CHECK (dis >= 0),
  adis            core.amount NOT NULL,
  vra             numeric(7,4) NOT NULL CHECK (vra >= 0 AND vra <= 100),
  vam             core.amount NOT NULL,
  odt             text CHECK (odt ~ '^[A-Za-z0-9._-]{1,40}$'),
  odr             numeric(7,4) NOT NULL DEFAULT 0 CHECK (odr >= 0 AND odr <= 100),
  odam            core.amount NOT NULL DEFAULT 0,
  olt             text CHECK (olt ~ '^[A-Za-z0-9._-]{1,40}$'),
  olr             numeric(7,4) NOT NULL DEFAULT 0 CHECK (olr >= 0 AND olr <= 100),
  olam            core.amount NOT NULL DEFAULT 0,
  tsstam          core.amount NOT NULL,
  rate_source     text NOT NULL CHECK (rate_source IN ('sstid_catalog','not_called_in_zero','pattern_zero','category_fallback','migration')),
  source_line_id  uuid,                         -- sales.invoice_line (FK در 99_cross_fk)
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, issue_id, line_no),
  FOREIGN KEY (tenant_id, issue_id) REFERENCES tax.invoice_issue(tenant_id, id),
  CONSTRAINT line_prdis CHECK (prdis = trunc(am * fee, amount_scale)),
  CONSTRAINT line_adis CHECK (dis <= prdis AND adis = prdis - dis),
  CONSTRAINT line_vam CHECK (vam = tax.moadian_part(adis, vra, amount_scale)),
  CONSTRAINT line_odam CHECK (odam = tax.moadian_part(adis, odr, amount_scale) AND (odr = 0 OR odt IS NOT NULL)),
  CONSTRAINT line_olam CHECK (olam = tax.moadian_part(adis, olr, amount_scale) AND (olr = 0 OR olt IS NOT NULL)),
  CONSTRAINT line_total CHECK (tsstam = adis + vam + odam + olam),
  CONSTRAINT line_zero_rate_source CHECK (rate_source NOT IN ('not_called_in_zero','pattern_zero') OR vra = 0)
);
SELECT core.enable_tenant_rls('tax.invoice_issue_line');
DROP TRIGGER IF EXISTS trg_immutable ON tax.invoice_issue_line;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON tax.invoice_issue_line FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

CREATE OR REPLACE FUNCTION tax.invoice_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE r tax.invoice; v_changed text[];
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM core.raise_hk('HK_TAX_INVOICE_IMMUTABLE', 'tax documents are withdrawn, never deleted');
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'pending' AND NOT (NEW.source_kind = 'migration' AND NEW.status = 'in_progress') THEN
      PERFORM core.raise_hk('HK_TAX_INVOICE_TRANSITION', 'tax documents start pending');
    END IF;
    IF NEW.subject <> 1 THEN
      SELECT * INTO r FROM tax.invoice WHERE tenant_id = NEW.tenant_id AND id = NEW.ref_invoice_id;
      IF r.inv_type <> NEW.inv_type OR r.pattern <> NEW.pattern THEN
        PERFORM core.raise_hk('HK_TAX_REF_CHANGES_TYPE', 'corrective/cancel/return keep the type and pattern of the reference');
      END IF;
      IF r.status = 'withdrawn' THEN
        PERFORM core.raise_hk('HK_TAX_REF_NOT_REGISTERABLE', 'the reference was withdrawn and is not registered');
      END IF;
      IF NEW.root_invoice_id IS DISTINCT FROM coalesce(r.root_invoice_id, r.id) THEN
        PERFORM core.raise_hk('HK_TAX_REF_ROOT', 'root_invoice_id must be the chain original');
      END IF;
      IF r.subject IN (3) THEN
        PERFORM core.raise_hk('HK_TAX_REF_CANCELLED', 'a cancellation cannot be referenced');
      END IF;
      -- مرجع باید سرِ زنجیره باشد: اصلاحی فعال یا ابطالی فعال روی آن نباشد
      IF EXISTS (SELECT 1 FROM tax.invoice x WHERE x.tenant_id = NEW.tenant_id AND x.ref_invoice_id = r.id
                    AND x.subject IN (2,3) AND x.status <> 'withdrawn') THEN
        PERFORM core.raise_hk('HK_TAX_REF_NOT_HEAD', 'refer to the latest version of the invoice (it has a corrective or cancellation)');
      END IF;
    END IF;
    RETURN NEW;
  END IF;
  v_changed := rules.changed_columns(to_jsonb(OLD), to_jsonb(NEW));
  IF NOT (v_changed <@ ARRAY['status','registered_issue_id','withdrawn_reason','withdrawn_at','updated_at','row_version']) THEN
    PERFORM core.raise_hk('HK_TAX_INVOICE_IMMUTABLE', format('cannot change %s', array_to_string(v_changed, ',')));
  END IF;
  IF NEW.status = OLD.status THEN RETURN NEW; END IF;
  IF NOT ((OLD.status, NEW.status) IN (('pending','in_progress'),('in_progress','registered'),('in_progress','rejected'),
                                        ('rejected','in_progress'),('pending','withdrawn'),('rejected','withdrawn'),
                                        ('in_progress','withdrawn'))) THEN
    PERFORM core.raise_hk('HK_TAX_INVOICE_TRANSITION', format('%s → %s is not allowed', OLD.status, NEW.status));
  END IF;
  IF NEW.status = 'registered' AND NOT EXISTS (SELECT 1 FROM tax.invoice_issue i WHERE i.tenant_id = NEW.tenant_id
         AND i.id = NEW.registered_issue_id AND i.invoice_id = NEW.id AND i.status = 'success') THEN
    PERFORM core.raise_hk('HK_TAX_INVOICE_EVIDENCE', 'registered needs a successful issue of this document');
  END IF;
  IF NEW.status = 'withdrawn' AND EXISTS (SELECT 1 FROM tax.invoice_issue i WHERE i.tenant_id = NEW.tenant_id
         AND i.invoice_id = NEW.id AND i.status IN ('sent','unknown','success')) THEN
    PERFORM core.raise_hk('HK_TAX_WITHDRAW_IN_FLIGHT', 'an issue was sent or its outcome is unknown; inquire first');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON tax.invoice;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON tax.invoice FOR EACH ROW EXECUTE FUNCTION tax.invoice_guard();
DROP TRIGGER IF EXISTS trg_touch ON tax.invoice;
CREATE TRIGGER trg_touch BEFORE UPDATE ON tax.invoice FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- کنار گذاشتن نسخه‌های باز پس از withdraw
CREATE OR REPLACE FUNCTION tax.invoice_after() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status = 'withdrawn' AND OLD.status <> 'withdrawn' THEN
    UPDATE tax.invoice_issue SET status = 'abandoned', abandoned_at = now(), abandoned_reason = 'document withdrawn: ' || NEW.withdrawn_reason
     WHERE tenant_id = NEW.tenant_id AND invoice_id = NEW.id AND status IN ('prepared','signed','not_received');
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_after ON tax.invoice;
CREATE TRIGGER trg_after AFTER UPDATE ON tax.invoice FOR EACH ROW EXECUTE FUNCTION tax.invoice_after();

CREATE OR REPLACE FUNCTION tax.issue_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE inv tax.invoice; m tax.memory; n core.number_issued; v_changed text[]; v_prev int; ref_issue tax.invoice_issue;
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM core.raise_hk('HK_TAX_ISSUE_IMMUTABLE', 'issued tax invoices are archived forever');
  END IF;
  IF TG_OP = 'INSERT' THEN
    SELECT * INTO inv FROM tax.invoice WHERE tenant_id = NEW.tenant_id AND id = NEW.invoice_id;
    SELECT * INTO m FROM tax.memory WHERE tenant_id = NEW.tenant_id AND id = NEW.memory_ref;
    IF NEW.memory_ref <> inv.memory_ref OR NEW.memory_id <> m.memory_id THEN
      PERFORM core.raise_hk('HK_TAX_ISSUE_MEMORY', 'issue memory must be the document memory');
    END IF;
    IF (NEW.subject, NEW.inv_type, NEW.pattern) IS DISTINCT FROM (inv.subject, inv.inv_type, inv.pattern) THEN
      PERFORM core.raise_hk('HK_TAX_ISSUE_HEADER', 'subject/type/pattern must equal the document');
    END IF;
    IF inv.status NOT IN ('pending','rejected') AND NOT (inv.source_kind = 'migration' AND inv.status = 'in_progress') THEN
      PERFORM core.raise_hk('HK_TAX_ISSUE_STATE', format('cannot issue for a document in status %s', inv.status));
    END IF;
    SELECT coalesce(max(issue_no), 0) INTO v_prev FROM tax.invoice_issue WHERE tenant_id = NEW.tenant_id AND invoice_id = NEW.invoice_id;
    IF NEW.issue_no <> v_prev + 1 THEN
      PERFORM core.raise_hk('HK_TAX_ISSUE_NO', format('issue_no must be %s', v_prev + 1));
    END IF;
    IF NEW.status = 'success' THEN
      IF NOT (inv.source_kind = 'migration' AND NEW.allocation = 'migration') THEN
        PERFORM core.raise_hk('HK_TAX_ISSUE_STATE', 'only migrated history is inserted as success');
      END IF;
    ELSIF NEW.status <> 'prepared' THEN
      PERFORM core.raise_hk('HK_TAX_ISSUE_STATE', 'issues start prepared');
    ELSIF m.status <> 'active' THEN
      PERFORM core.raise_hk('HK_TAX_MEMORY_NOT_ACTIVE', format('memory %s is %s', m.memory_id, m.status));
    END IF;
    -- تاریخچهٔ منتقل‌شده: سریال‌های قبلی زیر start_value سری (سریال تازه = بیشینهٔ قبلی + ۱)
    IF NEW.allocation = 'migration' THEN
      IF NEW.serial >= (SELECT start_value FROM core.number_series WHERE tenant_id = NEW.tenant_id AND id = m.serial_series_id) THEN
        PERFORM core.raise_hk('HK_TAX_MIGRATION_SERIAL', 'migrated serials must be below the series start value (previous max + 1)');
      END IF;
      RETURN NEW;
    END IF;
    -- سریال از سری حافظه صادر شده و به همین نسخه تعلق دارد
    SELECT * INTO n FROM core.number_issued WHERE tenant_id = NEW.tenant_id AND id = NEW.number_issued_id;
    IF n.series_id <> m.serial_series_id OR n.value <> NEW.serial OR n.status <> 'used'
       OR n.doc_type <> 'tax.moadian_serial' OR n.doc_id <> NEW.id THEN
      PERFORM core.raise_hk('HK_TAX_SERIAL_NOT_ISSUED', 'serial must be the number issued from the memory series for this issue');
    END IF;
    IF (NEW.allocation = 'server' AND m.allocation <> 'server')
       OR (NEW.allocation = 'device' AND (m.allocation <> 'device' OR NEW.device_id <> m.device_id))
       OR (NEW.allocation = 'device_range' AND (m.allocation <> 'device_ranges' OR n.reservation_id IS NULL OR n.device_id <> NEW.device_id)) THEN
      PERFORM core.raise_hk('HK_TAX_SERIAL_ALLOCATION', 'serial allocation does not match the memory');
    END IF;
    -- مرجع: taxid نسخهٔ ثبت‌شدهٔ سند مرجع و تاریخ صدور بعد از آن
    IF NEW.subject <> 1 THEN
      SELECT i.* INTO ref_issue FROM tax.invoice r JOIN tax.invoice_issue i ON i.tenant_id = r.tenant_id AND i.id = r.registered_issue_id
       WHERE r.tenant_id = NEW.tenant_id AND r.id = inv.ref_invoice_id AND r.status = 'registered';
      IF NOT FOUND THEN
        PERFORM core.raise_hk('HK_TAX_REF_NOT_REGISTERED', 'the reference must be registered before a corrective/cancel/return is issued');
      END IF;
      IF NEW.irtaxid <> ref_issue.taxid THEN
        PERFORM core.raise_hk('HK_TAX_IRTAXID', 'irtaxid must be the registered taxid of the reference');
      END IF;
      IF NEW.indatim_ms <= ref_issue.indatim_ms THEN
        PERFORM core.raise_hk('HK_TAX_REF_DATE', 'a referencing invoice must be issued after its reference');
      END IF;
    END IF;
    RETURN NEW;
  END IF;
  -- UPDATE: محتوا تغییرناپذیر؛ فقط ستون‌های وضعیت
  v_changed := rules.changed_columns(to_jsonb(OLD), to_jsonb(NEW));
  IF NOT (v_changed <@ ARRAY['status','signed_at','signer','jws_sha256','jws_attachment_id','last_reference_number',
                              'success_reference_number','success_at','success_sign_jws','failure_codes','failed_at',
                              'abandoned_reason','abandoned_at','buyer_reaction','reaction_checked_at','updated_at','row_version']) THEN
    PERFORM core.raise_hk('HK_TAX_ISSUE_IMMUTABLE', format('cannot change %s', array_to_string(v_changed, ',')));
  END IF;
  IF OLD.signed_at IS NOT NULL AND v_changed && ARRAY['signed_at','signer','jws_sha256','jws_attachment_id'] THEN
    PERFORM core.raise_hk('HK_TAX_ISSUE_IMMUTABLE', 'signature is fixed once stored');
  END IF;
  IF NEW.status = OLD.status THEN
    IF v_changed && ARRAY['buyer_reaction','reaction_checked_at'] AND OLD.status <> 'success' THEN
      PERFORM core.raise_hk('HK_TAX_ISSUE_STATE', 'buyer reaction is tracked only for registered invoices');
    END IF;
    RETURN NEW;
  END IF;
  IF NOT ((OLD.status, NEW.status) IN (
       ('prepared','signed'),('prepared','abandoned'),('signed','sent'),('signed','unknown'),('signed','not_received'),
       ('signed','abandoned'),('sent','success'),('sent','failed'),('sent','not_received'),('unknown','sent'),
       ('unknown','success'),('unknown','failed'),('unknown','not_received'),('not_received','sent'),
       ('not_received','unknown'),('not_received','abandoned'),('not_received','not_received'))) THEN
    PERFORM core.raise_hk('HK_TAX_ISSUE_TRANSITION', format('%s → %s is not allowed', OLD.status, NEW.status));
  END IF;
  -- گذارهای ارسال/پاسخ فقط با شاهدِ آخرین ردیف بایگانی (تلاش ارسال یا استعلام)
  IF NOT tax.issue_evidence_ok(NEW, OLD.status) THEN
    PERFORM core.raise_hk('HK_TAX_ISSUE_EVIDENCE', format('%s → %s needs a matching archived submission attempt or inquiry', OLD.status, NEW.status));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON tax.invoice_issue;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON tax.invoice_issue FOR EACH ROW EXECUTE FUNCTION tax.issue_guard();
DROP TRIGGER IF EXISTS trg_touch ON tax.invoice_issue;
CREATE TRIGGER trg_touch BEFORE UPDATE ON tax.invoice_issue FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- همگام‌سازی وضعیت سند منطقی با نسخه
CREATE OR REPLACE FUNCTION tax.issue_after() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status = 'success' THEN   -- تاریخچهٔ مهاجرت
      UPDATE tax.invoice SET status = 'in_progress' WHERE tenant_id = NEW.tenant_id AND id = NEW.invoice_id AND status = 'pending';
      UPDATE tax.invoice SET status = 'registered', registered_issue_id = NEW.id WHERE tenant_id = NEW.tenant_id AND id = NEW.invoice_id;
    ELSE
      UPDATE tax.invoice SET status = 'in_progress' WHERE tenant_id = NEW.tenant_id AND id = NEW.invoice_id AND status <> 'in_progress';
    END IF;
    RETURN NULL;
  END IF;
  IF NEW.status = 'success' AND OLD.status <> 'success' THEN
    UPDATE tax.invoice SET status = 'registered', registered_issue_id = NEW.id WHERE tenant_id = NEW.tenant_id AND id = NEW.invoice_id;
  ELSIF NEW.status = 'failed' AND OLD.status <> 'failed' THEN
    UPDATE tax.invoice SET status = 'rejected' WHERE tenant_id = NEW.tenant_id AND id = NEW.invoice_id AND status = 'in_progress';
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_after ON tax.invoice_issue;
CREATE TRIGGER trg_after AFTER INSERT OR UPDATE ON tax.invoice_issue FOR EACH ROW EXECUTE FUNCTION tax.issue_after();

-- راستی‌آزمایی deferred نسخه: جمع‌ها = Σ سطرها؛ payload = ستون‌ها؛ قواعد اصلاحی/برگشت نسبت به مرجع
CREATE OR REPLACE FUNCTION tax.issue_verify() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE i tax.invoice_issue; h jsonb; s record; ref_issue_id uuid; ref_issue tax.invoice_issue; v_bad int; v_id uuid;
BEGIN
  IF TG_TABLE_NAME = 'invoice_issue' THEN v_id := NEW.id; ELSE v_id := NEW.issue_id; END IF;
  SELECT * INTO i FROM tax.invoice_issue WHERE tenant_id = NEW.tenant_id AND id = v_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT count(*) AS n, coalesce(sum(prdis),0) AS prdis, coalesce(sum(dis),0) AS dis, coalesce(sum(adis),0) AS adis,
         coalesce(sum(vam),0) AS vam, coalesce(sum(odam),0) AS odam, coalesce(sum(olam),0) AS olam,
         coalesce(sum(tsstam),0) AS tsstam, bool_and(amount_scale = i.amount_scale) AS scale_ok
    INTO s FROM tax.invoice_issue_line WHERE tenant_id = i.tenant_id AND issue_id = i.id;
  IF s.n = 0 THEN PERFORM core.raise_hk('HK_TAX_ISSUE_NO_LINES', 'an e-invoice needs at least one line'); END IF;
  IF NOT s.scale_ok OR (s.prdis, s.dis, s.adis, s.vam, s.odam, s.olam, s.tsstam)
       IS DISTINCT FROM (i.tprdis, i.tdis, i.tadis, i.tvam, i.todam, i.tolam, i.tbill) THEN
    PERFORM core.raise_hk('HK_TAX_ISSUE_TOTALS', format('header totals do not equal the sum of lines (tbill %s vs %s)', i.tbill, s.tsstam));
  END IF;
  h := i.payload -> 'header';
  IF h ->> 'taxid' IS DISTINCT FROM i.taxid OR (h ->> 'indatim')::bigint IS DISTINCT FROM i.indatim_ms
     OR h ->> 'inno' IS DISTINCT FROM substr(i.taxid, 12, 10)
     OR (h ->> 'inty')::smallint IS DISTINCT FROM i.inv_type OR (h ->> 'inp')::smallint IS DISTINCT FROM i.pattern
     OR (h ->> 'ins')::smallint IS DISTINCT FROM i.subject OR h ->> 'irtaxid' IS DISTINCT FROM i.irtaxid
     OR (h ->> 'tbill')::numeric IS DISTINCT FROM i.tbill OR (h ->> 'tvam')::numeric IS DISTINCT FROM i.tvam
     OR (h ->> 'setm')::smallint IS DISTINCT FROM i.setm OR jsonb_array_length(i.payload -> 'body') <> s.n THEN
    PERFORM core.raise_hk('HK_TAX_PAYLOAD_MISMATCH', 'payload header/body does not match the stored columns');
  END IF;
  IF i.subject IN (2,4) THEN
    SELECT r.registered_issue_id INTO ref_issue_id FROM tax.invoice t JOIN tax.invoice r ON r.tenant_id = t.tenant_id AND r.id = t.ref_invoice_id
     WHERE t.tenant_id = i.tenant_id AND t.id = i.invoice_id;
    SELECT * INTO ref_issue FROM tax.invoice_issue WHERE tenant_id = i.tenant_id AND id = ref_issue_id;
    IF i.subject = 2 AND (i.buyer_type, i.buyer_national_id, i.buyer_tin) IS DISTINCT FROM
                         (ref_issue.buyer_type, ref_issue.buyer_national_id, ref_issue.buyer_tin) THEN
      PERFORM core.raise_hk('HK_TAX_CORRECTIVE_BUYER', 'a corrective invoice cannot change the buyer (cancel and reissue instead)');
    END IF;
    -- اصلاحی: مجموعهٔ (sstid، نرخ) همان مرجع؛ برگشت: هر سطر با همان (sstid، fee، نرخ) مرجع و مقدار ≤ مقدار مرجع
    IF i.subject = 2 THEN
      SELECT count(*) INTO v_bad FROM (
        (SELECT sstid, vra FROM tax.invoice_issue_line WHERE tenant_id = i.tenant_id AND issue_id = i.id
         EXCEPT SELECT sstid, vra FROM tax.invoice_issue_line WHERE tenant_id = i.tenant_id AND issue_id = ref_issue.id)
        UNION ALL
        (SELECT sstid, vra FROM tax.invoice_issue_line WHERE tenant_id = i.tenant_id AND issue_id = ref_issue.id
         EXCEPT SELECT sstid, vra FROM tax.invoice_issue_line WHERE tenant_id = i.tenant_id AND issue_id = i.id)) x;
      IF v_bad > 0 THEN
        PERFORM core.raise_hk('HK_TAX_CORRECTIVE_ITEMS', 'a corrective invoice cannot change item ids or VAT rates');
      END IF;
    ELSE
      SELECT count(*) INTO v_bad FROM (
        SELECT l.sstid, l.fee, l.vra, sum(l.am) AS am FROM tax.invoice_issue_line l
         WHERE l.tenant_id = i.tenant_id AND l.issue_id = i.id GROUP BY 1, 2, 3) cur
        LEFT JOIN (SELECT l.sstid, l.fee, l.vra, sum(l.am) AS am FROM tax.invoice_issue_line l
                    WHERE l.tenant_id = i.tenant_id AND l.issue_id = ref_issue.id GROUP BY 1, 2, 3) ref
          ON ref.sstid = cur.sstid AND ref.fee = cur.fee AND ref.vra = cur.vra
       WHERE ref.sstid IS NULL OR cur.am > ref.am;
      IF v_bad > 0 THEN
        PERFORM core.raise_hk('HK_TAX_RETURN_ITEMS', 'a return lists the sold items minus returned ones at the same unit price and rate');
      END IF;
      IF NOT EXISTS (SELECT 1 FROM (SELECT sum(am) a FROM tax.invoice_issue_line WHERE tenant_id = i.tenant_id AND issue_id = i.id) c,
                                   (SELECT sum(am) a FROM tax.invoice_issue_line WHERE tenant_id = i.tenant_id AND issue_id = ref_issue.id) r
                      WHERE c.a < r.a) THEN
        PERFORM core.raise_hk('HK_TAX_RETURN_NOTHING', 'a return must reduce quantities (a full return is a cancellation, ins=3)');
      END IF;
    END IF;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_verify ON tax.invoice_issue;
CREATE CONSTRAINT TRIGGER trg_verify AFTER INSERT ON tax.invoice_issue
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tax.issue_verify();
DROP TRIGGER IF EXISTS trg_verify ON tax.invoice_issue_line;
CREATE CONSTRAINT TRIGGER trg_verify AFTER INSERT ON tax.invoice_issue_line
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tax.issue_verify();

-- سطرها فقط هم‌زمان با درج نسخه (همان تراکنش، پیش از امضا)
CREATE OR REPLACE FUNCTION tax.issue_line_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE i tax.invoice_issue;
BEGIN
  SELECT * INTO i FROM tax.invoice_issue WHERE tenant_id = NEW.tenant_id AND id = NEW.issue_id;
  IF i.status <> 'prepared' AND NOT (i.status = 'success' AND i.allocation = 'migration') THEN
    PERFORM core.raise_hk('HK_TAX_ISSUE_IMMUTABLE', 'lines are added only while the issue is prepared');
  END IF;
  IF NEW.amount_scale <> i.amount_scale THEN
    PERFORM core.raise_hk('HK_TAX_ISSUE_TOTALS', 'line amount_scale must equal the issue');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON tax.invoice_issue_line;
CREATE TRIGGER trg_guard BEFORE INSERT ON tax.invoice_issue_line FOR EACH ROW EXECUTE FUNCTION tax.issue_line_guard();

-- =====================================================================
-- ۹. tax — صف ارسال، تلاش‌ها و استعلام‌ها (بایگانی تغییرناپذیر)
-- =====================================================================
CREATE TABLE IF NOT EXISTS tax.send_batch (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  company_id        uuid NOT NULL,
  memory_ref        uuid NOT NULL,
  adapter           text NOT NULL CHECK (adapter IN ('direct_v2_cert','direct_v1_self_tsp','tsp','mock','sandbox')),
  environment       text NOT NULL CHECK (environment IN ('production','sandbox','mock')),
  item_count        integer NOT NULL CHECK (item_count BETWEEN 1 AND 10000),
  max_items         integer NOT NULL CHECK (max_items BETWEEN 1 AND 10000),   -- snapshot پارامتر tax.moadian.api.max_invoices_per_request
  status            text NOT NULL DEFAULT 'open' CHECK (status IN ('open','sent','error')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  sent_at           timestamptz,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, memory_ref) REFERENCES tax.memory(tenant_id, company_id, id),
  CHECK (item_count <= max_items),
  CHECK ((status = 'open') = (sent_at IS NULL))
);
SELECT core.enable_tenant_rls('tax.send_batch');

CREATE TABLE IF NOT EXISTS tax.submission_attempt (
  tenant_id              uuid NOT NULL REFERENCES core.tenant(id),
  id                     uuid NOT NULL DEFAULT uuidv7(),
  company_id             uuid NOT NULL,
  issue_id               uuid NOT NULL,
  batch_id               uuid NOT NULL,
  attempt_no             smallint NOT NULL CHECK (attempt_no BETWEEN 1 AND 50),
  request_trace_id       uuid NOT NULL,           -- یکتا برای هر تلاش (تکرار ⇒ رد کل درخواست)
  adapter                text NOT NULL,
  environment            text NOT NULL,
  sent_at                timestamptz NOT NULL,
  transport_outcome      text NOT NULL CHECK (transport_outcome IN ('accepted','rejected_sync','network_error','http_error')),
  http_status            smallint CHECK (http_status BETWEEN 100 AND 599),
  reference_number       text,
  error_codes            text[] NOT NULL DEFAULT '{}',
  request_sha256         bytea NOT NULL CHECK (octet_length(request_sha256) = 32),
  request_attachment_id  uuid,
  response               jsonb,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, request_trace_id),
  UNIQUE (tenant_id, issue_id, attempt_no),
  FOREIGN KEY (tenant_id, company_id, issue_id) REFERENCES tax.invoice_issue(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, batch_id) REFERENCES tax.send_batch(tenant_id, id),
  FOREIGN KEY (tenant_id, request_attachment_id) REFERENCES core.attachment(tenant_id, id),
  CHECK ((transport_outcome = 'accepted') = (reference_number IS NOT NULL)),
  CHECK (transport_outcome <> 'rejected_sync' OR cardinality(error_codes) >= 1)
);
SELECT core.enable_tenant_rls('tax.submission_attempt');

CREATE TABLE IF NOT EXISTS tax.inquiry_log (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  company_id        uuid NOT NULL,
  issue_id          uuid NOT NULL,
  kind              text NOT NULL CHECK (kind IN ('status','reaction')),
  asked_at          timestamptz NOT NULL DEFAULT now(),
  by_key            text NOT NULL CHECK (by_key IN ('uid','reference','taxid')),
  result            text NOT NULL CHECK (result IN ('SUCCESS','FAILED','IN_PROGRESS','NOT_FOUND','TIMEOUT',
                                                     'AWAITING_REACTION','APPROVED','SYSTEMIC_APPROVED','REJECTED',
                                                     'IMPOSSIBLE_REACTION','NO_NEED_REACTION','CANCELED')),
  reference_number  text,
  error_codes       text[] NOT NULL DEFAULT '{}',
  warnings          jsonb NOT NULL DEFAULT '[]'::jsonb,
  sign_jws          text,
  raw               jsonb,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, issue_id) REFERENCES tax.invoice_issue(tenant_id, company_id, id),
  CHECK ((kind = 'status') = (result IN ('SUCCESS','FAILED','IN_PROGRESS','NOT_FOUND','TIMEOUT'))),
  CHECK (result <> 'SUCCESS' OR (reference_number IS NOT NULL AND sign_jws IS NOT NULL)),
  CHECK (result <> 'FAILED' OR cardinality(error_codes) >= 1)
);
SELECT core.enable_tenant_rls('tax.inquiry_log');
CREATE INDEX IF NOT EXISTS inquiry_log_issue ON tax.inquiry_log (tenant_id, issue_id, id);

DROP TRIGGER IF EXISTS trg_immutable ON tax.submission_attempt;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON tax.submission_attempt FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();
DROP TRIGGER IF EXISTS trg_immutable ON tax.inquiry_log;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON tax.inquiry_log FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

-- شاهد گذار: آخرین تلاش/استعلام باید با وضعیت مقصد بخواند
CREATE OR REPLACE FUNCTION tax.issue_evidence_ok(i tax.invoice_issue, p_old text) RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
DECLARE a tax.submission_attempt; q tax.inquiry_log;
BEGIN
  SELECT * INTO a FROM tax.submission_attempt WHERE tenant_id = i.tenant_id AND issue_id = i.id ORDER BY attempt_no DESC LIMIT 1;
  SELECT * INTO q FROM tax.inquiry_log WHERE tenant_id = i.tenant_id AND issue_id = i.id AND kind = 'status' ORDER BY id DESC LIMIT 1;
  IF i.status IN ('prepared','signed','abandoned') THEN RETURN true; END IF;
  IF p_old IN ('signed','not_received') AND i.status IN ('sent','unknown','not_received') THEN
    RETURN a.id IS NOT NULL AND (q.id IS NULL OR a.sent_at >= q.asked_at)
           AND a.transport_outcome = CASE i.status WHEN 'sent' THEN 'accepted' WHEN 'unknown' THEN a.transport_outcome
                                                  ELSE 'rejected_sync' END
           AND (i.status <> 'unknown' OR a.transport_outcome IN ('network_error','http_error'));
  END IF;
  IF p_old IN ('sent','unknown') THEN
    RETURN q.id IS NOT NULL AND (a.id IS NULL OR q.asked_at >= a.sent_at)
           AND q.result = ANY (CASE i.status WHEN 'sent' THEN ARRAY['IN_PROGRESS'] WHEN 'success' THEN ARRAY['SUCCESS']
                                             WHEN 'failed' THEN ARRAY['FAILED'] WHEN 'not_received' THEN ARRAY['NOT_FOUND','TIMEOUT']
                                             ELSE ARRAY[]::text[] END)
           AND (i.status <> 'success' OR (q.reference_number = i.success_reference_number AND q.sign_jws = i.success_sign_jws));
  END IF;
  RETURN false;
END $$;

-- ارسال: هرگز پس از ثبت موفق؛ پس از خطای شبکه اول استعلام (وضعیت unknown ⇒ تلاش تازه رد می‌شود)
CREATE OR REPLACE FUNCTION tax.attempt_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE i tax.invoice_issue; b tax.send_batch; v_prev smallint;
BEGIN
  SELECT * INTO i FROM tax.invoice_issue WHERE tenant_id = NEW.tenant_id AND id = NEW.issue_id FOR UPDATE;
  IF i.status = 'success' THEN
    PERFORM core.raise_hk('HK_TAX_ALREADY_REGISTERED', 'a registered taxid is never sent again');
  ELSIF i.status IN ('sent','unknown') THEN
    PERFORM core.raise_hk('HK_TAX_INQUIRE_FIRST', 'outcome of the previous send is pending/unknown; inquire before resending');
  ELSIF i.status NOT IN ('signed','not_received') THEN
    PERFORM core.raise_hk('HK_TAX_ISSUE_STATE', format('cannot send an issue in status %s', i.status));
  END IF;
  IF i.send_deadline_at < NEW.sent_at THEN
    -- ارسال پس از مهلت ممنوع نیست (سامانه تصمیم می‌گیرد) ولی ثبت می‌شود؛ هشدار در سرویس
    NULL;
  END IF;
  SELECT * INTO b FROM tax.send_batch WHERE tenant_id = NEW.tenant_id AND id = NEW.batch_id;
  IF b.memory_ref <> i.memory_ref OR b.adapter <> NEW.adapter OR b.environment <> NEW.environment THEN
    PERFORM core.raise_hk('HK_TAX_BATCH_MISMATCH', 'attempt must use the batch memory/adapter/environment');
  END IF;
  IF (SELECT count(*) FROM tax.submission_attempt x WHERE x.tenant_id = NEW.tenant_id AND x.batch_id = NEW.batch_id) >= b.item_count THEN
    PERFORM core.raise_hk('HK_TAX_BATCH_FULL', format('batch holds at most %s invoices', b.item_count));
  END IF;
  SELECT coalesce(max(attempt_no), 0) INTO v_prev FROM tax.submission_attempt WHERE tenant_id = NEW.tenant_id AND issue_id = NEW.issue_id;
  IF NEW.attempt_no <> v_prev + 1 THEN
    PERFORM core.raise_hk('HK_TAX_ATTEMPT_NO', format('attempt_no must be %s', v_prev + 1));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON tax.submission_attempt;
CREATE TRIGGER trg_guard BEFORE INSERT ON tax.submission_attempt FOR EACH ROW EXECUTE FUNCTION tax.attempt_guard();

CREATE OR REPLACE FUNCTION tax.attempt_after() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE tax.invoice_issue
     SET status = CASE NEW.transport_outcome WHEN 'accepted' THEN 'sent' WHEN 'rejected_sync' THEN 'not_received' ELSE 'unknown' END,
         last_reference_number = coalesce(NEW.reference_number, last_reference_number)
   WHERE tenant_id = NEW.tenant_id AND id = NEW.issue_id;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_after ON tax.submission_attempt;
CREATE TRIGGER trg_after AFTER INSERT ON tax.submission_attempt FOR EACH ROW EXECUTE FUNCTION tax.attempt_after();

CREATE OR REPLACE FUNCTION tax.inquiry_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE i tax.invoice_issue;
BEGIN
  SELECT * INTO i FROM tax.invoice_issue WHERE tenant_id = NEW.tenant_id AND id = NEW.issue_id FOR UPDATE;
  IF NEW.kind = 'status' AND i.status NOT IN ('sent','unknown') THEN
    PERFORM core.raise_hk('HK_TAX_ISSUE_STATE', format('status inquiry is meaningful only for sent/unknown issues (got %s)', i.status));
  END IF;
  IF NEW.kind = 'reaction' AND i.status <> 'success' THEN
    PERFORM core.raise_hk('HK_TAX_ISSUE_STATE', 'reaction inquiry is only for registered invoices');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON tax.inquiry_log;
CREATE TRIGGER trg_guard BEFORE INSERT ON tax.inquiry_log FOR EACH ROW EXECUTE FUNCTION tax.inquiry_guard();

CREATE OR REPLACE FUNCTION tax.inquiry_after() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.kind = 'status' THEN
    UPDATE tax.invoice_issue
       SET status = CASE NEW.result WHEN 'SUCCESS' THEN 'success' WHEN 'FAILED' THEN 'failed'
                                    WHEN 'IN_PROGRESS' THEN 'sent' ELSE 'not_received' END,
           success_reference_number = CASE WHEN NEW.result = 'SUCCESS' THEN NEW.reference_number END,
           success_sign_jws = CASE WHEN NEW.result = 'SUCCESS' THEN NEW.sign_jws END,
           success_at = CASE WHEN NEW.result = 'SUCCESS' THEN NEW.asked_at END,
           failure_codes = CASE WHEN NEW.result = 'FAILED' THEN NEW.error_codes END,
           failed_at = CASE WHEN NEW.result = 'FAILED' THEN NEW.asked_at END,
           last_reference_number = coalesce(NEW.reference_number, last_reference_number)
     WHERE tenant_id = NEW.tenant_id AND id = NEW.issue_id;
  ELSE
    UPDATE tax.invoice_issue
       SET buyer_reaction = CASE NEW.result WHEN 'AWAITING_REACTION' THEN 'awaiting' WHEN 'APPROVED' THEN 'approved'
                                            WHEN 'SYSTEMIC_APPROVED' THEN 'systemic_approved' WHEN 'REJECTED' THEN 'rejected'
                                            WHEN 'IMPOSSIBLE_REACTION' THEN 'impossible' WHEN 'NO_NEED_REACTION' THEN 'no_need'
                                            ELSE 'canceled' END,
           reaction_checked_at = NEW.asked_at
     WHERE tenant_id = NEW.tenant_id AND id = NEW.issue_id;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_after ON tax.inquiry_log;
CREATE TRIGGER trg_after AFTER INSERT ON tax.inquiry_log FOR EACH ROW EXECUTE FUNCTION tax.inquiry_after();

-- =====================================================================
-- ۱۰. tax — دفتر مالیات خرید (اعتبار مالیاتی)، پایش سقف‌ها، اظهارنامهٔ فصلی، گزارش‌های قانونی
-- =====================================================================
-- ثبت‌کننده: سرویس TaxRegisterService به درخواست purchase/assets/migration (هرگز درج مستقیم ماژول دیگر)
CREATE TABLE IF NOT EXISTS tax.purchase_entry (
  tenant_id              uuid NOT NULL REFERENCES core.tenant(id),
  id                     uuid NOT NULL DEFAULT uuidv7(),
  company_id             uuid NOT NULL,
  source_module          text NOT NULL CHECK (source_module IN ('purchase','treasury','assets','migration')),
  source_doc_type        text NOT NULL CHECK (source_doc_type ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  source_doc_id          uuid NOT NULL,
  source_doc_no          text CHECK (char_length(source_doc_no) <= 100),
  entry_kind             text NOT NULL CHECK (entry_kind IN ('invoice','return','cancellation')),
  supplier_party_id      uuid NOT NULL,
  supplier_tin           text CHECK (supplier_tin ~ '^([0-9]{11}|[0-9]{14})$'),
  doc_date               date NOT NULL,
  period_key             text NOT NULL CHECK (period_key ~ '^jq:[0-9]{4}Q[1-4]$'),
  sign                   smallint NOT NULL CHECK (sign IN (1,-1)),
  net_amount             core.amount NOT NULL CHECK (net_amount >= 0),
  vat_amount             core.amount NOT NULL CHECK (vat_amount >= 0),
  other_tax_amount       core.amount NOT NULL DEFAULT 0 CHECK (other_tax_amount >= 0),
  moadian_taxid          char(22),
  moadian_inv_type       smallint CHECK (moadian_inv_type IN (1,2,3)),
  moadian_status         text NOT NULL DEFAULT 'unknown'
                         CHECK (moadian_status IN ('unknown','not_registered','registered','awaiting_reaction','approved',
                                                   'systemic_approved','rejected','canceled')),
  credit_eligibility     text NOT NULL DEFAULT 'pending' CHECK (credit_eligibility IN ('pending','eligible','ineligible','paper_grace')),
  eligibility_reason     text,
  eligibility_snapshot_id uuid,
  vat_return_id          uuid,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  row_version            integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, source_module, source_doc_type, source_doc_id, entry_kind),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, supplier_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, eligibility_snapshot_id) REFERENCES rules.calc_snapshot(tenant_id, id),
  CONSTRAINT purchase_entry_sign CHECK ((entry_kind = 'invoice') = (sign = 1)),
  CONSTRAINT purchase_entry_taxid CHECK (moadian_taxid IS NULL OR tax.taxid_valid(moadian_taxid)),
  CONSTRAINT purchase_entry_registered CHECK (moadian_status IN ('unknown','not_registered') OR moadian_taxid IS NOT NULL),
  -- اعتبار خرید فقط با صورتحساب نوع ۱ ثبت‌شده و تأییدشده (صریح یا سیستمی)؛ «مهلت کاغذی» تابع قاعدهٔ تاریخ‌دار
  CONSTRAINT purchase_entry_eligible CHECK (credit_eligibility <> 'eligible'
        OR (moadian_inv_type = 1 AND moadian_status IN ('approved','systemic_approved'))),
  CONSTRAINT purchase_entry_decided CHECK (credit_eligibility = 'pending'
        OR (eligibility_reason IS NOT NULL AND eligibility_snapshot_id IS NOT NULL))
);
SELECT core.enable_tenant_rls('tax.purchase_entry');
CREATE UNIQUE INDEX IF NOT EXISTS purchase_entry_taxid_uq ON tax.purchase_entry (tenant_id, company_id, moadian_taxid, entry_kind)
  WHERE moadian_taxid IS NOT NULL;
CREATE INDEX IF NOT EXISTS purchase_entry_period ON tax.purchase_entry (tenant_id, company_id, period_key);

-- پایش حد ماده ۶ و سقف معافیت ماده ۱۴ مکرر (هر شرکت، هر سال جلالی)
CREATE TABLE IF NOT EXISTS tax.threshold_monitor (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL DEFAULT uuidv7(),
  company_id         uuid NOT NULL,
  kind               text NOT NULL CHECK (kind IN ('article6_limit','art14m_ceiling')),
  tax_year           smallint NOT NULL CHECK (tax_year BETWEEN 1390 AND 1500),
  limit_amount       core.amount NOT NULL CHECK (limit_amount > 0),
  limit_basis        jsonb NOT NULL CHECK (jsonb_typeof(limit_basis) = 'object'),   -- {prior_year_sales, multiplier, source}
  rule_snapshot_id   uuid NOT NULL,
  warn_ratio         numeric(5,4) NOT NULL CHECK (warn_ratio > 0 AND warn_ratio < 1),
  cumulative_amount  core.amount NOT NULL DEFAULT 0 CHECK (cumulative_amount >= 0),
  status             text NOT NULL DEFAULT 'ok' CHECK (status IN ('ok','warning','exceeded')),
  crossed_on         date,
  consequence_from   date,                                   -- مثلاً آغاز فصل بعد برای پایان معافیت ۱۴ مکرر
  portal_status      text,                                   -- article6Status از API
  portal_checked_at  timestamptz,
  evaluated_at       timestamptz NOT NULL DEFAULT now(),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  row_version        integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, kind, tax_year),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, rule_snapshot_id) REFERENCES rules.calc_snapshot(tenant_id, id),
  CONSTRAINT threshold_status CHECK (status = CASE WHEN cumulative_amount > limit_amount THEN 'exceeded'
                                                   WHEN cumulative_amount >= limit_amount * warn_ratio THEN 'warning'
                                                   ELSE 'ok' END),
  CONSTRAINT threshold_crossed CHECK ((status = 'exceeded') = (crossed_on IS NOT NULL)),
  CONSTRAINT threshold_consequence CHECK (consequence_from IS NULL OR crossed_on IS NOT NULL AND consequence_from >= crossed_on)
);
SELECT core.enable_tenant_rls('tax.threshold_monitor');
DROP TRIGGER IF EXISTS trg_touch ON tax.threshold_monitor;
CREATE TRIGGER trg_touch BEFORE UPDATE ON tax.threshold_monitor FOR EACH ROW EXECUTE FUNCTION core.touch_row();

CREATE OR REPLACE FUNCTION tax.threshold_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN PERFORM core.raise_hk('HK_TAX_THRESHOLD_IMMUTABLE', 'threshold history is kept'); END IF;
  IF NEW.cumulative_amount < OLD.cumulative_amount AND NEW.limit_amount = OLD.limit_amount THEN
    PERFORM core.raise_hk('HK_TAX_THRESHOLD_BACKWARD', 'cumulative sales only grow (cancellations are separate documents)');
  END IF;
  IF OLD.crossed_on IS NOT NULL AND NEW.crossed_on IS DISTINCT FROM OLD.crossed_on THEN
    PERFORM core.raise_hk('HK_TAX_THRESHOLD_IMMUTABLE', 'the crossing date is fixed once recorded');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON tax.threshold_monitor;
CREATE TRIGGER trg_guard BEFORE UPDATE OR DELETE ON tax.threshold_monitor FOR EACH ROW EXECUTE FUNCTION tax.threshold_guard();

-- اظهارنامهٔ فصلی ارزش افزوده (تطبیق: صورتحساب‌های ثبت‌شده ↔ دفتر کل ↔ «خلاصه عملکرد» کارپوشه)
CREATE TABLE IF NOT EXISTS tax.vat_return (
  tenant_id               uuid NOT NULL REFERENCES core.tenant(id),
  id                      uuid NOT NULL DEFAULT uuidv7(),
  company_id              uuid NOT NULL,
  period_key              text NOT NULL CHECK (period_key ~ '^jq:[0-9]{4}Q[1-4]$'),
  period_start            date NOT NULL,
  period_end              date NOT NULL,
  version                 smallint NOT NULL DEFAULT 1 CHECK (version BETWEEN 1 AND 50),
  status                  text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','computed','filed','superseded')),
  rule_snapshot_id        uuid,
  output_vat_registered   core.amount,          -- Σ tvam صورتحساب‌های ثبت‌شده (با علامت ابطالی/برگشت)
  output_vat_unregistered core.amount,          -- فروش‌های دوره که هنوز ثبت نشده‌اند (ریسک)
  output_vat_gl           core.amount,          -- گردش حساب‌های کلید tax.vat_payable در دوره
  input_vat_eligible      core.amount,
  input_vat_ineligible    core.amount,
  input_vat_gl            core.amount,
  other_tax_output        core.amount,
  portal_output_vat       core.amount,          -- ورود دستی از «خلاصه عملکرد» کارپوشه
  portal_input_credit     core.amount,
  payable_amount          core.amount,          -- output_vat_registered − input_vat_eligible
  computed_at             timestamptz,
  filed_at                timestamptz,
  filed_by                uuid,
  portal_tracking_no      text,
  settlement_journal_id   uuid,
  superseded_by           uuid,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  row_version             integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, company_id, period_key, version),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, rule_snapshot_id) REFERENCES rules.calc_snapshot(tenant_id, id),
  FOREIGN KEY (tenant_id, filed_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, company_id, settlement_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, superseded_by) REFERENCES tax.vat_return(tenant_id, company_id, id),
  CHECK (period_end > period_start),
  CONSTRAINT vat_return_computed CHECK (status = 'draft' OR (computed_at IS NOT NULL AND rule_snapshot_id IS NOT NULL
        AND num_nulls(output_vat_registered, output_vat_unregistered, output_vat_gl, input_vat_eligible, input_vat_ineligible,
                      input_vat_gl, other_tax_output, payable_amount) = 0)),
  CONSTRAINT vat_return_payable CHECK (payable_amount IS NULL OR payable_amount = output_vat_registered - input_vat_eligible),
  CONSTRAINT vat_return_filed CHECK ((status IN ('filed','superseded')) = (filed_at IS NOT NULL AND filed_by IS NOT NULL
        AND portal_output_vat IS NOT NULL AND portal_input_credit IS NOT NULL)),
  CONSTRAINT vat_return_superseded CHECK ((status = 'superseded') = (superseded_by IS NOT NULL))
);
SELECT core.enable_tenant_rls('tax.vat_return');
CREATE UNIQUE INDEX IF NOT EXISTS vat_return_one_filed ON tax.vat_return (tenant_id, company_id, period_key) WHERE status = 'filed';
CREATE UNIQUE INDEX IF NOT EXISTS vat_return_one_open ON tax.vat_return (tenant_id, company_id, period_key) WHERE status IN ('draft','computed');
DROP TRIGGER IF EXISTS trg_touch ON tax.vat_return;
CREATE TRIGGER trg_touch BEFORE UPDATE ON tax.vat_return FOR EACH ROW EXECUTE FUNCTION core.touch_row();

CREATE TABLE IF NOT EXISTS tax.vat_return_line (
  tenant_id       uuid NOT NULL REFERENCES core.tenant(id),
  id              uuid NOT NULL DEFAULT uuidv7(),
  vat_return_id   uuid NOT NULL,
  section         text NOT NULL CHECK (section IN ('output','input','other_tax','reconciliation')),
  category        text NOT NULL CHECK (category ~ '^[a-z][a-z0-9_.:-]{1,80}$'),   -- 'rate:10'، 'inv_type:1'، 'not_called_in'، ...
  base_amount     core.amount NOT NULL,
  vat_amount      core.amount NOT NULL,
  doc_count       integer NOT NULL CHECK (doc_count >= 0),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, vat_return_id, section, category),
  FOREIGN KEY (tenant_id, vat_return_id) REFERENCES tax.vat_return(tenant_id, id)
);
SELECT core.enable_tenant_rls('tax.vat_return_line');

CREATE OR REPLACE FUNCTION tax.vat_return_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_changed text[];
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN PERFORM core.raise_hk('HK_TAX_RETURN_IMMUTABLE', 'only draft returns can be deleted'); END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' THEN PERFORM core.raise_hk('HK_TAX_RETURN_TRANSITION', 'returns start as draft'); END IF;
    IF NEW.version > 1 AND NOT EXISTS (SELECT 1 FROM tax.vat_return r WHERE r.tenant_id = NEW.tenant_id AND r.company_id = NEW.company_id
                                          AND r.period_key = NEW.period_key AND r.version = NEW.version - 1 AND r.status = 'filed') THEN
      PERFORM core.raise_hk('HK_TAX_RETURN_AMEND', 'an amendment follows the filed previous version');
    END IF;
    RETURN NEW;
  END IF;
  v_changed := rules.changed_columns(to_jsonb(OLD), to_jsonb(NEW));
  IF OLD.status IN ('filed','superseded') AND NOT (OLD.status = 'filed' AND NEW.status = 'superseded'
        AND v_changed <@ ARRAY['status','superseded_by','updated_at','row_version']) THEN
    PERFORM core.raise_hk('HK_TAX_RETURN_IMMUTABLE', 'a filed return is amended by a new version');
  END IF;
  IF NEW.status <> OLD.status AND NOT ((OLD.status, NEW.status) IN
       (('draft','computed'),('computed','draft'),('computed','filed'),('filed','superseded'))) THEN
    PERFORM core.raise_hk('HK_TAX_RETURN_TRANSITION', format('%s → %s is not allowed', OLD.status, NEW.status));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON tax.vat_return;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON tax.vat_return FOR EACH ROW EXECUTE FUNCTION tax.vat_return_guard();

CREATE OR REPLACE FUNCTION tax.vat_return_line_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_status text;
BEGIN
  SELECT status INTO v_status FROM tax.vat_return WHERE tenant_id = coalesce(NEW.tenant_id, OLD.tenant_id)
     AND id = coalesce(NEW.vat_return_id, OLD.vat_return_id);
  IF v_status NOT IN ('draft','computed') THEN
    PERFORM core.raise_hk('HK_TAX_RETURN_IMMUTABLE', 'lines of a filed return cannot change');
  END IF;
  RETURN coalesce(NEW, OLD);
END $$;
DROP TRIGGER IF EXISTS trg_guard ON tax.vat_return_line;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON tax.vat_return_line FOR EACH ROW EXECUTE FUNCTION tax.vat_return_line_guard();

-- قفل دفتر خرید پس از درج در اظهارنامهٔ تسلیم‌شده
CREATE OR REPLACE FUNCTION tax.purchase_entry_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_status text; v_changed text[];
BEGIN
  IF TG_OP = 'DELETE' THEN PERFORM core.raise_hk('HK_TAX_PURCHASE_IMMUTABLE', 'register entries are reversed, never deleted'); END IF;
  IF TG_OP = 'UPDATE' THEN
    v_changed := rules.changed_columns(to_jsonb(OLD), to_jsonb(NEW));
    IF NOT (v_changed <@ ARRAY['moadian_taxid','moadian_inv_type','moadian_status','credit_eligibility','eligibility_reason',
                                'eligibility_snapshot_id','vat_return_id','updated_at','row_version']) THEN
      PERFORM core.raise_hk('HK_TAX_PURCHASE_IMMUTABLE', format('cannot change %s', array_to_string(v_changed, ',')));
    END IF;
    IF OLD.vat_return_id IS NOT NULL THEN
      SELECT status INTO v_status FROM tax.vat_return WHERE tenant_id = OLD.tenant_id AND id = OLD.vat_return_id;
      IF v_status IN ('filed','superseded') THEN
        PERFORM core.raise_hk('HK_TAX_PURCHASE_LOCKED', 'entry is part of a filed VAT return');
      END IF;
    END IF;
  END IF;
  IF NEW.vat_return_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM tax.vat_return r WHERE r.tenant_id = NEW.tenant_id
        AND r.id = NEW.vat_return_id AND r.company_id = NEW.company_id AND r.period_key = NEW.period_key) THEN
    PERFORM core.raise_hk('HK_TAX_PURCHASE_PERIOD', 'entry can only join the VAT return of its own company and quarter');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON tax.purchase_entry;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON tax.purchase_entry FOR EACH ROW EXECUTE FUNCTION tax.purchase_entry_guard();
DROP TRIGGER IF EXISTS trg_touch ON tax.purchase_entry;
CREATE TRIGGER trg_touch BEFORE UPDATE ON tax.purchase_entry FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- خروجی‌های قانونی دوره‌ای با قالب نسخه‌دار (فهرست معاملات ماده ۱۶۹، خلاصهٔ ارزش افزوده، دفاتر فروش/خرید)
CREATE TABLE IF NOT EXISTS tax.legal_report (
  tenant_id           uuid NOT NULL REFERENCES core.tenant(id),
  id                  uuid NOT NULL DEFAULT uuidv7(),
  company_id          uuid NOT NULL,
  report_kind         text NOT NULL CHECK (report_kind IN ('art169_quarterly','vat_summary','sales_register','purchase_register')),
  period_key          text NOT NULL CHECK (period_key ~ '^(jq:[0-9]{4}Q[1-4]|jy:[0-9]{4}|jm:[0-9]{4}-(0[1-9]|1[0-2]))$'),
  period_start        date NOT NULL,
  period_end          date NOT NULL,
  format_key          text NOT NULL REFERENCES rules.param_def(key),
  format_version      text NOT NULL CHECK (format_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,60}$'),
  rule_snapshot_id    uuid NOT NULL,
  status              text NOT NULL DEFAULT 'generated' CHECK (status IN ('generated','submitted','superseded')),
  row_count           integer NOT NULL CHECK (row_count >= 0),
  total_amount        core.amount NOT NULL,
  total_vat           core.amount NOT NULL,
  file_attachment_id  uuid NOT NULL,
  file_sha256         bytea NOT NULL CHECK (octet_length(file_sha256) = 32),
  generated_by        uuid,
  generated_at        timestamptz NOT NULL DEFAULT now(),
  submitted_at        timestamptz,
  submission_ref      text,
  superseded_by       uuid,
  updated_at          timestamptz NOT NULL DEFAULT now(),
  row_version         integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, rule_snapshot_id) REFERENCES rules.calc_snapshot(tenant_id, id),
  FOREIGN KEY (tenant_id, file_attachment_id) REFERENCES core.attachment(tenant_id, id),
  FOREIGN KEY (tenant_id, generated_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, company_id, superseded_by) REFERENCES tax.legal_report(tenant_id, company_id, id),
  CHECK (period_end > period_start),
  CHECK (split_part(format_key, '.', 1) = 'tax'),
  CHECK ((status = 'submitted') = (submitted_at IS NOT NULL AND submission_ref IS NOT NULL) OR status = 'superseded'),
  CHECK ((status = 'superseded') = (superseded_by IS NOT NULL))
);
SELECT core.enable_tenant_rls('tax.legal_report');
CREATE UNIQUE INDEX IF NOT EXISTS legal_report_one_submitted ON tax.legal_report (tenant_id, company_id, report_kind, period_key) WHERE status = 'submitted';

CREATE OR REPLACE FUNCTION tax.legal_report_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_changed text[];
BEGIN
  IF TG_OP = 'DELETE' THEN PERFORM core.raise_hk('HK_TAX_REPORT_IMMUTABLE', 'legal reports are superseded, never deleted'); END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'generated' THEN PERFORM core.raise_hk('HK_TAX_REPORT_TRANSITION', 'reports start generated'); END IF;
    RETURN NEW;
  END IF;
  v_changed := rules.changed_columns(to_jsonb(OLD), to_jsonb(NEW));
  IF NOT (v_changed <@ ARRAY['status','submitted_at','submission_ref','superseded_by','updated_at','row_version']) THEN
    PERFORM core.raise_hk('HK_TAX_REPORT_IMMUTABLE', format('cannot change %s', array_to_string(v_changed, ',')));
  END IF;
  IF NEW.status <> OLD.status AND NOT ((OLD.status, NEW.status) IN
       (('generated','submitted'),('generated','superseded'),('submitted','superseded'))) THEN
    PERFORM core.raise_hk('HK_TAX_REPORT_TRANSITION', format('%s → %s is not allowed', OLD.status, NEW.status));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON tax.legal_report;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON tax.legal_report FOR EACH ROW EXECUTE FUNCTION tax.legal_report_guard();

-- ویوی منتشرشده برای reports/pos/دستیار: وضعیت مؤدیان هر سند فروش (فقط خواندن)
CREATE OR REPLACE VIEW tax.v_sales_moadian_status WITH (security_invoker = true) AS
  SELECT t.tenant_id, t.company_id, t.sales_invoice_id, t.id AS tax_invoice_id, t.subject, t.inv_type, t.pattern, t.status AS doc_status,
         i.id AS issue_id, i.issue_no, i.taxid, i.status AS issue_status, i.send_deadline_at, i.success_at, i.buyer_reaction,
         i.failure_codes
    FROM tax.invoice t
    LEFT JOIN LATERAL (SELECT x.* FROM tax.invoice_issue x WHERE x.tenant_id = t.tenant_id AND x.invoice_id = t.id
                        ORDER BY x.issue_no DESC LIMIT 1) i ON true;

-- صف مهلت ۷ روزه (پایش): نسخه‌های ثبت‌نشده به ترتیب مهلت
CREATE OR REPLACE VIEW tax.v_send_deadline_queue WITH (security_invoker = true) AS
  SELECT i.tenant_id, i.company_id, i.id AS issue_id, i.invoice_id, i.memory_ref, i.taxid, i.status, i.indatim_ms,
         i.send_deadline_at, i.send_deadline_at - now() AS remaining
    FROM tax.invoice_issue i
   WHERE i.status IN ('prepared','signed','sent','unknown','not_received');

-- =====================================================================
-- ۱۱. payroll — کاتالوگ طبقه‌های قانونی اقلام (کدی). رفتار بیمه/مالیات هر طبقه تاریخ‌دار در rules
--     (کلید payroll.item_class.treatment با qualifier = code)؛ این‌جا فقط هویت طبقه.
-- =====================================================================
CREATE TABLE IF NOT EXISTS payroll.statutory_class (
  code             text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  kind             text NOT NULL CHECK (kind IN ('earning','deduction','info')),
  allows_negative  boolean NOT NULL DEFAULT false,      -- فقط تعدیل‌ها (مثلاً کسر کار)
  description_key  text NOT NULL,
  introduced_in    text NOT NULL
);

-- =====================================================================
-- ۱۲. payroll — کارگاه، کارمند، افراد تحت تکفل، قرارداد، حکم، تعریف اقلام
-- =====================================================================
CREATE TABLE IF NOT EXISTS payroll.workshop (
  tenant_id                uuid NOT NULL REFERENCES core.tenant(id),
  id                       uuid NOT NULL DEFAULT uuidv7(),
  company_id               uuid NOT NULL,
  branch_id                uuid,
  code                     text NOT NULL CHECK (code ~ '^[0-9]{10}$'),                -- DSK_ID کد کارگاه تأمین اجتماعی
  contract_row             text NOT NULL DEFAULT '000' CHECK (contract_row ~ '^[0-9]{3}$'),   -- MON_PYM ردیف پیمان
  name                     text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 100),
  employer_name            text NOT NULL CHECK (char_length(employer_name) BETWEEN 1 AND 100),
  address                  text NOT NULL CHECK (char_length(address) BETWEEN 1 AND 100),
  ssi_branch_code          text CHECK (ssi_branch_code ~ '^[0-9]{1,6}$'),
  tax_office_code          text CHECK (tax_office_code ~ '^[0-9]{1,10}$'),             -- حوزهٔ مالیاتی (پوشهٔ ZIP فایل حقوق)
  ssi_list_profile         text NOT NULL DEFAULT 'listdisk_6' CHECK (ssi_list_profile IN ('listdisk_2_7','listdisk_6')),
  ssi_code_page            text NOT NULL DEFAULT 'cp1256' CHECK (ssi_code_page IN ('cp1256','iran_system')),
  dsw_id1_width            smallint NOT NULL DEFAULT 10 CHECK (dsw_id1_width IN (8,10)),
  dsk_rate                 numeric(5,2) NOT NULL CHECK (dsk_rate BETWEEN 0 AND 100),  -- DSK_RATE (محل اختلاف؛ پارامتر کارگاه)
  salary_tax_format        text NOT NULL CHECK (salary_tax_format ~ '^[a-z0-9][a-z0-9._-]{1,40}$'),   -- qualifier قالب payroll.format.salary_tax
  include_wk_file          boolean NOT NULL DEFAULT true,
  is_hard_job_workshop     boolean NOT NULL DEFAULT false,
  status                   text NOT NULL DEFAULT 'active' CHECK (status IN ('active','closed')),
  opened_on                date NOT NULL,
  closed_on                date,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  row_version              integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, company_id, code, contract_row),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  CHECK ((status = 'closed') = (closed_on IS NOT NULL)),
  CHECK (closed_on IS NULL OR closed_on >= opened_on)
);
SELECT core.enable_tenant_rls('payroll.workshop');
DROP TRIGGER IF EXISTS trg_touch ON payroll.workshop;
CREATE TRIGGER trg_touch BEFORE UPDATE ON payroll.workshop FOR EACH ROW EXECUTE FUNCTION core.touch_row();

CREATE TABLE IF NOT EXISTS payroll.employee (
  tenant_id                 uuid NOT NULL REFERENCES core.tenant(id),
  id                        uuid NOT NULL DEFAULT uuidv7(),
  company_id                uuid NOT NULL,
  party_id                  uuid NOT NULL,                 -- شخص (نقش employee)؛ ماندهٔ شخصی روی بُعد party (CR-05 بخش ۰۴)
  employee_no               text NOT NULL CHECK (employee_no ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,19}$'),
  insurance_no              text CHECK (insurance_no ~ '^[0-9]{8,10}$'),            -- DSW_ID1
  ssi_job_code              text REFERENCES ref.ssi_job_code(code),                -- DSW_JOB
  job_title                 text CHECK (char_length(job_title) BETWEEN 1 AND 100),
  education_code            text CHECK (education_code ~ '^[0-9]{1,3}$'),          -- کد WP
  tax_exemption_code        text CHECK (tax_exemption_code ~ '^[0-9]{1,3}$'),      -- نوع معافیت WP
  employment_category_code  text CHECK (employment_category_code ~ '^[0-9]{1,3}$'),
  prior_ssi_days            integer NOT NULL DEFAULT 0 CHECK (prior_ssi_days >= 0),  -- سابقهٔ بیمه پیش از استخدام (شرط حق اولاد)
  prior_ssi_days_as_of      date,
  salary_bank_account_id    uuid,
  hire_date                 date NOT NULL,
  termination_date          date,
  termination_reason        text,
  status                    text NOT NULL DEFAULT 'active' CHECK (status IN ('active','terminated')),
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  row_version               integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, company_id, employee_no),
  UNIQUE (tenant_id, company_id, party_id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, salary_bank_account_id) REFERENCES parties.party_bank_account(tenant_id, id),
  CHECK ((status = 'terminated') = (termination_date IS NOT NULL AND termination_reason IS NOT NULL)),
  CHECK (termination_date IS NULL OR termination_date >= hire_date),
  CHECK ((prior_ssi_days > 0) <= (prior_ssi_days_as_of IS NOT NULL))
);
SELECT core.enable_tenant_rls('payroll.employee');
DROP TRIGGER IF EXISTS trg_touch ON payroll.employee;
CREATE TRIGGER trg_touch BEFORE UPDATE ON payroll.employee FOR EACH ROW EXECUTE FUNCTION core.touch_row();

CREATE OR REPLACE FUNCTION payroll.employee_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE p parties.party;
BEGIN
  SELECT * INTO p FROM parties.party WHERE tenant_id = NEW.tenant_id AND id = NEW.party_id;
  IF p.person_type NOT IN ('natural','foreign_natural') OR p.is_anonymous THEN
    PERFORM core.raise_hk('HK_PAYROLL_EMPLOYEE_PERSON', 'an employee must be an identified natural person');
  END IF;
  IF p.status = 'merged' THEN
    PERFORM core.raise_hk('HK_PAYROLL_EMPLOYEE_PERSON', 'party is merged; use the surviving party');
  END IF;
  IF p.person_type = 'natural' AND p.national_id IS NULL THEN
    PERFORM core.raise_hk('HK_PAYROLL_EMPLOYEE_NATIONAL_ID', 'an Iranian employee needs a national code (insurance list and WP)');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM parties.party_role r WHERE r.tenant_id = NEW.tenant_id AND r.party_id = NEW.party_id
                    AND r.role = 'employee' AND r.is_active AND (r.company_id IS NULL OR r.company_id = NEW.company_id)) THEN
    PERFORM core.raise_hk('HK_PAYROLL_EMPLOYEE_ROLE', 'party must have an active employee role');
  END IF;
  IF NEW.salary_bank_account_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM parties.party_bank_account b
        WHERE b.tenant_id = NEW.tenant_id AND b.id = NEW.salary_bank_account_id AND b.party_id = NEW.party_id AND b.is_active) THEN
    PERFORM core.raise_hk('HK_PAYROLL_BANK_ACCOUNT', 'salary account must be an active account of the same person');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON payroll.employee;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OF party_id, salary_bank_account_id ON payroll.employee
  FOR EACH ROW EXECUTE FUNCTION payroll.employee_guard();
DROP TRIGGER IF EXISTS trg_child_party ON payroll.employee;
CREATE TRIGGER trg_child_party BEFORE INSERT OR UPDATE OF party_id ON payroll.employee
  FOR EACH ROW EXECUTE FUNCTION parties.child_party_guard('party_id');

CREATE TABLE IF NOT EXISTS payroll.employee_dependent (
  tenant_id       uuid NOT NULL REFERENCES core.tenant(id),
  id              uuid NOT NULL DEFAULT uuidv7(),
  employee_id     uuid NOT NULL,
  relation        text NOT NULL CHECK (relation IN ('spouse','child')),
  full_name       text NOT NULL CHECK (char_length(full_name) BETWEEN 1 AND 200),
  national_id     text CHECK (national_id ~ '^[0-9]{10}$'),
  birth_date      date,
  is_student      boolean NOT NULL DEFAULT false,
  is_disabled     boolean NOT NULL DEFAULT false,
  valid_from      date NOT NULL,                       -- ازدواج/تولد/ثبت
  valid_to        date,                                -- طلاق/فوت/خروج از تکفل
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  row_version     integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, employee_id) REFERENCES payroll.employee(tenant_id, id),
  CHECK (valid_to IS NULL OR valid_to > valid_from),
  CHECK (relation <> 'child' OR birth_date IS NOT NULL),
  EXCLUDE USING gist (tenant_id WITH =, employee_id WITH =, daterange(valid_from, valid_to, '[)') WITH &&) WHERE (relation = 'spouse')
);
SELECT core.enable_tenant_rls('payroll.employee_dependent');
DROP TRIGGER IF EXISTS trg_touch ON payroll.employee_dependent;
CREATE TRIGGER trg_touch BEFORE UPDATE ON payroll.employee_dependent FOR EACH ROW EXECUTE FUNCTION core.touch_row();

CREATE TABLE IF NOT EXISTS payroll.contract (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  company_id        uuid NOT NULL,
  employee_id       uuid NOT NULL,
  workshop_id       uuid NOT NULL,
  contract_no       text NOT NULL CHECK (char_length(contract_no) BETWEEN 1 AND 40),
  kind              text NOT NULL CHECK (kind IN ('indefinite','fixed_term','project','probation')),
  employment_type   text NOT NULL CHECK (employment_type IN ('full_time','part_time','hourly')),
  weekly_hours      numeric(5,2) CHECK (weekly_hours > 0 AND weekly_hours <= 84),   -- پاره‌وقت: ساعت توافقی
  is_hard_job       boolean NOT NULL DEFAULT false,
  is_shift_worker   boolean NOT NULL DEFAULT false,
  start_date        date NOT NULL,
  end_date          date,                                   -- انحصاری
  status            text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','active','ended','cancelled')),
  signed_on         date,
  attachment_id     uuid,
  ended_reason      text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  row_version       integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, company_id, contract_no),
  FOREIGN KEY (tenant_id, company_id, employee_id) REFERENCES payroll.employee(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, workshop_id) REFERENCES payroll.workshop(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, attachment_id) REFERENCES core.attachment(tenant_id, id),
  CHECK (end_date IS NULL OR end_date > start_date),
  CHECK (kind = 'indefinite' OR end_date IS NOT NULL),
  CHECK ((employment_type = 'part_time') = (weekly_hours IS NOT NULL)),
  CHECK (status IN ('draft','cancelled') OR signed_on IS NOT NULL),
  CHECK ((status = 'ended') = (ended_reason IS NOT NULL)),
  -- یک قرارداد مؤثر در هر زمان برای هر کارمند
  EXCLUDE USING gist (tenant_id WITH =, employee_id WITH =, daterange(start_date, end_date, '[)') WITH &&) WHERE (status IN ('active','ended'))
);
SELECT core.enable_tenant_rls('payroll.contract');
DROP TRIGGER IF EXISTS trg_touch ON payroll.contract;
CREATE TRIGGER trg_touch BEFORE UPDATE ON payroll.contract FOR EACH ROW EXECUTE FUNCTION core.touch_row();

CREATE TABLE IF NOT EXISTS payroll.pay_item (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  company_id           uuid NOT NULL,
  code                 text NOT NULL CHECK (code ~ '^[A-Z][A-Z0-9_]{1,30}$'),
  name                 text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 100),
  statutory_class      text NOT NULL REFERENCES payroll.statutory_class(code),
  calc_method          text NOT NULL CHECK (calc_method IN ('decree_daily','decree_monthly','decree_hourly','attendance_rate',
                                                            'statutory','formula','manual_input','loan','accrual')),
  formula              text CHECK (char_length(formula) BETWEEN 1 AND 2000),        -- DSL امن (نه eval)؛ اعتبارسنجی در Python
  display_order        smallint NOT NULL DEFAULT 100,
  is_active            boolean NOT NULL DEFAULT true,
  source_pack          text,
  source_pack_version  text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, company_id, code),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  CHECK ((calc_method = 'formula') = (formula IS NOT NULL)),
  CHECK ((source_pack IS NULL) = (source_pack_version IS NULL))
);
SELECT core.enable_tenant_rls('payroll.pay_item');
DROP TRIGGER IF EXISTS trg_touch ON payroll.pay_item;
CREATE TRIGGER trg_touch BEFORE UPDATE ON payroll.pay_item FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- حکم کارگزینی (مزد و مزایای ثابت از تاریخ اثر). تأییدشده تغییرناپذیر؛ اصلاح = حکم تازه
CREATE TABLE IF NOT EXISTS payroll.decree (
  tenant_id                   uuid NOT NULL REFERENCES core.tenant(id),
  id                          uuid NOT NULL DEFAULT uuidv7(),
  company_id                  uuid NOT NULL,
  employee_id                 uuid NOT NULL,
  contract_id                 uuid NOT NULL,
  decree_no                   text NOT NULL CHECK (char_length(decree_no) BETWEEN 1 AND 40),
  effective_from              date NOT NULL,
  reason                      text NOT NULL CHECK (reason IN ('hire','annual_adjustment','promotion','correction','retroactive','termination','other')),
  wage_basis                  text NOT NULL CHECK (wage_basis IN ('daily','hourly')),
  daily_wage                  core.amount CHECK (daily_wage > 0),
  hourly_wage                 core.amount CHECK (hourly_wage > 0),
  last_prev_year_daily_wage   core.amount CHECK (last_prev_year_daily_wage > 0),   -- مبنای فرمول «سایر سطوح»
  seniority_bases_count       smallint NOT NULL DEFAULT 0 CHECK (seniority_bases_count >= 0),
  rule_snapshot_id            uuid,
  status                      text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','approved','superseded','cancelled')),
  approved_by                 uuid,
  approved_at                 timestamptz,
  superseded_by               uuid,
  created_by                  uuid,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  row_version                 integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, company_id, decree_no),
  FOREIGN KEY (tenant_id, company_id, employee_id) REFERENCES payroll.employee(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, contract_id) REFERENCES payroll.contract(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, rule_snapshot_id) REFERENCES rules.calc_snapshot(tenant_id, id),
  FOREIGN KEY (tenant_id, approved_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, company_id, superseded_by) REFERENCES payroll.decree(tenant_id, company_id, id),
  CHECK ((wage_basis = 'daily') = (daily_wage IS NOT NULL AND hourly_wage IS NULL)),
  CHECK ((wage_basis = 'hourly') = (hourly_wage IS NOT NULL AND daily_wage IS NULL)),
  CHECK ((status IN ('approved','superseded')) = (approved_by IS NOT NULL AND approved_at IS NOT NULL AND rule_snapshot_id IS NOT NULL)),
  CHECK ((status = 'superseded') = (superseded_by IS NOT NULL))
);
SELECT core.enable_tenant_rls('payroll.decree');
CREATE UNIQUE INDEX IF NOT EXISTS decree_one_approved ON payroll.decree (tenant_id, employee_id, effective_from) WHERE status = 'approved';

CREATE TABLE IF NOT EXISTS payroll.decree_item (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  company_id    uuid NOT NULL,
  decree_id     uuid NOT NULL,
  pay_item_id   uuid NOT NULL,
  basis         text NOT NULL CHECK (basis IN ('monthly','daily','hourly','percent_of_wage')),
  amount        core.amount NOT NULL CHECK (amount >= 0),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, decree_id, pay_item_id),
  FOREIGN KEY (tenant_id, company_id, decree_id) REFERENCES payroll.decree(tenant_id, company_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, company_id, pay_item_id) REFERENCES payroll.pay_item(tenant_id, company_id, id),
  CHECK (basis <> 'percent_of_wage' OR amount <= 1000)
);
SELECT core.enable_tenant_rls('payroll.decree_item');

-- کف قانونی مزد در تأیید حکم (مقدار مؤثر rules با جایگزین کارگاهی/پیمان دسته‌جمعی)
CREATE OR REPLACE FUNCTION payroll.decree_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE c payroll.contract; v_min jsonb; v_week jsonb; v_div jsonb; v_floor numeric; v_changed text[];
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN PERFORM core.raise_hk('HK_PAYROLL_DECREE_IMMUTABLE', 'only draft decrees can be deleted'); END IF;
    RETURN OLD;
  END IF;
  SELECT * INTO c FROM payroll.contract WHERE tenant_id = NEW.tenant_id AND id = NEW.contract_id;
  IF c.employee_id <> NEW.employee_id THEN
    PERFORM core.raise_hk('HK_PAYROLL_DECREE_CONTRACT', 'decree contract belongs to another employee');
  END IF;
  IF NEW.effective_from < c.start_date OR (c.end_date IS NOT NULL AND NEW.effective_from >= c.end_date) THEN
    PERFORM core.raise_hk('HK_PAYROLL_DECREE_CONTRACT', 'decree effective date must fall inside the contract');
  END IF;
  IF (c.employment_type = 'hourly') <> (NEW.wage_basis = 'hourly') THEN
    PERFORM core.raise_hk('HK_PAYROLL_DECREE_BASIS', 'hourly contracts use hourly decrees and vice versa');
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' THEN PERFORM core.raise_hk('HK_PAYROLL_DECREE_TRANSITION', 'decrees start as draft'); END IF;
    RETURN NEW;
  END IF;
  v_changed := rules.changed_columns(to_jsonb(OLD), to_jsonb(NEW));
  IF OLD.status <> 'draft' AND NOT (v_changed <@ ARRAY['status','superseded_by','updated_at','row_version']) THEN
    PERFORM core.raise_hk('HK_PAYROLL_DECREE_IMMUTABLE', 'an approved decree is replaced by a new decree');
  END IF;
  IF NEW.status <> OLD.status AND NOT ((OLD.status, NEW.status) IN
       (('draft','approved'),('draft','cancelled'),('approved','superseded'))) THEN
    PERFORM core.raise_hk('HK_PAYROLL_DECREE_TRANSITION', format('%s → %s is not allowed', OLD.status, NEW.status));
  END IF;
  IF NEW.status = 'approved' AND OLD.status = 'draft' THEN
    IF c.status <> 'active' THEN PERFORM core.raise_hk('HK_PAYROLL_DECREE_CONTRACT', 'contract is not active'); END IF;
    v_min := rules.effective_value('payroll.wage.min_daily', NEW.effective_from, '', NEW.company_id, c.workshop_id);
    IF v_min ->> 'unit' = 'IRR' THEN
      v_floor := (v_min ->> 'amount')::numeric;
      IF c.employment_type = 'part_time' THEN
        v_week := rules.effective_value('payroll.time.weekly_hours', NEW.effective_from, '', NEW.company_id, c.workshop_id);
        v_floor := v_floor * c.weekly_hours / (v_week ->> 'v')::numeric;
      ELSIF c.employment_type = 'hourly' THEN
        v_div := rules.effective_value('payroll.time.hourly_divisor', NEW.effective_from, '', NEW.company_id, c.workshop_id);
        v_floor := v_floor / (v_div ->> 'v')::numeric;
      END IF;
      IF coalesce(NEW.daily_wage, NEW.hourly_wage) < trunc(v_floor, 0) THEN
        PERFORM core.raise_hk('HK_PAYROLL_BELOW_MIN_WAGE',
          format('wage %s is below the statutory floor %s on %s', coalesce(NEW.daily_wage, NEW.hourly_wage), trunc(v_floor, 0), NEW.effective_from));
      END IF;
    END IF;
  END IF;
  IF NEW.status = 'superseded' AND NOT EXISTS (SELECT 1 FROM payroll.decree d WHERE d.tenant_id = NEW.tenant_id AND d.id = NEW.superseded_by
        AND d.employee_id = NEW.employee_id AND d.status = 'draft') THEN
    PERFORM core.raise_hk('HK_PAYROLL_DECREE_TRANSITION', 'superseded by a draft decree of the same employee being approved');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON payroll.decree;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON payroll.decree FOR EACH ROW EXECUTE FUNCTION payroll.decree_guard();
DROP TRIGGER IF EXISTS trg_touch ON payroll.decree;
CREATE TRIGGER trg_touch BEFORE UPDATE ON payroll.decree FOR EACH ROW EXECUTE FUNCTION core.touch_row();

CREATE OR REPLACE FUNCTION payroll.decree_item_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_status text;
BEGIN
  SELECT status INTO v_status FROM payroll.decree WHERE tenant_id = coalesce(NEW.tenant_id, OLD.tenant_id)
     AND id = coalesce(NEW.decree_id, OLD.decree_id);
  IF v_status IS DISTINCT FROM 'draft' AND NOT (TG_OP = 'DELETE' AND v_status IS NULL) THEN
    PERFORM core.raise_hk('HK_PAYROLL_DECREE_IMMUTABLE', 'items of an approved decree cannot change');
  END IF;
  RETURN coalesce(NEW, OLD);
END $$;
DROP TRIGGER IF EXISTS trg_guard ON payroll.decree_item;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON payroll.decree_item FOR EACH ROW EXECUTE FUNCTION payroll.decree_item_guard();

-- =====================================================================
-- ۱۳. payroll — حضور و غیاب: کارکرد ماهانه (Excel/دستی) و تردد خام ← موتور شیفت ← کارکرد روزانه
-- =====================================================================
CREATE TABLE IF NOT EXISTS payroll.attendance_import (
  tenant_id       uuid NOT NULL REFERENCES core.tenant(id),
  id              uuid NOT NULL DEFAULT uuidv7(),
  company_id      uuid NOT NULL,
  kind            text NOT NULL CHECK (kind IN ('monthly_excel','clock_file')),
  attachment_id   uuid NOT NULL,
  file_sha256     bytea NOT NULL CHECK (octet_length(file_sha256) = 32),
  profile         jsonb NOT NULL CHECK (jsonb_typeof(profile) = 'object'),   -- نگاشت ستون/جداکننده/کد وضعیت
  row_count       integer NOT NULL DEFAULT 0 CHECK (row_count >= 0),
  error_count     integer NOT NULL DEFAULT 0 CHECK (error_count >= 0),
  errors          jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(errors) = 'array'),
  status          text NOT NULL DEFAULT 'uploaded' CHECK (status IN ('uploaded','parsed','failed')),
  uploaded_by     uuid,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, kind, file_sha256),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, attachment_id) REFERENCES core.attachment(tenant_id, id),
  FOREIGN KEY (tenant_id, uploaded_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (error_count <= row_count)
);
SELECT core.enable_tenant_rls('payroll.attendance_import');

CREATE TABLE IF NOT EXISTS payroll.clock_device (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  company_id   uuid NOT NULL,
  code         text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$'),
  vendor       text NOT NULL CHECK (vendor IN ('zkteco','other')),
  serial_no    text,
  ingest_mode  text NOT NULL DEFAULT 'file' CHECK (ingest_mode IN ('file','adms_push','agent_pull')),   -- push/pull: v2
  is_active    boolean NOT NULL DEFAULT true,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, code),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id)
);
SELECT core.enable_tenant_rls('payroll.clock_device');

CREATE TABLE IF NOT EXISTS payroll.clock_user_map (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  device_id         uuid NOT NULL,
  device_user_code  text NOT NULL CHECK (device_user_code ~ '^[A-Za-z0-9_-]{1,30}$'),
  employee_id       uuid NOT NULL,
  valid_from        date NOT NULL,
  valid_to          date,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, device_id) REFERENCES payroll.clock_device(tenant_id, id),
  FOREIGN KEY (tenant_id, employee_id) REFERENCES payroll.employee(tenant_id, id),
  CHECK (valid_to IS NULL OR valid_to > valid_from),
  EXCLUDE USING gist (tenant_id WITH =, device_id WITH =, device_user_code WITH =, daterange(valid_from, valid_to, '[)') WITH &&)
);
SELECT core.enable_tenant_rls('payroll.clock_user_map');

-- تردد خام (فقط‌افزودنی؛ تکرار ورود یک فایل اثر ندارد)
CREATE TABLE IF NOT EXISTS payroll.clock_event (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  device_id         uuid NOT NULL,
  device_user_code  text NOT NULL,
  punched_at        timestamptz NOT NULL,
  state             text NOT NULL CHECK (state IN ('in','out','break_out','break_in','overtime_in','overtime_out','unknown')),
  verify_method     text,
  import_id         uuid,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, device_id, device_user_code, punched_at),
  FOREIGN KEY (tenant_id, device_id) REFERENCES payroll.clock_device(tenant_id, id),
  FOREIGN KEY (tenant_id, import_id) REFERENCES payroll.attendance_import(tenant_id, id)
);
SELECT core.enable_tenant_rls('payroll.clock_event');
DROP TRIGGER IF EXISTS trg_immutable ON payroll.clock_event;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON payroll.clock_event FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

CREATE TABLE IF NOT EXISTS payroll.shift_def (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL DEFAULT uuidv7(),
  company_id         uuid NOT NULL,
  code               text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,19}$'),
  name               text NOT NULL,
  start_time         time NOT NULL,
  end_time           time NOT NULL,                     -- اگر ≤ start_time یعنی عبور از نیمه‌شب
  break_minutes      smallint NOT NULL DEFAULT 0 CHECK (break_minutes BETWEEN 0 AND 600),
  grace_in_minutes   smallint NOT NULL DEFAULT 0 CHECK (grace_in_minutes BETWEEN 0 AND 120),
  grace_out_minutes  smallint NOT NULL DEFAULT 0 CHECK (grace_out_minutes BETWEEN 0 AND 120),
  rounding_minutes   smallint NOT NULL DEFAULT 1 CHECK (rounding_minutes IN (1,5,10,15,30)),
  shift_kind         text NOT NULL DEFAULT 'fixed' CHECK (shift_kind IN ('fixed','rotating_me','rotating_men','rotating_mn_en')),
  is_active          boolean NOT NULL DEFAULT true,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, code),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  CHECK (start_time <> end_time)
);
SELECT core.enable_tenant_rls('payroll.shift_def');

CREATE TABLE IF NOT EXISTS payroll.shift_assignment (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  employee_id   uuid NOT NULL,
  pattern       jsonb NOT NULL CHECK (jsonb_typeof(pattern) = 'array' AND jsonb_array_length(pattern) BETWEEN 1 AND 62),  -- [shift_def_id|null] چرخه
  cycle_anchor  date NOT NULL,
  valid_from    date NOT NULL,
  valid_to      date,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, employee_id) REFERENCES payroll.employee(tenant_id, id),
  CHECK (valid_to IS NULL OR valid_to > valid_from),
  EXCLUDE USING gist (tenant_id WITH =, employee_id WITH =, daterange(valid_from, valid_to, '[)') WITH &&)
);
SELECT core.enable_tenant_rls('payroll.shift_assignment');

-- خروجی موتور شیفت (روزانه؛ کاربر پیش از تجمیع ماهانه بازبینی/اصلاح می‌کند)
CREATE TABLE IF NOT EXISTS payroll.attendance_day (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL DEFAULT uuidv7(),
  employee_id        uuid NOT NULL,
  work_date          date NOT NULL,
  shift_def_id       uuid,
  first_in           timestamptz,
  last_out           timestamptz,
  worked_minutes     integer NOT NULL DEFAULT 0 CHECK (worked_minutes BETWEEN 0 AND 1440),
  overtime_minutes   integer NOT NULL DEFAULT 0 CHECK (overtime_minutes BETWEEN 0 AND 1440),
  night_minutes      integer NOT NULL DEFAULT 0 CHECK (night_minutes BETWEEN 0 AND 1440),
  late_minutes       integer NOT NULL DEFAULT 0 CHECK (late_minutes BETWEEN 0 AND 1440),
  early_out_minutes  integer NOT NULL DEFAULT 0 CHECK (early_out_minutes BETWEEN 0 AND 1440),
  day_kind           text NOT NULL CHECK (day_kind IN ('work','friday','holiday','leave','sick','absent','mission','off')),
  status             text NOT NULL DEFAULT 'computed' CHECK (status IN ('computed','edited','confirmed')),
  anomalies          jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(anomalies) = 'array'),
  edited_by          uuid,
  engine_version     text NOT NULL,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, employee_id, work_date),
  FOREIGN KEY (tenant_id, employee_id) REFERENCES payroll.employee(tenant_id, id),
  FOREIGN KEY (tenant_id, shift_def_id) REFERENCES payroll.shift_def(tenant_id, id),
  FOREIGN KEY (tenant_id, edited_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (first_in IS NULL OR last_out IS NULL OR last_out > first_in),
  CHECK ((status = 'edited') <= (edited_by IS NOT NULL)),
  CHECK (overtime_minutes <= worked_minutes AND night_minutes <= worked_minutes)
);
SELECT core.enable_tenant_rls('payroll.attendance_day');

-- کارکرد ماهانه (ورودی اجرای حقوق؛ منبع: دستی، Excel، موتور شیفت یا مهاجرت)
CREATE TABLE IF NOT EXISTS payroll.attendance_summary (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL DEFAULT uuidv7(),
  company_id         uuid NOT NULL,
  workshop_id        uuid NOT NULL,
  employee_id        uuid NOT NULL,
  period_key         text NOT NULL CHECK (period_key ~ '^jm:[0-9]{4}-(0[1-9]|1[0-2])$'),
  period_start       date NOT NULL,
  period_end         date NOT NULL,
  calendar_days      smallint NOT NULL CHECK (calendar_days BETWEEN 28 AND 31),
  work_days          numeric(5,2) NOT NULL DEFAULT 0 CHECK (work_days >= 0),
  paid_leave_days    numeric(5,2) NOT NULL DEFAULT 0 CHECK (paid_leave_days >= 0),
  paid_leave_hours   numeric(6,2) NOT NULL DEFAULT 0 CHECK (paid_leave_hours >= 0),
  sick_days          numeric(5,2) NOT NULL DEFAULT 0 CHECK (sick_days >= 0),
  unpaid_leave_days  numeric(5,2) NOT NULL DEFAULT 0 CHECK (unpaid_leave_days >= 0),
  absence_days       numeric(5,2) NOT NULL DEFAULT 0 CHECK (absence_days >= 0),
  mission_days       numeric(5,2) NOT NULL DEFAULT 0 CHECK (mission_days >= 0),
  hours_worked       numeric(7,2) NOT NULL DEFAULT 0 CHECK (hours_worked >= 0),     -- کارکنان ساعتی
  overtime_hours     numeric(6,2) NOT NULL DEFAULT 0 CHECK (overtime_hours >= 0),
  night_hours        numeric(6,2) NOT NULL DEFAULT 0 CHECK (night_hours >= 0),
  friday_hours       numeric(6,2) NOT NULL DEFAULT 0 CHECK (friday_hours >= 0),
  holiday_hours      numeric(6,2) NOT NULL DEFAULT 0 CHECK (holiday_hours >= 0),
  shortage_hours     numeric(6,2) NOT NULL DEFAULT 0 CHECK (shortage_hours >= 0),
  shift_pattern      text NOT NULL DEFAULT 'none' CHECK (shift_pattern IN ('none','me','men','mn_en')),
  source             text NOT NULL CHECK (source IN ('manual','excel','shift_engine','migration')),
  import_id          uuid,
  status             text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','confirmed')),
  confirmed_by       uuid,
  confirmed_at       timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  row_version        integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, employee_id, period_key),
  FOREIGN KEY (tenant_id, company_id, workshop_id) REFERENCES payroll.workshop(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, employee_id) REFERENCES payroll.employee(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, import_id) REFERENCES payroll.attendance_import(tenant_id, id),
  FOREIGN KEY (tenant_id, confirmed_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (period_end >= period_start AND period_end - period_start + 1 = calendar_days),
  CHECK (work_days + paid_leave_days + sick_days + unpaid_leave_days + absence_days <= calendar_days),
  CHECK ((source = 'excel') <= (import_id IS NOT NULL)),
  CHECK ((status = 'confirmed') = (confirmed_by IS NOT NULL AND confirmed_at IS NOT NULL))
);
SELECT core.enable_tenant_rls('payroll.attendance_summary');
DROP TRIGGER IF EXISTS trg_touch ON payroll.attendance_summary;
CREATE TRIGGER trg_touch BEFORE UPDATE ON payroll.attendance_summary FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- =====================================================================
-- ۱۴. payroll — اجرای حقوق، فیش، سطر فیش (snapshot قواعد؛ پس از تأیید تغییرناپذیر)
-- =====================================================================
-- مالیات پلکانی از جدول snapshot‌شده: rows = [{"from":"0","to":"400000000","rate":"0"}, …] (to = null ⇒ باز)
CREATE OR REPLACE FUNCTION payroll.bracket_tax(p_income numeric, p_rows jsonb) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(sum(greatest(0, least(p_income, coalesce((r ->> 'to')::numeric, p_income)) - (r ->> 'from')::numeric)
                      * (r ->> 'rate')::numeric), 0)
    FROM jsonb_array_elements(p_rows) r
$$;

CREATE TABLE IF NOT EXISTS payroll.run (
  tenant_id               uuid NOT NULL REFERENCES core.tenant(id),
  id                      uuid NOT NULL DEFAULT uuidv7(),
  company_id              uuid NOT NULL,
  workshop_id             uuid NOT NULL,
  kind                    text NOT NULL CHECK (kind IN ('regular','retro_difference','eidi','settlement','off_cycle')),
  period_key              text NOT NULL CHECK (period_key ~ '^jm:[0-9]{4}-(0[1-9]|1[0-2])$'),
  period_start            date NOT NULL,
  period_end              date NOT NULL,
  payment_date            date NOT NULL,
  status                  text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','calculated','approved','posted','cancelled')),
  rule_snapshot_id        uuid,
  engine_version          text CHECK (engine_version ~ '^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$'),
  employee_count          integer NOT NULL DEFAULT 0 CHECK (employee_count >= 0),
  gross_total             core.amount NOT NULL DEFAULT 0,
  ssi_employee_total      core.amount NOT NULL DEFAULT 0,
  ssi_employer_total      core.amount NOT NULL DEFAULT 0,
  unemployment_total      core.amount NOT NULL DEFAULT 0,
  hard_job_ssi_total      core.amount NOT NULL DEFAULT 0,
  tax_total               core.amount NOT NULL DEFAULT 0,
  deduction_total         core.amount NOT NULL DEFAULT 0,
  net_total               core.amount NOT NULL DEFAULT 0,
  calculated_by           uuid,
  calculated_at           timestamptz,
  approved_by             uuid,
  approved_at             timestamptz,
  self_approval_reason    text,                    -- تفکیک وظایف: تأییدکننده = محاسبه‌گر فقط با دلیل ثبت‌شده
  low_confidence_ack_by   uuid,                    -- پذیرش صریح پارامترهای با اطمینان پایین/تأییدنشده
  gl_journal_id           uuid,
  posted_at               timestamptz,
  cancel_journal_id       uuid,
  cancelled_at            timestamptz,
  cancel_reason           text,
  retro_proposal_id       uuid,                    -- اجرای مابه‌التفاوت ← پیشنهاد بازمحاسبهٔ rules
  base_run_id             uuid,                    -- اجرای اصلیِ مابه‌التفاوت/تسویه
  payment_status          text NOT NULL DEFAULT 'unpaid' CHECK (payment_status IN ('unpaid','partial','paid')),
  created_by              uuid,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  row_version             integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, workshop_id) REFERENCES payroll.workshop(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, rule_snapshot_id) REFERENCES rules.calc_snapshot(tenant_id, id),
  FOREIGN KEY (tenant_id, calculated_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, approved_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, low_confidence_ack_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, company_id, gl_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, cancel_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, retro_proposal_id) REFERENCES rules.recalc_proposal(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, base_run_id) REFERENCES payroll.run(tenant_id, company_id, id),
  CHECK (period_end >= period_start AND payment_date >= period_start),
  CONSTRAINT run_net CHECK (net_total = gross_total - ssi_employee_total - tax_total - deduction_total),
  CONSTRAINT run_calculated CHECK (status IN ('draft','cancelled') OR (rule_snapshot_id IS NOT NULL AND engine_version IS NOT NULL
                                    AND calculated_by IS NOT NULL AND calculated_at IS NOT NULL)),
  CONSTRAINT run_approved CHECK ((status IN ('approved','posted')) <= (approved_by IS NOT NULL AND approved_at IS NOT NULL)),
  CONSTRAINT run_sod CHECK (approved_by IS NULL OR approved_by <> calculated_by
                            OR char_length(btrim(coalesce(self_approval_reason, ''))) >= 10),
  CONSTRAINT run_posted CHECK ((status = 'posted') <= (gl_journal_id IS NOT NULL AND posted_at IS NOT NULL)),
  CONSTRAINT run_cancelled CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL AND cancel_reason IS NOT NULL)
                                  AND (status <> 'cancelled' OR gl_journal_id IS NULL OR cancel_journal_id IS NOT NULL)),
  CONSTRAINT run_retro CHECK ((kind = 'retro_difference') = (retro_proposal_id IS NOT NULL)
                              AND (kind NOT IN ('retro_difference','settlement') OR base_run_id IS NOT NULL OR kind = 'settlement'))
);
SELECT core.enable_tenant_rls('payroll.run');
CREATE UNIQUE INDEX IF NOT EXISTS run_one_regular ON payroll.run (tenant_id, workshop_id, period_key)
  WHERE kind = 'regular' AND status <> 'cancelled';
DROP TRIGGER IF EXISTS trg_touch ON payroll.run;
CREATE TRIGGER trg_touch BEFORE UPDATE ON payroll.run FOR EACH ROW EXECUTE FUNCTION core.touch_row();

CREATE TABLE IF NOT EXISTS payroll.payslip (
  tenant_id              uuid NOT NULL REFERENCES core.tenant(id),
  id                     uuid NOT NULL DEFAULT uuidv7(),
  company_id             uuid NOT NULL,
  run_id                 uuid NOT NULL,
  employee_id            uuid NOT NULL,
  contract_id            uuid NOT NULL,
  decree_id              uuid NOT NULL,
  calendar_days          smallint NOT NULL CHECK (calendar_days BETWEEN 1 AND 31),
  paid_days              numeric(5,2) NOT NULL CHECK (paid_days >= 0),
  insurance_days         smallint NOT NULL CHECK (insurance_days >= 0),            -- DSW_DD
  daily_wage             core.amount NOT NULL CHECK (daily_wage >= 0),             -- DSW_ROOZ
  monthly_wage           core.amount NOT NULL CHECK (monthly_wage >= 0),           -- DSW_MAH
  gross_earnings         core.amount NOT NULL,
  insurable_raw          core.amount NOT NULL CHECK (insurable_raw >= 0),
  insurable_benefits     core.amount NOT NULL CHECK (insurable_benefits >= 0),     -- DSW_MAZ
  ssi_cap_amount         core.amount NOT NULL CHECK (ssi_cap_amount > 0),
  ssi_base               core.amount NOT NULL CHECK (ssi_base >= 0),               -- DSW_MASH (سقف‌خورده)
  ssi_rounding           text NOT NULL CHECK (ssi_rounding IN ('half_up','truncate','half_even')),
  ssi_employee_rate      core.rate NOT NULL CHECK (ssi_employee_rate >= 0 AND ssi_employee_rate < 1),
  ssi_employee           core.amount NOT NULL,                                     -- DSW_BIME
  ssi_employer_rate      core.rate NOT NULL CHECK (ssi_employer_rate >= 0 AND ssi_employer_rate < 1),
  ssi_employer           core.amount NOT NULL,
  unemployment_rate      core.rate NOT NULL CHECK (unemployment_rate >= 0 AND unemployment_rate < 1),
  unemployment           core.amount NOT NULL,
  hard_job_rate          core.rate NOT NULL DEFAULT 0 CHECK (hard_job_rate >= 0 AND hard_job_rate < 1),
  hard_job_ssi           core.amount NOT NULL DEFAULT 0,
  total_paid_all         core.amount NOT NULL CHECK (total_paid_all >= 0),         -- DSW_TOTL (مشمول + غیرمشمول)
  taxable_income         core.amount NOT NULL CHECK (taxable_income >= 0),         -- مبنای پلکانی ماه
  tax_exempt_amount      core.amount NOT NULL DEFAULT 0 CHECK (tax_exempt_amount >= 0),
  flat_tax_amount        core.amount NOT NULL DEFAULT 0 CHECK (flat_tax_amount >= 0),
  salary_tax             core.amount NOT NULL CHECK (salary_tax >= 0),
  other_deductions       core.amount NOT NULL DEFAULT 0 CHECK (other_deductions >= 0),
  net_pay                core.amount NOT NULL,
  payment_doc_ref        uuid,                                                     -- treasury (FK در 99_cross_fk)
  payment_status         text NOT NULL DEFAULT 'unpaid' CHECK (payment_status IN ('unpaid','paid')),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, run_id, employee_id),
  FOREIGN KEY (tenant_id, company_id, run_id) REFERENCES payroll.run(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, employee_id) REFERENCES payroll.employee(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, contract_id) REFERENCES payroll.contract(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, decree_id) REFERENCES payroll.decree(tenant_id, company_id, id),
  CONSTRAINT payslip_days CHECK (insurance_days <= calendar_days AND paid_days <= calendar_days),
  CONSTRAINT payslip_monthly_wage CHECK (monthly_wage = daily_wage * insurance_days),
  CONSTRAINT payslip_benefits CHECK (insurable_benefits = insurable_raw - monthly_wage),
  CONSTRAINT payslip_ssi_base CHECK (ssi_base = least(insurable_raw, ssi_cap_amount)),
  CONSTRAINT payslip_ssi_amounts CHECK (
        ssi_employee = ledger.round_amount(ssi_base * ssi_employee_rate, 0::smallint, ssi_rounding)
    AND ssi_employer = ledger.round_amount(ssi_base * ssi_employer_rate, 0::smallint, ssi_rounding)
    AND unemployment = ledger.round_amount(ssi_base * unemployment_rate, 0::smallint, ssi_rounding)
    AND hard_job_ssi = ledger.round_amount(ssi_base * hard_job_rate, 0::smallint, ssi_rounding)),
  CONSTRAINT payslip_total_paid CHECK (total_paid_all >= insurable_raw),
  CONSTRAINT payslip_net CHECK (net_pay = gross_earnings - ssi_employee - salary_tax - other_deductions AND net_pay >= 0),
  CONSTRAINT payslip_paid CHECK ((payment_status = 'paid') = (payment_doc_ref IS NOT NULL))
);
SELECT core.enable_tenant_rls('payroll.payslip');

CREATE TABLE IF NOT EXISTS payroll.loan (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  company_id           uuid NOT NULL,
  employee_id          uuid NOT NULL,
  kind                 text NOT NULL CHECK (kind IN ('loan','advance')),     -- وام / مساعده
  principal            core.amount NOT NULL CHECK (principal > 0),
  installment_count    smallint NOT NULL CHECK (installment_count BETWEEN 1 AND 120),
  start_period_key     text NOT NULL CHECK (start_period_key ~ '^jm:[0-9]{4}-(0[1-9]|1[0-2])$'),
  status               text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','active','settled','cancelled')),
  disbursement_ref     uuid,                         -- treasury (FK در 99_cross_fk)
  approved_by          uuid,
  approved_at          timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, employee_id) REFERENCES payroll.employee(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, approved_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK ((status IN ('active','settled')) <= (approved_by IS NOT NULL AND approved_at IS NOT NULL)),
  CHECK (kind <> 'advance' OR installment_count = 1)
);
SELECT core.enable_tenant_rls('payroll.loan');
DROP TRIGGER IF EXISTS trg_touch ON payroll.loan;
CREATE TRIGGER trg_touch BEFORE UPDATE ON payroll.loan FOR EACH ROW EXECUTE FUNCTION core.touch_row();

CREATE TABLE IF NOT EXISTS payroll.loan_installment (
  tenant_id      uuid NOT NULL REFERENCES core.tenant(id),
  id             uuid NOT NULL DEFAULT uuidv7(),
  loan_id        uuid NOT NULL,
  seq            smallint NOT NULL CHECK (seq >= 1),
  period_key     text NOT NULL CHECK (period_key ~ '^jm:[0-9]{4}-(0[1-9]|1[0-2])$'),
  amount         core.amount NOT NULL CHECK (amount > 0),
  status         text NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled','deducted','deferred','waived')),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, loan_id, seq),
  FOREIGN KEY (tenant_id, loan_id) REFERENCES payroll.loan(tenant_id, id)
);
SELECT core.enable_tenant_rls('payroll.loan_installment');

CREATE TABLE IF NOT EXISTS payroll.payslip_line (
  tenant_id              uuid NOT NULL REFERENCES core.tenant(id),
  id                     uuid NOT NULL DEFAULT uuidv7(),
  payslip_id             uuid NOT NULL,
  line_no                smallint NOT NULL CHECK (line_no BETWEEN 1 AND 500),
  pay_item_id            uuid,
  statutory_class        text NOT NULL REFERENCES payroll.statutory_class(code),
  kind                   text NOT NULL CHECK (kind IN ('earning','deduction','info')),
  quantity               numeric(12,4),
  rate                   core.rate,
  amount                 core.amount NOT NULL,
  -- snapshot رفتار قانونی همان تاریخ (از rules.payroll.item_class.treatment)
  ssi_insurable          boolean NOT NULL,
  tax_treatment          text NOT NULL CHECK (tax_treatment IN ('progressive','flat','exempt','exempt_up_to','exempt_within_customary_limit','not_applicable')),
  is_continuous          boolean NOT NULL,
  is_cash                boolean NOT NULL,
  wh_column              text CHECK (wh_column ~ '^[a-z][a-z0-9_]{1,40}$'),
  dsk_bucket             text NOT NULL CHECK (dsk_bucket IN ('ROOZ','MAZ','INC','SPOUSE','NONINSURABLE','NONE')),
  source                 text NOT NULL CHECK (source IN ('decree','attendance','statutory','loan','manual','retro','accrual')),
  loan_installment_id    uuid,
  retro_of_payslip_id    uuid,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, payslip_id, line_no),
  UNIQUE (tenant_id, loan_installment_id),
  FOREIGN KEY (tenant_id, payslip_id) REFERENCES payroll.payslip(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, pay_item_id) REFERENCES payroll.pay_item(tenant_id, id),
  FOREIGN KEY (tenant_id, loan_installment_id) REFERENCES payroll.loan_installment(tenant_id, id),
  FOREIGN KEY (tenant_id, retro_of_payslip_id) REFERENCES payroll.payslip(tenant_id, id),
  CHECK ((source = 'loan') = (loan_installment_id IS NOT NULL)),
  CHECK ((source = 'retro') = (retro_of_payslip_id IS NOT NULL)),
  CHECK (kind = 'earning' OR NOT ssi_insurable),
  CHECK (kind <> 'deduction' OR amount > 0),
  CHECK (ssi_insurable = (dsk_bucket IN ('ROOZ','MAZ','INC','SPOUSE')) OR kind <> 'earning')
);
SELECT core.enable_tenant_rls('payroll.payslip_line');

-- محتوای فیش فقط وقتی اجرا در draft/calculated است تغییر می‌کند
CREATE OR REPLACE FUNCTION payroll.payslip_content_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_status text; v_run uuid; v_changed text[];
BEGIN
  IF TG_TABLE_NAME = 'payslip' THEN
    v_run := coalesce(NEW.run_id, OLD.run_id);
  ELSE
    SELECT run_id INTO v_run FROM payroll.payslip WHERE tenant_id = coalesce(NEW.tenant_id, OLD.tenant_id)
       AND id = coalesce(NEW.payslip_id, OLD.payslip_id);
  END IF;
  SELECT status INTO v_status FROM payroll.run WHERE tenant_id = coalesce(NEW.tenant_id, OLD.tenant_id) AND id = v_run;
  IF v_status IN ('draft','calculated') OR (TG_OP = 'DELETE' AND v_status IS NULL) THEN
    RETURN coalesce(NEW, OLD);
  END IF;
  -- پس از تأیید فقط وضعیت پرداخت فیش
  IF TG_TABLE_NAME = 'payslip' AND TG_OP = 'UPDATE' THEN
    v_changed := rules.changed_columns(to_jsonb(OLD), to_jsonb(NEW));
    IF v_changed <@ ARRAY['payment_doc_ref','payment_status'] AND v_status IN ('approved','posted') THEN
      RETURN NEW;
    END IF;
  END IF;
  PERFORM core.raise_hk('HK_PAYROLL_RUN_IMMUTABLE', format('payslips of a %s run cannot change', v_status));
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON payroll.payslip;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON payroll.payslip FOR EACH ROW EXECUTE FUNCTION payroll.payslip_content_guard();
DROP TRIGGER IF EXISTS trg_guard ON payroll.payslip_line;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON payroll.payslip_line FOR EACH ROW EXECUTE FUNCTION payroll.payslip_content_guard();

-- راستی‌آزمایی deferred فیش: جمع سطرها، علامت‌ها، قسط وام، و مالیات پلکانی از snapshot اجرا
CREATE OR REPLACE FUNCTION payroll.payslip_verify() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE s payroll.payslip; r payroll.run; t record; v_rows jsonb; v_mode text; v_expected numeric; v_id uuid;
BEGIN
  IF TG_TABLE_NAME = 'payslip' THEN v_id := NEW.id; ELSE v_id := NEW.payslip_id; END IF;
  SELECT * INTO s FROM payroll.payslip WHERE tenant_id = NEW.tenant_id AND id = v_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO r FROM payroll.run WHERE tenant_id = s.tenant_id AND id = s.run_id;
  SELECT coalesce(sum(l.amount) FILTER (WHERE l.kind = 'earning'), 0) AS gross,
         coalesce(sum(l.amount) FILTER (WHERE l.kind = 'earning' AND l.ssi_insurable), 0) AS insurable,
         coalesce(sum(l.amount) FILTER (WHERE l.kind = 'deduction'), 0) AS deductions,
         count(*) FILTER (WHERE l.amount < 0 AND NOT c.allows_negative) AS bad_negative,
         count(*) FILTER (WHERE l.kind <> c.kind) AS bad_kind
    INTO t
    FROM payroll.payslip_line l JOIN payroll.statutory_class c ON c.code = l.statutory_class
   WHERE l.tenant_id = s.tenant_id AND l.payslip_id = s.id;
  IF t.bad_negative > 0 OR t.bad_kind > 0 THEN
    PERFORM core.raise_hk('HK_PAYROLL_LINE_CLASS', 'line kind/sign does not match its statutory class');
  END IF;
  IF (t.gross, t.insurable, t.deductions) IS DISTINCT FROM (s.gross_earnings, s.insurable_raw, s.other_deductions) THEN
    PERFORM core.raise_hk('HK_PAYROLL_PAYSLIP_TOTALS', format('payslip totals differ from its lines (gross %s vs %s)', s.gross_earnings, t.gross));
  END IF;
  IF EXISTS (SELECT 1 FROM payroll.payslip_line l JOIN payroll.loan_installment i ON i.tenant_id = l.tenant_id AND i.id = l.loan_installment_id
                JOIN payroll.loan n ON n.tenant_id = i.tenant_id AND n.id = i.loan_id
              WHERE l.tenant_id = s.tenant_id AND l.payslip_id = s.id
                AND (l.amount <> i.amount OR n.employee_id <> s.employee_id OR n.status <> 'active' OR l.kind <> 'deduction')) THEN
    PERFORM core.raise_hk('HK_PAYROLL_LOAN_LINE', 'loan deduction must equal the installment of an active loan of the same employee');
  END IF;
  IF r.kind IN ('regular','settlement','off_cycle','eidi') THEN
    SELECT c.content -> 'payroll.tax.brackets_monthly' -> '_' -> 'rows', c.content -> 'payroll.tax.rounding' -> '_' ->> 'v'
      INTO v_rows, v_mode FROM rules.calc_snapshot c WHERE c.tenant_id = r.tenant_id AND c.id = r.rule_snapshot_id;
    IF v_rows IS NULL OR v_mode IS NULL THEN
      PERFORM core.raise_hk('HK_PAYROLL_SNAPSHOT_INCOMPLETE', 'run snapshot lacks payroll.tax.brackets_monthly / payroll.tax.rounding');
    END IF;
    v_expected := ledger.round_amount(payroll.bracket_tax(s.taxable_income, v_rows), 0::smallint, v_mode) + s.flat_tax_amount;
    IF s.salary_tax <> v_expected THEN
      PERFORM core.raise_hk('HK_PAYROLL_TAX_MISMATCH', format('salary tax %s differs from the snapshot brackets (%s)', s.salary_tax, v_expected));
    END IF;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_verify ON payroll.payslip;
CREATE CONSTRAINT TRIGGER trg_verify AFTER INSERT OR UPDATE ON payroll.payslip
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION payroll.payslip_verify();
DROP TRIGGER IF EXISTS trg_verify ON payroll.payslip_line;
CREATE CONSTRAINT TRIGGER trg_verify AFTER INSERT OR UPDATE ON payroll.payslip_line
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION payroll.payslip_verify();

CREATE OR REPLACE FUNCTION payroll.run_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_changed text[]; t record; snap rules.calc_snapshot;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN PERFORM core.raise_hk('HK_PAYROLL_RUN_IMMUTABLE', 'only draft runs can be deleted'); END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' THEN PERFORM core.raise_hk('HK_PAYROLL_RUN_TRANSITION', 'runs start as draft'); END IF;
    RETURN NEW;
  END IF;
  v_changed := rules.changed_columns(to_jsonb(OLD), to_jsonb(NEW));
  IF OLD.status IN ('approved','posted','cancelled') AND NOT (v_changed <@ ARRAY['status','gl_journal_id','posted_at','cancel_journal_id',
        'cancelled_at','cancel_reason','payment_status','updated_at','row_version']) THEN
    PERFORM core.raise_hk('HK_PAYROLL_RUN_IMMUTABLE', format('cannot change %s on a %s run', array_to_string(v_changed, ','), OLD.status));
  END IF;
  IF NEW.status = OLD.status THEN RETURN NEW; END IF;
  IF NOT ((OLD.status, NEW.status) IN (('draft','calculated'),('calculated','draft'),('calculated','approved'),('approved','posted'),
                                        ('approved','cancelled'),('posted','cancelled'),('calculated','cancelled'))) THEN
    PERFORM core.raise_hk('HK_PAYROLL_RUN_TRANSITION', format('%s → %s is not allowed', OLD.status, NEW.status));
  END IF;
  IF NEW.status = 'calculated' OR NEW.status = 'approved' THEN
    SELECT count(*) AS n, coalesce(sum(gross_earnings),0) AS gross, coalesce(sum(ssi_employee),0) AS ssi_e,
           coalesce(sum(ssi_employer),0) AS ssi_r, coalesce(sum(unemployment),0) AS unemp, coalesce(sum(hard_job_ssi),0) AS hard,
           coalesce(sum(salary_tax),0) AS tax, coalesce(sum(other_deductions),0) AS ded, coalesce(sum(net_pay),0) AS net
      INTO t FROM payroll.payslip WHERE tenant_id = NEW.tenant_id AND run_id = NEW.id;
    IF t.n = 0 OR (t.n, t.gross, t.ssi_e, t.ssi_r, t.unemp, t.hard, t.tax, t.ded, t.net) IS DISTINCT FROM
       (NEW.employee_count::bigint, NEW.gross_total, NEW.ssi_employee_total, NEW.ssi_employer_total, NEW.unemployment_total,
        NEW.hard_job_ssi_total, NEW.tax_total, NEW.deduction_total, NEW.net_total) THEN
      PERFORM core.raise_hk('HK_PAYROLL_RUN_TOTALS', 'run totals must equal the sum of its payslips');
    END IF;
  END IF;
  IF NEW.status = 'approved' THEN
    SELECT * INTO snap FROM rules.calc_snapshot WHERE tenant_id = NEW.tenant_id AND id = NEW.rule_snapshot_id;
    IF snap.engine_version <> NEW.engine_version THEN
      PERFORM core.raise_hk('HK_PAYROLL_ENGINE_MISMATCH', 'run engine version must equal the snapshot engine version');
    END IF;
    IF NOT rules.snapshot_golden_ok(NEW.rule_snapshot_id, NEW.engine_version) THEN
      PERFORM core.raise_hk('HK_PAYROLL_GOLDEN_NOT_PASSED', 'a rule package used by this run has no passing golden run on this engine version');
    END IF;
    IF snap.min_confidence IN ('low','unverified') AND NEW.low_confidence_ack_by IS NULL THEN
      PERFORM core.raise_hk('HK_PAYROLL_LOW_CONFIDENCE', 'run uses low-confidence/unverified parameters; explicit acknowledgment required');
    END IF;
    IF NEW.kind = 'regular' AND EXISTS (SELECT 1 FROM payroll.payslip p
          LEFT JOIN payroll.attendance_summary a ON a.tenant_id = p.tenant_id AND a.employee_id = p.employee_id AND a.period_key = NEW.period_key
         WHERE p.tenant_id = NEW.tenant_id AND p.run_id = NEW.id AND a.status IS DISTINCT FROM 'confirmed') THEN
      PERFORM core.raise_hk('HK_PAYROLL_ATTENDANCE_UNCONFIRMED', 'every payslip of a regular run needs confirmed attendance');
    END IF;
  END IF;
  IF NEW.status = 'cancelled' AND char_length(btrim(coalesce(NEW.cancel_reason, ''))) < 10 THEN
    PERFORM core.raise_hk('HK_PAYROLL_REASON_REQUIRED', 'cancelling a run needs a reason of at least 10 characters');
  END IF;
  IF NEW.status = 'cancelled' AND EXISTS (SELECT 1 FROM payroll.gov_file g WHERE g.tenant_id = NEW.tenant_id AND g.run_id = NEW.id
        AND g.status IN ('uploaded','accepted')) THEN
    PERFORM core.raise_hk('HK_PAYROLL_RUN_FILED', 'government files of this run were uploaded; issue a corrective list instead');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON payroll.run;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON payroll.run FOR EACH ROW EXECUTE FUNCTION payroll.run_guard();

-- کارکرد تأییدشده‌ای که در اجرای تأییدشده مصرف شده تغییر نمی‌کند
CREATE OR REPLACE FUNCTION payroll.attendance_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM payroll.payslip p JOIN payroll.run r ON r.tenant_id = p.tenant_id AND r.id = p.run_id
              WHERE p.tenant_id = OLD.tenant_id AND p.employee_id = OLD.employee_id AND r.period_key = OLD.period_key
                AND r.kind = 'regular' AND r.status IN ('approved','posted')) THEN
    PERFORM core.raise_hk('HK_PAYROLL_ATTENDANCE_LOCKED', 'attendance used by an approved run is locked (use a retro/off-cycle run)');
  END IF;
  RETURN coalesce(NEW, OLD);
END $$;
DROP TRIGGER IF EXISTS trg_guard ON payroll.attendance_summary;
CREATE TRIGGER trg_guard BEFORE UPDATE OR DELETE ON payroll.attendance_summary FOR EACH ROW EXECUTE FUNCTION payroll.attendance_guard();

-- اقساط: جمع = اصل وام؛ پس از فعال شدن فقط وضعیت قسط
CREATE OR REPLACE FUNCTION payroll.loan_verify() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE l payroll.loan; v_sum numeric; v_n int; v_id uuid;
BEGIN
  IF TG_TABLE_NAME = 'loan' THEN v_id := NEW.id; ELSE v_id := NEW.loan_id; END IF;
  SELECT * INTO l FROM payroll.loan WHERE tenant_id = NEW.tenant_id AND id = v_id;
  IF NOT FOUND OR l.status IN ('draft','cancelled') THEN RETURN NULL; END IF;
  SELECT coalesce(sum(amount), 0), count(*) INTO v_sum, v_n FROM payroll.loan_installment
   WHERE tenant_id = l.tenant_id AND loan_id = l.id AND status <> 'waived';
  IF v_sum <> l.principal AND NOT EXISTS (SELECT 1 FROM payroll.loan_installment WHERE tenant_id = l.tenant_id AND loan_id = l.id AND status = 'waived') THEN
    PERFORM core.raise_hk('HK_PAYROLL_LOAN_SCHEDULE', format('installments sum %s differs from principal %s', v_sum, l.principal));
  END IF;
  IF l.status = 'settled' AND EXISTS (SELECT 1 FROM payroll.loan_installment WHERE tenant_id = l.tenant_id AND loan_id = l.id
                                          AND status IN ('scheduled','deferred')) THEN
    PERFORM core.raise_hk('HK_PAYROLL_LOAN_SCHEDULE', 'a settled loan has no open installments');
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_verify ON payroll.loan;
CREATE CONSTRAINT TRIGGER trg_verify AFTER INSERT OR UPDATE ON payroll.loan
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION payroll.loan_verify();
DROP TRIGGER IF EXISTS trg_verify ON payroll.loan_installment;
CREATE CONSTRAINT TRIGGER trg_verify AFTER INSERT OR UPDATE ON payroll.loan_installment
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION payroll.loan_verify();

CREATE OR REPLACE FUNCTION payroll.loan_installment_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_status text;
BEGIN
  SELECT status INTO v_status FROM payroll.loan WHERE tenant_id = coalesce(NEW.tenant_id, OLD.tenant_id) AND id = coalesce(NEW.loan_id, OLD.loan_id);
  IF v_status <> 'draft' THEN
    IF TG_OP = 'DELETE' OR TG_OP = 'INSERT' OR rules.changed_columns(to_jsonb(OLD), to_jsonb(NEW)) <> ARRAY['status'] THEN
      PERFORM core.raise_hk('HK_PAYROLL_LOAN_IMMUTABLE', 'schedule of an active loan only changes installment status');
    END IF;
  END IF;
  RETURN coalesce(NEW, OLD);
END $$;
DROP TRIGGER IF EXISTS trg_guard ON payroll.loan_installment;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON payroll.loan_installment FOR EACH ROW EXECUTE FUNCTION payroll.loan_installment_guard();

-- =====================================================================
-- ۱۵. payroll — ذخایر (عیدی، سنوات)، دفتر مرخصی، فایل‌های دولتی
-- =====================================================================
CREATE TABLE IF NOT EXISTS payroll.accrual_entry (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  company_id        uuid NOT NULL,
  employee_id       uuid NOT NULL,
  kind              text NOT NULL CHECK (kind IN ('eidi','severance')),
  entry_type        text NOT NULL CHECK (entry_type IN ('provision','payment','reversal','opening')),
  period_key        text NOT NULL CHECK (period_key ~ '^jm:[0-9]{4}-(0[1-9]|1[0-2])$'),
  work_year         smallint NOT NULL CHECK (work_year BETWEEN 1390 AND 1500),   -- سال کارکرد (نه سال پرداخت)
  amount            core.amount NOT NULL,                                       -- ذخیره +، پرداخت/برگشت −
  run_id            uuid,
  rule_snapshot_id  uuid,
  basis             jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, employee_id) REFERENCES payroll.employee(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, run_id) REFERENCES payroll.run(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, rule_snapshot_id) REFERENCES rules.calc_snapshot(tenant_id, id),
  CHECK ((entry_type IN ('provision','opening')) = (amount > 0)),
  CHECK (entry_type = 'opening' OR run_id IS NOT NULL),
  CHECK (entry_type <> 'provision' OR rule_snapshot_id IS NOT NULL)
);
SELECT core.enable_tenant_rls('payroll.accrual_entry');
DROP TRIGGER IF EXISTS trg_immutable ON payroll.accrual_entry;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON payroll.accrual_entry FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

CREATE TABLE IF NOT EXISTS payroll.leave_entry (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  employee_id   uuid NOT NULL,
  entry_type    text NOT NULL CHECK (entry_type IN ('accrual','usage','carryover_lapse','payout','opening','adjustment')),
  leave_year    smallint NOT NULL CHECK (leave_year BETWEEN 1390 AND 1500),
  days          numeric(7,3) NOT NULL CHECK (days <> 0),
  period_key    text CHECK (period_key ~ '^jm:[0-9]{4}-(0[1-9]|1[0-2])$'),
  source        text NOT NULL CHECK (source IN ('run','attendance','manual','migration')),
  run_id        uuid,
  reason        text,
  created_by    uuid,
  created_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, employee_id) REFERENCES payroll.employee(tenant_id, id),
  FOREIGN KEY (tenant_id, run_id) REFERENCES payroll.run(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK ((entry_type IN ('accrual','opening')) <= (days > 0)),
  CHECK ((entry_type IN ('usage','carryover_lapse','payout')) <= (days < 0)),
  CHECK ((entry_type = 'adjustment') <= (char_length(btrim(coalesce(reason, ''))) >= 5)),
  CHECK ((source = 'run') = (run_id IS NOT NULL))
);
SELECT core.enable_tenant_rls('payroll.leave_entry');
DROP TRIGGER IF EXISTS trg_immutable ON payroll.leave_entry;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON payroll.leave_entry FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

CREATE OR REPLACE VIEW payroll.v_leave_balance WITH (security_invoker = true) AS
  SELECT tenant_id, employee_id, leave_year, sum(days) AS balance_days, count(*) AS entries
    FROM payroll.leave_entry GROUP BY tenant_id, employee_id, leave_year;

CREATE OR REPLACE VIEW payroll.v_accrual_balance WITH (security_invoker = true) AS
  SELECT tenant_id, company_id, employee_id, kind, work_year, sum(amount) AS balance
    FROM payroll.accrual_entry GROUP BY tenant_id, company_id, employee_id, kind, work_year;

-- فایل‌های دولتی (لیست بیمه DBF، فایل‌های WP/WH/WK) برای بارگذاری دستی؛ محتوا تغییرناپذیر
CREATE TABLE IF NOT EXISTS payroll.gov_file (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  company_id       uuid NOT NULL,
  workshop_id      uuid NOT NULL,
  run_id           uuid NOT NULL,
  kind             text NOT NULL CHECK (kind IN ('ssi_list','salary_tax')),
  format_key       text NOT NULL REFERENCES rules.param_def(key),
  format_version   text NOT NULL CHECK (format_version ~ '^[a-z0-9][a-z0-9._-]{1,40}$'),    -- listdisk_6، wh-1.7 …
  code_page        text CHECK (code_page IN ('cp1256','iran_system','utf-8')),
  list_no          text CHECK (list_no ~ '^[0-9]{1,12}$'),                 -- DSK_LISTNO (لیست اصلی/اصلاحی)
  rule_snapshot_id uuid NOT NULL,
  control_totals   jsonb NOT NULL CHECK (jsonb_typeof(control_totals) = 'object'),
  status           text NOT NULL DEFAULT 'generated' CHECK (status IN ('generated','uploaded','accepted','rejected','superseded')),
  portal_ref       text,
  generated_by     uuid,
  generated_at     timestamptz NOT NULL DEFAULT now(),
  uploaded_at      timestamptz,
  superseded_by    uuid,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  row_version      integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, workshop_id) REFERENCES payroll.workshop(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, run_id) REFERENCES payroll.run(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, rule_snapshot_id) REFERENCES rules.calc_snapshot(tenant_id, id),
  FOREIGN KEY (tenant_id, generated_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, company_id, superseded_by) REFERENCES payroll.gov_file(tenant_id, company_id, id),
  CHECK (format_key = CASE kind WHEN 'ssi_list' THEN 'payroll.format.ssi_list' ELSE 'payroll.format.salary_tax' END),
  CHECK ((kind = 'ssi_list') = (code_page IN ('cp1256','iran_system') AND list_no IS NOT NULL)),
  CHECK ((status IN ('uploaded','accepted','rejected')) <= (uploaded_at IS NOT NULL)),
  CHECK ((status = 'superseded') = (superseded_by IS NOT NULL))
);
SELECT core.enable_tenant_rls('payroll.gov_file');
CREATE UNIQUE INDEX IF NOT EXISTS gov_file_one_uploaded ON payroll.gov_file (tenant_id, run_id, kind) WHERE status IN ('uploaded','accepted');

CREATE TABLE IF NOT EXISTS payroll.gov_file_part (
  tenant_id      uuid NOT NULL REFERENCES core.tenant(id),
  id             uuid NOT NULL DEFAULT uuidv7(),
  gov_file_id    uuid NOT NULL,
  file_name      text NOT NULL CHECK (file_name ~ '^(DSKKAR00\.DBF|DSKWOR00\.DBF|W[PHK][0-9]{6}\.txt|[A-Za-z0-9_.-]{1,60}\.(zip|xlsx))$'),
  attachment_id  uuid NOT NULL,
  sha256         bytea NOT NULL CHECK (octet_length(sha256) = 32),
  byte_size      bigint NOT NULL CHECK (byte_size > 0),
  record_count   integer NOT NULL CHECK (record_count >= 0),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, gov_file_id, file_name),
  FOREIGN KEY (tenant_id, gov_file_id) REFERENCES payroll.gov_file(tenant_id, id),
  FOREIGN KEY (tenant_id, attachment_id) REFERENCES core.attachment(tenant_id, id)
);
SELECT core.enable_tenant_rls('payroll.gov_file_part');
DROP TRIGGER IF EXISTS trg_immutable ON payroll.gov_file_part;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON payroll.gov_file_part FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

-- مقادیر کنترلی فایل = جمع فیش‌های اجرای تأییدشده (TDD، TMASH، TBIME، TKOSO+BIC، تعداد؛ مالیات)
CREATE OR REPLACE FUNCTION payroll.gov_file_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE r payroll.run; t record; v_changed text[];
BEGIN
  IF TG_OP = 'DELETE' THEN PERFORM core.raise_hk('HK_PAYROLL_FILE_IMMUTABLE', 'government files are superseded, never deleted'); END IF;
  IF TG_OP = 'UPDATE' THEN
    v_changed := rules.changed_columns(to_jsonb(OLD), to_jsonb(NEW));
    IF NOT (v_changed <@ ARRAY['status','portal_ref','uploaded_at','superseded_by','updated_at','row_version']) THEN
      PERFORM core.raise_hk('HK_PAYROLL_FILE_IMMUTABLE', format('cannot change %s', array_to_string(v_changed, ',')));
    END IF;
    IF NEW.status <> OLD.status AND NOT ((OLD.status, NEW.status) IN (('generated','uploaded'),('uploaded','accepted'),
          ('uploaded','rejected'),('generated','superseded'),('rejected','superseded'),('uploaded','superseded'))) THEN
      PERFORM core.raise_hk('HK_PAYROLL_FILE_TRANSITION', format('%s → %s is not allowed', OLD.status, NEW.status));
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.status <> 'generated' THEN PERFORM core.raise_hk('HK_PAYROLL_FILE_TRANSITION', 'files start generated'); END IF;
  SELECT * INTO r FROM payroll.run WHERE tenant_id = NEW.tenant_id AND id = NEW.run_id;
  IF r.status NOT IN ('approved','posted') OR r.workshop_id <> NEW.workshop_id THEN
    PERFORM core.raise_hk('HK_PAYROLL_FILE_RUN', 'files are generated only from an approved run of the same workshop');
  END IF;
  SELECT count(*) FILTER (WHERE insurance_days > 0) AS num, coalesce(sum(insurance_days),0) AS tdd, coalesce(sum(ssi_base),0) AS tmash,
         coalesce(sum(ssi_employee),0) AS tbime, coalesce(sum(ssi_employer),0) AS tkoso, coalesce(sum(unemployment),0) AS bic,
         coalesce(sum(salary_tax),0) AS tax, count(*) AS n
    INTO t FROM payroll.payslip WHERE tenant_id = NEW.tenant_id AND run_id = NEW.run_id;
  IF NEW.kind = 'ssi_list' AND ((NEW.control_totals ->> 'DSK_NUM')::numeric, (NEW.control_totals ->> 'DSK_TDD')::numeric,
        (NEW.control_totals ->> 'DSK_TMASH')::numeric, (NEW.control_totals ->> 'DSK_TBIME')::numeric,
        (NEW.control_totals ->> 'DSK_TKOSO')::numeric, (NEW.control_totals ->> 'DSK_BIC')::numeric)
        IS DISTINCT FROM (t.num::numeric, t.tdd::numeric, t.tmash, t.tbime, t.tkoso, t.bic) THEN
    PERFORM core.raise_hk('HK_PAYROLL_FILE_TOTALS', 'insurance list control totals differ from the approved payslips');
  END IF;
  IF NEW.kind = 'salary_tax' AND ((NEW.control_totals ->> 'tax_total')::numeric, (NEW.control_totals ->> 'employees')::numeric)
        IS DISTINCT FROM (t.tax, t.n::numeric) THEN
    PERFORM core.raise_hk('HK_PAYROLL_FILE_TOTALS', 'salary tax file control totals differ from the approved payslips');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON payroll.gov_file;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON payroll.gov_file FOR EACH ROW EXECUTE FUNCTION payroll.gov_file_guard();

-- =====================================================================
-- ۱۶. assets — دارایی ثابت: طبقه، دفترها (حسابداری/مالیاتی)، دارایی، پلاک، دفتر هر دارایی
-- =====================================================================
CREATE TABLE IF NOT EXISTS assets.asset_class (
  tenant_id               uuid NOT NULL REFERENCES core.tenant(id),
  id                      uuid NOT NULL DEFAULT uuidv7(),
  company_id              uuid NOT NULL,
  code                    text NOT NULL CHECK (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,19}$'),
  name                    text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 100),
  is_land                 boolean NOT NULL DEFAULT false,
  default_method          text NOT NULL CHECK (default_method IN ('straight_line','declining_balance','none')),
  default_life_months     smallint CHECK (default_life_months BETWEEN 1 AND 1200),
  default_declining_rate  numeric(7,4) CHECK (default_declining_rate > 0 AND default_declining_rate <= 100),
  tax_class_code          text CHECK (tax_class_code ~ '^[A-Za-z0-9._-]{1,40}$'),   -- ردیف جدول نسخه‌دار assets.art149.classes
  posting_group_code      text NOT NULL CHECK (posting_group_code ~ '^[A-Za-z0-9._-]{1,40}$'),   -- attr:asset_group برای قواعد GL
  is_active               boolean NOT NULL DEFAULT true,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, company_id, code),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  CHECK (NOT is_land OR default_method = 'none'),
  CHECK ((default_method = 'straight_line') = (default_life_months IS NOT NULL)),
  CHECK ((default_method = 'declining_balance') = (default_declining_rate IS NOT NULL))
);
SELECT core.enable_tenant_rls('assets.asset_class');

CREATE TABLE IF NOT EXISTS assets.book (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  company_id   uuid NOT NULL,
  code         text NOT NULL CHECK (code ~ '^[A-Z][A-Z0-9_]{0,19}$'),
  name         text NOT NULL,
  kind         text NOT NULL CHECK (kind IN ('accounting','tax','combined')),
  posts_to_gl  boolean NOT NULL,
  is_active    boolean NOT NULL DEFAULT true,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, company_id, code),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  CHECK ((kind = 'tax') = NOT posts_to_gl)          -- دفتر مالیاتی فقط حافظه است؛ حسابداری/ترکیبی ثبت GL دارد
);
SELECT core.enable_tenant_rls('assets.book');
CREATE UNIQUE INDEX IF NOT EXISTS book_one_gl ON assets.book (tenant_id, company_id) WHERE posts_to_gl AND is_active;
CREATE UNIQUE INDEX IF NOT EXISTS book_one_tax ON assets.book (tenant_id, company_id) WHERE kind IN ('tax','combined') AND is_active;

CREATE TABLE IF NOT EXISTS assets.asset (
  tenant_id              uuid NOT NULL REFERENCES core.tenant(id),
  id                     uuid NOT NULL DEFAULT uuidv7(),
  company_id             uuid NOT NULL,
  branch_id              uuid,
  class_id               uuid NOT NULL,
  tag_no                 text NOT NULL CHECK (tag_no ~ '^[A-Za-z0-9][A-Za-z0-9._/-]{0,29}$'),   -- پلاک جاری
  name                   text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 200),
  serial_no              text,
  location               text,
  is_land                boolean NOT NULL DEFAULT false,
  acquisition_date       date NOT NULL,
  available_date         date,                                    -- آماده‌به‌کار (مبدأ قاعدهٔ شروع استهلاک)
  acquisition_cost       core.amount NOT NULL CHECK (acquisition_cost > 0),
  supplier_party_id      uuid,
  custodian_party_id     uuid,
  source_module          text CHECK (source_module IN ('purchase','migration','manual','inventory')),
  source_doc_id          uuid,
  dimension_value_id     uuid,                                    -- بُعد fixed_asset در دفتر کل
  legacy_code            text,
  status                 text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','active','disposed','cancelled')),
  activated_at           timestamptz,
  disposed_on            date,
  created_by             uuid,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  row_version            integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, company_id, tag_no),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, class_id) REFERENCES assets.asset_class(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, supplier_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, custodian_party_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, dimension_value_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (available_date IS NULL OR available_date >= acquisition_date),
  CHECK (status IN ('draft','cancelled') OR (activated_at IS NOT NULL AND available_date IS NOT NULL)),
  CHECK ((status = 'disposed') = (disposed_on IS NOT NULL)),
  CHECK (disposed_on IS NULL OR disposed_on >= acquisition_date)
);
SELECT core.enable_tenant_rls('assets.asset');
DROP TRIGGER IF EXISTS trg_touch ON assets.asset;
CREATE TRIGGER trg_touch BEFORE UPDATE ON assets.asset FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- تاریخچهٔ پلاک (تعویض پلاک فرسوده/گم‌شده)
CREATE TABLE IF NOT EXISTS assets.asset_tag (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  company_id    uuid NOT NULL,
  asset_id      uuid NOT NULL,
  tag_no        text NOT NULL CHECK (tag_no ~ '^[A-Za-z0-9][A-Za-z0-9._/-]{0,29}$'),
  barcode       text CHECK (barcode ~ '^[0-9A-Za-z-]{4,48}$'),
  assigned_on   date NOT NULL,
  retired_on    date,
  retire_reason text,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, asset_id) REFERENCES assets.asset(tenant_id, company_id, id),
  CHECK ((retired_on IS NULL) = (retire_reason IS NULL)),
  CHECK (retired_on IS NULL OR retired_on >= assigned_on)
);
SELECT core.enable_tenant_rls('assets.asset_tag');
CREATE UNIQUE INDEX IF NOT EXISTS asset_tag_active_uq ON assets.asset_tag (tenant_id, company_id, tag_no) WHERE retired_on IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS asset_tag_one_active ON assets.asset_tag (tenant_id, asset_id) WHERE retired_on IS NULL;

CREATE TABLE IF NOT EXISTS assets.asset_book (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  company_id           uuid NOT NULL,
  asset_id             uuid NOT NULL,
  book_id              uuid NOT NULL,
  method               text NOT NULL CHECK (method IN ('straight_line','declining_balance','none')),
  useful_life_months   smallint CHECK (useful_life_months BETWEEN 1 AND 1200),
  declining_rate       numeric(7,4) CHECK (declining_rate > 0 AND declining_rate <= 100),   -- درصد سالانه روی ارزش دفتری اول سال
  salvage_value        core.amount NOT NULL DEFAULT 0 CHECK (salvage_value >= 0),
  depreciation_start   date,                         -- حاصل قاعدهٔ پارامتری assets.depreciation.start_rule (snapshot)
  start_rule           text CHECK (start_rule IN ('available_date','first_day_next_month')),
  tax_class_code       text,
  tax_table_value_id   uuid REFERENCES rules.param_value(id),     -- نسخهٔ جدول ماده ۱۴۹ که روش/نرخ از آن آمده
  rule_snapshot_id     uuid,
  status               text NOT NULL DEFAULT 'active' CHECK (status IN ('active','fully_depreciated','disposed','suspended')),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, asset_id, book_id),
  FOREIGN KEY (tenant_id, company_id, asset_id) REFERENCES assets.asset(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, book_id) REFERENCES assets.book(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, rule_snapshot_id) REFERENCES rules.calc_snapshot(tenant_id, id),
  CONSTRAINT asset_book_method CHECK (
       (method = 'straight_line' AND useful_life_months IS NOT NULL AND declining_rate IS NULL)
    OR (method = 'declining_balance' AND declining_rate IS NOT NULL AND useful_life_months IS NULL)
    OR (method = 'none' AND useful_life_months IS NULL AND declining_rate IS NULL)),
  CONSTRAINT asset_book_start CHECK ((method = 'none') = (depreciation_start IS NULL) AND (depreciation_start IS NULL) = (start_rule IS NULL)
                                     AND (method = 'none' OR rule_snapshot_id IS NOT NULL))
);
SELECT core.enable_tenant_rls('assets.asset_book');
DROP TRIGGER IF EXISTS trg_touch ON assets.asset_book;
CREATE TRIGGER trg_touch BEFORE UPDATE ON assets.asset_book FOR EACH ROW EXECUTE FUNCTION core.touch_row();

CREATE OR REPLACE FUNCTION assets.asset_book_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE a assets.asset; b assets.book; v_changed text[]; v_key text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF EXISTS (SELECT 1 FROM assets.asset_txn t WHERE t.tenant_id = OLD.tenant_id AND t.asset_book_id = OLD.id) THEN
      PERFORM core.raise_hk('HK_ASSETS_BOOK_IN_USE', 'an asset book with transactions cannot be deleted');
    END IF;
    RETURN OLD;
  END IF;
  SELECT * INTO a FROM assets.asset WHERE tenant_id = NEW.tenant_id AND id = NEW.asset_id;
  SELECT * INTO b FROM assets.book WHERE tenant_id = NEW.tenant_id AND id = NEW.book_id;
  IF a.is_land AND NEW.method <> 'none' THEN
    PERFORM core.raise_hk('HK_ASSETS_LAND_NOT_DEPRECIABLE', 'land is not depreciable');
  END IF;
  IF NEW.depreciation_start IS NOT NULL AND (a.available_date IS NULL OR NEW.depreciation_start < a.available_date) THEN
    PERFORM core.raise_hk('HK_ASSETS_START_BEFORE_AVAILABLE', 'depreciation cannot start before the asset is available for use');
  END IF;
  IF b.kind IN ('tax','combined') AND NEW.method <> 'none' THEN
    SELECT key INTO v_key FROM rules.param_value WHERE id = NEW.tax_table_value_id;
    IF NEW.tax_class_code IS NULL OR v_key IS DISTINCT FROM 'assets.art149.classes' THEN
      PERFORM core.raise_hk('HK_ASSETS_TAX_CLASS_REQUIRED', 'tax book needs a class from a versioned Article 149 table value');
    END IF;
  END IF;
  IF TG_OP = 'UPDATE' AND EXISTS (SELECT 1 FROM assets.asset_txn t WHERE t.tenant_id = NEW.tenant_id AND t.asset_book_id = NEW.id
                                     AND t.kind = 'depreciation') THEN
    v_changed := rules.changed_columns(to_jsonb(OLD), to_jsonb(NEW));
    IF v_changed && ARRAY['asset_id','book_id','depreciation_start','start_rule','salvage_value'] THEN
      PERFORM core.raise_hk('HK_ASSETS_BOOK_LOCKED', 'start date and salvage are fixed after the first depreciation (change prospectively by method/life)');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON assets.asset_book;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON assets.asset_book FOR EACH ROW EXECUTE FUNCTION assets.asset_book_guard();

-- دوره‌های بلااستفاده (مبنای قاعدهٔ پارامتری کاهش نرخ؛ مرز «بیش از» یا «حداقل» از rules)
CREATE TABLE IF NOT EXISTS assets.idle_period (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  company_id    uuid NOT NULL,
  asset_id      uuid NOT NULL,
  from_date     date NOT NULL,
  to_date       date,                                   -- شامل؛ NULL = هنوز بلااستفاده
  reason        text NOT NULL CHECK (char_length(reason) BETWEEN 3 AND 500),
  attachment_id uuid,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, asset_id) REFERENCES assets.asset(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, attachment_id) REFERENCES core.attachment(tenant_id, id),
  CHECK (to_date IS NULL OR to_date >= from_date),
  EXCLUDE USING gist (tenant_id WITH =, asset_id WITH =, daterange(from_date, to_date, '[]') WITH &&)
);
SELECT core.enable_tenant_rls('assets.idle_period');

-- =====================================================================
-- ۱۷. assets — اجرای استهلاک، واگذاری، جابه‌جایی، و دفتر رویدادهای مالی هر دارایی (فقط‌افزودنی)
-- =====================================================================
CREATE TABLE IF NOT EXISTS assets.depreciation_run (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL DEFAULT uuidv7(),
  company_id         uuid NOT NULL,
  book_id            uuid NOT NULL,
  period_key         text NOT NULL CHECK (period_key ~ '^(jm:[0-9]{4}-(0[1-9]|1[0-2])|jy:[0-9]{4})$'),
  period_start       date NOT NULL,
  period_end         date NOT NULL,
  status             text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','posted','cancelled')),
  rule_snapshot_id   uuid NOT NULL,
  engine_version     text NOT NULL CHECK (engine_version ~ '^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$'),
  line_count         integer NOT NULL DEFAULT 0 CHECK (line_count >= 0),
  total_amount       core.amount NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
  gl_journal_id      uuid,
  posted_by          uuid,
  posted_at          timestamptz,
  cancel_journal_id  uuid,
  cancelled_at       timestamptz,
  cancel_reason      text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  row_version        integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, book_id) REFERENCES assets.book(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, rule_snapshot_id) REFERENCES rules.calc_snapshot(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, gl_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, cancel_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, posted_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (period_end >= period_start),
  CHECK ((status IN ('posted','cancelled')) <= (posted_at IS NOT NULL OR status = 'cancelled')),
  CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL AND cancel_reason IS NOT NULL))
);
SELECT core.enable_tenant_rls('assets.depreciation_run');
CREATE UNIQUE INDEX IF NOT EXISTS depreciation_run_one_live ON assets.depreciation_run (tenant_id, book_id, period_key) WHERE status <> 'cancelled';
DROP TRIGGER IF EXISTS trg_touch ON assets.depreciation_run;
CREATE TRIGGER trg_touch BEFORE UPDATE ON assets.depreciation_run FOR EACH ROW EXECUTE FUNCTION core.touch_row();

CREATE TABLE IF NOT EXISTS assets.depreciation_line (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  company_id       uuid NOT NULL,
  run_id           uuid NOT NULL,
  asset_book_id    uuid NOT NULL,
  asset_id         uuid NOT NULL,
  period_start     date NOT NULL,
  period_end       date NOT NULL,
  method           text NOT NULL CHECK (method IN ('straight_line','declining_balance')),
  basis_amount     core.amount NOT NULL CHECK (basis_amount >= 0),       -- بهای مستهلک‌شدنی (مستقیم) یا ارزش دفتری اول سال (نزولی)
  months           numeric(5,2) NOT NULL CHECK (months > 0 AND months <= 12),
  idle_factor      numeric(5,4) NOT NULL DEFAULT 1 CHECK (idle_factor > 0 AND idle_factor <= 1),
  amount           core.amount NOT NULL CHECK (amount >= 0),
  nbv_before       core.amount NOT NULL,
  nbv_after        core.amount NOT NULL,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, run_id, asset_book_id),
  FOREIGN KEY (tenant_id, company_id, run_id) REFERENCES assets.depreciation_run(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, asset_book_id) REFERENCES assets.asset_book(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, asset_id) REFERENCES assets.asset(tenant_id, company_id, id),
  CHECK (period_end >= period_start),
  CHECK (nbv_after = nbv_before - amount)
);
SELECT core.enable_tenant_rls('assets.depreciation_line');

CREATE TABLE IF NOT EXISTS assets.disposal (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL DEFAULT uuidv7(),
  company_id         uuid NOT NULL,
  asset_id           uuid NOT NULL,
  kind               text NOT NULL CHECK (kind IN ('sale','scrap','donation','loss')),
  disposal_date      date NOT NULL,
  proceeds           core.amount NOT NULL DEFAULT 0 CHECK (proceeds >= 0),
  sales_invoice_id   uuid,                                -- sales.invoice (فروش ⇒ صورتحساب مؤدیان؛ FK در 99_cross_fk)
  status             text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','posted','cancelled')),
  gain_loss          core.amount,
  gl_journal_id      uuid,
  posted_at          timestamptz,
  cancel_reason      text,
  created_by         uuid,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  row_version        integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, asset_id) REFERENCES assets.asset(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, gl_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK ((kind = 'sale') = (sales_invoice_id IS NOT NULL)),
  CHECK (kind = 'sale' OR proceeds = 0),
  CHECK ((status = 'posted') = (posted_at IS NOT NULL AND gain_loss IS NOT NULL)),
  CHECK ((status = 'cancelled') = (cancel_reason IS NOT NULL))
);
SELECT core.enable_tenant_rls('assets.disposal');
CREATE UNIQUE INDEX IF NOT EXISTS disposal_one_posted ON assets.disposal (tenant_id, asset_id) WHERE status = 'posted';
DROP TRIGGER IF EXISTS trg_touch ON assets.disposal;
CREATE TRIGGER trg_touch BEFORE UPDATE ON assets.disposal FOR EACH ROW EXECUTE FUNCTION core.touch_row();

CREATE TABLE IF NOT EXISTS assets.asset_movement (
  tenant_id           uuid NOT NULL REFERENCES core.tenant(id),
  id                  uuid NOT NULL DEFAULT uuidv7(),
  company_id          uuid NOT NULL,
  asset_id            uuid NOT NULL,
  moved_on            date NOT NULL,
  from_branch_id      uuid,
  to_branch_id        uuid,
  from_custodian_id   uuid,
  to_custodian_id     uuid,
  to_location         text,
  reason              text NOT NULL CHECK (char_length(reason) BETWEEN 3 AND 500),
  created_by          uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, asset_id) REFERENCES assets.asset(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, from_branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, to_branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, from_custodian_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, to_custodian_id) REFERENCES parties.party(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (num_nonnulls(to_branch_id, to_custodian_id, to_location) >= 1)
);
SELECT core.enable_tenant_rls('assets.asset_movement');
DROP TRIGGER IF EXISTS trg_immutable ON assets.asset_movement;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON assets.asset_movement FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

-- رویداد مالی هر (دارایی، دفتر): منبع زیردفتر دارایی ثابت. فقط‌افزودنی؛ اصلاح = ردیف reversal
CREATE TABLE IF NOT EXISTS assets.asset_txn (
  tenant_id              uuid NOT NULL REFERENCES core.tenant(id),
  id                     uuid NOT NULL DEFAULT uuidv7(),
  company_id             uuid NOT NULL,
  asset_id               uuid NOT NULL,
  asset_book_id          uuid NOT NULL,
  book_id                uuid NOT NULL,
  kind                   text NOT NULL CHECK (kind IN ('acquisition','improvement','opening','depreciation','disposal','reversal',
                                                      'revaluation','impairment')),
  txn_date               date NOT NULL,
  cost_delta             core.amount NOT NULL DEFAULT 0,
  accum_delta            core.amount NOT NULL DEFAULT 0,
  depreciation_line_id   uuid,
  disposal_id            uuid,
  reverses_txn_id        uuid,
  cost_account_id        uuid,
  accum_account_id       uuid,
  gl_journal_id          uuid,
  created_by             uuid,
  created_at             timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, reverses_txn_id),
  UNIQUE (tenant_id, depreciation_line_id),
  FOREIGN KEY (tenant_id, company_id, asset_id) REFERENCES assets.asset(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, asset_book_id) REFERENCES assets.asset_book(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, book_id) REFERENCES assets.book(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, depreciation_line_id) REFERENCES assets.depreciation_line(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, disposal_id) REFERENCES assets.disposal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, reverses_txn_id) REFERENCES assets.asset_txn(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, cost_account_id) REFERENCES ledger.account(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, accum_account_id) REFERENCES ledger.account(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, gl_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CONSTRAINT asset_txn_shape CHECK (
       (kind IN ('acquisition','improvement') AND cost_delta > 0 AND accum_delta = 0)
    OR (kind = 'opening' AND cost_delta > 0 AND accum_delta >= 0)
    OR (kind = 'depreciation' AND cost_delta = 0 AND accum_delta > 0 AND depreciation_line_id IS NOT NULL)
    OR (kind = 'disposal' AND cost_delta < 0 AND accum_delta <= 0 AND disposal_id IS NOT NULL)
    OR (kind = 'reversal' AND reverses_txn_id IS NOT NULL)
    OR (kind IN ('revaluation','impairment'))),
  CONSTRAINT asset_txn_links CHECK ((kind = 'depreciation') = (depreciation_line_id IS NOT NULL)
                                    AND (kind = 'disposal') = (disposal_id IS NOT NULL)
                                    AND (kind = 'reversal') = (reverses_txn_id IS NOT NULL))
);
SELECT core.enable_tenant_rls('assets.asset_txn');
CREATE INDEX IF NOT EXISTS asset_txn_book_idx ON assets.asset_txn (tenant_id, asset_book_id, txn_date);
DROP TRIGGER IF EXISTS trg_immutable ON assets.asset_txn;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON assets.asset_txn FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

CREATE OR REPLACE FUNCTION assets.asset_txn_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE ab assets.asset_book; b assets.book; a assets.asset; l assets.depreciation_line; r assets.asset_txn;
BEGIN
  SELECT * INTO ab FROM assets.asset_book WHERE tenant_id = NEW.tenant_id AND id = NEW.asset_book_id;
  SELECT * INTO b FROM assets.book WHERE tenant_id = NEW.tenant_id AND id = NEW.book_id;
  SELECT * INTO a FROM assets.asset WHERE tenant_id = NEW.tenant_id AND id = NEW.asset_id;
  IF ab.asset_id <> NEW.asset_id OR ab.book_id <> NEW.book_id THEN
    PERFORM core.raise_hk('HK_ASSETS_TXN_BOOK', 'transaction asset/book must match the asset book');
  END IF;
  IF a.status NOT IN ('active','disposed') THEN
    PERFORM core.raise_hk('HK_ASSETS_NOT_ACTIVE', format('asset is %s', a.status));
  END IF;
  -- دفتر ثبت‌کننده در GL: هر رویداد سند و حساب‌های حل‌شده دارد (زیردفتر با GL تطبیق می‌خورد)
  IF b.posts_to_gl AND (NEW.gl_journal_id IS NULL OR NEW.cost_account_id IS NULL OR NEW.accum_account_id IS NULL) THEN
    PERFORM core.raise_hk('HK_ASSETS_GL_REQUIRED', 'transactions of the GL book need the journal and resolved accounts');
  END IF;
  IF NOT b.posts_to_gl AND NEW.gl_journal_id IS NOT NULL THEN
    PERFORM core.raise_hk('HK_ASSETS_GL_FORBIDDEN', 'a memo (tax) book never posts to the general ledger');
  END IF;
  IF NEW.kind = 'depreciation' THEN
    SELECT * INTO l FROM assets.depreciation_line WHERE tenant_id = NEW.tenant_id AND id = NEW.depreciation_line_id;
    IF l.asset_book_id <> NEW.asset_book_id OR l.amount <> NEW.accum_delta OR NEW.txn_date <> l.period_end THEN
      PERFORM core.raise_hk('HK_ASSETS_TXN_LINE', 'depreciation transaction must mirror its run line (amount, book, period end)');
    END IF;
    IF a.is_land OR ab.method = 'none' THEN
      PERFORM core.raise_hk('HK_ASSETS_LAND_NOT_DEPRECIABLE', 'this asset book is not depreciable');
    END IF;
    IF l.period_start < ab.depreciation_start THEN
      PERFORM core.raise_hk('HK_ASSETS_DEPRECIATION_BEFORE_START', 'depreciation period starts before the depreciation start date');
    END IF;
    IF a.disposed_on IS NOT NULL AND l.period_start > a.disposed_on THEN
      PERFORM core.raise_hk('HK_ASSETS_DEPRECIATION_AFTER_DISPOSAL', 'no depreciation after disposal');
    END IF;
  ELSIF NEW.kind = 'reversal' THEN
    SELECT * INTO r FROM assets.asset_txn WHERE tenant_id = NEW.tenant_id AND id = NEW.reverses_txn_id;
    IF r.asset_book_id <> NEW.asset_book_id OR r.kind = 'reversal' OR NEW.cost_delta <> -r.cost_delta OR NEW.accum_delta <> -r.accum_delta THEN
      PERFORM core.raise_hk('HK_ASSETS_REVERSAL', 'a reversal mirrors exactly one non-reversal transaction of the same book');
    END IF;
  ELSIF NEW.kind IN ('revaluation','impairment') THEN
    PERFORM core.raise_hk('HK_ASSETS_NOT_IN_V1', 'revaluation/impairment are planned for v2');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON assets.asset_txn;
CREATE TRIGGER trg_guard BEFORE INSERT ON assets.asset_txn FOR EACH ROW EXECUTE FUNCTION assets.asset_txn_guard();

-- مانده‌های هر (دارایی، دفتر): بها ≥ ۰، ۰ ≤ استهلاک انباشته ≤ بها − ارزش اسقاط؛ پس از واگذاری هر دو صفر
CREATE OR REPLACE FUNCTION assets.asset_book_verify() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE ab assets.asset_book; a assets.asset; v_cost numeric; v_acc numeric; v_disposed boolean;
BEGIN
  SELECT * INTO ab FROM assets.asset_book WHERE tenant_id = NEW.tenant_id AND id = NEW.asset_book_id;
  SELECT * INTO a FROM assets.asset WHERE tenant_id = NEW.tenant_id AND id = ab.asset_id;
  SELECT coalesce(sum(cost_delta), 0), coalesce(sum(accum_delta), 0), bool_or(kind = 'disposal')
    INTO v_cost, v_acc, v_disposed
    FROM assets.asset_txn t WHERE t.tenant_id = NEW.tenant_id AND t.asset_book_id = ab.id
     AND NOT EXISTS (SELECT 1 FROM assets.asset_txn x WHERE x.tenant_id = t.tenant_id AND x.reverses_txn_id = t.id)
     AND t.kind <> 'reversal';
  IF v_cost < 0 OR v_acc < 0 THEN
    PERFORM core.raise_hk('HK_ASSETS_NEGATIVE_BALANCE', 'cost and accumulated depreciation cannot be negative');
  END IF;
  IF NOT coalesce(v_disposed, false) AND v_acc > v_cost - ab.salvage_value THEN
    PERFORM core.raise_hk('HK_ASSETS_OVER_DEPRECIATED', format('accumulated %s exceeds depreciable base %s', v_acc, v_cost - ab.salvage_value));
  END IF;
  IF coalesce(v_disposed, false) AND (v_cost <> 0 OR v_acc <> 0) THEN
    PERFORM core.raise_hk('HK_ASSETS_DISPOSAL_INCOMPLETE', 'disposal must remove the full cost and accumulated depreciation');
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_verify ON assets.asset_txn;
CREATE CONSTRAINT TRIGGER trg_verify AFTER INSERT ON assets.asset_txn
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION assets.asset_book_verify();

-- خط استهلاک: یک دوره برای هر (دفتر دارایی) در اجراهای زنده؛ پس از ثبت تغییرناپذیر
CREATE OR REPLACE FUNCTION assets.depreciation_line_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE rn assets.depreciation_run; ab assets.asset_book;
BEGIN
  SELECT * INTO rn FROM assets.depreciation_run WHERE tenant_id = coalesce(NEW.tenant_id, OLD.tenant_id) AND id = coalesce(NEW.run_id, OLD.run_id);
  IF rn.status <> 'draft' THEN
    PERFORM core.raise_hk('HK_ASSETS_RUN_IMMUTABLE', 'lines of a posted/cancelled run cannot change');
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  SELECT * INTO ab FROM assets.asset_book WHERE tenant_id = NEW.tenant_id AND id = NEW.asset_book_id;
  IF ab.book_id <> rn.book_id OR ab.asset_id <> NEW.asset_id THEN
    PERFORM core.raise_hk('HK_ASSETS_TXN_BOOK', 'line asset book must belong to the run book');
  END IF;
  IF NEW.period_start < rn.period_start OR NEW.period_end > rn.period_end THEN
    PERFORM core.raise_hk('HK_ASSETS_LINE_PERIOD', 'line period must lie inside the run period');
  END IF;
  IF EXISTS (SELECT 1 FROM assets.depreciation_line x JOIN assets.depreciation_run y ON y.tenant_id = x.tenant_id AND y.id = x.run_id
              WHERE x.tenant_id = NEW.tenant_id AND x.asset_book_id = NEW.asset_book_id AND x.id <> NEW.id
                AND y.status <> 'cancelled' AND daterange(x.period_start, x.period_end, '[]') && daterange(NEW.period_start, NEW.period_end, '[]')) THEN
    PERFORM core.raise_hk('HK_ASSETS_DOUBLE_DEPRECIATION', 'this asset book is already depreciated for an overlapping period');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON assets.depreciation_line;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON assets.depreciation_line FOR EACH ROW EXECUTE FUNCTION assets.depreciation_line_guard();

CREATE OR REPLACE FUNCTION assets.depreciation_run_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_changed text[]; t record; b assets.book;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN PERFORM core.raise_hk('HK_ASSETS_RUN_IMMUTABLE', 'only draft runs can be deleted'); END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' THEN PERFORM core.raise_hk('HK_ASSETS_RUN_TRANSITION', 'runs start as draft'); END IF;
    RETURN NEW;
  END IF;
  v_changed := rules.changed_columns(to_jsonb(OLD), to_jsonb(NEW));
  IF OLD.status <> 'draft' AND NOT (v_changed <@ ARRAY['status','cancel_journal_id','cancelled_at','cancel_reason','updated_at','row_version']) THEN
    PERFORM core.raise_hk('HK_ASSETS_RUN_IMMUTABLE', format('cannot change %s', array_to_string(v_changed, ',')));
  END IF;
  IF NEW.status <> OLD.status AND NOT ((OLD.status, NEW.status) IN (('draft','posted'),('posted','cancelled'),('draft','cancelled'))) THEN
    PERFORM core.raise_hk('HK_ASSETS_RUN_TRANSITION', format('%s → %s is not allowed', OLD.status, NEW.status));
  END IF;
  IF NEW.status = 'posted' AND OLD.status = 'draft' THEN
    SELECT * INTO b FROM assets.book WHERE tenant_id = NEW.tenant_id AND id = NEW.book_id;
    SELECT count(*) AS n, coalesce(sum(amount), 0) AS amt INTO t FROM assets.depreciation_line WHERE tenant_id = NEW.tenant_id AND run_id = NEW.id;
    IF (t.n, t.amt) IS DISTINCT FROM (NEW.line_count::bigint, NEW.total_amount) THEN
      PERFORM core.raise_hk('HK_ASSETS_RUN_TOTALS', 'run totals must equal its lines');
    END IF;
    IF b.posts_to_gl AND NEW.total_amount > 0 AND NEW.gl_journal_id IS NULL THEN
      PERFORM core.raise_hk('HK_ASSETS_GL_REQUIRED', 'posting a GL-book run needs its journal');
    END IF;
    IF NOT b.posts_to_gl AND NEW.gl_journal_id IS NOT NULL THEN
      PERFORM core.raise_hk('HK_ASSETS_GL_FORBIDDEN', 'a memo (tax) book never posts to the general ledger');
    END IF;
  END IF;
  IF NEW.status = 'cancelled' AND OLD.status = 'posted' AND NEW.cancel_journal_id IS NULL AND OLD.gl_journal_id IS NOT NULL THEN
    PERFORM core.raise_hk('HK_ASSETS_GL_REQUIRED', 'cancelling a posted GL run needs the reversal journal');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON assets.depreciation_run;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON assets.depreciation_run FOR EACH ROW EXECUTE FUNCTION assets.depreciation_run_guard();

CREATE OR REPLACE FUNCTION assets.asset_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_changed text[]; c assets.asset_class;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN PERFORM core.raise_hk('HK_ASSETS_IMMUTABLE', 'only draft assets can be deleted'); END IF;
    RETURN OLD;
  END IF;
  SELECT * INTO c FROM assets.asset_class WHERE tenant_id = NEW.tenant_id AND id = NEW.class_id;
  IF NEW.is_land <> c.is_land THEN
    PERFORM core.raise_hk('HK_ASSETS_CLASS_MISMATCH', 'is_land must follow the asset class');
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' THEN PERFORM core.raise_hk('HK_ASSETS_TRANSITION', 'assets start as draft'); END IF;
    RETURN NEW;
  END IF;
  v_changed := rules.changed_columns(to_jsonb(OLD), to_jsonb(NEW));
  IF OLD.status <> 'draft' AND v_changed && ARRAY['company_id','class_id','is_land','acquisition_date','available_date','acquisition_cost'] THEN
    PERFORM core.raise_hk('HK_ASSETS_IMMUTABLE', 'financial identity of an active asset is fixed (use improvement/reversal transactions)');
  END IF;
  IF NEW.status <> OLD.status AND NOT ((OLD.status, NEW.status) IN (('draft','active'),('draft','cancelled'),('active','disposed'))) THEN
    PERFORM core.raise_hk('HK_ASSETS_TRANSITION', format('%s → %s is not allowed', OLD.status, NEW.status));
  END IF;
  IF NEW.status = 'disposed' AND OLD.status = 'active' AND NOT EXISTS (SELECT 1 FROM assets.disposal d
        WHERE d.tenant_id = NEW.tenant_id AND d.asset_id = NEW.id AND d.status = 'posted' AND d.disposal_date = NEW.disposed_on) THEN
    PERFORM core.raise_hk('HK_ASSETS_DISPOSAL_REQUIRED', 'an asset is disposed only by a posted disposal document');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON assets.asset;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON assets.asset FOR EACH ROW EXECUTE FUNCTION assets.asset_guard();

CREATE OR REPLACE FUNCTION assets.disposal_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE a assets.asset; v_changed text[];
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN PERFORM core.raise_hk('HK_ASSETS_IMMUTABLE', 'only draft disposals can be deleted'); END IF;
    RETURN OLD;
  END IF;
  SELECT * INTO a FROM assets.asset WHERE tenant_id = NEW.tenant_id AND id = NEW.asset_id;
  IF NEW.disposal_date < a.acquisition_date THEN
    PERFORM core.raise_hk('HK_ASSETS_DISPOSAL_DATE', 'disposal cannot precede acquisition');
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' THEN PERFORM core.raise_hk('HK_ASSETS_TRANSITION', 'disposals start as draft'); END IF;
    IF a.status <> 'active' THEN PERFORM core.raise_hk('HK_ASSETS_NOT_ACTIVE', 'only active assets can be disposed'); END IF;
    RETURN NEW;
  END IF;
  v_changed := rules.changed_columns(to_jsonb(OLD), to_jsonb(NEW));
  IF OLD.status <> 'draft' AND NOT (v_changed <@ ARRAY['status','cancel_reason','updated_at','row_version']) THEN
    PERFORM core.raise_hk('HK_ASSETS_IMMUTABLE', 'a posted disposal is reversed, not edited');
  END IF;
  IF NEW.status <> OLD.status AND NOT ((OLD.status, NEW.status) IN (('draft','posted'),('draft','cancelled'))) THEN
    PERFORM core.raise_hk('HK_ASSETS_TRANSITION', format('%s → %s is not allowed (v1)', OLD.status, NEW.status));
  END IF;
  IF NEW.status = 'posted' AND EXISTS (SELECT 1 FROM assets.book b WHERE b.tenant_id = NEW.tenant_id AND b.company_id = NEW.company_id
        AND b.posts_to_gl AND b.is_active) AND NEW.gl_journal_id IS NULL THEN
    PERFORM core.raise_hk('HK_ASSETS_GL_REQUIRED', 'posting a disposal needs its journal');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON assets.disposal;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE OR DELETE ON assets.disposal FOR EACH ROW EXECUTE FUNCTION assets.disposal_guard();

-- قرارداد زیردفتر (بخش ۰۳ §۵-۱۴): ماندهٔ تجمعی دفتر GL به تفکیک حساب و بُعد fixed_asset
CREATE OR REPLACE FUNCTION assets.ledger_subledger_fixed_assets(p_company_id uuid, p_as_of date)
RETURNS TABLE (account_id uuid, dim_value_id uuid, currency char(3), balance_base numeric, balance_txn numeric)
LANGUAGE sql STABLE AS $$
  WITH t AS (
    SELECT x.asset_id, x.cost_account_id AS acc, x.cost_delta AS amt
      FROM assets.asset_txn x JOIN assets.book b ON b.tenant_id = x.tenant_id AND b.id = x.book_id
     WHERE x.company_id = p_company_id AND x.txn_date <= p_as_of AND b.posts_to_gl
    UNION ALL
    SELECT x.asset_id, x.accum_account_id, -x.accum_delta
      FROM assets.asset_txn x JOIN assets.book b ON b.tenant_id = x.tenant_id AND b.id = x.book_id
     WHERE x.company_id = p_company_id AND x.txn_date <= p_as_of AND b.posts_to_gl
  )
  SELECT t.acc, a.dimension_value_id, c.base_currency, sum(t.amt), sum(t.amt)
    FROM t JOIN assets.asset a ON a.id = t.asset_id
    JOIN core.company c ON c.id = p_company_id
   GROUP BY t.acc, a.dimension_value_id, c.base_currency
  HAVING sum(t.amt) <> 0
$$;

CREATE OR REPLACE VIEW assets.v_asset_book_balance WITH (security_invoker = true) AS
  SELECT ab.tenant_id, ab.company_id, ab.asset_id, ab.book_id, ab.id AS asset_book_id,
         coalesce(sum(t.cost_delta), 0) AS cost, coalesce(sum(t.accum_delta), 0) AS accumulated,
         coalesce(sum(t.cost_delta), 0) - coalesce(sum(t.accum_delta), 0) AS net_book_value
    FROM assets.asset_book ab
    LEFT JOIN assets.asset_txn t ON t.tenant_id = ab.tenant_id AND t.asset_book_id = ab.id
   GROUP BY ab.tenant_id, ab.company_id, ab.asset_id, ab.book_id, ab.id;

-- تفاوت استهلاک دفتری و مالیاتی (کاربرگ تعدیلات اظهارنامهٔ عملکرد)
CREATE OR REPLACE VIEW assets.v_book_tax_difference WITH (security_invoker = true) AS
  SELECT x.tenant_id, x.company_id, x.asset_id, date_trunc('year', x.txn_date)::date AS year_start,
         sum(x.accum_delta) FILTER (WHERE b.posts_to_gl) AS accounting_depreciation,
         sum(x.accum_delta) FILTER (WHERE b.kind IN ('tax','combined')) AS tax_depreciation
    FROM assets.asset_txn x JOIN assets.book b ON b.tenant_id = x.tenant_id AND b.id = x.book_id
   WHERE x.kind IN ('depreciation','reversal')
   GROUP BY x.tenant_id, x.company_id, x.asset_id, date_trunc('year', x.txn_date);

-- =====================================================================
-- ۱۸. کاتالوگ‌های کدی: تعریف کلیدهای قانونی (بدون مقدار)، تکلیف‌ها، طبقه‌های حقوقی
-- =====================================================================
INSERT INTO rules.param_def (key, domain, package_code, value_type, unit, enum_values, qualifier_kind, override_policy, override_levels, description_key, introduced_in) VALUES
  -- مالیات بر ارزش افزوده و مؤدیان (بستهٔ ir.tax)
  ('tax.vat.general_rate',                         'tax', 'ir.tax', 'percent', 'percent', NULL, 'none',  'none', '{}', 'rules.tax.vat.general_rate', '1.0'),
  ('tax.vat.category_rate',                        'tax', 'ir.tax', 'percent', 'percent', NULL, 'class', 'none', '{}', 'rules.tax.vat.category_rate', '1.0'),
  ('tax.vat.not_called_in_zero_rate',              'tax', 'ir.tax', 'boolean', NULL, NULL, 'none',  'none', '{}', 'rules.tax.vat.not_called_in_zero_rate', '1.0'),
  ('tax.vat.zero_rate_patterns',                   'tax', 'ir.tax', 'json',    NULL, NULL, 'none',  'none', '{}', 'rules.tax.vat.zero_rate_patterns', '1.0'),
  ('tax.vat.input_credit_rule',                    'tax', 'ir.tax', 'json',    NULL, NULL, 'none',  'none', '{}', 'rules.tax.vat.input_credit_rule', '1.0'),
  ('tax.other_levy.rate',                          'tax', 'ir.tax', 'percent', 'percent', NULL, 'code',  'none', '{}', 'rules.tax.other_levy.rate', '1.0'),
  ('tax.moadian.instruction_version',              'tax', 'ir.tax', 'text',    NULL, NULL, 'none',  'none', '{}', 'rules.tax.moadian.instruction_version', '1.0'),
  ('tax.moadian.send_deadline_days',               'tax', 'ir.tax', 'integer', 'days', NULL, 'none', 'none', '{}', 'rules.tax.moadian.send_deadline_days', '1.0'),
  ('tax.moadian.deadline_warn_days',               'tax', 'ir.tax', 'integer', 'days', NULL, 'none', 'none', '{}', 'rules.tax.moadian.deadline_warn_days', '1.0'),
  ('tax.moadian.api.max_invoices_per_request',     'tax', 'ir.tax', 'integer', 'count', NULL, 'none', 'none', '{}', 'rules.tax.moadian.api.max_invoices_per_request', '1.0'),
  ('tax.moadian.api.max_inquiry_days',             'tax', 'ir.tax', 'integer', 'days', NULL, 'none', 'none', '{}', 'rules.tax.moadian.api.max_inquiry_days', '1.0'),
  ('tax.moadian.api.nonce_ttl_seconds',            'tax', 'ir.tax', 'integer', 'seconds', NULL, 'none', 'none', '{}', 'rules.tax.moadian.api.nonce_ttl_seconds', '1.0'),
  ('tax.moadian.future_tolerance_seconds',         'tax', 'ir.tax', 'integer', 'seconds', NULL, 'none', 'none', '{}', 'rules.tax.moadian.future_tolerance_seconds', '1.0'),
  ('tax.moadian.v1_api_enabled',                   'tax', 'ir.tax', 'boolean', NULL, NULL, 'none',  'none', '{}', 'rules.tax.moadian.v1_api_enabled', '1.0'),
  ('tax.moadian.endpoints',                        'tax', 'ir.tax', 'json',    NULL, NULL, 'profile', 'none', '{}', 'rules.tax.moadian.endpoints', '1.0'),
  ('tax.moadian.type3_allowed',                    'tax', 'ir.tax', 'boolean', NULL, NULL, 'none',  'none', '{}', 'rules.tax.moadian.type3_allowed', '1.0'),
  ('tax.moadian.art14m.exemption_ceiling',         'tax', 'ir.tax', 'money',   'IRR', NULL, 'none', 'none', '{}', 'rules.tax.moadian.art14m.exemption_ceiling', '1.0'),
  ('tax.moadian.art6.multiplier',                  'tax', 'ir.tax', 'decimal', NULL, NULL, 'none',  'none', '{}', 'rules.tax.moadian.art6.multiplier', '1.0'),
  ('tax.moadian.threshold.warn_ratio',             'tax', 'ir.tax', 'ratio',   'ratio', NULL, 'none', 'none', '{}', 'rules.tax.moadian.threshold.warn_ratio', '1.0'),
  ('tax.moadian.reaction_deadline_days',           'tax', 'ir.tax', 'integer', 'days', NULL, 'none', 'none', '{}', 'rules.tax.moadian.reaction_deadline_days', '1.0'),
  ('tax.moadian.error_catalog',                    'tax', 'ir.tax', 'table',   NULL, NULL, 'none',  'none', '{}', 'rules.tax.moadian.error_catalog', '1.0'),
  ('tax.art169.exclude_moadian_registered',        'tax', 'ir.tax', 'boolean', NULL, NULL, 'none',  'none', '{}', 'rules.tax.art169.exclude_moadian_registered', '1.0'),
  ('tax.income.legal_entity_rate',                 'tax', 'ir.tax', 'percent', 'percent', NULL, 'none', 'none', '{}', 'rules.tax.income.legal_entity_rate', '1.0'),
  -- قالب‌های فایل (بستهٔ ir.formats)
  ('tax.eledger.format',                           'tax', 'ir.formats', 'json', NULL, NULL, 'profile', 'none', '{}', 'rules.tax.eledger.format', '1.0'),
  ('tax.art169.format',                            'tax', 'ir.formats', 'json', NULL, NULL, 'profile', 'none', '{}', 'rules.tax.art169.format', '1.0'),
  ('tax.vat_summary.format',                       'tax', 'ir.formats', 'json', NULL, NULL, 'profile', 'none', '{}', 'rules.tax.vat_summary.format', '1.0'),
  ('tax.moadian.portal_purchase_excel.format',     'tax', 'ir.formats', 'json', NULL, NULL, 'profile', 'none', '{}', 'rules.tax.moadian.portal_purchase_excel.format', '1.0'),
  ('payroll.format.ssi_list',                      'payroll', 'ir.formats', 'json', NULL, NULL, 'profile', 'none', '{}', 'rules.payroll.format.ssi_list', '1.0'),
  ('payroll.format.salary_tax',                    'payroll', 'ir.formats', 'json', NULL, NULL, 'profile', 'none', '{}', 'rules.payroll.format.salary_tax', '1.0'),
  ('payroll.format.attendance_excel',              'payroll', 'ir.formats', 'json', NULL, NULL, 'profile', 'none', '{}', 'rules.payroll.format.attendance_excel', '1.0'),
  -- حقوق، بیمه و مالیات حقوق (بستهٔ ir.payroll)
  ('payroll.wage.min_daily',                       'payroll', 'ir.payroll', 'money', 'IRR', NULL, 'none', 'floor', '{workshop}', 'rules.payroll.wage.min_daily', '1.0'),
  ('payroll.wage.other_levels',                    'payroll', 'ir.payroll', 'json', NULL, NULL, 'none', 'any', '{workshop}', 'rules.payroll.wage.other_levels', '1.0'),
  ('payroll.allowance.housing_monthly',            'payroll', 'ir.payroll', 'money', 'IRR', NULL, 'none', 'floor', '{company,workshop}', 'rules.payroll.allowance.housing_monthly', '1.0'),
  ('payroll.allowance.grocery_monthly',            'payroll', 'ir.payroll', 'money', 'IRR', NULL, 'none', 'floor', '{company,workshop}', 'rules.payroll.allowance.grocery_monthly', '1.0'),
  ('payroll.allowance.marriage_monthly',           'payroll', 'ir.payroll', 'money', 'IRR', NULL, 'none', 'floor', '{company,workshop}', 'rules.payroll.allowance.marriage_monthly', '1.0'),
  ('payroll.allowance.child_daily_multiplier',     'payroll', 'ir.payroll', 'decimal', NULL, NULL, 'none', 'floor', '{company,workshop}', 'rules.payroll.allowance.child_daily_multiplier', '1.0'),
  ('payroll.allowance.child_min_ssi_days',         'payroll', 'ir.payroll', 'integer', 'days', NULL, 'none', 'none', '{}', 'rules.payroll.allowance.child_min_ssi_days', '1.0'),
  ('payroll.allowance.child_max_age',              'payroll', 'ir.payroll', 'integer', 'years', NULL, 'none', 'none', '{}', 'rules.payroll.allowance.child_max_age', '1.0'),
  ('payroll.seniority.base_daily',                 'payroll', 'ir.payroll', 'money', 'IRR', NULL, 'none', 'floor', '{company,workshop}', 'rules.payroll.seniority.base_daily', '1.0'),
  ('payroll.eidi.min_days',                        'payroll', 'ir.payroll', 'integer', 'days', NULL, 'none', 'floor', '{company,workshop}', 'rules.payroll.eidi.min_days', '1.0'),
  ('payroll.eidi.cap_days_of_min_wage',            'payroll', 'ir.payroll', 'integer', 'days', NULL, 'none', 'none', '{}', 'rules.payroll.eidi.cap_days_of_min_wage', '1.0'),
  ('payroll.severance.days_per_year',              'payroll', 'ir.payroll', 'integer', 'days', NULL, 'none', 'floor', '{company,workshop}', 'rules.payroll.severance.days_per_year', '1.0'),
  ('payroll.time.weekly_hours',                    'payroll', 'ir.payroll', 'decimal', 'hours', NULL, 'none', 'none', '{}', 'rules.payroll.time.weekly_hours', '1.0'),
  ('payroll.time.hourly_divisor',                  'payroll', 'ir.payroll', 'decimal', NULL, NULL, 'none', 'any', '{company,workshop}', 'rules.payroll.time.hourly_divisor', '1.0'),
  ('payroll.time.night_window',                    'payroll', 'ir.payroll', 'json', NULL, NULL, 'none', 'none', '{}', 'rules.payroll.time.night_window', '1.0'),
  ('payroll.rate.overtime',                        'payroll', 'ir.payroll', 'ratio', 'ratio', NULL, 'none', 'floor', '{company,workshop}', 'rules.payroll.rate.overtime', '1.0'),
  ('payroll.rate.night',                           'payroll', 'ir.payroll', 'ratio', 'ratio', NULL, 'none', 'floor', '{company,workshop}', 'rules.payroll.rate.night', '1.0'),
  ('payroll.rate.shift',                           'payroll', 'ir.payroll', 'ratio', 'ratio', NULL, 'code', 'floor', '{company,workshop}', 'rules.payroll.rate.shift', '1.0'),
  ('payroll.rate.friday',                          'payroll', 'ir.payroll', 'ratio', 'ratio', NULL, 'none', 'floor', '{company,workshop}', 'rules.payroll.rate.friday', '1.0'),
  ('payroll.rate.holiday',                         'payroll', 'ir.payroll', 'ratio', 'ratio', NULL, 'none', 'floor', '{company,workshop}', 'rules.payroll.rate.holiday', '1.0'),
  ('payroll.leave.annual_days',                    'payroll', 'ir.payroll', 'decimal', 'days', NULL, 'none', 'floor', '{company,workshop}', 'rules.payroll.leave.annual_days', '1.0'),
  ('payroll.leave.carryover_max_days',             'payroll', 'ir.payroll', 'decimal', 'days', NULL, 'none', 'none', '{}', 'rules.payroll.leave.carryover_max_days', '1.0'),
  ('payroll.leave.hours_per_day',                  'payroll', 'ir.payroll', 'decimal', 'hours', NULL, 'none', 'any', '{company,workshop}', 'rules.payroll.leave.hours_per_day', '1.0'),
  ('payroll.ssi.employee_rate',                    'payroll', 'ir.payroll', 'ratio', 'ratio', NULL, 'none', 'none', '{}', 'rules.payroll.ssi.employee_rate', '1.0'),
  ('payroll.ssi.employer_rate',                    'payroll', 'ir.payroll', 'ratio', 'ratio', NULL, 'none', 'none', '{}', 'rules.payroll.ssi.employer_rate', '1.0'),
  ('payroll.ssi.unemployment_rate',                'payroll', 'ir.payroll', 'ratio', 'ratio', NULL, 'none', 'none', '{}', 'rules.payroll.ssi.unemployment_rate', '1.0'),
  ('payroll.ssi.hard_job_rate',                    'payroll', 'ir.payroll', 'ratio', 'ratio', NULL, 'none', 'none', '{}', 'rules.payroll.ssi.hard_job_rate', '1.0'),
  ('payroll.ssi.cap_multiplier',                   'payroll', 'ir.payroll', 'decimal', NULL, NULL, 'none', 'none', '{}', 'rules.payroll.ssi.cap_multiplier', '1.0'),
  ('payroll.ssi.rounding',                         'payroll', 'ir.payroll', 'enum', NULL, '{half_up,truncate,half_even}', 'none', 'none', '{}', 'rules.payroll.ssi.rounding', '1.0'),
  ('payroll.ssi.small_workshop_exemption',         'payroll', 'ir.payroll', 'json', NULL, NULL, 'none', 'none', '{}', 'rules.payroll.ssi.small_workshop_exemption', '1.0'),
  ('payroll.tax.brackets_monthly',                 'payroll', 'ir.payroll', 'table', NULL, NULL, 'none', 'none', '{}', 'rules.payroll.tax.brackets_monthly', '1.0'),
  ('payroll.tax.annual_exemption',                 'payroll', 'ir.payroll', 'money', 'IRR', NULL, 'none', 'none', '{}', 'rules.payroll.tax.annual_exemption', '1.0'),
  ('payroll.tax.eidi_exemption_fraction',          'payroll', 'ir.payroll', 'ratio', 'ratio', NULL, 'none', 'none', '{}', 'rules.payroll.tax.eidi_exemption_fraction', '1.0'),
  ('payroll.tax.noncash_exemption_fraction',       'payroll', 'ir.payroll', 'ratio', 'ratio', NULL, 'none', 'none', '{}', 'rules.payroll.tax.noncash_exemption_fraction', '1.0'),
  ('payroll.tax.employee_ssi_deductible_fraction', 'payroll', 'ir.payroll', 'ratio', 'ratio', NULL, 'none', 'none', '{}', 'rules.payroll.tax.employee_ssi_deductible_fraction', '1.0'),
  ('payroll.tax.remit_days_after_payment',         'payroll', 'ir.payroll', 'integer', 'days', NULL, 'none', 'none', '{}', 'rules.payroll.tax.remit_days_after_payment', '1.0'),
  ('payroll.tax.rounding',                         'payroll', 'ir.payroll', 'enum', NULL, '{half_up,truncate,half_even}', 'none', 'none', '{}', 'rules.payroll.tax.rounding', '1.0'),
  ('payroll.item_class.treatment',                 'payroll', 'ir.payroll', 'json', NULL, NULL, 'class', 'none', '{}', 'rules.payroll.item_class.treatment', '1.0'),
  ('payroll.part_time.allowance_proration',        'payroll', 'ir.payroll', 'enum', NULL, '{by_hours,full}', 'none', 'any', '{company,workshop}', 'rules.payroll.part_time.allowance_proration', '1.0'),
  -- دارایی ثابت (بستهٔ ir.assets) — جدول ماده ۱۴۹ فقط داده است؛ هیچ نرخی در کد نیست
  ('assets.art149.classes',                        'assets', 'ir.assets', 'table', NULL, NULL, 'none', 'none', '{}', 'rules.assets.art149.classes', '1.0'),
  ('assets.depreciation.start_rule',               'assets', 'ir.assets', 'enum', NULL, '{available_date,first_day_next_month}', 'none', 'none', '{}', 'rules.assets.depreciation.start_rule', '1.0'),
  ('assets.art149.idle_threshold_months',          'assets', 'ir.assets', 'integer', 'months', NULL, 'none', 'none', '{}', 'rules.assets.art149.idle_threshold_months', '1.0'),
  ('assets.art149.idle_comparator',                'assets', 'ir.assets', 'enum', NULL, '{gt,gte}', 'none', 'none', '{}', 'rules.assets.art149.idle_comparator', '1.0'),
  ('assets.art149.idle_rate_factor',               'assets', 'ir.assets', 'ratio', 'ratio', NULL, 'none', 'none', '{}', 'rules.assets.art149.idle_rate_factor', '1.0'),
  ('assets.depreciation.partial_period',           'assets', 'ir.assets', 'enum', NULL, '{monthly_twelfth,daily}', 'none', 'none', '{}', 'rules.assets.depreciation.partial_period', '1.0'),
  -- تقویم انطباق (بستهٔ ir.calendar)
  ('calendar.due_rule',                            'calendar', 'ir.calendar', 'json', NULL, NULL, 'code', 'none', '{}', 'rules.calendar.due_rule', '1.0'),
  ('calendar.extension',                           'calendar', 'ir.calendar', 'date', NULL, NULL, 'obligation_period', 'none', '{}', 'rules.calendar.extension', '1.0'),
  ('calendar.official_holidays',                   'calendar', 'ir.calendar', 'table', NULL, NULL, 'year', 'none', '{}', 'rules.calendar.official_holidays', '1.0'),
  -- عمومی (بستهٔ ir.general)
  ('currency.redenomination.factor',               'currency', 'ir.general', 'decimal', NULL, NULL, 'none', 'none', '{}', 'rules.currency.redenomination.factor', '1.0'),
  ('retention.accounting_records.years',           'retention', 'ir.general', 'integer', 'years', NULL, 'none', 'none', '{}', 'rules.retention.accounting_records.years', '1.0')
ON CONFLICT (key) DO NOTHING;

INSERT INTO rules.tax_category (code, kind, title_key, introduced_in) VALUES
  ('standard',     'vat',        'tax_category.standard', '1.0'),
  ('exempt',       'vat',        'tax_category.exempt', '1.0'),
  ('zero_rated',   'vat',        'tax_category.zero_rated', '1.0'),
  ('not_subject',  'vat',        'tax_category.not_subject', '1.0'),
  ('gold_wage',    'vat',        'tax_category.gold_wage', '1.0'),
  ('harmful',      'other_tax',  'tax_category.harmful', '1.0'),
  ('municipal',    'other_levy', 'tax_category.municipal', '1.0')
ON CONFLICT (code) DO NOTHING;

INSERT INTO rules.obligation_def (code, domain, frequency, applies_to, title_key, introduced_in) VALUES
  ('tax.vat.quarterly_return',     'tax',     'quarterly',  'company',  'obligation.tax.vat.quarterly_return', '1.0'),
  ('tax.art169.quarterly_list',    'tax',     'quarterly',  'company',  'obligation.tax.art169.quarterly_list', '1.0'),
  ('tax.eledger.periodic',         'tax',     'quarterly',  'company',  'obligation.tax.eledger.periodic', '1.0'),
  ('tax.income.annual_return',     'tax',     'annual',     'company',  'obligation.tax.income.annual_return', '1.0'),
  ('tax.moadian.cert_renewal',     'tax',     'per_event',  'memory',   'obligation.tax.moadian.cert_renewal', '1.0'),
  ('payroll.ssi.monthly_list',     'payroll', 'monthly',    'workshop', 'obligation.payroll.ssi.monthly_list', '1.0'),
  ('payroll.salary_tax.remit',     'payroll', 'per_event',  'workshop', 'obligation.payroll.salary_tax.remit', '1.0')
ON CONFLICT (code) DO NOTHING;

INSERT INTO payroll.statutory_class (code, kind, allows_negative, description_key, introduced_in) VALUES
  ('base_wage',            'earning',   false, 'payroll.class.base_wage', '1.0'),
  ('hourly_wage',          'earning',   false, 'payroll.class.hourly_wage', '1.0'),
  ('seniority_base',       'earning',   false, 'payroll.class.seniority_base', '1.0'),
  ('housing',              'earning',   false, 'payroll.class.housing', '1.0'),
  ('grocery',              'earning',   false, 'payroll.class.grocery', '1.0'),
  ('marriage',             'earning',   false, 'payroll.class.marriage', '1.0'),
  ('child',                'earning',   false, 'payroll.class.child', '1.0'),
  ('overtime',             'earning',   false, 'payroll.class.overtime', '1.0'),
  ('night_work',           'earning',   false, 'payroll.class.night_work', '1.0'),
  ('shift_work',           'earning',   false, 'payroll.class.shift_work', '1.0'),
  ('friday_work',          'earning',   false, 'payroll.class.friday_work', '1.0'),
  ('holiday_work',         'earning',   false, 'payroll.class.holiday_work', '1.0'),
  ('hard_job_allowance',   'earning',   false, 'payroll.class.hard_job_allowance', '1.0'),
  ('shortage_adjustment',  'earning',   true,  'payroll.class.shortage_adjustment', '1.0'),
  ('mission',              'earning',   false, 'payroll.class.mission', '1.0'),
  ('travel',               'earning',   false, 'payroll.class.travel', '1.0'),
  ('commission',           'earning',   false, 'payroll.class.commission', '1.0'),
  ('tips',                 'earning',   false, 'payroll.class.tips', '1.0'),
  ('bonus_occasional',     'earning',   false, 'payroll.class.bonus_occasional', '1.0'),
  ('welfare_incentive',    'earning',   false, 'payroll.class.welfare_incentive', '1.0'),
  ('noncash_benefit',      'earning',   false, 'payroll.class.noncash_benefit', '1.0'),
  ('year_end_bonus',       'earning',   false, 'payroll.class.year_end_bonus', '1.0'),
  ('leave_payout',         'earning',   false, 'payroll.class.leave_payout', '1.0'),
  ('severance',            'earning',   false, 'payroll.class.severance', '1.0'),
  ('retro_continuous',     'earning',   true,  'payroll.class.retro_continuous', '1.0'),
  ('retro_noncontinuous',  'earning',   true,  'payroll.class.retro_noncontinuous', '1.0'),
  ('loan_repayment',       'deduction', false, 'payroll.class.loan_repayment', '1.0'),
  ('advance_repayment',    'deduction', false, 'payroll.class.advance_repayment', '1.0'),
  ('other_deduction',      'deduction', false, 'payroll.class.other_deduction', '1.0'),
  ('info',                 'info',      false, 'payroll.class.info', '1.0')
ON CONFLICT (code) DO NOTHING;

-- =====================================================================
-- ۱۹. ثبت در کاتالوگ‌های ماژول‌های پایه (کلید نگاشت GL، زیردفتر، مجوز، تنظیم، رویداد، اعلان، صدور)
-- =====================================================================
INSERT INTO ledger.posting_key (key, owner_module, expected_account_types, is_required, name_fa, introduced_in) VALUES
  ('tax.vat_settlement',                    'tax',     '{liability,asset}', false, 'تسویهٔ مالیات بر ارزش افزوده', '1.0'),
  ('tax.other_tax_payable',                 'tax',     '{liability}',       false, 'سایر مالیات‌ها و عوارض پرداختنی', '1.0'),
  ('tax.levy_payable',                      'tax',     '{liability}',       false, 'سایر وجوه قانونی پرداختنی', '1.0'),
  ('tax.vat_input_nondeductible',           'tax',     '{expense}',         false, 'ارزش افزودهٔ خرید غیرقابل‌کسر', '1.0'),
  ('payroll.unemployment_insurance_expense','payroll', '{expense}',         false, 'بیمهٔ بیکاری سهم کارفرما', '1.0'),
  ('payroll.eidi_expense',                  'payroll', '{expense}',         false, 'هزینهٔ عیدی و پاداش', '1.0'),
  ('payroll.eidi_provision',                'payroll', '{liability}',       false, 'ذخیرهٔ عیدی و پاداش', '1.0'),
  ('payroll.severance_expense',             'payroll', '{expense}',         false, 'هزینهٔ مزایای پایان خدمت', '1.0'),
  ('payroll.severance_provision',           'payroll', '{liability}',       false, 'ذخیرهٔ مزایای پایان خدمت', '1.0'),
  ('payroll.leave_expense',                 'payroll', '{expense}',         false, 'هزینهٔ مرخصی ذخیره', '1.0'),
  ('payroll.leave_provision',               'payroll', '{liability}',       false, 'ذخیرهٔ مرخصی', '1.0'),
  ('payroll.employee_loan',                 'payroll', '{asset}',           false, 'وام کارکنان', '1.0'),
  ('payroll.employee_advance',              'payroll', '{asset}',           false, 'مساعدهٔ کارکنان', '1.0'),
  ('payroll.other_deduction_payable',       'payroll', '{liability}',       false, 'سایر کسورات پرداختنی', '1.0'),
  ('assets.acquisition_clearing',           'assets',  '{asset,liability}', false, 'واسط تحصیل دارایی ثابت', '1.0'),
  ('assets.disposal_clearing',              'assets',  '{asset,liability}', false, 'واسط فروش دارایی ثابت', '1.0'),
  ('assets.disposal_gain',                  'assets',  '{income}',          false, 'سود فروش دارایی ثابت', '1.0'),
  ('assets.disposal_loss',                  'assets',  '{expense}',         false, 'زیان واگذاری دارایی ثابت', '1.0')
ON CONFLICT (key) DO NOTHING;

INSERT INTO ledger.subledger_source (subledger_kind, owner_module, balance_function, dim_slot, compare_txn, introduced_in)
VALUES ('fixed_asset', 'assets', 'assets.ledger_subledger_fixed_assets', 1, false, '1.0')
ON CONFLICT (subledger_kind) DO NOTHING;

INSERT INTO core.permission (code, module, scope_dimensions, risk, allow_service_account, allow_impersonation_write, description_key, introduced_in) VALUES
  ('rules.package.read',        'rules',   '{}',        'normal',    true,  false, 'perm.rules.package.read', '1.0'),
  ('rules.override.manage',     'rules',   '{company}', 'critical',  false, false, 'perm.rules.override.manage', '1.0'),
  ('rules.proposal.read',       'rules',   '{company}', 'normal',    true,  false, 'perm.rules.proposal.read', '1.0'),
  ('rules.proposal.decide',     'rules',   '{company}', 'sensitive', false, false, 'perm.rules.proposal.decide', '1.0'),
  ('rules.calendar.read',       'rules',   '{company}', 'normal',    true,  false, 'perm.rules.calendar.read', '1.0'),
  ('rules.calendar.manage',     'rules',   '{company}', 'normal',    false, true,  'perm.rules.calendar.manage', '1.0'),
  ('rules.pack.manage',         'rules',   '{company}', 'critical',  false, false, 'perm.rules.pack.manage', '1.0'),
  ('tax.profile.manage',        'tax',     '{company}', 'critical',  false, false, 'perm.tax.profile.manage', '1.0'),
  ('tax.memory.read',           'tax',     '{company}', 'normal',    true,  false, 'perm.tax.memory.read', '1.0'),
  ('tax.memory.manage',         'tax',     '{company}', 'critical',  false, false, 'perm.tax.memory.manage', '1.0'),
  ('tax.key.manage',            'tax',     '{company}', 'critical',  false, false, 'perm.tax.key.manage', '1.0'),
  ('tax.invoice.read',          'tax',     '{company,branch}', 'normal', true, false, 'perm.tax.invoice.read', '1.0'),
  ('tax.invoice.send',          'tax',     '{company}', 'sensitive', true,  false, 'perm.tax.invoice.send', '1.0'),
  ('tax.invoice.reissue',       'tax',     '{company}', 'sensitive', false, false, 'perm.tax.invoice.reissue', '1.0'),
  ('tax.invoice.withdraw',      'tax',     '{company}', 'critical',  false, false, 'perm.tax.invoice.withdraw', '1.0'),
  ('tax.purchase.read',         'tax',     '{company}', 'normal',    true,  false, 'perm.tax.purchase.read', '1.0'),
  ('tax.purchase.manage',       'tax',     '{company}', 'sensitive', true,  false, 'perm.tax.purchase.manage', '1.0'),
  ('tax.vat_return.read',       'tax',     '{company}', 'normal',    true,  false, 'perm.tax.vat_return.read', '1.0'),
  ('tax.vat_return.prepare',    'tax',     '{company}', 'sensitive', false, false, 'perm.tax.vat_return.prepare', '1.0'),
  ('tax.vat_return.file',       'tax',     '{company}', 'critical',  false, false, 'perm.tax.vat_return.file', '1.0'),
  ('tax.report.generate',       'tax',     '{company}', 'sensitive', true,  false, 'perm.tax.report.generate', '1.0'),
  ('tax.threshold.read',        'tax',     '{company}', 'normal',    true,  false, 'perm.tax.threshold.read', '1.0'),
  ('payroll.workshop.manage',   'payroll', '{company}', 'critical',  false, false, 'perm.payroll.workshop.manage', '1.0'),
  ('payroll.employee.read',     'payroll', '{company}', 'sensitive', true,  false, 'perm.payroll.employee.read', '1.0'),
  ('payroll.employee.manage',   'payroll', '{company}', 'sensitive', false, false, 'perm.payroll.employee.manage', '1.0'),
  ('payroll.salary.read',       'payroll', '{company}', 'critical',  false, false, 'perm.payroll.salary.read', '1.0'),
  ('payroll.decree.manage',     'payroll', '{company}', 'sensitive', false, false, 'perm.payroll.decree.manage', '1.0'),
  ('payroll.decree.approve',    'payroll', '{company}', 'critical',  false, false, 'perm.payroll.decree.approve', '1.0'),
  ('payroll.attendance.manage', 'payroll', '{company}', 'normal',    true,  false, 'perm.payroll.attendance.manage', '1.0'),
  ('payroll.attendance.confirm','payroll', '{company}', 'sensitive', false, false, 'perm.payroll.attendance.confirm', '1.0'),
  ('payroll.run.calculate',     'payroll', '{company}', 'sensitive', false, false, 'perm.payroll.run.calculate', '1.0'),
  ('payroll.run.approve',       'payroll', '{company}', 'critical',  false, false, 'perm.payroll.run.approve', '1.0'),
  ('payroll.run.post',          'payroll', '{company}', 'critical',  false, false, 'perm.payroll.run.post', '1.0'),
  ('payroll.run.cancel',        'payroll', '{company}', 'critical',  false, false, 'perm.payroll.run.cancel', '1.0'),
  ('payroll.payslip.read',      'payroll', '{company}', 'critical',  false, false, 'perm.payroll.payslip.read', '1.0'),
  ('payroll.loan.manage',       'payroll', '{company}', 'sensitive', false, false, 'perm.payroll.loan.manage', '1.0'),
  ('payroll.file.generate',     'payroll', '{company}', 'sensitive', false, false, 'perm.payroll.file.generate', '1.0'),
  ('assets.asset.read',         'assets',  '{company,branch}', 'normal', true, false, 'perm.assets.asset.read', '1.0'),
  ('assets.asset.manage',       'assets',  '{company,branch}', 'sensitive', false, false, 'perm.assets.asset.manage', '1.0'),
  ('assets.book.manage',        'assets',  '{company}', 'critical',  false, false, 'perm.assets.book.manage', '1.0'),
  ('assets.depreciation.run',   'assets',  '{company}', 'sensitive', true,  false, 'perm.assets.depreciation.run', '1.0'),
  ('assets.depreciation.post',  'assets',  '{company}', 'critical',  false, false, 'perm.assets.depreciation.post', '1.0'),
  ('assets.disposal.post',      'assets',  '{company}', 'critical',  false, false, 'perm.assets.disposal.post', '1.0')
ON CONFLICT (code) DO NOTHING;

INSERT INTO core.role_template_permission (template_code, permission_code)
SELECT 'payroll_officer', code FROM core.permission WHERE module = 'payroll'
   AND code NOT IN ('payroll.run.approve','payroll.run.cancel','payroll.decree.approve','payroll.workshop.manage')
UNION ALL SELECT 'payroll_officer', code FROM core.permission WHERE code IN ('rules.package.read','rules.calendar.read','rules.proposal.read')
UNION ALL SELECT 'accountant', code FROM core.permission WHERE module IN ('tax','assets','rules')
   AND code NOT IN ('tax.key.manage','tax.memory.manage','tax.profile.manage','tax.vat_return.file','tax.invoice.withdraw',
                    'rules.override.manage','rules.pack.manage','assets.book.manage')
UNION ALL SELECT 'auditor', code FROM core.permission WHERE code IN
  ('rules.package.read','rules.proposal.read','rules.calendar.read','tax.memory.read','tax.invoice.read','tax.purchase.read',
   'tax.vat_return.read','tax.threshold.read','assets.asset.read','payroll.employee.read')
UNION ALL SELECT 'admin', code FROM core.permission WHERE module IN ('tax','assets','rules','payroll')
UNION ALL SELECT 'cashier', code FROM core.permission WHERE code IN ('tax.invoice.read')
UNION ALL SELECT 'sales_clerk', code FROM core.permission WHERE code IN ('tax.invoice.read','tax.invoice.send')
ON CONFLICT DO NOTHING;

INSERT INTO core.field_guard (resource, field, read_permission, write_permission, mask_style, is_secret) VALUES
  ('tax.memory_key', 'private_key_sealed', 'tax.key.manage', 'tax.key.manage', 'omit', true),
  ('payroll.decree', 'daily_wage',         'payroll.salary.read', 'payroll.decree.manage', 'omit', false),
  ('payroll.decree', 'hourly_wage',        'payroll.salary.read', 'payroll.decree.manage', 'omit', false),
  ('payroll.payslip', 'net_pay',           'payroll.payslip.read', 'payroll.run.calculate', 'omit', false)
ON CONFLICT DO NOTHING;

INSERT INTO core.setting_def (key, module, value_type, enum_values, min_value, max_value, allowed_levels, default_value,
                              read_permission, write_permission, description_key, introduced_in) VALUES
  ('tax.moadian.warn_before_deadline_hours', 'tax', 'int', NULL, 1, 144, '{tenant,company}', '24', NULL, 'tax.profile.manage', 'setting.tax.moadian.warn_before_deadline_hours', '1.0'),
  ('tax.moadian.max_resend_attempts',        'tax', 'int', NULL, 1, 50, '{tenant,company}', '10', NULL, 'tax.profile.manage', 'setting.tax.moadian.max_resend_attempts', '1.0'),
  ('tax.moadian.inquiry_backoff_seconds',    'tax', 'int', NULL, 10, 86400, '{tenant}', '60', NULL, 'tax.profile.manage', 'setting.tax.moadian.inquiry_backoff_seconds', '1.0'),
  ('payroll.run.require_distinct_approver',  'payroll', 'bool', NULL, NULL, NULL, '{tenant,company}', 'true', NULL, 'payroll.workshop.manage', 'setting.payroll.run.require_distinct_approver', '1.0'),
  ('payroll.payslip.publish_channel',        'payroll', 'enum', '{none,in_app,sms}', NULL, NULL, '{tenant,company}', '"in_app"', NULL, 'payroll.workshop.manage', 'setting.payroll.payslip.publish_channel', '1.0'),
  ('assets.depreciation.frequency',          'assets', 'enum', '{monthly,annual}', NULL, NULL, '{tenant,company}', '"monthly"', NULL, 'assets.book.manage', 'setting.assets.depreciation.frequency', '1.0'),
  ('rules.calendar.remind_days_before',      'rules', 'int', NULL, 0, 60, '{tenant,company}', '7', NULL, 'rules.calendar.manage', 'setting.rules.calendar.remind_days_before', '1.0')
ON CONFLICT (key) DO NOTHING;

INSERT INTO core.event_subscriber (subscriber, ordered, max_attempts, requires_webhook_endpoint, introduced_in) VALUES
  ('rules.retro_scan',     true,  25, false, '1.0'),
  ('rules.calendar_sync',  false, 25, false, '1.0'),
  ('tax.threshold_track',  true,  25, false, '1.0'),
  ('tax.party_merge',      true,  25, false, '1.0'),
  ('payroll.party_merge',  true,  25, false, '1.0'),
  ('assets.party_merge',   true,  25, false, '1.0'),
  ('assets.year_close',    true,  25, false, '1.0')
ON CONFLICT DO NOTHING;
INSERT INTO core.event_subscription (event_type, subscriber) VALUES
  ('rules.package.activated',   'rules.retro_scan'),
  ('rules.package.activated',   'rules.calendar_sync'),
  ('tax.invoice.registered',    'tax.threshold_track'),
  ('parties.party.merged',      'tax.party_merge'),
  ('parties.party.merged',      'payroll.party_merge'),
  ('parties.party.merged',      'assets.party_merge'),
  ('ledger.year.closed',        'assets.year_close')
ON CONFLICT DO NOTHING;

INSERT INTO core.notification_category (code, module, is_mandatory, default_channels, description_key) VALUES
  ('tax.moadian_deadline',   'tax',     true,  '{in_app,sms}', 'ntf.tax.moadian_deadline'),
  ('tax.moadian_rejected',   'tax',     true,  '{in_app}',     'ntf.tax.moadian_rejected'),
  ('tax.threshold',          'tax',     true,  '{in_app,sms}', 'ntf.tax.threshold'),
  ('tax.key_expiry',         'tax',     true,  '{in_app,sms}', 'ntf.tax.key_expiry'),
  ('rules.package_activated','rules',   false, '{in_app}',     'ntf.rules.package_activated'),
  ('rules.compliance_due',   'rules',   false, '{in_app,sms}', 'ntf.rules.compliance_due'),
  ('payroll.run_approval',   'payroll', false, '{in_app}',     'ntf.payroll.run_approval')
ON CONFLICT (code) DO NOTHING;

INSERT INTO core.export_table_registry (schema_name, table_name, module, mode, export_order, pii_columns, secret_columns, note) VALUES
  ('rules','param_override',        'rules',   'rows', 800, '{}', '{}', NULL),
  ('rules','calc_snapshot',         'rules',   'rows', 802, '{}', '{}', 'refers to global rules.package/param_value ids; importer verifies the target cell has the same packages'),
  ('rules','recalc_proposal',       'rules',   'rows', 804, '{}', '{}', NULL),
  ('rules','compliance_item',       'rules',   'rows', 806, '{}', '{}', NULL),
  ('rules','tenant_pack',           'rules',   'rows', 808, '{}', '{}', NULL),
  ('rules','tenant_pack_event',     'rules',   'rows', 810, '{}', '{}', NULL),
  ('rules','pack_artifact',         'rules',   'rows', 812, '{}', '{}', NULL),
  ('tax','taxpayer_profile',        'tax',     'rows', 820, '{}', '{}', NULL),
  ('tax','vat_registration',        'tax',     'rows', 822, '{}', '{}', NULL),
  ('tax','memory',                  'tax',     'rows', 824, '{}', '{}', NULL),
  ('tax','memory_key',              'tax',     'rows', 826, '{}', '{private_key_sealed}', 'sealed with the source KEK; the import hook re-seals with the target KeyManager'),
  ('tax','invoice',                 'tax',     'rows', 828, '{}', '{}', NULL),
  ('tax','invoice_issue',           'tax',     'rows', 830, '{buyer_national_id,buyer_postal_code}', '{}', 'immutable archive (taxid continuity)'),
  ('tax','invoice_issue_line',      'tax',     'rows', 832, '{}', '{}', NULL),
  ('tax','send_batch',              'tax',     'rows', 834, '{}', '{}', NULL),
  ('tax','submission_attempt',      'tax',     'rows', 836, '{}', '{}', NULL),
  ('tax','inquiry_log',             'tax',     'rows', 838, '{}', '{}', NULL),
  ('tax','purchase_entry',          'tax',     'rows', 840, '{}', '{}', NULL),
  ('tax','threshold_monitor',       'tax',     'rows', 842, '{}', '{}', NULL),
  ('tax','vat_return',              'tax',     'rows', 844, '{}', '{}', NULL),
  ('tax','vat_return_line',         'tax',     'rows', 846, '{}', '{}', NULL),
  ('tax','legal_report',            'tax',     'rows', 848, '{}', '{}', NULL),
  ('payroll','workshop',            'payroll', 'rows', 860, '{}', '{}', NULL),
  ('payroll','employee',            'payroll', 'rows', 862, '{insurance_no}', '{}', NULL),
  ('payroll','employee_dependent',  'payroll', 'rows', 864, '{full_name,national_id,birth_date}', '{}', NULL),
  ('payroll','contract',            'payroll', 'rows', 866, '{}', '{}', NULL),
  ('payroll','pay_item',            'payroll', 'rows', 868, '{}', '{}', NULL),
  ('payroll','decree',              'payroll', 'rows', 870, '{daily_wage,hourly_wage}', '{}', NULL),
  ('payroll','decree_item',         'payroll', 'rows', 872, '{}', '{}', NULL),
  ('payroll','attendance_import',   'payroll', 'rows', 874, '{}', '{}', NULL),
  ('payroll','clock_device',        'payroll', 'rows', 876, '{}', '{}', NULL),
  ('payroll','clock_user_map',      'payroll', 'rows', 878, '{}', '{}', NULL),
  ('payroll','clock_event',         'payroll', 'rows', 880, '{}', '{}', NULL),
  ('payroll','shift_def',           'payroll', 'rows', 882, '{}', '{}', NULL),
  ('payroll','shift_assignment',    'payroll', 'rows', 884, '{}', '{}', NULL),
  ('payroll','attendance_day',      'payroll', 'rows', 886, '{}', '{}', NULL),
  ('payroll','attendance_summary',  'payroll', 'rows', 888, '{}', '{}', NULL),
  ('payroll','run',                 'payroll', 'rows', 890, '{}', '{}', NULL),
  ('payroll','payslip',             'payroll', 'rows', 892, '{}', '{}', NULL),
  ('payroll','loan',                'payroll', 'rows', 894, '{}', '{}', NULL),
  ('payroll','loan_installment',    'payroll', 'rows', 896, '{}', '{}', NULL),
  ('payroll','payslip_line',        'payroll', 'rows', 898, '{}', '{}', NULL),
  ('payroll','accrual_entry',       'payroll', 'rows', 900, '{}', '{}', NULL),
  ('payroll','leave_entry',         'payroll', 'rows', 902, '{}', '{}', NULL),
  ('payroll','gov_file',            'payroll', 'rows', 904, '{}', '{}', NULL),
  ('payroll','gov_file_part',       'payroll', 'rows', 906, '{}', '{}', NULL),
  ('assets','asset_class',          'assets',  'rows', 920, '{}', '{}', NULL),
  ('assets','book',                 'assets',  'rows', 922, '{}', '{}', NULL),
  ('assets','asset',                'assets',  'rows', 924, '{}', '{}', NULL),
  ('assets','asset_tag',            'assets',  'rows', 926, '{}', '{}', NULL),
  ('assets','asset_book',           'assets',  'rows', 928, '{}', '{}', NULL),
  ('assets','idle_period',          'assets',  'rows', 930, '{}', '{}', NULL),
  ('assets','depreciation_run',     'assets',  'rows', 932, '{}', '{}', NULL),
  ('assets','depreciation_line',    'assets',  'rows', 934, '{}', '{}', NULL),
  ('assets','disposal',             'assets',  'rows', 936, '{}', '{}', NULL),
  ('assets','asset_movement',       'assets',  'rows', 938, '{}', '{}', NULL),
  ('assets','asset_txn',            'assets',  'rows', 940, '{}', '{}', 'verbatim; the import hook runs ledger.check_control_accounts for fixed_asset')
ON CONFLICT DO NOTHING;

-- =====================================================================
-- ۲۰. دسترسی نقش‌ها
-- =====================================================================
-- سراسری: فقط خواندن برای برنامه (نوشتن = نصب‌کنندهٔ بسته با نقش migrator)
GRANT SELECT ON rules.param_def, rules.package, rules.param_value, rules.golden_test, rules.golden_run, rules.package_event,
                rules.obligation_def, rules.tax_category, rules.industry_pack, rules.industry_pack_version, ref.sstid_vat_rate, ref.ssi_job_code,
                payroll.statutory_class TO hk_app, hk_readonly;
-- rules (مستأجری)
GRANT SELECT, INSERT, UPDATE ON rules.param_override, rules.recalc_proposal, rules.tenant_pack, rules.pack_artifact TO hk_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON rules.compliance_item TO hk_app;
GRANT SELECT, INSERT ON rules.calc_snapshot, rules.tenant_pack_event TO hk_app;
-- tax
GRANT SELECT, INSERT, UPDATE ON tax.taxpayer_profile, tax.vat_registration, tax.memory_key, tax.invoice, tax.invoice_issue,
                                tax.send_batch, tax.purchase_entry, tax.threshold_monitor, tax.legal_report TO hk_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON tax.memory, tax.vat_return, tax.vat_return_line TO hk_app;
GRANT SELECT, INSERT ON tax.invoice_issue_line, tax.submission_attempt, tax.inquiry_log TO hk_app;
-- payroll
GRANT SELECT, INSERT, UPDATE ON payroll.workshop, payroll.employee, payroll.employee_dependent, payroll.contract, payroll.pay_item,
                                payroll.attendance_import, payroll.clock_device, payroll.clock_user_map, payroll.shift_def,
                                payroll.shift_assignment, payroll.loan, payroll.gov_file TO hk_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON payroll.decree, payroll.decree_item, payroll.attendance_day, payroll.attendance_summary,
                                        payroll.run, payroll.payslip, payroll.payslip_line, payroll.loan_installment TO hk_app;
GRANT SELECT, INSERT ON payroll.clock_event, payroll.accrual_entry, payroll.leave_entry, payroll.gov_file_part TO hk_app;
-- assets
GRANT SELECT, INSERT, UPDATE ON assets.asset_class, assets.book, assets.asset_book, assets.asset_tag, assets.idle_period TO hk_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON assets.asset, assets.depreciation_run, assets.depreciation_line, assets.disposal TO hk_app;
GRANT SELECT, INSERT ON assets.asset_txn, assets.asset_movement TO hk_app;
-- ویوها و توابع
GRANT SELECT ON tax.v_sales_moadian_status, tax.v_send_deadline_queue, payroll.v_leave_balance, payroll.v_accrual_balance,
                assets.v_asset_book_balance, assets.v_book_tax_difference TO hk_app, hk_readonly;
-- فقط‌خواندنی: همه به‌جز رمزینهٔ کلید خصوصی (ستون‌به‌ستون)
GRANT SELECT ON ALL TABLES IN SCHEMA rules, tax, payroll, assets TO hk_readonly;
REVOKE SELECT ON tax.memory_key FROM hk_readonly;
GRANT SELECT (tenant_id, id, memory_ref, kind, custody, public_key_spki, key_bits, fingerprint_sha256, kms_key_ref, device_id,
              certificate_der, cert_subject_serial, cert_not_before, cert_not_after, status, registered_confirmed_at,
              custody_contract_version, custody_contract_accepted_by, custody_contract_accepted_at, activated_at, retired_at,
              retire_reason, created_at, updated_at, row_version) ON tax.memory_key TO hk_readonly;
