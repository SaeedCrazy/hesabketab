-- =====================================================================
-- حساب‌کتاب — 20_ledger.sql   (سند طراحی: docs/design/03-ledger.md)
-- هستهٔ حسابداری: کدینگ، ابعاد (تفصیلی شناور)، سال و دورهٔ مالی، سند حسابداری،
-- دفتر کل فقط‌افزودنی، شماره‌گذاری دائم ترتیبی، ارز و نرخ، نگاشت حساب (posting profile)،
-- بستن سال، تراز و صورت‌های مالی، و توابع راستی‌آزمایی.
--
-- پیش‌نیاز: 00_foundation.sql. (به 10_core.sql وابسته نیست؛ اگر آن فایل پیش از این اجرا شده باشد
-- ثبت در کاتالوگ‌های core به‌صورت شرطی انجام می‌شود.)
-- اجرا با نقش migrator/superuser. برنامه با hk_app (نه مالک، NOBYPASSRLS) وصل می‌شود.
-- پیشوند پیام خطاها: HK_LEDGER_* (SQLSTATE P0001) — نگاشت به کد API در سند §۵-۱۲.
-- =====================================================================

-- EXCLUDE روی بازهٔ تاریخ سال/دوره و قاعدهٔ نگاشت
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- نقش مالک توابع SECURITY DEFINER این ماژول (D-32): NOLOGIN, NOBYPASSRLS
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hk_ledger_definer') THEN
    CREATE ROLE hk_ledger_definer NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
  END IF;
END $$;
GRANT USAGE ON SCHEMA ledger, core TO hk_ledger_definer;

-- قید کمکی روی core.branch (هم‌نام و هم‌تعریف با 10_core.sql تا هر دو ترتیب اجرا سازگار باشد)
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_constraint WHERE conname = 'branch_tenant_company_id_key') THEN
    ALTER TABLE core.branch ADD CONSTRAINT branch_tenant_company_id_key UNIQUE (tenant_id, company_id, id);
  END IF;
END $$;

-- ---------- کمکی‌ها ----------
CREATE OR REPLACE FUNCTION ledger.raise_error(p_code text, p_message text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '%: %', p_code, p_message USING ERRCODE = 'P0001';
END $$;

-- تریگرهای deferred در commit با زمینهٔ مستأجرِ همان لحظه اجرا می‌شوند؛ تعویض مستأجر وسط تراکنش ممنوع است
CREATE OR REPLACE FUNCTION ledger.assert_tenant_context(p_tenant uuid) RETURNS void
LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF p_tenant IS DISTINCT FROM core.current_tenant_id() THEN
    RAISE EXCEPTION 'HK_LEDGER_TENANT_CONTEXT: tenant context changed inside the transaction' USING ERRCODE = 'P0001';
  END IF;
END $$;

-- گرد کردن با حالت مشخص (همتای Python: Decimal.quantize)
CREATE OR REPLACE FUNCTION ledger.round_amount(p_value numeric, p_minor smallint, p_mode text DEFAULT 'half_up')
RETURNS numeric LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE f numeric := power(10::numeric, p_minor); x numeric;
BEGIN
  IF p_mode = 'truncate' THEN RETURN trunc(p_value, p_minor); END IF;
  IF p_mode = 'half_up' THEN RETURN round(p_value, p_minor); END IF;  -- numeric round = half away from zero
  IF p_mode = 'half_even' THEN
    x := p_value * f;
    IF abs(x - trunc(x)) = 0.5 THEN
      RETURN (CASE WHEN mod(trunc(x), 2) = 0 THEN trunc(x) ELSE trunc(x) + sign(x) END) / f;
    END IF;
    RETURN round(p_value, p_minor);
  END IF;
  RAISE EXCEPTION 'HK_LEDGER_ROUNDING_MODE: unknown rounding mode %', p_mode USING ERRCODE = 'P0001';
END $$;

-- =====================================================================
-- ۱. کاتالوگ‌های سراسری (بدون tenant_id؛ hk_app فقط SELECT؛ با migration/انتشار پر می‌شوند)
-- =====================================================================
CREATE TABLE IF NOT EXISTS ledger.journal_type (
  code                          text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  entry_class                   text NOT NULL CHECK (entry_class IN ('opening','regular','closing')),
  class_rank                    smallint NOT NULL,
  origin                        text NOT NULL CHECK (origin IN ('manual','module','system','mirror','import')),
  skip_line_rules               boolean NOT NULL DEFAULT false,  -- سطرها کپی سطرهای معتبرند (آینه) یا بستن سال
  bypass_posting_policy         boolean NOT NULL DEFAULT false,  -- مجاز به ثبت در حساب کنترلی بدون زیردفتر
  allows_base_only_lines        boolean NOT NULL DEFAULT false,  -- سطر «فقط ارز پایه» (تسعیر، بستن)
  requires_input_unit           boolean NOT NULL DEFAULT false,  -- واحد مبلغ ورودی (IRR/IRT/IRR_NEW) اجباری
  excluded_from_subledger_check boolean NOT NULL DEFAULT false,  -- در تطبیق GL و زیردفتر کنار گذاشته می‌شود (تسعیر)
  name_fa                       text NOT NULL,
  introduced_in                 text NOT NULL,
  CHECK ((entry_class, class_rank) IN (('opening',0::smallint),('regular',1::smallint),('closing',2::smallint)))
);

CREATE TABLE IF NOT EXISTS ledger.posting_key (
  key                     text PRIMARY KEY CHECK (key ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){1,4}$'),
  owner_module            text NOT NULL,
  expected_account_types  text[] NOT NULL DEFAULT '{}'
                          CHECK (expected_account_types <@ ARRAY['asset','liability','equity','income','expense','memo']::text[]),
  is_required             boolean NOT NULL DEFAULT false,
  name_fa                 text NOT NULL,
  introduced_in           text NOT NULL,
  CHECK (split_part(key, '.', 1) = owner_module)
);

CREATE TABLE IF NOT EXISTS ledger.dimension_type_catalog (
  code             text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  slot             smallint NOT NULL CHECK (slot BETWEEN 1 AND 6),
  owner_module     text NOT NULL,
  is_hierarchical  boolean NOT NULL DEFAULT false,
  name_fa          text NOT NULL,
  introduced_in    text NOT NULL
);

CREATE TABLE IF NOT EXISTS ledger.coa_template (
  code             text NOT NULL CHECK (code ~ '^[a-z][a-z0-9_.-]{1,60}$'),
  version          integer NOT NULL CHECK (version >= 1),
  industry_pack    text NOT NULL DEFAULT 'general',
  extends_code     text,
  extends_version  integer,
  name_fa          text NOT NULL,
  status           text NOT NULL DEFAULT 'published' CHECK (status IN ('draft','published','retired')),
  code_mode        text NOT NULL DEFAULT 'hierarchical' CHECK (code_mode IN ('hierarchical','free')),
  levels           jsonb NOT NULL CHECK (jsonb_typeof(levels) = 'array' AND jsonb_array_length(levels) BETWEEN 1 AND 9),
  source           text,
  confidence       text NOT NULL DEFAULT 'low' CHECK (confidence IN ('high','medium','low')),
  reviewed_by      text,
  PRIMARY KEY (code, version),
  FOREIGN KEY (extends_code, extends_version) REFERENCES ledger.coa_template(code, version),
  CHECK ((extends_code IS NULL) = (extends_version IS NULL))
);

CREATE TABLE IF NOT EXISTS ledger.coa_template_account (
  template_code           text NOT NULL,
  template_version        integer NOT NULL,
  code                    text NOT NULL CHECK (code ~ '^[0-9A-Za-z._-]{1,40}$'),
  parent_code             text,
  level                   smallint NOT NULL CHECK (level BETWEEN 1 AND 9),
  name_fa                 text NOT NULL,
  name_en                 text,
  kind                    text NOT NULL CHECK (kind IN ('group','posting')),
  account_type            text NOT NULL CHECK (account_type IN ('asset','liability','equity','income','expense','memo')),
  nature                  text NOT NULL DEFAULT 'none' CHECK (nature IN ('debit','credit','none')),
  role                    text,
  tags                    text[] NOT NULL DEFAULT '{}',
  posting_policy          text NOT NULL DEFAULT 'open' CHECK (posting_policy IN ('open','subledger_only','system_only')),
  allowed_source_modules  text[] NOT NULL DEFAULT '{}',
  subledger_kind          text,
  currency_policy         text NOT NULL DEFAULT 'base_only' CHECK (currency_policy IN ('base_only','any','fixed')),
  revalue_fx              boolean NOT NULL DEFAULT false,
  branch_rule             text NOT NULL DEFAULT 'optional' CHECK (branch_rule IN ('required','optional','forbidden')),
  dimension_rules         jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(dimension_rules) = 'object'),
  PRIMARY KEY (template_code, template_version, code),
  FOREIGN KEY (template_code, template_version) REFERENCES ledger.coa_template(code, version),
  CHECK ((level = 1) = (parent_code IS NULL))
);

CREATE TABLE IF NOT EXISTS ledger.coa_template_posting_rule (
  template_code     text NOT NULL,
  template_version  integer NOT NULL,
  posting_key       text NOT NULL REFERENCES ledger.posting_key(key),
  priority          integer NOT NULL DEFAULT 100,
  conditions        jsonb NOT NULL DEFAULT '{}',
  account_code      text NOT NULL,
  PRIMARY KEY (template_code, template_version, posting_key, priority, account_code),
  FOREIGN KEY (template_code, template_version) REFERENCES ledger.coa_template(code, version)
);

-- قرارداد زیردفتر: هر ماژول مالک زیردفتر تابع ماندهٔ خود را ثبت می‌کند:
--   <schema>.<fn>(p_company_id uuid, p_as_of date)
--   RETURNS TABLE (account_id uuid, dim_value_id uuid, currency char(3), balance_base numeric, balance_txn numeric)
CREATE TABLE IF NOT EXISTS ledger.subledger_source (
  subledger_kind    text PRIMARY KEY CHECK (subledger_kind ~ '^[a-z][a-z0-9_]{1,40}$'),
  owner_module      text NOT NULL,
  balance_function  text NOT NULL CHECK (balance_function ~ '^[a-z_][a-z0-9_]{0,62}\.[a-z_][a-z0-9_]{0,62}$'),
  dim_slot          smallint CHECK (dim_slot BETWEEN 1 AND 6),   -- NULL = مقایسه در سطح حساب
  compare_txn       boolean NOT NULL DEFAULT true,
  introduced_in     text NOT NULL
);

CREATE TABLE IF NOT EXISTS ledger.report_template (
  code          text NOT NULL CHECK (code ~ '^[a-z][a-z0-9_.-]{1,60}$'),
  version       integer NOT NULL CHECK (version >= 1),
  kind          text NOT NULL CHECK (kind IN ('balance_sheet','profit_loss','cash_flow','equity_changes','custom')),
  name_fa       text NOT NULL,
  standard_ref  text,
  confidence    text NOT NULL DEFAULT 'low' CHECK (confidence IN ('high','medium','low')),
  status        text NOT NULL DEFAULT 'published' CHECK (status IN ('draft','published','retired')),
  PRIMARY KEY (code, version)
);

CREATE TABLE IF NOT EXISTS ledger.report_template_row (
  template_code     text NOT NULL,
  template_version  integer NOT NULL,
  row_code          text NOT NULL CHECK (row_code ~ '^[A-Z][A-Z0-9_]{0,30}$'),
  sort_order        integer NOT NULL,
  indent            smallint NOT NULL DEFAULT 0 CHECK (indent BETWEEN 0 AND 6),
  label_fa          text NOT NULL,
  row_type          text NOT NULL CHECK (row_type IN ('heading','accounts','formula','pl_result')),
  selector          jsonb,
  balance_basis     text CHECK (balance_basis IN ('closing','opening','period_net','change')),
  sign              smallint NOT NULL DEFAULT 1 CHECK (sign IN (1,-1)),
  formula           text CHECK (formula ~ '^[+-]?\s*[A-Z][A-Z0-9_]*(\s*[+-]\s*[A-Z][A-Z0-9_]*)*$'),
  is_check_row      boolean NOT NULL DEFAULT false,      -- مقدار باید صفر باشد (کنترل جریان وجوه نقد)
  PRIMARY KEY (template_code, template_version, row_code),
  UNIQUE (template_code, template_version, sort_order),
  FOREIGN KEY (template_code, template_version) REFERENCES ledger.report_template(code, version),
  CHECK ((row_type = 'accounts') = (selector IS NOT NULL)),
  CHECK (selector IS NULL OR jsonb_typeof(selector) = 'object'),
  CHECK ((row_type = 'formula') = (formula IS NOT NULL)),
  CHECK ((row_type IN ('accounts','pl_result')) = (balance_basis IS NOT NULL))
);

-- =====================================================================
-- ۲. پیکربندی شرکت و سطوح کدینگ
-- =====================================================================
CREATE TABLE IF NOT EXISTS ledger.rate_type (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  code                 text NOT NULL CHECK (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  name                 text NOT NULL,
  is_default           boolean NOT NULL DEFAULT false,
  max_staleness_days   smallint NOT NULL DEFAULT 7 CHECK (max_staleness_days BETWEEN 0 AND 366),
  is_active            boolean NOT NULL DEFAULT true,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, code)
);
SELECT core.enable_tenant_rls('ledger.rate_type');
CREATE UNIQUE INDEX IF NOT EXISTS rate_type_one_default ON ledger.rate_type (tenant_id) WHERE is_default;

CREATE TABLE IF NOT EXISTS ledger.company_config (
  tenant_id                       uuid NOT NULL REFERENCES core.tenant(id),
  id                              uuid NOT NULL DEFAULT uuidv7(),
  company_id                      uuid NOT NULL,
  code_mode                       text NOT NULL DEFAULT 'hierarchical' CHECK (code_mode IN ('hierarchical','free')),
  legal_book_level                smallint NOT NULL DEFAULT 2 CHECK (legal_book_level BETWEEN 1 AND 9),
  eledger_kol_level               smallint NOT NULL DEFAULT 2 CHECK (eledger_kol_level BETWEEN 1 AND 9),
  eledger_moein_level             smallint NOT NULL DEFAULT 3 CHECK (eledger_moein_level BETWEEN 1 AND 9),
  eledger_detail_source           text NOT NULL DEFAULT 'dim_slot:1' CHECK (eledger_detail_source ~ '^(none|level:[1-9]|dim_slot:[1-6])$'),
  default_rate_type_id            uuid,
  fx_rounding_mode                text NOT NULL DEFAULT 'half_up' CHECK (fx_rounding_mode IN ('half_up','half_even','truncate')),
  require_review_before_finalize  boolean NOT NULL DEFAULT false,
  coa_template_code               text,
  coa_template_version            integer,
  created_at                      timestamptz NOT NULL DEFAULT now(),
  updated_at                      timestamptz NOT NULL DEFAULT now(),
  row_version                     integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, default_rate_type_id) REFERENCES ledger.rate_type(tenant_id, id),
  CHECK (eledger_moein_level > eledger_kol_level)
);
SELECT core.enable_tenant_rls('ledger.company_config');

CREATE TABLE IF NOT EXISTS ledger.coa_level (
  tenant_id       uuid NOT NULL REFERENCES core.tenant(id),
  id              uuid NOT NULL DEFAULT uuidv7(),
  company_id      uuid NOT NULL,
  level_no        smallint NOT NULL CHECK (level_no BETWEEN 1 AND 9),
  name_fa         text NOT NULL,          -- گروه، کل، معین، ...
  segment_length  smallint CHECK (segment_length BETWEEN 1 AND 12),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  row_version     integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, level_no),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id)
);
SELECT core.enable_tenant_rls('ledger.coa_level');

-- =====================================================================
-- ۳. ابعاد (تفصیلی شناور)
-- =====================================================================
CREATE TABLE IF NOT EXISTS ledger.dimension_type (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  code             text NOT NULL CHECK (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  name             text NOT NULL,
  slot             smallint NOT NULL CHECK (slot BETWEEN 1 AND 6),
  kind             text NOT NULL DEFAULT 'user' CHECK (kind IN ('system','user')),
  owner_module     text NOT NULL DEFAULT 'ledger',
  is_hierarchical  boolean NOT NULL DEFAULT false,
  is_active        boolean NOT NULL DEFAULT true,
  sort_order       integer NOT NULL DEFAULT 0,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  row_version      integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, id, slot),
  UNIQUE (tenant_id, code),
  CHECK (kind = 'system' OR owner_module = 'ledger')
);
SELECT core.enable_tenant_rls('ledger.dimension_type');

CREATE TABLE IF NOT EXISTS ledger.dimension_value (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL DEFAULT uuidv7(),
  dimension_type_id  uuid NOT NULL,
  slot               smallint NOT NULL CHECK (slot BETWEEN 1 AND 6),   -- = نوع؛ با FK ترکیبی تضمین می‌شود
  code               text NOT NULL CHECK (code ~ '^[0-9A-Za-z._/-]{1,40}$'),
  name               text NOT NULL,
  name_search        text,                -- نرمال‌شده با fa-norm (سرویس core)
  parent_id          uuid,
  company_id         uuid,                -- NULL = مشترک بین شرکت‌های مستأجر
  is_group           boolean NOT NULL DEFAULT false,
  is_active          boolean NOT NULL DEFAULT true,
  source_module      text NOT NULL DEFAULT 'ledger',
  source_entity_id   uuid,                -- شناسهٔ موجودیت مالک (شخص، حساب بانکی، صندوق، ...)
  party_id           uuid GENERATED ALWAYS AS (CASE WHEN source_module = 'parties' THEN source_entity_id END) STORED,
  legacy_code        text,
  merged_into_id     uuid,                -- ادغام (مثلاً دو شخص تکراری): سطرهای قدیم دفتر تغییر نمی‌کنند، گزارش به مقصد نسبت می‌دهد
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  row_version        integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, dimension_type_id, code),
  FOREIGN KEY (tenant_id, dimension_type_id, slot) REFERENCES ledger.dimension_type(tenant_id, id, slot),
  FOREIGN KEY (tenant_id, parent_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, merged_into_id) REFERENCES ledger.dimension_value(tenant_id, id),
  CHECK ((source_module = 'ledger') = (source_entity_id IS NULL)),
  CHECK (parent_id IS NULL OR parent_id <> id),
  CHECK (merged_into_id IS NULL OR (merged_into_id <> id AND NOT is_active))
);
SELECT core.enable_tenant_rls('ledger.dimension_value');
CREATE UNIQUE INDEX IF NOT EXISTS dimension_value_source_uq ON ledger.dimension_value (tenant_id, dimension_type_id, source_entity_id)
  WHERE source_entity_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS dimension_value_search_idx ON ledger.dimension_value (tenant_id, dimension_type_id, name_search);

-- =====================================================================
-- ۴. کدینگ حساب‌ها
-- =====================================================================
CREATE TABLE IF NOT EXISTS ledger.account (
  tenant_id               uuid NOT NULL REFERENCES core.tenant(id),
  id                      uuid NOT NULL DEFAULT uuidv7(),
  company_id              uuid NOT NULL,
  parent_id               uuid,
  level                   smallint NOT NULL CHECK (level BETWEEN 1 AND 9),
  code                    text NOT NULL CHECK (code ~ '^[0-9A-Za-z._-]{1,40}$'),
  name                    text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 200),
  name_en                 text,
  name_search             text,
  kind                    text NOT NULL CHECK (kind IN ('group','posting')),
  account_type            text NOT NULL CHECK (account_type IN ('asset','liability','equity','income','expense','memo')),
  nature                  text NOT NULL DEFAULT 'none' CHECK (nature IN ('debit','credit','none')),
  role                    text CHECK (role ~ '^[A-Z][A-Z0-9_]{1,40}$'),
  tags                    text[] NOT NULL DEFAULT '{}',
  posting_policy          text NOT NULL DEFAULT 'open' CHECK (posting_policy IN ('open','subledger_only','system_only')),
  allowed_source_modules  text[] NOT NULL DEFAULT '{}',
  subledger_kind          text CHECK (subledger_kind ~ '^[a-z][a-z0-9_]{1,40}$'),
  currency_policy         text NOT NULL DEFAULT 'base_only' CHECK (currency_policy IN ('base_only','any','fixed')),
  fixed_currency          char(3) REFERENCES ref.currency(code),
  revalue_fx              boolean NOT NULL DEFAULT false,
  branch_rule             text NOT NULL DEFAULT 'optional' CHECK (branch_rule IN ('required','optional','forbidden')),
  is_active               boolean NOT NULL DEFAULT true,
  legacy_code             text,
  legacy_path             text,
  legacy_system           text,
  description             text,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  row_version             integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, company_id, code),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, parent_id) REFERENCES ledger.account(tenant_id, company_id, id),
  CHECK ((level = 1) = (parent_id IS NULL)),
  CHECK ((currency_policy = 'fixed') = (fixed_currency IS NOT NULL)),
  CHECK (posting_policy <> 'subledger_only' OR cardinality(allowed_source_modules) > 0),
  CHECK (NOT revalue_fx OR currency_policy <> 'base_only'),
  CHECK (account_type <> 'memo' OR NOT revalue_fx)
);
SELECT core.enable_tenant_rls('ledger.account');
CREATE INDEX IF NOT EXISTS account_parent_idx ON ledger.account (tenant_id, parent_id);
CREATE INDEX IF NOT EXISTS account_role_idx ON ledger.account (tenant_id, company_id, role) WHERE role IS NOT NULL;
CREATE INDEX IF NOT EXISTS account_legacy_idx ON ledger.account (tenant_id, company_id, legacy_code) WHERE legacy_code IS NOT NULL;

CREATE TABLE IF NOT EXISTS ledger.account_dimension_rule (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL DEFAULT uuidv7(),
  account_id         uuid NOT NULL,
  dimension_type_id  uuid NOT NULL,
  requirement        text NOT NULL CHECK (requirement IN ('required','optional','forbidden')),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  row_version        integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, account_id, dimension_type_id),
  FOREIGN KEY (tenant_id, account_id) REFERENCES ledger.account(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, dimension_type_id) REFERENCES ledger.dimension_type(tenant_id, id)
);
SELECT core.enable_tenant_rls('ledger.account_dimension_rule');

-- =====================================================================
-- ۵. سال مالی، دوره، تاریخچهٔ وضعیت، قفل ماژولی
-- =====================================================================
CREATE TABLE IF NOT EXISTS ledger.fiscal_year (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL DEFAULT uuidv7(),
  company_id         uuid NOT NULL,
  code               text NOT NULL CHECK (code ~ '^[0-9A-Za-z._-]{1,20}$'),
  name               text NOT NULL,
  start_date         date NOT NULL,
  end_date           date NOT NULL,
  status             text NOT NULL DEFAULT 'open' CHECK (status IN ('open','closing','closed','locked')),
  base_currency      char(3) NOT NULL REFERENCES ref.currency(code),
  previous_year_id   uuid,
  opening_state      text NOT NULL DEFAULT 'pending' CHECK (opening_state IN ('pending','posted','not_required')),
  finalized_through  date,                 -- سندهای تا این تاریخ دائم‌اند؛ ثبت با تاریخ ≤ آن ممنوع
  last_permanent_no  integer NOT NULL DEFAULT 0 CHECK (last_permanent_no >= 0),
  chain_head_hash    bytea,
  status_reason      text,
  closed_at          timestamptz,
  closed_by          uuid,
  locked_at          timestamptz,
  locked_by          uuid,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  row_version        integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, company_id, code),
  UNIQUE (tenant_id, previous_year_id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, previous_year_id) REFERENCES ledger.fiscal_year(tenant_id, company_id, id),
  CHECK (end_date >= start_date AND end_date - start_date <= 550),
  CHECK (finalized_through IS NULL OR finalized_through BETWEEN start_date AND end_date),
  CHECK ((last_permanent_no = 0) = (chain_head_hash IS NULL)),
  EXCLUDE USING gist (tenant_id WITH =, company_id WITH =, daterange(start_date, end_date, '[]') WITH &&)
);
SELECT core.enable_tenant_rls('ledger.fiscal_year');
CREATE UNIQUE INDEX IF NOT EXISTS fiscal_year_one_first ON ledger.fiscal_year (tenant_id, company_id) WHERE previous_year_id IS NULL;

CREATE TABLE IF NOT EXISTS ledger.fiscal_period (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  company_id           uuid NOT NULL,
  fiscal_year_id       uuid NOT NULL,
  period_no            smallint NOT NULL CHECK (period_no BETWEEN 1 AND 24),
  name                 text NOT NULL,
  start_date           date NOT NULL,
  end_date             date NOT NULL,
  status               text NOT NULL DEFAULT 'open' CHECK (status IN ('open','soft_closed','closed','locked')),
  status_reason        text,
  status_approval_ref  uuid,                -- core.approval_request (FK در 99_cross_fk)
  status_changed_at    timestamptz,
  status_changed_by    uuid,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  row_version          integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, fiscal_year_id, id),
  UNIQUE (tenant_id, fiscal_year_id, period_no),
  FOREIGN KEY (tenant_id, company_id, fiscal_year_id) REFERENCES ledger.fiscal_year(tenant_id, company_id, id),
  CHECK (end_date >= start_date),
  EXCLUDE USING gist (tenant_id WITH =, company_id WITH =, daterange(start_date, end_date, '[]') WITH &&)
);
SELECT core.enable_tenant_rls('ledger.fiscal_period');
CREATE INDEX IF NOT EXISTS fiscal_period_date_idx ON ledger.fiscal_period (tenant_id, company_id, start_date, end_date);

CREATE TABLE IF NOT EXISTS ledger.period_status_event (
  tenant_id            uuid NOT NULL REFERENCES core.tenant(id),
  id                   uuid NOT NULL DEFAULT uuidv7(),
  period_id            uuid NOT NULL,
  from_status          text NOT NULL,
  to_status            text NOT NULL,
  reason               text,
  approval_ref         uuid,
  actor_user_id        uuid,
  occurred_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, period_id) REFERENCES ledger.fiscal_period(tenant_id, id)
);
SELECT core.enable_tenant_rls('ledger.period_status_event');
CREATE INDEX IF NOT EXISTS period_status_event_idx ON ledger.period_status_event (tenant_id, period_id, occurred_at);

CREATE TABLE IF NOT EXISTS ledger.period_module_lock (
  tenant_id    uuid NOT NULL REFERENCES core.tenant(id),
  id           uuid NOT NULL DEFAULT uuidv7(),
  period_id    uuid NOT NULL,
  module       text NOT NULL CHECK (module ~ '^[a-z][a-z0-9_]{1,30}$'),
  reason       text,
  locked_by    uuid,
  locked_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, period_id, module),
  FOREIGN KEY (tenant_id, period_id) REFERENCES ledger.fiscal_period(tenant_id, id)
);
SELECT core.enable_tenant_rls('ledger.period_module_lock');

-- =====================================================================
-- ۶. نرخ ارز
-- =====================================================================
CREATE TABLE IF NOT EXISTS ledger.exchange_rate (
  tenant_id      uuid NOT NULL REFERENCES core.tenant(id),
  id             uuid NOT NULL DEFAULT uuidv7(),
  rate_type_id   uuid NOT NULL,
  currency       char(3) NOT NULL REFERENCES ref.currency(code),
  base_currency  char(3) NOT NULL REFERENCES ref.currency(code),
  rate_date      date NOT NULL,
  rate           core.rate NOT NULL CHECK (rate > 0),   -- 1 واحد currency = rate واحد base_currency
  source         text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','import','feed')),
  entered_by     uuid,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  row_version    integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, rate_type_id, currency, base_currency, rate_date),
  FOREIGN KEY (tenant_id, rate_type_id) REFERENCES ledger.rate_type(tenant_id, id),
  CHECK (currency <> base_currency)
);
SELECT core.enable_tenant_rls('ledger.exchange_rate');

