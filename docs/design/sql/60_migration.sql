-- =====================================================================
-- حساب‌کتاب — 60_migration.sql   (سند طراحی: docs/design/08-migration.md)
-- ماژول migration: انتقال داده از نرم‌افزار قبلی (هلو، سپیدار، حسابفا، محک، اکسل، ...)
--
-- پیش‌نیاز: 00_foundation.sql، 10_core.sql، 20_ledger.sql، 25_masterdata.sql (به همین ترتیب).
-- جدول‌های ماژول‌های بیرون از این وابستگی‌ها (inventory، treasury، sales، purchase، tax، payroll،
-- assets، rules) فقط با ستون uuid ارجاع می‌شوند؛ FK آن‌ها در سند §۱۲ آمده است (99_cross_fk.sql).
--
-- قواعد: PK = id uuid DEFAULT uuidv7()؛ جدول مستأجری tenant_id NOT NULL + UNIQUE (tenant_id, id)
-- + core.enable_tenant_rls؛ ارجاع بین جدول‌های مستأجری FK ترکیبی؛ ستون‌های کنشگر (*_by) به
-- core.tenant_membership(tenant_id, user_id)؛ کاتالوگ‌ها بدون tenant_id و برای hk_app فقط SELECT.
-- خطاها: RAISE با پیام 'HK_MIG_<CODE>: ...' و ERRCODE P0001 (نگاشت به کد API در سند §۵-۱۴).
-- اصطلاحات یکسان‌شده: بستهٔ میانی = HIF (Hesabketab Interchange Format)؛ کار = migration.job.
-- =====================================================================

DO $$
BEGIN
  IF current_setting('server_encoding') <> 'UTF8' THEN
    RAISE EXCEPTION 'HK_ENCODING: data-plane database must be UTF8 (found %)', current_setting('server_encoding');
  END IF;
  IF to_regclass('core.tenant_membership') IS NULL OR to_regclass('ledger.journal') IS NULL
     OR to_regclass('parties.party') IS NULL OR to_regclass('catalog.item') IS NULL THEN
    RAISE EXCEPTION 'HK_MIG_PREREQ: apply 00_foundation, 10_core, 20_ledger and 25_masterdata first';
  END IF;
END $$;

-- =====================================================================
-- ۱. توابع کمکی (بدون حالت)
-- =====================================================================
CREATE OR REPLACE FUNCTION migration.raise_error(p_code text, p_message text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '%: %', p_code, p_message USING ERRCODE = 'P0001';
END $$;

-- نرمال‌سازی سرستون برای تطبیق خودکار (همتای پایتون: hesabketab.migration.domain.headers.norm_header؛
-- بردار مشترک: docs/design/sql/tests/mig_header_norm_v1.json). مقدار خام جداگانه نگه داشته می‌شود.
-- ترتیب مهم است: ارقام عربی-هندی پیش از حذف بازهٔ اعراب (U+064B..U+0670 که آن ارقام را هم دربر دارد) تبدیل می‌شوند.
CREATE OR REPLACE FUNCTION migration.norm_header(p text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
SELECT lower(btrim(regexp_replace(
         regexp_replace(
           replace(replace(replace(
             regexp_replace(
               translate(
                 translate(normalize(coalesce(p, ''), NFKC),
                           U&'\064A\0649\0626\0643\0629\06C0\0623\0625\0622\0624',
                           U&'\06CC\06CC\06CC\06A9\0647\0647\0627\0627\0627\0648'),
                 U&'\06F0\06F1\06F2\06F3\06F4\06F5\06F6\06F7\06F8\06F9\0660\0661\0662\0663\0664\0665\0666\0667\0668\0669',
                 '01234567890123456789'),
               U&'[\064B-\0670\065F\0640]', '', 'g'),
             U&'\200C', ' '), U&'\200F', ''), U&'\200E', ''),
           '[()\[\]{}:/\\\-_.،,*#]+', ' ', 'g'),
         '\s+', ' ', 'g')))
$$;

-- رقم کنترل Verhoeff (جدول‌های رسمی؛ سند RC_DCPS.SN V1.3). ورودی فقط رقم.
CREATE OR REPLACE FUNCTION migration.verhoeff_digit(p_num text) RETURNS integer
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
  d int[] := ARRAY[[0,1,2,3,4,5,6,7,8,9],[1,2,3,4,0,6,7,8,9,5],[2,3,4,0,1,7,8,9,5,6],[3,4,0,1,2,8,9,5,6,7],
                   [4,0,1,2,3,9,5,6,7,8],[5,9,8,7,6,0,4,3,2,1],[6,5,9,8,7,1,0,4,3,2],[7,6,5,9,8,2,1,0,4,3],
                   [8,7,6,5,9,3,2,1,0,4],[9,8,7,6,5,4,3,2,1,0]];
  pt int[] := ARRAY[[0,1,2,3,4,5,6,7,8,9],[1,5,7,6,2,8,3,0,9,4],[5,8,0,3,7,9,6,1,4,2],[8,9,1,6,0,4,3,5,2,7],
                    [9,4,5,3,1,2,6,8,7,0],[4,2,8,6,5,7,3,9,0,1],[2,7,9,3,8,0,6,4,1,5],[7,0,4,6,9,1,3,2,5,8]];
  inv int[] := ARRAY[0,4,3,2,1,5,6,7,8,9];
  c int := 0;
  n int := length(p_num);
  i int;
BEGIN
  IF p_num !~ '^[0-9]+$' THEN RETURN NULL; END IF;
  FOR i IN 0 .. n - 1 LOOP
    c := d[c + 1][pt[((i + 1) % 8) + 1][substr(p_num, n - i, 1)::int + 1] + 1];
  END LOOP;
  RETURN inv[c + 1];
END $$;

CREATE OR REPLACE FUNCTION migration.hex_to_bigint(p_hex text) RETURNS bigint
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
SELECT ('x' || lpad(p_hex, 16, '0'))::bit(64)::bigint
$$;

-- شمارهٔ منحصربه‌فرد مالیاتی ۲۲ نویسه: حافظه(۶) + روز Hex(۵) + سریال Hex(۱۰) + رقم کنترل Verhoeff.
-- رشتهٔ کنترل = (حرف حافظه ← کد ASCII، رقم بدون تغییر) + روز دهدهی zfill(6) + سریال دهدهی zfill(12).
-- اعتبارسنج سخت‌گیر است (فقط شکل متعارف با حروف بزرگ؛ هم‌معنا با tax.taxid_valid بخش ۰۷). نرمال‌ساز مهاجرت
-- پیش از اعتبارسنجی trim و upper می‌کند. zfill هرگز کوتاه نمی‌کند (سریال ≥ 10^12 و روز ≥ 10^6؛ سند §۱۳ CR-MG22).
-- همتای پایتون: kernel.validators.iran.valid_taxid؛ بردار مشترک: tests/mig_taxid_v1.json
CREATE OR REPLACE FUNCTION migration.taxid_is_valid(p text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
  t text := coalesce(p, '');
  mem text := '';
  ch text;
  days text;
  serial text;
  i int;
BEGIN
  IF t !~ '^[A-Z0-9]{6}[0-9A-F]{5}[0-9A-F]{10}[0-9]$' THEN RETURN false; END IF;
  FOR i IN 1 .. 6 LOOP
    ch := substr(t, i, 1);
    mem := mem || CASE WHEN ch ~ '[0-9]' THEN ch ELSE ascii(ch)::text END;
  END LOOP;
  days := migration.hex_to_bigint(substr(t, 7, 5))::text;
  serial := migration.hex_to_bigint(substr(t, 12, 10))::text;
  IF length(days) < 6 THEN days := lpad(days, 6, '0'); END IF;       -- zfill: هرگز کوتاه نمی‌کند
  IF length(serial) < 12 THEN serial := lpad(serial, 12, '0'); END IF;
  RETURN migration.verhoeff_digit(mem || days || serial) = substr(t, 22, 1)::int;
END $$;

-- شمار ردیف خام هر جدول مبدأ طبق manifest بستهٔ HIF (§۵-۲): {"<table>": rows} از files[] با kind='raw'.
-- NULL یعنی manifest بدشکل است (files آرایه نیست، یا فایل raw بی‌جدول یا با rows ناعدد).
CREATE OR REPLACE FUNCTION migration.manifest_raw_counts(p_manifest jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE f jsonb; r jsonb := '{}'; t text;
BEGIN
  IF jsonb_typeof(p_manifest -> 'files') IS DISTINCT FROM 'array' THEN RETURN NULL; END IF;
  FOR f IN SELECT x FROM jsonb_array_elements(p_manifest -> 'files') x LOOP
    CONTINUE WHEN f ->> 'kind' IS DISTINCT FROM 'raw';
    t := f ->> 'table';
    IF coalesce(t, '') = '' OR jsonb_typeof(f -> 'rows') IS DISTINCT FROM 'number' OR (f ->> 'rows') !~ '^[0-9]{1,15}$' THEN
      RETURN NULL;
    END IF;
    r := r || jsonb_build_object(t, coalesce((r ->> t)::bigint, 0) + (f ->> 'rows')::bigint);
  END LOOP;
  RETURN r;
END $$;

-- INV-MIG-04 (RV-MG-18): ستون row_count_total همان manifest.row_count_total و جمع files[].rows فایل‌های raw است
CREATE OR REPLACE FUNCTION migration.manifest_rows_ok(p_manifest jsonb, p_total bigint) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE c jsonb := migration.manifest_raw_counts(p_manifest); s bigint := 0; k text;
BEGIN
  IF c IS NULL OR jsonb_typeof(p_manifest -> 'row_count_total') IS DISTINCT FROM 'number'
     OR (p_manifest ->> 'row_count_total') !~ '^[0-9]{1,15}$' OR (p_manifest ->> 'row_count_total')::bigint <> p_total THEN
    RETURN false;
  END IF;
  FOR k IN SELECT jsonb_object_keys(c) LOOP s := s + (c ->> k)::bigint; END LOOP;
  RETURN s = p_total;
END $$;

-- ترتیب ثابت مرحله‌های commit (D-MG17؛ RV-MG-15). inventory_conversion: سند تبدیل ادواری به دائمی در D-1 (RV-MG-21).
CREATE OR REPLACE FUNCTION migration.stage_rank(p_stage text) RETURNS integer
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
SELECT CASE p_stage WHEN 'masterdata' THEN 1 WHEN 'coa' THEN 2 WHEN 'dimensions' THEN 3 WHEN 'funds' THEN 4
                    WHEN 'opening_gl' THEN 5 WHEN 'history_gl' THEN 6 WHEN 'regenerated_docs' THEN 7
                    WHEN 'inventory_conversion' THEN 8 WHEN 'subledger_positions' THEN 9 WHEN 'tax_continuity' THEN 10
                    WHEN 'payroll' THEN 11 WHEN 'archive' THEN 12 END
$$;

-- RV-MG-22: dry-run حالت full_tx همان کد commit را روی کار validated اجرا می‌کند. GUC تراکنشی hk.migration_dry_run='on'
-- (رجیستری R-GUC بخش ۰۲) گیت‌های «فقط committing» را برای همان تراکنش باز می‌کند و نگهبان تأخیری هر COMMIT آن را رد می‌کند.
CREATE OR REPLACE FUNCTION migration.in_dry_run() RETURNS boolean
LANGUAGE sql STABLE PARALLEL SAFE AS $$
SELECT coalesce(current_setting('hk.migration_dry_run', true), '') = 'on'
$$;

-- RV-MG-13: کنش انسانی (امضای رضایت، تأیید واحد، پذیرش پیش‌نمایش، تأیید زنده شدن، تأیید توضیح، تأیید نگاشت، override)
-- فقط کار خود کاربر جاری است: app.user_id تنظیم و برابر ستون باشد، و نه از دستیار (app.actor_via). کنش critical
-- (p_critical) فقط مستقیم و بدون نشست ورود به‌جای کاربر است؛ بقیه تأیید پیشنهاد دستیار (assistant_confirm) را هم می‌پذیرند.
CREATE OR REPLACE FUNCTION migration.assert_human_act(p_user uuid, p_what text, p_critical boolean DEFAULT false) RETURNS void
LANGUAGE plpgsql STABLE AS $$
DECLARE v_via text := coalesce(nullif(current_setting('app.actor_via', true), ''), 'direct');
BEGIN
  IF core.current_user_id() IS NULL OR p_user IS DISTINCT FROM core.current_user_id() THEN
    PERFORM migration.raise_error('HK_MIG_ACTOR', format('%s is recorded only as the acting user''s own act', p_what));
  END IF;
  IF NOT (v_via = 'direct' OR (v_via = 'assistant_confirm' AND NOT p_critical)) THEN
    PERFORM migration.raise_error('HK_MIG_ACTOR', format('%s is not allowed when app.actor_via = %s', p_what, v_via));
  END IF;
  IF p_critical AND coalesce(current_setting('app.impersonation_session_id', true), '') <> '' THEN
    PERFORM migration.raise_error('HK_MIG_ACTOR', format('%s is never done through impersonation', p_what));
  END IF;
END $$;

-- =====================================================================
-- ۲. کاتالوگ‌های سراسری (بدون tenant_id؛ hk_app فقط SELECT؛ پر شدن فقط با migration پایگاه داده
--    یا بستهٔ امضاشدهٔ انتشار از پنل مالک که فرایند migrate با hk_migrator اعمال می‌کند)
-- =====================================================================
CREATE TABLE IF NOT EXISTS migration.source_system (
  code            text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{1,30}$'),
  name_fa         text NOT NULL,
  name_en         text NOT NULL,
  kind            text NOT NULL CHECK (kind IN ('vendor','generic','government','bank')),
  channels        text[] NOT NULL CHECK (cardinality(channels) >= 1 AND channels <@ ARRAY['api','agent','backup','file']::text[]),
  support_status  text NOT NULL CHECK (support_status IN ('supported','beta','probe_only','planned')),
  phase           text NOT NULL CHECK (phase IN ('v1','v1_conditional','v2','later')),
  notes           text,
  introduced_in   text NOT NULL
);

-- پروفایل نگاشت فروشنده (vendor@version) به‌صورت داده؛ کد پایتون فقط موتور اجراست.
CREATE TABLE IF NOT EXISTS migration.profile (
  code                     text NOT NULL CHECK (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  version                  integer NOT NULL CHECK (version >= 1),
  source_system            text NOT NULL REFERENCES migration.source_system(code),
  title                    text NOT NULL,
  channel                  text NOT NULL CHECK (channel IN ('api','agent','backup','file')),
  source_versions          text NOT NULL,                 -- توصیف بازهٔ نسخهٔ نرم‌افزار مبدأ، مثل 'holoo classic 1395..1405'
  fingerprint              jsonb NOT NULL CHECK (jsonb_typeof(fingerprint) = 'object'),   -- قواعد تشخیص (جدول‌ها، ستون‌ها، امتیاز)
  spec                     jsonb NOT NULL CHECK (jsonb_typeof(spec) = 'object'),          -- کوئری‌های allowlist، نگاشت ستون، قواعد پارتیشن
  spec_sha256              bytea NOT NULL CHECK (octet_length(spec_sha256) = 32),
  status                   text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','beta','published','retired')),
  confidence               text NOT NULL CHECK (confidence IN ('high','medium','low')),
  golden_dataset_ref       text,                           -- شناسهٔ دیتاست طلایی مصنوعی در مخزن آزمون
  real_sample_verified_at  timestamptz,                    -- آزمون روی دست‌کم یک دیتابیس واقعی با رضایت کتبی
  published_at             timestamptz,
  PRIMARY KEY (code, version),
  -- INV-MIG-28: پروفایل منتشرشده دیتاست طلایی و آزمون روی دادهٔ واقعی دارد و اطمینانش «پایین» نیست
  CHECK (status NOT IN ('published') OR (golden_dataset_ref IS NOT NULL AND real_sample_verified_at IS NOT NULL
                                         AND published_at IS NOT NULL AND confidence <> 'low')),
  CHECK (status <> 'beta' OR golden_dataset_ref IS NOT NULL)
);

-- فرهنگ مترادف سرستون‌ها (سراسری؛ ارتقای نگاشت‌های پرتکرار مستأجرها با تأیید در پنل مالک)
CREATE TABLE IF NOT EXISTS migration.header_synonym (
  id             uuid PRIMARY KEY DEFAULT uuidv7(),
  field_key      text NOT NULL CHECK (field_key ~ '^[a-z][a-z0-9_]{1,60}$'),
  entity         text,                                -- NULL = همهٔ موجودیت‌ها
  source_system  text REFERENCES migration.source_system(code),   -- NULL = همهٔ مبدأها
  synonym_norm   text NOT NULL CHECK (char_length(synonym_norm) BETWEEN 1 AND 120 AND synonym_norm = migration.norm_header(synonym_norm)),
  dict_version   integer NOT NULL CHECK (dict_version >= 1),
  origin         text NOT NULL CHECK (origin IN ('seed','promoted')),
  status         text NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired'))
);
-- INV-MIG-25: هر مترادف فعال در هر (موجودیت، مبدأ) فقط به یک فیلد اشاره می‌کند (تطبیق قطعی است)
CREATE UNIQUE INDEX IF NOT EXISTS header_synonym_active_uq
  ON migration.header_synonym (entity, source_system, synonym_norm) NULLS NOT DISTINCT WHERE status = 'active';

-- قالب جامع Excel (T00..T17 و T11b): کلید انگلیسی ثابت در ردیف مخفی + عنوان فارسی (کلید i18n)
CREATE TABLE IF NOT EXISTS migration.template_column (
  template_version  integer NOT NULL CHECK (template_version >= 1),
  sheet_code        text NOT NULL CHECK (sheet_code ~ '^T(0[0-9]|1[0-7])b?$'),
  sheet_entity      text NOT NULL,
  column_key        text NOT NULL CHECK (column_key ~ '^[a-z][a-z0-9_]{0,60}$'),
  ordinal           smallint NOT NULL CHECK (ordinal >= 1),
  is_required       boolean NOT NULL,
  data_type         text NOT NULL CHECK (data_type IN ('text','code','int','decimal','amount','qty','rate','date','bool','enum')),
  enum_values       text[],
  title_key         text NOT NULL,
  -- اجبار شرطی (RV-MG-20): ستون وقتی اجباری است که ستون نام‌برده (همان شیت یا شیت سرآیند) پر باشد؛ مثل sstid سطر T15b
  -- وقتی فاکتور در T15 شمارهٔ مالیاتی دارد. اعتبارسنج در نبودش MIG_SSTID_REQUIRED یا MIG_REQUIRED_MISSING می‌دهد.
  required_if       text CHECK (required_if IS NULL OR required_if ~ '^T(0[0-9]|1[0-7])b?\.[a-z][a-z0-9_]{0,60}$'),
  PRIMARY KEY (template_version, sheet_code, column_key),
  UNIQUE (template_version, sheet_code, ordinal),
  CHECK ((data_type = 'enum') = (enum_values IS NOT NULL)),
  CHECK (NOT (is_required AND required_if IS NOT NULL))
);

-- کاتالوگ کد مشکل اعتبارسنجی (شدت پیش‌فرض، قابلیت override، مجوز override)
CREATE TABLE IF NOT EXISTS migration.issue_code (
  code                 text PRIMARY KEY CHECK (code ~ '^MIG_[A-Z0-9_]{3,60}$'),
  category             text NOT NULL CHECK (category IN ('structural','referential','checksum','business','duplicate',
                                                         'reconciliation','security','partition','unit','continuity')),
  default_severity     text NOT NULL CHECK (default_severity IN ('error','warning','info')),
  overridable          boolean NOT NULL,
  override_permission  text REFERENCES core.permission(code),
  message_key          text NOT NULL,
  introduced_in        text NOT NULL,
  CHECK (NOT overridable OR override_permission IS NOT NULL),
  CHECK (default_severity <> 'info' OR NOT overridable)
);

-- پارتیشن انحصاری اسناد مبدأ: کلاس → وضعیت‌های مجاز (هر سند دقیقاً یک کلاس و یک وضعیت)
CREATE TABLE IF NOT EXISTS migration.partition_rule (
  partition_class  text NOT NULL CHECK (partition_class IN ('OPENING','SKIP_CONTROL','CLOSING','CHEQUE','INVOICE',
                                                             'RECEIPT_PAYMENT','EXPENSE_INCOME','MANUAL','UNCLASSIFIED')),
  disposition      text NOT NULL CHECK (disposition IN ('opening_gl','history_gl','regenerate','skip','archive','blocked')),
  is_default       boolean NOT NULL DEFAULT false,
  phase            text NOT NULL CHECK (phase IN ('v1','v2')),
  description_key  text NOT NULL,
  PRIMARY KEY (partition_class, disposition),
  CHECK ((partition_class = 'UNCLASSIFIED') = (disposition = 'blocked') OR disposition = 'archive')
);
CREATE UNIQUE INDEX IF NOT EXISTS partition_rule_one_default ON migration.partition_rule (partition_class) WHERE is_default;

-- =====================================================================
-- ۳. جدول‌های مستأجری
-- =====================================================================

-- ---------- ۳-۱. کار مهاجرت ----------
CREATE TABLE IF NOT EXISTS migration.job (
  tenant_id                 uuid NOT NULL REFERENCES core.tenant(id),
  id                        uuid NOT NULL DEFAULT uuidv7(),
  company_id                uuid NOT NULL,
  title                     text NOT NULL CHECK (char_length(title) BETWEEN 1 AND 200),
  source_system             text NOT NULL REFERENCES migration.source_system(code),
  source_version            text,
  source_scope              text NOT NULL DEFAULT '' CHECK (char_length(source_scope) <= 120),   -- مثل Holoo1 یا Sepidar01/1405
  channel                   text NOT NULL CHECK (channel IN ('api','agent','backup','file')),
  mode                      text NOT NULL CHECK (mode IN ('opening','current_fy','archive')),
  cutover_date              date NOT NULL,
  fiscal_year_id            uuid,
  amount_unit               core.amount_unit NOT NULL,
  amount_unit_confirmed_by  uuid,
  amount_unit_confirmed_at  timestamptz,
  coding_mode               text NOT NULL DEFAULT 'standard' CHECK (coding_mode IN ('standard','keep_legacy')),
  coa_template_code         text,
  coa_template_version      integer,
  profile_code              text,
  profile_version           integer,
  status                    text NOT NULL DEFAULT 'draft'
                            CHECK (status IN ('draft','awaiting_source','staged','mapping','validated','previewed','committing',
                                              'committed','reconciled','live','rolling_back','rolled_back','cancelled','failed')),
  status_changed_at         timestamptz NOT NULL DEFAULT now(),
  consent_id                uuid,
  assisted                  boolean NOT NULL DEFAULT false,
  support_grant_id          uuid,
  is_rehearsal              boolean NOT NULL DEFAULT false,
  inputs_hash               bytea CHECK (inputs_hash IS NULL OR octet_length(inputs_hash) = 32),
  preview_dry_run_id        uuid,
  preview_accepted_by       uuid,
  preview_accepted_at       timestamptz,
  reconciliation_id         uuid,
  golive_approved_by        uuid,
  golive_approved_at        timestamptz,
  golive_client_ip          inet,
  locked_at                 timestamptz,
  rolled_back_at            timestamptz,
  cancelled_at              timestamptz,
  failure_code              text,
  failure_detail            text,
  raw_retain_until          timestamptz,
  created_by                uuid NOT NULL,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  row_version               integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, fiscal_year_id) REFERENCES ledger.fiscal_year(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, support_grant_id) REFERENCES core.support_access_grant(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, amount_unit_confirmed_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, preview_accepted_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, golive_approved_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (profile_code, profile_version) REFERENCES migration.profile(code, version),
  CHECK ((amount_unit_confirmed_by IS NULL) = (amount_unit_confirmed_at IS NULL)),
  CHECK ((preview_accepted_by IS NULL) = (preview_accepted_at IS NULL)),
  CHECK ((golive_approved_by IS NULL) = (golive_approved_at IS NULL)),
  CHECK ((profile_code IS NULL) = (profile_version IS NULL)),
  CHECK ((coa_template_code IS NULL) = (coa_template_version IS NULL)),
  CHECK (assisted = (support_grant_id IS NOT NULL)),
  -- INV-MIG-22: کار آزمایشی (شرکت تمرینی) هرگز زنده نمی‌شود
  CHECK (NOT (is_rehearsal AND status = 'live')),
  CHECK ((status = 'live') = (locked_at IS NOT NULL)),
  CHECK (status <> 'failed' OR failure_code IS NOT NULL)
);
SELECT core.enable_tenant_rls('migration.job');
-- INV-MIG-21: در هر شرکت حداکثر یک کار ثبت‌کننده (غیرآرشیو) فعال
CREATE UNIQUE INDEX IF NOT EXISTS job_one_active_per_company
  ON migration.job (tenant_id, company_id)
  WHERE mode <> 'archive' AND status NOT IN ('live','rolled_back','cancelled');
CREATE INDEX IF NOT EXISTS job_status_idx ON migration.job (tenant_id, status, status_changed_at);

-- تاریخچهٔ گذار وضعیت (فقط‌افزودنی؛ تریگر job می‌نویسد)
CREATE TABLE IF NOT EXISTS migration.job_event (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  job_id       uuid NOT NULL,
  from_status  text NOT NULL,
  to_status    text NOT NULL,
  actor_id     uuid,
  at           timestamptz NOT NULL DEFAULT now(),
  note         text,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, job_id) REFERENCES migration.job(tenant_id, id),
  FOREIGN KEY (tenant_id, actor_id) REFERENCES core.tenant_membership(tenant_id, user_id)
);
SELECT core.enable_tenant_rls('migration.job_event');
CREATE INDEX IF NOT EXISTS job_event_job_idx ON migration.job_event (tenant_id, job_id, at);

-- ---------- ۳-۲. رضایت مالک داده ----------
CREATE TABLE IF NOT EXISTS migration.consent (
  tenant_id                   uuid NOT NULL REFERENCES core.tenant(id),
  id                          uuid NOT NULL DEFAULT uuidv7(),
  job_id                      uuid NOT NULL,
  kind                        text NOT NULL CHECK (kind IN ('data_owner_migration','backup_processing','third_party_api',
                                                            'agent_execution','assisted_access','ai_mapping_suggestions',
                                                            'raw_retention_extended')),
  statement_code              text NOT NULL CHECK (statement_code ~ '^[a-z][a-z0-9_.]{2,60}$'),
  statement_version           integer NOT NULL CHECK (statement_version >= 1),
  statement_sha256            bytea NOT NULL CHECK (octet_length(statement_sha256) = 32),   -- hash متن دقیق نمایش‌داده‌شده
  signer_user_id              uuid NOT NULL,
  signer_full_name            text NOT NULL CHECK (char_length(signer_full_name) BETWEEN 3 AND 200
                                                   AND signer_full_name = core.fa_normalize_text(signer_full_name)),
  signer_capacity             text NOT NULL CHECK (signer_capacity IN ('owner','legal_representative','authorized_accountant')),
  written_form_attachment_id  uuid,                    -- فرم کتبی اسکن‌شده (خدمت حضوری)
  scope                       jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(scope) = 'object'),
  accepted_at                 timestamptz NOT NULL DEFAULT now(),
  valid_until                 timestamptz NOT NULL,
  client_ip                   inet,
  user_agent_sha256           bytea CHECK (user_agent_sha256 IS NULL OR octet_length(user_agent_sha256) = 32),
  revoked_at                  timestamptz,
  revoked_by                  uuid,
  revoke_reason               text,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, job_id, id),
  FOREIGN KEY (tenant_id, job_id) REFERENCES migration.job(tenant_id, id),
  FOREIGN KEY (tenant_id, signer_user_id) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, revoked_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, written_form_attachment_id) REFERENCES core.attachment(tenant_id, id),
  CHECK (valid_until > accepted_at AND valid_until <= accepted_at + interval '366 days'),
  CHECK ((revoked_at IS NULL) = (revoked_by IS NULL) AND (revoked_at IS NULL) = (revoke_reason IS NULL)),
  CHECK (revoke_reason IS NULL OR char_length(btrim(revoke_reason)) >= 10)
);
SELECT core.enable_tenant_rls('migration.consent');
CREATE INDEX IF NOT EXISTS consent_job_idx ON migration.consent (tenant_id, job_id, kind);

ALTER TABLE migration.job DROP CONSTRAINT IF EXISTS job_consent_fk;
ALTER TABLE migration.job ADD CONSTRAINT job_consent_fk
  FOREIGN KEY (tenant_id, id, consent_id) REFERENCES migration.consent(tenant_id, job_id, id);

-- ---------- ۳-۳. سیاست پارتیشن برای هر کار (کلاس → یک وضعیت) ----------
CREATE TABLE IF NOT EXISTS migration.job_partition_policy (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  job_id           uuid NOT NULL,
  partition_class  text NOT NULL,
  disposition      text NOT NULL,
  chosen_by        uuid,
  chosen_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, job_id, partition_class),       -- INV-MIG-08: هر کلاس در هر کار دقیقاً یک وضعیت
  FOREIGN KEY (tenant_id, job_id) REFERENCES migration.job(tenant_id, id),
  FOREIGN KEY (partition_class, disposition) REFERENCES migration.partition_rule(partition_class, disposition),
  FOREIGN KEY (tenant_id, chosen_by) REFERENCES core.tenant_membership(tenant_id, user_id)
);
SELECT core.enable_tenant_rls('migration.job_partition_policy');

