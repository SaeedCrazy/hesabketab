-- =====================================================================
-- حساب‌کتاب — tests/99_integration_test.sql   (مالک: یکپارچه‌ساز، بخش ۲)
-- آزمون یکپارچهٔ صفحهٔ داده: روی پایگاه کامل 00→10→20→25→30→40→50→60→80→99_cross_fk اجرا می‌شود
-- (run_all.sh گام b؛ پیش از گام idempotency). هر بخش دیگر فقط زنجیرهٔ خودش را می‌آزماید؛ این فایل
-- قراردادهای «بین» بخش‌ها را روی SQL واقعی همهٔ بخش‌ها می‌سنجد.
--
-- اجرا (از ریشهٔ مخزن):
--   export PGPASSWORD=postgres
--   PREFIX=it2_ docs/design/sql/run_all.sh integrated            # یا: psql -d <db> -f docs/design/sql/tests/99_integration_test.sql
--
-- نقش‌ها در هر بخش:
--   بخش ۰ (زیرساخت)   postgres: جدول نتیجه public.it_result، کلیدهای fixture public.it_key و کمک‌تابع‌ها (SECURITY INVOKER).
--   بخش A (lint سراسری) postgres فقط کاتالوگ را می‌خواند؛ دسترسی نقش‌ها با has_*_privilege('hk_app'|'hk_readonly', …) سنجیده
--                      می‌شود. هر lint فهرست اشیای خاطی را در پیام شکست می‌آورد.
--   بخش B.1 (fixture)   postgres: دو مستأجر A و B، شرکت، شعبه، کاربر، عضویت، دستگاه، سری شماره، اشخاص، کالا، انبار
--                      (همان چیزی که پنل مالک/provisioning و ماژول‌های پایه می‌سازند).
--   بخش C (جریان‌ها)    hk_app با SET ROLE؛ هر DO block یک تراکنش است و مستأجر را با
--                      set_config('app.tenant_id', …, true) تنظیم می‌کند. جریان‌ها برای هر دو مستأجر اجرا می‌شوند تا
--                      دادهٔ B هم برای بخش B وجود داشته باشد. هر جا طرح تابع SQL مستند دارد همان صدا زده می‌شود
--                      (ledger.provision_tenant/apply_coa_template/resolve_account/reverse_journal/trial_balance/
--                      check_control_accounts، core.number_next/number_record_external، treasury.subledger_*، …)؛
--                      وگرنه «همان ردیف‌هایی که سرویس پایتون مستند درج می‌کند» درج می‌شود (در توضیح هر گام نام سرویس آمده).
--   بخش B.2 (نشت)      hk_app (و hk_readonly): بررسی پویا روی همهٔ جدول‌های مستأجری از کاتالوگ: دیدن ردیف مستأجر دیگر،
--                      درج با tenant_id دیگر، UPDATE/DELETE ردیف مستأجر دیگر، FK ترکیبی به والد مستأجر دیگر، رفتار بدون
--                      مستأجر، و جدول‌های سطح قلمرو (R-USER). پیش از آن postgres برای هر جدولی که جریان‌ها ردیف B نساخته‌اند
--                      یک ردیف ترکیبی B در حالت replica درج می‌کند (فقط برای کاوش؛ پس از B.2 پاک می‌شود). جدول‌هایی که مولد
--                      ساده CHECKشان را برآورده نمی‌کند «fixture ناممکن»‌اند و فهرستشان در گزارش پوشش چاپ می‌شود؛ آن‌ها فقط
--                      با lint ایستای A1 (policy استاندارد روی همه، هیچ policy مجاز بی‌مستأجر) و کاوش درج B2.2/B2.4 پوشش دارند.
--   ترتیب فایل: ۰ → A → B.1 → C → B.2 → گزارش (B.2 پس از C می‌آید تا روی دادهٔ واقعی جریان‌ها اجرا شود).
--
-- سیاست شکست: هر بررسی در public.it_result ثبت می‌شود (PASS/FAIL + شناسهٔ یافته + مسئول). وقتی یک جریان به‌خاطر
-- ناهمخوانی قرارداد بین دو بخش اجرا نمی‌شود، تلاش مستند در زیرتراکنش برگشتی انجام و یافته ثبت می‌شود؛ جریان POS (C4)
-- همان‌جا متوقف می‌شود. برای سه ناهمخوانی که جریان‌های پایین‌دست را قفل می‌کنند (RV-IT2-01 حساب کنترلی موجودی،
-- RV-IT2-05 قالب source_event چک) یک «راه گریز» صریح و برچسب‌دار به کار می‌رود تا جریان‌های بعدی (خرید، فروش، چک،
-- ابطال، تراز) همچنان اجرا شوند؛ این راه گریز قرارداد نیست و یافته FAIL می‌ماند.
-- در پایان جدول کامل چاپ می‌شود؛ اگر حتی یک FAIL باشد «TEST FAILED» و کد خروج ≠ ۰. هیچ allowlistی برای یافته‌ها
-- نیست: هارنس تا رفع آن‌ها قرمز می‌ماند (همان سیاست RV-IT-01 در بخش ۱).
-- خروجی موفق: «ALL 99_integration TESTS PASSED».
--
-- شناسهٔ یافته‌ها: RV-IT2-NN (پاسخ ساخت‌یافتهٔ یکپارچه‌ساز بخش ۲)؛ RV-IT-NN مال بخش ۱ است.
-- =====================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
SET client_min_messages = warning;
RESET ROLE;

-- =====================================================================
-- بخش ۰: زیرساخت آزمون (postgres)
-- =====================================================================
DROP TABLE IF EXISTS public.it_result;
CREATE TABLE public.it_result (
  seq      bigserial PRIMARY KEY,
  part     text NOT NULL,
  check_id text NOT NULL,
  ok       boolean NOT NULL,
  finding  text,          -- RV-IT2-NN وقتی شکست یک یافتهٔ ثبت‌شده است
  owner    text,          -- بخش مسئول رفع
  detail   text
);
DROP TABLE IF EXISTS public.it_key;
CREATE TABLE public.it_key (name text PRIMARY KEY, id uuid NOT NULL);
GRANT SELECT, INSERT ON public.it_result TO hk_app, hk_readonly;
GRANT USAGE ON SEQUENCE public.it_result_seq_seq TO hk_app, hk_readonly;
GRANT SELECT, INSERT, UPDATE ON public.it_key TO hk_app;
GRANT SELECT ON public.it_key TO hk_readonly;

-- ثبت نتیجهٔ یک بررسی
CREATE OR REPLACE FUNCTION public.it_rec(p_part text, p_check text, p_ok boolean, p_detail text DEFAULT NULL,
                                         p_finding text DEFAULT NULL, p_owner text DEFAULT NULL) RETURNS boolean
LANGUAGE sql AS $$
  INSERT INTO public.it_result (part, check_id, ok, finding, owner, detail)
  VALUES (p_part, p_check, coalesce(p_ok, false),
          CASE WHEN coalesce(p_ok, false) THEN NULL ELSE p_finding END,
          CASE WHEN coalesce(p_ok, false) THEN NULL ELSE p_owner END,
          CASE WHEN coalesce(p_ok, false) THEN NULL ELSE left(p_detail, 4000) END)
  RETURNING ok
$$;

-- اجرای SQL در زیرتراکنش (تریگرهای deferred همان‌جا)؛ برمی‌گرداند NULL اگر موفق شد، وگرنه 'SQLSTATE: پیام'
CREATE OR REPLACE FUNCTION public.it_try(p_sql text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v_state text; v_msg text;
BEGIN
  BEGIN
    EXECUTE p_sql;
    EXECUTE 'SET CONSTRAINTS ALL IMMEDIATE';
    EXECUTE 'SET CONSTRAINTS ALL DEFERRED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    RETURN v_state || ': ' || v_msg;
  END;
  RETURN NULL;
END $$;

-- اجرای SQL و برگرداندن همیشگی (rollback) — برای «باید شکست بخورد» و «تا اینجا اجرا شد»
CREATE OR REPLACE FUNCTION public.it_try_rollback(p_sql text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v_state text; v_msg text;
BEGIN
  BEGIN
    EXECUTE p_sql;
    EXECUTE 'SET CONSTRAINTS ALL IMMEDIATE';
    RAISE EXCEPTION 'IT_ROLLBACK_OK';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_msg = 'IT_ROLLBACK_OK' THEN RETURN NULL; END IF;
    RETURN v_state || ': ' || v_msg;
  END;
END $$;

CREATE OR REPLACE FUNCTION public.it_k(p_name text) RETURNS uuid
LANGUAGE sql STABLE AS $$ SELECT id FROM public.it_key WHERE name = p_name $$;

-- زمینهٔ مستأجر و کاربر (فقط همین تراکنش). '' = بدون مستأجر.
CREATE OR REPLACE FUNCTION public.it_ctx(p_tenant text) RETURNS void
LANGUAGE sql AS $$
  SELECT set_config('app.tenant_id', coalesce((SELECT id::text FROM public.it_key WHERE name = p_tenant || '.T'), ''), true),
         set_config('app.user_id',   coalesce((SELECT id::text FROM public.it_key WHERE name = p_tenant || '.U1'), ''), true);
$$;

-- اسکیماهای صفحهٔ داده = همهٔ اسکیماهای غیرسیستمی جز public (از کاتالوگ؛ اسکیمای تازهٔ هر بخش خودکار پوشش می‌گیرد)
CREATE OR REPLACE FUNCTION public.it_dp_schemas() RETURNS TABLE (oid oid, nspname name)
LANGUAGE sql STABLE AS $$
  SELECT n.oid, n.nspname FROM pg_namespace n
   WHERE n.nspname NOT IN ('pg_catalog','information_schema','public','pg_toast') AND n.nspname NOT LIKE 'pg\_%'
$$;
CREATE OR REPLACE FUNCTION public.it_tenant_tables() RETURNS TABLE (rel regclass, nspname name, relname name)
LANGUAGE sql STABLE AS $$
  SELECT c.oid::regclass, s.nspname, c.relname
    FROM pg_class c JOIN public.it_dp_schemas() s ON s.oid = c.relnamespace
   WHERE c.relkind IN ('r','p') AND NOT c.relispartition
     AND EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped)
$$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO hk_app, hk_readonly;

-- =====================================================================
-- بخش A: lint سراسری روی همهٔ اسکیماهای صفحهٔ داده (postgres؛ فقط کاتالوگ)
-- =====================================================================

-- ---------- A1: جدول مستأجری = RLS روشن و اجباری + policy + UNIQUE (tenant_id, id)؛ policyهای مجاز؛ جدول بی‌tenant ----------
DO $$
DECLARE v text;
BEGIN
  SELECT string_agg(rel::text, ', ' ORDER BY rel::text) INTO v FROM public.it_tenant_tables() t
    JOIN pg_class c ON c.oid = t.rel WHERE NOT c.relrowsecurity OR NOT c.relforcerowsecurity;
  PERFORM it_rec('A', 'A1.rls_enabled_and_forced', v IS NULL, 'tenant tables without ENABLE+FORCE RLS: ' || v);

  SELECT string_agg(rel::text, ', ' ORDER BY rel::text) INTO v FROM public.it_tenant_tables() t
   WHERE NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = t.rel);
  PERFORM it_rec('A', 'A1.rls_has_policy', v IS NULL, 'tenant tables without any policy: ' || v);

  -- هر جدول مستأجری policy استاندارد tenant_isolation دارد (FOR ALL، USING و WITH CHECK = tenant_id = core.current_tenant_id())
  SELECT string_agg(rel::text, ', ' ORDER BY rel::text) INTO v FROM public.it_tenant_tables() t
   WHERE NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = t.rel AND p.polcmd = '*' AND p.polpermissive
                       AND pg_get_expr(p.polqual, p.polrelid) = '(tenant_id = core.current_tenant_id())'
                       AND pg_get_expr(p.polwithcheck, p.polrelid) = '(tenant_id = core.current_tenant_id())');
  PERFORM it_rec('A', 'A1.rls_standard_tenant_policy', v IS NULL, 'tenant tables without the standard tenant_isolation policy: ' || v);

  -- policy مجاز (permissive) دیگری که به hk_app/hk_readonly/PUBLIC اعمال شود و به مستأجر محدود نباشد = نشت (OR می‌شود)
  -- allowlist: core.tenant_membership.member_self_select — کاربر عضویت‌های خودش را در همهٔ مستأجرها می‌بیند (02 INV-IAM-02، R-USER)
  SELECT string_agg(p.polrelid::regclass || '.' || p.polname, ', ' ORDER BY 1) INTO v
    FROM pg_policy p JOIN public.it_tenant_tables() t ON t.rel = p.polrelid
   WHERE p.polpermissive
     AND (0 = ANY (p.polroles) OR (SELECT oid FROM pg_roles WHERE rolname = 'hk_app') = ANY (p.polroles)
          OR (SELECT oid FROM pg_roles WHERE rolname = 'hk_readonly') = ANY (p.polroles))
     AND NOT (coalesce(pg_get_expr(p.polqual, p.polrelid), '(tenant_id = core.current_tenant_id())') = '(tenant_id = core.current_tenant_id())'
          AND coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '(tenant_id = core.current_tenant_id())') = '(tenant_id = core.current_tenant_id())')
     AND (p.polrelid::regclass::text, p.polname) NOT IN (('core.tenant_membership', 'member_self_select'));
  PERFORM it_rec('A', 'A1.no_unscoped_permissive_policy', v IS NULL, 'permissive policies for app roles not scoped to the tenant: ' || v);

  -- UNIQUE (tenant_id, id) (یا PRIMARY KEY (tenant_id, id)، R-PK)، نه جزئی
  SELECT string_agg(rel::text, ', ' ORDER BY rel::text) INTO v FROM public.it_tenant_tables() t
   WHERE EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = t.rel AND a.attname = 'id' AND NOT a.attisdropped)
     AND NOT EXISTS (
       SELECT 1 FROM pg_index i
        WHERE i.indrelid = t.rel AND i.indisunique AND i.indisvalid AND i.indpred IS NULL AND i.indnatts = 2 AND i.indnkeyatts = 2
          AND (SELECT array_agg(a.attname::text ORDER BY a.attname) FROM pg_attribute a
                WHERE a.attrelid = t.rel AND a.attnum = ANY (i.indkey)) = ARRAY['id','tenant_id']);
  PERFORM it_rec('A', 'A1.unique_tenant_id_id', v IS NULL, 'tenant tables with id but no UNIQUE (tenant_id, id): ' || v);

  -- جدول بدون tenant_id بیرون از ref فقط با دلیل (سطح قلمرو یا کاتالوگ سراسری)
  CREATE TEMP TABLE it_nontenant_allow (rel text PRIMARY KEY, reason text NOT NULL) ON COMMIT DROP;
  INSERT INTO it_nontenant_allow VALUES
    ('core.tenant', 'ریشهٔ مستأجر؛ RLS روی id (00_foundation)'),
    ('core.app_user', 'R-USER: کاربر سطح قلمرو، RLS کاربرمحور (02 §13.4)'),
    ('core.user_login_identifier', 'R-USER'), ('core.user_credential', 'R-USER'), ('core.user_recovery_code', 'R-USER'),
    ('core.user_session', 'R-USER'), ('core.otp_challenge', 'R-USER'), ('core.auth_event', 'R-USER: لاگ امنیتی قلمرو'),
    ('core.rate_limit_counter', '02 §4: UNLOGGED، کلید scope:sha256 بدون دادهٔ مستأجر'),
    ('core.deployment_info', '02 §4: تک‌ردیف نصب'), ('core.system_task_run', '02 §4: کار سیستمی hk_dispatcher'),
    ('core.job_queue', 'کاتالوگ'), ('core.event_subscriber', 'کاتالوگ'), ('core.event_subscription', 'کاتالوگ'),
    ('core.permission', 'کاتالوگ'), ('core.role_template', 'کاتالوگ'), ('core.role_template_permission', 'کاتالوگ'),
    ('core.field_guard', 'کاتالوگ'), ('core.setting_def', 'کاتالوگ'), ('core.custom_field_entity', 'کاتالوگ'),
    ('core.notification_category', 'کاتالوگ'), ('core.notification_template_def', 'کاتالوگ'),
    ('core.export_table_registry', 'کاتالوگ'), ('core.retention_class', 'کاتالوگ'),
    ('ledger.journal_type', 'کاتالوگ'), ('ledger.posting_key', 'کاتالوگ'), ('ledger.dimension_type_catalog', 'کاتالوگ'),
    ('ledger.coa_template', 'دادهٔ استاندارد R-STDDATA'), ('ledger.coa_template_account', 'R-STDDATA'),
    ('ledger.coa_template_posting_rule', 'R-STDDATA'), ('ledger.subledger_source', 'کاتالوگ'),
    ('ledger.report_template', 'R-STDDATA'), ('ledger.report_template_row', 'R-STDDATA'),
    ('treasury.cheque_state', 'کاتالوگ'), ('treasury.cheque_transition', 'کاتالوگ'), ('treasury.gateway_provider', 'کاتالوگ'),
    ('treasury.statement_header_synonym', 'کاتالوگ'), ('treasury.statement_keyword', 'کاتالوگ'),
    ('treasury.statement_profile_global', 'کاتالوگ'), ('pos.command_type', 'کاتالوگ'),
    ('rules.param_def', 'بستهٔ قواعد سراسری'), ('rules.package', 'بستهٔ قواعد'), ('rules.param_value', 'بستهٔ قواعد'),
    ('rules.golden_test', 'بستهٔ قواعد'), ('rules.golden_run', 'بستهٔ قواعد'), ('rules.package_event', 'بستهٔ قواعد'),
    ('rules.obligation_def', 'بستهٔ قواعد'), ('rules.tax_category', 'بستهٔ قواعد'), ('rules.industry_pack', 'R-STDDATA'),
    ('rules.industry_pack_version', 'R-STDDATA'), ('payroll.statutory_class', 'کاتالوگ'),
    ('migration.source_system', 'کاتالوگ'), ('migration.profile', 'کاتالوگ'), ('migration.header_synonym', 'کاتالوگ'),
    ('migration.template_column', 'کاتالوگ'), ('migration.issue_code', 'کاتالوگ'), ('migration.partition_rule', 'کاتالوگ'),
    ('assistant.data_class', 'کاتالوگ'), ('assistant.purpose', 'کاتالوگ'), ('assistant.proposal_kind', 'کاتالوگ'),
    ('assistant.tool', 'کاتالوگ'), ('assistant.tool_permission', 'کاتالوگ'), ('assistant.prompt_suggestion', 'کاتالوگ');
  SELECT string_agg(c.oid::regclass::text, ', ' ORDER BY 1) INTO v
    FROM pg_class c JOIN public.it_dp_schemas() s ON s.oid = c.relnamespace
   WHERE c.relkind IN ('r','p') AND s.nspname <> 'ref'
     AND NOT EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped)
     AND c.oid::regclass::text NOT IN (SELECT rel FROM it_nontenant_allow);
  PERFORM it_rec('A', 'A1.non_tenant_tables_allowlisted', v IS NULL, 'tables without tenant_id outside ref and not allowlisted: ' || v);

  -- کاتالوگ سراسری (غیر R-USER) برای hk_app/hk_readonly فقط‌خواندنی است؛ نوشتن آن = اثر روی همهٔ مستأجرها
  SELECT string_agg(a.rel || ':' || r.rolname, ', ' ORDER BY 1) INTO v
    FROM it_nontenant_allow a CROSS JOIN (VALUES ('hk_app'), ('hk_readonly')) r(rolname)
   WHERE a.rel NOT IN ('core.tenant','core.app_user','core.user_login_identifier','core.user_credential','core.user_recovery_code',
                       'core.user_session','core.otp_challenge','core.auth_event','core.rate_limit_counter','core.deployment_info')
     AND (has_table_privilege(r.rolname, a.rel, 'INSERT') OR has_any_column_privilege(r.rolname, a.rel, 'UPDATE')
          OR has_table_privilege(r.rolname, a.rel, 'DELETE') OR has_table_privilege(r.rolname, a.rel, 'TRUNCATE'));
  PERFORM it_rec('A', 'A1.global_catalogs_read_only', v IS NULL, 'global catalog tables writable by a runtime role: ' || v);
  SELECT string_agg(c.oid::regclass || ':' || r.rolname, ', ' ORDER BY 1) INTO v
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'ref'
    CROSS JOIN (VALUES ('hk_app'), ('hk_readonly')) r(rolname)
   WHERE c.relkind IN ('r','p')
     AND (has_table_privilege(r.rolname, c.oid, 'INSERT') OR has_any_column_privilege(r.rolname, c.oid, 'UPDATE')
          OR has_table_privilege(r.rolname, c.oid, 'DELETE') OR has_table_privilege(r.rolname, c.oid, 'TRUNCATE'));
  PERFORM it_rec('A', 'A1.ref_read_only', v IS NULL, 'ref tables writable by a runtime role (R-REF): ' || v);