-- =====================================================================
-- ۷. نگاشت حساب (posting profile)
-- =====================================================================
CREATE OR REPLACE FUNCTION ledger.valid_conditions(p jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT jsonb_typeof(p) = 'object'
     AND NOT EXISTS (
       SELECT 1 FROM jsonb_each(p) e
        WHERE e.key !~ '^(branch|currency|dim:[a-z][a-z0-9_]{1,40}|attr:[a-z][a-z0-9_.]{1,60})$'
           OR NOT (jsonb_typeof(e.value) = 'string'
                   OR (jsonb_typeof(e.value) = 'array' AND jsonb_array_length(e.value) BETWEEN 1 AND 200
                       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(e.value) x WHERE jsonb_typeof(x) <> 'string'))))
$$;

CREATE TABLE IF NOT EXISTS ledger.posting_rule (
  tenant_id           uuid NOT NULL REFERENCES core.tenant(id),
  id                  uuid NOT NULL DEFAULT uuidv7(),
  company_id          uuid NOT NULL,
  posting_key         text NOT NULL REFERENCES ledger.posting_key(key),
  priority            integer NOT NULL DEFAULT 100 CHECK (priority BETWEEN 0 AND 10000),
  conditions          jsonb NOT NULL DEFAULT '{}' CHECK (ledger.valid_conditions(conditions)),
  account_id          uuid NOT NULL,
  dimension_defaults  jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(dimension_defaults) = 'object'),
  valid_from          date NOT NULL DEFAULT '1900-01-01',
  valid_to            date NOT NULL DEFAULT '9999-12-31',
  is_active           boolean NOT NULL DEFAULT true,
  note                text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  row_version         integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, account_id) REFERENCES ledger.account(tenant_id, company_id, id),
  CHECK (valid_to >= valid_from),
  EXCLUDE USING gist (tenant_id WITH =, company_id WITH =, posting_key WITH =, priority WITH =,
                      md5(conditions::text) WITH =, daterange(valid_from, valid_to, '[]') WITH &&) WHERE (is_active)
);
SELECT core.enable_tenant_rls('ledger.posting_rule');
CREATE INDEX IF NOT EXISTS posting_rule_lookup_idx ON ledger.posting_rule (tenant_id, company_id, posting_key) WHERE is_active;

-- =====================================================================
-- ۸. پیش‌نویس سند (فضای کاری قابل‌ویرایش؛ هنوز در دفتر کل نیست)
-- =====================================================================
CREATE TABLE IF NOT EXISTS ledger.journal_draft (
  tenant_id             uuid NOT NULL REFERENCES core.tenant(id),
  id                    uuid NOT NULL DEFAULT uuidv7(),   -- پس از ارسال، شناسهٔ همان سند در ledger.journal
  company_id            uuid NOT NULL,
  branch_id             uuid,
  journal_date          date NOT NULL,
  journal_type          text NOT NULL DEFAULT 'manual' REFERENCES ledger.journal_type(code),
  description           text NOT NULL DEFAULT '',
  status                text NOT NULL DEFAULT 'editing' CHECK (status IN ('editing','pending_approval','approved')),
  approval_request_id   uuid,
  recurring_journal_id  uuid,
  recurring_occurrence  date,
  input_amount_unit     core.amount_unit,
  legacy_ref            text,
  -- منشأ پیش‌نویس؛ سرویس از principal تعیین می‌کند و کلاینت نمی‌تواند آن را بفرستد.
  -- 'assistant' = پیشنهاد دستیار هوشمند (Q-F): فقط کاربر انسانی می‌تواند آن را ارسال (submit) کند.
  created_via           text NOT NULL DEFAULT 'user'
                        CHECK (created_via IN ('user','api','recurring','copy','import','assistant')),
  created_by            uuid,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  row_version           integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  CHECK ((recurring_journal_id IS NULL) = (recurring_occurrence IS NULL)),
  CHECK (created_via <> 'recurring' OR recurring_journal_id IS NOT NULL)
);
SELECT core.enable_tenant_rls('ledger.journal_draft');
CREATE UNIQUE INDEX IF NOT EXISTS journal_draft_recurring_uq ON ledger.journal_draft (tenant_id, recurring_journal_id, recurring_occurrence)
  WHERE recurring_journal_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS ledger.journal_draft_line (
  tenant_id      uuid NOT NULL REFERENCES core.tenant(id),
  id             uuid NOT NULL DEFAULT uuidv7(),
  draft_id       uuid NOT NULL,
  line_no        integer NOT NULL CHECK (line_no >= 1),
  company_id     uuid NOT NULL,
  account_id     uuid,                  -- پیش‌نویس می‌تواند ناقص باشد
  branch_id      uuid,
  dim1_id uuid, dim2_id uuid, dim3_id uuid, dim4_id uuid, dim5_id uuid, dim6_id uuid,
  currency       char(3) REFERENCES ref.currency(code),
  exchange_rate  core.rate CHECK (exchange_rate > 0),
  rate_type_id   uuid,
  debit_txn      core.amount NOT NULL DEFAULT 0 CHECK (debit_txn >= 0),
  credit_txn     core.amount NOT NULL DEFAULT 0 CHECK (credit_txn >= 0),
  debit_base     core.amount CHECK (debit_base >= 0),
  credit_base    core.amount CHECK (credit_base >= 0),
  quantity       core.qty,
  description    text,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, draft_id, line_no),
  FOREIGN KEY (tenant_id, draft_id) REFERENCES ledger.journal_draft(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, company_id, account_id) REFERENCES ledger.account(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, dim1_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, dim2_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, dim3_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, dim4_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, dim5_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, dim6_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, rate_type_id) REFERENCES ledger.rate_type(tenant_id, id),
  CHECK (NOT (debit_txn > 0 AND credit_txn > 0))
);
SELECT core.enable_tenant_rls('ledger.journal_draft_line');

-- =====================================================================
-- ۹. سند حسابداری و سطرهای دفتر کل (تنها منبع حقیقت گزارش‌های مالی)
-- =====================================================================
CREATE TABLE IF NOT EXISTS ledger.journal (
  tenant_id               uuid NOT NULL REFERENCES core.tenant(id),
  id                      uuid NOT NULL DEFAULT uuidv7(),
  company_id              uuid NOT NULL,
  fiscal_year_id          uuid NOT NULL,
  period_id               uuid NOT NULL,
  branch_id               uuid,                        -- شعبهٔ اصلی سند (دامنهٔ دسترسی)
  journal_date            date NOT NULL,
  journal_type            text NOT NULL REFERENCES ledger.journal_type(code),
  entry_class             text NOT NULL CHECK (entry_class IN ('opening','regular','closing')),
  class_rank              smallint NOT NULL,
  status                  text NOT NULL CHECK (status IN ('temporary','permanent','voided')),
  reference_no            bigint NOT NULL CHECK (reference_no >= 1),   -- شمارهٔ عطف (core numbering، بی‌فاصله در سال)
  reference_text          text NOT NULL CHECK (char_length(reference_text) BETWEEN 1 AND 100),
  number_issued_id        uuid,                        -- core.number_issued (FK در 99_cross_fk)
  permanent_no            integer CHECK (permanent_no >= 1),            -- شمارهٔ سند دائم: ۱..n بی‌فاصله و به ترتیب تاریخ
  daily_no                integer CHECK (daily_no >= 1),                -- شمارهٔ روزانه
  description             text NOT NULL DEFAULT '',
  source_module           text NOT NULL CHECK (source_module ~ '^[a-z][a-z0-9_]{1,30}$'),
  source_doc_type         text CHECK (source_doc_type ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  source_doc_id           uuid,
  source_doc_no           text,
  source_event            text NOT NULL DEFAULT 'post' CHECK (source_event ~ '^[a-z0-9][a-z0-9_:.-]{0,60}$'),
  request_hash            bytea,
  base_currency           char(3) NOT NULL REFERENCES ref.currency(code),
  line_count              integer NOT NULL CHECK (line_count BETWEEN 2 AND 1000000),
  total_debit_base        core.amount NOT NULL,
  total_credit_base       core.amount NOT NULL,
  memo_debit_base         core.amount NOT NULL DEFAULT 0,
  memo_credit_base        core.amount NOT NULL DEFAULT 0,
  input_amount_unit       core.amount_unit,
  soft_close_override     boolean NOT NULL DEFAULT false,
  reversal_of_journal_id  uuid,
  void_of_journal_id      uuid,
  adjusts_journal_id      uuid,
  recurring_journal_id    uuid,
  approval_request_id     uuid,                        -- core.approval_request (FK در 99_cross_fk)
  legacy_ref              text,
  legacy_permanent_no     integer,
  void_reason             text,
  posted_by               uuid,
  posted_at               timestamptz NOT NULL DEFAULT now(),
  reviewed_by             uuid,
  reviewed_at             timestamptz,
  finalized_by            uuid,
  finalized_at            timestamptz,
  chain_prev_hash         bytea,
  chain_hash              bytea,
  updated_at              timestamptz NOT NULL DEFAULT now(),
  row_version             integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, id),
  UNIQUE (tenant_id, company_id, fiscal_year_id, reference_no),
  UNIQUE (tenant_id, company_id, fiscal_year_id, permanent_no),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, fiscal_year_id) REFERENCES ledger.fiscal_year(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, fiscal_year_id, period_id) REFERENCES ledger.fiscal_period(tenant_id, fiscal_year_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, reversal_of_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, void_of_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, adjusts_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  CHECK (total_debit_base = total_credit_base AND total_debit_base > 0),
  CHECK (memo_debit_base = memo_credit_base AND memo_debit_base >= 0 AND memo_debit_base <= total_debit_base),
  CHECK ((entry_class, class_rank) IN (('opening',0::smallint),('regular',1::smallint),('closing',2::smallint))),
  CHECK ((status = 'permanent') = (permanent_no IS NOT NULL)),
  CHECK ((status = 'permanent') = (chain_hash IS NOT NULL AND chain_prev_hash IS NOT NULL AND finalized_at IS NOT NULL AND daily_no IS NOT NULL)),
  CHECK ((journal_type = 'void') = (void_of_journal_id IS NOT NULL)),
  CHECK ((journal_type IN ('reversal','fx_revaluation_reversal')) = (reversal_of_journal_id IS NOT NULL)),
  CHECK (void_of_journal_id IS NULL OR status = 'voided'),
  CHECK (status <> 'voided' OR void_reason IS NOT NULL OR void_of_journal_id IS NOT NULL),
  CHECK ((source_doc_type IS NULL) = (source_doc_id IS NULL))
);
SELECT core.enable_tenant_rls('ledger.journal');
-- idempotency بر اساس مرجع مبدأ (سند ابطال‌شده جای خود را آزاد می‌کند)
CREATE UNIQUE INDEX IF NOT EXISTS journal_source_uq ON ledger.journal
  (tenant_id, company_id, source_module, source_doc_type, source_doc_id, source_event)
  WHERE source_doc_id IS NOT NULL AND status <> 'voided';
-- هر سند حداکثر یک برگشت فعال
CREATE UNIQUE INDEX IF NOT EXISTS journal_one_reversal_uq ON ledger.journal (tenant_id, reversal_of_journal_id)
  WHERE reversal_of_journal_id IS NOT NULL AND status <> 'voided';
CREATE UNIQUE INDEX IF NOT EXISTS journal_one_void_uq ON ledger.journal (tenant_id, void_of_journal_id)
  WHERE void_of_journal_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS journal_date_idx ON ledger.journal (tenant_id, company_id, journal_date);
CREATE INDEX IF NOT EXISTS journal_temporary_idx ON ledger.journal (tenant_id, company_id, fiscal_year_id, journal_date, class_rank)
  WHERE status = 'temporary';
CREATE INDEX IF NOT EXISTS journal_source_idx ON ledger.journal (tenant_id, source_doc_id) WHERE source_doc_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS ledger.journal_line (
  tenant_id        uuid NOT NULL REFERENCES core.tenant(id),
  id               uuid NOT NULL DEFAULT uuidv7(),
  journal_id       uuid NOT NULL,
  line_no          integer NOT NULL CHECK (line_no >= 1),
  -- رونوشت از سرسند (تریگر پر می‌کند)
  company_id       uuid NOT NULL,
  fiscal_year_id   uuid NOT NULL,
  period_id        uuid NOT NULL,
  journal_date     date NOT NULL,
  entry_class      text NOT NULL CHECK (entry_class IN ('opening','regular','closing')),
  is_memo          boolean NOT NULL DEFAULT false,
  -- حساب و ابعاد
  account_id       uuid NOT NULL,
  branch_id        uuid,
  dim1_id uuid, dim2_id uuid, dim3_id uuid, dim4_id uuid, dim5_id uuid, dim6_id uuid,
  -- مبلغ‌ها: ارز معامله و ارز پایه
  currency         char(3) NOT NULL REFERENCES ref.currency(code),
  exchange_rate    core.rate NOT NULL CHECK (exchange_rate > 0),
  rate_type_id     uuid,
  debit_txn        core.amount NOT NULL DEFAULT 0 CHECK (debit_txn >= 0),
  credit_txn       core.amount NOT NULL DEFAULT 0 CHECK (credit_txn >= 0),
  debit_base       core.amount NOT NULL DEFAULT 0 CHECK (debit_base >= 0),
  credit_base      core.amount NOT NULL DEFAULT 0 CHECK (credit_base >= 0),
  line_kind        text NOT NULL DEFAULT 'normal' CHECK (line_kind IN ('normal','rounding','base_adjustment')),
  quantity         core.qty,
  description      text,
  posting_key      text,
  posting_rule_id  uuid,
  source_line_ref  text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, journal_id, line_no),
  FOREIGN KEY (tenant_id, company_id, journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, account_id) REFERENCES ledger.account(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, dim1_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, dim2_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, dim3_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, dim4_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, dim5_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, dim6_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, rate_type_id) REFERENCES ledger.rate_type(tenant_id, id),
  FOREIGN KEY (tenant_id, posting_rule_id) REFERENCES ledger.posting_rule(tenant_id, id),
  -- هر سطر فقط یک طرف دارد و طرف ارز معامله و ارز پایه یکی است
  CHECK (NOT (debit_base > 0 AND credit_base > 0)),
  CHECK (NOT (debit_txn > 0 AND credit_txn > 0)),
  CHECK (NOT (debit_base > 0 AND credit_txn > 0) AND NOT (credit_base > 0 AND debit_txn > 0)),
  CHECK (debit_base + credit_base + debit_txn + credit_txn > 0),
  CHECK (line_kind <> 'base_adjustment' OR (debit_txn = 0 AND credit_txn = 0)),
  CHECK (quantity IS NULL OR quantity >= 0)
);
SELECT core.enable_tenant_rls('ledger.journal_line');
CREATE INDEX IF NOT EXISTS journal_line_account_idx ON ledger.journal_line
  (tenant_id, company_id, account_id, journal_date, journal_id, line_no)
  INCLUDE (debit_base, credit_base, debit_txn, credit_txn, currency, entry_class);
CREATE INDEX IF NOT EXISTS journal_line_period_idx ON ledger.journal_line (tenant_id, company_id, period_id, account_id);
CREATE INDEX IF NOT EXISTS journal_line_dim1_idx ON ledger.journal_line (tenant_id, dim1_id, journal_date) WHERE dim1_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS journal_line_dim2_idx ON ledger.journal_line (tenant_id, dim2_id, journal_date) WHERE dim2_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS journal_line_dim3_idx ON ledger.journal_line (tenant_id, dim3_id, journal_date) WHERE dim3_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS journal_line_dim4_idx ON ledger.journal_line (tenant_id, dim4_id, journal_date) WHERE dim4_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS journal_line_dim5_idx ON ledger.journal_line (tenant_id, dim5_id, journal_date) WHERE dim5_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS journal_line_dim6_idx ON ledger.journal_line (tenant_id, dim6_id, journal_date) WHERE dim6_id IS NOT NULL;

-- =====================================================================
-- ۱۰. سطل‌های مانده (دادهٔ مشتق؛ درج در همان تراکنش + فشرده‌سازی + راستی‌آزمایی)
-- =====================================================================
CREATE TABLE IF NOT EXISTS ledger.balance_bucket (
  tenant_id       uuid NOT NULL REFERENCES core.tenant(id),
  id              uuid NOT NULL DEFAULT uuidv7(),
  company_id      uuid NOT NULL,
  fiscal_year_id  uuid NOT NULL,
  period_id       uuid NOT NULL,
  account_id      uuid NOT NULL,
  entry_class     text NOT NULL,
  branch_id       uuid,
  dim1_id uuid, dim2_id uuid, dim3_id uuid, dim4_id uuid, dim5_id uuid, dim6_id uuid,
  currency        char(3) NOT NULL,
  debit_base      numeric NOT NULL,
  credit_base     numeric NOT NULL,
  debit_txn       numeric NOT NULL,
  credit_txn      numeric NOT NULL,
  line_count      bigint NOT NULL,
  is_compacted    boolean NOT NULL DEFAULT false,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id)
);
SELECT core.enable_tenant_rls('ledger.balance_bucket');
CREATE INDEX IF NOT EXISTS balance_bucket_key_idx ON ledger.balance_bucket (tenant_id, company_id, fiscal_year_id, period_id, account_id);
CREATE INDEX IF NOT EXISTS balance_bucket_dim1_idx ON ledger.balance_bucket (tenant_id, dim1_id, period_id) WHERE dim1_id IS NOT NULL;

-- =====================================================================
-- ۱۱. سند تکرارشونده
-- =====================================================================
CREATE TABLE IF NOT EXISTS ledger.recurring_journal (
  tenant_id          uuid NOT NULL REFERENCES core.tenant(id),
  id                 uuid NOT NULL DEFAULT uuidv7(),
  company_id         uuid NOT NULL,
  code               text NOT NULL CHECK (code ~ '^[0-9A-Za-z._-]{1,40}$'),
  name               text NOT NULL,
  journal_type       text NOT NULL DEFAULT 'recurring' REFERENCES ledger.journal_type(code),
  description        text NOT NULL DEFAULT '',
  frequency          text NOT NULL CHECK (frequency IN ('daily','weekly','monthly','quarterly','semiannual','yearly')),
  interval_count     smallint NOT NULL DEFAULT 1 CHECK (interval_count BETWEEN 1 AND 24),
  day_rule           text NOT NULL DEFAULT 'same_day' CHECK (day_rule IN ('same_day','first_day','last_day')),
  calendar           text NOT NULL DEFAULT 'jalali' CHECK (calendar IN ('jalali','gregorian')),
  start_date         date NOT NULL,
  end_date           date,
  next_run_date      date,
  max_occurrences    integer CHECK (max_occurrences >= 1),
  occurrences_done   integer NOT NULL DEFAULT 0 CHECK (occurrences_done >= 0),
  mode               text NOT NULL DEFAULT 'draft' CHECK (mode IN ('draft','post')),
  status             text NOT NULL DEFAULT 'active' CHECK (status IN ('active','paused','ended')),
  branch_id          uuid,
  created_by         uuid,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  row_version        integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, code),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  CHECK (end_date IS NULL OR end_date >= start_date),
  CHECK (journal_type IN ('recurring','manual','adjustment'))
);
SELECT core.enable_tenant_rls('ledger.recurring_journal');
CREATE INDEX IF NOT EXISTS recurring_journal_due_idx ON ledger.recurring_journal (next_run_date) WHERE status = 'active';

CREATE TABLE IF NOT EXISTS ledger.recurring_journal_line (
  tenant_id             uuid NOT NULL REFERENCES core.tenant(id),
  id                    uuid NOT NULL DEFAULT uuidv7(),
  recurring_journal_id  uuid NOT NULL,
  company_id            uuid NOT NULL,
  line_no               integer NOT NULL CHECK (line_no >= 1),
  account_id            uuid NOT NULL,
  branch_id             uuid,
  dim1_id uuid, dim2_id uuid, dim3_id uuid, dim4_id uuid, dim5_id uuid, dim6_id uuid,
  currency              char(3) NOT NULL REFERENCES ref.currency(code),
  rate_type_id          uuid,
  debit_txn             core.amount NOT NULL DEFAULT 0 CHECK (debit_txn >= 0),
  credit_txn            core.amount NOT NULL DEFAULT 0 CHECK (credit_txn >= 0),
  description           text,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, recurring_journal_id, line_no),
  FOREIGN KEY (tenant_id, recurring_journal_id) REFERENCES ledger.recurring_journal(tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, company_id, account_id) REFERENCES ledger.account(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, branch_id) REFERENCES core.branch(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, dim1_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, dim2_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, dim3_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, dim4_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, dim5_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, dim6_id) REFERENCES ledger.dimension_value(tenant_id, id),
  FOREIGN KEY (tenant_id, rate_type_id) REFERENCES ledger.rate_type(tenant_id, id),
  CHECK ((debit_txn > 0) <> (credit_txn > 0))
);
SELECT core.enable_tenant_rls('ledger.recurring_journal_line');

ALTER TABLE ledger.journal_draft DROP CONSTRAINT IF EXISTS journal_draft_recurring_fk;
ALTER TABLE ledger.journal_draft ADD CONSTRAINT journal_draft_recurring_fk
  FOREIGN KEY (tenant_id, recurring_journal_id) REFERENCES ledger.recurring_journal(tenant_id, id);
ALTER TABLE ledger.journal DROP CONSTRAINT IF EXISTS journal_recurring_fk;
ALTER TABLE ledger.journal ADD CONSTRAINT journal_recurring_fk
  FOREIGN KEY (tenant_id, recurring_journal_id) REFERENCES ledger.recurring_journal(tenant_id, id);

-- =====================================================================
-- ۱۲. اجراها: بستن سال، تسعیر، دفاتر الکترونیکی، راستی‌آزمایی، نگاشت گزارش
-- =====================================================================
CREATE TABLE IF NOT EXISTS ledger.year_close_run (
  tenant_id                   uuid NOT NULL REFERENCES core.tenant(id),
  id                          uuid NOT NULL DEFAULT uuidv7(),
  company_id                  uuid NOT NULL,
  fiscal_year_id              uuid NOT NULL,
  next_fiscal_year_id         uuid NOT NULL,
  status                      text NOT NULL DEFAULT 'running' CHECK (status IN ('running','completed','reverted','failed')),
  conversion_factor           core.rate NOT NULL DEFAULT 1 CHECK (conversion_factor > 0),   -- حذف صفرها: ارز پایهٔ سال بعد
  net_result_base             core.amount,
  pl_closing_journal_id       uuid,
  re_transfer_journal_id      uuid,
  balance_closing_journal_id  uuid,
  opening_journal_id          uuid,
  summary                     jsonb NOT NULL DEFAULT '{}',
  started_by                  uuid,
  started_at                  timestamptz NOT NULL DEFAULT now(),
  completed_at                timestamptz,
  reverted_at                 timestamptz,
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  row_version                 integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, fiscal_year_id) REFERENCES ledger.fiscal_year(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, next_fiscal_year_id) REFERENCES ledger.fiscal_year(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, pl_closing_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, re_transfer_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, balance_closing_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, opening_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id)
);
SELECT core.enable_tenant_rls('ledger.year_close_run');
CREATE UNIQUE INDEX IF NOT EXISTS year_close_run_active_uq ON ledger.year_close_run (tenant_id, fiscal_year_id)
  WHERE status IN ('running','completed');

CREATE TABLE IF NOT EXISTS ledger.fx_revaluation_run (
  tenant_id             uuid NOT NULL REFERENCES core.tenant(id),
  id                    uuid NOT NULL DEFAULT uuidv7(),
  company_id            uuid NOT NULL,
  period_id             uuid NOT NULL,
  as_of_date            date NOT NULL,
  rate_type_id          uuid NOT NULL,
  reversal_date         date,
  status                text NOT NULL DEFAULT 'posted' CHECK (status IN ('posted','voided')),
  journal_id            uuid,
  reversal_journal_id   uuid,
  rates_snapshot        jsonb NOT NULL CHECK (jsonb_typeof(rates_snapshot) = 'object'),
  created_by            uuid,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  row_version           integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, period_id) REFERENCES ledger.fiscal_period(tenant_id, id),
  FOREIGN KEY (tenant_id, rate_type_id) REFERENCES ledger.rate_type(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  FOREIGN KEY (tenant_id, company_id, reversal_journal_id) REFERENCES ledger.journal(tenant_id, company_id, id),
  CHECK (reversal_date IS NULL OR reversal_date > as_of_date)
);
SELECT core.enable_tenant_rls('ledger.fx_revaluation_run');
CREATE UNIQUE INDEX IF NOT EXISTS fx_revaluation_run_uq ON ledger.fx_revaluation_run (tenant_id, company_id, as_of_date, rate_type_id)
  WHERE status = 'posted';

CREATE TABLE IF NOT EXISTS ledger.eledger_export (
  tenant_id           uuid NOT NULL REFERENCES core.tenant(id),
  id                  uuid NOT NULL DEFAULT uuidv7(),
  company_id          uuid NOT NULL,
  fiscal_year_id      uuid NOT NULL,
  from_date           date NOT NULL,
  to_date             date NOT NULL,
  format_rule_key     text NOT NULL,         -- کلید پارامتر در موتور قواعد، مثل tax.eledger.format
  format_version      text NOT NULL,         -- نسخهٔ snapshot‌شده، مثل 1404-02-document
  status              text NOT NULL DEFAULT 'generated' CHECK (status IN ('generated','submitted','superseded')),
  row_count           integer NOT NULL CHECK (row_count >= 0),
  total_debit         core.amount NOT NULL,
  total_credit        core.amount NOT NULL,
  file_attachment_id  uuid,                  -- core.attachment (FK در 99_cross_fk)
  file_sha256         bytea NOT NULL,
  generated_by        uuid,
  generated_at        timestamptz NOT NULL DEFAULT now(),
  submitted_at        timestamptz,
  submission_ref      text,                  -- کد رهگیری سامانه
  updated_at          timestamptz NOT NULL DEFAULT now(),
  row_version         integer NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, fiscal_year_id) REFERENCES ledger.fiscal_year(tenant_id, company_id, id),
  CHECK (to_date >= from_date),
  CHECK (total_debit = total_credit),
  CHECK ((status = 'submitted') = (submitted_at IS NOT NULL))
);
SELECT core.enable_tenant_rls('ledger.eledger_export');

CREATE TABLE IF NOT EXISTS ledger.integrity_run (
  tenant_id       uuid NOT NULL REFERENCES core.tenant(id),
  id              uuid NOT NULL DEFAULT uuidv7(),
  company_id      uuid NOT NULL,
  fiscal_year_id  uuid,
  check_code      text NOT NULL CHECK (check_code IN ('journal_balance','trial_balance','balance_buckets','permanent_chain',
                                                       'control_accounts','year_close','numbering','report_coverage')),
  status          text NOT NULL CHECK (status IN ('ok','violation','error')),
  violations      integer NOT NULL DEFAULT 0 CHECK (violations >= 0),
  details         jsonb NOT NULL DEFAULT '[]',
  started_at      timestamptz NOT NULL,
  finished_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, company_id) REFERENCES core.company(tenant_id, id),
  FOREIGN KEY (tenant_id, company_id, fiscal_year_id) REFERENCES ledger.fiscal_year(tenant_id, company_id, id),
  CHECK ((status = 'ok') = (violations = 0))
);
SELECT core.enable_tenant_rls('ledger.integrity_run');