-- ---------- ۳-۴. اعتبارنامهٔ API ابری (فقط ارجاع به KeyManager؛ راز هرگز در پایگاه داده نیست) ----------
CREATE TABLE IF NOT EXISTS migration.source_credential (
  tenant_id      uuid NOT NULL REFERENCES core.tenant(id),
  id             uuid NOT NULL DEFAULT uuidv7(),
  job_id         uuid NOT NULL,
  kind           text NOT NULL CHECK (kind IN ('hesabfa_api','mahak_sync','sepidar_ws','tncholoo')),
  endpoint_base  text NOT NULL CHECK (endpoint_base ~ '^https://[a-z0-9.-]+(:[0-9]{2,5})?/' OR kind IN ('sepidar_ws','tncholoo')),
  secret_ref     text NOT NULL CHECK (secret_ref ~ '^secret://[a-z0-9/_.-]+$'),
  status         text NOT NULL DEFAULT 'active' CHECK (status IN ('active','purged','revoked')),
  purge_after    timestamptz NOT NULL,
  purged_at      timestamptz,
  created_by     uuid NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  row_version    integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, job_id) REFERENCES migration.job(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK ((status = 'purged') = (purged_at IS NOT NULL)),
  CHECK (purge_after <= created_at + interval '30 days')     -- INV-MIG-31
);
SELECT core.enable_tenant_rls('migration.source_credential');

-- ---------- ۳-۵. نشست عامل ویندوزی (جفت‌سازی با کد یک‌بارمصرف + کلید Ed25519) ----------
CREATE TABLE IF NOT EXISTS migration.agent_session (
  tenant_id                 uuid NOT NULL REFERENCES core.tenant(id),
  id                        uuid NOT NULL DEFAULT uuidv7(),
  job_id                    uuid NOT NULL,
  pairing_code_hash         bytea NOT NULL CHECK (octet_length(pairing_code_hash) = 32),
  status                    text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','paired','completed','revoked','expired')),
  expires_at                timestamptz NOT NULL,
  agent_public_key          bytea CHECK (agent_public_key IS NULL OR octet_length(agent_public_key) = 32),
  agent_version             text,
  agent_build_sha256        bytea CHECK (agent_build_sha256 IS NULL OR octet_length(agent_build_sha256) = 32),
  host_os                   text,
  host_fingerprint_sha256   bytea CHECK (host_fingerprint_sha256 IS NULL OR octet_length(host_fingerprint_sha256) = 32),
  sql_server_version        text,
  sql_compat_level          smallint,
  db_driver                 text CHECK (db_driver IS NULL OR db_driver IN ('odbc18','odbc17','pytds')),
  trust_server_certificate  boolean,
  login_is_privileged       boolean,                 -- sysadmin/db_owner تشخیص داده شد (هشدار؛ §۵-۹)
  token_hash                bytea CHECK (token_hash IS NULL OR octet_length(token_hash) = 32),
  token_expires_at          timestamptz,
  paired_at                 timestamptz,
  last_seen_at              timestamptz,
  created_by                uuid NOT NULL,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  row_version               integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, job_id, id),
  FOREIGN KEY (tenant_id, job_id) REFERENCES migration.job(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (expires_at <= created_at + interval '24 hours'),                          -- INV-MIG-32
  CHECK (status NOT IN ('paired','completed') OR (agent_public_key IS NOT NULL AND paired_at IS NOT NULL)),
  CHECK ((token_hash IS NULL) = (token_expires_at IS NULL)),
  CHECK (token_hash IS NULL OR status = 'paired')
);
SELECT core.enable_tenant_rls('migration.agent_session');

-- ---------- ۳-۶. فایل بارگذاری‌شده (اکسل، CSV، بکاپ، DBF، بستهٔ HIF، ...) ----------
CREATE TABLE IF NOT EXISTS migration.upload (
  tenant_id           uuid NOT NULL REFERENCES core.tenant(id),
  id                  uuid NOT NULL DEFAULT uuidv7(),
  job_id              uuid NOT NULL,
  kind                text NOT NULL CHECK (kind IN ('hif','backup','excel','csv','dbf','eledger','trial_balance','report',
                                                    'bank_statement','zip','other')),
  file_name           text NOT NULL CHECK (char_length(file_name) BETWEEN 1 AND 255 AND file_name !~ '[/\\]'
                                           AND file_name = core.fa_normalize_text(file_name)),
  size_bytes          bigint CHECK (size_bytes IS NULL OR size_bytes BETWEEN 1 AND 68719476736),   -- سقف سخت ۶۴ GiB
  sha256              bytea CHECK (sha256 IS NULL OR octet_length(sha256) = 32),
  sniffed_format      text CHECK (sniffed_format IS NULL OR sniffed_format IN ('mtf','zip','xlsx','xls','csv','dbf','hif','pdf','unknown')),
  amount_unit         core.amount_unit,           -- NULL = واحد کار؛ برای فایل پولی با واحد متفاوت صریح
  storage_backend     text NOT NULL CHECK (storage_backend IN ('s3','fs')),
  bucket              text NOT NULL,
  object_key          text NOT NULL,
  encryption_key_ref  text NOT NULL,
  status              text NOT NULL DEFAULT 'pending_upload'
                      CHECK (status IN ('pending_upload','uploaded','scanning','accepted','rejected','purged')),
  reject_code         text REFERENCES migration.issue_code(code),
  purge_after         timestamptz NOT NULL,
  purged_at           timestamptz,
  uploaded_by         uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  uploaded_at         timestamptz,
  updated_at          timestamptz NOT NULL DEFAULT now(),
  row_version         integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, job_id, id),
  UNIQUE (storage_backend, bucket, object_key),
  FOREIGN KEY (tenant_id, job_id) REFERENCES migration.job(tenant_id, id),
  FOREIGN KEY (tenant_id, uploaded_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  -- INV-MIG-29: فضای نام شیء هر مستأجر و هر کار جداست
  CHECK (object_key = 't/' || tenant_id::text || '/migration/' || job_id::text || '/' || id::text),
  CHECK ((status = 'purged') = (purged_at IS NOT NULL)),
  CHECK (status IN ('pending_upload','rejected','purged') OR (size_bytes IS NOT NULL AND sha256 IS NOT NULL AND uploaded_at IS NOT NULL)),
  CHECK ((status = 'rejected') = (reject_code IS NOT NULL) OR status = 'purged'),
  -- INV-MIG-30: بکاپ فقط با سرآیند شناخته‌شده (MTF یا ZIP) پذیرفته می‌شود؛ RESTORE روی قالب ناشناخته ممنوع
  CHECK (NOT (kind = 'backup' AND status = 'accepted' AND sniffed_format NOT IN ('mtf','zip'))),
  CHECK (NOT (kind = 'hif' AND status = 'accepted' AND sniffed_format <> 'hif')),
  CHECK (purge_after <= created_at + interval '400 days')
);
SELECT core.enable_tenant_rls('migration.upload');
CREATE INDEX IF NOT EXISTS upload_purge_idx ON migration.upload (purge_after) WHERE status <> 'purged';

-- ---------- ۳-۷. بستهٔ HIF ----------
CREATE TABLE IF NOT EXISTS migration.package (
  tenant_id                  uuid NOT NULL REFERENCES core.tenant(id),
  id                         uuid NOT NULL DEFAULT uuidv7(),
  job_id                     uuid NOT NULL,
  upload_id                  uuid,
  producer                   text NOT NULL CHECK (producer IN ('agent','server_backup','server_api','server_file')),
  agent_session_id           uuid,
  format_version             text NOT NULL CHECK (format_version ~ '^hif/1(\.[0-9]{1,3})?$'),
  manifest                   jsonb NOT NULL CONSTRAINT package_a_manifest_object CHECK (jsonb_typeof(manifest) = 'object'),
  manifest_sha256            bytea NOT NULL CHECK (octet_length(manifest_sha256) = 32),
  signer_key_id              text NOT NULL,
  signature_verified_at      timestamptz,
  source_system              text NOT NULL REFERENCES migration.source_system(code),
  source_version             text,
  source_db                  text NOT NULL DEFAULT '',
  source_fingerprint_sha256  bytea CHECK (source_fingerprint_sha256 IS NULL OR octet_length(source_fingerprint_sha256) = 32),
  extractor                  text NOT NULL,                     -- 'hk-agent/2027.1.0' یا 'hk-extract/2027.1.0'
  profile_code               text,
  profile_version            integer,
  amount_unit                core.amount_unit NOT NULL,
  date_mode                  text NOT NULL CHECK (date_mode IN ('gregorian_datetime','jalali_text','excel_serial','mixed')),
  extracted_at               timestamptz NOT NULL,
  row_count_total            bigint NOT NULL CONSTRAINT package_a_row_count_nonneg CHECK (row_count_total >= 0),
  status                     text NOT NULL DEFAULT 'received' CHECK (status IN ('received','verified','rejected','superseded')),
  reject_code                text REFERENCES migration.issue_code(code),
  verified_at                timestamptz,
  superseded_at              timestamptz,
  created_at                 timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, job_id, id),
  FOREIGN KEY (tenant_id, job_id) REFERENCES migration.job(tenant_id, id),
  FOREIGN KEY (tenant_id, job_id, upload_id) REFERENCES migration.upload(tenant_id, job_id, id),
  FOREIGN KEY (tenant_id, job_id, agent_session_id) REFERENCES migration.agent_session(tenant_id, job_id, id),
  FOREIGN KEY (profile_code, profile_version) REFERENCES migration.profile(code, version),
  CHECK ((profile_code IS NULL) = (profile_version IS NULL)),
  CHECK ((producer = 'agent') = (agent_session_id IS NOT NULL)),
  CHECK (producer <> 'agent' OR upload_id IS NOT NULL),
  CHECK (status NOT IN ('verified','superseded') OR (signature_verified_at IS NOT NULL AND verified_at IS NOT NULL)),
  CHECK ((status = 'rejected') = (reject_code IS NOT NULL)),
  CHECK ((status = 'superseded') = (superseded_at IS NOT NULL)),
  -- INV-MIG-04 (RV-MG-18): شمار اعلام‌شده همان manifest است (row_count_total و جمع files[].rows فایل‌های raw)
  CHECK (migration.manifest_rows_ok(manifest, row_count_total))
);
SELECT core.enable_tenant_rls('migration.package');
-- INV-MIG-05: در هر کار حداکثر یک بستهٔ فعال
CREATE UNIQUE INDEX IF NOT EXISTS package_one_active ON migration.package (tenant_id, job_id) WHERE status IN ('received','verified');

-- ---------- ۳-۸. snapshot خام مبدأ (فقط‌افزودنی؛ حذف فقط در پاک‌سازی نگهداری) ----------
CREATE TABLE IF NOT EXISTS migration.raw_record (
  tenant_id       uuid NOT NULL REFERENCES core.tenant(id),
  id              uuid NOT NULL DEFAULT uuidv7(),
  job_id          uuid NOT NULL,
  package_id      uuid NOT NULL,
  source_system   text NOT NULL,
  source_db       text NOT NULL,
  source_table    text NOT NULL CHECK (char_length(source_table) BETWEEN 1 AND 128),
  source_key      text NOT NULL CHECK (char_length(source_key) BETWEEN 1 AND 512),
  row_no          bigint NOT NULL CHECK (row_no >= 1),
  payload         jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
  content_hash    bytea NOT NULL CHECK (octet_length(content_hash) = 32),
  source_deleted  boolean NOT NULL DEFAULT false,      -- [Delete] هلو / IsDeleted سپیدار: نگه داشته و گزارش می‌شود
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, job_id, id),
  UNIQUE (tenant_id, package_id, source_table, source_key),
  FOREIGN KEY (tenant_id, job_id, package_id) REFERENCES migration.package(tenant_id, job_id, id)
);
SELECT core.enable_tenant_rls('migration.raw_record');

-- ---------- ۳-۹. رکورد مرحله‌ای (مدل میانی کانونی CMM) ----------
CREATE TABLE IF NOT EXISTS migration.staged_record (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL DEFAULT uuidv7(),
  job_id             uuid NOT NULL,
  raw_record_id      uuid,
  parent_id          uuid,
  entity             text NOT NULL CHECK (entity IN (
                       'fiscal_year','currency','account','dimension_type','dimension_value','party','party_group',
                       'item','item_variant','item_category','uom','warehouse','price','bom','bom_line',
                       'bank_account','cash_box','petty_cash','card_terminal',
                       'opening_balance_line','open_document','cheque','bank_unreconciled_item','stock_opening','fixed_asset',
                       'voucher','voucher_line','invoice_history','invoice_line_history','receipt_payment',
                       'employee','payroll_ytd','tax_continuity','serial_history')),
  source_system      text NOT NULL,
  source_db          text NOT NULL,
  source_table       text NOT NULL,
  source_key         text NOT NULL CHECK (char_length(source_key) BETWEEN 1 AND 512),
  legacy_code        text,
  line_no            integer CHECK (line_no IS NULL OR line_no >= 1),
  normalized         jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(normalized) = 'object'),
  normalization_log  jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(normalization_log) = 'array'),
  mapped             jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(mapped) = 'object'),
  debit              core.amount CHECK (debit IS NULL OR debit >= 0),
  credit             core.amount CHECK (credit IS NULL OR credit >= 0),
  amount             core.amount,
  amount_unit        core.amount_unit,
  qty                core.qty,
  unit_cost          core.rate CHECK (unit_cost IS NULL OR unit_cost >= 0),
  total_value        core.amount,
  cost_status        text CHECK (cost_status IS NULL OR cost_status IN ('known','unknown','user_provided')),
  doc_date           date,
  partition_class    text,
  disposition        text,
  status             text NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending','valid','warning','blocked','excluded','committed','rolled_back')),
  exclusion_reason   text,
  target_kind        text,
  target_id          uuid,
  committed_chunk    integer,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  row_version        integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, job_id, id),
  -- INV-MIG-06: یک رکورد مرحله‌ای برای هر رکورد مبدأ و هر موجودیت در یک کار (lineage یکتا)
  UNIQUE (tenant_id, job_id, entity, source_system, source_db, source_table, source_key),
  FOREIGN KEY (tenant_id, job_id) REFERENCES migration.job(tenant_id, id),
  FOREIGN KEY (tenant_id, job_id, raw_record_id) REFERENCES migration.raw_record(tenant_id, job_id, id),
  FOREIGN KEY (tenant_id, job_id, parent_id) REFERENCES migration.staged_record(tenant_id, job_id, id),
  FOREIGN KEY (partition_class, disposition) REFERENCES migration.partition_rule(partition_class, disposition),
  -- INV-MIG-02: هر مبلغ ورودی واحد صریح دارد
  CHECK (amount_unit IS NOT NULL OR entity NOT IN ('opening_balance_line','open_document','cheque','bank_unreconciled_item',
         'stock_opening','fixed_asset','voucher','voucher_line','invoice_history','invoice_line_history','receipt_payment',
         'payroll_ytd','price')),
  -- سطرهای سند و تراز افتتاحیه: دقیقاً یک طرف مثبت (یا کنار گذاشته)
  CHECK (entity NOT IN ('voucher_line','opening_balance_line') OR status = 'excluded'
         OR (num_nonnulls(debit, credit) = 1 AND coalesce(debit, credit) > 0)),
  -- INV-MIG-11: بهای نامعلوم نامعلوم است، نه صفر
  CHECK (entity <> 'stock_opening' OR cost_status IS NOT NULL),
  CHECK (cost_status IS DISTINCT FROM 'unknown' OR (unit_cost IS NULL AND total_value IS NULL)),
  CHECK (cost_status NOT IN ('known','user_provided') OR unit_cost IS NOT NULL),
  CHECK (unit_cost IS DISTINCT FROM 0 OR cost_status = 'user_provided'),
  CHECK (entity NOT IN ('voucher_line','invoice_line_history','bom_line') OR parent_id IS NOT NULL),
  CHECK (entity <> 'voucher' OR status = 'pending' OR partition_class IS NOT NULL),
  CHECK ((partition_class IS NULL) = (disposition IS NULL)),
  CHECK (partition_class IS NULL OR entity = 'voucher'),
  CHECK ((status = 'excluded') = (exclusion_reason IS NOT NULL)),
  CHECK (status <> 'committed' OR committed_chunk IS NOT NULL),
  CHECK ((target_kind IS NULL) = (target_id IS NULL))
);
SELECT core.enable_tenant_rls('migration.staged_record');
CREATE INDEX IF NOT EXISTS staged_job_entity_idx ON migration.staged_record (tenant_id, job_id, entity, status);
CREATE INDEX IF NOT EXISTS staged_parent_idx ON migration.staged_record (tenant_id, job_id, parent_id) WHERE parent_id IS NOT NULL;

-- ---------- ۳-۱۰. نگاشت شناسهٔ مبدأ به مقصد (پایدار بین کارها؛ الگوی External ID) ----------
CREATE TABLE IF NOT EXISTS migration.id_map (
  tenant_id      uuid NOT NULL REFERENCES core.tenant(id),
  id             uuid NOT NULL DEFAULT uuidv7(),
  company_id     uuid,                                -- RV-MG-01: شرکت مقصد؛ NULL = مقصد مشترک مستأجر (شخص/کالای بی‌شرکت)
  source_system  text NOT NULL,
  source_db      text NOT NULL,
  source_table   text NOT NULL,
  source_key     text NOT NULL CHECK (char_length(source_key) BETWEEN 1 AND 512),
  target_kind    text NOT NULL CHECK (target_kind ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  target_id      uuid NOT NULL,
  link_method    text NOT NULL CHECK (link_method IN ('created','linked_existing','linked_by_identifier','merged')),
  content_hash   bytea NOT NULL CHECK (octet_length(content_hash) = 32),
  first_job_id   uuid NOT NULL,
  last_job_id    uuid NOT NULL,
  status         text NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired')),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  row_version    integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  -- INV-MIG-07: هر رکورد مبدأ برای هر نوع مقصد در هر شرکت (یا یک‌بار برای مقصد مشترک مستأجر) حداکثر یک مقصد دارد
  -- (اجرای دوباره = به‌روزرسانی، نه تکرار). RV-MG-01: شرکت دوم یا شرکت تمرینی همان مستأجر کلید جدا دارد.
  UNIQUE NULLS NOT DISTINCT (tenant_id, company_id, source_system, source_db, source_table, source_key, target_kind),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, first_job_id) REFERENCES migration.job(tenant_id, id),
  FOREIGN KEY (tenant_id, last_job_id) REFERENCES migration.job(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, first_job_id) REFERENCES migration.job(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, last_job_id) REFERENCES migration.job(tenant_id, company_id, id)
);
SELECT core.enable_tenant_rls('migration.id_map');
CREATE INDEX IF NOT EXISTS id_map_target_idx ON migration.id_map (tenant_id, target_kind, target_id);

-- ---------- ۳-۱۱. نگاشت ستون/مقدار/حساب (کاری یا حافظهٔ مستأجر) ----------
CREATE TABLE IF NOT EXISTS migration.mapping (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL DEFAULT uuidv7(),
  job_id             uuid,                                -- NULL = حافظهٔ مستأجر
  kind               text NOT NULL CHECK (kind IN ('column','value_unit','value_tax_rate','value_person_type','value_cheque_status',
                                                   'value_bool','account','dimension','party_link','item_link','bank_account',
                                                   'cash_box','warehouse','currency')),
  source_system      text REFERENCES migration.source_system(code),
  scope              text NOT NULL DEFAULT '' CHECK (char_length(scope) <= 120),
  source_value       text NOT NULL CHECK (char_length(source_value) BETWEEN 1 AND 500),
  source_value_norm  text NOT NULL CHECK (char_length(source_value_norm) BETWEEN 0 AND 500),
  target_value       text,
  target_ref         uuid,
  method             text NOT NULL CHECK (method IN ('template_key','tenant_memory','profile','synonym','exact_identifier',
                                                     'fuzzy','content','manual','ai_suggestion')),
  confidence         numeric(5,4) NOT NULL CHECK (confidence BETWEEN 0 AND 1),
  reason             text,
  status             text NOT NULL DEFAULT 'suggested' CHECK (status IN ('suggested','confirmed','rejected')),
  confirmed_by       uuid,
  confirmed_at       timestamptz,
  uses               integer NOT NULL DEFAULT 0 CHECK (uses >= 0),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  row_version        integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, job_id) REFERENCES migration.job(tenant_id, id),
  FOREIGN KEY (tenant_id, confirmed_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK ((confirmed_by IS NULL) = (confirmed_at IS NULL)),
  CHECK (status = 'rejected' OR num_nonnulls(target_value, target_ref) = 1),
  -- INV-MIG-10: پیشنهاد fuzzy، محتوا یا دستیار هرگز بدون تأیید انسانی قطعی نمی‌شود
  CHECK (status <> 'confirmed' OR method NOT IN ('fuzzy','content','ai_suggestion') OR confirmed_by IS NOT NULL),
  -- INV-MIG-09: نگاشت حساب، بانک، صندوق، انبار و پیوند شخص/کالا فقط قطعی (کلید قالب، پروفایل، شناسهٔ دقیق) یا با تأیید انسان
  CHECK (status <> 'confirmed' OR kind NOT IN ('account','bank_account','cash_box','warehouse','party_link','item_link','dimension')
         OR method IN ('template_key','profile','exact_identifier') OR confirmed_by IS NOT NULL),
  CHECK (method <> 'ai_suggestion' OR job_id IS NOT NULL)
);
SELECT core.enable_tenant_rls('migration.mapping');
CREATE UNIQUE INDEX IF NOT EXISTS mapping_scope_uq
  ON migration.mapping (tenant_id, job_id, kind, scope, source_value_norm) NULLS NOT DISTINCT WHERE status <> 'rejected';

-- ---------- ۳-۱۲. مشکل اعتبارسنجی ----------
CREATE TABLE IF NOT EXISTS migration.issue (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  job_id            uuid NOT NULL,
  staged_record_id  uuid,
  raw_record_id     uuid,
  upload_id         uuid,
  code              text NOT NULL REFERENCES migration.issue_code(code),
  severity          text NOT NULL CHECK (severity IN ('error','warning','info')),
  field             text,
  params            jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(params) = 'object'),
  status            text NOT NULL DEFAULT 'open' CHECK (status IN ('open','resolved','overridden')),
  override_reason   text,
  overridden_by     uuid,
  overridden_at     timestamptz,
  resolved_at       timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  row_version       integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, job_id) REFERENCES migration.job(tenant_id, id),
  FOREIGN KEY (tenant_id, job_id, staged_record_id) REFERENCES migration.staged_record(tenant_id, job_id, id),
  FOREIGN KEY (tenant_id, job_id, raw_record_id) REFERENCES migration.raw_record(tenant_id, job_id, id),
  FOREIGN KEY (tenant_id, job_id, upload_id) REFERENCES migration.upload(tenant_id, job_id, id),
  FOREIGN KEY (tenant_id, overridden_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK ((status = 'overridden') = (overridden_by IS NOT NULL AND overridden_at IS NOT NULL AND override_reason IS NOT NULL)),
  CHECK (override_reason IS NULL OR char_length(btrim(override_reason)) >= 10),
  CHECK ((status = 'resolved') = (resolved_at IS NOT NULL))
);
SELECT core.enable_tenant_rls('migration.issue');
CREATE INDEX IF NOT EXISTS issue_job_open_idx ON migration.issue (tenant_id, job_id, severity) WHERE status = 'open';
CREATE INDEX IF NOT EXISTS issue_staged_idx ON migration.issue (tenant_id, job_id, staged_record_id) WHERE staged_record_id IS NOT NULL;

-- ---------- ۳-۱۳. اجرای آزمایشی (Dry-run) — فقط‌افزودنی ----------
CREATE TABLE IF NOT EXISTS migration.dry_run (
  tenant_id      uuid NOT NULL REFERENCES core.tenant(id),
  id             uuid NOT NULL DEFAULT uuidv7(),
  job_id         uuid NOT NULL,
  seq            integer NOT NULL CHECK (seq >= 1),
  run_mode       text NOT NULL CHECK (run_mode IN ('full_tx','validate_only')),
  inputs_hash    bytea NOT NULL CHECK (octet_length(inputs_hash) = 32),
  started_at     timestamptz NOT NULL,
  finished_at    timestamptz NOT NULL DEFAULT now(),
  outcome        text NOT NULL CHECK (outcome IN ('ok','failed')),
  report         jsonb NOT NULL CHECK (jsonb_typeof(report) = 'object'),
  report_sha256  bytea NOT NULL CHECK (octet_length(report_sha256) = 32),
  error_code     text,
  started_by     uuid,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, job_id, id),
  UNIQUE (tenant_id, job_id, seq),
  FOREIGN KEY (tenant_id, job_id) REFERENCES migration.job(tenant_id, id),
  FOREIGN KEY (tenant_id, started_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK (finished_at >= started_at),
  CHECK ((outcome = 'failed') = (error_code IS NOT NULL))
);
SELECT core.enable_tenant_rls('migration.dry_run');

ALTER TABLE migration.job DROP CONSTRAINT IF EXISTS job_preview_dry_run_fk;
ALTER TABLE migration.job ADD CONSTRAINT job_preview_dry_run_fk
  FOREIGN KEY (tenant_id, id, preview_dry_run_id) REFERENCES migration.dry_run(tenant_id, job_id, id);

-- ---------- ۳-۱۴. تکهٔ ثبت (Commit chunk) — checkpoint و ادامه‌پذیری ----------
CREATE TABLE IF NOT EXISTS migration.commit_chunk (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  job_id        uuid NOT NULL,
  chunk_no      integer NOT NULL CHECK (chunk_no >= 1),
  stage         text NOT NULL CHECK (migration.stage_rank(stage) IS NOT NULL),   -- D-MG17: ترتیب ثابت در stage_rank
  status        text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','running','done','failed')),
  item_count    integer NOT NULL CONSTRAINT commit_chunk_a_item_count_nonneg CHECK (item_count >= 0),
  done_count    integer NOT NULL DEFAULT 0 CHECK (done_count >= 0),
  attempts      integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  started_at    timestamptz,
  finished_at   timestamptz,
  last_error    jsonb,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  row_version   integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, job_id, chunk_no),
  FOREIGN KEY (tenant_id, job_id) REFERENCES migration.job(tenant_id, id),
  CHECK (done_count <= item_count),
  CHECK (status <> 'done' OR (done_count = item_count AND finished_at IS NOT NULL)),
  CHECK (status <> 'failed' OR last_error IS NOT NULL)
);
SELECT core.enable_tenant_rls('migration.commit_chunk');