END $$;

-- ---------- A2: هر FK بین دو جدول مستأجری tenant_id را با tenant_id والد جفت می‌کند ----------
DO $$
DECLARE v text;
BEGIN
  SELECT string_agg(con.conrelid::regclass || '/' || con.conname || ' -> ' || con.confrelid::regclass, ', ' ORDER BY 1) INTO v
    FROM pg_constraint con
    JOIN public.it_tenant_tables() s ON s.rel = con.conrelid
    JOIN public.it_tenant_tables() d ON d.rel = con.confrelid
   WHERE con.contype = 'f'
     AND NOT EXISTS (SELECT 1 FROM unnest(con.conkey, con.confkey) AS u(k, fk)
                      WHERE k  = (SELECT attnum FROM pg_attribute WHERE attrelid = con.conrelid  AND attname = 'tenant_id')
                        AND fk = (SELECT attnum FROM pg_attribute WHERE attrelid = con.confrelid AND attname = 'tenant_id'));
  PERFORM it_rec('A', 'A2.fk_tenant_composite', v IS NULL, 'FKs between tenant tables that do not pair tenant_id with tenant_id: ' || v);
  SELECT string_agg(con.conrelid::regclass || '/' || con.conname, ', ' ORDER BY 1) INTO v
    FROM pg_constraint con WHERE con.contype = 'f' AND NOT con.convalidated;
  PERFORM it_rec('A', 'A2.fk_all_validated', v IS NULL, 'NOT VALID foreign keys: ' || v);
  -- جدول مستأجری فقط با tenant_id به core.tenant اشاره می‌کند
  SELECT string_agg(con.conrelid::regclass || '/' || con.conname, ', ' ORDER BY 1) INTO v
    FROM pg_constraint con JOIN public.it_tenant_tables() s ON s.rel = con.conrelid
   WHERE con.contype = 'f' AND con.confrelid = 'core.tenant'::regclass
     AND con.conkey <> ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = con.conrelid AND attname = 'tenant_id')]::int2[];
  PERFORM it_rec('A', 'A2.fk_to_tenant_only_via_tenant_id', v IS NULL, 'tenant tables referencing core.tenant through another column: ' || v);
END $$;

-- ---------- A2-DAG: هر FK بین‌اسکیمایی در depends_on جدول ۰۱ §۵-۱ است یا استثنای برچسب‌دار پذیرفته (RV-ARCH-08) ----------
-- مقایسهٔ شمارهٔ لایه کافی نبود: یال هم‌لایه (چرخهٔ inventory↔tax) و یال رو به پایینِ اعلام‌نشده (treasury→catalog،
-- pos→ledger) از خودآزمایی قدیم 99 می‌گذشت. این بررسی‌ها تابع پایه core.xfk_dag_violations() را می‌سنجند که خودآزمایی
-- 99 (HK_XFK_DAG) هم صدا می‌زند.
DO $$
DECLARE v text; v2 text;
BEGIN
  IF to_regprocedure('core.xfk_dag_violations()') IS NULL OR to_regprocedure('core.module_registry()') IS NULL THEN
    PERFORM it_rec('A', 'A2.cross_schema_fks_follow_dag', false,
                   'core.module_registry()/core.xfk_dag_violations() missing from 00_foundation.sql', 'RV-ARCH-08', 'integration');
    RETURN;
  END IF;
  -- (۱) پایگاه یکپارچه: صفر FK بیرون از DAG بدون برچسب
  SELECT string_agg(x.from_table || '/' || x.conname || ' -> ' || x.to_table || ' [' || x.problem || ']', ', '
                    ORDER BY x.from_table::text, x.conname) INTO v
    FROM core.xfk_dag_violations() x;
  PERFORM it_rec('A', 'A2.cross_schema_fks_follow_dag', v IS NULL,
                 'cross-schema FKs outside 01 §5-1 depends_on without HK_DAG_EXCEPTION: ' || v, 'RV-ARCH-08', 'integration');

  -- (۲) رجیستری با اسکیماهای واقعی برابر است (اسکیمای تازه بدون ردیف DAG = ماژول بدون ADR)
  SELECT string_agg(s.nspname, ', ' ORDER BY s.nspname) INTO v
    FROM public.it_dp_schemas() s WHERE NOT EXISTS (SELECT 1 FROM core.module_registry() m WHERE m.module = s.nspname::text);
  SELECT string_agg(m.module, ', ' ORDER BY m.module) INTO v2
    FROM core.module_registry() m WHERE to_regnamespace(m.module) IS NULL;
  PERFORM it_rec('A', 'A2.dag_registry_matches_schemas', v IS NULL AND v2 IS NULL,
                 'schemas without a module_registry row: ' || coalesce(v, '-') || '; registry modules without a schema: ' || coalesce(v2, '-'),
                 'RV-ARCH-08', 'integration');

  -- (۳) خود رجیستری DAG است: هر وابستگی ثبت‌شده است، به لایهٔ هم‌سطح یا پایین‌تر می‌رود، و هیچ چرخه‌ای نیست
  WITH RECURSIVE e AS (
    SELECT m.module AS src, d AS dst FROM core.module_registry() m, unnest(m.depends_on) d
  ), reach(src, dst, path) AS (
    SELECT src, dst, ARRAY[src, dst] FROM e
    UNION ALL
    SELECT r.src, e.dst, r.path || e.dst FROM reach r JOIN e ON e.src = r.dst WHERE NOT e.dst = ANY (r.path)
  )
  SELECT string_agg(p, '; ' ORDER BY p) INTO v FROM (
    SELECT 'unregistered dependency ' || e.src || '->' || e.dst AS p FROM e
     WHERE NOT EXISTS (SELECT 1 FROM core.module_registry() m WHERE m.module = e.dst)
    UNION ALL
    SELECT 'upward dependency ' || e.src || '->' || e.dst FROM e
      JOIN core.module_registry() ms ON ms.module = e.src JOIN core.module_registry() md ON md.module = e.dst
     WHERE md.layer > ms.layer
    UNION ALL
    SELECT DISTINCT 'cycle at ' || r.src FROM reach r JOIN e ON e.src = r.dst AND e.dst = r.src
  ) q;
  PERFORM it_rec('A', 'A2.dag_registry_is_layered_dag', v IS NULL, v, 'RV-ARCH-08', 'integration');

  -- (۴) هر برچسب HK_DAG_EXCEPTION یک استثنای پذیرفتهٔ change-requests.md (R-XFK بند ۵) است و هر استثنای پذیرفته
  --     برچسب خورده است؛ بخشی نمی‌تواند با برچسب زدن به FK خودش از lint بگذرد.
  WITH accepted(src, dst) AS (VALUES
    ('core.role_assignment_scope', 'inventory.warehouse'), ('core.role_assignment_scope', 'treasury.cash_box'),
    ('core.role_assignment_scope', 'pos.terminal'),        ('core.role_assignment_scope', 'ledger.dimension_value'),
    ('rules.param_override', 'payroll.workshop'),
    ('tax.invoice', 'sales.invoice'), ('tax.invoice_issue_line', 'sales.invoice_line'),
    ('assets.disposal', 'sales.invoice'),
    ('pos.cash_movement', 'ledger.posting_key')
  ), labelled AS (
    SELECT c.conrelid::regclass::text AS src, c.confrelid::regclass::text AS dst, c.conname
      FROM pg_constraint c
     WHERE c.contype = 'f' AND c.conparentid = 0
       AND obj_description(c.oid, 'pg_constraint') LIKE 'HK_DAG_EXCEPTION:%'
  )
  SELECT string_agg(p, '; ' ORDER BY p) INTO v FROM (
    SELECT 'label not in R-XFK-5: ' || l.src || '/' || l.conname || ' -> ' || l.dst AS p FROM labelled l
     WHERE NOT EXISTS (SELECT 1 FROM accepted a WHERE a.src = l.src AND a.dst = l.dst)
    UNION ALL
    SELECT 'accepted exception without a labelled FK: ' || a.src || ' -> ' || a.dst FROM accepted a
     WHERE NOT EXISTS (SELECT 1 FROM labelled l WHERE l.src = a.src AND l.dst = a.dst)
  ) q;
  PERFORM it_rec('A', 'A2.dag_exceptions_match_rulings', v IS NULL, v, 'RV-ARCH-08', 'integration');

  -- (۵) کاوش: FKهای ساختگی در زیرتراکنش برگشتی. باید دقیقاً چهار مورد بی‌برچسب گرفته شوند — چرخهٔ هم‌لایهٔ
  --     inventory↔tax، یال رو به پایین اعلام‌نشدهٔ treasury→catalog، یال رو به بالای ledger→inventory — و FK
  --     اعلام‌شدهٔ sales→catalog و FK برچسب‌دار catalog→inventory گرفته نشوند. خودآزمایی قدیم 99 (مقایسهٔ لایه) هیچ‌کدام
  --     از سه مورد اول را نمی‌گرفت.
  v := NULL;
  BEGIN
    ALTER TABLE inventory.warehouse ADD COLUMN it_dag_probe uuid;
    ALTER TABLE inventory.warehouse ADD CONSTRAINT it_dag_probe_1 FOREIGN KEY (tenant_id, it_dag_probe) REFERENCES tax.invoice (tenant_id, id);
    ALTER TABLE tax.invoice ADD COLUMN it_dag_probe uuid;
    ALTER TABLE tax.invoice ADD CONSTRAINT it_dag_probe_2 FOREIGN KEY (tenant_id, it_dag_probe) REFERENCES inventory.warehouse (tenant_id, id);
    ALTER TABLE treasury.cash_box ADD COLUMN it_dag_probe uuid;
    ALTER TABLE treasury.cash_box ADD CONSTRAINT it_dag_probe_3 FOREIGN KEY (tenant_id, it_dag_probe) REFERENCES catalog.item (tenant_id, id);
    ALTER TABLE ledger.account ADD COLUMN it_dag_probe uuid;
    ALTER TABLE ledger.account ADD CONSTRAINT it_dag_probe_4 FOREIGN KEY (tenant_id, it_dag_probe) REFERENCES inventory.warehouse (tenant_id, id);
    ALTER TABLE sales.invoice ADD COLUMN it_dag_probe uuid;
    ALTER TABLE sales.invoice ADD CONSTRAINT it_dag_probe_ok_declared FOREIGN KEY (tenant_id, it_dag_probe) REFERENCES catalog.item (tenant_id, id);
    ALTER TABLE catalog.item ADD COLUMN it_dag_probe uuid;
    ALTER TABLE catalog.item ADD CONSTRAINT it_dag_probe_ok_labelled FOREIGN KEY (tenant_id, it_dag_probe) REFERENCES inventory.warehouse (tenant_id, id);
    COMMENT ON CONSTRAINT it_dag_probe_ok_labelled ON catalog.item IS 'HK_DAG_EXCEPTION: probe';
    SELECT string_agg(x.conname, ',' ORDER BY x.conname) INTO v FROM core.xfk_dag_violations() x WHERE x.conname LIKE 'it_dag_probe%';
    RAISE EXCEPTION 'IT_DAG_PROBE_DONE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'IT_DAG_PROBE_DONE' THEN v := 'probe error: ' || SQLSTATE || ' ' || SQLERRM; END IF;
  END;
  PERFORM it_rec('A', 'A2.dag_lint_flags_same_layer_upward_and_undeclared', v = 'it_dag_probe_1,it_dag_probe_2,it_dag_probe_3,it_dag_probe_4',
                 'expected it_dag_probe_1..4 flagged, got: ' || coalesce(v, '<none flagged>'), 'RV-ARCH-08', 'integration');
END $$;

-- ---------- A3: مالکیت و امتیازهای نقش‌های زمان اجرا؛ جدول‌های فقط‌افزودنی ----------
DO $$
DECLARE v text; v_list text;
BEGIN
  SELECT string_agg(x, ', ' ORDER BY x) INTO v FROM (
    SELECT c.oid::regclass::text || ' (' || r.rolname || ')' AS x
      FROM pg_class c JOIN pg_roles r ON r.oid = c.relowner
     WHERE r.rolname IN ('hk_app','hk_readonly','hk_reports','hk_dispatcher')
    UNION ALL
    SELECT p.oid::regprocedure::text || ' (' || r.rolname || ')'
      FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
     WHERE r.rolname IN ('hk_app','hk_readonly','hk_reports','hk_dispatcher')
    UNION ALL
    SELECT n.nspname || ' (' || r.rolname || ')' FROM pg_namespace n JOIN pg_roles r ON r.oid = n.nspowner
     WHERE r.rolname IN ('hk_app','hk_readonly','hk_reports','hk_dispatcher')
    UNION ALL
    SELECT t.oid::regtype::text || ' (' || r.rolname || ')' FROM pg_type t JOIN pg_roles r ON r.oid = t.typowner
     WHERE r.rolname IN ('hk_app','hk_readonly','hk_reports','hk_dispatcher')) q;
  PERFORM it_rec('A', 'A3.runtime_roles_own_nothing', v IS NULL, 'objects owned by a runtime role: ' || v);

  SELECT string_agg(r.rolname, ', ') INTO v FROM pg_roles r
   WHERE r.rolname IN ('hk_app','hk_readonly','hk_reports','hk_dispatcher','hk_audit_writer','hk_core_definer',
                       'hk_ledger_definer','hk_inventory_definer')
     AND (r.rolsuper OR r.rolbypassrls OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication);
  PERFORM it_rec('A', 'A3.runtime_roles_unprivileged', v IS NULL, 'runtime/definer roles with SUPERUSER/BYPASSRLS/CREATE*: ' || v);

  -- بدون TRUNCATE، REFERENCES یا TRIGGER روی هیچ جدول (این‌ها از RLS عبور می‌کنند یا کد اجرا می‌کنند)
  SELECT string_agg(c.oid::regclass || ':' || r.rolname || ':' || pr.p, ', ' ORDER BY 1) INTO v
    FROM pg_class c JOIN public.it_dp_schemas() s ON s.oid = c.relnamespace
    CROSS JOIN (VALUES ('hk_app'), ('hk_readonly'), ('hk_reports'), ('hk_dispatcher')) r(rolname)
    CROSS JOIN (VALUES ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) pr(p)
   WHERE c.relkind IN ('r','p','v','m','f')
     AND CASE pr.p WHEN 'REFERENCES' THEN has_any_column_privilege(r.rolname, c.oid, 'REFERENCES')
                   ELSE has_table_privilege(r.rolname, c.oid, pr.p) END;
  PERFORM it_rec('A', 'A3.no_truncate_references_trigger', v IS NULL, 'runtime roles holding TRUNCATE/REFERENCES/TRIGGER: ' || v);

  -- hk_readonly/hk_reports هیچ نوشتنی ندارند
  SELECT string_agg(c.oid::regclass || ':' || r.rolname, ', ' ORDER BY 1) INTO v
    FROM pg_class c JOIN public.it_dp_schemas() s ON s.oid = c.relnamespace
    CROSS JOIN (VALUES ('hk_readonly'), ('hk_reports')) r(rolname)
   WHERE c.relkind IN ('r','p','v')
     AND (has_table_privilege(r.rolname, c.oid, 'INSERT') OR has_any_column_privilege(r.rolname, c.oid, 'UPDATE')
          OR has_table_privilege(r.rolname, c.oid, 'DELETE'));
  PERFORM it_rec('A', 'A3.readonly_has_no_write', v IS NULL, 'read-only roles with write privileges: ' || v);

  -- فقط‌افزودنی (۱): هر جدول با تریگر سطری core.forbid_mutation روی UPDATE/DELETE → hk_app همان امتیاز را ندارد
  SELECT string_agg(x, ', ' ORDER BY x) INTO v FROM (
    SELECT tg.tgrelid::regclass || ':UPDATE' AS x FROM pg_trigger tg
     WHERE tg.tgfoid = 'core.forbid_mutation'::regproc AND NOT tg.tgisinternal AND (tg.tgtype & 1) = 1 AND (tg.tgtype & 16) <> 0
       AND tg.tgqual IS NULL AND tg.tgattr = ''::int2vector AND has_any_column_privilege('hk_app', tg.tgrelid, 'UPDATE')
    UNION
    SELECT tg.tgrelid::regclass || ':DELETE' FROM pg_trigger tg
     WHERE tg.tgfoid = 'core.forbid_mutation'::regproc AND NOT tg.tgisinternal AND (tg.tgtype & 1) = 1 AND (tg.tgtype & 8) <> 0
       AND tg.tgqual IS NULL AND has_table_privilege('hk_app', tg.tgrelid, 'DELETE')) q;
  PERFORM it_rec('A', 'A3.append_only_grants_match_triggers', v IS NULL, 'hk_app holds UPDATE/DELETE on append-only tables: ' || v);
  -- فقط‌افزودنی (۲): فهرست مستند (۰۲ D-AUD، ۰۳ D-L07، ۰۵ D-C01، ۰۶ D-T03/§۴، ۰۷ D-CMP-200، ۰۹/۱۰ نیست) ←
  -- هر کدام تریگر forbid_mutation برای DELETE (و جز ستون‌های گذار مستند، برای UPDATE) و TRUNCATE دارد
  CREATE TEMP TABLE it_ao_doc (rel text PRIMARY KEY, need_update_block boolean NOT NULL, src text NOT NULL) ON COMMIT DROP;
  INSERT INTO it_ao_doc VALUES
    ('core.audit_log', true, '02 D-AUD'), ('core.number_issued', true, '02 NUM'), ('core.approval_decision', true, '02 APR'),
    ('core.setting_history', true, '02 SET'), ('core.outbox_event', true, '02 OBX (DELETE فقط purge dispatcher)'),
    ('ledger.journal_line', true, '03 D-L07'), ('ledger.period_status_event', true, '03 D-L09'),
    ('ledger.journal', false, '03 D-L07 (فقط گذار وضعیت)'),
    ('inventory.stock_move', true, '05 D-C01'), ('inventory.valuation_layer', true, '05 D-C01'),
    ('sales.credit_check', true, '05 D-C18'),
    ('treasury.cheque_event', true, '06 D-T03'), ('treasury.allocation', false, '06 D-T01 (فقط گذار ابطال)'),
    ('pos.device_command', true, '06 INV-SYNC'), ('pos.ticket', false, '06 INV-POS-08 (فقط پیوندهای ثبت)'),
    ('pos.ticket_line', false, '06 INV-POS-08'), ('pos.ticket_payment', false, '06 INV-POS-08'),
    ('rules.param_value', true, '07 l.200'), ('rules.golden_test', true, '07 l.200'), ('rules.golden_run', true, '07 l.200'),
    ('rules.package_event', true, '07 l.200'), ('rules.calc_snapshot', true, '07 l.200'), ('tax.invoice_issue_line', true, '07 l.200'),
    ('tax.submission_attempt', true, '07 l.200'), ('tax.inquiry_log', true, '07 l.200'), ('payroll.clock_event', true, '07 l.200'),
    ('payroll.accrual_entry', true, '07 l.200'), ('payroll.leave_entry', true, '07 l.200'), ('payroll.gov_file_part', true, '07 l.200'),
    ('assets.asset_txn', true, '07 l.200'), ('assets.asset_movement', true, '07 l.200'), ('rules.tenant_pack_event', true, '07 l.200');
  SELECT string_agg(d.rel || ' [' || d.src || ']: ' ||
           concat_ws('/', CASE WHEN to_regclass(d.rel) IS NULL THEN 'missing table' END,
             CASE WHEN NOT EXISTS (SELECT 1 FROM pg_trigger tg WHERE tg.tgrelid = to_regclass(d.rel) AND NOT tg.tgisinternal
                                     AND (tg.tgtype & 1) = 1 AND (tg.tgtype & 8) <> 0
                                     AND tg.tgfoid = 'core.forbid_mutation'::regproc)
                       AND d.rel <> 'core.outbox_event' THEN 'no DELETE guard' END,
             CASE WHEN d.need_update_block AND NOT EXISTS (SELECT 1 FROM pg_trigger tg WHERE tg.tgrelid = to_regclass(d.rel) AND NOT tg.tgisinternal
                                     AND (tg.tgtype & 1) = 1 AND (tg.tgtype & 16) <> 0
                                     AND tg.tgfoid = 'core.forbid_mutation'::regproc) THEN 'no UPDATE guard' END,
             CASE WHEN NOT EXISTS (SELECT 1 FROM pg_trigger tg WHERE tg.tgrelid = to_regclass(d.rel) AND NOT tg.tgisinternal
                                     AND (tg.tgtype & 32) <> 0) THEN 'no TRUNCATE guard' END,
             CASE WHEN has_table_privilege('hk_app', to_regclass(d.rel), 'DELETE') THEN 'hk_app DELETE' END,
             CASE WHEN d.need_update_block AND has_any_column_privilege('hk_app', to_regclass(d.rel), 'UPDATE') THEN 'hk_app UPDATE' END),
         '; ' ORDER BY d.rel) INTO v
    FROM it_ao_doc d
   WHERE to_regclass(d.rel) IS NULL
      OR (NOT EXISTS (SELECT 1 FROM pg_trigger tg WHERE tg.tgrelid = to_regclass(d.rel) AND NOT tg.tgisinternal
                        AND (tg.tgtype & 1) = 1 AND (tg.tgtype & 8) <> 0 AND tg.tgfoid = 'core.forbid_mutation'::regproc)
          AND d.rel <> 'core.outbox_event')
      OR (d.need_update_block AND NOT EXISTS (SELECT 1 FROM pg_trigger tg WHERE tg.tgrelid = to_regclass(d.rel) AND NOT tg.tgisinternal
                        AND (tg.tgtype & 1) = 1 AND (tg.tgtype & 16) <> 0 AND tg.tgfoid = 'core.forbid_mutation'::regproc))
      OR NOT EXISTS (SELECT 1 FROM pg_trigger tg WHERE tg.tgrelid = to_regclass(d.rel) AND NOT tg.tgisinternal AND (tg.tgtype & 32) <> 0)
      OR has_table_privilege('hk_app', to_regclass(d.rel), 'DELETE')
      OR (d.need_update_block AND has_any_column_privilege('hk_app', to_regclass(d.rel), 'UPDATE'));
  PERFORM it_rec('A', 'A3.documented_append_only_enforced', v IS NULL, 'documented append-only tables not enforced: ' || v);