CREATE TABLE IF NOT EXISTS ledger.report_account_map (
  tenant_id         uuid NOT NULL REFERENCES core.tenant(id),
  id                uuid NOT NULL DEFAULT uuidv7(),
  company_id        uuid NOT NULL,
  template_code     text NOT NULL,
  template_version  integer NOT NULL,
  row_code          text NOT NULL,
  account_id        uuid NOT NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, company_id, template_code, template_version, account_id),
  FOREIGN KEY (template_code, template_version, row_code) REFERENCES ledger.report_template_row(template_code, template_version, row_code),
  FOREIGN KEY (tenant_id, company_id, account_id) REFERENCES ledger.account(tenant_id, company_id, id) ON DELETE CASCADE
);
SELECT core.enable_tenant_rls('ledger.report_account_map');

-- =====================================================================
-- ۱۳. تریگرها: کدینگ، ابعاد، سال و دوره
-- =====================================================================
CREATE OR REPLACE FUNCTION ledger.account_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE p ledger.account; v_mode text; v_len integer; v_levels integer; v_has_lines boolean;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.tenant_id <> OLD.tenant_id OR NEW.id <> OLD.id OR NEW.company_id <> OLD.company_id OR NEW.level <> OLD.level THEN
      PERFORM ledger.raise_error('HK_LEDGER_ACCOUNT_IMMUTABLE', 'tenant, company and level of an account are immutable');
    END IF;
    v_has_lines := EXISTS (SELECT 1 FROM ledger.journal_line l
                            WHERE l.tenant_id = OLD.tenant_id AND l.company_id = OLD.company_id AND l.account_id = OLD.id);
    IF NEW.account_type <> OLD.account_type AND (v_has_lines OR EXISTS (
         SELECT 1 FROM ledger.account c WHERE c.tenant_id = OLD.tenant_id AND c.parent_id = OLD.id)) THEN
      PERFORM ledger.raise_error('HK_LEDGER_ACCOUNT_TYPE_LOCKED', 'account type cannot change once the account has postings or children');
    END IF;
    IF OLD.kind = 'posting' AND NEW.kind = 'group' AND v_has_lines THEN
      PERFORM ledger.raise_error('HK_LEDGER_ACCOUNT_HAS_POSTINGS', 'an account with postings cannot become a group account');
    END IF;
    IF OLD.kind = 'group' AND NEW.kind = 'posting' AND EXISTS (
         SELECT 1 FROM ledger.account c WHERE c.tenant_id = OLD.tenant_id AND c.parent_id = OLD.id) THEN
      PERFORM ledger.raise_error('HK_LEDGER_ACCOUNT_HAS_CHILDREN', 'a group account with children cannot become a posting account');
    END IF;
  END IF;

  IF NEW.parent_id IS NOT NULL THEN
    SELECT * INTO p FROM ledger.account WHERE tenant_id = NEW.tenant_id AND id = NEW.parent_id;
    IF p.kind <> 'group' THEN
      PERFORM ledger.raise_error('HK_LEDGER_PARENT_NOT_GROUP', 'parent account must be a group account');
    END IF;
    IF NEW.level <> p.level + 1 THEN
      PERFORM ledger.raise_error('HK_LEDGER_ACCOUNT_LEVEL', format('child level %s must be parent level %s + 1', NEW.level, p.level));
    END IF;
    IF NEW.account_type <> p.account_type THEN
      PERFORM ledger.raise_error('HK_LEDGER_ACCOUNT_TYPE_MISMATCH', 'child account type must equal parent account type');
    END IF;
  END IF;

  SELECT count(*) INTO v_levels FROM ledger.coa_level WHERE tenant_id = NEW.tenant_id AND company_id = NEW.company_id;
  IF v_levels > 0 AND NOT EXISTS (SELECT 1 FROM ledger.coa_level WHERE tenant_id = NEW.tenant_id
                                     AND company_id = NEW.company_id AND level_no = NEW.level) THEN
    PERFORM ledger.raise_error('HK_LEDGER_ACCOUNT_DEPTH', format('level %s is not defined for this company', NEW.level));
  END IF;

  SELECT c.code_mode INTO v_mode FROM ledger.company_config c WHERE c.tenant_id = NEW.tenant_id AND c.company_id = NEW.company_id;
  IF v_mode = 'hierarchical' THEN
    SELECT sum(segment_length) INTO v_len FROM ledger.coa_level
     WHERE tenant_id = NEW.tenant_id AND company_id = NEW.company_id AND level_no <= NEW.level;
    IF NEW.code !~ '^[0-9]+$' OR (v_len IS NOT NULL AND char_length(NEW.code) <> v_len)
       OR (NEW.parent_id IS NOT NULL AND left(NEW.code, char_length(p.code)) <> p.code) THEN
      PERFORM ledger.raise_error('HK_LEDGER_ACCOUNT_CODE', format('code %s does not follow the hierarchical coding of this company', NEW.code));
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON ledger.account;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON ledger.account FOR EACH ROW EXECUTE FUNCTION ledger.account_guard();

-- در کدینگ سلسله‌مراتبی، تغییر کد گروه باید با کد فرزندان هم‌خوان شود (در پایان تراکنش)
CREATE OR REPLACE FUNCTION ledger.account_children_verify() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_mode text; v_code text;
BEGIN
  PERFORM ledger.assert_tenant_context(NEW.tenant_id);
  SELECT c.code_mode INTO v_mode FROM ledger.company_config c WHERE c.tenant_id = NEW.tenant_id AND c.company_id = NEW.company_id;
  SELECT a.code INTO v_code FROM ledger.account a WHERE a.tenant_id = NEW.tenant_id AND a.id = NEW.id;
  IF v_mode = 'hierarchical' AND EXISTS (SELECT 1 FROM ledger.account ch WHERE ch.tenant_id = NEW.tenant_id AND ch.parent_id = NEW.id
                                            AND left(ch.code, char_length(v_code)) <> v_code) THEN
    PERFORM ledger.raise_error('HK_LEDGER_ACCOUNT_CODE', format('children of %s must be recoded in the same transaction', v_code));
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_children_verify ON ledger.account;
CREATE CONSTRAINT TRIGGER trg_children_verify AFTER UPDATE OF code ON ledger.account
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ledger.account_children_verify();

-- قاعدهٔ بعد: در هر جایگاه (slot) حداکثر یک نوع «اجباری»، و اگر اجباری هست نوع دیگری در آن جایگاه مجاز نیست
CREATE OR REPLACE FUNCTION ledger.account_rule_verify() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_bad integer; v_kind text;
BEGIN
  PERFORM ledger.assert_tenant_context(NEW.tenant_id);
  SELECT kind INTO v_kind FROM ledger.account WHERE tenant_id = NEW.tenant_id AND id = NEW.account_id;
  IF v_kind IS DISTINCT FROM 'posting' THEN
    PERFORM ledger.raise_error('HK_LEDGER_RULE_ON_GROUP', 'dimension rules are defined on posting accounts only');
  END IF;
  SELECT count(*) INTO v_bad FROM (
    SELECT t.slot
      FROM ledger.account_dimension_rule r
      JOIN ledger.dimension_type t ON t.tenant_id = r.tenant_id AND t.id = r.dimension_type_id
     WHERE r.tenant_id = NEW.tenant_id AND r.account_id = NEW.account_id AND r.requirement <> 'forbidden'
     GROUP BY t.slot
    HAVING count(*) FILTER (WHERE r.requirement = 'required') > 1
        OR (count(*) FILTER (WHERE r.requirement = 'required') = 1 AND count(*) > 1)) s;
  IF v_bad > 0 THEN
    PERFORM ledger.raise_error('HK_LEDGER_RULE_SLOT_CONFLICT', 'a slot with a required dimension type cannot allow another type');
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_verify ON ledger.account_dimension_rule;
CREATE CONSTRAINT TRIGGER trg_verify AFTER INSERT OR UPDATE ON ledger.account_dimension_rule
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ledger.account_rule_verify();

CREATE OR REPLACE FUNCTION ledger.dimension_value_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_slot smallint; p ledger.dimension_value;
BEGIN
  IF TG_OP = 'UPDATE' AND (NEW.dimension_type_id <> OLD.dimension_type_id OR NEW.tenant_id <> OLD.tenant_id) THEN
    PERFORM ledger.raise_error('HK_LEDGER_DIM_IMMUTABLE', 'dimension type of a value is immutable');
  END IF;
  SELECT slot INTO v_slot FROM ledger.dimension_type WHERE tenant_id = NEW.tenant_id AND id = NEW.dimension_type_id;
  NEW.slot := v_slot;
  IF NEW.parent_id IS NOT NULL THEN
    SELECT * INTO p FROM ledger.dimension_value WHERE tenant_id = NEW.tenant_id AND id = NEW.parent_id;
    IF p.dimension_type_id <> NEW.dimension_type_id OR NOT p.is_group THEN
      PERFORM ledger.raise_error('HK_LEDGER_DIM_PARENT', 'parent must be a group value of the same type');
    END IF;
  END IF;
  IF NEW.merged_into_id IS NOT NULL THEN
    IF TG_OP = 'UPDATE' AND OLD.merged_into_id IS NOT NULL AND NEW.merged_into_id <> OLD.merged_into_id
       AND NOT EXISTS (SELECT 1 FROM ledger.dimension_value x WHERE x.tenant_id = NEW.tenant_id AND x.id = OLD.merged_into_id
                         AND x.merged_into_id = NEW.merged_into_id) THEN
      PERFORM ledger.raise_error('HK_LEDGER_DIM_MERGE', 'a merge can only be re-pointed along the chain of its target');
    END IF;
    SELECT * INTO p FROM ledger.dimension_value WHERE tenant_id = NEW.tenant_id AND id = NEW.merged_into_id;
    IF p.dimension_type_id <> NEW.dimension_type_id OR p.merged_into_id IS NOT NULL OR p.is_group <> NEW.is_group THEN
      PERFORM ledger.raise_error('HK_LEDGER_DIM_MERGE', 'merge target must be an unmerged value of the same type and kind');
    END IF;
  ELSIF TG_OP = 'UPDATE' AND OLD.merged_into_id IS NOT NULL THEN
    PERFORM ledger.raise_error('HK_LEDGER_DIM_MERGE', 'a merge cannot be undone; post reclassification journals instead');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON ledger.dimension_value;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON ledger.dimension_value FOR EACH ROW EXECUTE FUNCTION ledger.dimension_value_guard();

CREATE OR REPLACE FUNCTION ledger.posting_rule_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE a ledger.account; k ledger.posting_key;
BEGIN
  SELECT * INTO a FROM ledger.account WHERE tenant_id = NEW.tenant_id AND id = NEW.account_id;
  SELECT * INTO k FROM ledger.posting_key WHERE key = NEW.posting_key;
  IF a.kind <> 'posting' THEN
    PERFORM ledger.raise_error('HK_LEDGER_ACCOUNT_NOT_POSTABLE', 'a posting rule must target a posting account');
  END IF;
  IF cardinality(k.expected_account_types) > 0 AND NOT (a.account_type = ANY (k.expected_account_types)) THEN
    PERFORM ledger.raise_error('HK_LEDGER_MAPPING_ACCOUNT_TYPE',
      format('key %s expects %s, account is %s', k.key, k.expected_account_types, a.account_type));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON ledger.posting_rule;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON ledger.posting_rule FOR EACH ROW EXECUTE FUNCTION ledger.posting_rule_guard();

-- ---------- سال مالی ----------
CREATE OR REPLACE FUNCTION ledger.fiscal_year_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE prev ledger.fiscal_year; nxt ledger.fiscal_year; v_base char(3); v_max integer; v_head bytea;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'open' OR NEW.finalized_through IS NOT NULL OR NEW.last_permanent_no <> 0 THEN
      PERFORM ledger.raise_error('HK_LEDGER_FY_INSERT', 'a new fiscal year starts open, unfinalized and without permanent numbers');
    END IF;
    SELECT base_currency INTO v_base FROM core.company WHERE tenant_id = NEW.tenant_id AND id = NEW.company_id;
    IF NEW.base_currency <> v_base THEN
      PERFORM ledger.raise_error('HK_LEDGER_FY_CURRENCY', 'fiscal year base currency must equal the company base currency');
    END IF;
    IF NEW.previous_year_id IS NULL THEN
      IF EXISTS (SELECT 1 FROM ledger.fiscal_year f WHERE f.tenant_id = NEW.tenant_id AND f.company_id = NEW.company_id) THEN
        PERFORM ledger.raise_error('HK_LEDGER_FY_CHAIN', 'only the first fiscal year of a company may have no previous year');
      END IF;
    ELSE
      SELECT * INTO prev FROM ledger.fiscal_year WHERE tenant_id = NEW.tenant_id AND id = NEW.previous_year_id;
      IF prev.end_date + 1 <> NEW.start_date THEN
        PERFORM ledger.raise_error('HK_LEDGER_FY_CHAIN', 'a fiscal year must start the day after its previous year ends');
      END IF;
      IF NEW.opening_state <> 'pending' THEN
        PERFORM ledger.raise_error('HK_LEDGER_FY_INSERT', 'opening of a non-first year comes from closing the previous year');
      END IF;
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE
  IF (NEW.tenant_id, NEW.id, NEW.company_id, NEW.start_date, NEW.end_date, NEW.base_currency, NEW.previous_year_id)
     IS DISTINCT FROM (OLD.tenant_id, OLD.id, OLD.company_id, OLD.start_date, OLD.end_date, OLD.base_currency, OLD.previous_year_id) THEN
    PERFORM ledger.raise_error('HK_LEDGER_FY_IMMUTABLE', 'dates, currency and chain of a fiscal year are immutable');
  END IF;
  -- قفل انحصاری ردیف تا ثبت‌های در جریان (که FOR KEY SHARE گرفته‌اند) تمام شوند
  IF NEW.status <> OLD.status OR NEW.finalized_through IS DISTINCT FROM OLD.finalized_through THEN
    PERFORM 1 FROM ledger.fiscal_year WHERE tenant_id = OLD.tenant_id AND id = OLD.id FOR UPDATE;
  END IF;
  SELECT * INTO nxt FROM ledger.fiscal_year WHERE tenant_id = OLD.tenant_id AND previous_year_id = OLD.id;

  IF NEW.status <> OLD.status THEN
    IF (OLD.status, NEW.status) = ('open','closing') THEN
      IF EXISTS (SELECT 1 FROM ledger.fiscal_period p WHERE p.tenant_id = OLD.tenant_id AND p.fiscal_year_id = OLD.id
                    AND p.status NOT IN ('closed','locked')) THEN
        PERFORM ledger.raise_error('HK_LEDGER_FY_PERIODS_OPEN', 'all periods must be closed before year-end closing');
      END IF;
    ELSIF (OLD.status, NEW.status) = ('closing','open') THEN
      IF EXISTS (SELECT 1 FROM ledger.journal j WHERE j.tenant_id = OLD.tenant_id AND j.fiscal_year_id = OLD.id
                    AND j.entry_class = 'closing' AND j.status <> 'voided') THEN
        PERFORM ledger.raise_error('HK_LEDGER_FY_CLOSING_JOURNALS', 'void closing journals before reopening the year');
      END IF;
      IF nxt.id IS NOT NULL AND EXISTS (SELECT 1 FROM ledger.journal j WHERE j.tenant_id = OLD.tenant_id AND j.fiscal_year_id = nxt.id
                    AND j.journal_type = 'opening' AND j.status <> 'voided') THEN
        PERFORM ledger.raise_error('HK_LEDGER_FY_CLOSING_JOURNALS', 'void the opening journal of the next year before reopening');
      END IF;
    ELSIF (OLD.status, NEW.status) = ('closing','closed') THEN
      IF nxt.id IS NULL OR nxt.opening_state <> 'posted' THEN
        PERFORM ledger.raise_error('HK_LEDGER_FY_NO_OPENING', 'the next fiscal year must have its opening journal posted');
      END IF;
      NEW.closed_at := now(); NEW.closed_by := core.current_user_id();
    ELSIF (OLD.status, NEW.status) = ('closed','closing') THEN
      IF COALESCE(OLD.finalized_through, OLD.start_date - 1) >= OLD.end_date
         OR (nxt.id IS NOT NULL AND nxt.finalized_through IS NOT NULL) THEN
        PERFORM ledger.raise_error('HK_LEDGER_FY_FINALIZED', 'closing/opening journals are permanent; use prior-period adjustments');
      END IF;
    ELSIF (OLD.status, NEW.status) = ('closed','locked') THEN
      IF NEW.finalized_through IS DISTINCT FROM OLD.end_date OR EXISTS (
           SELECT 1 FROM ledger.fiscal_period p WHERE p.tenant_id = OLD.tenant_id AND p.fiscal_year_id = OLD.id AND p.status <> 'locked') THEN
        PERFORM ledger.raise_error('HK_LEDGER_FY_LOCK', 'locking a year requires full finalization and all periods locked');
      END IF;
      NEW.locked_at := now(); NEW.locked_by := core.current_user_id();
    ELSE
      PERFORM ledger.raise_error('HK_LEDGER_FY_TRANSITION', format('fiscal year transition %s -> %s is not allowed', OLD.status, NEW.status));
    END IF;
  END IF;

  IF NEW.opening_state <> OLD.opening_state THEN
    IF (OLD.opening_state, NEW.opening_state) = ('pending','posted') THEN
      IF NOT EXISTS (SELECT 1 FROM ledger.journal j WHERE j.tenant_id = OLD.tenant_id AND j.fiscal_year_id = OLD.id
                       AND j.entry_class = 'opening' AND j.status <> 'voided') THEN
        PERFORM ledger.raise_error('HK_LEDGER_FY_NO_OPENING', 'no opening journal exists');
      END IF;
      -- افتتاحیهٔ چندتکه (دفتر کل + زیردفترها) فقط وقتی کامل است که حساب تراز افتتاحیه صفر شده باشد
      IF EXISTS (SELECT 1 FROM ledger.journal_line l JOIN ledger.account a ON a.tenant_id = l.tenant_id AND a.id = l.account_id
                  WHERE l.tenant_id = OLD.tenant_id AND l.company_id = OLD.company_id AND l.fiscal_year_id = OLD.id
                    AND l.entry_class = 'opening' AND a.role = 'OPENING_BALANCE_CLEARING'
                 HAVING sum(l.debit_base - l.credit_base) <> 0) THEN
        PERFORM ledger.raise_error('HK_LEDGER_OPENING_CLEARING', 'opening balance clearing account must net to zero');
      END IF;
    ELSIF (OLD.opening_state, NEW.opening_state) = ('pending','not_required') THEN
      IF OLD.previous_year_id IS NOT NULL THEN
        PERFORM ledger.raise_error('HK_LEDGER_FY_OPENING_STATE', 'only the first fiscal year may skip the opening journal');
      END IF;
    ELSIF (OLD.opening_state, NEW.opening_state) IN (('posted','pending'),('not_required','pending')) THEN
      IF OLD.finalized_through IS NOT NULL OR EXISTS (SELECT 1 FROM ledger.journal j WHERE j.tenant_id = OLD.tenant_id
             AND j.fiscal_year_id = OLD.id AND j.entry_class = 'opening' AND j.status <> 'voided') THEN
        PERFORM ledger.raise_error('HK_LEDGER_FY_OPENING_STATE', 'opening can be reset only before finalization and after voiding');
      END IF;
    ELSE
      PERFORM ledger.raise_error('HK_LEDGER_FY_OPENING_STATE', 'invalid opening_state transition');
    END IF;
  END IF;

  IF NEW.finalized_through IS DISTINCT FROM OLD.finalized_through THEN
    IF OLD.finalized_through IS NOT NULL AND (NEW.finalized_through IS NULL OR NEW.finalized_through < OLD.finalized_through) THEN
      PERFORM ledger.raise_error('HK_LEDGER_FINALIZE_BACKWARD', 'the finalization cut-off only moves forward');
    END IF;
    IF NEW.opening_state = 'pending' THEN
      PERFORM ledger.raise_error('HK_LEDGER_OPENING_PENDING', 'post (or waive) the opening journal before finalizing');
    END IF;
    IF EXISTS (SELECT 1 FROM ledger.journal j WHERE j.tenant_id = OLD.tenant_id AND j.company_id = OLD.company_id
                 AND j.fiscal_year_id = OLD.id AND j.status = 'temporary' AND j.journal_date <= NEW.finalized_through) THEN
      PERFORM ledger.raise_error('HK_LEDGER_FINALIZE_GAP', 'temporary journals remain on or before the cut-off date');
    END IF;
  END IF;

  IF NEW.last_permanent_no <> OLD.last_permanent_no OR NEW.chain_head_hash IS DISTINCT FROM OLD.chain_head_hash THEN
    SELECT j.permanent_no, j.chain_hash INTO v_max, v_head FROM ledger.journal j
     WHERE j.tenant_id = OLD.tenant_id AND j.company_id = OLD.company_id AND j.fiscal_year_id = OLD.id AND j.status = 'permanent'
     ORDER BY j.permanent_no DESC LIMIT 1;
    IF COALESCE(v_max, 0) <> NEW.last_permanent_no OR v_head IS DISTINCT FROM NEW.chain_head_hash THEN
      PERFORM ledger.raise_error('HK_LEDGER_CHAIN_HEAD', 'last_permanent_no/chain_head_hash must match the last permanent journal');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON ledger.fiscal_year;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON ledger.fiscal_year FOR EACH ROW EXECUTE FUNCTION ledger.fiscal_year_guard();

-- پوشش کامل سال با دوره‌ها (در پایان تراکنش ساخت سال)
CREATE OR REPLACE FUNCTION ledger.fiscal_year_verify() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE s record;
BEGIN
  PERFORM ledger.assert_tenant_context(NEW.tenant_id);
  SELECT count(*) AS n, min(p.start_date) AS mn, max(p.end_date) AS mx, COALESCE(sum(p.end_date - p.start_date + 1), 0) AS days,
         bool_and(p.period_no = p.rn) AS ordered
    INTO s
    FROM (SELECT fp.*, row_number() OVER (ORDER BY fp.start_date) AS rn
            FROM ledger.fiscal_period fp WHERE fp.tenant_id = NEW.tenant_id AND fp.fiscal_year_id = NEW.id) p;
  IF s.n = 0 OR s.mn <> NEW.start_date OR s.mx <> NEW.end_date OR s.days <> (NEW.end_date - NEW.start_date + 1) OR NOT s.ordered THEN
    PERFORM ledger.raise_error('HK_LEDGER_PERIOD_COVERAGE',
      'periods must partition the fiscal year exactly and be numbered 1..n in date order');
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_verify ON ledger.fiscal_year;
CREATE CONSTRAINT TRIGGER trg_verify AFTER INSERT ON ledger.fiscal_year
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ledger.fiscal_year_verify();

-- ---------- دوره ----------
CREATE OR REPLACE FUNCTION ledger.fiscal_period_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE fy ledger.fiscal_year; v_rank_old int; v_rank_new int;
BEGIN
  SELECT * INTO fy FROM ledger.fiscal_year WHERE tenant_id = NEW.tenant_id AND id = NEW.fiscal_year_id;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'open' THEN
      PERFORM ledger.raise_error('HK_LEDGER_PERIOD_INSERT', 'a new period starts open');
    END IF;
    IF NEW.start_date < fy.start_date OR NEW.end_date > fy.end_date OR fy.status <> 'open' THEN
      PERFORM ledger.raise_error('HK_LEDGER_PERIOD_RANGE', 'period must lie inside an open fiscal year');
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.tenant_id, NEW.id, NEW.company_id, NEW.fiscal_year_id, NEW.period_no, NEW.start_date, NEW.end_date)
     IS DISTINCT FROM (OLD.tenant_id, OLD.id, OLD.company_id, OLD.fiscal_year_id, OLD.period_no, OLD.start_date, OLD.end_date) THEN
    PERFORM ledger.raise_error('HK_LEDGER_PERIOD_IMMUTABLE', 'period identity and dates are immutable');
  END IF;
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;
  v_rank_old := array_position(ARRAY['open','soft_closed','closed','locked'], OLD.status);
  v_rank_new := array_position(ARRAY['open','soft_closed','closed','locked'], NEW.status);
  IF v_rank_new > v_rank_old THEN
    -- محدودتر شدن: صبر برای ثبت‌های در جریان (FOR KEY SHARE) پیش از تغییر
    PERFORM 1 FROM ledger.fiscal_period WHERE tenant_id = OLD.tenant_id AND id = OLD.id FOR UPDATE;
  END IF;

  IF (OLD.status, NEW.status) IN (('open','soft_closed'), ('soft_closed','open')) THEN
    IF NEW.status = 'open' AND fy.status <> 'open' THEN
      PERFORM ledger.raise_error('HK_LEDGER_PERIOD_TRANSITION', 'cannot reopen a period of a year that is not open');
    END IF;
  ELSIF NEW.status = 'closed' AND OLD.status IN ('open','soft_closed') THEN
    IF EXISTS (SELECT 1 FROM ledger.fiscal_period p WHERE p.tenant_id = OLD.tenant_id AND p.fiscal_year_id = OLD.fiscal_year_id
                 AND p.period_no < OLD.period_no AND p.status NOT IN ('closed','locked')) THEN
      PERFORM ledger.raise_error('HK_LEDGER_PERIOD_SEQUENCE', 'earlier periods must be closed first');
    END IF;
  ELSIF OLD.status = 'closed' AND NEW.status IN ('open','soft_closed') THEN
    IF fy.status <> 'open' THEN
      PERFORM ledger.raise_error('HK_LEDGER_PERIOD_TRANSITION', 'cannot reopen a period of a year that is not open');
    END IF;
    IF COALESCE(fy.finalized_through, fy.start_date - 1) >= OLD.end_date THEN
      PERFORM ledger.raise_error('HK_LEDGER_PERIOD_FINALIZED', 'all dates of this period are finalized; reopening is pointless');
    END IF;
    IF NEW.status_reason IS NULL OR char_length(btrim(NEW.status_reason)) < 5 THEN
      PERFORM ledger.raise_error('HK_LEDGER_REASON_REQUIRED', 'reopening a closed period requires a reason');
    END IF;
  ELSIF (OLD.status, NEW.status) = ('closed','locked') THEN
    IF COALESCE(fy.finalized_through, fy.start_date - 1) < OLD.end_date THEN
      PERFORM ledger.raise_error('HK_LEDGER_PERIOD_NOT_FINALIZED', 'lock requires all journals of the period to be permanent');
    END IF;
  ELSIF (OLD.status, NEW.status) = ('locked','closed') THEN
    IF NEW.status_approval_ref IS NULL OR NEW.status_reason IS NULL OR char_length(btrim(NEW.status_reason)) < 5 THEN
      PERFORM ledger.raise_error('HK_LEDGER_UNLOCK_APPROVAL', 'unlocking a period requires an approval reference and a reason');
    END IF;
    IF fy.status = 'locked' THEN
      PERFORM ledger.raise_error('HK_LEDGER_PERIOD_TRANSITION', 'periods of a locked fiscal year cannot be unlocked');
    END IF;
  ELSE
    PERFORM ledger.raise_error('HK_LEDGER_PERIOD_TRANSITION', format('period transition %s -> %s is not allowed', OLD.status, NEW.status));
  END IF;
  NEW.status_changed_at := now();
  NEW.status_changed_by := core.current_user_id();
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON ledger.fiscal_period;
CREATE TRIGGER trg_guard BEFORE INSERT OR UPDATE ON ledger.fiscal_period FOR EACH ROW EXECUTE FUNCTION ledger.fiscal_period_guard();