-- ---------- ۳-۱۵. ثبت‌های انجام‌شده با lineage (دفتر اثرهای مهاجرت) ----------
CREATE TABLE IF NOT EXISTS migration.posting (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  job_id            uuid NOT NULL,
  company_id        uuid NOT NULL,                     -- RV-MG-01: شرکت کار (تریگر از کار پر می‌کند؛ FK سه‌ستونی)
  chunk_no          integer NOT NULL,
  staged_record_id  uuid,                              -- پس از پاک‌سازی نگهداری NULL می‌شود (RV-MG-08)؛ lineage در ستون‌های زیر می‌ماند
  staged_entity     text,                              -- رونوشت تریگر از رکورد مرحله‌ای (RV-MG-08، RV-MG-19)
  legacy_code       text,
  partition_class   text,
  disposition       text,
  source_system     text NOT NULL,
  source_db         text NOT NULL,
  source_table      text NOT NULL,
  source_key        text NOT NULL,
  target_module     text NOT NULL CHECK (target_module IN ('ledger','parties','catalog','inventory','treasury','sales',
                                                           'purchase','assets','payroll','tax','migration')),
  target_doc_type   text NOT NULL CHECK (target_doc_type ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  target_doc_id     uuid NOT NULL,
  journal_id        uuid,
  gl_effect         text NOT NULL CHECK (gl_effect IN ('posted','none')),
  amount_base       core.amount,
  state             text NOT NULL DEFAULT 'live' CHECK (state IN ('live','compensated')),
  compensation_kind text CHECK (compensation_kind IN ('void','cancel','deactivate','revert')),
  compensation_doc_id uuid,
  compensated_at    timestamptz,
  posted_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, job_id) REFERENCES migration.job(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, job_id) REFERENCES migration.job(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, job_id, chunk_no) REFERENCES migration.commit_chunk(tenant_id, job_id, chunk_no),
  -- RV-MG-08/19: پاک‌سازی ردیف مرحله‌ای فقط همین ستون را NULL می‌کند؛ صدور .hkx هم آن را NULL می‌نویسد (قلاب صدور)
  FOREIGN KEY (tenant_id, job_id, staged_record_id) REFERENCES migration.staged_record(tenant_id, job_id, id)
    ON DELETE SET NULL (staged_record_id),
  -- RV-MG-07: سند دفتر کل از همان شرکت کار است
  FOREIGN KEY (tenant_id, company_id, journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  CHECK ((gl_effect = 'posted') = (journal_id IS NOT NULL)),
  -- RV-MG-15: جبران همیشه نوع دارد؛ جز غیرفعال‌سازی دادهٔ پایه، سند جبران دارد؛ اثر GL فقط با ابطال یا لغو سند جبران می‌شود
  CHECK ((state = 'compensated') = (compensated_at IS NOT NULL AND compensation_kind IS NOT NULL)),
  CHECK (state <> 'compensated' OR compensation_doc_id IS NOT NULL OR compensation_kind = 'deactivate'),
  CHECK (state <> 'compensated' OR gl_effect = 'none' OR compensation_kind IN ('void','cancel'))
);
SELECT core.enable_tenant_rls('migration.posting');
-- INV-MIG-03: هر سند مبدأ در هر شرکت حداکثر یک‌بار (برای هر نوع سند مقصد) به‌صورت زنده ثبت می‌شود (RV-MG-01: کلید شرکت‌دار)
CREATE UNIQUE INDEX IF NOT EXISTS posting_one_live_per_source
  ON migration.posting (tenant_id, company_id, source_system, source_db, source_table, source_key, target_doc_type) WHERE state = 'live';
CREATE INDEX IF NOT EXISTS posting_job_idx ON migration.posting (tenant_id, job_id, state);
-- RV-MG-25: drill-down «این سند از کجا آمد» (LineageQuery.for_journal)
CREATE INDEX IF NOT EXISTS posting_journal_idx ON migration.posting (tenant_id, journal_id) WHERE journal_id IS NOT NULL;

-- ---------- ۳-۱۶. ارقام کنترلی سمت مبدأ (فقط‌افزودنی) ----------
CREATE TABLE IF NOT EXISTS migration.source_balance (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  job_id       uuid NOT NULL,
  origin       text NOT NULL CHECK (origin IN ('source_db_query','tncholoo_api','hesabfa_api','uploaded_tb','eledger_file',
                                               'user_declared','source_summary_table')),
  as_of        date NOT NULL,
  key_kind     text NOT NULL CHECK (key_kind IN ('account','account_dim','party','bank','cash','petty_cash','cheque_open',
                                                 'item_wh_qty','item_wh_value','asset_cost','asset_accdep','doc_count','tb_total')),
  key          text NOT NULL,
  debit        numeric(28,6),
  credit       numeric(28,6),
  value        numeric(28,6),
  raw_text     text,                                    -- مقدار عیناً از منبع (مثل '3.25787252E8' از TncHoloo)
  amount_unit  core.amount_unit,
  captured_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, job_id) REFERENCES migration.job(tenant_id, id),
  CHECK (num_nonnulls(debit, credit, value) >= 1),
  CHECK (amount_unit IS NOT NULL OR key_kind IN ('item_wh_qty','doc_count'))
);
SELECT core.enable_tenant_rls('migration.source_balance');
CREATE INDEX IF NOT EXISTS source_balance_job_idx ON migration.source_balance (tenant_id, job_id, key_kind, key);

-- ---------- ۳-۱۷. توضیح اختلاف ----------
CREATE TABLE IF NOT EXISTS migration.explanation (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  job_id       uuid NOT NULL,
  check_kind   text NOT NULL,
  key          text NOT NULL,
  category     text NOT NULL CHECK (category IN ('source_inconsistency','unknown_cost','deleted_in_source','excluded_by_user',
                                                 'source_rounding','perpetual_vs_periodic','fx_rounding','source_summary_drift')),
  amount       numeric(28,6) NOT NULL CHECK (amount <> 0),
  description  text NOT NULL CHECK (char_length(btrim(description)) >= 10),
  evidence     jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(evidence) = 'object'),
  status       text NOT NULL DEFAULT 'proposed' CHECK (status IN ('proposed','approved','withdrawn')),
  created_by   uuid NOT NULL,
  approved_by  uuid,
  approved_at  timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  row_version  integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, job_id, id),
  FOREIGN KEY (tenant_id, job_id) REFERENCES migration.job(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  FOREIGN KEY (tenant_id, approved_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK ((approved_by IS NULL) = (approved_at IS NULL)),
  CHECK (status <> 'approved' OR approved_by IS NOT NULL),
  -- INV-MIG-19: اختلاف تراز آزمایشی و شمار اسناد فقط با دسته‌های مشخص و محدود توضیح‌پذیر است
  CHECK (check_kind NOT IN ('trial_balance','doc_count','clearing')
         OR category IN ('source_inconsistency','deleted_in_source','excluded_by_user','source_rounding')),
  CHECK (category <> 'unknown_cost' OR check_kind IN ('stock_value','control_account')),
  -- RV-MG-21 / INV-MIG-38: حساب کنترل (GL در برابر زیردفتر مقصد) تلورانس صفر دارد؛ فقط بهای نامعلومِ با GL معوق
  -- (inventory gl_status='deferred') توضیح‌پذیر است. اختلاف ادواری/دائمی با سند تبدیل بسته می‌شود، نه با توضیح.
  CHECK (check_kind <> 'control_account' OR category = 'unknown_cost'),
  CHECK (category <> 'perpetual_vs_periodic' OR check_kind = 'source_cross_check')
);
SELECT core.enable_tenant_rls('migration.explanation');

-- ---------- ۳-۱۸. تطبیق (فقط‌افزودنی) ----------
CREATE TABLE IF NOT EXISTS migration.reconciliation (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL DEFAULT uuidv7(),
  job_id             uuid NOT NULL,
  seq                integer NOT NULL CHECK (seq >= 1),
  as_of              date NOT NULL,
  status             text NOT NULL CHECK (status IN ('balanced','differences')),
  line_count         integer NOT NULL CHECK (line_count >= 1),
  unexplained_count  integer NOT NULL CHECK (unexplained_count >= 0),
  report_sha256      bytea NOT NULL CHECK (octet_length(report_sha256) = 32),
  created_by         uuid,
  created_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, job_id, id),
  UNIQUE (tenant_id, job_id, seq),
  FOREIGN KEY (tenant_id, job_id) REFERENCES migration.job(tenant_id, id),
  FOREIGN KEY (tenant_id, created_by) REFERENCES core.tenant_membership(tenant_id, user_id),
  CHECK ((status = 'balanced') = (unexplained_count = 0)),
  CHECK (unexplained_count <= line_count)
);
SELECT core.enable_tenant_rls('migration.reconciliation');

ALTER TABLE migration.job DROP CONSTRAINT IF EXISTS job_reconciliation_fk;
ALTER TABLE migration.job ADD CONSTRAINT job_reconciliation_fk
  FOREIGN KEY (tenant_id, id, reconciliation_id) REFERENCES migration.reconciliation(tenant_id, job_id, id);

CREATE TABLE IF NOT EXISTS migration.reconciliation_line (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL DEFAULT uuidv7(),
  job_id             uuid NOT NULL,
  reconciliation_id  uuid NOT NULL,
  line_no            integer NOT NULL CHECK (line_no >= 1),     -- RV-MG-04: ۱..line_count سرآیند؛ سطر دیرهنگام جا ندارد
  check_kind         text NOT NULL CHECK (check_kind IN ('trial_balance','control_account','party','bank','cash','petty_cash',
                                                         'cheque','stock_qty','stock_value','asset','doc_count','clearing',
                                                         'moadian_continuity','source_cross_check')),
  key                text NOT NULL,
  label              text,
  source_value       numeric(28,6) NOT NULL,
  target_value       numeric(28,6) NOT NULL,
  difference         numeric(28,6) GENERATED ALWAYS AS (target_value - source_value) STORED,
  explanation_id     uuid,
  line_status        text GENERATED ALWAYS AS (CASE WHEN target_value = source_value THEN 'match'
                                                    WHEN explanation_id IS NOT NULL THEN 'explained'
                                                    ELSE 'unexplained' END) STORED,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, reconciliation_id, check_kind, key),
  UNIQUE (tenant_id, reconciliation_id, line_no),
  FOREIGN KEY (tenant_id, job_id, reconciliation_id) REFERENCES migration.reconciliation(tenant_id, job_id, id),
  FOREIGN KEY (tenant_id, job_id, explanation_id) REFERENCES migration.explanation(tenant_id, job_id, id)
);
SELECT core.enable_tenant_rls('migration.reconciliation_line');

-- ---------- ۳-۱۹. تداوم سامانهٔ مؤدیان (هر حافظهٔ مالیاتی یک ردیف) ----------
CREATE TABLE IF NOT EXISTS migration.moadian_continuity (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  job_id           uuid NOT NULL,
  company_id       uuid NOT NULL,
  memory_id        text NOT NULL CONSTRAINT moadian_continuity_a_memory_id CHECK (memory_id ~ '^[A-Z0-9]{6}$'),
  last_inno        text NOT NULL CONSTRAINT moadian_continuity_a_last_inno CHECK (last_inno ~ '^[0-9A-F]{10}$'),
  last_taxid       text NOT NULL,
  connection_mode  text NOT NULL CHECK (connection_mode IN ('direct','trusted_company')),
  origin           text NOT NULL CHECK (origin IN ('template_t17','source_db','user_entry')),
  status           text NOT NULL DEFAULT 'staged' CHECK (status IN ('staged','committed','rolled_back')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  row_version      integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, job_id, memory_id),
  FOREIGN KEY (tenant_id, company_id, job_id) REFERENCES migration.job(tenant_id, company_id, id),
  -- INV-MIG-17: taxid معتبر (Verhoeff)، هم‌حافظه و سریالش همان آخرین inno است
  CHECK (migration.taxid_is_valid(last_taxid)),
  CHECK (substr(last_taxid, 1, 6) = memory_id AND substr(last_taxid, 12, 10) = last_inno)
);
SELECT core.enable_tenant_rls('migration.moadian_continuity');

-- ---------- ۳-۲۰. آرشیو سال‌های قبل (حالت C؛ بدون اثر بر مانده؛ فقط‌افزودنی) ----------
CREATE TABLE IF NOT EXISTS migration.archive_entry (
  tenant_id     uuid NOT NULL REFERENCES core.tenant(id),
  id            uuid NOT NULL DEFAULT uuidv7(),
  job_id        uuid NOT NULL,
  company_id    uuid NOT NULL,
  fiscal_label  text NOT NULL CHECK (char_length(fiscal_label) BETWEEN 1 AND 40),
  doc_kind      text NOT NULL CHECK (doc_kind IN ('voucher','sales_invoice','purchase_invoice','receipt','payment','cheque','other')),
  doc_no        text,
  doc_date      date,
  party_name    text,
  amount        core.amount,
  amount_unit   core.amount_unit NOT NULL,
  description   text,
  payload       jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
  source_system text NOT NULL,
  source_db     text NOT NULL DEFAULT '',
  source_table  text NOT NULL,
  source_key    text NOT NULL,
  search_key    text GENERATED ALWAYS AS (core.fa_search_key(coalesce(doc_no, '') || ' ' || coalesce(party_name, '') || ' '
                                                            || coalesce(description, ''))) STORED,
  created_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  -- RV-MG-27: دو پایگاه مبدأ (Holoo1/Holoo2؛ §۸ ردیف ۳۶) کلید جدا دارند
  UNIQUE (tenant_id, company_id, source_system, source_db, source_table, source_key, fiscal_label),
  FOREIGN KEY (tenant_id, company_id, job_id) REFERENCES migration.job(tenant_id, company_id, id)
);
SELECT core.enable_tenant_rls('migration.archive_entry');
CREATE INDEX IF NOT EXISTS archive_entry_search_idx ON migration.archive_entry USING gin (search_key gin_trgm_ops);
CREATE INDEX IF NOT EXISTS archive_entry_date_idx ON migration.archive_entry (tenant_id, company_id, doc_date);

-- =====================================================================
-- ۴. تریگرها
-- =====================================================================

CREATE OR REPLACE FUNCTION migration.job_status_of(p_tenant uuid, p_job uuid) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT status FROM migration.job WHERE tenant_id = p_tenant AND id = p_job
$$;

-- RV-MG-02: هر نوشتن فرزند وضعیت کار را با FOR SHARE می‌خواند. این قفل با قفل ردیفِ گذار وضعیت (FOR NO KEY UPDATE)
-- تعارض دارد؛ پس نوشتن فرزند و گذار کار سریالی‌اند: گیت گذار نوشتهٔ commitشدهٔ هم‌زمان را می‌بیند و نوشتنِ منتظر،
-- پس از commit گذار، وضعیت تازه را می‌خواند (READ COMMITTED آخرین نسخهٔ ردیف قفل‌شده را برمی‌گرداند).
CREATE OR REPLACE FUNCTION migration.lock_job_status(p_tenant uuid, p_job uuid) RETURNS text
LANGUAGE plpgsql VOLATILE AS $$
DECLARE v text;
BEGIN
  SELECT j.status INTO v FROM migration.job j WHERE j.tenant_id = p_tenant AND j.id = p_job FOR SHARE;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION migration.assert_job_status(p_tenant uuid, p_job uuid, p_allowed text[], p_what text) RETURNS void
LANGUAGE plpgsql VOLATILE AS $$
DECLARE v text := migration.lock_job_status(p_tenant, p_job);
BEGIN
  IF v IS NULL OR NOT (v = ANY (p_allowed)) THEN
    PERFORM migration.raise_error('HK_MIG_JOB_STATE', format('%s is not allowed while the job is %s', p_what, coalesce(v, 'missing')));
  END IF;
END $$;

-- گذارهای مجاز ماشین حالت کار. RV-MG-06: failed → validated حذف شد؛ بازگشت از failed همیشه از mapping (یا قبل‌تر) می‌گذرد.
CREATE OR REPLACE FUNCTION migration.job_transition_allowed(p_from text, p_to text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
SELECT (p_from, p_to) IN (
  ('draft','awaiting_source'), ('draft','cancelled'),
  ('awaiting_source','staged'), ('awaiting_source','cancelled'), ('awaiting_source','failed'),
  ('staged','mapping'), ('staged','awaiting_source'), ('staged','cancelled'), ('staged','failed'),
  ('mapping','validated'), ('mapping','awaiting_source'), ('mapping','cancelled'), ('mapping','failed'),
  ('validated','mapping'), ('validated','previewed'), ('validated','cancelled'), ('validated','failed'),
  ('previewed','mapping'), ('previewed','committing'), ('previewed','cancelled'),
  ('committing','committed'), ('committing','rolling_back'),
  ('committed','reconciled'), ('committed','rolling_back'),
  ('reconciled','committed'), ('reconciled','live'), ('reconciled','rolling_back'),
  ('rolling_back','rolled_back'),
  ('failed','awaiting_source'), ('failed','staged'), ('failed','mapping'), ('failed','cancelled')
)
$$;

CREATE OR REPLACE FUNCTION migration.consent_is_active(p_tenant uuid, p_job uuid, p_kind text) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM migration.consent c
                  WHERE c.tenant_id = p_tenant AND c.job_id = p_job AND c.kind = p_kind
                    AND c.revoked_at IS NULL AND c.valid_until > now())
$$;

-- RV-MG-17 / D-MG24: مهاجرت همراه‌با‌کارشناس فقط با رضایت پشتیبانی نوشتنی، لغونشده و در بازهٔ اعتبار
CREATE OR REPLACE FUNCTION migration.support_grant_ok(p_tenant uuid, p_grant uuid) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM core.support_access_grant g
                  WHERE g.tenant_id = p_tenant AND g.id = p_grant AND g.access_mode = 'read_write'
                    AND g.revoked_at IS NULL AND now() >= g.starts_at AND now() < g.expires_at)
$$;

CREATE OR REPLACE FUNCTION migration.job_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_kind     text;
  v_needed   text[] := ARRAY[]::text[];
  v_dr       record;
  v_rec      record;
  v_latest   uuid;
  -- وضعیت‌هایی که تنظیمات کار در آن‌ها تغییرپذیر است (RV-MG-05)
  c_open     CONSTANT text[] := ARRAY['draft','awaiting_source','staged','mapping','failed'];
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM migration.raise_error('HK_MIG_JOB_DELETE', 'migration jobs are never deleted; cancel or roll back instead');
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' OR NEW.consent_id IS NOT NULL OR NEW.inputs_hash IS NOT NULL OR NEW.preview_dry_run_id IS NOT NULL
       OR NEW.preview_accepted_by IS NOT NULL OR NEW.reconciliation_id IS NOT NULL OR NEW.golive_approved_by IS NOT NULL
       OR NEW.golive_client_ip IS NOT NULL OR NEW.locked_at IS NOT NULL OR NEW.rolled_back_at IS NOT NULL
       OR NEW.cancelled_at IS NOT NULL OR NEW.failure_code IS NOT NULL THEN
      PERFORM migration.raise_error('HK_MIG_JOB_INITIAL', 'a job starts as an empty draft');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM migration.source_system s WHERE s.code = NEW.source_system AND NEW.channel = ANY (s.channels)) THEN
      PERFORM migration.raise_error('HK_MIG_CHANNEL', format('source %s does not support channel %s', NEW.source_system, NEW.channel));
    END IF;
    IF NEW.support_grant_id IS NOT NULL AND NOT migration.support_grant_ok(NEW.tenant_id, NEW.support_grant_id) THEN
      PERFORM migration.raise_error('HK_MIG_SUPPORT_GRANT', 'an assisted job needs a valid, unrevoked read_write support grant');
    END IF;
    IF NEW.amount_unit_confirmed_by IS NOT NULL THEN
      PERFORM migration.assert_human_act(NEW.amount_unit_confirmed_by, 'confirming the amount unit');
      NEW.amount_unit_confirmed_at := now();
    END IF;
    NEW.created_at := now();
    NEW.status_changed_at := now();
    RETURN NEW;
  END IF;

  -- UPDATE ------------------------------------------------------------------
  IF (NEW.tenant_id, NEW.id, NEW.company_id, NEW.source_system, NEW.channel, NEW.mode, NEW.is_rehearsal, NEW.assisted,
      NEW.created_by, NEW.created_at)
     IS DISTINCT FROM (OLD.tenant_id, OLD.id, OLD.company_id, OLD.source_system, OLD.channel, OLD.mode, OLD.is_rehearsal, OLD.assisted,
      OLD.created_by, OLD.created_at) THEN
    PERFORM migration.raise_error('HK_MIG_JOB_IMMUTABLE', 'company, source, channel, mode, rehearsal and assisted flags are fixed at creation');
  END IF;
  IF OLD.status IN ('live','rolled_back','cancelled') THEN
    -- RV-MG-12: فهرست سفید. در کار پایانی جز مهلت نگهداری هیچ ستونی (از جمله شواهد زنده شدن، پذیرش و تأیید واحد) تغییر نمی‌کند.
    IF (to_jsonb(NEW) - 'raw_retain_until' - 'updated_at' - 'row_version')
       IS DISTINCT FROM (to_jsonb(OLD) - 'raw_retain_until' - 'updated_at' - 'row_version') THEN
      PERFORM migration.raise_error('HK_MIG_JOB_TERMINAL', format('job is %s; only retention metadata may change', OLD.status));
    END IF;
    RETURN NEW;
  END IF;
  -- زمان‌های وضعیت را فقط گیت‌ها می‌نویسند
  IF (NEW.status_changed_at, NEW.locked_at, NEW.rolled_back_at, NEW.cancelled_at)
     IS DISTINCT FROM (OLD.status_changed_at, OLD.locked_at, OLD.rolled_back_at, OLD.cancelled_at) THEN
    PERFORM migration.raise_error('HK_MIG_JOB_IMMUTABLE', 'status timestamps are written by the transition gates only');
  END IF;

  -- INV-MIG-13 (RV-MG-05): تنظیمات کار و تأیید واحد از validated به بعد منجمدند؛ هر اصلاح یعنی بازگشت به mapping
  IF NOT (OLD.status = ANY (c_open))
     AND (NEW.cutover_date, NEW.fiscal_year_id, NEW.amount_unit, NEW.coding_mode, NEW.profile_code, NEW.profile_version,
          NEW.coa_template_code, NEW.coa_template_version, NEW.amount_unit_confirmed_by, NEW.amount_unit_confirmed_at)
         IS DISTINCT FROM
         (OLD.cutover_date, OLD.fiscal_year_id, OLD.amount_unit, OLD.coding_mode, OLD.profile_code, OLD.profile_version,
          OLD.coa_template_code, OLD.coa_template_version, OLD.amount_unit_confirmed_by, OLD.amount_unit_confirmed_at) THEN
    PERFORM migration.raise_error('HK_MIG_INPUTS_FROZEN', 'job settings are frozen from validation on; move the job back to mapping first');
  END IF;
  IF NEW.inputs_hash IS DISTINCT FROM OLD.inputs_hash
     AND NOT (OLD.status = ANY (c_open || ARRAY['validated']) AND NEW.status = ANY (c_open || ARRAY['validated','cancelled'])) THEN
    PERFORM migration.raise_error('HK_MIG_INPUTS_FROZEN', 'inputs are frozen after preview; move the job back to mapping first');
  END IF;
  IF NEW.preview_dry_run_id IS DISTINCT FROM OLD.preview_dry_run_id
     AND NOT (OLD.status IN ('validated','previewed') AND NEW.status = 'previewed')
     AND NOT (NEW.status = 'mapping' AND OLD.status <> 'mapping') THEN
    PERFORM migration.raise_error('HK_MIG_INPUTS_FROZEN', 'the previewed dry-run is chosen only while the job is previewed');
  END IF;
  -- D-MG15: تغییر واحد، تأیید قبلی را باطل می‌کند؛ تأیید تازه کنش خود کاربر است (RV-MG-13) و زمانش زمان سرور
  IF NEW.amount_unit IS DISTINCT FROM OLD.amount_unit
     AND (NEW.amount_unit_confirmed_by, NEW.amount_unit_confirmed_at) IS NOT DISTINCT FROM (OLD.amount_unit_confirmed_by, OLD.amount_unit_confirmed_at) THEN
    NEW.amount_unit_confirmed_by := NULL;
    NEW.amount_unit_confirmed_at := NULL;
  ELSIF NEW.amount_unit_confirmed_by IS NOT NULL
        AND (NEW.amount_unit_confirmed_by, NEW.amount_unit_confirmed_at) IS DISTINCT FROM (OLD.amount_unit_confirmed_by, OLD.amount_unit_confirmed_at) THEN
    PERFORM migration.assert_human_act(NEW.amount_unit_confirmed_by, 'confirming the amount unit');
    NEW.amount_unit_confirmed_at := now();
  END IF;
  -- پذیرش پیش‌نمایش: یک‌بار، در previewed، کنش خود کاربر (RV-MG-12، RV-MG-13). گذار به mapping آن را پاک می‌کند.
  IF (NEW.preview_accepted_by, NEW.preview_accepted_at) IS DISTINCT FROM (OLD.preview_accepted_by, OLD.preview_accepted_at)
     AND NOT (NEW.status = 'mapping' AND OLD.status <> 'mapping') THEN
    IF OLD.preview_accepted_by IS NOT NULL OR NEW.preview_accepted_by IS NULL
       OR NOT (OLD.status = 'previewed' AND NEW.status IN ('previewed','committing')) THEN
      PERFORM migration.raise_error('HK_MIG_PREVIEW_STATE', 'the preview can be accepted only once, while the job is previewed');
    END IF;
    PERFORM migration.assert_human_act(NEW.preview_accepted_by, 'accepting the preview');
    NEW.preview_accepted_at := now();
  END IF;
  -- INV-MIG-24: تأیید زنده شدن (کنشگر، زمان، IP) فقط با گذار reconciled → live ثبت می‌شود
  IF (NEW.golive_approved_by, NEW.golive_approved_at, NEW.golive_client_ip)
     IS DISTINCT FROM (OLD.golive_approved_by, OLD.golive_approved_at, OLD.golive_client_ip)
     AND NOT (OLD.status = 'reconciled' AND NEW.status = 'live') THEN
    PERFORM migration.raise_error('HK_MIG_GOLIVE_STATE', 'go-live approval is recorded only with the reconciled → live transition');
  END IF;
  IF NEW.reconciliation_id IS DISTINCT FROM OLD.reconciliation_id AND OLD.status <> 'committed' THEN
    PERFORM migration.raise_error('HK_MIG_NOT_RECONCILED', 'move the job back to committed before switching reconciliations');
  END IF;
  -- RV-MG-16: رضایت را می‌توان در هر وضعیت غیرپایانی با رضایت مالک دادهٔ تازه و فعال همین کار عوض کرد (در job_event ثبت می‌شود)
  IF NEW.consent_id IS DISTINCT FROM OLD.consent_id AND OLD.status <> 'draft'
     AND (NEW.consent_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM migration.consent c
             WHERE c.tenant_id = NEW.tenant_id AND c.id = NEW.consent_id AND c.job_id = NEW.id
               AND c.kind = 'data_owner_migration' AND c.revoked_at IS NULL AND c.valid_until > now())) THEN
    PERFORM migration.raise_error('HK_MIG_CONSENT_FIXED', 'a running job can switch only to another active data-owner consent of the same job');
  END IF;
  -- RV-MG-17: تمدید رضایت پشتیبانی (حداکثر ۷ روزه) با رضایت معتبر دیگر
  IF NEW.support_grant_id IS DISTINCT FROM OLD.support_grant_id AND NOT migration.support_grant_ok(NEW.tenant_id, NEW.support_grant_id) THEN
    PERFORM migration.raise_error('HK_MIG_SUPPORT_GRANT', 'an assisted job needs a valid, unrevoked read_write support grant');
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT migration.job_transition_allowed(OLD.status, NEW.status) THEN
      PERFORM migration.raise_error('HK_MIG_JOB_TRANSITION', format('job transition %s -> %s is not allowed', OLD.status, NEW.status));
    END IF;
    NEW.status_changed_at := now();

    -- INV-MIG-01: هیچ گام رو به جلو بدون رضایت فعال مالک داده
    IF NEW.status NOT IN ('cancelled','failed','rolling_back','rolled_back') THEN
      IF NEW.consent_id IS NULL OR NOT EXISTS (
           SELECT 1 FROM migration.consent c
            WHERE c.tenant_id = NEW.tenant_id AND c.id = NEW.consent_id AND c.job_id = NEW.id
              AND c.kind = 'data_owner_migration' AND c.revoked_at IS NULL AND c.valid_until > now()) THEN
        PERFORM migration.raise_error('HK_MIG_CONSENT_REQUIRED', 'an active data-owner consent is required');
      END IF;
      v_needed := CASE NEW.channel WHEN 'backup' THEN ARRAY['backup_processing']
                                   WHEN 'api' THEN ARRAY['third_party_api']
                                   WHEN 'agent' THEN ARRAY['agent_execution']
                                   ELSE ARRAY[]::text[] END;
      IF NEW.assisted THEN v_needed := array_append(v_needed, 'assisted_access'); END IF;
      FOREACH v_kind IN ARRAY v_needed LOOP
        IF NOT migration.consent_is_active(NEW.tenant_id, NEW.id, v_kind) THEN
          PERFORM migration.raise_error('HK_MIG_CONSENT_REQUIRED', format('an active %s consent is required', v_kind));
        END IF;
      END LOOP;
      -- RV-MG-17: هر گام رو به جلوی کار همراه‌با‌کارشناس رضایت پشتیبانی نوشتنی و معتبر می‌خواهد
      IF NEW.assisted AND NOT migration.support_grant_ok(NEW.tenant_id, NEW.support_grant_id) THEN
        PERFORM migration.raise_error('HK_MIG_SUPPORT_GRANT', 'an assisted job needs a valid, unrevoked read_write support grant');
      END IF;
    END IF;

    CASE NEW.status
      WHEN 'staged' THEN
        IF NOT EXISTS (SELECT 1 FROM migration.package p WHERE p.tenant_id = NEW.tenant_id AND p.job_id = NEW.id AND p.status = 'verified') THEN
          PERFORM migration.raise_error('HK_MIG_NO_PACKAGE', 'a verified HIF package is required');
        END IF;
      WHEN 'mapping' THEN
        NEW.preview_dry_run_id := NULL; NEW.preview_accepted_by := NULL; NEW.preview_accepted_at := NULL;
      WHEN 'validated' THEN
        IF NEW.amount_unit_confirmed_at IS NULL THEN
          PERFORM migration.raise_error('HK_MIG_UNIT_UNCONFIRMED', 'the amount unit must be explicitly confirmed (IRR/IRT/IRR_NEW)');
        END IF;
        IF NEW.mode <> 'archive' AND NEW.fiscal_year_id IS NULL THEN
          PERFORM migration.raise_error('HK_MIG_NO_FISCAL_YEAR', 'opening and current-year jobs need a target fiscal year');
        END IF;
        IF EXISTS (SELECT 1 FROM migration.issue i WHERE i.tenant_id = NEW.tenant_id AND i.job_id = NEW.id
                     AND i.status = 'open' AND i.severity = 'error') THEN
          PERFORM migration.raise_error('HK_MIG_OPEN_ERRORS', 'open error issues block validation');
        END IF;
        IF EXISTS (SELECT 1 FROM migration.staged_record s WHERE s.tenant_id = NEW.tenant_id AND s.job_id = NEW.id
                     AND s.status IN ('pending','blocked')) THEN
          PERFORM migration.raise_error('HK_MIG_UNRESOLVED_RECORDS', 'pending or blocked staged records remain');
        END IF;
        IF EXISTS (SELECT 1 FROM migration.staged_record s WHERE s.tenant_id = NEW.tenant_id AND s.job_id = NEW.id
                     AND s.entity = 'voucher' AND NOT EXISTS (
                       SELECT 1 FROM migration.job_partition_policy p WHERE p.tenant_id = s.tenant_id AND p.job_id = s.job_id
                          AND p.partition_class = s.partition_class)) THEN
          PERFORM migration.raise_error('HK_MIG_PARTITION_POLICY', 'every voucher class needs a disposition policy');
        END IF;
        -- RV-MG-06: بازسنجی مجموعه‌ای در گیت؛ سند «معتبری» که سطرش بعداً حذف شده هرگز نمی‌گذرد (INV-MIG-15).
        -- (سطر pending یا blocked را بررسی HK_MIG_UNRESOLVED_RECORDS بالا پیش‌تر گرفته است.)
        IF EXISTS (SELECT 1 FROM migration.staged_record v
                     LEFT JOIN LATERAL (SELECT coalesce(sum(c.debit), 0) AS dr, coalesce(sum(c.credit), 0) AS cr
                                          FROM migration.staged_record c
                                         WHERE c.tenant_id = v.tenant_id AND c.job_id = v.job_id AND c.parent_id = v.id
                                           AND c.status <> 'excluded') t ON true
                    WHERE v.tenant_id = NEW.tenant_id AND v.job_id = NEW.id AND v.entity = 'voucher'
                      AND v.status IN ('valid','warning') AND (t.dr <> t.cr OR t.dr = 0)) THEN
          PERFORM migration.raise_error('HK_MIG_VOUCHER_UNBALANCED', 'a valid voucher is unbalanced or empty');
        END IF;
      WHEN 'previewed' THEN
        IF NEW.amount_unit_confirmed_at IS NULL THEN
          PERFORM migration.raise_error('HK_MIG_UNIT_UNCONFIRMED', 'the amount unit must be explicitly confirmed (IRR/IRT/IRR_NEW)');
        END IF;
        SELECT * INTO v_dr FROM migration.dry_run d WHERE d.tenant_id = NEW.tenant_id AND d.id = NEW.preview_dry_run_id AND d.job_id = NEW.id;
        -- RV-MG-06: dry-run باید آخرین، موفق، روی همین hash و ثبت‌شده پس از آخرین ورود به validated باشد
        IF NOT FOUND OR v_dr.outcome <> 'ok' OR NEW.inputs_hash IS NULL OR v_dr.inputs_hash <> NEW.inputs_hash
           OR v_dr.seq <> (SELECT max(seq) FROM migration.dry_run d2 WHERE d2.tenant_id = NEW.tenant_id AND d2.job_id = NEW.id)
           OR v_dr.finished_at < OLD.status_changed_at THEN
          PERFORM migration.raise_error('HK_MIG_DRY_RUN_REQUIRED', 'preview needs the latest successful dry-run over the current inputs');
        END IF;
      WHEN 'committing' THEN
        IF NEW.amount_unit_confirmed_at IS NULL THEN
          PERFORM migration.raise_error('HK_MIG_UNIT_UNCONFIRMED', 'the amount unit must be explicitly confirmed (IRR/IRT/IRR_NEW)');
        END IF;
        IF NEW.preview_accepted_by IS NULL THEN
          PERFORM migration.raise_error('HK_MIG_PREVIEW_NOT_ACCEPTED', 'a user must accept the preview before commit');
        END IF;
        SELECT * INTO v_dr FROM migration.dry_run d WHERE d.tenant_id = NEW.tenant_id AND d.id = NEW.preview_dry_run_id;
        IF NOT FOUND OR v_dr.inputs_hash <> NEW.inputs_hash THEN
          PERFORM migration.raise_error('HK_MIG_DRY_RUN_REQUIRED', 'inputs changed since the accepted dry-run');
        END IF;
        -- RV-MG-15: برنامهٔ ثبت پیش از commit و هم‌زمان با آن ساخته می‌شود و پس از آن ثابت است
        IF NOT EXISTS (SELECT 1 FROM migration.commit_chunk c WHERE c.tenant_id = NEW.tenant_id AND c.job_id = NEW.id) THEN
          PERFORM migration.raise_error('HK_MIG_CHUNKS_PENDING', 'plan the commit chunks before committing');
        END IF;
      WHEN 'committed' THEN
        IF NOT EXISTS (SELECT 1 FROM migration.commit_chunk c WHERE c.tenant_id = NEW.tenant_id AND c.job_id = NEW.id)
           OR EXISTS (SELECT 1 FROM migration.commit_chunk c WHERE c.tenant_id = NEW.tenant_id AND c.job_id = NEW.id AND c.status <> 'done') THEN
          PERFORM migration.raise_error('HK_MIG_CHUNKS_PENDING', 'all commit chunks must be done');
        END IF;
      WHEN 'reconciled', 'live' THEN
        IF NEW.status = 'live' THEN
          IF NEW.golive_approved_by IS NULL THEN
            PERFORM migration.raise_error('HK_MIG_GOLIVE_APPROVAL', 'go-live needs the responsible accountant''s approval');
          END IF;
          -- RV-MG-13 / D-MG20: تأیید زنده شدن کنش خود حسابدار است (نه سیستم، نه دستیار، نه ورود به‌جای کاربر)
          PERFORM migration.assert_human_act(NEW.golive_approved_by, 'go-live approval', true);
          NEW.golive_approved_at := now();
        END IF;
        SELECT r.id INTO v_latest FROM migration.reconciliation r WHERE r.tenant_id = NEW.tenant_id AND r.job_id = NEW.id
         ORDER BY r.seq DESC LIMIT 1;
        SELECT * INTO v_rec FROM migration.reconciliation r WHERE r.tenant_id = NEW.tenant_id AND r.id = NEW.reconciliation_id;
        IF NOT FOUND OR v_rec.id <> v_latest OR v_rec.status <> 'balanced' THEN
          PERFORM migration.raise_error('HK_MIG_NOT_RECONCILED',
            CASE NEW.status WHEN 'live' THEN 'go-live requires the latest reconciliation to be balanced'
                            ELSE 'the latest reconciliation must be balanced (zero unexplained difference)' END);
        END IF;
        -- RV-MG-03: توضیحی که سطر تطبیق به آن تکیه دارد هنوز تأییدشده است (پس‌گرفتن توضیح، تطبیق تازه می‌خواهد)
        IF EXISTS (SELECT 1 FROM migration.reconciliation_line l
                     JOIN migration.explanation e ON e.tenant_id = l.tenant_id AND e.id = l.explanation_id
                    WHERE l.tenant_id = NEW.tenant_id AND l.reconciliation_id = NEW.reconciliation_id
                      AND l.line_status = 'explained' AND e.status <> 'approved') THEN
          PERFORM migration.raise_error('HK_MIG_NOT_RECONCILED', 'an explanation used by the reconciliation is no longer approved; reconcile again');
        END IF;
        IF NEW.status = 'live' THEN
          NEW.locked_at := now();
        END IF;
      WHEN 'rolled_back' THEN
        IF EXISTS (SELECT 1 FROM migration.posting p WHERE p.tenant_id = NEW.tenant_id AND p.job_id = NEW.id AND p.state = 'live') THEN
          PERFORM migration.raise_error('HK_MIG_ROLLBACK_INCOMPLETE', 'live postings remain; compensate them first');
        END IF;
        -- RV-MG-15 / INV-MIG-14: ردیف مرحله‌ای و تداوم ثبت‌شده باید rolled_back شده باشند
        IF EXISTS (SELECT 1 FROM migration.staged_record s WHERE s.tenant_id = NEW.tenant_id AND s.job_id = NEW.id AND s.status = 'committed')
           OR EXISTS (SELECT 1 FROM migration.moadian_continuity m WHERE m.tenant_id = NEW.tenant_id AND m.job_id = NEW.id AND m.status = 'committed') THEN
          PERFORM migration.raise_error('HK_MIG_ROLLBACK_INCOMPLETE', 'committed staged or continuity rows remain; mark them rolled back first');
        END IF;
        NEW.rolled_back_at := now();
      WHEN 'cancelled' THEN
        NEW.cancelled_at := now();
      ELSE NULL;
    END CASE;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_job_guard ON migration.job;
