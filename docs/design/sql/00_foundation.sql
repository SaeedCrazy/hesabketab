-- =====================================================================
-- حساب‌کتاب — 00_foundation.sql
-- پایهٔ مشترک پایگاه دادهٔ «داده» (data plane) — PostgreSQL 18
-- مالک: یکپارچه‌ساز (تصمیم‌ها: docs/design/change-requests.md، «قواعد یکپارچه‌سازی»).
-- همهٔ فایل‌های بعدی روی این فایل بنا می‌شوند. ترتیب اجرا: نام فایل (run_all.sh).
--
-- اجرا: بار اول با نقش ابرکاربر/bootstrap (ساخت نقش‌ها، افزونه‌ها و BYPASSRLS به آن نیاز دارد)؛
-- فایل‌های ماژول با hk_migrator. برنامه با hk_app وصل می‌شود که مالک هیچ شیئی نیست و
-- BYPASSRLS ندارد. این فایل idempotent است و اجرای دوباره‌اش (حتی پس از همهٔ فایل‌های بعدی)
-- هیچ چیز را سست نمی‌کند (run_all.sh گام idempotency).
--
-- نقش‌ها اینجا NOLOGIN و بدون رمز ساخته می‌شوند (R-ROLE). استقرار (hk migrate / hkctl) از
-- SecretStore با «ALTER ROLE … LOGIN PASSWORD» آن‌ها را فعال می‌کند. برای آزمون محلی فقط:
--   psql -v hk_dev_ok=1 -f docs/design/sql/dev_roles.sql
-- پایگاه داده باید این‌گونه ساخته شود (R-DB):
--   CREATE DATABASE <name> ENCODING 'UTF8' TEMPLATE template0 LC_COLLATE 'C' LC_CTYPE 'C.UTF-8';
-- =====================================================================

-- ---------- پیش‌شرط‌ها ----------
DO $$
BEGIN
  IF current_setting('server_encoding') <> 'UTF8' THEN
    RAISE EXCEPTION 'HK_ENCODING: data-plane database must be UTF8 (found %); create it with ENCODING ''UTF8'' TEMPLATE template0',
      current_setting('server_encoding');
  END IF;
  IF current_setting('server_version_num')::int < 180000 THEN
    RAISE EXCEPTION 'HK_PG_VERSION: PostgreSQL 18+ required (uuidv7)';
  END IF;
  -- همتای HK_PLT_WRONG_DATABASE در 70_platform.sql: پایگاه کنترل هرگز پایهٔ صفحهٔ داده نمی‌گیرد
  IF EXISTS (SELECT FROM pg_namespace WHERE nspname = 'platform') THEN
    RAISE EXCEPTION 'HK_WRONG_DATABASE: 00_foundation.sql must not be applied to the control-plane database';
  END IF;
END $$;