END $$;

-- ---------- A4: هر ویو security_invoker؛ هیچ materialized view ----------
DO $$
DECLARE v text;
BEGIN
  SELECT string_agg(c.oid::regclass::text, ', ' ORDER BY 1) INTO v
    FROM pg_class c JOIN public.it_dp_schemas() s ON s.oid = c.relnamespace
   WHERE c.relkind = 'v'
     AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(c.reloptions, '{}')) o
                      WHERE lower(o) IN ('security_invoker=true','security_invoker=on','security_invoker=1'));
  PERFORM it_rec('A', 'A4.views_security_invoker', v IS NULL, 'views without security_invoker (allowlist is empty, 01 D-32): ' || v);
  SELECT string_agg(c.oid::regclass::text, ', ' ORDER BY 1) INTO v
    FROM pg_class c JOIN public.it_dp_schemas() s ON s.oid = c.relnamespace WHERE c.relkind = 'm';
  PERFORM it_rec('A', 'A4.no_materialized_views', v IS NULL, 'materialized views on tenant data (01 D-32): ' || v);
END $$;

-- ---------- A5: SECURITY DEFINER فقط از فهرست مجاز مستند و با پنج شرط D-32 ----------
-- فهرست مجاز از متن طراحی (deploy/ci/secdef-allowlist.toml هنوز نیست):
--   02 §4-3/D-02: core.audit_seal (hk_audit_writer)، core.auth_resolve_login/api_key/token (hk_core_definer)
--   03 D-L24: ledger.bucket_from_lines، compact_balance_buckets، rebuild_balance_buckets (hk_ledger_definer)
--   05 D-C02/CR-C04: ده تابع inventory (hk_inventory_definer)
--   06، 07 (D-CMP «هیچ»)، 08، 10 (§4 «هیچ»): هیچ
DO $$
DECLARE v text;
BEGIN
  CREATE TEMP TABLE it_secdef_allow (fn text PRIMARY KEY, owner text NOT NULL, tenant_free boolean NOT NULL) ON COMMIT DROP;
  INSERT INTO it_secdef_allow VALUES
    ('core.audit_seal', 'hk_audit_writer', false),
    ('core.auth_resolve_login', 'hk_core_definer', true),     -- پیش از تعیین مستأجر (ورود)؛ فقط شناسه برمی‌گرداند
    ('core.auth_resolve_api_key', 'hk_core_definer', true),
    ('core.auth_resolve_token', 'hk_core_definer', true),
    ('ledger.bucket_from_lines', 'hk_ledger_definer', false), ('ledger.compact_balance_buckets', 'hk_ledger_definer', false),
    ('ledger.rebuild_balance_buckets', 'hk_ledger_definer', false),
    ('inventory.pool_acquire', 'hk_inventory_definer', false), ('inventory.fifo_take', 'hk_inventory_definer', false),
    ('inventory.valuate', 'hk_inventory_definer', false), ('inventory.stock_move_after', 'hk_inventory_definer', false),
    ('inventory.serial_move_after', 'hk_inventory_definer', false), ('inventory.add_cost_adjustment', 'hk_inventory_definer', false),
    ('inventory.repost_pool', 'hk_inventory_definer', false), ('inventory.create_checkpoint', 'hk_inventory_definer', false),
    ('inventory.verify_pool_replay', 'hk_inventory_definer', false), ('inventory.rebuild_derived', 'hk_inventory_definer', false);
  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY 1) INTO v
    FROM pg_proc p JOIN public.it_dp_schemas() s ON s.oid = p.pronamespace
   WHERE p.prosecdef AND (s.nspname || '.' || p.proname) NOT IN (SELECT fn FROM it_secdef_allow);
  PERFORM it_rec('A', 'A5.secdef_only_allowlisted', v IS NULL, 'SECURITY DEFINER functions not on the documented allowlist: ' || v);
  SELECT string_agg(p.oid::regprocedure || ' [' ||
           concat_ws(',', CASE WHEN r.rolname <> a.owner THEN 'owner=' || r.rolname END,
                          CASE WHEN r.rolcanlogin OR r.rolbypassrls OR r.rolsuper THEN 'owner LOGIN/BYPASSRLS' END,
                          CASE WHEN coalesce(p.proconfig, '{}') <> ARRAY['search_path=pg_catalog, pg_temp'] THEN 'search_path=' || coalesce(array_to_string(p.proconfig, ';'), 'none') END,
                          CASE WHEN has_function_privilege('public', p.oid, 'EXECUTE') THEN 'EXECUTE to PUBLIC' END,
                          CASE WHEN coalesce(obj_description(p.oid, 'pg_proc'), '') NOT LIKE 'HK_DEFINER_REVIEWED:%' THEN 'not reviewed' END,
                          CASE WHEN NOT a.tenant_free AND p.prorettype <> 'trigger'::regtype
                                    AND has_function_privilege('hk_app', p.oid, 'EXECUTE')
                                    AND pg_get_functiondef(p.oid) !~ '(current_tenant_id|require_tenant|assert_tenant)' THEN 'no tenant check' END,
                          CASE WHEN pg_get_functiondef(p.oid) ~* '\mEXECUTE\s+(format|''|\$|[a-z_]+\s*(\|\||;))' THEN 'dynamic SQL' END)
           || ']', ', ' ORDER BY 1) INTO v
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace JOIN pg_roles r ON r.oid = p.proowner
    JOIN it_secdef_allow a ON a.fn = n.nspname || '.' || p.proname
   WHERE p.prosecdef
     AND (r.rolname <> a.owner OR r.rolcanlogin OR r.rolbypassrls OR r.rolsuper
          OR coalesce(p.proconfig, '{}') <> ARRAY['search_path=pg_catalog, pg_temp']
          OR has_function_privilege('public', p.oid, 'EXECUTE')
          OR coalesce(obj_description(p.oid, 'pg_proc'), '') NOT LIKE 'HK_DEFINER_REVIEWED:%'
          OR (NOT a.tenant_free AND p.prorettype <> 'trigger'::regtype AND has_function_privilege('hk_app', p.oid, 'EXECUTE')
              AND pg_get_functiondef(p.oid) !~ '(current_tenant_id|require_tenant|assert_tenant)')
          OR pg_get_functiondef(p.oid) ~* '\mEXECUTE\s+(format|''|\$|[a-z_]+\s*(\|\||;))');
  PERFORM it_rec('A', 'A5.secdef_d32_conditions', v IS NULL, 'allowlisted SECURITY DEFINER functions breaking a D-32 condition: ' || v);
  -- توابع definer داخلی که p_tenant می‌گیرند برای hk_app قابل اجرا نیستند (۰۵ CR-C04)
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v
    FROM pg_proc p JOIN public.it_dp_schemas() s ON s.oid = p.pronamespace
   WHERE p.prosecdef AND 'p_tenant' = ANY (p.proargnames) AND has_function_privilege('hk_app', p.oid, 'EXECUTE');
  PERFORM it_rec('A', 'A5.secdef_tenant_param_not_callable', v IS NULL, 'definer functions taking p_tenant executable by hk_app: ' || v);
END $$;

-- ---------- A6: هر جدول مستأجری در رجیستری صدور (R-EXPORT) و رجیستری بی‌ردیف مرده ----------
DO $$
DECLARE v text; n int;
BEGIN
  SELECT count(*), string_agg(t.rel::text, ', ' ORDER BY t.rel::text) INTO n, v FROM public.it_tenant_tables() t
   WHERE NOT EXISTS (SELECT 1 FROM core.export_table_registry r WHERE r.schema_name = t.nspname AND r.table_name = t.relname);
  PERFORM it_rec('A', 'A6.tenant_tables_in_export_registry', v IS NULL,
                 n || ' tenant tables missing from core.export_table_registry (tenant export/move would drop them): ' || v,
                 'RV-IT-01', 'masterdata');
  SELECT string_agg(r.schema_name || '.' || r.table_name, ', ' ORDER BY 1) INTO v FROM core.export_table_registry r
   WHERE to_regclass(quote_ident(r.schema_name) || '.' || quote_ident(r.table_name)) IS NULL;
  PERFORM it_rec('A', 'A6.export_registry_no_stale_rows', v IS NULL, 'export registry rows naming tables that do not exist: ' || v);
  SELECT string_agg(r.schema_name || '.' || r.table_name || '.' || c, ', ' ORDER BY 1) INTO v
    FROM core.export_table_registry r CROSS JOIN LATERAL unnest(r.secret_columns || r.pii_columns) c
   WHERE to_regclass(quote_ident(r.schema_name) || '.' || quote_ident(r.table_name)) IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = to_regclass(quote_ident(r.schema_name) || '.' || quote_ident(r.table_name))
                       AND a.attname = c AND NOT a.attisdropped);
  PERFORM it_rec('A', 'A6.export_registry_columns_exist', v IS NULL, 'secret/pii columns in the registry that do not exist: ' || v);
END $$;

