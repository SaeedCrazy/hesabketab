-- =====================================================================
-- آزمون پایگاه داده‌ای 20_ledger.sql (سند: docs/design/03-ledger.md §۷ و §۹)
--
-- اجرا (از ریشهٔ مخزن؛ پایگاه دادهٔ تازه با UTF8):
--   export PGPASSWORD=postgres
--   psql -h localhost -p 5433 -U postgres -d postgres -c "DROP DATABASE IF EXISTS ds_ledger"
--   psql -h localhost -p 5433 -U postgres -d postgres -c "CREATE DATABASE ds_ledger ENCODING 'UTF8' TEMPLATE template0 LC_COLLATE 'C' LC_CTYPE 'C.UTF-8'"
--   psql -h localhost -p 5433 -U postgres -d ds_ledger -v ON_ERROR_STOP=1 -f docs/design/sql/00_foundation.sql
--   psql -h localhost -p 5433 -U postgres -d ds_ledger -v ON_ERROR_STOP=1 -f docs/design/sql/20_ledger.sql
--   psql -h localhost -p 5433 -U postgres -d ds_ledger -v ON_ERROR_STOP=1 -f docs/design/sql/tests/20_ledger_test.sql
-- (همین فایل پس از 10_core.sql هم اجرا می‌شود: 00 → 10 → 20 → این آزمون.)
--
-- ساختار (یک نشست psql با superuser):
--   بخش ۱ (fixture، نقش postgres): مستأجر A (دو شرکت CA و CA2) و B (شرکت CB)، شعبه‌ها، توابع کمکی آزمون
--         (expect_error, assert_true, t_ctx, t_post, t_make_year, t_acc, t_dim, t_ref) و زیردفتر جعلی اشخاص.
--   بخش ۲ (assert، «SET ROLE hk_app»): همهٔ ناوردایی‌های پایگاه داده‌ای با DO block؛ هر DO یک تراکنش است و
--         تریگرهای deferred در commit آن اجرا می‌شوند. موارد منفیِ deferred با «SET CONSTRAINTS ALL IMMEDIATE»
--         درون زیرتراکنش expect_error آزموده می‌شوند. زمینهٔ مستأجر با set_config('app.tenant_id', ..., true).
--         T20 هر بررسی تریگر/تابعی را که آزمون جهش (neutralize هر raise_error) بی‌آزمون یافت، با الگوی دقیق کد و پیام می‌آزماید.
--   بخش ۳ (tamper، نقش postgres، ROLLBACK): دست‌کاری مستقیم سطر دائم با غیرفعال کردن تریگر و کشف آن با
--         verify_permanent_chain و verify_balance_buckets؛ و آزمون hk_readonly.
-- خروجی موفق با «ALL 20_ledger TESTS PASSED» پایان می‌یابد؛ هر شکست «TEST FAILED: ...» است و psql با کد ≠ ۰ خارج می‌شود.
-- =====================================================================
\set ON_ERROR_STOP 1
\set QUIET 1

-- =====================================================================
-- بخش ۱: fixture (postgres)
-- =====================================================================
RESET ROLE;
BEGIN;
INSERT INTO core.tenant (id, slug, display_name) VALUES
  ('0a000000-0000-7000-8000-000000000001', 'tenant-a', 'A'),
  ('0b000000-0000-7000-8000-000000000001', 'tenant-b', 'B');
INSERT INTO core.company (tenant_id, id, code, name) VALUES
  ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000000c1', 'C1', 'شرکت الف'),
  ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000000c2', 'C2', 'شرکت الف ۲'),
  ('0b000000-0000-7000-8000-000000000001', '0b000000-0000-7000-8000-0000000000c1', 'C1', 'شرکت ب'),
  -- T20 (شکاف‌های آزمون جهش): CA3 با کدینگ و سال، CA4 خالی (بدون حساب و سال)
  ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000000c3', 'C3', 'شرکت الف ۳'),
  ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000000c4', 'C4', 'شرکت الف ۴');
INSERT INTO core.branch (tenant_id, id, company_id, code, name) VALUES
  ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000000b1', '0a000000-0000-7000-8000-0000000000c1', 'BR1', 'شعبه ۱'),
  ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000000b2', '0a000000-0000-7000-8000-0000000000c2', 'BR1', 'شعبه ۱'),
  ('0b000000-0000-7000-8000-000000000001', '0b000000-0000-7000-8000-0000000000b1', '0b000000-0000-7000-8000-0000000000c1', 'BR1', 'شعبه ۱');