CREATE OR REPLACE FUNCTION ledger.fiscal_period_history() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO ledger.period_status_event (tenant_id, period_id, from_status, to_status, reason, approval_ref, actor_user_id)
  VALUES (NEW.tenant_id, NEW.id, OLD.status, NEW.status, NEW.status_reason, NEW.status_approval_ref, core.current_user_id());
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_history ON ledger.fiscal_period;
CREATE TRIGGER trg_history AFTER UPDATE OF status ON ledger.fiscal_period
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION ledger.fiscal_period_history();

-- =====================================================================
-- ۱۴. تریگرهای سند و سطر
-- =====================================================================
-- شکل متعارف سند دائم برای زنجیرهٔ hash (بدون زمان و کاربر تا بازپخش قطعی باشد)
CREATE OR REPLACE FUNCTION ledger.journal_canonical(j ledger.journal) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT concat_ws('|', 'v1', j.company_id, j.fiscal_year_id, j.id, j.permanent_no, j.journal_date, j.journal_type,
                   j.entry_class, j.reference_no, j.source_module, COALESCE(j.source_doc_type, '-'),
                   COALESCE(j.source_doc_id::text, '-'), j.source_event, j.base_currency, j.line_count,
                   j.total_debit_base, j.memo_debit_base,
                   COALESCE(j.reversal_of_journal_id::text, '-'), char_length(j.description) || ':' || j.description)
         || E'\n' ||
         COALESCE((SELECT string_agg(concat_ws(',', l.line_no, l.account_id, COALESCE(l.branch_id::text, '-'),
                                               COALESCE(l.dim1_id::text, '-'), COALESCE(l.dim2_id::text, '-'),
                                               COALESCE(l.dim3_id::text, '-'), COALESCE(l.dim4_id::text, '-'),
                                               COALESCE(l.dim5_id::text, '-'), COALESCE(l.dim6_id::text, '-'),
                                               l.currency, l.exchange_rate, l.debit_txn, l.credit_txn, l.debit_base,
                                               l.credit_base, l.line_kind, COALESCE(l.quantity::text, '-'),
                                               char_length(COALESCE(l.description, '')) || ':' || COALESCE(l.description, '')),
                                     E'\n' ORDER BY l.line_no)
                     FROM ledger.journal_line l WHERE l.tenant_id = j.tenant_id AND l.journal_id = j.id), '')
$$;

CREATE OR REPLACE FUNCTION ledger.chain_genesis(p_company_id uuid, p_fiscal_year_id uuid) RETURNS bytea
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT sha256(convert_to('hk-ledger-chain-v1:' || p_company_id::text || ':' || p_fiscal_year_id::text, 'UTF8'))
$$;

CREATE OR REPLACE FUNCTION ledger.journal_before_insert() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE t ledger.journal_type; fy ledger.fiscal_year; prev_fy ledger.fiscal_year; p ledger.fiscal_period; o ledger.journal;
BEGIN
  SELECT * INTO t FROM ledger.journal_type WHERE code = NEW.journal_type;
  IF NOT FOUND THEN
    PERFORM ledger.raise_error('HK_LEDGER_JOURNAL_TYPE', format('unknown journal type %s', NEW.journal_type));
  END IF;
  IF NEW.permanent_no IS NOT NULL OR NEW.daily_no IS NOT NULL OR NEW.chain_hash IS NOT NULL OR NEW.chain_prev_hash IS NOT NULL
     OR NEW.finalized_at IS NOT NULL OR NEW.reviewed_at IS NOT NULL THEN
    PERFORM ledger.raise_error('HK_LEDGER_JOURNAL_INSERT', 'permanent/review fields are set only by later transitions');
  END IF;

  -- سال مالی: قفل اشتراکی تا نهایی‌سازی/تغییر وضعیت هم‌زمان منتظر بماند (و ما مقدار تازه را بخوانیم)
  IF NEW.fiscal_year_id IS NULL THEN
    SELECT f.id INTO NEW.fiscal_year_id FROM ledger.fiscal_year f
     WHERE f.tenant_id = NEW.tenant_id AND f.company_id = NEW.company_id AND NEW.journal_date BETWEEN f.start_date AND f.end_date;
  END IF;
  SELECT * INTO fy FROM ledger.fiscal_year f
   WHERE f.tenant_id = NEW.tenant_id AND f.id = NEW.fiscal_year_id AND f.company_id = NEW.company_id FOR KEY SHARE;
  IF NOT FOUND OR NEW.journal_date NOT BETWEEN fy.start_date AND fy.end_date THEN
    PERFORM ledger.raise_error('HK_LEDGER_NO_FISCAL_YEAR', format('no fiscal year of this company contains %s', NEW.journal_date));
  END IF;
  SELECT * INTO p FROM ledger.fiscal_period fp
   WHERE fp.tenant_id = NEW.tenant_id AND fp.fiscal_year_id = fy.id AND NEW.journal_date BETWEEN fp.start_date AND fp.end_date
   FOR KEY SHARE;
  IF NOT FOUND OR (NEW.period_id IS NOT NULL AND NEW.period_id <> p.id) THEN
    PERFORM ledger.raise_error('HK_LEDGER_NO_PERIOD', format('journal date %s is not inside the given period', NEW.journal_date));
  END IF;
  NEW.period_id := p.id;
  IF NEW.base_currency IS DISTINCT FROM fy.base_currency THEN
    PERFORM ledger.raise_error('HK_LEDGER_BASE_CURRENCY', 'journal base currency must equal the fiscal year base currency');
  END IF;

  -- کلاس سند (ابطال کلاس سند اصلی را می‌گیرد)
  IF NEW.journal_type = 'void' THEN
    SELECT * INTO o FROM ledger.journal WHERE tenant_id = NEW.tenant_id AND id = NEW.void_of_journal_id FOR UPDATE;
    IF NOT FOUND OR o.status <> 'temporary' THEN
      PERFORM ledger.raise_error('HK_LEDGER_VOID_NOT_TEMPORARY', 'only a temporary journal can be voided');
    END IF;
    IF o.journal_date <> NEW.journal_date OR o.company_id <> NEW.company_id OR NEW.status <> 'voided'
       OR o.source_module <> NEW.source_module THEN
      PERFORM ledger.raise_error('HK_LEDGER_VOID_PAIR', 'a void journal mirrors its original on the same date and source');
    END IF;
    NEW.entry_class := o.entry_class; NEW.class_rank := o.class_rank;
  ELSE
    IF NEW.status <> 'temporary' THEN
      PERFORM ledger.raise_error('HK_LEDGER_JOURNAL_INSERT', 'a journal is inserted as temporary');
    END IF;
    NEW.entry_class := t.entry_class; NEW.class_rank := t.class_rank;
  END IF;

  IF NEW.reversal_of_journal_id IS NOT NULL THEN
    SELECT * INTO o FROM ledger.journal WHERE tenant_id = NEW.tenant_id AND id = NEW.reversal_of_journal_id;
    IF NOT FOUND OR o.status NOT IN ('temporary','permanent') OR o.entry_class <> 'regular' THEN
      PERFORM ledger.raise_error('HK_LEDGER_REVERSAL_TARGET', 'only a temporary or permanent regular journal can be reversed');
    END IF;
    IF NEW.journal_date < o.journal_date OR o.source_module <> NEW.source_module THEN
      PERFORM ledger.raise_error('HK_LEDGER_REVERSAL_DATE', 'a reversal is dated on/after its original and keeps its source module');
    END IF;
    IF (NEW.journal_type = 'fx_revaluation_reversal') <> (o.journal_type = 'fx_revaluation') THEN
      PERFORM ledger.raise_error('HK_LEDGER_REVERSAL_TYPE', 'fx revaluations are reversed with fx_revaluation_reversal only');
    END IF;
  END IF;

  -- مبدأ سند
  IF t.origin = 'manual' AND NEW.source_module <> 'ledger' THEN
    PERFORM ledger.raise_error('HK_LEDGER_SOURCE_MODULE', 'manual journal types belong to the ledger module');
  ELSIF t.origin = 'module' AND NEW.source_module = 'ledger' THEN
    PERFORM ledger.raise_error('HK_LEDGER_SOURCE_MODULE', 'module journals must name their source module');
  ELSIF t.origin = 'system' AND NEW.source_module <> 'ledger' THEN
    PERFORM ledger.raise_error('HK_LEDGER_SOURCE_MODULE', 'system journal types are created by the ledger');
  END IF;   -- origin = 'import': هر ماژول مالک داده (ledger، migration، treasury، inventory، ...) با واحد مبلغ صریح
  IF t.requires_input_unit AND NEW.input_amount_unit IS NULL THEN
    PERFORM ledger.raise_error('HK_LEDGER_INPUT_UNIT', 'imported amounts must declare their unit (IRR/IRT/IRR_NEW)');
  END IF;

  -- بُرش نهایی‌سازی
  IF fy.finalized_through IS NOT NULL AND NEW.journal_date <= fy.finalized_through THEN
    PERFORM ledger.raise_error('HK_LEDGER_FINALIZED_DATE', format('dates up to %s are finalized (permanent)', fy.finalized_through));
  END IF;

  -- وضعیت سال و دوره بر اساس کلاس
  IF NEW.entry_class = 'closing' THEN
    IF fy.status <> 'closing' OR NEW.journal_date <> fy.end_date OR p.status = 'locked' THEN
      PERFORM ledger.raise_error('HK_LEDGER_CLOSING_STATE', 'closing journals are posted on the last day while the year is closing');
    END IF;
  ELSIF NEW.entry_class = 'opening' THEN
    IF fy.status <> 'open' OR NEW.journal_date <> fy.start_date OR p.status = 'locked' THEN
      PERFORM ledger.raise_error('HK_LEDGER_OPENING_STATE', 'opening journals are posted on the first day of an open year');
    END IF;
    IF NEW.journal_type = 'opening' THEN
      SELECT * INTO prev_fy FROM ledger.fiscal_year WHERE tenant_id = NEW.tenant_id AND id = fy.previous_year_id;
      IF NOT FOUND OR prev_fy.status <> 'closing' THEN
        PERFORM ledger.raise_error('HK_LEDGER_OPENING_STATE', 'a year-close opening journal requires the previous year to be closing');
      END IF;
    ELSIF NEW.journal_type = 'opening_import' AND (fy.previous_year_id IS NOT NULL OR fy.opening_state <> 'pending') THEN
      PERFORM ledger.raise_error('HK_LEDGER_OPENING_STATE', 'opening balances can be imported only into a first year still pending');
    END IF;
  ELSE
    IF fy.status <> 'open' THEN
      PERFORM ledger.raise_error('HK_LEDGER_YEAR_NOT_OPEN', format('fiscal year %s is %s', fy.code, fy.status));
    END IF;
    IF p.status IN ('closed','locked') THEN
      PERFORM ledger.raise_error('HK_LEDGER_PERIOD_CLOSED', format('period %s is %s', p.name, p.status));
    END IF;
    IF p.status = 'soft_closed' AND NOT NEW.soft_close_override THEN
      PERFORM ledger.raise_error('HK_LEDGER_PERIOD_SOFT_CLOSED', format('period %s is soft-closed', p.name));
    END IF;
  END IF;
  IF NEW.entry_class <> 'closing' AND EXISTS (SELECT 1 FROM ledger.period_module_lock m
       WHERE m.tenant_id = NEW.tenant_id AND m.period_id = p.id AND m.module = NEW.source_module) THEN
    PERFORM ledger.raise_error('HK_LEDGER_MODULE_LOCKED', format('period %s is locked for module %s', p.name, NEW.source_module));
  END IF;

  NEW.posted_at := now();
  NEW.posted_by := COALESCE(NEW.posted_by, core.current_user_id());
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_before_insert ON ledger.journal;
CREATE TRIGGER trg_before_insert BEFORE INSERT ON ledger.journal FOR EACH ROW EXECUTE FUNCTION ledger.journal_before_insert();

CREATE OR REPLACE FUNCTION ledger.journal_before_update() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_mutable constant text[] := ARRAY['status','permanent_no','daily_no','finalized_at','finalized_by','chain_prev_hash',
                                     'chain_hash','reviewed_at','reviewed_by','void_reason','updated_at','row_version'];
  prev ledger.journal; fy ledger.fiscal_year; v_review boolean;
BEGIN
  IF (to_jsonb(NEW) - v_mutable) IS DISTINCT FROM (to_jsonb(OLD) - v_mutable) THEN
    PERFORM ledger.raise_error('HK_IMMUTABLE', 'posted journal content is immutable; use a reversal or adjustment');
  END IF;
  IF OLD.status <> 'temporary' THEN
    PERFORM ledger.raise_error('HK_IMMUTABLE', format('a %s journal cannot change', OLD.status));
  END IF;

  IF NEW.status = 'temporary' THEN
    IF NEW.permanent_no IS NOT NULL OR NEW.void_reason IS NOT NULL
       OR (OLD.reviewed_at IS NOT NULL AND (NEW.reviewed_at, NEW.reviewed_by) IS DISTINCT FROM (OLD.reviewed_at, OLD.reviewed_by)) THEN
      PERFORM ledger.raise_error('HK_LEDGER_BAD_TRANSITION', 'a temporary journal may only be marked reviewed once');
    END IF;
    RETURN NEW;
  ELSIF NEW.status = 'voided' THEN
    IF NOT EXISTS (SELECT 1 FROM ledger.journal v WHERE v.tenant_id = OLD.tenant_id AND v.void_of_journal_id = OLD.id) THEN
      PERFORM ledger.raise_error('HK_LEDGER_VOID_PAIR', 'insert the mirroring void journal before voiding');
    END IF;
    IF NEW.void_reason IS NULL OR char_length(btrim(NEW.void_reason)) < 3 OR NEW.permanent_no IS NOT NULL THEN
      PERFORM ledger.raise_error('HK_LEDGER_REASON_REQUIRED', 'voiding requires a reason');
    END IF;
    IF EXISTS (SELECT 1 FROM ledger.journal r WHERE r.tenant_id = OLD.tenant_id AND r.reversal_of_journal_id = OLD.id
                 AND r.status <> 'voided') THEN
      PERFORM ledger.raise_error('HK_LEDGER_VOID_HAS_REVERSAL', 'void the reversal of this journal first');
    END IF;
    RETURN NEW;
  ELSIF NEW.status = 'permanent' THEN
    SELECT * INTO fy FROM ledger.fiscal_year WHERE tenant_id = OLD.tenant_id AND id = OLD.fiscal_year_id;
    IF fy.opening_state = 'pending' THEN
      PERFORM ledger.raise_error('HK_LEDGER_OPENING_PENDING', 'post (or waive) the opening journal before finalizing');
    END IF;
    SELECT c.require_review_before_finalize INTO v_review FROM ledger.company_config c
     WHERE c.tenant_id = OLD.tenant_id AND c.company_id = OLD.company_id;
    IF COALESCE(v_review, false) AND OLD.reviewed_at IS NULL THEN
      PERFORM ledger.raise_error('HK_LEDGER_NOT_REVIEWED', 'journal must be reviewed before it becomes permanent');
    END IF;
    IF NEW.permanent_no IS NULL OR NEW.finalized_at IS NULL THEN
      PERFORM ledger.raise_error('HK_LEDGER_BAD_TRANSITION', 'permanent number and finalization time are required');
    END IF;
    IF NEW.permanent_no = 1 THEN
      IF NEW.chain_prev_hash IS DISTINCT FROM ledger.chain_genesis(OLD.company_id, OLD.fiscal_year_id) OR NEW.daily_no <> 1 THEN
        PERFORM ledger.raise_error('HK_LEDGER_CHAIN_LINK', 'first permanent journal must link to the genesis hash');
      END IF;
    ELSE
      SELECT * INTO prev FROM ledger.journal j WHERE j.tenant_id = OLD.tenant_id AND j.company_id = OLD.company_id
         AND j.fiscal_year_id = OLD.fiscal_year_id AND j.permanent_no = NEW.permanent_no - 1;
      IF NOT FOUND THEN
        PERFORM ledger.raise_error('HK_LEDGER_PERMANENT_GAP', format('permanent number %s skips %s', NEW.permanent_no, NEW.permanent_no - 1));
      END IF;
      IF (OLD.journal_date, OLD.class_rank) < (prev.journal_date, prev.class_rank) THEN
        PERFORM ledger.raise_error('HK_LEDGER_PERMANENT_ORDER', 'permanent numbers must follow date order');
      END IF;
      IF NEW.chain_prev_hash IS DISTINCT FROM prev.chain_hash THEN
        PERFORM ledger.raise_error('HK_LEDGER_CHAIN_LINK', 'chain_prev_hash must equal the previous permanent journal hash');
      END IF;
      IF NEW.daily_no <> (CASE WHEN prev.journal_date = OLD.journal_date THEN prev.daily_no + 1 ELSE 1 END) THEN
        PERFORM ledger.raise_error('HK_LEDGER_DAILY_NO', 'daily number must continue within the day');
      END IF;
    END IF;
    IF EXISTS (SELECT 1 FROM ledger.journal j WHERE j.tenant_id = OLD.tenant_id AND j.company_id = OLD.company_id
                 AND j.fiscal_year_id = OLD.fiscal_year_id AND j.status = 'temporary' AND j.id <> OLD.id
                 AND (j.journal_date, j.class_rank) < (OLD.journal_date, OLD.class_rank)) THEN
      PERFORM ledger.raise_error('HK_LEDGER_PERMANENT_PENDING_EARLIER', 'earlier temporary journals must become permanent first');
    END IF;
    IF NEW.chain_hash IS DISTINCT FROM sha256(NEW.chain_prev_hash || convert_to(ledger.journal_canonical(NEW), 'UTF8')) THEN
      PERFORM ledger.raise_error('HK_LEDGER_CHAIN_CONTENT', 'chain_hash does not match the canonical content');
    END IF;
    RETURN NEW;
  END IF;
  PERFORM ledger.raise_error('HK_LEDGER_BAD_TRANSITION', format('journal transition %s -> %s is not allowed', OLD.status, NEW.status));
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_before_update ON ledger.journal;
CREATE TRIGGER trg_before_update BEFORE UPDATE ON ledger.journal FOR EACH ROW EXECUTE FUNCTION ledger.journal_before_update();
-- در پایان تراکنش: هر سند دائم داخل بُرش نهایی‌سازی است (دائم ⇔ تاریخ ≤ finalized_through و باطل‌نشده)
CREATE OR REPLACE FUNCTION ledger.journal_permanent_verify() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_cut date;
BEGIN
  PERFORM ledger.assert_tenant_context(NEW.tenant_id);
  SELECT finalized_through INTO v_cut FROM ledger.fiscal_year WHERE tenant_id = NEW.tenant_id AND id = NEW.fiscal_year_id;
  IF v_cut IS NULL OR NEW.journal_date > v_cut THEN
    PERFORM ledger.raise_error('HK_LEDGER_PERMANENT_CUTOFF', 'a journal becomes permanent only together with the finalization cut-off');
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_permanent_verify ON ledger.journal;
CREATE CONSTRAINT TRIGGER trg_permanent_verify AFTER UPDATE OF status ON ledger.journal
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.status = 'permanent') EXECUTE FUNCTION ledger.journal_permanent_verify();
DROP TRIGGER IF EXISTS trg_nodelete ON ledger.journal;
CREATE TRIGGER trg_nodelete BEFORE DELETE ON ledger.journal FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();
DROP TRIGGER IF EXISTS trg_touch ON ledger.journal;
CREATE TRIGGER trg_touch BEFORE UPDATE ON ledger.journal FOR EACH ROW EXECUTE FUNCTION core.touch_row();

-- در پایان تراکنش: تعداد سطرها، تراز پایه، تراز انتظامی، و آینه بودن ابطال/برگشت
CREATE OR REPLACE FUNCTION ledger.journal_verify() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE s record; o ledger.journal; v_bad integer;
BEGIN
  PERFORM ledger.assert_tenant_context(NEW.tenant_id);
  SELECT count(*) AS n, COALESCE(sum(l.debit_base), 0) AS dr, COALESCE(sum(l.credit_base), 0) AS cr,
         COALESCE(sum(l.debit_base) FILTER (WHERE l.is_memo), 0) AS mdr,
         COALESCE(sum(l.credit_base) FILTER (WHERE l.is_memo), 0) AS mcr
    INTO s FROM ledger.journal_line l WHERE l.tenant_id = NEW.tenant_id AND l.journal_id = NEW.id;
  IF s.n <> NEW.line_count THEN
    PERFORM ledger.raise_error('HK_LEDGER_LINE_COUNT', format('journal %s declares %s lines but has %s', NEW.reference_text, NEW.line_count, s.n));
  END IF;
  IF s.dr <> s.cr OR s.dr <> NEW.total_debit_base OR s.cr <> NEW.total_credit_base THEN
    PERFORM ledger.raise_error('HK_UNBALANCED', format('journal %s: debit %s, credit %s, declared %s', NEW.reference_text, s.dr, s.cr, NEW.total_debit_base));
  END IF;
  IF s.mdr <> s.mcr OR s.mdr <> NEW.memo_debit_base OR s.mcr <> NEW.memo_credit_base THEN
    PERFORM ledger.raise_error('HK_LEDGER_MEMO_UNBALANCED', format('journal %s: memo debit %s, memo credit %s', NEW.reference_text, s.mdr, s.mcr));
  END IF;
  IF NEW.void_of_journal_id IS NOT NULL OR NEW.reversal_of_journal_id IS NOT NULL THEN
    SELECT * INTO o FROM ledger.journal WHERE tenant_id = NEW.tenant_id AND id = COALESCE(NEW.void_of_journal_id, NEW.reversal_of_journal_id);
    IF NEW.void_of_journal_id IS NOT NULL AND o.status <> 'voided' THEN
      PERFORM ledger.raise_error('HK_LEDGER_VOID_PAIR', 'the original of a void journal must be voided in the same transaction');
    END IF;
    SELECT count(*) INTO v_bad
      FROM (SELECT * FROM ledger.journal_line WHERE tenant_id = NEW.tenant_id AND journal_id = NEW.id) x
      FULL JOIN (SELECT * FROM ledger.journal_line WHERE tenant_id = NEW.tenant_id AND journal_id = o.id) y USING (line_no)
     WHERE x.id IS NULL OR y.id IS NULL
        OR x.account_id <> y.account_id OR x.branch_id IS DISTINCT FROM y.branch_id
        OR x.dim1_id IS DISTINCT FROM y.dim1_id OR x.dim2_id IS DISTINCT FROM y.dim2_id OR x.dim3_id IS DISTINCT FROM y.dim3_id
        OR x.dim4_id IS DISTINCT FROM y.dim4_id OR x.dim5_id IS DISTINCT FROM y.dim5_id OR x.dim6_id IS DISTINCT FROM y.dim6_id
        OR x.currency <> y.currency OR x.exchange_rate <> y.exchange_rate OR x.line_kind <> y.line_kind
        OR x.debit_base <> y.credit_base OR x.credit_base <> y.debit_base
        OR x.debit_txn <> y.credit_txn OR x.credit_txn <> y.debit_txn
        OR x.quantity IS DISTINCT FROM y.quantity;
    IF v_bad > 0 THEN
      PERFORM ledger.raise_error('HK_LEDGER_MIRROR', format('%s lines of %s do not mirror the original', v_bad, NEW.reference_text));
    END IF;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_verify ON ledger.journal;
CREATE CONSTRAINT TRIGGER trg_verify AFTER INSERT ON ledger.journal
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ledger.journal_verify();

CREATE OR REPLACE FUNCTION ledger.journal_line_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  h ledger.journal; t ledger.journal_type; a ledger.account;
  v_minor_base smallint; v_minor_txn smallint; v_dims uuid[]; v_val record; v_req text; k integer; r record;
BEGIN
  SELECT * INTO h FROM ledger.journal WHERE tenant_id = NEW.tenant_id AND id = NEW.journal_id;
  IF NOT FOUND THEN
    PERFORM ledger.raise_error('HK_LEDGER_JOURNAL_NOT_FOUND', 'the journal header must be inserted before its lines');
  END IF;
  IF h.status NOT IN ('temporary','voided') THEN
    PERFORM ledger.raise_error('HK_IMMUTABLE', 'lines cannot be added to a permanent journal');
  END IF;
  IF NEW.line_no > h.line_count THEN
    PERFORM ledger.raise_error('HK_LEDGER_LINE_SLOT', format('line_no %s exceeds the declared line_count %s', NEW.line_no, h.line_count));
  END IF;
  NEW.company_id := h.company_id; NEW.fiscal_year_id := h.fiscal_year_id; NEW.period_id := h.period_id;
  NEW.journal_date := h.journal_date; NEW.entry_class := h.entry_class; NEW.created_at := now();

  SELECT * INTO t FROM ledger.journal_type WHERE code = h.journal_type;
  SELECT * INTO a FROM ledger.account WHERE tenant_id = NEW.tenant_id AND id = NEW.account_id;
  IF NOT FOUND OR a.company_id <> h.company_id THEN
    PERFORM ledger.raise_error('HK_LEDGER_ACCOUNT_COMPANY', 'account does not belong to the journal company');
  END IF;
  IF a.kind <> 'posting' THEN
    PERFORM ledger.raise_error('HK_LEDGER_ACCOUNT_NOT_POSTABLE', format('account %s is a group account', a.code));
  END IF;
  NEW.is_memo := (a.account_type = 'memo');

  -- دقت مبلغ‌ها بر اساس minor_unit هر ارز
  SELECT minor_unit INTO v_minor_base FROM ref.currency WHERE code = h.base_currency;
  SELECT minor_unit INTO v_minor_txn FROM ref.currency WHERE code = NEW.currency;
  IF NEW.debit_base <> round(NEW.debit_base, v_minor_base) OR NEW.credit_base <> round(NEW.credit_base, v_minor_base)
     OR NEW.debit_txn <> round(NEW.debit_txn, v_minor_txn) OR NEW.credit_txn <> round(NEW.credit_txn, v_minor_txn) THEN
    PERFORM ledger.raise_error('HK_LEDGER_AMOUNT_PRECISION', 'amount has more decimals than the currency minor unit');
  END IF;

  -- سازگاری مبلغ پایه با مبلغ معامله × نرخ
  IF NEW.currency = h.base_currency THEN
    IF NEW.exchange_rate <> 1 OR NEW.debit_txn <> NEW.debit_base OR NEW.credit_txn <> NEW.credit_base OR NEW.line_kind = 'base_adjustment' THEN
      PERFORM ledger.raise_error('HK_LEDGER_BASE_MISMATCH', 'a base-currency line has rate 1 and equal transaction and base amounts');
    END IF;
  ELSIF NEW.line_kind = 'base_adjustment' THEN
    IF NOT t.allows_base_only_lines THEN
      PERFORM ledger.raise_error('HK_LEDGER_BASE_ONLY_LINE', format('journal type %s does not allow base-only lines', t.code));
    END IF;
  ELSIF abs((NEW.debit_base - NEW.credit_base) - (NEW.debit_txn - NEW.credit_txn) * NEW.exchange_rate) >= power(10::numeric, -v_minor_base) THEN
    PERFORM ledger.raise_error('HK_LEDGER_BASE_MISMATCH', 'base amount must equal round(transaction amount x rate)');
  END IF;

  IF t.skip_line_rules THEN
    RETURN NEW;   -- آینه (ابطال/برگشت) با journal_verify، بستن سال با check_year_close راستی‌آزمایی می‌شود
  END IF;

  IF NOT a.is_active THEN
    PERFORM ledger.raise_error('HK_LEDGER_ACCOUNT_INACTIVE', format('account %s is inactive', a.code));
  END IF;
  IF NOT t.bypass_posting_policy THEN
    IF a.posting_policy = 'subledger_only' AND NOT (h.source_module = ANY (a.allowed_source_modules)) THEN
      PERFORM ledger.raise_error('HK_LEDGER_CONTROL_ACCOUNT',
        format('account %s accepts postings only from %s', a.code, array_to_string(a.allowed_source_modules, ',')));
    END IF;
    IF a.posting_policy = 'system_only' AND t.origin IN ('manual','import') THEN
      PERFORM ledger.raise_error('HK_LEDGER_SYSTEM_ONLY_ACCOUNT', format('account %s accepts system postings only', a.code));
    END IF;
  END IF;
  IF a.currency_policy = 'base_only' AND NEW.currency <> h.base_currency
     OR a.currency_policy = 'fixed' AND NEW.currency <> a.fixed_currency THEN
    PERFORM ledger.raise_error('HK_LEDGER_ACCOUNT_CURRENCY', format('account %s does not accept currency %s', a.code, NEW.currency));
  END IF;
  IF a.branch_rule = 'required' AND NEW.branch_id IS NULL THEN
    PERFORM ledger.raise_error('HK_LEDGER_BRANCH_REQUIRED', format('account %s requires a branch', a.code));
  ELSIF a.branch_rule = 'forbidden' AND NEW.branch_id IS NOT NULL THEN
    PERFORM ledger.raise_error('HK_LEDGER_BRANCH_FORBIDDEN', format('account %s does not accept a branch', a.code));
  END IF;

  v_dims := ARRAY[NEW.dim1_id, NEW.dim2_id, NEW.dim3_id, NEW.dim4_id, NEW.dim5_id, NEW.dim6_id];
  FOR k IN 1..6 LOOP
    CONTINUE WHEN v_dims[k] IS NULL;
    SELECT v.slot, v.dimension_type_id, v.is_active, v.is_group, v.company_id INTO v_val
      FROM ledger.dimension_value v WHERE v.tenant_id = NEW.tenant_id AND v.id = v_dims[k];
    IF v_val.slot <> k THEN
      PERFORM ledger.raise_error('HK_LEDGER_DIM_SLOT', format('dimension value in dim%s_id belongs to slot %s', k, v_val.slot));
    END IF;
    IF NOT v_val.is_active OR v_val.is_group THEN
      PERFORM ledger.raise_error('HK_LEDGER_DIM_NOT_POSTABLE', format('dimension value in slot %s is inactive or a group', k));
    END IF;
    IF v_val.company_id IS NOT NULL AND v_val.company_id <> h.company_id THEN
      PERFORM ledger.raise_error('HK_LEDGER_DIM_COMPANY', format('dimension value in slot %s belongs to another company', k));
    END IF;
    SELECT requirement INTO v_req FROM ledger.account_dimension_rule
     WHERE tenant_id = NEW.tenant_id AND account_id = a.id AND dimension_type_id = v_val.dimension_type_id;
    IF v_req IS NULL OR v_req = 'forbidden' THEN
      PERFORM ledger.raise_error('HK_LEDGER_DIM_FORBIDDEN', format('account %s does not accept the dimension in slot %s', a.code, k));
    END IF;
  END LOOP;
  FOR r IN SELECT ar.dimension_type_id, dt.slot, dt.code
             FROM ledger.account_dimension_rule ar
             JOIN ledger.dimension_type dt ON dt.tenant_id = ar.tenant_id AND dt.id = ar.dimension_type_id
            WHERE ar.tenant_id = NEW.tenant_id AND ar.account_id = a.id AND ar.requirement = 'required' LOOP
    IF v_dims[r.slot] IS NULL OR NOT EXISTS (SELECT 1 FROM ledger.dimension_value v WHERE v.tenant_id = NEW.tenant_id
                                               AND v.id = v_dims[r.slot] AND v.dimension_type_id = r.dimension_type_id) THEN
      PERFORM ledger.raise_error('HK_LEDGER_DIM_REQUIRED', format('account %s requires dimension %s', a.code, r.code));
    END IF;
  END LOOP;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_guard ON ledger.journal_line;