-- ---------- A7: core.security_lint() خالی ----------
DO $$
DECLARE v text; n int;
BEGIN
  SELECT count(*), string_agg(object || '|' || problem, ', ' ORDER BY 1) INTO n, v FROM core.security_lint();
  PERFORM it_rec('A', 'A7.core_security_lint_empty', n = 0, n || ' rows: ' || left(v, 3000), 'RV-IT-01', 'masterdata');
  -- security_lint فهرست ثابت اسکیما دارد؛ هر اسکیمای صفحهٔ داده باید در آن باشد (C-AS-04 / RV-IT-05)
  SELECT string_agg(s.nspname, ', ') INTO v FROM public.it_dp_schemas() s
   WHERE pg_get_functiondef('core.security_lint'::regproc) !~ ('''' || s.nspname || '''');
  PERFORM it_rec('A', 'A7.security_lint_covers_all_schemas', v IS NULL, 'schemas not linted by core.security_lint(): ' || v,
                 'RV-IT-05', 'core');
END $$;

-- ---------- A8: hk_readonly/hk_reports ستون‌های راز را نمی‌خوانند ----------
-- مرجع راز: export_table_registry.secret_columns + هر ستون با الگوی نام راز (hash رمز/PIN/توکن/کد، کلید خصوصی، مُهرشده)
-- 02 INV-IAM-11 و R-GRANT. hash زنجیره/محتوا (row_hash، request_hash، …) راز نیست و در الگو نمی‌آید.
CREATE OR REPLACE FUNCTION public.it_owner(p_schema text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_schema WHEN 'core' THEN 'core' WHEN 'ledger' THEN 'ledger' WHEN 'parties' THEN 'masterdata' WHEN 'catalog' THEN 'masterdata'
         WHEN 'ref' THEN 'masterdata' WHEN 'inventory' THEN 'commerce' WHEN 'sales' THEN 'commerce' WHEN 'purchase' THEN 'commerce'
         WHEN 'treasury' THEN 'treasury_pos' WHEN 'pos' THEN 'treasury_pos' WHEN 'tax' THEN 'compliance' WHEN 'payroll' THEN 'compliance'
         WHEN 'assets' THEN 'compliance' WHEN 'rules' THEN 'compliance' WHEN 'migration' THEN 'migration' WHEN 'assistant' THEN 'assistant'
         ELSE 'integration' END
$$;
CREATE OR REPLACE FUNCTION public.it_secret_columns() RETURNS TABLE (rel regclass, nspname name, relname name, col name)
LANGUAGE sql STABLE AS $$
  SELECT c.oid::regclass, s.nspname, c.relname, a.attname
    FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN public.it_dp_schemas() s ON s.oid = c.relnamespace
   WHERE c.relkind IN ('r','p','v') AND a.attnum > 0 AND NOT a.attisdropped
     AND a.attname ~ '(password_hash|secret_hash|pin_hash|token_hash|code_hash|_sealed|secret_enc|private_key|totp_key_ref|totp_last_step|secret_ref|_secret)$'
     AND a.attname <> 'is_secret'
  UNION
  SELECT to_regclass(quote_ident(e.schema_name) || '.' || quote_ident(e.table_name)), e.schema_name::name, e.table_name::name, x::name
    FROM core.export_table_registry e CROSS JOIN LATERAL unnest(e.secret_columns) x
   WHERE to_regclass(quote_ident(e.schema_name) || '.' || quote_ident(e.table_name)) IS NOT NULL
$$;
GRANT EXECUTE ON FUNCTION public.it_owner(text), public.it_secret_columns() TO hk_app, hk_readonly;
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT public.it_owner(x.nspname) AS owner,
                  string_agg(DISTINCT x.rel || '.' || x.col || ':' || ro.rolname, ', ') AS v
             FROM public.it_secret_columns() x CROSS JOIN (VALUES ('hk_readonly'), ('hk_reports')) ro(rolname)
            WHERE has_column_privilege(ro.rolname, x.rel, x.col, 'SELECT')
            GROUP BY 1 LOOP
    PERFORM it_rec('A', 'A8.readonly_cannot_read_secrets[' || r.owner || ']', false, 'secret columns readable by read-only roles: ' || r.v,
                   CASE r.owner WHEN 'treasury_pos' THEN 'RV-IT2-11' END, r.owner);
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM public.it_secret_columns() x CROSS JOIN (VALUES ('hk_readonly'), ('hk_reports')) ro(rolname)
                  WHERE has_column_privilege(ro.rolname, x.rel, x.col, 'SELECT')) THEN
    PERFORM it_rec('A', 'A8.readonly_cannot_read_secrets', true);
  END IF;
  -- هر ستون راز جدول مستأجری در secret_columns رجیستری آمده (وگرنه صدور مستأجر hash/راز را بی‌مُهر بیرون می‌برد)
  FOR r IN SELECT public.it_owner(x.nspname) AS owner, string_agg(x.rel || '.' || x.col, ', ' ORDER BY 1) AS v
             FROM public.it_secret_columns() x JOIN public.it_tenant_tables() t ON t.rel = x.rel
             JOIN core.export_table_registry e ON e.schema_name = t.nspname AND e.table_name = t.relname
            WHERE e.mode <> 'skip' AND NOT x.col = ANY (e.secret_columns)
            GROUP BY 1 LOOP
    PERFORM it_rec('A', 'A8.secret_columns_registered[' || r.owner || ']', false,
                   'secret columns exported in clear (not in export_table_registry.secret_columns): ' || r.v,
                   CASE r.owner WHEN 'treasury_pos' THEN 'RV-IT2-11' WHEN 'core' THEN 'RV-IT2-12' END, r.owner);
  END LOOP;
  IF NOT FOUND THEN PERFORM it_rec('A', 'A8.secret_columns_registered', true); END IF;
END $$;

-- =====================================================================
-- بخش B.1: fixture دو مستأجر (postgres) — همان چیزی که provisioning پنل مالک و ماژول‌های پایه می‌سازند
--   مستأجر، شرکت، شعبه، کاربر و عضویت (R-ACTOR)، دستگاه صندوق، سری‌های شماره، اشخاص، کالا، حافظهٔ مالیاتی.
--   هر چیز دیگر را جریان‌های بخش C با hk_app می‌سازند (برای هر دو مستأجر).
-- =====================================================================
DO $$
DECLARE x text; v_t uuid; v_co uuid; v_br uuid; v_u1 uuid; v_u2 uuid; v_dev uuid; n text;
BEGIN
  FOREACH x IN ARRAY ARRAY['A','B'] LOOP
    FOREACH n IN ARRAY ARRAY['T','CO','BR','U1','U2','DEV','NS.PINV','NS.SINV','NS.SRET','NS.RCPT','NS.POS','NS.TAXSER','NS.JRN',
                             'CUST','SUP','WALK','UOM','IPG','ITEM','VAR','MEM','WH','BANK','DRAWER','CASH','TERM','BD','SHIFT'] LOOP
      INSERT INTO public.it_key VALUES (x || '.' || n, uuidv7()) ON CONFLICT (name) DO NOTHING;
    END LOOP;
    v_t := it_k(x || '.T'); v_co := it_k(x || '.CO'); v_br := it_k(x || '.BR'); v_u1 := it_k(x || '.U1'); v_u2 := it_k(x || '.U2');
    v_dev := it_k(x || '.DEV');
    INSERT INTO core.tenant (id, slug, display_name) VALUES (v_t, 'it2-tenant-' || lower(x), 'مستأجر آزمون ' || x);
    INSERT INTO core.company (tenant_id, id, code, name, legal_name, national_id, economic_code)
    VALUES (v_t, v_co, 'CO', 'شرکت ' || x, 'شرکت آزمون ' || x, '14003778990', '14003778990');
    INSERT INTO core.branch (tenant_id, id, company_id, code, name) VALUES (v_t, v_br, v_co, 'BR1', 'شعبهٔ مرکزی');
    INSERT INTO core.app_user (id, display_name) VALUES (v_u1, 'مالک ' || x), (v_u2, 'صندوقدار ' || x);
    INSERT INTO core.tenant_membership (tenant_id, user_id, status, is_owner, joined_at)
    VALUES (v_t, v_u1, 'active', true, now()), (v_t, v_u2, 'active', false, now());
    INSERT INTO core.device (tenant_id, id, company_id, branch_id, kind, name, key_alg, public_key, status, registered_by, activated_at)
    VALUES (v_t, v_dev, v_co, v_br, 'pos', 'صندوق ۱', 'ed25519',
            decode(CASE x WHEN 'A' THEN repeat('a1', 32) ELSE repeat('b1', 32) END, 'hex'), 'active', v_u1, now());
    INSERT INTO core.number_series (tenant_id, id, company_id, code, name, doc_type, scope, branch_id, device_id, allocation, pattern, reset_policy, is_default) VALUES
      (v_t, it_k(x || '.NS.PINV'),   v_co, 'pinv', 'فاکتور خرید',  'purchase.invoice', 'company', NULL, NULL, 'server', 'PI-{seq}', 'never', true),
      (v_t, it_k(x || '.NS.SINV'),   v_co, 'sinv', 'فاکتور فروش',  'sales.invoice',    'company', NULL, NULL, 'server', 'SI-{seq}', 'never', true),
      (v_t, it_k(x || '.NS.SRET'),   v_co, 'sret', 'برگشت فروش',   'sales.return',     'company', NULL, NULL, 'server', 'SR-{seq}', 'never', true),
      (v_t, it_k(x || '.NS.RCPT'),   v_co, 'rcpt', 'سند دریافت',   'treasury.receipt', 'company', NULL, NULL, 'server', 'RC-{seq}', 'never', true),
      (v_t, it_k(x || '.NS.JRN'),    v_co, 'jrn',  'سند حسابداری', 'ledger.journal',   'company', NULL, NULL, 'server', '{seq}',    'fiscal_year', true),
      (v_t, it_k(x || '.NS.TAXSER'), v_co, 'taxser', 'سریال مؤدیان', 'tax.moadian_serial', 'company', NULL, NULL, 'server', '{seq}', 'never', false),
      (v_t, it_k(x || '.NS.POS'),    v_co, 'pos.d1', 'رسید صندوق ۱', 'pos.ticket', 'device', v_br, v_dev, 'device', x || '1-{seq:6}', 'never', false);
    INSERT INTO parties.party (tenant_id, id, code, person_type, name, national_id, national_id_status, economic_code, is_anonymous, created_by) VALUES
      (v_t, it_k(x || '.CUST'), 'C001', 'legal',   'مشتری حقوقی ' || x, '14003778990', 'valid', '14003778990', false, v_u1),
      (v_t, it_k(x || '.SUP'),  'S001', 'legal',   'تأمین‌کننده ' || x,  NULL, NULL, NULL, false, v_u1),
      (v_t, it_k(x || '.WALK'), 'WALK', 'natural', 'مشتری عمومی ' || x, NULL, NULL, NULL, true, v_u1);
    INSERT INTO catalog.uom (tenant_id, id, code, name, dimension, dimension_factor, qty_decimals, moadian_unit_code)
    VALUES (v_t, it_k(x || '.UOM'), 'PCS', 'عدد', 'count', 1, 0, '1627');
    INSERT INTO catalog.item_posting_group (tenant_id, id, code, name) VALUES (v_t, it_k(x || '.IPG'), 'GOODS', 'کالای تجاری');
    INSERT INTO catalog.item (tenant_id, id, code, name, item_type, base_uom_id, posting_group_id, sstid, sstid_kind, created_by)
    VALUES (v_t, it_k(x || '.ITEM'), 'GOODS1', 'کالای یک', 'stock', it_k(x || '.UOM'), it_k(x || '.IPG'), '2710000138624', 'general', v_u1);
    INSERT INTO catalog.item_uom (tenant_id, item_id, uom_id, factor, is_base) VALUES (v_t, it_k(x || '.ITEM'), it_k(x || '.UOM'), 1, true);
    INSERT INTO catalog.item_variant (tenant_id, id, item_id, code, is_default) VALUES (v_t, it_k(x || '.VAR'), it_k(x || '.ITEM'), 'GOODS1', true);
    INSERT INTO tax.memory (tenant_id, id, company_id, memory_id, label, send_mode, adapter, environment, key_custody, allocation, serial_series_id, created_by)
    VALUES (v_t, it_k(x || '.MEM'), v_co, CASE x WHEN 'A' THEN 'DEF5GH' ELSE 'A2HP31' END, 'حافظهٔ اصلی', 'taxpayer', 'direct_v1_self_tsp',
            'production', 'server_kms', 'server', it_k(x || '.NS.TAXSER'), v_u1);
  END LOOP;
END $$;
-- =====================================================================
-- بخش C: جریان‌های کسب‌وکاری سرتاسری (کمک‌تابع‌ها با postgres ساخته می‌شوند، SECURITY INVOKER؛ با hk_app اجرا)
-- =====================================================================
RESET ROLE;

-- ثبت سند حسابداری مثل LedgerPostingService.post (۰۳ §۵-۴): حساب از کلید با ledger.resolve_account (یا account_id صریح)،
-- بُعد شخص از ledger.dimension_value(party_id)، شمارهٔ عطف از core.number_next(سری ledger.journal، 'fy:'+سال)،
-- سرسند با مقادیر کنترلی، سپس سطرها در یک دستور. سطرها: [{"key"|"acct", "dr"|"cr", "party", "dim1", "attrs"}]
CREATE OR REPLACE FUNCTION public.it_jr(p_x text, p_date date, p_module text, p_doc_type text, p_doc_id uuid, p_event text,
                                        p_lines jsonb, p_type text DEFAULT 'module') RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid := uuidv7(); v_co uuid := it_k(p_x || '.CO'); v_fy uuid; n record; v_tot numeric; v_cnt int;
BEGIN
  SELECT f.id INTO v_fy FROM ledger.fiscal_year f WHERE f.company_id = v_co AND p_date BETWEEN f.start_date AND f.end_date;
  SELECT * INTO n FROM core.number_next(it_k(p_x || '.NS.JRN'), 'fy:' || v_fy, '{seq}', 'ledger.journal', v_id);
  SELECT coalesce(sum((l->>'dr')::numeric), 0), count(*) INTO v_tot, v_cnt FROM jsonb_array_elements(p_lines) l;
  INSERT INTO ledger.journal (tenant_id, id, company_id, fiscal_year_id, journal_date, journal_type, status, reference_no, reference_text,
                              number_issued_id, source_module, source_doc_type, source_doc_id, source_event, base_currency, line_count,
                              total_debit_base, total_credit_base, description)
  VALUES (core.current_tenant_id(), v_id, v_co, v_fy, p_date, p_type, 'temporary', n.value, n.formatted, n.number_id,
          p_module, p_doc_type, p_doc_id, p_event, 'IRR', v_cnt, v_tot, v_tot, 'آزمون یکپارچه: ' || p_doc_type);
  INSERT INTO ledger.journal_line (tenant_id, journal_id, line_no, account_id, branch_id, dim1_id, currency, exchange_rate,
                                   debit_txn, credit_txn, debit_base, credit_base, posting_key)
  SELECT core.current_tenant_id(), v_id, o.ord::int, a.id,
         CASE WHEN a.branch_rule <> 'forbidden' THEN it_k(p_x || '.BR') END,
         coalesce((o.l->>'dim1')::uuid,
                  (SELECT dv.id FROM ledger.dimension_value dv WHERE dv.party_id = (o.l->>'party')::uuid AND dv.merged_into_id IS NULL)),
         'IRR', 1,
         coalesce((o.l->>'dr')::numeric, 0), coalesce((o.l->>'cr')::numeric, 0),
         coalesce((o.l->>'dr')::numeric, 0), coalesce((o.l->>'cr')::numeric, 0),
         o.l->>'key'
    FROM jsonb_array_elements(p_lines) WITH ORDINALITY o(l, ord)
    JOIN ledger.account a ON a.id = coalesce((o.l->>'acct')::uuid,
           (SELECT r.account_id FROM ledger.resolve_account(v_co, o.l->>'key', p_date, coalesce(o.l->'attrs', '{}'::jsonb)) r));
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.it_acct(p_x text, p_key text, p_date date DEFAULT DATE '2026-05-01', p_attrs jsonb DEFAULT '{}')
RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT r.account_id FROM ledger.resolve_account(it_k(p_x || '.CO'), p_key, p_date, p_attrs) r
$$;
CREATE OR REPLACE FUNCTION public.it_pdim(p_party uuid) RETURNS uuid
LANGUAGE sql STABLE AS $$ SELECT id FROM ledger.dimension_value WHERE party_id = p_party AND merged_into_id IS NULL $$;
-- ماندهٔ GL یک حساب (بدهکار − بستانکار) تا تاریخ، اختیاری با بُعد جایگاه ۱
CREATE OR REPLACE FUNCTION public.it_gl(p_x text, p_acct uuid, p_as_of date DEFAULT DATE '2027-03-20', p_dim1 uuid DEFAULT NULL)
RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT coalesce(sum(l.debit_base - l.credit_base), 0) FROM ledger.journal_line l
   WHERE l.company_id = it_k(p_x || '.CO') AND l.account_id = p_acct AND l.journal_date <= p_as_of
     AND (p_dim1 IS NULL OR l.dim1_id = p_dim1)
$$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO hk_app, hk_readonly;

-- ---------- C0: راه‌اندازی شرکت با نقش برنامه (هر دو مستأجر) ----------
-- ledger.provision_tenant + apply_coa_template('ir.general', 1) + سال مالی ۱۴۰۵ و ۱۲ دوره (۰۳ §۵-۷)،
-- بُعد شخص برای هر شخص (۰۴ §۳ «شخص = بُعد»؛ در تولید subscriber رویداد party.created)، سیاست موجودی و انبار (۰۵)،
-- حساب بانک/کشوی صندوق با بُعد (۰۶ T00)، پایانهٔ صندوق، وضعیت همگام‌سازی، روز کاری و شیفت (۰۶ §۵).
CREATE OR REPLACE FUNCTION public.it_c0_setup(x text) RETURNS void
LANGUAGE plpgsql AS $f$
DECLARE v_t uuid; v_co uuid; v_br uuid; v_fy uuid := NULL; d date; i int;
        lens int[] := ARRAY[31,31,31,31,31,31,30,30,30,30,30,29]; v_dt uuid; v_p uuid; v_err text;
BEGIN
    v_t := it_k(x || '.T'); v_co := it_k(x || '.CO'); v_br := it_k(x || '.BR');
    PERFORM ledger.provision_tenant();
    PERFORM ledger.apply_coa_template(v_co, 'ir.general', 1);
    v_fy := uuidv7(); d := DATE '2026-03-21';
    INSERT INTO ledger.fiscal_year (tenant_id, id, company_id, code, name, start_date, end_date, base_currency)
    VALUES (v_t, v_fy, v_co, '1405', 'سال ۱۴۰۵', d, d + 364, 'IRR');
    FOR i IN 1..12 LOOP
      INSERT INTO ledger.fiscal_period (tenant_id, company_id, fiscal_year_id, period_no, name, start_date, end_date)
      VALUES (v_t, v_co, v_fy, i, 'ماه ' || i, d, d + lens[i] - 1);
      d := d + lens[i];
    END LOOP;
    SELECT id INTO v_dt FROM ledger.dimension_type WHERE code = 'party';
    FOREACH v_p IN ARRAY ARRAY[it_k(x || '.CUST'), it_k(x || '.SUP'), it_k(x || '.WALK')] LOOP
      INSERT INTO ledger.dimension_value (tenant_id, dimension_type_id, slot, code, name, source_module, source_entity_id)
      SELECT v_t, v_dt, 1, p.code, p.name, 'parties', p.id FROM parties.party p WHERE p.id = v_p;
    END LOOP;
    INSERT INTO inventory.company_policy (tenant_id, company_id, effective_from, valuation_method, inventory_mode, cost_pool_scope)
    VALUES (v_t, v_co, DATE '2026-03-21', 'moving_average', 'perpetual', 'company');
    INSERT INTO inventory.warehouse (tenant_id, id, company_id, branch_id, code, name, kind, negative_policy)
    VALUES (v_t, it_k(x || '.WH'), v_co, v_br, 'W1', 'انبار اصلی', 'standard', 'inherit');
    INSERT INTO treasury.bank_account (tenant_id, id, company_id, code, name, bank_code, sheba, account_type)
    VALUES (v_t, it_k(x || '.BANK'), v_co, 'BK1', 'بانک ملت جاری', 'mellat', 'IR350120000000000001234567', 'current');
    INSERT INTO treasury.cash_box (tenant_id, id, company_id, branch_id, code, name, kind) VALUES
      (v_t, it_k(x || '.DRAWER'), v_co, v_br, 'POS1', 'کشوی صندوق ۱', 'pos_drawer'),
      (v_t, it_k(x || '.CASH'),   v_co, v_br, 'MAIN', 'صندوق اصلی', 'main');
    INSERT INTO ledger.dimension_value (tenant_id, id, dimension_type_id, slot, code, name, source_module, source_entity_id)
    SELECT v_t, uuidv7(), dt.id, dt.slot, e.code, e.code, 'treasury', e.id
      FROM (VALUES ('bank_account', it_k(x || '.BANK'), 'BK1'), ('cash_box', it_k(x || '.DRAWER'), 'POS1'), ('cash_box', it_k(x || '.CASH'), 'MAIN')) e(t, id, code)
      JOIN ledger.dimension_type dt ON dt.code = e.t;
    UPDATE treasury.bank_account b SET dimension_value_id = dv.id FROM ledger.dimension_value dv
     WHERE dv.source_entity_id = b.id AND b.id = it_k(x || '.BANK');
    UPDATE treasury.cash_box b SET dimension_value_id = dv.id FROM ledger.dimension_value dv
     WHERE dv.source_entity_id = b.id AND b.id IN (it_k(x || '.DRAWER'), it_k(x || '.CASH'));
    INSERT INTO pos.terminal (tenant_id, id, company_id, branch_id, code, name, device_id, cash_box_id, receipt_series_id, walk_in_party_id, service_modes)
    VALUES (v_t, it_k(x || '.TERM'), v_co, v_br, 'T1', 'صندوق ۱', it_k(x || '.DEV'), it_k(x || '.DRAWER'), it_k(x || '.NS.POS'), it_k(x || '.WALK'), '{retail}');
    INSERT INTO pos.device_sync_state (tenant_id, device_id, terminal_id, last_hash)
    VALUES (v_t, it_k(x || '.DEV'), it_k(x || '.TERM'), pos.genesis_hash(it_k(x || '.DEV')));
    INSERT INTO pos.business_day (tenant_id, id, company_id, branch_id, business_date, opened_at, opened_by)
    VALUES (v_t, it_k(x || '.BD'), v_co, v_br, DATE '2026-05-20', timestamptz '2026-05-20 08:00+03:30', it_k(x || '.U2'));
    INSERT INTO pos.shift (tenant_id, id, company_id, branch_id, terminal_id, business_day_id, cash_box_id, opened_by, opened_at, opening_float, open_cmd_id)
    VALUES (v_t, it_k(x || '.SHIFT'), v_co, v_br, it_k(x || '.TERM'), it_k(x || '.BD'), it_k(x || '.DRAWER'), it_k(x || '.U2'),
            timestamptz '2026-05-20 08:05+03:30', 0, uuidv7());
END $f$;
GRANT EXECUTE ON FUNCTION public.it_c0_setup(text) TO hk_app;
SET ROLE hk_app;
DO $$ BEGIN PERFORM it_ctx('A'); PERFORM it_c0_setup('A'); END $$;
DO $$ BEGIN PERFORM it_ctx('B'); PERFORM it_c0_setup('B'); END $$;


DO $$
DECLARE x text; n int;
BEGIN
  FOREACH x IN ARRAY ARRAY['A','B'] LOOP
    PERFORM set_config('app.tenant_id', it_k(x || '.T')::text, true);
    SELECT count(*) INTO n FROM ledger.account WHERE company_id = it_k(x || '.CO');
    PERFORM it_rec('C', 'C0.setup[' || x || '] chart applied and year open', n > 0
                   AND (SELECT status FROM ledger.fiscal_year WHERE company_id = it_k(x || '.CO')) = 'open'
                   AND (SELECT count(*) FROM ledger.fiscal_period p JOIN ledger.fiscal_year f ON f.id = p.fiscal_year_id
                         WHERE f.company_id = it_k(x || '.CO')) = 12, n || ' accounts');
  END LOOP;
END $$;

-- ---------- C0b: قراردادهای راه‌اندازی بین بخش‌ها (کدینگ پیش‌فرض ↔ کلیدهای ثبت ماژول‌ها ↔ زیردفترها) ----------
RESET ROLE;
CREATE OR REPLACE FUNCTION public.it_resolve_err(p_co uuid, p_key text) RETURNS text
LANGUAGE plpgsql STABLE AS $$
BEGIN
  PERFORM 1 FROM ledger.resolve_account(p_co, p_key, DATE '2026-05-01', '{}'::jsonb);
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN RETURN SQLERRM;
END $$;
GRANT EXECUTE ON FUNCTION public.it_resolve_err(uuid, text) TO hk_app;
SET ROLE hk_app;
DO $$
DECLARE v text; r record; v_err text;
BEGIN
  PERFORM it_ctx('A');
  -- (۱) هر کلید ثبتی که بخش‌ها در ledger.posting_key ثبت کرده‌اند در کدینگ پیش‌فرض ir.general نگاشت دارد
  --     (وگرنه جریان v1 مالک آن کلید روی شرکت تازه با HK_LEDGER_MAPPING_MISSING می‌ایستد)
  FOR r IN SELECT k.owner_module, string_agg(k.key, ', ' ORDER BY k.key) AS keys
             FROM ledger.posting_key k WHERE it_resolve_err(it_k('A.CO'), k.key) IS NOT NULL GROUP BY 1 ORDER BY 1 LOOP
    PERFORM it_rec('C', 'C0.default_chart_maps_' || r.owner_module || '_keys', false,
                   'ir.general v1 has no posting rule for: ' || r.keys, 'RV-IT2-03', 'ledger');
  END LOOP;
  IF NOT FOUND THEN PERFORM it_rec('C', 'C0.default_chart_maps_every_posting_key', true); END IF;
  -- (۲) سند GL فاکتور خرید/فروش با سطر موجودی در همان PostingRequest (۰۵ §۵-۶، §۵-۷ گام ۵؛ D-C13) را ledger می‌پذیرد
  v_err := it_try_rollback($q$SELECT it_jr('A', DATE '2026-05-01', 'purchase', 'purchase.invoice', uuidv7(), 'post',
             jsonb_build_array(jsonb_build_object('key','inventory.asset','dr',1000), jsonb_build_object('key','tax.vat_receivable','dr',100),
                               jsonb_build_object('key','purchase.payable','cr',1100,'party',it_k('A.SUP'))))$q$);
  PERFORM it_rec('C', 'C0.ledger_accepts_purchase_journal_with_inventory_line', v_err IS NULL,
                 'documented purchase-invoice journal (Dr inventory.asset / Dr tax.vat_receivable / Cr purchase.payable, source_module=purchase) rejected: ' || v_err,
                 'RV-IT2-01', 'commerce');
  v_err := it_try_rollback($q$SELECT it_jr('A', DATE '2026-05-01', 'sales', 'sales.invoice', uuidv7(), 'post',
             jsonb_build_array(jsonb_build_object('key','sales.receivable','dr',1100,'party',it_k('A.CUST')),
                               jsonb_build_object('key','sales.revenue','cr',1000), jsonb_build_object('key','tax.vat_payable','cr',100),
                               jsonb_build_object('key','inventory.cogs','dr',600), jsonb_build_object('key','inventory.asset','cr',600)))$q$);
  PERFORM it_rec('C', 'C0.ledger_accepts_sales_journal_with_cogs_lines', v_err IS NULL,
                 'documented sales-invoice journal with COGS / inventory lines (source_module=sales) rejected: ' || v_err,
                 'RV-IT2-01', 'commerce');
  -- (۳) هر subledger_kind که کدینگ روی حساب کنترلی گذاشته در ledger.subledger_source ثبت شده (وگرنه check_control_accounts آن را
  --     بی‌صدا رد می‌کند؛ ۰۳ §۵-۱۴ «party: sales، purchase، parties»، ۰۶ D-T01 «زیردفتر اقلام باز مال treasury»)
  SELECT string_agg(DISTINCT a.subledger_kind || ' (' || a.code || ')', ', ') INTO v FROM ledger.account a
   WHERE a.company_id = it_k('A.CO') AND a.subledger_kind IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM ledger.subledger_source s WHERE s.subledger_kind = a.subledger_kind);
  PERFORM it_rec('C', 'C0.every_control_account_kind_has_a_subledger', v IS NULL,
                 'control accounts whose subledger_kind has no ledger.subledger_source row (never reconciled): ' || v, 'RV-IT2-04', 'treasury_pos');
END $$;

-- راه گریز برای ادامهٔ جریان‌های پایین‌دست (نه قرارداد مستند): پیکربندی مستأجر حساب کنترلی موجودی را برای ماژول‌های sales و
-- purchase باز می‌کند تا سند مستند ۰۵ §۵-۶ ثبت شود (پیشنهاد رفع RV-IT2-01 گزینهٔ «داده»). اگر hk_app این حق را ندارد، یافته است.
DO $$
DECLARE x text; v_err text;
BEGIN
  PERFORM it_ctx('A');
  v_err := it_try($q$UPDATE ledger.account SET allowed_source_modules = allowed_source_modules || ARRAY['sales','purchase']
                      WHERE company_id = it_k('A.CO') AND posting_policy = 'subledger_only' AND subledger_kind = 'inventory'
                        AND NOT ('sales' = ANY (allowed_source_modules))$q$);
  PERFORM it_rec('C', 'C0.workaround_inventory_account_open_to_commerce[A]', v_err IS NULL, v_err);