-- ---------- نقش‌ها (سطح کلاستر؛ idempotent و امن در اجرای هم‌زمان) ----------
-- R-ROLE: همهٔ نقش‌های صفحهٔ داده فقط این‌جا ساخته می‌شوند؛ هیچ‌کدام رمز ندارند.
--   hk_migrator          مالک اشیاء؛ BYPASSRLS؛ فقط migrate/hkctl/نگهداری (۰۱ D-06)
--   hk_app               زمان اجرا؛ نه مالک، نه BYPASSRLS
--   hk_readonly          گزارش/پشتیبانی فقط‌خواندنی؛ GRANT ستونی بدون ستون‌های راز (R-GRANT)
--   hk_reports           replica؛ عضو hk_readonly؛ statement_timeout بلند
--   hk_dispatcher        برداشتن job/outbox از همهٔ مستأجرها با policy مختص (۰۱ §۴-۳)
--   hk_audit_writer، hk_core_definer، hk_ledger_definer، hk_inventory_definer
--                        مالک توابع SECURITY DEFINER فهرست مجاز (۰۱ D-32)؛ NOLOGIN همیشه
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('hk_migrator',          true),
      ('hk_app',               false),
      ('hk_readonly',          false),
      ('hk_reports',           false),
      ('hk_dispatcher',        false),
      ('hk_audit_writer',      false),
      ('hk_core_definer',      false),
      ('hk_ledger_definer',    false),
      ('hk_inventory_definer', false)
    ) AS t(rolname, bypass)
  LOOP
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = r.rolname) THEN
      BEGIN
        EXECUTE format('CREATE ROLE %I NOLOGIN NOSUPERUSER %s NOCREATEDB NOCREATEROLE NOREPLICATION',
                       r.rolname, CASE WHEN r.bypass THEN 'BYPASSRLS' ELSE 'NOBYPASSRLS' END);
      EXCEPTION WHEN duplicate_object THEN NULL;   -- اجرای هم‌زمان روی همان کلاستر
      END;
    END IF;
    -- سخت‌سازی ویژگی‌های امنیتی (LOGIN و رمز مال ابزار استقرار است و دست نمی‌خورد)
    IF EXISTS (SELECT FROM pg_roles
                WHERE rolname = r.rolname
                  AND (rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls <> r.bypass)) THEN
      EXECUTE format('ALTER ROLE %I NOSUPERUSER %s NOCREATEDB NOCREATEROLE NOREPLICATION',
                     r.rolname, CASE WHEN r.bypass THEN 'BYPASSRLS' ELSE 'NOBYPASSRLS' END);
    END IF;
  END LOOP;

  -- نقش‌های مالک definer هرگز ورود ندارند
  FOR r IN SELECT rolname FROM pg_roles
            WHERE rolname IN ('hk_audit_writer','hk_core_definer','hk_ledger_definer','hk_inventory_definer')
              AND rolcanlogin
  LOOP
    EXECUTE format('ALTER ROLE %I NOLOGIN', r.rolname);
  END LOOP;

  -- مهلت‌ها (۰۱ C-02). روی نشستِ ورود اعمال می‌شوند، نه روی SET ROLE.
  -- jobهای طولانی (بستن سال، بازپخش موجودی، commit مهاجرت) با SET LOCAL statement_timeout خودشان را بالا می‌برند.
  FOR r IN
    SELECT * FROM (VALUES
      ('hk_app',     'statement_timeout',                   '30s'),
      ('hk_app',     'idle_in_transaction_session_timeout', '15s'),
      ('hk_reports', 'statement_timeout',                   '300s'),
      ('hk_reports', 'idle_in_transaction_session_timeout', '60s')
    ) AS t(rolname, guc, val)
  LOOP
    IF NOT EXISTS (SELECT FROM pg_db_role_setting s JOIN pg_roles ro ON ro.oid = s.setrole
                    WHERE ro.rolname = r.rolname AND s.setdatabase = 0
                      AND (r.guc || '=' || r.val) = ANY (s.setconfig)) THEN
      EXECUTE format('ALTER ROLE %I SET %I = %L', r.rolname, r.guc, r.val);
    END IF;
  END LOOP;

  -- hk_reports = hk_readonly + مهلت بلند (همان GRANTهای ستونی؛ هیچ GRANT جداگانه‌ای لازم نیست)
  IF NOT EXISTS (SELECT FROM pg_auth_members m
                   JOIN pg_roles g ON g.oid = m.roleid AND g.rolname = 'hk_readonly'
                   JOIN pg_roles u ON u.oid = m.member AND u.rolname = 'hk_reports') THEN
    GRANT hk_readonly TO hk_reports WITH INHERIT TRUE, SET FALSE;
  END IF;

  -- پاک‌سازی نهایی مستأجر و درون‌ریزی .hkx با session_replication_role=replica (R-IMPORT)
  IF NOT has_parameter_privilege('hk_migrator', 'session_replication_role', 'SET') THEN
    GRANT SET ON PARAMETER session_replication_role TO hk_migrator;
  END IF;
END $$;

-- ---------- افزونه‌ها (فقط این‌جا؛ R-EXT) ----------
-- در اسکیمای public می‌مانند: نام opclassها (gin_trgm_ops) و عملگرها (%) در فایل‌ها بی‌پیشوندند.
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;   -- EXCLUDE روی بازه‌ها (شماره، قیمت، BOM، ...)
CREATE EXTENSION IF NOT EXISTS pg_trgm    WITH SCHEMA public;   -- جست‌وجوی تقریبی نام و نامزد تکراری