CREATE TRIGGER trg_guard BEFORE INSERT ON ledger.journal_line FOR EACH ROW EXECUTE FUNCTION ledger.journal_line_guard();
DROP TRIGGER IF EXISTS trg_immutable ON ledger.journal_line;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON ledger.journal_line FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

-- سطل‌های مانده: در همان تراکنش، یک ردیف تجمیعی برای هر کلید در هر دستور درج
CREATE OR REPLACE FUNCTION ledger.bucket_from_lines() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM new_lines n WHERE n.tenant_id IS DISTINCT FROM core.current_tenant_id()) THEN
    RAISE EXCEPTION 'HK_LEDGER_TENANT_CONTEXT: lines outside the current tenant context' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO ledger.balance_bucket (tenant_id, company_id, fiscal_year_id, period_id, account_id, entry_class, branch_id,
                                     dim1_id, dim2_id, dim3_id, dim4_id, dim5_id, dim6_id, currency,
                                     debit_base, credit_base, debit_txn, credit_txn, line_count)
  SELECT n.tenant_id, n.company_id, n.fiscal_year_id, n.period_id, n.account_id, n.entry_class, n.branch_id,
         n.dim1_id, n.dim2_id, n.dim3_id, n.dim4_id, n.dim5_id, n.dim6_id, n.currency,
         sum(n.debit_base), sum(n.credit_base), sum(n.debit_txn), sum(n.credit_txn), count(*)
    FROM new_lines n
   GROUP BY n.tenant_id, n.company_id, n.fiscal_year_id, n.period_id, n.account_id, n.entry_class, n.branch_id,
            n.dim1_id, n.dim2_id, n.dim3_id, n.dim4_id, n.dim5_id, n.dim6_id, n.currency;
  RETURN NULL;
END $$;
ALTER FUNCTION ledger.bucket_from_lines() OWNER TO hk_ledger_definer;
COMMENT ON FUNCTION ledger.bucket_from_lines() IS
  'HK_DEFINER_REVIEWED: 2026-11-17 section 03; inserts derived buckets for rows of the current tenant only (explicit check + RLS); fixed search_path; no dynamic SQL';
DROP TRIGGER IF EXISTS trg_bucket ON ledger.journal_line;
CREATE TRIGGER trg_bucket AFTER INSERT ON ledger.journal_line REFERENCING NEW TABLE AS new_lines
  FOR EACH STATEMENT EXECUTE FUNCTION ledger.bucket_from_lines();

-- فقط‌افزودنی بودن تاریخچهٔ وضعیت دوره و نتایج راستی‌آزمایی
DROP TRIGGER IF EXISTS trg_immutable ON ledger.period_status_event;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON ledger.period_status_event FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();
DROP TRIGGER IF EXISTS trg_immutable ON ledger.integrity_run;
CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON ledger.integrity_run FOR EACH ROW EXECUTE FUNCTION core.forbid_mutation();

-- updated_at و row_version روی جدول‌های تغییرپذیر
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['ledger.rate_type','ledger.company_config','ledger.coa_level','ledger.dimension_type','ledger.dimension_value',
                           'ledger.account','ledger.account_dimension_rule','ledger.fiscal_year','ledger.fiscal_period',
                           'ledger.exchange_rate','ledger.posting_rule','ledger.journal_draft','ledger.recurring_journal',
                           'ledger.year_close_run','ledger.fx_revaluation_run','ledger.eledger_export']
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_touch ON %s', t);
    EXECUTE format('CREATE TRIGGER trg_touch BEFORE UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION core.touch_row()', t);
  END LOOP;
END $$;

-- =====================================================================
-- ۱۵. عملیات (توابع با نقش فراخوان؛ RLS برقرار است)
-- =====================================================================
-- ابطال سند موقت: سند آینه با همان تاریخ؛ هر دو «باطل» و بیرون از شماره‌گذاری دائم
CREATE OR REPLACE FUNCTION ledger.void_journal(p_journal_id uuid, p_void_id uuid, p_reference_no bigint, p_reference_text text,
                                               p_reason text, p_soft_close_override boolean DEFAULT false)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE j ledger.journal;
BEGIN
  SELECT * INTO j FROM ledger.journal WHERE id = p_journal_id FOR UPDATE;
  IF NOT FOUND THEN PERFORM ledger.raise_error('HK_LEDGER_JOURNAL_NOT_FOUND', 'journal not found'); END IF;
  INSERT INTO ledger.journal (tenant_id, id, company_id, fiscal_year_id, period_id, branch_id, journal_date, journal_type,
                              entry_class, class_rank, status, reference_no, reference_text, description, source_module,
                              source_doc_type, source_doc_id, source_doc_no, source_event, base_currency, line_count,
                              total_debit_base, total_credit_base, memo_debit_base, memo_credit_base, soft_close_override,
                              void_of_journal_id, void_reason)
  VALUES (j.tenant_id, p_void_id, j.company_id, j.fiscal_year_id, j.period_id, j.branch_id, j.journal_date, 'void',
          j.entry_class, j.class_rank, 'voided', p_reference_no, p_reference_text, 'ابطال: ' || j.description, j.source_module,
          j.source_doc_type, j.source_doc_id, j.source_doc_no, 'void:' || left(j.source_event, 55), j.base_currency, j.line_count,
          j.total_debit_base, j.total_credit_base, j.memo_debit_base, j.memo_credit_base, p_soft_close_override,
          j.id, p_reason);
  INSERT INTO ledger.journal_line (tenant_id, journal_id, line_no, company_id, fiscal_year_id, period_id, journal_date, entry_class,
                                   account_id, branch_id, dim1_id, dim2_id, dim3_id, dim4_id, dim5_id, dim6_id, currency,
                                   exchange_rate, rate_type_id, debit_txn, credit_txn, debit_base, credit_base, line_kind,
                                   quantity, description, posting_key, posting_rule_id, source_line_ref)
  SELECT l.tenant_id, p_void_id, l.line_no, l.company_id, l.fiscal_year_id, l.period_id, l.journal_date, l.entry_class,
         l.account_id, l.branch_id, l.dim1_id, l.dim2_id, l.dim3_id, l.dim4_id, l.dim5_id, l.dim6_id, l.currency,
         l.exchange_rate, l.rate_type_id, l.credit_txn, l.debit_txn, l.credit_base, l.debit_base, l.line_kind,
         l.quantity, l.description, l.posting_key, l.posting_rule_id, l.source_line_ref
    FROM ledger.journal_line l WHERE l.tenant_id = j.tenant_id AND l.journal_id = j.id ORDER BY l.line_no;
  UPDATE ledger.journal SET status = 'voided', void_reason = p_reason WHERE tenant_id = j.tenant_id AND id = j.id;
  RETURN p_void_id;
END $$;

-- سند برگشت (معکوس) با تاریخ ≥ تاریخ اصل؛ اصل تغییر نمی‌کند و «برگشت‌خورده» حالت مشتق است
CREATE OR REPLACE FUNCTION ledger.reverse_journal(p_journal_id uuid, p_reversal_id uuid, p_date date, p_reference_no bigint,
                                                  p_reference_text text, p_description text DEFAULT NULL,
                                                  p_source_event text DEFAULT 'reverse', p_soft_close_override boolean DEFAULT false)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE j ledger.journal;
BEGIN
  SELECT * INTO j FROM ledger.journal WHERE id = p_journal_id FOR SHARE;
  IF NOT FOUND THEN PERFORM ledger.raise_error('HK_LEDGER_JOURNAL_NOT_FOUND', 'journal not found'); END IF;
  INSERT INTO ledger.journal (tenant_id, id, company_id, branch_id, journal_date, journal_type, status, reference_no, reference_text,
                              description, source_module, source_doc_type, source_doc_id, source_doc_no, source_event,
                              base_currency, line_count, total_debit_base, total_credit_base, memo_debit_base, memo_credit_base,
                              soft_close_override, reversal_of_journal_id, entry_class, class_rank)
  SELECT j.tenant_id, p_reversal_id, j.company_id, j.branch_id, p_date,
         CASE WHEN j.journal_type = 'fx_revaluation' THEN 'fx_revaluation_reversal' ELSE 'reversal' END,
         'temporary', p_reference_no, p_reference_text, COALESCE(p_description, 'برگشت: ' || j.description),
         j.source_module, j.source_doc_type, j.source_doc_id, j.source_doc_no, p_source_event,
         f.base_currency, j.line_count, j.total_debit_base, j.total_credit_base, j.memo_debit_base, j.memo_credit_base,
         p_soft_close_override, j.id, 'regular', 1
    FROM ledger.fiscal_year f
   WHERE f.tenant_id = j.tenant_id AND f.company_id = j.company_id AND p_date BETWEEN f.start_date AND f.end_date;
  IF NOT FOUND THEN PERFORM ledger.raise_error('HK_LEDGER_NO_FISCAL_YEAR', format('no fiscal year contains %s', p_date)); END IF;
  INSERT INTO ledger.journal_line (tenant_id, journal_id, line_no, company_id, fiscal_year_id, period_id, journal_date, entry_class,
                                   account_id, branch_id, dim1_id, dim2_id, dim3_id, dim4_id, dim5_id, dim6_id, currency,
                                   exchange_rate, rate_type_id, debit_txn, credit_txn, debit_base, credit_base, line_kind,
                                   quantity, description, posting_key, posting_rule_id, source_line_ref)
  SELECT l.tenant_id, p_reversal_id, l.line_no, l.company_id, l.fiscal_year_id, l.period_id, l.journal_date, l.entry_class,
         l.account_id, l.branch_id, l.dim1_id, l.dim2_id, l.dim3_id, l.dim4_id, l.dim5_id, l.dim6_id, l.currency,
         l.exchange_rate, l.rate_type_id, l.credit_txn, l.debit_txn, l.credit_base, l.debit_base, l.line_kind,
         l.quantity, l.description, l.posting_key, l.posting_rule_id, l.source_line_ref
    FROM ledger.journal_line l WHERE l.tenant_id = j.tenant_id AND l.journal_id = j.id ORDER BY l.line_no;
  RETURN p_reversal_id;
END $$;

-- قطعی (دائم) کردن اسناد موقت تا یک تاریخ: شمارهٔ دائم ۱..n به ترتیب (تاریخ، کلاس، شمارهٔ عطف) + زنجیرهٔ hash
CREATE OR REPLACE FUNCTION ledger.finalize_through(p_fiscal_year_id uuid, p_through date)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE fy ledger.fiscal_year; j ledger.journal; n integer; v_prev bytea; v_last_date date; v_daily integer;
        v_hash bytea; v_count integer := 0; v_user uuid := core.current_user_id(); v_now timestamptz := now();
BEGIN
  SELECT * INTO fy FROM ledger.fiscal_year WHERE id = p_fiscal_year_id FOR UPDATE;
  IF NOT FOUND THEN PERFORM ledger.raise_error('HK_LEDGER_NO_FISCAL_YEAR', 'fiscal year not found'); END IF;
  IF p_through < fy.start_date OR p_through > fy.end_date THEN
    PERFORM ledger.raise_error('HK_LEDGER_FINALIZE_RANGE', 'cut-off date must be inside the fiscal year');
  END IF;
  IF fy.finalized_through IS NOT NULL AND p_through <= fy.finalized_through THEN
    RETURN 0;
  END IF;
  n := fy.last_permanent_no;
  IF n = 0 THEN
    v_prev := ledger.chain_genesis(fy.company_id, fy.id); v_last_date := NULL; v_daily := 0;
  ELSE
    SELECT x.chain_hash, x.journal_date, x.daily_no INTO v_prev, v_last_date, v_daily FROM ledger.journal x
     WHERE x.tenant_id = fy.tenant_id AND x.company_id = fy.company_id AND x.fiscal_year_id = fy.id AND x.permanent_no = n;
  END IF;
  FOR j IN SELECT * FROM ledger.journal x
            WHERE x.tenant_id = fy.tenant_id AND x.company_id = fy.company_id AND x.fiscal_year_id = fy.id
              AND x.status = 'temporary' AND x.journal_date <= p_through
            ORDER BY x.journal_date, x.class_rank, x.legacy_permanent_no NULLS LAST, x.reference_no
            FOR UPDATE LOOP
    n := n + 1;
    v_daily := CASE WHEN v_last_date = j.journal_date THEN v_daily + 1 ELSE 1 END;
    j.status := 'permanent'; j.permanent_no := n;
    v_hash := sha256(v_prev || convert_to(ledger.journal_canonical(j), 'UTF8'));
    UPDATE ledger.journal SET status = 'permanent', permanent_no = n, daily_no = v_daily, finalized_at = v_now,
                              finalized_by = v_user, chain_prev_hash = v_prev, chain_hash = v_hash
     WHERE tenant_id = j.tenant_id AND id = j.id;
    v_prev := v_hash; v_last_date := j.journal_date; v_count := v_count + 1;
  END LOOP;
  UPDATE ledger.fiscal_year
     SET finalized_through = p_through, last_permanent_no = n,
         chain_head_hash = CASE WHEN n = 0 THEN NULL ELSE v_prev END
   WHERE tenant_id = fy.tenant_id AND id = fy.id;
  RETURN v_count;
END $$;

-- حل حساب از روی کلید نگاشت و ویژگی‌های زمینه (قطعی؛ گره → خطا)
CREATE OR REPLACE FUNCTION ledger.resolve_account(p_company_id uuid, p_key text, p_date date, p_attrs jsonb)
RETURNS TABLE (rule_id uuid, account_id uuid, dimension_defaults jsonb)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
DECLARE c record; first_rec record; n integer := 0;
BEGIN
  FOR c IN
    SELECT r.id, r.account_id, r.dimension_defaults, r.priority,
           (SELECT count(*) FROM jsonb_object_keys(r.conditions)) AS specificity
      FROM ledger.posting_rule r
     WHERE r.company_id = p_company_id AND r.posting_key = p_key AND r.is_active
       AND p_date BETWEEN r.valid_from AND r.valid_to
       AND NOT EXISTS (
         SELECT 1 FROM jsonb_each(r.conditions) e
          WHERE NOT COALESCE(CASE jsonb_typeof(e.value)
                               WHEN 'string' THEN (p_attrs ->> e.key) = (e.value #>> '{}')
                               WHEN 'array'  THEN e.value ? (p_attrs ->> e.key)
                             END, false))
     ORDER BY r.priority, specificity DESC, r.id
     LIMIT 2
  LOOP
    n := n + 1;
    IF n = 1 THEN
      first_rec := c;
    ELSIF c.priority = first_rec.priority AND c.specificity = first_rec.specificity THEN
      PERFORM ledger.raise_error('HK_LEDGER_MAPPING_AMBIGUOUS',
        format('key %s: rules %s and %s match with equal priority and specificity', p_key, first_rec.id, c.id));
    END IF;
  END LOOP;
  IF n = 0 THEN
    PERFORM ledger.raise_error('HK_LEDGER_MAPPING_MISSING', format('no account mapping for key %s on %s', p_key, p_date));
  END IF;
  rule_id := first_rec.id; account_id := first_rec.account_id; dimension_defaults := first_rec.dimension_defaults;
  RETURN NEXT;
END $$;

-- آخرین نرخ تا یک تاریخ
CREATE OR REPLACE FUNCTION ledger.rate_on(p_rate_type_id uuid, p_currency char(3), p_base char(3), p_date date)
RETURNS TABLE (rate numeric, rate_date date)
LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN p_currency = p_base THEN 1::numeric END, p_date WHERE p_currency = p_base
  UNION ALL
  (SELECT x.rate, x.rate_date FROM ledger.exchange_rate x
    WHERE p_currency <> p_base AND x.rate_type_id = p_rate_type_id AND x.currency = p_currency
      AND x.base_currency = p_base AND x.rate_date <= p_date
    ORDER BY x.rate_date DESC LIMIT 1)
$$;

-- ابعاد سیستمی و نوع نرخ پیش‌فرض برای مستأجر جاری (idempotent)
CREATE OR REPLACE FUNCTION ledger.provision_tenant() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_tenant uuid := core.current_tenant_id(); n integer;
BEGIN
  IF v_tenant IS NULL THEN PERFORM ledger.raise_error('HK_LEDGER_TENANT_CONTEXT', 'tenant context is required'); END IF;
  INSERT INTO ledger.dimension_type (tenant_id, code, name, slot, kind, owner_module, is_hierarchical, sort_order)
  SELECT v_tenant, c.code, c.name_fa, c.slot, 'system', c.owner_module, c.is_hierarchical, row_number() OVER (ORDER BY c.slot, c.code)
    FROM ledger.dimension_type_catalog c
  ON CONFLICT (tenant_id, code) DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  INSERT INTO ledger.rate_type (tenant_id, code, name, is_default)
  SELECT v_tenant, 'official', 'نرخ رسمی', NOT EXISTS (SELECT 1 FROM ledger.rate_type WHERE tenant_id = v_tenant AND is_default)
  ON CONFLICT (tenant_id, code) DO NOTHING;
  RETURN n;
END $$;

-- اعمال قالب کدینگ روی یک شرکت (سطوح، پیکربندی، حساب‌ها، قواعد بُعد، نگاشت‌ها)
CREATE OR REPLACE FUNCTION ledger.apply_coa_template(p_company_id uuid, p_code text, p_version integer)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE v_tenant uuid := core.current_tenant_id(); tpl ledger.coa_template; lvl jsonb; ta record; v_parent uuid; v_id uuid;
        v_count integer := 0; d record; v_type uuid;
BEGIN
  SELECT * INTO tpl FROM ledger.coa_template WHERE code = p_code AND version = p_version AND status = 'published';
  IF NOT FOUND THEN PERFORM ledger.raise_error('HK_LEDGER_TEMPLATE_NOT_FOUND', format('template %s v%s not found', p_code, p_version)); END IF;
  IF EXISTS (SELECT 1 FROM ledger.account WHERE company_id = p_company_id) THEN
    PERFORM ledger.raise_error('HK_LEDGER_COA_NOT_EMPTY', 'the company already has accounts');
  END IF;
  IF tpl.extends_code IS NOT NULL THEN
    PERFORM ledger.raise_error('HK_LEDGER_TEMPLATE_EXTENDS', 'apply the flattened template (extends is resolved at publish time)');
  END IF;
  DELETE FROM ledger.coa_level WHERE company_id = p_company_id;
  FOR lvl IN SELECT * FROM jsonb_array_elements(tpl.levels) LOOP
    INSERT INTO ledger.coa_level (tenant_id, company_id, level_no, name_fa, segment_length)
    VALUES (v_tenant, p_company_id, (lvl->>'level')::smallint, lvl->>'name_fa', (lvl->>'segment_length')::smallint);
  END LOOP;
  INSERT INTO ledger.company_config (tenant_id, company_id, code_mode, coa_template_code, coa_template_version)
  VALUES (v_tenant, p_company_id, tpl.code_mode, tpl.code, tpl.version)
  ON CONFLICT (tenant_id, company_id) DO UPDATE SET code_mode = EXCLUDED.code_mode,
     coa_template_code = EXCLUDED.coa_template_code, coa_template_version = EXCLUDED.coa_template_version;
  FOR ta IN SELECT * FROM ledger.coa_template_account
             WHERE template_code = p_code AND template_version = p_version ORDER BY level, code LOOP
    v_parent := NULL;
    IF ta.parent_code IS NOT NULL THEN
      SELECT id INTO v_parent FROM ledger.account WHERE company_id = p_company_id AND code = ta.parent_code;
      IF v_parent IS NULL THEN PERFORM ledger.raise_error('HK_LEDGER_TEMPLATE_PARENT', format('parent %s missing', ta.parent_code)); END IF;
    END IF;
    INSERT INTO ledger.account (tenant_id, company_id, parent_id, level, code, name, name_en, kind, account_type, nature, role, tags,
                                posting_policy, allowed_source_modules, subledger_kind, currency_policy, revalue_fx, branch_rule)
    VALUES (v_tenant, p_company_id, v_parent, ta.level, ta.code, ta.name_fa, ta.name_en, ta.kind, ta.account_type, ta.nature, ta.role,
            ta.tags, ta.posting_policy, ta.allowed_source_modules, ta.subledger_kind, ta.currency_policy, ta.revalue_fx, ta.branch_rule)
    RETURNING id INTO v_id;
    v_count := v_count + 1;
    FOR d IN SELECT key, value #>> '{}' AS req FROM jsonb_each(ta.dimension_rules) LOOP
      SELECT id INTO v_type FROM ledger.dimension_type WHERE code = d.key;
      IF v_type IS NULL THEN PERFORM ledger.raise_error('HK_LEDGER_DIM_TYPE_MISSING', format('dimension type %s not provisioned', d.key)); END IF;
      INSERT INTO ledger.account_dimension_rule (tenant_id, account_id, dimension_type_id, requirement)
      VALUES (v_tenant, v_id, v_type, d.req);
    END LOOP;
  END LOOP;
  INSERT INTO ledger.posting_rule (tenant_id, company_id, posting_key, priority, conditions, account_id)
  SELECT v_tenant, p_company_id, r.posting_key, r.priority, r.conditions, a.id
    FROM ledger.coa_template_posting_rule r
    JOIN ledger.account a ON a.company_id = p_company_id AND a.code = r.account_code
   WHERE r.template_code = p_code AND r.template_version = p_version;
  RETURN v_count;
END $$;

-- =====================================================================
-- ۱۶. سطل‌های مانده: فشرده‌سازی، بازسازی، راستی‌آزمایی
-- =====================================================================
CREATE OR REPLACE FUNCTION ledger.compact_balance_buckets(p_company_id uuid, p_period_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_tenant uuid := core.current_tenant_id(); n integer;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'HK_LEDGER_TENANT_CONTEXT: tenant context is required' USING ERRCODE = 'P0001';
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'ledger.bucket:' || v_tenant::text || ':' || p_company_id::text || ':' || p_period_id::text, 0));
  WITH victims AS (
    DELETE FROM ledger.balance_bucket b
     WHERE b.tenant_id = v_tenant AND b.company_id = p_company_id AND b.period_id = p_period_id
    RETURNING b.*
  ), ins AS (
    INSERT INTO ledger.balance_bucket (tenant_id, company_id, fiscal_year_id, period_id, account_id, entry_class, branch_id,
                                       dim1_id, dim2_id, dim3_id, dim4_id, dim5_id, dim6_id, currency,
                                       debit_base, credit_base, debit_txn, credit_txn, line_count, is_compacted)
    SELECT v.tenant_id, v.company_id, v.fiscal_year_id, v.period_id, v.account_id, v.entry_class, v.branch_id,
           v.dim1_id, v.dim2_id, v.dim3_id, v.dim4_id, v.dim5_id, v.dim6_id, v.currency,
           sum(v.debit_base), sum(v.credit_base), sum(v.debit_txn), sum(v.credit_txn), sum(v.line_count), true
      FROM victims v
     GROUP BY v.tenant_id, v.company_id, v.fiscal_year_id, v.period_id, v.account_id, v.entry_class, v.branch_id,
              v.dim1_id, v.dim2_id, v.dim3_id, v.dim4_id, v.dim5_id, v.dim6_id, v.currency
    RETURNING 1
  )
  SELECT count(*) INTO n FROM ins;
  RETURN n;
END $$;
ALTER FUNCTION ledger.compact_balance_buckets(uuid, uuid) OWNER TO hk_ledger_definer;
COMMENT ON FUNCTION ledger.compact_balance_buckets(uuid, uuid) IS
  'HK_DEFINER_REVIEWED: 2026-11-17 section 03; sum-preserving compaction in one statement for the current tenant; fixed search_path; no dynamic SQL';