END $$;
DO $$
DECLARE v_err text;
BEGIN
  PERFORM it_ctx('B');
  v_err := it_try($q$UPDATE ledger.account SET allowed_source_modules = allowed_source_modules || ARRAY['sales','purchase']
                      WHERE company_id = it_k('B.CO') AND posting_policy = 'subledger_only' AND subledger_kind = 'inventory'
                        AND NOT ('sales' = ANY (allowed_source_modules))$q$);
  PERFORM it_rec('C', 'C0.workaround_inventory_account_open_to_commerce[B]', v_err IS NULL, v_err);
END $$;

-- ---------- C1: فاکتور خرید مستقیم کالا ثبت → ورود انبار + GL + قلم باز تأمین‌کننده (۰۵ §۵-۶ «فاکتور خرید مستقیم کالا»، §۵-۱۰؛ ۰۶ D-T01) ----------
-- PurchaseInvoiceService.post: شماره (core.number_next) ← حرکت انبار receipt با بهای ورودی و asset_account_id حل‌شده (D-C13)
-- ← LedgerPostingService.post (یک سند: بد موجودی / بد مالیات خرید / بس پرداختنی [شخص]) ← OpenItemService.register ← وضعیت posted.
RESET ROLE;
CREATE OR REPLACE FUNCTION public.it_c1_purchase(x text, p_qty numeric, p_unit numeric, p_date date) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_inv uuid := uuidv7(); v_line uuid := uuidv7(); v_move uuid := uuidv7(); n record; v_j uuid; v_acct uuid;
        v_net numeric := p_qty * p_unit; v_vat numeric := trunc(p_qty * p_unit * 10 / 100); v_co uuid := it_k(x || '.CO');
BEGIN
  INSERT INTO purchase.invoice (tenant_id, id, company_id, branch_id, doc_kind, doc_date, supplier_party_id, supplier_invoice_no,
                                currency, currency_minor, stock_mode, warehouse_id, channel)
  VALUES (core.current_tenant_id(), v_inv, v_co, it_k(x || '.BR'), 'invoice', p_date, it_k(x || '.SUP'), 'F-' || substr(v_inv::text, 25),
          'IRR', 0, 'immediate', it_k(x || '.WH'), 'manual');
  INSERT INTO purchase.invoice_line (tenant_id, id, invoice_id, line_no, item_id, variant_id, uom_id, qty, qty_base, unit_price,
                                     gross_amount, net_amount, vat_rate, vat_amount, line_total)
  VALUES (core.current_tenant_id(), v_line, v_inv, 1, it_k(x || '.ITEM'), it_k(x || '.VAR'), it_k(x || '.UOM'), p_qty, p_qty, p_unit,
          v_net, v_net, 10, v_vat, v_net + v_vat);
  UPDATE purchase.invoice SET gross_amount = v_net, net_amount = v_net, vat_amount = v_vat, total_amount = v_net + v_vat,
         total_base = v_net + v_vat WHERE id = v_inv;
  SELECT * INTO n FROM core.number_next(it_k(x || '.NS.PINV'), 'all', 'PI-{seq}', 'purchase.invoice', v_inv);
  v_acct := it_acct(x, 'inventory.asset', p_date, jsonb_build_object('item_posting_group', 'GOODS', 'warehouse', 'W1'));
  INSERT INTO inventory.stock_move (tenant_id, id, company_id, branch_id, warehouse_id, item_id, variant_id, move_date, move_kind, qty_base,
                                    uom_id, qty_uom, valuation_rule, input_value, input_cost_status, party_id, asset_account_id,
                                    source_module, source_doc_type, source_doc_id, source_line_id, origin)
  VALUES (core.current_tenant_id(), v_move, v_co, it_k(x || '.BR'), it_k(x || '.WH'), it_k(x || '.ITEM'), it_k(x || '.VAR'), p_date,
          'receipt', p_qty, it_k(x || '.UOM'), p_qty, 'input', v_net, 'known', it_k(x || '.SUP'), v_acct,
          'purchase', 'purchase.invoice', v_inv, v_line, 'online');
  v_j := it_jr(x, p_date, 'purchase', 'purchase.invoice', v_inv, 'post', jsonb_build_array(
           jsonb_build_object('acct', v_acct, 'key', 'inventory.asset', 'dr', v_net),
           jsonb_build_object('key', 'tax.vat_receivable', 'dr', v_vat),
           jsonb_build_object('key', 'purchase.payable', 'cr', v_net + v_vat, 'party', it_k(x || '.SUP'))));
  INSERT INTO treasury.open_item (tenant_id, company_id, branch_id, party_id, party_role, account_class, direction, source_module, source_doc_type,
                                  source_doc_id, source_doc_no, doc_date, due_date, currency, amount, amount_base, journal_id)
  VALUES (core.current_tenant_id(), v_co, it_k(x || '.BR'), it_k(x || '.SUP'), 'supplier', 'payable', 'credit', 'purchase', 'purchase.invoice',
          v_inv, n.formatted, p_date, p_date + 30, 'IRR', v_net + v_vat, v_net + v_vat, v_j);
  UPDATE purchase.invoice SET status = 'posted', posted_at = now(), number_issued_id = n.number_id, doc_no = n.formatted,
         gl_status = 'posted', gl_journal_id = v_j WHERE id = v_inv;
  INSERT INTO public.it_key VALUES (x || '.PINV1', v_inv) ON CONFLICT (name) DO UPDATE SET id = EXCLUDED.id;
  RETURN v_inv;
END $$;

-- ---------- C2: فاکتور فروش با ارزش افزوده ثبت → درآمد/مالیات/دریافتنی + بهای تمام‌شده + خروج انبار + سند مؤدیان (۰۵ §۵-۷) ----------
CREATE OR REPLACE FUNCTION public.it_c2_sales(x text, p_qty numeric, p_price numeric, p_date date, p_key text, p_opts jsonb DEFAULT '{}') RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_inv uuid := uuidv7(); v_line uuid := uuidv7(); v_move uuid := uuidv7(); n record; v_j uuid; v_acct uuid; v_cogs numeric;
        v_gross numeric := trunc(p_qty * p_price); v_vat numeric := trunc(trunc(p_qty * p_price) * 10 / 100);
        v_co uuid := it_k(x || '.CO'); v_tax uuid := uuidv7();
BEGIN
  INSERT INTO sales.invoice (tenant_id, id, company_id, branch_id, doc_kind, status, doc_date, number_source, customer_party_id,
                             buyer_person_type, buyer_economic_code, buyer_national_id, buyer_postal_code, currency, currency_minor,
                             exchange_rate, prices_include_tax, settlement_method, stock_mode, warehouse_id, moadian_required,
                             moadian_type, moadian_pattern, tax_snapshot, channel, gl_mode, created_by)
  VALUES (core.current_tenant_id(), v_inv, v_co, it_k(x || '.BR'), 'invoice', 'draft', p_date, 'server', it_k(x || '.CUST'),
          'legal', '14003778990', NULL, NULL, 'IRR', 0, 1, false, 'credit', 'immediate', it_k(x || '.WH'), true, 1, 1,
          '{"vat_rule":"rules:vat.standard_rate"}', 'invoice', 'per_document', it_k(x || '.U1'));
  INSERT INTO sales.invoice_line (tenant_id, id, invoice_id, line_no, item_id, variant_id, uom_id, qty, qty_base, unit_price, currency_minor,
                                  gross_amount, line_discount_amount, invoice_discount_alloc, discount_amount, net_amount, tax_rounding,
                                  vat_rate, vat_amount, other_tax_rate, other_tax_amount, other_levy_rate, other_levy_amount, line_total,
                                  sstid, moadian_unit_code, price_source, moadian_extra)
  VALUES (core.current_tenant_id(), v_line, v_inv, 1, it_k(x || '.ITEM'), it_k(x || '.VAR'), it_k(x || '.UOM'), p_qty, p_qty, p_price, 0,
          v_gross, 0, 0, 0, v_gross, 'truncate', 10, v_vat, 0, 0, 0, 0, v_gross + v_vat, '2710000138624', '1627', 'price_list', '{}');
  UPDATE sales.invoice SET gross_amount = v_gross, net_amount = v_gross, vat_amount = v_vat, total_amount = v_gross + v_vat,
         total_base = v_gross + v_vat WHERE id = v_inv;
  -- (۳) شماره
  SELECT * INTO n FROM core.number_next(it_k(x || '.NS.SINV'), 'all', 'SI-{seq}', 'sales.invoice', v_inv);
  -- (۴) کالا: StockPostingService.post_moves — حساب موجودی پیش از درج روی حرکت (D-C13)
  v_acct := it_acct(x, 'inventory.asset', p_date, jsonb_build_object('item_posting_group', 'GOODS', 'warehouse', 'W1'));
  INSERT INTO inventory.stock_move (tenant_id, id, company_id, branch_id, warehouse_id, item_id, variant_id, move_date, move_kind, qty_base,
                                    uom_id, qty_uom, valuation_rule, party_id, asset_account_id, source_module, source_doc_type,
                                    source_doc_id, source_line_id, origin)
  VALUES (core.current_tenant_id(), v_move, v_co, it_k(x || '.BR'), it_k(x || '.WH'), it_k(x || '.ITEM'), it_k(x || '.VAR'), p_date,
          'sale_issue', -p_qty, it_k(x || '.UOM'), p_qty, 'pool_out', it_k(x || '.CUST'), v_acct, 'sales', 'sales.invoice', v_inv, v_line, 'online');
  SELECT -coalesce(sum(value), 0) INTO v_cogs FROM inventory.valuation_layer WHERE move_id = v_move;
  -- (۵) GL: بد دریافتنی (کل) / بس درآمد (ناخالص) / بس مالیات فروش / بد بهای تمام‌شده / بس موجودی (ارزش خروج) — ۰۵ §۵-۶
  IF p_opts->>'gl' = 'one_rial' THEN   -- فقط کاوش C7: سند همان مبدأ با مبلغ نادرست (مثل c_journal در 30_commerce_test)
    v_j := it_jr(x, p_date, 'sales', 'sales.invoice', v_inv, 'post', jsonb_build_array(
             jsonb_build_object('key', 'sales.receivable', 'dr', 1, 'party', it_k(x || '.CUST')), jsonb_build_object('key', 'sales.revenue', 'cr', 1)));
  ELSE
  v_j := it_jr(x, p_date, 'sales', 'sales.invoice', v_inv, 'post', jsonb_build_array(
           jsonb_build_object('key', 'sales.receivable', 'dr', v_gross + v_vat, 'party', it_k(x || '.CUST')),
           jsonb_build_object('key', 'sales.revenue', 'cr', v_gross),
           jsonb_build_object('key', 'tax.vat_payable', 'cr', v_vat),
           jsonb_build_object('key', 'inventory.cogs', 'dr', v_cogs),
           jsonb_build_object('acct', v_acct, 'key', 'inventory.asset', 'cr', v_cogs)));
  END IF;
  -- (۶) قلم باز دریافتنی
  INSERT INTO treasury.open_item (tenant_id, company_id, branch_id, party_id, party_role, account_class, direction, source_module, source_doc_type,
                                  source_doc_id, source_doc_no, doc_date, due_date, currency, amount, amount_base, journal_id)
  VALUES (core.current_tenant_id(), v_co, it_k(x || '.BR'), it_k(x || '.CUST'), 'customer', 'receivable', 'debit', 'sales', 'sales.invoice',
          v_inv, n.formatted, p_date, p_date + 30, 'IRR', v_gross + v_vat, v_gross + v_vat, v_j);
  -- (۷) سند مؤدیان (TaxDocumentService.create_for_sales؛ پیش‌نویس، ارسال async)
  IF p_opts ? 'tax_doc_of' THEN         -- فقط کاوش C7: سند مؤدیانِ فاکتور دیگر
    SELECT tax_document_id INTO v_tax FROM sales.invoice WHERE id = it_k(x || '.' || (p_opts->>'tax_doc_of'));
  ELSE
  INSERT INTO tax.invoice (tenant_id, id, company_id, memory_ref, source_kind, sales_invoice_id, source_doc_no, subject, inv_type, pattern,
                           instruction_version, status, created_by)
  VALUES (core.current_tenant_id(), v_tax, v_co, it_k(x || '.MEM'), 'sales_invoice', v_inv, n.formatted, 1, 1, 1, 'RC_IITP.IS-1', 'pending',
          it_k(x || '.U1'));
  END IF;
  -- (۸) سرسند
  UPDATE sales.invoice SET status = 'posted', number_issued_id = n.number_id, doc_no = n.formatted, issued_at = now(), posted_at = now(),
         posted_by = it_k(x || '.U1'), gl_journal_id = v_j, tax_document_id = v_tax WHERE id = v_inv;
  INSERT INTO public.it_key VALUES (x || '.' || p_key, v_inv) ON CONFLICT (name) DO UPDATE SET id = EXCLUDED.id;
  RETURN v_inv;
END $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO hk_app;
SET ROLE hk_app;
DO $$ DECLARE v text; BEGIN PERFORM it_ctx('A');
  v := it_try($q$SELECT it_c1_purchase('A', 10, 1000000, DATE '2026-05-01')$q$);
  PERFORM it_rec('C', 'C1.purchase_invoice_posted[A]', v IS NULL, v); END $$;
DO $$ DECLARE v text; BEGIN PERFORM it_ctx('B');
  v := it_try($q$SELECT it_c1_purchase('B', 10, 1000000, DATE '2026-05-01')$q$);
  PERFORM it_rec('C', 'C1.purchase_invoice_posted[B]', v IS NULL, v); END $$;
DO $$ DECLARE v text; BEGIN PERFORM it_ctx('A');
  v := it_try($q$SELECT it_c2_sales('A', 4, 3000000, DATE '2026-05-10', 'SINV1')$q$);
  PERFORM it_rec('C', 'C2.sales_invoice_posted[A]', v IS NULL, v); END $$;
DO $$ DECLARE v text; BEGIN PERFORM it_ctx('B');
  v := it_try($q$SELECT it_c2_sales('B', 4, 3000000, DATE '2026-05-10', 'SINV1')$q$);
  PERFORM it_rec('C', 'C2.sales_invoice_posted[B]', v IS NULL, v); END $$;

-- ---------- C1/C2 راستی‌آزمایی: مبالغ GL، زیردفتر موجودی، اقلام باز، پیوند دوطرفهٔ فروش ↔ مؤدیان ----------
DO $$
DECLARE x text; v_inv sales.invoice; v_pinv purchase.invoice; v_bad text; v_n int; v_ar numeric; v_oi numeric; v_inv_gl numeric; v_sub numeric;
BEGIN
  FOREACH x IN ARRAY ARRAY['A','B'] LOOP
    PERFORM set_config('app.tenant_id', it_k(x || '.T')::text, true);
    SELECT * INTO v_pinv FROM purchase.invoice WHERE id = it_k(x || '.PINV1');
    SELECT * INTO v_inv FROM sales.invoice WHERE id = it_k(x || '.SINV1');
    PERFORM it_rec('C', 'C1.purchase GL = invoice totals [' || x || ']',
      it_gl(x, it_acct(x, 'purchase.payable'), DATE '2026-05-01', it_pdim(it_k(x || '.SUP'))) = -v_pinv.total_amount
      AND it_gl(x, it_acct(x, 'tax.vat_receivable'), DATE '2026-05-01') = v_pinv.vat_amount,
      format('payable %s vs total %s', it_gl(x, it_acct(x, 'purchase.payable'), DATE '2026-05-01'), v_pinv.total_amount));
    PERFORM it_rec('C', 'C2.sales GL = invoice totals [' || x || ']',
      it_gl(x, it_acct(x, 'sales.receivable'), DATE '2026-05-10', it_pdim(it_k(x || '.CUST'))) = v_inv.total_amount
      AND it_gl(x, it_acct(x, 'sales.revenue'), DATE '2026-05-10') = -v_inv.gross_amount
      AND it_gl(x, it_acct(x, 'tax.vat_payable'), DATE '2026-05-10') = -v_inv.vat_amount
      AND v_inv.total_amount = 13200000 AND v_inv.vat_amount = 1200000,
      format('AR %s revenue %s vat %s', it_gl(x, it_acct(x, 'sales.receivable'), DATE '2026-05-10'),
             it_gl(x, it_acct(x, 'sales.revenue'), DATE '2026-05-10'), it_gl(x, it_acct(x, 'tax.vat_payable'), DATE '2026-05-10')));
    PERFORM it_rec('C', 'C2.COGS = moving-average cost of issued qty [' || x || ']',
      it_gl(x, it_acct(x, 'inventory.cogs'), DATE '2026-05-10') = 4000000
      AND it_gl(x, it_acct(x, 'inventory.asset'), DATE '2026-05-10') = 6000000,
      format('cogs %s inventory %s', it_gl(x, it_acct(x, 'inventory.cogs'), DATE '2026-05-10'), it_gl(x, it_acct(x, 'inventory.asset'), DATE '2026-05-10')));
    SELECT coalesce(sum(qty_base), 0) INTO v_sub FROM inventory.stock_move WHERE company_id = it_k(x || '.CO') AND variant_id = it_k(x || '.VAR');
    PERFORM it_rec('C', 'C2.stock quantity after purchase and sale [' || x || ']', v_sub = 6, 'qty ' || v_sub);
    -- زیردفتر موجودی = GL (۰۵ INV-INV-35)
    SELECT count(*), string_agg(subledger_kind || ':' || coalesce(gl_base, 0) || '/' || coalesce(sub_base, 0), ', ') INTO v_n, v_bad
      FROM ledger.check_control_accounts(it_k(x || '.CO'), DATE '2026-05-10') WHERE subledger_kind = 'inventory';
    PERFORM it_rec('C', 'C2.inventory subledger reconciles to GL [' || x || ']', v_n = 0, v_bad);
    -- زیردفتر اقلام باز = GL به تفکیک شخص (۰۶ D-T01؛ تطبیق مستقیم چون نوع party ثبت نشده — RV-IT2-04)
    SELECT coalesce(sum(CASE direction WHEN 'debit' THEN amount_base - allocated_amount ELSE -(amount_base - allocated_amount) END), 0) INTO v_oi
      FROM treasury.open_item WHERE company_id = it_k(x || '.CO') AND party_id = it_k(x || '.CUST') AND account_class = 'receivable' AND status <> 'cancelled';
    v_ar := it_gl(x, it_acct(x, 'sales.receivable'), DATE '2026-05-10', it_pdim(it_k(x || '.CUST')));
    PERFORM it_rec('C', 'C2.open items = GL receivable for the customer [' || x || ']', v_oi = v_ar, format('open items %s GL %s', v_oi, v_ar));
    -- پیوند دوطرفهٔ فروش ↔ سند مؤدیان
    PERFORM it_rec('C', 'C2.sales invoice <-> tax document link [' || x || ']',
      (SELECT t.sales_invoice_id FROM tax.invoice t WHERE t.id = v_inv.tax_document_id) = v_inv.id, NULL);
  END LOOP;
END $$;

-- RV-IT2-04 شاهد: سند دستی روی دریافتنی تجاری بدون قلم باز؛ check_control_accounts هیچ اختلافی گزارش نمی‌کند
DO $$
DECLARE v_n int; v_err text;
BEGIN
  PERFORM it_ctx('A');
  BEGIN
    PERFORM it_jr('A', DATE '2026-05-11', 'ledger', 'ledger.manual', uuidv7(), 'post', jsonb_build_array(
              jsonb_build_object('key', 'sales.receivable', 'dr', 777, 'party', it_k('A.CUST')),
              jsonb_build_object('key', 'sales.revenue', 'cr', 777)), 'manual');
    SELECT count(*) INTO v_n FROM ledger.check_control_accounts(it_k('A.CO'), DATE '2026-05-11');
    RAISE EXCEPTION 'IT_ROLLBACK:%', v_n;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'IT_ROLLBACK:%' THEN v_err := SQLERRM; END IF;
    v_n := CASE WHEN SQLERRM LIKE 'IT_ROLLBACK:%' THEN split_part(SQLERRM, ':', 2)::int END;
  END;
  PERFORM it_rec('C', 'C2.receivable drift without an open item is detected by ledger.check_control_accounts', v_n > 0,
                 coalesce(v_err, 'manual journal Dr 1201 [customer] 777 / Cr 6101 left AR GL <> open items, check_control_accounts returned ' || v_n || ' rows'),
                 'RV-IT2-04', 'treasury_pos');