-- ---------- اسکیماها: یک اسکیما برای هر ماژول ----------
CREATE SCHEMA IF NOT EXISTS ref;        -- دادهٔ مرجع بیرونی سراسری (ارز، واحد، بانک، ...) — بدون tenant_id، فقط‌خواندنی برای برنامه (R-REF)
CREATE SCHEMA IF NOT EXISTS core;       -- مستأجر، شرکت، شعبه، هویت، دسترسی، ممیزی، شماره‌گذاری، تنظیمات، outbox، job
CREATE SCHEMA IF NOT EXISTS ledger;     -- کدینگ، ابعاد، سند حسابداری، دوره، سال مالی، ارز و نرخ
CREATE SCHEMA IF NOT EXISTS parties;    -- اشخاص (مشتری، تأمین‌کننده، کارمند، ...)
CREATE SCHEMA IF NOT EXISTS catalog;    -- کالا و خدمت، واحد، variant، بارکد
CREATE SCHEMA IF NOT EXISTS inventory;  -- انبار، دفتر موجودی، ارزیابی
CREATE SCHEMA IF NOT EXISTS sales;
CREATE SCHEMA IF NOT EXISTS purchase;
CREATE SCHEMA IF NOT EXISTS treasury;   -- صندوق، بانک، چک، کارتخوان، تنخواه، مغایرت
CREATE SCHEMA IF NOT EXISTS pos;        -- صندوق فروشگاهی، شیفت، دستگاه، همگام‌سازی آفلاین
CREATE SCHEMA IF NOT EXISTS tax;        -- ارزش افزوده، مؤدیان، گزارش‌های قانونی
CREATE SCHEMA IF NOT EXISTS payroll;
CREATE SCHEMA IF NOT EXISTS assets;     -- دارایی ثابت
CREATE SCHEMA IF NOT EXISTS rules;      -- بستهٔ قواعد و پارامترهای قانونی نسخه‌دار (کپی محلی؛ مرجع در پنل مالک)
CREATE SCHEMA IF NOT EXISTS migration;  -- انتقال داده از نرم‌افزار قبلی
CREATE SCHEMA IF NOT EXISTS reports;
CREATE SCHEMA IF NOT EXISTS assistant;  -- دستیار هوشمند (L8؛ ۱۰ C-AS-16)

-- مالک اسکیماها hk_migrator است تا فایل‌های ماژول با همان نقش (بدون ابرکاربر) اجرا شوند.
DO $$
DECLARE s text;
BEGIN
  FOREACH s IN ARRAY ARRAY['ref','core','ledger','parties','catalog','inventory','sales','purchase','treasury',
                           'pos','tax','payroll','assets','rules','migration','reports','assistant'] LOOP
    IF (SELECT nspowner FROM pg_namespace WHERE nspname = s) <> (SELECT oid FROM pg_roles WHERE rolname = 'hk_migrator') THEN
      EXECUTE format('ALTER SCHEMA %I OWNER TO hk_migrator', s);
    END IF;
  END LOOP;
END $$;

-- ---------- نقشهٔ ماژول‌ها و DAG در پایگاه داده (INV-ARCH-09؛ R-XFK-5؛ RV-ARCH-08) ----------
-- هر اسکیمای صفحهٔ داده = یک ماژول. depends_on دقیقاً ستون «وابستگی مجاز» جدول ۰۱ §۵-۱ است (فهرست کامل، نه بستار
-- گذرا) به‌اضافهٔ تصمیم‌های پذیرفتهٔ یکپارچه‌سازی: catalog → parties (04:CR-01) و assistant در L8 با وابستگی به
-- L0 تا L7 (10:C-AS-05). ماژول‌های بی‌اسکیما (kernel، contracts، integrations، edge) و platform (پایگاه جدا) این‌جا
-- نیستند. ModuleSpec.depends_on (پایتون) باید با همین برابر باشد (01 INV-ARCH-07)؛ هر تغییر DAG هر دو را با هم عوض می‌کند.
CREATE OR REPLACE FUNCTION core.module_registry()
RETURNS TABLE (module text, layer smallint, depends_on text[])
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT m.module, m.layer::smallint, m.depends_on FROM (VALUES
    ('ref',       0, '{}'::text[]),
    ('core',      0, '{ref}'),
    ('rules',     1, '{core,ref}'),
    ('parties',   2, '{core,ref,rules}'),
    ('catalog',   2, '{core,ref,rules,parties}'),                                        -- 04:CR-01
    ('ledger',    3, '{core,ref,rules,parties}'),
    ('inventory', 4, '{core,ref,rules,parties,catalog,ledger}'),
    ('treasury',  4, '{core,ref,rules,parties,ledger}'),
    ('tax',       4, '{core,ref,rules,parties,catalog,ledger}'),
    ('assets',    4, '{core,ref,rules,parties,ledger}'),
    ('sales',     5, '{core,ref,rules,parties,catalog,ledger,inventory,treasury,tax}'),     -- L0..L4 جز assets
    ('purchase',  5, '{core,ref,rules,parties,catalog,ledger,inventory,treasury,tax}'),     -- L0..L4 جز assets
    ('payroll',   5, '{core,ref,rules,parties,ledger,treasury}'),
    ('pos',       6, '{core,ref,rules,parties,catalog,inventory,treasury,tax,sales}'),      -- بدون ledger (06 INV-POS-14)
    ('reports',   7, '{core,ref,rules,parties,catalog,ledger,inventory,treasury,tax,assets,sales,purchase,payroll,pos}'),
    ('migration', 7, '{core,ref,rules,parties,catalog,ledger,inventory,treasury,tax,assets,sales,purchase,payroll,pos}'),
    ('assistant', 8, '{core,ref,rules,parties,catalog,ledger,inventory,treasury,tax,assets,sales,purchase,payroll,pos,reports,migration}')  -- 10:C-AS-05
  ) AS m(module, layer, depends_on)