-- ---------- کمکی‌های آزمون (SECURITY INVOKER) ----------
CREATE OR REPLACE FUNCTION public.assert_true(p_cond boolean, p_label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond IS NOT TRUE THEN RAISE EXCEPTION 'TEST FAILED: %', p_label; END IF;
END $$;

-- اجرای SQL در زیرتراکنش؛ تریگرهای deferred همان‌جا اجرا می‌شوند؛ خطا باید با الگو بخواند
CREATE OR REPLACE FUNCTION public.expect_error(p_sql text, p_pattern text, p_label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE p_sql;
    EXECUTE 'SET CONSTRAINTS ALL IMMEDIATE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM !~ p_pattern THEN
      RAISE EXCEPTION 'TEST FAILED: % — expected /%/, got: %', p_label, p_pattern, SQLERRM;
    END IF;
    RETURN;
  END;
  RAISE EXCEPTION 'TEST FAILED: % — statement succeeded but must fail', p_label;
END $$;

CREATE OR REPLACE FUNCTION public.t_ctx(p_tenant text) RETURNS void
LANGUAGE sql AS $$
  SELECT set_config('app.tenant_id', CASE p_tenant WHEN 'A' THEN '0a000000-0000-7000-8000-000000000001'
                                                    WHEN 'B' THEN '0b000000-0000-7000-8000-000000000001' ELSE '' END, true),
         set_config('app.user_id', '0a000000-0000-7000-8000-00000000a001', true);
$$;

CREATE OR REPLACE FUNCTION public.t_acc(p_company uuid, p_code text) RETURNS uuid
LANGUAGE sql STABLE AS $$ SELECT id FROM ledger.account WHERE company_id = p_company AND code = p_code $$;

CREATE OR REPLACE FUNCTION public.t_dim(p_type text, p_code text) RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT v.id FROM ledger.dimension_value v JOIN ledger.dimension_type t ON t.id = v.dimension_type_id
   WHERE t.code = p_type AND v.code = p_code
$$;

CREATE OR REPLACE FUNCTION public.t_fy(p_company uuid, p_code text) RETURNS uuid
LANGUAGE sql STABLE AS $$ SELECT id FROM ledger.fiscal_year WHERE company_id = p_company AND code = p_code $$;

CREATE OR REPLACE FUNCTION public.t_ref(p_company uuid, p_date date) RETURNS bigint
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(max(j.reference_no), 0) + 1 FROM ledger.journal j
    JOIN ledger.fiscal_year f ON f.id = j.fiscal_year_id
   WHERE j.company_id = p_company AND p_date BETWEEN f.start_date AND f.end_date
$$;

-- سال مالی ۳۶۵ روزه با ۱۲ دورهٔ جلالی (۶×۳۱، ۵×۳۰، ۲۹)
CREATE OR REPLACE FUNCTION public.t_make_year(p_company uuid, p_code text, p_start date, p_prev uuid, p_periods integer DEFAULT 12)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid := uuidv7(); lens int[] := ARRAY[31,31,31,31,31,31,30,30,30,30,30,29]; d date := p_start; i int;
BEGIN
  INSERT INTO ledger.fiscal_year (tenant_id, id, company_id, code, name, start_date, end_date, base_currency, previous_year_id)
  VALUES (core.current_tenant_id(), v_id, p_company, p_code, 'سال ' || p_code, p_start, p_start + 364, 'IRR', p_prev);
  FOR i IN 1..p_periods LOOP
    INSERT INTO ledger.fiscal_period (tenant_id, company_id, fiscal_year_id, period_no, name, start_date, end_date)
    VALUES (core.current_tenant_id(), p_company, v_id, i, 'ماه ' || i, d, d + lens[i] - 1);
    d := d + lens[i];
  END LOOP;
  RETURN v_id;
END $$;

-- ثبت سند آزمایشی (در تولید: LedgerPostingService). سطرها: [{"a":کد|"aid":uuid,"dr":..,"cr":..,"d1".."d3":uuid,
-- "br":uuid,"cur":"USD","rate":..,"dtx":..,"ctx":..,"kind":"..","ln":..}]
CREATE OR REPLACE FUNCTION public.t_post(p_company uuid, p_date date, p_lines jsonb, p_type text DEFAULT 'manual',
                                         p_source text DEFAULT 'ledger', p_doc_id uuid DEFAULT NULL, p_event text DEFAULT 'post',
                                         p_soft boolean DEFAULT false, p_unit core.amount_unit DEFAULT NULL,
                                         p_count integer DEFAULT NULL, p_total numeric DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid := uuidv7(); v_fy uuid; v_base char(3); v_ref bigint; v_n int; v_tot numeric; v_memo numeric;
BEGIN
  SELECT f.id, f.base_currency INTO v_fy, v_base FROM ledger.fiscal_year f
   WHERE f.company_id = p_company AND p_date BETWEEN f.start_date AND f.end_date;
  v_ref := public.t_ref(p_company, p_date);
  WITH x AS (
    SELECT o.l, COALESCE((o.l->>'aid')::uuid, a.id) AS acc
      FROM jsonb_array_elements(p_lines) WITH ORDINALITY o(l, ord)
      LEFT JOIN ledger.account a ON a.company_id = p_company AND a.code = o.l->>'a')
  SELECT count(*), COALESCE(sum((x.l->>'dr')::numeric), 0),
         COALESCE(sum((x.l->>'dr')::numeric) FILTER (WHERE ac.account_type = 'memo'), 0)
    INTO v_n, v_tot, v_memo
    FROM x LEFT JOIN ledger.account ac ON ac.id = x.acc;
  INSERT INTO ledger.journal (tenant_id, id, company_id, fiscal_year_id, journal_date, journal_type, status, reference_no, reference_text,
                              source_module, source_doc_type, source_doc_id, source_event, base_currency, line_count,
                              total_debit_base, total_credit_base, memo_debit_base, memo_credit_base, soft_close_override,
                              input_amount_unit, description)
  VALUES (core.current_tenant_id(), v_id, p_company, v_fy, p_date, p_type, 'temporary', v_ref, 'T-' || v_ref,
          p_source, CASE WHEN p_doc_id IS NOT NULL THEN p_source || '.doc' END, p_doc_id, p_event, COALESCE(v_base, 'IRR'),
          COALESCE(p_count, v_n), COALESCE(p_total, v_tot), COALESCE(p_total, v_tot), v_memo, v_memo, p_soft, p_unit, 'آزمون');
  INSERT INTO ledger.journal_line (tenant_id, journal_id, line_no, account_id, branch_id, dim1_id, dim2_id, dim3_id, currency,
                                   exchange_rate, debit_txn, credit_txn, debit_base, credit_base, line_kind)
  SELECT core.current_tenant_id(), v_id, COALESCE((o.l->>'ln')::int, o.ord::int), COALESCE((o.l->>'aid')::uuid, a.id),
         (o.l->>'br')::uuid, (o.l->>'d1')::uuid, (o.l->>'d2')::uuid, (o.l->>'d3')::uuid,
         COALESCE(o.l->>'cur', v_base, 'IRR'), COALESCE((o.l->>'rate')::numeric, 1),
         COALESCE((o.l->>'dtx')::numeric, (o.l->>'dr')::numeric, 0), COALESCE((o.l->>'ctx')::numeric, (o.l->>'cr')::numeric, 0),
         COALESCE((o.l->>'dr')::numeric, 0), COALESCE((o.l->>'cr')::numeric, 0), COALESCE(o.l->>'kind', 'normal')
    FROM jsonb_array_elements(p_lines) WITH ORDINALITY o(l, ord)
    LEFT JOIN ledger.account a ON a.company_id = p_company AND a.code = o.l->>'a';
  RETURN v_id;
END $$;

-- سند آینهٔ نادرست (برای آزمون منفی ابطال/برگشت)
CREATE OR REPLACE FUNCTION public.t_bad_mirror(p_original uuid, p_kind text, p_acc_a uuid, p_acc_b uuid, p_dim uuid,
                                               p_void_original boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE o ledger.journal; v uuid := uuidv7();
BEGIN
  SELECT * INTO o FROM ledger.journal WHERE id = p_original;
  INSERT INTO ledger.journal (tenant_id, id, company_id, journal_date, journal_type, status, reference_no, reference_text, source_module,
                              base_currency, line_count, total_debit_base, total_credit_base, void_of_journal_id, reversal_of_journal_id, void_reason)
  VALUES (o.tenant_id, v, o.company_id, o.journal_date, p_kind, CASE p_kind WHEN 'void' THEN 'voided' ELSE 'temporary' END,
          public.t_ref(o.company_id, o.journal_date), 'BAD', o.source_module, o.base_currency, 2, o.total_debit_base, o.total_credit_base,
          CASE WHEN p_kind = 'void' THEN o.id END, CASE WHEN p_kind = 'reversal' THEN o.id END, CASE WHEN p_kind = 'void' THEN 'bad mirror' END);
  INSERT INTO ledger.journal_line (tenant_id, journal_id, line_no, account_id, currency, exchange_rate, debit_txn, credit_txn, debit_base, credit_base, dim1_id)
  VALUES (o.tenant_id, v, 1, p_acc_a, 'IRR', 1, 0, o.total_debit_base, 0, o.total_debit_base, NULL),
         (o.tenant_id, v, 2, p_acc_b, 'IRR', 1, o.total_debit_base, 0, o.total_debit_base, 0, p_dim);
  IF p_kind = 'void' AND p_void_original THEN
    UPDATE ledger.journal SET status = 'voided', void_reason = 'bad mirror' WHERE id = o.id;
  END IF;
END $$;

-- زیردفتر جعلی اشخاص (به‌جای ماژول parties/sales مرحلهٔ ۲) برای آزمون قرارداد subledger_source
CREATE TABLE public.t_party_items (tenant_id uuid NOT NULL, company_id uuid NOT NULL, account_id uuid NOT NULL,
                                   party_dim uuid NOT NULL, amount numeric NOT NULL);
ALTER TABLE public.t_party_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY p ON public.t_party_items USING (tenant_id = core.current_tenant_id()) WITH CHECK (tenant_id = core.current_tenant_id());
GRANT SELECT, INSERT, UPDATE, DELETE ON public.t_party_items TO hk_app;
CREATE OR REPLACE FUNCTION public.t_party_subledger(p_company_id uuid, p_as_of date)
RETURNS TABLE (account_id uuid, dim_value_id uuid, currency char(3), balance_base numeric, balance_txn numeric)
LANGUAGE sql STABLE AS $$
  SELECT i.account_id, i.party_dim, 'IRR'::char(3), sum(i.amount), sum(i.amount)
    FROM public.t_party_items i WHERE i.company_id = p_company_id GROUP BY 1, 2
$$;
INSERT INTO ledger.subledger_source (subledger_kind, owner_module, balance_function, dim_slot, compare_txn, introduced_in)
VALUES ('party', 'tests', 'public.t_party_subledger', 1, true, 'test');

-- سرسند خام با مقادیر قابل‌بازنویسی (برای آزمون مستقیم هر بررسی journal_before_insert؛ T20)
-- p_over: jsonb با نام ستون‌های ledger.journal؛ دو سطر ۵۱۰۱ بدهکار ۱ / ۵۲۰۱ بستانکار ۱
CREATE OR REPLACE FUNCTION public.t_raw(p_company uuid, p_date date, p_over jsonb DEFAULT '{}')
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE r ledger.journal; v_fy ledger.fiscal_year;
BEGIN
  SELECT * INTO v_fy FROM ledger.fiscal_year f WHERE f.company_id = p_company AND p_date BETWEEN f.start_date AND f.end_date;
  r.tenant_id := core.current_tenant_id(); r.id := uuidv7(); r.company_id := p_company; r.fiscal_year_id := v_fy.id;
  r.journal_date := p_date; r.journal_type := 'manual'; r.status := 'temporary';
  r.reference_no := public.t_ref(p_company, p_date); r.reference_text := 'R-' || r.reference_no;
  r.description := 'raw'; r.source_module := 'ledger'; r.source_event := 'post'; r.base_currency := COALESCE(v_fy.base_currency, 'IRR');
  r.line_count := 2; r.total_debit_base := 1; r.total_credit_base := 1; r.memo_debit_base := 0; r.memo_credit_base := 0;
  r.soft_close_override := false; r.posted_at := now(); r.updated_at := now(); r.row_version := 1;
  r := jsonb_populate_record(r, p_over);
  INSERT INTO ledger.journal SELECT r.*;
  INSERT INTO ledger.journal_line (tenant_id, journal_id, line_no, account_id, currency, exchange_rate, debit_txn, credit_txn, debit_base, credit_base)
  VALUES (r.tenant_id, r.id, 1, public.t_acc(p_company, '5101'), 'IRR', 1, 1, 0, 1, 0),
         (r.tenant_id, r.id, 2, public.t_acc(p_company, '5201'), 'IRR', 1, 0, 1, 0, 1);
  RETURN r.id;
END $$;

-- کاتالوگ‌های معیوب برای آزمون مسیرهای خطای اعمال قالب و ارزیابی صورت (T20)
INSERT INTO ledger.coa_template (code, version, industry_pack, extends_code, extends_version, name_fa, code_mode, levels, source, confidence) VALUES
  ('test.ext', 1, 'test', 'ir.general', 1, 'آزمون extends', 'hierarchical', '[{"level":1,"name_fa":"گروه","segment_length":1}]', 'test', 'low'),
  ('test.badparent', 1, 'test', NULL, NULL, 'آزمون والد', 'free',
   '[{"level":1,"name_fa":"گروه","segment_length":1},{"level":2,"name_fa":"کل","segment_length":1}]', 'test', 'low'),
  ('test.baddim', 1, 'test', NULL, NULL, 'آزمون بُعد', 'free', '[{"level":1,"name_fa":"گروه","segment_length":1}]', 'test', 'low');
INSERT INTO ledger.coa_template_account (template_code, template_version, code, parent_code, level, name_fa, kind, account_type, dimension_rules) VALUES
  ('test.badparent', 1, '91', '9', 2, 'بی‌والد', 'posting', 'asset', '{}'),
  ('test.baddim', 1, '1', NULL, 1, 'حساب', 'posting', 'asset', '{"no_such_type":"optional"}');
INSERT INTO ledger.report_template (code, version, kind, name_fa) VALUES ('test.badformula', 1, 'custom', 'آزمون فرمول');
INSERT INTO ledger.report_template_row (template_code, template_version, row_code, sort_order, label_fa, row_type, formula)
VALUES ('test.badformula', 1, 'TOTAL', 1, 'جمع', 'formula', 'AAA + BBB');
COMMIT;

-- =====================================================================
-- بخش ۲: ادعاها با نقش برنامه
-- =====================================================================
SET ROLE hk_app;

-- ---------- T00: آماده‌سازی با نقش برنامه (کدینگ از قالب، ابعاد، سال‌ها) ----------
DO $$
DECLARE n integer; CA uuid := '0a000000-0000-7000-8000-0000000000c1'; CA2 uuid := '0a000000-0000-7000-8000-0000000000c2';
BEGIN
  PERFORM t_ctx('A');
  PERFORM ledger.provision_tenant();
  PERFORM assert_true((SELECT count(*) FROM ledger.dimension_type) = 9, 'T00 provision dimension types');
  PERFORM assert_true(ledger.provision_tenant() = 0, 'T00 provision is idempotent');
  n := ledger.apply_coa_template(CA, 'ir.general', 1);
  PERFORM assert_true(n >= 90, 'T00 template applied: ' || n);
  PERFORM ledger.apply_coa_template(CA2, 'ir.general', 1);
  INSERT INTO ledger.dimension_value (tenant_id, dimension_type_id, code, name, source_module, source_entity_id)
  SELECT core.current_tenant_id(), t.id, v.code, v.name, v.src, uuidv7()
    FROM (VALUES ('party','P1','مشتری ۱','parties'), ('party','P2','مشتری ۲','parties'), ('party','PX','غیرفعال','parties'),
                 ('cash_box','CB1','صندوق ۱','treasury'), ('bank_account','BK1','بانک ملت','treasury'),
                 ('employee','E1','کارمند ۱','payroll')) v(type, code, name, src)
    JOIN ledger.dimension_type t ON t.code = v.type;
  INSERT INTO ledger.dimension_value (tenant_id, dimension_type_id, code, name, is_group)
  SELECT core.current_tenant_id(), t.id, 'CCG', 'گروه مراکز', true FROM ledger.dimension_type t WHERE t.code = 'cost_center';
  INSERT INTO ledger.dimension_value (tenant_id, dimension_type_id, code, name, parent_id)
  SELECT core.current_tenant_id(), t.id, 'CC1', 'مرکز ۱', t_dim('cost_center', 'CCG') FROM ledger.dimension_type t WHERE t.code = 'cost_center';
  INSERT INTO ledger.dimension_value (tenant_id, dimension_type_id, code, name, company_id)
  SELECT core.current_tenant_id(), t.id, 'PR2', 'پروژهٔ شرکت ۲', CA2 FROM ledger.dimension_type t WHERE t.code = 'project';
  INSERT INTO ledger.dimension_value (tenant_id, dimension_type_id, code, name)
  SELECT core.current_tenant_id(), t.id, 'PR1', 'پروژه ۱' FROM ledger.dimension_type t WHERE t.code = 'project';
  UPDATE ledger.dimension_value SET is_active = false WHERE code = 'PX';
  PERFORM assert_true((SELECT slot FROM ledger.dimension_value WHERE code = 'CC1') = 2, 'T00 value slot copied from type');
  PERFORM t_make_year(CA, '1405', '2026-03-21', NULL);
  PERFORM t_make_year(CA2, '1405', '2026-03-21', NULL);
END $$;

-- ---------- T01: جداسازی مستأجر و fail-closed ----------
DO $$
BEGIN
  PERFORM t_ctx('');
  PERFORM assert_true((SELECT count(*) FROM ledger.account) = 0, 'T01 no tenant context sees no accounts');
  PERFORM assert_true((SELECT count(*) FROM ledger.fiscal_year) = 0, 'T01 no tenant context sees no fiscal years');
  PERFORM t_ctx('B');
  PERFORM assert_true((SELECT count(*) FROM ledger.account) = 0, 'T01 tenant B sees no accounts of A');
  PERFORM expect_error($q$INSERT INTO ledger.rate_type (tenant_id, code, name) VALUES ('0a000000-0000-7000-8000-000000000001','x','x')$q$,
                       'row-level security', 'T01 cross-tenant insert blocked by RLS');
  PERFORM expect_error($q$INSERT INTO ledger.journal_type (code, entry_class, class_rank, origin, name_fa, introduced_in)
                          VALUES ('hack','regular',1,'manual','x','1')$q$, 'permission denied', 'T01 catalogs are read-only');
  PERFORM expect_error($q$INSERT INTO ledger.balance_bucket (tenant_id, company_id, fiscal_year_id, period_id, account_id, entry_class,
                          currency, debit_base, credit_base, debit_txn, credit_txn, line_count)
                          VALUES (core.current_tenant_id(), uuidv7(), uuidv7(), uuidv7(), uuidv7(), 'regular', 'IRR', 1, 0, 1, 0, 1)$q$,
                       'permission denied', 'T01 buckets are not writable by hk_app');
END $$;

-- ---------- T02: کدینگ (درخت، سطح، نوع، کد سلسله‌مراتبی، شرکت) ----------
DO $$
DECLARE CA uuid := '0a000000-0000-7000-8000-0000000000c1'; CA2 uuid := '0a000000-0000-7000-8000-0000000000c2';
BEGIN
  PERFORM t_ctx('A');
  PERFORM expect_error(format($q$INSERT INTO ledger.account (tenant_id, company_id, parent_id, level, code, name, kind, account_type)
     VALUES (core.current_tenant_id(), %L, %L, 4, '110101', 'x', 'posting', 'asset')$q$, CA, t_acc(CA, '1101')),
     'HK_LEDGER_PARENT_NOT_GROUP', 'T02 child of a posting account');
  PERFORM expect_error(format($q$INSERT INTO ledger.account (tenant_id, company_id, parent_id, level, code, name, kind, account_type)
     VALUES (core.current_tenant_id(), %L, %L, 3, '1199', 'x', 'posting', 'expense')$q$, CA, t_acc(CA, '11')),
     'HK_LEDGER_ACCOUNT_TYPE_MISMATCH', 'T02 child type must equal parent type');
  PERFORM expect_error(format($q$INSERT INTO ledger.account (tenant_id, company_id, parent_id, level, code, name, kind, account_type)
     VALUES (core.current_tenant_id(), %L, %L, 3, '19', 'x', 'posting', 'asset')$q$, CA, t_acc(CA, '1')),
     'HK_LEDGER_ACCOUNT_LEVEL', 'T02 level = parent level + 1');
  PERFORM expect_error(format($q$INSERT INTO ledger.account (tenant_id, company_id, parent_id, level, code, name, kind, account_type)
     VALUES (core.current_tenant_id(), %L, %L, 3, '1299', 'x', 'posting', 'asset')$q$, CA, t_acc(CA, '11')),
     'HK_LEDGER_ACCOUNT_CODE', 'T02 hierarchical code prefix');
  INSERT INTO ledger.account (tenant_id, company_id, parent_id, level, code, name, kind, account_type)
  VALUES (core.current_tenant_id(), CA, t_acc(CA, '11'), 3, '1190', 'گروه آزمایشی', 'group', 'asset');
  PERFORM expect_error(format($q$INSERT INTO ledger.account (tenant_id, company_id, parent_id, level, code, name, kind, account_type)
     VALUES (core.current_tenant_id(), %L, %L, 4, '119001', 'x', 'posting', 'asset')$q$, CA, t_acc(CA, '1190')),
     'HK_LEDGER_ACCOUNT_DEPTH', 'T02 depth limited by coa_level');
  PERFORM expect_error(format($q$INSERT INTO ledger.account (tenant_id, company_id, parent_id, level, code, name, kind, account_type)
     VALUES (core.current_tenant_id(), %L, %L, 3, '1198', 'x', 'posting', 'asset')$q$, CA2, t_acc(CA, '11')),
     'violates foreign key|HK_LEDGER', 'T02 parent must be in the same company');
  PERFORM expect_error(format($q$INSERT INTO ledger.account (tenant_id, company_id, parent_id, level, code, name, kind, account_type)
     VALUES (core.current_tenant_id(), %L, %L, 3, '1101', 'x', 'posting', 'asset')$q$, CA, t_acc(CA, '11')),
     'duplicate key', 'T02 code unique per company');
  -- تغییر کد گروه بدون تغییر کد فرزندان در همان تراکنش
  PERFORM expect_error(format($q$UPDATE ledger.account SET code = '24' WHERE id = %L$q$, t_acc(CA, '23')),
     'HK_LEDGER_ACCOUNT_CODE', 'T02 recode group requires recoding children (deferred)');
  UPDATE ledger.account SET code = '24' WHERE id = t_acc(CA, '23');
  UPDATE ledger.account SET code = '2401' WHERE id = t_acc(CA, '2301');
  -- قاعدهٔ بعد روی حساب گروه
  PERFORM expect_error(format($q$INSERT INTO ledger.account_dimension_rule (tenant_id, account_id, dimension_type_id, requirement)
     VALUES (core.current_tenant_id(), %L, (SELECT id FROM ledger.dimension_type WHERE code='project'), 'optional')$q$, t_acc(CA, '12')),
     'HK_LEDGER_RULE_ON_GROUP', 'T02 dimension rules only on posting accounts');
  -- دو نوع در یک جایگاه وقتی یکی اجباری است
  PERFORM expect_error(format($q$INSERT INTO ledger.account_dimension_rule (tenant_id, account_id, dimension_type_id, requirement)
     VALUES (core.current_tenant_id(), %L, (SELECT id FROM ledger.dimension_type WHERE code='bank_account'), 'optional')$q$, t_acc(CA, '1201')),
     'HK_LEDGER_RULE_SLOT_CONFLICT', 'T02 a required slot excludes other types');
  -- جایگاه نوع بعد پس از استفاده تغییرناپذیر (FK ترکیبی شامل slot)
  PERFORM expect_error($q$UPDATE ledger.dimension_type SET slot = 4 WHERE code = 'party'$q$,
     'violates foreign key', 'T02 slot of a used dimension type is immutable');
END $$;

-- ---------- T03: سال و دوره ----------
DO $$
DECLARE CA uuid := '0a000000-0000-7000-8000-0000000000c1'; v uuid;
BEGIN
  PERFORM t_ctx('A');
  PERFORM expect_error(format($q$SELECT t_make_year(%L, '1406x', '2027-03-21', %L, 11)$q$, CA, t_fy(CA, '1405')),
     'HK_LEDGER_PERIOD_COVERAGE', 'T03 periods must cover the year (deferred)');
  PERFORM expect_error(format($q$SELECT t_make_year(%L, '1406x', '2027-03-25', %L)$q$, CA, t_fy(CA, '1405')),
     'HK_LEDGER_FY_CHAIN', 'T03 next year must be contiguous');
  PERFORM expect_error(format($q$SELECT t_make_year(%L, '1300', '2020-03-21', NULL)$q$, CA),
     'HK_LEDGER_FY_CHAIN', 'T03 only one first year per company');
  PERFORM expect_error(format($q$INSERT INTO ledger.fiscal_year (tenant_id, company_id, code, name, start_date, end_date, base_currency, previous_year_id)
     VALUES (core.current_tenant_id(), %L, 'X', 'x', '2026-06-01', '2027-05-31', 'IRR', %L)$q$, CA, t_fy(CA, '1405')),
     'conflicting key|exclusion|HK_LEDGER_FY_CHAIN', 'T03 overlapping years rejected');
  PERFORM expect_error(format($q$INSERT INTO ledger.fiscal_year (tenant_id, company_id, code, name, start_date, end_date, base_currency, previous_year_id)
     VALUES (core.current_tenant_id(), %L, 'X', 'x', '2027-03-21', '2028-03-19', 'USD', %L)$q$, CA, t_fy(CA, '1405')),
     'HK_LEDGER_FY_CURRENCY', 'T03 base currency equals company base');
  PERFORM expect_error(format($q$INSERT INTO ledger.fiscal_period (tenant_id, company_id, fiscal_year_id, period_no, name, start_date, end_date)
     VALUES (core.current_tenant_id(), %L, %L, 13, 'x', '2027-03-21', '2027-03-25')$q$, CA, t_fy(CA, '1405')),
     'HK_LEDGER_PERIOD_RANGE', 'T03 period inside its year');
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_period SET end_date = end_date + 1 WHERE fiscal_year_id = %L AND period_no = 1$q$, t_fy(CA, '1405')),
     'HK_LEDGER_PERIOD_IMMUTABLE', 'T03 period dates immutable');
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_year SET start_date = start_date + 1 WHERE id = %L$q$, t_fy(CA, '1405')),
     'HK_LEDGER_FY_IMMUTABLE', 'T03 fiscal year dates immutable');