END $$;

-- ---------- C3: دریافت از مشتری با چک → ثبت چک (R1) → واگذاری به بانک (R2) → وصول (R3) → GL؛ تسویهٔ قلم باز (۰۶ §۵، D-T09) ----------
-- ReceiptService (MoneyDocumentService.create_and_post) + ChequeService.receive/deposit/collect + OpenItemService.allocate
RESET ROLE;
CREATE OR REPLACE FUNCTION public.it_c3_cheque(x text, p_sayad text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_doc uuid := uuidv7(); v_chq uuid := uuidv7(); n record; v_j1 uuid; v_j2 uuid; v_j3 uuid; v_co uuid := it_k(x || '.CO');
        v_amt numeric; v_inv uuid := it_k(x || '.SINV1'); v_rcpt_item uuid := uuidv7(); v_bank uuid := it_k(x || '.BANK'); v_bdim uuid;
        v_hold uuid; v_coll uuid;
BEGIN
  SELECT total_amount INTO v_amt FROM sales.invoice WHERE id = v_inv;
  SELECT dimension_value_id INTO v_bdim FROM treasury.bank_account WHERE id = v_bank;
  v_hold := it_acct(x, 'treasury.cheque_receivable', DATE '2026-05-15'); v_coll := it_acct(x, 'treasury.cheque_in_collection', DATE '2026-05-20');
  -- سند دریافت (پیش‌نویس) با ابزار «چک» و طرف «مشتری»
  INSERT INTO treasury.money_document (tenant_id, id, company_id, branch_id, direction, doc_date, party_id, total_amount, created_by)
  VALUES (core.current_tenant_id(), v_doc, v_co, it_k(x || '.BR'), 'receipt', DATE '2026-05-15', it_k(x || '.CUST'), v_amt, it_k(x || '.U1'));
  INSERT INTO treasury.cheque (tenant_id, id, company_id, branch_id, direction, purpose, state, medium, sayad_id, amount, amount_base,
                               issue_date, due_date, drawer_name, received_from_party_id, sayad_state, origin, money_document_id, created_by)
  VALUES (core.current_tenant_id(), v_chq, v_co, it_k(x || '.BR'), 'received', 'payment', 'in_hand', 'electronic', p_sayad, v_amt, v_amt,
          DATE '2026-05-15', DATE '2026-06-15', 'مشتری حقوقی', it_k(x || '.CUST'), 'not_inquired', 'receipt', v_doc, it_k(x || '.U1'));
  INSERT INTO treasury.money_instrument (tenant_id, document_id, line_no, kind, amount, cheque_id)
  VALUES (core.current_tenant_id(), v_doc, 1, 'cheque', v_amt, v_chq);
  INSERT INTO treasury.money_counter_line (tenant_id, document_id, line_no, kind, party_id, party_role, amount)
  VALUES (core.current_tenant_id(), v_doc, 1, 'party', it_k(x || '.CUST'), 'customer', v_amt);
  -- R1: بد اسناد دریافتنی [شخص] / بس دریافتنی تجاری [شخص] (قالب کاتالوگ: @holding / @counter)
  v_j1 := it_jr(x, DATE '2026-05-15', 'treasury', 'treasury.receipt', v_doc, 'post', jsonb_build_array(
            jsonb_build_object('acct', v_hold, 'key', 'treasury.cheque_receivable', 'dr', v_amt, 'party', it_k(x || '.CUST')),
            jsonb_build_object('key', 'sales.receivable', 'cr', v_amt, 'party', it_k(x || '.CUST'))));
  INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, to_state, event_date, collected_after, long_term_after,
                                     journal_id, money_document_id, holding_account_id, holding_dim_value_id, holding_amount, holding_amount_base, actor_id)
  VALUES (core.current_tenant_id(), v_chq, 1, 'transition', 'R1', 'in_hand', DATE '2026-05-15', 0, false, v_j1, v_doc,
          v_hold, it_pdim(it_k(x || '.CUST')), v_amt, v_amt, it_k(x || '.U1'));
  SELECT * INTO n FROM core.number_next(it_k(x || '.NS.RCPT'), 'all', 'RC-{seq}', 'treasury.receipt', v_doc);
  UPDATE treasury.money_document SET status = 'posted', journal_id = v_j1, number_issued_id = n.number_id, doc_no = n.formatted,
         posted_at = now(), posted_by = it_k(x || '.U1') WHERE id = v_doc;
  -- قلم باز بستانکار دریافت و تخصیص به قلم بدهکار فاکتور
  INSERT INTO treasury.open_item (tenant_id, id, company_id, branch_id, party_id, party_role, account_class, direction, source_module, source_doc_type,
                                  source_doc_id, source_doc_no, doc_date, due_date, currency, amount, amount_base, journal_id)
  VALUES (core.current_tenant_id(), v_rcpt_item, v_co, it_k(x || '.BR'), it_k(x || '.CUST'), 'customer', 'receivable', 'credit', 'treasury',
          'treasury.receipt', v_doc, n.formatted, DATE '2026-05-15', DATE '2026-05-15', 'IRR', v_amt, v_amt, v_j1);
  INSERT INTO treasury.allocation (tenant_id, company_id, debit_item_id, credit_item_id, amount, currency, allocation_date, created_by)
  SELECT core.current_tenant_id(), v_co, oi.id, v_rcpt_item, v_amt, 'IRR', DATE '2026-05-15', it_k(x || '.U1')
    FROM treasury.open_item oi WHERE oi.source_doc_id = v_inv AND oi.direction = 'debit';
  -- R2: واگذاری به بانک — بد در جریان وصول [بانک] / بس اسناد دریافتنی [شخص]
  v_j2 := it_jr(x, DATE '2026-05-20', 'treasury', 'treasury.cheque', v_chq, lower('R2:2'), jsonb_build_array(
            jsonb_build_object('acct', v_coll, 'key', 'treasury.cheque_in_collection', 'dr', v_amt, 'dim1', v_bdim),
            jsonb_build_object('acct', v_hold, 'key', 'treasury.cheque_receivable', 'cr', v_amt, 'party', it_k(x || '.CUST'))));
  INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date, collected_after, long_term_after,
                                     journal_id, bank_account_id, deposit_bank_after, holding_account_id, holding_dim_value_id, holding_amount, holding_amount_base, actor_id)
  VALUES (core.current_tenant_id(), v_chq, 2, 'transition', 'R2', 'in_hand', 'deposited', DATE '2026-05-20', 0, false,
          v_j2, v_bank, v_bank, v_coll, v_bdim, v_amt, v_amt, it_k(x || '.U1'));
  -- R3: وصول — بد بانک [بانک] / بس در جریان وصول [بانک]
  v_j3 := it_jr(x, DATE '2026-06-16', 'treasury', 'treasury.cheque', v_chq, lower('R3:3'), jsonb_build_array(
            jsonb_build_object('key', 'treasury.bank', 'dr', v_amt, 'dim1', v_bdim),
            jsonb_build_object('acct', v_coll, 'key', 'treasury.cheque_in_collection', 'cr', v_amt, 'dim1', v_bdim)));
  INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date, amount, collected_after,
                                     long_term_after, journal_id, bank_account_id, deposit_bank_after, actor_id)
  VALUES (core.current_tenant_id(), v_chq, 3, 'transition', 'R3', 'deposited', 'collected', DATE '2026-06-16', v_amt, v_amt, false,
          v_j3, v_bank, v_bank, it_k(x || '.U1'));
  INSERT INTO public.it_key VALUES (x || '.CHQ1', v_chq), (x || '.RCPT1', v_doc) ON CONFLICT (name) DO UPDATE SET id = EXCLUDED.id;
  RETURN v_chq;
END $$;
GRANT EXECUTE ON FUNCTION public.it_c3_cheque(text, text) TO hk_app;
SET ROLE hk_app;
-- قرارداد ۰۶ §۵ (ChequeService.transition): PostingRequest(source_doc_type='treasury.cheque', source_event=f'{t.code}:{seq}')؛
-- کد گذار کاتالوگ بزرگ‌حرف است (cheque_transition_code_check '^[A-Z]…') ولی ledger فقط کوچک‌حرف می‌پذیرد (۰۳ §۵-۲ و CHECK
-- journal_source_event_check '^[a-z0-9][a-z0-9_:.-]{0,60}$'). جریان زیر با lower() ادامه می‌دهد (راه گریز، نه قرارداد).
DO $$ DECLARE v text; BEGIN PERFORM it_ctx('A');
  v := it_try_rollback($q$SELECT it_jr('A', DATE '2026-05-20', 'treasury', 'treasury.cheque', uuidv7(), 'R2:2', jsonb_build_array(
         jsonb_build_object('key', 'treasury.bank', 'dr', 10, 'dim1', (SELECT dimension_value_id FROM treasury.bank_account WHERE id = it_k('A.BANK'))),
         jsonb_build_object('key', 'treasury.cash', 'cr', 10, 'dim1', (SELECT dimension_value_id FROM treasury.cash_box WHERE id = it_k('A.CASH')))))$q$);
  PERFORM it_rec('C', 'C3.ledger accepts the documented cheque source_event (R2:2)', v IS NULL,
                 'PostingRequest(source_event=f''{t.code}:{seq}'') from 06 §5 rejected: ' || v, 'RV-IT2-05', 'treasury_pos'); END $$;
DO $$ DECLARE v text; BEGIN PERFORM it_ctx('A');
  v := it_try($q$SELECT it_c3_cheque('A', '1111222233334444')$q$);
  PERFORM it_rec('C', 'C3.cheque receipt -> deposit -> collect posted [A]', v IS NULL, v); END $$;
DO $$ DECLARE v text; BEGIN PERFORM it_ctx('B');
  v := it_try($q$SELECT it_c3_cheque('B', '1111222233334444')$q$);
  PERFORM it_rec('C', 'C3.cheque receipt -> deposit -> collect posted [B]', v IS NULL, v); END $$;

-- C3 راستی‌آزمایی: وضعیت چک، زیردفتر چک = GL در هر سه تاریخ (۰۶ INV-CHQ-14)، بانک، تسویهٔ اقلام باز، دریافتنی صفر
DO $$
DECLARE x text; c treasury.cheque; v_n int; v_bad text; d date; v_bdim uuid;
BEGIN
  FOREACH x IN ARRAY ARRAY['A','B'] LOOP
    PERFORM set_config('app.tenant_id', it_k(x || '.T')::text, true);
    SELECT * INTO c FROM treasury.cheque WHERE id = it_k(x || '.CHQ1');
    SELECT dimension_value_id INTO v_bdim FROM treasury.bank_account WHERE id = it_k(x || '.BANK');
    PERFORM it_rec('C', 'C3.cheque collected via events [' || x || ']',
                   c.state = 'collected' AND c.collected_amount = c.amount AND c.last_event_seq = 3, format('%s %s/%s', c.state, c.collected_amount, c.amount));
    FOREACH d IN ARRAY ARRAY[DATE '2026-05-15', DATE '2026-05-20', DATE '2026-06-16'] LOOP
      SELECT count(*), string_agg(coalesce(gl_base, 0) || '/' || coalesce(sub_base, 0), ', ') INTO v_n, v_bad
        FROM ledger.check_control_accounts(it_k(x || '.CO'), d) WHERE subledger_kind LIKE 'cheque%';
      PERFORM it_rec('C', 'C3.cheque subledger = GL on ' || d || ' [' || x || ']', v_n = 0, v_bad);
    END LOOP;
    PERFORM it_rec('C', 'C3.bank and receivable balances after collection [' || x || ']',
      it_gl(x, it_acct(x, 'treasury.bank'), DATE '2026-06-16', v_bdim) = c.amount
      AND it_gl(x, it_acct(x, 'treasury.cheque_receivable'), DATE '2026-06-16') = 0
      AND it_gl(x, it_acct(x, 'treasury.cheque_in_collection'), DATE '2026-06-16') = 0
      AND it_gl(x, it_acct(x, 'sales.receivable'), DATE '2026-06-16', it_pdim(it_k(x || '.CUST'))) = 0,
      format('bank %s chq %s coll %s AR %s', it_gl(x, it_acct(x, 'treasury.bank'), DATE '2026-06-16', v_bdim),
             it_gl(x, it_acct(x, 'treasury.cheque_receivable'), DATE '2026-06-16'), it_gl(x, it_acct(x, 'treasury.cheque_in_collection'), DATE '2026-06-16'),
             it_gl(x, it_acct(x, 'sales.receivable'), DATE '2026-06-16', it_pdim(it_k(x || '.CUST')))));
    PERFORM it_rec('C', 'C3.invoice and receipt open items closed by allocation [' || x || ']',
      (SELECT count(*) FROM treasury.open_item WHERE party_id = it_k(x || '.CUST') AND status = 'closed') = 2
      AND (SELECT status FROM treasury.money_document WHERE id = it_k(x || '.RCPT1')) = 'posted', NULL);
  END LOOP;
END $$;