CREATE OR REPLACE FUNCTION ledger.rebuild_balance_buckets(p_company_id uuid, p_fiscal_year_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_tenant uuid := core.current_tenant_id(); n integer;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'HK_LEDGER_TENANT_CONTEXT: tenant context is required' USING ERRCODE = 'P0001';
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'ledger.bucket.rebuild:' || v_tenant::text || ':' || p_company_id::text || ':' || p_fiscal_year_id::text, 0));
  -- یک دستور = یک snapshot: سطرهای دیده‌شده دقیقاً همان‌هایی‌اند که سطل‌هایشان حذف می‌شود
  WITH del AS (
    DELETE FROM ledger.balance_bucket b
     WHERE b.tenant_id = v_tenant AND b.company_id = p_company_id AND b.fiscal_year_id = p_fiscal_year_id
    RETURNING 1
  ), ins AS (
    INSERT INTO ledger.balance_bucket (tenant_id, company_id, fiscal_year_id, period_id, account_id, entry_class, branch_id,
                                       dim1_id, dim2_id, dim3_id, dim4_id, dim5_id, dim6_id, currency,
                                       debit_base, credit_base, debit_txn, credit_txn, line_count, is_compacted)
    SELECT l.tenant_id, l.company_id, l.fiscal_year_id, l.period_id, l.account_id, l.entry_class, l.branch_id,
           l.dim1_id, l.dim2_id, l.dim3_id, l.dim4_id, l.dim5_id, l.dim6_id, l.currency,
           sum(l.debit_base), sum(l.credit_base), sum(l.debit_txn), sum(l.credit_txn), count(*), true
      FROM ledger.journal_line l
     WHERE l.tenant_id = v_tenant AND l.company_id = p_company_id AND l.fiscal_year_id = p_fiscal_year_id
     GROUP BY l.tenant_id, l.company_id, l.fiscal_year_id, l.period_id, l.account_id, l.entry_class, l.branch_id,
              l.dim1_id, l.dim2_id, l.dim3_id, l.dim4_id, l.dim5_id, l.dim6_id, l.currency
    RETURNING 1
  )
  SELECT (SELECT count(*) FROM ins) INTO n FROM (SELECT count(*) FROM del) d;
  RETURN n;
END $$;
ALTER FUNCTION ledger.rebuild_balance_buckets(uuid, uuid) OWNER TO hk_ledger_definer;
COMMENT ON FUNCTION ledger.rebuild_balance_buckets(uuid, uuid) IS
  'HK_DEFINER_REVIEWED: 2026-11-17 section 03; rebuilds derived buckets of the current tenant from journal_line in one statement; fixed search_path; no dynamic SQL';

-- تفاوت سطل‌ها با سطرها (خالی = درست)
CREATE OR REPLACE FUNCTION ledger.verify_balance_buckets(p_company_id uuid, p_fiscal_year_id uuid)
RETURNS TABLE (period_id uuid, account_id uuid, entry_class text, currency char(3),
               line_debit numeric, bucket_debit numeric, line_credit numeric, bucket_credit numeric)
LANGUAGE sql STABLE AS $$
  WITH l AS (
    SELECT period_id, account_id, entry_class, branch_id, dim1_id, dim2_id, dim3_id, dim4_id, dim5_id, dim6_id, currency,
           sum(debit_base) AS dr, sum(credit_base) AS cr, sum(debit_txn) AS tdr, sum(credit_txn) AS tcr, count(*) AS n
      FROM ledger.journal_line WHERE company_id = p_company_id AND fiscal_year_id = p_fiscal_year_id
     GROUP BY 1,2,3,4,5,6,7,8,9,10,11
  ), b AS (
    SELECT period_id, account_id, entry_class, branch_id, dim1_id, dim2_id, dim3_id, dim4_id, dim5_id, dim6_id, currency,
           sum(debit_base) AS dr, sum(credit_base) AS cr, sum(debit_txn) AS tdr, sum(credit_txn) AS tcr, sum(line_count) AS n
      FROM ledger.balance_bucket WHERE company_id = p_company_id AND fiscal_year_id = p_fiscal_year_id
     GROUP BY 1,2,3,4,5,6,7,8,9,10,11
  )
  SELECT COALESCE(l.period_id, b.period_id), COALESCE(l.account_id, b.account_id), COALESCE(l.entry_class, b.entry_class),
         COALESCE(l.currency, b.currency), l.dr, b.dr, l.cr, b.cr
    FROM l FULL JOIN b
      ON (l.period_id, l.account_id, l.entry_class, l.currency) = (b.period_id, b.account_id, b.entry_class, b.currency)
     AND l.branch_id IS NOT DISTINCT FROM b.branch_id
     AND l.dim1_id IS NOT DISTINCT FROM b.dim1_id AND l.dim2_id IS NOT DISTINCT FROM b.dim2_id
     AND l.dim3_id IS NOT DISTINCT FROM b.dim3_id AND l.dim4_id IS NOT DISTINCT FROM b.dim4_id
     AND l.dim5_id IS NOT DISTINCT FROM b.dim5_id AND l.dim6_id IS NOT DISTINCT FROM b.dim6_id
   WHERE l.dr IS DISTINCT FROM b.dr OR l.cr IS DISTINCT FROM b.cr OR l.tdr IS DISTINCT FROM b.tdr
      OR l.tcr IS DISTINCT FROM b.tcr OR l.n IS DISTINCT FROM b.n
$$;

-- =====================================================================
-- ۱۷. گزارش‌ها و راستی‌آزمایی‌ها (SECURITY INVOKER؛ RLS)
-- =====================================================================
-- تراز آزمایشی در سطح حساب معین/برگ: گردش ابتدای دوره (شامل افتتاحیه) و گردش طی دوره، به ارز پایه
CREATE OR REPLACE FUNCTION ledger.trial_balance(p_company_id uuid, p_from date, p_to date, p_include_closing boolean DEFAULT false)
RETURNS TABLE (account_id uuid, open_debit numeric, open_credit numeric, period_debit numeric, period_credit numeric)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
DECLARE fy ledger.fiscal_year;
BEGIN
  SELECT * INTO fy FROM ledger.fiscal_year f WHERE f.company_id = p_company_id AND p_from BETWEEN f.start_date AND f.end_date;
  IF NOT FOUND OR p_to < p_from OR p_to > fy.end_date THEN
    PERFORM ledger.raise_error('HK_LEDGER_REPORT_RANGE', 'report range must lie inside one fiscal year');
  END IF;
  RETURN QUERY
  WITH pr AS (
    SELECT p.id,
           CASE WHEN p.end_date < p_from THEN 'before'
                WHEN p.start_date >= p_from AND p.end_date <= p_to THEN 'inside'
                WHEN p.start_date > p_to THEN 'after'
                ELSE 'partial' END AS pos
      FROM ledger.fiscal_period p WHERE p.fiscal_year_id = fy.id
  ), src AS (
    SELECT b.account_id AS acc, b.entry_class AS cls,
           CASE WHEN pr.pos = 'before' OR b.entry_class = 'opening' THEN 'open' ELSE 'period' END AS col,
           b.debit_base AS dr, b.credit_base AS cr
      FROM ledger.balance_bucket b JOIN pr ON pr.id = b.period_id
     WHERE b.company_id = p_company_id AND b.fiscal_year_id = fy.id AND pr.pos IN ('before','inside')
    UNION ALL
    SELECT l.account_id, l.entry_class,
           CASE WHEN l.journal_date < p_from OR l.entry_class = 'opening' THEN 'open' ELSE 'period' END,
           l.debit_base, l.credit_base
      FROM ledger.journal_line l JOIN pr ON pr.id = l.period_id
     WHERE l.company_id = p_company_id AND l.fiscal_year_id = fy.id AND pr.pos = 'partial' AND l.journal_date <= p_to
  )
  SELECT s.acc,
         COALESCE(sum(s.dr) FILTER (WHERE s.col = 'open'), 0), COALESCE(sum(s.cr) FILTER (WHERE s.col = 'open'), 0),
         COALESCE(sum(s.dr) FILTER (WHERE s.col = 'period'), 0), COALESCE(sum(s.cr) FILTER (WHERE s.col = 'period'), 0)
    FROM src s
   WHERE s.cls <> 'closing' OR p_include_closing
   GROUP BY s.acc;
END $$;

-- نیاکان هر حساب (شامل خودش)
CREATE OR REPLACE VIEW ledger.v_account_lineage WITH (security_invoker = true) AS
WITH RECURSIVE up AS (
  SELECT a.tenant_id, a.id AS account_id, a.id AS ancestor_id, a.level AS ancestor_level
    FROM ledger.account a
  UNION ALL
  SELECT up.tenant_id, up.account_id, p.parent_id, (p.level - 1)::smallint
    FROM up JOIN ledger.account p ON p.tenant_id = up.tenant_id AND p.id = up.ancestor_id
   WHERE p.parent_id IS NOT NULL
)
SELECT tenant_id, account_id, ancestor_id, ancestor_level FROM up;

-- تراز در سطح دلخواه (گروه/کل/معین/...): برگ‌های عمیق‌تر به نیای آن سطح جمع می‌شوند
CREATE OR REPLACE FUNCTION ledger.trial_balance_rollup(p_company_id uuid, p_from date, p_to date, p_level smallint,
                                                       p_include_closing boolean DEFAULT false)
RETURNS TABLE (account_id uuid, code text, name text, open_debit numeric, open_credit numeric, period_debit numeric, period_credit numeric)
LANGUAGE sql STABLE AS $$
  WITH tb AS (SELECT * FROM ledger.trial_balance(p_company_id, p_from, p_to, p_include_closing)),
  m AS (
    SELECT tb.*, COALESCE(lg.ancestor_id, tb.account_id) AS target
      FROM tb LEFT JOIN ledger.v_account_lineage lg ON lg.account_id = tb.account_id AND lg.ancestor_level = p_level
  )
  SELECT a.id, a.code, a.name, sum(m.open_debit), sum(m.open_credit), sum(m.period_debit), sum(m.period_credit)
    FROM m JOIN ledger.account a ON a.id = m.target
   GROUP BY a.id, a.code, a.name
$$;

-- تراز کل باید صفر باشد: ردیف خروجی = ناترازی (خالی = درست)
CREATE OR REPLACE FUNCTION ledger.check_trial_balance(p_company_id uuid, p_fiscal_year_id uuid)
RETURNS TABLE (period_id uuid, source text, total_debit numeric, total_credit numeric)
LANGUAGE sql STABLE AS $$
  SELECT l.period_id, 'lines', sum(l.debit_base), sum(l.credit_base) FROM ledger.journal_line l
   WHERE l.company_id = p_company_id AND l.fiscal_year_id = p_fiscal_year_id
   GROUP BY l.period_id HAVING sum(l.debit_base) <> sum(l.credit_base)
  UNION ALL
  SELECT b.period_id, 'buckets', sum(b.debit_base), sum(b.credit_base) FROM ledger.balance_bucket b
   WHERE b.company_id = p_company_id AND b.fiscal_year_id = p_fiscal_year_id
   GROUP BY b.period_id HAVING sum(b.debit_base) <> sum(b.credit_base)
  UNION ALL
  SELECT NULL, 'memo', sum(l.debit_base), sum(l.credit_base) FROM ledger.journal_line l
   WHERE l.company_id = p_company_id AND l.fiscal_year_id = p_fiscal_year_id AND l.is_memo
  HAVING sum(l.debit_base) <> sum(l.credit_base)
$$;

-- زنجیرهٔ سندهای دائم و پیوستگی شماره‌ها (خالی = سالم)
CREATE OR REPLACE FUNCTION ledger.verify_permanent_chain(p_fiscal_year_id uuid)
RETURNS TABLE (permanent_no integer, problem text)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
DECLARE fy ledger.fiscal_year; j ledger.journal; v_prev bytea; v_expected integer := 1;
BEGIN
  SELECT * INTO fy FROM ledger.fiscal_year WHERE id = p_fiscal_year_id;
  v_prev := ledger.chain_genesis(fy.company_id, fy.id);
  FOR j IN SELECT * FROM ledger.journal x WHERE x.company_id = fy.company_id AND x.fiscal_year_id = fy.id AND x.status = 'permanent'
            ORDER BY x.permanent_no LOOP
    IF j.permanent_no <> v_expected THEN
      permanent_no := v_expected; problem := 'gap'; RETURN NEXT; v_expected := j.permanent_no;
    END IF;
    IF j.chain_prev_hash IS DISTINCT FROM v_prev THEN
      permanent_no := j.permanent_no; problem := 'broken_link'; RETURN NEXT;
    END IF;
    IF j.chain_hash IS DISTINCT FROM sha256(j.chain_prev_hash || convert_to(ledger.journal_canonical(j), 'UTF8')) THEN
      permanent_no := j.permanent_no; problem := 'content_hash_mismatch'; RETURN NEXT;
    END IF;
    v_prev := j.chain_hash; v_expected := v_expected + 1;
  END LOOP;
  IF fy.last_permanent_no <> v_expected - 1 OR (fy.last_permanent_no > 0 AND fy.chain_head_hash IS DISTINCT FROM v_prev) THEN
    permanent_no := fy.last_permanent_no; problem := 'head_mismatch'; RETURN NEXT;
  END IF;
END $$;

-- تطبیق حساب‌های کنترلی با زیردفترهای ثبت‌شده (خالی = برابر)
CREATE OR REPLACE FUNCTION ledger.check_control_accounts(p_company_id uuid, p_as_of date)
RETURNS TABLE (subledger_kind text, account_id uuid, dim_value_id uuid, currency char(3),
               gl_base numeric, sub_base numeric, gl_txn numeric, sub_txn numeric)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
DECLARE s ledger.subledger_source; fy ledger.fiscal_year; v_dim text;
BEGIN
  SELECT * INTO fy FROM ledger.fiscal_year f WHERE f.company_id = p_company_id AND p_as_of BETWEEN f.start_date AND f.end_date;
  IF NOT FOUND THEN PERFORM ledger.raise_error('HK_LEDGER_NO_FISCAL_YEAR', 'no fiscal year contains the date'); END IF;
  FOR s IN SELECT * FROM ledger.subledger_source ORDER BY subledger_kind LOOP
    IF to_regprocedure(s.balance_function || '(uuid,date)') IS NULL THEN
      RETURN QUERY SELECT s.subledger_kind, a.id, NULL::uuid, NULL::char(3), NULL::numeric, NULL::numeric, NULL::numeric, NULL::numeric
                     FROM ledger.account a WHERE a.company_id = p_company_id AND a.subledger_kind = s.subledger_kind;
      CONTINUE;
    END IF;
    v_dim := CASE WHEN s.dim_slot IS NULL THEN 'NULL::uuid'
                  ELSE format('(SELECT COALESCE(dv.merged_into_id, dv.id) FROM ledger.dimension_value dv WHERE dv.tenant_id = l.tenant_id AND dv.id = l.dim%s_id)', s.dim_slot) END;
    RETURN QUERY EXECUTE format($q$
      WITH gl AS (
        SELECT l.account_id AS acc, %1$s AS dim, l.currency AS cur,
               sum(l.debit_base - l.credit_base) AS base, sum(l.debit_txn - l.credit_txn) AS txn
          FROM ledger.journal_line l
          JOIN ledger.account a ON a.tenant_id = l.tenant_id AND a.id = l.account_id
          JOIN ledger.journal j ON j.tenant_id = l.tenant_id AND j.id = l.journal_id
          JOIN ledger.journal_type jt ON jt.code = j.journal_type
         WHERE l.company_id = $1 AND l.fiscal_year_id = $3 AND l.journal_date <= $2 AND a.subledger_kind = $4
           AND l.entry_class <> 'closing' AND NOT jt.excluded_from_subledger_check
         GROUP BY 1, 2, 3
      ), sub AS (
        SELECT x.account_id AS acc, x.dim_value_id AS dim, x.currency AS cur, sum(x.balance_base) AS base, sum(x.balance_txn) AS txn
          FROM %2$s($1, $2) x GROUP BY 1, 2, 3
      )
      SELECT $4::text, COALESCE(gl.acc, sub.acc), COALESCE(gl.dim, sub.dim), COALESCE(gl.cur, sub.cur)::char(3),
             gl.base, sub.base, gl.txn, sub.txn
        FROM gl FULL JOIN sub ON gl.acc = sub.acc AND gl.dim IS NOT DISTINCT FROM sub.dim AND gl.cur = sub.cur
       WHERE COALESCE(gl.base, 0) <> COALESCE(sub.base, 0)
          OR ($5 AND COALESCE(gl.txn, 0) <> COALESCE(sub.txn, 0))
    $q$, v_dim, s.balance_function)
    USING p_company_id, p_as_of, fy.id, s.subledger_kind, s.compare_txn;
  END LOOP;
END $$;

-- بستن سال: حساب‌های موقت صفر، همهٔ حساب‌ها پس از اختتامیه صفر، افتتاحیهٔ سال بعد = قرینهٔ اختتامیه
CREATE OR REPLACE FUNCTION ledger.check_year_close(p_fiscal_year_id uuid)
RETURNS TABLE (problem text, account_id uuid, amount numeric)
LANGUAGE sql STABLE AS $$
  WITH fy AS (SELECT * FROM ledger.fiscal_year WHERE id = p_fiscal_year_id),
  nxt AS (SELECT n.* FROM ledger.fiscal_year n JOIN fy ON n.previous_year_id = fy.id),
  bal AS (
    SELECT l.account_id, a.account_type, sum(l.debit_base - l.credit_base) AS b,
           sum(l.debit_base - l.credit_base) FILTER (WHERE l.entry_class <> 'closing'
              OR j.journal_type IN ('closing_pl','closing_re')) AS b_before_balance_close
      FROM ledger.journal_line l JOIN fy ON l.fiscal_year_id = fy.id
      JOIN ledger.account a ON a.tenant_id = l.tenant_id AND a.id = l.account_id
      JOIN ledger.journal j ON j.tenant_id = l.tenant_id AND j.id = l.journal_id
     GROUP BY l.account_id, a.account_type
  ),
  close_bal AS (
    SELECT l.account_id, l.branch_id, l.dim1_id, l.dim2_id, l.dim3_id, l.dim4_id, l.dim5_id, l.dim6_id, l.currency,
           sum(l.debit_base - l.credit_base) AS b, sum(l.debit_txn - l.credit_txn) AS t
      FROM ledger.journal_line l JOIN fy ON l.fiscal_year_id = fy.id
      JOIN ledger.journal j ON j.tenant_id = l.tenant_id AND j.id = l.journal_id
     WHERE j.journal_type = 'closing_balance' AND j.status <> 'voided'
     GROUP BY 1,2,3,4,5,6,7,8,9
  ),
  open_bal AS (
    SELECT l.account_id, l.branch_id, l.dim1_id, l.dim2_id, l.dim3_id, l.dim4_id, l.dim5_id, l.dim6_id, l.currency,
           sum(l.debit_base - l.credit_base) AS b, sum(l.debit_txn - l.credit_txn) AS t
      FROM ledger.journal_line l JOIN nxt ON l.fiscal_year_id = nxt.id
      JOIN ledger.journal j ON j.tenant_id = l.tenant_id AND j.id = l.journal_id
     WHERE j.journal_type = 'opening' AND j.status <> 'voided'
     GROUP BY 1,2,3,4,5,6,7,8,9
  )
  SELECT 'temporary_account_not_closed', bal.account_id, bal.b_before_balance_close FROM bal
   WHERE bal.account_type IN ('income','expense') AND COALESCE(bal.b_before_balance_close, 0) <> 0
  UNION ALL
  SELECT 'balance_not_closed', bal.account_id, bal.b FROM bal WHERE bal.b <> 0
  UNION ALL
  SELECT 'opening_mismatch', COALESCE(c.account_id, o.account_id), COALESCE(c.b, 0) + COALESCE(o.b, 0)
    FROM close_bal c FULL JOIN open_bal o
      ON c.account_id = o.account_id AND c.currency = o.currency AND c.branch_id IS NOT DISTINCT FROM o.branch_id
     AND c.dim1_id IS NOT DISTINCT FROM o.dim1_id AND c.dim2_id IS NOT DISTINCT FROM o.dim2_id
     AND c.dim3_id IS NOT DISTINCT FROM o.dim3_id AND c.dim4_id IS NOT DISTINCT FROM o.dim4_id
     AND c.dim5_id IS NOT DISTINCT FROM o.dim5_id AND c.dim6_id IS NOT DISTINCT FROM o.dim6_id
   WHERE EXISTS (SELECT 1 FROM nxt) AND (COALESCE(c.b, 0) + COALESCE(o.b, 0) <> 0 OR COALESCE(c.t, 0) + COALESCE(o.t, 0) <> 0)
$$;

-- انطباق حساب با انتخاب‌گر ردیف قالب گزارش
CREATE OR REPLACE FUNCTION ledger.account_matches(a ledger.account, sel jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT NOT (a.tags && COALESCE(ARRAY(SELECT jsonb_array_elements_text(sel->'exclude_tags')), '{}'))
     AND (   a.tags && COALESCE(ARRAY(SELECT jsonb_array_elements_text(sel->'tags_any')), '{}')
          OR COALESCE(a.role = ANY (ARRAY(SELECT jsonb_array_elements_text(sel->'roles'))), false)
          OR a.account_type = ANY (COALESCE(ARRAY(SELECT jsonb_array_elements_text(sel->'account_types')), '{}'))
          OR EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(sel->'code_ranges', '[]')) r
                      WHERE a.code BETWEEN r->>0 AND r->>1))
$$;

-- نگاشت حساب‌های برگ به ردیف‌های قالب (با اولویت نگاشت صریح شرکت)
CREATE OR REPLACE FUNCTION ledger.report_row_accounts(p_company_id uuid, p_template_code text, p_version integer)
RETURNS TABLE (row_code text, account_id uuid)
LANGUAGE sql STABLE AS $$
  SELECT m.row_code, m.account_id FROM ledger.report_account_map m
   WHERE m.company_id = p_company_id AND m.template_code = p_template_code AND m.template_version = p_version
  UNION ALL
  SELECT r.row_code, a.id
    FROM ledger.report_template_row r
    JOIN ledger.account a ON a.company_id = p_company_id AND a.kind = 'posting'
   WHERE r.template_code = p_template_code AND r.template_version = p_version AND r.row_type = 'accounts'
     AND ledger.account_matches(a, r.selector)
     AND NOT EXISTS (SELECT 1 FROM ledger.report_account_map m WHERE m.company_id = p_company_id
                       AND m.template_code = p_template_code AND m.template_version = p_version AND m.account_id = a.id)
$$;

-- پوشش قالب‌ها: هر حساب برگ غیرانتظامی دقیقاً یک بار در ردیف‌های «accounts» با مبنای غیر از opening
CREATE OR REPLACE FUNCTION ledger.report_coverage(p_company_id uuid, p_templates text[], p_versions integer[])
RETURNS TABLE (account_id uuid, code text, problem text, row_codes text[])
LANGUAGE sql STABLE AS $$
  WITH t AS (SELECT unnest(p_templates) AS code, unnest(p_versions) AS version),
  hits AS (
    SELECT ra.account_id, t.code || ':' || ra.row_code AS rc
      FROM t CROSS JOIN LATERAL ledger.report_row_accounts(p_company_id, t.code, t.version) ra
      JOIN ledger.report_template_row r ON r.template_code = t.code AND r.template_version = t.version AND r.row_code = ra.row_code
     WHERE r.balance_basis <> 'opening'
  )
  SELECT a.id, a.code, CASE WHEN count(h.rc) = 0 THEN 'unmapped' ELSE 'multi_mapped' END, array_remove(array_agg(h.rc), NULL)
    FROM ledger.account a LEFT JOIN hits h ON h.account_id = a.id
   WHERE a.company_id = p_company_id AND a.kind = 'posting' AND a.account_type <> 'memo'
   GROUP BY a.id, a.code
  HAVING count(h.rc) <> 1
$$;

-- ارزیابی قالب صورت مالی؛ مقدار هر ردیف = sign × Σ(بدهکار − بستانکار) با مبنای ردیف
CREATE OR REPLACE FUNCTION ledger.evaluate_statement(p_company_id uuid, p_template_code text, p_version integer,
                                                     p_from date, p_to date, p_include_closing boolean DEFAULT false)
RETURNS TABLE (row_code text, sort_order integer, label_fa text, value numeric, is_check_row boolean)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
DECLARE r ledger.report_template_row; vals jsonb := '{}'; v numeric; term text[]; v_term numeric; v_tb jsonb;
BEGIN
  -- تراز یک‌باره: account_id → {o: ماندهٔ ابتدا, p: خالص طی دوره, t: نوع حساب}
  SELECT COALESCE(jsonb_object_agg(tb.account_id::text,
           jsonb_build_object('o', tb.open_debit - tb.open_credit, 'p', tb.period_debit - tb.period_credit, 't', a.account_type)), '{}')
    INTO v_tb
    FROM ledger.trial_balance(p_company_id, p_from, p_to, p_include_closing) tb
    JOIN ledger.account a ON a.id = tb.account_id;
  FOR r IN SELECT * FROM ledger.report_template_row x WHERE x.template_code = p_template_code AND x.template_version = p_version
            ORDER BY x.sort_order LOOP
    v := NULL;
    IF r.row_type IN ('accounts','pl_result') THEN
      SELECT COALESCE(sum(CASE r.balance_basis
                            WHEN 'closing'    THEN (e.value->>'o')::numeric + (e.value->>'p')::numeric
                            WHEN 'opening'    THEN (e.value->>'o')::numeric
                            ELSE (e.value->>'p')::numeric END), 0) * r.sign
        INTO v
        FROM jsonb_each(v_tb) e
       WHERE (r.row_type = 'pl_result' AND e.value->>'t' IN ('income','expense'))
          OR (r.row_type = 'accounts' AND e.key::uuid IN (
                SELECT ra.account_id FROM ledger.report_row_accounts(p_company_id, p_template_code, p_version) ra
                 WHERE ra.row_code = r.row_code));
    ELSIF r.row_type = 'formula' THEN
      v := 0;
      FOR term IN SELECT regexp_matches(regexp_replace(r.formula, '\s', '', 'g'), '([+-]?)([A-Z][A-Z0-9_]*)', 'g') LOOP
        IF NOT vals ? term[2] THEN
          PERFORM ledger.raise_error('HK_LEDGER_TEMPLATE_FORMULA', format('row %s references %s before it is computed', r.row_code, term[2]));
        END IF;
        v_term := (vals ->> term[2])::numeric;
        v := v + CASE WHEN term[1] = '-' THEN -v_term ELSE v_term END;
      END LOOP;
    END IF;
    IF v IS NOT NULL THEN vals := vals || jsonb_build_object(r.row_code, v); END IF;
    row_code := r.row_code; sort_order := r.sort_order; label_fa := r.label_fa; value := v; is_check_row := r.is_check_row;
    RETURN NEXT;
  END LOOP;
END $$;

-- =====================================================================
-- ۱۸. ویوهای منتشرشده (security_invoker)
-- =====================================================================
CREATE OR REPLACE VIEW ledger.v_journal_line WITH (security_invoker = true) AS
SELECT l.tenant_id, l.id AS line_id, l.journal_id, l.line_no, l.company_id, l.fiscal_year_id, l.period_id, l.journal_date,
       l.entry_class, j.journal_type, j.status, j.reference_no, j.reference_text, j.permanent_no, j.daily_no,
       j.description AS journal_description, j.source_module, j.source_doc_type, j.source_doc_id, j.source_doc_no,
       (EXISTS (SELECT 1 FROM ledger.journal r WHERE r.tenant_id = j.tenant_id AND r.reversal_of_journal_id = j.id
                  AND r.status <> 'voided')) AS is_reversed,
       l.account_id, a.code AS account_code, a.name AS account_name, a.account_type, l.is_memo,
       l.branch_id, l.dim1_id, l.dim2_id, l.dim3_id, l.dim4_id, l.dim5_id, l.dim6_id,
       l.currency, l.exchange_rate, l.debit_txn, l.credit_txn, l.debit_base, l.credit_base, l.line_kind,
       l.quantity, l.description, l.source_line_ref
  FROM ledger.journal_line l
  JOIN ledger.journal j ON j.tenant_id = l.tenant_id AND j.id = l.journal_id
  JOIN ledger.account a ON a.tenant_id = l.tenant_id AND a.id = l.account_id;