END $$;

-- ---------- T04: ثبت سند — موارد مثبت و تراز ----------
DO $$
DECLARE CA uuid := '0a000000-0000-7000-8000-0000000000c1'; j uuid;
BEGIN
  PERFORM t_ctx('A');
  j := t_post(CA, '2026-04-01', jsonb_build_array(
         jsonb_build_object('a','1101','dr',1000000,'d1',t_dim('cash_box','CB1')),
         jsonb_build_object('a','5101','cr',1000000)));
  PERFORM assert_true((SELECT status FROM ledger.journal WHERE id = j) = 'temporary', 'T04 posted as temporary');
  PERFORM assert_true((SELECT count(*) FROM ledger.journal_line WHERE journal_id = j AND company_id = CA AND period_id IS NOT NULL) = 2,
                      'T04 lines denormalized from header');
  -- فروش نسیه با شخص و پروژه، و ارزی در بانک
  PERFORM t_post(CA, '2026-04-10', jsonb_build_array(
         jsonb_build_object('a','1201','dr',2500000,'d1',t_dim('party','P1'),'d3',t_dim('project','PR1')),
         jsonb_build_object('a','6101','cr',2500000,'d2',t_dim('cost_center','CC1'))), 'module', 'sales', uuidv7());
  PERFORM t_post(CA, '2026-05-02', jsonb_build_array(
         jsonb_build_object('a','1102','dr',3336667,'d1',t_dim('bank_account','BK1'),'cur','USD','rate',333333.3333,'dtx',10.01,'ctx',0),
         jsonb_build_object('a','5101','cr',3336667)));
  -- سند انتظامی تراز با زیردفتر خزانه
  PERFORM t_post(CA, '2026-05-03', jsonb_build_array(
         jsonb_build_object('a','8101','dr',700000,'d1',t_dim('party','P1')),
         jsonb_build_object('a','8201','cr',700000,'d1',t_dim('party','P1'))), 'module', 'treasury', uuidv7());
  PERFORM assert_true((SELECT memo_debit_base FROM ledger.journal WHERE total_debit_base = 700000) = 700000, 'T04 memo totals');
  PERFORM assert_true(NOT EXISTS (SELECT 1 FROM ledger.verify_balance_buckets(CA, t_fy(CA, '1405'))), 'T04 buckets equal lines');
END $$;

-- ---------- T05: ثبت سند — نقض‌ها ----------
DO $$
DECLARE CA uuid := '0a000000-0000-7000-8000-0000000000c1'; CA2 uuid := '0a000000-0000-7000-8000-0000000000c2'; j uuid; cb text;
BEGIN
  PERFORM t_ctx('A');
  cb := t_dim('cash_box','CB1')::text;
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-02', '[{"a":"1101","dr":100,"d1":"%s"},{"a":"5101","cr":90}]')$q$, CA, cb),
     'HK_UNBALANCED', 'T05 unbalanced journal rejected at commit');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-02', '[{"a":"1101","dr":100,"d1":"%s"},{"a":"5101","cr":100}]', p_total => 200)$q$, CA, cb),
     'HK_UNBALANCED', 'T05 header totals must equal line sums');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-02', '[{"a":"1101","dr":100,"d1":"%s"},{"a":"5101","cr":100}]', p_total => 100, p_count => 3)$q$, CA, cb),
     'HK_LEDGER_LINE_COUNT', 'T05 declared line count enforced');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-02', '[{"a":"1101","dr":100,"d1":"%s"},{"a":"5101","cr":100,"ln":3}]')$q$, CA, cb),
     'HK_LEDGER_LINE_SLOT', 'T05 line_no within line_count');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-02', '[{"a":"1101","dr":100,"cr":100,"d1":"%s"},{"a":"5101","cr":100}]')$q$, CA, cb),
     'check constraint', 'T05 a line has a single side');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-02', '[{"a":"1101","dr":0,"d1":"%s"},{"a":"5101","cr":0}]', p_total => 1)$q$, CA, cb),
     'check constraint', 'T05 zero lines rejected');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-02', '[{"a":"1101","dr":100.5,"d1":"%s"},{"a":"5101","cr":100.5}]')$q$, CA, cb),
     'HK_LEDGER_AMOUNT_PRECISION', 'T05 IRR has no decimals');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-02', '[{"a":"1101","dr":100,"rate":2,"d1":"%s"},{"a":"5101","cr":100}]')$q$, CA, cb),
     'HK_LEDGER_BASE_MISMATCH', 'T05 base-currency line has rate 1');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-05-02', '[{"a":"1102","dr":5000001,"d1":"%s","cur":"USD","rate":500000,"dtx":10,"ctx":0},{"a":"5101","cr":5000001}]')$q$,
       CA, t_dim('bank_account','BK1')), 'HK_LEDGER_BASE_MISMATCH', 'T05 base = round(txn x rate)');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-05-02', '[{"a":"1102","dr":5000000,"d1":"%s","cur":"USD","rate":500000,"dtx":10.001,"ctx":0},{"a":"5101","cr":5000000}]')$q$,
       CA, t_dim('bank_account','BK1')), 'HK_LEDGER_AMOUNT_PRECISION', 'T05 txn precision per currency minor unit');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-05-02', '[{"a":"1103","dr":5000000,"cur":"USD","rate":500000,"dtx":10,"ctx":0},{"a":"5101","cr":5000000}]')$q$,
       CA), 'HK_LEDGER_ACCOUNT_CURRENCY', 'T05 base_only account rejects foreign currency');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-05-02', '[{"a":"1102","dr":1000,"d1":"%s","cur":"USD","rate":1,"dtx":0,"ctx":0,"kind":"base_adjustment"},{"a":"5101","cr":1000}]')$q$,
       CA, t_dim('bank_account','BK1')), 'HK_LEDGER_BASE_ONLY_LINE', 'T05 base-only lines only for permitted journal types');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-05-03', '[{"a":"8101","dr":700,"d1":"%s"},{"a":"5101","cr":700}]', 'module', 'treasury')$q$,
       CA, t_dim('party','P1')), 'HK_LEDGER_MEMO_UNBALANCED', 'T05 memo lines balance among themselves');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-02', '[{"a":"11","dr":100},{"a":"5101","cr":100}]')$q$, CA),
     'HK_LEDGER_ACCOUNT_NOT_POSTABLE', 'T05 no posting into group accounts');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-02', '[{"aid":"%s","dr":100},{"a":"5101","cr":100}]')$q$, CA, t_acc(CA2, '5101')),
     'HK_LEDGER_ACCOUNT_COMPANY', 'T05 account must belong to the journal company');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-02', '[{"a":"5101","dr":100},{"a":"5201","cr":100}]', 'manual', 'sales')$q$, CA),
     'HK_LEDGER_SOURCE_MODULE', 'T05 manual journals belong to ledger');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-02', '[{"a":"5101","dr":100},{"a":"5201","cr":100}]', 'module', 'ledger')$q$, CA),
     'HK_LEDGER_SOURCE_MODULE', 'T05 module journals name their module');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-03-21', '[{"a":"5101","dr":100},{"a":"5201","cr":100}]', 'opening_import')$q$, CA),
     'HK_LEDGER_INPUT_UNIT', 'T05 imported amounts declare their unit');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-02', '[{"a":"5101","dr":100},{"a":"5201","cr":100}]', 'opening_import', p_unit => 'IRR')$q$, CA),
     'HK_LEDGER_OPENING_STATE', 'T05 opening journals only on the first day');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2030-01-01', '[{"a":"5101","dr":100},{"a":"5201","cr":100}]')$q$, CA),
     'HK_LEDGER_NO_FISCAL_YEAR', 'T05 date must be inside a fiscal year');
  -- حساب غیرفعال
  UPDATE ledger.account SET is_active = false WHERE id = t_acc(CA, '5201');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-02', '[{"a":"5101","dr":100},{"a":"5201","cr":100}]')$q$, CA),
     'HK_LEDGER_ACCOUNT_INACTIVE', 'T05 inactive account rejected');
  UPDATE ledger.account SET is_active = true WHERE id = t_acc(CA, '5201');
END $$;

-- ---------- T06: قواعد ابعاد، شعبه و حساب کنترلی ----------
DO $$
DECLARE CA uuid := '0a000000-0000-7000-8000-0000000000c1'; BA uuid := '0a000000-0000-7000-8000-0000000000b1';
BEGIN
  PERFORM t_ctx('A');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-03', '[{"a":"1201","dr":100},{"a":"6101","cr":100}]', 'module', 'sales')$q$, CA),
     'HK_LEDGER_DIM_REQUIRED', 'T06 required dimension missing');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-03', '[{"a":"1201","dr":100,"d1":"%s"},{"a":"6101","cr":100}]', 'module', 'sales')$q$,
     CA, t_dim('cash_box','CB1')), 'HK_LEDGER_DIM_FORBIDDEN', 'T06 dimension type not allowed on the account');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-03', '[{"a":"1201","dr":100,"d1":"%s","d2":"%s"},{"a":"6101","cr":100}]', 'module', 'sales')$q$,
     CA, t_dim('party','P1'), t_dim('party','P2')), 'HK_LEDGER_DIM_SLOT', 'T06 value must sit in its type slot');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-03', '[{"a":"1201","dr":100,"d1":"%s"},{"a":"6101","cr":100}]', 'module', 'sales')$q$,
     CA, t_dim('party','PX')), 'HK_LEDGER_DIM_NOT_POSTABLE', 'T06 inactive dimension value');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-03', '[{"a":"7202","dr":100,"d2":"%s"},{"a":"5101","cr":100}]')$q$,
     CA, t_dim('cost_center','CCG')), 'HK_LEDGER_DIM_NOT_POSTABLE', 'T06 group dimension value not postable');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-03', '[{"a":"6101","dr":100,"d3":"%s"},{"a":"5101","cr":100}]')$q$,
     CA, t_dim('project','PR2')), 'HK_LEDGER_DIM_COMPANY', 'T06 company-restricted dimension value');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-03', '[{"a":"1101","dr":100,"d1":"%s","d2":"%s"},{"a":"5101","cr":100}]')$q$,
     CA, t_dim('cash_box','CB1'), t_dim('cost_center','CC1')), 'HK_LEDGER_DIM_FORBIDDEN', 'T06 unlisted dimension type is forbidden');
  UPDATE ledger.account SET branch_rule = 'required' WHERE id = t_acc(CA, '7202');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-03', '[{"a":"7202","dr":100},{"a":"5101","cr":100}]')$q$, CA),
     'HK_LEDGER_BRANCH_REQUIRED', 'T06 branch required by account');
  PERFORM t_post(CA, '2026-04-03', jsonb_build_array(jsonb_build_object('a','7202','dr',100,'br',BA), jsonb_build_object('a','5101','cr',100)));
  UPDATE ledger.account SET branch_rule = 'forbidden' WHERE id = t_acc(CA, '7202');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-03', '[{"a":"7202","dr":100,"br":"%s"},{"a":"5101","cr":100}]')$q$, CA, BA),
     'HK_LEDGER_BRANCH_FORBIDDEN', 'T06 branch forbidden by account');
  UPDATE ledger.account SET branch_rule = 'optional' WHERE id = t_acc(CA, '7202');
  -- حساب کنترلی و فقط‌سیستمی
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-03', '[{"a":"1401","dr":100},{"a":"5101","cr":100}]')$q$, CA),
     'HK_LEDGER_CONTROL_ACCOUNT', 'T06 control account rejects manual journals');
  PERFORM t_post(CA, '2026-04-03', '[{"a":"1401","dr":100},{"a":"5101","cr":100}]', 'module', 'inventory', uuidv7());
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-03', '[{"a":"5303","dr":100},{"a":"5101","cr":100}]')$q$, CA),
     'HK_LEDGER_SYSTEM_ONLY_ACCOUNT', 'T06 system-only account rejects manual journals');
END $$;