CREATE TRIGGER trg_job_guard BEFORE INSERT OR UPDATE OR DELETE ON migration.job
  FOR EACH ROW EXECUTE FUNCTION migration.job_guard();
DROP TRIGGER IF EXISTS trg_touch ON migration.job;
CREATE TRIGGER trg_touch BEFORE UPDATE ON migration.job FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- RV-MG-27: ساخت کار (— → draft)، هر گذار و هر تعویض رضایت (RV-MG-16) با کنشگر در job_event ثبت می‌شود
CREATE OR REPLACE FUNCTION migration.job_log_event() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_actor uuid := (SELECT m.user_id FROM core.tenant_membership m WHERE m.tenant_id = NEW.tenant_id AND m.user_id = core.current_user_id());
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO migration.job_event (tenant_id, job_id, from_status, to_status, actor_id, note)
    VALUES (NEW.tenant_id, NEW.id, '—', NEW.status, v_actor, NULL);
  ELSIF NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO migration.job_event (tenant_id, job_id, from_status, to_status, actor_id, note)
    VALUES (NEW.tenant_id, NEW.id, OLD.status, NEW.status, v_actor, NEW.failure_code);
  ELSIF NEW.consent_id IS DISTINCT FROM OLD.consent_id THEN
    INSERT INTO migration.job_event (tenant_id, job_id, from_status, to_status, actor_id, note)
    VALUES (NEW.tenant_id, NEW.id, OLD.status, NEW.status, v_actor, 'consent:' || coalesce(NEW.consent_id::text, 'none'));
  END IF;
  -- CR-MG05 (ruling: سازوکار عمومی core.export_blocker): در committing و rolling_back صدور .hkx مستأجر بسته است تا
  -- بسته حالت نیمه نداشته باشد؛ با خروج از آن وضعیت مانع آزاد می‌شود
  IF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status THEN
    IF OLD.status IN ('committing','rolling_back') THEN
      UPDATE core.export_blocker b SET released_at = now()
       WHERE b.tenant_id = NEW.tenant_id AND b.module = 'migration' AND b.resource_id = NEW.id
         AND b.reason_code = 'migration.job.' || OLD.status AND b.released_at IS NULL;
    END IF;
    IF NEW.status IN ('committing','rolling_back') THEN
      INSERT INTO core.export_blocker (tenant_id, module, reason_code, resource_id)
      VALUES (NEW.tenant_id, 'migration', 'migration.job.' || NEW.status, NEW.id);
    END IF;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_job_log_event ON migration.job;
CREATE TRIGGER trg_job_log_event AFTER INSERT OR UPDATE OF status, consent_id ON migration.job
  FOR EACH ROW EXECUTE FUNCTION migration.job_log_event();

DROP TRIGGER IF EXISTS trg_forbid_mutation ON migration.job_event;
CREATE TRIGGER trg_forbid_mutation BEFORE UPDATE OR DELETE ON migration.job_event
  FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

-- ---------- رضایت: تغییرناپذیر، فقط یک‌بار لغوشدنی ----------
CREATE OR REPLACE FUNCTION migration.consent_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM migration.raise_error('HK_MIG_CONSENT_IMMUTABLE', 'consents are evidence and are never deleted');
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.revoked_at IS NOT NULL OR NEW.revoked_by IS NOT NULL THEN
      PERFORM migration.raise_error('HK_MIG_CONSENT_IMMUTABLE', 'a consent is recorded un-revoked');
    END IF;
    -- RV-MG-13: امضا کنش خود کاربر جاری است؛ زمینهٔ سیستمی (بی app.user_id) یا دستیار نمی‌تواند به نام کسی امضا کند
    IF core.current_user_id() IS NULL OR NEW.signer_user_id IS DISTINCT FROM core.current_user_id() THEN
      PERFORM migration.raise_error('HK_MIG_CONSENT_SIGNER', 'consent is signed by the acting user only');
    END IF;
    PERFORM migration.assert_human_act(NEW.signer_user_id, 'signing a consent', true);
    -- RV-MG-16: رضایت تازه در هر وضعیت غیرپایانی ثبت‌شدنی است (رضایت لغوشده یا منقضی دیگر کار را زندانی نمی‌کند)
    PERFORM migration.assert_job_status(NEW.tenant_id, NEW.job_id,
      ARRAY['draft','awaiting_source','staged','mapping','validated','previewed','committing','committed','reconciled',
            'rolling_back','failed'], 'recording consent');
    NEW.accepted_at := now();                         -- زمان امضا = زمان سرور (شاهد)
    RETURN NEW;
  END IF;
  IF OLD.revoked_at IS NOT NULL
     OR (NEW.tenant_id, NEW.id, NEW.job_id, NEW.kind, NEW.statement_code, NEW.statement_version, NEW.statement_sha256,
         NEW.signer_user_id, NEW.signer_full_name, NEW.signer_capacity, NEW.written_form_attachment_id, NEW.scope,
         NEW.accepted_at, NEW.valid_until, NEW.client_ip, NEW.user_agent_sha256)
        IS DISTINCT FROM
        (OLD.tenant_id, OLD.id, OLD.job_id, OLD.kind, OLD.statement_code, OLD.statement_version, OLD.statement_sha256,
         OLD.signer_user_id, OLD.signer_full_name, OLD.signer_capacity, OLD.written_form_attachment_id, OLD.scope,
         OLD.accepted_at, OLD.valid_until, OLD.client_ip, OLD.user_agent_sha256) THEN
    PERFORM migration.raise_error('HK_MIG_CONSENT_IMMUTABLE', 'a consent can only be revoked once');
  END IF;
  IF NEW.revoked_by IS NOT NULL THEN
    PERFORM migration.assert_human_act(NEW.revoked_by, 'revoking a consent');
    NEW.revoked_at := now();
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_consent_guard ON migration.consent;
CREATE TRIGGER trg_consent_guard BEFORE INSERT OR UPDATE OR DELETE ON migration.consent
  FOR EACH ROW EXECUTE FUNCTION migration.consent_guard();

-- ---------- سیاست پارتیشن: فقط پیش از پیش‌نمایش تغییرپذیر ----------
CREATE OR REPLACE FUNCTION migration.partition_policy_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM migration.assert_job_status(OLD.tenant_id, OLD.job_id, ARRAY['draft','awaiting_source','staged','mapping'], 'changing the partition policy');
    IF EXISTS (SELECT 1 FROM migration.staged_record s WHERE s.tenant_id = OLD.tenant_id AND s.job_id = OLD.job_id
                 AND s.entity = 'voucher' AND s.partition_class = OLD.partition_class AND s.status <> 'pending') THEN
      PERFORM migration.raise_error('HK_MIG_PARTITION_POLICY', 'reset the vouchers of this class to pending before changing the policy');
    END IF;
    RETURN OLD;
  END IF;
  PERFORM migration.assert_job_status(NEW.tenant_id, NEW.job_id, ARRAY['draft','awaiting_source','staged','mapping'], 'changing the partition policy');
  IF TG_OP = 'UPDATE' THEN
    IF (NEW.tenant_id, NEW.job_id, NEW.partition_class) IS DISTINCT FROM (OLD.tenant_id, OLD.job_id, OLD.partition_class) THEN
      PERFORM migration.raise_error('HK_MIG_IMMUTABLE_FIELD', 'policy key is immutable');
    END IF;
    IF NEW.disposition <> OLD.disposition AND EXISTS (
         SELECT 1 FROM migration.staged_record s WHERE s.tenant_id = OLD.tenant_id AND s.job_id = OLD.job_id
            AND s.entity = 'voucher' AND s.partition_class = OLD.partition_class AND s.status <> 'pending') THEN
      PERFORM migration.raise_error('HK_MIG_PARTITION_POLICY', 'reset the vouchers of this class to pending before changing the policy');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_partition_policy_guard ON migration.job_partition_policy;
CREATE TRIGGER trg_partition_policy_guard BEFORE INSERT OR UPDATE OR DELETE ON migration.job_partition_policy
  FOR EACH ROW EXECUTE FUNCTION migration.partition_policy_guard();

-- ---------- اعتبارنامه، عامل، فایل: فقط پس از رضایت؛ هویت ثابت ----------
CREATE OR REPLACE FUNCTION migration.source_intake_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM migration.raise_error('HK_MIG_NO_DELETE', format('%s rows are purged, never deleted', TG_TABLE_NAME));
  END IF;
  IF TG_OP = 'INSERT' THEN
    -- INV-MIG-01: هیچ دادهٔ مبدأ (فایل، اعتبارنامه، عامل) پیش از رضایت وارد نمی‌شود
    PERFORM migration.assert_job_status(NEW.tenant_id, NEW.job_id, ARRAY['awaiting_source','staged','mapping','failed'],
                                        format('adding %s', TG_TABLE_NAME));
    -- RV-MG-14: ماشین حالت از درج هم اجرا می‌شود؛ زمان ساخت = زمان سرور (پنجرهٔ ۲۴ ساعته و ۳۰ روزه از آن سنجیده می‌شود)
    IF TG_TABLE_NAME = 'upload' THEN
      IF NEW.status <> 'pending_upload' OR NEW.uploaded_at IS NOT NULL OR NEW.purged_at IS NOT NULL THEN
        PERFORM migration.raise_error('HK_MIG_INTAKE_INITIAL', 'an upload starts pending_upload');
      END IF;
    ELSIF TG_TABLE_NAME = 'agent_session' THEN
      IF NEW.status <> 'pending' OR NEW.agent_public_key IS NOT NULL OR NEW.token_hash IS NOT NULL
         OR NEW.token_expires_at IS NOT NULL OR NEW.paired_at IS NOT NULL THEN
        PERFORM migration.raise_error('HK_MIG_INTAKE_INITIAL', 'an agent session starts pending, without key or token');
      END IF;
    ELSIF TG_TABLE_NAME = 'source_credential' THEN
      IF NEW.status <> 'active' OR NEW.purged_at IS NOT NULL THEN
        PERFORM migration.raise_error('HK_MIG_INTAKE_INITIAL', 'a credential starts active');
      END IF;
    END IF;
    NEW.created_at := now();
    RETURN NEW;
  END IF;
  IF (NEW.tenant_id, NEW.id, NEW.job_id, NEW.created_at) IS DISTINCT FROM (OLD.tenant_id, OLD.id, OLD.job_id, OLD.created_at) THEN
    PERFORM migration.raise_error('HK_MIG_IMMUTABLE_FIELD', 'identity is immutable');
  END IF;
  IF TG_TABLE_NAME = 'upload' THEN
    IF OLD.status = 'purged' THEN
      PERFORM migration.raise_error('HK_MIG_PURGED', 'a purged upload is final');
    END IF;
    IF (NEW.kind, NEW.object_key, NEW.storage_backend, NEW.bucket) IS DISTINCT FROM (OLD.kind, OLD.object_key, OLD.storage_backend, OLD.bucket)
       OR (OLD.sha256 IS NOT NULL AND NEW.sha256 IS DISTINCT FROM OLD.sha256)
       OR (OLD.size_bytes IS NOT NULL AND NEW.size_bytes IS DISTINCT FROM OLD.size_bytes) THEN
      PERFORM migration.raise_error('HK_MIG_IMMUTABLE_FIELD', 'upload content identity is immutable');
    END IF;
    IF NEW.status <> OLD.status AND (OLD.status, NEW.status) NOT IN (
         ('pending_upload','uploaded'), ('pending_upload','rejected'), ('uploaded','scanning'), ('uploaded','rejected'),
         ('scanning','accepted'), ('scanning','rejected'), ('accepted','purged'), ('rejected','purged'), ('uploaded','purged'),
         ('pending_upload','purged')) THEN
      PERFORM migration.raise_error('HK_MIG_UPLOAD_TRANSITION', format('upload %s -> %s is not allowed', OLD.status, NEW.status));
    END IF;
  ELSIF TG_TABLE_NAME = 'agent_session' THEN
    IF OLD.agent_public_key IS NOT NULL AND NEW.agent_public_key IS DISTINCT FROM OLD.agent_public_key THEN
      PERFORM migration.raise_error('HK_MIG_IMMUTABLE_FIELD', 'agent key is bound once');
    END IF;
    IF NEW.pairing_code_hash IS DISTINCT FROM OLD.pairing_code_hash OR NEW.expires_at IS DISTINCT FROM OLD.expires_at THEN
      PERFORM migration.raise_error('HK_MIG_IMMUTABLE_FIELD', 'pairing code is single-use');
    END IF;
    IF NEW.status <> OLD.status AND (OLD.status, NEW.status) NOT IN (
         ('pending','paired'), ('pending','expired'), ('pending','revoked'), ('paired','completed'), ('paired','revoked'), ('paired','expired')) THEN
      PERFORM migration.raise_error('HK_MIG_AGENT_TRANSITION', format('agent session %s -> %s is not allowed', OLD.status, NEW.status));
    END IF;
    IF OLD.status = 'pending' AND NEW.status = 'paired' AND OLD.expires_at <= now() THEN
      PERFORM migration.raise_error('HK_MIG_AGENT_PAIRING_EXPIRED', 'the pairing code has expired');
    END IF;
    -- INV-MIG-32: توکن عامل کوتاه‌عمر (≤ ۱ ساعت) است
    IF NEW.token_expires_at IS DISTINCT FROM OLD.token_expires_at AND NEW.token_expires_at > now() + interval '1 hour' THEN
      PERFORM migration.raise_error('HK_MIG_AGENT_TOKEN_TTL', 'agent tokens live at most one hour');
    END IF;
  ELSIF TG_TABLE_NAME = 'source_credential' THEN
    IF OLD.status <> 'active' THEN
      PERFORM migration.raise_error('HK_MIG_PURGED', 'a purged or revoked credential is final');
    END IF;
    IF (NEW.kind, NEW.endpoint_base, NEW.secret_ref, NEW.purge_after) IS DISTINCT FROM (OLD.kind, OLD.endpoint_base, OLD.secret_ref, OLD.purge_after) THEN
      PERFORM migration.raise_error('HK_MIG_IMMUTABLE_FIELD', 'credential reference is immutable; create a new one');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_intake_guard ON migration.upload;
CREATE TRIGGER trg_intake_guard BEFORE INSERT OR UPDATE OR DELETE ON migration.upload FOR EACH ROW EXECUTE FUNCTION migration.source_intake_guard();
DROP TRIGGER IF EXISTS trg_intake_guard ON migration.agent_session;
CREATE TRIGGER trg_intake_guard BEFORE INSERT OR UPDATE OR DELETE ON migration.agent_session FOR EACH ROW EXECUTE FUNCTION migration.source_intake_guard();
DROP TRIGGER IF EXISTS trg_intake_guard ON migration.source_credential;
CREATE TRIGGER trg_intake_guard BEFORE INSERT OR UPDATE OR DELETE ON migration.source_credential FOR EACH ROW EXECUTE FUNCTION migration.source_intake_guard();
DROP TRIGGER IF EXISTS trg_touch ON migration.upload;
CREATE TRIGGER trg_touch BEFORE UPDATE ON migration.upload FOR EACH ROW EXECUTE FUNCTION core.touch_row();
DROP TRIGGER IF EXISTS trg_touch ON migration.agent_session;
CREATE TRIGGER trg_touch BEFORE UPDATE ON migration.agent_session FOR EACH ROW EXECUTE FUNCTION core.touch_row();
DROP TRIGGER IF EXISTS trg_touch ON migration.source_credential;
CREATE TRIGGER trg_touch BEFORE UPDATE ON migration.source_credential FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- ---------- بستهٔ HIF ----------
CREATE OR REPLACE FUNCTION migration.package_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_rows jsonb; v_session record;
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM migration.raise_error('HK_MIG_NO_DELETE', 'packages are superseded, never deleted');
  END IF;
  IF TG_OP = 'INSERT' THEN
    PERFORM migration.assert_job_status(NEW.tenant_id, NEW.job_id, ARRAY['awaiting_source','staged','mapping','failed'], 'receiving a package');
    IF NEW.status <> 'received' THEN
      PERFORM migration.raise_error('HK_MIG_PACKAGE_TRANSITION', 'a package starts as received');
    END IF;
    IF NEW.producer = 'agent' AND NEW.agent_session_id IS NOT NULL THEN
      SELECT * INTO v_session FROM migration.agent_session a WHERE a.tenant_id = NEW.tenant_id AND a.id = NEW.agent_session_id;
      IF v_session.status IS DISTINCT FROM 'paired' THEN
        PERFORM migration.raise_error('HK_MIG_AGENT_NOT_PAIRED', 'agent packages need a paired agent session');
      END IF;
    END IF;
    NEW.created_at := now();
    RETURN NEW;
  END IF;
  IF (NEW.tenant_id, NEW.id, NEW.job_id, NEW.upload_id, NEW.producer, NEW.agent_session_id, NEW.format_version, NEW.manifest,
      NEW.manifest_sha256, NEW.signer_key_id, NEW.source_system, NEW.source_db, NEW.amount_unit, NEW.row_count_total, NEW.extracted_at,
      NEW.created_at)
     IS DISTINCT FROM
     (OLD.tenant_id, OLD.id, OLD.job_id, OLD.upload_id, OLD.producer, OLD.agent_session_id, OLD.format_version, OLD.manifest,
      OLD.manifest_sha256, OLD.signer_key_id, OLD.source_system, OLD.source_db, OLD.amount_unit, OLD.row_count_total, OLD.extracted_at,
      OLD.created_at) THEN
    PERFORM migration.raise_error('HK_MIG_IMMUTABLE_FIELD', 'package manifest is immutable');
  END IF;
  IF NEW.status <> OLD.status THEN
    IF (OLD.status, NEW.status) NOT IN (('received','verified'), ('received','rejected'), ('verified','superseded')) THEN
      PERFORM migration.raise_error('HK_MIG_PACKAGE_TRANSITION', format('package %s -> %s is not allowed', OLD.status, NEW.status));
    END IF;
    IF NEW.status = 'verified' THEN
      -- INV-MIG-04 (RV-MG-18): شمار ردیف خام بارگذاری‌شدهٔ هر جدول = files[].rows همان جدول در manifest
      -- (row_count_total با CHECK manifest_rows_ok برابر جمع همین‌هاست)
      SELECT coalesce(jsonb_object_agg(x.source_table, x.n), '{}') INTO v_rows
        FROM (SELECT r.source_table, count(*) AS n FROM migration.raw_record r
               WHERE r.tenant_id = NEW.tenant_id AND r.package_id = NEW.id GROUP BY r.source_table) x;
      IF v_rows IS DISTINCT FROM (SELECT coalesce(jsonb_object_agg(e.key, e.value), '{}')
                                    FROM jsonb_each(migration.manifest_raw_counts(NEW.manifest)) e WHERE e.value <> '0'::jsonb) THEN
        PERFORM migration.raise_error('HK_MIG_ROW_COUNT_MISMATCH',
          format('manifest declares %s rows (%s) but %s were loaded', NEW.row_count_total, migration.manifest_raw_counts(NEW.manifest), v_rows));
      END IF;
      NEW.verified_at := now();
    ELSIF NEW.status = 'superseded' THEN
      NEW.superseded_at := now();
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_package_guard ON migration.package;
CREATE TRIGGER trg_package_guard BEFORE INSERT OR UPDATE OR DELETE ON migration.package FOR EACH ROW EXECUTE FUNCTION migration.package_guard();

-- ---------- snapshot خام: درج فقط در بارگذاری؛ بدون ویرایش؛ حذف فقط در پاک‌سازی ----------
-- شرط پاک‌سازی نگهداری (INV-MIG-33): GUC تراکنشی hk.migration_purge، کار پایانی و مهلت نگهداری گذشته
CREATE OR REPLACE FUNCTION migration.purge_allowed(p_tenant uuid, p_job uuid) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT coalesce(current_setting('hk.migration_purge', true), '') = 'on'
     AND EXISTS (SELECT 1 FROM migration.job j WHERE j.tenant_id = p_tenant AND j.id = p_job
                   AND j.status IN ('live','rolled_back','cancelled') AND j.raw_retain_until IS NOT NULL AND j.raw_retain_until <= now())
$$;