-- ---------- C4: رسید صندوق (فرمان امضاشدهٔ دستگاه) → سند فروش (۰۶ §۵ TicketService.ingest، §۵-۲۰؛ ۰۵ §۵-۷ post_from_pos) ----------
RESET ROLE;
CREATE OR REPLACE FUNCTION public.it_c4_ticket(x text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_t uuid := uuidv7(); v_cmd uuid := uuidv7(); v_batch uuid := uuidv7(); v_dev uuid := it_k(x || '.DEV'); s pos.device_sync_state;
        v_body text; v_at timestamptz := timestamptz '2026-05-20 10:00+03:30'; v_num uuid;
BEGIN
  SELECT * INTO s FROM pos.device_sync_state WHERE device_id = v_dev;
  INSERT INTO pos.sync_batch (tenant_id, id, device_id, client_batch_id, device_sent_at, clock_offset_ms, first_seq, last_seq, command_count)
  VALUES (core.current_tenant_id(), v_batch, v_dev, uuidv7(), v_at, 0, s.last_seq + 1, s.last_seq + 1, 1);
  v_body := jsonb_build_object('v', 1, 'cmd_id', v_cmd, 'device_id', v_dev, 'device_seq', s.last_seq + 1, 'type', 'sale.completed',
                               'schema_version', 1, 'occurred_at', to_char(v_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
                               'prev_hash', encode(s.last_hash, 'hex'), 'payload', jsonb_build_object('ticket_id', v_t))::text;
  INSERT INTO pos.device_command (tenant_id, device_id, device_seq, cmd_id, type, schema_version, occurred_at, body, prev_hash, hash, sig,
                                  sig_alg, batch_id, clock_offset_ms)
  VALUES (core.current_tenant_id(), v_dev, s.last_seq + 1, v_cmd, 'sale.completed', 1, v_at, v_body, s.last_hash,
          sha256(convert_to(v_body, 'UTF8')), decode(repeat('ab', 64), 'hex'), 'ed25519', v_batch, 0);
  -- گام ۲: شمارهٔ رسید روی سری دستگاه (doc_type pos.ticket)
  v_num := core.number_record_external(it_k(x || '.NS.POS'), 'all', 1, x || '1-000001', 'pos.ticket', v_t, v_dev);
  -- گام ۳: رسید + سطر + پرداخت نقد
  INSERT INTO pos.ticket (tenant_id, id, company_id, branch_id, terminal_id, shift_id, business_day_id, device_id, cmd_id, kind, order_type,
                          ticket_no, number_issued_id, customer_party_id, subtotal, tax_total, tip_amount, total, occurred_at, cashier_user_id)
  VALUES (core.current_tenant_id(), v_t, it_k(x || '.CO'), it_k(x || '.BR'), it_k(x || '.TERM'), it_k(x || '.SHIFT'), it_k(x || '.BD'),
          v_dev, v_cmd, 'sale', 'retail', x || '1-000001', v_num, it_k(x || '.WALK'), 3000000, 300000, 0, 3300000, v_at, it_k(x || '.U2'));
  INSERT INTO pos.ticket_line (tenant_id, ticket_id, line_no, direction, item_id, variant_id, uom_id, qty, unit_price, price_source,
                               line_gross, line_net, tax_amount)
  VALUES (core.current_tenant_id(), v_t, 1, 'sale', it_k(x || '.ITEM'), it_k(x || '.VAR'), it_k(x || '.UOM'), 1, 3000000, 'list',
          3000000, 3000000, 300000);
  INSERT INTO pos.ticket_payment (tenant_id, ticket_id, line_no, method, amount, tendered, change_given)
  VALUES (core.current_tenant_id(), v_t, 1, 'cash', 3300000, 3500000, 200000);
  INSERT INTO public.it_key VALUES (x || '.TICKET1', v_t) ON CONFLICT (name) DO UPDATE SET id = EXCLUDED.id;
  RETURN v_t;
END $$;

-- گام ۴: SalesInvoiceService.post_from_pos — channel='pos'، number_source='device'، device_id (۰۵ §۵-۷، ۰۶ §۵-۲۰).
-- PosTicketIn شماره‌ای حمل نمی‌کند؛ تنها شمارهٔ دستگاهی موجود، شمارهٔ رسید (doc_type='pos.ticket') است.
CREATE OR REPLACE FUNCTION public.it_c4_post_from_pos(x text, p_ticket uuid, p_number text DEFAULT 'ticket') RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE t pos.ticket; v_inv uuid := uuidv7(); v_line uuid := uuidv7(); v_acct uuid; v_move uuid := uuidv7(); v_cogs numeric; v_j uuid; n record;
BEGIN
  SELECT * INTO t FROM pos.ticket WHERE id = p_ticket;
  INSERT INTO sales.invoice (tenant_id, id, company_id, branch_id, doc_kind, status, doc_date, number_source, device_id, customer_party_id,
                             buyer_person_type, currency, currency_minor, exchange_rate, prices_include_tax, settlement_method, stock_mode,
                             warehouse_id, moadian_required, moadian_type, moadian_pattern, tax_snapshot, channel, source_ref, gl_mode)
  VALUES (core.current_tenant_id(), v_inv, t.company_id, t.branch_id, 'invoice', 'draft', DATE '2026-05-20', 'device', t.device_id,
          t.customer_party_id, 'natural', 'IRR', 0, 1, false, 'cash', 'immediate', it_k(x || '.WH'), true, 2, 1,
          '{"vat_rule":"rules:vat.standard_rate"}', 'pos', 'pos:' || t.cmd_id, 'per_document');
  INSERT INTO sales.invoice_line (tenant_id, id, invoice_id, line_no, item_id, variant_id, uom_id, qty, qty_base, unit_price, currency_minor,
                                  gross_amount, line_discount_amount, invoice_discount_alloc, discount_amount, net_amount, tax_rounding,
                                  vat_rate, vat_amount, other_tax_rate, other_tax_amount, other_levy_rate, other_levy_amount, line_total,
                                  sstid, moadian_unit_code, price_source, moadian_extra)
  VALUES (core.current_tenant_id(), v_line, v_inv, 1, it_k(x || '.ITEM'), it_k(x || '.VAR'), it_k(x || '.UOM'), 1, 1, 3000000, 0,
          3000000, 0, 0, 0, 3000000, 'truncate', 10, 300000, 0, 0, 0, 0, 3300000, '2710000138624', '1627', 'price_list', '{}');
  UPDATE sales.invoice SET gross_amount = 3000000, net_amount = 3000000, vat_amount = 300000, total_amount = 3300000, total_base = 3300000
   WHERE id = v_inv;
  v_acct := it_acct(x, 'inventory.asset', DATE '2026-05-20', jsonb_build_object('item_posting_group', 'GOODS', 'warehouse', 'W1'));
  INSERT INTO inventory.stock_move (tenant_id, id, company_id, branch_id, warehouse_id, item_id, variant_id, move_date, move_kind, qty_base,
                                    uom_id, qty_uom, valuation_rule, party_id, asset_account_id, source_module, source_doc_type,
                                    source_doc_id, source_line_id, origin)
  VALUES (core.current_tenant_id(), v_move, t.company_id, t.branch_id, it_k(x || '.WH'), it_k(x || '.ITEM'), it_k(x || '.VAR'), DATE '2026-05-20',
          'sale_issue', -1, it_k(x || '.UOM'), 1, 'pool_out', t.customer_party_id, v_acct, 'sales', 'sales.invoice', v_inv, v_line, 'offline_device');
  SELECT -coalesce(sum(value), 0) INTO v_cogs FROM inventory.valuation_layer WHERE move_id = v_move;
  v_j := it_jr(x, DATE '2026-05-20', 'sales', 'sales.invoice', v_inv, 'post', jsonb_build_array(
           jsonb_build_object('key', 'sales.receivable', 'dr', 3300000, 'party', t.customer_party_id),
           jsonb_build_object('key', 'sales.revenue', 'cr', 3000000), jsonb_build_object('key', 'tax.vat_payable', 'cr', 300000),
           jsonb_build_object('key', 'inventory.cogs', 'dr', v_cogs), jsonb_build_object('acct', v_acct, 'key', 'inventory.asset', 'cr', v_cogs)));
  -- شمارهٔ «دستگاه»: همان شمارهٔ رسید (تنها شمارهٔ دستگاهی صادرشده برای این فروش)
  IF p_number = 'server' THEN   -- فقط تشخیص: شمارهٔ سرور سری sales.invoice (خلاف number_source='device')
    SELECT * INTO n FROM core.number_next(it_k(x || '.NS.SINV'), 'all', 'SI-{seq}', 'sales.invoice', v_inv);
    UPDATE sales.invoice SET status = 'posted', number_issued_id = n.number_id, doc_no = n.formatted, issued_at = t.occurred_at,
           posted_at = now(), gl_journal_id = v_j WHERE id = v_inv;
  ELSE
  UPDATE sales.invoice SET status = 'posted', number_issued_id = t.number_issued_id, doc_no = t.ticket_no, issued_at = t.occurred_at,
         posted_at = now(), gl_journal_id = v_j WHERE id = v_inv;
  END IF;
  UPDATE pos.ticket SET posting_status = 'posted', sales_doc_id = v_inv, posted_at = now() WHERE id = p_ticket;
  RETURN v_inv;
END $$;
GRANT EXECUTE ON FUNCTION public.it_c4_ticket(text), public.it_c4_post_from_pos(text, uuid, text) TO hk_app;
SET ROLE hk_app;
DO $$ DECLARE v text; BEGIN PERFORM it_ctx('A');
  v := it_try($q$SELECT it_c4_ticket('A')$q$);
  PERFORM it_rec('C', 'C4.ticket stored from a signed device command [A]', v IS NULL, v); END $$;
DO $$ DECLARE v text; BEGIN PERFORM it_ctx('B');
  v := it_try($q$SELECT it_c4_ticket('B')$q$);
  PERFORM it_rec('C', 'C4.ticket stored from a signed device command [B]', v IS NULL, v); END $$;
DO $$ DECLARE v text; BEGIN PERFORM it_ctx('A');
  v := it_try_rollback($q$SELECT it_c4_post_from_pos('A', it_k('A.TICKET1'))$q$);
  PERFORM it_rec('C', 'C4.post_from_pos: ticket -> sales invoice (channel=pos, number_source=device)', v IS NULL,
                 'documented POS posting cannot satisfy sales.invoice_verify: ' || v, 'RV-IT2-06', 'commerce');
  -- تشخیص: همان ثبت با شمارهٔ سرور sales.invoice می‌گذرد ⇒ تنها مانع قرارداد شماره است (برگشت داده می‌شود)
  PERFORM it_rec('C', 'C4.diagnostic: identical posting with a server sales.invoice number passes', it_try_rollback(
                 $q$SELECT it_c4_post_from_pos('A', it_k('A.TICKET1'), 'server')$q$) IS NULL,
                 it_try_rollback($q$SELECT it_c4_post_from_pos('A', it_k('A.TICKET1'), 'server')$q$));
  -- جریان متوقف شد (قرارداد شماره ناهمخوان)؛ رسید طبق ۰۶ §۵ گام ۸ به «review» می‌رود
  IF v IS NOT NULL THEN
    UPDATE pos.ticket SET posting_status = 'review' WHERE id = it_k('A.TICKET1');
  END IF;
END $$;
DO $$ BEGIN PERFORM it_ctx('B'); UPDATE pos.ticket SET posting_status = 'review' WHERE id = it_k('B.TICKET1'); END $$;
-- ---------- C5: برگشت (ابطال) فاکتور فروش ثبت‌شده (۰۵ §۵-۷ «ابطال»؛ ۰۳ reverse_journal؛ ۰۶ OpenItemService.cancel؛ ۰۷ withdraw) ----------
RESET ROLE;
CREATE OR REPLACE FUNCTION public.it_c5_cancel(x text, p_inv uuid, p_date date) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE h sales.invoice; m inventory.stock_move; v_rev uuid := uuidv7(); n record; v_fy uuid;
BEGIN
  SELECT * INTO h FROM sales.invoice WHERE id = p_inv FOR UPDATE;
  -- StockPostingService.reverse_source: هر حرکت با valuation_rule='reverse' در همان تاریخ اصل
  FOR m IN SELECT * FROM inventory.stock_move WHERE source_doc_id = p_inv AND reversal_of_move_id IS NULL LOOP
    INSERT INTO inventory.stock_move (tenant_id, company_id, branch_id, warehouse_id, item_id, variant_id, move_date, move_kind, qty_base, uom_id,
                                      qty_uom, valuation_rule, reversal_of_move_id, party_id, asset_account_id, source_module, source_doc_type,
                                      source_doc_id, source_line_id, origin)
    VALUES (m.tenant_id, m.company_id, m.branch_id, m.warehouse_id, m.item_id, m.variant_id, m.move_date, m.move_kind, -m.qty_base, m.uom_id,
            m.qty_uom, 'reverse', m.id, m.party_id, m.asset_account_id, m.source_module, m.source_doc_type, m.source_doc_id, m.source_line_id, 'online');
  END LOOP;
  -- LedgerPostingService.reverse_by_source(…, source_event='cancel') → ledger.reverse_journal با شمارهٔ عطف تازه
  SELECT f.id INTO v_fy FROM ledger.fiscal_year f WHERE f.company_id = h.company_id AND p_date BETWEEN f.start_date AND f.end_date;
  SELECT * INTO n FROM core.number_next(it_k(x || '.NS.JRN'), 'fy:' || v_fy, '{seq}', 'ledger.journal', v_rev);
  PERFORM ledger.reverse_journal(h.gl_journal_id, v_rev, p_date, n.value, n.formatted, NULL, 'cancel');
  -- OpenItemService.cancel
  UPDATE treasury.open_item SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'ابطال فاکتور فروش'
   WHERE source_doc_id = p_inv AND source_module = 'sales' AND status = 'open';
  -- TaxDocumentService.request_cancel: سند مؤدیان هنوز ارسال نشده → withdrawn
  UPDATE tax.invoice SET status = 'withdrawn', withdrawn_at = now(), withdrawn_reason = 'ابطال پیش از ارسال' WHERE id = h.tax_document_id;
  UPDATE sales.invoice SET status = 'cancelled', cancelled_at = now(), cancelled_by = it_k(x || '.U1'), cancel_reason = 'اشتباه در صدور',
         cancel_journal_id = v_rev WHERE id = p_inv;
  RETURN v_rev;
END $$;
GRANT EXECUTE ON FUNCTION public.it_c5_cancel(text, uuid, date) TO hk_app;
SET ROLE hk_app;
DO $$ DECLARE v text; BEGIN PERFORM it_ctx('A');
  v := it_try($q$SELECT it_c2_sales('A', 2, 3000000, DATE '2026-05-12', 'SINV2')$q$);
  PERFORM it_rec('C', 'C5.second sales invoice posted [A]', v IS NULL, v);
  v := it_try($q$SELECT it_c5_cancel('A', it_k('A.SINV2'), DATE '2026-05-13')$q$);
  PERFORM it_rec('C', 'C5.posted sales invoice cancelled by reversal [A]', v IS NULL, v); END $$;
DO $$ DECLARE v text; BEGIN PERFORM it_ctx('B');
  v := it_try($q$SELECT it_c2_sales('B', 2, 3000000, DATE '2026-05-12', 'SINV2')$q$);
  PERFORM it_rec('C', 'C5.second sales invoice posted [B]', v IS NULL, v);
  v := it_try($q$SELECT it_c5_cancel('B', it_k('B.SINV2'), DATE '2026-05-13')$q$);
  PERFORM it_rec('C', 'C5.posted sales invoice cancelled by reversal [B]', v IS NULL, v); END $$;
DO $$
DECLARE x text; h sales.invoice; v_net numeric; v_n int; v_bad text;
BEGIN
  FOREACH x IN ARRAY ARRAY['A','B'] LOOP
    PERFORM set_config('app.tenant_id', it_k(x || '.T')::text, true);
    SELECT * INTO h FROM sales.invoice WHERE id = it_k(x || '.SINV2');
    SELECT count(*) INTO v_n FROM (
      SELECT l.account_id, l.dim1_id, sum(l.debit_base - l.credit_base) s FROM ledger.journal_line l
       WHERE l.journal_id IN (h.gl_journal_id, h.cancel_journal_id) GROUP BY 1, 2 HAVING sum(l.debit_base - l.credit_base) <> 0) q;
    PERFORM it_rec('C', 'C5.cancellation nets the invoice journal to zero per account [' || x || ']',
                   h.status = 'cancelled' AND v_n = 0
                   AND (SELECT reversal_of_journal_id FROM ledger.journal WHERE id = h.cancel_journal_id) = h.gl_journal_id,
                   h.status || ' / non-zero accounts ' || v_n);
    PERFORM it_rec('C', 'C5.stock restored after cancellation [' || x || ']',
      (SELECT sum(qty_base) FROM inventory.stock_move WHERE company_id = it_k(x || '.CO')) = 6
      AND it_gl(x, it_acct(x, 'inventory.asset'), DATE '2026-05-13') = 6000000,
      format('qty %s inventory GL %s', (SELECT sum(qty_base) FROM inventory.stock_move WHERE company_id = it_k(x || '.CO')),
             it_gl(x, it_acct(x, 'inventory.asset'), DATE '2026-05-13')));
    SELECT count(*), string_agg(subledger_kind || ':' || coalesce(gl_base, 0) || '/' || coalesce(sub_base, 0), ', ') INTO v_n, v_bad
      FROM ledger.check_control_accounts(it_k(x || '.CO'), DATE '2026-05-13');
    PERFORM it_rec('C', 'C5.all registered subledgers reconcile after cancellation [' || x || ']', v_n = 0, v_bad);
    PERFORM it_rec('C', 'C5.cancelled invoice open item and tax document closed [' || x || ']',
      (SELECT status FROM treasury.open_item WHERE source_doc_id = h.id) = 'cancelled'
      AND (SELECT status FROM tax.invoice WHERE id = h.tax_document_id) = 'withdrawn', NULL);
  END LOOP;
END $$;

-- ---------- C6: تراز آزمایشی، سطل‌های مانده، زیردفترها در پایان دوره (۰۳ §۵-۱۱/§۵-۱۳) ----------
DO $$
DECLARE x text; v_dr numeric; v_cr numeric; v_n int; v_bad text; v_fy uuid; v_oi numeric; v_gl numeric;
BEGIN
  FOREACH x IN ARRAY ARRAY['A','B'] LOOP
    PERFORM set_config('app.tenant_id', it_k(x || '.T')::text, true);
    SELECT id INTO v_fy FROM ledger.fiscal_year WHERE company_id = it_k(x || '.CO');
    SELECT sum(open_debit + period_debit), sum(open_credit + period_credit) INTO v_dr, v_cr
      FROM ledger.trial_balance(it_k(x || '.CO'), DATE '2026-03-21', DATE '2027-03-20');
    PERFORM it_rec('C', 'C6.trial balance balances [' || x || ']', v_dr = v_cr AND v_dr > 0, format('debit %s credit %s', v_dr, v_cr));
    SELECT count(*), string_agg(source || ':' || total_debit || '/' || total_credit, ', ') INTO v_n, v_bad
      FROM ledger.check_trial_balance(it_k(x || '.CO'), v_fy);
    PERFORM it_rec('C', 'C6.ledger.check_trial_balance empty [' || x || ']', v_n = 0, v_bad);
    SELECT count(*) INTO v_n FROM ledger.verify_balance_buckets(it_k(x || '.CO'), v_fy);
    PERFORM it_rec('C', 'C6.balance buckets = journal lines [' || x || ']', v_n = 0, v_n || ' mismatching buckets');
    SELECT count(*), string_agg(subledger_kind || ':' || coalesce(gl_base, 0) || '/' || coalesce(sub_base, 0), ', ') INTO v_n, v_bad
      FROM ledger.check_control_accounts(it_k(x || '.CO'), DATE '2027-03-20');
    PERFORM it_rec('C', 'C6.registered subledgers (inventory, cheques, guarantees, fixed assets) reconcile [' || x || ']', v_n = 0, v_bad);
    -- اشخاص: اقلام باز (treasury) = GL حساب‌های subledger_kind='party' به تفکیک بُعد شخص (تطبیق دستی؛ RV-IT2-04)
    SELECT count(*), string_agg(q.party || ':' || q.gl || '/' || q.oi, ', ') INTO v_n, v_bad FROM (
      SELECT dv.party_id AS party, coalesce(sum(l.debit_base - l.credit_base), 0) AS gl,
             coalesce((SELECT sum(CASE o.direction WHEN 'debit' THEN o.amount_base - o.allocated_amount ELSE o.allocated_amount - o.amount_base END)
                         FROM treasury.open_item o WHERE o.company_id = it_k(x || '.CO') AND o.party_id = dv.party_id AND o.status <> 'cancelled'), 0) AS oi
        FROM ledger.journal_line l JOIN ledger.account a ON a.id = l.account_id AND a.subledger_kind = 'party'
        JOIN ledger.dimension_value dv ON dv.id = l.dim1_id
       WHERE l.company_id = it_k(x || '.CO') GROUP BY dv.party_id) q WHERE q.gl <> q.oi;
    PERFORM it_rec('C', 'C6.party open items = GL by party [' || x || ']', v_n = 0, v_bad);
  END LOOP;
END $$;

-- ---------- C7: پیوندهای بین‌ماژولی که فقط «مبدأ» را می‌سنجند، نه «همان سند/همان مبلغ» ----------
-- (۱) فاکتور فروش با سند GL که مبلغش با فاکتور نمی‌خواند (۰۵ INV-SAL-13 فقط مبدأ؛ 30_commerce_test با سند ۱ ریالی سبز است)
-- (۲) RV-IT-SALESTAX: فاکتور فروش به سند مؤدیانِ فاکتور دیگر همان شرکت اشاره می‌کند (هر دو با it_c2_sales و p_opts)
RESET ROLE;
-- (۳) رویداد چک با سند GL که از چک نیامده (سند فاکتور فروش) — ۰۶ INV-CHQ-04 فقط وجود سند را می‌سنجد
CREATE OR REPLACE FUNCTION public.it_c7_cheque_foreign_journal(x text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_chq uuid := uuidv7(); v_amt numeric := 5000000;
BEGIN
  INSERT INTO treasury.cheque (tenant_id, id, company_id, direction, purpose, state, medium, sayad_id, amount, amount_base, due_date,
                               received_from_party_id, sayad_state, origin)
  VALUES (core.current_tenant_id(), v_chq, it_k(x || '.CO'), 'received', 'payment', 'in_hand', 'electronic', '9999888877776666', v_amt, v_amt,
          DATE '2026-07-01', it_k(x || '.CUST'), 'not_inquired', 'manual');
  INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, to_state, event_date, collected_after, long_term_after,
                                     journal_id, holding_account_id, holding_dim_value_id, holding_amount, holding_amount_base)
  VALUES (core.current_tenant_id(), v_chq, 1, 'transition', 'R1', 'in_hand', DATE '2026-05-15', 0, false,
          (SELECT gl_journal_id FROM sales.invoice WHERE id = it_k(x || '.SINV1')),
          it_acct(x, 'treasury.cheque_receivable'), it_pdim(it_k(x || '.CUST')), v_amt, v_amt);
END $$;
GRANT EXECUTE ON FUNCTION public.it_c7_cheque_foreign_journal(text) TO hk_app;
SET ROLE hk_app;
DO $$ DECLARE v text; BEGIN PERFORM it_ctx('A');
  v := it_try_rollback($q$SELECT it_c2_sales('A', 1, 3000000, DATE '2026-05-14', 'SINV_TMP', '{"gl":"one_rial"}')$q$);
  PERFORM it_rec('C', 'C7.posted sales invoice rejects a GL journal whose amounts differ from the invoice', v IS NOT NULL,
                 'invoice total 3,300,000 accepted gl_journal_id of a 1-rial journal from the same source (sales.invoice_verify checks origin only)',
                 'RV-IT2-09', 'commerce');
  v := it_try_rollback($q$SELECT it_c2_sales('A', 1, 3000000, DATE '2026-05-14', 'SINV_TMP', '{"tax_doc_of":"SINV1"}')$q$);
  PERFORM it_rec('C', 'C7.sales invoice cannot point at the tax document of another invoice', v IS NOT NULL,
                 'sales.invoice.tax_document_id accepted the tax.invoice whose sales_invoice_id is a different invoice', 'RV-IT-SALESTAX', 'compliance');
  v := it_try_rollback($q$SELECT it_c7_cheque_foreign_journal('A')$q$);
  PERFORM it_rec('C', 'C7.cheque event rejects a GL journal that does not come from treasury/the cheque', v IS NOT NULL,
                 'cheque_event R1 accepted journal_id of the sales-invoice journal (no source check); cheque subledger and GL then diverge silently',
                 'RV-IT2-10', 'treasury_pos');
END $$;

-- =====================================================================
-- بخش B.2: کاوش نشت بین مستأجری روی همهٔ جدول‌های مستأجری (پویا از کاتالوگ)
--   پیش‌شرط: B.1 و جریان‌های C برای هر دو مستأجر داده ساخته‌اند. پوشش داده در پایان چاپ می‌شود.
-- =====================================================================
RESET ROLE;
-- پوشش: جدول‌هایی که برای هر دو مستأجر ردیف دارند (postgres؛ RLS دور زده می‌شود فقط برای شمارش)
DROP TABLE IF EXISTS public.it_coverage;
CREATE TABLE public.it_coverage (rel text PRIMARY KEY, rows_a bigint, rows_b bigint);
DO $$
DECLARE r record; a bigint; b bigint;
BEGIN
  FOR r IN SELECT rel FROM public.it_tenant_tables() ORDER BY rel::text LOOP
    EXECUTE format('SELECT count(*) FILTER (WHERE tenant_id = $1), count(*) FILTER (WHERE tenant_id = $2) FROM %s', r.rel)
      INTO a, b USING it_k('A.T'), it_k('B.T');
    INSERT INTO public.it_coverage VALUES (r.rel::text, a, b);
  END LOOP;
END $$;
GRANT SELECT ON public.it_coverage TO hk_app, hk_readonly;
-- ردیف ترکیبی (synthetic) برای مستأجر B در هر جدولی که جریان‌ها برایش ردیف B نساخته‌اند — فقط برای کاوش نشت.
-- با session_replication_role=replica (postgres) درج می‌شود تا FK/تریگر دور زده شود؛ CHECKها برقرارند و هر جدولی که
-- مولد ساده نتواند CHECKهایش را برآورد «fixture ناممکن» است و نامش در گزارش پوشش می‌آید. پس از B.2 همه پاک می‌شوند.
CREATE OR REPLACE FUNCTION public.it_synth_value(p_rel regclass, p_col name, p_type oid, p_typmod int, p_try int) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE v_check text; v_m text[]; v_base oid; v_tname text;
BEGIN
  -- CHECK (col = ANY (ARRAY['a'::text, ...])) یا (col = 'a') → نخستین مقدار مجاز
  FOR v_check IN SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c
                  WHERE c.conrelid = p_rel AND c.contype = 'c' AND c.conkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = p_rel AND attname = p_col)]::int2[] LOOP
    v_m := regexp_match(v_check, 'ARRAY\[''([^'']*)''');
    IF v_m IS NOT NULL THEN RETURN quote_literal(v_m[1]); END IF;
    v_m := regexp_match(v_check, '= ANY \(ARRAY\[([0-9]+)');
    IF v_m IS NOT NULL THEN RETURN v_m[1]; END IF;
  END LOOP;
  SELECT t.typbasetype, t.typname INTO v_base, v_tname FROM pg_type t WHERE t.oid = p_type;
  IF v_base <> 0 THEN p_type := v_base; END IF;
  IF EXISTS (SELECT 1 FROM pg_enum WHERE enumtypid = p_type) THEN
    RETURN quote_literal((SELECT enumlabel FROM pg_enum WHERE enumtypid = p_type ORDER BY enumsortorder LIMIT 1)) || '::' || p_type::regtype;
  END IF;
  RETURN CASE p_type::regtype::text
    WHEN 'uuid' THEN 'uuidv7()'
    WHEN 'text' THEN CASE p_try WHEN 0 THEN '''x''' WHEN 1 THEN '''abc''' WHEN 2 THEN '''A1''' ELSE '''a.b''' END
    WHEN 'character varying' THEN '''x'''
    WHEN 'character' THEN '''IRR'''
    WHEN 'numeric' THEN '1' WHEN 'integer' THEN '1' WHEN 'smallint' THEN '1' WHEN 'bigint' THEN '1'
    WHEN 'boolean' THEN 'false' WHEN 'date' THEN '''2026-05-01''' WHEN 'timestamp with time zone' THEN 'now()'
    WHEN 'jsonb' THEN '''{}''' WHEN 'json' THEN '''{}''' WHEN 'bytea' THEN 'sha256(''x''::bytea)'
    WHEN 'text[]' THEN '''{}''' WHEN 'uuid[]' THEN '''{}''' WHEN 'inet' THEN '''127.0.0.1''' WHEN 'interval' THEN '''1 day'''
    WHEN 'xid8' THEN 'pg_current_xact_id()' WHEN 'daterange' THEN '''[2026-05-01,2026-06-01)''' WHEN 'tstzrange' THEN 'tstzrange(now(), now() + interval ''1 day'')'
    WHEN 'time without time zone' THEN '''08:00''' WHEN 'smallint[]' THEN '''{}''' WHEN 'integer[]' THEN '''{}'''
    ELSE 'NULL' END;