-- ---------- T07: تغییرناپذیری ----------
DO $$
DECLARE CA uuid := '0a000000-0000-7000-8000-0000000000c1'; j uuid;
BEGIN
  PERFORM t_ctx('A');
  SELECT id INTO j FROM ledger.journal WHERE company_id = CA ORDER BY reference_no LIMIT 1;
  PERFORM expect_error(format($q$UPDATE ledger.journal_line SET debit_base = debit_base + 1 WHERE journal_id = %L$q$, j),
     'permission denied', 'T07 lines are not updatable');
  PERFORM expect_error(format($q$DELETE FROM ledger.journal_line WHERE journal_id = %L$q$, j), 'permission denied', 'T07 lines are not deletable');
  PERFORM expect_error(format($q$UPDATE ledger.journal SET description = 'x' WHERE id = %L$q$, j), 'permission denied', 'T07 header content not updatable');
  PERFORM expect_error(format($q$DELETE FROM ledger.journal WHERE id = %L$q$, j), 'permission denied', 'T07 journals are not deletable');
  PERFORM expect_error(format($q$UPDATE ledger.journal SET status = 'permanent' WHERE id = %L$q$, j),
     'HK_LEDGER_|check constraint', 'T07 no direct jump to permanent');
  PERFORM expect_error(format($q$UPDATE ledger.journal SET status = 'voided', void_reason = 'test reason' WHERE id = %L$q$, j),
     'HK_LEDGER_VOID_PAIR', 'T07 void requires the mirror journal');
  PERFORM expect_error(format($q$INSERT INTO ledger.journal_line (tenant_id, journal_id, line_no, account_id, currency, exchange_rate, debit_txn, debit_base)
     VALUES (core.current_tenant_id(), %L, 2, %L, 'IRR', 1, 5, 5)$q$, j, t_acc(CA, '5101')),
     'duplicate key', 'T07 lines cannot be appended to an existing journal (slot taken)');
  PERFORM expect_error(format($q$INSERT INTO ledger.journal_line (tenant_id, journal_id, line_no, account_id, currency, exchange_rate, debit_txn, debit_base)
     VALUES (core.current_tenant_id(), %L, 3, %L, 'IRR', 1, 5, 5)$q$, j, t_acc(CA, '5101')),
     'HK_LEDGER_LINE_SLOT', 'T07 lines cannot be appended to an existing journal (beyond count)');
  UPDATE ledger.journal SET reviewed_at = now(), reviewed_by = core.current_user_id() WHERE id = j;
  PERFORM expect_error(format($q$UPDATE ledger.journal SET reviewed_by = NULL WHERE id = %L$q$, j),
     'HK_LEDGER_BAD_TRANSITION', 'T07 review is recorded once');
END $$;

-- ---------- T08: ابطال و برگشت ----------
DO $$
DECLARE CA uuid := '0a000000-0000-7000-8000-0000000000c1'; j uuid; v uuid; r uuid; doc uuid := uuidv7(); bad uuid;
BEGIN
  PERFORM t_ctx('A');
  j := t_post(CA, '2026-06-01', jsonb_build_array(
         jsonb_build_object('a','1201','dr',400000,'d1',t_dim('party','P2')),
         jsonb_build_object('a','6101','cr',400000)), 'module', 'sales', doc);
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-06-01', '[{"a":"1201","dr":1,"d1":"%s"},{"a":"6101","cr":1}]', 'module', 'sales', %L)$q$,
     CA, t_dim('party','P2'), doc), 'duplicate key', 'T08 idempotent source reference');
  v := ledger.void_journal(j, uuidv7(), t_ref(CA, '2026-06-01'), 'V-1', 'ثبت اشتباه');
  PERFORM assert_true((SELECT status FROM ledger.journal WHERE id = j) = 'voided', 'T08 original voided');
  PERFORM assert_true((SELECT status FROM ledger.journal WHERE id = v) = 'voided', 'T08 void journal voided');
  PERFORM assert_true((SELECT sum(debit_base - credit_base) FROM ledger.journal_line WHERE journal_id IN (j, v) AND account_id = t_acc(CA,'1201')) = 0,
                      'T08 void nets to zero');
  -- پس از ابطال، همان مرجع مبدأ دوباره قابل ثبت است
  j := t_post(CA, '2026-06-01', jsonb_build_array(
         jsonb_build_object('a','1201','dr',450000,'d1',t_dim('party','P2')),
         jsonb_build_object('a','6101','cr',450000)), 'module', 'sales', doc);
  PERFORM expect_error(format($q$SELECT ledger.void_journal(%L, uuidv7(), 999, 'V-x', 'x')$q$, v),
     'HK_LEDGER_VOID_NOT_TEMPORARY', 'T08 a voided journal cannot be voided');
  -- برگشت
  r := ledger.reverse_journal(j, uuidv7(), '2026-06-10', t_ref(CA, '2026-06-10'), 'R-1', NULL, 'cancel');
  PERFORM assert_true(NOT EXISTS (SELECT 1 FROM ledger.journal_line WHERE journal_id IN (j, r)
                       GROUP BY account_id, dim1_id, dim2_id, dim3_id, currency
                       HAVING sum(debit_base - credit_base) <> 0 OR sum(debit_txn - credit_txn) <> 0), 'T08 reversal nets to zero per account');
  PERFORM assert_true((SELECT is_reversed FROM ledger.v_journal_line WHERE journal_id = j LIMIT 1), 'T08 reversed is derived');
  PERFORM expect_error(format($q$SELECT ledger.reverse_journal(%L, uuidv7(), '2026-06-11', 999, 'R-x', NULL, 'cancel2')$q$, j),
     'duplicate key', 'T08 at most one active reversal');
  PERFORM expect_error(format($q$SELECT ledger.void_journal(%L, uuidv7(), 998, 'V-y', 'reason')$q$, j),
     'HK_LEDGER_VOID_HAS_REVERSAL', 'T08 cannot void a reversed journal');
  j := t_post(CA, '2026-06-05', jsonb_build_array(
         jsonb_build_object('a','7202','dr',10000), jsonb_build_object('a','1101','cr',10000,'d1',t_dim('cash_box','CB1'))));
  PERFORM expect_error(format($q$SELECT ledger.reverse_journal(%L, uuidv7(), '2026-06-04', 997, 'R-y')$q$, j),
     'HK_LEDGER_REVERSAL_DATE', 'T08 reversal dated on/after original');
  PERFORM expect_error(format($q$SELECT ledger.reverse_journal(%L, uuidv7(), '2026-06-06', 997, 'R-y')$q$, v),
     'HK_LEDGER_REVERSAL_TARGET', 'T08 voided journals cannot be reversed');
  -- سند ابطال/برگشت با سطرهای غیرآینه
  PERFORM expect_error(format($q$SELECT t_bad_mirror(%L, 'void', %L, %L, %L)$q$, j, t_acc(CA, '7203'), t_acc(CA, '1101'), t_dim('cash_box','CB1')),
     'HK_LEDGER_MIRROR', 'T08 void journal must mirror the original');
  PERFORM expect_error(format($q$SELECT t_bad_mirror(%L, 'reversal', %L, %L, %L)$q$, j, t_acc(CA, '7203'), t_acc(CA, '1101'), t_dim('cash_box','CB1')),
     'HK_LEDGER_MIRROR', 'T08 reversal journal must mirror the original');
  PERFORM expect_error(format($q$SELECT t_bad_mirror(%L, 'void', %L, %L, %L, false)$q$, j, t_acc(CA, '7202'), t_acc(CA, '1101'), t_dim('cash_box','CB1')),
     'HK_LEDGER_VOID_PAIR', 'T08 void journal requires its original to be voided in the same transaction');
  PERFORM ledger.void_journal(j, uuidv7(), t_ref(CA, '2026-06-05'), 'V-2', 'تست ابطال');
END $$;

-- ---------- T09: دوره‌ها، قفل ماژولی، تاریخچه ----------
DO $$
DECLARE CA uuid := '0a000000-0000-7000-8000-0000000000c1'; fy uuid; p1 uuid; p2 uuid; p3 uuid;
BEGIN
  PERFORM t_ctx('A');
  fy := t_fy(CA, '1405');
  SELECT id INTO p1 FROM ledger.fiscal_period WHERE fiscal_year_id = fy AND period_no = 1;
  SELECT id INTO p2 FROM ledger.fiscal_period WHERE fiscal_year_id = fy AND period_no = 2;
  SELECT id INTO p3 FROM ledger.fiscal_period WHERE fiscal_year_id = fy AND period_no = 3;
  UPDATE ledger.fiscal_period SET status = 'soft_closed' WHERE id = p1;
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-04', '[{"a":"5101","dr":10},{"a":"5201","cr":10}]')$q$, CA),
     'HK_LEDGER_PERIOD_SOFT_CLOSED', 'T09 soft-closed period needs override');
  PERFORM t_post(CA, '2026-04-04', '[{"a":"5101","dr":10},{"a":"5201","cr":10}]', p_soft => true);
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_period SET status = 'closed' WHERE id = %L$q$, p2),
     'HK_LEDGER_PERIOD_SEQUENCE', 'T09 periods close in order');
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_period SET status = 'locked' WHERE id = %L$q$, p2),
     'HK_LEDGER_PERIOD_TRANSITION', 'T09 open -> locked not allowed');
  UPDATE ledger.fiscal_period SET status = 'closed' WHERE id = p1;
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-04-04', '[{"a":"5101","dr":10},{"a":"5201","cr":10}]', p_soft => true)$q$, CA),
     'HK_LEDGER_PERIOD_CLOSED', 'T09 no posting into a closed period');
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_period SET status = 'open' WHERE id = %L$q$, p1),
     'HK_LEDGER_REASON_REQUIRED', 'T09 reopen requires a reason');
  UPDATE ledger.fiscal_period SET status = 'open', status_reason = 'اصلاح سند جاافتاده' WHERE id = p1;
  UPDATE ledger.fiscal_period SET status = 'closed', status_reason = NULL WHERE id = p1;
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_period SET status = 'locked' WHERE id = %L$q$, p1),
     'HK_LEDGER_PERIOD_NOT_FINALIZED', 'T09 lock requires finalization');
  PERFORM assert_true((SELECT count(*) FROM ledger.period_status_event WHERE period_id = p1) = 4, 'T09 status history recorded');
  PERFORM expect_error(format($q$UPDATE ledger.period_status_event SET reason = 'x' WHERE period_id = %L$q$, p1),
     'permission denied', 'T09 status history append-only');
  INSERT INTO ledger.period_module_lock (tenant_id, period_id, module, reason) VALUES (core.current_tenant_id(), p3, 'sales', 'اظهارنامه ارسال شد');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-06-02', '[{"a":"1201","dr":10,"d1":"%s"},{"a":"6101","cr":10}]', 'module', 'sales', uuidv7())$q$,
     CA, t_dim('party','P1')), 'HK_LEDGER_MODULE_LOCKED', 'T09 module lock blocks that module');
  PERFORM t_post(CA, '2026-06-02', '[{"a":"5101","dr":10},{"a":"5201","cr":10}]');
END $$;