CREATE OR REPLACE FUNCTION migration.raw_record_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_pkg text;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    PERFORM migration.raise_error('HK_MIG_RAW_IMMUTABLE', 'raw source rows are an immutable snapshot');
  END IF;
  IF TG_OP = 'INSERT' THEN
    -- RV-MG-02: وضعیت بسته با FOR SHARE خوانده می‌شود تا verify هم‌زمان شمار را از دست ندهد
    SELECT p.status INTO v_pkg FROM migration.package p WHERE p.tenant_id = NEW.tenant_id AND p.id = NEW.package_id FOR SHARE;
    IF v_pkg IS DISTINCT FROM 'received' THEN
      PERFORM migration.raise_error('HK_MIG_RAW_IMMUTABLE', 'raw rows are loaded only while the package is received');
    END IF;
    RETURN NEW;
  END IF;
  -- DELETE: فقط کار پاک‌سازی (GUC تراکنشی hk.migration_purge) پس از پایان کار و مهلت نگهداری، یا بستهٔ کنارگذاشته
  IF coalesce(current_setting('hk.migration_purge', true), '') <> 'on' THEN
    PERFORM migration.raise_error('HK_MIG_RAW_IMMUTABLE', 'raw rows are removed only by the retention purge');
  END IF;
  SELECT p.status INTO v_pkg FROM migration.package p WHERE p.tenant_id = OLD.tenant_id AND p.id = OLD.package_id;
  IF NOT (v_pkg IN ('rejected','superseded') OR migration.purge_allowed(OLD.tenant_id, OLD.job_id)) THEN
    PERFORM migration.raise_error('HK_MIG_RETENTION', 'raw rows are kept until the job ends and its retention period passes');
  END IF;
  IF EXISTS (SELECT 1 FROM migration.staged_record s WHERE s.tenant_id = OLD.tenant_id AND s.job_id = OLD.job_id
               AND s.raw_record_id = OLD.id) THEN
    PERFORM migration.raise_error('HK_MIG_RETENTION', 'purge staged rows first');
  END IF;
  RETURN OLD;
END $$;
DROP TRIGGER IF EXISTS trg_raw_record_guard ON migration.raw_record;
CREATE TRIGGER trg_raw_record_guard BEFORE INSERT OR UPDATE OR DELETE ON migration.raw_record FOR EACH ROW EXECUTE FUNCTION migration.raw_record_guard();

-- ---------- رکورد مرحله‌ای ----------
CREATE OR REPLACE FUNCTION migration.staged_record_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_job        text;
  v_parent     record;
  v_disp       text;
  v_dr         numeric;
  v_cr         numeric;
  v_content_changed boolean;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_job := migration.lock_job_status(OLD.tenant_id, OLD.job_id);
    -- RV-MG-08 / INV-MIG-33: پاک‌سازی نگهداری کار پایانی (پس از مهلت) ردیف ثبت‌شده را هم پاک می‌کند؛
    -- lineage در ستون‌های posting می‌ماند و posting.staged_record_id با FK به NULL می‌رود
    IF migration.purge_allowed(OLD.tenant_id, OLD.job_id) THEN
      RETURN OLD;
    END IF;
    IF OLD.status IN ('committed','rolled_back') OR NOT (coalesce(v_job, '') IN ('staged','mapping','awaiting_source','failed','cancelled')) THEN
      PERFORM migration.raise_error('HK_MIG_STAGED_FROZEN', 'committed staged rows and rows of a frozen job cannot be deleted (only the retention purge)');
    END IF;
    RETURN OLD;
  END IF;

  v_job := migration.lock_job_status(NEW.tenant_id, NEW.job_id);

  IF TG_OP = 'INSERT' THEN
    IF NOT (coalesce(v_job, '') IN ('staged','mapping')) THEN
      PERFORM migration.raise_error('HK_MIG_JOB_STATE', format('staging rows is not allowed while the job is %s', v_job));
    END IF;
    IF NEW.status NOT IN ('pending','excluded','blocked') OR NEW.committed_chunk IS NOT NULL THEN
      PERFORM migration.raise_error('HK_MIG_STAGED_TRANSITION', 'staged rows start pending, excluded or blocked');
    END IF;
    v_content_changed := true;
  ELSE
    IF (NEW.tenant_id, NEW.id, NEW.job_id, NEW.entity, NEW.source_system, NEW.source_db, NEW.source_table, NEW.source_key, NEW.raw_record_id, NEW.parent_id)
       IS DISTINCT FROM (OLD.tenant_id, OLD.id, OLD.job_id, OLD.entity, OLD.source_system, OLD.source_db, OLD.source_table, OLD.source_key, OLD.raw_record_id, OLD.parent_id) THEN
      PERFORM migration.raise_error('HK_MIG_IMMUTABLE_FIELD', 'lineage of a staged row is immutable');
    END IF;
    v_content_changed := (NEW.normalized, NEW.mapped, NEW.debit, NEW.credit, NEW.amount, NEW.amount_unit, NEW.qty, NEW.unit_cost,
                          NEW.total_value, NEW.cost_status, NEW.doc_date, NEW.partition_class, NEW.disposition, NEW.legacy_code, NEW.line_no)
                         IS DISTINCT FROM
                         (OLD.normalized, OLD.mapped, OLD.debit, OLD.credit, OLD.amount, OLD.amount_unit, OLD.qty, OLD.unit_cost,
                          OLD.total_value, OLD.cost_status, OLD.doc_date, OLD.partition_class, OLD.disposition, OLD.legacy_code, OLD.line_no);
    -- INV-MIG-14: ردیف ثبت‌شده منجمد است؛ فقط در rollback به rolled_back می‌رود
    IF OLD.status IN ('committed','rolled_back') THEN
      IF v_content_changed OR (NEW.target_kind, NEW.target_id, NEW.committed_chunk) IS DISTINCT FROM (OLD.target_kind, OLD.target_id, OLD.committed_chunk)
         OR NOT (NEW.status = OLD.status OR (OLD.status = 'committed' AND NEW.status = 'rolled_back' AND v_job = 'rolling_back')) THEN
        PERFORM migration.raise_error('HK_MIG_STAGED_FROZEN', 'a committed staged row is frozen');
      END IF;
      RETURN NEW;
    END IF;
    IF NEW.status = 'committed' THEN
      -- RV-MG-22: dry-run حالت full_tx همان گام را روی کار validated اجرا می‌کند (تراکنشش هرگز commit نمی‌شود)
      IF NOT (v_job = 'committing' OR (v_job = 'validated' AND migration.in_dry_run())) OR v_content_changed THEN
        PERFORM migration.raise_error('HK_MIG_STAGED_FROZEN', 'rows are committed only by the commit stage, without content changes');
      END IF;
      IF OLD.status NOT IN ('valid','warning') THEN
        PERFORM migration.raise_error('HK_MIG_STAGED_TRANSITION', format('cannot commit a %s row', OLD.status));
      END IF;
    ELSIF NEW.status = 'rolled_back' THEN
      PERFORM migration.raise_error('HK_MIG_STAGED_TRANSITION', 'only committed rows are rolled back');
    ELSIF v_content_changed OR NEW.status <> OLD.status OR (NEW.target_kind, NEW.target_id, NEW.committed_chunk)
                                                            IS DISTINCT FROM (OLD.target_kind, OLD.target_id, OLD.committed_chunk) THEN
      -- INV-MIG-13: ویرایش فقط در مرحلهٔ نگاشت (و failed که بازگشتش از mapping می‌گذرد)
      IF NOT (coalesce(v_job, '') IN ('staged','mapping','failed')) THEN
        PERFORM migration.raise_error('HK_MIG_INPUTS_FROZEN', format('staged rows cannot change while the job is %s', v_job));
      END IF;
    END IF;
  END IF;

  -- پیوند والد/فرزند
  IF NEW.parent_id IS NOT NULL THEN
    SELECT entity, status INTO v_parent FROM migration.staged_record p WHERE p.tenant_id = NEW.tenant_id AND p.id = NEW.parent_id;
    IF (NEW.entity, v_parent.entity) NOT IN (('voucher_line','voucher'), ('invoice_line_history','invoice_history'), ('bom_line','bom')) THEN
      PERFORM migration.raise_error('HK_MIG_PARENT_KIND', format('%s cannot belong to %s', NEW.entity, v_parent.entity));
    END IF;
  END IF;

  -- INV-MIG-08: وضعیت سند = سیاست کلاس در همان کار (پارتیشن انحصاری)
  IF NEW.entity = 'voucher' AND NEW.partition_class IS NOT NULL THEN
    SELECT disposition INTO v_disp FROM migration.job_partition_policy p
     WHERE p.tenant_id = NEW.tenant_id AND p.job_id = NEW.job_id AND p.partition_class = NEW.partition_class;
    IF v_disp IS NULL THEN
      PERFORM migration.raise_error('HK_MIG_PARTITION_POLICY', format('no disposition policy for class %s', NEW.partition_class));
    END IF;
    IF NEW.disposition IS DISTINCT FROM v_disp THEN
      PERFORM migration.raise_error('HK_MIG_PARTITION_POLICY', format('class %s is %s in this job, not %s', NEW.partition_class, v_disp, NEW.disposition));
    END IF;
    IF NEW.disposition = 'blocked' AND NEW.status NOT IN ('blocked','pending','excluded') THEN
      PERFORM migration.raise_error('HK_MIG_UNCLASSIFIED', 'an unclassified voucher stays blocked (or is excluded with a reason)');
    END IF;
  END IF;

  -- INV-MIG-12 و INV-MIG-15: سند معتبر = هیچ سطر مسدود + تراز (Σبدهکار = Σبستانکار > ۰)
  IF NEW.entity = 'voucher' AND NEW.status IN ('valid','warning','committed') THEN
    IF EXISTS (SELECT 1 FROM migration.staged_record c WHERE c.tenant_id = NEW.tenant_id AND c.job_id = NEW.job_id
                 AND c.parent_id = NEW.id AND c.status = 'blocked') THEN
      PERFORM migration.raise_error('HK_MIG_VOUCHER_BLOCKED', 'a voucher with an unmapped or blocked line is blocked as a whole');
    END IF;
    SELECT coalesce(sum(c.debit), 0), coalesce(sum(c.credit), 0) INTO v_dr, v_cr
      FROM migration.staged_record c WHERE c.tenant_id = NEW.tenant_id AND c.job_id = NEW.job_id
       AND c.parent_id = NEW.id AND c.status <> 'excluded';
    IF v_dr <> v_cr OR v_dr = 0 THEN
      PERFORM migration.raise_error('HK_MIG_VOUCHER_UNBALANCED', format('voucher %s is unbalanced (debit %s, credit %s)', NEW.source_key, v_dr, v_cr));
    END IF;
  END IF;
  IF NEW.entity = 'invoice_history' AND NEW.status IN ('valid','warning','committed')
     AND EXISTS (SELECT 1 FROM migration.staged_record c WHERE c.tenant_id = NEW.tenant_id AND c.job_id = NEW.job_id
                   AND c.parent_id = NEW.id AND c.status = 'blocked') THEN
    PERFORM migration.raise_error('HK_MIG_VOUCHER_BLOCKED', 'an invoice with a blocked line is blocked as a whole');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_staged_record_guard ON migration.staged_record;
CREATE TRIGGER trg_staged_record_guard BEFORE INSERT OR UPDATE OR DELETE ON migration.staged_record
  FOR EACH ROW EXECUTE FUNCTION migration.staged_record_guard();
DROP TRIGGER IF EXISTS trg_touch ON migration.staged_record;
CREATE TRIGGER trg_touch BEFORE UPDATE ON migration.staged_record FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- سطر مسدود ← سند والد مسدود؛ تغییر یا حذف سطر ← سند معتبر دوباره pending (اعتبارسنجی دوباره؛ RV-MG-06)
CREATE OR REPLACE FUNCTION migration.staged_child_cascade() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    -- در وضعیت‌های ویرایش‌پذیر والد باز می‌شود؛ در بقیه (استخراج دوباره، لغو، پاک‌سازی) گیت validated مجموعه را بازمی‌سنجد
    IF migration.job_status_of(OLD.tenant_id, OLD.job_id) IN ('staged','mapping','failed') THEN
      UPDATE migration.staged_record p SET status = 'pending'
       WHERE p.tenant_id = OLD.tenant_id AND p.job_id = OLD.job_id AND p.id = OLD.parent_id AND p.status IN ('valid','warning');
    END IF;
    RETURN NULL;
  END IF;
  IF NEW.parent_id IS NULL THEN RETURN NULL; END IF;
  IF NEW.status = 'blocked' THEN
    UPDATE migration.staged_record p SET status = 'blocked'
     WHERE p.tenant_id = NEW.tenant_id AND p.job_id = NEW.job_id AND p.id = NEW.parent_id AND p.status IN ('pending','valid','warning');
  ELSIF TG_OP = 'UPDATE' AND NEW.status NOT IN ('committed','rolled_back')
        AND (NEW.debit, NEW.credit, NEW.mapped, NEW.status) IS DISTINCT FROM (OLD.debit, OLD.credit, OLD.mapped, OLD.status) THEN
    UPDATE migration.staged_record p SET status = 'pending'
     WHERE p.tenant_id = NEW.tenant_id AND p.job_id = NEW.job_id AND p.id = NEW.parent_id AND p.status IN ('valid','warning');
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_staged_child_cascade ON migration.staged_record;
CREATE TRIGGER trg_staged_child_cascade AFTER INSERT OR UPDATE OF status, debit, credit, mapped ON migration.staged_record
  FOR EACH ROW WHEN (NEW.parent_id IS NOT NULL) EXECUTE FUNCTION migration.staged_child_cascade();
DROP TRIGGER IF EXISTS trg_staged_child_delete ON migration.staged_record;
CREATE TRIGGER trg_staged_child_delete AFTER DELETE ON migration.staged_record
  FOR EACH ROW WHEN (OLD.parent_id IS NOT NULL) EXECUTE FUNCTION migration.staged_child_cascade();

-- ---------- id_map ----------
CREATE OR REPLACE FUNCTION migration.id_map_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_status text; v_rehearsal boolean;
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM migration.raise_error('HK_MIG_NO_DELETE', 'id map rows are retired, never deleted');
  END IF;
  IF TG_OP = 'UPDATE' AND
     (NEW.tenant_id, NEW.id, NEW.company_id, NEW.source_system, NEW.source_db, NEW.source_table, NEW.source_key, NEW.target_kind,
      NEW.target_id, NEW.link_method, NEW.first_job_id, NEW.created_at)
     IS DISTINCT FROM (OLD.tenant_id, OLD.id, OLD.company_id, OLD.source_system, OLD.source_db, OLD.source_table, OLD.source_key,
      OLD.target_kind, OLD.target_id, OLD.link_method, OLD.first_job_id, OLD.created_at) THEN
    PERFORM migration.raise_error('HK_MIG_IMMUTABLE_FIELD', 'a source record keeps its target forever (re-runs update, never re-point)');
  END IF;
  -- نگاشت شناسه را فقط مرحلهٔ commit کاری که آن را لمس می‌کند (یا dry-run آن، یا جبرانش) می‌نویسد
  v_status := migration.lock_job_status(NEW.tenant_id, NEW.last_job_id);
  IF NOT (v_status IN ('committing','rolling_back') OR (v_status = 'validated' AND migration.in_dry_run())) THEN
    PERFORM migration.raise_error('HK_MIG_JOB_STATE', format('writing the id map is not allowed while the job is %s', coalesce(v_status, 'missing')));
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.first_job_id IS DISTINCT FROM NEW.last_job_id THEN
      PERFORM migration.raise_error('HK_MIG_LINEAGE', 'a new id map row names the same first and last job');
    END IF;
    -- RV-MG-01: یک رکورد مبدأ یا به یک مقصد مشترک مستأجر نگاشت می‌شود یا به مقصدهای شرکتی، نه هر دو
    IF EXISTS (SELECT 1 FROM migration.id_map m
                WHERE m.tenant_id = NEW.tenant_id AND m.source_system = NEW.source_system AND m.source_db = NEW.source_db
                  AND m.source_table = NEW.source_table AND m.source_key = NEW.source_key AND m.target_kind = NEW.target_kind
                  AND (m.company_id IS NULL) <> (NEW.company_id IS NULL)) THEN
      PERFORM migration.raise_error('HK_MIG_IDMAP_SCOPE', 'a source record maps either to one tenant-shared target or to company targets');
    END IF;
    -- RV-MG-01 / CR-MG14: کار تمرینی دادهٔ پایهٔ مشترک مستأجر نمی‌سازد (فقط در شرکت تمرینی)
    SELECT j.is_rehearsal INTO v_rehearsal FROM migration.job j WHERE j.tenant_id = NEW.tenant_id AND j.id = NEW.first_job_id;
    IF v_rehearsal AND NEW.company_id IS NULL AND NEW.link_method = 'created' THEN
      PERFORM migration.raise_error('HK_MIG_REHEARSAL_SCOPE', 'a rehearsal job creates only company-scoped targets in its rehearsal company');
    END IF;
    NEW.created_at := now();
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_id_map_guard ON migration.id_map;
CREATE TRIGGER trg_id_map_guard BEFORE INSERT OR UPDATE OR DELETE ON migration.id_map FOR EACH ROW EXECUTE FUNCTION migration.id_map_guard();
DROP TRIGGER IF EXISTS trg_touch ON migration.id_map;
CREATE TRIGGER trg_touch BEFORE UPDATE ON migration.id_map FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- ---------- نگاشت ----------
CREATE OR REPLACE FUNCTION migration.mapping_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.job_id IS NOT NULL THEN
      -- RV-MG-08: نگاشت‌های کاری (با مقدار مبدأ، مثل نام شخص) در پاک‌سازی نگهداری کار پایانی پاک می‌شوند
      IF migration.purge_allowed(OLD.tenant_id, OLD.job_id) THEN RETURN OLD; END IF;
      PERFORM migration.assert_job_status(OLD.tenant_id, OLD.job_id, ARRAY['staged','mapping'], 'changing job mappings');
    END IF;
    RETURN OLD;
  END IF;
  IF NEW.job_id IS NOT NULL THEN
    PERFORM migration.assert_job_status(NEW.tenant_id, NEW.job_id, ARRAY['staged','mapping'], 'changing job mappings');
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF (NEW.tenant_id, NEW.id, NEW.job_id, NEW.kind, NEW.scope, NEW.source_value_norm)
       IS DISTINCT FROM (OLD.tenant_id, OLD.id, OLD.job_id, OLD.kind, OLD.scope, OLD.source_value_norm) THEN
      PERFORM migration.raise_error('HK_MIG_IMMUTABLE_FIELD', 'mapping key is immutable');
    END IF;
  END IF;
  IF NEW.kind = 'column' AND NEW.source_value_norm <> migration.norm_header(NEW.source_value) THEN
    PERFORM migration.raise_error('HK_MIG_HEADER_NORM', 'column mappings are keyed by the normalized header');
  END IF;
  -- RV-MG-13 / INV-MIG-09/10: «تأیید انسانی» کنش خود کاربر جاری است، نه کنشگری که برنامه به ستون می‌نویسد
  IF NEW.confirmed_by IS NOT NULL
     AND (TG_OP = 'INSERT' OR (NEW.confirmed_by, NEW.confirmed_at) IS DISTINCT FROM (OLD.confirmed_by, OLD.confirmed_at)) THEN
    PERFORM migration.assert_human_act(NEW.confirmed_by, 'confirming a mapping');
    NEW.confirmed_at := now();
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_mapping_guard ON migration.mapping;
CREATE TRIGGER trg_mapping_guard BEFORE INSERT OR UPDATE OR DELETE ON migration.mapping FOR EACH ROW EXECUTE FUNCTION migration.mapping_guard();
DROP TRIGGER IF EXISTS trg_touch ON migration.mapping;
CREATE TRIGGER trg_touch BEFORE UPDATE ON migration.mapping FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- ---------- مشکل اعتبارسنجی ----------
CREATE OR REPLACE FUNCTION migration.issue_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE c record;
BEGIN
  IF TG_OP = 'DELETE' THEN
    -- RV-MG-08: فقط پاک‌سازی نگهداری کار پایانی (پیش از ردیف‌های مرحله‌ای و خام)
    IF migration.purge_allowed(OLD.tenant_id, OLD.job_id) THEN RETURN OLD; END IF;
    PERFORM migration.raise_error('HK_MIG_NO_DELETE', 'issues are resolved or overridden, never deleted');
  END IF;
  SELECT * INTO c FROM migration.issue_code ic WHERE ic.code = NEW.code;
  IF TG_OP = 'INSERT' THEN
    PERFORM migration.assert_job_status(NEW.tenant_id, NEW.job_id,
      ARRAY['awaiting_source','staged','mapping','validated','previewed','committing','committed','reconciled','failed'], 'raising an issue');
    IF NEW.severity <> c.default_severity THEN
      PERFORM migration.raise_error('HK_MIG_ISSUE_SEVERITY', format('%s has severity %s', NEW.code, c.default_severity));
    END IF;
    IF NEW.status <> 'open' THEN
      PERFORM migration.raise_error('HK_MIG_ISSUE_TRANSITION', 'issues start open');
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.tenant_id, NEW.id, NEW.job_id, NEW.code, NEW.severity, NEW.staged_record_id, NEW.raw_record_id, NEW.upload_id, NEW.field, NEW.params)
     IS DISTINCT FROM (OLD.tenant_id, OLD.id, OLD.job_id, OLD.code, OLD.severity, OLD.staged_record_id, OLD.raw_record_id, OLD.upload_id, OLD.field, OLD.params) THEN
    PERFORM migration.raise_error('HK_MIG_IMMUTABLE_FIELD', 'an issue is immutable except its resolution');
  END IF;
  IF NEW.status <> OLD.status THEN
    IF OLD.status <> 'open' THEN
      PERFORM migration.raise_error('HK_MIG_ISSUE_TRANSITION', 'resolved or overridden issues are final; re-validation raises new issues');
    END IF;
    -- INV-MIG-16: فقط کد قابل override و با دلیل
    IF NEW.status = 'overridden' AND NOT c.overridable THEN
      PERFORM migration.raise_error('HK_MIG_NOT_OVERRIDABLE', format('%s cannot be overridden', NEW.code));
    END IF;
    IF NEW.status = 'overridden' AND NEW.overridden_by IS NOT NULL THEN
      PERFORM migration.assert_human_act(NEW.overridden_by, 'overriding an issue');            -- RV-MG-13
      NEW.overridden_at := now();
    ELSIF NEW.status = 'resolved' THEN
      NEW.resolved_at := now();
    END IF;
  ELSIF (NEW.overridden_by, NEW.overridden_at, NEW.override_reason, NEW.resolved_at)
        IS DISTINCT FROM (OLD.overridden_by, OLD.overridden_at, OLD.override_reason, OLD.resolved_at) THEN
    PERFORM migration.raise_error('HK_MIG_ISSUE_TRANSITION', 'the resolution is recorded with the status change');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_issue_guard ON migration.issue;
CREATE TRIGGER trg_issue_guard BEFORE INSERT OR UPDATE OR DELETE ON migration.issue FOR EACH ROW EXECUTE FUNCTION migration.issue_guard();
DROP TRIGGER IF EXISTS trg_touch ON migration.issue;
CREATE TRIGGER trg_touch BEFORE UPDATE ON migration.issue FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- ---------- dry-run: فقط‌افزودنی، فقط روی دادهٔ اعتبارسنجی‌شده ----------
CREATE OR REPLACE FUNCTION migration.dry_run_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM migration.assert_job_status(NEW.tenant_id, NEW.job_id, ARRAY['validated'], 'recording a dry-run');
  IF NEW.seq <> coalesce((SELECT max(seq) FROM migration.dry_run d WHERE d.tenant_id = NEW.tenant_id AND d.job_id = NEW.job_id), 0) + 1 THEN
    PERFORM migration.raise_error('HK_MIG_SEQ', 'dry-run sequence is gapless');
  END IF;
  NEW.finished_at := now();          -- RV-MG-06: گیت previewed dry-run ثبت‌شده پیش از آخرین ورود به validated را نمی‌پذیرد
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_dry_run_guard ON migration.dry_run;
CREATE TRIGGER trg_dry_run_guard BEFORE INSERT ON migration.dry_run FOR EACH ROW EXECUTE FUNCTION migration.dry_run_guard();
DROP TRIGGER IF EXISTS trg_forbid_mutation ON migration.dry_run;
CREATE TRIGGER trg_forbid_mutation BEFORE UPDATE OR DELETE ON migration.dry_run FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

-- ---------- تکهٔ ثبت ----------
CREATE OR REPLACE FUNCTION migration.commit_chunk_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_job record; v_status text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM migration.raise_error('HK_MIG_NO_DELETE', 'commit chunks are checkpoints and are never deleted');
  END IF;
  IF TG_OP = 'INSERT' THEN
    v_status := migration.lock_job_status(NEW.tenant_id, NEW.job_id);
    -- RV-MG-15: برنامهٔ ثبت فقط در previewed (و در همان تراکنشِ گذار به committing) یا در dry-run ساخته می‌شود؛ پس از آن ثابت است
    IF NOT (v_status = 'previewed' OR (v_status = 'validated' AND migration.in_dry_run())) THEN
      PERFORM migration.raise_error('HK_MIG_JOB_STATE', format('planning commit chunks is not allowed while the job is %s', coalesce(v_status, 'missing')));
    END IF;
    IF NEW.status <> 'pending' OR NEW.done_count <> 0 OR NEW.attempts <> 0 OR NEW.started_at IS NOT NULL OR NEW.finished_at IS NOT NULL THEN
      PERFORM migration.raise_error('HK_MIG_CHUNK_TRANSITION', 'chunks start pending');
    END IF;
    SELECT j.mode, j.is_rehearsal INTO v_job FROM migration.job j WHERE j.tenant_id = NEW.tenant_id AND j.id = NEW.job_id;
    IF (v_job.mode = 'archive') <> (NEW.stage = 'archive') THEN
      PERFORM migration.raise_error('HK_MIG_CHUNK_STAGE', 'an archive job has only archive chunks, and only an archive job has them');
    END IF;
    -- RV-MG-01 / CR-MG14: تمرین هرگز حافظهٔ مؤدیان (یکتا در مستأجر) را لمس نمی‌کند
    IF v_job.is_rehearsal AND NEW.stage = 'tax_continuity' THEN
      PERFORM migration.raise_error('HK_MIG_REHEARSAL_SCOPE', 'a rehearsal job never registers Moadian continuity');
    END IF;
    -- D-MG17 / INV-MIG-18: ترتیب ثابت مرحله‌ها با شمارهٔ تکه هم‌جهت است
    IF EXISTS (SELECT 1 FROM migration.commit_chunk c WHERE c.tenant_id = NEW.tenant_id AND c.job_id = NEW.job_id
                 AND ((c.chunk_no < NEW.chunk_no AND migration.stage_rank(c.stage) > migration.stage_rank(NEW.stage))
                   OR (c.chunk_no > NEW.chunk_no AND migration.stage_rank(c.stage) < migration.stage_rank(NEW.stage)))) THEN
      PERFORM migration.raise_error('HK_MIG_CHUNK_ORDER', format('stage %s is out of the fixed stage order', NEW.stage));
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.tenant_id, NEW.id, NEW.job_id, NEW.chunk_no, NEW.stage, NEW.item_count)
     IS DISTINCT FROM (OLD.tenant_id, OLD.id, OLD.job_id, OLD.chunk_no, OLD.stage, OLD.item_count) THEN
    PERFORM migration.raise_error('HK_MIG_IMMUTABLE_FIELD', 'the commit plan is immutable');
  END IF;
  IF NEW.status <> OLD.status THEN
    IF (OLD.status, NEW.status) NOT IN (('pending','running'), ('running','done'), ('running','failed'), ('running','pending'), ('failed','running')) THEN
      PERFORM migration.raise_error('HK_MIG_CHUNK_TRANSITION', format('chunk %s -> %s is not allowed', OLD.status, NEW.status));
    END IF;
    IF NEW.status = 'running' THEN
      v_status := migration.lock_job_status(NEW.tenant_id, NEW.job_id);
      IF NOT (v_status = 'committing' OR (v_status = 'validated' AND migration.in_dry_run())) THEN
        PERFORM migration.raise_error('HK_MIG_JOB_STATE', format('running a commit chunk is not allowed while the job is %s', coalesce(v_status, 'missing')));
      END IF;
      -- INV-MIG-18: ترتیب وابستگی: هیچ تکه پیش از تمام شدن تکه‌های قبلی اجرا نمی‌شود
      IF EXISTS (SELECT 1 FROM migration.commit_chunk c WHERE c.tenant_id = NEW.tenant_id AND c.job_id = NEW.job_id
                   AND c.chunk_no < NEW.chunk_no AND c.status <> 'done') THEN
        PERFORM migration.raise_error('HK_MIG_CHUNK_ORDER', 'earlier chunks must be done first');
      END IF;
      NEW.attempts := OLD.attempts + 1;
      NEW.started_at := now();
    ELSIF NEW.status = 'done' THEN
      NEW.finished_at := coalesce(NEW.finished_at, now());
    END IF;
  ELSIF OLD.status = 'done' AND NEW IS DISTINCT FROM OLD THEN
    PERFORM migration.raise_error('HK_MIG_CHUNK_TRANSITION', 'a done chunk is final');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_commit_chunk_guard ON migration.commit_chunk;