END $$;

DROP TABLE IF EXISTS public.it_synth;
CREATE TABLE public.it_synth (rel text PRIMARY KEY, ok boolean, err text);
SET session_replication_role = replica;
DO $$
DECLARE r record; c record; v_cols text; v_vals text; v_try int; v_err text; v_ok boolean;
BEGIN
  FOR r IN SELECT t.rel FROM public.it_tenant_tables() t
            WHERE NOT EXISTS (SELECT 1 FROM public.it_coverage cv WHERE cv.rel = t.rel::text AND cv.rows_b > 0) ORDER BY 1 LOOP
    v_ok := false; v_err := NULL;
    FOR v_try IN 0..3 LOOP
      v_cols := 'tenant_id'; v_vals := quote_literal(it_k('B.T'));
      FOR c IN SELECT a.attname, a.atttypid, a.atttypmod FROM pg_attribute a
                WHERE a.attrelid = r.rel AND a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated = '' AND a.attidentity <> 'a'
                  AND a.attname <> 'tenant_id' AND a.attnotnull AND NOT a.atthasdef ORDER BY a.attnum LOOP
        v_cols := v_cols || ', ' || quote_ident(c.attname);
        v_vals := v_vals || ', ' || CASE WHEN c.attname = 'company_id' THEN quote_literal(it_k('B.CO'))
                                         WHEN c.attname = 'branch_id' THEN quote_literal(it_k('B.BR'))
                                         ELSE public.it_synth_value(r.rel, c.attname, c.atttypid, c.atttypmod, v_try) END;
      END LOOP;
      BEGIN
        EXECUTE format('INSERT INTO %s (%s) VALUES (%s)', r.rel, v_cols, v_vals);
        v_ok := true; EXIT;
      EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE || ' ' || SQLERRM;
      END;
    END LOOP;
    INSERT INTO public.it_synth VALUES (r.rel::text, v_ok, CASE WHEN NOT v_ok THEN v_err END);
  END LOOP;
END $$;
SET session_replication_role = origin;
UPDATE public.it_coverage cv SET rows_b = rows_b + 1 FROM public.it_synth x WHERE x.rel = cv.rel AND x.ok;

SET ROLE hk_app;
-- ---------- B2.1: با مستأجر A هیچ ردیفی از مستأجر دیگر دیده نمی‌شود (هر جدول مستأجری) ----------
DO $$
DECLARE r record; n bigint; v text := NULL; v_err text := NULL;
BEGIN
  PERFORM it_ctx('A');
  FOR r IN SELECT rel FROM public.it_tenant_tables() ORDER BY rel::text LOOP
    BEGIN
      EXECUTE format('SELECT count(*) FROM %s WHERE tenant_id IS DISTINCT FROM $1', r.rel) INTO n USING it_k('A.T');
      IF n > 0 THEN v := concat_ws(', ', v, r.rel || '=' || n); END IF;
    EXCEPTION WHEN insufficient_privilege THEN NULL;   -- hk_app بدون SELECT (مثلاً سطل‌ها)؛ نشتی ممکن نیست
    END;
  END LOOP;
  PERFORM it_rec('B', 'B2.1 hk_app[A] sees no row of another tenant in any tenant table', v IS NULL, v);
END $$;
-- ---------- B2.2: درج با tenant_id=B در زمینهٔ A شکست می‌خورد (هر جدول مستأجری؛ INSERT (tenant_id) VALUES (B)) ----------
-- RLS WITH CHECK پیش از NOT NULL/CHECK اجرا می‌شود؛ پس 42501 اثبات RLS است. خطای دیگر = تریگر BEFORE زودتر رد کرد (پذیرفته، شمارش می‌شود).
DO $$
DECLARE r record; v_ok int := 0; v_other int := 0; v_leak text := NULL; v_state text; v_msg text;
BEGIN
  PERFORM it_ctx('A');
  FOR r IN SELECT rel FROM public.it_tenant_tables() ORDER BY rel::text LOOP
    BEGIN
      EXECUTE format('INSERT INTO %s (tenant_id) VALUES ($1)', r.rel) USING it_k('B.T');
      EXECUTE 'SET CONSTRAINTS ALL IMMEDIATE';
      v_leak := concat_ws(', ', v_leak, r.rel::text);
      RAISE EXCEPTION 'IT_UNDO';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
      IF v_msg = 'IT_UNDO' THEN NULL;
      ELSIF v_state = '42501' THEN v_ok := v_ok + 1;
      ELSE v_other := v_other + 1; END IF;
    END;
  END LOOP;
  PERFORM it_rec('B', 'B2.2 hk_app[A] cannot insert a row for tenant B (' || v_ok || ' rejected by RLS/grant, ' || v_other || ' by an earlier trigger)',
                 v_leak IS NULL, 'tables that accepted a tenant-B row from tenant A: ' || v_leak);
END $$;
-- ---------- B2.3: UPDATE/DELETE ردیف‌های B از زمینهٔ A هیچ ردیفی را لمس نمی‌کند ----------
DO $$
DECLARE r record; n bigint; v text := NULL; v_msg text;
BEGIN
  PERFORM it_ctx('A');
  FOR r IN SELECT c.rel FROM public.it_tenant_tables() c JOIN public.it_coverage cv ON cv.rel = c.rel::text WHERE cv.rows_b > 0 ORDER BY 1 LOOP
    BEGIN
      EXECUTE format('UPDATE %s SET tenant_id = tenant_id WHERE tenant_id = $1', r.rel) USING it_k('B.T');
      GET DIAGNOSTICS n = ROW_COUNT;
      IF n > 0 THEN v := concat_ws(', ', v, r.rel || ':update=' || n); END IF;
      EXECUTE format('DELETE FROM %s WHERE tenant_id = $1', r.rel) USING it_k('B.T');
      GET DIAGNOSTICS n = ROW_COUNT;
      IF n > 0 THEN v := concat_ws(', ', v, r.rel || ':delete=' || n); END IF;
      RAISE EXCEPTION 'IT_UNDO';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
      IF v_msg <> 'IT_UNDO' AND v_msg NOT LIKE 'permission denied%' THEN
        v := concat_ws(', ', v, r.rel || ':' || v_msg);    -- خطای غیرمنتظره (ردیف B دیده شد و تریگر اجرا شد)
      END IF;
    END;
  END LOOP;
  PERFORM it_rec('B', 'B2.3 hk_app[A] UPDATE/DELETE of tenant-B rows touches nothing', v IS NULL, v);
END $$;
-- ---------- B2.4: بدون مستأجر: خواندن صفر ردیف، نوشتن شکست ----------
DO $$
DECLARE r record; n bigint; v text := NULL; v_leak text := NULL; v_msg text;
BEGIN
  PERFORM set_config('app.tenant_id', '', true); PERFORM set_config('app.user_id', '', true);
  FOR r IN SELECT rel FROM public.it_tenant_tables() ORDER BY rel::text LOOP
    BEGIN
      EXECUTE format('SELECT count(*) FROM %s', r.rel) INTO n;
      IF n > 0 THEN v := concat_ws(', ', v, r.rel || '=' || n); END IF;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
      EXECUTE format('INSERT INTO %s (tenant_id) VALUES ($1)', r.rel) USING it_k('A.T');
      EXECUTE 'SET CONSTRAINTS ALL IMMEDIATE';
      v_leak := concat_ws(', ', v_leak, r.rel::text);
      RAISE EXCEPTION 'IT_UNDO';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;
  PERFORM it_rec('B', 'B2.4 no tenant context: every tenant table reads 0 rows', v IS NULL, v);
  PERFORM it_rec('B', 'B2.4 no tenant context: every insert fails', v_leak IS NULL, v_leak);
  -- جدول‌های سطح قلمرو هم بدون مستأجر و کاربر چیزی نشان نمی‌دهند
  PERFORM it_rec('B', 'B2.4 no context: core.tenant/app_user/login identifiers invisible',
                 (SELECT count(*) FROM core.tenant) = 0 AND (SELECT count(*) FROM core.app_user) = 0
                 AND (SELECT count(*) FROM core.user_login_identifier) = 0, NULL);
END $$;
-- ---------- B2.5: FK ترکیبی به والد مستأجر B از زمینهٔ A رد می‌شود (نمونه‌های بین‌ماژولی) ----------
DO $$
DECLARE v text; v_bad text := NULL; v_seen text := '';
        probes text[] := ARRAY[
  -- core: شعبه → شرکت B
  $q$INSERT INTO core.branch (tenant_id, company_id, code, name) VALUES (it_k('A.T'), it_k('B.CO'), 'XB', 'x')$q$,
  -- catalog: variant → کالای B
  $q$INSERT INTO catalog.item_variant (tenant_id, item_id, code, is_default) VALUES (it_k('A.T'), it_k('B.ITEM'), 'XX', false)$q$,
  -- inventory → core: انبار → شعبهٔ B
  $q$INSERT INTO inventory.warehouse (tenant_id, company_id, branch_id, code, name) VALUES (it_k('A.T'), it_k('A.CO'), it_k('B.BR'), 'XW', 'x')$q$,
  -- sales → parties: مشتری B
  $q$INSERT INTO sales.invoice (tenant_id, company_id, branch_id, doc_date, customer_party_id, currency, currency_minor, stock_mode)
       VALUES (it_k('A.T'), it_k('A.CO'), it_k('A.BR'), DATE '2026-05-01', it_k('B.CUST'), 'IRR', 0, 'none')$q$,
  -- sales: سطر در فاکتور B
  $q$INSERT INTO sales.invoice_line (tenant_id, invoice_id, line_no, item_id, variant_id, uom_id, qty, qty_base, unit_price, currency_minor,
       gross_amount, net_amount, tax_rounding, vat_rate, vat_amount, line_total)
       VALUES (it_k('A.T'), it_k('B.SINV1'), 9, it_k('A.ITEM'), it_k('A.VAR'), it_k('A.UOM'), 1, 1, 1, 0, 1, 1, 'truncate', 0, 0, 1)$q$,
  -- treasury → parties: قلم باز برای شخص B
  $q$INSERT INTO treasury.open_item (tenant_id, company_id, party_id, party_role, account_class, direction, source_module, source_doc_type,
       source_doc_id, doc_date, due_date, currency, amount, amount_base) VALUES (it_k('A.T'), it_k('A.CO'), it_k('B.CUST'), 'customer',
       'receivable', 'debit', 'sales', 'sales.invoice', uuidv7(), DATE '2026-05-01', DATE '2026-05-01', 'IRR', 1, 1)$q$,
  -- tax → sales (99_cross_fk، خلاف DAG)
  $q$INSERT INTO tax.invoice (tenant_id, company_id, memory_ref, source_kind, sales_invoice_id, subject, inv_type, pattern, instruction_version, status)
       VALUES (it_k('A.T'), it_k('A.CO'), it_k('A.MEM'), 'sales_invoice', it_k('B.SINV1'), 1, 1, 1, 'RC_IITP.IS-1', 'pending')$q$,
  -- pos → sales (99_cross_fk سه‌ستونی)
  $q$UPDATE pos.ticket SET sales_doc_id = it_k('B.SINV1'), posting_status = 'posted', posted_at = now() WHERE id = it_k('A.TICKET1')$q$];
BEGIN
  PERFORM it_ctx('A');
  FOR i IN 1 .. array_length(probes, 1) LOOP
    v := it_try_rollback(probes[i]);
    IF v IS NULL THEN
      v_bad := concat_ws(' | ', v_bad, 'probe ' || i || ' accepted');
    ELSIF v !~ '^(23503|42501)' THEN
      v_bad := concat_ws(' | ', v_bad, 'probe ' || i || ' failed for another reason (FK not proven): ' || v);
    END IF;
    v_seen := v_seen || i || ':' || coalesce(left(v, 5), 'ok') || ' ';
  END LOOP;
  PERFORM it_rec('B', 'B2.5 composite FKs reject a tenant-B parent from tenant A (' || v_seen || ')', v_bad IS NULL, v_bad);
END $$;
-- ---------- B2.6: جدول‌های سطح قلمرو (R-USER): مستأجر A به کاربر/عضویت مستأجر B دست نمی‌یابد ----------
DO $$
DECLARE v text; n int;
BEGIN
  PERFORM it_ctx('A');
  SELECT count(*) INTO n FROM core.app_user WHERE id IN (it_k('B.U1'), it_k('B.U2'));
  PERFORM it_rec('B', 'B2.6 tenant A cannot see users of tenant B', n = 0, n || ' visible');
  SELECT count(*) INTO n FROM core.tenant_membership WHERE tenant_id = it_k('B.T');
  PERFORM it_rec('B', 'B2.6 tenant A cannot see memberships of tenant B', n = 0, n || ' visible');
  SELECT count(*) INTO n FROM core.tenant WHERE id <> it_k('A.T');
  PERFORM it_rec('B', 'B2.6 tenant A sees only its own core.tenant row', n = 0, n || ' visible');
  -- شناسهٔ ورود برای کاربر مستأجر دیگر: ورود OTP به این مقدار = ورود به حساب قربانی (auth_resolve_login تأیید را نمی‌سنجد)
  v := it_try_rollback($q$INSERT INTO core.user_login_identifier (user_id, kind, value, verified_at, is_primary)
                          VALUES (it_k('B.U1'), 'email', 'attacker@example.ir', now(), false)$q$);
  PERFORM it_rec('B', 'B2.6 tenant A cannot attach a login identifier to a user of tenant B', v IS NOT NULL,
                 'core.user_login_identifier accepted a login identifier for a user who is not a member of the current tenant (policy uli_insert: user_id = current_user_id() OR current_tenant_id() IS NOT NULL)',
                 'RV-IT2-07', 'core');
  -- همان با app_user: ساختن کاربر انسانی تازه مجاز است (دعوت)، ولی ویرایش کاربر مستأجر دیگر نه
  v := it_try_rollback($q$UPDATE core.app_user SET display_name = 'x' WHERE id = it_k('B.U1')$q$);
  PERFORM it_rec('B', 'B2.6 tenant A cannot rename a user of tenant B', v IS NULL
                 AND NOT EXISTS (SELECT 1 FROM core.app_user WHERE id = it_k('B.U1')), v);
  -- عضویت «active» بدون پذیرش کاربر: هویت کاربر B (شماره/ایمیل) را برای A قابل‌دیدن می‌کند
  v := it_try_rollback($q$INSERT INTO core.tenant_membership (tenant_id, user_id, status, is_owner, joined_at)
                          VALUES (it_k('A.T'), it_k('B.U2'), 'active', false, now())$q$);
  PERFORM it_rec('B', 'B2.6 tenant A cannot enrol a user of tenant B as active member without acceptance', v IS NOT NULL,
                 'core.tenant_membership accepted (A, user of B, status=active) without an invitation; the user''s login identifiers become visible to A (uli_select)',
                 'RV-IT2-08', 'core');
END $$;
-- ---------- B2.7: hk_readonly همان جداسازی را دارد ----------
RESET ROLE;
SET ROLE hk_readonly;
DO $$
DECLARE r record; n bigint; v text := NULL;
BEGIN
  PERFORM it_ctx('A');
  FOR r IN SELECT rel FROM public.it_tenant_tables() ORDER BY rel::text LOOP
    BEGIN
      EXECUTE format('SELECT count(*) FROM %s WHERE tenant_id IS DISTINCT FROM $1', r.rel) INTO n USING it_k('A.T');
      IF n > 0 THEN v := concat_ws(', ', v, r.rel || '=' || n); END IF;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;
  PERFORM it_rec('B', 'B2.7 hk_readonly[A] sees no row of another tenant', v IS NULL, v);
  PERFORM it_rec('B', 'B2.7 hk_readonly[A] sees its own business data', (SELECT count(*) FROM sales.invoice) > 0
                 AND (SELECT count(*) FROM ledger.journal_line) > 0, NULL);
END $$;
RESET ROLE;
-- پاک‌سازی ردیف‌های ترکیبی (همان جدول‌ها پیش از آن ردیف B نداشتند)
SET session_replication_role = replica;
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT rel FROM public.it_synth WHERE ok LOOP
    EXECUTE format('DELETE FROM %s WHERE tenant_id = $1', r.rel) USING it_k('B.T');
  END LOOP;
END $$;
SET session_replication_role = origin;

-- =====================================================================
-- گزارش پایانی: پوشش داده، جدول نتیجه، و حکم
-- =====================================================================
RESET ROLE;
\echo '== 99_integration: coverage of tenant tables during B.2 (rows_b includes synthetic rows)'
SELECT count(*) FILTER (WHERE rows_a > 0 AND rows_b > 0) AS both_tenants,
       count(*) FILTER (WHERE rows_a > 0 AND rows_b = 0) AS tenant_a_only,
       count(*) FILTER (WHERE rows_a = 0 AND rows_b > 0) AS tenant_b_only,
       count(*) FILTER (WHERE rows_a = 0 AND rows_b = 0) AS no_rows,
       count(*) AS tenant_tables
  FROM public.it_coverage;
-- جدول‌های بدون داده در هر دو مستأجر: بررسی B2.1/B2.3 روی آن‌ها فقط با policy پوشش دارد (A1 ثابت می‌کند policy استاندارد
-- tenant_isolation روی همه هست و هیچ policy مجاز بی‌مستأجری نیست)، و B2.2/B2.4 (درج) بی‌نیاز از داده روی همه اجرا شد.
\echo '== 99_integration: tenant-B rows: from business flows / synthetic (replica-mode) / impractical (covered only statically by A1 + insert probes B2.2/B2.4)'
SELECT count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM public.it_synth x WHERE x.rel = cv.rel)) AS from_flows_and_fixtures,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM public.it_synth x WHERE x.rel = cv.rel AND x.ok)) AS synthetic,
       count(*) FILTER (WHERE rows_b = 0) AS impractical
  FROM public.it_coverage cv;
SELECT string_agg(rel, ', ' ORDER BY rel) AS impractical_tables_no_tenant_b_row FROM public.it_coverage WHERE rows_b = 0;
\echo '== 99_integration: results'
\pset pager off
SELECT seq, part, check_id, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, finding, owner, left(detail, 600) AS detail
  FROM public.it_result ORDER BY seq;
DO $$
DECLARE n_fail int; n_all int; v text;
BEGIN
  SELECT count(*) FILTER (WHERE NOT ok), count(*),
         string_agg(CASE WHEN NOT ok THEN check_id || coalesce(' [' || finding || ' → ' || owner || ']', '') END, '; ' ORDER BY seq)
    INTO n_fail, n_all, v FROM public.it_result;
  IF n_fail > 0 THEN
    RAISE EXCEPTION 'TEST FAILED: % of % integration checks failed: %', n_fail, n_all, v;
  END IF;
END $$;
\echo 'ALL 99_integration TESTS PASSED'