-- ---------- T10: قطعی کردن (شمارهٔ دائم ترتیبی، روزانه، زنجیره) ----------
DO $$
DECLARE CA uuid := '0a000000-0000-7000-8000-0000000000c1'; fy uuid; n integer; j uuid; late uuid;
BEGIN
  PERFORM t_ctx('A');
  fy := t_fy(CA, '1405');
  -- سند با تاریخ دیرتر زودتر ثبت شده است: ترتیب دائم باید بر اساس تاریخ باشد
  late := t_post(CA, '2026-07-01', '[{"a":"5101","dr":7},{"a":"5201","cr":7}]');
  PERFORM t_post(CA, '2026-06-20', '[{"a":"5101","dr":6},{"a":"5201","cr":6}]');
  PERFORM expect_error(format($q$SELECT ledger.finalize_through(%L, '2026-06-30')$q$, fy),
     'HK_LEDGER_OPENING_PENDING', 'T10 finalization waits for the opening decision');
  UPDATE ledger.fiscal_year SET opening_state = 'not_required' WHERE id = fy;
  n := ledger.finalize_through(fy, '2026-06-30');
  PERFORM assert_true(n > 0, 'T10 journals finalized: ' || n);
  PERFORM assert_true(NOT EXISTS (
      SELECT 1 FROM (SELECT permanent_no, journal_date, class_rank, lag(journal_date) OVER w AS pd, lag(permanent_no) OVER w AS pn
                       FROM ledger.journal WHERE fiscal_year_id = fy AND status = 'permanent' WINDOW w AS (ORDER BY permanent_no)) s
       WHERE s.pd > s.journal_date OR s.pn <> s.permanent_no - 1), 'T10 permanent numbers gapless and date-ordered');
  PERFORM assert_true((SELECT min(permanent_no) FROM ledger.journal WHERE fiscal_year_id = fy) = 1, 'T10 numbering starts at 1');
  PERFORM assert_true(NOT EXISTS (SELECT 1 FROM ledger.journal WHERE fiscal_year_id = fy AND status = 'voided' AND permanent_no IS NOT NULL),
                      'T10 voided journals get no permanent number');
  PERFORM assert_true((SELECT status FROM ledger.journal WHERE id = late) = 'temporary', 'T10 later journal stays temporary');
  PERFORM assert_true(NOT EXISTS (SELECT 1 FROM ledger.verify_permanent_chain(fy)), 'T10 hash chain verifies');
  PERFORM assert_true(NOT EXISTS (
      SELECT 1 FROM (SELECT journal_date, daily_no, row_number() OVER (PARTITION BY journal_date ORDER BY permanent_no) rn
                       FROM ledger.journal WHERE fiscal_year_id = fy AND status = 'permanent') s WHERE s.daily_no <> s.rn),
      'T10 daily numbers restart each day');
  PERFORM assert_true(ledger.finalize_through(fy, '2026-06-30') = 0, 'T10 finalization is idempotent');
  -- بُرش: ثبت با تاریخ ≤ بُرش ممنوع
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-06-30', '[{"a":"5101","dr":1},{"a":"5201","cr":1}]')$q$, CA),
     'HK_LEDGER_FINALIZED_DATE', 'T10 no posting on finalized dates');
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_year SET finalized_through = '2026-06-01' WHERE id = %L$q$, fy),
     'HK_LEDGER_FINALIZE_BACKWARD', 'T10 cut-off moves forward only');
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_year SET finalized_through = '2026-07-05' WHERE id = %L$q$, fy),
     'HK_LEDGER_FINALIZE_GAP', 'T10 cut-off cannot skip temporary journals');
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_year SET last_permanent_no = last_permanent_no + 1 WHERE id = %L$q$, fy),
     'HK_LEDGER_CHAIN_HEAD', 'T10 head counter must match');
  PERFORM expect_error(format($q$UPDATE ledger.journal SET status = 'permanent', permanent_no = 999, daily_no = 1, finalized_at = now(),
     chain_prev_hash = '\x00', chain_hash = '\x00' WHERE id = %L$q$, late), 'HK_LEDGER_PERMANENT_GAP', 'T10 permanent numbers cannot skip');
  PERFORM expect_error(format($q$UPDATE ledger.journal SET status = 'permanent', permanent_no = (SELECT last_permanent_no + 1 FROM ledger.fiscal_year WHERE id = %L),
     daily_no = 1, finalized_at = now(), chain_prev_hash = '\x00', chain_hash = '\x00' WHERE id = %L$q$, fy, late),
     'HK_LEDGER_CHAIN_LINK', 'T10 chain link enforced');
  PERFORM expect_error(format($q$SELECT ledger.void_journal(id, uuidv7(), 995, 'V-p', 'reason') FROM ledger.journal WHERE fiscal_year_id = %L AND permanent_no = 1$q$, fy),
     'HK_LEDGER_VOID_NOT_TEMPORARY', 'T10 a permanent journal cannot be voided');
  -- قطعی کردن مستقیم (بی‌واسطهٔ finalize_through): ترتیب، زنجیره و بُرش — همه در زیرتراکنشی که برمی‌گردد
  DECLARE x ledger.journal; z ledger.journal; fyr ledger.fiscal_year; h bytea; y uuid;
  BEGIN
    PERFORM ledger.void_journal(late, uuidv7(), t_ref(CA, '2026-07-01'), 'V-L', 'آزمون ترتیب');
    x.id := t_post(CA, '2026-07-10', '[{"a":"5101","dr":8},{"a":"5201","cr":8}]');
    y := t_post(CA, '2026-07-05', '[{"a":"5101","dr":9},{"a":"5201","cr":9}]');
    SELECT * INTO fyr FROM ledger.fiscal_year WHERE id = fy;
    SELECT * INTO x FROM ledger.journal WHERE id = x.id;
    x.permanent_no := fyr.last_permanent_no + 1;
    h := sha256(fyr.chain_head_hash || convert_to(ledger.journal_canonical(x), 'UTF8'));
    PERFORM expect_error(format($q$UPDATE ledger.journal SET status = 'permanent', permanent_no = %s, daily_no = 1, finalized_at = now(),
         chain_prev_hash = %L, chain_hash = %L WHERE id = %L$q$, x.permanent_no, fyr.chain_head_hash, h, x.id),
       'HK_LEDGER_PERMANENT_PENDING_EARLIER', 'T10 earlier temporary journals block a later permanent');
    PERFORM ledger.void_journal(y, uuidv7(), t_ref(CA, '2026-07-05'), 'V-Y', 'آزمون ترتیب');
    PERFORM expect_error(format($q$UPDATE ledger.journal SET status = 'permanent', permanent_no = %s, daily_no = 1, finalized_at = now(),
         chain_prev_hash = %L, chain_hash = '\x00' WHERE id = %L$q$, x.permanent_no, fyr.chain_head_hash, x.id),
       'HK_LEDGER_CHAIN_CONTENT', 'T10 chain hash must match canonical content');
    UPDATE ledger.journal SET status = 'permanent', permanent_no = x.permanent_no, daily_no = 1, finalized_at = now(),
           chain_prev_hash = fyr.chain_head_hash, chain_hash = h WHERE id = x.id;
    z.id := t_post(CA, '2026-07-06', '[{"a":"5101","dr":4},{"a":"5201","cr":4}]');
    SELECT * INTO z FROM ledger.journal WHERE id = z.id;
    z.permanent_no := x.permanent_no + 1;
    PERFORM expect_error(format($q$UPDATE ledger.journal SET status = 'permanent', permanent_no = %s, daily_no = 1, finalized_at = now(),
         chain_prev_hash = %L, chain_hash = %L WHERE id = %L$q$, z.permanent_no, h,
         sha256(h || convert_to(ledger.journal_canonical(z), 'UTF8')), z.id),
       'HK_LEDGER_PERMANENT_ORDER', 'T10 permanent numbers follow date order');
    EXECUTE 'SET CONSTRAINTS ALL IMMEDIATE';
    RAISE EXCEPTION 'TEST FAILED: T10 permanent journal outside the cut-off accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM !~ '^HK_LEDGER_PERMANENT_CUTOFF' THEN RAISE EXCEPTION '%', SQLERRM; END IF;
  END;
  PERFORM assert_true((SELECT status FROM ledger.journal WHERE id = late) = 'temporary', 'T10 sub-transaction rolled back');
  -- قفل دورهٔ ۱ پس از قطعی شدن
  UPDATE ledger.fiscal_period SET status = 'locked' WHERE fiscal_year_id = fy AND period_no = 1;
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_period SET status = 'closed' WHERE fiscal_year_id = %L AND period_no = 1$q$, fy),
     'HK_LEDGER_UNLOCK_APPROVAL', 'T10 unlock needs approval reference');
  -- بازبینی پیش از قطعی شدن (پیکربندی)
  UPDATE ledger.company_config SET require_review_before_finalize = true WHERE company_id = CA;
  PERFORM expect_error(format($q$SELECT ledger.finalize_through(%L, '2026-07-01')$q$, fy),
     'HK_LEDGER_NOT_REVIEWED', 'T10 review required before finalization when configured');
  UPDATE ledger.company_config SET require_review_before_finalize = false WHERE company_id = CA;
END $$;

-- ---------- T11: سطل‌های مانده و تراز ----------
DO $$
DECLARE CA uuid := '0a000000-0000-7000-8000-0000000000c1'; fy uuid; p uuid; before_n bigint; n int; tb record; r record;
BEGIN
  PERFORM t_ctx('A');
  fy := t_fy(CA, '1405');
  PERFORM assert_true(NOT EXISTS (SELECT 1 FROM ledger.verify_balance_buckets(CA, fy)), 'T11 buckets equal lines');
  PERFORM assert_true(NOT EXISTS (SELECT 1 FROM ledger.check_trial_balance(CA, fy)), 'T11 trial balance balances');
  SELECT id INTO p FROM ledger.fiscal_period WHERE fiscal_year_id = fy AND period_no = 1;
  SELECT count(*) INTO before_n FROM ledger.balance_bucket WHERE period_id = p;
  n := ledger.compact_balance_buckets(CA, p);
  PERFORM assert_true(n < before_n, format('T11 compaction reduces rows %s -> %s', before_n, n));
  PERFORM assert_true(NOT EXISTS (SELECT 1 FROM ledger.verify_balance_buckets(CA, fy)), 'T11 compaction preserves sums');
  PERFORM ledger.rebuild_balance_buckets(CA, fy);
  PERFORM assert_true(NOT EXISTS (SELECT 1 FROM ledger.verify_balance_buckets(CA, fy)), 'T11 rebuild equals lines');
  PERFORM expect_error($q$DELETE FROM ledger.balance_bucket$q$, 'permission denied', 'T11 buckets not deletable by hk_app');
  -- تراز: جمع بدهکار = جمع بستانکار در هر سطح و با بازهٔ جزئی
  SELECT sum(open_debit) od, sum(open_credit) oc, sum(period_debit) pd, sum(period_credit) pc INTO tb
    FROM ledger.trial_balance(CA, '2026-04-05', '2026-06-15');
  PERFORM assert_true(tb.od = tb.oc AND tb.pd = tb.pc, 'T11 partial-range trial balance balances');
  PERFORM assert_true(tb.pd = (SELECT sum(debit_base) FROM ledger.journal_line WHERE company_id = CA AND journal_date BETWEEN '2026-04-05' AND '2026-06-15'),
                      'T11 period turnover equals lines (hybrid bucket/line path)');
  FOR r IN SELECT lvl FROM generate_series(1, 3) lvl LOOP
    SELECT sum(open_debit + period_debit) d, sum(open_credit + period_credit) c INTO tb
      FROM ledger.trial_balance_rollup(CA, '2026-03-21', '2027-03-20', r.lvl::smallint);
    PERFORM assert_true(tb.d = tb.c, 'T11 trial balance balances at level ' || r.lvl);
  END LOOP;
  PERFORM assert_true((SELECT sum(debit_base) FROM ledger.v_period_balance WHERE company_id = CA) =
                      (SELECT sum(debit_base) FROM ledger.journal_line WHERE company_id = CA), 'T11 v_period_balance equals lines');
END $$;

-- ---------- T12: نگاشت حساب (posting profile) ----------
DO $$
DECLARE CA uuid := '0a000000-0000-7000-8000-0000000000c1'; BA uuid := '0a000000-0000-7000-8000-0000000000b1'; r record;
BEGIN
  PERFORM t_ctx('A');
  SELECT * INTO r FROM ledger.resolve_account(CA, 'sales.revenue', '2026-05-01', '{}');
  PERFORM assert_true(r.account_id = t_acc(CA, '6101'), 'T12 default mapping');
  INSERT INTO ledger.posting_rule (tenant_id, company_id, posting_key, priority, conditions, account_id)
  VALUES (core.current_tenant_id(), CA, 'sales.revenue', 50, jsonb_build_object('branch', BA::text), t_acc(CA, '6102'));
  SELECT * INTO r FROM ledger.resolve_account(CA, 'sales.revenue', '2026-05-01', jsonb_build_object('branch', BA::text));
  PERFORM assert_true(r.account_id = t_acc(CA, '6102'), 'T12 conditional mapping wins');
  SELECT * INTO r FROM ledger.resolve_account(CA, 'sales.revenue', '2026-05-01', '{"branch":"other"}');
  PERFORM assert_true(r.account_id = t_acc(CA, '6101'), 'T12 non-matching condition falls back');
  INSERT INTO ledger.posting_rule (tenant_id, company_id, posting_key, priority, conditions, account_id) VALUES
    (core.current_tenant_id(), CA, 'sales.revenue', 40, '{"attr:channel":"pos"}', t_acc(CA, '6101')),
    (core.current_tenant_id(), CA, 'sales.revenue', 40, '{"attr:category":["shoe","bag"]}', t_acc(CA, '6102'));
  PERFORM expect_error(format($q$SELECT * FROM ledger.resolve_account(%L, 'sales.revenue', '2026-05-01', '{"attr:channel":"pos","attr:category":"shoe"}')$q$, CA),
     'HK_LEDGER_MAPPING_AMBIGUOUS', 'T12 ambiguous mapping is an error');
  SELECT * INTO r FROM ledger.resolve_account(CA, 'sales.revenue', '2026-05-01', '{"attr:category":"bag"}');
  PERFORM assert_true(r.account_id = t_acc(CA, '6102'), 'T12 list condition');
END $$;

DO $$
DECLARE CA uuid := '0a000000-0000-7000-8000-0000000000c1';
BEGIN
  PERFORM t_ctx('A');
  DELETE FROM ledger.posting_rule WHERE company_id = CA AND posting_key = 'ledger.suspense';
  PERFORM expect_error(format($q$SELECT * FROM ledger.resolve_account(%L, 'ledger.suspense', '2026-05-01', '{}')$q$, CA),
     'HK_LEDGER_MAPPING_MISSING', 'T12 missing mapping is an error (no silent default)');
  PERFORM expect_error(format($q$INSERT INTO ledger.posting_rule (tenant_id, company_id, posting_key, priority, conditions, account_id)
     VALUES (core.current_tenant_id(), %L, 'sales.revenue', 100, '{}', %L)$q$, CA, t_acc(CA, '6102')),
     'conflicting key|exclusion', 'T12 duplicate rule with overlapping validity rejected');
  PERFORM expect_error(format($q$INSERT INTO ledger.posting_rule (tenant_id, company_id, posting_key, priority, account_id)
     VALUES (core.current_tenant_id(), %L, 'sales.revenue', 7, %L)$q$, CA, t_acc(CA, '1101')),
     'HK_LEDGER_MAPPING_ACCOUNT_TYPE', 'T12 mapped account type must match the key');
  PERFORM expect_error(format($q$INSERT INTO ledger.posting_rule (tenant_id, company_id, posting_key, priority, conditions, account_id)
     VALUES (core.current_tenant_id(), %L, 'sales.revenue', 8, '{"Bad Key":"x"}', %L)$q$, CA, t_acc(CA, '6101')),
     'check constraint', 'T12 condition keys validated');
  PERFORM expect_error(format($q$INSERT INTO ledger.posting_rule (tenant_id, company_id, posting_key, priority, account_id)
     VALUES (core.current_tenant_id(), %L, 'sales.revenue', 9, %L)$q$, CA, t_acc(CA, '61')),
     'HK_LEDGER_ACCOUNT_NOT_POSTABLE', 'T12 mapping targets posting accounts');
END $$;

-- ---------- T13: نرخ ارز ----------
DO $$
DECLARE rt uuid; r record;
BEGIN
  PERFORM t_ctx('A');
  SELECT id INTO rt FROM ledger.rate_type WHERE code = 'official';
  INSERT INTO ledger.exchange_rate (tenant_id, rate_type_id, currency, base_currency, rate_date, rate) VALUES
    (core.current_tenant_id(), rt, 'USD', 'IRR', '2026-05-01', 500000), (core.current_tenant_id(), rt, 'USD', 'IRR', '2026-05-10', 520000);
  SELECT * INTO r FROM ledger.rate_on(rt, 'USD', 'IRR', '2026-05-09');
  PERFORM assert_true(r.rate = 500000 AND r.rate_date = '2026-05-01', 'T13 latest rate on or before date');
  PERFORM assert_true((SELECT rate FROM ledger.rate_on(rt, 'IRR', 'IRR', '2026-05-09')) = 1, 'T13 same currency rate is 1');
  PERFORM expect_error(format($q$INSERT INTO ledger.exchange_rate (tenant_id, rate_type_id, currency, base_currency, rate_date, rate)
     VALUES (core.current_tenant_id(), %L, 'EUR', 'IRR', '2026-05-01', 0)$q$, rt), 'check constraint', 'T13 rate must be positive');
  PERFORM expect_error(format($q$INSERT INTO ledger.exchange_rate (tenant_id, rate_type_id, currency, base_currency, rate_date, rate)
     VALUES (core.current_tenant_id(), %L, 'USD', 'IRR', '2026-05-01', 1)$q$, rt), 'duplicate key', 'T13 one rate per type, pair and date');
  PERFORM assert_true(ledger.round_amount(2.5, 0::smallint, 'half_even') = 2 AND ledger.round_amount(3.5, 0::smallint, 'half_even') = 4
                      AND ledger.round_amount(2.5, 0::smallint, 'half_up') = 3 AND ledger.round_amount(-2.5, 0::smallint, 'half_up') = -3
                      AND ledger.round_amount(2.99, 0::smallint, 'truncate') = 2, 'T13 rounding modes');
END $$;