$$;

-- هر FK بین‌اسکیمایی که جفت (ماژول مبدأ، ماژول مقصد) آن در depends_on نیست — هم‌لایه، چرخه، رو به بالا، یا رو به
-- پایینِ اعلام‌نشده — و برچسب «HK_DAG_EXCEPTION: <دلیل>» (COMMENT ON CONSTRAINT) ندارد. اسکیمای ثبت‌نشده (ماژول
-- تازه بدون ADR و ردیف بالا) هم خطاست. قیدهای فرزند پارتیشن (conparentid ≠ 0) برچسب والد را دارند و شمرده نمی‌شوند.
-- خودآزمایی پایانی 99_cross_fk.sql (HK_XFK_DAG) و آزمون یکپارچه (A2.cross_schema_fks_follow_dag) همین را صدا می‌زنند.
CREATE OR REPLACE FUNCTION core.xfk_dag_violations()
RETURNS TABLE (from_table regclass, conname name, to_table regclass, from_module text, to_module text, problem text)
LANGUAGE sql STABLE AS $$
  SELECT c.conrelid::regclass, c.conname, c.confrelid::regclass, sn.nspname::text, dn.nspname::text,
         CASE WHEN ms.module IS NULL THEN 'unregistered_schema:' || sn.nspname
              WHEN md.module IS NULL THEN 'unregistered_schema:' || dn.nspname
              WHEN sn.nspname::text = ANY (md.depends_on) OR ms.layer < md.layer THEN 'against_dag'
              ELSE 'not_in_depends_on' END
    FROM pg_catalog.pg_constraint c
    JOIN pg_catalog.pg_class s     ON s.oid = c.conrelid
    JOIN pg_catalog.pg_namespace sn ON sn.oid = s.relnamespace
    JOIN pg_catalog.pg_class d     ON d.oid = c.confrelid
    JOIN pg_catalog.pg_namespace dn ON dn.oid = d.relnamespace
    LEFT JOIN core.module_registry() ms ON ms.module = sn.nspname::text
    LEFT JOIN core.module_registry() md ON md.module = dn.nspname::text
   WHERE c.contype = 'f' AND c.conparentid = 0
     AND sn.nspname <> dn.nspname
     AND NOT (ms.module IS NOT NULL AND md.module IS NOT NULL AND dn.nspname::text = ANY (ms.depends_on))
     AND coalesce(pg_catalog.obj_description(c.oid, 'pg_constraint'), '') NOT LIKE 'HK_DAG_EXCEPTION:%'
$$;
-- فقط برای migrate، lint و آزمون؛ نقش‌های زمان اجرا به آن نیازی ندارند
REVOKE EXECUTE ON FUNCTION core.module_registry(), core.xfk_dag_violations() FROM PUBLIC;

-- ---------- انواع دامنه (هرگز float برای پول/مقدار) ----------
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname='core' AND t.typname='amount') THEN
    -- مبلغ: ریال فعلی صحیح است؛ ۴ رقم اعشار برای ارزهای خارجی، ریال جدید (قِران) و محاسبات میانی
    CREATE DOMAIN core.amount AS numeric(24,4);
  END IF;
  IF NOT EXISTS (SELECT FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname='core' AND t.typname='qty') THEN
    CREATE DOMAIN core.qty AS numeric(24,6);
  END IF;
  IF NOT EXISTS (SELECT FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname='core' AND t.typname='rate') THEN
    CREATE DOMAIN core.rate AS numeric(28,12);
  END IF;
  IF NOT EXISTS (SELECT FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname='core' AND t.typname='amount_unit') THEN
    -- واحد صریح هر مبلغ ورودی (ورود داده، مهاجرت، API عمومی)
    CREATE TYPE core.amount_unit AS ENUM ('IRR', 'IRT', 'IRR_NEW');
  END IF;
