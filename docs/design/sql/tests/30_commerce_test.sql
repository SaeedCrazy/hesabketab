-- =====================================================================
-- آزمون پایگاه داده‌ای 30_commerce.sql (سند: docs/design/05-commerce.md §۷ و §۹)
--
-- اجرا (از ریشهٔ مخزن؛ پایگاه دادهٔ تازه با UTF8):
--   export PGPASSWORD=postgres
--   psql -h localhost -p 5433 -U postgres -d postgres -c "DROP DATABASE IF EXISTS ds_commerce"
--   psql -h localhost -p 5433 -U postgres -d postgres -c "CREATE DATABASE ds_commerce ENCODING 'UTF8' TEMPLATE template0 LC_COLLATE 'C' LC_CTYPE 'C.UTF-8'"
--   for f in 00_foundation 10_core 20_ledger 25_masterdata 30_commerce; do
--     psql -h localhost -p 5433 -U postgres -d ds_commerce -v ON_ERROR_STOP=1 -f docs/design/sql/$f.sql; done
--   psql -h localhost -p 5433 -U postgres -d ds_commerce -v ON_ERROR_STOP=1 -f docs/design/sql/tests/30_commerce_test.sql
--
-- ساختار (یک نشست psql که با superuser وصل می‌شود):
--   بخش ۱ (fixture، نقش postgres): مستأجر A (شرکت CA: میانگین موزون، استخر شرکت، دائمی؛ CF: FIFO، استخر انبار؛
--         CP: ادواری) و مستأجر B؛ کاربران و عضویت‌ها؛ کدینگ ir.general و سال مالی ۱۴۰۵؛ کالاها (ساده، بچ/انقضا،
--         سریال، منو با دستور پخت، خدمت، بدون تخفیف، نیمه‌آماده)؛ اشخاص؛ سری شماره؛ توابع کمکی آزمون
--         (c_ok, c_err, c_ctx, c_num, c_journal, c_move).
--   بخش ۲ (assert، «SET ROLE hk_app»؛ نه مالک، NOBYPASSRLS): هر DO block یک تراکنش است و مستأجر را با
--         set_config('app.tenant_id', ..., true) تنظیم می‌کند. موارد منفیِ deferred با SET CONSTRAINTS ALL IMMEDIATE
--         درون زیرتراکنش c_err آزموده می‌شوند. هر شکست «TEST FAILED: ...» است و psql با کد ≠ ۰ خارج می‌شود.
--   بخش ۳: جداسازی مستأجر (مستأجر B) و نقش hk_readonly.
-- خروجی موفق با «ALL 30_commerce TESTS PASSED» پایان می‌یابد.
-- =====================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
SET client_min_messages = warning;