-- ---------- T14: تطبیق حساب کنترلی با زیردفتر ----------
DO $$
DECLARE CA uuid := '0a000000-0000-7000-8000-0000000000c1';
BEGIN
  PERFORM t_ctx('A');
  INSERT INTO public.t_party_items (tenant_id, company_id, account_id, party_dim, amount)
  SELECT core.current_tenant_id(), CA, l.account_id, l.dim1_id, sum(l.debit_base - l.credit_base)
    FROM ledger.journal_line l JOIN ledger.account a ON a.id = l.account_id
   WHERE l.company_id = CA AND a.subledger_kind = 'party' GROUP BY l.account_id, l.dim1_id;
  PERFORM assert_true(NOT EXISTS (SELECT 1 FROM ledger.check_control_accounts(CA, '2027-03-20')), 'T14 GL equals subledger');
  UPDATE public.t_party_items SET amount = amount + 1 WHERE party_dim = t_dim('party','P1');
  PERFORM assert_true((SELECT count(*) FROM ledger.check_control_accounts(CA, '2027-03-20')) = 1, 'T14 difference detected');
  UPDATE public.t_party_items SET amount = amount - 1 WHERE party_dim = t_dim('party','P1');
  -- ادغام شخص: سطرهای قدیم دست نمی‌خورند؛ تطبیق به مقصد ادغام نسبت می‌دهد
  INSERT INTO ledger.dimension_value (tenant_id, dimension_type_id, code, name, source_module, source_entity_id)
  SELECT core.current_tenant_id(), id, 'P3', 'مشتری تکراری', 'parties', uuidv7() FROM ledger.dimension_type WHERE code = 'party';
  PERFORM t_post(CA, '2026-07-15', jsonb_build_array(jsonb_build_object('a','1201','dr',123,'d1',t_dim('party','P3')),
                 jsonb_build_object('a','6101','cr',123)), 'module', 'sales', uuidv7());
  PERFORM expect_error(format($q$UPDATE ledger.dimension_value SET merged_into_id = %L WHERE code = 'P3'$q$, t_dim('party','P1')),
     'check constraint', 'T14 a merged value must be inactive');
  PERFORM expect_error(format($q$UPDATE ledger.dimension_value SET merged_into_id = %L, is_active = false WHERE code = 'P3'$q$, t_dim('cash_box','CB1')),
     'HK_LEDGER_DIM_MERGE', 'T14 merge target must be the same type');
  UPDATE ledger.dimension_value SET merged_into_id = t_dim('party','P1'), is_active = false WHERE code = 'P3';
  UPDATE public.t_party_items SET amount = amount + 123 WHERE party_dim = t_dim('party','P1');
  PERFORM assert_true(NOT EXISTS (SELECT 1 FROM ledger.check_control_accounts(CA, '2027-03-20')), 'T14 merged dimension resolved to survivor');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-07-16', '[{"a":"1201","dr":1,"d1":"%s"},{"a":"6101","cr":1}]', 'module', 'sales')$q$,
     CA, t_dim('party','P3')), 'HK_LEDGER_DIM_NOT_POSTABLE', 'T14 merged value is not postable');
  PERFORM expect_error($q$UPDATE ledger.dimension_value SET merged_into_id = NULL, is_active = true WHERE code = 'P3'$q$,
     'HK_LEDGER_DIM_MERGE', 'T14 merges cannot be undone');
END $$;

-- ---------- T15: چرخهٔ بستن سال (شرکت CA2) ----------
DO $$
DECLARE CA2 uuid := '0a000000-0000-7000-8000-0000000000c2'; fy uuid; cb text;
BEGIN
  PERFORM t_ctx('A');
  fy := t_fy(CA2, '1405');
  cb := t_dim('cash_box','CB1')::text;
  PERFORM t_post(CA2, '2026-03-21', jsonb_build_array(jsonb_build_object('a','1101','dr',1000000,'d1',cb), jsonb_build_object('a','5101','cr',1000000)),
                 'opening_import', p_unit => 'IRR');
  UPDATE ledger.fiscal_year SET opening_state = 'posted' WHERE id = fy;
  PERFORM t_post(CA2, '2026-05-01', jsonb_build_array(jsonb_build_object('a','1101','dr',500000,'d1',cb), jsonb_build_object('a','6101','cr',500000)),
                 'module', 'sales', uuidv7());
  PERFORM t_post(CA2, '2026-08-01', jsonb_build_array(jsonb_build_object('a','7202','dr',200000), jsonb_build_object('a','1101','cr',200000,'d1',cb)));
  PERFORM expect_error(format($q$SELECT t_post(%L, '2027-03-20', '[{"a":"6101","dr":1},{"a":"5303","cr":1}]', 'closing_pl')$q$, CA2),
     'HK_LEDGER_CLOSING_STATE', 'T15 closing journals only while closing');
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_year SET status = 'closing' WHERE id = %L$q$, fy),
     'HK_LEDGER_FY_PERIODS_OPEN', 'T15 closing requires all periods closed');
  PERFORM t_make_year(CA2, '1406', '2027-03-21', fy);
END $$;

DO $$
DECLARE CA2 uuid := '0a000000-0000-7000-8000-0000000000c2'; fy uuid;
BEGIN
  PERFORM t_ctx('A');
  fy := t_fy(CA2, '1405');
  UPDATE ledger.fiscal_period SET status = 'closed' WHERE id IN (SELECT id FROM ledger.fiscal_period WHERE fiscal_year_id = fy ORDER BY period_no LIMIT 1);
  FOR i IN 2..12 LOOP
    UPDATE ledger.fiscal_period SET status = 'closed' WHERE fiscal_year_id = fy AND period_no = i;
  END LOOP;
  UPDATE ledger.fiscal_year SET status = 'closing' WHERE id = fy;
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-09-01', '[{"a":"5101","dr":1},{"a":"5201","cr":1}]')$q$, CA2),
     'HK_LEDGER_YEAR_NOT_OPEN|HK_LEDGER_PERIOD_CLOSED', 'T15 no regular posting while closing');
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_year SET status = 'closed' WHERE id = %L$q$, fy),
     'HK_LEDGER_FY_NO_OPENING', 'T15 closed requires the next opening');
END $$;

DO $$
DECLARE CA2 uuid := '0a000000-0000-7000-8000-0000000000c2'; fy uuid; fy2 uuid; cb text; s record;
BEGIN
  PERFORM t_ctx('A');
  fy := t_fy(CA2, '1405'); fy2 := t_fy(CA2, '1406');
  cb := t_dim('cash_box','CB1')::text;
  PERFORM t_post(CA2, '2027-03-20', '[{"a":"6101","dr":500000},{"a":"7202","cr":200000},{"a":"5303","cr":300000}]', 'closing_pl');
  PERFORM t_post(CA2, '2027-03-20', '[{"a":"5303","dr":300000},{"a":"5301","cr":300000}]', 'closing_re');
  PERFORM t_post(CA2, '2027-03-20', jsonb_build_array(jsonb_build_object('a','5101','dr',1000000), jsonb_build_object('a','5301','dr',300000),
                 jsonb_build_object('a','1101','cr',1300000,'d1',cb)), 'closing_balance');
  PERFORM t_post(CA2, '2027-03-21', jsonb_build_array(jsonb_build_object('a','1101','dr',1300000,'d1',cb), jsonb_build_object('a','5101','cr',1000000),
                 jsonb_build_object('a','5301','cr',300000)), 'opening');
  UPDATE ledger.fiscal_year SET opening_state = 'posted' WHERE id = fy2;
  UPDATE ledger.fiscal_year SET status = 'closed' WHERE id = fy;
  PERFORM assert_true(NOT EXISTS (SELECT 1 FROM ledger.check_year_close(fy)), 'T15 year close verified');
  -- صورت‌های مالی سال بسته‌شده (بدون اسناد بستن)
  PERFORM assert_true((SELECT value FROM ledger.evaluate_statement(CA2, 'ir.bs', 1, '2026-03-21', '2027-03-20') WHERE row_code = 'BS_CHECK') = 0,
                      'T15 balance sheet balances');
  PERFORM assert_true((SELECT value FROM ledger.evaluate_statement(CA2, 'ir.bs', 1, '2026-03-21', '2027-03-20') WHERE row_code = 'ASSETS_TOTAL') = 1300000,
                      'T15 total assets');
  PERFORM assert_true((SELECT value FROM ledger.evaluate_statement(CA2, 'ir.pl', 1, '2026-03-21', '2027-03-20') WHERE row_code = 'NET') = 300000,
                      'T15 net profit');
  PERFORM assert_true((SELECT value FROM ledger.evaluate_statement(CA2, 'ir.pl', 1, '2026-03-21', '2027-03-20') WHERE row_code = 'PL_CHECK') = 0,
                      'T15 P&L rows cover all temporary accounts');
  PERFORM assert_true((SELECT value FROM ledger.evaluate_statement(CA2, 'ir.cf', 1, '2026-03-21', '2027-03-20') WHERE row_code = 'CF_CHECK') = 0,
                      'T15 cash flow reconciles to cash');
  PERFORM assert_true((SELECT value FROM ledger.evaluate_statement(CA2, 'ir.bs', 1, '2026-03-21', '2027-03-20', true) WHERE row_code = 'ASSETS_TOTAL') = 0,
                      'T15 after closing entries all balances are zero');
  PERFORM assert_true(NOT EXISTS (SELECT 1 FROM ledger.report_coverage(CA2, ARRAY['ir.bs','ir.pl'], ARRAY[1,1])), 'T15 every leaf account maps to one row');
  -- بازگشایی: تا اسناد بستن باطل نشده‌اند ممکن نیست
  UPDATE ledger.fiscal_year SET status = 'closing' WHERE id = fy;
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_year SET status = 'open' WHERE id = %L$q$, fy),
     'HK_LEDGER_FY_CLOSING_JOURNALS', 'T15 reopen requires voiding closing journals');
  UPDATE ledger.fiscal_year SET status = 'closed' WHERE id = fy;
  -- قطعی کردن کل سال: اسناد بستن آخرین شماره‌ها
  PERFORM ledger.finalize_through(fy, '2027-03-20');
  SELECT max(permanent_no) FILTER (WHERE entry_class = 'closing') mc, min(permanent_no) FILTER (WHERE entry_class = 'closing') minc,
         max(permanent_no) FILTER (WHERE entry_class <> 'closing') mr, min(permanent_no) FILTER (WHERE entry_class = 'opening') mo INTO s
    FROM ledger.journal WHERE fiscal_year_id = fy;
  PERFORM assert_true(s.mo = 1 AND s.minc > s.mr, 'T15 opening first, closing last in permanent order');
  PERFORM assert_true(NOT EXISTS (SELECT 1 FROM ledger.verify_permanent_chain(fy)), 'T15 chain verifies after year finalization');
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_year SET status = 'closing' WHERE id = %L$q$, fy),
     'HK_LEDGER_FY_FINALIZED', 'T15 finalized year cannot be reopened');
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_year SET status = 'locked' WHERE id = %L$q$, fy),
     'HK_LEDGER_FY_LOCK', 'T15 lock requires all periods locked');
  UPDATE ledger.fiscal_period SET status = 'locked' WHERE fiscal_year_id = fy;
  UPDATE ledger.fiscal_year SET status = 'locked' WHERE id = fy;
  -- سال بعد: افتتاحیه شمارهٔ ۱
  PERFORM ledger.finalize_through(fy2, '2027-03-21');
  PERFORM assert_true((SELECT journal_type FROM ledger.journal WHERE fiscal_year_id = fy2 AND permanent_no = 1) = 'opening', 'T15 opening is #1 of next year');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2027-03-21', '[{"a":"5101","dr":1},{"a":"5201","cr":1}]', 'opening_import', p_unit => 'IRR')$q$,
     CA2), 'HK_LEDGER_FINALIZED_DATE|HK_LEDGER_OPENING_STATE', 'T15 no second opening after finalization');
END $$;

-- ---------- T16: پوشش قالب گزارش برای شرکت CA و تراز سال ----------
DO $$
DECLARE CA uuid := '0a000000-0000-7000-8000-0000000000c1';
BEGIN
  PERFORM t_ctx('A');
  PERFORM assert_true(NOT EXISTS (SELECT 1 FROM ledger.report_coverage(CA, ARRAY['ir.bs','ir.pl'], ARRAY[1,1]) WHERE code <> '1190'),
                      'T16 template coverage on a template-based COA');
  PERFORM assert_true((SELECT value FROM ledger.evaluate_statement(CA, 'ir.bs', 1, '2026-03-21', '2027-03-20') WHERE row_code = 'BS_CHECK') = 0,
                      'T16 balance sheet balances with FX, memo and control accounts');
  PERFORM assert_true((SELECT value FROM ledger.evaluate_statement(CA, 'ir.cf', 1, '2026-03-21', '2027-03-20') WHERE row_code = 'CF_CHECK') = 0,
                      'T16 cash flow reconciles');
END $$;

-- ---------- T17: مستأجر B — جداسازی کامل ----------
DO $$
DECLARE CB uuid := '0b000000-0000-7000-8000-0000000000c1'; fy uuid; j uuid; ja uuid; acc_a uuid;
BEGIN
  PERFORM t_ctx('A');
  SELECT id INTO ja FROM ledger.journal WHERE status = 'temporary' LIMIT 1;
  acc_a := t_acc('0a000000-0000-7000-8000-0000000000c1', '5101');
  PERFORM t_ctx('B');
  PERFORM ledger.provision_tenant();
  PERFORM ledger.apply_coa_template(CB, 'ir.general', 1);
  fy := t_make_year(CB, '1405', '2026-03-21', NULL);
  j := t_post(CB, '2026-04-01', '[{"a":"5101","dr":5},{"a":"5201","cr":5}]');
  PERFORM assert_true((SELECT count(*) FROM ledger.journal) = 1, 'T17 tenant B sees only its journal');
  PERFORM assert_true(NOT EXISTS (SELECT 1 FROM ledger.dimension_value WHERE code = 'P1'), 'T17 tenant B sees no A dimension values');
  PERFORM assert_true((SELECT sum(period_debit) FROM ledger.trial_balance(CB, '2026-03-21', '2027-03-20')) = 5, 'T17 B trial balance only B');
  -- افتتاحیهٔ چندتکه با حساب تراز افتتاحیه (ورود از دفتر کل و از ماژول زیردفتر)
  PERFORM t_post(CB, '2026-03-21', '[{"a":"5201","dr":700},{"a":"1304","cr":700}]', 'opening_import', p_unit => 'IRT');
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_year SET opening_state = 'posted' WHERE id = %L$q$, fy),
     'HK_LEDGER_OPENING_CLEARING', 'T17 opening incomplete while clearing account is not zero');
  PERFORM t_post(CB, '2026-03-21', '[{"a":"1304","dr":700},{"a":"1401","cr":700}]', 'opening_import', 'inventory', uuidv7(), p_unit => 'IRR');
  UPDATE ledger.fiscal_year SET opening_state = 'posted' WHERE id = fy;
  PERFORM assert_true((SELECT sum(open_debit) FROM ledger.trial_balance(CB, '2026-03-21', '2027-03-20')) = 1400, 'T17 opening column holds opening entries');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2026-03-21', '[{"a":"1304","dr":1},{"a":"5101","cr":1}]', 'opening_import', p_unit => 'IRR')$q$, CB),
     'HK_LEDGER_OPENING_STATE', 'T17 no opening import after the opening is posted');
  PERFORM expect_error(format($q$INSERT INTO ledger.journal_line (tenant_id, journal_id, line_no, account_id, currency, exchange_rate, debit_txn, debit_base)
     VALUES (core.current_tenant_id(), %L, 1, %L, 'IRR', 1, 1, 1)$q$, ja, t_acc(CB, '5101')),
     'HK_LEDGER_JOURNAL_NOT_FOUND', 'T17 a B line cannot target an A journal');
  PERFORM expect_error(format($q$INSERT INTO ledger.journal_line (tenant_id, journal_id, line_no, account_id, currency, exchange_rate, debit_txn, debit_base)
     VALUES ('0a000000-0000-7000-8000-000000000001', %L, 1, %L, 'IRR', 1, 1, 1)$q$, ja, acc_a),
     'row-level security|HK_LEDGER_JOURNAL_NOT_FOUND', 'T17 B cannot write A rows');
  PERFORM expect_error(format($q$SELECT ledger.finalize_through(%L, '2026-04-01')$q$, t_fy('0a000000-0000-7000-8000-0000000000c1', '1405')),
     'HK_LEDGER_NO_FISCAL_YEAR', 'T17 B cannot finalize A year');
  -- تعویض مستأجر وسط تراکنش: بررسی‌های deferred صریحاً شکست می‌خورند (fail-safe)
  BEGIN
    PERFORM t_post(CB, '2026-04-02', '[{"a":"5101","dr":5},{"a":"5201","cr":5}]');
    PERFORM t_ctx('A');
    EXECUTE 'SET CONSTRAINTS ALL IMMEDIATE';
    RAISE EXCEPTION 'TEST FAILED: T17 tenant switch inside a transaction was not detected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM !~ '^HK_LEDGER_TENANT_CONTEXT' THEN
      RAISE EXCEPTION 'TEST FAILED: T17 switching tenant inside a transaction is rejected — got: %', SQLERRM;
    END IF;
  END;
  PERFORM assert_true(core.current_tenant_id() = '0b000000-0000-7000-8000-000000000001', 'T17 context restored after rollback');