END $$;

-- ---------- زمینهٔ مستأجر ----------
-- برنامه در ابتدای هر تراکنش:  SELECT set_config('app.tenant_id', $1, true);
-- (true = فقط همین تراکنش؛ سازگار با PgBouncer در حالت transaction)
-- R-TX: یک تراکنش = یک مستأجر؛ تنظیم دوبارهٔ app.tenant_id با مقدار دیگر در همان تراکنش خطاست (UnitOfWork).
CREATE OR REPLACE FUNCTION core.current_tenant_id() RETURNS uuid
LANGUAGE sql STABLE PARALLEL SAFE AS
$$ SELECT NULLIF(current_setting('app.tenant_id', true), '')::uuid $$;

-- کاربر جاری (برای ممیزی و created_by)؛ همان الگو
CREATE OR REPLACE FUNCTION core.current_user_id() RETURNS uuid
LANGUAGE sql STABLE PARALLEL SAFE AS
$$ SELECT NULLIF(current_setting('app.user_id', true), '')::uuid $$;

-- فعال‌سازی RLS استاندارد روی هر جدول مستأجری. هر جدول دارای tenant_id باید این را صدا بزند.
CREATE OR REPLACE FUNCTION core.enable_tenant_rls(tbl regclass) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', tbl);
  EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', tbl);
  EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %s', tbl);
  EXECUTE format(
    'CREATE POLICY tenant_isolation ON %s AS PERMISSIVE FOR ALL '
    'USING (tenant_id = core.current_tenant_id()) '
    'WITH CHECK (tenant_id = core.current_tenant_id())', tbl);
END $$;

-- تریگر عمومی: جلوگیری از UPDATE/DELETE روی جدول‌های فقط‌افزودنی (دفتر کل، ممیزی، ...)
-- در تریگر سطح دستور هم کار می‌کند (TG_OP = 'TRUNCATE').
CREATE OR REPLACE FUNCTION core.forbid_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'HK_IMMUTABLE: % on %.% is not allowed', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME
    USING ERRCODE = 'P0001';
END $$;

-- کمک‌تابع: جدول فقط‌افزودنی کامل = UPDATE/DELETE سطری + TRUNCATE سطح دستور ممنوع (R-APPEND).
-- پاک‌سازی نهایی مستأجر و درون‌ریزی .hkx با session_replication_role=replica (فقط hk_migrator) از آن می‌گذرند؛
-- پس هیچ بخشی نباید روی جدول فقط‌افزودنی تریگر ENABLE ALWAYS بگذارد.
CREATE OR REPLACE FUNCTION core.make_append_only(tbl regclass) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('DROP TRIGGER IF EXISTS trg_immutable ON %s', tbl);
  EXECUTE format('CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation()', tbl);
  EXECUTE format('DROP TRIGGER IF EXISTS trg_no_truncate ON %s', tbl);
  EXECUTE format('CREATE TRIGGER trg_no_truncate BEFORE TRUNCATE ON %s FOR EACH STATEMENT EXECUTE FUNCTION core.forbid_mutation()', tbl);
END $$;

-- تریگر عمومی updated_at و row_version (هم‌روندی خوش‌بینانه)
CREATE OR REPLACE FUNCTION core.touch_row() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  NEW.row_version := OLD.row_version + 1;
  RETURN NEW;
END $$;

-- کمک‌تابع‌های DDL برای نقش‌های زمان اجرا لازم نیستند
REVOKE EXECUTE ON FUNCTION core.enable_tenant_rls(regclass), core.make_append_only(regclass) FROM PUBLIC;