CREATE TRIGGER trg_commit_chunk_guard BEFORE INSERT OR UPDATE OR DELETE ON migration.commit_chunk FOR EACH ROW EXECUTE FUNCTION migration.commit_chunk_guard();
DROP TRIGGER IF EXISTS trg_touch ON migration.commit_chunk;
CREATE TRIGGER trg_touch BEFORE UPDATE ON migration.commit_chunk FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- ---------- دفتر اثرهای مهاجرت ----------
CREATE OR REPLACE FUNCTION migration.posting_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_status text; v_company uuid; v_chunk text; v_staged record; v_entity text; v_class text; v_policy text; v_jr record;
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM migration.raise_error('HK_MIG_NO_DELETE', 'postings are compensated, never deleted');
  END IF;
  IF TG_OP = 'INSERT' THEN
    v_status := migration.lock_job_status(NEW.tenant_id, NEW.job_id);
    IF NOT (v_status = 'committing' OR (v_status = 'validated' AND migration.in_dry_run())) THEN
      PERFORM migration.raise_error('HK_MIG_JOB_STATE', format('recording a posting is not allowed while the job is %s', coalesce(v_status, 'missing')));
    END IF;
    SELECT j.company_id INTO v_company FROM migration.job j WHERE j.tenant_id = NEW.tenant_id AND j.id = NEW.job_id;
    NEW.company_id := coalesce(NEW.company_id, v_company);          -- FK سه‌ستونی برابری با شرکت کار را می‌سنجد
    SELECT status INTO v_chunk FROM migration.commit_chunk c WHERE c.tenant_id = NEW.tenant_id AND c.job_id = NEW.job_id AND c.chunk_no = NEW.chunk_no;
    IF v_chunk IS DISTINCT FROM 'running' THEN
      PERFORM migration.raise_error('HK_MIG_CHUNK_STATE', 'postings are recorded only inside a running chunk');
    END IF;
    IF NEW.state <> 'live' OR NEW.compensation_kind IS NOT NULL OR NEW.compensation_doc_id IS NOT NULL OR NEW.compensated_at IS NOT NULL THEN
      PERFORM migration.raise_error('HK_MIG_POSTING_TRANSITION', 'postings start live');
    END IF;
    NEW.posted_at := now();
    IF NEW.staged_record_id IS NOT NULL THEN
      SELECT entity, disposition, partition_class, legacy_code, source_system, source_db, source_table, source_key INTO v_staged
        FROM migration.staged_record s WHERE s.tenant_id = NEW.tenant_id AND s.job_id = NEW.job_id AND s.id = NEW.staged_record_id;
      IF (v_staged.source_system, v_staged.source_db, v_staged.source_table, v_staged.source_key)
         IS DISTINCT FROM (NEW.source_system, NEW.source_db, NEW.source_table, NEW.source_key) THEN
        PERFORM migration.raise_error('HK_MIG_LINEAGE', 'posting lineage must equal the staged row lineage');
      END IF;
      v_entity := v_staged.entity;
      -- RV-MG-08 / RV-MG-19: lineage در خود posting کپی می‌شود (پس از پاک‌سازی و پس از جابه‌جایی .hkx می‌ماند)
      NEW.staged_entity := v_staged.entity;
      NEW.legacy_code := v_staged.legacy_code;
      NEW.partition_class := v_staged.partition_class;
      NEW.disposition := v_staged.disposition;
      -- INV-MIG-08: سندی که ماژول تخصصی بازسازی می‌کند (regenerate) یا کنار گذاشته شده، دوباره در دفتر کل ثبت نمی‌شود
      IF v_entity = 'voucher' AND (NEW.target_doc_type = 'ledger.journal' OR NEW.gl_effect = 'posted')
         AND v_staged.disposition NOT IN ('opening_gl','history_gl') THEN
        PERFORM migration.raise_error('HK_MIG_DOUBLE_POSTING', format('voucher %s is %s; its GL comes from the specialised module or is skipped',
                                                                       v_staged.source_key, v_staged.disposition));
      END IF;
      -- D-MG10 / INV-MIG-38 (RV-MG-07): فقط تراز افتتاحیه، سند مبدأ و سند بازسازی‌شده اثر GL دارند؛
      -- موقعیت زیردفترها و دادهٔ پایه همیشه بی‌GL‌اند
      IF NEW.gl_effect = 'posted' AND v_entity NOT IN ('opening_balance_line','voucher','invoice_history','receipt_payment') THEN
        PERFORM migration.raise_error('HK_MIG_DOUBLE_POSTING', format('%s rows never post to the GL; sub-ledger positions and master data are GL-free', v_entity));
      END IF;
      -- RV-MG-07: سند بازسازی‌شده با GL فقط وقتی کلاسش در این کار regenerate است؛ وگرنه سند GL مبدأ (history_gl) همان را ثبت کرده است
      IF NEW.gl_effect = 'posted' AND v_entity IN ('invoice_history','receipt_payment') THEN
        v_class := CASE v_entity WHEN 'invoice_history' THEN 'INVOICE' ELSE 'RECEIPT_PAYMENT' END;
        SELECT p.disposition INTO v_policy FROM migration.job_partition_policy p
         WHERE p.tenant_id = NEW.tenant_id AND p.job_id = NEW.job_id AND p.partition_class = v_class;
        IF v_policy IS NOT NULL AND v_policy <> 'regenerate' THEN
          PERFORM migration.raise_error('HK_MIG_DOUBLE_POSTING', format('class %s is %s in this job; regenerated documents carry no GL (gl_mode=none)', v_class, v_policy));
        END IF;
      END IF;
    ELSIF NEW.gl_effect = 'posted'
          AND NOT (NEW.target_module = 'migration' AND NEW.target_doc_type IN ('migration.period_summary','migration.inventory_conversion')) THEN
      -- RV-MG-07: ثبت GL بدون رکورد مرحله‌ای فقط برای سندهای مشتق خود migration (خلاصهٔ دوره، تبدیل ادواری به دائمی)
      PERFORM migration.raise_error('HK_MIG_LINEAGE', 'a GL posting names its staged record (only migration summary and conversion journals are derived)');
    END IF;
    -- RV-MG-07 / INV-MIG-36: سند دفتر کل از همان شرکت (FK سه‌ستونی) و از منشأ درست است
    IF NEW.journal_id IS NOT NULL THEN
      SELECT j.source_module, j.journal_type, j.source_doc_id INTO v_jr
        FROM ledger.journal j WHERE j.tenant_id = NEW.tenant_id AND j.company_id = NEW.company_id AND j.id = NEW.journal_id;
      IF FOUND THEN
        IF NEW.target_module IN ('ledger','migration') THEN
          IF v_jr.source_module <> 'migration' OR v_jr.journal_type NOT IN ('opening_import','history_import')
             OR (NEW.target_doc_type IN ('ledger.journal','migration.period_summary','migration.inventory_conversion') AND NEW.target_doc_id <> NEW.journal_id)
             OR (v_entity = 'voucher' AND v_jr.source_doc_id IS DISTINCT FROM NEW.staged_record_id) THEN
            PERFORM migration.raise_error('HK_MIG_JOURNAL_SOURCE', 'a migration GL posting points at its own opening_import/history_import journal');
          END IF;
        ELSIF v_jr.source_module <> NEW.target_module OR v_jr.source_doc_id IS DISTINCT FROM NEW.target_doc_id THEN
          PERFORM migration.raise_error('HK_MIG_JOURNAL_SOURCE', 'a regenerated document''s journal belongs to that document in its owning module');
        END IF;
      END IF;
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.tenant_id, NEW.id, NEW.job_id, NEW.company_id, NEW.chunk_no, NEW.source_system, NEW.source_db, NEW.source_table,
      NEW.source_key, NEW.target_module, NEW.target_doc_type, NEW.target_doc_id, NEW.journal_id, NEW.gl_effect, NEW.amount_base, NEW.posted_at,
      NEW.staged_entity, NEW.legacy_code, NEW.partition_class, NEW.disposition)
     IS DISTINCT FROM
     (OLD.tenant_id, OLD.id, OLD.job_id, OLD.company_id, OLD.chunk_no, OLD.source_system, OLD.source_db, OLD.source_table,
      OLD.source_key, OLD.target_module, OLD.target_doc_type, OLD.target_doc_id, OLD.journal_id, OLD.gl_effect, OLD.amount_base, OLD.posted_at,
      OLD.staged_entity, OLD.legacy_code, OLD.partition_class, OLD.disposition)
     OR (NEW.staged_record_id IS DISTINCT FROM OLD.staged_record_id
         AND NOT (NEW.staged_record_id IS NULL AND coalesce(current_setting('hk.migration_purge', true), '') = 'on')) THEN
    PERFORM migration.raise_error('HK_MIG_IMMUTABLE_FIELD', 'a posting record is immutable');
  END IF;
  IF NEW.state <> OLD.state THEN
    -- INV-MIG-20: جبران فقط در rollback پیش از قفل
    IF (OLD.state, NEW.state) <> ('live','compensated') THEN
      PERFORM migration.raise_error('HK_MIG_POSTING_TRANSITION', 'postings go live -> compensated only');
    END IF;
    PERFORM migration.assert_job_status(NEW.tenant_id, NEW.job_id, ARRAY['rolling_back'], 'compensating a posting');
    NEW.compensated_at := now();
  ELSIF (NEW.compensation_doc_id, NEW.compensation_kind, NEW.compensated_at)
        IS DISTINCT FROM (OLD.compensation_doc_id, OLD.compensation_kind, OLD.compensated_at) THEN
    PERFORM migration.raise_error('HK_MIG_IMMUTABLE_FIELD', 'compensation is recorded with the state change');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_posting_guard ON migration.posting;
CREATE TRIGGER trg_posting_guard BEFORE INSERT OR UPDATE OR DELETE ON migration.posting FOR EACH ROW EXECUTE FUNCTION migration.posting_guard();

-- ---------- ارقام مبدأ، تطبیق، آرشیو: فقط‌افزودنی ----------
CREATE OR REPLACE FUNCTION migration.append_only_job_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_status text; v_job record;
BEGIN
  IF TG_TABLE_NAME = 'source_balance' THEN
    PERFORM migration.assert_job_status(NEW.tenant_id, NEW.job_id,
      ARRAY['awaiting_source','staged','mapping','validated','previewed','committing','committed','reconciled'], 'capturing source control figures');
  ELSIF TG_TABLE_NAME = 'reconciliation' THEN
    PERFORM migration.assert_job_status(NEW.tenant_id, NEW.job_id, ARRAY['committed','reconciled'], 'recording a reconciliation');
    IF NEW.seq <> coalesce((SELECT max(seq) FROM migration.reconciliation r WHERE r.tenant_id = NEW.tenant_id AND r.job_id = NEW.job_id), 0) + 1 THEN
      PERFORM migration.raise_error('HK_MIG_SEQ', 'reconciliation sequence is gapless');
    END IF;
    NEW.created_at := now();
  ELSIF TG_TABLE_NAME = 'archive_entry' THEN
    v_status := migration.lock_job_status(NEW.tenant_id, NEW.job_id);
    SELECT j.mode, j.source_system INTO v_job FROM migration.job j WHERE j.tenant_id = NEW.tenant_id AND j.id = NEW.job_id;
    IF v_job.mode IS DISTINCT FROM 'archive' OR NOT (v_status = 'committing' OR (v_status = 'validated' AND migration.in_dry_run())) THEN
      PERFORM migration.raise_error('HK_MIG_ARCHIVE_ONLY', 'archive entries are written only by a committing archive job');
    END IF;
    IF NEW.source_system IS DISTINCT FROM v_job.source_system THEN
      PERFORM migration.raise_error('HK_MIG_LINEAGE', 'an archive entry carries the job''s source system');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_append_guard ON migration.source_balance;
CREATE TRIGGER trg_append_guard BEFORE INSERT ON migration.source_balance FOR EACH ROW EXECUTE FUNCTION migration.append_only_job_guard();
DROP TRIGGER IF EXISTS trg_append_guard ON migration.reconciliation;
CREATE TRIGGER trg_append_guard BEFORE INSERT ON migration.reconciliation FOR EACH ROW EXECUTE FUNCTION migration.append_only_job_guard();
DROP TRIGGER IF EXISTS trg_append_guard ON migration.archive_entry;
CREATE TRIGGER trg_append_guard BEFORE INSERT ON migration.archive_entry FOR EACH ROW EXECUTE FUNCTION migration.append_only_job_guard();
DROP TRIGGER IF EXISTS trg_forbid_mutation ON migration.source_balance;
CREATE TRIGGER trg_forbid_mutation BEFORE UPDATE OR DELETE ON migration.source_balance FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();
DROP TRIGGER IF EXISTS trg_forbid_mutation ON migration.reconciliation;
CREATE TRIGGER trg_forbid_mutation BEFORE UPDATE OR DELETE ON migration.reconciliation FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();
DROP TRIGGER IF EXISTS trg_forbid_mutation ON migration.reconciliation_line;
CREATE TRIGGER trg_forbid_mutation BEFORE UPDATE OR DELETE ON migration.reconciliation_line FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();
DROP TRIGGER IF EXISTS trg_forbid_mutation ON migration.archive_entry;
CREATE TRIGGER trg_forbid_mutation BEFORE UPDATE OR DELETE ON migration.archive_entry FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

-- سطر تطبیق: فقط در کار committed/reconciled، فقط تا ظرفیت سرآیند؛ توضیح باید تأییدشده، هم‌کلید و دقیقاً برابر اختلاف باشد
CREATE OR REPLACE FUNCTION migration.reconciliation_line_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE e record; v_count integer;
BEGIN
  PERFORM migration.assert_job_status(NEW.tenant_id, NEW.job_id, ARRAY['committed','reconciled'], 'adding reconciliation lines');
  SELECT r.line_count INTO v_count FROM migration.reconciliation r WHERE r.tenant_id = NEW.tenant_id AND r.id = NEW.reconciliation_id;
  IF NEW.line_no IS NULL THEN
    SELECT coalesce(max(l.line_no), 0) + 1 INTO NEW.line_no
      FROM migration.reconciliation_line l WHERE l.tenant_id = NEW.tenant_id AND l.reconciliation_id = NEW.reconciliation_id;
  END IF;
  -- RV-MG-04 / INV-MIG-19: سرآیند تغییرناپذیر شمار سطرها را ثابت می‌کند؛ line_no یکتا در ۱..line_count یعنی سطر دیرهنگام جا ندارد
  IF NEW.line_no > v_count THEN
    PERFORM migration.raise_error('HK_MIG_RECONCILIATION_TOTALS',
      format('reconciliation already holds its %s lines; record a new reconciliation instead', v_count));
  END IF;
  IF NEW.explanation_id IS NOT NULL THEN
    SELECT * INTO e FROM migration.explanation x WHERE x.tenant_id = NEW.tenant_id AND x.id = NEW.explanation_id;
    IF e.status <> 'approved' OR e.check_kind <> NEW.check_kind OR e.key <> NEW.key
       OR e.amount <> (NEW.target_value - NEW.source_value) THEN
      PERFORM migration.raise_error('HK_MIG_EXPLANATION_MISMATCH',
        'an explanation must be approved, for the same check and key, and equal to the exact difference');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_reconciliation_line_guard ON migration.reconciliation_line;
CREATE TRIGGER trg_reconciliation_line_guard BEFORE INSERT ON migration.reconciliation_line
  FOR EACH ROW EXECUTE FUNCTION migration.reconciliation_line_guard();

-- INV-MIG-19: سرآیند تطبیق با سطرهایش سازگار است (deferred؛ در commit)
CREATE OR REPLACE FUNCTION migration.reconciliation_check() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_lines integer; v_unexp integer;
BEGIN
  PERFORM ledger.assert_tenant_context(NEW.tenant_id);
  SELECT count(*), count(*) FILTER (WHERE l.line_status = 'unexplained') INTO v_lines, v_unexp
    FROM migration.reconciliation_line l WHERE l.tenant_id = NEW.tenant_id AND l.reconciliation_id = NEW.id;
  IF v_lines <> NEW.line_count OR v_unexp <> NEW.unexplained_count THEN
    PERFORM migration.raise_error('HK_MIG_RECONCILIATION_TOTALS',
      format('header says %s lines / %s unexplained, lines say %s / %s', NEW.line_count, NEW.unexplained_count, v_lines, v_unexp));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM migration.reconciliation_line l WHERE l.tenant_id = NEW.tenant_id AND l.reconciliation_id = NEW.id
                   AND l.check_kind = 'trial_balance')
     AND (SELECT mode FROM migration.job j WHERE j.tenant_id = NEW.tenant_id AND j.id = NEW.job_id) <> 'archive' THEN
    PERFORM migration.raise_error('HK_MIG_RECONCILIATION_SCOPE', 'a ledger-affecting job is reconciled at least on the trial balance');
  END IF;
  -- RV-MG-21 / INV-MIG-38: کاری که موقعیت زیردفتر ساخته است، حساب‌های کنترل را هم تطبیق می‌دهد (تلورانس صفر)
  IF EXISTS (SELECT 1 FROM migration.posting p WHERE p.tenant_id = NEW.tenant_id AND p.job_id = NEW.job_id AND p.state = 'live'
               AND p.gl_effect = 'none' AND p.target_module IN ('inventory','treasury','assets'))
     AND NOT EXISTS (SELECT 1 FROM migration.reconciliation_line l WHERE l.tenant_id = NEW.tenant_id AND l.reconciliation_id = NEW.id
                       AND l.check_kind = 'control_account') THEN
    PERFORM migration.raise_error('HK_MIG_RECONCILIATION_SCOPE', 'a job with sub-ledger positions is reconciled on the control accounts');
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_reconciliation_check ON migration.reconciliation;
CREATE CONSTRAINT TRIGGER trg_reconciliation_check AFTER INSERT ON migration.reconciliation
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION migration.reconciliation_check();

-- ---------- توضیح اختلاف ----------
CREATE OR REPLACE FUNCTION migration.explanation_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM migration.raise_error('HK_MIG_NO_DELETE', 'explanations are withdrawn, never deleted');
  END IF;
  IF TG_OP = 'INSERT' THEN
    PERFORM migration.assert_job_status(NEW.tenant_id, NEW.job_id, ARRAY['validated','previewed','committing','committed','reconciled'],
                                        'explaining a difference');
    IF NEW.status <> 'proposed' OR NEW.approved_by IS NOT NULL THEN
      PERFORM migration.raise_error('HK_MIG_EXPLANATION_TRANSITION', 'explanations start proposed');
    END IF;
    NEW.created_at := now();
    RETURN NEW;
  END IF;
  IF (NEW.tenant_id, NEW.id, NEW.job_id, NEW.check_kind, NEW.key, NEW.category, NEW.amount, NEW.description, NEW.evidence, NEW.created_by, NEW.created_at)
     IS DISTINCT FROM (OLD.tenant_id, OLD.id, OLD.job_id, OLD.check_kind, OLD.key, OLD.category, OLD.amount, OLD.description, OLD.evidence, OLD.created_by, OLD.created_at) THEN
    PERFORM migration.raise_error('HK_MIG_IMMUTABLE_FIELD', 'an explanation is immutable; withdraw it and add a new one');
  END IF;
  IF NEW.status <> OLD.status THEN
    IF (OLD.status, NEW.status) NOT IN (('proposed','approved'), ('proposed','withdrawn'), ('approved','withdrawn')) THEN
      PERFORM migration.raise_error('HK_MIG_EXPLANATION_TRANSITION', format('explanation %s -> %s is not allowed', OLD.status, NEW.status));
    END IF;
    IF NEW.status = 'approved' THEN
      PERFORM migration.assert_job_status(NEW.tenant_id, NEW.job_id, ARRAY['validated','previewed','committing','committed'],
                                          'approving an explanation (move a reconciled job back to committed first)');
      -- RV-MG-13 / D-MG19: تأیید توضیح کنش خود حسابدار است
      IF NEW.approved_by IS NOT NULL THEN
        PERFORM migration.assert_human_act(NEW.approved_by, 'approving an explanation', true);
        NEW.approved_at := now();
      END IF;
    ELSIF NEW.status = 'withdrawn' THEN
      PERFORM migration.assert_job_status(NEW.tenant_id, NEW.job_id, ARRAY['validated','previewed','committing','committed'],
                                          'withdrawing an explanation (move a reconciled job back to committed first)');
    END IF;
  ELSIF (NEW.approved_by, NEW.approved_at) IS DISTINCT FROM (OLD.approved_by, OLD.approved_at) THEN
    PERFORM migration.raise_error('HK_MIG_EXPLANATION_TRANSITION', 'approval is recorded with the status change');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_explanation_guard ON migration.explanation;
CREATE TRIGGER trg_explanation_guard BEFORE INSERT OR UPDATE OR DELETE ON migration.explanation FOR EACH ROW EXECUTE FUNCTION migration.explanation_guard();
DROP TRIGGER IF EXISTS trg_touch ON migration.explanation;
CREATE TRIGGER trg_touch BEFORE UPDATE ON migration.explanation FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- ---------- تداوم مؤدیان ----------
CREATE OR REPLACE FUNCTION migration.moadian_continuity_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_job text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM migration.assert_job_status(OLD.tenant_id, OLD.job_id, ARRAY['staged','mapping'], 'removing continuity rows');
    IF OLD.status <> 'staged' THEN
      PERFORM migration.raise_error('HK_MIG_STAGED_FROZEN', 'committed continuity rows are kept');
    END IF;
    RETURN OLD;
  END IF;
  v_job := migration.lock_job_status(NEW.tenant_id, NEW.job_id);
  IF TG_OP = 'INSERT' THEN
    IF NOT (coalesce(v_job, '') IN ('staged','mapping')) OR NEW.status <> 'staged' THEN
      PERFORM migration.raise_error('HK_MIG_JOB_STATE', 'continuity rows are staged during mapping');
    END IF;
    -- RV-MG-01 / CR-MG14: حافظهٔ مؤدیان در مستأجر یکتاست (tax.memory)؛ کار تمرینی هرگز آن را نمی‌گیرد
    IF EXISTS (SELECT 1 FROM migration.job j WHERE j.tenant_id = NEW.tenant_id AND j.id = NEW.job_id AND j.is_rehearsal) THEN
      PERFORM migration.raise_error('HK_MIG_REHEARSAL_SCOPE', 'a rehearsal job never registers Moadian continuity');
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.tenant_id, NEW.id, NEW.job_id, NEW.company_id) IS DISTINCT FROM (OLD.tenant_id, OLD.id, OLD.job_id, OLD.company_id) THEN
    PERFORM migration.raise_error('HK_MIG_IMMUTABLE_FIELD', 'identity is immutable');
  END IF;
  IF OLD.status <> 'staged' AND (NEW.memory_id, NEW.last_inno, NEW.last_taxid, NEW.connection_mode, NEW.origin)
                                IS DISTINCT FROM (OLD.memory_id, OLD.last_inno, OLD.last_taxid, OLD.connection_mode, OLD.origin) THEN
    PERFORM migration.raise_error('HK_MIG_STAGED_FROZEN', 'committed continuity is frozen');
  END IF;
  IF NEW.status <> OLD.status THEN
    IF NOT ((OLD.status, NEW.status) = ('staged','committed') AND (v_job = 'committing' OR (v_job = 'validated' AND migration.in_dry_run()))
            OR (OLD.status, NEW.status) = ('committed','rolled_back') AND v_job = 'rolling_back') THEN
      PERFORM migration.raise_error('HK_MIG_STAGED_TRANSITION', format('continuity %s -> %s is not allowed while the job is %s', OLD.status, NEW.status, v_job));
    END IF;
  ELSIF OLD.status = 'staged' AND NOT (coalesce(v_job, '') IN ('staged','mapping')) THEN
    PERFORM migration.raise_error('HK_MIG_INPUTS_FROZEN', 'continuity rows change only during mapping');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_moadian_continuity_guard ON migration.moadian_continuity;
CREATE TRIGGER trg_moadian_continuity_guard BEFORE INSERT OR UPDATE OR DELETE ON migration.moadian_continuity
  FOR EACH ROW EXECUTE FUNCTION migration.moadian_continuity_guard();
DROP TRIGGER IF EXISTS trg_touch ON migration.moadian_continuity;
CREATE TRIGGER trg_touch BEFORE UPDATE ON migration.moadian_continuity FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- ---------- نگهبان dry-run (RV-MG-22): تراکنشی که hk.migration_dry_run='on' دارد هرگز commit نمی‌شود ----------
-- WHEN فقط در همان تراکنش dry-run رویداد را صف می‌کند؛ COMMIT واقعی هیچ هزینه‌ای ندارد.
CREATE OR REPLACE FUNCTION migration.dry_run_sentinel() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF migration.in_dry_run() THEN
    PERFORM migration.raise_error('HK_MIG_DRY_RUN_COMMIT', 'a dry-run transaction (hk.migration_dry_run = on) never commits; end it with ROLLBACK');
  END IF;
  RETURN NULL;
END $$;
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['commit_chunk','posting','staged_record','moadian_continuity','archive_entry','id_map'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_dry_run_sentinel ON migration.%I', t);
    EXECUTE format('CREATE CONSTRAINT TRIGGER trg_dry_run_sentinel AFTER INSERT OR UPDATE ON migration.%I '
                   'DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (migration.in_dry_run()) '
                   'EXECUTE FUNCTION migration.dry_run_sentinel()', t);
  END LOOP;
END $$;

-- ---------- RV-MG-27 / R-APPEND: هیچ جدول مستأجری migration (شاهد، lineage یا دادهٔ کاری) TRUNCATE نمی‌شود، حتی با نقش مالک ----------
DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT c.relname FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'migration' AND c.relkind = 'r'
              AND EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a WHERE a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped)
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_no_truncate ON migration.%I', t);
    EXECUTE format('CREATE TRIGGER trg_no_truncate BEFORE TRUNCATE ON migration.%I FOR EACH STATEMENT EXECUTE FUNCTION core.forbid_mutation()', t);
  END LOOP;
END $$;

-- ---------- کاتالوگ پروفایل: منتشرشده تغییرناپذیر ----------
CREATE OR REPLACE FUNCTION migration.profile_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN
      PERFORM migration.raise_error('HK_MIG_PROFILE_IMMUTABLE', 'only draft profiles can be deleted');
    END IF;
    RETURN OLD;
  END IF;
  IF OLD.status IN ('published','retired') AND (NEW.spec, NEW.spec_sha256, NEW.fingerprint, NEW.source_system, NEW.channel)
                                              IS DISTINCT FROM (OLD.spec, OLD.spec_sha256, OLD.fingerprint, OLD.source_system, OLD.channel) THEN
    PERFORM migration.raise_error('HK_MIG_PROFILE_IMMUTABLE', 'a published profile is immutable; publish a new version');
  END IF;
  IF NEW.status <> OLD.status AND (OLD.status, NEW.status) NOT IN
       (('draft','beta'), ('draft','published'), ('beta','published'), ('beta','retired'), ('published','retired'), ('beta','draft')) THEN
    PERFORM migration.raise_error('HK_MIG_PROFILE_IMMUTABLE', format('profile %s -> %s is not allowed', OLD.status, NEW.status));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_profile_guard ON migration.profile;
CREATE TRIGGER trg_profile_guard BEFORE UPDATE OR DELETE ON migration.profile FOR EACH ROW EXECUTE FUNCTION migration.profile_guard();

-- =====================================================================
-- ۵. ویوها (security_invoker)
-- =====================================================================
CREATE OR REPLACE VIEW migration.v_job_blockers WITH (security_invoker = true) AS
SELECT j.tenant_id, j.id AS job_id, j.status,
       (SELECT count(*) FROM migration.issue i WHERE i.tenant_id = j.tenant_id AND i.job_id = j.id AND i.status = 'open' AND i.severity = 'error')   AS open_errors,
       (SELECT count(*) FROM migration.issue i WHERE i.tenant_id = j.tenant_id AND i.job_id = j.id AND i.status = 'open' AND i.severity = 'warning') AS open_warnings,
       (SELECT count(*) FROM migration.staged_record s WHERE s.tenant_id = j.tenant_id AND s.job_id = j.id AND s.status = 'blocked')                 AS blocked_records,
       (SELECT count(*) FROM migration.staged_record s WHERE s.tenant_id = j.tenant_id AND s.job_id = j.id AND s.status = 'pending')                 AS pending_records,
       (j.amount_unit_confirmed_at IS NULL)                                                                                                         AS unit_unconfirmed
  FROM migration.job j;

CREATE OR REPLACE VIEW migration.v_job_progress WITH (security_invoker = true) AS
SELECT j.tenant_id, j.id AS job_id, j.status,
       count(c.id)                                   AS chunks_total,
       count(c.id) FILTER (WHERE c.status = 'done')  AS chunks_done,
       count(c.id) FILTER (WHERE c.status = 'failed') AS chunks_failed,
       coalesce(sum(c.item_count), 0)                AS items_total,
       coalesce(sum(c.done_count), 0)                AS items_done
  FROM migration.job j LEFT JOIN migration.commit_chunk c ON c.tenant_id = j.tenant_id AND c.job_id = j.id
 GROUP BY j.tenant_id, j.id, j.status;