END $$;

DO $$
DECLARE CB uuid := '0b000000-0000-7000-8000-0000000000c1';
BEGIN
  PERFORM t_ctx('A');
  PERFORM assert_true(NOT EXISTS (SELECT 1 FROM ledger.journal WHERE company_id = CB), 'T17 A cannot see B journal');
  PERFORM assert_true(NOT EXISTS (SELECT 1 FROM ledger.balance_bucket WHERE company_id = CB), 'T17 A cannot see B buckets');
  PERFORM assert_true(NOT EXISTS (SELECT 1 FROM ledger.account WHERE company_id = CB), 'T17 A cannot see B accounts');
END $$;

-- ---------- T20: شکاف‌های آزمون جهش (هر بررسی تریگر/تابع با خطای دقیق خودش) ----------
-- هر expect_error الگوی کد و پیام دقیق را می‌خواهد تا لایهٔ دفاعی دیگری که همان نقض را می‌گیرد آزمون را «سبز» نکند.
-- CA3: کدینگ ir.general، سال ۱۴۰۵ (و ۱۴۰۶)؛ CA4: بدون حساب و سال.
DO $$
DECLARE CA3 uuid := '0a000000-0000-7000-8000-0000000000c3';
BEGIN
  PERFORM t_ctx('A');
  PERFORM ledger.apply_coa_template(CA3, 'ir.general', 1);
  PERFORM t_make_year(CA3, '1405', '2026-03-21', NULL);
  PERFORM t_post(CA3, '2026-04-01', '[{"a":"5101","dr":10},{"a":"5201","cr":10}]');
END $$;

DO $$
DECLARE CA3 uuid := '0a000000-0000-7000-8000-0000000000c3'; fy uuid; j1 uuid; j2 uuid; j3 uuid; j4 uuid;
        x ledger.journal; fyr ledger.fiscal_year; h bytea;
BEGIN
  PERFORM t_ctx('A');
  fy := t_fy(CA3, '1405');
  SELECT id INTO j1 FROM ledger.journal WHERE company_id = CA3 AND journal_date = '2026-04-01';
  -- کدینگ
  PERFORM expect_error(format($q$UPDATE ledger.account SET level = 2 WHERE company_id = %L AND code = '1'$q$, CA3),
     '^HK_LEDGER_ACCOUNT_IMMUTABLE', 'T20 account level is immutable');
  PERFORM expect_error(format($q$UPDATE ledger.account SET account_type = 'expense' WHERE company_id = %L AND code = '5101'$q$, CA3),
     '^HK_LEDGER_ACCOUNT_TYPE_LOCKED', 'T20 account type locked after postings');
  PERFORM expect_error(format($q$UPDATE ledger.account SET kind = 'group' WHERE company_id = %L AND code = '5101'$q$, CA3),
     '^HK_LEDGER_ACCOUNT_HAS_POSTINGS', 'T20 account with postings cannot become a group');
  PERFORM expect_error(format($q$UPDATE ledger.account SET kind = 'posting' WHERE company_id = %L AND code = '51'$q$, CA3),
     '^HK_LEDGER_ACCOUNT_HAS_CHILDREN', 'T20 group with children cannot become a posting account');
  -- سال با افتتاحیهٔ معلق
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_year SET finalized_through = '2026-03-21' WHERE id = %L$q$, fy),
     '^HK_LEDGER_OPENING_PENDING', 'T20 cut-off cannot move while the opening is pending');
  PERFORM expect_error(format($q$UPDATE ledger.journal SET status = 'permanent', permanent_no = 1, daily_no = 1, finalized_at = now(),
     chain_prev_hash = '\x00', chain_hash = '\x00' WHERE id = %L$q$, j1),
     '^HK_LEDGER_OPENING_PENDING', 'T20 a journal cannot become permanent while the opening is pending');
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_year SET opening_state = 'posted' WHERE id = %L$q$, fy),
     '^HK_LEDGER_FY_NO_OPENING', 'T20 opening posted requires an opening journal');
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_year SET status = 'locked' WHERE id = %L$q$, fy),
     '^HK_LEDGER_FY_TRANSITION', 'T20 open -> locked is not a year transition');
  UPDATE ledger.fiscal_year SET opening_state = 'not_required' WHERE id = fy;
  -- گذار مستقیم به دائم
  PERFORM expect_error(format($q$UPDATE ledger.journal SET status = 'permanent' WHERE id = %L$q$, j1),
     '^HK_LEDGER_BAD_TRANSITION', 'T20 permanent needs number and finalization time');
  PERFORM expect_error(format($q$UPDATE ledger.journal SET status = 'permanent', permanent_no = 1, daily_no = 1, finalized_at = now(),
     chain_prev_hash = '\x00', chain_hash = '\x00' WHERE id = %L$q$, j1),
     '^HK_LEDGER_CHAIN_LINK', 'T20 first permanent journal links to genesis');
  PERFORM expect_error(format($q$UPDATE ledger.journal SET status = 'permanent', permanent_no = 1, daily_no = 2, finalized_at = now(),
     chain_prev_hash = ledger.chain_genesis(%L, %L), chain_hash = '\x00' WHERE id = %L$q$, CA3, fy, j1),
     '^HK_LEDGER_CHAIN_LINK', 'T20 first permanent journal has daily number 1');
  PERFORM assert_true(ledger.finalize_through(fy, '2026-04-01') = 1, 'T20 finalize first journal');
  PERFORM expect_error(format($q$SELECT ledger.finalize_through(%L, '2030-01-01')$q$, fy),
     '^HK_LEDGER_FINALIZE_RANGE', 'T20 cut-off must lie inside the year');
  PERFORM expect_error(format($q$UPDATE ledger.journal SET reviewed_at = now(), reviewed_by = core.current_user_id() WHERE id = %L$q$, j1),
     '^HK_IMMUTABLE: a permanent journal cannot change', 'T20 a permanent journal cannot even be marked reviewed');
  PERFORM expect_error(format($q$INSERT INTO ledger.journal_line (tenant_id, journal_id, line_no, account_id, currency, exchange_rate, debit_txn, debit_base)
     VALUES (core.current_tenant_id(), %L, 1, %L, 'IRR', 1, 1, 1)$q$, j1, t_acc(CA3, '5101')),
     '^HK_IMMUTABLE: lines cannot be added', 'T20 no lines on a permanent journal');
  -- شمارهٔ روزانه و وضعیت ناشناخته
  j2 := t_post(CA3, '2026-04-02', '[{"a":"5101","dr":2},{"a":"5201","cr":2}]');
  SELECT * INTO fyr FROM ledger.fiscal_year WHERE id = fy;
  SELECT * INTO x FROM ledger.journal WHERE id = j2;
  x.permanent_no := 2;
  h := sha256(fyr.chain_head_hash || convert_to(ledger.journal_canonical(x), 'UTF8'));
  PERFORM expect_error(format($q$UPDATE ledger.journal SET status = 'permanent', permanent_no = 2, daily_no = 2, finalized_at = now(),
     chain_prev_hash = %L, chain_hash = %L WHERE id = %L$q$, fyr.chain_head_hash, h, j2),
     '^HK_LEDGER_DAILY_NO', 'T20 daily number restarts on a new date');
  PERFORM expect_error(format($q$UPDATE ledger.journal SET status = 'archived' WHERE id = %L$q$, j2),
     '^HK_LEDGER_BAD_TRANSITION: journal transition', 'T20 unknown journal status rejected by the state machine');
  -- عملیات روی سند ناموجود یا تاریخ بیرون از سال
  PERFORM expect_error($q$SELECT ledger.void_journal(uuidv7(), uuidv7(), 9001, 'V-x', 'reason')$q$,
     '^HK_LEDGER_JOURNAL_NOT_FOUND', 'T20 void of a missing journal');
  PERFORM expect_error($q$SELECT ledger.reverse_journal(uuidv7(), uuidv7(), '2026-05-01', 9002, 'R-x')$q$,
     '^HK_LEDGER_JOURNAL_NOT_FOUND', 'T20 reversal of a missing journal');
  PERFORM expect_error(format($q$SELECT ledger.reverse_journal(%L, uuidv7(), '2031-01-01', 9003, 'R-y')$q$, j2),
     '^HK_LEDGER_NO_FISCAL_YEAR: no fiscal year contains', 'T20 reversal date must be inside a fiscal year');
  -- ابطال
  j3 := t_post(CA3, '2026-05-01', '[{"a":"5101","dr":3},{"a":"5201","cr":3}]');
  PERFORM expect_error(format($q$SELECT ledger.void_journal(%L, uuidv7(), t_ref(%L, '2026-05-01'), 'V-3', 'ab')$q$, j3, CA3),
     '^HK_LEDGER_REASON_REQUIRED', 'T20 void reason has at least three characters');
  PERFORM ledger.void_journal(j3, uuidv7(), t_ref(CA3, '2026-05-01'), 'V-3', 'آزمون ابطال');
  PERFORM expect_error(format($q$UPDATE ledger.journal SET void_reason = 'دلیل دیگر' WHERE id = %L$q$, j3),
     '^HK_IMMUTABLE: a voided journal cannot change', 'T20 a voided journal is final');
  -- بررسی‌های درج سرسند، هرکدام جدا
  j4 := t_post(CA3, '2026-05-01', '[{"a":"5101","dr":4},{"a":"5201","cr":4}]');
  PERFORM expect_error(format($q$SELECT t_raw(%L, '2026-05-01', '{"journal_type":"no_such_type"}')$q$, CA3),
     '^HK_LEDGER_JOURNAL_TYPE', 'T20 unknown journal type');
  PERFORM expect_error(format($q$SELECT t_raw(%L, '2026-05-01', '{"permanent_no":1}')$q$, CA3),
     '^HK_LEDGER_JOURNAL_INSERT: permanent/review fields', 'T20 permanent fields cannot be set on insert');
  PERFORM expect_error(format($q$SELECT t_raw(%L, '2026-05-01', '{"status":"voided","void_reason":"xyz"}')$q$, CA3),
     '^HK_LEDGER_JOURNAL_INSERT: a journal is inserted as temporary', 'T20 a regular journal is inserted as temporary');
  PERFORM expect_error(format($q$SELECT t_raw(%L, '2026-05-01', jsonb_build_object('period_id', (SELECT id FROM ledger.fiscal_period WHERE fiscal_year_id = %L AND period_no = 1)))$q$, CA3, fy),
     '^HK_LEDGER_NO_PERIOD', 'T20 explicit period must contain the journal date');
  PERFORM expect_error(format($q$SELECT t_raw(%L, '2026-05-01', '{"base_currency":"USD"}')$q$, CA3),
     '^HK_LEDGER_BASE_CURRENCY', 'T20 journal base currency equals the year base currency');
  PERFORM expect_error(format($q$SELECT t_raw(%L, '2026-05-01', '{"journal_type":"fx_revaluation","source_module":"sales"}')$q$, CA3),
     '^HK_LEDGER_SOURCE_MODULE: system journal types', 'T20 system journal types belong to the ledger');
  PERFORM expect_error(format($q$SELECT t_raw(%L, '2026-05-02', jsonb_build_object('journal_type','void','status','voided','void_of_journal_id',%L::uuid,'void_reason','xyz'))$q$, CA3, j4),
     '^HK_LEDGER_VOID_PAIR: a void journal mirrors its original', 'T20 void journal has the date of its original');
  PERFORM expect_error(format($q$SELECT t_raw(%L, '2026-05-03', jsonb_build_object('journal_type','fx_revaluation_reversal','reversal_of_journal_id',%L::uuid))$q$, CA3, j4),
     '^HK_LEDGER_REVERSAL_TYPE', 'T20 fx_revaluation_reversal only reverses an fx revaluation');
  -- وضعیت افتتاحیه
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_year SET opening_state = 'posted' WHERE id = %L$q$, fy),
     '^HK_LEDGER_FY_OPENING_STATE: invalid opening_state transition', 'T20 not_required -> posted is not allowed');
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_year SET opening_state = 'pending' WHERE id = %L$q$, fy),
     '^HK_LEDGER_FY_OPENING_STATE: opening can be reset only', 'T20 opening cannot be reset after finalization');
  -- گزارش و توابع کمکی
  PERFORM expect_error(format($q$SELECT * FROM ledger.trial_balance(%L, '2026-05-01', '2026-04-01')$q$, CA3),
     '^HK_LEDGER_REPORT_RANGE', 'T20 report range must be ordered and inside one year');
  PERFORM expect_error(format($q$SELECT * FROM ledger.check_control_accounts(%L, '2035-01-01')$q$, CA3),
     '^HK_LEDGER_NO_FISCAL_YEAR', 'T20 control check date must be inside a year');
  PERFORM expect_error(format($q$SELECT * FROM ledger.evaluate_statement(%L, 'test.badformula', 1, '2026-03-21', '2026-04-30')$q$, CA3),
     '^HK_LEDGER_TEMPLATE_FORMULA', 'T20 formula may reference only earlier rows');
  PERFORM expect_error($q$SELECT ledger.round_amount(1.5, 0::smallint, 'bogus')$q$,
     '^HK_LEDGER_ROUNDING_MODE', 'T20 unknown rounding mode');
  -- دورهٔ تماماً قطعی‌شده بازگشایی نمی‌شود
  PERFORM ledger.finalize_through(fy, '2026-04-20');
  UPDATE ledger.fiscal_period SET status = 'closed' WHERE fiscal_year_id = fy AND period_no = 1;
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_period SET status = 'open', status_reason = 'بازگشایی آزمون' WHERE fiscal_year_id = %L AND period_no = 1$q$, fy),
     '^HK_LEDGER_PERIOD_FINALIZED', 'T20 a fully finalized period cannot be reopened');