-- مقدار مؤثر بعد پس از ادغام (برای گزارش و تطبیق)
CREATE OR REPLACE VIEW ledger.v_dimension_effective WITH (security_invoker = true) AS
SELECT v.tenant_id, v.id AS dim_value_id, COALESCE(v.merged_into_id, v.id) AS effective_id
  FROM ledger.dimension_value v;

CREATE OR REPLACE VIEW ledger.v_period_balance WITH (security_invoker = true) AS
SELECT tenant_id, company_id, fiscal_year_id, period_id, account_id, entry_class, branch_id,
       dim1_id, dim2_id, dim3_id, dim4_id, dim5_id, dim6_id, currency,
       sum(debit_base) AS debit_base, sum(credit_base) AS credit_base,
       sum(debit_txn) AS debit_txn, sum(credit_txn) AS credit_txn, sum(line_count) AS line_count
  FROM ledger.balance_bucket
 GROUP BY tenant_id, company_id, fiscal_year_id, period_id, account_id, entry_class, branch_id,
          dim1_id, dim2_id, dim3_id, dim4_id, dim5_id, dim6_id, currency;

-- =====================================================================
-- ۱۹. دسترسی‌ها
-- =====================================================================
GRANT SELECT ON ledger.journal_type, ledger.posting_key, ledger.dimension_type_catalog, ledger.coa_template,
                ledger.coa_template_account, ledger.coa_template_posting_rule, ledger.subledger_source,
                ledger.report_template, ledger.report_template_row TO hk_app, hk_readonly;

GRANT SELECT, INSERT, UPDATE, DELETE ON ledger.rate_type, ledger.company_config, ledger.coa_level, ledger.dimension_type,
      ledger.dimension_value, ledger.account, ledger.account_dimension_rule, ledger.exchange_rate, ledger.posting_rule,
      ledger.journal_draft, ledger.journal_draft_line, ledger.recurring_journal, ledger.recurring_journal_line,
      ledger.report_account_map TO hk_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ledger.fiscal_year, ledger.fiscal_period TO hk_app;
GRANT SELECT, INSERT, DELETE ON ledger.period_module_lock TO hk_app;
GRANT SELECT, INSERT ON ledger.period_status_event, ledger.journal_line, ledger.integrity_run TO hk_app;
GRANT SELECT, INSERT ON ledger.journal TO hk_app;
GRANT UPDATE (status, permanent_no, daily_no, finalized_at, finalized_by, chain_prev_hash, chain_hash,
              reviewed_at, reviewed_by, void_reason) ON ledger.journal TO hk_app;
GRANT SELECT, INSERT, UPDATE ON ledger.year_close_run, ledger.fx_revaluation_run, ledger.eledger_export TO hk_app;
GRANT SELECT ON ledger.balance_bucket TO hk_app;
GRANT SELECT ON ledger.v_journal_line, ledger.v_period_balance, ledger.v_account_lineage, ledger.v_dimension_effective TO hk_app, hk_readonly;

GRANT SELECT ON ALL TABLES IN SCHEMA ledger TO hk_readonly;

-- نقش definer فقط آنچه سطل‌ها لازم دارند
GRANT SELECT, INSERT, DELETE ON ledger.balance_bucket TO hk_ledger_definer;
GRANT SELECT ON ledger.journal_line TO hk_ledger_definer;

REVOKE ALL ON FUNCTION ledger.compact_balance_buckets(uuid, uuid), ledger.rebuild_balance_buckets(uuid, uuid),
                       ledger.bucket_from_lines() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ledger.compact_balance_buckets(uuid, uuid), ledger.rebuild_balance_buckets(uuid, uuid) TO hk_app;

-- =====================================================================
-- ۲۰. دادهٔ کاتالوگ
-- =====================================================================
INSERT INTO ledger.journal_type (code, entry_class, class_rank, origin, skip_line_rules, bypass_posting_policy, allows_base_only_lines,
                                 requires_input_unit, excluded_from_subledger_check, name_fa, introduced_in) VALUES
  ('manual',                  'regular', 1, 'manual', false, false, false, false, false, 'سند دستی', '1.0'),
  ('adjustment',              'regular', 1, 'manual', false, false, false, false, false, 'سند اصلاحی', '1.0'),
  ('prior_period_adjustment', 'regular', 1, 'manual', false, false, false, false, false, 'تعدیلات سنواتی', '1.0'),
  ('recurring',               'regular', 1, 'manual', false, false, false, false, false, 'سند تکرارشونده', '1.0'),
  ('module',                  'regular', 1, 'module', false, false, false, false, false, 'سند خودکار ماژول', '1.0'),
  ('fx_revaluation',          'regular', 1, 'system', false, true,  true,  false, true,  'تسعیر ارز', '1.0'),
  ('fx_revaluation_reversal', 'regular', 1, 'mirror', true,  true,  true,  false, true,  'برگشت تسعیر ارز', '1.0'),
  ('reversal',                'regular', 1, 'mirror', true,  true,  true,  false, false, 'سند برگشت (معکوس)', '1.0'),
  ('void',                    'regular', 1, 'mirror', true,  true,  true,  false, false, 'ابطال سند موقت', '1.0'),
  ('opening',                 'opening', 0, 'system', true,  true,  true,  false, false, 'سند افتتاحیه', '1.0'),
  ('opening_import',          'opening', 0, 'import', false, false, false, true,  false, 'افتتاحیهٔ ورودی (انتقال داده)', '1.0'),
  ('history_import',          'regular', 1, 'import', false, false, false, true,  false, 'سند منتقل‌شده از نرم‌افزار قبلی', '1.0'),
  ('closing_pl',              'closing', 2, 'system', true,  true,  true,  false, false, 'بستن حساب‌های موقت', '1.0'),
  ('closing_re',              'closing', 2, 'system', true,  true,  true,  false, false, 'انتقال سود و زیان به سود انباشته', '1.0'),
  ('closing_balance',         'closing', 2, 'system', true,  true,  true,  false, false, 'سند اختتامیه', '1.0')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ledger.dimension_type_catalog (code, slot, owner_module, is_hierarchical, name_fa, introduced_in) VALUES
  ('party',        1, 'parties',  false, 'اشخاص',              '1.0'),
  ('bank_account', 1, 'treasury', false, 'حساب بانکی',          '1.0'),
  ('cash_box',     1, 'treasury', false, 'صندوق',               '1.0'),
  ('petty_cash',   1, 'treasury', false, 'تنخواه‌گردان',          '1.0'),
  ('pos_terminal', 1, 'treasury', false, 'پایانهٔ کارتخوان',     '1.0'),
  ('employee',     1, 'payroll',  false, 'کارکنان',             '1.0'),
  ('fixed_asset',  1, 'assets',   false, 'دارایی ثابت',         '1.0'),
  ('cost_center',  2, 'ledger',   true,  'مرکز هزینه',          '1.0'),
  ('project',      3, 'ledger',   true,  'پروژه',               '1.0')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ledger.posting_key (key, owner_module, expected_account_types, is_required, name_fa, introduced_in) VALUES
  ('ledger.rounding',                  'ledger',    '{expense,income}',   true,  'تفاوت گرد کردن', '1.0'),
  ('ledger.fx.unrealized_gain',        'ledger',    '{income}',           false, 'سود تسعیر تحقق‌نیافته', '1.0'),
  ('ledger.fx.unrealized_loss',        'ledger',    '{expense}',          false, 'زیان تسعیر تحقق‌نیافته', '1.0'),
  ('ledger.fx.realized_gain',          'ledger',    '{income}',           false, 'سود تسعیر تحقق‌یافته', '1.0'),
  ('ledger.fx.realized_loss',          'ledger',    '{expense}',          false, 'زیان تسعیر تحقق‌یافته', '1.0'),
  ('ledger.income_summary',            'ledger',    '{equity}',           true,  'خلاصهٔ سود و زیان', '1.0'),
  ('ledger.retained_earnings',         'ledger',    '{equity}',           true,  'سود (زیان) انباشته', '1.0'),
  ('ledger.prior_period_adjustment',   'ledger',    '{equity}',           false, 'تعدیلات سنواتی', '1.0'),
  ('ledger.opening_balance_clearing',  'ledger',    '{asset,liability,equity}', false, 'حساب تراز افتتاحیه', '1.0'),
  ('ledger.suspense',                  'ledger',    '{asset,liability}',  false, 'حساب معلق', '1.0'),
  ('sales.revenue',                    'sales',     '{income}',           false, 'فروش', '1.0'),
  ('sales.returns',                    'sales',     '{income}',           false, 'برگشت از فروش', '1.0'),
  ('sales.discount',                   'sales',     '{income}',           false, 'تخفیفات فروش', '1.0'),
  ('sales.receivable',                 'sales',     '{asset}',            false, 'حساب‌های دریافتنی', '1.0'),
  ('sales.customer_advance',           'sales',     '{liability}',        false, 'پیش‌دریافت از مشتری', '1.0'),
  ('purchase.payable',                 'purchase',  '{liability}',        false, 'حساب‌های پرداختنی', '1.0'),
  ('purchase.supplier_advance',        'purchase',  '{asset}',            false, 'پیش‌پرداخت به تأمین‌کننده', '1.0'),
  ('purchase.expense',                 'purchase',  '{expense,asset}',    false, 'خرید خدمات/هزینه', '1.0'),
  ('tax.vat_payable',                  'tax',       '{liability}',        false, 'مالیات بر ارزش افزودهٔ فروش', '1.0'),
  ('tax.vat_receivable',               'tax',       '{asset}',            false, 'مالیات بر ارزش افزودهٔ خرید', '1.0'),
  ('inventory.asset',                  'inventory', '{asset}',            false, 'موجودی کالا', '1.0'),
  ('inventory.cogs',                   'inventory', '{expense}',          false, 'بهای تمام‌شدهٔ کالای فروش‌رفته', '1.0'),
  ('inventory.adjustment',             'inventory', '{expense,income}',   false, 'کسری و اضافی انبار', '1.0'),
  ('inventory.goods_in_transit',       'inventory', '{asset}',            false, 'کالای در راه', '1.0'),
  ('treasury.cash',                    'treasury',  '{asset}',            false, 'صندوق', '1.0'),
  ('treasury.bank',                    'treasury',  '{asset}',            false, 'بانک', '1.0'),
  ('treasury.petty_cash',              'treasury',  '{asset}',            false, 'تنخواه‌گردان', '1.0'),
  ('treasury.card_clearing',           'treasury',  '{asset}',            false, 'واسط کارتخوان', '1.0'),
  ('treasury.cheque_receivable',       'treasury',  '{asset}',            false, 'اسناد دریافتنی', '1.0'),
  ('treasury.cheque_in_collection',    'treasury',  '{asset}',            false, 'چک‌های در جریان وصول', '1.0'),
  ('treasury.cheque_payable',          'treasury',  '{liability}',        false, 'اسناد پرداختنی', '1.0'),
  ('treasury.bank_fee',                'treasury',  '{expense}',          false, 'کارمزد بانکی', '1.0'),
  ('treasury.guarantee_received',      'treasury',  '{memo}',             false, 'اسناد تضمینی دریافتی', '1.0'),
  ('treasury.guarantee_received_contra','treasury', '{memo}',             false, 'طرف اسناد تضمینی دریافتی', '1.0'),
  ('treasury.guarantee_given',         'treasury',  '{memo}',             false, 'اسناد تضمینی پرداختی', '1.0'),
  ('treasury.guarantee_given_contra',  'treasury',  '{memo}',             false, 'طرف اسناد تضمینی پرداختی', '1.0'),
  ('assets.cost',                      'assets',    '{asset}',            false, 'بهای تمام‌شدهٔ دارایی ثابت', '1.0'),
  ('assets.accumulated_depreciation',  'assets',    '{asset}',            false, 'استهلاک انباشته', '1.0'),
  ('assets.depreciation_expense',      'assets',    '{expense}',          false, 'هزینهٔ استهلاک', '1.0'),
  ('payroll.salary_expense',           'payroll',   '{expense}',          false, 'هزینهٔ حقوق و دستمزد', '1.0'),
  ('payroll.salary_payable',           'payroll',   '{liability}',        false, 'حقوق پرداختنی', '1.0'),
  ('payroll.insurance_payable',        'payroll',   '{liability}',        false, 'حق بیمهٔ پرداختنی', '1.0'),
  ('payroll.tax_payable',              'payroll',   '{liability}',        false, 'مالیات حقوق پرداختنی', '1.0'),
  ('payroll.employer_insurance_expense','payroll',   '{expense}',          false, 'حق بیمهٔ سهم کارفرما', '1.0')
ON CONFLICT (key) DO NOTHING;

-- ---------- قالب کدینگ عمومی (نمونهٔ v1؛ پیش از انتشار تولیدی باید حسابدار رسمی بازبینی کند) ----------
INSERT INTO ledger.coa_template (code, version, industry_pack, name_fa, code_mode, levels, source, confidence) VALUES
  ('ir.general', 1, 'general', 'کدینگ عمومی کسب‌وکارهای کوچک و متوسط', 'hierarchical',
   '[{"level":1,"name_fa":"گروه","segment_length":1},{"level":2,"name_fa":"کل","segment_length":1},{"level":3,"name_fa":"معین","segment_length":2}]',
   'design sample (docs/design/03-ledger.md §4); requires accountant review', 'low')
ON CONFLICT DO NOTHING;

INSERT INTO ledger.coa_template_account (template_code, template_version, code, parent_code, level, name_fa, kind, account_type, nature,
       role, tags, posting_policy, allowed_source_modules, subledger_kind, currency_policy, revalue_fx, dimension_rules)
SELECT 'ir.general', 1, v.code, v.parent, v.lvl, v.name, v.kind, v.atype, v.nature, v.role, v.tags::text[], v.policy,
       v.mods::text[], v.subledger, v.cur, v.reval, v.dims::jsonb