-- ---------- دادهٔ مرجع سراسری ----------
-- R-REF: ref.currency مال پایه است؛ هر جدول ref دیگر مال بخشی است که آن را ساخته (فهرست در change-requests.md).
CREATE TABLE IF NOT EXISTS ref.currency (
  code        char(3) PRIMARY KEY,               -- ISO 4217
  name_fa     text    NOT NULL,
  name_en     text    NOT NULL,
  minor_unit  smallint NOT NULL CHECK (minor_unit BETWEEN 0 AND 4),  -- IRR = 0
  symbol      text,
  is_active   boolean NOT NULL DEFAULT true
);
INSERT INTO ref.currency(code, name_fa, name_en, minor_unit, symbol) VALUES
  ('IRR','ریال','Iranian Rial',0,'﷼'),
  ('USD','دلار آمریکا','US Dollar',2,'$'),
  ('EUR','یورو','Euro',2,'€'),
  ('AED','درهم امارات','UAE Dirham',2,'د.إ'),
  ('CNY','یوان چین','Chinese Yuan',2,'¥'),
  ('TRY','لیر ترکیه','Turkish Lira',2,'₺'),
  ('IQD','دینار عراق','Iraqi Dinar',3,'ع.د')
ON CONFLICT (code) DO NOTHING;
-- ریال جدید (C-L10): ردیف پس از قطعی شدن کد ISO 4217 با migration داده افزوده می‌شود؛ ضریب فقط در
-- پارامتر قواعد currency.redenomination.factor است، هرگز این‌جا.

-- ---------- مستأجر، شرکت، شعبه ----------
-- core.tenant: رکورد محلی مستأجر در پایگاه دادهٔ داده. رجیستری اصلی مستأجرها در پایگاه دادهٔ
-- «کنترل» پنل مالک است (platform.*) که جداست. در On-prem فقط یک ردیف دارد.
-- معنای این سه جدول (policyهای افزوده، رجیستری صدور، قیدهای کمکی) مال بخش هسته (۰۲) است.
CREATE TABLE IF NOT EXISTS core.tenant (
  id           uuid PRIMARY KEY DEFAULT uuidv7(),
  slug         text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
  display_name text NOT NULL,
  status       text NOT NULL DEFAULT 'active'
               CHECK (status IN ('provisioning','active','read_only','suspended','exporting','archived')),
  deployment   text NOT NULL DEFAULT 'saas_shared'
               CHECK (deployment IN ('saas_shared','saas_dedicated','onprem')),
  locale       text NOT NULL DEFAULT 'fa-IR',
  timezone     text NOT NULL DEFAULT 'Asia/Tehran',
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  row_version  integer NOT NULL DEFAULT 1
);
ALTER TABLE core.tenant ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.tenant FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_self ON core.tenant;
CREATE POLICY tenant_self ON core.tenant USING (id = core.current_tenant_id()) WITH CHECK (id = core.current_tenant_id());

-- شرکت = شخصیت حقوقی/دفاتر جدا. یک مستأجر می‌تواند چند شرکت داشته باشد.
-- base_currency: نگهبان تغییر پس از وجود سال مالی مال ledger است (C-L09؛ جهت DAG).
CREATE TABLE IF NOT EXISTS core.company (
  tenant_id      uuid NOT NULL REFERENCES core.tenant(id),
  id             uuid NOT NULL DEFAULT uuidv7(),
  code           text NOT NULL,
  name           text NOT NULL,
  legal_name     text,
  entity_type    text NOT NULL DEFAULT 'legal' CHECK (entity_type IN ('legal','natural')),  -- حقوقی / حقیقی (مشاغل)
  national_id    text,          -- شناسهٔ ملی ۱۱ رقمی (حقوقی) یا کد ملی ۱۰ رقمی (حقیقی)
  economic_code  text,          -- کد اقتصادی ۱۱/۱۴ رقمی
  base_currency  char(3) NOT NULL DEFAULT 'IRR' REFERENCES ref.currency(code),
  is_active      boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  row_version    integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code)
);
SELECT core.enable_tenant_rls('core.company');

CREATE TABLE IF NOT EXISTS core.branch (
  tenant_id    uuid NOT NULL,
  id           uuid NOT NULL DEFAULT uuidv7(),
  company_id   uuid NOT NULL,
  code         text NOT NULL,
  name         text NOT NULL,
  is_active    boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  row_version  integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, code),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id)
);
SELECT core.enable_tenant_rls('core.branch');
-- FK سه‌ستونی «شعبهٔ همان شرکت» (۰۲ §۱۳ بند ۳؛ همان نام قیدی که 10_core.sql بررسی می‌کند)
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_constraint
                  WHERE conname = 'branch_tenant_company_id_key' AND conrelid = 'core.branch'::regclass) THEN
    ALTER TABLE core.branch ADD CONSTRAINT branch_tenant_company_id_key UNIQUE (tenant_id, company_id, id);
  END IF;