CREATE OR REPLACE VIEW migration.v_reconciliation_latest WITH (security_invoker = true) AS
SELECT DISTINCT ON (r.tenant_id, r.job_id) r.tenant_id, r.job_id, r.id AS reconciliation_id, r.seq, r.as_of, r.status,
       r.line_count, r.unexplained_count, r.created_at
  FROM migration.reconciliation r
 ORDER BY r.tenant_id, r.job_id, r.seq DESC;

-- lineage هر سند دفتر کل به رکورد مبدأ (برای drill-down «این سند از کجا آمد»)
-- RV-MG-08/19: lineage از ستون‌های خود posting می‌آید (پس از پاک‌سازی ردیف مرحله‌ای و پس از جابه‌جایی .hkx هم می‌ماند)
DROP VIEW IF EXISTS migration.v_journal_lineage;
CREATE VIEW migration.v_journal_lineage WITH (security_invoker = true) AS
SELECT p.tenant_id, p.company_id, p.journal_id, p.job_id, p.source_system, p.source_db, p.source_table, p.source_key, p.target_doc_type,
       p.state, p.staged_entity, p.legacy_code, p.partition_class, p.disposition
  FROM migration.posting p
 WHERE p.journal_id IS NOT NULL;

-- =====================================================================
-- ۶. دسترسی‌ها
-- =====================================================================
GRANT USAGE ON SCHEMA migration TO hk_app, hk_readonly;
GRANT SELECT ON migration.source_system, migration.profile, migration.header_synonym, migration.template_column,
                migration.issue_code, migration.partition_rule TO hk_app, hk_readonly;

GRANT SELECT, INSERT, UPDATE ON migration.job, migration.consent, migration.upload, migration.package, migration.staged_record,
                                migration.id_map, migration.mapping, migration.issue, migration.commit_chunk, migration.posting,
                                migration.explanation, migration.moadian_continuity, migration.job_partition_policy TO hk_app;
GRANT SELECT, INSERT, UPDATE ON migration.agent_session, migration.source_credential TO hk_app;
GRANT DELETE ON migration.staged_record, migration.mapping, migration.job_partition_policy, migration.raw_record,
                migration.moadian_continuity, migration.issue TO hk_app;   -- همه با تریگر محافظت می‌شوند (issue فقط پاک‌سازی نگهداری)
GRANT SELECT, INSERT ON migration.job_event, migration.raw_record, migration.dry_run, migration.source_balance,
                        migration.reconciliation, migration.reconciliation_line, migration.archive_entry TO hk_app;
GRANT SELECT ON migration.v_job_blockers, migration.v_job_progress, migration.v_reconciliation_latest, migration.v_journal_lineage
  TO hk_app, hk_readonly;

GRANT SELECT ON migration.job, migration.job_event, migration.consent, migration.upload, migration.package, migration.raw_record,
                migration.staged_record, migration.id_map, migration.mapping, migration.issue, migration.dry_run,
                migration.commit_chunk, migration.posting, migration.source_balance, migration.explanation,
                migration.reconciliation, migration.reconciliation_line, migration.moadian_continuity, migration.archive_entry,
                migration.job_partition_policy TO hk_readonly;
-- رازها: hk_readonly ستون‌های hash/ارجاع راز را نمی‌بیند (درخواست هسته: grant ستونی)
GRANT SELECT (tenant_id, id, job_id, kind, endpoint_base, status, purge_after, purged_at, created_by, created_at, updated_at, row_version)
  ON migration.source_credential TO hk_readonly;
GRANT SELECT (tenant_id, id, job_id, status, expires_at, agent_version, host_os, sql_server_version, sql_compat_level, db_driver,
              trust_server_certificate, login_is_privileged, paired_at, last_seen_at, created_by, created_at, updated_at, row_version)
  ON migration.agent_session TO hk_readonly;

-- =====================================================================
-- ۷. دادهٔ کاتالوگ
-- =====================================================================
INSERT INTO migration.source_system (code, name_fa, name_en, kind, channels, support_status, phase, notes, introduced_in) VALUES
  ('template',       'قالب جامع حساب‌کتاب',         'Hesabketab universal template', 'generic',    '{file}',               'supported',  'v1', 'T00..T17 + T11b', '1.0'),
  ('generic_tb',     'تراز آزمایشی (هر نرم‌افزار)',  'Generic trial balance',         'generic',    '{file}',               'supported',  'v1', '2/4/6/8 column, report-shaped', '1.0'),
  ('eledger',        'دفاتر تجاری الکترونیکی',      'Electronic commercial ledger',  'government', '{file}',               'supported',  'v1', 'both template versions (1403-11 turnover, 1404-02 document)', '1.0'),
  ('insurance_dbf',  'فایل لیست بیمه (DSKWOR00)',     'Insurance list DBF',            'government', '{file}',               'supported',  'v1', 'DSKWOR00.DBF / DSKKAR00.DBF, cp1256', '1.0'),
  ('bank_statement', 'صورتحساب بانک',               'Bank statement',                'bank',       '{file}',               'supported',  'v1', 'via treasury statement profiles', '1.0'),
  ('holoo',          'هلو',                         'Holoo',                         'vendor',     '{agent,backup,file}',  'supported',  'v1', 'SQL Server (Holoo1); APEX needs its own profile', '1.0'),
  ('sepidar',        'سپیدار',                      'Sepidar',                       'vendor',     '{agent,backup,file}',  'supported',  'v1', 'SQL Server (Sepidar01; ACC/GNR/INV/SLS/RPA)', '1.0'),
  ('hesabfa',        'حسابفا',                      'Hesabfa',                       'vendor',     '{api,file}',           'supported',  'v1', 'official API, ≤1 req/s', '1.0'),
  ('mahak',          'محک',                         'Mahak',                         'vendor',     '{agent,backup,file,api}', 'probe_only', 'v2', 'schema unknown until a consented probe', '1.0'),
  ('parmis',         'پارمیس',                      'Parmis',                        'vendor',     '{agent,backup,file}',  'probe_only', 'v2', 'schema unknown until a consented probe', '1.0'),
  ('dasht',          'دشت',                         'Dasht',                         'vendor',     '{file}',               'beta',       'v2', 'report-shaped Excel', '1.0'),
  ('rahkaran',       'راهکاران',                    'Rahkaran',                      'vendor',     '{file}',               'planned',    'v2', 'report-shaped Excel, e-ledger', '1.0'),
  ('tadbir',         'تدبیر',                       'Tadbir',                        'vendor',     '{file}',               'planned',    'v2', 'XML (8.4+) after samples', '1.0'),
  ('rafe',           'رافع',                        'Rafe',                          'vendor',     '{file}',               'planned',    'later', NULL, '1.0'),
  ('mizan',          'میزان',                       'Mizan',                         'vendor',     '{file}',               'planned',    'later', NULL, '1.0'),
  ('other',          'سایر یا دفتر دستی',            'Other / manual books',          'generic',    '{file}',               'supported',  'v1', 'universal template', '1.0')
ON CONFLICT (code) DO NOTHING;

INSERT INTO migration.partition_rule (partition_class, disposition, is_default, phase, description_key) VALUES
  ('OPENING',         'opening_gl', true,  'v1', 'mig.partition.opening.opening_gl'),
  ('OPENING',         'archive',    false, 'v1', 'mig.partition.any.archive'),
  ('SKIP_CONTROL',    'skip',       true,  'v1', 'mig.partition.skip_control.skip'),
  ('CLOSING',         'skip',       true,  'v1', 'mig.partition.closing.skip'),
  ('CLOSING',         'archive',    false, 'v1', 'mig.partition.any.archive'),
  ('CHEQUE',          'history_gl', true,  'v1', 'mig.partition.cheque.history_gl'),
  ('CHEQUE',          'regenerate', false, 'v2', 'mig.partition.cheque.regenerate'),
  ('CHEQUE',          'archive',    false, 'v1', 'mig.partition.any.archive'),
  ('INVOICE',         'regenerate', true,  'v1', 'mig.partition.invoice.regenerate'),
  ('INVOICE',         'history_gl', false, 'v1', 'mig.partition.invoice.history_gl'),
  ('INVOICE',         'archive',    false, 'v1', 'mig.partition.any.archive'),
  ('RECEIPT_PAYMENT', 'regenerate', true,  'v1', 'mig.partition.receipt_payment.regenerate'),
  ('RECEIPT_PAYMENT', 'history_gl', false, 'v1', 'mig.partition.receipt_payment.history_gl'),
  ('RECEIPT_PAYMENT', 'archive',    false, 'v1', 'mig.partition.any.archive'),
  ('EXPENSE_INCOME',  'history_gl', true,  'v1', 'mig.partition.expense_income.history_gl'),
  ('EXPENSE_INCOME',  'archive',    false, 'v1', 'mig.partition.any.archive'),
  ('MANUAL',          'history_gl', true,  'v1', 'mig.partition.manual.history_gl'),
  ('MANUAL',          'archive',    false, 'v1', 'mig.partition.any.archive'),
  ('UNCLASSIFIED',    'blocked',    true,  'v1', 'mig.partition.unclassified.blocked')
ON CONFLICT DO NOTHING;

-- مجوزها پیش از issue_code (FK مجوز override)
INSERT INTO core.permission (code, module, scope_dimensions, risk, allow_service_account, allow_impersonation_write, description_key, introduced_in) VALUES
  ('migration.job.read',              'migration', '{company}', 'normal',    true,  true,  'perm.migration.job.read',              '1.0'),
  ('migration.job.create',            'migration', '{company}', 'sensitive', false, true,  'perm.migration.job.create',            '1.0'),
  ('migration.job.edit',              'migration', '{company}', 'sensitive', false, true,  'perm.migration.job.edit',              '1.0'),
  ('migration.job.commit',            'migration', '{company}', 'critical',  false, true,  'perm.migration.job.commit',            '1.0'),
  ('migration.job.rollback',          'migration', '{company}', 'critical',  false, true,  'perm.migration.job.rollback',          '1.0'),
  ('migration.job.golive',            'migration', '{company}', 'critical',  false, false, 'perm.migration.job.golive',            '1.0'),
  ('migration.consent.sign',          'migration', '{}',        'critical',  false, false, 'perm.migration.consent.sign',          '1.0'),
  ('migration.issue.override',        'migration', '{company}', 'sensitive', false, true,  'perm.migration.issue.override',        '1.0'),
  ('migration.explanation.approve',   'migration', '{company}', 'critical',  false, false, 'perm.migration.explanation.approve',   '1.0'),
  ('migration.agent.pair',            'migration', '{}',        'sensitive', false, true,  'perm.migration.agent.pair',            '1.0'),
  ('migration.credential.manage',     'migration', '{}',        'sensitive', false, false, 'perm.migration.credential.manage',     '1.0'),
  ('migration.archive.read',          'migration', '{company}', 'normal',    true,  false, 'perm.migration.archive.read',          '1.0'),
  ('migration.memory.manage',         'migration', '{}',        'normal',    false, true,  'perm.migration.memory.manage',         '1.0')
ON CONFLICT (code) DO NOTHING;

INSERT INTO core.role_template_permission (template_code, permission_code)
SELECT 'admin', code FROM core.permission
 WHERE module = 'migration' AND code NOT IN ('migration.consent.sign','migration.job.golive','migration.explanation.approve')
UNION ALL SELECT 'accountant', code FROM core.permission WHERE code IN
  ('migration.job.read','migration.job.create','migration.job.edit','migration.job.commit','migration.job.rollback',
   'migration.job.golive','migration.issue.override','migration.explanation.approve','migration.archive.read','migration.memory.manage')
UNION ALL SELECT 'auditor', code FROM core.permission WHERE code IN ('migration.job.read','migration.archive.read')
UNION ALL SELECT 'support_readonly', code FROM core.permission WHERE code IN ('migration.job.read')
ON CONFLICT DO NOTHING;

INSERT INTO migration.issue_code (code, category, default_severity, overridable, override_permission, message_key, introduced_in) VALUES
  ('MIG_REQUIRED_MISSING',         'structural',     'error',   false, NULL, 'mig.issue.required_missing', '1.0'),
  ('MIG_TYPE_INVALID',             'structural',     'error',   false, NULL, 'mig.issue.type_invalid', '1.0'),
  ('MIG_DATE_UNPARSEABLE',         'structural',     'error',   false, NULL, 'mig.issue.date_unparseable', '1.0'),
  ('MIG_DATE_OUT_OF_YEAR',         'business',       'error',   false, NULL, 'mig.issue.date_out_of_year', '1.0'),
  ('MIG_DATE_AFTER_CUTOVER',       'business',       'error',   false, NULL, 'mig.issue.date_after_cutover', '1.0'),
  ('MIG_UNIT_AMBIGUOUS',           'unit',           'error',   false, NULL, 'mig.issue.unit_ambiguous', '1.0'),
  ('MIG_UNIT_MAGNITUDE_SUSPECT',   'unit',           'warning', false, NULL, 'mig.issue.unit_magnitude_suspect', '1.0'),
  ('MIG_ACCOUNT_UNMAPPED',         'referential',    'error',   false, NULL, 'mig.issue.account_unmapped', '1.0'),
  ('MIG_ACCOUNT_NOT_POSTING',      'referential',    'error',   false, NULL, 'mig.issue.account_not_posting', '1.0'),
  ('MIG_DIMENSION_REQUIRED',       'referential',    'error',   false, NULL, 'mig.issue.dimension_required', '1.0'),
  ('MIG_PARTY_UNRESOLVED',         'referential',    'error',   false, NULL, 'mig.issue.party_unresolved', '1.0'),
  ('MIG_BANK_UNRESOLVED',          'referential',    'error',   false, NULL, 'mig.issue.bank_unresolved', '1.0'),
  ('MIG_CASHBOX_UNRESOLVED',       'referential',    'error',   false, NULL, 'mig.issue.cashbox_unresolved', '1.0'),
  ('MIG_ITEM_UNRESOLVED',          'referential',    'error',   false, NULL, 'mig.issue.item_unresolved', '1.0'),
  ('MIG_WAREHOUSE_UNRESOLVED',     'referential',    'error',   false, NULL, 'mig.issue.warehouse_unresolved', '1.0'),
  ('MIG_REFERENCE_MISSING',        'referential',    'error',   false, NULL, 'mig.issue.reference_missing', '1.0'),
  ('MIG_VOUCHER_UNBALANCED',       'business',       'error',   false, NULL, 'mig.issue.voucher_unbalanced', '1.0'),
  ('MIG_VOUCHER_LINE_BLOCKED',     'business',       'error',   false, NULL, 'mig.issue.voucher_line_blocked', '1.0'),
  ('MIG_UNCLASSIFIED_VOUCHER',     'partition',      'error',   false, NULL, 'mig.issue.unclassified_voucher', '1.0'),
  ('MIG_DOUBLE_SOURCE',            'partition',      'error',   false, NULL, 'mig.issue.double_source', '1.0'),
  ('MIG_DUPLICATE_CODE',           'duplicate',      'error',   false, NULL, 'mig.issue.duplicate_code', '1.0'),
  ('MIG_DUPLICATE_CANDIDATE',      'duplicate',      'warning', false, NULL, 'mig.issue.duplicate_candidate', '1.0'),
  ('MIG_DUPLICATE_DOC_NO',         'duplicate',      'error',   false, NULL, 'mig.issue.duplicate_doc_no', '1.0'),
  ('MIG_NATIONAL_CODE_CHECKSUM',   'checksum',       'error',   true,  'migration.issue.override', 'mig.issue.national_code_checksum', '1.0'),
  ('MIG_LEGAL_ID_CHECKSUM',        'checksum',       'error',   true,  'migration.issue.override', 'mig.issue.legal_id_checksum', '1.0'),
  ('MIG_ECONOMIC_CODE_FORMAT',     'checksum',       'warning', false, NULL, 'mig.issue.economic_code_format', '1.0'),
  ('MIG_SHEBA_CHECKSUM',           'checksum',       'error',   true,  'migration.issue.override', 'mig.issue.sheba_checksum', '1.0'),
  ('MIG_CARD_CHECKSUM',            'checksum',       'warning', false, NULL, 'mig.issue.card_checksum', '1.0'),
  ('MIG_POSTAL_CODE_FORMAT',       'checksum',       'warning', false, NULL, 'mig.issue.postal_code_format', '1.0'),
  ('MIG_SAYAD_FORMAT',             'checksum',       'error',   false, NULL, 'mig.issue.sayad_format', '1.0'),
  ('MIG_SAYAD_MISSING_LEGACY',     'checksum',       'warning', false, NULL, 'mig.issue.sayad_missing_legacy', '1.0'),
  ('MIG_TAXID_INVALID',            'continuity',     'error',   false, NULL, 'mig.issue.taxid_invalid', '1.0'),
  ('MIG_SSTID_FORMAT',             'continuity',     'warning', false, NULL, 'mig.issue.sstid_format', '1.0'),
  ('MIG_INNO_NOT_HEX',             'continuity',     'error',   false, NULL, 'mig.issue.inno_not_hex', '1.0'),
  ('MIG_INVOICE_LINES_MISSING',    'continuity',     'warning', false, NULL, 'mig.issue.invoice_lines_missing', '1.0'),
  ('MIG_SSTID_REQUIRED',           'continuity',     'error',   false, NULL, 'mig.issue.sstid_required', '1.0'),
  ('MIG_MOADIAN_AMOUNT_MISMATCH',  'continuity',     'error',   false, NULL, 'mig.issue.moadian_amount_mismatch', '1.0'),
  ('MIG_FX_INCOMPLETE',            'business',       'error',   false, NULL, 'mig.issue.fx_incomplete', '1.0'),
  ('MIG_WARRANTY_DATES',           'business',       'warning', false, NULL, 'mig.issue.warranty_dates', '1.0'),
  ('MIG_UNKNOWN_COST',             'business',       'warning', false, NULL, 'mig.issue.unknown_cost', '1.0'),
  ('MIG_NEGATIVE_STOCK',           'business',       'warning', false, NULL, 'mig.issue.negative_stock', '1.0'),
  ('MIG_NEGATIVE_AMOUNT',          'business',       'error',   false, NULL, 'mig.issue.negative_amount', '1.0'),
  ('MIG_OUTSTANDING_GT_TOTAL',     'business',       'error',   false, NULL, 'mig.issue.outstanding_gt_total', '1.0'),
  ('MIG_SERIAL_QTY',               'business',       'error',   false, NULL, 'mig.issue.serial_qty', '1.0'),
  ('MIG_ITEM_NO_UNIT',             'business',       'warning', false, NULL, 'mig.issue.item_no_unit', '1.0'),
  ('MIG_PRICE_SOURCES_DIFFER',     'business',       'warning', false, NULL, 'mig.issue.price_sources_differ', '1.0'),
  ('MIG_CONTROL_SUM_MISMATCH',     'reconciliation', 'error',   false, NULL, 'mig.issue.control_sum_mismatch', '1.0'),
  ('MIG_REPORT_TOTAL_MISMATCH',    'reconciliation', 'error',   false, NULL, 'mig.issue.report_total_mismatch', '1.0'),
  ('MIG_YEAR_INCOMPLETE',          'reconciliation', 'error',   false, NULL, 'mig.issue.year_incomplete', '1.0'),
  ('MIG_OPENING_REPEATED',         'business',       'error',   false, NULL, 'mig.issue.opening_repeated', '1.0'),
  ('MIG_LOAN_IN_PAYABLES',         'business',       'warning', false, NULL, 'mig.issue.loan_in_payables', '1.0'),
  ('MIG_FILE_UNSAFE',              'security',       'error',   false, NULL, 'mig.issue.file_unsafe', '1.0'),
  ('MIG_FILE_FORMULA',             'security',       'info',    false, NULL, 'mig.issue.file_formula', '1.0'),
  ('MIG_BACKUP_FORMAT_UNKNOWN',    'security',       'error',   false, NULL, 'mig.issue.backup_format_unknown', '1.0'),
  ('MIG_BACKUP_ENCRYPTED',         'security',       'error',   false, NULL, 'mig.issue.backup_encrypted', '1.0'),
  ('MIG_BACKUP_TOO_LARGE',         'security',       'error',   false, NULL, 'mig.issue.backup_too_large', '1.0'),
  ('MIG_SOURCE_LOGIN_PRIVILEGED',  'security',       'warning', false, NULL, 'mig.issue.source_login_privileged', '1.0'),
  ('MIG_PACKAGE_SIGNATURE',        'security',       'error',   false, NULL, 'mig.issue.package_signature', '1.0'),
  ('MIG_PACKAGE_CHECKSUM',         'security',       'error',   false, NULL, 'mig.issue.package_checksum', '1.0'),
  ('MIG_ROW_COUNT_MISMATCH',       'structural',     'error',   false, NULL, 'mig.issue.row_count_mismatch', '1.0'),
  ('MIG_SOURCE_CHANGED_DURING_EXTRACT', 'structural', 'error',   false, NULL, 'mig.issue.source_changed_during_extract', '1.0'),
  ('MIG_PROFILE_UNKNOWN',          'structural',     'error',   false, NULL, 'mig.issue.profile_unknown', '1.0'),
  ('MIG_COMPAT_LEVEL',             'structural',     'info',    false, NULL, 'mig.issue.compat_level', '1.0'),
  ('MIG_PERIODIC_INVENTORY',       'partition',      'info',    false, NULL, 'mig.issue.periodic_inventory', '1.0'),
  ('MIG_GL_SOURCE_CONFLICT',       'partition',      'error',   false, NULL, 'mig.issue.gl_source_conflict', '1.0'),
  ('MIG_MIDQUARTER_CUTOVER',       'business',       'warning', false, NULL, 'mig.issue.midquarter_cutover', '1.0'),
  ('MIG_DELETED_IN_SOURCE',        'structural',     'info',    false, NULL, 'mig.issue.deleted_in_source', '1.0'),
  ('MIG_NORMALIZED',               'structural',     'info',    false, NULL, 'mig.issue.normalized', '1.0')
ON CONFLICT (code) DO NOTHING;

INSERT INTO core.setting_def (key, module, value_type, enum_values, min_value, max_value, allowed_levels, default_value,
                              read_permission, write_permission, description_key, introduced_in) VALUES
  ('migration.upload.retention_days',        'migration', 'int',     NULL, 1, 365, '{tenant}', '30',     NULL, 'migration.job.create', 'setting.migration.upload.retention_days', '1.0'),
  ('migration.raw.retention_days',           'migration', 'int',     NULL, 7, 730, '{tenant}', '90',     NULL, 'migration.job.create', 'setting.migration.raw.retention_days', '1.0'),
  ('migration.commit.chunk_size',            'migration', 'int',     NULL, 100, 10000, '{tenant}', '2000', NULL, 'migration.job.create', 'setting.migration.commit.chunk_size', '1.0'),
  ('migration.dry_run.max_lines_full_tx',    'migration', 'int',     NULL, 1000, 2000000, '{tenant}', '300000', NULL, 'migration.job.create', 'setting.migration.dry_run.max_lines_full_tx', '1.0'),
  -- RV-MG-23: سقف واقعی پارامتر قاعدهٔ تاریخ‌دار migration.hesabfa.max_rps است (⚠ نامطمئن؛ بخش ۰۷). تنظیم مستأجر فقط
  -- پایین‌تر می‌آورد: نرخ مؤثر = min(این تنظیم، پارامتر قاعده) در HesabfaClient؛ پس این‌جا سقف سخت ندارد.
  ('migration.api.hesabfa.max_rps',          'migration', 'decimal', NULL, 0.1, NULL, '{tenant}', '"1.0"',  NULL, 'migration.job.create', 'setting.migration.api.hesabfa.max_rps', '1.0'),
  ('migration.ai_suggestions.enabled',       'migration', 'bool',    NULL, NULL, NULL, '{tenant}', 'false', NULL, 'migration.job.create', 'setting.migration.ai_suggestions.enabled', '1.0')
ON CONFLICT (key) DO NOTHING;

-- RV-MG-09 / RV-X1-06: صفحهٔ کنترل نمی‌تواند در صفحهٔ داده اشتراک ثبت کند؛ هر دو خانوادهٔ رویداد uplink را خود migration ثبت می‌کند
-- (migration.mapping.confirmed خوراک صف نامزد فرهنگ مترادف پنل مالک است؛ §۵-۱۶)
INSERT INTO core.event_subscription (event_type, subscriber) VALUES
  ('migration.job.*', 'uplink'),
  ('migration.mapping.confirmed', 'uplink')
ON CONFLICT DO NOTHING;

INSERT INTO core.retention_class (code, basis, default_period, rules_param_key, min_period, action, description_key) VALUES
  ('migration_raw',       'closed_at', interval '90 days', NULL, interval '7 days', 'delete', 'ret.migration_raw'),
  ('migration_evidence',  'fiscal_year_end', NULL, 'retention.accounting_records.years', NULL, 'archive_then_delete', 'ret.migration_evidence')
ON CONFLICT DO NOTHING;

INSERT INTO core.export_table_registry (schema_name, table_name, module, mode, export_order, pii_columns, secret_columns, note) VALUES
  ('migration','job',                  'migration', 'rows', 9000, '{}', '{}', NULL),
  ('migration','consent',              'migration', 'rows', 9010, '{signer_full_name,client_ip}', '{}', 'legal evidence; kept with the books'),
  ('migration','job_event',            'migration', 'rows', 9020, '{}', '{}', NULL),
  ('migration','job_partition_policy', 'migration', 'rows', 9030, '{}', '{}', NULL),
  ('migration','id_map',               'migration', 'rows', 9040, '{}', '{}', 'keeps re-runs idempotent after a tenant move'),
  ('migration','mapping',              'migration', 'rows', 9050, '{}', '{}', 'tenant mapping memory'),
  ('migration','dry_run',              'migration', 'rows', 9060, '{}', '{}', NULL),
  ('migration','commit_chunk',         'migration', 'rows', 9070, '{}', '{}', NULL),
  ('migration','posting',              'migration', 'hook', 9080, '{}', '{}', 'lineage of every migrated document; the migration export hook writes staged_record_id as NULL (staged rows are not moved; RV-MG-19) and the lineage columns travel in the row'),
  ('migration','source_balance',       'migration', 'rows', 9090, '{}', '{}', 'acceptance evidence'),
  ('migration','explanation',          'migration', 'rows', 9100, '{}', '{}', NULL),
  ('migration','reconciliation',       'migration', 'rows', 9110, '{}', '{}', 'signed acceptance report'),
  ('migration','reconciliation_line',  'migration', 'rows', 9120, '{}', '{}', NULL),
  ('migration','moadian_continuity',   'migration', 'rows', 9130, '{}', '{}', NULL),
  ('migration','archive_entry',        'migration', 'rows', 9140, '{party_name}', '{}', 'mode C archive is tenant data'),
  ('migration','issue',                'migration', 'skip', 0, '{}', '{}', 'working state; regenerated by re-validation; purged by retention'),
  ('migration','staged_record',        'migration', 'skip', 0, '{}', '{}', 'working state with personal data; purged by retention (posting keeps the lineage)'),
  ('migration','raw_record',           'migration', 'skip', 0, '{}', '{}', 'raw source snapshot; purged by retention, never moved'),
  ('migration','package',              'migration', 'skip', 0, '{}', '{}', 'describes uploads of the source placement'),
  ('migration','upload',               'migration', 'skip', 0, '{file_name}', '{}', 'objects are purged after N days'),
  ('migration','agent_session',        'migration', 'skip', 0, '{}', '{pairing_code_hash,token_hash}', 'ephemeral pairing'),
  ('migration','source_credential',    'migration', 'skip', 0, '{}', '{secret_ref}', 'secrets never leave the placement')
ON CONFLICT DO NOTHING;

