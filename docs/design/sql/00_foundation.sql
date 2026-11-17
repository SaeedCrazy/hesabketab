-- =====================================================================
-- حساب‌کتاب — 00_foundation.sql
-- پایهٔ مشترک پایگاه دادهٔ «داده» (data plane) — PostgreSQL 18
-- همهٔ فایل‌های بعدی روی این فایل بنا می‌شوند. ترتیب اجرا: نام فایل.
-- اجرا با نقش مهاجرت (migrator/superuser). برنامه با نقش hk_app وصل می‌شود
-- که مالک جدول‌ها نیست و BYPASSRLS ندارد.
-- =====================================================================

-- ---------- نقش‌ها (سطح کلاستر، idempotent) ----------
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hk_app') THEN
    CREATE ROLE hk_app LOGIN PASSWORD 'hk_app' NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hk_readonly') THEN
    CREATE ROLE hk_readonly LOGIN PASSWORD 'hk_readonly' NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
  END IF;
END $$;

-- ---------- اسکیماها: یک اسکیما برای هر ماژول ----------
CREATE SCHEMA IF NOT EXISTS ref;        -- دادهٔ مرجع سراسری (ارز، واحد، بانک، ...) — بدون tenant_id، فقط‌خواندنی برای برنامه
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
CREATE OR REPLACE FUNCTION core.forbid_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'HK_IMMUTABLE: % on %.% is not allowed', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME
    USING ERRCODE = 'P0001';
END $$;

-- تریگر عمومی updated_at و row_version (هم‌روندی خوش‌بینانه)
CREATE OR REPLACE FUNCTION core.touch_row() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  NEW.row_version := OLD.row_version + 1;
  RETURN NEW;
END $$;

-- ---------- دادهٔ مرجع سراسری ----------
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

-- ---------- مستأجر، شرکت، شعبه ----------
-- core.tenant: رکورد محلی مستأجر در پایگاه دادهٔ داده. رجیستری اصلی مستأجرها در پایگاه دادهٔ
-- «کنترل» پنل مالک است (platform.*) که جداست. در On-prem فقط یک ردیف دارد.
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

DROP TRIGGER IF EXISTS trg_touch ON core.tenant;
CREATE TRIGGER trg_touch BEFORE UPDATE ON core.tenant  FOR EACH ROW EXECUTE FUNCTION core.touch_row();
DROP TRIGGER IF EXISTS trg_touch ON core.company;
CREATE TRIGGER trg_touch BEFORE UPDATE ON core.company FOR EACH ROW EXECUTE FUNCTION core.touch_row();
DROP TRIGGER IF EXISTS trg_touch ON core.branch;
CREATE TRIGGER trg_touch BEFORE UPDATE ON core.branch  FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- ---------- دسترسی نقش برنامه ----------
-- هر فایل بعدی پس از ساخت جدول‌هایش همین الگو را تکرار می‌کند (یا در انتها GRANT ... ON ALL TABLES).
GRANT USAGE ON SCHEMA ref, core, ledger, parties, catalog, inventory, sales, purchase, treasury, pos, tax, payroll, assets, rules, migration, reports TO hk_app, hk_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA ref TO hk_app, hk_readonly;
GRANT SELECT, INSERT, UPDATE ON core.tenant, core.company, core.branch TO hk_app;
GRANT SELECT ON core.tenant, core.company, core.branch TO hk_readonly;