END $$;

DROP TRIGGER IF EXISTS trg_touch ON core.tenant;
CREATE TRIGGER trg_touch BEFORE UPDATE ON core.tenant  FOR EACH ROW EXECUTE FUNCTION core.touch_row();
DROP TRIGGER IF EXISTS trg_touch ON core.company;
CREATE TRIGGER trg_touch BEFORE UPDATE ON core.company FOR EACH ROW EXECUTE FUNCTION core.touch_row();
DROP TRIGGER IF EXISTS trg_touch ON core.branch;
CREATE TRIGGER trg_touch BEFORE UPDATE ON core.branch  FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- مالکیت اشیاء پایه: hk_migrator (۰۱ D-06)
DO $$
DECLARE o record;
BEGIN
  FOR o IN SELECT c.oid::regclass AS rel FROM pg_class c
            WHERE c.oid IN ('ref.currency'::regclass, 'core.tenant'::regclass, 'core.company'::regclass, 'core.branch'::regclass)
              AND c.relowner <> (SELECT oid FROM pg_roles WHERE rolname = 'hk_migrator') LOOP
    EXECUTE format('ALTER TABLE %s OWNER TO hk_migrator', o.rel);
  END LOOP;
  FOR o IN SELECT p.oid::regprocedure AS fn FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'core'
              AND p.proname IN ('current_tenant_id','current_user_id','enable_tenant_rls','forbid_mutation','make_append_only','touch_row',
                                'module_registry','xfk_dag_violations')
              AND p.proowner <> (SELECT oid FROM pg_roles WHERE rolname = 'hk_migrator') LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO hk_migrator', o.fn);
  END LOOP;
  FOR o IN SELECT t.oid::regtype AS typ FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
            WHERE n.nspname = 'core' AND t.typname IN ('amount','qty','rate','amount_unit')
              AND t.typowner <> (SELECT oid FROM pg_roles WHERE rolname = 'hk_migrator') LOOP
    EXECUTE format('ALTER TYPE %s OWNER TO hk_migrator', o.typ);
  END LOOP;
END $$;

-- ---------- دسترسی نقش‌های زمان اجرا ----------
-- R-GRANT: هر فایل پس از ساخت جدول‌هایش GRANT صریح می‌دهد. هیچ پیش‌فرض نوشتنی وجود ندارد.
-- hk_readonly فقط SELECT صریح، و روی جدول دارای ستون راز فقط GRANT ستونی (بدون ستون‌های راز).
GRANT USAGE ON SCHEMA ref, core, ledger, parties, catalog, inventory, sales, purchase, treasury, pos, tax,
                      payroll, assets, rules, migration, reports, assistant TO hk_app, hk_readonly;
GRANT USAGE ON SCHEMA core TO hk_dispatcher, hk_audit_writer, hk_core_definer;

-- ref: SELECT برای همه؛ نوشتن فقط hk_migrator (migration داده یا بستهٔ امضاشده؛ ۰۱ C-05)
GRANT SELECT ON ALL TABLES IN SCHEMA ref TO hk_app, hk_readonly;
ALTER DEFAULT PRIVILEGES FOR ROLE hk_migrator IN SCHEMA ref GRANT SELECT ON TABLES TO hk_app, hk_readonly;
DO $$
BEGIN
  -- همان پیش‌فرض برای نقشی که فایل‌ها را اجرا می‌کند (در توسعه postgres؛ در تولید خود hk_migrator)
  IF current_user <> 'hk_migrator' THEN
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA ref GRANT SELECT ON TABLES TO hk_app, hk_readonly';
  END IF;
END $$;

-- core.tenant: وضعیت، slug و نوع استقرار را فقط پنل مالک (از راه فرمان و hk_migrator) تغییر می‌دهد (۰۲ §۱۳ بند ۹)
GRANT SELECT, INSERT ON core.tenant TO hk_app;
REVOKE UPDATE ON core.tenant FROM hk_app;
GRANT UPDATE (display_name, locale, timezone) ON core.tenant TO hk_app;
GRANT SELECT, INSERT, UPDATE ON core.company, core.branch TO hk_app;
GRANT SELECT ON core.tenant, core.company, core.branch TO hk_readonly;