FROM (VALUES
  ('1',    NULL, 1, 'دارایی‌های جاری',                'group',   'asset', 'debit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('11',   '1',  2, 'موجودی نقد',                     'group',   'asset', 'debit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('1101', '11', 3, 'صندوق',                          'posting', 'asset', 'debit', 'CASH', '{bs.ca.cash}', 'open', '{}', NULL, 'any', true, '{"cash_box":"required"}'),
  ('1102', '11', 3, 'بانک‌ها',                         'posting', 'asset', 'debit', 'BANK', '{bs.ca.cash}', 'open', '{}', NULL, 'any', true, '{"bank_account":"required"}'),
  ('1103', '11', 3, 'تنخواه‌گردان',                    'posting', 'asset', 'debit', 'PETTY_CASH', '{bs.ca.cash}', 'open', '{}', NULL, 'base_only', false, '{"petty_cash":"required"}'),
  ('12',   '1',  2, 'دریافتنی‌های تجاری',              'group',   'asset', 'debit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('1201', '12', 3, 'حساب‌های دریافتنی تجاری',         'posting', 'asset', 'debit', 'AR_TRADE', '{bs.ca.trade_receivables}', 'open', '{}', 'party', 'any', true, '{"party":"required","project":"optional"}'),
  ('1202', '12', 3, 'اسناد دریافتنی',                  'posting', 'asset', 'debit', 'NOTES_RECEIVABLE', '{bs.ca.trade_receivables}', 'subledger_only', '{treasury,migration}', 'cheque_receivable', 'base_only', false, '{"party":"required"}'),
  ('1203', '12', 3, 'چک‌های در جریان وصول',            'posting', 'asset', 'debit', 'CHEQUES_IN_COLLECTION', '{bs.ca.trade_receivables}', 'subledger_only', '{treasury,migration}', 'cheque_receivable', 'base_only', false, '{"bank_account":"required"}'),
  ('13',   '1',  2, 'سایر دریافتنی‌ها',                'group',   'asset', 'debit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('1301', '13', 3, 'سایر حساب‌های دریافتنی',          'posting', 'asset', 'debit', NULL, '{bs.ca.other_receivables}', 'open', '{}', NULL, 'base_only', false, '{"party":"required"}'),
  ('1302', '13', 3, 'مالیات بر ارزش افزودهٔ خرید',     'posting', 'asset', 'debit', 'VAT_RECEIVABLE', '{bs.ca.other_receivables}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('1303', '13', 3, 'حساب واسط کارتخوان',             'posting', 'asset', 'debit', 'CARD_CLEARING', '{bs.ca.other_receivables}', 'open', '{}', NULL, 'base_only', false, '{"pos_terminal":"required"}'),
  ('1304', '13', 3, 'حساب تراز افتتاحیه',             'posting', 'asset', 'none',  'OPENING_BALANCE_CLEARING', '{bs.ca.other_receivables}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('14',   '1',  2, 'موجودی مواد و کالا',              'group',   'asset', 'debit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('1401', '14', 3, 'موجودی کالا',                    'posting', 'asset', 'debit', 'INVENTORY', '{bs.ca.inventory}', 'subledger_only', '{inventory,migration}', 'inventory', 'base_only', false, '{}'),
  ('1402', '14', 3, 'کالای در راه',                   'posting', 'asset', 'debit', 'GOODS_IN_TRANSIT', '{bs.ca.inventory}', 'open', '{}', NULL, 'base_only', false, '{"party":"optional"}'),
  ('15',   '1',  2, 'پیش‌پرداخت‌ها',                    'group',   'asset', 'debit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('1501', '15', 3, 'پیش‌پرداخت خرید',                 'posting', 'asset', 'debit', 'PREPAYMENTS', '{bs.ca.prepayments}', 'open', '{}', NULL, 'any', true, '{"party":"required"}'),
  ('2',    NULL, 1, 'دارایی‌های غیرجاری',              'group',   'asset', 'debit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('21',   '2',  2, 'دارایی‌های ثابت مشهود',           'group',   'asset', 'debit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('2101', '21', 3, 'ساختمان',                        'posting', 'asset', 'debit', 'FIXED_ASSET_COST', '{bs.nca.ppe_cost}', 'subledger_only', '{assets,migration}', 'fixed_asset', 'base_only', false, '{"fixed_asset":"required"}'),
  ('2102', '21', 3, 'اثاثه و منصوبات',                'posting', 'asset', 'debit', 'FIXED_ASSET_COST', '{bs.nca.ppe_cost}', 'subledger_only', '{assets,migration}', 'fixed_asset', 'base_only', false, '{"fixed_asset":"required"}'),
  ('2103', '21', 3, 'وسایل نقلیه',                    'posting', 'asset', 'debit', 'FIXED_ASSET_COST', '{bs.nca.ppe_cost}', 'subledger_only', '{assets,migration}', 'fixed_asset', 'base_only', false, '{"fixed_asset":"required"}'),
  ('2190', '21', 3, 'استهلاک انباشته',                'posting', 'asset', 'credit', 'ACCUMULATED_DEPRECIATION', '{bs.nca.ppe_accdep}', 'subledger_only', '{assets,migration}', 'fixed_asset', 'base_only', false, '{"fixed_asset":"required"}'),
  ('22',   '2',  2, 'دارایی‌های نامشهود',              'group',   'asset', 'debit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('2201', '22', 3, 'سرقفلی و حق کسب و پیشه',          'posting', 'asset', 'debit', NULL, '{bs.nca.intangible}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('23',   '2',  2, 'سرمایه‌گذاری‌های بلندمدت',         'group',   'asset', 'debit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('2301', '23', 3, 'سرمایه‌گذاری‌های بلندمدت',         'posting', 'asset', 'debit', NULL, '{bs.nca.investments}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('3',    NULL, 1, 'بدهی‌های جاری',                   'group',   'liability', 'credit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('31',   '3',  2, 'پرداختنی‌های تجاری',              'group',   'liability', 'credit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('3101', '31', 3, 'حساب‌های پرداختنی تجاری',         'posting', 'liability', 'credit', 'AP_TRADE', '{bs.cl.trade_payables}', 'open', '{}', 'party', 'any', true, '{"party":"required","project":"optional"}'),
  ('3102', '31', 3, 'اسناد پرداختنی',                  'posting', 'liability', 'credit', 'NOTES_PAYABLE', '{bs.cl.trade_payables}', 'subledger_only', '{treasury,migration}', 'cheque_payable', 'base_only', false, '{"party":"required"}'),
  ('32',   '3',  2, 'سایر پرداختنی‌ها',                'group',   'liability', 'credit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('3201', '32', 3, 'سایر حساب‌های پرداختنی',          'posting', 'liability', 'credit', NULL, '{bs.cl.other_payables}', 'open', '{}', NULL, 'base_only', false, '{"party":"required"}'),
  ('3202', '32', 3, 'مالیات بر ارزش افزودهٔ فروش',     'posting', 'liability', 'credit', 'VAT_PAYABLE', '{bs.cl.tax}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('3203', '32', 3, 'مالیات حقوق پرداختنی',           'posting', 'liability', 'credit', NULL, '{bs.cl.tax}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('3204', '32', 3, 'حق بیمهٔ پرداختنی',               'posting', 'liability', 'credit', NULL, '{bs.cl.other_payables}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('3205', '32', 3, 'حقوق و دستمزد پرداختنی',          'posting', 'liability', 'credit', NULL, '{bs.cl.other_payables}', 'open', '{}', NULL, 'base_only', false, '{"employee":"required"}'),
  ('33',   '3',  2, 'پیش‌دریافت‌ها',                    'group',   'liability', 'credit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('3301', '33', 3, 'پیش‌دریافت فروش',                 'posting', 'liability', 'credit', 'CUSTOMER_ADVANCES', '{bs.cl.advances}', 'open', '{}', NULL, 'any', true, '{"party":"required"}'),
  ('34',   '3',  2, 'ذخایر و تسهیلات جاری',            'group',   'liability', 'credit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('3401', '34', 3, 'ذخیرهٔ مالیات بر درآمد',          'posting', 'liability', 'credit', NULL, '{bs.cl.tax}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('3402', '34', 3, 'تسهیلات مالی کوتاه‌مدت',          'posting', 'liability', 'credit', 'LOANS', '{bs.cl.loans}', 'open', '{}', NULL, 'base_only', false, '{"bank_account":"optional"}'),
  ('4',    NULL, 1, 'بدهی‌های غیرجاری',                'group',   'liability', 'credit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('41',   '4',  2, 'بدهی‌های بلندمدت',                'group',   'liability', 'credit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('4101', '41', 3, 'تسهیلات مالی بلندمدت',            'posting', 'liability', 'credit', 'LOANS', '{bs.ncl.loans}', 'open', '{}', NULL, 'base_only', false, '{"bank_account":"optional"}'),
  ('4102', '41', 3, 'ذخیرهٔ مزایای پایان خدمت کارکنان', 'posting', 'liability', 'credit', NULL, '{bs.ncl.provisions}', 'open', '{}', NULL, 'base_only', false, '{"employee":"optional"}'),
  ('5',    NULL, 1, 'حقوق مالکانه',                    'group',   'equity', 'credit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('51',   '5',  2, 'سرمایه',                          'group',   'equity', 'credit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('5101', '51', 3, 'سرمایه',                          'posting', 'equity', 'credit', 'CAPITAL', '{bs.eq.capital}', 'open', '{}', NULL, 'base_only', false, '{"party":"optional"}'),
  ('5102', '51', 3, 'حساب جاری شرکا',                  'posting', 'equity', 'none',   'PARTNER_CURRENT', '{bs.eq.capital}', 'open', '{}', NULL, 'base_only', false, '{"party":"required"}'),
  ('52',   '5',  2, 'اندوخته‌ها',                       'group',   'equity', 'credit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('5201', '52', 3, 'اندوختهٔ قانونی',                  'posting', 'equity', 'credit', NULL, '{bs.eq.reserves}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('53',   '5',  2, 'سود (زیان) انباشته',              'group',   'equity', 'credit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('5301', '53', 3, 'سود (زیان) انباشته',              'posting', 'equity', 'none',   'RETAINED_EARNINGS', '{bs.eq.retained}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('5302', '53', 3, 'تعدیلات سنواتی',                  'posting', 'equity', 'none',   'PRIOR_PERIOD_ADJ', '{bs.eq.retained}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('5303', '53', 3, 'خلاصهٔ سود و زیان',               'posting', 'equity', 'none',   'INCOME_SUMMARY', '{bs.eq.retained}', 'system_only', '{}', NULL, 'base_only', false, '{}'),
  ('6',    NULL, 1, 'درآمدها',                          'group',   'income', 'credit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('61',   '6',  2, 'فروش',                            'group',   'income', 'credit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('6101', '61', 3, 'فروش کالا',                       'posting', 'income', 'credit', 'SALES', '{pl.revenue}', 'open', '{}', NULL, 'base_only', false, '{"cost_center":"optional","project":"optional"}'),
  ('6102', '61', 3, 'فروش خدمات',                      'posting', 'income', 'credit', 'SALES', '{pl.revenue}', 'open', '{}', NULL, 'base_only', false, '{"cost_center":"optional","project":"optional"}'),
  ('6103', '61', 3, 'برگشت از فروش',                   'posting', 'income', 'debit',  'SALES_RETURNS', '{pl.revenue_deductions}', 'open', '{}', NULL, 'base_only', false, '{"cost_center":"optional"}'),
  ('6104', '61', 3, 'تخفیفات فروش',                    'posting', 'income', 'debit',  'SALES_DISCOUNTS', '{pl.revenue_deductions}', 'open', '{}', NULL, 'base_only', false, '{"cost_center":"optional"}'),
  ('62',   '6',  2, 'سایر درآمدها',                     'group',   'income', 'credit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('6201', '62', 3, 'سود تسعیر ارز',                   'posting', 'income', 'credit', 'FX_GAIN', '{pl.other_nonop}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('6202', '62', 3, 'سایر درآمدهای غیرعملیاتی',        'posting', 'income', 'credit', 'OTHER_INCOME', '{pl.other_nonop}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('7',    NULL, 1, 'بهای تمام‌شده و هزینه‌ها',         'group',   'expense', 'debit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('71',   '7',  2, 'بهای تمام‌شدهٔ کالای فروش‌رفته',    'group',   'expense', 'debit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('7101', '71', 3, 'بهای تمام‌شدهٔ کالای فروش‌رفته',    'posting', 'expense', 'debit', 'COGS', '{pl.cogs}', 'open', '{}', NULL, 'base_only', false, '{"cost_center":"optional"}'),
  ('7102', '71', 3, 'کسری و اضافی انبار',              'posting', 'expense', 'none',  NULL, '{pl.cogs}', 'open', '{}', NULL, 'base_only', false, '{"cost_center":"optional"}'),
  ('72',   '7',  2, 'هزینه‌های عمومی، اداری و فروش',     'group',   'expense', 'debit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('7201', '72', 3, 'حقوق و دستمزد',                   'posting', 'expense', 'debit', 'EXPENSE_PAYROLL', '{pl.opex}', 'open', '{}', NULL, 'base_only', false, '{"cost_center":"optional","project":"optional"}'),
  ('7202', '72', 3, 'اجاره',                           'posting', 'expense', 'debit', 'EXPENSE_RENT', '{pl.opex}', 'open', '{}', NULL, 'base_only', false, '{"cost_center":"optional"}'),
  ('7203', '72', 3, 'آب، برق، گاز و تلفن',             'posting', 'expense', 'debit', NULL, '{pl.opex}', 'open', '{}', NULL, 'base_only', false, '{"cost_center":"optional"}'),
  ('7204', '72', 3, 'هزینهٔ استهلاک',                   'posting', 'expense', 'debit', 'EXPENSE_DEPRECIATION', '{pl.opex}', 'open', '{}', NULL, 'base_only', false, '{"cost_center":"optional"}'),
  ('7205', '72', 3, 'کارمزد بانکی',                    'posting', 'expense', 'debit', 'EXPENSE_BANK', '{pl.opex}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('7206', '72', 3, 'سایر هزینه‌ها',                    'posting', 'expense', 'debit', NULL, '{pl.opex}', 'open', '{}', NULL, 'base_only', false, '{"cost_center":"optional","project":"optional"}'),
  ('73',   '7',  2, 'هزینه‌های مالی و غیرعملیاتی',       'group',   'expense', 'debit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('7301', '73', 3, 'هزینه‌های مالی',                   'posting', 'expense', 'debit', 'EXPENSE_FINANCE', '{pl.finance_costs}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('7302', '73', 3, 'زیان تسعیر ارز',                  'posting', 'expense', 'debit', 'FX_LOSS', '{pl.other_nonop}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('7303', '73', 3, 'تفاوت گرد کردن',                  'posting', 'expense', 'none',  'ROUNDING', '{pl.other_nonop}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('7304', '73', 3, 'هزینهٔ مالیات بر درآمد',           'posting', 'expense', 'debit', 'INCOME_TAX', '{pl.income_tax}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('8',    NULL, 1, 'حساب‌های انتظامی',                 'group',   'memo', 'debit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('81',   '8',  2, 'حساب‌های انتظامی',                 'group',   'memo', 'debit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('8101', '81', 3, 'اسناد تضمینی دریافتی',            'posting', 'memo', 'debit',  'MEMO_GUARANTEE_RECEIVED', '{}', 'subledger_only', '{treasury,migration}', 'guarantee_received', 'base_only', false, '{"party":"required"}'),
  ('8102', '81', 3, 'اسناد تضمینی پرداختی',            'posting', 'memo', 'debit',  'MEMO_GUARANTEE_GIVEN', '{}', 'subledger_only', '{treasury,migration}', 'guarantee_given', 'base_only', false, '{"party":"required"}'),
  ('82',   '8',  2, 'طرف حساب‌های انتظامی',             'group',   'memo', 'credit', NULL, '{}', 'open', '{}', NULL, 'base_only', false, '{}'),
  ('8201', '82', 3, 'طرف اسناد تضمینی دریافتی',        'posting', 'memo', 'credit', 'MEMO_GUARANTEE_RECEIVED_CONTRA', '{}', 'subledger_only', '{treasury,migration}', NULL, 'base_only', false, '{"party":"required"}'),
  ('8202', '82', 3, 'طرف اسناد تضمینی پرداختی',        'posting', 'memo', 'credit', 'MEMO_GUARANTEE_GIVEN_CONTRA', '{}', 'subledger_only', '{treasury,migration}', NULL, 'base_only', false, '{"party":"required"}')
) AS v(code, parent, lvl, name, kind, atype, nature, role, tags, policy, mods, subledger, cur, reval, dims)
ON CONFLICT DO NOTHING;

INSERT INTO ledger.coa_template_posting_rule (template_code, template_version, posting_key, account_code) VALUES
  ('ir.general', 1, 'ledger.rounding', '7303'), ('ir.general', 1, 'ledger.fx.unrealized_gain', '6201'),
  ('ir.general', 1, 'ledger.fx.unrealized_loss', '7302'), ('ir.general', 1, 'ledger.fx.realized_gain', '6201'),
  ('ir.general', 1, 'ledger.fx.realized_loss', '7302'), ('ir.general', 1, 'ledger.income_summary', '5303'),
  ('ir.general', 1, 'ledger.retained_earnings', '5301'), ('ir.general', 1, 'ledger.prior_period_adjustment', '5302'),
  ('ir.general', 1, 'ledger.opening_balance_clearing', '1304'),
  ('ir.general', 1, 'sales.revenue', '6101'), ('ir.general', 1, 'sales.returns', '6103'), ('ir.general', 1, 'sales.discount', '6104'),
  ('ir.general', 1, 'sales.receivable', '1201'), ('ir.general', 1, 'sales.customer_advance', '3301'),
  ('ir.general', 1, 'purchase.payable', '3101'), ('ir.general', 1, 'purchase.supplier_advance', '1501'),
  ('ir.general', 1, 'purchase.expense', '7206'),
  ('ir.general', 1, 'tax.vat_payable', '3202'), ('ir.general', 1, 'tax.vat_receivable', '1302'),
  ('ir.general', 1, 'inventory.asset', '1401'), ('ir.general', 1, 'inventory.cogs', '7101'),
  ('ir.general', 1, 'inventory.adjustment', '7102'), ('ir.general', 1, 'inventory.goods_in_transit', '1402'),
  ('ir.general', 1, 'treasury.cash', '1101'), ('ir.general', 1, 'treasury.bank', '1102'), ('ir.general', 1, 'treasury.petty_cash', '1103'),
  ('ir.general', 1, 'treasury.card_clearing', '1303'), ('ir.general', 1, 'treasury.cheque_receivable', '1202'),
  ('ir.general', 1, 'treasury.cheque_in_collection', '1203'), ('ir.general', 1, 'treasury.cheque_payable', '3102'),
  ('ir.general', 1, 'treasury.bank_fee', '7205'),
  ('ir.general', 1, 'treasury.guarantee_received', '8101'), ('ir.general', 1, 'treasury.guarantee_received_contra', '8201'),
  ('ir.general', 1, 'treasury.guarantee_given', '8102'), ('ir.general', 1, 'treasury.guarantee_given_contra', '8202'),
  ('ir.general', 1, 'assets.cost', '2102'), ('ir.general', 1, 'assets.accumulated_depreciation', '2190'),
  ('ir.general', 1, 'assets.depreciation_expense', '7204'),
  ('ir.general', 1, 'payroll.salary_expense', '7201'), ('ir.general', 1, 'payroll.salary_payable', '3205'),
  ('ir.general', 1, 'payroll.insurance_payable', '3204'), ('ir.general', 1, 'payroll.tax_payable', '3203'),
  ('ir.general', 1, 'payroll.employer_insurance_expense', '7201')
ON CONFLICT DO NOTHING;

-- ---------- قالب‌های صورت مالی (استانداردهای حسابداری ایران؛ اسکلت نسخه‌دار، نیازمند بازبینی) ----------
INSERT INTO ledger.report_template (code, version, kind, name_fa, standard_ref, confidence) VALUES
  ('ir.bs', 1, 'balance_sheet', 'صورت وضعیت مالی', 'استاندارد حسابداری ۱ (ارائهٔ صورت‌های مالی) — نیازمند تطبیق با متن رسمی', 'low'),
  ('ir.pl', 1, 'profit_loss',   'صورت سود و زیان', 'استاندارد حسابداری ۱ — نیازمند تطبیق با متن رسمی', 'low'),
  ('ir.cf', 1, 'cash_flow',     'صورت جریان‌های نقدی (روش غیرمستقیم، اسکلت)', 'استاندارد حسابداری ۲ — نیازمند تطبیق با متن رسمی', 'low')
ON CONFLICT DO NOTHING;

INSERT INTO ledger.report_template_row (template_code, template_version, row_code, sort_order, indent, label_fa, row_type, selector,
                                        balance_basis, sign, formula, is_check_row)
SELECT v.t, 1, v.rc, v.so, v.ind, v.label, v.rt, v.sel::jsonb, v.basis, v.sgn, v.f, v.chk
FROM (VALUES
  ('ir.bs','H_ASSETS',      10, 0, 'دارایی‌ها',                        'heading',  NULL, NULL, 1, NULL, false),
  ('ir.bs','NCA_PPE',       20, 2, 'دارایی‌های ثابت مشهود',             'accounts', '{"tags_any":["bs.nca.ppe_cost","bs.nca.ppe_accdep"]}', 'closing', 1, NULL, false),
  ('ir.bs','NCA_INTANG',    30, 2, 'دارایی‌های نامشهود',                'accounts', '{"tags_any":["bs.nca.intangible"]}', 'closing', 1, NULL, false),
  ('ir.bs','NCA_INV',       40, 2, 'سرمایه‌گذاری‌های بلندمدت',          'accounts', '{"tags_any":["bs.nca.investments"]}', 'closing', 1, NULL, false),
  ('ir.bs','NCA_TOTAL',     50, 1, 'جمع دارایی‌های غیرجاری',            'formula',  NULL, NULL, 1, 'NCA_PPE + NCA_INTANG + NCA_INV', false),
  ('ir.bs','CA_PREPAY',     60, 2, 'پیش‌پرداخت‌ها',                     'accounts', '{"tags_any":["bs.ca.prepayments"]}', 'closing', 1, NULL, false),
  ('ir.bs','CA_INVENTORY',  70, 2, 'موجودی مواد و کالا',               'accounts', '{"tags_any":["bs.ca.inventory"]}', 'closing', 1, NULL, false),
  ('ir.bs','CA_TRADE_REC',  80, 2, 'دریافتنی‌های تجاری',               'accounts', '{"tags_any":["bs.ca.trade_receivables"]}', 'closing', 1, NULL, false),
  ('ir.bs','CA_OTHER_REC',  90, 2, 'سایر دریافتنی‌ها',                 'accounts', '{"tags_any":["bs.ca.other_receivables"]}', 'closing', 1, NULL, false),
  ('ir.bs','CA_CASH',      100, 2, 'موجودی نقد',                       'accounts', '{"tags_any":["bs.ca.cash"]}', 'closing', 1, NULL, false),
  ('ir.bs','CA_TOTAL',     110, 1, 'جمع دارایی‌های جاری',               'formula',  NULL, NULL, 1, 'CA_PREPAY + CA_INVENTORY + CA_TRADE_REC + CA_OTHER_REC + CA_CASH', false),
  ('ir.bs','ASSETS_TOTAL', 120, 0, 'جمع دارایی‌ها',                     'formula',  NULL, NULL, 1, 'NCA_TOTAL + CA_TOTAL', false),
  ('ir.bs','H_EQ_LIAB',    130, 0, 'حقوق مالکانه و بدهی‌ها',             'heading',  NULL, NULL, 1, NULL, false),
  ('ir.bs','EQ_CAPITAL',   140, 2, 'سرمایه و جاری شرکا',               'accounts', '{"tags_any":["bs.eq.capital"]}', 'closing', -1, NULL, false),
  ('ir.bs','EQ_RESERVES',  150, 2, 'اندوخته‌ها',                        'accounts', '{"tags_any":["bs.eq.reserves"]}', 'closing', -1, NULL, false),
  ('ir.bs','EQ_RETAINED',  160, 2, 'سود (زیان) انباشته',               'accounts', '{"tags_any":["bs.eq.retained"]}', 'closing', -1, NULL, false),
  ('ir.bs','EQ_CURRENT',   170, 2, 'سود (زیان) دورهٔ جاری',              'pl_result', NULL, 'closing', -1, NULL, false),
  ('ir.bs','EQ_TOTAL',     180, 1, 'جمع حقوق مالکانه',                  'formula',  NULL, NULL, 1, 'EQ_CAPITAL + EQ_RESERVES + EQ_RETAINED + EQ_CURRENT', false),
  ('ir.bs','NCL_LOANS',    190, 2, 'تسهیلات مالی بلندمدت',              'accounts', '{"tags_any":["bs.ncl.loans"]}', 'closing', -1, NULL, false),
  ('ir.bs','NCL_PROV',     200, 2, 'ذخیرهٔ مزایای پایان خدمت',           'accounts', '{"tags_any":["bs.ncl.provisions"]}', 'closing', -1, NULL, false),
  ('ir.bs','NCL_TOTAL',    210, 1, 'جمع بدهی‌های غیرجاری',               'formula',  NULL, NULL, 1, 'NCL_LOANS + NCL_PROV', false),
  ('ir.bs','CL_TRADE_PAY', 220, 2, 'پرداختنی‌های تجاری',                'accounts', '{"tags_any":["bs.cl.trade_payables"]}', 'closing', -1, NULL, false),
  ('ir.bs','CL_OTHER_PAY', 230, 2, 'سایر پرداختنی‌ها',                  'accounts', '{"tags_any":["bs.cl.other_payables"]}', 'closing', -1, NULL, false),
  ('ir.bs','CL_TAX',       240, 2, 'مالیات پرداختنی',                   'accounts', '{"tags_any":["bs.cl.tax"]}', 'closing', -1, NULL, false),
  ('ir.bs','CL_ADV',       250, 2, 'پیش‌دریافت‌ها',                      'accounts', '{"tags_any":["bs.cl.advances"]}', 'closing', -1, NULL, false),
  ('ir.bs','CL_LOANS',     260, 2, 'تسهیلات مالی جاری',                 'accounts', '{"tags_any":["bs.cl.loans"]}', 'closing', -1, NULL, false),
  ('ir.bs','CL_TOTAL',     270, 1, 'جمع بدهی‌های جاری',                  'formula',  NULL, NULL, 1, 'CL_TRADE_PAY + CL_OTHER_PAY + CL_TAX + CL_ADV + CL_LOANS', false),
  ('ir.bs','LIAB_TOTAL',   280, 1, 'جمع بدهی‌ها',                        'formula',  NULL, NULL, 1, 'NCL_TOTAL + CL_TOTAL', false),
  ('ir.bs','EQ_LIAB_TOTAL',290, 0, 'جمع حقوق مالکانه و بدهی‌ها',          'formula',  NULL, NULL, 1, 'EQ_TOTAL + LIAB_TOTAL', false),
  ('ir.bs','BS_CHECK',     300, 0, 'کنترل توازن (باید صفر باشد)',        'formula',  NULL, NULL, 1, 'ASSETS_TOTAL - EQ_LIAB_TOTAL', true),

  ('ir.pl','REV',           10, 1, 'درآمد فروش',                         'accounts', '{"tags_any":["pl.revenue"]}', 'period_net', -1, NULL, false),
  ('ir.pl','REV_DED',       20, 1, 'برگشت از فروش و تخفیفات',            'accounts', '{"tags_any":["pl.revenue_deductions"]}', 'period_net', -1, NULL, false),
  ('ir.pl','NET_REV',       30, 0, 'درآمدهای عملیاتی',                    'formula',  NULL, NULL, 1, 'REV + REV_DED', false),
  ('ir.pl','COGS',          40, 1, 'بهای تمام‌شدهٔ درآمدهای عملیاتی',       'accounts', '{"tags_any":["pl.cogs"]}', 'period_net', -1, NULL, false),
  ('ir.pl','GROSS',         50, 0, 'سود (زیان) ناخالص',                   'formula',  NULL, NULL, 1, 'NET_REV + COGS', false),
  ('ir.pl','OPEX',          60, 1, 'هزینه‌های فروش، اداری و عمومی',        'accounts', '{"tags_any":["pl.opex"]}', 'period_net', -1, NULL, false),
  ('ir.pl','OP_RESULT',     70, 0, 'سود (زیان) عملیاتی',                  'formula',  NULL, NULL, 1, 'GROSS + OPEX', false),
  ('ir.pl','FIN_COST',      80, 1, 'هزینه‌های مالی',                       'accounts', '{"tags_any":["pl.finance_costs"]}', 'period_net', -1, NULL, false),
  ('ir.pl','OTHER_NONOP',   90, 1, 'سایر درآمدها و هزینه‌های غیرعملیاتی',   'accounts', '{"tags_any":["pl.other_nonop"]}', 'period_net', -1, NULL, false),
  ('ir.pl','PBT',          100, 0, 'سود (زیان) پیش از مالیات',              'formula',  NULL, NULL, 1, 'OP_RESULT + FIN_COST + OTHER_NONOP', false),
  ('ir.pl','TAX',          110, 1, 'مالیات بر درآمد',                      'accounts', '{"tags_any":["pl.income_tax"]}', 'period_net', -1, NULL, false),
  ('ir.pl','NET',          120, 0, 'سود (زیان) خالص',                     'formula',  NULL, NULL, 1, 'PBT + TAX', false),
  ('ir.pl','PL_CHECK',     130, 0, 'کنترل با جمع حساب‌های موقت (باید صفر باشد)', 'formula', NULL, NULL, 1, 'NET - PL_ALL', true),
  ('ir.pl','PL_ALL',       125, 0, 'جمع حساب‌های درآمد و هزینه',           'pl_result', NULL, 'period_net', -1, NULL, false),

  ('ir.cf','CF_PROFIT',     10, 1, 'سود (زیان) خالص',                      'pl_result', NULL, 'period_net', -1, NULL, false),
  ('ir.cf','CF_DEP',        20, 1, 'استهلاک (تغییر استهلاک انباشته)',       'accounts', '{"tags_any":["bs.nca.ppe_accdep"]}', 'change', -1, NULL, false),
  ('ir.cf','CF_WC_REC',     30, 1, 'تغییر دریافتنی‌ها',                     'accounts', '{"tags_any":["bs.ca.trade_receivables","bs.ca.other_receivables"]}', 'change', -1, NULL, false),
  ('ir.cf','CF_WC_INV',     40, 1, 'تغییر موجودی‌ها',                        'accounts', '{"tags_any":["bs.ca.inventory"]}', 'change', -1, NULL, false),
  ('ir.cf','CF_WC_PRE',     50, 1, 'تغییر پیش‌پرداخت‌ها',                    'accounts', '{"tags_any":["bs.ca.prepayments"]}', 'change', -1, NULL, false),
  ('ir.cf','CF_WC_PAY',     60, 1, 'تغییر پرداختنی‌ها، مالیات و پیش‌دریافت‌ها', 'accounts', '{"tags_any":["bs.cl.trade_payables","bs.cl.other_payables","bs.cl.tax","bs.cl.advances","bs.ncl.provisions"]}', 'change', -1, NULL, false),
  ('ir.cf','CF_OPERATING',  70, 0, 'جریان خالص نقد از فعالیت‌های عملیاتی',   'formula',  NULL, NULL, 1, 'CF_PROFIT + CF_DEP + CF_WC_REC + CF_WC_INV + CF_WC_PRE + CF_WC_PAY', false),
  ('ir.cf','CF_INVESTING',  80, 1, 'خرید و فروش دارایی‌های بلندمدت',        'accounts', '{"tags_any":["bs.nca.ppe_cost","bs.nca.intangible","bs.nca.investments"]}', 'change', -1, NULL, false),
  ('ir.cf','CF_INV_TOTAL',  90, 0, 'جریان خالص نقد از فعالیت‌های سرمایه‌گذاری', 'formula', NULL, NULL, 1, 'CF_INVESTING', false),
  ('ir.cf','CF_FIN_LOANS', 100, 1, 'دریافت و بازپرداخت تسهیلات',           'accounts', '{"tags_any":["bs.cl.loans","bs.ncl.loans"]}', 'change', -1, NULL, false),
  ('ir.cf','CF_FIN_EQ',    110, 1, 'تغییرات سرمایه، اندوخته و سود انباشته',  'accounts', '{"tags_any":["bs.eq.capital","bs.eq.reserves","bs.eq.retained"]}', 'change', -1, NULL, false),
  ('ir.cf','CF_FIN_TOTAL', 120, 0, 'جریان خالص نقد از فعالیت‌های تأمین مالی', 'formula', NULL, NULL, 1, 'CF_FIN_LOANS + CF_FIN_EQ', false),
  ('ir.cf','CF_NET',       130, 0, 'خالص افزایش (کاهش) موجودی نقد',         'formula',  NULL, NULL, 1, 'CF_OPERATING + CF_INV_TOTAL + CF_FIN_TOTAL', false),
  ('ir.cf','CF_CASH_OPEN', 140, 1, 'موجودی نقد ابتدای دوره',               'accounts', '{"tags_any":["bs.ca.cash"]}', 'opening', 1, NULL, false),
  ('ir.cf','CF_CASH_CLOSE',150, 1, 'موجودی نقد پایان دوره',                'accounts', '{"tags_any":["bs.ca.cash"]}', 'closing', 1, NULL, false),
  ('ir.cf','CF_CHECK',     160, 0, 'کنترل (باید صفر باشد)',                 'formula',  NULL, NULL, 1, 'CF_CASH_OPEN + CF_NET - CF_CASH_CLOSE', true)
) AS v(t, rc, so, ind, label, rt, sel, basis, sgn, f, chk)
ON CONFLICT DO NOTHING;

-- =====================================================================
-- ۲۱. ثبت شرطی در کاتالوگ‌های core (اگر 10_core.sql پیش‌تر اجرا شده باشد)
-- =====================================================================
DO $$
BEGIN
  IF to_regclass('core.export_table_registry') IS NOT NULL THEN
    INSERT INTO core.export_table_registry (schema_name, table_name, module, mode, export_order, note) VALUES
      ('ledger','rate_type',              'ledger', 'rows', 300, NULL),
      ('ledger','company_config',         'ledger', 'rows', 302, NULL),
      ('ledger','coa_level',              'ledger', 'rows', 304, NULL),
      ('ledger','dimension_type',         'ledger', 'rows', 306, NULL),
      ('ledger','dimension_value',        'ledger', 'rows', 308, NULL),
      ('ledger','account',                'ledger', 'rows', 310, NULL),
      ('ledger','account_dimension_rule', 'ledger', 'rows', 312, NULL),
      ('ledger','exchange_rate',          'ledger', 'rows', 314, NULL),
      ('ledger','posting_rule',           'ledger', 'rows', 316, NULL),
      ('ledger','recurring_journal',      'ledger', 'rows', 318, NULL),
      ('ledger','recurring_journal_line', 'ledger', 'rows', 320, NULL),
      ('ledger','journal_draft',          'ledger', 'rows', 322, NULL),
      ('ledger','journal_draft_line',     'ledger', 'rows', 324, NULL),
      ('ledger','fiscal_year',            'ledger', 'rows', 330, NULL),
      ('ledger','fiscal_period',          'ledger', 'rows', 332, NULL),
      ('ledger','period_status_event',    'ledger', 'rows', 334, NULL),
      ('ledger','period_module_lock',     'ledger', 'rows', 336, NULL),
      ('ledger','journal',                'ledger', 'rows', 340, 'verbatim; post-import hook verifies chains, numbering and control totals (03-ledger §5-13)'),
      ('ledger','journal_line',           'ledger', 'rows', 342, 'verbatim; verified by the ledger import hook'),
      ('ledger','balance_bucket',         'ledger', 'skip', 344, 'derived; rebuilt by ledger import hook (rebuild_balance_buckets)'),
      ('ledger','year_close_run',         'ledger', 'rows', 346, NULL),
      ('ledger','fx_revaluation_run',     'ledger', 'rows', 348, NULL),
      ('ledger','eledger_export',         'ledger', 'rows', 350, NULL),
      ('ledger','integrity_run',          'ledger', 'rows', 352, NULL),
      ('ledger','report_account_map',     'ledger', 'rows', 354, NULL)
    ON CONFLICT DO NOTHING;
  END IF;
  IF to_regclass('core.permission') IS NOT NULL THEN
    INSERT INTO core.permission (code, module, scope_dimensions, risk, allow_service_account, allow_impersonation_write, description_key, introduced_in) VALUES
      ('ledger.account.read',          'ledger', '{company}',        'normal',    true,  false, 'perm.ledger.account.read', '1.0'),
      ('ledger.account.manage',        'ledger', '{company}',        'sensitive', false, false, 'perm.ledger.account.manage', '1.0'),
      ('ledger.coa.setup',             'ledger', '{company}',        'critical',  false, false, 'perm.ledger.coa.setup', '1.0'),
      ('ledger.dimension.read',        'ledger', '{company}',        'normal',    true,  false, 'perm.ledger.dimension.read', '1.0'),
      ('ledger.dimension.manage',      'ledger', '{company}',        'sensitive', true,  false, 'perm.ledger.dimension.manage', '1.0'),
      ('ledger.fiscal.read',           'ledger', '{company}',        'normal',    true,  false, 'perm.ledger.fiscal.read', '1.0'),
      ('ledger.fiscal.manage',         'ledger', '{company}',        'critical',  false, false, 'perm.ledger.fiscal.manage', '1.0'),
      ('ledger.period.close',          'ledger', '{company}',        'sensitive', false, false, 'perm.ledger.period.close', '1.0'),
      ('ledger.period.reopen',         'ledger', '{company}',        'critical',  false, false, 'perm.ledger.period.reopen', '1.0'),
      ('ledger.period.lock',           'ledger', '{company}',        'critical',  false, false, 'perm.ledger.period.lock', '1.0'),
      ('ledger.period.unlock',         'ledger', '{company}',        'critical',  false, false, 'perm.ledger.period.unlock', '1.0'),
      ('ledger.period.post_soft_closed','ledger','{company}',        'sensitive', false, false, 'perm.ledger.period.post_soft_closed', '1.0'),
      ('ledger.journal.read',          'ledger', '{company,branch}', 'normal',    true,  false, 'perm.ledger.journal.read', '1.0'),
      ('ledger.journal.create',        'ledger', '{company,branch}', 'normal',    true,  false, 'perm.ledger.journal.create', '1.0'),
      ('ledger.journal.post',          'ledger', '{company,branch}', 'sensitive', true,  false, 'perm.ledger.journal.post', '1.0'),
      ('ledger.journal.review',        'ledger', '{company,branch}', 'sensitive', false, false, 'perm.ledger.journal.review', '1.0'),
      ('ledger.journal.void',          'ledger', '{company,branch}', 'sensitive', false, false, 'perm.ledger.journal.void', '1.0'),
      ('ledger.journal.reverse',       'ledger', '{company,branch}', 'sensitive', false, false, 'perm.ledger.journal.reverse', '1.0'),
      ('ledger.journal.finalize',      'ledger', '{company}',        'critical',  false, false, 'perm.ledger.journal.finalize', '1.0'),
      ('ledger.year.close',            'ledger', '{company}',        'critical',  false, false, 'perm.ledger.year.close', '1.0'),
      ('ledger.year.reopen',           'ledger', '{company}',        'critical',  false, false, 'perm.ledger.year.reopen', '1.0'),
      ('ledger.year.lock',             'ledger', '{company}',        'critical',  false, false, 'perm.ledger.year.lock', '1.0'),
      ('ledger.fx.manage',             'ledger', '{company}',        'sensitive', true,  false, 'perm.ledger.fx.manage', '1.0'),
      ('ledger.fx.revalue',            'ledger', '{company}',        'sensitive', false, false, 'perm.ledger.fx.revalue', '1.0'),
      ('ledger.mapping.read',          'ledger', '{company}',        'normal',    true,  false, 'perm.ledger.mapping.read', '1.0'),
      ('ledger.mapping.manage',        'ledger', '{company}',        'critical',  false, false, 'perm.ledger.mapping.manage', '1.0'),
      ('ledger.recurring.manage',      'ledger', '{company}',        'sensitive', false, false, 'perm.ledger.recurring.manage', '1.0'),
      ('ledger.opening.import',        'ledger', '{company}',        'critical',  true,  false, 'perm.ledger.opening.import', '1.0'),
      ('ledger.report.read',           'ledger', '{company,branch,cost_center}', 'normal', true, false, 'perm.ledger.report.read', '1.0'),
      ('ledger.report.export',         'ledger', '{company,branch,cost_center}', 'sensitive', true, false, 'perm.ledger.report.export', '1.0'),
      ('ledger.eledger.export',        'ledger', '{company}',        'critical',  false, false, 'perm.ledger.eledger.export', '1.0'),
      ('ledger.integrity.verify',      'ledger', '{company}',        'normal',    true,  false, 'perm.ledger.integrity.verify', '1.0')
    ON CONFLICT (code) DO NOTHING;
  END IF;
END $$;