-- =====================================================================
-- بخش ۱: fixture (postgres)
-- =====================================================================
RESET ROLE;
CREATE OR REPLACE FUNCTION public.c_ok(p_cond boolean, p_label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond IS NOT TRUE THEN RAISE EXCEPTION 'TEST FAILED: %', p_label; END IF;
END $$;

-- اجرای SQL در زیرتراکنش؛ تریگرهای deferred همان‌جا اجرا می‌شوند؛ خطا باید با الگو (regex روی پیام یا SQLSTATE) بخواند
CREATE OR REPLACE FUNCTION public.c_err(p_sql text, p_pattern text, p_label text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_state text; v_msg text;
BEGIN
  BEGIN
    EXECUTE p_sql;
    EXECUTE 'SET CONSTRAINTS ALL IMMEDIATE';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state ~ ('^(' || p_pattern || ')$') OR v_msg ~ p_pattern THEN RETURN; END IF;
    RAISE EXCEPTION 'TEST FAILED: % — expected /%/, got % %', p_label, p_pattern, v_state, v_msg;
  END;
  RAISE EXCEPTION 'TEST FAILED: % — statement succeeded but must fail', p_label;
END $$;

CREATE OR REPLACE FUNCTION public.c_ctx(p_tenant text) RETURNS void
LANGUAGE sql AS $$
  SELECT set_config('app.tenant_id', CASE p_tenant WHEN 'A' THEN '30a00000-0000-7000-8000-000000000001'
                                                    WHEN 'B' THEN '30b00000-0000-7000-8000-000000000001' ELSE '' END, true),
         set_config('app.user_id', CASE p_tenant WHEN 'A' THEN '30a00000-0000-7000-8000-00000000aa01'
                                                  WHEN 'B' THEN '30b00000-0000-7000-8000-00000000aa01' ELSE '' END, true);
$$;

-- شمارهٔ بی‌فاصله برای یک سند (سری پیش‌فرض شرکت/نوع)
CREATE OR REPLACE FUNCTION public.c_num(p_company uuid, p_doc_type text, p_doc_id uuid) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_series uuid; r record;
BEGIN
  SELECT s.id INTO v_series FROM core.number_series s WHERE s.company_id = p_company AND s.doc_type = p_doc_type AND s.is_default;
  SELECT * INTO r FROM core.number_next(v_series, 'all', p_doc_type || '-{seq}', p_doc_type, p_doc_id);
  RETURN r.number_id;
END $$;
CREATE OR REPLACE FUNCTION public.c_no(p_number uuid) RETURNS text
LANGUAGE sql STABLE AS $$ SELECT formatted FROM core.number_issued WHERE id = p_number $$;

-- سند حسابداری آزمایشی با مرجع مبدأ (در تولید: LedgerPostingService.post)
CREATE OR REPLACE FUNCTION public.c_journal(p_company uuid, p_date date, p_module text, p_doc_type text, p_doc_id uuid,
                                            p_event text DEFAULT 'post') RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid := uuidv7(); v_fy uuid; v_ref bigint; a1 uuid; a2 uuid;
BEGIN
  SELECT f.id INTO v_fy FROM ledger.fiscal_year f WHERE f.company_id = p_company AND p_date BETWEEN f.start_date AND f.end_date;
  SELECT coalesce(max(j.reference_no), 0) + 1 INTO v_ref FROM ledger.journal j WHERE j.company_id = p_company AND j.fiscal_year_id = v_fy;
  SELECT id INTO a1 FROM ledger.account WHERE company_id = p_company AND code = '7303';
  SELECT id INTO a2 FROM ledger.account WHERE company_id = p_company AND code = '6202';
  INSERT INTO ledger.journal (tenant_id, id, company_id, fiscal_year_id, journal_date, journal_type, status, reference_no, reference_text,
                              source_module, source_doc_type, source_doc_id, source_event, base_currency, line_count,
                              total_debit_base, total_credit_base, description)
  VALUES (core.current_tenant_id(), v_id, p_company, v_fy, p_date, 'module', 'temporary', v_ref, 'T-' || v_ref,
          p_module, p_doc_type, p_doc_id, p_event, 'IRR', 2, 1, 1, 'آزمون بازرگانی');
  INSERT INTO ledger.journal_line (tenant_id, journal_id, line_no, account_id, currency, exchange_rate, debit_txn, credit_txn, debit_base, credit_base)
  VALUES (core.current_tenant_id(), v_id, 1, a1, 'IRR', 1, 1, 0, 1, 0),
         (core.current_tenant_id(), v_id, 2, a2, 'IRR', 1, 0, 1, 0, 1);
  RETURN v_id;
END $$;

-- سند حسابداری واقعی از کلیدهای ثبت (در تولید: LedgerPostingService.post): سطرها [{key, dr|cr, party?, acct?}]؛ مبلغ منفی به طرف
-- دیگر می‌رود و صفر حذف می‌شود؛ حساب با ledger.resolve_account؛ بُعد شخص (جایگاه ۱) از ledger.dimension_value.party_id.
CREATE OR REPLACE FUNCTION public.c_jr(p_company uuid, p_date date, p_module text, p_doc_type text, p_doc_id uuid, p_event text,
                                       p_lines jsonb) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid := uuidv7(); v_fy uuid; v_ref bigint; v_tot numeric; v_cnt int; v_br uuid;
BEGIN
  SELECT f.id INTO v_fy FROM ledger.fiscal_year f WHERE f.company_id = p_company AND p_date BETWEEN f.start_date AND f.end_date;
  SELECT coalesce(max(j.reference_no), 0) + 1 INTO v_ref FROM ledger.journal j WHERE j.company_id = p_company AND j.fiscal_year_id = v_fy;
  SELECT b.id INTO v_br FROM core.branch b WHERE b.company_id = p_company ORDER BY b.code LIMIT 1;
  CREATE TEMP TABLE IF NOT EXISTS c_jr_lines (ord int, acct uuid, key text, amt numeric, party uuid) ON COMMIT DROP;
  DELETE FROM c_jr_lines;
  INSERT INTO c_jr_lines
  SELECT o.ord::int, coalesce((o.l->>'acct')::uuid, (SELECT r.account_id FROM ledger.resolve_account(p_company, o.l->>'key', p_date, '{}'::jsonb) r)),
         o.l->>'key', coalesce((o.l->>'dr')::numeric, 0) - coalesce((o.l->>'cr')::numeric, 0), (o.l->>'party')::uuid
    FROM jsonb_array_elements(p_lines) WITH ORDINALITY o(l, ord)
   WHERE coalesce((o.l->>'dr')::numeric, 0) - coalesce((o.l->>'cr')::numeric, 0) <> 0;
  SELECT coalesce(sum(greatest(amt, 0)), 0), count(*) INTO v_tot, v_cnt FROM c_jr_lines;
  IF v_cnt = 0 THEN RETURN NULL; END IF;
  INSERT INTO ledger.journal (tenant_id, id, company_id, fiscal_year_id, journal_date, journal_type, status, reference_no, reference_text,
                              source_module, source_doc_type, source_doc_id, source_event, base_currency, line_count,
                              total_debit_base, total_credit_base, description)
  VALUES (core.current_tenant_id(), v_id, p_company, v_fy, p_date, 'module', 'temporary', v_ref, 'T-' || v_ref,
          p_module, p_doc_type, p_doc_id, p_event, 'IRR', v_cnt, v_tot, v_tot, 'آزمون بازرگانی: ' || p_doc_type);
  INSERT INTO ledger.journal_line (tenant_id, journal_id, line_no, account_id, branch_id, dim1_id, currency, exchange_rate,
                                   debit_txn, credit_txn, debit_base, credit_base, posting_key)
  SELECT core.current_tenant_id(), v_id, row_number() OVER (ORDER BY x.ord), x.acct,
         CASE WHEN a.branch_rule <> 'forbidden' THEN v_br END,
         (SELECT dv.id FROM ledger.dimension_value dv WHERE dv.party_id = x.party AND dv.merged_into_id IS NULL LIMIT 1),
         'IRR', 1, greatest(x.amt, 0), greatest(-x.amt, 0), greatest(x.amt, 0), greatest(-x.amt, 0), x.key
    FROM c_jr_lines x JOIN ledger.account a ON a.id = x.acct;
  RETURN v_id;
END $$;

-- سند موجودی (source_module='inventory') از حرکت‌های زندهٔ سند(ها): برای هر (حساب موجودی، کلید طرف مقابل) ارزش لایه‌های move و
-- تسویه؛ ارزش صفر ← بی‌سند (NULL). p_off: انحراف عمدی برای آزمون منفی.
CREATE OR REPLACE FUNCTION public.c_stock_jr(p_company uuid, p_date date, p_doc_type text, p_doc_id uuid, p_docs uuid[],
                                             p_event text DEFAULT 'post', p_reversals boolean DEFAULT false, p_off numeric DEFAULT 0)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_lines jsonb;
BEGIN
  SELECT jsonb_agg(x) INTO v_lines FROM (
    SELECT jsonb_build_object('acct', m.asset_account_id, 'key', 'inventory.asset', 'dr', sum(l.value) + p_off) AS x
      FROM inventory.stock_move m JOIN inventory.valuation_layer l ON l.move_id = m.id AND l.reason IN ('move','negative_settlement')
     WHERE m.source_doc_id = ANY (p_docs) AND m.asset_account_id IS NOT NULL AND (m.reversal_of_move_id IS NOT NULL) = p_reversals
     GROUP BY m.asset_account_id, m.contra_posting_key
    UNION ALL
    SELECT jsonb_build_object('key', m.contra_posting_key, 'cr', sum(l.value) + p_off)
      FROM inventory.stock_move m JOIN inventory.valuation_layer l ON l.move_id = m.id AND l.reason IN ('move','negative_settlement')
     WHERE m.source_doc_id = ANY (p_docs) AND m.asset_account_id IS NOT NULL AND (m.reversal_of_move_id IS NOT NULL) = p_reversals
     GROUP BY m.asset_account_id, m.contra_posting_key) q;
  IF v_lines IS NULL THEN RETURN NULL; END IF;
  RETURN public.c_jr(p_company, p_date, 'inventory', p_doc_type, p_doc_id, p_event, v_lines);
END $$;

-- برگشت یک سند GL (در تولید: LedgerPostingService.reverse_by_source)
CREATE OR REPLACE FUNCTION public.c_rev_jr(p_journal uuid, p_date date, p_event text DEFAULT 'cancel') RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_ref bigint; j ledger.journal;
BEGIN
  IF p_journal IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO j FROM ledger.journal WHERE id = p_journal;
  SELECT coalesce(max(x.reference_no), 0) + 1 INTO v_ref FROM ledger.journal x WHERE x.company_id = j.company_id AND x.fiscal_year_id = j.fiscal_year_id;
  RETURN ledger.reverse_journal(p_journal, uuidv7(), p_date, v_ref, 'R-' || v_ref, NULL, p_event);
END $$;

-- درج حرکت انبار با پیش‌فرض‌ها: {"company","wh","item","variant","kind","qty","date", اختیاری: "rule","value","cost",
-- "unknown","src","rev","group","batch","uom","qty_uom","doc","line","origin","party","acct","id"}
CREATE OR REPLACE FUNCTION public.c_move(p jsonb) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE r inventory.stock_move;
BEGIN
  r.tenant_id := core.current_tenant_id();
  r.id := coalesce((p->>'id')::uuid, uuidv7());
  r.company_id := (p->>'company')::uuid; r.warehouse_id := (p->>'wh')::uuid;
  r.item_id := (p->>'item')::uuid; r.variant_id := (p->>'variant')::uuid; r.batch_id := (p->>'batch')::uuid;
  r.move_date := (p->>'date')::date; r.move_kind := p->>'kind'; r.qty_base := (p->>'qty')::numeric;
  r.uom_id := coalesce((p->>'uom')::uuid, (SELECT s.base_uom_id FROM catalog.v_sku s WHERE s.variant_id = r.variant_id));
  r.qty_uom := coalesce((p->>'qty_uom')::numeric, abs(r.qty_base));
  r.valuation_rule := coalesce(p->>'rule', CASE WHEN p ? 'rev' THEN 'reverse'
                                                 WHEN inventory.kind_sign(r.move_kind) > 0 THEN 'input' ELSE 'pool_out' END);
  r.input_value := (p->>'value')::numeric; r.input_unit_cost := (p->>'cost')::numeric;
  r.input_cost_status := CASE WHEN p ? 'unknown' THEN 'unknown' ELSE 'known' END;
  r.cost_source_move_id := (p->>'src')::uuid; r.reversal_of_move_id := (p->>'rev')::uuid; r.cost_group_id := (p->>'group')::uuid;
  r.party_id := (p->>'party')::uuid; r.asset_account_id := (p->>'acct')::uuid;
  -- شبیه سرویس (D-C13): در حالت دائمی حساب موجودی حل‌شده روی حرکت می‌نشیند (گزینهٔ no_acct برای آزمون منفی)
  IF r.asset_account_id IS NULL AND NOT p ? 'no_acct' AND r.reversal_of_move_id IS NULL
     AND (SELECT x.inventory_mode FROM inventory.company_policy x WHERE x.company_id = r.company_id AND x.effective_from <= r.move_date
           ORDER BY x.effective_from DESC LIMIT 1) = 'perpetual' THEN
    SELECT a.account_id INTO r.asset_account_id FROM ledger.resolve_account(r.company_id, 'inventory.asset', r.move_date, '{}'::jsonb) a;
  END IF;
  IF r.reversal_of_move_id IS NOT NULL AND NOT p ? 'acct' THEN
    SELECT m.asset_account_id INTO r.asset_account_id FROM inventory.stock_move m WHERE m.id = r.reversal_of_move_id;
  END IF;
  r.contra_posting_key := p->>'contra';
  r.source_module := coalesce(p->>'module', 'inventory'); r.source_doc_type := coalesce(p->>'doc_type', 'inventory.test');
  r.source_doc_id := coalesce((p->>'doc')::uuid, uuidv7()); r.source_line_id := (p->>'line')::uuid;
  r.origin := coalesce(p->>'origin', 'online');
  -- فروش آفلاین فقط از دستگاه صندوق و برای سند فروش (RV-COM-20)
  IF r.origin = 'offline_device' THEN
    r.device_id := coalesce((p->>'device')::uuid, public.k('DEV1'));
    r.source_module := coalesce(p->>'module', 'sales'); r.source_doc_type := coalesce(p->>'doc_type', 'sales.invoice');
  END IF;
  INSERT INTO inventory.stock_move SELECT r.*;
  RETURN r.id;
END $$;
CREATE OR REPLACE FUNCTION public.c_mval(p_move uuid) RETURNS numeric
LANGUAGE sql STABLE AS $$ SELECT coalesce(sum(value), 0) FROM inventory.valuation_layer WHERE move_id = p_move $$;
GRANT EXECUTE ON FUNCTION public.c_ok(boolean, text), public.c_err(text, text, text), public.c_ctx(text),
  public.c_num(uuid, text, uuid), public.c_no(uuid), public.c_journal(uuid, date, text, text, uuid, text),
  public.c_move(jsonb), public.c_mval(uuid), public.c_jr(uuid, date, text, text, uuid, text, jsonb),
  public.c_stock_jr(uuid, date, text, uuid, uuid[], text, boolean, numeric), public.c_rev_jr(uuid, date, text) TO hk_app, hk_readonly;


-- نام‌های کوتاه شناسه‌های fixture
CREATE TABLE IF NOT EXISTS public.c_key (name text PRIMARY KEY, id uuid NOT NULL);
INSERT INTO public.c_key VALUES
  ('A','30a00000-0000-7000-8000-000000000001'), ('B','30b00000-0000-7000-8000-000000000001'),
  ('CA','30a00000-0000-7000-8000-0000000000c1'), ('CF','30a00000-0000-7000-8000-0000000000c2'), ('CP','30a00000-0000-7000-8000-0000000000c3'),
  ('CB','30b00000-0000-7000-8000-0000000000c1'), ('BA','30a00000-0000-7000-8000-0000000000b1'), ('BF','30a00000-0000-7000-8000-0000000000b2'),
  ('BP','30a00000-0000-7000-8000-0000000000b3'), ('BB','30b00000-0000-7000-8000-0000000000b1'),
  ('U1','30a00000-0000-7000-8000-00000000aa01'), ('U2','30a00000-0000-7000-8000-00000000aa02'), ('UB','30b00000-0000-7000-8000-00000000aa01'),
  ('W1','30a00000-0000-7000-8000-00000000d001'), ('W2','30a00000-0000-7000-8000-00000000d002'), ('WT','30a00000-0000-7000-8000-00000000d003'),
  ('F1','30a00000-0000-7000-8000-00000000d011'), ('F2','30a00000-0000-7000-8000-00000000d012'), ('FT','30a00000-0000-7000-8000-00000000d013'),
  ('P1','30a00000-0000-7000-8000-00000000d021'),
  ('PCS','30a00000-0000-7000-8000-00000000c001'), ('CTN','30a00000-0000-7000-8000-00000000c002'), ('KG','30a00000-0000-7000-8000-00000000c003'),
  ('CUP','30a00000-0000-7000-8000-00000000c006'),
  ('I.X','30a00000-0000-7000-8000-00000000c101'), ('V.X','30a00000-0000-7000-8000-00000000c111'),
  ('I.MILK','30a00000-0000-7000-8000-00000000c102'), ('V.MILK','30a00000-0000-7000-8000-00000000c112'),
  ('I.TV','30a00000-0000-7000-8000-00000000c103'), ('V.TV','30a00000-0000-7000-8000-00000000c113'),
  ('I.LATTE','30a00000-0000-7000-8000-00000000c104'), ('V.LATTE','30a00000-0000-7000-8000-00000000c114'),
  ('I.SRV','30a00000-0000-7000-8000-00000000c105'), ('V.SRV','30a00000-0000-7000-8000-00000000c115'),
  ('I.NOD','30a00000-0000-7000-8000-00000000c106'), ('V.NOD','30a00000-0000-7000-8000-00000000c116'),
  ('I.SYR','30a00000-0000-7000-8000-00000000c107'), ('V.SYR','30a00000-0000-7000-8000-00000000c117'),
  ('BOM.LATTE','30a00000-0000-7000-8000-00000000c201'), ('BOM.SYR','30a00000-0000-7000-8000-00000000c202'),
  ('ANON','30a00000-0000-7000-8000-00000000a100'), ('C1','30a00000-0000-7000-8000-00000000a101'), ('C2','30a00000-0000-7000-8000-00000000a102'),
  ('S1','30a00000-0000-7000-8000-00000000a201'), ('S2','30a00000-0000-7000-8000-00000000a202'), ('AG1','30a00000-0000-7000-8000-00000000a301'),
  ('DEV1','30a00000-0000-7000-8000-0000000de001'), ('DEV2','30a00000-0000-7000-8000-0000000de002'),
  ('I.DA','30a00000-0000-7000-8000-00000000c1a1'), ('V.DA','30a00000-0000-7000-8000-00000000c1b1'),
  ('I.DB','30a00000-0000-7000-8000-00000000c1a2'), ('V.DB','30a00000-0000-7000-8000-00000000c1b2'),
  ('I.LK','30a00000-0000-7000-8000-00000000c1a3'), ('V.LK','30a00000-0000-7000-8000-00000000c1b3'),
  ('W9','30a00000-0000-7000-8000-00000000d009'),
  ('M1','30a00000-0000-7000-8000-00000000a401'), ('M2','30a00000-0000-7000-8000-00000000a402'),
  ('NS.TICKET','30a00000-0000-7000-8000-0000000de101')
ON CONFLICT DO NOTHING;
CREATE OR REPLACE FUNCTION public.k(p_name text) RETURNS uuid
LANGUAGE sql STABLE AS $$ SELECT id FROM public.c_key WHERE name = p_name $$;
-- حرکت با نام‌های کوتاه: c_mv('CA','W1','X','receipt',10,'2026-04-01','{"value":1000}')
CREATE OR REPLACE FUNCTION public.c_mv(p_company text, p_wh text, p_sku text, p_kind text, p_qty numeric, p_date date,
                                       p_extra jsonb DEFAULT '{}') RETURNS uuid
LANGUAGE sql AS $$
  SELECT public.c_move(jsonb_build_object('company', public.k(p_company), 'wh', public.k(p_wh), 'item', public.k('I.' || p_sku),
                                          'variant', public.k('V.' || p_sku), 'kind', p_kind, 'qty', p_qty, 'date', p_date) || p_extra)
$$;
CREATE OR REPLACE FUNCTION public.c_pool(p_move uuid) RETURNS inventory.cost_pool
LANGUAGE sql STABLE AS $$ SELECT c.* FROM inventory.cost_pool c JOIN inventory.stock_move m ON m.pool_id = c.id WHERE m.id = p_move $$;
GRANT SELECT ON public.c_key TO hk_app, hk_readonly;
GRANT EXECUTE ON FUNCTION public.k(text), public.c_mv(text, text, text, text, numeric, date, jsonb), public.c_pool(uuid) TO hk_app, hk_readonly;

BEGIN;
\o /dev/null
SELECT set_config('app.tenant_id', '30a00000-0000-7000-8000-000000000001', true);
\o
INSERT INTO core.tenant (id, slug, display_name) VALUES
  ('30a00000-0000-7000-8000-000000000001', 'cm-tenant-a', 'A'),
  ('30b00000-0000-7000-8000-000000000001', 'cm-tenant-b', 'B');
INSERT INTO core.company (tenant_id, id, code, name) VALUES
  ('30a00000-0000-7000-8000-000000000001', '30a00000-0000-7000-8000-0000000000c1', 'CA', 'کافه و فروشگاه الف'),
  ('30a00000-0000-7000-8000-000000000001', '30a00000-0000-7000-8000-0000000000c2', 'CF', 'پوشاک الف'),
  ('30a00000-0000-7000-8000-000000000001', '30a00000-0000-7000-8000-0000000000c3', 'CP', 'ادواری الف'),
  ('30b00000-0000-7000-8000-000000000001', '30b00000-0000-7000-8000-0000000000c1', 'CB', 'شرکت ب');
INSERT INTO core.branch (tenant_id, id, company_id, code, name) VALUES
  ('30a00000-0000-7000-8000-000000000001', '30a00000-0000-7000-8000-0000000000b1', '30a00000-0000-7000-8000-0000000000c1', 'BR1', 'شعبه ۱'),
  ('30a00000-0000-7000-8000-000000000001', '30a00000-0000-7000-8000-0000000000b2', '30a00000-0000-7000-8000-0000000000c2', 'BR1', 'شعبه ۱'),
  ('30a00000-0000-7000-8000-000000000001', '30a00000-0000-7000-8000-0000000000b3', '30a00000-0000-7000-8000-0000000000c3', 'BR1', 'شعبه ۱'),
  ('30b00000-0000-7000-8000-000000000001', '30b00000-0000-7000-8000-0000000000b1', '30b00000-0000-7000-8000-0000000000c1', 'BR1', 'شعبه ۱');
INSERT INTO core.app_user (id, display_name) VALUES
  ('30a00000-0000-7000-8000-00000000aa01', 'کاربر یک'), ('30a00000-0000-7000-8000-00000000aa02', 'کاربر دو'),
  ('30b00000-0000-7000-8000-00000000aa01', 'کاربر ب');
INSERT INTO core.tenant_membership (tenant_id, user_id, status, is_owner, joined_at) VALUES
  ('30a00000-0000-7000-8000-000000000001', '30a00000-0000-7000-8000-00000000aa01', 'active', true, now()),
  ('30a00000-0000-7000-8000-000000000001', '30a00000-0000-7000-8000-00000000aa02', 'active', false, now()),
  ('30b00000-0000-7000-8000-000000000001', '30b00000-0000-7000-8000-00000000aa01', 'active', true, now());
-- سری شماره (یکی برای هر نوع سند در CA و CF و CB)
INSERT INTO core.number_series (tenant_id, company_id, code, name, doc_type, scope, pattern, reset_policy)
SELECT c.tenant_id, c.id, d, d, d, 'company', '{prefix}{seq}', 'never'
  FROM core.company c CROSS JOIN unnest(ARRAY['inventory.adjustment','inventory.transfer','inventory.opening','inventory.production',
       'inventory.count','sales.invoice','sales.return','sales.correction','sales.delivery','sales.quotation','sales.order',
       'purchase.receipt','purchase.invoice','purchase.return','purchase.order','purchase.requisition']) d;
COMMIT;

-- کدینگ، سال مالی و دادهٔ پایه (با زمینهٔ مستأجر؛ هنوز postgres)
DO $$
DECLARE t uuid := '30a00000-0000-7000-8000-000000000001'; c uuid; v_fy uuid; lens int[] := ARRAY[31,31,31,31,31,31,30,30,30,30,30,29];
        d date; i int;
BEGIN
  PERFORM public.c_ctx('A');
  PERFORM ledger.provision_tenant();
  FOREACH c IN ARRAY ARRAY['30a00000-0000-7000-8000-0000000000c1','30a00000-0000-7000-8000-0000000000c2','30a00000-0000-7000-8000-0000000000c3']::uuid[] LOOP
    PERFORM ledger.apply_coa_template(c, 'ir.general', 1);
    v_fy := uuidv7(); d := DATE '2026-03-21';
    INSERT INTO ledger.fiscal_year (tenant_id, id, company_id, code, name, start_date, end_date, base_currency)
    VALUES (t, v_fy, c, '1405', 'سال ۱۴۰۵', d, d + 364, 'IRR');
    FOR i IN 1..12 LOOP
      INSERT INTO ledger.fiscal_period (tenant_id, company_id, fiscal_year_id, period_no, name, start_date, end_date)
      VALUES (t, c, v_fy, i, 'ماه ' || i, d, d + lens[i] - 1);
      d := d + lens[i];
    END LOOP;
  END LOOP;

  INSERT INTO catalog.uom (tenant_id, id, code, name, dimension, dimension_factor, qty_decimals, moadian_unit_code) VALUES
    (t, '30a00000-0000-7000-8000-00000000c001', 'PCS', 'عدد', 'count', 1, 0, '1627'),
    (t, '30a00000-0000-7000-8000-00000000c002', 'CTN', 'کارتن', 'count', NULL, 0, '1624'),
    (t, '30a00000-0000-7000-8000-00000000c003', 'KG', 'کیلوگرم', 'mass', 1, 3, '164'),
    (t, '30a00000-0000-7000-8000-00000000c006', 'CUP', 'لیوان', 'count', NULL, 0, '16108');
  INSERT INTO catalog.item_posting_group (tenant_id, id, code, name) VALUES
    (t, '30a00000-0000-7000-8000-00000000c041', 'GOODS', 'کالای تجاری');
  -- X: کالای ساده (کارتن = ۱۲ عدد)
  INSERT INTO catalog.item (tenant_id, id, code, name, item_type, base_uom_id, posting_group_id, sstid, sstid_kind) VALUES
    (t, '30a00000-0000-7000-8000-00000000c101', 'X', 'کالای ایکس', 'stock', '30a00000-0000-7000-8000-00000000c001',
     '30a00000-0000-7000-8000-00000000c041', '2710000138624', 'general');
  INSERT INTO catalog.item_uom (tenant_id, item_id, uom_id, factor, is_base) VALUES
    (t, '30a00000-0000-7000-8000-00000000c101', '30a00000-0000-7000-8000-00000000c001', 1, true),
    (t, '30a00000-0000-7000-8000-00000000c101', '30a00000-0000-7000-8000-00000000c002', 12, false);
  INSERT INTO catalog.item_variant (tenant_id, id, item_id, code, is_default) VALUES
    (t, '30a00000-0000-7000-8000-00000000c111', '30a00000-0000-7000-8000-00000000c101', 'X', true);
  -- MILK: بچ + انقضا
  INSERT INTO catalog.item (tenant_id, id, code, name, item_type, base_uom_id, track_batch, track_expiry, shelf_life_days) VALUES
    (t, '30a00000-0000-7000-8000-00000000c102', 'MILK', 'شیر', 'stock', '30a00000-0000-7000-8000-00000000c003', true, true, 10);
  INSERT INTO catalog.item_uom (tenant_id, item_id, uom_id, factor, is_base) VALUES
    (t, '30a00000-0000-7000-8000-00000000c102', '30a00000-0000-7000-8000-00000000c003', 1, true);
  INSERT INTO catalog.item_variant (tenant_id, id, item_id, code, is_default) VALUES
    (t, '30a00000-0000-7000-8000-00000000c112', '30a00000-0000-7000-8000-00000000c102', 'MILK', true);
  -- TV: سریال + گارانتی ۳۶۵ روز
  INSERT INTO catalog.item (tenant_id, id, code, name, item_type, base_uom_id, track_serial, warranty_days, sstid, sstid_kind) VALUES
    (t, '30a00000-0000-7000-8000-00000000c103', 'TV', 'تلویزیون', 'stock', '30a00000-0000-7000-8000-00000000c001', true, 365,
     '2710000138624', 'general');
  INSERT INTO catalog.item_uom (tenant_id, item_id, uom_id, factor, is_base) VALUES
    (t, '30a00000-0000-7000-8000-00000000c103', '30a00000-0000-7000-8000-00000000c001', 1, true);
  INSERT INTO catalog.item_variant (tenant_id, id, item_id, code, is_default) VALUES
    (t, '30a00000-0000-7000-8000-00000000c113', '30a00000-0000-7000-8000-00000000c103', 'TV', true);
  -- LATTE: منو (غیرانباری) با دستور پخت
  INSERT INTO catalog.item (tenant_id, id, code, name, item_type, base_uom_id, sstid, sstid_kind) VALUES
    (t, '30a00000-0000-7000-8000-00000000c104', 'LATTE', 'لاته', 'non_stock', '30a00000-0000-7000-8000-00000000c006',
     '2710000138624', 'general');
  INSERT INTO catalog.item_uom (tenant_id, item_id, uom_id, factor, is_base) VALUES
    (t, '30a00000-0000-7000-8000-00000000c104', '30a00000-0000-7000-8000-00000000c006', 1, true);
  INSERT INTO catalog.item_variant (tenant_id, id, item_id, code, is_default) VALUES
    (t, '30a00000-0000-7000-8000-00000000c114', '30a00000-0000-7000-8000-00000000c104', 'LATTE', true);
  -- SRV: خدمت؛ NOD: کالای انباری بدون تخفیف و بدون تغییر قیمت؛ SYR: نیمه‌آمادهٔ تولیدی
  INSERT INTO catalog.item (tenant_id, id, code, name, item_type, base_uom_id, allow_discount, allow_price_override) VALUES
    (t, '30a00000-0000-7000-8000-00000000c105', 'SRV', 'خدمت نصب', 'service', '30a00000-0000-7000-8000-00000000c001', true, true),
    (t, '30a00000-0000-7000-8000-00000000c106', 'NOD', 'کالای قیمت ثابت', 'stock', '30a00000-0000-7000-8000-00000000c001', false, false),
    (t, '30a00000-0000-7000-8000-00000000c107', 'SYR', 'سیروپ', 'stock', '30a00000-0000-7000-8000-00000000c003', true, true);
  INSERT INTO catalog.item_uom (tenant_id, item_id, uom_id, factor, is_base) VALUES
    (t, '30a00000-0000-7000-8000-00000000c105', '30a00000-0000-7000-8000-00000000c001', 1, true),
    (t, '30a00000-0000-7000-8000-00000000c106', '30a00000-0000-7000-8000-00000000c001', 1, true),
    (t, '30a00000-0000-7000-8000-00000000c107', '30a00000-0000-7000-8000-00000000c003', 1, true);
  INSERT INTO catalog.item_variant (tenant_id, id, item_id, code, is_default) VALUES
    (t, '30a00000-0000-7000-8000-00000000c115', '30a00000-0000-7000-8000-00000000c105', 'SRV', true),
    (t, '30a00000-0000-7000-8000-00000000c116', '30a00000-0000-7000-8000-00000000c106', 'NOD', true),
    (t, '30a00000-0000-7000-8000-00000000c117', '30a00000-0000-7000-8000-00000000c107', 'SYR', true);
  INSERT INTO catalog.bom (tenant_id, id, item_id, kind, version_no, yield_qty, yield_uom_id) VALUES
    (t, '30a00000-0000-7000-8000-00000000c201', '30a00000-0000-7000-8000-00000000c104', 'recipe', 1, 1, '30a00000-0000-7000-8000-00000000c006'),
    (t, '30a00000-0000-7000-8000-00000000c202', '30a00000-0000-7000-8000-00000000c107', 'production', 1, 1, '30a00000-0000-7000-8000-00000000c003');
  INSERT INTO catalog.bom_line (tenant_id, bom_id, line_no, component_item_id, qty, uom_id) VALUES
    (t, '30a00000-0000-7000-8000-00000000c201', 1, '30a00000-0000-7000-8000-00000000c102', 0.2, '30a00000-0000-7000-8000-00000000c003'),
    (t, '30a00000-0000-7000-8000-00000000c202', 1, '30a00000-0000-7000-8000-00000000c102', 1, '30a00000-0000-7000-8000-00000000c003');
  -- فعال‌سازی پس‌تاریخ BOM فقط با پرچم مهاجرت/fixture (RV-MD-16 در 25_masterdata)
  PERFORM set_config('hk.catalog_allow_backdate', 'on', true);
  UPDATE catalog.bom SET status = 'active', valid_from = DATE '2026-03-21', activated_at = now()
   WHERE tenant_id = t AND id IN ('30a00000-0000-7000-8000-00000000c201','30a00000-0000-7000-8000-00000000c202');

  INSERT INTO parties.party (tenant_id, id, code, person_type, name, is_anonymous) VALUES
    (t, '30a00000-0000-7000-8000-00000000a100', 'ANON', 'natural', 'مشتری نقدی', true);
  INSERT INTO parties.party (tenant_id, id, code, person_type, name, first_name, last_name, national_id, national_id_status) VALUES
    (t, '30a00000-0000-7000-8000-00000000a101', 'C1', 'natural', 'علی محمدی', 'علی', 'محمدی', '0013542419', 'valid');
  INSERT INTO parties.party (tenant_id, id, code, person_type, name, national_id, national_id_status, economic_code) VALUES
    (t, '30a00000-0000-7000-8000-00000000a102', 'C2', 'legal', 'شرکت نمونه', '14003778990', 'valid', '14003778990');
  INSERT INTO parties.party (tenant_id, id, code, person_type, name) VALUES
    (t, '30a00000-0000-7000-8000-00000000a201', 'S1', 'legal', 'تأمین‌کننده یک'),
    (t, '30a00000-0000-7000-8000-00000000a202', 'S2', 'legal', 'تأمین‌کننده دو'),
    (t, '30a00000-0000-7000-8000-00000000a301', 'AG1', 'natural', 'بازاریاب یک'),
    (t, '30a00000-0000-7000-8000-00000000a401', 'M1', 'legal', 'مشتری برنده'),
    (t, '30a00000-0000-7000-8000-00000000a402', 'M2', 'legal', 'مشتری تکراری');

  -- سیاست موجودی: CA میانگین/شرکت/دائمی، CF فایفو/انبار، CP ادواری
  INSERT INTO inventory.company_policy (tenant_id, company_id, effective_from, valuation_method, inventory_mode, cost_pool_scope) VALUES
    (t, '30a00000-0000-7000-8000-0000000000c1', '2026-03-21', 'moving_average', 'perpetual', 'company'),
    (t, '30a00000-0000-7000-8000-0000000000c2', '2026-03-21', 'fifo', 'perpetual', 'warehouse'),
    (t, '30a00000-0000-7000-8000-0000000000c3', '2026-03-21', 'moving_average', 'periodic', 'company');
  INSERT INTO inventory.warehouse (tenant_id, id, company_id, branch_id, code, name, kind, negative_policy, is_default_transit) VALUES
    (t, '30a00000-0000-7000-8000-00000000d001', '30a00000-0000-7000-8000-0000000000c1', '30a00000-0000-7000-8000-0000000000b1', 'W1', 'انبار اصلی', 'standard', 'inherit', false),
    (t, '30a00000-0000-7000-8000-00000000d002', '30a00000-0000-7000-8000-0000000000c1', '30a00000-0000-7000-8000-0000000000b1', 'W2', 'انبار بسته', 'standard', 'block', false),
    (t, '30a00000-0000-7000-8000-00000000d003', '30a00000-0000-7000-8000-0000000000c1', NULL, 'WT', 'کالای در راه', 'transit', 'block', true),
    (t, '30a00000-0000-7000-8000-00000000d011', '30a00000-0000-7000-8000-0000000000c2', '30a00000-0000-7000-8000-0000000000b2', 'F1', 'انبار یک', 'standard', 'inherit', false),
    (t, '30a00000-0000-7000-8000-00000000d012', '30a00000-0000-7000-8000-0000000000c2', '30a00000-0000-7000-8000-0000000000b2', 'F2', 'انبار دو', 'standard', 'inherit', false),
    (t, '30a00000-0000-7000-8000-00000000d013', '30a00000-0000-7000-8000-0000000000c2', NULL, 'FT', 'در راه', 'transit', 'block', true),
    (t, '30a00000-0000-7000-8000-00000000d021', '30a00000-0000-7000-8000-0000000000c3', '30a00000-0000-7000-8000-0000000000b3', 'P1', 'انبار ادواری', 'standard', 'inherit', false),
    (t, '30a00000-0000-7000-8000-00000000d009', '30a00000-0000-7000-8000-0000000000c1', '30a00000-0000-7000-8000-0000000000b1', 'W9', 'انبار افتتاحیه', 'standard', 'inherit', false);
  -- کالاهای هم‌شکل برای آزمون تفاضلی ترتیب درج (DA، DB) و قفل کاربرد کالا (LK)
  INSERT INTO catalog.item (tenant_id, id, code, name, item_type, base_uom_id) VALUES
    (t, '30a00000-0000-7000-8000-00000000c1a1', 'DA', 'کالای تفاضلی الف', 'stock', '30a00000-0000-7000-8000-00000000c001'),
    (t, '30a00000-0000-7000-8000-00000000c1a2', 'DB', 'کالای تفاضلی ب', 'stock', '30a00000-0000-7000-8000-00000000c001'),
    (t, '30a00000-0000-7000-8000-00000000c1a3', 'LK', 'کالای قفل', 'stock', '30a00000-0000-7000-8000-00000000c001');
  INSERT INTO catalog.item_uom (tenant_id, item_id, uom_id, factor, is_base) VALUES
    (t, '30a00000-0000-7000-8000-00000000c1a1', '30a00000-0000-7000-8000-00000000c001', 1, true),
    (t, '30a00000-0000-7000-8000-00000000c1a2', '30a00000-0000-7000-8000-00000000c001', 1, true),
    (t, '30a00000-0000-7000-8000-00000000c1a3', '30a00000-0000-7000-8000-00000000c001', 1, true);
  INSERT INTO catalog.item_variant (tenant_id, id, item_id, code, is_default) VALUES
    (t, '30a00000-0000-7000-8000-00000000c1b1', '30a00000-0000-7000-8000-00000000c1a1', 'DA', true),
    (t, '30a00000-0000-7000-8000-00000000c1b2', '30a00000-0000-7000-8000-00000000c1a2', 'DB', true),
    (t, '30a00000-0000-7000-8000-00000000c1b3', '30a00000-0000-7000-8000-00000000c1a3', 'LK', true);
  -- دستگاه صندوق فعال (DEV1) و دستگاه در انتظار ثبت (DEV2)
  INSERT INTO core.device (tenant_id, id, company_id, branch_id, kind, name, public_key, status, activated_at, registered_by) VALUES
    (t, '30a00000-0000-7000-8000-0000000de001', '30a00000-0000-7000-8000-0000000000c1', '30a00000-0000-7000-8000-0000000000b1', 'pos',
     'صندوق یک', decode(repeat('ab', 32), 'hex'), 'active', now(), '30a00000-0000-7000-8000-00000000aa01');
  INSERT INTO core.device (tenant_id, id, company_id, branch_id, kind, name, status, enrollment_code_hash, enrollment_expires_at, registered_by) VALUES
    (t, '30a00000-0000-7000-8000-0000000de002', '30a00000-0000-7000-8000-0000000000c1', '30a00000-0000-7000-8000-0000000000b1', 'pos',
     'صندوق دو', 'pending', sha256('enroll'::bytea), now() + interval '1 day', '30a00000-0000-7000-8000-00000000aa01');
  -- سری شمارهٔ رسید صندوق دستگاه DEV1 (شمارهٔ دستگاهی = شمارهٔ فاکتور صندوق؛ RV-IT2-06)
  INSERT INTO core.number_series (tenant_id, id, company_id, code, name, doc_type, scope, branch_id, device_id, allocation, pattern, reset_policy)
  VALUES (t, '30a00000-0000-7000-8000-0000000de101', '30a00000-0000-7000-8000-0000000000c1', 'pos.ticket.dev1', 'رسید صندوق ۱', 'pos.ticket',
          'device', '30a00000-0000-7000-8000-0000000000b1', '30a00000-0000-7000-8000-0000000de001', 'device', 'D1-{seq}', 'never');
  -- بُعد شخص (در تولید: مشترک ledger.party_dimension روی parties.party.created)
  INSERT INTO ledger.dimension_value (tenant_id, dimension_type_id, slot, code, name, source_module, source_entity_id)
  SELECT t, dt.id, dt.slot, p.code, p.name, 'parties', p.id
    FROM parties.party p CROSS JOIN ledger.dimension_type dt WHERE dt.code = 'party' AND p.tenant_id = t;
END $$;
DO $$
BEGIN
  PERFORM public.c_ctx('B');
  PERFORM ledger.provision_tenant();
  INSERT INTO inventory.company_policy (tenant_id, company_id, effective_from) VALUES
    ('30b00000-0000-7000-8000-000000000001', '30b00000-0000-7000-8000-0000000000c1', '2026-03-21');
END $$;

-- ---------- کمکی‌های فروش و خرید (شبیه‌ساز سرویس؛ SECURITY INVOKER) ----------
CREATE OR REPLACE FUNCTION public.c_inv(p jsonb DEFAULT '{}') RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE r sales.invoice;
BEGIN
  r.tenant_id := core.current_tenant_id(); r.id := coalesce((p->>'id')::uuid, uuidv7());
  r.company_id := coalesce((p->>'company')::uuid, public.k('CA')); r.branch_id := coalesce((p->>'branch')::uuid, public.k('BA'));
  r.doc_kind := coalesce(p->>'kind', 'invoice'); r.status := 'draft'; r.doc_date := coalesce((p->>'date')::date, DATE '2026-05-10');
  r.number_source := 'server'; r.original_invoice_id := (p->>'original')::uuid; r.supersedes_invoice_id := (p->>'supersedes')::uuid;
  r.order_id := (p->>'order')::uuid;
  r.customer_party_id := coalesce((p->>'customer')::uuid, public.k('C2'));
  r.buyer_person_type := coalesce(p->>'buyer_type', 'legal');
  r.buyer_economic_code := CASE WHEN p ? 'buyer_eco' THEN p->>'buyer_eco' ELSE '14003778990' END;
  r.buyer_national_id := p->>'buyer_nid'; r.buyer_postal_code := p->>'buyer_postal';
  r.currency := 'IRR'; r.currency_minor := 0; r.exchange_rate := 1; r.prices_include_tax := false;
  r.settlement_method := coalesce(p->>'setm', 'credit'); r.cash_amount := (p->>'cash')::numeric; r.credit_amount := (p->>'credit')::numeric;
  r.stock_mode := coalesce(p->>'stock_mode', CASE WHEN r.doc_kind = 'correction' THEN 'none' ELSE 'immediate' END);
  r.warehouse_id := CASE WHEN r.stock_mode = 'immediate' THEN coalesce((p->>'wh')::uuid, public.k('W1')) END;
  r.gross_amount := 0; r.line_discount_total := 0; r.invoice_discount_mode := 'none'; r.invoice_discount_amount := 0;
  r.net_amount := 0; r.vat_amount := 0; r.other_tax_amount := 0; r.other_levy_amount := 0; r.total_amount := 0; r.total_base := 0;
  r.moadian_required := coalesce((p->>'moadian')::boolean, true); r.moadian_type := coalesce((p->>'inty')::smallint, 1);
  r.moadian_pattern := 1; r.moadian_extra := '{}'; r.tax_snapshot := '{"vat_rule":"test"}';
  r.channel := coalesce(p->>'channel', 'invoice'); r.gl_mode := coalesce(p->>'gl_mode', 'per_document'); r.gl_batch_id := (p->>'batch')::uuid;
  IF p ? 'device' THEN r.number_source := 'device'; r.device_id := (p->>'device')::uuid; r.pos_ticket_id := (p->>'ticket')::uuid; END IF;
  IF p ? 'currency' THEN r.currency := p->>'currency'; r.currency_minor := coalesce((p->>'minor')::smallint, 2); END IF;
  r.custom := '{}'; r.created_at := now(); r.updated_at := now(); r.row_version := 1;
  INSERT INTO sales.invoice SELECT r.*;
  RETURN r.id;
END $$;

CREATE OR REPLACE FUNCTION public.c_line(p_inv uuid, p_line_no int, p_sku text, p_qty numeric, p_price numeric, p jsonb DEFAULT '{}')
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE r sales.invoice_line; v_ld numeric := coalesce((p->>'ld')::numeric, 0); v_ia numeric := coalesce((p->>'ia')::numeric, 0);
BEGIN
  r.tenant_id := core.current_tenant_id(); r.id := coalesce((p->>'id')::uuid, uuidv7()); r.invoice_id := p_inv; r.line_no := p_line_no;
  r.item_id := public.k('I.' || p_sku); r.variant_id := public.k('V.' || p_sku);
  r.uom_id := (SELECT base_uom_id FROM catalog.v_sku WHERE variant_id = r.variant_id);
  r.qty := p_qty; r.qty_base := p_qty; r.unit_price := p_price; r.currency_minor := coalesce((p->>'minor')::smallint, 0);
  r.gross_amount := coalesce((p->>'gross')::numeric, trunc(p_qty * p_price, 0));
  r.line_discount_amount := v_ld; r.invoice_discount_alloc := v_ia; r.discount_amount := v_ld + v_ia;
  r.net_amount := r.gross_amount - r.discount_amount; r.tax_rounding := 'truncate'; r.vat_rate := coalesce((p->>'vat')::numeric, 10);
  r.vat_amount := coalesce((p->>'vam')::numeric, trunc(r.net_amount * r.vat_rate / 100, 0));
  r.other_tax_rate := coalesce((p->>'otr')::numeric, 0); r.other_tax_code := p->>'otc';
  r.other_tax_amount := trunc(r.net_amount * r.other_tax_rate / 100, 0); r.other_levy_rate := 0; r.other_levy_amount := 0;
  r.line_total := r.net_amount + r.vat_amount + r.other_tax_amount;
  r.sstid := CASE WHEN p ? 'no_sstid' THEN NULL ELSE '2710000138624' END; r.moadian_unit_code := '1627';
  r.pos_ticket_line_id := (p->>'pos_line')::uuid;
  r.price_source := coalesce(p->>'price_source', 'price_list'); r.original_line_id := (p->>'orig')::uuid;
  r.line_kind := coalesce(p->>'line_kind', 'goods'); r.warehouse_id := (p->>'wh')::uuid; r.bom_id := (p->>'bom')::uuid;
  r.delivery_line_id := (p->>'delivery_line')::uuid;
  IF p ? 'sstid' THEN r.sstid := p->>'sstid'; END IF;
  r.order_line_id := (p->>'order_line')::uuid; r.moadian_extra := '{}';
  INSERT INTO sales.invoice_line SELECT r.*;
  IF v_ld > 0 AND NOT p ? 'no_trace' THEN
    INSERT INTO sales.invoice_line_discount (tenant_id, line_id, seq, source, basis, amount) VALUES (r.tenant_id, r.id, 1, 'manual', 'amount', v_ld);
  END IF;
  IF v_ia > 0 AND NOT p ? 'no_trace' THEN
    INSERT INTO sales.invoice_line_discount (tenant_id, line_id, seq, source, basis, amount) VALUES (r.tenant_id, r.id, 2, 'invoice', 'amount', v_ia);
  END IF;
  RETURN r.id;
END $$;

-- جمع‌های سرسند = Σ سطرها (+ انحراف عمدی برای آزمون منفی)
CREATE OR REPLACE FUNCTION public.c_totals(p_inv uuid, p_adjust numeric DEFAULT 0) RETURNS void
LANGUAGE sql AS $$
  UPDATE sales.invoice i
     SET gross_amount = t.g + p_adjust, line_discount_total = t.ld,
         invoice_discount_mode = CASE WHEN t.ia > 0 THEN 'amount' ELSE 'none' END, invoice_discount_amount = t.ia,
         net_amount = t.g + p_adjust - t.ld - t.ia, vat_amount = t.v, other_tax_amount = t.ot,
         total_amount = t.tot + p_adjust, total_base = t.tot + p_adjust,
         credit_amount = CASE WHEN i.settlement_method = 'mixed' THEN t.tot + p_adjust - t.v - t.ot - i.cash_amount ELSE i.credit_amount END
    FROM (SELECT coalesce(sum(gross_amount), 0) g, coalesce(sum(line_discount_amount), 0) ld, coalesce(sum(invoice_discount_alloc), 0) ia,
                 coalesce(sum(vat_amount), 0) v, coalesce(sum(other_tax_amount), 0) ot, coalesce(sum(line_total), 0) tot
            FROM sales.invoice_line WHERE invoice_id = p_inv) t
   WHERE i.id = p_inv
$$;

-- سند فروش یک فاکتور از سرسند (مستقل از تابع پایگاه داده): بد دریافتنی (کل) و تخفیف / بس درآمد (ناخالص) و مالیات‌ها؛ برگشت قرینه
-- با sales.returns؛ اصلاحی فقط تفاوت با نسخهٔ قبل. p_off: دریافتنی و درآمد هر دو + p_off (تراز ولی نادرست).
CREATE OR REPLACE FUNCTION public.c_sales_jr(p_inv uuid, p_event text DEFAULT 'post', p_doc uuid DEFAULT NULL, p_off numeric DEFAULT 0)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE h sales.invoice; pv sales.invoice; s int; g numeric; d numeric; v numeric; ot numeric; tot numeric; sc numeric; mk numeric;
BEGIN
  SELECT * INTO h FROM sales.invoice WHERE id = p_inv;
  SELECT coalesce(sum(gross_amount) FILTER (WHERE line_kind = 'goods'), 0), coalesce(sum(gross_amount) FILTER (WHERE line_kind = 'service_charge'), 0),
         coalesce(sum(net_amount) FILTER (WHERE line_kind = 'installment_markup'), 0)
    INTO g, sc, mk FROM sales.invoice_line WHERE invoice_id = h.id;
  d := h.line_discount_total + h.invoice_discount_amount; v := h.vat_amount; ot := h.other_tax_amount; tot := h.total_base;
  s := CASE WHEN h.doc_kind = 'return' THEN -1 ELSE 1 END;
  IF h.doc_kind = 'correction' THEN
    SELECT * INTO pv FROM sales.invoice WHERE id = h.supersedes_invoice_id;
    g := g - (SELECT coalesce(sum(gross_amount) FILTER (WHERE line_kind = 'goods'), 0) FROM sales.invoice_line WHERE invoice_id = pv.id);
    sc := sc - (SELECT coalesce(sum(gross_amount) FILTER (WHERE line_kind = 'service_charge'), 0) FROM sales.invoice_line WHERE invoice_id = pv.id);
    d := d - (pv.line_discount_total + pv.invoice_discount_amount); v := v - pv.vat_amount; ot := ot - pv.other_tax_amount;
    tot := tot - pv.total_base;
  END IF;
  RETURN public.c_jr(h.company_id, h.doc_date, 'sales', 'sales.' || h.doc_kind, coalesce(p_doc, h.id), p_event, jsonb_build_array(
           jsonb_build_object('key', 'sales.receivable', 'dr', s * tot + p_off, 'party', h.customer_party_id),
           jsonb_build_object('key', 'sales.discount', 'dr', s * d),
           jsonb_build_object('key', CASE WHEN h.doc_kind = 'return' THEN 'sales.returns' ELSE 'sales.revenue' END, 'cr', s * g + p_off),
           jsonb_build_object('key', 'sales.service_charge', 'cr', s * sc),
           jsonb_build_object('key', 'sales.installment_unearned', 'cr', s * mk, 'party', h.customer_party_id),
           jsonb_build_object('key', 'tax.vat_payable', 'cr', s * v),
           jsonb_build_object('key', 'tax.other_tax_payable', 'cr', s * ot)));
END $$;

-- ثبت (شبیه سرویس): شماره، حرکت انبار، سند فروش و سند موجودی، تغییر وضعیت.
-- گزینه‌ها: skip_stock، no_gl، gl_other، gl_off، no_stock_gl، stock_gl_off، num_other، adjust، rule (قاعدهٔ حرکت برگشت)، src_other
CREATE OR REPLACE FUNCTION public.c_post(p_inv uuid, p jsonb DEFAULT '{}') RETURNS void
LANGUAGE plpgsql AS $$
DECLARE h sales.invoice; l record; n uuid; j uuid; sj uuid; src uuid;
BEGIN
  PERFORM public.c_totals(p_inv, coalesce((p->>'adjust')::numeric, 0));
  SELECT * INTO h FROM sales.invoice WHERE id = p_inv;
  n := public.c_num(h.company_id, 'sales.' || h.doc_kind, CASE WHEN p ? 'num_other' THEN uuidv7() ELSE h.id END);
  IF h.stock_mode = 'immediate' AND NOT p ? 'skip_stock' THEN
    FOR l IN SELECT x.* FROM sales.invoice_line x JOIN catalog.v_sku s ON s.variant_id = x.variant_id
              WHERE x.invoice_id = p_inv AND s.item_type = 'stock' ORDER BY x.line_no LOOP
      IF h.doc_kind = 'return' THEN
        SELECT m.id INTO src FROM inventory.stock_move m
         WHERE m.source_line_id = CASE WHEN p ? 'src_other' THEN (p->>'src_other')::uuid ELSE l.original_line_id END
           AND m.move_kind = 'sale_issue' AND m.reversal_of_move_id IS NULL LIMIT 1;
        PERFORM public.c_move(jsonb_build_object('company', h.company_id, 'wh', coalesce(l.warehouse_id, h.warehouse_id), 'item', l.item_id,
                'variant', l.variant_id, 'kind', 'sale_return', 'qty', l.qty_base, 'date', h.doc_date, 'module', 'sales',
                'doc_type', 'sales.return', 'doc', h.id, 'line', l.id, 'party', h.customer_party_id)
                || CASE WHEN p->>'rule' = 'input' THEN jsonb_build_object('rule', 'input', 'value', 1)
                        ELSE jsonb_build_object('rule', 'source', 'src', src) END);
      ELSE
        PERFORM public.c_move(jsonb_build_object('company', h.company_id, 'wh', coalesce(l.warehouse_id, h.warehouse_id), 'item', l.item_id,
                'variant', l.variant_id, 'kind', 'sale_issue', 'qty', -l.qty_base, 'date', h.doc_date, 'module', 'sales',
                'doc_type', 'sales.invoice', 'doc', h.id, 'line', l.id, 'party', h.customer_party_id));
      END IF;
    END LOOP;
  END IF;
  IF h.gl_mode = 'per_document' AND p ? 'dummy_gl' THEN
    j := public.c_journal(h.company_id, h.doc_date, 'sales', 'sales.' || h.doc_kind, h.id);
  ELSIF h.gl_mode = 'per_document' AND NOT p ? 'no_gl' THEN
    j := public.c_sales_jr(h.id, 'post', CASE WHEN p ? 'gl_other' THEN uuidv7() END, coalesce((p->>'gl_off')::numeric, 0));
    IF NOT p ? 'no_stock_gl' THEN
      sj := public.c_stock_jr(h.company_id, h.doc_date, 'sales.' || h.doc_kind, h.id, ARRAY[h.id], 'post', false,
                              coalesce((p->>'stock_gl_off')::numeric, 0));
    END IF;
  END IF;
  UPDATE sales.invoice SET status = 'posted', number_issued_id = n, doc_no = public.c_no(n), issued_at = now(), posted_at = now(),
         gl_journal_id = j, stock_journal_id = sj WHERE id = p_inv;
END $$;

-- ابطال: برگشت همهٔ حرکت‌ها + برگشت اسناد فروش و موجودی (گزینه‌ها: skip_stock، no_gl، gl_other، no_reverse)
CREATE OR REPLACE FUNCTION public.c_cancel(p_inv uuid, p jsonb DEFAULT '{}') RETURNS void
LANGUAGE plpgsql AS $$
DECLARE h sales.invoice; m inventory.stock_move; j uuid;
BEGIN
  SELECT * INTO h FROM sales.invoice WHERE id = p_inv;
  IF NOT p ? 'skip_stock' THEN
    FOR m IN SELECT * FROM inventory.stock_move WHERE source_doc_id = p_inv AND reversal_of_move_id IS NULL ORDER BY posting_seq DESC LOOP
      PERFORM public.c_move(jsonb_build_object('company', m.company_id, 'wh', m.warehouse_id, 'item', m.item_id, 'variant', m.variant_id,
              'kind', m.move_kind, 'qty', -m.qty_base, 'date', m.move_date, 'rev', m.id, 'module', 'sales', 'doc_type', m.source_doc_type,
              'doc', m.source_doc_id, 'line', m.source_line_id, 'batch', m.batch_id));
    END LOOP;
  END IF;
  IF p ? 'gl_other' THEN
    j := public.c_journal(h.company_id, h.doc_date, 'sales', 'sales.invoice', uuidv7(), 'cancel');
  ELSIF p ? 'no_reverse' THEN
    j := public.c_journal(h.company_id, h.doc_date, 'sales', 'sales.' || h.doc_kind, h.id, 'cancel');
  ELSIF NOT p ? 'no_gl' THEN
    j := public.c_rev_jr(h.gl_journal_id, h.doc_date);
    PERFORM public.c_rev_jr(h.stock_journal_id, h.doc_date);
  END IF;
  UPDATE sales.invoice SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'اشتباه در صدور', cancel_journal_id = j WHERE id = p_inv;
END $$;
GRANT EXECUTE ON FUNCTION public.c_inv(jsonb), public.c_line(uuid, int, text, numeric, numeric, jsonb), public.c_totals(uuid, numeric),
  public.c_post(uuid, jsonb), public.c_cancel(uuid, jsonb), public.c_sales_jr(uuid, text, uuid, numeric) TO hk_app;

-- پیوست آزمایشی برای دستهٔ کارپوشه
INSERT INTO core.attachment (tenant_id, id, company_id, storage_backend, bucket, object_key, file_name, encryption_key_ref)
VALUES ('30a00000-0000-7000-8000-000000000001', '30a00000-0000-7000-8000-0000000a7001', '30a00000-0000-7000-8000-0000000000c1', 's3', 'hk',
        't/30a00000-0000-7000-8000-000000000001/2026/05/30a00000-0000-7000-8000-0000000a7001', 'karpoosheh.xlsx', 'dek://test');

-- فاکتور خرید با یک سطر X (۱۰۰٬۰۰۰ ریال) و هزینهٔ جانبی اختیاری. گزینه‌ها: id, line_id, kind, original, orig_line, qty, charge,
-- no_alloc, alloc_line, supno, taxid, supplier, channel, unit, adjust, post, skip_stock, date
CREATE OR REPLACE FUNCTION public.c_pinv(p jsonb DEFAULT '{}') RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid := coalesce((p->>'id')::uuid, uuidv7()); l uuid := coalesce((p->>'line_id')::uuid, uuidv7()); c uuid; n uuid; j uuid; sj uuid;
        q numeric := coalesce((p->>'qty')::numeric, 10); v_charge numeric := coalesce((p->>'charge')::numeric, 0);
        v_kind text := coalesce(p->>'kind', 'invoice'); v_date date := coalesce((p->>'date')::date, DATE '2026-05-05'); v_src uuid;
        v_adj numeric := coalesce((p->>'adjust')::numeric, 0);
BEGIN
  INSERT INTO purchase.invoice (tenant_id, id, company_id, branch_id, doc_kind, doc_date, supplier_party_id, supplier_invoice_no, supplier_taxid,
                                original_invoice_id, currency, currency_minor, stock_mode, warehouse_id, channel, amount_unit)
  VALUES (core.current_tenant_id(), v_id, public.k('CA'), public.k('BA'), v_kind, v_date, coalesce((p->>'supplier')::uuid, public.k('S1')),
          CASE WHEN v_kind = 'invoice' THEN coalesce(p->>'supno', 'F-' || substr(v_id::text, 25)) END, p->>'taxid', (p->>'original')::uuid,
          'IRR', 0, 'immediate', public.k('W1'), coalesce(p->>'channel', 'manual'), (p->>'unit')::core.amount_unit);
  INSERT INTO purchase.invoice_line (tenant_id, id, invoice_id, line_no, item_id, variant_id, uom_id, qty, qty_base, unit_price,
                                     gross_amount, net_amount, vat_rate, vat_amount, line_total, original_line_id)
  VALUES (core.current_tenant_id(), l, v_id, 1, public.k('I.X'), public.k('V.X'), public.k('PCS'), q, q, 100000,
          q * 100000, q * 100000, 10, q * 10000, q * 110000, (p->>'orig_line')::uuid);
  IF v_charge > 0 THEN
    c := uuidv7();
    INSERT INTO purchase.invoice_charge (tenant_id, id, invoice_id, line_no, charge_kind, amount, capitalize)
    VALUES (core.current_tenant_id(), c, v_id, 1, 'freight', v_charge, true);
    IF NOT p ? 'no_alloc' THEN
      INSERT INTO purchase.cost_allocation (tenant_id, charge_id, target_invoice_line_id, basis_value, amount, amount_base)
      VALUES (core.current_tenant_id(), c, coalesce((p->>'alloc_line')::uuid, l), q * 100000, v_charge, v_charge);
    END IF;
  END IF;
  UPDATE purchase.invoice SET gross_amount = q * 100000 + v_adj, net_amount = q * 100000 + v_adj, vat_amount = q * 10000,
         charges_amount = v_charge, total_amount = q * 110000 + v_adj + v_charge, total_base = q * 110000 + v_adj + v_charge
   WHERE id = v_id;
  IF p ? 'post' THEN
    IF NOT p ? 'skip_stock' THEN
      IF v_kind = 'return' THEN
        SELECT m.id INTO v_src FROM inventory.stock_move m WHERE m.source_line_id = (p->>'orig_line')::uuid AND m.move_kind = 'receipt' LIMIT 1;
        PERFORM public.c_move(jsonb_build_object('company', public.k('CA'), 'wh', public.k('W1'), 'item', public.k('I.X'), 'variant', public.k('V.X'),
                'kind', 'purchase_return', 'qty', -q, 'date', v_date, 'module', 'purchase',
                'doc_type', 'purchase.return', 'doc', v_id, 'line', l)
                || CASE WHEN p->>'rule' = 'pool_out' THEN '{"rule":"pool_out"}'::jsonb ELSE jsonb_build_object('rule', 'source', 'src', v_src) END);
      ELSE
        PERFORM public.c_move(jsonb_build_object('company', public.k('CA'), 'wh', public.k('W1'), 'item', public.k('I.X'), 'variant', public.k('V.X'),
                'kind', 'receipt', 'qty', q, 'date', v_date, 'value', q * 100000 + v_charge + coalesce((p->>'value_off')::numeric, 0), 'module', 'purchase',
                'doc_type', 'purchase.invoice', 'doc', v_id, 'line', l));
      END IF;
    END IF;
    n := public.c_num(public.k('CA'), 'purchase.' || v_kind, v_id);
    -- سند خرید: بد GRNI (خالص + هزینهٔ سرمایه‌ای) و مالیات خرید / بس پرداختنی (کل)؛ برگشت قرینه. سند موجودی جدا (RV-IT2-01).
    j := public.c_jr(public.k('CA'), v_date, 'purchase', 'purchase.' || v_kind, CASE WHEN p ? 'gl_other' THEN uuidv7() ELSE v_id END, 'post',
           jsonb_build_array(
             jsonb_build_object('key', 'purchase.grni', 'dr', (CASE WHEN v_kind = 'return' THEN -1 ELSE 1 END) * (q * 100000 + v_adj + v_charge)),
             jsonb_build_object('key', 'tax.vat_receivable', 'dr', (CASE WHEN v_kind = 'return' THEN -1 ELSE 1 END) * q * 10000),
             jsonb_build_object('key', 'purchase.payable', 'cr', (CASE WHEN v_kind = 'return' THEN -1 ELSE 1 END) * (q * 110000 + v_adj + v_charge)
                                                                  + coalesce((p->>'gl_off')::numeric, 0),
                                'party', coalesce((p->>'supplier')::uuid, public.k('S1'))),
             jsonb_build_object('key', 'purchase.grni', 'dr', coalesce((p->>'gl_off')::numeric, 0))));
    IF NOT p ? 'no_stock_gl' THEN
      sj := public.c_stock_jr(public.k('CA'), v_date, 'purchase.' || v_kind, v_id, ARRAY[v_id]);
    END IF;
    UPDATE purchase.invoice SET status = 'posted', posted_at = now(), number_issued_id = n, doc_no = public.c_no(n),
           gl_status = 'posted', gl_journal_id = j, stock_journal_id = sj WHERE id = v_id;
  END IF;
  RETURN v_id;
END $$;
GRANT EXECUTE ON FUNCTION public.c_pinv(jsonb) TO hk_app;

-- =====================================================================
-- بخش ۲: ادعاها با نقش برنامه
-- =====================================================================
SET ROLE hk_app;
DO $$ BEGIN PERFORM c_ok(current_user = 'hk_app', 'running as hk_app'); END $$;

-- ---------- T01 (INV-INV-01/02): سیاست و انبار ----------
DO $$
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_err($q$SELECT c_mv('CA','W1','X','receipt',1,'2026-01-01','{"value":10}')$q$, 'HK_INV_POLICY_MISSING', 'T01 move before first policy');
  PERFORM c_err($q$INSERT INTO inventory.warehouse (tenant_id, company_id, branch_id, code, name, kind, negative_policy)
                  VALUES (k('A'), k('CA'), NULL, 'TX', 'در راه بد', 'transit', 'allow')$q$, 'warehouse_transit_blocks_negative', 'T01 transit must block negative');
  PERFORM c_err($q$INSERT INTO inventory.warehouse (tenant_id, company_id, code, name) VALUES (k('A'), k('CA'), 'NB', 'بی‌شعبه')$q$,
                'warehouse_branch_required', 'T01 standard warehouse needs a branch');
  PERFORM c_err($q$INSERT INTO inventory.warehouse (tenant_id, company_id, code, name, kind, negative_policy, is_default_transit)
                  VALUES (k('A'), k('CA'), 'WT2', 'در راه دوم', 'transit', 'block', true)$q$, '23505', 'T01 one default transit per company');
  PERFORM c_err($q$INSERT INTO inventory.warehouse (tenant_id, company_id, branch_id, code, name)
                  VALUES (k('A'), k('CA'), k('BF'), 'XB', 'شعبهٔ شرکت دیگر')$q$, '23503', 'T01 branch of another company');
END $$;

-- ---------- T02 (INV-INV-03..08): حرکت، میانگین موزون، علامت، قاعده، واحد، بچ، در راه، تغییرناپذیری ----------
DO $$
DECLARE r1 uuid; r2 uuid; i1 uuid; r3 uuid; p inventory.cost_pool;
BEGIN
  PERFORM c_ctx('A');
  r1 := c_mv('CA','W1','X','receipt',10,'2026-04-01','{"value":1000}');
  r2 := c_mv('CA','W1','X','receipt',10,'2026-04-02','{"cost":200}');
  i1 := c_mv('CA','W1','X','sale_issue',-5,'2026-04-03', jsonb_build_object('id', '30a00000-0000-7000-8000-0000000f0001'));
  PERFORM c_ok(c_mval(r1) = 1000 AND c_mval(r2) = 2000, 'T02 receipt values (input value / input unit cost)');
  PERFORM c_ok(c_mval(i1) = -750, 'T02 moving-average issue = 5 × 150');
  p := c_pool(i1);
  PERFORM c_ok(p.qty = 15 AND p.value = 2250 AND p.method = 'moving_average' AND p.warehouse_id IS NULL, 'T02 company-scope pool state');
  PERFORM c_ok((SELECT posting_seq FROM inventory.stock_move WHERE id = r2) > (SELECT posting_seq FROM inventory.stock_move WHERE id = r1), 'T02 posting_seq increases');
  PERFORM c_ok((SELECT qty FROM inventory.stock_balance WHERE warehouse_id = k('W1') AND variant_id = k('V.X')) = 15, 'T02 stock balance');
  PERFORM c_ok((SELECT branch_id FROM inventory.stock_move WHERE id = r1) = k('BA'), 'T02 branch taken from warehouse');
  -- واحد فرعی: کارتن = ۱۲
  r3 := c_mv('CA','W1','X','receipt',12,'2026-04-04', jsonb_build_object('uom', k('CTN'), 'qty_uom', 1, 'value', 1800));
  PERFORM c_ok((c_pool(r3)).qty = 27 AND (c_pool(r3)).value = 4050, 'T02 carton receipt converted to base');
  PERFORM c_err($q$SELECT c_mv('CA','W1','X','receipt',10,'2026-04-04', jsonb_build_object('uom', k('CTN'), 'qty_uom', 1, 'value', 10))$q$,
                'HK_INV_MOVE_UOM', 'T02 qty_base must equal qty_uom × factor');
  PERFORM c_err($q$SELECT c_mv('CA','W1','X','receipt',-1,'2026-04-04','{"value":10}')$q$, 'HK_INV_MOVE_SIGN', 'T02 receipt must be positive');
  PERFORM c_err($q$SELECT c_mv('CA','W1','X','sale_issue',1,'2026-04-04')$q$, 'HK_INV_MOVE_SIGN', 'T02 issue must be negative');
  PERFORM c_err($q$SELECT c_mv('CA','W1','X','receipt',1,'2026-04-04','{"rule":"pool_in"}')$q$, 'HK_INV_MOVE_RULE', 'T02 receipt rule must be input');
  PERFORM c_err($q$SELECT c_mv('CA','W1','X','receipt',1,'2026-04-04')$q$, 'stock_move_input_shape', 'T02 input rule needs a cost');
  PERFORM c_err($q$SELECT c_mv('CA','W1','LATTE','receipt',1,'2026-04-04','{"value":1}')$q$, 'HK_INV_NOT_STOCK_ITEM', 'T02 non-stock item has no moves');
  PERFORM c_err($q$SELECT c_mv('CA','W1','MILK','receipt',1,'2026-04-04','{"value":1}')$q$, 'HK_INV_BATCH_REQUIRED', 'T02 batch item needs batch');
  PERFORM c_err($q$SELECT c_mv('CA','WT','X','receipt',1,'2026-04-04','{"value":1}')$q$, 'HK_INV_TRANSIT_KIND', 'T02 transit only for transfers');
  PERFORM c_err(format($q$SELECT c_move(jsonb_build_object('company',k('CA'),'wh',k('W1'),'item',k('I.X'),'variant',k('V.TV'),'kind','receipt','qty',1,'date','2026-04-04','value',1))$q$),
                'HK_INV_SKU_NOT_FOUND', 'T02 variant must belong to item');
  PERFORM c_err($q$SELECT c_mv('CA','F1','X','receipt',1,'2026-04-04','{"value":1}')$q$, '23503', 'T02 warehouse of another company');
  PERFORM c_err(format('UPDATE inventory.stock_move SET qty_base = 1 WHERE id = %L', r1), '42501', 'T02 stock_move has no UPDATE grant');
  PERFORM c_err(format('DELETE FROM inventory.stock_move WHERE id = %L', r1), '42501', 'T02 stock_move has no DELETE grant');
  PERFORM c_err(format($q$INSERT INTO inventory.valuation_layer (tenant_id, company_id, pool_id, move_id, layer_kind, is_derived, reason, value, cost_status, gl_date)
                         SELECT tenant_id, company_id, pool_id, id, 'adjustment', false, 'landed_cost', 1, 'known', move_date FROM inventory.stock_move WHERE id = %L$q$, r1),
                '42501', 'T02 valuation layers are engine-only');
  PERFORM c_err(format('UPDATE inventory.cost_pool SET value = 0 WHERE id = %L', p.id), '42501', 'T02 cost pool is engine-only');
  PERFORM c_err('UPDATE inventory.stock_balance SET qty = 0', '42501', 'T02 stock balance is engine-only');
  PERFORM c_err(format($q$SELECT inventory.valuate(m, 'initial', NULL, NULL) FROM inventory.stock_move m WHERE m.id = %L$q$, r1),
                '42501', 'T02 internal engine function is not executable by hk_app');
  PERFORM c_ok(NOT EXISTS (SELECT 1 FROM inventory.verify_derived(k('CA'))), 'T02 derived state consistent');
  PERFORM c_ok(inventory.verify_pool_replay(p.id) = 0, 'T02 full replay reproduces layers');
END $$;

-- ---------- T03 (INV-INV-09/10): منفی مجاز با هشدار، بهای نامعلوم، تسویهٔ کسری (میانگین) ----------
DO $$
DECLARE i uuid; r uuid; p inventory.cost_pool;
BEGIN
  PERFORM c_ctx('A');
  i := c_mv('CA','W1','NOD','sale_issue',-3,'2026-04-01');
  PERFORM c_ok(c_mval(i) = 0 AND (SELECT cost_status FROM inventory.valuation_layer WHERE move_id = i) = 'unknown', 'T03 issue from empty pool is unknown, not invented');
  PERFORM c_ok((SELECT count(*) FROM inventory.stock_exception WHERE move_id = i AND kind IN ('negative_stock','unknown_cost')) = 2,
               'T03 negative + unknown-cost exceptions recorded');
  r := c_mv('CA','W1','NOD','receipt',5,'2026-04-02','{"value":500}');
  PERFORM c_ok((SELECT value FROM inventory.valuation_layer WHERE move_id = r AND layer_kind = 'settlement') = -300, 'T03 settlement layer for deficit');
  p := c_pool(r);
  PERFORM c_ok(p.qty = 2 AND p.value = 200, 'T03 pool after settlement = 2 × 100');
  PERFORM c_ok(inventory.verify_pool_replay(p.id) = 0, 'T03 replay reproduces settlement');
END $$;

-- ---------- T04 (INV-INV-11): FIFO با کسری و تسویه (CF، استخر انبار) ----------
DO $$
DECLARE r1 uuid; r2 uuid; i1 uuid; i2 uuid; r3 uuid; p inventory.cost_pool;
BEGIN
  PERFORM c_ctx('A');
  r1 := c_mv('CF','F1','X','receipt',10,'2026-04-01','{"value":1000}');
  r2 := c_mv('CF','F1','X','receipt',10,'2026-04-02','{"value":2000}');
  i1 := c_mv('CF','F1','X','sale_issue',-15,'2026-04-03');
  PERFORM c_ok(c_mval(i1) = -2000, 'T04 FIFO issue 10×100 + 5×200');
  PERFORM c_ok(jsonb_array_length((SELECT fifo_detail FROM inventory.valuation_layer WHERE move_id = i1)) = 2, 'T04 fifo detail lists consumed layers');
  PERFORM c_ok((c_pool(i1)).warehouse_id = k('F1') AND (c_pool(i1)).method = 'fifo', 'T04 warehouse-scope FIFO pool');
  i2 := c_mv('CF','F1','X','sale_issue',-10,'2026-04-04');
  PERFORM c_ok(c_mval(i2) = -2000 AND (SELECT cost_status FROM inventory.valuation_layer WHERE move_id = i2) = 'estimated',
               'T04 deficit valued at last cost (estimated)');
  PERFORM c_ok((c_pool(i2)).deficit_qty = 5 AND (c_pool(i2)).deficit_value = 1000, 'T04 deficit tracked');
  r3 := c_mv('CF','F1','X','receipt',10,'2026-04-05','{"value":3000}');
  PERFORM c_ok((SELECT value FROM inventory.valuation_layer WHERE move_id = r3 AND layer_kind = 'settlement') = -500, 'T04 FIFO settlement 1000 − 1500');
  p := c_pool(r3);
  PERFORM c_ok(p.qty = 5 AND p.value = 1500 AND p.deficit_qty = 0, 'T04 pool after replenishment');
  PERFORM c_ok((SELECT sum(qty_remaining) FROM inventory.fifo_layer WHERE pool_id = p.id) = 5, 'T04 queue holds 5');
  PERFORM c_ok(inventory.verify_pool_replay(p.id) = 0, 'T04 replay reproduces FIFO');
END $$;

-- ---------- T05 (INV-INV-12/13): ثبت پس‌تاریخ و بازارزیابی idempotent ----------
DO $$
DECLARE r1 uuid; i1 uuid; b uuid; run uuid; n int; p inventory.cost_pool; b2 uuid;
BEGIN
  PERFORM c_ctx('A');
  r1 := c_mv('CA','W1','SYR','receipt',10,'2026-04-10', jsonb_build_object('value',1000,'id','30a00000-0000-7000-8000-0000000f0010'));
  i1 := c_mv('CA','W1','SYR','sale_issue',-4,'2026-04-12', jsonb_build_object('id','30a00000-0000-7000-8000-0000000f0011'));
  PERFORM c_ok(c_mval(i1) = -400, 'T05 issue before backdating');
  b := c_mv('CA','W1','SYR','receipt',10,'2026-04-11','{"value":3000}');
  p := c_pool(b);
  PERFORM c_ok(p.dirty_from_date = DATE '2026-04-11', 'T05 backdated move marks the pool dirty');
  INSERT INTO inventory.repost_run (tenant_id, company_id, trigger_reason, gl_floor_date) VALUES (k('A'), k('CA'), 'backdated', '2026-04-01')
  RETURNING id INTO run;
  n := inventory.repost_pool(p.id, run, '2026-04-01');
  PERFORM c_ok(n = 1 AND c_mval(i1) = -800, 'T05 repost adds one delta: issue now 4 × 200');
  PERFORM c_ok((c_pool(b)).dirty_from_date IS NULL AND (c_pool(b)).qty = 16 AND (c_pool(b)).value = 3200, 'T05 pool clean after repost');
  PERFORM c_ok(inventory.repost_pool(p.id, run, '2026-04-01') = 0, 'T05 repost of a clean pool is a no-op');
  PERFORM c_ok(inventory.verify_pool_replay(p.id) = 0, 'T05 idempotent: full replay adds nothing');
  PERFORM c_ok((SELECT layers_added FROM inventory.repost_run WHERE id = run) = 1, 'T05 run counters');
  -- کف تاریخ GL: اصلاح در دورهٔ بسته به نخستین تاریخ باز می‌رود
  b2 := c_mv('CA','W1','SYR','receipt',4,'2026-04-09','{"value":4000}');
  INSERT INTO inventory.repost_run (tenant_id, company_id, trigger_reason, gl_floor_date) VALUES (k('A'), k('CA'), 'backdated', '2026-05-01')
  RETURNING id INTO run;
  PERFORM inventory.repost_pool(p.id, run, '2026-05-01');
  PERFORM c_ok((SELECT gl_date FROM inventory.valuation_layer WHERE move_id = i1 AND repost_run_id = run) = DATE '2026-05-01', 'T05 GL floor date applied');
  PERFORM c_err(format('SELECT inventory.repost_pool(%L, uuidv7(), %L)', p.id, '2026-05-01'), 'HK_INV_REPOST_RUN', 'T05 repost needs a running run');
  UPDATE inventory.repost_run SET status = 'completed', finished_at = now() WHERE id = run;
  PERFORM c_err(format('SELECT inventory.repost_pool(%L, %L, %L)', p.id, run, '2026-05-01'), 'HK_INV_REPOST_RUN', 'T05 completed run cannot be reused');
END $$;

-- ---------- T06 (INV-INV-14): تعدیل بهای ثابت (هزینهٔ جانبی) ----------
DO $$
DECLARE r1 uuid := '30a00000-0000-7000-8000-0000000f0010'; i1 uuid := '30a00000-0000-7000-8000-0000000f0011'; run uuid; v_before numeric;
BEGIN
  PERFORM c_ctx('A');
  v_before := c_mval(i1);
  PERFORM inventory.add_cost_adjustment(r1, 1000, 'landed_cost', 'purchase', 'purchase.invoice', uuidv7(), NULL);
  PERFORM c_ok((c_pool(r1)).dirty_from_date = DATE '2026-04-10', 'T06 fixed adjustment dirties the pool from the receipt');
  INSERT INTO inventory.repost_run (tenant_id, company_id, trigger_reason, gl_floor_date) VALUES (k('A'), k('CA'), 'cost_adjustment', '2026-04-01')
  RETURNING id INTO run;
  PERFORM inventory.repost_pool((c_pool(r1)).id, run, '2026-04-01');
  PERFORM c_ok(c_mval(i1) < v_before, 'T06 landed cost flows to the later issue');
  PERFORM c_ok(inventory.verify_pool_replay((c_pool(r1)).id) = 0, 'T06 replay consistent after adjustment');
  PERFORM c_err(format($q$SELECT inventory.add_cost_adjustment(%L, 10, 'landed_cost', 'purchase', 'purchase.invoice', uuidv7(), NULL)$q$, i1),
                'HK_INV_ADJUST_TARGET', 'T06 adjustment only on incoming input moves');
  PERFORM c_err(format($q$SELECT inventory.add_cost_adjustment(%L, 0, 'landed_cost', 'purchase', 'purchase.invoice', uuidv7(), NULL)$q$, r1),
                'HK_INV_ADJUST_AMOUNT', 'T06 zero delta rejected');
  PERFORM c_err(format($q$SELECT inventory.add_cost_adjustment(%L, 1.5, 'landed_cost', 'purchase', 'purchase.invoice', uuidv7(), NULL)$q$, r1),
                'HK_INV_ADJUST_AMOUNT', 'T06 delta must respect the currency minor unit');
  PERFORM c_err(format($q$SELECT inventory.add_cost_adjustment(%L, 10, 'repost', 'purchase', 'purchase.invoice', uuidv7(), NULL)$q$, r1),
                'HK_INV_ADJUST_REASON', 'T06 only fixed reasons');
  PERFORM c_err(format($q$SELECT inventory.add_cost_adjustment(%L, -999999, 'price_difference', 'purchase', 'purchase.invoice', uuidv7(), NULL)$q$, r1),
                'HK_INV_ADJUST_NEGATIVE', 'T06 incoming value cannot become negative');
END $$;

-- ---------- T07 (INV-INV-15/16): سیاست block (جاری و پس‌تاریخ) و صندوق آفلاین ----------
DO $$
DECLARE o uuid;
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_mv('CA','W2','NOD','receipt',2,'2026-04-05','{"value":300}');
  PERFORM c_err($q$SELECT c_mv('CA','W2','NOD','sale_issue',-3,'2026-04-06')$q$, 'HK_INV_NEGATIVE_STOCK', 'T07 block warehouse rejects negative');
  PERFORM c_mv('CA','W2','NOD','receipt',10,'2026-04-25','{"value":1000}');
  PERFORM c_mv('CA','W2','NOD','sale_issue',-1,'2026-04-20');
  PERFORM c_err($q$SELECT c_mv('CA','W2','NOD','sale_issue',-2,'2026-04-21')$q$, 'HK_INV_NEGATIVE_STOCK',
                'T07 backdated issue that makes a past point negative is rejected');
  PERFORM c_mv('CA','W2','NOD','sale_issue',-1,'2026-04-21');
  o := c_mv('CA','W2','NOD','sale_issue',-20,'2026-04-26','{"origin":"offline_device"}');
  PERFORM c_ok(EXISTS (SELECT 1 FROM inventory.stock_exception WHERE move_id = o AND kind = 'negative_stock'), 'T07 offline sale accepted with exception');
  PERFORM c_err($q$SELECT c_mv('CA','WT','NOD','transfer_out',-1,'2026-04-26','{"origin":"offline_device"}')$q$, 'HK_INV_NEGATIVE_STOCK',
                'T07 transit never goes negative, even offline');
END $$;

-- ---------- T08 (INV-INV-17): برگشت حرکت (ابطال) ----------
DO $$
DECLARE i1 uuid := '30a00000-0000-7000-8000-0000000f0001'; rv uuid;
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_err(format($q$SELECT c_mv('CA','W1','X','sale_issue',5,'2026-04-04', jsonb_build_object('rev', %L::uuid))$q$, i1),
                'HK_INV_REVERSAL_MISMATCH', 'T08 reversal keeps the original date');
  PERFORM c_err(format($q$SELECT c_mv('CA','W1','X','sale_issue',4,'2026-04-03', jsonb_build_object('rev', %L::uuid))$q$, i1),
                'HK_INV_REVERSAL_MISMATCH', 'T08 reversal negates the full quantity');
  rv := c_mv('CA','W1','X','sale_issue',5,'2026-04-03', jsonb_build_object('rev', i1));
  PERFORM c_ok(c_mval(rv) = -c_mval(i1), 'T08 reversal value is the exact negation');
  PERFORM c_err(format($q$SELECT c_mv('CA','W1','X','sale_issue',5,'2026-04-03', jsonb_build_object('rev', %L::uuid))$q$, i1),
                '23505', 'T08 one reversal per move');
  PERFORM c_err(format($q$SELECT c_mv('CA','W1','X','sale_issue',5,'2026-04-03', jsonb_build_object('rev', %L::uuid))$q$, rv),
                'HK_INV_REVERSAL_MISMATCH', 'T08 a reversal is not reversible');
  PERFORM c_err(format($q$SELECT c_mv('CA','W1','X','sale_issue',-5,'2026-04-03', jsonb_build_object('rev', %L::uuid))$q$, rv),
                'HK_INV_MOVE_SIGN', 'T08 reversal quantity has the opposite sign');
  PERFORM c_err(format($q$SELECT c_mv('CA','W1','X','sale_issue',5,'2026-04-03', jsonb_build_object('rev', %L::uuid, 'acct', (SELECT id FROM ledger.account WHERE company_id = k('CA') AND code = '1402')))$q$, i1),
                'HK_INV_REVERSAL_MISMATCH', 'T08 reversal keeps the GL inventory account of the original');
END $$;

-- ---------- T09 (INV-INV-18): افتتاحیهٔ انبار یکتا و نخستین ----------
DO $$
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_mv('CF','F2','X','opening',5,'2026-03-21','{"value":500}');
  PERFORM c_err($q$SELECT c_mv('CF','F2','X','opening',5,'2026-03-21','{"value":500}')$q$, 'HK_INV_OPENING_DUPLICATE', 'T09 opening repeated for the same key (Sepidar trap)');
  PERFORM c_mv('CF','F2','SYR','opening',1,'2026-04-01','{"value":100}');
  PERFORM c_err($q$SELECT c_mv('CF','F2','SYR','receipt',1,'2026-03-25','{"value":1}')$q$, 'HK_INV_BEFORE_OPENING', 'T09 no move before opening');
  PERFORM c_err($q$SELECT c_mv('CF','F1','X','opening',1,'2026-04-10','{"value":1}')$q$, 'HK_INV_OPENING_NOT_FIRST', 'T09 opening after other moves');
  PERFORM c_ok((SELECT (c_pool(id)).warehouse_id FROM inventory.stock_move WHERE move_kind = 'opening' AND warehouse_id = k('F2') AND variant_id = k('V.X')) = k('F2'), 'T09 opening pool');
END $$;
DO $$
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_mv('CF','F1','SYR','opening',1,'2026-03-21','{"value":100}');
END $$;
DO $$
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_err($q$SELECT c_mv('CF','F1','SYR','opening',1,'2026-03-22','{"value":100}')$q$, 'HK_INV_OPENING_DUPLICATE', 'T09 second opening rejected (committed)');
END $$;

-- ---------- T10 (INV-INV-19..22): سریال: وضعیت، تعداد، تعارض آفلاین، گارانتی ----------
DO $$
DECLARE r uuid; i uuid; o uuid;
BEGIN
  PERFORM c_ctx('A');
  INSERT INTO inventory.serial (tenant_id, id, item_id, variant_id, serial_no) VALUES
    (k('A'), '30a00000-0000-7000-8000-0000000e0001', k('I.TV'), k('V.TV'), 'SN001'),
    (k('A'), '30a00000-0000-7000-8000-0000000e0002', k('I.TV'), k('V.TV'), 'SN002'),
    (k('A'), '30a00000-0000-7000-8000-0000000e0003', k('I.TV'), k('V.TV'), 'SN003');
  r := c_mv('CA','W1','TV','receipt',2,'2026-04-01','{"value":20000000}');
  INSERT INTO inventory.serial_move (tenant_id, move_id, serial_id) VALUES
    (k('A'), r, '30a00000-0000-7000-8000-0000000e0001'), (k('A'), r, '30a00000-0000-7000-8000-0000000e0002');
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM c_ok((SELECT count(*) FROM inventory.serial WHERE status = 'in_stock' AND warehouse_id = k('W1')) = 2, 'T10 received serials in stock');
  PERFORM c_err($q$WITH m AS (SELECT c_mv('CA','W1','TV','receipt',2,'2026-04-02','{"value":2}') AS id)
                  INSERT INTO inventory.serial_move (tenant_id, move_id, serial_id) SELECT k('A'), m.id, '30a00000-0000-7000-8000-0000000e0003' FROM m$q$,
                'HK_INV_SERIAL_COUNT', 'T10 serial count must equal quantity');
  PERFORM c_err($q$WITH m AS (SELECT c_mv('CA','W1','TV','sale_issue',-1,'2026-04-02') AS id)
                  INSERT INTO inventory.serial_move (tenant_id, move_id, serial_id) SELECT k('A'), m.id, '30a00000-0000-7000-8000-0000000e0003' FROM m$q$,
                'HK_INV_SERIAL_STATE', 'T10 cannot issue a serial that is not in stock');
  PERFORM c_err($q$WITH m AS (SELECT c_mv('CA','W1','TV','receipt',1,'2026-04-02','{"value":2}') AS id)
                  INSERT INTO inventory.serial_move (tenant_id, move_id, serial_id) SELECT k('A'), m.id, '30a00000-0000-7000-8000-0000000e0001' FROM m$q$,
                'HK_INV_SERIAL_STATE', 'T10 cannot receive a serial already in stock');
  i := c_mv('CA','W1','TV','sale_issue',-1,'2026-04-02', jsonb_build_object('party', k('C1')));
  INSERT INTO inventory.serial_move (tenant_id, move_id, serial_id) VALUES (k('A'), i, '30a00000-0000-7000-8000-0000000e0001');
  PERFORM c_ok((SELECT status = 'out' AND warranty_start = DATE '2026-04-02' AND warranty_end = DATE '2026-04-02' + 365 AND sold_to_party_id = k('C1')
                  FROM inventory.serial WHERE id = '30a00000-0000-7000-8000-0000000e0001'), 'T10 sale sets warranty and buyer');
  o := c_mv('CA','W1','TV','sale_issue',-1,'2026-04-03','{"origin":"offline_device"}');
  INSERT INTO inventory.serial_move (tenant_id, move_id, serial_id) VALUES (k('A'), o, '30a00000-0000-7000-8000-0000000e0001');
  PERFORM c_ok(EXISTS (SELECT 1 FROM inventory.stock_exception WHERE move_id = o AND kind = 'serial_conflict'), 'T10 offline serial conflict recorded');
  PERFORM c_ok((SELECT sold_to_party_id = k('C1') AND warranty_start = DATE '2026-04-02' FROM inventory.serial WHERE id = '30a00000-0000-7000-8000-0000000e0001'),
               'T10 an offline conflict keeps the legitimate buyer and warranty (RV-X2-05)');
  PERFORM c_ok((SELECT detail->>'sold_to_before' = k('C1')::text FROM inventory.stock_exception WHERE move_id = o AND kind = 'serial_conflict'),
               'T10 the conflict records the previous buyer');
  PERFORM c_err($q$INSERT INTO inventory.serial (tenant_id, item_id, variant_id, serial_no, status) VALUES (k('A'), k('I.TV'), k('V.TV'), 'SN9', 'in_stock')$q$,
                'HK_INV_SERIAL_STATE', 'T10 new serial starts registered');
  PERFORM c_err($q$INSERT INTO inventory.serial (tenant_id, item_id, variant_id, serial_no) VALUES (k('A'), k('I.X'), k('V.X'), 'SN9')$q$,
                'HK_INV_SERIAL_NOT_TRACKED', 'T10 serial only for serial-tracked items');
  PERFORM c_err($q$UPDATE inventory.serial SET status = 'in_stock' WHERE serial_no = 'SN003'$q$, '42501', 'T10 serial state is engine-only');
  PERFORM c_err($q$UPDATE inventory.serial SET serial_no = 'X' WHERE serial_no = 'SN003'$q$, '42501', 'T10 serial number immutable');
  UPDATE inventory.serial SET notes = 'یادداشت' WHERE serial_no = 'SN003';
  PERFORM c_err($q$WITH m AS (SELECT c_mv('CA','W1','X','receipt',1,'2026-04-20','{"value":1}') AS id)
                  INSERT INTO inventory.serial_move (tenant_id, move_id, serial_id) SELECT k('A'), m.id, '30a00000-0000-7000-8000-0000000e0003' FROM m$q$,
                'HK_INV_SERIAL_SKU', 'T10 serial of another SKU');
  PERFORM c_err($q$UPDATE inventory.serial_move SET qty_sign = 1$q$, '42501', 'T10 serial moves are append-only');
END $$;

-- ---------- T11 (INV-INV-23/24): بچ، انقضا، FEFO ----------
DO $$
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_err($q$INSERT INTO inventory.batch (tenant_id, item_id, batch_no) VALUES (k('A'), k('I.X'), 'L1')$q$, 'HK_INV_BATCH_NOT_TRACKED', 'T11 batch only for batch items');
  PERFORM c_err($q$INSERT INTO inventory.batch (tenant_id, item_id, batch_no) VALUES (k('A'), k('I.MILK'), 'L1')$q$, 'HK_INV_BATCH_EXPIRY_REQUIRED', 'T11 expiry required');
  INSERT INTO inventory.batch (tenant_id, id, item_id, batch_no, expiry_date) VALUES
    (k('A'), '30a00000-0000-7000-8000-0000000b0001', k('I.MILK'), 'B1', '2026-04-20'),
    (k('A'), '30a00000-0000-7000-8000-0000000b0002', k('I.MILK'), 'B2', '2026-04-15'),
    (k('A'), '30a00000-0000-7000-8000-0000000b0003', k('I.MILK'), 'B3', '2026-04-30');
  PERFORM c_mv('CA','W1','MILK','receipt',2,'2026-04-05', jsonb_build_object('value',200,'batch','30a00000-0000-7000-8000-0000000b0001'));
  PERFORM c_mv('CA','W1','MILK','receipt',2,'2026-04-05', jsonb_build_object('value',200,'batch','30a00000-0000-7000-8000-0000000b0002'));
  PERFORM c_mv('CA','W1','MILK','receipt',2,'2026-04-05', jsonb_build_object('value',200,'batch','30a00000-0000-7000-8000-0000000b0003'));
  PERFORM c_ok((SELECT array_agg(batch_no ORDER BY expiry_date) FROM inventory.fefo_candidates(k('W1'), k('V.MILK'), 3, '2026-04-10')) = ARRAY['B2','B1'],
               'T11 FEFO picks earliest expiry first');
  PERFORM c_ok((SELECT sum(take) FROM inventory.fefo_candidates(k('W1'), k('V.MILK'), 3, '2026-04-10')) = 3, 'T11 FEFO covers the quantity');
  PERFORM c_ok((SELECT array_agg(batch_no ORDER BY expiry_date) FROM inventory.fefo_candidates(k('W1'), k('V.MILK'), 3, '2026-04-18')) = ARRAY['B1','B3'],
               'T11 FEFO skips expired batches');
  PERFORM c_mv('CA','W1','MILK','sale_issue',-1,'2026-04-18', jsonb_build_object('batch','30a00000-0000-7000-8000-0000000b0002'));
  PERFORM c_ok(EXISTS (SELECT 1 FROM inventory.stock_exception WHERE kind = 'expired_batch'), 'T11 expired sale warns by default');
  INSERT INTO core.setting_value (tenant_id, setting_key, level, company_id, value)
  VALUES (k('A'), 'inventory.expired_batch_sale', 'company', k('CA'), '"block"');
  PERFORM c_err($q$SELECT c_mv('CA','W1','MILK','sale_issue',-1,'2026-04-18', jsonb_build_object('batch','30a00000-0000-7000-8000-0000000b0002'))$q$,
                'HK_INV_BATCH_EXPIRED', 'T11 expired sale blocked by setting');
  UPDATE inventory.batch SET status = 'recalled' WHERE id = '30a00000-0000-7000-8000-0000000b0003';
  PERFORM c_err($q$SELECT c_mv('CA','W1','MILK','sale_issue',-1,'2026-04-18', jsonb_build_object('batch','30a00000-0000-7000-8000-0000000b0003'))$q$,
                'HK_INV_BATCH_BLOCKED', 'T11 recalled batch cannot be sold');
  PERFORM c_err($q$UPDATE inventory.batch SET expiry_date = '2026-05-20' WHERE batch_no = 'B1'$q$, 'HK_INV_BATCH_LOCKED', 'T11 batch dates fixed after first move');
END $$;

-- ---------- T12 (INV-INV-25/26): bundle ردیابی ----------
DO $$
DECLARE b uuid; b2 uuid;
BEGIN
  PERFORM c_ctx('A');
  INSERT INTO inventory.tracking_bundle (tenant_id, id, company_id, item_id, variant_id, warehouse_id, direction, total_qty_base)
  VALUES (k('A'), uuidv7(), k('CA'), k('I.TV'), k('V.TV'), k('W1'), 'out', 1) RETURNING id INTO b;
  INSERT INTO inventory.tracking_bundle_entry (tenant_id, bundle_id, serial_no, qty_base) VALUES (k('A'), b, 'NEW-SERIAL', 1);
  PERFORM c_err(format($q$UPDATE inventory.tracking_bundle SET status = 'posted', source_doc_type = 'sales.invoice', source_doc_id = uuidv7() WHERE id = %L$q$, b),
                'HK_INV_BUNDLE_OUT_NEW', 'T12 outgoing bundle cannot invent serials');
  DELETE FROM inventory.tracking_bundle_entry WHERE bundle_id = b;
  INSERT INTO inventory.tracking_bundle_entry (tenant_id, bundle_id, serial_id, qty_base) VALUES (k('A'), b, '30a00000-0000-7000-8000-0000000e0002', 1);
  UPDATE inventory.tracking_bundle SET status = 'posted', source_doc_type = 'sales.invoice', source_doc_id = uuidv7() WHERE id = b;
  PERFORM c_err(format($q$INSERT INTO inventory.tracking_bundle_entry (tenant_id, bundle_id, serial_id, qty_base) VALUES (k('A'), %L, '30a00000-0000-7000-8000-0000000e0003', 1)$q$, b),
                'HK_INV_BUNDLE_LOCKED', 'T12 posted bundle entries are immutable');
  PERFORM c_err(format($q$UPDATE inventory.tracking_bundle SET total_qty_base = 2 WHERE id = %L$q$, b), 'HK_INV_BUNDLE_LOCKED', 'T12 posted bundle is immutable');
  INSERT INTO inventory.tracking_bundle (tenant_id, id, company_id, item_id, variant_id, warehouse_id, direction, total_qty_base)
  VALUES (k('A'), uuidv7(), k('CA'), k('I.MILK'), k('V.MILK'), k('W1'), 'in', 5) RETURNING id INTO b2;
  INSERT INTO inventory.tracking_bundle_entry (tenant_id, bundle_id, new_batch_no, new_batch_expiry, qty_base) VALUES (k('A'), b2, 'B9', '2026-06-01', 3);
  PERFORM c_err(format($q$UPDATE inventory.tracking_bundle SET status = 'posted', source_doc_type = 'purchase.receipt', source_doc_id = uuidv7() WHERE id = %L$q$, b2),
                'HK_INV_BUNDLE_QTY', 'T12 bundle entries must sum to the line quantity');
  PERFORM c_err(format($q$INSERT INTO inventory.tracking_bundle_entry (tenant_id, bundle_id, serial_no, qty_base) VALUES (k('A'), %L, 'Z', 2)$q$, b2),
                'bundle_entry_serial_qty', 'T12 a serial entry is one unit');
  INSERT INTO inventory.tracking_bundle_entry (tenant_id, bundle_id, new_batch_no, new_batch_expiry, qty_base) VALUES (k('A'), b2, 'B10', '2026-06-02', 2);
  PERFORM c_err(format($q$UPDATE inventory.tracking_bundle SET status = 'posted' WHERE id = %L$q$, b2), '23514', 'T12 posted bundle needs its source document');
END $$;

-- ---------- T13 (INV-INV-27..29): چرخهٔ سند انبار؛ پیوند شماره، GL و حرکت (RV-COM-03) ----------
DO $$
DECLARE d uuid := uuidv7(); d2 uuid := uuidv7(); n uuid; l uuid; l2 uuid; mv uuid; j uuid; o1 uuid; o2 uuid;
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_err($q$INSERT INTO inventory.stock_doc (tenant_id, company_id, doc_type, doc_date, warehouse_id, to_warehouse_id)
                  VALUES (k('A'), k('CA'), 'transfer', '2026-04-20', k('W1'), k('W1'))$q$, 'stock_doc_transfer_shape', 'T13 transfer to the same warehouse');
  -- ردیف کاملاً معتبرِ «ثبت‌شده» در درج: فقط نگهبان گذار رد می‌کند (بدون جایگزین CHECK)
  PERFORM c_err($q$INSERT INTO inventory.stock_doc (tenant_id, id, company_id, doc_type, doc_date, warehouse_id, status, posted_at,
                                                    number_issued_id, doc_no, gl_status)
                  VALUES (k('A'), '30a00000-0000-7000-8000-0000000f1301', k('CA'), 'adjustment', '2026-04-20', k('W1'), 'posted', now(),
                          c_num(k('CA'), 'inventory.adjustment', '30a00000-0000-7000-8000-0000000f1301'), 'ADJ-X', 'not_required')$q$,
                'HK_INV_DOC_TRANSITION', 'T13 documents start as draft');
  INSERT INTO inventory.stock_doc (tenant_id, id, company_id, branch_id, doc_type, doc_date, warehouse_id, reason_code)
  VALUES (k('A'), d, k('CA'), k('BA'), 'adjustment', '2026-04-20', k('W1'), 'waste');
  INSERT INTO inventory.stock_doc_line (tenant_id, id, doc_id, line_no, item_id, variant_id, uom_id, qty, qty_base, direction, reason_code)
  VALUES (k('A'), uuidv7(), d, 1, k('I.X'), k('V.X'), k('PCS'), 1, 1, 'out', 'waste') RETURNING id INTO l;
  PERFORM c_err(format($q$UPDATE inventory.stock_doc SET status = 'posted', posted_at = now(), gl_status = 'not_required' WHERE id = %L$q$, d),
                'stock_doc_number_when_issued', 'T13 posting needs a number');
  n := c_num(k('CA'), 'inventory.adjustment', d);
  PERFORM c_err(format($q$UPDATE inventory.stock_doc SET status = 'posted', posted_at = now(), number_issued_id = %L, doc_no = 'A', gl_status = 'not_required' WHERE id = %L$q$, n, d),
                'HK_INV_DOC_STOCK_LINK', 'T13 posted lines need their stock moves');
  PERFORM c_err(format($q$UPDATE inventory.stock_doc SET status = 'posted', posted_at = now(), number_issued_id = c_num(k('CA'), 'sales.invoice', uuidv7()),
                         doc_no = 'A', gl_status = 'not_required' WHERE id = %L$q$, d),
                'HK_COMMERCE_NUMBER_LINK', 'T13 number must be issued to this stock document');
  PERFORM c_err(format($q$SELECT c_mv('CA','W1','NOD','waste',-1,'2026-04-20', jsonb_build_object('doc', %L::uuid, 'line', %L::uuid, 'doc_type', 'inventory.adjustment'));
                         UPDATE inventory.stock_doc SET status = 'posted', posted_at = now(), number_issued_id = %L, doc_no = 'A', gl_status = 'posted',
                                gl_journal_id = c_stock_jr(k('CA'), '2026-04-20', 'inventory.adjustment', %L, ARRAY[%L::uuid]) WHERE id = %L$q$, d, l, n, d, d, d),
                'HK_INV_DOC_STOCK_LINK', 'T13 a move of another SKU does not satisfy the line');
  mv := c_mv('CA','W1','X','waste',-1,'2026-04-20', jsonb_build_object('doc', d, 'line', l, 'doc_type', 'inventory.adjustment'));
  PERFORM c_err(format($q$UPDATE inventory.stock_doc SET status = 'posted', posted_at = now(), number_issued_id = %L, doc_no = 'A', gl_status = 'not_required' WHERE id = %L$q$, n, d),
                'HK_COMMERCE_STOCK_GL_MISSING', 'T13 a valued perpetual adjustment needs its inventory journal');
  PERFORM c_err(format($q$UPDATE inventory.stock_doc SET status = 'posted', posted_at = now(), number_issued_id = %L, doc_no = 'A', gl_status = 'posted',
                         gl_journal_id = c_journal(k('CA'), '2026-04-20', 'sales', 'sales.invoice', %L) WHERE id = %L$q$, n, d, d),
                'HK_COMMERCE_GL_LINK', 'T13 GL journal must originate from inventory/this document');
  PERFORM c_err(format($q$UPDATE inventory.stock_doc SET status = 'posted', posted_at = now(), number_issued_id = %L, doc_no = 'A', gl_status = 'posted',
                         gl_journal_id = c_stock_jr(k('CA'), '2026-04-20', 'inventory.adjustment', %L, ARRAY[%L::uuid], 'post', false, 1) WHERE id = %L$q$, n, d, d, d),
                'HK_COMMERCE_GL_AMOUNT', 'T13 inventory journal equals the move values');
  PERFORM c_err(format($q$UPDATE inventory.stock_doc SET status = 'posted', posted_at = now(), number_issued_id = %L, doc_no = 'A', gl_status = 'not_required' WHERE id = %L$q$, n, d),
                'HK_COMMERCE_STOCK_GL_MISSING', 'T13 gl_status cannot dodge the journal of a valued move');
  j := c_stock_jr(k('CA'), '2026-04-20', 'inventory.adjustment', d, ARRAY[d]);
  UPDATE inventory.stock_doc SET status = 'posted', posted_at = now(), number_issued_id = n, doc_no = c_no(n), gl_status = 'posted', gl_journal_id = j
   WHERE id = d;
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM c_ok((SELECT sum(debit_base - credit_base) FROM ledger.journal_line WHERE journal_id = j AND posting_key = 'inventory.waste') = -c_mval(mv),
               'T13 waste journal: Dr inventory.waste / Cr inventory at the issue value');
  PERFORM c_err(format($q$UPDATE inventory.stock_doc SET description = 'تغییر' WHERE id = %L$q$, d), 'HK_INV_DOC_IMMUTABLE', 'T13 posted header immutable');
  PERFORM c_err(format($q$UPDATE inventory.stock_doc SET status = 'draft' WHERE id = %L$q$, d), 'HK_INV_DOC_TRANSITION', 'T13 no posted → draft');
  PERFORM c_err(format($q$DELETE FROM inventory.stock_doc WHERE id = %L$q$, d), 'HK_INV_DOC_IMMUTABLE', 'T13 posted doc cannot be deleted');
  PERFORM c_err(format($q$UPDATE inventory.stock_doc_line SET qty = 2, qty_base = 2 WHERE id = %L$q$, l), 'HK_INV_DOC_IMMUTABLE', 'T13 posted lines immutable');
  PERFORM c_err(format($q$INSERT INTO inventory.stock_doc_line (tenant_id, doc_id, line_no, item_id, variant_id, uom_id, qty, qty_base, direction)
                         VALUES (k('A'), %L, 2, k('I.X'), k('V.X'), k('PCS'), 1, 1, 'out')$q$, d), 'HK_INV_DOC_IMMUTABLE', 'T13 no lines added after posting');
  PERFORM c_err(format($q$UPDATE inventory.stock_doc SET status = 'cancelled', cancelled_at = now(), cancel_journal_id = c_rev_jr(gl_journal_id, '2026-04-20')
                         WHERE id = %L$q$, d), 'stock_doc_cancel_meta', 'T13 cancel needs a reason');
  -- ابطال (RV-COM-02): حرکت‌ها برگردند و سند GL ابطال (برگشت سند اصل) لازم است
  PERFORM c_err(format($q$UPDATE inventory.stock_doc SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'اشتباه',
                         cancel_journal_id = c_rev_jr(gl_journal_id, '2026-04-20') WHERE id = %L$q$, d), 'HK_INV_CANCEL_STOCK', 'T13 cancel reverses every move');
  PERFORM c_err(format($q$SELECT c_mv('CA','W1','X','waste',1,'2026-04-20', jsonb_build_object('rev', %L::uuid, 'doc', %L::uuid, 'line', %L::uuid, 'doc_type', 'inventory.adjustment'));
                         UPDATE inventory.stock_doc SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'اشتباه' WHERE id = %L$q$, mv, d, l, d),
                'stock_doc_cancel_gl', 'T13 cancelling a GL-posted document needs its cancel journal');
  PERFORM c_err(format($q$SELECT c_mv('CA','W1','X','waste',1,'2026-04-20', jsonb_build_object('rev', %L::uuid, 'doc', %L::uuid, 'line', %L::uuid, 'doc_type', 'inventory.adjustment'));
                         UPDATE inventory.stock_doc SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'اشتباه',
                                cancel_journal_id = c_stock_jr(k('CA'), '2026-04-20', 'inventory.adjustment', %L, ARRAY[%L::uuid], 'cancel', true) WHERE id = %L$q$,
                       mv, d, l, d, d, d),
                'HK_COMMERCE_GL_NOT_REVERSED', 'T13 cancel journal must be the reversal of the posted journal');
  PERFORM c_mv('CA','W1','X','waste',1,'2026-04-20', jsonb_build_object('rev', mv, 'doc', d, 'line', l, 'doc_type', 'inventory.adjustment'));
  UPDATE inventory.stock_doc SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'اشتباه', cancel_journal_id = c_rev_jr(j, '2026-04-20')
   WHERE id = d;
  -- انتقال دومرحله‌ای: ارسال (W1 → در راه) → دریافت (در راه → W2)
  INSERT INTO inventory.stock_doc (tenant_id, id, company_id, branch_id, doc_type, doc_date, warehouse_id, to_warehouse_id, transit_warehouse_id, two_step)
  VALUES (k('A'), d2, k('CA'), k('BA'), 'transfer', '2026-04-21', k('W1'), k('W2'), k('WT'), true);
  INSERT INTO inventory.stock_doc_line (tenant_id, id, doc_id, line_no, item_id, variant_id, uom_id, qty, qty_base, direction)
  VALUES (k('A'), uuidv7(), d2, 1, k('I.X'), k('V.X'), k('PCS'), 2, 2, 'out') RETURNING id INTO l2;
  n := c_num(k('CA'), 'inventory.transfer', d2);
  PERFORM c_err(format($q$UPDATE inventory.stock_doc SET status = 'in_transit', posted_at = now(), number_issued_id = %L, doc_no = 'T', gl_status = 'not_required' WHERE id = %L$q$, n, d2),
                'HK_INV_DOC_STOCK_LINK', 'T13 sending needs the out/in-transit moves');
  o1 := c_mv('CA','W1','X','transfer_out',-2,'2026-04-21', jsonb_build_object('doc', d2, 'line', l2, 'doc_type', 'inventory.transfer'));
  PERFORM c_mv('CA','WT','X','transfer_in',2,'2026-04-21', jsonb_build_object('rule','source','src', o1, 'doc', d2, 'line', l2, 'doc_type', 'inventory.transfer'));
  UPDATE inventory.stock_doc SET status = 'in_transit', posted_at = now(), number_issued_id = n, doc_no = c_no(n), gl_status = 'not_required' WHERE id = d2;
  UPDATE inventory.stock_doc_line SET received_qty_base = 2 WHERE id = l2;
  PERFORM c_err(format($q$UPDATE inventory.stock_doc_line SET qty = 3, qty_base = 3 WHERE id = %L$q$, l2), 'HK_INV_DOC_IMMUTABLE', 'T13 in-transit lines: only received qty');
  PERFORM c_err(format($q$UPDATE inventory.stock_doc SET status = 'posted' WHERE id = %L$q$, d2), 'stock_doc_two_step_posted', 'T13 receiving needs a received date');
  PERFORM c_err(format($q$UPDATE inventory.stock_doc SET status = 'posted', received_date = '2026-04-22', received_at = now() WHERE id = %L$q$, d2),
                'HK_INV_DOC_STOCK_LINK', 'T13 receiving needs the transit-out/destination-in moves (no stock out of thin air)');
  o2 := c_mv('CA','WT','X','transfer_out',-2,'2026-04-22', jsonb_build_object('doc', d2, 'line', l2, 'doc_type', 'inventory.transfer'));
  PERFORM c_mv('CA','W2','X','transfer_in',2,'2026-04-22', jsonb_build_object('rule','source','src', o2, 'doc', d2, 'line', l2, 'doc_type', 'inventory.transfer'));
  UPDATE inventory.stock_doc SET status = 'posted', received_date = '2026-04-22', received_at = now() WHERE id = d2;
END $$;

-- ---------- T14 (INV-INV-30..32): انبارگردانی ----------
DO $$
DECLARE s uuid := uuidv7(); s2 uuid := uuidv7(); l uuid; n uuid;
BEGIN
  PERFORM c_ctx('A');
  INSERT INTO inventory.count_session (tenant_id, id, company_id, branch_id, warehouse_id, count_date, rounds)
  VALUES (k('A'), s, k('CA'), k('BA'), k('W1'), '2026-04-30', 2);
  INSERT INTO inventory.count_line (tenant_id, id, session_id, line_no, item_id, variant_id, uom_id)
  VALUES (k('A'), uuidv7(), s, 1, k('I.X'), k('V.X'), k('PCS')) RETURNING id INTO l;
  PERFORM c_err(format($q$INSERT INTO inventory.count_entry (tenant_id, line_id, round_no, qty, qty_base, counted_by) VALUES (k('A'), %L, 1, 5, 5, k('U1'))$q$, l),
                'HK_INV_COUNT_STATE', 'T14 entries only while counting');
  PERFORM c_err(format($q$UPDATE inventory.count_session SET status = 'reviewing', reviewed_at = now(), started_at = now() WHERE id = %L$q$, s),
                'HK_INV_COUNT_STATE', 'T14 draft cannot jump to reviewing');
  UPDATE inventory.count_session SET status = 'counting', started_at = now() WHERE id = s;
  INSERT INTO inventory.count_session (tenant_id, id, company_id, warehouse_id, count_date) VALUES (k('A'), s2, k('CA'), k('W1'), '2026-04-30');
  PERFORM c_err(format($q$UPDATE inventory.count_session SET status = 'counting', started_at = now() WHERE id = %L$q$, s2), '23505', 'T14 one open count per warehouse');
  INSERT INTO inventory.count_entry (tenant_id, line_id, round_no, qty, qty_base, counted_by) VALUES (k('A'), l, 1, 20, 20, k('U1'));
  PERFORM c_err(format($q$INSERT INTO inventory.count_entry (tenant_id, line_id, round_no, qty, qty_base, counted_by) VALUES (k('A'), %L, 2, 20, 20, k('U1'))$q$, l),
                'HK_INV_COUNT_SAME_COUNTER', 'T14 second round by another counter');
  INSERT INTO inventory.count_entry (tenant_id, line_id, round_no, qty, qty_base, counted_by) VALUES (k('A'), l, 2, 20, 20, k('U2'));
  PERFORM c_err(format($q$UPDATE inventory.count_line SET system_qty_base = 30 WHERE id = %L$q$, l), 'HK_INV_COUNT_STATE', 'T14 system snapshot only in review');
  PERFORM c_err('UPDATE inventory.count_entry SET qty = 1', '42501', 'T14 count entries are append-only');
  UPDATE inventory.count_session SET status = 'reviewing', reviewed_at = now() WHERE id = s;
  UPDATE inventory.count_line SET system_qty_base = 30 WHERE id = l;
  n := c_num(k('CA'), 'inventory.count', s);
  PERFORM c_err(format($q$UPDATE inventory.count_session SET status = 'posted', posted_at = now(), number_issued_id = %L, doc_no = 'x' WHERE id = %L$q$, n, s),
                'HK_INV_COUNT_INCOMPLETE', 'T14 every line needs an accepted count');
  UPDATE inventory.count_line SET counted_qty_base = 20 WHERE id = l;
  UPDATE inventory.count_session SET status = 'posted', posted_at = now(), number_issued_id = n, doc_no = c_no(n) WHERE id = s;
  PERFORM c_err(format($q$UPDATE inventory.count_session SET blind = false WHERE id = %L$q$, s), 'HK_INV_COUNT_STATE', 'T14 posted count immutable');
  PERFORM c_err(format($q$UPDATE inventory.count_line SET counted_qty_base = 21 WHERE id = %L$q$, l), 'HK_INV_COUNT_STATE', 'T14 posted count lines immutable');
END $$;

-- ---------- T15 (INV-INV-33/34): بستن ادواری؛ سطرها، سند GL، حالت، هم‌پوشانی (RV-COM-07/08/09/17) ----------
DO $$
DECLARE pc uuid := uuidv7(); pc2 uuid := uuidv7(); op uuid := uuidv7(); fy uuid; fyca uuid; acc uuid; acca uuid; j uuid; l uuid; v_lines jsonb;
BEGIN
  PERFORM c_ctx('A');
  SELECT id INTO fy FROM ledger.fiscal_year WHERE company_id = k('CP');
  SELECT id INTO fyca FROM ledger.fiscal_year WHERE company_id = k('CA');
  SELECT id INTO acc FROM ledger.account WHERE company_id = k('CP') AND code = '1401';
  SELECT id INTO acca FROM ledger.account WHERE company_id = k('CA') AND code = '1401';
  -- ثبت ماندهٔ آغاز حالت ادواری (از افتتاحیهٔ GL): زیردفتر پیش از نخستین بستن خالی نیست
  INSERT INTO inventory.periodic_close (tenant_id, id, company_id, fiscal_year_id, period_from, period_to, basis, opening_value, closing_value, cogs_value)
  VALUES (k('A'), op, k('CP'), fy, '2026-03-21', '2026-03-21', 'opening', 100, 100, 0);
  INSERT INTO inventory.periodic_close_line (tenant_id, close_id, company_id, asset_account_id, opening_value, closing_value)
  VALUES (k('A'), op, k('CP'), acc, 100, 100);
  UPDATE inventory.periodic_close SET status = 'posted', posted_at = now() WHERE id = op;
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM c_ok((SELECT balance_base FROM inventory.ledger_subledger_stock(k('CP'), '2026-05-01') WHERE account_id = acc) = 100,
               'T15 periodic subledger starts from the registered opening, not empty');
  PERFORM c_err(format($q$INSERT INTO inventory.periodic_close (tenant_id, company_id, fiscal_year_id, period_from, period_to, basis, opening_value, closing_value, cogs_value)
                         VALUES (k('A'), k('CP'), %L, '2026-03-21', '2026-03-21', 'opening', 100, 90, 10)$q$, fy),
                'periodic_close_opening_shape', 'T15 an opening registration has no movement');
  PERFORM c_err(format($q$INSERT INTO inventory.periodic_close (tenant_id, company_id, fiscal_year_id, period_from, period_to, basis,
                         opening_value, purchases_value, purchase_returns_value, closing_value, cogs_value)
                         VALUES (k('A'), k('CP'), %L, '2026-03-21', '2026-06-21', 'valuation', 100, 1000, 50, 200, 1)$q$, fy),
                'periodic_close_cogs', 'T15 COGS = opening + purchases − returns − discounts − closing');
  PERFORM c_err(format($q$INSERT INTO inventory.periodic_close (tenant_id, company_id, fiscal_year_id, period_from, period_to, basis,
                         opening_value, purchases_value, purchase_returns_value, purchase_discounts_value, closing_value, cogs_value)
                         VALUES (k('A'), k('CP'), %L, '2026-03-21', '2026-06-21', 'valuation', 100, 1000, 50, 30, 200, 850)$q$, fy),
                'periodic_close_cogs', 'T15 purchase discounts reduce COGS (RV-COM-09)');
  INSERT INTO inventory.periodic_close (tenant_id, id, company_id, fiscal_year_id, period_from, period_to, basis,
                                        opening_value, purchases_value, purchase_returns_value, closing_value, cogs_value)
  VALUES (k('A'), pc, k('CP'), fy, '2026-03-22', '2026-06-21', 'valuation', 100, 1000, 50, 200, 850);
  INSERT INTO inventory.periodic_close_line (tenant_id, id, close_id, company_id, asset_account_id, opening_value, closing_value)
  VALUES (k('A'), uuidv7(), pc, k('CP'), acc, 100, 200) RETURNING id INTO l;
  -- ردیف کاملاً معتبرِ ثبت‌شده در درج: فقط نگهبان رد می‌کند
  PERFORM c_err(format($q$INSERT INTO inventory.periodic_close (tenant_id, company_id, fiscal_year_id, period_from, period_to, basis, cogs_value, status, posted_at, gl_journal_id)
                         VALUES (k('A'), k('CP'), %L, '2026-06-22', '2026-07-21', 'valuation', 0, 'posted', now(),
                                 c_journal(k('CP'), '2026-07-21', 'inventory', 'inventory.periodic_close', uuidv7()))$q$, fy),
                'HK_INV_PERIODIC_STATE', 'T15 close starts as draft');
  -- قالب §۵-۶ (RV-COM-09): ابتدا از حساب موجودی (نه کلید هزینهٔ inventory.opening_stock)، خرید، برگشت، پایان
  v_lines := jsonb_build_array(
    jsonb_build_object('key','inventory.cogs','dr',100), jsonb_build_object('acct',acc,'key','inventory.asset','cr',100),
    jsonb_build_object('key','inventory.cogs','dr',1000), jsonb_build_object('key','purchase.purchases','cr',1000),
    jsonb_build_object('key','purchase.returns','dr',50), jsonb_build_object('key','inventory.cogs','cr',50),
    jsonb_build_object('acct',acc,'key','inventory.asset','dr',200), jsonb_build_object('key','inventory.cogs','cr',200));
  PERFORM c_err(format($q$UPDATE inventory.periodic_close SET status = 'posted', posted_at = now(),
                         gl_journal_id = c_jr(k('CP'), '2026-06-21', 'inventory', 'inventory.periodic_close', %L, 'post', %L::jsonb - 0 - 0) WHERE id = %L$q$, pc, v_lines, pc),
                'HK_COMMERCE_GL_AMOUNT', 'T15 close journal must relieve the opening from the inventory account (the old template left it there)');
  PERFORM c_err(format($q$UPDATE inventory.periodic_close SET status = 'posted', posted_at = now(),
                         gl_journal_id = c_journal(k('CP'), '2026-06-21', 'sales', 'sales.invoice', %L) WHERE id = %L$q$, pc, pc),
                'HK_COMMERCE_GL_LINK', 'T15 close journal originates from inventory/this close');
  PERFORM c_err(format($q$UPDATE inventory.periodic_close_line SET closing_value = 199 WHERE id = %L;
                         UPDATE inventory.periodic_close SET status = 'posted', posted_at = now(),
                         gl_journal_id = c_jr(k('CP'), '2026-06-21', 'inventory', 'inventory.periodic_close', %L, 'post', %L::jsonb) WHERE id = %L$q$, l, pc, v_lines, pc),
                'HK_INV_PERIODIC_LINES', 'T15 lines sum to the header opening/closing');
  j := c_jr(k('CP'), '2026-06-21', 'inventory', 'inventory.periodic_close', pc, 'post', v_lines);
  UPDATE inventory.periodic_close SET status = 'posted', posted_at = now(), gl_journal_id = j WHERE id = pc;
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM c_ok((SELECT sum(debit_base - credit_base) FROM ledger.journal_line WHERE journal_id = j AND account_id = acc) + 100 = 200,
               'T15 inventory account = closing value after the close (GL opening 100 + close journal)');
  PERFORM c_ok((SELECT balance_base FROM inventory.ledger_subledger_stock(k('CP'), '2026-07-01') WHERE account_id = acc) = 200,
               'T15 periodic subledger = closing value');
  PERFORM c_err(format($q$UPDATE inventory.periodic_close SET closing_value = 300, cogs_value = 750 WHERE id = %L$q$, pc), 'HK_INV_PERIODIC_STATE', 'T15 posted close immutable');
  PERFORM c_err(format($q$UPDATE inventory.periodic_close_line SET closing_value = 999999 WHERE id = %L$q$, l), 'HK_INV_PERIODIC_STATE', 'T15 lines of a posted close immutable (RV-COM-07)');
  PERFORM c_err(format($q$INSERT INTO inventory.periodic_close_line (tenant_id, close_id, company_id, asset_account_id, posting_group_code, opening_value, closing_value)
                         VALUES (k('A'), %L, k('CP'), %L, 'X', 0, 5)$q$, pc, acc), 'HK_INV_PERIODIC_STATE', 'T15 no lines added to a posted close');
  PERFORM c_err(format($q$DELETE FROM inventory.periodic_close_line WHERE id = %L$q$, l), 'HK_INV_PERIODIC_STATE', 'T15 lines of a posted close cannot be deleted');
  PERFORM c_err(format($q$DELETE FROM inventory.periodic_close WHERE id = %L$q$, pc), 'HK_INV_PERIODIC_STATE', 'T15 posted close cannot be deleted');
  -- هم‌پوشانی (RV-COM-08): دو بستن ثبت‌شده برای همان ماه‌ها
  PERFORM c_err(format($q$INSERT INTO inventory.periodic_close (tenant_id, id, company_id, fiscal_year_id, period_from, period_to, basis, cogs_value)
                         VALUES (k('A'), %L, k('CP'), %L, '2026-03-22', '2026-09-21', 'valuation', 0);
                         INSERT INTO inventory.periodic_close_line (tenant_id, close_id, company_id, asset_account_id, opening_value, closing_value)
                         VALUES (k('A'), %L, k('CP'), %L, 0, 0);
                         UPDATE inventory.periodic_close SET status = 'posted', posted_at = now(),
                                gl_journal_id = c_journal(k('CP'), '2026-09-21', 'inventory', 'inventory.periodic_close', %L) WHERE id = %L$q$, pc2, fy, pc2, acc, pc2, pc2),
                '23P01', 'T15 overlapping posted closes are rejected');
  -- حالت (RV-COM-08): شرکت دائمی بستن ادواری ندارد (سند همان شرکت تا فقط نگهبان حالت رد کند)
  PERFORM c_err(format($q$INSERT INTO inventory.periodic_close (tenant_id, id, company_id, fiscal_year_id, period_from, period_to, basis, cogs_value)
                         VALUES (k('A'), %L, k('CA'), %L, '2026-03-21', '2026-06-21', 'valuation', 0);
                         INSERT INTO inventory.periodic_close_line (tenant_id, close_id, company_id, asset_account_id, opening_value, closing_value)
                         VALUES (k('A'), %L, k('CA'), %L, 0, 0);
                         UPDATE inventory.periodic_close SET status = 'posted', posted_at = now(),
                                gl_journal_id = c_journal(k('CA'), '2026-06-21', 'inventory', 'inventory.periodic_close', %L) WHERE id = %L$q$,
                       pc2, fyca, pc2, acca, pc2, pc2),
                'HK_INV_PERIODIC_MODE', 'T15 periodic close only in periodic mode');
  PERFORM c_err(format($q$INSERT INTO inventory.periodic_close (tenant_id, id, company_id, fiscal_year_id, period_from, period_to, basis, cogs_value)
                         VALUES (k('A'), %L, k('CP'), %L, '2026-06-22', '2027-04-21', 'valuation', 0);
                         UPDATE inventory.periodic_close SET status = 'posted', posted_at = now(),
                                gl_journal_id = c_journal(k('CP'), '2026-09-21', 'inventory', 'inventory.periodic_close', %L) WHERE id = %L$q$, pc2, fy, pc2, pc2),
                'HK_INV_PERIODIC_PERIOD', 'T15 close period lies inside its fiscal year');
  -- برگشت: سند برگشت = برگشت همان سند بستن
  PERFORM c_err(format($q$UPDATE inventory.periodic_close SET status = 'reversed',
                         reversal_journal_id = c_journal(k('CP'), '2026-06-22', 'inventory', 'inventory.periodic_close', %L, 'reverse') WHERE id = %L$q$, pc, pc),
                'HK_COMMERCE_GL_NOT_REVERSED', 'T15 reversal journal must reverse the close journal');
  UPDATE inventory.periodic_close SET status = 'reversed', reversal_journal_id = c_rev_jr(j, '2026-06-22', 'reverse') WHERE id = pc;
END $$;

-- ---------- T16 (INV-INV-02): سیاست تاریخ‌دار ----------
DO $$
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_err($q$INSERT INTO inventory.company_policy (tenant_id, company_id, effective_from, valuation_method) VALUES (k('A'), k('CA'), '2027-03-21', 'fifo')$q$,
                'HK_INV_POLICY_METHOD_CHANGE', 'T16 valuation method change is v2');
  PERFORM c_err($q$INSERT INTO inventory.company_policy (tenant_id, company_id, effective_from, inventory_mode) VALUES (k('A'), k('CA'), '2026-04-01', 'periodic')$q$,
                'HK_INV_POLICY_RETROACTIVE', 'T16 no policy over existing moves');
  PERFORM c_err($q$UPDATE inventory.company_policy SET inventory_mode = 'periodic' WHERE company_id = k('CA')$q$, 'HK_INV_POLICY_LOCKED', 'T16 policy locked by moves');
  UPDATE inventory.company_policy SET negative_stock_default = 'allow' WHERE company_id = k('CA');
  INSERT INTO inventory.company_policy (tenant_id, company_id, effective_from, inventory_mode) VALUES (k('A'), k('CP'), '2027-03-21', 'perpetual');
  PERFORM c_err($q$INSERT INTO inventory.company_policy (tenant_id, company_id, effective_from, inventory_mode) VALUES (k('A'), k('CP'), '2026-12-01', 'perpetual')$q$,
                'HK_INV_POLICY_RETROACTIVE', 'T16 no policy before a later one');
END $$;

-- ---------- T17 (INV-INV-01): نگهبان انبار ----------
DO $$
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_err($q$UPDATE inventory.warehouse SET code = 'W1X' WHERE id = k('W1')$q$, 'HK_INV_WAREHOUSE_LOCKED', 'T17 warehouse code immutable');
  PERFORM c_err($q$UPDATE inventory.warehouse SET branch_id = NULL, kind = 'transit', negative_policy = 'block' WHERE id = k('W1')$q$,
                'HK_INV_WAREHOUSE_LOCKED', 'T17 kind fixed after moves');
  UPDATE inventory.warehouse SET name = 'انبار مرکزی' WHERE id = k('W1');
END $$;

-- ---------- T18 (INV-INV-35): زیردفتر موجودی برای تطبیق با GL ----------
DO $$
DECLARE acc uuid; r uuid; i uuid; v_before numeric; v_before_d numeric;
BEGIN
  PERFORM c_ctx('A');
  SELECT id INTO acc FROM ledger.account WHERE company_id = k('CF') AND code = '1401';
  v_before := coalesce((SELECT balance_base FROM inventory.ledger_subledger_stock(k('CF'), '2026-12-31') WHERE account_id = acc), 0);
  v_before_d := coalesce((SELECT balance_base FROM inventory.ledger_subledger_stock(k('CF'), '2026-05-01') WHERE account_id = acc), 0);
  r := c_mv('CF','F2','NOD','receipt',4,'2026-05-01', jsonb_build_object('value', 400, 'acct', acc));
  i := c_mv('CF','F2','NOD','sale_issue',-1,'2026-05-02', jsonb_build_object('acct', acc));
  PERFORM c_ok((SELECT balance_base FROM inventory.ledger_subledger_stock(k('CF'), '2026-12-31') WHERE account_id = acc) = v_before + 300,
               'T18 subledger balance per GL account');
  PERFORM c_ok((SELECT balance_base FROM inventory.ledger_subledger_stock(k('CF'), '2026-05-01') WHERE account_id = acc) = v_before_d + 400,
               'T18 subledger as-of date honoured');
  PERFORM c_ok((SELECT balance_base FROM inventory.ledger_subledger_stock(k('CF'), '2026-12-31') WHERE account_id = acc)
               = (SELECT sum(l.value) FROM inventory.valuation_layer l JOIN inventory.stock_move m ON m.id = l.move_id
                   WHERE m.company_id = k('CF') AND m.asset_account_id = acc AND l.gl_date <= '2026-12-31'),
               'T18 subledger = Σ layers of the account''s moves (every perpetual move carries its account; RV-COM-17)');
  PERFORM c_ok((SELECT currency FROM inventory.ledger_subledger_stock(k('CF'), '2026-12-31') WHERE account_id = acc) = 'IRR',
               'T18 inventory subledger is reported in base currency (inventory GL lines are base-only)');
  PERFORM c_ok(EXISTS (SELECT 1 FROM ledger.subledger_source WHERE subledger_kind = 'inventory' AND balance_function = 'inventory.ledger_subledger_stock'),
               'T18 subledger registered with ledger');
END $$;

-- ---------- T19 (INV-INV-36): انتقال با در راه (استخر انبار) ----------
DO $$
DECLARE o1 uuid; i1 uuid; o2 uuid; i2 uuid; doc uuid := uuidv7();
BEGIN
  PERFORM c_ctx('A');
  o1 := c_mv('CF','F1','X','transfer_out',-2,'2026-04-06', jsonb_build_object('doc', doc));
  i1 := c_mv('CF','FT','X','transfer_in',2,'2026-04-06', jsonb_build_object('rule','source','src', o1, 'doc', doc));
  PERFORM c_ok(c_mval(i1) = -c_mval(o1) AND c_mval(o1) = -600, 'T19 transit receives the source value (2 × 300)');
  o2 := c_mv('CF','FT','X','transfer_out',-2,'2026-04-07', jsonb_build_object('doc', doc));
  i2 := c_mv('CF','F2','X','transfer_in',2,'2026-04-07', jsonb_build_object('rule','source','src', o2, 'doc', doc));
  PERFORM c_ok(c_mval(i2) = 600 AND (SELECT qty FROM inventory.stock_balance WHERE warehouse_id = k('FT') AND variant_id = k('V.X')) = 0,
               'T19 transit empties after receipt');
  PERFORM c_err(format($q$SELECT c_mv('CF','FT','X','transfer_in',1,'2026-04-07', jsonb_build_object('rule','source','src', %L::uuid))$q$, i1),
                'HK_INV_COST_SOURCE', 'T19 transfer_in must source a transfer_out');
  PERFORM c_err(format($q$SELECT c_mv('CF','F2','X','transfer_in',2,'2026-04-05', jsonb_build_object('rule','source','src', %L::uuid))$q$, o2),
                'HK_INV_COST_SOURCE', 'T19 receipt cannot predate the shipment');
  PERFORM c_err($q$SELECT c_mv('CF','FT','X','transfer_out',-1,'2026-04-08')$q$, 'HK_INV_NEGATIVE_STOCK', 'T19 transit cannot go negative');
END $$;

-- ---------- T20 (INV-INV-37): تولید داخلی (ارزش خروجی = Σ اجزا) ----------
DO $$
DECLARE doc uuid := uuidv7(); g uuid := uuidv7(); c1 uuid; o uuid;
BEGIN
  PERFORM c_ctx('A');
  c1 := c_mv('CA','W1','MILK','production_out',-1,'2026-04-12', jsonb_build_object('batch','30a00000-0000-7000-8000-0000000b0001','doc',doc,'group',g));
  o := c_mv('CA','W1','SYR','production_in',1,'2026-04-12', jsonb_build_object('rule','components','doc',doc,'group',g));
  PERFORM c_ok(c_mval(o) = -c_mval(c1) AND c_mval(o) > 0, 'T20 production output valued at its components');
  PERFORM c_err($q$SELECT c_mv('CA','W1','MILK','production_out',-1,'2026-04-12', jsonb_build_object('batch','30a00000-0000-7000-8000-0000000b0001'))$q$,
                'stock_move_production_group', 'T20 production moves carry a cost group');
END $$;

-- ---------- T21 (INV-INV-38): برگشت از فروش به بهای فروش اصلی ----------
DO $$
DECLARE i uuid; r uuid; rc uuid;
BEGIN
  PERFORM c_ctx('A');
  i := c_mv('CF','F1','X','sale_issue',-2,'2026-04-15');
  r := c_mv('CF','F1','X','sale_return',1,'2026-04-16', jsonb_build_object('rule','source','src', i));
  PERFORM c_ok(c_mval(r) = round(-c_mval(i) / 2, 0), 'T21 partial return at the original unit cost');
  rc := (SELECT id FROM inventory.stock_move WHERE company_id = k('CF') AND move_kind = 'receipt' ORDER BY posting_seq LIMIT 1);
  PERFORM c_err(format($q$SELECT c_mv('CF','F1','X','sale_return',1,'2026-04-16', jsonb_build_object('rule','source','src', %L::uuid))$q$, rc),
                'HK_INV_COST_SOURCE', 'T21 sale return must source a sale issue');
  PERFORM c_err(format($q$SELECT c_mv('CF','F1','X','sale_return',1,'2026-04-14', jsonb_build_object('rule','source','src', %L::uuid))$q$, i),
                'HK_INV_COST_SOURCE', 'T21 return cannot predate the sale');
  PERFORM c_err(format($q$SELECT c_mv('CF','F1','X','sale_return',3,'2026-04-16', jsonb_build_object('rule','source','src', %L::uuid))$q$, i),
                'HK_INV_COST_SOURCE', 'T21 return cannot exceed the sale');
  PERFORM c_ok(NOT EXISTS (SELECT 1 FROM inventory.verify_derived(k('CF'))) AND NOT EXISTS (SELECT 1 FROM inventory.verify_derived(k('CA'))),
               'T21 derived state consistent for both companies');
END $$;

-- ---------- T22 (INV-INV-39): بازسازی مشتق‌ها (قلاب درون‌ریزی) ----------
DO $$
DECLARE n int; v_bal numeric;
BEGIN
  PERFORM c_ctx('A');
  SELECT sum(qty) INTO v_bal FROM inventory.stock_balance WHERE company_id = k('CF');
  n := inventory.rebuild_derived(k('CF'));
  PERFORM c_ok(n > 0 AND (SELECT sum(qty) FROM inventory.stock_balance WHERE company_id = k('CF')) = v_bal, 'T22 rebuild reproduces balances and layers');
  PERFORM c_ok(NOT EXISTS (SELECT 1 FROM inventory.verify_derived(k('CF'))), 'T22 consistent after rebuild');
END $$;
-- RV-COM-18: صدورِ هنگام بازارزیابیِ در صف (استخر کثیف) درون‌ریزی را رد نمی‌کند؛ اصلاح‌های پس از نقطهٔ کثیف همان کار معوق‌اند
DO $$
DECLARE n int;
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_mv('CF','F1','X','receipt',3,'2026-04-02','{"value":999}');
  PERFORM c_ok(EXISTS (SELECT 1 FROM inventory.cost_pool WHERE company_id = k('CF') AND dirty_from_date IS NOT NULL), 'T22 a backdated receipt leaves a dirty pool');
  n := inventory.rebuild_derived(k('CF'));
  PERFORM c_ok(n > 0 AND NOT EXISTS (SELECT 1 FROM inventory.cost_pool WHERE company_id = k('CF') AND dirty_from_date IS NOT NULL)
               AND NOT EXISTS (SELECT 1 FROM inventory.verify_derived(k('CF'))), 'T22 rebuild of a dirty export completes the pending repost');
END $$;

-- ---------- T23 (INV-INV-40): نقطهٔ بازیابی و بازپخش از آن (FIFO) ----------
DO $$
DECLARE r1 uuid; i1 uuid; cp uuid; b uuid; run uuid; pid uuid;
BEGIN
  PERFORM c_ctx('A');
  r1 := c_mv('CF','F2','SYR','receipt',10,'2026-06-01','{"value":1000}');
  i1 := c_mv('CF','F2','SYR','sale_issue',-4,'2026-06-02');
  pid := (c_pool(r1)).id;
  cp := inventory.create_checkpoint(pid);
  PERFORM c_ok(cp IS NOT NULL AND (SELECT jsonb_array_length(fifo_state) FROM inventory.pool_checkpoint WHERE id = cp) = 1, 'T23 checkpoint captures the FIFO queue');
  PERFORM c_mv('CF','F2','SYR','receipt',5,'2026-06-05','{"value":1000}');
  PERFORM c_mv('CF','F2','SYR','sale_issue',-8,'2026-06-06');
  b := c_mv('CF','F2','SYR','receipt',2,'2026-06-03','{"value":600}');
  INSERT INTO inventory.repost_run (tenant_id, company_id, trigger_reason, gl_floor_date) VALUES (k('A'), k('CF'), 'backdated', '2026-06-01')
  RETURNING id INTO run;
  PERFORM inventory.repost_pool(pid, run, '2026-06-01');
  PERFORM c_ok((SELECT count(*) FROM inventory.pool_checkpoint WHERE pool_id = pid) = 1, 'T23 checkpoint before the dirty point survives');
  PERFORM c_ok(inventory.verify_pool_replay(pid) = 0 AND NOT EXISTS (SELECT 1 FROM inventory.verify_derived(k('CF'))), 'T23 replay from checkpoint = full replay');
  UPDATE inventory.warehouse SET is_active = false WHERE id = k('F2');
  PERFORM c_err($q$SELECT c_mv('CF','F2','SYR','receipt',1,'2026-06-07','{"value":1}')$q$, 'HK_INV_WAREHOUSE_INACTIVE', 'T23 inactive warehouse takes no new moves');
  UPDATE inventory.warehouse SET is_active = true WHERE id = k('F2');
  UPDATE inventory.stock_exception SET status = 'acknowledged' WHERE id = (SELECT id FROM inventory.stock_exception WHERE kind = 'negative_stock' ORDER BY created_at LIMIT 1);
  PERFORM c_err($q$UPDATE inventory.stock_exception SET status = 'open' WHERE status = 'acknowledged'$q$, 'HK_INV_EXCEPTION_STATE', 'T23 exceptions move forward only');
  PERFORM c_err($q$UPDATE inventory.stock_exception SET status = 'resolved' WHERE status = 'acknowledged'$q$, '23514', 'T23 resolution needs a note and time');
  UPDATE inventory.stock_exception SET status = 'resolved', resolved_at = now(), resolved_by = k('U1'), resolution_note = 'شمارش شد' WHERE status = 'acknowledged';
END $$;
DO $$
DECLARE s uuid := uuidv7(); l uuid;
BEGIN
  PERFORM c_ctx('A');
  INSERT INTO inventory.count_session (tenant_id, id, company_id, warehouse_id, count_date, rounds) VALUES (k('A'), s, k('CA'), k('W2'), '2026-05-30', 1);
  INSERT INTO inventory.count_line (tenant_id, id, session_id, line_no, item_id, variant_id, uom_id) VALUES (k('A'), uuidv7(), s, 1, k('I.NOD'), k('V.NOD'), k('PCS')) RETURNING id INTO l;
  UPDATE inventory.count_session SET status = 'counting', started_at = now() WHERE id = s;
  PERFORM c_err(format($q$INSERT INTO inventory.count_entry (tenant_id, line_id, round_no, qty, qty_base, counted_by) VALUES (k('A'), %L, 2, 1, 1, k('U2'))$q$, l),
                'HK_INV_COUNT_ROUND', 'T23 single-round count has no round 2');
  UPDATE inventory.count_session SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'تکراری' WHERE id = s;
END $$;

-- ---------- T10b (RV-X2-05): برگشت سریال گارانتی و خریدار را پاک می‌کند؛ ابطال برگشت آن‌ها را بازمی‌گرداند ----------
DO $$
DECLARE i uuid; r uuid;
BEGIN
  PERFORM c_ctx('A');
  i := c_mv('CA','W1','TV','sale_issue',-1,'2026-06-01', jsonb_build_object('party', k('C1')));
  INSERT INTO inventory.serial_move (tenant_id, move_id, serial_id) VALUES (k('A'), i, '30a00000-0000-7000-8000-0000000e0002');
  r := c_mv('CA','W1','TV','sale_return',1,'2026-06-05', jsonb_build_object('rule','source','src', i, 'party', k('C1')));
  INSERT INTO inventory.serial_move (tenant_id, move_id, serial_id) VALUES (k('A'), r, '30a00000-0000-7000-8000-0000000e0002');
  PERFORM c_ok((SELECT status = 'in_stock' AND warranty_start IS NULL AND warranty_end IS NULL AND sold_to_party_id IS NULL
                  FROM inventory.serial WHERE id = '30a00000-0000-7000-8000-0000000e0002'), 'T10b returned serial has no warranty or buyer');
  i := c_mv('CA','W1','TV','sale_return',-1,'2026-06-05', jsonb_build_object('rev', r));
  INSERT INTO inventory.serial_move (tenant_id, move_id, serial_id) VALUES (k('A'), i, '30a00000-0000-7000-8000-0000000e0002');
  PERFORM c_ok((SELECT status = 'out' AND warranty_start = DATE '2026-06-01' AND warranty_end = DATE '2026-06-01' + 365 AND sold_to_party_id = k('C1')
                  FROM inventory.serial WHERE id = '30a00000-0000-7000-8000-0000000e0002'), 'T10b cancelling the return restores the sale''s warranty and buyer');
  PERFORM c_err($q$INSERT INTO inventory.serial_move (tenant_id, move_id, serial_id) VALUES (k('A'), uuidv7(), '30a00000-0000-7000-8000-0000000e0003')$q$,
                'HK_INV_MOVE_NOT_FOUND', 'T10b serial move needs its stock move');
END $$;

-- ---------- T24 (RV-COM-01): ارزیابی مستقل از ترتیب درج؛ وضعیت مؤثر حرکت ----------
-- (الف) سناریوی بازبین: A به ترتیب تاریخ، B با فروش آفلاینِ پیش از رسید و سپس بازارزیابی
DO $$
DECLARE a uuid[] := '{}'; b uuid[] := '{}'; run uuid; p record; pa inventory.cost_pool; pb inventory.cost_pool; v uuid;
BEGIN
  PERFORM c_ctx('A');
  a := a || c_mv('CA','W1','DA','receipt',1,'2026-07-01','{"value":1000}');
  a := a || c_mv('CA','W1','DA','sale_issue',-1,'2026-07-02');
  a := a || c_mv('CA','W1','DA','receipt',1,'2026-07-03','{"value":3000}');
  a := a || c_mv('CA','W1','DA','sale_issue',-1,'2026-07-04');
  a := a || c_mv('CA','W1','DA','sale_return',1,'2026-07-05', jsonb_build_object('rule','source','src', a[2]));
  a := a || c_mv('CA','W1','DA','sale_issue',-1,'2026-07-06');
  a := a || c_mv('CA','W1','DA','sale_issue',-1,'2026-07-07');
  v := c_mv('CA','W1','DB','sale_issue',-1,'2026-07-02');                       -- S1 پیش از R1 (همگام‌سازی آفلاین)
  b := ARRAY[c_mv('CA','W1','DB','receipt',1,'2026-07-01','{"value":1000}'), v];
  b := b || c_mv('CA','W1','DB','receipt',1,'2026-07-03','{"value":3000}');
  b := b || c_mv('CA','W1','DB','sale_issue',-1,'2026-07-04');
  b := b || c_mv('CA','W1','DB','sale_return',1,'2026-07-05', jsonb_build_object('rule','source','src', b[2]));
  b := b || c_mv('CA','W1','DB','sale_issue',-1,'2026-07-06');
  b := b || c_mv('CA','W1','DB','sale_issue',-1,'2026-07-07');
  INSERT INTO inventory.repost_run (tenant_id, company_id, trigger_reason, gl_floor_date) VALUES (k('A'), k('CA'), 'backdated', '2026-07-01') RETURNING id INTO run;
  PERFORM inventory.repost_pool((c_pool(b[1])).id, run, '2026-07-01');
  pa := c_pool(a[1]); pb := c_pool(b[1]);
  PERFORM c_ok(c_mval(a[7]) = -1000 AND c_mval(b[7]) = -1000, format('T24 S4 is valued the same whatever the insert order (A %s, B %s)', c_mval(a[7]), c_mval(b[7])));
  PERFORM c_ok((SELECT cost_status FROM inventory.v_move_value WHERE move_id = b[2]) = 'known'
               AND (SELECT cost_status FROM inventory.v_move_value WHERE move_id = b[5]) = 'known',
               'T24 a resolved move (and the return sourced from it) is known after repost, not stuck at its first «unknown» layer');
  PERFORM c_ok(pa.value = pb.value AND pa.qty = pb.qty AND pa.last_unit_cost = pb.last_unit_cost,
               format('T24 pools equal (A %s/%s luc %s, B %s/%s luc %s)', pa.qty, pa.value, pa.last_unit_cost, pb.qty, pb.value, pb.last_unit_cost));
  PERFORM c_ok(inventory.verify_pool_replay(pa.id) = 0 AND inventory.verify_pool_replay(pb.id) = 0, 'T24 replay agrees for both pools');
END $$;

-- (ب) تفاضلی تصادفی قطعی: همان مجموعه حرکت (رسید، فروش، برگشت از فروش، انتقال) یک بار به ترتیب تاریخ و یک بار با ترتیب درج
-- تصادفیِ سازگار با وابستگی + بازارزیابی؛ ارزش و وضعیت هر حرکت و استخرها باید برابر باشند (میانگین و FIFO).
DO $$
DECLARE meth text; seed int; co uuid; whs uuid[]; ia uuid; ib uuid; va uuid; vb uuid; n int := 14; i int; r float8; q numeric;
        w uuid; w2 uuid; rem numeric; st record; run uuid; p record; loops int; v_bad int; d0 date := DATE '2026-08-01'; m uuid; v_msg text;
BEGIN
  PERFORM c_ctx('A');
  CREATE TEMP TABLE IF NOT EXISTS c24 (idx int, kind text, qty numeric, val numeric, wh uuid, dep int, a_id uuid, b_id uuid) ON COMMIT DROP;
  FOREACH meth IN ARRAY ARRAY['ma','fifo'] LOOP
    FOR seed IN 1..8 LOOP
      DELETE FROM c24;
      PERFORM setseed(seed / 100.0 + CASE meth WHEN 'ma' THEN 0 ELSE 0.5 END);
      co := CASE meth WHEN 'ma' THEN k('CA') ELSE k('CF') END;
      whs := CASE meth WHEN 'ma' THEN ARRAY[k('W1'), k('W9')] ELSE ARRAY[k('F1'), k('F2')] END;
      ia := uuidv7(); ib := uuidv7(); va := uuidv7(); vb := uuidv7();
      INSERT INTO catalog.item (tenant_id, id, code, name, item_type, base_uom_id) VALUES
        (k('A'), ia, 'D' || meth || seed || 'A', 'تفاضلی', 'stock', k('PCS')), (k('A'), ib, 'D' || meth || seed || 'B', 'تفاضلی', 'stock', k('PCS'));
      INSERT INTO catalog.item_uom (tenant_id, item_id, uom_id, factor, is_base) VALUES (k('A'), ia, k('PCS'), 1, true), (k('A'), ib, k('PCS'), 1, true);
      INSERT INTO catalog.item_variant (tenant_id, id, item_id, code, is_default) VALUES (k('A'), va, ia, 'D' || meth || seed || 'A', true), (k('A'), vb, ib, 'D' || meth || seed || 'B', true);
      i := 0;
      WHILE i < n LOOP
        r := random(); w := whs[1 + floor(random() * 2)::int];
        IF r < 0.35 OR i = 0 THEN
          q := 1 + floor(random() * 4);
          INSERT INTO c24 VALUES (i, 'receipt', q, q * (100 + floor(random() * 4900)), w, NULL);
        ELSIF r < 0.68 THEN
          INSERT INTO c24 VALUES (i, 'sale_issue', 1 + floor(random() * 3), NULL, w, NULL);
        ELSIF r < 0.84 THEN
          SELECT x.idx, x.wh, x.qty - coalesce((SELECT sum(y.qty) FROM c24 y WHERE y.dep = x.idx AND y.kind = 'sale_return'), 0) AS rem INTO st
            FROM c24 x WHERE x.kind = 'sale_issue'
             AND x.qty > coalesce((SELECT sum(y.qty) FROM c24 y WHERE y.dep = x.idx AND y.kind = 'sale_return'), 0)
           ORDER BY random() LIMIT 1;
          IF FOUND THEN
            INSERT INTO c24 VALUES (i, 'sale_return', 1 + floor(random() * st.rem), NULL, st.wh, st.idx);
          ELSE
            INSERT INTO c24 VALUES (i, 'receipt', 1, 100 + floor(random() * 4900), w, NULL);
          END IF;
        ELSIF i + 1 < n THEN
          w2 := CASE WHEN w = whs[1] THEN whs[2] ELSE whs[1] END; q := 1 + floor(random() * 2);
          INSERT INTO c24 VALUES (i, 'transfer_out', q, NULL, w, NULL), (i + 1, 'transfer_in', q, NULL, w2, i);
          i := i + 1;
        ELSE
          INSERT INTO c24 VALUES (i, 'sale_issue', 1, NULL, w, NULL);
        END IF;
        i := i + 1;
      END LOOP;
      -- A: به ترتیب تاریخ
      FOR st IN SELECT * FROM c24 ORDER BY idx LOOP
        m := c_move(jsonb_build_object('company', co, 'wh', st.wh, 'item', ia, 'variant', va, 'kind', st.kind, 'date', d0 + st.idx,
                                       'qty', CASE WHEN st.kind IN ('sale_issue','transfer_out') THEN -st.qty ELSE st.qty END)
                    || CASE st.kind WHEN 'receipt' THEN jsonb_build_object('value', st.val)
                                    WHEN 'sale_return' THEN jsonb_build_object('rule', 'source', 'src', (SELECT a_id FROM c24 x WHERE x.idx = st.dep))
                                    WHEN 'transfer_in' THEN jsonb_build_object('rule', 'source', 'src', (SELECT a_id FROM c24 x WHERE x.idx = st.dep))
                                    ELSE '{}'::jsonb END);
        UPDATE c24 SET a_id = m WHERE idx = st.idx;
      END LOOP;
      -- B: ترتیب تصادفی سازگار با وابستگی، سپس بازارزیابی همهٔ استخرهای کثیف تا پایدار شدن (مثل job)
      LOOP
        SELECT * INTO st FROM c24 x WHERE x.b_id IS NULL AND (x.dep IS NULL OR (SELECT y.b_id FROM c24 y WHERE y.idx = x.dep) IS NOT NULL)
         ORDER BY random() LIMIT 1;
        EXIT WHEN NOT FOUND;
        m := c_move(jsonb_build_object('company', co, 'wh', st.wh, 'item', ib, 'variant', vb, 'kind', st.kind, 'date', d0 + st.idx,
                                       'qty', CASE WHEN st.kind IN ('sale_issue','transfer_out') THEN -st.qty ELSE st.qty END)
                    || CASE st.kind WHEN 'receipt' THEN jsonb_build_object('value', st.val)
                                    WHEN 'sale_return' THEN jsonb_build_object('rule', 'source', 'src', (SELECT b_id FROM c24 x WHERE x.idx = st.dep))
                                    WHEN 'transfer_in' THEN jsonb_build_object('rule', 'source', 'src', (SELECT b_id FROM c24 x WHERE x.idx = st.dep))
                                    ELSE '{}'::jsonb END);
        UPDATE c24 SET b_id = m WHERE idx = st.idx;
      END LOOP;
      INSERT INTO inventory.repost_run (tenant_id, company_id, trigger_reason, gl_floor_date) VALUES (k('A'), co, 'backdated', d0) RETURNING id INTO run;
      loops := 0;
      LOOP
        loops := loops + 1;
        EXIT WHEN loops > 10 OR NOT EXISTS (SELECT 1 FROM inventory.cost_pool c WHERE c.item_id = ib AND c.dirty_from_date IS NOT NULL);
        FOR p IN SELECT c.id FROM inventory.cost_pool c WHERE c.item_id = ib AND c.dirty_from_date IS NOT NULL ORDER BY c.dirty_from_date, c.dirty_from_seq LOOP
          PERFORM inventory.repost_pool(p.id, run, d0);
        END LOOP;
      END LOOP;
      SELECT count(*) INTO v_bad FROM c24 x
        JOIN inventory.v_move_value ma ON ma.move_id = x.a_id JOIN inventory.v_move_value mb ON mb.move_id = x.b_id
       WHERE ma.total_value <> mb.total_value OR ma.cost_status <> mb.cost_status;
      PERFORM c_ok(v_bad = 0, format('T24 %s seed %s: %s moves valued differently after out-of-order insert + repost', meth, seed, v_bad));
      SELECT count(*), string_agg(format('A %s/%s/%s/%s luc %s B %s/%s/%s/%s luc %s', pa.qty, pa.value, pa.deficit_qty, pa.deficit_value, pa.last_unit_cost,
                                         pb.qty, pb.value, pb.deficit_qty, pb.deficit_value, pb.last_unit_cost), '; ')
        INTO v_bad, v_msg FROM inventory.cost_pool pa JOIN inventory.cost_pool pb
          ON pb.item_id = ib AND pb.warehouse_id IS NOT DISTINCT FROM pa.warehouse_id
       WHERE pa.item_id = ia AND ((pa.qty, pa.value, pa.deficit_qty, pa.deficit_value) IS DISTINCT FROM (pb.qty, pb.value, pb.deficit_qty, pb.deficit_value)
          OR pa.last_unit_cost IS DISTINCT FROM pb.last_unit_cost);
      PERFORM c_ok(v_bad = 0, format('T24 %s seed %s: pool states differ: %s', meth, seed, v_msg));
      SELECT count(*) INTO v_bad FROM inventory.cost_pool c WHERE c.item_id IN (ia, ib) AND inventory.verify_pool_replay(c.id) <> 0;
      PERFORM c_ok(v_bad = 0, format('T24 %s seed %s: replay disagrees', meth, seed));
    END LOOP;
  END LOOP;
END $$;

-- ---------- T25 (RV-COM-05): مصرف تجمعی مبدأ بها؛ مبدأ برگشت‌خورده ----------
DO $$
DECLARE o uuid; i1 uuid; s uuid; r1 uuid; r2 uuid; x uuid;
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_mv('CF','F1','NOD','receipt',20,'2026-07-01','{"value":20000}');
  o := c_mv('CF','F1','NOD','transfer_out',-10,'2026-07-02');
  i1 := c_mv('CF','F2','NOD','transfer_in',10,'2026-07-02', jsonb_build_object('rule','source','src', o));
  PERFORM c_err(format($q$SELECT c_mv('CF','F2','NOD','transfer_in',10,'2026-07-02', jsonb_build_object('rule','source','src', %L::uuid))$q$, o),
                'HK_INV_COST_SOURCE_EXHAUSTED', 'T25 one transfer_out cannot be received twice (no stock from thin air)');
  s := c_mv('CF','F1','NOD','sale_issue',-2,'2026-07-03');
  r1 := c_mv('CF','F1','NOD','sale_return',1,'2026-07-04', jsonb_build_object('rule','source','src', s));
  PERFORM c_err(format($q$SELECT c_mv('CF','F1','NOD','sale_return',2,'2026-07-04', jsonb_build_object('rule','source','src', %L::uuid))$q$, s),
                'HK_INV_COST_SOURCE_EXHAUSTED', 'T25 returns cannot exceed the sale cumulatively (3 of 2)');
  PERFORM c_err(format($q$SELECT c_mv('CF','F1','NOD','sale_issue',2,'2026-07-03', jsonb_build_object('rev', %L::uuid))$q$, s),
                'HK_INV_REVERSAL_HAS_DEPENDENTS', 'T25 a sale with a live return cannot be reversed');
  PERFORM c_mv('CF','F1','NOD','sale_return',-1,'2026-07-04', jsonb_build_object('rev', r1));
  r2 := c_mv('CF','F1','NOD','sale_return',2,'2026-07-05', jsonb_build_object('rule','source','src', s));
  PERFORM c_ok(c_mval(r2) = -c_mval(s), 'T25 reversing a return frees its share of the source');
  PERFORM c_mv('CF','F1','NOD','sale_return',-2,'2026-07-05', jsonb_build_object('rev', r2));
  x := c_mv('CF','F1','NOD','sale_issue',2,'2026-07-03', jsonb_build_object('rev', s));
  PERFORM c_err(format($q$SELECT c_mv('CF','F1','NOD','sale_return',1,'2026-07-06', jsonb_build_object('rule','source','src', %L::uuid))$q$, s),
                'HK_INV_COST_SOURCE', 'T25 a reversed (cancelled) move is no cost source');
END $$;

-- ---------- T26 (RV-COM-11): افتتاحیهٔ ابطال‌شده دوباره قابل ورود است؛ دو افتتاحیهٔ زنده نه ----------
DO $$
DECLARE o uuid; o2 uuid;
BEGIN
  PERFORM c_ctx('A');
  o := c_mv('CA','W9','LK','opening',7,'2026-03-21','{"value":700}');
  PERFORM c_err($q$SELECT c_mv('CA','W9','LK','opening',5,'2026-03-21','{"value":500}')$q$, 'HK_INV_OPENING_DUPLICATE', 'T26 one live opening per key');
  PERFORM c_mv('CA','W9','LK','opening',-7,'2026-03-21', jsonb_build_object('rev', o));
  o2 := c_mv('CA','W9','LK','opening',5,'2026-03-21','{"value":500}');
  PERFORM c_ok((SELECT qty FROM inventory.stock_balance WHERE warehouse_id = k('W9') AND variant_id = k('V.LK')) = 5,
               'T26 corrected opening after cancelling the wrong one (migration rollback + re-run)');
  PERFORM c_err($q$SELECT c_mv('CA','W9','LK','receipt',1,'2026-03-20','{"value":1}')$q$, 'HK_INV_POLICY_MISSING', 'T26 no move before the first policy');
END $$;

-- ---------- T27 (RV-COM-17): حساب GL موجودی روی هر حرکت دائمی؛ هیچ‌کدام در ادواری ----------
DO $$
DECLARE m uuid;
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_err($q$SELECT c_mv('CA','W1','X','receipt',1,'2026-07-10','{"value":1,"no_acct":true}')$q$,
                'HK_INV_ASSET_ACCOUNT_REQUIRED', 'T27 a perpetual move carries its resolved inventory account');
  PERFORM c_err($q$SELECT c_mv('CP','P1','X','receipt',1,'2026-07-10', jsonb_build_object('value', 1, 'acct', (SELECT id FROM ledger.account WHERE company_id = k('CP') AND code = '1401')))$q$,
                'HK_INV_PERIODIC_NO_GL', 'T27 a periodic move has no GL account');
  PERFORM c_err($q$SELECT c_mv('CP','P1','X','receipt',1,'2026-07-10','{"value":1,"contra":"purchase.grni"}')$q$,
                'HK_INV_PERIODIC_NO_GL', 'T27 a periodic move has no contra key');
  m := c_mv('CP','P1','X','receipt',1,'2026-07-10','{"value":100}');
  PERFORM c_ok((SELECT asset_account_id IS NULL AND contra_posting_key IS NULL FROM inventory.stock_move WHERE id = m), 'T27 periodic move accepted without GL fields');
  m := c_mv('CA','W1','X','sale_issue',-1,'2026-07-10');
  PERFORM c_ok((SELECT contra_posting_key FROM inventory.stock_move WHERE id = m) = 'inventory.cogs', 'T27 contra key defaults by move kind');
  PERFORM c_ok(NOT EXISTS (SELECT 1 FROM inventory.stock_move s JOIN inventory.company_policy p ON p.company_id = s.company_id
                            WHERE p.inventory_mode = 'perpetual' AND s.move_date >= p.effective_from AND s.asset_account_id IS NULL
                              AND NOT EXISTS (SELECT 1 FROM inventory.company_policy p2 WHERE p2.company_id = s.company_id
                                                AND p2.effective_from > p.effective_from AND p2.effective_from <= s.move_date)),
               'T27 no perpetual move is invisible to the inventory subledger');
END $$;

-- ---------- T28 (RV-COM-20): فروش آفلاین فقط از دستگاه ثبت‌شده و برای سند فروش ----------
DO $$
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_err($q$SELECT c_mv('CA','W2','NOD','sale_issue',-50,'2026-07-11','{"origin":"offline_device","module":"inventory","doc_type":"inventory.test"}')$q$,
                'stock_move_offline_device', 'T28 offline exemption only for sales/POS documents');
  PERFORM c_err($q$SELECT c_mv('CA','W2','NOD','sale_issue',-50,'2026-07-11', jsonb_build_object('origin','offline_device','device',k('DEV2')))$q$,
                'HK_INV_OFFLINE_DEVICE', 'T28 offline exemption only for an enrolled device');
  PERFORM c_err($q$SELECT c_move(jsonb_build_object('company',k('CA'),'wh',k('W2'),'item',k('I.NOD'),'variant',k('V.NOD'),'kind','sale_issue','qty',-50,
                    'date','2026-07-11','module','sales'))$q$,
                'HK_INV_NEGATIVE_STOCK', 'T28 an online sale cannot bypass the block policy');
  PERFORM c_ok(EXISTS (SELECT 1 FROM inventory.stock_move WHERE origin = 'offline_device' AND device_id = k('DEV1') AND source_module = 'sales'),
               'T28 the accepted offline sale names its device');
END $$;

-- ---------- T29 (RV-MD-01): نخستین حرکت یا فروش کالا را قفل می‌کند (واحد پایه، نوع، ردیابی) ----------
DO $$
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_ok((SELECT usage_locked_at IS NOT NULL FROM catalog.item WHERE id = k('I.LK')), 'T29 first stock move locks the item');
  PERFORM c_err($q$UPDATE catalog.item SET item_type = 'service' WHERE id = k('I.LK')$q$, 'HK_CATALOG_ITEM_LOCKED', 'T29 a stocked item cannot become a service');
  PERFORM c_err($q$UPDATE catalog.item SET track_batch = true WHERE id = k('I.LK')$q$, 'HK_CATALOG_ITEM_LOCKED', 'T29 tracking is frozen after the first move');
  PERFORM c_err($q$UPDATE catalog.item_uom SET factor = 2 WHERE item_id = k('I.LK')$q$, 'HK_CATALOG_ITEM_LOCKED', 'T29 unit factors are frozen after the first move');
END $$;

-- ---------- T30 (INV-SAL-01..03): قاعدهٔ قیمت و تخفیف ----------
DO $$
DECLARE r uuid := uuidv7();
BEGIN
  PERFORM c_ctx('A');
  INSERT INTO sales.pricing_rule (tenant_id, id, code, name, kind, discount_percent, valid_from, category_id)
  VALUES (k('A'), r, 'SPRING', 'حراج بهار', 'line_discount', 10, '2026-04-01', NULL);
  UPDATE sales.pricing_rule SET status = 'active' WHERE id = r;
  PERFORM c_err($q$INSERT INTO sales.pricing_rule (tenant_id, code, name, kind, discount_percent, discount_amount, currency, valid_from)
                  VALUES (k('A'), 'BAD1', 'بد', 'line_discount', 10, 1000, 'IRR', '2026-04-01')$q$, 'pricing_rule_kind_shape', 'T30 one discount value per line rule');
  PERFORM c_err($q$INSERT INTO sales.pricing_rule (tenant_id, code, name, kind, discount_percent, valid_from, item_id)
                  VALUES (k('A'), 'BAD2', 'بد', 'invoice_discount', 5, '2026-04-01', k('I.X'))$q$, 'pricing_rule_kind_shape', 'T30 invoice rule has no item scope');
  PERFORM c_err($q$INSERT INTO sales.pricing_rule (tenant_id, code, name, kind, discount_amount, valid_from)
                  VALUES (k('A'), 'BAD3', 'بد', 'line_discount', 1000, '2026-04-01')$q$, 'pricing_rule_currency', 'T30 amount needs currency');
  PERFORM c_err($q$INSERT INTO sales.pricing_rule (tenant_id, code, name, kind, buy_qty, free_qty, valid_from)
                  VALUES (k('A'), 'BAD4', 'بد', 'free_item', 2, 1, '2026-04-01')$q$, 'pricing_rule_kind_shape', 'T30 free item needs its SKU and unit');
  PERFORM c_err($q$INSERT INTO sales.pricing_rule (tenant_id, code, version, name, kind, discount_percent, valid_from, status)
                  VALUES (k('A'), 'SPRING', 2, 'حراج بهار ۲', 'line_discount', 15, '2026-05-01', 'active')$q$, '23P01', 'T30 one active version per code and date');
  PERFORM c_err($q$INSERT INTO sales.pricing_rule (tenant_id, code, name, kind, discount_percent, valid_from, weekdays) VALUES (k('A'), 'BAD5', 'بد', 'line_discount', 5, '2026-04-01', '{7}')$q$,
                '23514', 'T30 weekdays are 0..6 (Saturday = 0)');
  PERFORM c_err(format($q$INSERT INTO sales.pricing_rule_tier (tenant_id, rule_id, min_qty, discount_percent) VALUES (k('A'), %L, 10, 5)$q$, r),
                'HK_SALES_RULE_USED', 'T30 tiers only on draft rules');
  UPDATE sales.pricing_rule SET first_used_at = now() WHERE id = r;
  PERFORM c_err(format($q$UPDATE sales.pricing_rule SET discount_percent = 20 WHERE id = %L$q$, r), 'HK_SALES_RULE_USED', 'T30 used rule content immutable');
  PERFORM c_err(format($q$UPDATE sales.pricing_rule SET first_used_at = now() + interval '1 day' WHERE id = %L$q$, r), 'HK_SALES_RULE_USED', 'T30 first_used_at write-once');
  PERFORM c_err(format($q$DELETE FROM sales.pricing_rule WHERE id = %L$q$, r), 'HK_SALES_RULE_USED', 'T30 used rule cannot be deleted');
  UPDATE sales.pricing_rule SET valid_to = '2026-06-30' WHERE id = r;
  PERFORM c_err(format($q$UPDATE sales.pricing_rule SET valid_to = '2026-07-30' WHERE id = %L$q$, r), 'HK_SALES_RULE_USED', 'T30 validity can only shorten');
  UPDATE sales.pricing_rule SET status = 'retired' WHERE id = r;
  PERFORM c_err(format($q$UPDATE sales.pricing_rule SET name = 'تغییر' WHERE id = %L$q$, r), 'HK_SALES_RULE_USED', 'T30 retired rules are immutable');
  -- قاعدهٔ بستهٔ صنفی در هر شرکت جدا نصب می‌شود (RV-COM-21)
  INSERT INTO sales.pricing_rule (tenant_id, company_id, code, name, kind, discount_percent, valid_from, status, source_pack, source_pack_version)
  VALUES (k('A'), k('CA'), 'HAPPY_HOUR', 'ساعت خوش', 'line_discount', 10, '2026-04-01', 'active', 'cafe', '1.0.0'),
         (k('A'), k('CF'), 'HAPPY_HOUR', 'ساعت خوش', 'line_discount', 10, '2026-04-01', 'active', 'cafe', '1.0.0');
  PERFORM c_err($q$INSERT INTO sales.pricing_rule (tenant_id, company_id, code, name, kind, discount_percent, valid_from)
                  VALUES (k('A'), k('CA'), 'HAPPY_HOUR', 'تکراری', 'line_discount', 5, '2026-04-01')$q$, '23505', 'T30 code+version unique per company');
  PERFORM c_err($q$INSERT INTO sales.pricing_rule (tenant_id, company_id, code, version, name, kind, discount_percent, valid_from, status)
                  VALUES (k('A'), k('CA'), 'HAPPY_HOUR', 2, 'نسخهٔ ۲', 'line_discount', 5, '2026-05-01', 'active')$q$, '23P01', 'T30 one active version per company and code');
  PERFORM c_err($q$INSERT INTO sales.pricing_rule (tenant_id, code, name, kind, discount_percent, valid_from, first_used_at)
                  VALUES (k('A'), 'USEDNEW', 'بد', 'line_discount', 5, '2026-04-01', now())$q$, 'HK_SALES_RULE_USED', 'T30 first_used_at is set by posting only');
  INSERT INTO sales.pricing_rule (tenant_id, id, code, version, name, kind, valid_from) VALUES (k('A'), uuidv7(), 'TIER', 1, 'پلکانی', 'tiered', '2026-04-01');
  INSERT INTO sales.pricing_rule_tier (tenant_id, rule_id, min_qty, discount_percent)
  SELECT k('A'), id, 10, 5 FROM sales.pricing_rule WHERE code = 'TIER';
  PERFORM c_err($q$INSERT INTO sales.pricing_rule_tier (tenant_id, rule_id, min_qty, discount_percent, discount_amount)
                  SELECT k('A'), id, 20, 5, 100 FROM sales.pricing_rule WHERE code = 'TIER'$q$, '23514', 'T30 one benefit per tier');
END $$;

-- ---------- T31 (INV-SAL-04/05): پیش‌فاکتور و سفارش ----------
DO $$
DECLARE q uuid := uuidv7(); o uuid := uuidv7(); ol uuid; n uuid;
BEGIN
  PERFORM c_ctx('A');
  INSERT INTO sales."order" (tenant_id, id, company_id, branch_id, kind, doc_date, valid_until, customer_party_id, currency)
  VALUES (k('A'), q, k('CA'), k('BA'), 'quotation', '2026-05-01', '2026-05-15', k('C2'), 'IRR');
  INSERT INTO sales.order_line (tenant_id, order_id, line_no, item_id, variant_id, uom_id, qty, qty_base, unit_price, net_amount)
  VALUES (k('A'), q, 1, k('I.X'), k('V.X'), k('PCS'), 2, 2, 150000, 300000);
  n := c_num(k('CA'), 'sales.quotation', q);
  UPDATE sales."order" SET status = 'open', number_issued_id = n, doc_no = c_no(n) WHERE id = q;
  PERFORM c_err(format($q$UPDATE sales."order" SET status = 'confirmed', confirmed_at = now() WHERE id = %L$q$, q), 'HK_COMMERCE_DOC_TRANSITION', 'T31 quotation is never confirmed');
  PERFORM c_err(format($q$UPDATE sales."order" SET customer_party_id = k('C1') WHERE id = %L$q$, q), 'HK_COMMERCE_DOC_IMMUTABLE', 'T31 sent quotation immutable');
  UPDATE sales."order" SET notes = 'پیگیری تلفنی' WHERE id = q;
  INSERT INTO sales."order" (tenant_id, id, company_id, branch_id, kind, doc_date, customer_party_id, currency, quotation_id)
  VALUES (k('A'), o, k('CA'), k('BA'), 'order', '2026-05-02', k('C2'), 'IRR', q);
  INSERT INTO sales.order_line (tenant_id, id, order_id, line_no, item_id, variant_id, uom_id, qty, qty_base, unit_price, net_amount)
  VALUES (k('A'), '30a00000-0000-7000-8000-0000000f0101', o, 1, k('I.X'), k('V.X'), k('PCS'), 2, 2, 150000, 300000);
  n := c_num(k('CA'), 'sales.order', o);
  UPDATE sales."order" SET status = 'confirmed', confirmed_at = now(), number_issued_id = n, doc_no = c_no(n) WHERE id = o;
  UPDATE sales."order" SET status = 'won' WHERE id = q;
  PERFORM c_err(format($q$INSERT INTO sales.order_line (tenant_id, order_id, line_no, item_id, variant_id, uom_id, qty, qty_base, unit_price, net_amount)
                         VALUES (k('A'), %L, 2, k('I.X'), k('V.X'), k('PCS'), 1, 1, 1, 1)$q$, o), 'HK_COMMERCE_DOC_IMMUTABLE', 'T31 confirmed order lines immutable');
  PERFORM c_err($q$INSERT INTO sales."order" (tenant_id, company_id, branch_id, kind, doc_date, customer_party_id, currency, status)
                  VALUES (k('A'), k('CA'), k('BA'), 'order', '2026-05-02', k('C2'), 'IRR', 'confirmed')$q$, 'HK_COMMERCE_DOC_TRANSITION', 'T31 orders start as draft');
  PERFORM c_err($q$INSERT INTO sales."order" (tenant_id, company_id, branch_id, kind, doc_date, valid_until, customer_party_id, currency)
                  VALUES (k('A'), k('CA'), k('BA'), 'order', '2026-05-02', '2026-05-20', k('C2'), 'IRR')$q$, 'order_valid_until', 'T31 validity only on quotations');
END $$;

-- ---------- T32 (INV-SAL-06..09): حساب سطر فاکتور (قواعد مؤدیان: قطع، نه گرد) ----------
DO $$
DECLARE i uuid;
BEGIN
  PERFORM c_ctx('A');
  i := c_inv('{"moadian":false}');
  -- نمونهٔ RC_TICS: am=2، fee=10000، dis=500، vra=9 ⇒ vam=1755، tsstam=21255
  PERFORM c_line(i, 1, 'SRV', 2, 10000, '{"ld":500,"vat":9}');
  PERFORM c_ok((SELECT vat_amount = 1755 AND line_total = 21255 FROM sales.invoice_line WHERE invoice_id = i AND line_no = 1), 'T32 RC_TICS golden vector');
  -- قطع: adis = 99999، vra = 10 ⇒ vam = 9999 (نه 10000)
  PERFORM c_line(i, 2, 'SRV', 1, 99999, '{"vat":10}');
  PERFORM c_ok((SELECT vat_amount FROM sales.invoice_line WHERE invoice_id = i AND line_no = 2) = 9999, 'T32 VAT is truncated');
  PERFORM c_err(format($q$SELECT c_line(%L, 3, 'SRV', 1, 99999, '{"vat":10,"vam":10000}')$q$, i), 'invoice_line_vat', 'T32 rounded VAT rejected');
  PERFORM c_err(format($q$SELECT c_line(%L, 3, 'SRV', 3, 5, '{"gross":16}')$q$, i), 'invoice_line_gross', 'T32 prdis = trunc(am × fee)');
  PERFORM c_err(format($q$SELECT c_line(%L, 3, 'SRV', 3, 0.5, '{"gross":1}')$q$, i), 'HK_SALES_UNIT_PRICE_MINOR', 'T32 rial fee is an integer (RV-COM-16)');
  PERFORM c_err($q$SELECT c_inv('{"currency":"IRR","minor":2}')$q$, 'HK_COMMERCE_CURRENCY_MINOR', 'T32 currency_minor snapshot = ref.currency minor unit');
  PERFORM c_err($q$SELECT c_inv('{"currency":"USD","minor":2}')$q$, 'HK_SALES_MOADIAN_CURRENCY', 'T32 v1 Moadian invoices are in rials');
  PERFORM c_err(format($q$SELECT c_line(%L, 3, 'SRV', 1, 100, '{"minor":2}')$q$, i), 'HK_SALES_LINE_MINOR', 'T32 line minor = invoice minor');
  PERFORM c_err(format($q$SELECT c_line(%L, 3, 'NOD', 1, 100, '{"ld":10}')$q$, i), 'HK_SALES_DISCOUNT_NOT_ALLOWED', 'T32 item without discounts');
  PERFORM c_err(format($q$SELECT c_line(%L, 3, 'NOD', 1, 100, '{"price_source":"manual"}')$q$, i), 'HK_SALES_PRICE_OVERRIDE_NOT_ALLOWED', 'T32 item without manual price');
  PERFORM c_err(format($q$SELECT c_line(%L, 3, 'SRV', 1, 100, jsonb_build_object('orig', (SELECT id FROM sales.invoice_line WHERE invoice_id = %L AND line_no = 1)))$q$, i, i),
                'HK_SALES_ORIGINAL_LINE_REQUIRED', 'T32 plain invoice has no original line');
  PERFORM c_err(format($q$SELECT c_line(%L, 3, 'X', 1, 100, '{"line_kind":"service_charge"}')$q$, i), 'HK_SALES_SERVICE_CHARGE_LINE', 'T32 service charge is a non-stock line');
  PERFORM c_err(format($q$SELECT c_line(%L, 3, 'SRV', 1, 1000, '{"otr":5}')$q$, i), 'invoice_line_other_tax', 'T32 other tax needs its code');
  PERFORM c_line(i, 3, 'SRV', 1, 1000, '{"otr":5,"otc":"DUTY"}');
  PERFORM c_err(format($q$SELECT c_line(%L, 4, 'SRV', 1, 100, '{"ld":200}')$q$, i), '23514', 'T32 discount cannot exceed the line');
  DELETE FROM sales.invoice WHERE id = i;
END $$;

-- ---------- T33 (INV-SAL-10..17): ثبت فاکتور و راستی‌آزمایی‌های deferred ----------
DO $$
DECLARE i uuid := '30a00000-0000-7000-8000-0000000f0201'; v uuid;
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_inv(jsonb_build_object('id', i, 'order', (SELECT order_id FROM sales.order_line WHERE id = '30a00000-0000-7000-8000-0000000f0101')));
  PERFORM c_line(i, 1, 'X', 2, 150000, jsonb_build_object('ld', 10000, 'ia', 3000, 'id', '30a00000-0000-7000-8000-0000000f0211',
                                                            'order_line', '30a00000-0000-7000-8000-0000000f0101'));
  PERFORM c_line(i, 2, 'SRV', 1, 50000, jsonb_build_object('ia', 2000, 'id', '30a00000-0000-7000-8000-0000000f0212'));
  INSERT INTO sales.invoice_salesperson (tenant_id, invoice_id, party_id, share_percent) VALUES (k('A'), i, k('AG1'), 100);
  PERFORM c_post(i);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM c_ok((SELECT status = 'posted' AND total_amount = (290000 - 3000) + 28700 + (50000 - 2000) + 4800 FROM sales.invoice WHERE id = i),
               'T33 posted invoice totals');
  PERFORM c_ok((SELECT count(*) FROM inventory.stock_move WHERE source_doc_id = i) = 1, 'T33 stock line issued once; service has no move');
  PERFORM c_ok((SELECT current_total FROM sales.v_invoice_current WHERE invoice_id = i) = (SELECT total_amount FROM sales.invoice WHERE id = i),
               'T33 current total of an uncorrected invoice');
  PERFORM c_ok((SELECT invoiced_base FROM sales.v_order_line_progress WHERE order_line_id = '30a00000-0000-7000-8000-0000000f0101') = 2, 'T33 order progress');
  PERFORM c_ok((SELECT cost_amount > 0 FROM sales.v_invoice_line_margin WHERE line_id = '30a00000-0000-7000-8000-0000000f0211'), 'T33 margin from stock moves');
  -- منفی‌ها (هر کدام در زیرتراکنش)
  PERFORM c_err($q$SELECT c_post(c_inv('{}'), '{"dummy_gl":true}') $q$, 'HK_SALES_EMPTY', 'T33 empty invoice');
  PERFORM c_err($q$WITH h AS (SELECT c_inv('{}') AS id), l AS (SELECT c_line(h.id, 1, 'X', 1, 1000, '{}') FROM h) SELECT c_post(h.id, '{"adjust":5,"dummy_gl":true}') FROM h, l$q$,
                'HK_SALES_TOTALS', 'T33 header totals must match lines');
  PERFORM c_err($q$WITH h AS (SELECT c_inv('{}') AS id), l AS (SELECT c_line(h.id, 1, 'X', 1, 1000, '{"ld":10,"no_trace":true}') FROM h) SELECT c_post(h.id, '{"dummy_gl":true}') FROM h, l$q$,
                'HK_SALES_DISCOUNT_TRACE', 'T33 discount trace must explain the discount');
  PERFORM c_err($q$WITH h AS (SELECT c_inv('{}') AS id), l AS (SELECT c_line(h.id, 1, 'X', 1, 1000, '{}') FROM h) SELECT c_post(h.id, '{"skip_stock":true}') FROM h, l$q$,
                'HK_SALES_STOCK_LINK', 'T33 stock line needs its stock move');
  PERFORM c_err($q$WITH h AS (SELECT c_inv('{}') AS id), l AS (SELECT c_line(h.id, 1, 'SRV', 1, 1000, '{}') FROM h) SELECT c_post(h.id, '{"gl_other":true}') FROM h, l$q$,
                'HK_COMMERCE_GL_LINK', 'T33 GL journal must originate from the invoice');
  PERFORM c_err($q$WITH h AS (SELECT c_inv('{}') AS id), l AS (SELECT c_line(h.id, 1, 'SRV', 1, 1000, '{}') FROM h) SELECT c_post(h.id, '{"dummy_gl":true}') FROM h, l$q$,
                'HK_COMMERCE_GL_AMOUNT', 'T33 GL journal amounts equal the invoice (receivable, revenue, VAT; RV-IT2-09)');
  PERFORM c_err($q$WITH h AS (SELECT c_inv('{}') AS id), l AS (SELECT c_line(h.id, 1, 'SRV', 1, 1000, '{}') FROM h) SELECT c_post(h.id, '{"gl_off":7}') FROM h, l$q$,
                'HK_COMMERCE_GL_AMOUNT', 'T33 a balanced journal with a wrong receivable/revenue is rejected');
  PERFORM c_err($q$WITH h AS (SELECT c_inv('{}') AS id), l AS (SELECT c_line(h.id, 1, 'X', 1, 1000, '{}') FROM h) SELECT c_post(h.id, '{"no_stock_gl":true}') FROM h, l$q$,
                'HK_COMMERCE_STOCK_GL_MISSING', 'T33 COGS/inventory lines come in the inventory journal (RV-IT2-01)');
  PERFORM c_err($q$WITH h AS (SELECT c_inv('{}') AS id), l AS (SELECT c_line(h.id, 1, 'X', 1, 1000, '{}') FROM h) SELECT c_post(h.id, '{"stock_gl_off":3}') FROM h, l$q$,
                'HK_COMMERCE_GL_AMOUNT', 'T33 inventory journal equals the issue value');
  PERFORM c_err($q$WITH h AS (SELECT c_inv('{}') AS id), l AS (SELECT c_line(h.id, 1, 'SRV', 1, 1000, '{}') FROM h) SELECT c_post(h.id, '{"num_other":true,"dummy_gl":true}') FROM h, l$q$,
                'HK_COMMERCE_NUMBER_LINK', 'T33 number must be issued to this invoice');
  PERFORM c_err($q$WITH h AS (SELECT c_inv('{}') AS id), l AS (SELECT c_line(h.id, 1, 'SRV', 1, 1000, '{}') FROM h) SELECT c_post(h.id, '{"no_gl":true}') FROM h, l$q$,
                'invoice_gl_shape', 'T33 per-document GL is mandatory');
  PERFORM c_err($q$WITH h AS (SELECT c_inv('{"customer":"30a00000-0000-7000-8000-00000000a101","buyer_type":"natural","buyer_eco":null}') AS id),
                       l AS (SELECT c_line(h.id, 1, 'SRV', 1, 1000, '{}') FROM h) SELECT c_post(h.id, '{"dummy_gl":true}') FROM h, l$q$,
                'HK_SALES_MOADIAN_BUYER', 'T33 type-1 natural buyer needs economic code or national id + postal code');
  PERFORM c_err($q$WITH h AS (SELECT c_inv('{}') AS id), l AS (SELECT c_line(h.id, 1, 'SRV', 1, 1000, '{"no_sstid":true}') FROM h) SELECT c_post(h.id, '{"dummy_gl":true}') FROM h, l$q$,
                'HK_SALES_MOADIAN_FIELDS', 'T33 every line needs sstid');
  PERFORM c_err($q$WITH h AS (SELECT c_inv('{"inty":2}') AS id), l AS (SELECT c_line(h.id, 1, 'SRV', 1, 1000, '{}') FROM h) SELECT c_post(h.id, '{"dummy_gl":true}') FROM h, l$q$,
                'HK_SALES_MOADIAN_SETTLEMENT', 'T33 type-2 is cash only');
  PERFORM c_err($q$SELECT c_inv('{"setm":"mixed","cash":100,"id":"30a00000-0000-7000-8000-0000000f02fe"}');
                   SELECT c_line('30a00000-0000-7000-8000-0000000f02fe', 1, 'SRV', 1, 1000, '{}');
                   SELECT c_totals('30a00000-0000-7000-8000-0000000f02fe');
                   UPDATE sales.invoice SET credit_amount = credit_amount + 1 WHERE id = '30a00000-0000-7000-8000-0000000f02fe'$q$,
                'invoice_settlement_split', 'T33 mixed settlement split checked on drafts too');
  PERFORM c_err($q$WITH h AS (SELECT c_inv('{}') AS id), l AS (SELECT c_line(h.id, 1, 'SRV', 1, 1000, '{}') FROM h),
                     s AS (INSERT INTO sales.invoice_salesperson (tenant_id, invoice_id, party_id, share_percent) SELECT k('A'), h.id, k('AG1'), 60 FROM h RETURNING 1)
                   SELECT c_post(h.id, '{"dummy_gl":true}') FROM h, l, s$q$, 'HK_SALES_SHARES', 'T33 salesperson shares sum to 100');
  PERFORM c_err($q$SELECT c_inv('{"id":"30a00000-0000-7000-8000-0000000f02ff"}'); UPDATE sales.invoice SET warehouse_id = NULL WHERE id = '30a00000-0000-7000-8000-0000000f02ff'$q$,
                'invoice_stock_mode', 'T33 immediate stock needs a warehouse');
END $$;

-- ---------- T34 (INV-SAL-18): تغییرناپذیری فاکتور ثبت‌شده ----------
DO $$
DECLARE i uuid := '30a00000-0000-7000-8000-0000000f0201';
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_err(format($q$UPDATE sales.invoice SET notes = 'ویرایش' WHERE id = %L$q$, i), 'HK_COMMERCE_DOC_IMMUTABLE', 'T34 posted header immutable');
  PERFORM c_err(format($q$UPDATE sales.invoice SET status = 'draft' WHERE id = %L$q$, i), 'HK_COMMERCE_DOC_TRANSITION', 'T34 posted → draft');
  PERFORM c_err(format($q$DELETE FROM sales.invoice WHERE id = %L$q$, i), 'HK_COMMERCE_DOC_IMMUTABLE', 'T34 posted cannot be deleted');
  PERFORM c_err($q$UPDATE sales.invoice_line SET description = 'x' WHERE id = '30a00000-0000-7000-8000-0000000f0211'$q$, 'HK_COMMERCE_DOC_IMMUTABLE', 'T34 posted lines immutable');
  PERFORM c_err($q$DELETE FROM sales.invoice_line_discount WHERE line_id = '30a00000-0000-7000-8000-0000000f0211'$q$, 'HK_COMMERCE_DOC_IMMUTABLE', 'T34 discount trace immutable');
  PERFORM c_err(format($q$UPDATE sales.invoice_salesperson SET share_percent = 50 WHERE invoice_id = %L$q$, i), 'HK_COMMERCE_DOC_IMMUTABLE', 'T34 shares immutable');
  PERFORM c_err($q$UPDATE sales."order" SET status = 'cancelled', cancel_reason = 'انصراف' WHERE id = (SELECT order_id FROM sales.order_line WHERE id = '30a00000-0000-7000-8000-0000000f0101')$q$,
                'HK_SALES_ORDER_FULFILLED', 'T34 invoiced order cannot be cancelled');
END $$;

-- ---------- T35 (INV-SAL-19..21): برگشت از فروش ----------
DO $$
DECLARE i uuid := '30a00000-0000-7000-8000-0000000f0201'; r uuid := '30a00000-0000-7000-8000-0000000f0301'; x uuid;
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_inv(jsonb_build_object('id', r, 'kind', 'return', 'original', i, 'date', '2026-05-12'));
  PERFORM c_line(r, 1, 'X', 1, 150000, jsonb_build_object('orig', '30a00000-0000-7000-8000-0000000f0211', 'ld', 5000, 'ia', 1500));
  PERFORM c_post(r);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM c_ok((SELECT returned_qty FROM sales.v_line_returnable WHERE line_id = '30a00000-0000-7000-8000-0000000f0211') = 1, 'T35 returned qty tracked');
  PERFORM c_ok((SELECT move_kind = 'sale_return' AND qty_base = 1 FROM inventory.stock_move WHERE source_doc_id = r), 'T35 return restocks at source cost');
  PERFORM c_err(format($q$WITH h AS (SELECT c_inv(jsonb_build_object('kind','return','original',%L::uuid,'date','2026-05-12')) AS id),
                         l AS (SELECT c_line(h.id, 1, 'X', 2, 150000, jsonb_build_object('orig','30a00000-0000-7000-8000-0000000f0211','ld',10000,'ia',3000)) FROM h)
                         SELECT c_post(h.id, '{"skip_stock":true}') FROM h, l$q$, i), 'HK_SALES_RETURN_QTY', 'T35 cannot return more than remaining');
  PERFORM c_err(format($q$WITH h AS (SELECT c_inv(jsonb_build_object('kind','return','original',%L::uuid,'date','2026-05-12')) AS id),
                         l AS (SELECT c_line(h.id, 1, 'X', 2, 150000, jsonb_build_object('orig','30a00000-0000-7000-8000-0000000f0211','ld',10000,'ia',3000)) FROM h)
                         SELECT c_post(h.id) FROM h, l$q$, i), 'HK_INV_COST_SOURCE_EXHAUSTED', 'T35 restock cannot exceed the issue move (cumulative; RV-COM-05)');
  -- تخفیف برگشت = سهم نسبی تخفیف سطر فروش (RV-X2-03): برگشت واحد آخر بی‌تخفیف بیش از پرداختی مشتری بستانکار می‌کند
  PERFORM c_err(format($q$WITH h AS (SELECT c_inv(jsonb_build_object('kind','return','original',%L::uuid,'date','2026-05-12')) AS id),
                         l AS (SELECT c_line(h.id, 1, 'X', 1, 150000, jsonb_build_object('orig','30a00000-0000-7000-8000-0000000f0211')) FROM h)
                         SELECT c_post(h.id) FROM h, l$q$, i), 'HK_SALES_RETURN_DISCOUNT', 'T35 return carries the proportional discount of the sold line');
  PERFORM c_err(format($q$WITH h AS (SELECT c_inv(jsonb_build_object('kind','return','original',%L::uuid,'date','2026-05-12')) AS id),
                         l AS (SELECT c_line(h.id, 1, 'X', 1, 150000, jsonb_build_object('orig','30a00000-0000-7000-8000-0000000f0211','ld',5000,'ia',1000)) FROM h)
                         SELECT c_post(h.id) FROM h, l$q$, i), 'HK_SALES_RETURN_DISCOUNT', 'T35 invoice-discount share of the return is proportional too');
  PERFORM c_err(format($q$WITH h AS (SELECT c_inv(jsonb_build_object('kind','return','original',%L::uuid,'date','2026-05-12')) AS id),
                         l AS (SELECT c_line(h.id, 1, 'X', 1, 150000, jsonb_build_object('orig','30a00000-0000-7000-8000-0000000f0211','ld',5000,'ia',1500)) FROM h)
                         SELECT c_post(h.id, '{"rule":"input"}') FROM h, l$q$, i), 'HK_SALES_RETURN_COST', 'T35 return restocks at the original issue cost, not a typed cost');
  PERFORM c_err(format($q$WITH h AS (SELECT c_inv(jsonb_build_object('kind','return','original',%L::uuid,'date','2026-05-12')) AS id),
                         l AS (SELECT c_line(h.id, 1, 'X', 1, 150000, jsonb_build_object('orig','30a00000-0000-7000-8000-0000000f0211','ld',5000,'ia',1500,
                                                                                          'sstid','2710000999999')) FROM h)
                         SELECT c_post(h.id) FROM h, l$q$, i), 'HK_SALES_RETURN_LINE', 'T35 return keeps the Moadian item id (sstid)');
  PERFORM c_err(format($q$WITH h AS (SELECT c_inv(jsonb_build_object('kind','return','original',%L::uuid,'date','2026-05-12')) AS id),
                         l AS (SELECT c_line(h.id, 1, 'X', 1, 140000, jsonb_build_object('orig','30a00000-0000-7000-8000-0000000f0211')) FROM h)
                         SELECT c_post(h.id, '{"skip_stock":true}') FROM h, l$q$, i), 'HK_SALES_RETURN_PRICE', 'T35 return keeps the unit price (Moadian ins=4)');
  PERFORM c_err(format($q$WITH h AS (SELECT c_inv(jsonb_build_object('kind','return','original',%L::uuid,'date','2026-05-12','customer','30a00000-0000-7000-8000-00000000a101')) AS id),
                         l AS (SELECT c_line(h.id, 1, 'X', 1, 150000, jsonb_build_object('orig','30a00000-0000-7000-8000-0000000f0211')) FROM h)
                         SELECT c_post(h.id, '{"skip_stock":true}') FROM h, l$q$, i), 'HK_SALES_ORIGINAL_INVOICE', 'T35 return for the same customer');
  PERFORM c_err(format($q$WITH h AS (SELECT c_inv(jsonb_build_object('kind','return','original',%L::uuid,'date','2026-05-01')) AS id),
                         l AS (SELECT c_line(h.id, 1, 'X', 1, 150000, jsonb_build_object('orig','30a00000-0000-7000-8000-0000000f0211')) FROM h)
                         SELECT c_post(h.id, '{"skip_stock":true}') FROM h, l$q$, i), 'HK_SALES_ORIGINAL_INVOICE', 'T35 return cannot predate the invoice');
  PERFORM c_err(format($q$WITH h AS (SELECT c_inv(jsonb_build_object('kind','return','original',%L::uuid,'date','2026-05-12')) AS id)
                         SELECT c_line(h.id, 1, 'X', 1, 150000, '{}') FROM h$q$, i), 'HK_SALES_ORIGINAL_LINE_REQUIRED', 'T35 return line references the sold line');
  PERFORM c_err($q$SELECT c_inv('{"kind":"return"}')$q$, 'invoice_chain_shape', 'T35 return needs the original invoice');
END $$;

-- ---------- T36 (INV-SAL-22..24): صورتحساب اصلاحی (ins=2) ----------
DO $$
DECLARE i uuid := '30a00000-0000-7000-8000-0000000f0201'; c uuid := '30a00000-0000-7000-8000-0000000f0401';
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_inv(jsonb_build_object('id', c, 'kind', 'correction', 'original', i, 'supersedes', i, 'date', '2026-05-13'));
  PERFORM c_line(c, 1, 'X', 2, 150000, jsonb_build_object('orig', '30a00000-0000-7000-8000-0000000f0211', 'ld', 10000, 'ia', 3000));
  PERFORM c_line(c, 2, 'SRV', 1, 40000, jsonb_build_object('orig', '30a00000-0000-7000-8000-0000000f0212', 'ia', 2000));
  PERFORM c_post(c);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM c_ok((sales.current_line('30a00000-0000-7000-8000-0000000f0212')).unit_price = 40000, 'T36 current line follows the latest correction');
  PERFORM c_ok((SELECT current_total = (SELECT total_amount FROM sales.invoice WHERE id = c) AND current_version_id = c
                  FROM sales.v_invoice_current WHERE invoice_id = i), 'T36 current version follows the latest correction');
  PERFORM c_err(format($q$WITH h AS (SELECT c_inv(jsonb_build_object('kind','correction','original',%L::uuid,'supersedes',%L::uuid,'date','2026-05-14')) AS id),
                         l AS (SELECT c_line(h.id, 1, 'SRV', 1, 30000, jsonb_build_object('orig','30a00000-0000-7000-8000-0000000f0212')) FROM h)
                         SELECT c_post(h.id) FROM h, l$q$, i, i), '23505', 'T36 only the latest version can be corrected');
  PERFORM c_err(format($q$WITH h AS (SELECT c_inv(jsonb_build_object('kind','correction','original',%L::uuid,'supersedes',%L::uuid,'date','2026-05-14','buyer_eco','10100302746')) AS id),
                         l AS (SELECT c_line(h.id, 1, 'SRV', 1, 30000, jsonb_build_object('orig','30a00000-0000-7000-8000-0000000f0212')) FROM h)
                         SELECT c_post(h.id) FROM h, l$q$, i, c), 'HK_SALES_CORRECTION_SCOPE', 'T36 correction keeps the buyer identity sent to Moadian (RV-COM-14)');
  PERFORM c_err(format($q$WITH h AS (SELECT c_inv(jsonb_build_object('kind','correction','original',%L::uuid,'supersedes',%L::uuid,'date','2026-05-14')) AS id),
                         l AS (SELECT c_line(h.id, 1, 'SRV', 1, 30000, jsonb_build_object('orig','30a00000-0000-7000-8000-0000000f0212','sstid','2710000999999')) FROM h)
                         SELECT c_post(h.id) FROM h, l$q$, i, c), 'HK_SALES_CORRECTION_LINE', 'T36 correction keeps the Moadian item id (sstid)');
  PERFORM c_err(format($q$WITH h AS (SELECT c_inv(jsonb_build_object('kind','correction','original',%L::uuid,'supersedes',%L::uuid,'date','2026-05-14')) AS id),
                         l AS (SELECT c_line(h.id, 1, 'X', 1, 150000, jsonb_build_object('orig','30a00000-0000-7000-8000-0000000f0211')) FROM h)
                         SELECT c_post(h.id) FROM h, l$q$, i, c), 'HK_SALES_CORRECTION_LINE', 'T36 stock quantity changes only by return');
  PERFORM c_err(format($q$WITH h AS (SELECT c_inv(jsonb_build_object('kind','correction','original',%L::uuid,'supersedes',%L::uuid,'date','2026-05-14','inty',2,'setm','cash')) AS id),
                         l AS (SELECT c_line(h.id, 1, 'SRV', 1, 30000, jsonb_build_object('orig','30a00000-0000-7000-8000-0000000f0212')) FROM h)
                         SELECT c_post(h.id) FROM h, l$q$, i, c), 'HK_SALES_CORRECTION_SCOPE', 'T36 correction keeps the invoice type');
  PERFORM c_err(format($q$WITH h AS (SELECT c_inv(jsonb_build_object('kind','correction','original',%L::uuid,'supersedes',%L::uuid,'date','2026-05-14')) AS id),
                         l AS (SELECT c_line(h.id, 1, 'SRV', 1, 30000, jsonb_build_object('orig','30a00000-0000-7000-8000-0000000f0212','vat',9)) FROM h)
                         SELECT c_post(h.id) FROM h, l$q$, i, c), 'HK_SALES_CORRECTION_LINE', 'T36 correction keeps the VAT rate');
  PERFORM c_err(format($q$SELECT c_inv(jsonb_build_object('kind','correction','original',%L::uuid,'supersedes',%L::uuid,'stock_mode','immediate'))$q$, i, c),
                'invoice_correction_no_stock', 'T36 correction moves no stock');
  -- برگشت پس از اصلاحی: قیمت جاری
  PERFORM c_err(format($q$WITH h AS (SELECT c_inv(jsonb_build_object('kind','return','original',%L::uuid,'date','2026-05-14','stock_mode','none')) AS id),
                         l AS (SELECT c_line(h.id, 1, 'SRV', 1, 50000, jsonb_build_object('orig','30a00000-0000-7000-8000-0000000f0212')) FROM h)
                         SELECT c_post(h.id) FROM h, l$q$, i), 'HK_SALES_RETURN_PRICE', 'T36 return after correction uses the corrected price');
END $$;

-- ---------- T38 (INV-SAL-26..28): ابطال فاکتور ----------
DO $$
DECLARE i uuid := '30a00000-0000-7000-8000-0000000f0201'; j uuid := '30a00000-0000-7000-8000-0000000f0501'; s uuid;
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_err(format($q$SELECT c_cancel(%L, '{"skip_stock":true}')$q$, i), 'HK_SALES_CANCEL_HAS_DEPENDENTS', 'T38 cancel returns/corrections first');
  PERFORM c_err(format($q$SELECT c_cancel(%L)$q$, i), 'HK_INV_REVERSAL_HAS_DEPENDENTS', 'T38 the sold move cannot be reversed under a live return');
  PERFORM c_inv(jsonb_build_object('id', j, 'setm', 'cash', 'date', '2026-05-20'));
  PERFORM c_line(j, 1, 'X', 1, 150000);
  PERFORM c_post(j);
  PERFORM c_err(format($q$SELECT c_cancel(%L, '{"skip_stock":true}')$q$, j), 'HK_SALES_CANCEL_STOCK', 'T38 every stock move is reversed');
  PERFORM c_err(format($q$SELECT c_cancel(%L, '{"no_gl":true}')$q$, j), 'invoice_cancel_gl', 'T38 cancel needs its GL journal');
  PERFORM c_err(format($q$SELECT c_cancel(%L, '{"gl_other":true}')$q$, j), 'HK_COMMERCE_GL_LINK', 'T38 cancel journal must reference the invoice');
  PERFORM c_err(format($q$SELECT c_cancel(%L, '{"no_reverse":true}')$q$, j), 'HK_COMMERCE_GL_NOT_REVERSED', 'T38 the invoice journals are reversed on cancel');
  PERFORM c_cancel(j);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM c_ok((SELECT status FROM sales.invoice WHERE id = j) = 'cancelled', 'T38 cancelled with reversal');
  PERFORM c_err(format($q$UPDATE sales.invoice SET cancel_reason = 'دیگر' WHERE id = %L$q$, j), 'HK_COMMERCE_DOC_TRANSITION', 'T38 cancelled is final');
END $$;

-- ---------- T39 (INV-SAL-29): ثبت کنترل اعتبار ----------
DO $$
BEGIN
  PERFORM c_ctx('A');
  INSERT INTO sales.credit_check (tenant_id, company_id, party_id, doc_type, doc_id, policy, credit_limit, currency, exposure_receivable,
                                  exposure_open_orders, exposure_uncleared_cheques, doc_amount, total_exposure, result)
  VALUES (k('A'), k('CA'), k('C2'), 'sales.invoice', uuidv7(), 'block', 1000000, 'IRR', 900000, 0, 50000, 100000, 1050000, 'blocked');
  PERFORM c_err($q$INSERT INTO sales.credit_check (tenant_id, company_id, party_id, doc_type, doc_id, policy, credit_limit, currency, exposure_receivable,
                     exposure_open_orders, exposure_uncleared_cheques, doc_amount, total_exposure, result)
                  VALUES (k('A'), k('CA'), k('C2'), 'sales.invoice', uuidv7(), 'block', 1000000, 'IRR', 900000, 0, 50000, 100000, 1050000, 'ok')$q$,
                'credit_check_result', 'T39 over-limit block cannot be ok');
  PERFORM c_err($q$INSERT INTO sales.credit_check (tenant_id, company_id, party_id, doc_type, doc_id, policy, credit_limit, currency, exposure_receivable,
                     exposure_open_orders, exposure_uncleared_cheques, doc_amount, total_exposure, result)
                  VALUES (k('A'), k('CA'), k('C2'), 'sales.invoice', uuidv7(), 'block', 1000000, 'IRR', 900000, 0, 50000, 100000, 999, 'ok')$q$,
                'credit_check_total', 'T39 exposure is the sum of its parts');
  PERFORM c_err($q$INSERT INTO sales.credit_check (tenant_id, company_id, party_id, doc_type, doc_id, policy, credit_limit, currency, exposure_receivable,
                     exposure_open_orders, exposure_uncleared_cheques, doc_amount, total_exposure, result)
                  VALUES (k('A'), k('CA'), k('C2'), 'sales.invoice', uuidv7(), 'block', 1000000, 'IRR', 900000, 0, 50000, 100000, 1050000, 'overridden')$q$,
                'credit_check_result', 'T39 override names the approver');
  PERFORM c_err($q$UPDATE sales.credit_check SET result = 'ok'$q$, '42501', 'T39 credit checks are append-only');
END $$;

-- ---------- T40 (INV-SAL-30): دستهٔ GL صندوق؛ مبالغ دسته و ابطال پس از ثبت دسته (RV-COM-02، RV-COM-15) ----------
DO $$
DECLARE b uuid := uuidv7(); i uuid; jb uuid;
BEGIN
  PERFORM c_ctx('A');
  INSERT INTO sales.gl_batch (tenant_id, id, company_id, branch_id, batch_date, source_kind) VALUES (k('A'), b, k('CA'), k('BA'), '2026-05-22', 'pos_shift');
  i := c_inv(jsonb_build_object('gl_mode', 'batched', 'batch', b, 'setm', 'cash', 'inty', 2, 'date', '2026-05-22'));
  PERFORM c_line(i, 1, 'SRV', 1, 1000);
  PERFORM c_post(i);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM c_err(format($q$UPDATE sales.gl_batch SET status = 'cancelled' WHERE id = %L$q$, b), 'HK_SALES_BATCH_CLOSED', 'T40 batch with invoices cannot be cancelled');
  PERFORM c_err(format($q$UPDATE sales.gl_batch SET status = 'posted', posted_at = now(), gl_journal_id = c_journal(k('CA'), '2026-05-22', 'sales', 'sales.gl_batch', uuidv7()) WHERE id = %L$q$, b),
                'HK_COMMERCE_GL_LINK', 'T40 batch journal must originate from the batch');
  PERFORM c_err(format($q$UPDATE sales.gl_batch SET status = 'posted', posted_at = now(), gl_journal_id = c_journal(k('CA'), '2026-05-22', 'sales', 'sales.gl_batch', %L) WHERE id = %L$q$, b, b),
                'HK_COMMERCE_GL_AMOUNT', 'T40 batch journal = Σ member invoices per posting key');
  jb := c_jr(k('CA'), '2026-05-22', 'sales', 'sales.gl_batch', b, 'post', jsonb_build_array(
          jsonb_build_object('key','sales.receivable','dr',1100,'party',k('C2')), jsonb_build_object('key','sales.revenue','cr',1000),
          jsonb_build_object('key','tax.vat_payable','cr',100)));
  UPDATE sales.gl_batch SET status = 'posted', posted_at = now(), gl_journal_id = jb WHERE id = b;
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM c_err(format($q$WITH h AS (SELECT c_inv(jsonb_build_object('gl_mode','batched','batch',%L::uuid,'setm','cash','inty',2)) AS id),
                         l AS (SELECT c_line(h.id, 1, 'SRV', 1, 1000) FROM h) SELECT c_post(h.id) FROM h, l$q$, b), 'HK_SALES_BATCH_CLOSED', 'T40 no invoice joins a posted batch');
  PERFORM c_err(format($q$UPDATE sales.gl_batch SET batch_date = '2026-05-23' WHERE id = %L$q$, b), 'HK_SALES_BATCH_CLOSED', 'T40 posted batch immutable');
  -- ابطال فاکتور دستهٔ ثبت‌شده: سند برگشت خودش لازم است (درآمد، مالیات و دریافتنی در GL نمی‌مانند)
  PERFORM c_err(format($q$UPDATE sales.invoice SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'x' WHERE id = %L$q$, i),
                'HK_SALES_BATCH_CANCEL_GL', 'T40 cancelling an invoice of a posted batch needs its own reversing journal');
  PERFORM c_err(format($q$UPDATE sales.invoice SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'x',
                         cancel_journal_id = c_journal(k('CA'), '2026-05-22', 'sales', 'sales.invoice', %L, 'cancel') WHERE id = %L$q$, i, i),
                'HK_COMMERCE_GL_AMOUNT', 'T40 the reversing journal negates the invoice amounts');
  UPDATE sales.invoice SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'x',
         cancel_journal_id = c_jr(k('CA'), '2026-05-22', 'sales', 'sales.invoice', i, 'cancel', jsonb_build_array(
           jsonb_build_object('key','sales.receivable','cr',1100,'party',k('C2')), jsonb_build_object('key','sales.revenue','dr',1000),
           jsonb_build_object('key','tax.vat_payable','dr',100)))
   WHERE id = i;
END $$;
-- فاکتور دستهٔ باز ابطال می‌شود و فقط از سند دسته بیرون می‌ماند
DO $$
DECLARE b uuid := uuidv7(); i uuid; i2 uuid;
BEGIN
  PERFORM c_ctx('A');
  INSERT INTO sales.gl_batch (tenant_id, id, company_id, branch_id, batch_date, source_kind) VALUES (k('A'), b, k('CA'), k('BA'), '2026-05-23', 'pos_shift');
  i := c_inv(jsonb_build_object('gl_mode', 'batched', 'batch', b, 'setm', 'cash', 'inty', 2, 'date', '2026-05-23'));
  PERFORM c_line(i, 1, 'SRV', 1, 1000);
  PERFORM c_post(i);
  i2 := c_inv(jsonb_build_object('gl_mode', 'batched', 'batch', b, 'setm', 'cash', 'inty', 2, 'date', '2026-05-23'));
  PERFORM c_line(i2, 1, 'SRV', 2, 1000);
  PERFORM c_post(i2);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM c_err(format($q$UPDATE sales.invoice SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'x',
                         cancel_journal_id = c_journal(k('CA'), '2026-05-23', 'sales', 'sales.invoice', %L, 'cancel') WHERE id = %L$q$, i, i),
                'HK_SALES_BATCH_CANCEL_GL', 'T40 an invoice of an open batch has no own cancel journal');
  UPDATE sales.invoice SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'x' WHERE id = i;
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM c_err(format($q$UPDATE sales.gl_batch SET status = 'posted', posted_at = now(), gl_journal_id = c_jr(k('CA'), '2026-05-23', 'sales', 'sales.gl_batch', %L, 'post',
                           jsonb_build_array(jsonb_build_object('key','sales.receivable','dr',3300,'party',k('C2')), jsonb_build_object('key','sales.revenue','cr',3000),
                                             jsonb_build_object('key','tax.vat_payable','cr',300))) WHERE id = %L$q$, b, b),
                'HK_COMMERCE_GL_AMOUNT', 'T40 a cancelled member is not in the batch journal');
  UPDATE sales.gl_batch SET status = 'posted', posted_at = now(), gl_journal_id = c_jr(k('CA'), '2026-05-23', 'sales', 'sales.gl_batch', b, 'post',
           jsonb_build_array(jsonb_build_object('key','sales.receivable','dr',2200,'party',k('C2')), jsonb_build_object('key','sales.revenue','cr',2000),
                             jsonb_build_object('key','tax.vat_payable','cr',200)))
   WHERE id = b;
END $$;

-- ---------- T41 (INV-SAL-31): پورسانت ----------
DO $$
DECLARE pl uuid := uuidv7(); e uuid;
BEGIN
  PERFORM c_ctx('A');
  INSERT INTO sales.commission_plan (tenant_id, id, company_id, code, name, basis, valid_from) VALUES (k('A'), pl, k('CA'), 'STD', 'پایه', 'net_revenue', '2026-03-21');
  INSERT INTO sales.commission_rule (tenant_id, plan_id, rate_percent) VALUES (k('A'), pl, 2);
  INSERT INTO sales.commission_assignment (tenant_id, plan_id, party_id, valid_from) VALUES (k('A'), pl, k('AG1'), '2026-03-21');
  PERFORM c_err(format($q$INSERT INTO sales.commission_assignment (tenant_id, plan_id, party_id, valid_from) VALUES (k('A'), %L, k('AG1'), '2026-06-01')$q$, pl),
                '23P01', 'T41 one plan per agent per date');
  INSERT INTO sales.commission_entry (tenant_id, id, company_id, party_id, plan_id, invoice_id, entry_date, basis_amount, rate_percent, amount)
  VALUES (k('A'), uuidv7(), k('CA'), k('AG1'), pl, '30a00000-0000-7000-8000-0000000f0201', '2026-05-10', 335000, 2, 6700) RETURNING id INTO e;
  PERFORM c_err(format($q$INSERT INTO sales.commission_entry (tenant_id, company_id, party_id, plan_id, invoice_id, entry_date, basis_amount, amount, reversal_of_id)
                         VALUES (k('A'), k('CA'), k('AG1'), %L, '30a00000-0000-7000-8000-0000000f0201', '2026-05-12', 0, -100, %L)$q$, pl, e),
                'HK_SALES_COMMISSION_REVERSAL', 'T41 reversal mirrors the entry');
  INSERT INTO sales.commission_entry (tenant_id, company_id, party_id, plan_id, invoice_id, entry_date, basis_amount, amount, reversal_of_id)
  VALUES (k('A'), k('CA'), k('AG1'), pl, '30a00000-0000-7000-8000-0000000f0201', '2026-05-12', 0, -6700, e);
  PERFORM c_err($q$UPDATE sales.commission_entry SET amount = 1$q$, '42501', 'T41 commission entries are append-only');
END $$;

-- ---------- T42 (INV-SAL-32): حوالهٔ تحویل؛ GL موجودی، رسید مرجوعی، فاکتور از حواله (RV-COM-04/05/22) ----------
DO $$
DECLARE d uuid := uuidv7(); l uuid; n uuid; mv uuid; rd uuid := uuidv7(); rl uuid; rmv uuid; inv uuid; rd2 uuid := uuidv7();
BEGIN
  PERFORM c_ctx('A');
  INSERT INTO sales.delivery (tenant_id, id, company_id, branch_id, doc_date, customer_party_id, warehouse_id) VALUES (k('A'), d, k('CA'), k('BA'), '2026-05-23', k('C2'), k('W1'));
  INSERT INTO sales.delivery_line (tenant_id, id, delivery_id, line_no, item_id, variant_id, uom_id, qty, qty_base)
  VALUES (k('A'), uuidv7(), d, 1, k('I.X'), k('V.X'), k('PCS'), 2, 2) RETURNING id INTO l;
  n := c_num(k('CA'), 'sales.delivery', d);
  PERFORM c_err(format($q$UPDATE sales.delivery SET status = 'posted', posted_at = now(), number_issued_id = %L, doc_no = 'D', gl_status = 'not_required' WHERE id = %L$q$, n, d),
                'HK_SALES_STOCK_LINK', 'T42 delivery lines need stock moves');
  PERFORM c_err(format($q$SELECT c_mv('CA','W1','NOD','sale_issue',-2,'2026-05-23', jsonb_build_object('module','sales','doc_type','sales.delivery','doc', %L::uuid, 'line', %L::uuid));
                         UPDATE sales.delivery SET status = 'posted', posted_at = now(), number_issued_id = %L, doc_no = 'D', gl_status = 'posted',
                                gl_journal_id = c_stock_jr(k('CA'), '2026-05-23', 'sales.delivery', %L, ARRAY[%L::uuid]) WHERE id = %L$q$, d, l, n, d, d, d),
                'HK_SALES_STOCK_LINK', 'T42 a move of another SKU does not deliver the line');
  mv := c_mv('CA','W1','X','sale_issue',-2,'2026-05-23', jsonb_build_object('module','sales','doc_type','sales.delivery','doc', d, 'line', l));
  PERFORM c_err(format($q$UPDATE sales.delivery SET status = 'posted', posted_at = now(), number_issued_id = %L, doc_no = 'D', gl_status = 'not_required' WHERE id = %L$q$, n, d),
                'HK_COMMERCE_STOCK_GL_MISSING', 'T42 a perpetual delivery posts its COGS journal (RV-COM-22)');
  PERFORM c_err(format($q$UPDATE sales.delivery SET status = 'posted', posted_at = now(), number_issued_id = %L, doc_no = 'D', gl_status = 'deferred' WHERE id = %L$q$, n, d),
                'HK_SALES_DELIVERY_GL', 'T42 delivery GL is posted or (zero value) not required');
  PERFORM c_err(format($q$UPDATE sales.delivery SET status = 'posted', posted_at = now(), number_issued_id = %L, doc_no = 'D', gl_status = 'posted',
                         gl_journal_id = c_journal(k('CA'), '2026-05-23', 'sales', 'sales.delivery', %L) WHERE id = %L$q$, n, d, d),
                'HK_COMMERCE_GL_LINK', 'T42 delivery COGS journal comes from inventory');
  UPDATE sales.delivery SET status = 'posted', posted_at = now(), number_issued_id = n, doc_no = c_no(n), gl_status = 'posted',
         gl_journal_id = c_stock_jr(k('CA'), '2026-05-23', 'sales.delivery', d, ARRAY[d]) WHERE id = d;
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM c_ok((SELECT sum(debit_base - credit_base) FROM ledger.journal_line WHERE journal_id = (SELECT gl_journal_id FROM sales.delivery WHERE id = d)
                 AND posting_key = 'inventory.cogs') = -c_mval(mv), 'T42 delivery journal: Dr COGS / Cr inventory at the issue value');
  PERFORM c_err($q$INSERT INTO sales.delivery (tenant_id, company_id, branch_id, direction, doc_date, customer_party_id, warehouse_id) VALUES (k('A'), k('CA'), k('BA'), 'return', '2026-05-23', k('C2'), k('W1'))$q$,
                'delivery_return_link', 'T42 return delivery references the original');
  PERFORM c_err(format($q$UPDATE sales.delivery_line SET qty = 1, qty_base = 1 WHERE id = %L$q$, l), 'HK_COMMERCE_DOC_IMMUTABLE', 'T42 posted delivery lines immutable');
  -- رسید مرجوعی ۲ عدد از همان حواله (به بهای خروج)، سپس برگشت بیشتر رد می‌شود (RV-COM-05)
  INSERT INTO sales.delivery (tenant_id, id, company_id, branch_id, direction, original_delivery_id, doc_date, customer_party_id, warehouse_id)
  VALUES (k('A'), rd, k('CA'), k('BA'), 'return', d, '2026-05-24', k('C2'), k('W1'));
  INSERT INTO sales.delivery_line (tenant_id, id, delivery_id, line_no, original_line_id, item_id, variant_id, uom_id, qty, qty_base)
  VALUES (k('A'), uuidv7(), rd, 1, l, k('I.X'), k('V.X'), k('PCS'), 2, 2) RETURNING id INTO rl;
  rmv := c_mv('CA','W1','X','sale_return',2,'2026-05-24', jsonb_build_object('rule','source','src', mv, 'module','sales','doc_type','sales.delivery','doc', rd, 'line', rl));
  n := c_num(k('CA'), 'sales.delivery', rd);
  UPDATE sales.delivery SET status = 'posted', posted_at = now(), number_issued_id = n, doc_no = c_no(n), gl_status = 'posted',
         gl_journal_id = c_stock_jr(k('CA'), '2026-05-24', 'sales.delivery', rd, ARRAY[rd]) WHERE id = rd;
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM c_ok(c_mval(rmv) = -c_mval(mv), 'T42 returned goods come back at the delivery issue cost');
  PERFORM c_err(format($q$INSERT INTO sales.delivery (tenant_id, id, company_id, branch_id, direction, original_delivery_id, doc_date, customer_party_id, warehouse_id)
                         VALUES (k('A'), %L, k('CA'), k('BA'), 'return', %L, '2026-05-25', k('C2'), k('W1'));
                         INSERT INTO sales.delivery_line (tenant_id, delivery_id, line_no, original_line_id, item_id, variant_id, uom_id, qty, qty_base)
                         VALUES (k('A'), %L, 1, %L, k('I.X'), k('V.X'), k('PCS'), 1, 1);
                         UPDATE sales.delivery SET status = 'posted', posted_at = now(), number_issued_id = c_num(k('CA'), 'sales.delivery', %L), doc_no = 'RD2',
                                gl_status = 'not_required' WHERE id = %L$q$, rd2, d, rd2, l, rd2, rd2),
                'HK_SALES_RETURN_QTY', 'T42 return deliveries cannot exceed the original delivery line (cumulative)');
  -- فاکتور «از حواله»: سطر انباری به سطر حوالهٔ ثبت‌شدهٔ همان مشتری؛ بدون حرکت تازه
  inv := c_inv(jsonb_build_object('stock_mode', 'via_delivery', 'date', '2026-05-24'));
  PERFORM c_line(inv, 1, 'X', 2, 150000, jsonb_build_object('delivery_line', l));
  PERFORM c_post(inv);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM c_err(format($q$WITH h AS (SELECT c_inv('{"stock_mode":"via_delivery","date":"2026-05-24"}') AS id),
                         x AS (SELECT c_line(h.id, 1, 'X', 2, 150000, jsonb_build_object('delivery_line', %L::uuid)) FROM h)
                         SELECT c_post(h.id) FROM h, x$q$, l), 'HK_SALES_DELIVERY_LINK', 'T42 a delivery line is billed at most once');
  PERFORM c_err(format($q$WITH h AS (SELECT c_inv('{"stock_mode":"via_delivery","date":"2026-05-24","customer":"30a00000-0000-7000-8000-00000000a101","buyer_type":"natural","buyer_eco":"11111111111"}') AS id),
                         x AS (SELECT c_line(h.id, 1, 'X', 2, 150000, jsonb_build_object('delivery_line', %L::uuid)) FROM h)
                         SELECT c_post(h.id) FROM h, x$q$, rl), 'HK_SALES_DELIVERY_LINK', 'T42 bill only deliveries of the same customer and direction');
  PERFORM c_err(format($q$UPDATE sales.delivery SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'x',
                         cancel_journal_id = c_rev_jr(gl_journal_id, '2026-05-23') WHERE id = %L$q$, d),
                'HK_SALES_CANCEL_STOCK', 'T42 cancelling a delivery reverses its moves');
END $$;

-- ---------- T43 (INV-SAL-20): سطر برگشتی باید از فاکتور اصلی همان برگشت باشد ----------
DO $$
DECLARE i2 uuid := uuidv7(); l2 uuid := uuidv7();
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_inv(jsonb_build_object('id', i2, 'date', '2026-05-24'));
  PERFORM c_line(i2, 1, 'X', 1, 150000, jsonb_build_object('id', l2));
  PERFORM c_post(i2);
  PERFORM c_err(format($q$WITH h AS (SELECT c_inv(jsonb_build_object('kind','return','original','30a00000-0000-7000-8000-0000000f0201'::uuid,'date','2026-05-25','stock_mode','none')) AS id),
                         l AS (SELECT c_line(h.id, 1, 'X', 1, 150000, jsonb_build_object('orig', %L::uuid)) FROM h)
                         SELECT c_post(h.id) FROM h, l$q$, l2), 'HK_SALES_RETURN_LINE', 'T43 return line from another invoice');
END $$;

-- ---------- T44 (CR-06، RV-IT-04): شخص ادغام‌شده در سند تازه/پیش‌نویس رد می‌شود؛ سند ثبت‌شده و برگشت با جانشین آزاد ----------
DO $$
DECLARE i_old uuid; i_old2 uuid; d_before uuid; r uuid; l_old uuid := uuidv7();
BEGIN
  PERFORM c_ctx('A');
  i_old := c_inv(jsonb_build_object('customer', k('M2'), 'buyer_eco', NULL, 'moadian', false, 'date', '2026-06-10'));
  PERFORM c_line(i_old, 1, 'SRV', 1, 1000, jsonb_build_object('id', l_old));
  PERFORM c_post(i_old);
  i_old2 := c_inv(jsonb_build_object('customer', k('M2'), 'buyer_eco', NULL, 'moadian', false, 'date', '2026-06-10'));
  PERFORM c_line(i_old2, 1, 'SRV', 1, 2000);
  PERFORM c_post(i_old2);
  d_before := c_inv(jsonb_build_object('customer', k('M2'), 'buyer_eco', NULL, 'moadian', false, 'date', '2026-06-10'));
  PERFORM c_line(d_before, 1, 'SRV', 1, 3000);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM parties.merge_parties(k('M1'), k('M2'), 'مشتری تکراری است', k('U1'));
  PERFORM c_err($q$SELECT c_inv(jsonb_build_object('customer', k('M2'), 'buyer_eco', NULL, 'moadian', false))$q$, 'HK_PARTY_MERGED',
                'T44 a new invoice cannot name a merged party');
  PERFORM c_err(format($q$SELECT c_post(%L)$q$, d_before), 'HK_PARTY_MERGED', 'T44 a draft of a merged party cannot be posted (re-point it)');
  PERFORM c_err($q$INSERT INTO purchase.receipt (tenant_id, company_id, branch_id, doc_date, supplier_party_id, warehouse_id, currency)
                  VALUES (k('A'), k('CA'), k('BA'), '2026-06-10', k('M2'), k('W1'), 'IRR')$q$, 'HK_PARTY_MERGED', 'T44 purchase documents too');
  PERFORM c_err($q$INSERT INTO sales.pricing_rule (tenant_id, code, name, kind, discount_percent, valid_from, party_id)
                  VALUES (k('A'), 'M2ONLY', 'ویژه', 'line_discount', 5, '2026-06-10', k('M2'))$q$, 'HK_PARTY_MERGED', 'T44 and pricing rules');
  -- برگشت فاکتور قدیمِ بازنده با جانشین (M1) پذیرفته است؛ ابطال سند ثبت‌شدهٔ بازنده آزاد است
  r := c_inv(jsonb_build_object('kind', 'return', 'original', i_old, 'customer', k('M1'), 'buyer_eco', NULL, 'moadian', false, 'date', '2026-06-11'));
  PERFORM c_line(r, 1, 'SRV', 1, 1000, jsonb_build_object('orig', l_old));
  PERFORM c_post(r);
  PERFORM c_cancel(i_old2);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM c_ok((SELECT status FROM sales.invoice WHERE id = r) = 'posted' AND (SELECT status FROM sales.invoice WHERE id = i_old2) = 'cancelled',
               'T44 return to the successor and cancel of the loser''s posted invoice are allowed');
END $$;

-- ---------- T45 (RV-COM-12): تاریخچهٔ مهاجرت با gl_mode='none'؛ فاکتور عادی بی‌GL نه ----------
DO $$
DECLARE h uuid;
BEGIN
  PERFORM c_ctx('A');
  h := c_inv('{"gl_mode":"none","stock_mode":"none","channel":"migration","moadian":false,"date":"2026-04-15"}');
  PERFORM c_line(h, 1, 'X', 2, 150000);
  PERFORM c_post(h);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM c_ok((SELECT status = 'posted' AND gl_journal_id IS NULL FROM sales.invoice WHERE id = h), 'T45 migrated history invoice without GL (GL from the ledger import)');
  PERFORM c_err($q$WITH x AS (SELECT c_inv('{"gl_mode":"none","stock_mode":"none","moadian":false}') AS id), l AS (SELECT c_line(x.id, 1, 'SRV', 1, 1000) FROM x)
                  SELECT c_post(x.id) FROM x, l$q$, 'invoice_gl_shape', 'T45 a live invoice with an amount has GL');
  PERFORM c_err($q$WITH x AS (SELECT c_inv('{"stock_mode":"none","moadian":false}') AS id), l AS (SELECT c_line(x.id, 1, 'X', 1, 1000) FROM x)
                  SELECT c_post(x.id) FROM x, l$q$, 'HK_SALES_STOCK_MODE', 'T45 an ordinary invoice of a stock item moves stock (RV-COM-04)');
END $$;

-- ---------- T46 (RV-IT2-06): فاکتور صندوق با شمارهٔ رسید دستگاه ----------
DO $$
DECLARE h uuid; tk uuid := uuidv7(); n uuid; h2 uuid; tk2 uuid := uuidv7(); n2 uuid; mv uuid; l uuid := uuidv7(); pl uuid := uuidv7();
BEGIN
  PERFORM c_ctx('A');
  n := core.number_record_external(k('NS.TICKET'), 'all', 101, 'D1-101', 'pos.ticket', tk, k('DEV1'));
  h := c_inv(jsonb_build_object('channel', 'pos', 'device', k('DEV1'), 'ticket', tk, 'setm', 'cash', 'inty', 2, 'date', '2026-06-12'));
  PERFORM c_line(h, 1, 'SRV', 1, 5000, jsonb_build_object('line_kind', 'service_charge'));
  PERFORM c_line(h, 2, 'SRV', 1, 20000, jsonb_build_object('pos_line', pl));
  PERFORM c_totals(h);
  -- شمارهٔ سرور برای فاکتور «دستگاهی» رد می‌شود؛ شمارهٔ رسید همان دستگاه پذیرفته
  PERFORM c_err(format($q$UPDATE sales.invoice SET status = 'posted', number_issued_id = c_num(k('CA'), 'sales.invoice', %L), doc_no = 'X', issued_at = now(),
                         posted_at = now(), gl_journal_id = c_sales_jr(%L) WHERE id = %L$q$, h, h, h),
                'HK_COMMERCE_NUMBER_LINK', 'T46 a device-numbered invoice carries its POS ticket number, not a server number');
  PERFORM c_err(format($q$UPDATE sales.invoice SET status = 'posted', number_issued_id = %L, doc_no = 'D1-101', issued_at = now(), posted_at = now(),
                         gl_journal_id = c_jr(k('CA'), '2026-06-12', 'sales', 'sales.invoice', %L, 'post', jsonb_build_array(
                           jsonb_build_object('key','sales.receivable','dr',27500,'party',k('C2')), jsonb_build_object('key','sales.revenue','cr',25000),
                           jsonb_build_object('key','tax.vat_payable','cr',2500))) WHERE id = %L$q$, n, h, h),
                'HK_COMMERCE_GL_AMOUNT', 'T46 service charge revenue posts to sales.service_charge (CR-T07)');
  UPDATE sales.invoice SET status = 'posted', number_issued_id = n, doc_no = 'D1-101', issued_at = now(), posted_at = now(), gl_journal_id = c_sales_jr(h)
   WHERE id = h;
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM c_ok((SELECT sum(credit_base) FROM ledger.journal_line WHERE journal_id = (SELECT gl_journal_id FROM sales.invoice WHERE id = h)
                  AND posting_key = 'sales.service_charge') = 5000, 'T46 POS invoice posted with the device ticket number');
  PERFORM c_err($q$SELECT c_inv(jsonb_build_object('device', k('DEV1'), 'ticket', uuidv7()))$q$, 'invoice_device_number', 'T46 device numbers only on the POS channel');
  -- هر سطر رسید صندوق یک سطر فاکتور؛ فقط در فاکتور صندوق (RV-X2-04)
  PERFORM c_err(format($q$SELECT c_line(c_inv(jsonb_build_object('channel', 'pos', 'device', k('DEV1'), 'ticket', uuidv7(), 'setm', 'cash', 'date', '2026-06-12')),
                         1, 'SRV', 1, 100, jsonb_build_object('pos_line', %L::uuid))$q$, pl),
                'invoice_line_pos_line_uq', 'T46 a POS ticket line maps to one invoice line');
  PERFORM c_err(format($q$SELECT c_line(c_inv('{"date":"2026-06-12"}'), 1, 'SRV', 1, 100, jsonb_build_object('pos_line', %L::uuid))$q$, uuidv7()),
                'HK_SALES_POS_LINE', 'T46 POS ticket line ids only on POS invoices');
  -- فروش آفلاین فقط در فاکتور صندوق همان دستگاه (RV-COM-20)
  h2 := c_inv('{"date":"2026-06-12"}');
  PERFORM c_line(h2, 1, 'X', 1, 1000, jsonb_build_object('id', l));
  PERFORM c_err(format($q$SELECT c_mv('CA','W1','X','sale_issue',-1,'2026-06-12', jsonb_build_object('origin','offline_device','doc', %L::uuid, 'line', %L::uuid));
                         SELECT c_post(%L, '{"skip_stock":true}')$q$, h2, l, h2),
                'HK_SALES_OFFLINE_ORIGIN', 'T46 offline-device moves belong only to POS invoices of the same device');
  PERFORM c_err(format($q$SELECT c_mv('CA','W1','NOD','sale_issue',-1,'2026-06-12', jsonb_build_object('module','sales','doc', %L::uuid, 'line', %L::uuid));
                         SELECT c_post(%L, '{"skip_stock":true}')$q$, h2, l, h2),
                'HK_SALES_STOCK_LINK', 'T46 a move of another SKU does not satisfy an invoice line (RV-COM-04)');
END $$;

-- ---------- T47 (RV-X3-03/04): فروش اقساطی؛ اقساط = کل فاکتور، اضافه‌بها در درآمد تحقق‌نیافته ----------
DO $$
DECLARE h uuid := uuidv7();
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_inv(jsonb_build_object('id', h, 'date', '2026-06-15', 'stock_mode', 'none'));
  PERFORM c_line(h, 1, 'SRV', 1, 9000000);
  PERFORM c_line(h, 2, 'SRV', 1, 900000, '{"line_kind":"installment_markup"}');
  INSERT INTO sales.invoice_installment (tenant_id, invoice_id, seq, due_date, amount, markup_amount) VALUES
    (k('A'), h, 1, '2026-06-15', 3630000, 300000), (k('A'), h, 2, '2026-07-15', 3630000, 300000), (k('A'), h, 3, '2026-08-15', 3630000, 300000);
  PERFORM c_err(format($q$UPDATE sales.invoice_installment SET amount = amount - 1 WHERE invoice_id = %L AND seq = 3; SELECT c_post(%L)$q$, h, h),
                'HK_SALES_INSTALLMENTS', 'T47 installments sum to the invoice total');
  PERFORM c_err(format($q$UPDATE sales.invoice_installment SET due_date = '2026-06-01' WHERE invoice_id = %L AND seq = 2; SELECT c_post(%L)$q$, h, h),
                'HK_SALES_INSTALLMENTS', 'T47 installment due dates are non-decreasing from the invoice date');
  PERFORM c_err(format($q$UPDATE sales.invoice_installment SET markup_amount = 0 WHERE invoice_id = %L AND seq = 3; SELECT c_post(%L)$q$, h, h),
                'HK_SALES_INSTALLMENTS', 'T47 installment markup shares sum to the markup lines');
  PERFORM c_err(format($q$UPDATE sales.invoice SET settlement_method = 'cash' WHERE id = %L; SELECT c_post(%L)$q$, h, h),
                'HK_SALES_INSTALLMENTS', 'T47 an installment sale is not a cash sale');
  PERFORM c_err(format($q$SELECT c_totals(%L);
                         UPDATE sales.invoice SET status = 'posted', number_issued_id = c_num(k('CA'), 'sales.invoice', %L), doc_no = 'I', issued_at = now(), posted_at = now(),
                                gl_journal_id = c_jr(k('CA'), '2026-06-15', 'sales', 'sales.invoice', %L, 'post', jsonb_build_array(
                                  jsonb_build_object('key','sales.receivable','dr',10890000,'party',k('C2')), jsonb_build_object('key','sales.revenue','cr',9900000),
                                  jsonb_build_object('key','tax.vat_payable','cr',990000))) WHERE id = %L$q$, h, h, h, h),
                'HK_COMMERCE_GL_AMOUNT', 'T47 installment markup is unearned income, not revenue at sale');
  PERFORM c_post(h);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM c_ok((SELECT sum(credit_base) FROM ledger.journal_line WHERE journal_id = (SELECT gl_journal_id FROM sales.invoice WHERE id = h)
                  AND posting_key = 'sales.installment_unearned') = 900000, 'T47 installment invoice posted with deferred markup');
  PERFORM c_err(format($q$DELETE FROM sales.invoice_installment WHERE invoice_id = %L$q$, h), 'HK_COMMERCE_DOC_IMMUTABLE', 'T47 a posted schedule is immutable');
END $$;

-- ---------- T50 (INV-PUR-01..05): فاکتور خرید، هزینهٔ جانبی، تکرار فاکتور تأمین‌کننده ----------
DO $$
DECLARE pi uuid := '30a00000-0000-7000-8000-0000000f0601'; v uuid;
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_pinv(jsonb_build_object('id', pi, 'line_id', '30a00000-0000-7000-8000-0000000f0611', 'supno', 'F-100', 'charge', 50000,
                                    'taxid', 'A1B2C3D4E5F6A7B8C9D0E1', 'post', true));
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM c_ok((SELECT total_value FROM inventory.v_move_value WHERE source_doc_id = pi) = 1050000, 'T50 capitalized freight raises the stock value');
  PERFORM c_err($q$SELECT c_pinv('{"supno":"F-100"}')$q$, '23505', 'T50 same supplier invoice number entered twice');
  PERFORM c_err($q$SELECT c_pinv('{"taxid":"A1B2C3D4E5F6A7B8C9D0E1"}')$q$, '23505', 'T50 same Moadian taxid entered twice');
  PERFORM c_err($q$SELECT c_pinv('{"charge":1000,"no_alloc":true,"post":true}')$q$, 'HK_PUR_CHARGE_ALLOCATION', 'T50 capitalized charge fully allocated');
  PERFORM c_err($q$SELECT c_pinv('{"adjust":7,"post":true}')$q$, 'HK_PUR_TOTALS', 'T50 header totals equal lines + charges');
  PERFORM c_err($q$SELECT c_pinv('{"charge":1000,"alloc_line":"30a00000-0000-7000-8000-0000000f0611","post":true}')$q$, 'HK_PUR_CHARGE_ALLOCATION',
                'T50 allocate only to this invoice''s lines');
  PERFORM c_err($q$SELECT c_pinv('{"post":true,"skip_stock":true}')$q$, 'HK_PUR_STOCK_LINK', 'T50 stock lines need receipt moves');
  PERFORM c_err($q$SELECT c_pinv('{"charge":50000,"post":true,"value_off":-50000}')$q$, 'HK_PUR_STOCK_VALUE',
                'T50 capitalized freight must reach the receipt move value (RV-COM-04)');
  PERFORM c_err($q$SELECT c_pinv('{"post":true,"gl_off":5}')$q$, 'HK_COMMERCE_GL_AMOUNT', 'T50 payable equals the invoice total (RV-IT2-09)');
  PERFORM c_err($q$SELECT c_pinv('{"post":true,"no_stock_gl":true}')$q$, 'HK_COMMERCE_STOCK_GL_MISSING', 'T50 the receipt move has its inventory journal (RV-IT2-01)');
  PERFORM c_err($q$SELECT c_pinv('{}'); UPDATE purchase.invoice SET stock_mode = 'none', warehouse_id = NULL, status = 'posted', posted_at = now(),
                     number_issued_id = c_num(k('CA'), 'purchase.invoice', id), doc_no = 'PN', gl_status = 'posted',
                     gl_journal_id = c_jr(k('CA'), doc_date, 'purchase', 'purchase.invoice', id, 'post', jsonb_build_array(
                       jsonb_build_object('key','purchase.grni','dr',1000000), jsonb_build_object('key','tax.vat_receivable','dr',100000),
                       jsonb_build_object('key','purchase.payable','cr',1100000,'party',k('S1'))))
                   WHERE status = 'draft' AND supplier_invoice_no LIKE 'F-%' AND stock_mode = 'immediate' AND gross_amount = 1000000$q$,
                'HK_PUR_STOCK_MODE', 'T50 a purchase of stock items moves stock');
  PERFORM c_err($q$SELECT c_pinv('{}'); UPDATE purchase.invoice SET gl_status = 'not_required' WHERE status = 'draft' AND gross_amount = 1000000$q$,
                'pinv_gl_not_required', 'T50 only migrated history goes without GL (RV-COM-12)');
  PERFORM c_err($q$SELECT c_pinv('{"channel":"migration"}')$q$, 'pinv_migration_unit', 'T50 migrated purchase declares its amount unit');
  PERFORM c_err($q$UPDATE purchase.cost_allocation SET amount = 1 WHERE charge_id IN (SELECT id FROM purchase.invoice_charge WHERE invoice_id = '30a00000-0000-7000-8000-0000000f0601')$q$,
                'HK_COMMERCE_DOC_IMMUTABLE', 'T50 allocations of a posted invoice immutable');
  PERFORM c_err($q$INSERT INTO purchase.invoice_charge (tenant_id, invoice_id, line_no, charge_kind, amount, capitalize)
                  VALUES (k('A'), '30a00000-0000-7000-8000-0000000f0601', 2, 'other', 10, true)$q$, 'HK_COMMERCE_DOC_IMMUTABLE', 'T50 no charges after posting');
  v := c_pinv('{}');
  PERFORM c_err(format($q$INSERT INTO purchase.invoice_charge (tenant_id, invoice_id, line_no, charge_kind, amount, capitalize) VALUES (k('A'), %L, 1, 'other', 10, false)$q$, v),
                '23514', 'T50 expensed charge names its posting key');
  PERFORM c_err(format($q$UPDATE purchase.invoice SET supplier_invoice_no = 'F-101' WHERE id = %L$q$, '30a00000-0000-7000-8000-0000000f0601'), 'HK_COMMERCE_DOC_IMMUTABLE', 'T50 posted purchase invoice immutable');
END $$;

-- ---------- T51 (INV-PUR-06/07): رسید کالا، GRNI، پیوند فاکتور به رسید (RV-COM-02/04/06) ----------
DO $$
DECLARE r uuid := uuidv7(); rl uuid := uuidv7(); n uuid; pi uuid := uuidv7(); r2 uuid := uuidv7(); rl2 uuid := uuidv7(); mv uuid;
BEGIN
  PERFORM c_ctx('A');
  INSERT INTO purchase.receipt (tenant_id, id, company_id, branch_id, doc_date, supplier_party_id, warehouse_id, currency)
  VALUES (k('A'), r, k('CA'), k('BA'), '2026-05-06', k('S2'), k('W1'), 'IRR');
  INSERT INTO purchase.receipt_line (tenant_id, id, receipt_id, line_no, item_id, variant_id, uom_id, qty, qty_base, unit_price, value_txn, value_base)
  VALUES (k('A'), rl, r, 1, k('I.X'), k('V.X'), k('PCS'), 5, 5, 90000, 450000, 450000);
  n := c_num(k('CA'), 'purchase.receipt', r);
  PERFORM c_err(format($q$UPDATE purchase.receipt SET status = 'posted', posted_at = now(), number_issued_id = %L, doc_no = 'R', gl_status = 'not_required' WHERE id = %L$q$, n, r),
                'HK_PUR_STOCK_LINK', 'T51 receipt lines need receipt moves');
  PERFORM c_err(format($q$SELECT c_mv('CA','W1','X','receipt',5,'2026-05-06', jsonb_build_object('value', 450001, 'module','purchase','doc_type','purchase.receipt','doc', %L::uuid, 'line', %L::uuid));
                         UPDATE purchase.receipt SET status = 'posted', posted_at = now(), number_issued_id = %L, doc_no = 'R', gl_status = 'posted',
                                gl_journal_id = c_stock_jr(k('CA'), '2026-05-06', 'purchase.receipt', %L, ARRAY[%L::uuid]) WHERE id = %L$q$, r, rl, n, r, r, r),
                'HK_PUR_STOCK_VALUE', 'T51 receipt move value = receipt line value');
  PERFORM c_err(format($q$SELECT c_mv('CA','W2','X','receipt',5,'2026-05-06', jsonb_build_object('value', 450000, 'module','purchase','doc_type','purchase.receipt','doc', %L::uuid, 'line', %L::uuid));
                         UPDATE purchase.receipt SET status = 'posted', posted_at = now(), number_issued_id = %L, doc_no = 'R', gl_status = 'posted',
                                gl_journal_id = c_stock_jr(k('CA'), '2026-05-06', 'purchase.receipt', %L, ARRAY[%L::uuid]) WHERE id = %L$q$, r, rl, n, r, r, r),
                'HK_PUR_STOCK_LINK', 'T51 receipt move goes into the receipt warehouse');
  mv := c_mv('CA','W1','X','receipt',5,'2026-05-06', jsonb_build_object('value', 450000, 'module','purchase','doc_type','purchase.receipt','doc', r, 'line', rl));
  PERFORM c_err(format($q$UPDATE purchase.receipt SET status = 'posted', posted_at = now(), number_issued_id = %L, doc_no = 'R', gl_status = 'not_required' WHERE id = %L$q$, n, r),
                'HK_COMMERCE_STOCK_GL_MISSING', 'T51 a perpetual receipt posts Dr inventory / Cr GRNI');
  UPDATE purchase.receipt SET status = 'posted', posted_at = now(), number_issued_id = n, doc_no = c_no(n), gl_status = 'posted',
         gl_journal_id = c_stock_jr(k('CA'), '2026-05-06', 'purchase.receipt', r, ARRAY[r]) WHERE id = r;
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM c_ok((SELECT received_base - invoiced_base FROM purchase.v_receipt_line_unbilled WHERE receipt_line_id = rl) = 5, 'T51 GRNI before invoice');
  PERFORM c_ok((SELECT sum(credit_base - debit_base) FROM ledger.journal_line WHERE journal_id = (SELECT gl_journal_id FROM purchase.receipt WHERE id = r)
                  AND posting_key = 'purchase.grni') = 450000, 'T51 receipt credits GRNI');
  -- فاکتور بر اساس رسید (بدون حرکت انبار تازه)
  INSERT INTO purchase.invoice (tenant_id, id, company_id, branch_id, doc_date, supplier_party_id, supplier_invoice_no, currency, currency_minor, stock_mode)
  VALUES (k('A'), pi, k('CA'), k('BA'), '2026-05-07', k('S2'), 'S2-77', 'IRR', 0, 'via_receipt');
  INSERT INTO purchase.invoice_line (tenant_id, invoice_id, line_no, item_id, variant_id, uom_id, qty, qty_base, unit_price, gross_amount, net_amount, vat_rate, vat_amount, line_total, receipt_line_id)
  VALUES (k('A'), pi, 1, k('I.X'), k('V.X'), k('PCS'), 5, 5, 92000, 460000, 460000, 10, 46000, 506000, rl);
  UPDATE purchase.invoice SET gross_amount = 460000, net_amount = 460000, vat_amount = 46000, total_amount = 506000, total_base = 506000 WHERE id = pi;
  n := c_num(k('CA'), 'purchase.invoice', pi);
  PERFORM c_err(format($q$UPDATE purchase.invoice SET status = 'posted', posted_at = now(), number_issued_id = %L, doc_no = 'P', gl_status = 'posted',
                         gl_journal_id = c_jr(k('CA'), '2026-05-07', 'purchase', 'purchase.invoice', %L, 'post', jsonb_build_array(
                           jsonb_build_object('key','purchase.grni','dr',460000), jsonb_build_object('key','tax.vat_receivable','dr',46000),
                           jsonb_build_object('key','purchase.payable','cr',505000,'party',k('S2')), jsonb_build_object('key','purchase.price_difference','cr',1000)))
                         WHERE id = %L$q$, n, pi, pi),
                'HK_COMMERCE_GL_AMOUNT', 'T51 payable equals the invoice total (RV-IT2-09)');
  UPDATE purchase.invoice SET status = 'posted', posted_at = now(), number_issued_id = n, doc_no = c_no(n), gl_status = 'posted',
         gl_journal_id = c_jr(k('CA'), '2026-05-07', 'purchase', 'purchase.invoice', pi, 'post', jsonb_build_array(
           jsonb_build_object('key','purchase.grni','dr',460000), jsonb_build_object('key','tax.vat_receivable','dr',46000),
           jsonb_build_object('key','purchase.payable','cr',506000,'party',k('S2'))))
   WHERE id = pi;
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM c_ok((SELECT invoiced_base FROM purchase.v_receipt_line_unbilled WHERE receipt_line_id = rl) = 5, 'T51 GRNI cleared by the invoice');
  -- همان سطر رسید دوباره صورتحساب نمی‌شود؛ رسید پیش‌نویس یا رسید تأمین‌کنندهٔ دیگر هم نه (RV-COM-06)
  PERFORM c_err(format($q$SELECT c_pinv('{"supplier":"30a00000-0000-7000-8000-00000000a202","supno":"S2-78"}');
                         UPDATE purchase.invoice_line SET receipt_line_id = %L WHERE invoice_id = (SELECT id FROM purchase.invoice WHERE supplier_invoice_no = 'S2-78');
                         UPDATE purchase.invoice SET stock_mode = 'via_receipt', warehouse_id = NULL WHERE supplier_invoice_no = 'S2-78';
                         UPDATE purchase.invoice_line SET qty = 5, qty_base = 5, unit_price = 92000, gross_amount = 460000, net_amount = 460000, vat_amount = 46000, line_total = 506000
                          WHERE invoice_id = (SELECT id FROM purchase.invoice WHERE supplier_invoice_no = 'S2-78');
                         UPDATE purchase.invoice SET gross_amount = 460000, net_amount = 460000, vat_amount = 46000, total_amount = 506000, total_base = 506000,
                                status = 'posted', posted_at = now(), number_issued_id = c_num(k('CA'), 'purchase.invoice', id), doc_no = 'P2', gl_status = 'posted',
                                gl_journal_id = c_jr(k('CA'), '2026-05-07', 'purchase', 'purchase.invoice', id, 'post', jsonb_build_array(
                                  jsonb_build_object('key','purchase.grni','dr',460000), jsonb_build_object('key','tax.vat_receivable','dr',46000),
                                  jsonb_build_object('key','purchase.payable','cr',506000,'party',k('S2'))))
                          WHERE supplier_invoice_no = 'S2-78'$q$, rl),
                'HK_PUR_RECEIPT_OVERBILLED', 'T51 a receipt line is billed at most once (no double GRNI clearing)');
  INSERT INTO purchase.receipt (tenant_id, id, company_id, branch_id, doc_date, supplier_party_id, warehouse_id, currency)
  VALUES (k('A'), r2, k('CA'), k('BA'), '2026-05-06', k('S2'), k('W1'), 'IRR');
  INSERT INTO purchase.receipt_line (tenant_id, id, receipt_id, line_no, item_id, variant_id, uom_id, qty, qty_base, unit_price, value_txn, value_base)
  VALUES (k('A'), rl2, r2, 1, k('I.X'), k('V.X'), k('PCS'), 1, 1, 90000, 90000, 90000);
  PERFORM c_err(format($q$SELECT c_pinv('{"supno":"S1-DRAFTRCPT","qty":1}');
                         UPDATE purchase.invoice_line SET receipt_line_id = %L WHERE invoice_id = (SELECT id FROM purchase.invoice WHERE supplier_invoice_no = 'S1-DRAFTRCPT');
                         UPDATE purchase.invoice SET stock_mode = 'via_receipt', warehouse_id = NULL, status = 'posted', posted_at = now(),
                                number_issued_id = c_num(k('CA'), 'purchase.invoice', id), doc_no = 'P3', gl_status = 'posted',
                                gl_journal_id = c_jr(k('CA'), '2026-05-05', 'purchase', 'purchase.invoice', id, 'post', jsonb_build_array(
                                  jsonb_build_object('key','purchase.grni','dr',100000), jsonb_build_object('key','tax.vat_receivable','dr',10000),
                                  jsonb_build_object('key','purchase.payable','cr',110000,'party',k('S1'))))
                          WHERE supplier_invoice_no = 'S1-DRAFTRCPT'$q$, rl2),
                'HK_PUR_RECEIPT_LINK', 'T51 bill only a posted receipt of the same supplier');
  PERFORM c_err(format($q$UPDATE purchase.receipt SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'اشتباه',
                         cancel_journal_id = c_rev_jr(gl_journal_id, '2026-05-06') WHERE id = %L$q$, r),
                'HK_PUR_CANCEL_HAS_DEPENDENTS', 'T51 invoiced receipt cannot be cancelled');
END $$;
-- ابطال رسید ثبت‌شده: حرکت‌ها برگردند و سند GL برگردد (RV-COM-02)
DO $$
DECLARE r uuid := uuidv7(); rl uuid := uuidv7(); n uuid; mv uuid;
BEGIN
  PERFORM c_ctx('A');
  INSERT INTO purchase.receipt (tenant_id, id, company_id, branch_id, doc_date, supplier_party_id, warehouse_id, currency)
  VALUES (k('A'), r, k('CA'), k('BA'), '2026-05-09', k('S1'), k('W1'), 'IRR');
  INSERT INTO purchase.receipt_line (tenant_id, id, receipt_id, line_no, item_id, variant_id, uom_id, qty, qty_base, unit_price, value_txn, value_base)
  VALUES (k('A'), rl, r, 1, k('I.X'), k('V.X'), k('PCS'), 1, 1, 90000, 90000, 90000);
  mv := c_mv('CA','W1','X','receipt',1,'2026-05-09', jsonb_build_object('value', 90000, 'module','purchase','doc_type','purchase.receipt','doc', r, 'line', rl));
  n := c_num(k('CA'), 'purchase.receipt', r);
  UPDATE purchase.receipt SET status = 'posted', posted_at = now(), number_issued_id = n, doc_no = c_no(n), gl_status = 'posted',
         gl_journal_id = c_stock_jr(k('CA'), '2026-05-09', 'purchase.receipt', r, ARRAY[r]) WHERE id = r;
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM c_err(format($q$UPDATE purchase.receipt SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'x',
                         cancel_journal_id = c_rev_jr(gl_journal_id, '2026-05-09') WHERE id = %L$q$, r), 'HK_PUR_CANCEL_STOCK', 'T51 cancel reverses the receipt move');
  PERFORM c_mv('CA','W1','X','receipt',-1,'2026-05-09', jsonb_build_object('rev', mv, 'module','purchase','doc_type','purchase.receipt','doc', r, 'line', rl));
  PERFORM c_err(format($q$UPDATE purchase.receipt SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'x' WHERE id = %L$q$, r),
                'receipt_cancel_gl', 'T51 a GL-posted receipt is cancelled with a cancel journal');
  PERFORM c_err(format($q$UPDATE purchase.receipt SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'x',
                         cancel_journal_id = c_journal(k('CA'), '2026-05-09', 'inventory', 'purchase.receipt', %L, 'cancel') WHERE id = %L$q$, r, r),
                'HK_COMMERCE_GL_NOT_REVERSED', 'T51 the receipt journal is reversed (Inventory/GRNI do not stay in GL)');
  UPDATE purchase.receipt SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'x',
         cancel_journal_id = c_rev_jr(gl_journal_id, '2026-05-09') WHERE id = r;
END $$;

-- ---------- T52 (INV-PUR-08): برگشت از خرید ----------
DO $$
DECLARE pi uuid := '30a00000-0000-7000-8000-0000000f0601';
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_err(format($q$SELECT c_pinv(jsonb_build_object('kind','return','original',%L::uuid,'orig_line','30a00000-0000-7000-8000-0000000f0611','qty',11,'post',true,'date','2026-05-08'))$q$, pi),
                'HK_INV_COST_SOURCE', 'T52 a single return move cannot exceed its receipt move');
  PERFORM c_err(format($q$SELECT c_pinv(jsonb_build_object('kind','return','original',%L::uuid,'orig_line','30a00000-0000-7000-8000-0000000f0611','qty',2,'post',true,
                         'date','2026-05-08','rule','pool_out'))$q$, pi),
                'HK_PUR_RETURN_COST', 'T52 a purchase return relieves stock at the receipt cost, not pool average');
  PERFORM c_pinv(jsonb_build_object('id','30a00000-0000-7000-8000-0000000f0701','kind','return','original',pi,'orig_line','30a00000-0000-7000-8000-0000000f0611',
                                    'qty',2,'post',true,'date','2026-05-08'));
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM c_err(format($q$SELECT c_pinv(jsonb_build_object('kind','return','original',%L::uuid,'orig_line','30a00000-0000-7000-8000-0000000f0611','qty',9,'post',true,
                         'skip_stock',true,'date','2026-05-08'))$q$, pi),
                'HK_PUR_RETURN_QTY', 'T52 cannot return more than purchased (cumulative over returns)');
  PERFORM c_err(format($q$SELECT c_pinv(jsonb_build_object('kind','return','original',%L::uuid,'orig_line','30a00000-0000-7000-8000-0000000f0611','qty',9,'post',true,'date','2026-05-08'))$q$, pi),
                'HK_INV_COST_SOURCE_EXHAUSTED', 'T52 return moves cannot exceed the receipt move cumulatively (RV-COM-05)');
  PERFORM c_ok((SELECT move_kind = 'purchase_return' AND qty_base = -2 FROM inventory.stock_move WHERE source_doc_id = '30a00000-0000-7000-8000-0000000f0701'),
               'T52 return issues stock at the receipt cost');
  PERFORM c_err(format($q$SELECT c_pinv(jsonb_build_object('kind','return','original',%L::uuid,'qty',1,'post',true,'skip_stock',true,'date','2026-05-08'))$q$, pi),
                'HK_PUR_RETURN_LINE', 'T52 return line references the purchased line');
  PERFORM c_err(format($q$SELECT c_pinv(jsonb_build_object('kind','return','original',%L::uuid,'orig_line','30a00000-0000-7000-8000-0000000f0611','qty',1,'post',true,'skip_stock',true,'date','2026-05-08','supplier','30a00000-0000-7000-8000-00000000a202'))$q$, pi),
                'HK_PUR_ORIGINAL_INVOICE', 'T52 return to the same supplier');
END $$;

-- ---------- T53 (INV-PUR-09): ابطال فاکتور خرید با برگشت فعال ----------
DO $$
DECLARE pi uuid := '30a00000-0000-7000-8000-0000000f0601';
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_err(format($q$UPDATE purchase.invoice SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'x',
                         cancel_journal_id = c_rev_jr(gl_journal_id, '2026-05-05') WHERE id = %L$q$, pi),
                'HK_PUR_CANCEL_HAS_DEPENDENTS', 'T53 returned invoice cannot be cancelled');
  PERFORM c_err(format($q$UPDATE purchase.invoice SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'x' WHERE id = %L$q$, pi),
                'pinv_cancel_gl', 'T53 cancel needs its GL journal');
END $$;
-- ابطال فاکتور خرید بدون برگشت: حرکت‌ها برگردند و سند ابطال برگشت اسناد خرید و موجودی همین فاکتور باشد (RV-COM-02)
DO $$
DECLARE pi uuid := uuidv7(); l uuid := uuidv7(); mv uuid; sj uuid;
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_pinv(jsonb_build_object('id', pi, 'line_id', l, 'qty', 1, 'post', true, 'date', '2026-05-09'));
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  SELECT stock_journal_id INTO sj FROM purchase.invoice WHERE id = pi;
  PERFORM c_err(format($q$UPDATE purchase.invoice SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'x',
                         cancel_journal_id = c_rev_jr(gl_journal_id, '2026-05-09') WHERE id = %L$q$, pi),
                'HK_PUR_CANCEL_STOCK', 'T53 cancel reverses the stock moves first');
  SELECT id INTO mv FROM inventory.stock_move WHERE source_doc_id = pi;
  PERFORM c_mv('CA','W1','X','receipt',-1,'2026-05-09', jsonb_build_object('rev', mv, 'module','purchase','doc_type','purchase.invoice','doc', pi, 'line', l));
  PERFORM c_err(format($q$UPDATE purchase.invoice SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'x',
                         cancel_journal_id = c_journal(k('CA'), '2026-05-09', 'sales', 'sales.invoice', uuidv7(), 'cancel') WHERE id = %L$q$, pi),
                'HK_COMMERCE_GL_LINK', 'T53 a sales journal is not the purchase cancel journal');
  PERFORM c_err(format($q$UPDATE purchase.invoice SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'x',
                         cancel_journal_id = c_rev_jr(gl_journal_id, '2026-05-09') WHERE id = %L$q$, pi),
                'HK_COMMERCE_GL_NOT_REVERSED', 'T53 the inventory journal is reversed too');
  PERFORM c_rev_jr(sj, '2026-05-09');
  UPDATE purchase.invoice SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'x', cancel_journal_id = c_rev_jr(gl_journal_id, '2026-05-09')
   WHERE id = pi;
END $$;

-- ---------- T54 (INV-PUR-10..12): صورتحساب‌های خرید کارپوشه ----------
DO $$
DECLARE b uuid := uuidv7(); x uuid := uuidv7();
BEGIN
  PERFORM c_ctx('A');
  INSERT INTO purchase.moadian_inbox_batch (tenant_id, id, company_id, attachment_id, file_sha256, format_version, amount_unit, row_count)
  VALUES (k('A'), b, k('CA'), '30a00000-0000-7000-8000-0000000a7001', sha256('file-1'::bytea), 'karpoosheh-xlsx-1404', 'IRR', 2);
  PERFORM c_err(format($q$INSERT INTO purchase.moadian_inbox_batch (tenant_id, company_id, attachment_id, file_sha256, format_version, amount_unit)
                         VALUES (k('A'), k('CA'), '30a00000-0000-7000-8000-0000000a7001', sha256('file-1'::bytea), 'karpoosheh-xlsx-1404', 'IRR')$q$),
                '23505', 'T54 same file imported twice');
  INSERT INTO purchase.moadian_inbox_invoice (tenant_id, id, company_id, first_batch_id, last_batch_id, taxid, issue_date, seller_tin, invoice_type,
                                              invoice_subject, total_amount, vat_amount, portal_status, raw_row, supplier_party_id)
  VALUES (k('A'), x, k('CA'), b, b, 'A1B2C3D4E5F6A7B8C9D0E1', '2026-05-05', '10101010101', 1, 1, 1150000, 100000, 'confirmed', '{"row":1}', k('S1'));
  PERFORM c_err(format($q$UPDATE purchase.moadian_inbox_invoice SET match_status = 'matched', matched_at = now() WHERE id = %L$q$, x),
                'inbox_match_shape', 'T54 matched row names the purchase invoice');
  PERFORM c_err(format($q$UPDATE purchase.moadian_inbox_invoice SET match_status = 'matched', matched_at = now(),
                         matched_invoice_id = (SELECT id FROM purchase.invoice WHERE supplier_invoice_no = 'S2-77') WHERE id = %L$q$, x),
                'HK_PUR_INBOX_MATCH', 'T54 match only the same supplier');
  UPDATE purchase.moadian_inbox_invoice SET match_status = 'matched', matched_at = now(), matched_by = k('U1'),
         matched_invoice_id = '30a00000-0000-7000-8000-0000000f0601', buyer_reaction = 'accepted' WHERE id = x;
  INSERT INTO purchase.moadian_inbox_invoice (tenant_id, company_id, first_batch_id, last_batch_id, taxid, issue_date, seller_tin, total_amount,
                                              portal_status, raw_row, match_status, matched_invoice_id, matched_at)
  VALUES (k('A'), k('CA'), b, b, 'ZZB2C3D4E5F6A7B8C9D0E1', '2026-05-07', '10101010102', 506000, 'confirmed', '{}', 'matched',
          (SELECT id FROM purchase.invoice WHERE supplier_invoice_no = 'S2-77'), now());
  PERFORM c_err(format($q$INSERT INTO purchase.moadian_inbox_invoice (tenant_id, company_id, first_batch_id, last_batch_id, taxid, issue_date, seller_tin, total_amount,
                         portal_status, raw_row, match_status, matched_invoice_id, matched_at)
                         VALUES (k('A'), k('CA'), %L, %L, 'YYB2C3D4E5F6A7B8C9D0E1', '2026-05-07', '10101010102', 1, 'confirmed', '{}', 'matched',
                                 (SELECT id FROM purchase.invoice WHERE supplier_invoice_no = 'S2-77'), now())$q$, b, b), '23505', 'T54 one inbox row per purchase invoice');
  PERFORM c_err(format($q$UPDATE purchase.moadian_inbox_invoice SET taxid = 'QQB2C3D4E5F6A7B8C9D0E1' WHERE id = %L$q$, x), 'HK_PUR_INBOX_IMMUTABLE', 'T54 taxid immutable');
  PERFORM c_err(format($q$INSERT INTO purchase.moadian_inbox_invoice (tenant_id, company_id, first_batch_id, last_batch_id, taxid, issue_date, seller_tin, total_amount,
                         portal_status, raw_row) VALUES (k('A'), k('CA'), %L, %L, 'A1B2C3D4E5F6A7B8C9D0E1', '2026-05-05', '10101010101', 1, 'confirmed', '{}')$q$, b, b),
                '23505', 'T54 one row per taxid (re-import updates it)');
  PERFORM c_err(format($q$INSERT INTO purchase.moadian_inbox_invoice (tenant_id, company_id, first_batch_id, last_batch_id, taxid, issue_date, seller_tin, total_amount,
                         portal_status, raw_row, invoice_subject) VALUES (k('A'), k('CA'), %L, %L, 'B1B2C3D4E5F6A7B8C9D0E1', '2026-05-05', '10101010101', 1, 'confirmed', '{}', 2)$q$, b, b),
                'inbox_reference', 'T54 corrective/return invoices reference their original taxid');
END $$;

-- ---------- T55 (INV-PUR-13): درخواست و سفارش خرید ----------
DO $$
DECLARE rq uuid := uuidv7(); po uuid := uuidv7(); n uuid;
BEGIN
  PERFORM c_ctx('A');
  INSERT INTO purchase."order" (tenant_id, id, company_id, branch_id, kind, doc_date, currency) VALUES (k('A'), rq, k('CA'), k('BA'), 'requisition', '2026-05-01', 'IRR');
  n := c_num(k('CA'), 'purchase.requisition', rq);
  UPDATE purchase."order" SET status = 'submitted', number_issued_id = n, doc_no = c_no(n) WHERE id = rq;
  UPDATE purchase."order" SET status = 'approved' WHERE id = rq;
  PERFORM c_err(format($q$UPDATE purchase."order" SET status = 'confirmed' WHERE id = %L$q$, rq), 'HK_COMMERCE_DOC_TRANSITION|po_kind_status', 'T55 requisitions are not confirmed');
  INSERT INTO purchase."order" (tenant_id, id, company_id, branch_id, kind, doc_date, currency, supplier_party_id, requisition_id)
  VALUES (k('A'), po, k('CA'), k('BA'), 'order', '2026-05-02', 'IRR', k('S1'), rq);
  INSERT INTO purchase.order_line (tenant_id, order_id, line_no, item_id, variant_id, uom_id, qty, qty_base, unit_price, net_amount)
  VALUES (k('A'), po, 1, k('I.X'), k('V.X'), k('PCS'), 5, 5, 100000, 500000);
  n := c_num(k('CA'), 'purchase.order', po);
  UPDATE purchase."order" SET status = 'confirmed', confirmed_at = now(), number_issued_id = n, doc_no = c_no(n) WHERE id = po;
  PERFORM c_err(format($q$UPDATE purchase."order" SET supplier_party_id = k('S2') WHERE id = %L$q$, po), 'HK_COMMERCE_DOC_IMMUTABLE', 'T55 confirmed PO immutable');
  PERFORM c_err(format($q$UPDATE purchase."order" SET status = 'draft' WHERE id = %L$q$, po), 'HK_COMMERCE_DOC_TRANSITION', 'T55 no way back to draft');
  PERFORM c_err($q$INSERT INTO purchase."order" (tenant_id, company_id, branch_id, kind, doc_date, currency, status) VALUES (k('A'), k('CA'), k('BA'), 'order', '2026-05-02', 'IRR', 'confirmed')$q$,
                'HK_COMMERCE_DOC_TRANSITION', 'T55 POs start as draft');
  UPDATE purchase."order" SET status = 'closed', closed_at = now() WHERE id = po;
  PERFORM c_ok((SELECT origin FROM purchase."order" WHERE id = po) = 'manual', 'T55 purchase orders record their origin (C-AS-12)');
  INSERT INTO purchase."order" (tenant_id, company_id, branch_id, kind, doc_date, currency, supplier_party_id, origin)
  VALUES (k('A'), k('CA'), k('BA'), 'order', '2026-05-03', 'IRR', k('S1'), 'assistant');
  PERFORM c_err($q$INSERT INTO purchase."order" (tenant_id, company_id, branch_id, kind, doc_date, currency, origin) VALUES (k('A'), k('CA'), k('BA'), 'order', '2026-05-03', 'IRR', 'robot')$q$,
                '23514', 'T55 origin is a known source');
  PERFORM c_err($q$DELETE FROM purchase."order" WHERE status = 'closed'$q$, 'HK_COMMERCE_DOC_IMMUTABLE', 'T55 a non-draft purchase order cannot be deleted');
  -- دستیار (C-AS-02): پیش‌نویس سفارش در تراکنش assistant_confirm آزاد؛ حرکت انبار و گذار سند نه
  PERFORM set_config('app.actor_via', 'assistant_confirm', true);
  INSERT INTO purchase."order" (tenant_id, company_id, branch_id, kind, doc_date, currency, supplier_party_id, origin)
  VALUES (k('A'), k('CA'), k('BA'), 'order', '2026-05-04', 'IRR', k('S1'), 'assistant');
  PERFORM c_err($q$SELECT c_mv('CA','W1','X','receipt',1,'2026-05-04','{"value":1}')$q$, 'HK_CORE_ACTOR_VIA', 'T55 the assistant cannot move stock');
  PERFORM c_err($q$UPDATE purchase."order" SET status = 'submitted', number_issued_id = c_num(k('CA'), 'purchase.order', id), doc_no = 'PO-A'
                   WHERE origin = 'assistant' AND doc_date = '2026-05-04'$q$, 'HK_CORE_ACTOR_VIA', 'T55 the assistant cannot submit or post documents');
  PERFORM set_config('app.actor_via', 'direct', true);
END $$;

-- ---------- T56 (INV-PUR-14/15): فاکتور خرید خالی؛ لغو سفارش رسیده ----------
DO $$
DECLARE pi uuid := uuidv7(); po uuid := uuidv7(); ol uuid := uuidv7(); r uuid := uuidv7(); rl uuid := uuidv7(); n uuid;
BEGIN
  PERFORM c_ctx('A');
  INSERT INTO purchase.invoice (tenant_id, id, company_id, branch_id, doc_date, supplier_party_id, supplier_invoice_no, currency, currency_minor, stock_mode)
  VALUES (k('A'), pi, k('CA'), k('BA'), '2026-05-07', k('S2'), 'S2-EMPTY', 'IRR', 0, 'none');
  n := c_num(k('CA'), 'purchase.invoice', pi);
  PERFORM c_err(format($q$UPDATE purchase.invoice SET status = 'posted', posted_at = now(), number_issued_id = %L, doc_no = 'P', gl_status = 'posted',
                         gl_journal_id = c_journal(k('CA'), '2026-05-07', 'purchase', 'purchase.invoice', %L) WHERE id = %L$q$, n, pi, pi),
                'HK_PUR_EMPTY', 'T56 posted purchase invoice has lines');
  INSERT INTO purchase."order" (tenant_id, id, company_id, branch_id, kind, doc_date, currency, supplier_party_id) VALUES (k('A'), po, k('CA'), k('BA'), 'order', '2026-05-02', 'IRR', k('S1'));
  INSERT INTO purchase.order_line (tenant_id, id, order_id, line_no, item_id, variant_id, uom_id, qty, qty_base, unit_price, net_amount)
  VALUES (k('A'), ol, po, 1, k('I.X'), k('V.X'), k('PCS'), 1, 1, 100000, 100000);
  n := c_num(k('CA'), 'purchase.order', po);
  UPDATE purchase."order" SET status = 'confirmed', confirmed_at = now(), number_issued_id = n, doc_no = c_no(n) WHERE id = po;
  INSERT INTO purchase.receipt (tenant_id, id, company_id, branch_id, doc_date, supplier_party_id, order_id, warehouse_id, currency)
  VALUES (k('A'), r, k('CA'), k('BA'), '2026-05-08', k('S1'), po, k('W1'), 'IRR');
  INSERT INTO purchase.receipt_line (tenant_id, id, receipt_id, line_no, order_line_id, item_id, variant_id, uom_id, qty, qty_base, unit_price, value_txn, value_base)
  VALUES (k('A'), rl, r, 1, ol, k('I.X'), k('V.X'), k('PCS'), 1, 1, 100000, 100000, 100000);
  PERFORM c_mv('CA','W1','X','receipt',1,'2026-05-08', jsonb_build_object('value', 100000, 'module','purchase','doc_type','purchase.receipt','doc', r, 'line', rl));
  n := c_num(k('CA'), 'purchase.receipt', r);
  UPDATE purchase.receipt SET status = 'posted', posted_at = now(), number_issued_id = n, doc_no = c_no(n), gl_status = 'posted',
         gl_journal_id = c_stock_jr(k('CA'), '2026-05-08', 'purchase.receipt', r, ARRAY[r]) WHERE id = r;
  PERFORM c_err(format($q$UPDATE purchase."order" SET status = 'cancelled', cancel_reason = 'انصراف' WHERE id = %L$q$, po), 'HK_PUR_ORDER_RECEIVED', 'T56 received PO only closes');
END $$;

-- ---------- T60 (RV-COM-10): کدهای نگهبانی که پیش‌تر هیچ آزمونی نداشتند (هر ادعا فقط یک کد را می‌پذیرد) ----------
DO $$
DECLARE b uuid := uuidv7(); run uuid; s uuid := uuidv7(); it uuid := uuidv7(); va uuid := uuidv7(); sn uuid := uuidv7(); mv uuid;
BEGIN
  PERFORM c_ctx('A');
  -- bundle سریالی: یک سریال برای هر واحد
  INSERT INTO inventory.tracking_bundle (tenant_id, id, company_id, item_id, variant_id, warehouse_id, direction, total_qty_base)
  VALUES (k('A'), b, k('CA'), k('I.TV'), k('V.TV'), k('W1'), 'in', 2);
  INSERT INTO inventory.tracking_bundle_entry (tenant_id, bundle_id, serial_no, qty_base) VALUES (k('A'), b, 'NEW-SN-1', 1);
  INSERT INTO inventory.tracking_bundle_entry (tenant_id, bundle_id, new_batch_no, qty_base) VALUES (k('A'), b, 'LOT1', 1);
  PERFORM c_err(format($q$UPDATE inventory.tracking_bundle SET status = 'posted', source_doc_type = 'purchase.receipt', source_doc_id = uuidv7() WHERE id = %L$q$, b),
                'HK_INV_BUNDLE_QTY', 'T60 serial-tracked bundle needs one serial per unit');
  -- بازارزیابی با run شرکت دیگر
  INSERT INTO inventory.repost_run (tenant_id, company_id, trigger_reason, gl_floor_date) VALUES (k('A'), k('CF'), 'manual', '2026-04-01') RETURNING id INTO run;
  PERFORM c_err(format($q$SELECT inventory.repost_pool((SELECT id FROM inventory.cost_pool WHERE company_id = k('CA') LIMIT 1), %L, '2026-04-01')$q$, run),
                'HK_INV_REPOST_RUN', 'T60 a repost run serves only its own company');
  -- حرکت با بچ برای کالای بی‌بچ
  PERFORM c_err($q$SELECT c_mv('CA','W1','X','receipt',1,'2026-04-20', jsonb_build_object('value',1,'batch','30a00000-0000-7000-8000-0000000b0001'))$q$,
                'HK_INV_BATCH_NOT_TRACKED', 'T60 a non-batch item moves without batch');
  -- سریال ثبت‌شده و سپس خاموش‌شدن ردیابی پیش از نخستین حرکت: حرکت با سریال رد می‌شود (stock_move_verify)
  INSERT INTO catalog.item (tenant_id, id, code, name, item_type, base_uom_id, track_serial) VALUES (k('A'), it, 'SNX', 'سریالی موقت', 'stock', k('PCS'), true);
  INSERT INTO catalog.item_uom (tenant_id, item_id, uom_id, factor, is_base) VALUES (k('A'), it, k('PCS'), 1, true);
  INSERT INTO catalog.item_variant (tenant_id, id, item_id, code, is_default) VALUES (k('A'), va, it, 'SNX', true);
  INSERT INTO inventory.serial (tenant_id, id, item_id, variant_id, serial_no) VALUES (k('A'), sn, it, va, 'SNX-1');
  UPDATE catalog.item SET track_serial = false WHERE id = it;
  PERFORM c_err(format($q$WITH m AS (SELECT c_move(jsonb_build_object('company',k('CA'),'wh',k('W1'),'item',%L::uuid,'variant',%L::uuid,'kind','receipt','qty',1,
                                                      'date','2026-07-20','value',1)) AS id)
                         INSERT INTO inventory.serial_move (tenant_id, move_id, serial_id) SELECT k('A'), m.id, %L FROM m$q$, it, va, sn),
                'HK_INV_SERIAL_NOT_TRACKED', 'T60 serial moves only for serial-tracked items');
  -- انبارگردانی: درج غیرپیش‌نویس، حذف غیرپیش‌نویس، انبار/تاریخ ثابت پس از آغاز شمارش
  PERFORM c_err($q$INSERT INTO inventory.count_session (tenant_id, company_id, warehouse_id, count_date, status, started_at) VALUES (k('A'), k('CA'), k('W9'), '2026-07-01', 'counting', now())$q$,
                'HK_INV_COUNT_STATE', 'T60 count sessions start as draft');
  INSERT INTO inventory.count_session (tenant_id, id, company_id, warehouse_id, count_date) VALUES (k('A'), s, k('CA'), k('W9'), '2026-07-01');
  UPDATE inventory.count_session SET status = 'counting', started_at = now() WHERE id = s;
  PERFORM c_err(format($q$UPDATE inventory.count_session SET count_date = '2026-07-02' WHERE id = %L$q$, s), 'HK_INV_COUNT_STATE', 'T60 count date fixed once counting starts');
  PERFORM c_err(format($q$DELETE FROM inventory.count_session WHERE id = %L$q$, s), 'HK_INV_COUNT_STATE', 'T60 only draft count sessions are deleted');
  UPDATE inventory.count_session SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'آزمون' WHERE id = s;
  -- سرسند ثبت‌شدنی و سفارش و دستهٔ GL
  PERFORM c_err($q$INSERT INTO sales.delivery (tenant_id, company_id, branch_id, doc_date, customer_party_id, warehouse_id, status, number_issued_id, doc_no, posted_at, gl_status)
                  VALUES (k('A'), k('CA'), k('BA'), '2026-07-01', k('C2'), k('W1'), 'posted', c_num(k('CA'), 'sales.delivery', uuidv7()), 'DX', now(), 'not_required')$q$,
                'HK_COMMERCE_DOC_TRANSITION', 'T60 deliveries start as draft');
  PERFORM c_err($q$DELETE FROM sales."order" WHERE status = 'confirmed'$q$, 'HK_COMMERCE_DOC_IMMUTABLE', 'T60 a confirmed sales order cannot be deleted');
  PERFORM c_err($q$DELETE FROM sales.gl_batch WHERE status = 'posted'$q$, 'HK_SALES_BATCH_CLOSED', 'T60 a posted GL batch cannot be deleted');
END $$;

-- ---------- T61 (INV-PCK-01..06، RV-COM-26): بستهٔ صنفی روی جدول‌های rules (فقط وقتی 50_compliance اعمال شده است) ----------
RESET ROLE;
DO $$
DECLARE tp uuid := uuidv7(); m jsonb := '{"format":"hkpack/1","pack":"zz_test","version":"1.0.0"}';
BEGIN
  IF to_regclass('rules.tenant_pack') IS NULL THEN
    RAISE NOTICE 'SKIP T61: rules pack tables (50_compliance.sql) are not in this database';
    RETURN;
  END IF;
  PERFORM c_ctx('A');
  BEGIN
    EXECUTE $q$INSERT INTO rules.industry_pack (code, name_fa, kind, introduced_in) VALUES ('zz_test', 'آزمون', 'industry', '1.0')$q$;
    PERFORM c_err($q$INSERT INTO rules.industry_pack_version (pack_code, version, manifest, manifest_sha256, min_app_version)
                    VALUES ('zz_test', '1.0.0', '{"format":"hkpack/1","pack":"other","version":"1.0.0"}', sha256('m'::bytea), '1.0')$q$,
                  '23514', 'T61 INV-PCK-01 manifest names its own pack/version');
    PERFORM c_err(format($q$INSERT INTO rules.industry_pack_version (pack_code, version, manifest, manifest_sha256, min_app_version, status, published_at)
                    VALUES ('zz_test', '1.0.0', %L, sha256('m'::bytea), '1.0', 'published', now())$q$, m),
                  '23514', 'T61 INV-PCK-02 publishing needs review and a signed HKSB hash');
    EXECUTE format($q$INSERT INTO rules.industry_pack_version (pack_code, version, manifest, manifest_sha256, hksb_sha256, min_app_version, status, published_at, reviewed_by)
                      VALUES ('zz_test', '1.0.0', %L, sha256('m'::bytea), sha256('h'::bytea), '1.0', 'published', now(), 'reviewer')$q$, m);
    EXECUTE format($q$INSERT INTO rules.tenant_pack (tenant_id, id, company_id, pack_code, installed_version, status) VALUES (%L, %L, %L, 'zz_test', '1.0.0', 'active')$q$,
                   k('A'), tp, k('CA'));
    PERFORM c_err(format($q$INSERT INTO rules.tenant_pack (tenant_id, company_id, pack_code, installed_version) VALUES (%L, %L, 'zz_test', '1.0.0')$q$, k('A'), k('CA')),
                  '23505', 'T61 INV-PCK-03 one install per company');
    EXECUTE format($q$INSERT INTO rules.tenant_pack (tenant_id, company_id, pack_code, installed_version) VALUES (%L, NULL, 'zz_test', '1.0.0')$q$, k('A'));
    PERFORM c_err(format($q$INSERT INTO rules.tenant_pack (tenant_id, company_id, pack_code, installed_version) VALUES (%L, NULL, 'zz_test', '1.0.0')$q$, k('A')),
                  '23505', 'T61 INV-PCK-03 one tenant-level install');
    PERFORM c_err(format($q$INSERT INTO rules.tenant_pack (tenant_id, company_id, pack_code, installed_version) VALUES (%L, %L, 'zz_test', '9.9.9')$q$, k('A'), k('CF')),
                  '23503', 'T61 INV-PCK-06 installed version exists');
    EXECUTE format($q$INSERT INTO rules.pack_artifact (tenant_id, tenant_pack_id, module, entity_type, artifact_key, entity_id, installed_version, content_sha256)
                      VALUES (%L, %L, 'sales', 'sales.pricing_rule', 'HAPPY_HOUR', %L, '1.0.0', sha256('a'::bytea))$q$, k('A'), tp, k('CA'));
    PERFORM c_err(format($q$INSERT INTO rules.pack_artifact (tenant_id, tenant_pack_id, module, entity_type, artifact_key, entity_id, installed_version, content_sha256)
                      VALUES (%L, %L, 'sales', 'sales.pricing_rule', 'HAPPY_HOUR2', %L, '1.0.0', sha256('b'::bytea))$q$, k('A'), tp, k('CA')),
                  '23505', 'T61 INV-PCK-04 one managing pack per entity');
    PERFORM c_err(format($q$INSERT INTO rules.pack_artifact (tenant_id, tenant_pack_id, module, entity_type, artifact_key, entity_id, installed_version, content_sha256)
                      VALUES (%L, %L, 'inventory', 'sales.pricing_rule', 'X', uuidv7(), '1.0.0', sha256('c'::bytea))$q$, k('A'), tp),
                  '23514', 'T61 INV-PCK-04 artifact entity belongs to its module');
    EXECUTE format($q$INSERT INTO rules.tenant_pack_event (tenant_id, tenant_pack_id, action, to_version, outcome, plan) VALUES (%L, %L, 'install', '1.0.0', 'succeeded', '{}')$q$, k('A'), tp);
    PERFORM c_err($q$UPDATE rules.tenant_pack_event SET outcome = 'failed'$q$, 'HK_IMMUTABLE|immutable|append', 'T61 INV-PCK-05 pack events are append-only');
    RAISE EXCEPTION USING ERRCODE = 'HKT61', MESSAGE = 'rollback T61';
  EXCEPTION WHEN SQLSTATE 'HKT61' THEN NULL;
  END;
END $$;
SET ROLE hk_app;

-- =====================================================================
-- بخش ۳: جداسازی مستأجر و نقش فقط‌خواندنی
-- =====================================================================
-- ---------- T90 (INV-COM-01/02/05): مستأجر B هیچ دادهٔ A را نمی‌بیند و به آن ارجاع نمی‌دهد ----------
DO $$
DECLARE n bigint; v_pool uuid; v_move uuid;
BEGIN
  PERFORM c_ctx('A');
  SELECT id INTO v_pool FROM inventory.cost_pool LIMIT 1;
  SELECT id INTO v_move FROM inventory.stock_move WHERE move_kind = 'receipt' AND valuation_rule = 'input' LIMIT 1;
  PERFORM set_config('hk.test_pool', v_pool::text, false);
  PERFORM set_config('hk.test_move', v_move::text, false);
END $$;
DO $$
DECLARE n bigint; v int;
BEGIN
  PERFORM c_ctx('B');
  SELECT count(*) INTO n FROM (
    SELECT id FROM inventory.company_policy WHERE company_id <> k('CB') UNION ALL SELECT id FROM inventory.warehouse UNION ALL SELECT id FROM inventory.stock_move
    UNION ALL SELECT id FROM inventory.valuation_layer UNION ALL SELECT id FROM inventory.cost_pool UNION ALL SELECT id FROM inventory.fifo_layer
    UNION ALL SELECT id FROM inventory.stock_balance UNION ALL SELECT id FROM inventory.serial UNION ALL SELECT id FROM inventory.serial_move
    UNION ALL SELECT id FROM inventory.batch UNION ALL SELECT id FROM inventory.stock_doc UNION ALL SELECT id FROM inventory.count_session
    UNION ALL SELECT id FROM inventory.stock_exception UNION ALL SELECT id FROM inventory.repost_run UNION ALL SELECT id FROM inventory.periodic_close
    UNION ALL SELECT id FROM inventory.tracking_bundle
    UNION ALL SELECT id FROM sales.invoice UNION ALL SELECT id FROM sales.invoice_line UNION ALL SELECT id FROM sales.invoice_line_discount
    UNION ALL SELECT id FROM sales."order" UNION ALL SELECT id FROM sales.pricing_rule UNION ALL SELECT id FROM sales.credit_check
    UNION ALL SELECT id FROM sales.delivery UNION ALL SELECT id FROM sales.commission_entry UNION ALL SELECT id FROM sales.gl_batch
    UNION ALL SELECT id FROM purchase.invoice UNION ALL SELECT id FROM purchase.receipt UNION ALL SELECT id FROM purchase."order"
    UNION ALL SELECT id FROM purchase.invoice_charge UNION ALL SELECT id FROM purchase.moadian_inbox_invoice UNION ALL SELECT id FROM purchase.cost_allocation) x;
  PERFORM c_ok(n = 0, 'T90 tenant B sees nothing of tenant A');
  PERFORM c_ok((SELECT count(*) FROM inventory.v_move_value) = 0 AND (SELECT count(*) FROM inventory.v_kardex) = 0
               AND (SELECT count(*) FROM inventory.v_stock_on_hand) = 0 AND (SELECT count(*) FROM sales.v_invoice_current) = 0
               AND (SELECT count(*) FROM sales.v_invoice_line_margin) = 0 AND (SELECT count(*) FROM purchase.v_receipt_line_unbilled) = 0,
               'T90 views are security_invoker');
  PERFORM c_ok(NOT EXISTS (SELECT 1 FROM inventory.ledger_subledger_stock(k('CF'), '2026-12-31')), 'T90 subledger function respects RLS');
  PERFORM c_err(format($q$WITH r AS (INSERT INTO inventory.repost_run (tenant_id, company_id, trigger_reason, gl_floor_date)
                                     VALUES (k('B'), k('CB'), 'manual', '2026-05-01') RETURNING id)
                         SELECT inventory.repost_pool(%L, r.id, %L) FROM r$q$, current_setting('hk.test_pool'), '2026-05-01'), 'HK_INV_POOL_NOT_FOUND',
                'T90 definer repost cannot reach another tenant''s pool');
  PERFORM c_err(format('SELECT inventory.verify_pool_replay(%L)', current_setting('hk.test_pool')), 'HK_INV_POOL_NOT_FOUND', 'T90 definer verify cannot reach another tenant');
  PERFORM c_err(format($q$SELECT inventory.add_cost_adjustment(%L, 10, 'landed_cost', 'purchase', 'purchase.invoice', uuidv7(), NULL)$q$, current_setting('hk.test_move')),
                'HK_INV_MOVE_NOT_FOUND', 'T90 definer adjustment cannot reach another tenant');
  PERFORM c_err(format('SELECT inventory.create_checkpoint(%L)', current_setting('hk.test_pool')), 'HK_INV_CHECKPOINT_STATE', 'T90 checkpoint cannot reach another tenant');
  PERFORM c_err($q$SELECT inventory.rebuild_derived(k('CA'))$q$, 'HK_INV_COMPANY_NOT_FOUND', 'T90 rebuild cannot reach another tenant''s company');
  PERFORM c_err($q$INSERT INTO inventory.warehouse (tenant_id, company_id, branch_id, code, name) VALUES (k('A'), k('CA'), k('BA'), 'EV', 'نفوذ')$q$,
                '42501', 'T90 cannot write rows of another tenant');
  PERFORM c_err($q$INSERT INTO inventory.warehouse (tenant_id, company_id, branch_id, code, name) VALUES (k('B'), k('CB'), k('BA'), 'EV', 'نفوذ')$q$,
                '23503', 'T90 cannot reference another tenant''s branch');
  INSERT INTO inventory.warehouse (tenant_id, id, company_id, branch_id, code, name) VALUES (k('B'), '30b00000-0000-7000-8000-00000000d001', k('CB'), k('BB'), 'W1', 'انبار ب');
  PERFORM c_err($q$SELECT c_move(jsonb_build_object('company',k('CB'),'wh','30b00000-0000-7000-8000-00000000d001','item',k('I.X'),'variant',k('V.X'),
                    'kind','receipt','qty',1,'date','2026-04-01','value',1,'no_acct',true))$q$, 'HK_INV_SKU_NOT_FOUND', 'T90 cannot move another tenant''s SKU');
  PERFORM c_err($q$INSERT INTO sales.invoice (tenant_id, company_id, branch_id, doc_kind, doc_date, original_invoice_id, customer_party_id, currency, currency_minor, stock_mode)
                  VALUES (k('B'), k('CB'), k('BB'), 'return', '2026-05-20', '30a00000-0000-7000-8000-0000000f0201', k('C2'), 'IRR', 0, 'none')$q$,
                '23503', 'T90 cannot return another tenant''s invoice');
  UPDATE sales.invoice SET notes = 'hacked' WHERE id = '30a00000-0000-7000-8000-0000000f0201';
  GET DIAGNOSTICS v = ROW_COUNT;
  PERFORM c_ok(v = 0, 'T90 cross-tenant update affects no rows');
END $$;
DO $$
BEGIN
  PERFORM c_ctx('');
  PERFORM c_err($q$SELECT inventory.pool_acquire(uuidv7(), uuidv7(), uuidv7(), NULL, '2026-04-01')$q$, 'HK_TENANT_CONTEXT_MISSING', 'T90 no tenant context: engine refuses');
  PERFORM c_err($q$SELECT inventory.rebuild_derived(uuidv7())$q$, 'HK_TENANT_CONTEXT_MISSING', 'T90 no tenant context: rebuild refuses');
  PERFORM c_ok((SELECT count(*) FROM inventory.stock_move) = 0 AND (SELECT count(*) FROM sales.invoice) = 0, 'T90 no tenant context sees nothing');
END $$;

-- ---------- T91 (INV-COM-03): کاتالوگ‌ها و lint امنیتی ----------
DO $$
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_ok((SELECT count(*) FROM ledger.posting_key WHERE key IN ('purchase.grni','purchase.price_difference','inventory.waste','sales.commission_payable')) = 4,
               'T91 posting keys registered');
  PERFORM c_ok((SELECT count(*) FROM core.permission WHERE module IN ('inventory','sales','purchase')) = 49, 'T91 permissions registered (49)');
  PERFORM c_ok(EXISTS (SELECT 1 FROM ledger.posting_key WHERE key = 'sales.service_charge' AND owner_module = 'sales'), 'T91 sales.service_charge registered (CR-T07)');
  -- نام رویداد = نام منتشرشدهٔ مالک (fan-out تطبیق دقیق دارد؛ RV-LEDGER-10، RV-TP-14)
  PERFORM c_ok(EXISTS (SELECT 1 FROM core.event_subscription WHERE event_type = 'ledger.fiscal_year.closed' AND subscriber = 'inventory.year_close')
               AND NOT EXISTS (SELECT 1 FROM core.event_subscription WHERE event_type = 'ledger.year.closed' AND subscriber LIKE 'inventory.%')
               AND EXISTS (SELECT 1 FROM core.event_subscription WHERE event_type = 'pos.order.line_wasted' AND subscriber = 'inventory.pos_waste'),
               'T91 inventory subscribes to the published event names');
  PERFORM c_ok(NOT EXISTS (SELECT 1 FROM core.security_lint() WHERE object ~ '^(inventory|sales|purchase)\.'), 'T91 security lint clean for commerce');
  PERFORM c_err($q$INSERT INTO ledger.posting_key (key, owner_module, name_fa, introduced_in) VALUES ('sales.x', 'sales', 'x', 't')$q$, '42501', 'T91 catalogs are read-only');
END $$;
RESET ROLE;

-- ---------- T92 (INV-COM-04): نقش فقط‌خواندنی ----------
SET ROLE hk_readonly;
DO $$
BEGIN
  PERFORM c_ctx('A');
  PERFORM c_ok((SELECT count(*) FROM inventory.stock_move) > 10 AND (SELECT count(*) FROM sales.invoice) > 1 AND (SELECT count(*) FROM purchase.invoice) > 1,
               'T92 readonly can read');
  PERFORM c_err($q$INSERT INTO inventory.warehouse (tenant_id, company_id, branch_id, code, name) VALUES (k('A'), k('CA'), k('BA'), 'RO', 'فقط‌خواندنی')$q$,
                '42501', 'T92 readonly cannot write');
  PERFORM c_err($q$SELECT c_mv('CA','W1','X','receipt',1,'2026-05-01','{"value":1}')$q$, '42501', 'T92 readonly cannot post stock');
END $$;
RESET ROLE;

-- ---------- T93 (INV-INV-39): دست‌کاری لایه با superuser کشف می‌شود (ROLLBACK) ----------
BEGIN;
SELECT set_config('app.tenant_id', '30a00000-0000-7000-8000-000000000001', true) \g /dev/null
ALTER TABLE inventory.valuation_layer DISABLE TRIGGER trg_immutable;
UPDATE inventory.valuation_layer SET value = value - 7
 WHERE id = (SELECT l.id FROM inventory.valuation_layer l JOIN inventory.stock_move m ON m.id = l.move_id
              WHERE m.company_id = '30a00000-0000-7000-8000-0000000000c2' AND l.layer_kind = 'initial' AND l.is_derived ORDER BY m.posting_seq LIMIT 1);
DO $$
DECLARE v_msg text;
BEGIN
  BEGIN
    PERFORM inventory.rebuild_derived('30a00000-0000-7000-8000-0000000000c2');
    RAISE EXCEPTION 'TEST FAILED: T93 tampered derived layer not detected';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg NOT LIKE 'HK_INV_REBUILD_MISMATCH%' THEN RAISE; END IF;
  END;
END $$;
ROLLBACK;

-- ---------- T94 (RV-COM-15): همروندی واقعی — فاکتوری که هم‌زمان با ثبت دسته به آن می‌پیوندد رد می‌شود (dblink) ----------
-- نشست ۱ دسته را ثبت می‌کند و تراکنشش باز است؛ نشست ۲ فاکتور دسته‌ای را commit می‌کند و باید روی FOR SHARE منتظر بماند؛ پس از commit
-- نشست ۱، نشست ۲ وضعیت posted را می‌بیند و با HK_SALES_BATCH_CLOSED رد می‌شود (پیش از رفع، هر دو commit می‌شدند).
RESET ROLE;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'dblink') THEN
    CREATE SCHEMA IF NOT EXISTS t94;
    CREATE EXTENSION IF NOT EXISTS dblink SCHEMA t94;
  ELSE
    RAISE NOTICE 'SKIP T94: the contrib extension dblink is not installed';
  END IF;
END $$;
SET ROLE hk_app;
DO $$
DECLARE b uuid := '30a00000-0000-7000-8000-0000000fb001'; i uuid;
BEGIN
  PERFORM c_ctx('A');
  INSERT INTO sales.gl_batch (tenant_id, id, company_id, branch_id, batch_date, source_kind) VALUES (k('A'), b, k('CA'), k('BA'), '2026-06-20', 'pos_shift');
  i := c_inv(jsonb_build_object('gl_mode', 'batched', 'batch', b, 'setm', 'cash', 'inty', 2, 'date', '2026-06-20'));
  PERFORM c_line(i, 1, 'SRV', 1, 1000);
  PERFORM c_post(i);
END $$;
RESET ROLE;
DO $$
DECLARE v_pid int; v_res text; v_err text; v_conn text := format('dbname=%s user=%s host=%s port=%s', current_database(), current_user,
                                                   split_part(current_setting('unix_socket_directories'), ',', 1), current_setting('port'));
        v_blocked boolean := false;
BEGIN
  IF to_regnamespace('t94') IS NULL THEN RETURN; END IF;
  PERFORM t94.dblink_connect('s1', v_conn);
  PERFORM t94.dblink_connect('s2', v_conn);
  PERFORM t94.dblink_exec('s1', 'SET ROLE hk_app');
  PERFORM t94.dblink_exec('s2', 'SET ROLE hk_app');
  PERFORM t94.dblink_exec('s1', 'BEGIN');
  PERFORM 1 FROM t94.dblink('s1', $q$SELECT 1 FROM (SELECT c_ctx('A')) x$q$) AS x(v int);
  PERFORM t94.dblink_exec('s1', $q$UPDATE sales.gl_batch SET status = 'posted', posted_at = now(),
                                    gl_journal_id = c_jr(k('CA'), '2026-06-20', 'sales', 'sales.gl_batch', '30a00000-0000-7000-8000-0000000fb001', 'post',
                                      jsonb_build_array(jsonb_build_object('key','sales.receivable','dr',1100,'party',k('C2')),
                                                        jsonb_build_object('key','sales.revenue','cr',1000), jsonb_build_object('key','tax.vat_payable','cr',100)))
                                  WHERE id = '30a00000-0000-7000-8000-0000000fb001'$q$);
  PERFORM t94.dblink_exec('s2', 'BEGIN');
  PERFORM 1 FROM t94.dblink('s2', $q$SELECT 1 FROM (SELECT c_ctx('A')) x$q$) AS x(v int);
  SELECT x.pid INTO v_pid FROM t94.dblink('s2', 'SELECT pg_backend_pid()') AS x(pid int);
  PERFORM 1 FROM t94.dblink('s2', $q$SELECT 1 FROM (SELECT c_post(i.id) FROM (SELECT c_inv(jsonb_build_object('gl_mode','batched','batch','30a00000-0000-7000-8000-0000000fb001'::uuid,
                                     'setm','cash','inty',2,'date','2026-06-20')) AS id) i, LATERAL (SELECT c_line(i.id, 1, 'SRV', 1, 5000000)) l) z$q$) AS x(v int);
  PERFORM t94.dblink_send_query('s2', 'COMMIT');
  FOR n IN 1..200 LOOP
    IF EXISTS (SELECT 1 FROM pg_locks WHERE pid = v_pid AND NOT granted) THEN v_blocked := true; EXIT; END IF;
    PERFORM pg_sleep(0.02);
  END LOOP;
  PERFORM c_ok(v_blocked, 'T94 the joining invoice waits for the batch being posted (FOR SHARE vs the posting UPDATE)');
  PERFORM t94.dblink_exec('s1', 'COMMIT');
  SELECT x.v INTO v_res FROM t94.dblink_get_result('s2', false) AS x(v text);
  v_err := t94.dblink_error_message('s2');
  PERFORM 1 FROM t94.dblink_get_result('s2', false) AS x(v text);
  PERFORM t94.dblink_disconnect('s1');
  PERFORM t94.dblink_disconnect('s2');
  PERFORM c_ok(v_err LIKE '%HK_SALES_BATCH_CLOSED%', 'T94 the late invoice is rejected instead of escaping the batch journal: ' || coalesce(v_err, '<null>'));
  PERFORM set_config('app.tenant_id', '30a00000-0000-7000-8000-000000000001', true);
  PERFORM c_ok((SELECT count(*) FROM sales.invoice WHERE gl_batch_id = '30a00000-0000-7000-8000-0000000fb001') = 1
               AND (SELECT status FROM sales.gl_batch WHERE id = '30a00000-0000-7000-8000-0000000fb001') = 'posted',
               'T94 the posted batch holds exactly the invoices its journal covers');
END $$;

\echo 'ALL 30_commerce TESTS PASSED'