END $$;

DO $$
DECLARE CA3 uuid := '0a000000-0000-7000-8000-0000000000c3'; CA4 uuid := '0a000000-0000-7000-8000-0000000000c4';
        fy uuid; fy4 uuid; cpl uuid; i integer;
BEGIN
  PERFORM t_ctx('A');
  fy := t_fy(CA3, '1405');
  fy4 := t_make_year(CA3, '1406', '2027-03-21', fy);
  PERFORM expect_error(format($q$INSERT INTO ledger.fiscal_year (tenant_id, company_id, code, name, start_date, end_date, base_currency, previous_year_id, opening_state)
     SELECT core.current_tenant_id(), %L, '1407', 'x', f.end_date + 1, f.end_date + 365, 'IRR', f.id, 'not_required'
       FROM ledger.fiscal_year f WHERE f.id = %L$q$, CA3, fy4),
     '^HK_LEDGER_FY_INSERT: opening of a non-first year', 'T20 a non-first year starts with a pending opening');
  PERFORM expect_error(format($q$INSERT INTO ledger.fiscal_year (tenant_id, company_id, code, name, start_date, end_date, base_currency, status)
     VALUES (core.current_tenant_id(), %L, '1405', 'x', '2026-03-21', '2027-03-20', 'IRR', 'closed')$q$, CA4),
     '^HK_LEDGER_FY_INSERT: a new fiscal year starts open', 'T20 a new year starts open');
  PERFORM expect_error(format($q$INSERT INTO ledger.fiscal_period (tenant_id, company_id, fiscal_year_id, period_no, name, start_date, end_date, status)
     VALUES (core.current_tenant_id(), %L, %L, 13, 'x', '2027-03-21', '2027-03-25', 'closed')$q$, CA3, fy4),
     '^HK_LEDGER_PERIOD_INSERT', 'T20 a new period starts open');
  PERFORM expect_error(format($q$SELECT t_post(%L, '2027-03-21', '[{"a":"5101","dr":1},{"a":"5201","cr":1}]', 'opening')$q$, CA3),
     '^HK_LEDGER_OPENING_STATE: a year-close opening journal requires', 'T20 year-close opening needs the previous year closing');
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_year SET opening_state = 'not_required' WHERE id = %L$q$, fy4),
     '^HK_LEDGER_FY_OPENING_STATE: only the first fiscal year', 'T20 only the first year may skip the opening');
  -- بستن سال ۱۴۰۵ شرکت CA3 و بازگشایی‌های نامعتبر
  FOR i IN 2..12 LOOP
    UPDATE ledger.fiscal_period SET status = 'closed' WHERE fiscal_year_id = fy AND period_no = i;
  END LOOP;
  UPDATE ledger.fiscal_year SET status = 'closing' WHERE id = fy;
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_period SET status = 'open', status_reason = 'بازگشایی آزمون' WHERE fiscal_year_id = %L AND period_no = 12$q$, fy),
     '^HK_LEDGER_PERIOD_TRANSITION: cannot reopen', 'T20 a period of a closing year cannot be reopened');
  cpl := t_post(CA3, '2027-03-20', '[{"a":"5101","dr":3},{"a":"5201","cr":3}]', 'closing_pl');
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_year SET status = 'open' WHERE id = %L$q$, fy),
     '^HK_LEDGER_FY_CLOSING_JOURNALS: void closing journals', 'T20 reopen requires voided closing journals');
  PERFORM t_post(CA3, '2027-03-21', '[{"a":"5101","dr":3},{"a":"5201","cr":3}]', 'opening');
  PERFORM ledger.void_journal(cpl, uuidv7(), t_ref(CA3, '2027-03-20'), 'V-CPL', 'آزمون بازگشایی سال');
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_year SET status = 'open' WHERE id = %L$q$, fy),
     '^HK_LEDGER_FY_CLOSING_JOURNALS: void the opening journal', 'T20 reopen requires voiding the next opening');
END $$;

DO $$
DECLARE CA2 uuid := '0a000000-0000-7000-8000-0000000000c2'; CA4 uuid := '0a000000-0000-7000-8000-0000000000c4';
        m1 uuid; m2 uuid; m3 uuid; t_proj uuid; d uuid;
BEGIN
  PERFORM t_ctx('A');
  -- سال قفل‌شدهٔ CA2 (پس از T15): دوره قفل‌گشایی نمی‌شود
  PERFORM expect_error(format($q$UPDATE ledger.fiscal_period SET status = 'closed', status_approval_ref = uuidv7(), status_reason = 'قفل‌گشایی آزمون'
     WHERE fiscal_year_id = %L AND period_no = 1$q$, t_fy(CA2, '1405')),
     '^HK_LEDGER_PERIOD_TRANSITION: periods of a locked', 'T20 periods of a locked year cannot be unlocked');
  -- اعمال قالب
  PERFORM expect_error(format($q$SELECT ledger.apply_coa_template(%L, 'ir.general', 1)$q$, '0a000000-0000-7000-8000-0000000000c3'),
     '^HK_LEDGER_COA_NOT_EMPTY', 'T20 template applies only to an empty chart');
  PERFORM expect_error(format($q$SELECT ledger.apply_coa_template(%L, 'no.such', 1)$q$, CA4),
     '^HK_LEDGER_TEMPLATE_NOT_FOUND', 'T20 unknown template');
  PERFORM expect_error(format($q$SELECT ledger.apply_coa_template(%L, 'test.ext', 1)$q$, CA4),
     '^HK_LEDGER_TEMPLATE_EXTENDS', 'T20 only flattened templates are applied');
  PERFORM expect_error(format($q$SELECT ledger.apply_coa_template(%L, 'test.badparent', 1)$q$, CA4),
     '^HK_LEDGER_TEMPLATE_PARENT', 'T20 template account parent must exist');
  PERFORM expect_error(format($q$SELECT ledger.apply_coa_template(%L, 'test.baddim', 1)$q$, CA4),
     '^HK_LEDGER_DIM_TYPE_MISSING', 'T20 template dimension type must be provisioned');
  -- ابعاد
  SELECT id INTO t_proj FROM ledger.dimension_type WHERE code = 'project';
  PERFORM expect_error(format($q$UPDATE ledger.dimension_value SET dimension_type_id = %L WHERE code = 'CC1'$q$, t_proj),
     '^HK_LEDGER_DIM_IMMUTABLE', 'T20 dimension type of a value is immutable');
  PERFORM expect_error($q$INSERT INTO ledger.dimension_value (tenant_id, dimension_type_id, code, name, parent_id)
     SELECT core.current_tenant_id(), t.id, 'CC9', 'زیر برگ', t_dim('cost_center', 'CC1') FROM ledger.dimension_type t WHERE t.code = 'cost_center'$q$,
     '^HK_LEDGER_DIM_PARENT', 'T20 parent value must be a group of the same type');
  INSERT INTO ledger.dimension_value (tenant_id, dimension_type_id, code, name)
  SELECT core.current_tenant_id(), t_proj, v.c, v.c FROM (VALUES ('M1'), ('M2'), ('M3')) v(c);
  m1 := t_dim('project', 'M1'); m2 := t_dim('project', 'M2'); m3 := t_dim('project', 'M3');
  UPDATE ledger.dimension_value SET merged_into_id = m2, is_active = false WHERE id = m1;
  PERFORM expect_error(format($q$UPDATE ledger.dimension_value SET merged_into_id = %L WHERE id = %L$q$, m3, m1),
     '^HK_LEDGER_DIM_MERGE: a merge can only be re-pointed', 'T20 a merge is re-pointed only along its chain');
  -- توابع definer و provision بدون زمینهٔ مستأجر
  PERFORM t_ctx('');
  PERFORM expect_error($q$SELECT ledger.provision_tenant()$q$, '^HK_LEDGER_TENANT_CONTEXT', 'T20 provision requires a tenant context');
  PERFORM expect_error(format($q$SELECT ledger.compact_balance_buckets(%L, uuidv7())$q$, CA2),
     '^HK_LEDGER_TENANT_CONTEXT', 'T20 compaction requires a tenant context');
  PERFORM expect_error(format($q$SELECT ledger.rebuild_balance_buckets(%L, uuidv7())$q$, CA2),
     '^HK_LEDGER_TENANT_CONTEXT', 'T20 rebuild requires a tenant context');
  PERFORM t_ctx('A');
  -- منشأ پیش‌نویس (INV-LED-45)
  INSERT INTO ledger.journal_draft (tenant_id, company_id, journal_date, created_via)
  VALUES (core.current_tenant_id(), CA2, '2026-05-01', 'assistant') RETURNING id INTO d;
  PERFORM assert_true((SELECT created_via FROM ledger.journal_draft WHERE id = d) = 'assistant', 'T20 draft provenance recorded');
  PERFORM assert_true((SELECT created_via FROM ledger.journal_draft WHERE id <> d LIMIT 1) IS DISTINCT FROM 'assistant', 'T20 draft provenance defaults to user');
  PERFORM expect_error(format($q$INSERT INTO ledger.journal_draft (tenant_id, company_id, journal_date, created_via)
     VALUES (core.current_tenant_id(), %L, '2026-05-01', 'recurring')$q$, CA2),
     'journal_draft_check', 'T20 draft provenance recurring requires a recurring template');
  PERFORM expect_error(format($q$INSERT INTO ledger.journal_draft (tenant_id, company_id, journal_date, created_via)
     VALUES (core.current_tenant_id(), %L, '2026-05-01', 'robot')$q$, CA2),
     'created_via_check', 'T20 draft provenance is one of the allowed origins');
  DELETE FROM ledger.journal_draft WHERE id = d;
END $$;

-- ---------- T18: hk_readonly ----------
RESET ROLE;
SET ROLE hk_readonly;
DO $$
BEGIN
  PERFORM t_ctx('A');
  PERFORM assert_true((SELECT count(*) FROM ledger.journal) > 0, 'T18 readonly can read');
  PERFORM expect_error($q$INSERT INTO ledger.rate_type (tenant_id, code, name) VALUES (core.current_tenant_id(), 'zz', 'zz')$q$,
                       'permission denied', 'T18 readonly cannot write');
END $$;

-- =====================================================================
-- بخش ۳: دست‌کاری مستقیم (postgres، ROLLBACK)
-- =====================================================================
RESET ROLE;
BEGIN;
DO $$
DECLARE CA uuid := '0a000000-0000-7000-8000-0000000000c1'; fy uuid;
BEGIN
  PERFORM t_ctx('A');
  fy := t_fy(CA, '1405');
  -- حتی مالک جدول (بدون غیرفعال کردن تریگر) نمی‌تواند سطر دفتر را تغییر دهد
  PERFORM expect_error(format($q$UPDATE ledger.journal_line SET description = 'x' WHERE company_id = %L$q$, CA),
     'HK_IMMUTABLE', 'T19 owner update blocked by trigger');
  PERFORM expect_error(format($q$UPDATE ledger.journal SET description = 'x' WHERE company_id = %L AND status = 'permanent'$q$, CA),
     'HK_IMMUTABLE', 'T19 owner header update blocked by trigger');
  PERFORM expect_error(format($q$UPDATE ledger.journal SET description = 'x' WHERE company_id = %L AND status = 'temporary'$q$, CA),
     'HK_IMMUTABLE', 'T19 owner cannot edit a temporary journal content either');
  PERFORM expect_error(format($q$UPDATE ledger.journal SET journal_date = journal_date + 1 WHERE company_id = %L AND status = 'temporary'$q$, CA),
     'HK_IMMUTABLE', 'T19 owner cannot move a temporary journal date');
  PERFORM expect_error(format($q$DELETE FROM ledger.journal WHERE company_id = %L$q$, CA), 'HK_IMMUTABLE', 'T19 owner delete blocked');
END $$;
-- تریگر سطل (SECURITY DEFINER) سطر بیرون از زمینهٔ مستأجر را صریحاً رد می‌کند (مالک جدول RLS را دور می‌زند؛ تریگر نه)
DO $$
BEGIN
  PERFORM t_ctx('A');
  PERFORM expect_error($q$SELECT t_raw('0b000000-0000-7000-8000-0000000000c1', '2026-06-01', '{"tenant_id":"0b000000-0000-7000-8000-000000000001"}')$q$,
     '^HK_LEDGER_TENANT_CONTEXT: lines outside', 'T19 bucket trigger rejects lines outside the tenant context');
END $$;
ALTER TABLE ledger.journal_line DISABLE TRIGGER USER;
UPDATE ledger.journal_line l SET debit_base = debit_base + 1, debit_txn = debit_txn + 1
  FROM ledger.journal j WHERE j.id = l.journal_id AND j.permanent_no = 2 AND l.debit_base > 0
   AND j.company_id = '0a000000-0000-7000-8000-0000000000c1';
ALTER TABLE ledger.journal_line ENABLE TRIGGER USER;
DO $$
DECLARE CA uuid := '0a000000-0000-7000-8000-0000000000c1'; fy uuid;
BEGIN
  PERFORM t_ctx('A');
  fy := t_fy(CA, '1405');
  PERFORM assert_true(EXISTS (SELECT 1 FROM ledger.verify_permanent_chain(fy) WHERE problem = 'content_hash_mismatch' AND permanent_no = 2),
                      'T19 tampering detected by the hash chain');
  PERFORM assert_true(EXISTS (SELECT 1 FROM ledger.verify_balance_buckets(CA, fy)), 'T19 tampering detected by bucket verification');
  PERFORM assert_true(EXISTS (SELECT 1 FROM ledger.check_trial_balance(CA, fy)), 'T19 tampering detected by trial balance check');
END $$;
ROLLBACK;

\echo 'ALL 20_ledger TESTS PASSED'