-- قالب جامع v1: ستون‌های کلیدی هر شیت (فهرست کامل عنوان‌ها در کلیدهای i18n؛ ستون اجباری = *).
-- RV-MG-20: T15 سرآیند و T15b سطرهای فاکتور تاریخی سال جاری با همهٔ فیلدهای tax.invoice/tax.invoice_issue_line؛
-- RV-MG-26: گارانتی کالا در T04 و سریال‌های فروخته‌شده در T12b.
INSERT INTO migration.template_column (template_version, sheet_code, sheet_entity, column_key, ordinal, is_required, data_type, enum_values, title_key) VALUES
  (1,'T00','file_settings','source_system',1,true,'code',NULL,'mig.t00.source_system'),
  (1,'T00','file_settings','source_version',2,false,'text',NULL,'mig.t00.source_version'),
  (1,'T00','file_settings','amount_unit',3,true,'enum','{IRR,IRT,IRR_NEW}','mig.t00.amount_unit'),
  (1,'T00','file_settings','date_format',4,false,'enum','{jalali,gregorian,excel_serial}','mig.t00.date_format'),
  (1,'T00','file_settings','fiscal_year',5,true,'text',NULL,'mig.t00.fiscal_year'),
  (1,'T00','file_settings','cutover_date',6,true,'date',NULL,'mig.t00.cutover_date'),
  (1,'T00','file_settings','prepared_by',7,false,'text',NULL,'mig.t00.prepared_by'),
  (1,'T01','account','account_code',1,true,'code',NULL,'mig.t01.account_code'),
  (1,'T01','account','account_title',2,true,'text',NULL,'mig.t01.account_title'),
  (1,'T01','account','parent_code',3,false,'code',NULL,'mig.t01.parent_code'),
  (1,'T01','account','level',4,false,'enum','{group,general,subsidiary,detail}','mig.t01.level'),
  (1,'T01','account','account_kind',5,true,'enum','{asset,liability,equity,income,expense,memo}','mig.t01.account_kind'),
  (1,'T01','account','nature',6,false,'enum','{debit,credit,none}','mig.t01.nature'),
  (1,'T01','account','role',7,false,'code',NULL,'mig.t01.role'),
  (1,'T01','account','dl_types_allowed',8,false,'text',NULL,'mig.t01.dl_types_allowed'),
  (1,'T01','account','dl_required',9,false,'text',NULL,'mig.t01.dl_required'),
  (1,'T01','account','currency',10,false,'code',NULL,'mig.t01.currency'),
  (1,'T01','account','is_active',11,false,'bool',NULL,'mig.t01.is_active'),
  (1,'T01','account','legacy_code',12,false,'code',NULL,'mig.t01.legacy_code'),
  (1,'T02','dimension_value','dl_type',1,true,'enum','{party,bank_account,cash_box,petty_cash,cost_center,project,unit,other}','mig.t02.dl_type'),
  (1,'T02','dimension_value','dl_code',2,true,'code',NULL,'mig.t02.dl_code'),
  (1,'T02','dimension_value','dl_title',3,true,'text',NULL,'mig.t02.dl_title'),
  (1,'T02','dimension_value','parent_dl_code',4,false,'code',NULL,'mig.t02.parent_dl_code'),
  (1,'T02','dimension_value','linked_party_code',5,false,'code',NULL,'mig.t02.linked_party_code'),
  (1,'T02','dimension_value','is_active',6,false,'bool',NULL,'mig.t02.is_active'),
  (1,'T03','party','legacy_id',1,true,'code',NULL,'mig.t03.legacy_id'),
  (1,'T03','party','code',2,false,'code',NULL,'mig.t03.code'),
  (1,'T03','party','person_type',3,true,'enum','{natural,legal,civil_partnership,foreign_natural,foreign_legal}','mig.t03.person_type'),
  (1,'T03','party','first_name',4,false,'text',NULL,'mig.t03.first_name'),
  (1,'T03','party','last_name',5,false,'text',NULL,'mig.t03.last_name'),
  (1,'T03','party','company_name',6,false,'text',NULL,'mig.t03.company_name'),
  (1,'T03','party','national_code',7,false,'code',NULL,'mig.t03.national_code'),
  (1,'T03','party','national_id',8,false,'code',NULL,'mig.t03.national_id'),
  (1,'T03','party','economic_code',9,false,'code',NULL,'mig.t03.economic_code'),
  (1,'T03','party','postal_code',10,false,'code',NULL,'mig.t03.postal_code'),
  (1,'T03','party','mobile',11,false,'code',NULL,'mig.t03.mobile'),
  (1,'T03','party','address',12,false,'text',NULL,'mig.t03.address'),
  (1,'T03','party','roles',13,true,'text',NULL,'mig.t03.roles'),
  (1,'T03','party','group',14,false,'code',NULL,'mig.t03.group'),
  (1,'T03','party','credit_limit',15,false,'amount',NULL,'mig.t03.credit_limit'),
  (1,'T03','party','sheba',16,false,'code',NULL,'mig.t03.sheba'),
  (1,'T03','party','is_active',17,false,'bool',NULL,'mig.t03.is_active'),
  (1,'T04','item','legacy_id',1,true,'code',NULL,'mig.t04.legacy_id'),
  (1,'T04','item','code',2,true,'code',NULL,'mig.t04.code'),
  (1,'T04','item','name',3,true,'text',NULL,'mig.t04.name'),
  (1,'T04','item','item_type',4,true,'enum','{goods,service,kit}','mig.t04.item_type'),
  (1,'T04','item','category',5,false,'code',NULL,'mig.t04.category'),
  (1,'T04','item','main_uom',6,true,'code',NULL,'mig.t04.main_uom'),
  (1,'T04','item','alt_uom',7,false,'code',NULL,'mig.t04.alt_uom'),
  (1,'T04','item','alt_factor',8,false,'qty',NULL,'mig.t04.alt_factor'),
  (1,'T04','item','barcodes',9,false,'text',NULL,'mig.t04.barcodes'),
  (1,'T04','item','moadian_product_id',10,false,'code',NULL,'mig.t04.moadian_product_id'),
  (1,'T04','item','purchase_price',11,false,'amount',NULL,'mig.t04.purchase_price'),
  (1,'T04','item','sale_price',12,false,'amount',NULL,'mig.t04.sale_price'),
  (1,'T04','item','variant_of',13,false,'code',NULL,'mig.t04.variant_of'),
  (1,'T04','item','attr1_name',14,false,'text',NULL,'mig.t04.attr1_name'),
  (1,'T04','item','attr1_value',15,false,'text',NULL,'mig.t04.attr1_value'),
  (1,'T04','item','attr2_name',16,false,'text',NULL,'mig.t04.attr2_name'),
  (1,'T04','item','attr2_value',17,false,'text',NULL,'mig.t04.attr2_value'),
  (1,'T04','item','track_serial',18,false,'bool',NULL,'mig.t04.track_serial'),
  (1,'T04','item','track_batch',19,false,'bool',NULL,'mig.t04.track_batch'),
  (1,'T04','item','is_active',20,false,'bool',NULL,'mig.t04.is_active'),
  (1,'T04','item','warranty_days',21,false,'int',NULL,'mig.t04.warranty_days'),
  (1,'T04','item','warranty_basis',22,false,'enum','{sale_date,activation}','mig.t04.warranty_basis'),
  (1,'T04','item','warranty_provider',23,false,'code',NULL,'mig.t04.warranty_provider'),
  (1,'T05','warehouse','code',1,true,'code',NULL,'mig.t05.code'),
  (1,'T05','warehouse','name',2,true,'text',NULL,'mig.t05.name'),
  (1,'T05','warehouse','branch',3,false,'code',NULL,'mig.t05.branch'),
  (1,'T06','bom','parent_item',1,true,'code',NULL,'mig.t06.parent_item'),
  (1,'T06','bom','component_item',2,true,'code',NULL,'mig.t06.component_item'),
  (1,'T06','bom','qty',3,true,'qty',NULL,'mig.t06.qty'),
  (1,'T06','bom','uom',4,false,'code',NULL,'mig.t06.uom'),
  (1,'T06','bom','waste_pct',5,false,'decimal',NULL,'mig.t06.waste_pct'),
  (1,'T07','price','price_list',1,true,'code',NULL,'mig.t07.price_list'),
  (1,'T07','price','item_code',2,true,'code',NULL,'mig.t07.item_code'),
  (1,'T07','price','uom',3,false,'code',NULL,'mig.t07.uom'),
  (1,'T07','price','price',4,true,'amount',NULL,'mig.t07.price'),
  (1,'T07','price','valid_from',5,false,'date',NULL,'mig.t07.valid_from'),
  (1,'T08','opening_balance_line','account_code',1,true,'code',NULL,'mig.t08.account_code'),
  (1,'T08','opening_balance_line','dl1_type',2,false,'code',NULL,'mig.t08.dl1_type'),
  (1,'T08','opening_balance_line','dl1_code',3,false,'code',NULL,'mig.t08.dl1_code'),
  (1,'T08','opening_balance_line','dl2_type',4,false,'code',NULL,'mig.t08.dl2_type'),
  (1,'T08','opening_balance_line','dl2_code',5,false,'code',NULL,'mig.t08.dl2_code'),
  (1,'T08','opening_balance_line','debit',6,false,'amount',NULL,'mig.t08.debit'),
  (1,'T08','opening_balance_line','credit',7,false,'amount',NULL,'mig.t08.credit'),
  (1,'T08','opening_balance_line','currency',8,false,'code',NULL,'mig.t08.currency'),
  (1,'T08','opening_balance_line','fx_amount',9,false,'amount',NULL,'mig.t08.fx_amount'),
  (1,'T08','opening_balance_line','fx_rate',10,false,'rate',NULL,'mig.t08.fx_rate'),
  (1,'T09','open_document','doc_kind',1,true,'enum','{sales_invoice,purchase_invoice,sales_return,purchase_return,customer_advance,supplier_advance,other_receivable,other_payable}','mig.t09.doc_kind'),
  (1,'T09','open_document','legacy_doc_no',2,true,'code',NULL,'mig.t09.legacy_doc_no'),
  (1,'T09','open_document','party_code',3,true,'code',NULL,'mig.t09.party_code'),
  (1,'T09','open_document','doc_date',4,true,'date',NULL,'mig.t09.doc_date'),
  (1,'T09','open_document','due_date',5,false,'date',NULL,'mig.t09.due_date'),
  (1,'T09','open_document','total_amount',6,false,'amount',NULL,'mig.t09.total_amount'),
  (1,'T09','open_document','outstanding_amount',7,true,'amount',NULL,'mig.t09.outstanding_amount'),
  (1,'T09','open_document','moadian_taxid',8,false,'code',NULL,'mig.t09.moadian_taxid'),
  (1,'T09','open_document','currency',9,false,'code',NULL,'mig.t09.currency'),
  (1,'T09','open_document','fx_amount',10,false,'amount',NULL,'mig.t09.fx_amount'),
  (1,'T09','open_document','fx_rate',11,false,'rate',NULL,'mig.t09.fx_rate'),
  (1,'T09','open_document','control_account',12,false,'code',NULL,'mig.t09.control_account'),
  (1,'T09','open_document','cost_center',13,false,'code',NULL,'mig.t09.cost_center'),
  (1,'T09','open_document','project',14,false,'code',NULL,'mig.t09.project'),
  (1,'T09','open_document','description',15,false,'text',NULL,'mig.t09.description'),
  (1,'T09','open_document','moadian_inno',16,false,'code',NULL,'mig.t09.moadian_inno'),
  (1,'T09','open_document','moadian_status',17,false,'enum','{not_sent,sent,accepted,rejected,cancelled}','mig.t09.moadian_status'),
  (1,'T10','cheque','direction',1,true,'enum','{received,issued}','mig.t10.direction'),
  (1,'T10','cheque','sayad_id',2,false,'code',NULL,'mig.t10.sayad_id'),
  (1,'T10','cheque','cheque_no',3,true,'code',NULL,'mig.t10.cheque_no'),
  (1,'T10','cheque','bank',4,true,'code',NULL,'mig.t10.bank'),
  (1,'T10','cheque','party_code',5,true,'code',NULL,'mig.t10.party_code'),
  (1,'T10','cheque','amount',6,true,'amount',NULL,'mig.t10.amount'),
  (1,'T10','cheque','due_date',7,true,'date',NULL,'mig.t10.due_date'),
  (1,'T10','cheque','status',8,true,'enum','{in_hand,in_collection,deposited,endorsed,bounced,guarantee,issued_unpaid}','mig.t10.status'),
  (1,'T10','cheque','deposit_bank_account',9,false,'code',NULL,'mig.t10.deposit_bank_account'),
  (1,'T10','cheque','currency',10,false,'code',NULL,'mig.t10.currency'),
  (1,'T10','cheque','fx_amount',11,false,'amount',NULL,'mig.t10.fx_amount'),
  (1,'T10','cheque','fx_rate',12,false,'rate',NULL,'mig.t10.fx_rate'),
  (1,'T10','cheque','description',13,false,'text',NULL,'mig.t10.description'),
  (1,'T11','bank_account','code',1,true,'code',NULL,'mig.t11.code'),
  (1,'T11','bank_account','type',2,true,'enum','{bank,cash_box,petty_cash,card_terminal}','mig.t11.type'),
  (1,'T11','bank_account','bank',3,false,'code',NULL,'mig.t11.bank'),
  (1,'T11','bank_account','account_no',4,false,'code',NULL,'mig.t11.account_no'),
  (1,'T11','bank_account','sheba',5,false,'code',NULL,'mig.t11.sheba'),
  (1,'T11','bank_account','gl_account',6,true,'code',NULL,'mig.t11.gl_account'),
  (1,'T11','bank_account','balance_at_cutover',7,true,'amount',NULL,'mig.t11.balance_at_cutover'),
  (1,'T11','bank_account','statement_balance',8,false,'amount',NULL,'mig.t11.statement_balance'),
  (1,'T11b','bank_unreconciled_item','bank_account',1,true,'code',NULL,'mig.t11b.bank_account'),
  (1,'T11b','bank_unreconciled_item','date',2,true,'date',NULL,'mig.t11b.date'),
  (1,'T11b','bank_unreconciled_item','amount',3,true,'amount',NULL,'mig.t11b.amount'),
  (1,'T11b','bank_unreconciled_item','ref',4,false,'text',NULL,'mig.t11b.ref'),
  (1,'T12','stock_opening','item_code',1,true,'code',NULL,'mig.t12.item_code'),
  (1,'T12','stock_opening','warehouse_code',2,true,'code',NULL,'mig.t12.warehouse_code'),
  (1,'T12','stock_opening','qty',3,true,'qty',NULL,'mig.t12.qty'),
  (1,'T12','stock_opening','uom',4,false,'code',NULL,'mig.t12.uom'),
  (1,'T12','stock_opening','unit_cost',5,false,'rate',NULL,'mig.t12.unit_cost'),
  (1,'T12','stock_opening','total_value',6,false,'amount',NULL,'mig.t12.total_value'),
  (1,'T12','stock_opening','layer_date',7,false,'date',NULL,'mig.t12.layer_date'),
  (1,'T12','stock_opening','batch_no',8,false,'code',NULL,'mig.t12.batch_no'),
  (1,'T12','stock_opening','expiry_date',9,false,'date',NULL,'mig.t12.expiry_date'),
  (1,'T12','stock_opening','serial_no',10,false,'code',NULL,'mig.t12.serial_no'),
  (1,'T12b','serial_history','item_code',1,true,'code',NULL,'mig.t12b.item_code'),
  (1,'T12b','serial_history','serial_no',2,true,'code',NULL,'mig.t12b.serial_no'),
  (1,'T12b','serial_history','sale_date',3,true,'date',NULL,'mig.t12b.sale_date'),
  (1,'T12b','serial_history','party_code',4,false,'code',NULL,'mig.t12b.party_code'),
  (1,'T12b','serial_history','legacy_invoice_no',5,false,'code',NULL,'mig.t12b.legacy_invoice_no'),
  (1,'T12b','serial_history','warranty_start',6,false,'date',NULL,'mig.t12b.warranty_start'),
  (1,'T12b','serial_history','warranty_end',7,false,'date',NULL,'mig.t12b.warranty_end'),
  (1,'T12b','serial_history','warranty_provider',8,false,'code',NULL,'mig.t12b.warranty_provider'),
  (1,'T13','fixed_asset','asset_code',1,true,'code',NULL,'mig.t13.asset_code'),
  (1,'T13','fixed_asset','name',2,true,'text',NULL,'mig.t13.name'),
  (1,'T13','fixed_asset','asset_class',3,true,'code',NULL,'mig.t13.asset_class'),
  (1,'T13','fixed_asset','acquisition_date',4,true,'date',NULL,'mig.t13.acquisition_date'),
  (1,'T13','fixed_asset','in_service_date',5,true,'date',NULL,'mig.t13.in_service_date'),
  (1,'T13','fixed_asset','cost',6,true,'amount',NULL,'mig.t13.cost'),
  (1,'T13','fixed_asset','accumulated_depreciation',7,true,'amount',NULL,'mig.t13.accumulated_depreciation'),
  (1,'T13','fixed_asset','dep_method',8,true,'enum','{straight_line,declining}','mig.t13.dep_method'),
  (1,'T13','fixed_asset','useful_life_or_rate',9,true,'decimal',NULL,'mig.t13.useful_life_or_rate'),
  (1,'T14','voucher_line','voucher_no',1,true,'code',NULL,'mig.t14.voucher_no'),
  (1,'T14','voucher_line','voucher_date',2,true,'date',NULL,'mig.t14.voucher_date'),
  (1,'T14','voucher_line','voucher_type',3,false,'enum','{regular,opening,closing}','mig.t14.voucher_type'),
  (1,'T14','voucher_line','line_no',4,false,'int',NULL,'mig.t14.line_no'),
  (1,'T14','voucher_line','account_code',5,true,'code',NULL,'mig.t14.account_code'),
  (1,'T14','voucher_line','dl1_code',6,false,'code',NULL,'mig.t14.dl1_code'),
  (1,'T14','voucher_line','description',7,false,'text',NULL,'mig.t14.description'),
  (1,'T14','voucher_line','debit',8,false,'amount',NULL,'mig.t14.debit'),
  (1,'T14','voucher_line','credit',9,false,'amount',NULL,'mig.t14.credit'),
  (1,'T14','voucher_line','source_kind',10,false,'enum','{manual,invoice,cheque,receipt_payment,expense_income,opening,closing}','mig.t14.source_kind'),
  (1,'T15','invoice_history','legacy_no',1,true,'code',NULL,'mig.t15.legacy_no'),
  (1,'T15','invoice_history','kind',2,true,'enum','{sale,purchase,sale_return,purchase_return}','mig.t15.kind'),
  (1,'T15','invoice_history','date',3,true,'date',NULL,'mig.t15.date'),
  (1,'T15','invoice_history','party_code',4,true,'code',NULL,'mig.t15.party_code'),
  (1,'T15','invoice_history','moadian_taxid',5,false,'code',NULL,'mig.t15.moadian_taxid'),
  (1,'T15','invoice_history','moadian_inno',6,false,'code',NULL,'mig.t15.moadian_inno'),
  (1,'T15','invoice_history','moadian_status',7,false,'enum','{not_sent,sent,accepted,rejected,cancelled}','mig.t15.moadian_status'),
  (1,'T15','invoice_history','inv_type',8,false,'enum','{1,2,3}','mig.t15.inv_type'),
  (1,'T15','invoice_history','inv_pattern',9,false,'enum','{1,2,3,4,5,6,7,8,9,11,13,14}','mig.t15.inv_pattern'),
  (1,'T15','invoice_history','inv_subject',10,false,'enum','{1,2,3,4}','mig.t15.inv_subject'),
  (1,'T15','invoice_history','ref_taxid',11,false,'code',NULL,'mig.t15.ref_taxid'),
  (1,'T15','invoice_history','settlement_method',12,false,'enum','{1,2,3}','mig.t15.settlement_method'),
  (1,'T15','invoice_history','buyer_type',13,false,'enum','{1,2,3,4}','mig.t15.buyer_type'),
  (1,'T15','invoice_history','buyer_national_id',14,false,'code',NULL,'mig.t15.buyer_national_id'),
  (1,'T15','invoice_history','buyer_economic_code',15,false,'code',NULL,'mig.t15.buyer_economic_code'),
  (1,'T15','invoice_history','buyer_postal_code',16,false,'code',NULL,'mig.t15.buyer_postal_code'),
  (1,'T15','invoice_history','buyer_branch_code',17,false,'code',NULL,'mig.t15.buyer_branch_code'),
  (1,'T15','invoice_history','seller_branch_code',18,false,'code',NULL,'mig.t15.seller_branch_code'),
  (1,'T15','invoice_history','total_before_discount',19,false,'amount',NULL,'mig.t15.total_before_discount'),
  (1,'T15','invoice_history','total_discount',20,false,'amount',NULL,'mig.t15.total_discount'),
  (1,'T15','invoice_history','total_vat',21,false,'amount',NULL,'mig.t15.total_vat'),
  (1,'T15','invoice_history','total_other_duties',22,false,'amount',NULL,'mig.t15.total_other_duties'),
  (1,'T15','invoice_history','total_other_levies',23,false,'amount',NULL,'mig.t15.total_other_levies'),
  (1,'T15','invoice_history','total_amount',24,false,'amount',NULL,'mig.t15.total_amount'),
  (1,'T15','invoice_history','cash_amount',25,false,'amount',NULL,'mig.t15.cash_amount'),
  (1,'T15','invoice_history','credit_amount',26,false,'amount',NULL,'mig.t15.credit_amount'),
  (1,'T15','invoice_history','currency',27,false,'code',NULL,'mig.t15.currency'),
  (1,'T15','invoice_history','fx_rate',28,false,'rate',NULL,'mig.t15.fx_rate'),
  (1,'T15b','invoice_line_history','legacy_no',1,true,'code',NULL,'mig.t15b.legacy_no'),
  (1,'T15b','invoice_line_history','line_no',2,true,'int',NULL,'mig.t15b.line_no'),
  (1,'T15b','invoice_line_history','item_code',3,true,'code',NULL,'mig.t15b.item_code'),
  (1,'T15b','invoice_line_history','moadian_product_id',4,false,'code',NULL,'mig.t15b.moadian_product_id'),
  (1,'T15b','invoice_line_history','item_description',5,false,'text',NULL,'mig.t15b.item_description'),
  (1,'T15b','invoice_line_history','moadian_unit',6,false,'code',NULL,'mig.t15b.moadian_unit'),
  (1,'T15b','invoice_line_history','qty',7,true,'qty',NULL,'mig.t15b.qty'),
  (1,'T15b','invoice_line_history','unit_price',8,true,'amount',NULL,'mig.t15b.unit_price'),
  (1,'T15b','invoice_line_history','discount',9,false,'amount',NULL,'mig.t15b.discount'),
  (1,'T15b','invoice_line_history','vat_rate',10,false,'decimal',NULL,'mig.t15b.vat_rate'),
  (1,'T15b','invoice_line_history','vat_amount',11,false,'amount',NULL,'mig.t15b.vat_amount'),
  (1,'T15b','invoice_line_history','other_duty_code',12,false,'code',NULL,'mig.t15b.other_duty_code'),
  (1,'T15b','invoice_line_history','other_duty_rate',13,false,'decimal',NULL,'mig.t15b.other_duty_rate'),
  (1,'T15b','invoice_line_history','other_duty_amount',14,false,'amount',NULL,'mig.t15b.other_duty_amount'),
  (1,'T15b','invoice_line_history','other_levy_code',15,false,'code',NULL,'mig.t15b.other_levy_code'),
  (1,'T15b','invoice_line_history','other_levy_rate',16,false,'decimal',NULL,'mig.t15b.other_levy_rate'),
  (1,'T15b','invoice_line_history','other_levy_amount',17,false,'amount',NULL,'mig.t15b.other_levy_amount'),
  (1,'T15b','invoice_line_history','line_total',18,false,'amount',NULL,'mig.t15b.line_total'),
  (1,'T16','employee','personnel_no',1,true,'code',NULL,'mig.t16.personnel_no'),
  (1,'T16','employee','national_code',2,true,'code',NULL,'mig.t16.national_code'),
  (1,'T16','employee','name',3,true,'text',NULL,'mig.t16.name'),
  (1,'T16','employee','hire_date',4,false,'date',NULL,'mig.t16.hire_date'),
  (1,'T16','employee','insurance_no',5,false,'code',NULL,'mig.t16.insurance_no'),
  (1,'T16','employee','employment_kind',6,false,'enum','{full_time,part_time,hourly}','mig.t16.employment_kind'),
  (1,'T16','employee','last_daily_wage_prev_year',7,false,'amount',NULL,'mig.t16.last_daily_wage_prev_year'),
  (1,'T16','employee','ytd_gross',8,false,'amount',NULL,'mig.t16.ytd_gross'),
  (1,'T16','employee','ytd_tax',9,false,'amount',NULL,'mig.t16.ytd_tax'),
  (1,'T16','employee','ytd_insurance',10,false,'amount',NULL,'mig.t16.ytd_insurance'),
  (1,'T16','employee','severance_accrued',11,false,'amount',NULL,'mig.t16.severance_accrued'),
  (1,'T16','employee','leave_balance_days',12,false,'decimal',NULL,'mig.t16.leave_balance_days'),
  (1,'T16','employee','qualifying_children',13,false,'int',NULL,'mig.t16.qualifying_children'),
  (1,'T17','tax_continuity','memory_id',1,true,'code',NULL,'mig.t17.memory_id'),
  (1,'T17','tax_continuity','last_inno',2,true,'code',NULL,'mig.t17.last_inno'),
  (1,'T17','tax_continuity','last_taxid',3,true,'code',NULL,'mig.t17.last_taxid'),
  (1,'T17','tax_continuity','connection_mode',4,true,'enum','{direct,trusted_company}','mig.t17.connection_mode')
ON CONFLICT DO NOTHING;

-- اجبار شرطی قالب v1 (RV-MG-20): فاکتوری که شمارهٔ مالیاتی دارد بی این ستون‌ها قابل بازسازی برای اصلاحی/برگشتی نیست؛
-- سند ارزی بی نرخ و مبلغ ارزی تطبیق‌پذیر نیست
UPDATE migration.template_column t SET required_if = x.cond
  FROM (VALUES ('T15','inv_type','T15.moadian_taxid'), ('T15','inv_pattern','T15.moadian_taxid'), ('T15','inv_subject','T15.moadian_taxid'),
               ('T15','settlement_method','T15.moadian_taxid'), ('T15','moadian_inno','T15.moadian_taxid'),
               ('T15b','moadian_product_id','T15.moadian_taxid'), ('T15b','moadian_unit','T15.moadian_taxid'),
               ('T15b','vat_amount','T15.moadian_taxid'), ('T15b','line_total','T15.moadian_taxid'),
               ('T09','fx_amount','T09.currency'), ('T09','fx_rate','T09.currency'),
               ('T10','fx_amount','T10.currency'), ('T10','fx_rate','T10.currency')) AS x(sheet, col, cond)
 WHERE t.template_version = 1 AND t.sheet_code = x.sheet AND t.column_key = x.col AND t.required_if IS DISTINCT FROM x.cond;

-- فرهنگ مترادف (نمونهٔ seed؛ نسخهٔ ۱). مترادف به شکل نرمال‌شده ذخیره می‌شود.
INSERT INTO migration.header_synonym (field_key, entity, source_system, synonym_norm, dict_version, origin)
SELECT s.field_key, NULL, NULL, migration.norm_header(s.syn), 1, 'seed'
  FROM (VALUES
    ('account_code','کد حساب'), ('account_code','کد سرفصل'), ('account_code','کدحساب'), ('account_code','account code'), ('account_code','gl code'),
    ('account_title','عنوان حساب'), ('account_title','نام حساب'), ('account_title','شرح حساب'), ('account_title','account name'),
    ('dl_code','کد تفصیلی'), ('dl_code','کد تفصیل'), ('dl_code','کد شناور'),
    ('debit','بدهکار'), ('debit','گردش بدهکار'), ('debit','مبلغ بدهکار'), ('debit','debit'), ('debit','dr'),
    ('credit','بستانکار'), ('credit','گردش بستانکار'), ('credit','مبلغ بستانکار'), ('credit','credit'), ('credit','cr'),
    ('balance','مانده'), ('balance','مانده حساب'), ('balance_side','ماهیت'), ('balance_side','تشخیص'), ('balance_side','بد/بس'),
    ('voucher_no','شماره سند'), ('voucher_no','ش سند'), ('date','تاریخ'), ('date','تاریخ سند'), ('description','شرح'), ('description','شرح سند'),
    ('description','بابت'), ('party_name','نام طرف حساب'), ('party_name','نام شخص'), ('first_name','نام'), ('last_name','نام خانوادگی'),
    ('national_code','کد ملی'), ('national_code','کدملی'), ('national_id','شناسه ملی'), ('economic_code','کد اقتصادی'),
    ('postal_code','کد پستی'), ('mobile','موبایل'), ('mobile','تلفن همراه'), ('phone','تلفن'), ('address','آدرس'), ('address','نشانی'),
    ('item_code','کد کالا'), ('item_code','کد محصول'), ('item_name','نام کالا'), ('item_name','شرح کالا'), ('barcode','بارکد'),
    ('moadian_product_id','شناسه کالا'), ('moadian_product_id','شناسه ۱۳ رقمی'), ('uom','واحد'), ('uom','واحد سنجش'),
    ('qty','مقدار'), ('qty','تعداد'), ('unit_cost','فی'), ('unit_cost','بهای واحد'), ('total_value','ارزش موجودی'),
    ('warehouse','انبار'), ('due_date','سررسید'), ('due_date','تاریخ سررسید'), ('cheque_no','شماره چک'), ('cheque_no','سریال چک'),
    ('sayad_id','شناسه صیاد'), ('sayad_id','شناسه صیادی'), ('bank','بانک'), ('bank','نام بانک'), ('sheba','شبا'), ('sheba','شماره شبا'),
    ('card_no','شماره کارت'), ('vat_rate','نرخ مالیات'), ('vat_rate','نرخ ارزش افزوده'),
    ('moadian_taxid','شماره منحصر به فرد مالیاتی'), ('moadian_taxid','شماره مالیاتی')
  ) AS s(field_key, syn)
ON CONFLICT DO NOTHING;

-- پایان 60_migration.sql
