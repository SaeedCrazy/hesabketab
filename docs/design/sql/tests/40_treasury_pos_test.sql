-- =====================================================================
-- آزمون پایگاه داده‌ای 40_treasury_pos.sql (سند: docs/design/06-treasury-pos.md §۷ و §۹)
--
-- اجرا (از ریشهٔ مخزن؛ پایگاه دادهٔ تازه با UTF8):
--   export PGPASSWORD=postgres
--   psql -h localhost -p 5433 -U postgres -d postgres -c "DROP DATABASE IF EXISTS ds_treasury_pos"
--   psql -h localhost -p 5433 -U postgres -d postgres -c "CREATE DATABASE ds_treasury_pos ENCODING 'UTF8' TEMPLATE template0 LC_COLLATE 'C' LC_CTYPE 'C.UTF-8'"
--   for f in 00_foundation 10_core 20_ledger 25_masterdata 40_treasury_pos; do
--     psql -h localhost -p 5433 -U postgres -d ds_treasury_pos -v ON_ERROR_STOP=1 -f docs/design/sql/$f.sql; done
--   psql -h localhost -p 5433 -U postgres -d ds_treasury_pos -v ON_ERROR_STOP=1 -f docs/design/sql/tests/40_treasury_pos_test.sql
--
-- ساختار (یک نشست psql که با superuser وصل می‌شود):
--   بخش ۱ (fixture، نقش postgres): مستأجر A (شرکت CA، شعبه‌های BA و BA2) و B (CB، BB)، کاربران و عضویت‌ها،
--         دستگاه‌ها، سری‌های شماره، اشخاص (مشتری، تأمین‌کننده، مشتری عمومی، کارمند، بازنده ادغام)، کالا و
--         توابع کمکی آزمون (tp_expect، tp_assert، tp_ctx، tp_make_year، tp_jr، tp_dim، tp_cmd، ...).
--   بخش ۲ (assert، «SET ROLE hk_app»؛ نه مالک، NOBYPASSRLS): T00..T19 همهٔ ناوردایی‌های پایگاه داده‌ای؛ هر DO block
--         یک تراکنش است و مستأجر را با set_config('app.tenant_id', ..., true) تنظیم می‌کند. موارد منفیِ deferred
--         درون زیرتراکنش tp_expect با «SET CONSTRAINTS ALL IMMEDIATE» آزموده می‌شوند (بی‌اثر پس از بازگشت).
--   بخش ۳: T20 جداسازی مستأجر (RLS و FK ترکیبی)، T21 hk_readonly (بدون ستون راز)، T22 زیردفتر چک = دفتر کل.
-- خروجی موفق با «ALL 40_treasury_pos TESTS PASSED» پایان می‌یابد؛ هر شکست «TEST FAILED: ...» است و psql با کد ≠ ۰ خارج می‌شود.
-- =====================================================================
\set ON_ERROR_STOP 1
\set QUIET 1

-- =====================================================================
-- بخش ۱: fixture (postgres)
-- =====================================================================
RESET ROLE;
BEGIN;
INSERT INTO core.tenant (id, slug, display_name) VALUES
  ('4a000000-0000-7000-8000-000000000001', 'tp-tenant-a', 'A'),
  ('4b000000-0000-7000-8000-000000000001', 'tp-tenant-b', 'B');
INSERT INTO core.company (tenant_id, id, code, name) VALUES
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-0000000000c1', 'C1', 'کافه الف'),
  ('4b000000-0000-7000-8000-000000000001', '4b000000-0000-7000-8000-0000000000c1', 'C1', 'شرکت ب'),
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-0000000000c2', 'C2', 'شرکت الف دو (زیردفتر)');
INSERT INTO core.branch (tenant_id, id, company_id, code, name) VALUES
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-0000000000b1', '4a000000-0000-7000-8000-0000000000c1', 'BR1', 'شعبه ۱'),
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-0000000000b2', '4a000000-0000-7000-8000-0000000000c1', 'BR2', 'شعبه ۲'),
  ('4b000000-0000-7000-8000-000000000001', '4b000000-0000-7000-8000-0000000000b1', '4b000000-0000-7000-8000-0000000000c1', 'BR1', 'شعبه ب');
INSERT INTO core.app_user (id, display_name) VALUES
  ('4a000000-0000-7000-8000-00000000a001', 'صندوقدار یک'),
  ('4a000000-0000-7000-8000-00000000a002', 'حسابدار دو'),
  ('4b000000-0000-7000-8000-00000000a001', 'کاربر ب');
INSERT INTO core.tenant_membership (tenant_id, user_id, status, is_owner, joined_at) VALUES
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-00000000a001', 'active', true,  now()),
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-00000000a002', 'active', false, now()),
  ('4b000000-0000-7000-8000-000000000001', '4b000000-0000-7000-8000-00000000a001', 'active', true,  now());
INSERT INTO core.device (tenant_id, id, company_id, branch_id, kind, name, key_alg, public_key, status, registered_by, activated_at) VALUES
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-0000000000d1', '4a000000-0000-7000-8000-0000000000c1',
   '4a000000-0000-7000-8000-0000000000b1', 'pos', 'صندوق ۱', 'ed25519', decode(repeat('11', 32), 'hex'), 'active',
   '4a000000-0000-7000-8000-00000000a001', now()),
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-0000000000d2', '4a000000-0000-7000-8000-0000000000c1',
   '4a000000-0000-7000-8000-0000000000b1', 'android', 'تبلت ۲', 'ed25519', decode(repeat('22', 32), 'hex'), 'active',
   '4a000000-0000-7000-8000-00000000a001', now()),
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-0000000000d3', '4a000000-0000-7000-8000-0000000000c1',
   '4a000000-0000-7000-8000-0000000000b2', 'pos', 'صندوق شعبه ۲', 'ed25519', decode(repeat('33', 32), 'hex'), 'active',
   '4a000000-0000-7000-8000-00000000a001', now()),
  ('4b000000-0000-7000-8000-000000000001', '4b000000-0000-7000-8000-0000000000d1', '4b000000-0000-7000-8000-0000000000c1',
   '4b000000-0000-7000-8000-0000000000b1', 'pos', 'صندوق ب', 'ed25519', decode(repeat('44', 32), 'hex'), 'active',
   '4b000000-0000-7000-8000-00000000a001', now());
INSERT INTO core.number_series (tenant_id, id, company_id, code, name, doc_type, scope, branch_id, device_id, allocation, pattern, reset_policy) VALUES
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-000000000501', '4a000000-0000-7000-8000-0000000000c1', 'pos.d1', 'رسید صندوق ۱',
   'pos.ticket', 'device', '4a000000-0000-7000-8000-0000000000b1', '4a000000-0000-7000-8000-0000000000d1', 'device', 'R1-{seq:6}', 'never'),
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-000000000502', '4a000000-0000-7000-8000-0000000000c1', 'trs.rcpt', 'سند دریافت',
   'treasury.receipt', 'company', NULL, NULL, 'server', 'RC-{seq}', 'never'),
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-000000000503', '4a000000-0000-7000-8000-0000000000c1', 'pos.d2', 'رسید تبلت ۲',
   'pos.ticket', 'device', '4a000000-0000-7000-8000-0000000000b1', '4a000000-0000-7000-8000-0000000000d2', 'device', 'R2-{seq:6}', 'never'),
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-000000000504', '4a000000-0000-7000-8000-0000000000c1', 'trs.pay', 'سند پرداخت',
   'treasury.payment', 'company', NULL, NULL, 'server', 'PY-{seq}', 'never'),
  ('4b000000-0000-7000-8000-000000000001', '4b000000-0000-7000-8000-000000000501', '4b000000-0000-7000-8000-0000000000c1', 'pos.d1', 'رسید ب',
   'pos.ticket', 'device', '4b000000-0000-7000-8000-0000000000b1', '4b000000-0000-7000-8000-0000000000d1', 'device', 'B1-{seq:6}', 'never');
INSERT INTO parties.party (tenant_id, id, code, person_type, name, is_anonymous) VALUES
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-0000000000e1', 'C001', 'natural', 'مشتری یک', false),
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-0000000000e2', 'S001', 'legal',   'تأمین‌کننده قهوه', false),
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-0000000000e3', 'WALKIN', 'natural', 'مشتری عمومی', true),
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-0000000000e4', 'E001', 'natural', 'کارمند تنخواه‌دار', false),
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-0000000000e5', 'C002', 'natural', 'مشتری تکراری', false),
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-0000000000e6', 'C003', 'natural', 'مشتری سه', false),
  ('4b000000-0000-7000-8000-000000000001', '4b000000-0000-7000-8000-0000000000e1', 'C001', 'natural', 'مشتری ب', false),
  ('4b000000-0000-7000-8000-000000000001', '4b000000-0000-7000-8000-0000000000e3', 'WALKIN', 'natural', 'مشتری عمومی ب', true);
INSERT INTO catalog.uom (tenant_id, id, code, name, dimension) VALUES
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-0000000000f1', 'PCS', 'عدد', 'count');
INSERT INTO catalog.item (tenant_id, id, code, name, item_type, base_uom_id) VALUES
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-0000000000f2', 'ESP', 'اسپرسو', 'non_stock', '4a000000-0000-7000-8000-0000000000f1'),
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-0000000000f4', 'SHOT', 'شات اضافه', 'non_stock', '4a000000-0000-7000-8000-0000000000f1');
INSERT INTO catalog.item_variant (tenant_id, id, item_id, code, is_default) VALUES
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-0000000000f3', '4a000000-0000-7000-8000-0000000000f2', 'ESP', true),
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-0000000000f5', '4a000000-0000-7000-8000-0000000000f4', 'SHOT', true);
INSERT INTO catalog.item_uom (tenant_id, item_id, uom_id, factor, is_base) VALUES
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-0000000000f2', '4a000000-0000-7000-8000-0000000000f1', 1, true),
  ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-0000000000f4', '4a000000-0000-7000-8000-0000000000f1', 1, true);

-- ---------- کمکی‌های آزمون (SECURITY INVOKER) ----------
CREATE OR REPLACE FUNCTION public.tp_assert(p_cond boolean, p_label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond IS NOT TRUE THEN RAISE EXCEPTION 'TEST FAILED: %', p_label; END IF;
END $$;

-- SQL را در زیرتراکنش اجرا می‌کند؛ تریگرهای deferred همان‌جا اجرا می‌شوند؛ خطا باید با الگو بخواند.
-- در هر دو حالت زیرتراکنش برمی‌گردد و حالت قیدها دوباره DEFERRED می‌شود.
CREATE OR REPLACE FUNCTION public.tp_expect(p_sql text, p_pattern text, p_label text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_ok boolean := false; v_err text;
BEGIN
  BEGIN
    EXECUTE p_sql;
    SET CONSTRAINTS ALL IMMEDIATE;
    v_ok := true;
    RAISE EXCEPTION 'tp_rollback';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;
  SET CONSTRAINTS ALL DEFERRED;
  IF v_ok THEN
    RAISE EXCEPTION 'TEST FAILED: % — statement succeeded but must fail', p_label;
  END IF;
  IF v_err !~ p_pattern THEN
    RAISE EXCEPTION 'TEST FAILED: % — expected /%/, got: %', p_label, p_pattern, v_err;
  END IF;
END $$;

-- همان، ولی باید موفق شود (و برمی‌گردد): برای «حالت مثبت» بدون اثر جانبی
CREATE OR REPLACE FUNCTION public.tp_ok(p_sql text, p_label text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_err text := NULL;
BEGIN
  BEGIN
    EXECUTE p_sql;
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'tp_rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'tp_rollback' THEN v_err := SQLERRM; END IF;
  END;
  SET CONSTRAINTS ALL DEFERRED;
  IF v_err IS NOT NULL THEN RAISE EXCEPTION 'TEST FAILED: % — %', p_label, v_err; END IF;
END $$;

CREATE OR REPLACE FUNCTION public.tp_ctx(p_tenant text) RETURNS void
LANGUAGE sql AS $$
  SELECT set_config('app.tenant_id', CASE p_tenant WHEN 'A' THEN '4a000000-0000-7000-8000-000000000001'
                                                    WHEN 'B' THEN '4b000000-0000-7000-8000-000000000001' ELSE '' END, true),
         set_config('app.user_id', CASE p_tenant WHEN 'B' THEN '4b000000-0000-7000-8000-00000000a001'
                                                 ELSE '4a000000-0000-7000-8000-00000000a001' END, true);
$$;

CREATE OR REPLACE FUNCTION public.tp_acc(p_company uuid, p_code text) RETURNS uuid
LANGUAGE sql STABLE AS $$ SELECT id FROM ledger.account WHERE company_id = p_company AND code = p_code $$;

-- سال مالی ۳۶۵ روزه با ۱۲ دوره (۶×۳۱، ۵×۳۰، ۲۹)
CREATE OR REPLACE FUNCTION public.tp_make_year(p_company uuid, p_code text, p_start date) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid := uuidv7(); lens int[] := ARRAY[31,31,31,31,31,31,30,30,30,30,30,29]; d date := p_start; i int;
BEGIN
  INSERT INTO ledger.fiscal_year (tenant_id, id, company_id, code, name, start_date, end_date, base_currency)
  VALUES (core.current_tenant_id(), v_id, p_company, p_code, 'سال ' || p_code, p_start, p_start + 364, 'IRR');
  FOR i IN 1..12 LOOP
    INSERT INTO ledger.fiscal_period (tenant_id, company_id, fiscal_year_id, period_no, name, start_date, end_date)
    VALUES (core.current_tenant_id(), p_company, v_id, i, 'ماه ' || i, d, d + lens[i] - 1);
    d := d + lens[i];
  END LOOP;
  RETURN v_id;
END $$;

-- سند خزانهٔ آزمایشی (در تولید: LedgerPostingService.post). سطرها: [{"a":کد,"dr":..,"cr":..,"d1":uuid}]؛ پیش‌فرض ۵۱۰۱/۵۲۰۱
CREATE OR REPLACE FUNCTION public.tp_jr(p_company uuid, p_date date, p_lines jsonb DEFAULT NULL, p_source text DEFAULT 'treasury')
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid := uuidv7(); v_fy uuid; v_ref bigint; v_lines jsonb; v_tot numeric; v_memo numeric;
BEGIN
  v_lines := coalesce(p_lines, '[{"a":"5101","dr":1},{"a":"5201","cr":1}]'::jsonb);
  SELECT f.id INTO v_fy FROM ledger.fiscal_year f WHERE f.company_id = p_company AND p_date BETWEEN f.start_date AND f.end_date;
  SELECT coalesce(max(reference_no), 0) + 1 INTO v_ref FROM ledger.journal WHERE company_id = p_company AND fiscal_year_id = v_fy;
  SELECT coalesce(sum((l->>'dr')::numeric), 0),
         coalesce(sum((l->>'dr')::numeric) FILTER (WHERE a.account_type = 'memo'), 0)
    INTO v_tot, v_memo
    FROM jsonb_array_elements(v_lines) l JOIN ledger.account a ON a.company_id = p_company AND a.code = l->>'a';
  INSERT INTO ledger.journal (tenant_id, id, company_id, fiscal_year_id, journal_date, journal_type, status, reference_no, reference_text,
                              source_module, source_doc_type, source_doc_id, source_event, base_currency, line_count,
                              total_debit_base, total_credit_base, memo_debit_base, memo_credit_base, description)
  VALUES (core.current_tenant_id(), v_id, p_company, v_fy, p_date, 'module', 'temporary', v_ref, 'T-' || v_ref,
          p_source, p_source || '.test', v_id, 'post', 'IRR', jsonb_array_length(v_lines), v_tot, v_tot, v_memo, v_memo, 'آزمون');
  INSERT INTO ledger.journal_line (tenant_id, journal_id, line_no, account_id, dim1_id, currency, exchange_rate,
                                   debit_txn, credit_txn, debit_base, credit_base)
  SELECT core.current_tenant_id(), v_id, o.ord::int, a.id, (o.l->>'d1')::uuid, 'IRR', 1,
         coalesce((o.l->>'dr')::numeric, 0), coalesce((o.l->>'cr')::numeric, 0),
         coalesce((o.l->>'dr')::numeric, 0), coalesce((o.l->>'cr')::numeric, 0)
    FROM jsonb_array_elements(v_lines) WITH ORDINALITY o(l, ord)
    JOIN ledger.account a ON a.company_id = p_company AND a.code = o.l->>'a';
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.tp_pdim(p_party uuid) RETURNS uuid
LANGUAGE sql STABLE AS $$ SELECT id FROM ledger.dimension_value WHERE source_module = 'parties' AND source_entity_id = p_party $$;

CREATE OR REPLACE FUNCTION public.tp_jl(p_journal uuid, p_line int) RETURNS uuid
LANGUAGE sql STABLE AS $$ SELECT id FROM ledger.journal_line WHERE journal_id = p_journal AND line_no = p_line $$;

-- مقدار بُعد دفتر کل برای یک موجودیت
CREATE OR REPLACE FUNCTION public.tp_dim(p_type text, p_module text, p_entity uuid, p_code text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_type ledger.dimension_type; v_id uuid := uuidv7();
BEGIN
  SELECT * INTO v_type FROM ledger.dimension_type WHERE code = p_type;
  INSERT INTO ledger.dimension_value (tenant_id, id, dimension_type_id, slot, code, name, source_module, source_entity_id)
  VALUES (core.current_tenant_id(), v_id, v_type.id, v_type.slot, p_code, p_code, p_module, p_entity);
  RETURN v_id;
END $$;

-- ثبت چک دریافتی با رویداد ایجاد (R1) و سند آزمایشی؛ محل نگهداری: اسناد دریافتنی ۱۲۰۲ با بُعد شخص (اگر داده شود)
CREATE OR REPLACE FUNCTION public.tp_recv_cheque(p_sayad text, p_amount numeric, p_party uuid, p_journal uuid,
                                                 p_party_dim uuid DEFAULT NULL, p_date date DEFAULT DATE '2026-04-10')
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid := uuidv7(); CA uuid := '4a000000-0000-7000-8000-0000000000c1';
BEGIN
  INSERT INTO treasury.cheque (tenant_id, id, company_id, direction, purpose, state, medium, sayad_id, amount, amount_base,
                               issue_date, due_date, drawer_name, received_from_party_id, sayad_state, origin)
  VALUES (core.current_tenant_id(), v_id, CA, 'received', 'payment', 'in_hand', 'paper', p_sayad, p_amount, p_amount,
          p_date, p_date + 30, 'صادرکننده', p_party, 'not_inquired', 'receipt');
  INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date,
                                     collected_after, long_term_after, holding_account_id, holding_dim_value_id,
                                     holding_amount, holding_amount_base, journal_id)
  VALUES (core.current_tenant_id(), v_id, 1, 'transition', 'R1', NULL, 'in_hand', p_date, 0, false,
          public.tp_acc(CA, '1202'), p_party_dim, p_amount, p_amount, p_journal);
  RETURN v_id;
END $$;

-- فرمان دستگاه: بدنهٔ کانونی (v1) می‌سازد، prev_hash را از سر زنجیره می‌گیرد، hash = sha256(body)، امضای ساختگی ۶۴ بایتی
CREATE OR REPLACE FUNCTION public.tp_body(p_device uuid, p_seq bigint, p_cmd uuid, p_type text, p_at timestamptz, p_prev bytea, p_payload jsonb)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('v', 1, 'cmd_id', p_cmd, 'device_id', p_device, 'device_seq', p_seq, 'type', p_type,
                            'schema_version', 1, 'occurred_at', to_char(p_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
                            'prev_hash', encode(p_prev, 'hex'), 'payload', p_payload)::text
$$;
CREATE OR REPLACE FUNCTION public.tp_batch(p_device uuid, p_first bigint, p_count int) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid := uuidv7();
BEGIN
  INSERT INTO pos.sync_batch (tenant_id, id, device_id, client_batch_id, device_sent_at, clock_offset_ms, first_seq, last_seq, command_count)
  VALUES (core.current_tenant_id(), v_id, p_device, uuidv7(), now(), 150, p_first, p_first + p_count - 1, p_count);
  RETURN v_id;
END $$;
CREATE OR REPLACE FUNCTION public.tp_cmd(p_device uuid, p_type text, p_payload jsonb, p_batch uuid,
                                         p_at timestamptz DEFAULT now(), p_cmd uuid DEFAULT NULL, p_seq bigint DEFAULT NULL,
                                         p_prev bytea DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE s pos.device_sync_state; v_seq bigint; v_prev bytea; v_cmd uuid := coalesce(p_cmd, uuidv7()); v_body text; v_id uuid := uuidv7();
BEGIN
  SELECT * INTO s FROM pos.device_sync_state WHERE device_id = p_device;
  v_seq := coalesce(p_seq, s.last_seq + 1);
  v_prev := coalesce(p_prev, s.last_hash);
  v_body := public.tp_body(p_device, v_seq, v_cmd, p_type, p_at, v_prev, p_payload);
  INSERT INTO pos.device_command (tenant_id, id, device_id, device_seq, cmd_id, type, schema_version, occurred_at, body,
                                  prev_hash, hash, sig, sig_alg, batch_id, clock_offset_ms)
  VALUES (core.current_tenant_id(), v_id, p_device, v_seq, v_cmd, p_type, 1,
          (v_body::jsonb ->> 'occurred_at')::timestamptz, v_body, v_prev, sha256(convert_to(v_body, 'UTF8')),
          decode(repeat('ab', 64), 'hex'), 'ed25519', p_batch, 150);
  RETURN v_cmd;
END $$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO hk_app, hk_readonly;
COMMIT;

-- =====================================================================
-- بخش ۲: ادعاها با نقش برنامه
-- =====================================================================
SET ROLE hk_app;
SELECT public.tp_assert(current_user = 'hk_app', 'running as hk_app') \gset

-- ---------- T00: آماده‌سازی با نقش برنامه: کدینگ، سال، منابع وجه و ابعاد ----------
DO $$
DECLARE CA uuid := '4a000000-0000-7000-8000-0000000000c1'; BA uuid := '4a000000-0000-7000-8000-0000000000b1';
        v_bk uuid := '4a000000-0000-7000-8000-000000000101'; v_cb uuid := '4a000000-0000-7000-8000-000000000201';
        v_cb2 uuid := '4a000000-0000-7000-8000-000000000202'; v_ct uuid := '4a000000-0000-7000-8000-000000000301';
        v_pf uuid := '4a000000-0000-7000-8000-000000000401';
BEGIN
  PERFORM tp_ctx('A');
  PERFORM ledger.provision_tenant();
  PERFORM ledger.apply_coa_template(CA, 'ir.general', 1);
  PERFORM tp_make_year(CA, '1405', DATE '2026-03-21');
  INSERT INTO treasury.bank_account (tenant_id, id, company_id, code, name, bank_code, sheba, account_type, card_masks)
  VALUES (core.current_tenant_id(), v_bk, CA, 'BK1', 'ملت جاری', 'mellat', 'IR350120000000000001234567', 'current', '{603799******1234}');
  UPDATE treasury.bank_account SET dimension_value_id = tp_dim('bank_account', 'treasury', v_bk, 'BK1') WHERE id = v_bk;
  INSERT INTO treasury.cash_box (tenant_id, id, company_id, branch_id, code, name, kind)
  VALUES (core.current_tenant_id(), v_cb, CA, BA, 'POS1', 'کشوی صندوق ۱', 'pos_drawer'),
         (core.current_tenant_id(), v_cb2, CA, BA, 'MAIN', 'صندوق اصلی', 'main');
  UPDATE treasury.cash_box SET dimension_value_id = tp_dim('cash_box', 'treasury', id, code) WHERE id IN (v_cb, v_cb2);
  INSERT INTO treasury.card_terminal (tenant_id, id, company_id, branch_id, psp_code, terminal_no, name, settlement_bank_account_id)
  VALUES (core.current_tenant_id(), v_ct, CA, BA, 'sep', '00012345', 'کارتخوان سامان', v_bk);
  INSERT INTO treasury.petty_cash_fund (tenant_id, id, company_id, code, name, custodian_party_id, imprest_amount)
  VALUES (core.current_tenant_id(), v_pf, CA, 'PC1', 'تنخواه آشپزخانه', '4a000000-0000-7000-8000-0000000000e4', 50000000);
  PERFORM tp_dim('party', 'parties', '4a000000-0000-7000-8000-0000000000e1', 'C001');
  PERFORM tp_dim('party', 'parties', '4a000000-0000-7000-8000-0000000000e2', 'S001');
  PERFORM tp_assert((SELECT count(*) FROM treasury.bank_account) = 1, 'T00 bank account visible to hk_app');
END $$;

-- ---------- T01 (INV-CHQ-06/13): کاتالوگ گذارها — تراز ساختاری قالب‌ها، کلیدهای معتبر، ضمانت فقط انتظامی ----------
DO $$
DECLARE r record; v_bad int;
BEGIN
  PERFORM tp_ctx('A');
  -- برای هر گذار سنددار: چندمجموعهٔ amount طرف بدهکار = طرف بستانکار
  SELECT count(*) INTO v_bad FROM treasury.cheque_transition t
   WHERE t.requires_journal AND
     (SELECT array_agg(x->>'amount' ORDER BY x->>'amount') FROM jsonb_array_elements(t.journal_template) x WHERE x->>'side' = 'debit')
     IS DISTINCT FROM
     (SELECT array_agg(x->>'amount' ORDER BY x->>'amount') FROM jsonb_array_elements(t.journal_template) x WHERE x->>'side' = 'credit');
  PERFORM tp_assert(v_bad = 0, 'T01 INV-CHQ-13 every journal template balances by amount tokens');
  -- هر کلید یا نماد شناخته‌شده است یا در ledger.posting_key ثبت شده
  SELECT count(*) INTO v_bad FROM treasury.cheque_transition t, jsonb_array_elements(t.journal_template) x
   WHERE x->>'key' NOT IN ('@holding','@holding_payable','@counter','@bounce_target','@fund','@cost_target')
     AND NOT EXISTS (SELECT 1 FROM ledger.posting_key k WHERE k.key = x->>'key');
  PERFORM tp_assert(v_bad = 0, 'T01 INV-CHQ-13 template keys exist');
  -- چک ضمانت فقط با کلیدهای انتظامی
  SELECT count(*) INTO v_bad FROM treasury.cheque_transition t, jsonb_array_elements(t.journal_template) x
    LEFT JOIN ledger.posting_key k ON k.key = x->>'key'
   WHERE t.purpose = 'guarantee' AND (k.key IS NULL OR k.expected_account_types <> '{memo}');
  PERFORM tp_assert(v_bad = 0, 'T01 INV-CHQ-06 guarantee templates use memo keys only');
  SELECT count(*) INTO v_bad FROM treasury.cheque_transition t, jsonb_array_elements(t.journal_template) x
    JOIN ledger.posting_key k ON k.key = x->>'key'
   WHERE t.purpose = 'payment' AND 'memo' = ANY (k.expected_account_types);
  PERFORM tp_assert(v_bad = 0, 'T01 payment templates never touch memo keys');
  -- جدول پژوهش: R1..R14 (با R3' و R5') و P1..P4، P7 موجودند
  PERFORM tp_assert((SELECT count(*) FROM treasury.cheque_transition
                      WHERE code IN ('R1','R2','R3','R3B','R4','R5','R5B','R6','R7','R8','R9','R10','R11','R12','R13A','R14',
                                     'P1','P2','P3','P4','P7') AND is_research_row) = 21, 'T01 research rows present');
  PERFORM tp_assert((SELECT count(*) FROM treasury.cheque_state WHERE is_holding AND is_terminal) = 0, 'T01 holding states are not terminal');
  PERFORM tp_expect($q$INSERT INTO treasury.cheque_transition (code, direction, purpose, from_state, to_state, op, requires_journal, amount_rule, name_fa, research_ref, is_research_row)
                     VALUES ('ZX1','received','payment','collected','in_hand','zz', false,'none','x','x', false)$q$,
                    'permission denied', 'T01 catalog is read-only for hk_app');
END $$;

-- ---------- T02 (INV-TRS-01/02/03): اعتبار شبا و بانک، کارت فقط ماسک، بُعد منبع وجه ----------
DO $$
DECLARE CA uuid := '4a000000-0000-7000-8000-0000000000c1'; v_bk uuid := '4a000000-0000-7000-8000-000000000101';
BEGIN
  PERFORM tp_ctx('A');
  PERFORM tp_assert(treasury.is_masked_pan('603799******1234') AND treasury.is_masked_pan('6219****51234567') IS FALSE
                    AND NOT treasury.is_masked_pan('6037991234561234') AND NOT treasury.is_masked_pan(NULL), 'T02 masked pan function');
  PERFORM tp_expect(format($q$INSERT INTO treasury.bank_account (tenant_id, company_id, code, name, bank_code, sheba, account_type)
                     VALUES (core.current_tenant_id(), %L, 'BKX', 'x', 'mellat', 'IR820540102680020817909002', 'current')$q$, CA),
                    'HK_TRS_SHEBA_BANK_MISMATCH', 'T02 INV-TRS-01 SHEBA of Parsian on a Mellat account');
  PERFORM tp_expect(format($q$INSERT INTO treasury.bank_account (tenant_id, company_id, code, name, bank_code, sheba, account_type)
                     VALUES (core.current_tenant_id(), %L, 'BKX', 'x', 'mellat', 'IR350120000000000001234568', 'current')$q$, CA),
                    'bank_account_sheba_check|check constraint', 'T02 INV-TRS-01 invalid mod-97 SHEBA');
  PERFORM tp_ok(format($q$INSERT INTO treasury.bank_account (tenant_id, company_id, code, name, bank_code, sheba, account_type)
                VALUES (core.current_tenant_id(), %L, 'BKG', 'قوامین قدیم', 'sepah', 'IR120520000000000001111111', 'current')$q$, CA),
                'T02 INV-TRS-01 old Ghavamin SHEBA accepted on its merge successor (Sepah)');
  PERFORM tp_expect(format($q$INSERT INTO treasury.bank_account (tenant_id, company_id, code, name, bank_code, sheba, account_type)
                     VALUES (core.current_tenant_id(), %L, 'BKX', 'x', 'mellat', 'IR350120000000000001234567', 'current')$q$, CA),
                    'bank_account_sheba_uq', 'T02 one bank account per SHEBA');
  PERFORM tp_expect(format($q$UPDATE treasury.bank_account SET card_masks = '{6037991234561234}' WHERE id = %L$q$, v_bk),
                    'bank_account_card_masks_check', 'T02 INV-TRS-02 full card number rejected');
  PERFORM tp_expect(format($q$INSERT INTO treasury.bank_account (tenant_id, company_id, code, name, bank_code, account_type, currency)
                     VALUES (core.current_tenant_id(), %L, 'BKX', 'x', 'mellat', 'current', 'USD')$q$, CA),
                    'bank_account_identifier|bank_account_fx', 'T02 account needs identifier and fx type');
  -- بُعد: نوع اشتباه و موجودیت دیگر
  PERFORM tp_expect(format($q$UPDATE treasury.bank_account SET dimension_value_id =
                       (SELECT dimension_value_id FROM treasury.cash_box WHERE code = 'MAIN') WHERE id = %L$q$, v_bk),
                    'HK_TRS_FUND_DIMENSION', 'T02 INV-TRS-03 bank account with a cash-box dimension');
  PERFORM tp_expect(format($q$UPDATE treasury.cash_box SET dimension_value_id =
                       (SELECT dimension_value_id FROM treasury.cash_box WHERE code = 'MAIN') WHERE code = 'POS1'$q$),
                    'HK_TRS_FUND_DIMENSION', 'T02 INV-TRS-03 cash box with another cash box dimension');
  PERFORM tp_expect(format($q$UPDATE treasury.bank_account SET currency = 'USD', account_type = 'foreign_currency' WHERE id = %L$q$, v_bk),
                    'HK_TRS_IMMUTABLE_FIELD', 'T02 bank account currency immutable');
  PERFORM tp_expect(format($q$INSERT INTO treasury.card_terminal (tenant_id, company_id, psp_code, terminal_no, name, settlement_bank_account_id)
                     VALUES (core.current_tenant_id(), %L, 'sep', '00012345', 'تکراری', %L)$q$, CA, v_bk),
                    'card_terminal_tenant_id_psp_code_terminal_no_key', 'T02 INV-CRD-03 terminal unique per PSP');
END $$;

-- ---------- T03 (INV-TRS-04/05/10): سند دریافت/پرداخت ----------
DO $$
DECLARE CA uuid := '4a000000-0000-7000-8000-0000000000c1'; v_doc uuid := uuidv7(); v_doc2 uuid := uuidv7(); v_j uuid; v_j2 uuid;
        v_cb uuid := '4a000000-0000-7000-8000-000000000201'; PC uuid := '4a000000-0000-7000-8000-0000000000e1'; v_num uuid;
BEGIN
  PERFORM tp_ctx('A');
  INSERT INTO treasury.money_document (tenant_id, id, company_id, direction, doc_date, party_id, total_amount)
  VALUES (core.current_tenant_id(), v_doc, CA, 'receipt', DATE '2026-04-05', PC, 1500000);
  INSERT INTO treasury.money_instrument (tenant_id, document_id, line_no, kind, amount, cash_box_id)
  VALUES (core.current_tenant_id(), v_doc, 1, 'cash', 1000000, v_cb);
  INSERT INTO treasury.money_instrument (tenant_id, document_id, line_no, kind, amount, card_terminal_id, rrn, stan, masked_pan)
  VALUES (core.current_tenant_id(), v_doc, 2, 'card_pos', 500000, '4a000000-0000-7000-8000-000000000301', '000123456789', '004321', '603799******1234');
  INSERT INTO treasury.money_counter_line (tenant_id, document_id, line_no, kind, party_id, party_role, amount)
  VALUES (core.current_tenant_id(), v_doc, 1, 'party', PC, 'customer', 1500000);
  PERFORM tp_assert((SELECT rrn FROM treasury.money_instrument WHERE document_id = v_doc AND line_no = 2) = '000123456789',
                    'T03 INV-CRD-01 RRN keeps leading zeros (text)');
  -- شکل ابزار
  PERFORM tp_expect(format($q$INSERT INTO treasury.money_instrument (tenant_id, document_id, line_no, kind, amount)
                     VALUES (core.current_tenant_id(), %L, 3, 'cash', 1)$q$, v_doc), 'instrument_shape', 'T03 INV-TRS-05 cash needs a cash box');
  PERFORM tp_expect(format($q$INSERT INTO treasury.money_instrument (tenant_id, document_id, line_no, kind, amount, cash_box_id, rrn)
                     VALUES (core.current_tenant_id(), %L, 3, 'cash', 1, %L, '12')$q$, v_doc, v_cb), 'instrument_card_refs', 'T03 INV-TRS-05 rrn only on card instruments');
  PERFORM tp_expect(format($q$INSERT INTO treasury.money_instrument (tenant_id, document_id, line_no, kind, amount, petty_cash_fund_id)
                     VALUES (core.current_tenant_id(), %L, 3, 'petty_cash', 1, '4a000000-0000-7000-8000-000000000401')$q$, v_doc),
                    'HK_TRS_INSTRUMENT_DIRECTION', 'T03 INV-TRS-05 petty cash is not a receipt instrument');
  PERFORM tp_expect(format($q$INSERT INTO treasury.money_instrument (tenant_id, document_id, line_no, kind, amount, bank_account_id, transfer_method)
                     VALUES (core.current_tenant_id(), %L, 3, 'card_to_card', 1, '4a000000-0000-7000-8000-000000000101', 'paya')$q$, v_doc),
                    'instrument_transfer_method', 'T03 card_to_card method');
  PERFORM tp_expect(format($q$INSERT INTO treasury.money_counter_line (tenant_id, document_id, line_no, kind, amount)
                     VALUES (core.current_tenant_id(), %L, 2, 'party', 1)$q$, v_doc), 'counter_line_shape', 'T03 party line needs party and role');
  -- ثبت با جمع نابرابر → خطا در commit
  v_j := tp_jr(CA, DATE '2026-04-05');
  SELECT number_id INTO v_num FROM core.number_next('4a000000-0000-7000-8000-000000000502', 'all', 'RC-{seq}', 'treasury.receipt', v_doc);
  PERFORM tp_expect(format($q$UPDATE treasury.money_document SET status = 'posted', journal_id = %L, number_issued_id = %L, doc_no = 'RC-1',
                     posted_at = now(), total_amount = 1600000 WHERE id = %L$q$, v_j, v_num, v_doc),
                    'HK_TRS_DOC_UNBALANCED', 'T03 INV-TRS-04 posted document must balance');
  UPDATE treasury.money_document SET status = 'posted', journal_id = v_j, number_issued_id = v_num, doc_no = 'RC-1', posted_at = now()
   WHERE id = v_doc;
  PERFORM tp_expect(format($q$UPDATE treasury.money_document SET description = 'x' WHERE id = %L$q$, v_doc),
                    'HK_TRS_DOC_IMMUTABLE', 'T03 INV-TRS-04 posted document immutable');
  PERFORM tp_expect(format($q$INSERT INTO treasury.money_instrument (tenant_id, document_id, line_no, kind, amount, cash_box_id)
                     VALUES (core.current_tenant_id(), %L, 9, 'cash', 1, %L)$q$, v_doc, v_cb),
                    'HK_TRS_DOC_IMMUTABLE', 'T03 INV-TRS-04 no lines after posting');
  PERFORM tp_expect(format($q$DELETE FROM treasury.money_document WHERE id = %L$q$, v_doc), 'HK_TRS_DOC_IMMUTABLE', 'T03 posted document not deletable');
  PERFORM tp_expect(format($q$UPDATE treasury.money_document SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'اشتباه ثبت' WHERE id = %L$q$, v_doc),
                    'money_doc_cancel_cols', 'T03 cancel needs a reversal journal');
  PERFORM tp_expect(format($q$UPDATE treasury.money_document SET status = 'draft' WHERE id = %L$q$, v_doc), 'HK_TRS_DOC_IMMUTABLE', 'T03 no way back to draft');
  v_j2 := tp_jr(CA, DATE '2026-04-06');
  PERFORM tp_ok(format($q$UPDATE treasury.money_document SET status = 'cancelled', cancel_journal_id = %L, cancelled_at = now(),
                 cancel_reason = 'ثبت اشتباه' WHERE id = %L$q$, v_j2, v_doc), 'T03 cancel with reversal journal');
  -- پیش‌نویس قابل حذف؛ سند API بدون واحد مبلغ رد می‌شود؛ یکتایی مبدأ خودکار
  INSERT INTO treasury.money_document (tenant_id, id, company_id, direction, doc_date, total_amount)
  VALUES (core.current_tenant_id(), v_doc2, CA, 'payment', DATE '2026-04-05', 10);
  INSERT INTO treasury.money_instrument (tenant_id, document_id, line_no, kind, amount, cash_box_id)
  VALUES (core.current_tenant_id(), v_doc2, 1, 'cash', 10, v_cb);
  DELETE FROM treasury.money_document WHERE id = v_doc2;
  PERFORM tp_assert(NOT EXISTS (SELECT 1 FROM treasury.money_instrument WHERE document_id = v_doc2), 'T03 draft delete cascades lines');
  PERFORM tp_expect(format($q$INSERT INTO treasury.money_document (tenant_id, company_id, direction, doc_date, total_amount, origin)
                     VALUES (core.current_tenant_id(), %L, 'receipt', DATE '2026-04-05', 10, 'api')$q$, CA),
                    'money_doc_input_unit', 'T03 API document declares its amount unit');
  PERFORM tp_expect(format($q$INSERT INTO treasury.money_document (tenant_id, company_id, direction, doc_date, total_amount, origin, origin_ref)
                     VALUES (core.current_tenant_id(), %1$L, 'receipt', DATE '2026-04-05', 10, 'pos', '4a000000-0000-7000-8000-00000000ffff'),
                            (core.current_tenant_id(), %1$L, 'receipt', DATE '2026-04-05', 10, 'pos', '4a000000-0000-7000-8000-00000000ffff')$q$, CA),
                    'money_document_origin_uq', 'T03 INV-TRS-11 one live document per automatic origin');
  PERFORM tp_expect(format($q$INSERT INTO treasury.money_document (tenant_id, company_id, direction, doc_date, total_amount, origin)
                     VALUES (core.current_tenant_id(), %L, 'receipt', DATE '2026-04-05', 10, 'pos')$q$, CA),
                    'money_doc_origin_ref', 'T03 automatic origin needs its source reference');
END $$;

-- ---------- T04 (INV-TRS-06/07): اقلام باز و تسویه ----------
DO $$
DECLARE CA uuid := '4a000000-0000-7000-8000-0000000000c1'; PC uuid := '4a000000-0000-7000-8000-0000000000e1';
        PS uuid := '4a000000-0000-7000-8000-0000000000e2'; P3 uuid := '4a000000-0000-7000-8000-0000000000e6';
        v_inv uuid := uuidv7(); v_rcp uuid := uuidv7(); v_inv2 uuid := uuidv7(); v_sup uuid := uuidv7(); v_other uuid := uuidv7();
        v_usd uuid := uuidv7(); v_alloc uuid := uuidv7();
BEGIN
  PERFORM tp_ctx('A');
  INSERT INTO treasury.open_item (tenant_id, id, company_id, party_id, party_role, account_class, direction, source_module, source_doc_type,
                                  source_doc_id, doc_date, due_date, currency, amount, amount_base) VALUES
    (core.current_tenant_id(), v_inv,  CA, PC, 'customer', 'receivable', 'debit',  'sales', 'sales.invoice', uuidv7(), DATE '2026-04-01', DATE '2026-04-30', 'IRR', 1000, 1000),
    (core.current_tenant_id(), v_inv2, CA, PC, 'customer', 'receivable', 'debit',  'sales', 'sales.invoice', uuidv7(), DATE '2026-04-02', DATE '2026-04-30', 'IRR', 300, 300),
    (core.current_tenant_id(), v_rcp,  CA, PC, 'customer', 'receivable', 'credit', 'treasury', 'treasury.receipt', uuidv7(), DATE '2026-04-03', DATE '2026-04-03', 'IRR', 600, 600),
    (core.current_tenant_id(), v_sup,  CA, PC, 'supplier', 'payable',    'credit', 'purchase', 'purchase.invoice', uuidv7(), DATE '2026-04-03', DATE '2026-05-03', 'IRR', 200, 200),
    (core.current_tenant_id(), v_other,CA, P3, 'customer', 'receivable', 'credit', 'treasury', 'treasury.receipt', uuidv7(), DATE '2026-04-03', DATE '2026-04-03', 'IRR', 50, 50),
    (core.current_tenant_id(), v_usd,  CA, PC, 'customer', 'receivable', 'credit', 'treasury', 'treasury.receipt', uuidv7(), DATE '2026-04-03', DATE '2026-04-03', 'USD', 5, 500);
  INSERT INTO treasury.allocation (tenant_id, id, company_id, debit_item_id, credit_item_id, amount, currency, allocation_date)
  VALUES (core.current_tenant_id(), v_alloc, CA, v_inv, v_rcp, 600, 'IRR', DATE '2026-04-03');
  PERFORM tp_assert((SELECT allocated_amount FROM treasury.open_item WHERE id = v_inv) = 600
                    AND (SELECT status FROM treasury.open_item WHERE id = v_rcp) = 'closed'
                    AND (SELECT status FROM treasury.open_item WHERE id = v_inv) = 'open', 'T04 INV-TRS-06 allocation updates both items');
  PERFORM tp_assert((SELECT outstanding FROM treasury.v_open_item WHERE id = v_inv) = 400, 'T04 outstanding view');
  PERFORM tp_expect(format($q$INSERT INTO treasury.allocation (tenant_id, company_id, debit_item_id, credit_item_id, amount, currency, allocation_date)
                     VALUES (core.current_tenant_id(), %L, %L, %L, 1, 'IRR', DATE '2026-04-03')$q$, CA, v_inv, v_rcp),
                    'HK_TRS_ALLOC_ITEM_STATE', 'T04 closed item cannot take more');
  PERFORM tp_expect(format($q$INSERT INTO treasury.allocation (tenant_id, company_id, debit_item_id, credit_item_id, amount, currency, allocation_date)
                     VALUES (core.current_tenant_id(), %L, %L, %L, 1, 'IRR', DATE '2026-04-03')$q$, CA, v_rcp, v_inv),
                    'HK_TRS_ALLOC_DIRECTION', 'T04 debit/credit roles');
  PERFORM tp_expect(format($q$INSERT INTO treasury.allocation (tenant_id, company_id, debit_item_id, credit_item_id, amount, currency, allocation_date)
                     VALUES (core.current_tenant_id(), %L, %L, %L, 10, 'IRR', DATE '2026-04-03')$q$, CA, v_inv2, v_other),
                    'HK_TRS_ALLOC_PARTY', 'T04 different parties');
  PERFORM tp_expect(format($q$INSERT INTO treasury.allocation (tenant_id, company_id, debit_item_id, credit_item_id, amount, currency, allocation_date)
                     VALUES (core.current_tenant_id(), %L, %L, %L, 1, 'USD', DATE '2026-04-03')$q$, CA, v_inv2, v_usd),
                    'HK_TRS_ALLOC_CURRENCY', 'T04 currency must match');
  PERFORM tp_expect(format($q$INSERT INTO treasury.allocation (tenant_id, company_id, debit_item_id, credit_item_id, amount, currency, allocation_date)
                     VALUES (core.current_tenant_id(), %L, %L, %L, 100, 'IRR', DATE '2026-04-03')$q$, CA, v_inv2, v_sup),
                    'HK_TRS_ALLOC_CLASS', 'T04 receivable vs payable needs an offset');
  PERFORM tp_expect(format($q$INSERT INTO treasury.allocation (tenant_id, company_id, debit_item_id, credit_item_id, amount, currency, allocation_date, kind)
                     VALUES (core.current_tenant_id(), %L, %L, %L, 100, 'IRR', DATE '2026-04-03', 'offset')$q$, CA, v_inv2, v_sup),
                    'allocation_offset_journal', 'T04 offset needs its journal');
  PERFORM tp_expect(format($q$INSERT INTO treasury.allocation (tenant_id, company_id, debit_item_id, credit_item_id, amount, currency, allocation_date)
                     VALUES (core.current_tenant_id(), %L, %L, %L, 301, 'IRR', DATE '2026-04-03')$q$, CA, v_inv2, v_sup),
                    'HK_TRS_ALLOC_CLASS|HK_TRS_ALLOC_EXCEEDS', 'T04 exceeds');
  PERFORM tp_expect(format($q$UPDATE treasury.open_item SET allocated_amount = 0, status = 'open' WHERE id = %L$q$, v_inv),
                    'HK_TRS_ALLOC_DRIFT', 'T04 INV-TRS-06 allocated_amount equals active allocations');
  PERFORM tp_expect(format($q$UPDATE treasury.open_item SET amount = 5000 WHERE id = %L$q$, v_inv), 'HK_TRS_IMMUTABLE_FIELD', 'T04 INV-TRS-07 amount immutable');
  PERFORM tp_expect(format($q$UPDATE treasury.open_item SET status = 'cancelled', cancelled_at = now() WHERE id = %L$q$, v_inv),
                    'HK_TRS_OPEN_ITEM_ALLOCATED', 'T04 INV-TRS-07 allocated item cannot be cancelled');
  PERFORM tp_expect(format($q$INSERT INTO treasury.open_item (tenant_id, company_id, party_id, party_role, account_class, direction, source_module, source_doc_type,
                     source_doc_id, doc_date, due_date, currency, amount, amount_base)
                     SELECT tenant_id, company_id, party_id, party_role, account_class, direction, source_module, source_doc_type,
                            source_doc_id, doc_date, due_date, currency, amount, amount_base FROM treasury.open_item WHERE id = %L$q$, v_inv),
                    'open_item_source_uq', 'T04 INV-TRS-07 one live open item per source line');
  PERFORM tp_expect(format($q$UPDATE treasury.allocation SET amount = 1 WHERE id = %L$q$, v_alloc), 'HK_TRS_ALLOC_IMMUTABLE', 'T04 allocation immutable');
  PERFORM tp_expect(format($q$DELETE FROM treasury.allocation WHERE id = %L$q$, v_alloc), 'permission denied|HK_IMMUTABLE', 'T04 allocation not deletable (grant + trigger)');
  PERFORM tp_expect(format($q$UPDATE treasury.allocation SET status = 'reversed', reversed_at = now() WHERE id = %L$q$, v_alloc),
                    'allocation_reversed', 'T04 reversal needs a reason');
  UPDATE treasury.allocation SET status = 'reversed', reversed_at = now(), reverse_reason = 'تخصیص اشتباه' WHERE id = v_alloc;
  PERFORM tp_assert((SELECT allocated_amount FROM treasury.open_item WHERE id = v_inv) = 0
                    AND (SELECT status FROM treasury.open_item WHERE id = v_rcp) = 'open', 'T04 reversal restores both items');
  PERFORM tp_expect(format($q$UPDATE treasury.allocation SET status = 'active', reversed_at = NULL, reverse_reason = NULL WHERE id = %L$q$, v_alloc),
                    'HK_TRS_ALLOC_IMMUTABLE', 'T04 reversal is final');
  UPDATE treasury.open_item SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'برگشت سند' WHERE id = v_inv2;
  PERFORM tp_expect(format($q$UPDATE treasury.open_item SET status = 'open' WHERE id = %L$q$, v_inv2), 'HK_TRS_OPEN_ITEM_CANCELLED', 'T04 cancelled is final');
END $$;

-- ---------- T04b (INV-TRS-08): شخص ادغام‌شده — قلم تازه ممنوع، تسویه با جانشین مجاز ----------
DO $$
DECLARE CA uuid := '4a000000-0000-7000-8000-0000000000c1'; PC uuid := '4a000000-0000-7000-8000-0000000000e1';
        PM uuid := '4a000000-0000-7000-8000-0000000000e5'; v_old uuid := uuidv7(); v_new uuid := uuidv7();
BEGIN
  PERFORM tp_ctx('A');
  INSERT INTO treasury.open_item (tenant_id, id, company_id, party_id, party_role, account_class, direction, source_module, source_doc_type,
                                  source_doc_id, doc_date, due_date, currency, amount, amount_base)
  VALUES (core.current_tenant_id(), v_old, CA, PM, 'customer', 'receivable', 'debit', 'sales', 'sales.invoice', uuidv7(),
          DATE '2026-04-01', DATE '2026-04-30', 'IRR', 700, 700);
  PERFORM parties.merge_parties(PC, PM, 'ادغام تکراری آزمون', '4a000000-0000-7000-8000-00000000a001');
  PERFORM tp_expect(format($q$INSERT INTO treasury.open_item (tenant_id, company_id, party_id, party_role, account_class, direction, source_module,
                     source_doc_type, source_doc_id, doc_date, due_date, currency, amount, amount_base)
                     VALUES (core.current_tenant_id(), %L, %L, 'customer', 'receivable', 'debit', 'sales', 'sales.invoice', uuidv7(),
                             DATE '2026-04-01', DATE '2026-04-30', 'IRR', 1, 1)$q$, CA, PM),
                    'HK_PARTY_MERGED', 'T04b INV-TRS-08 no new open item on a merged party');
  INSERT INTO treasury.open_item (tenant_id, id, company_id, party_id, party_role, account_class, direction, source_module, source_doc_type,
                                  source_doc_id, doc_date, due_date, currency, amount, amount_base)
  VALUES (core.current_tenant_id(), v_new, CA, PC, 'customer', 'receivable', 'credit', 'treasury', 'treasury.receipt', uuidv7(),
          DATE '2026-04-05', DATE '2026-04-05', 'IRR', 700, 700);
  INSERT INTO treasury.allocation (tenant_id, company_id, debit_item_id, credit_item_id, amount, currency, allocation_date)
  VALUES (core.current_tenant_id(), CA, v_old, v_new, 700, 'IRR', DATE '2026-04-05');
  PERFORM tp_assert((SELECT status FROM treasury.open_item WHERE id = v_old) = 'closed', 'T04b INV-TRS-08 loser item settled by winner receipt');
END $$;

-- ---------- T05 (INV-TRS-09): انتقال وجه ----------
DO $$
DECLARE CA uuid := '4a000000-0000-7000-8000-0000000000c1'; v_cb uuid := '4a000000-0000-7000-8000-000000000201';
        v_cb2 uuid := '4a000000-0000-7000-8000-000000000202'; v_bk uuid := '4a000000-0000-7000-8000-000000000101';
        v_t uuid := uuidv7(); v_j uuid; v_num uuid;
BEGIN
  PERFORM tp_ctx('A');
  PERFORM tp_expect(format($q$INSERT INTO treasury.fund_transfer (tenant_id, company_id, doc_date, amount, from_cash_box_id, to_cash_box_id)
                     VALUES (core.current_tenant_id(), %L, DATE '2026-04-05', 10, %L, %L)$q$, CA, v_cb, v_cb),
                    'fund_transfer_not_self', 'T05 INV-TRS-09 no self transfer');
  PERFORM tp_expect(format($q$INSERT INTO treasury.fund_transfer (tenant_id, company_id, doc_date, amount, from_cash_box_id, from_bank_account_id, to_cash_box_id)
                     VALUES (core.current_tenant_id(), %L, DATE '2026-04-05', 10, %L, %L, %L)$q$, CA, v_cb, v_bk, v_cb2),
                    'fund_transfer_one_source', 'T05 INV-TRS-09 exactly one source fund');
  PERFORM tp_expect(format($q$INSERT INTO treasury.fund_transfer (tenant_id, company_id, doc_date, amount, from_cash_box_id, to_bank_account_id, currency)
                     VALUES (core.current_tenant_id(), %L, DATE '2026-04-05', 10, %L, %L, 'USD')$q$, CA, v_cb, v_bk),
                    'HK_TRS_TRANSFER_CURRENCY', 'T05 INV-TRS-09 fund currency');
  PERFORM tp_expect(format($q$INSERT INTO treasury.fund_transfer (tenant_id, company_id, doc_date, amount, from_cash_box_id, to_bank_account_id, purpose)
                     VALUES (core.current_tenant_id(), %L, DATE '2026-04-05', 10, %L, %L, 'petty_replenish')$q$, CA, v_cb, v_bk),
                    'fund_transfer_petty', 'T05 petty replenishment targets a petty cash fund');
  INSERT INTO treasury.fund_transfer (tenant_id, id, company_id, doc_date, amount, from_cash_box_id, to_bank_account_id, purpose, via_in_transit)
  VALUES (core.current_tenant_id(), v_t, CA, DATE '2026-04-05', 5000000, v_cb2, v_bk, 'deposit_cash', true);
  v_j := tp_jr(CA, DATE '2026-04-05');
  SELECT number_id INTO v_num FROM core.number_next('4a000000-0000-7000-8000-000000000504', 'all', 'PY-{seq}', 'treasury.payment', v_t);
  PERFORM tp_expect(format($q$UPDATE treasury.fund_transfer SET status = 'posted', journal_id = %L, number_issued_id = %L WHERE id = %L$q$, v_j, v_num, v_t),
                    'fund_transfer_transit', 'T05 in-transit transfer completes only with its receive leg');
  UPDATE treasury.fund_transfer SET status = 'sent', journal_id = v_j, number_issued_id = v_num, doc_no = 'PY-1' WHERE id = v_t;
  PERFORM tp_expect(format($q$UPDATE treasury.fund_transfer SET amount = 1 WHERE id = %L$q$, v_t), 'HK_TRS_DOC_IMMUTABLE', 'T05 sent transfer immutable');
  PERFORM tp_expect(format($q$UPDATE treasury.fund_transfer SET status = 'draft' WHERE id = %L$q$, v_t), 'HK_TRS_DOC_TRANSITION', 'T05 no way back');
  UPDATE treasury.fund_transfer SET status = 'posted', receive_journal_id = tp_jr(CA, DATE '2026-04-06'), received_date = DATE '2026-04-06' WHERE id = v_t;
  PERFORM tp_expect(format($q$DELETE FROM treasury.fund_transfer WHERE id = %L$q$, v_t), 'HK_TRS_DOC_IMMUTABLE', 'T05 posted transfer not deletable');
END $$;

-- ---------- T06 (INV-TRS-12): شمارش نقد ----------
DO $$
DECLARE CA uuid := '4a000000-0000-7000-8000-0000000000c1'; v_cb2 uuid := '4a000000-0000-7000-8000-000000000202'; v_c uuid := uuidv7();
BEGIN
  PERFORM tp_ctx('A');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cash_count (tenant_id, company_id, cash_box_id, counted_at, business_date, expected_amount, counted_amount, denominations)
                     VALUES (core.current_tenant_id(), %L, %L, now(), DATE '2026-04-05', 3000000, 3000000, '[{"value":"1000000","qty":2}]')$q$, CA, v_cb2),
                    'HK_TRS_CASH_COUNT_TOTAL', 'T06 INV-TRS-12 denominations add up to the count');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cash_count (tenant_id, company_id, cash_box_id, counted_at, business_date, expected_amount, counted_amount, denominations)
                     VALUES (core.current_tenant_id(), %L, %L, now(), DATE '2026-04-05', 3000000, 3000000, '[{"value":1000000,"qty":3}]')$q$, CA, v_cb2),
                    'HK_TRS_CASH_COUNT_DENOMINATION', 'T06 denomination value is a decimal string');
  INSERT INTO treasury.cash_count (tenant_id, id, company_id, cash_box_id, counted_at, business_date, expected_amount, counted_amount, denominations)
  VALUES (core.current_tenant_id(), v_c, CA, v_cb2, now(), DATE '2026-04-05', 3000000, 2900000,
          '[{"value":"1000000","qty":2},{"value":"500000","qty":1},{"value":"100000","qty":4}]');
  PERFORM tp_assert((SELECT difference FROM treasury.cash_count WHERE id = v_c) = -100000, 'T06 difference is generated');
  PERFORM tp_expect(format($q$UPDATE treasury.cash_count SET status = 'posted' WHERE id = %L$q$, v_c), 'cash_count_posted', 'T06 INV-TRS-12 shortage needs a journal');
  UPDATE treasury.cash_count SET status = 'posted', journal_id = tp_jr(CA, DATE '2026-04-05') WHERE id = v_c;
  PERFORM tp_expect(format($q$UPDATE treasury.cash_count SET note = 'x' WHERE id = %L$q$, v_c), 'HK_TRS_DOC_IMMUTABLE', 'T06 posted count immutable');
END $$;

-- ---------- T07 (INV-TRS-13): تنخواه ----------
DO $$
DECLARE CA uuid := '4a000000-0000-7000-8000-0000000000c1'; v_pf uuid := '4a000000-0000-7000-8000-000000000401'; v_c uuid := uuidv7();
        U1 uuid := '4a000000-0000-7000-8000-00000000a001'; U2 uuid := '4a000000-0000-7000-8000-00000000a002'; v_num uuid;
BEGIN
  PERFORM tp_ctx('A');
  INSERT INTO treasury.petty_cash_claim (tenant_id, id, company_id, fund_id, claim_date, total_amount)
  VALUES (core.current_tenant_id(), v_c, CA, v_pf, DATE '2026-04-07', 350000);
  INSERT INTO treasury.petty_cash_claim_line (tenant_id, claim_id, line_no, expense_date, description, amount, posting_key) VALUES
    (core.current_tenant_id(), v_c, 1, DATE '2026-04-06', 'خرید شیر', 200000, 'purchase.expense'),
    (core.current_tenant_id(), v_c, 2, DATE '2026-04-06', 'کرایه پیک', 100000, 'purchase.expense');
  PERFORM tp_expect(format($q$UPDATE treasury.petty_cash_claim SET status = 'submitted', submitted_by = %L, submitted_at = now() WHERE id = %L$q$, U1, v_c),
                    'HK_TRS_DOC_UNBALANCED', 'T07 INV-TRS-13 lines add up to the claim');
  INSERT INTO treasury.petty_cash_claim_line (tenant_id, claim_id, line_no, expense_date, description, amount, posting_key)
  VALUES (core.current_tenant_id(), v_c, 3, DATE '2026-04-06', 'نان', 50000, 'purchase.expense');
  UPDATE treasury.petty_cash_claim SET status = 'submitted', submitted_by = U1, submitted_at = now() WHERE id = v_c;
  PERFORM tp_expect(format($q$UPDATE treasury.petty_cash_claim_line SET amount = 1 WHERE claim_id = %L AND line_no = 1$q$, v_c),
                    'HK_TRS_DOC_IMMUTABLE', 'T07 lines locked after submission');
  PERFORM tp_expect(format($q$UPDATE treasury.petty_cash_claim SET status = 'approved', approved_by = %L, approved_at = now() WHERE id = %L$q$, U1, v_c),
                    'petty_claim_sod', 'T07 INV-TRS-13 approver differs from submitter');
  PERFORM tp_expect(format($q$UPDATE treasury.petty_cash_claim SET status = 'posted' WHERE id = %L$q$, v_c),
                    'HK_TRS_DOC_TRANSITION', 'T07 must be approved before posting');
  UPDATE treasury.petty_cash_claim SET status = 'approved', approved_by = U2, approved_at = now() WHERE id = v_c;
  SELECT number_id INTO v_num FROM core.number_next('4a000000-0000-7000-8000-000000000504', 'all', 'PY-{seq}', 'treasury.payment', v_c);
  UPDATE treasury.petty_cash_claim SET status = 'posted', journal_id = tp_jr(CA, DATE '2026-04-07'), number_issued_id = v_num, doc_no = 'PY-2' WHERE id = v_c;
  PERFORM tp_expect(format($q$UPDATE treasury.petty_cash_claim SET note = 'x' WHERE id = %L$q$, v_c), 'HK_TRS_DOC_IMMUTABLE', 'T07 posted claim immutable');
  PERFORM tp_expect(format($q$INSERT INTO treasury.petty_cash_claim_line (tenant_id, claim_id, line_no, expense_date, description, amount, posting_key, account_id)
                     VALUES (core.current_tenant_id(), uuidv7(), 1, DATE '2026-04-06', 'x', 1, 'purchase.expense', %L)$q$, tp_acc(CA, '7206')),
                    'petty_line_account', 'T07 one account reference per line');
END $$;

-- ---------- T08 (INV-CHQ-07): دسته‌چک و برگ ----------
DO $$
DECLARE CA uuid := '4a000000-0000-7000-8000-0000000000c1'; v_bk uuid := '4a000000-0000-7000-8000-000000000101';
        v_book uuid := '4a000000-0000-7000-8000-000000000601'; v_leaf uuid;
BEGIN
  PERFORM tp_ctx('A');
  INSERT INTO treasury.cheque_book (tenant_id, id, company_id, bank_account_id, medium, series, serial_from, serial_to, received_on)
  VALUES (core.current_tenant_id(), v_book, CA, v_bk, 'paper', '12', 100001, 100010, DATE '2026-03-25');
  INSERT INTO treasury.cheque_leaf (tenant_id, cheque_book_id, serial_no, sayad_id)
  SELECT core.current_tenant_id(), v_book, g, lpad((1234567800000000 + g)::text, 16, '0') FROM generate_series(100001, 100010) g;
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_book (tenant_id, company_id, bank_account_id, medium, series, serial_from, serial_to, received_on)
                     VALUES (core.current_tenant_id(), %L, %L, 'paper', '12', 100005, 100020, DATE '2026-03-25')$q$, CA, v_bk),
                    'cheque_book_no_overlap', 'T08 INV-CHQ-07 overlapping cheque books');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_leaf (tenant_id, cheque_book_id, serial_no) VALUES (core.current_tenant_id(), %L, 100011)$q$, v_book),
                    'HK_CHQ_LEAF_RANGE', 'T08 leaf outside the book range');
  SELECT id INTO v_leaf FROM treasury.cheque_leaf WHERE cheque_book_id = v_book AND serial_no = 100010;
  PERFORM tp_expect(format($q$UPDATE treasury.cheque_leaf SET state = 'void' WHERE id = %L$q$, v_leaf), 'cheque_leaf_reason', 'T08 void needs a reason');
  UPDATE treasury.cheque_leaf SET state = 'void', state_reason = 'برگ مخدوش' WHERE id = v_leaf;
  PERFORM tp_expect(format($q$UPDATE treasury.cheque_leaf SET state = 'unused', state_reason = NULL WHERE id = %L$q$, v_leaf),
                    'HK_CHQ_LEAF_TRANSITION', 'T08 void leaf is final (P5)');
  PERFORM tp_expect(format($q$UPDATE treasury.cheque_leaf SET state = 'issued' WHERE cheque_book_id = %L AND serial_no = 100009$q$, v_book),
                    'HK_CHQ_LEAF_TRANSITION', 'T08 leaf becomes issued only with an issued cheque');
  UPDATE treasury.cheque_leaf SET state = 'lost', state_reason = 'مفقود' WHERE cheque_book_id = v_book AND serial_no = 100009;
  PERFORM tp_expect(format($q$UPDATE treasury.cheque_leaf SET sayad_id = '9999999999999999' WHERE cheque_book_id = %L AND serial_no = 100001$q$, v_book),
                    'HK_TRS_IMMUTABLE_FIELD', 'T08 leaf sayad id immutable');
END $$;

-- ---------- T09 (INV-CHQ-01..05, 08, 12): چک دریافتی — ماشین حالت رویدادمحور ----------
DO $$
DECLARE CA uuid := '4a000000-0000-7000-8000-0000000000c1'; PC uuid := '4a000000-0000-7000-8000-0000000000e1';
        PS uuid := '4a000000-0000-7000-8000-0000000000e2'; v_bk uuid := '4a000000-0000-7000-8000-000000000101';
        v_cb2 uuid := '4a000000-0000-7000-8000-000000000202';
        v_c uuid; v_c2 uuid; v_c3 uuid; v_j uuid; v_e2 uuid; v_hold uuid; v_coll uuid; v_bdim uuid;
BEGIN
  PERFORM tp_ctx('A');
  v_hold := tp_acc(CA, '1202'); v_coll := tp_acc(CA, '1203');
  SELECT dimension_value_id INTO v_bdim FROM treasury.bank_account WHERE id = v_bk;
  v_c := tp_recv_cheque('1111222233334444', 20000000, PC, tp_jr(CA, DATE '2026-04-10'));
  PERFORM tp_assert((SELECT state || ':' || last_event_seq || ':' || sayad_unique FROM treasury.cheque WHERE id = v_c) = 'in_hand:1:true',
                    'T09 creation event applied');
  -- بدون رویداد ایجاد
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque (tenant_id, company_id, direction, state, medium, sayad_id, amount, amount_base, due_date,
                     received_from_party_id, sayad_state, origin)
                     VALUES (core.current_tenant_id(), %L, 'received', 'in_hand', 'paper', '5555666677778888', 10, 10, DATE '2026-05-01', %L, 'not_inquired', 'receipt')$q$, CA, PC),
                    'HK_CHQ_NO_CREATION_EVENT', 'T09 INV-CHQ-03 cheque needs its creation event');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque (tenant_id, company_id, direction, state, medium, amount, amount_base, due_date,
                     received_from_party_id, sayad_state, origin)
                     VALUES (core.current_tenant_id(), %L, 'received', 'in_hand', 'paper', 10, 10, DATE '2026-05-01', %L, 'not_inquired', 'receipt')$q$, CA, PC),
                    'cheque_sayad_or_legacy', 'T09 INV-CHQ-01 sayad id required unless legacy');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque (tenant_id, company_id, direction, state, medium, sayad_id, amount, amount_base, due_date,
                     received_from_party_id, sayad_state, origin)
                     VALUES (core.current_tenant_id(), %L, 'received', 'in_hand', 'paper', '12345', 10, 10, DATE '2026-05-01', %L, 'not_inquired', 'receipt')$q$, CA, PC),
                    'cheque_sayad_id_check', 'T09 INV-CHQ-01 sayad id is 16 digits');
  PERFORM tp_expect(format($q$SELECT tp_recv_cheque('1111222233334444', 5, %L, tp_jr(%L, DATE '2026-04-10'))$q$, PS, CA),
                    'cheque_sayad_active_uq', 'T09 INV-CHQ-02 duplicate active sayad id');
  -- تغییر مستقیم وضعیت و فیلدهای ثابت
  PERFORM tp_expect(format($q$UPDATE treasury.cheque SET state = 'deposited', deposit_bank_account_id = %L WHERE id = %L$q$, v_bk, v_c),
                    'HK_CHQ_STATE_VIA_EVENT', 'T09 INV-CHQ-03 state changes only via events');
  PERFORM tp_expect(format($q$UPDATE treasury.cheque SET amount = 1, amount_base = 1 WHERE id = %L$q$, v_c), 'HK_TRS_IMMUTABLE_FIELD', 'T09 INV-CHQ-12 amount immutable');
  PERFORM tp_expect(format($q$UPDATE treasury.cheque SET due_date = DATE '2026-12-01' WHERE id = %L$q$, v_c), 'HK_TRS_IMMUTABLE_FIELD', 'T09 INV-CHQ-12 due date immutable');
  -- گذارهای نادرست
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date,
                     collected_after, long_term_after, journal_id) VALUES (core.current_tenant_id(), %L, 2, 'transition', 'R3', 'in_hand', 'collected',
                     DATE '2026-04-11', 20000000, false, %L)$q$, v_c, tp_jr(CA, DATE '2026-04-11')),
                    'HK_CHQ_TRANSITION', 'T09 INV-CHQ-03 R3 needs deposited state');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date,
                     collected_after, long_term_after, journal_id, bank_account_id, deposit_bank_after, holding_account_id, holding_dim_value_id, holding_amount, holding_amount_base)
                     VALUES (core.current_tenant_id(), %L, 3, 'transition', 'R2', 'in_hand', 'deposited', DATE '2026-04-11', 0, false, %L, %L, %L, %L, %L, 20000000, 20000000)$q$,
                     v_c, tp_jr(CA, DATE '2026-04-11'), v_bk, v_bk, v_coll, v_bdim),
                    'HK_CHQ_EVENT_SEQ', 'T09 INV-CHQ-03 contiguous event seq');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date,
                     collected_after, long_term_after, bank_account_id, deposit_bank_after, holding_account_id, holding_dim_value_id, holding_amount, holding_amount_base)
                     VALUES (core.current_tenant_id(), %L, 2, 'transition', 'R2', 'in_hand', 'deposited', DATE '2026-04-11', 0, false, %L, %L, %L, %L, 20000000, 20000000)$q$,
                     v_c, v_bk, v_bk, v_coll, v_bdim),
                    'HK_CHQ_JOURNAL_REQUIRED', 'T09 INV-CHQ-04 deposit needs its journal');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date,
                     collected_after, long_term_after, journal_id, deposit_bank_after, holding_account_id, holding_dim_value_id, holding_amount, holding_amount_base)
                     VALUES (core.current_tenant_id(), %L, 2, 'transition', 'R2', 'in_hand', 'deposited', DATE '2026-04-11', 0, false, %L, %L, %L, %L, 20000000, 20000000)$q$,
                     v_c, tp_jr(CA, DATE '2026-04-11'), v_bk, v_coll, v_bdim),
                    'HK_CHQ_FUND_REQUIRED', 'T09 deposit needs a bank account');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date,
                     collected_after, long_term_after, journal_id, bank_account_id, deposit_bank_after, holding_account_id, holding_dim_value_id, holding_amount, holding_amount_base)
                     VALUES (core.current_tenant_id(), %L, 2, 'transition', 'R2', 'in_hand', 'deposited', DATE '2026-04-01', 0, false, %L, %L, %L, %L, %L, 20000000, 20000000)$q$,
                     v_c, tp_jr(CA, DATE '2026-04-01'), v_bk, v_bk, v_coll, v_bdim),
                    'HK_CHQ_EVENT_DATE', 'T09 event dates never go backwards');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date,
                     collected_after, long_term_after, journal_id, bank_account_id, deposit_bank_after, holding_account_id, holding_dim_value_id, holding_amount, holding_amount_base)
                     VALUES (core.current_tenant_id(), %L, 2, 'transition', 'R2', 'in_hand', 'deposited', DATE '2026-04-11', 0, false, %L, %L, NULL, %L, %L, 20000000, 20000000)$q$,
                     v_c, tp_jr(CA, DATE '2026-04-11'), v_bk, v_coll, v_bdim),
                    'HK_CHQ_AFTER_VALUES', 'T09 deposit records the deposit bank');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date,
                     collected_after, long_term_after, journal_id, bank_account_id, deposit_bank_after)
                     VALUES (core.current_tenant_id(), %L, 2, 'transition', 'R2', 'in_hand', 'deposited', DATE '2026-04-11', 0, false, %L, %L, %L)$q$,
                     v_c, tp_jr(CA, DATE '2026-04-11'), v_bk, v_bk),
                    'HK_CHQ_HOLDING', 'T09 INV-CHQ-14 holding state records its holding account');
  -- R2 واگذاری
  INSERT INTO treasury.cheque_event (tenant_id, id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date, collected_after,
                                     long_term_after, journal_id, bank_account_id, deposit_bank_after, holding_account_id, holding_dim_value_id,
                                     holding_amount, holding_amount_base)
  VALUES (core.current_tenant_id(), uuidv7(), v_c, 2, 'transition', 'R2', 'in_hand', 'deposited', DATE '2026-04-11', 0, false,
          tp_jr(CA, DATE '2026-04-11'), v_bk, v_bk, v_coll, v_bdim, 20000000, 20000000)
  RETURNING id INTO v_e2;
  PERFORM tp_assert((SELECT state FROM treasury.cheque WHERE id = v_c) = 'deposited'
                    AND (SELECT deposit_bank_account_id FROM treasury.cheque WHERE id = v_c) = v_bk, 'T09 R2 applied');
  -- R4 وصول بخشی: مبلغ باید کمتر از اسمی باشد
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date, amount,
                     collected_after, long_term_after, journal_id, bank_account_id, deposit_bank_after, holding_account_id, holding_amount, holding_amount_base)
                     VALUES (core.current_tenant_id(), %L, 3, 'transition', 'R4', 'deposited', 'partially_collected', DATE '2026-04-12', 20000000,
                     20000000, false, %L, %L, %L, %L, 1, 1)$q$, v_c, tp_jr(CA, DATE '2026-04-12'), v_bk, v_bk, tp_acc(CA, '1201')),
                    'HK_CHQ_AMOUNT', 'T09 INV-CHQ-05 partial amount below face');
  -- undo آخرین گذار (R2) و undo دوباره ممنوع
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, undoes_event_id, from_state, to_state, event_date,
                     collected_after, long_term_after, journal_id, holding_account_id, holding_amount, holding_amount_base)
                     VALUES (core.current_tenant_id(), %L, 3, 'undo', %L, 'deposited', 'in_hand', DATE '2026-04-12', 0, false, %L, %L, 19000000, 19000000)$q$,
                     v_c, v_e2, tp_jr(CA, DATE '2026-04-12'), v_hold),
                    'HK_CHQ_UNDO_VALUES', 'T09 undo restores the previous after-values exactly (holding)');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, undoes_event_id, from_state, to_state, event_date,
                     collected_after, long_term_after, holding_account_id, holding_amount, holding_amount_base)
                     VALUES (core.current_tenant_id(), %L, 3, 'undo', %L, 'deposited', 'in_hand', DATE '2026-04-12', 0, false, %L, 20000000, 20000000)$q$,
                     v_c, v_e2, v_hold),
                    'HK_CHQ_JOURNAL_REQUIRED', 'T09 undo of a journaled event references the reversal journal');
  INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, undoes_event_id, from_state, to_state, event_date, collected_after,
                                     long_term_after, journal_id, holding_account_id, holding_amount, holding_amount_base)
  VALUES (core.current_tenant_id(), v_c, 3, 'undo', v_e2, 'deposited', 'in_hand', DATE '2026-04-12', 0, false,
          tp_jr(CA, DATE '2026-04-12'), v_hold, 20000000, 20000000);
  PERFORM tp_assert((SELECT state FROM treasury.cheque WHERE id = v_c) = 'in_hand'
                    AND (SELECT deposit_bank_account_id FROM treasury.cheque WHERE id = v_c) IS NULL, 'T09 undo restored in_hand');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, undoes_event_id, from_state, to_state, event_date,
                     collected_after, long_term_after, journal_id, holding_account_id, holding_amount, holding_amount_base)
                     VALUES (core.current_tenant_id(), %L, 4, 'undo', %L, 'in_hand', 'in_hand', DATE '2026-04-12', 0, false, %L, %L, 20000000, 20000000)$q$,
                     v_c, v_e2, tp_jr(CA, DATE '2026-04-12'), v_hold),
                    'cheque_event_undo_once_uq|HK_CHQ_UNDO', 'T09 an event is undone at most once');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, undoes_event_id, from_state, to_state, event_date,
                     collected_after, long_term_after, holding_account_id, holding_amount, holding_amount_base)
                     SELECT core.current_tenant_id(), %1$L, 4, 'undo', id, 'in_hand', 'in_hand', DATE '2026-04-12', 0, false, %2$L, 20000000, 20000000
                       FROM treasury.cheque_event WHERE cheque_id = %1$L AND seq = 1$q$, v_c, v_hold),
                    'HK_CHQ_UNDO_TARGET', 'T09 creation cannot be undone (use cancel)');
  -- رویداد فقط‌افزودنی
  PERFORM tp_expect(format($q$UPDATE treasury.cheque_event SET reason = 'x' WHERE cheque_id = %L$q$, v_c), 'permission denied|HK_IMMUTABLE', 'T09 INV-CHQ-08 events append-only');
  -- R9 خرج چک → دیگر «فعال» نیست؛ همان شناسهٔ صیاد می‌تواند دوباره دریافت شود
  INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date, collected_after,
                                     long_term_after, journal_id, counterparty_party_id, endorsee_after)
  VALUES (core.current_tenant_id(), v_c, 4, 'transition', 'R9', 'in_hand', 'endorsed', DATE '2026-04-13', 0, false,
          tp_jr(CA, DATE '2026-04-13'), PS, PS);
  PERFORM tp_assert((SELECT sayad_unique FROM treasury.cheque WHERE id = v_c) = false, 'T09 endorsed cheque leaves the active set');
  v_c2 := tp_recv_cheque('1111222233334444', 20000000, PS, tp_jr(CA, DATE '2026-04-20'));
  PERFORM tp_assert(v_c2 IS NOT NULL, 'T09 INV-CHQ-02 spent cheque may come back as a new record');
  -- R10 روی رکورد قدیم با وجود رکورد فعال هم‌شناسه رد می‌شود (یکتایی فعال)
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date,
                     collected_after, long_term_after, journal_id, endorsee_after, holding_account_id, holding_amount, holding_amount_base)
                     VALUES (core.current_tenant_id(), %L, 5, 'transition', 'R10', 'endorsed', 'returned_by_third_party', DATE '2026-04-21', 0, false, %L, %L, %L, 20000000, 20000000)$q$,
                     v_c, tp_jr(CA, DATE '2026-04-21'), PS, tp_acc(CA, '1201')),
                    'cheque_sayad_active_uq', 'T09 INV-CHQ-02 reactivation conflicts with the active record');
  -- R5B برگشت در شعبه → R7 تسویه نادرست (مبلغ) و درست
  v_c3 := tp_recv_cheque('9999000011112222', 3000000, PC, tp_jr(CA, DATE '2026-04-10'));
  INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date, collected_after,
                                     long_term_after, journal_id, holding_account_id, holding_amount, holding_amount_base)
  VALUES (core.current_tenant_id(), v_c3, 2, 'transition', 'R5B', 'in_hand', 'bounced', DATE '2026-04-14', 0, false,
          tp_jr(CA, DATE '2026-04-14'), tp_acc(CA, '1201'), 3000000, 3000000);
  -- R7P تسویهٔ قسطی: قسط باید کمتر از مانده باشد؛ مانده و محل نگهداری کم می‌شود
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date, amount,
                     collected_after, long_term_after, journal_id, cash_box_id, holding_account_id, holding_amount, holding_amount_base)
                     VALUES (core.current_tenant_id(), %L, 3, 'transition', 'R7P', 'bounced', 'bounced', DATE '2026-04-14', 3000000, 3000000, false, %L, %L, %L, 0, 0)$q$,
                     v_c3, tp_jr(CA, DATE '2026-04-14'), v_cb2, tp_acc(CA, '1201')),
                    'HK_CHQ_AMOUNT', 'T09 installment is below the outstanding amount');
  INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date, amount, collected_after,
                                     long_term_after, journal_id, cash_box_id, holding_account_id, holding_amount, holding_amount_base)
  VALUES (core.current_tenant_id(), v_c3, 3, 'transition', 'R7P', 'bounced', 'bounced', DATE '2026-04-14', 1000000, 1000000, false,
          tp_jr(CA, DATE '2026-04-14'), v_cb2, tp_acc(CA, '1201'), 2000000, 2000000);
  PERFORM tp_assert((SELECT state || ':' || collected_amount::bigint FROM treasury.cheque WHERE id = v_c3) = 'bounced:1000000',
                    'T09 INV-CHQ-05 installment lowers the outstanding amount');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date, amount,
                     collected_after, long_term_after, journal_id, cash_box_id) VALUES (core.current_tenant_id(), %L, 4, 'transition', 'R7', 'bounced', 'settled',
                     DATE '2026-04-15', 3000000, 1000000, false, %L, %L)$q$, v_c3, tp_jr(CA, DATE '2026-04-15'), v_cb2),
                    'HK_CHQ_AMOUNT', 'T09 settlement equals the outstanding amount');
  INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date, amount, collected_after,
                                     long_term_after, journal_id, cash_box_id)
  VALUES (core.current_tenant_id(), v_c3, 4, 'transition', 'R7', 'bounced', 'settled', DATE '2026-04-15', 2000000, 1000000, false,
          tp_jr(CA, DATE '2026-04-15'), v_cb2);
  PERFORM tp_assert((SELECT state FROM treasury.cheque WHERE id = v_c3) = 'settled', 'T09 R5B then R7P then R7');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date,
                     collected_after, long_term_after, journal_id, bank_account_id, deposit_bank_after) VALUES (core.current_tenant_id(), %L, 5, 'transition', 'R2',
                     'settled', 'deposited', DATE '2026-04-16', 1000000, false, %L, %L, %L)$q$, v_c3, tp_jr(CA, DATE '2026-04-16'), v_bk, v_bk),
                    'HK_CHQ_TRANSITION', 'T09 terminal state has no exits');
END $$;

-- ---------- T10 (INV-CHQ-05/14): وصول، وصول بخشی، بلندمدت ----------
DO $$
DECLARE CA uuid := '4a000000-0000-7000-8000-0000000000c1'; PC uuid := '4a000000-0000-7000-8000-0000000000e1';
        v_bk uuid := '4a000000-0000-7000-8000-000000000101'; v_c uuid; v_lt uuid := uuidv7(); v_bdim uuid;
BEGIN
  PERFORM tp_ctx('A');
  SELECT dimension_value_id INTO v_bdim FROM treasury.bank_account WHERE id = v_bk;
  v_c := tp_recv_cheque('3333444455556666', 10000000, PC, tp_jr(CA, DATE '2026-04-10'));
  INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date, collected_after, long_term_after,
                                     journal_id, bank_account_id, deposit_bank_after, holding_account_id, holding_dim_value_id, holding_amount, holding_amount_base)
  VALUES (core.current_tenant_id(), v_c, 2, 'transition', 'R2', 'in_hand', 'deposited', DATE '2026-04-11', 0, false,
          tp_jr(CA, DATE '2026-04-11'), v_bk, v_bk, tp_acc(CA, '1203'), v_bdim, 10000000, 10000000);
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date, amount,
                     collected_after, long_term_after, journal_id, bank_account_id, deposit_bank_after, holding_account_id, holding_amount, holding_amount_base)
                     VALUES (core.current_tenant_id(), %L, 3, 'transition', 'R4', 'deposited', 'partially_collected', DATE '2026-04-12', 4000000,
                     4000000, false, %L, %L, %L, %L, 5000000, 5000000)$q$, v_c, tp_jr(CA, DATE '2026-04-12'), v_bk, v_bk, tp_acc(CA, '1201')),
                    'HK_CHQ_HOLDING', 'T10 INV-CHQ-14 holding amount = outstanding after partial collection');
  INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date, amount, collected_after,
                                     long_term_after, journal_id, bank_account_id, deposit_bank_after, holding_account_id, holding_amount, holding_amount_base)
  VALUES (core.current_tenant_id(), v_c, 3, 'transition', 'R4', 'deposited', 'partially_collected', DATE '2026-04-12', 4000000, 4000000,
          false, tp_jr(CA, DATE '2026-04-12'), v_bk, v_bk, tp_acc(CA, '1201'), 6000000, 6000000);
  PERFORM tp_assert((SELECT collected_amount FROM treasury.cheque WHERE id = v_c) = 4000000, 'T10 INV-CHQ-05 partial collection recorded');
  PERFORM tp_expect(format($q$UPDATE treasury.cheque SET collected_amount = 9000000 WHERE id = %L$q$, v_c), 'HK_CHQ_STATE_VIA_EVENT', 'T10 collected amount only via events');
  -- بلندمدت → جاری (R14) فقط از true به false
  INSERT INTO treasury.cheque (tenant_id, id, company_id, direction, state, medium, sayad_id, amount, amount_base, due_date, received_from_party_id,
                               sayad_state, origin, is_long_term)
  VALUES (core.current_tenant_id(), v_lt, CA, 'received', 'in_hand', 'electronic', '7777888899990000', 50000000, 50000000, DATE '2027-06-01', PC,
          'not_inquired', 'receipt', true);
  INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, to_state, event_date, collected_after, long_term_after, journal_id,
                                     holding_account_id, holding_amount, holding_amount_base)
  VALUES (core.current_tenant_id(), v_lt, 1, 'transition', 'R1', 'in_hand', DATE '2026-04-10', 0, true, tp_jr(CA, DATE '2026-04-10'),
          tp_acc(CA, '1202'), 50000000, 50000000);
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date, collected_after,
                     long_term_after, journal_id, bank_account_id, deposit_bank_after, holding_account_id, holding_amount, holding_amount_base)
                     VALUES (core.current_tenant_id(), %L, 2, 'transition', 'R2', 'in_hand', 'deposited', DATE '2026-04-11', 0, false, %L, %L, %L, %L, 50000000, 50000000)$q$,
                     v_lt, tp_jr(CA, DATE '2026-04-11'), v_bk, v_bk, tp_acc(CA, '1203')),
                    'HK_CHQ_AFTER_VALUES', 'T10 only R14 changes the long-term flag');
  INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date, collected_after, long_term_after,
                                     journal_id, holding_account_id, holding_amount, holding_amount_base)
  VALUES (core.current_tenant_id(), v_lt, 2, 'transition', 'R14', 'in_hand', 'in_hand', DATE '2026-05-01', 0, false,
          tp_jr(CA, DATE '2026-05-01'), tp_acc(CA, '1202'), 50000000, 50000000);
  PERFORM tp_assert((SELECT is_long_term FROM treasury.cheque WHERE id = v_lt) = false, 'T10 R14 reclassified to current');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date, collected_after,
                     long_term_after, journal_id, holding_account_id, holding_amount, holding_amount_base) VALUES (core.current_tenant_id(), %L, 3, 'transition', 'R14',
                     'in_hand', 'in_hand', DATE '2026-05-02', 0, false, %L, %L, 50000000, 50000000)$q$, v_lt, tp_jr(CA, DATE '2026-05-02'), tp_acc(CA, '1202')),
                    'HK_CHQ_AFTER_VALUES', 'T10 R14 only on a long-term cheque');
END $$;

-- ---------- T11 (INV-CHQ-06/07/09/10/11): چک پرداختی، برگ، ضمانت، ورود مهاجرت، صیاد ----------
DO $$
DECLARE CA uuid := '4a000000-0000-7000-8000-0000000000c1'; PC uuid := '4a000000-0000-7000-8000-0000000000e1';
        PS uuid := '4a000000-0000-7000-8000-0000000000e2'; v_bk uuid := '4a000000-0000-7000-8000-000000000101';
        v_book uuid := '4a000000-0000-7000-8000-000000000601'; v_leaf uuid; v_leaf_sayad text; v_i uuid := uuidv7(); v_g uuid := uuidv7();
        v_m uuid := uuidv7(); v_c uuid;
BEGIN
  PERFORM tp_ctx('A');
  SELECT id, sayad_id INTO v_leaf, v_leaf_sayad FROM treasury.cheque_leaf WHERE cheque_book_id = v_book AND serial_no = 100001;
  -- در وجه حامل ممنوع
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque (tenant_id, company_id, direction, state, medium, sayad_id, amount, amount_base, due_date,
                     bank_account_id, cheque_leaf_id, sayad_state, origin) VALUES (core.current_tenant_id(), %L, 'issued', 'issued', 'paper', %L, 10, 10,
                     DATE '2026-06-01', %L, %L, 'not_registered', 'payment')$q$, CA, v_leaf_sayad, v_bk, v_leaf),
                    'cheque_no_bearer', 'T11 INV-CHQ-09 bearer cheque forbidden');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque (tenant_id, company_id, direction, state, medium, sayad_id, amount, amount_base, due_date,
                     bank_account_id, payee_party_id, sayad_state, origin) VALUES (core.current_tenant_id(), %L, 'issued', 'issued', 'paper', '1212121212121212', 10, 10,
                     DATE '2026-06-01', %L, %L, 'not_registered', 'payment')$q$, CA, v_bk, PS),
                    'cheque_issued_leaf', 'T11 INV-CHQ-07 issued cheque uses a chequebook leaf');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque (tenant_id, company_id, direction, state, medium, sayad_id, amount, amount_base, due_date,
                     bank_account_id, cheque_leaf_id, payee_party_id, sayad_state, origin) VALUES (core.current_tenant_id(), %L, 'issued', 'issued', 'electronic', %L, 10, 10,
                     DATE '2026-06-01', %L, %L, %L, 'not_registered', 'payment')$q$, CA, v_leaf_sayad, v_bk, v_leaf, PS),
                    'HK_CHQ_LEAF_MISMATCH', 'T11 INV-CHQ-07 leaf medium must match');
  INSERT INTO treasury.cheque (tenant_id, id, company_id, direction, state, medium, sayad_id, amount, amount_base, due_date, bank_account_id,
                               cheque_leaf_id, payee_party_id, sayad_state, origin)
  VALUES (core.current_tenant_id(), v_i, CA, 'issued', 'issued', 'paper', v_leaf_sayad, 8000000, 8000000, DATE '2026-06-01', v_bk, v_leaf, PS,
          'not_registered', 'payment');
  INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, to_state, event_date, collected_after, long_term_after, journal_id,
                                     holding_account_id, holding_amount, holding_amount_base)
  VALUES (core.current_tenant_id(), v_i, 1, 'transition', 'P1', 'issued', DATE '2026-04-15', 0, false, tp_jr(CA, DATE '2026-04-15'),
          tp_acc(CA, '3102'), 8000000, 8000000);
  PERFORM tp_assert((SELECT state FROM treasury.cheque_leaf WHERE id = v_leaf) = 'issued', 'T11 INV-CHQ-07 leaf issued with the cheque');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque (tenant_id, company_id, direction, state, medium, amount, amount_base, due_date, bank_account_id,
                     cheque_leaf_id, payee_party_id, sayad_state, origin, is_legacy) VALUES (core.current_tenant_id(), %L, 'issued', 'issued', 'paper', 10, 10,
                     DATE '2026-06-01', %L, %L, %L, 'legacy', 'payment', true)$q$, CA, v_bk, v_leaf, PS),
                    'cheque_leaf_active_uq|HK_CHQ_LEAF_MISMATCH', 'T11 INV-CHQ-07 one active cheque per leaf');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date,
                     collected_after, long_term_after, journal_id, holding_account_id, holding_amount, holding_amount_base)
                     VALUES (core.current_tenant_id(), %L, 2, 'transition', 'R5', 'issued', 'bounced', DATE '2026-04-16', 0, false, %L, %L, 8000000, 8000000)$q$,
                     v_i, tp_jr(CA, DATE '2026-04-16'), tp_acc(CA, '3102')),
                    'HK_CHQ_TRANSITION_KIND', 'T11 received-cheque transitions do not apply to issued cheques');
  -- ابطال ثبت → برگ آزاد می‌شود
  INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date, collected_after, long_term_after)
  VALUES (core.current_tenant_id(), v_i, 2, 'transition', 'XC1', 'issued', 'cancelled', DATE '2026-04-16', 0, false);
  PERFORM tp_assert((SELECT state FROM treasury.cheque_leaf WHERE id = v_leaf) = 'unused', 'T11 cancelled registration frees the leaf');
  -- بُعد صیاد: فقط رو به جلو
  UPDATE treasury.cheque SET sayad_state = 'registered' WHERE id = v_i;
  PERFORM tp_expect(format($q$UPDATE treasury.cheque SET sayad_state = 'not_registered' WHERE id = %L$q$, v_i), 'HK_CHQ_SAYAD_TRANSITION', 'T11 INV-CHQ-11 sayad state forward only');
  PERFORM tp_expect(format($q$UPDATE treasury.cheque SET sayad_state = 'accepted' WHERE id = %L$q$, v_i), 'cheque_sayad_state', 'T11 INV-CHQ-11 sayad states per direction');
  -- ضمانت دریافتی: فقط گذارهای ضمانت
  INSERT INTO treasury.cheque (tenant_id, id, company_id, direction, purpose, state, medium, sayad_id, amount, amount_base, due_date,
                               received_from_party_id, sayad_state, origin)
  VALUES (core.current_tenant_id(), v_g, CA, 'received', 'guarantee', 'held', 'paper', '4444555566667777', 100000000, 100000000, DATE '2026-12-01', PC,
          'not_inquired', 'manual');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, to_state, event_date, collected_after,
                     long_term_after, journal_id, holding_account_id, holding_amount, holding_amount_base) VALUES (core.current_tenant_id(), %L, 1, 'transition', 'R1',
                     'held', DATE '2026-04-10', 0, false, %L, %L, 100000000, 100000000)$q$, v_g, tp_jr(CA, DATE '2026-04-10'), tp_acc(CA, '8101')),
                    'HK_CHQ_TRANSITION_KIND', 'T11 INV-CHQ-06 guarantee cheque cannot use payment transitions');
  INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, to_state, event_date, collected_after, long_term_after, journal_id,
                                     holding_account_id, holding_amount, holding_amount_base)
  VALUES (core.current_tenant_id(), v_g, 1, 'transition', 'G1', 'held', DATE '2026-04-10', 0, false,
          tp_jr(CA, DATE '2026-04-10', jsonb_build_array(jsonb_build_object('a','8101','dr',100000000,'d1',tp_pdim(PC)),
                                                         jsonb_build_object('a','8201','cr',100000000,'d1',tp_pdim(PC)))),
          tp_acc(CA, '8101'), 100000000, 100000000);
  -- ورود از نرم‌افزار قبلی: فقط با گذار import، بدون سند
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque (tenant_id, company_id, direction, state, medium, amount, amount_base, due_date, sayad_state, origin, is_legacy)
                     VALUES (core.current_tenant_id(), %L, 'received', 'deposited', 'paper', 2500000, 2500000, DATE '2026-04-30', 'legacy', 'migration', true)$q$, CA),
                    'cheque_deposited_bank', 'T11 deposited cheque names its deposit bank');
  INSERT INTO treasury.cheque (tenant_id, id, company_id, direction, state, medium, amount, amount_base, due_date, sayad_state, origin, is_legacy,
                               deposit_bank_account_id)
  VALUES (core.current_tenant_id(), v_m, CA, 'received', 'deposited', 'paper', 2500000, 2500000, DATE '2026-04-30', 'legacy', 'migration', true, v_bk);
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, to_state, event_date, collected_after,
                     long_term_after, deposit_bank_after, holding_account_id, holding_amount, holding_amount_base) VALUES (core.current_tenant_id(), %L, 1,
                     'transition', 'IMP_RP_DEPOSITED', 'deposited', DATE '2026-03-21', 0, false, NULL, %L, 2500000, 2500000)$q$, v_m, tp_acc(CA, '1203')),
                    'HK_CHQ_AFTER_VALUES', 'T11 import event describes the registered cheque');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, to_state, event_date, collected_after,
                     long_term_after, deposit_bank_after, holding_account_id, holding_amount, holding_amount_base, journal_id) VALUES (core.current_tenant_id(), %L, 1,
                     'transition', 'IMP_RP_DEPOSITED', 'deposited', DATE '2026-03-21', 0, false, %L, %L, 2500000, 2500000, %L)$q$, v_m, v_bk, tp_acc(CA, '1203'),
                     tp_jr(CA, DATE '2026-03-21')),
                    'HK_CHQ_JOURNAL_UNEXPECTED', 'T11 INV-CHQ-15 imported cheque has no new journal (balance comes from opening)');
  INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, to_state, event_date, collected_after, long_term_after,
                                     deposit_bank_after, holding_account_id, holding_amount, holding_amount_base)
  VALUES (core.current_tenant_id(), v_m, 1, 'transition', 'IMP_RP_DEPOSITED', 'deposited', DATE '2026-03-21', 0, false, v_bk, tp_acc(CA, '1203'),
          2500000, 2500000);
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque (tenant_id, company_id, direction, state, medium, sayad_id, amount, amount_base, due_date,
                     received_from_party_id, sayad_state, origin) VALUES (core.current_tenant_id(), %L, 'received', 'in_hand', 'paper', '1231231231231231', 10, 10,
                     DATE '2026-05-01', %L, 'not_inquired', 'receipt');
                     INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, to_state, event_date, collected_after, long_term_after,
                     holding_account_id, holding_amount, holding_amount_base) SELECT core.current_tenant_id(), id, 1, 'transition', 'IMP_RP_IN_HAND', 'in_hand',
                     DATE '2026-04-01', 0, false, %L, 10, 10 FROM treasury.cheque WHERE sayad_id = '1231231231231231'$q$, CA, PC, tp_acc(CA, '1202')),
                    'HK_CHQ_IMPORT_ORIGIN', 'T11 import transitions only for migrated cheques');
  -- استعلام صیاد: رنگ داده‌محور، فقط از راه استعلام، فقط تازه‌تر
  v_c := tp_recv_cheque('8888777766665555', 1000000, PC, tp_jr(CA, DATE '2026-04-10'));
  PERFORM tp_expect(format($q$UPDATE treasury.cheque SET sayad_color_code = 'red', sayad_inquired_at = now() WHERE id = %L$q$, v_c),
                    'HK_CHQ_SAYAD_COLOR', 'T11 INV-CHQ-10 colour only from a recorded inquiry');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_sayad_inquiry (tenant_id, cheque_id, inquired_at, color_code, channel)
                     VALUES (core.current_tenant_id(), %L, now(), 'purple', 'manual')$q$, v_c),
                    'foreign key|violates', 'T11 INV-CHQ-10 colour from the data-driven catalog');
  INSERT INTO treasury.cheque_sayad_inquiry (tenant_id, cheque_id, inquired_at, color_code, channel)
  VALUES (core.current_tenant_id(), v_c, timestamptz '2026-04-10 09:00+03:30', 'yellow', 'manual');
  PERFORM tp_assert((SELECT sayad_color_code || ':' || sayad_state FROM treasury.cheque WHERE id = v_c) = 'yellow:inquired', 'T11 inquiry applied');
  INSERT INTO treasury.cheque_sayad_inquiry (tenant_id, cheque_id, inquired_at, color_code, channel)
  VALUES (core.current_tenant_id(), v_c, timestamptz '2026-04-09 09:00+03:30', 'red', 'manual');
  PERFORM tp_assert((SELECT sayad_color_code FROM treasury.cheque WHERE id = v_c) = 'yellow', 'T11 older inquiry does not override');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_sayad_inquiry (tenant_id, cheque_id, inquired_at, color_code, channel)
                     VALUES (core.current_tenant_id(), %L, now(), 'white', 'manual')$q$, v_i), 'HK_CHQ_SAYAD_INQUIRY', 'T11 inquiry only for received cheques');
  UPDATE treasury.cheque SET legal_status = 'certificate_issued' WHERE id = v_c;
  PERFORM tp_expect(format($q$UPDATE treasury.cheque SET legal_status = 'none' WHERE id = %L$q$, v_c), 'HK_CHQ_LEGAL_TRANSITION', 'T11 legal status forward only');
END $$;

-- ---------- T12 (INV-CRD-01/02): کارتخوان — RRN رشته و یکتا، تسویهٔ یک‌باره، جمع تسویه ----------
DO $$
DECLARE CA uuid := '4a000000-0000-7000-8000-0000000000c1'; v_ct uuid := '4a000000-0000-7000-8000-000000000301';
        v_bk uuid := '4a000000-0000-7000-8000-000000000101'; v_t1 uuid := uuidv7(); v_t2 uuid := uuidv7(); v_s uuid := uuidv7(); v_s2 uuid := uuidv7();
BEGIN
  PERFORM tp_ctx('A');
  INSERT INTO treasury.card_txn (tenant_id, id, company_id, card_terminal_id, txn_at, business_date, amount, rrn, stan, masked_pan, source) VALUES
    (core.current_tenant_id(), v_t1, CA, v_ct, now(), DATE '2026-04-05', 700000, '000000000123', '000045', '603799******1234', 'pos'),
    (core.current_tenant_id(), v_t2, CA, v_ct, now(), DATE '2026-04-05', 300000, '000000000124', '000046', NULL, 'pos');
  PERFORM tp_assert((SELECT rrn FROM treasury.card_txn WHERE id = v_t1) = '000000000123', 'T12 INV-CRD-01 RRN text with leading zeros');
  PERFORM tp_expect(format($q$INSERT INTO treasury.card_txn (tenant_id, company_id, card_terminal_id, txn_at, business_date, amount, rrn, source)
                     VALUES (core.current_tenant_id(), %L, %L, now(), DATE '2026-04-05', 1, '000000000123', 'pos')$q$, CA, v_ct),
                    'card_txn_rrn_uq', 'T12 INV-CRD-01 RRN unique per terminal');
  PERFORM tp_expect(format($q$INSERT INTO treasury.card_txn (tenant_id, company_id, card_terminal_id, txn_at, business_date, amount, stan, source)
                     VALUES (core.current_tenant_id(), %L, %L, now(), DATE '2026-04-05', 1, '1234567', 'pos')$q$, CA, v_ct),
                    'card_txn_stan_check', 'T12 STAN is at most 6 digits');
  PERFORM tp_expect(format($q$INSERT INTO treasury.card_txn (tenant_id, company_id, card_terminal_id, txn_at, business_date, amount, masked_pan, source)
                     VALUES (core.current_tenant_id(), %L, %L, now(), DATE '2026-04-05', 1, '6037991234561234', 'pos')$q$, CA, v_ct),
                    'card_txn_masked_pan_check', 'T12 INV-TRS-02 no full PAN on card transactions');
  INSERT INTO treasury.card_settlement (tenant_id, id, company_id, card_terminal_id, bank_account_id, settlement_date, gross_amount, fee_amount, matched_by)
  VALUES (core.current_tenant_id(), v_s, CA, v_ct, v_bk, DATE '2026-04-06', 1000000, 0, 'window');
  UPDATE treasury.card_txn SET settlement_id = v_s, settled_at = now() WHERE id IN (v_t1, v_t2);
  PERFORM tp_expect(format($q$UPDATE treasury.card_settlement SET status = 'posted', journal_id = tp_jr(%L, DATE '2026-04-06'), gross_amount = 999000 WHERE id = %L$q$, CA, v_s),
                    'HK_CRD_SETTLEMENT_TOTAL', 'T12 INV-CRD-02 settlement equals its transactions');
  UPDATE treasury.card_settlement SET status = 'posted', journal_id = tp_jr(CA, DATE '2026-04-06') WHERE id = v_s;
  INSERT INTO treasury.card_settlement (tenant_id, id, company_id, card_terminal_id, bank_account_id, settlement_date, gross_amount, matched_by)
  VALUES (core.current_tenant_id(), v_s2, CA, v_ct, v_bk, DATE '2026-04-07', 700000, 'manual');
  PERFORM tp_expect(format($q$UPDATE treasury.card_txn SET settlement_id = %L WHERE id = %L$q$, v_s2, v_t1), 'HK_CRD_SETTLED_ONCE', 'T12 INV-CRD-02 settled once');
  PERFORM tp_expect(format($q$UPDATE treasury.card_txn SET amount = 1 WHERE id = %L$q$, v_t1), 'HK_TRS_IMMUTABLE_FIELD', 'T12 amount immutable');
  PERFORM tp_expect(format($q$UPDATE treasury.card_txn SET status = 'void', void_reason = 'x' WHERE id = %L$q$, v_t1), 'card_txn_unsettled_void', 'T12 settled transaction cannot be voided');
  PERFORM tp_expect(format($q$UPDATE treasury.card_settlement SET fee_amount = 1 WHERE id = %L$q$, v_s), 'HK_TRS_DOC_IMMUTABLE', 'T12 posted settlement immutable');
  UPDATE treasury.card_settlement SET status = 'cancelled', cancel_journal_id = tp_jr(CA, DATE '2026-04-08') WHERE id = v_s;
  PERFORM tp_assert((SELECT count(*) FROM treasury.card_txn WHERE settlement_id IS NULL AND id IN (v_t1, v_t2)) = 2, 'T12 cancelled settlement releases its transactions');
  INSERT INTO treasury.card_day_close (tenant_id, card_terminal_id, business_date, device_total, device_count, book_total, book_count, status)
  VALUES (core.current_tenant_id(), v_ct, DATE '2026-04-05', 1000000, 2, 1000000, 2, 'ok');
  PERFORM tp_expect(format($q$INSERT INTO treasury.card_day_close (tenant_id, card_terminal_id, business_date, device_total, device_count, book_total, book_count, status)
                     VALUES (core.current_tenant_id(), %L, DATE '2026-04-06', 900000, 2, 1000000, 2, 'ok')$q$, v_ct),
                    'card_day_close_status', 'T12 a mismatching day close cannot be ok');
END $$;

-- ---------- T13 (INV-GW-01..05): درگاه پرداخت مستأجر ----------
DO $$
DECLARE CA uuid := '4a000000-0000-7000-8000-0000000000c1'; v_bk uuid := '4a000000-0000-7000-8000-000000000101';
        PC uuid := '4a000000-0000-7000-8000-0000000000e1'; v_ga uuid := uuidv7(); v_gp uuid := uuidv7(); v_gm uuid := uuidv7();
        v_gm2 uuid := uuidv7(); v_doc uuid := uuidv7(); v_ga2 uuid := uuidv7();
BEGIN
  PERFORM tp_ctx('A');
  PERFORM tp_expect(format($q$INSERT INTO treasury.gateway_account (tenant_id, company_id, code, name, provider_code, credentials_sealed, credentials_key_ref,
                     callback_base_url, settlement_bank_account_id) VALUES (core.current_tenant_id(), %L, 'GWX', 'آیدی‌پی', 'idpay', decode(repeat('aa', 32), 'hex'),
                     'kms:tenant/a/gw', 'https://a.example.ir/cb', %L)$q$, CA, v_bk),
                    'HK_GW_PROVIDER_BLOCKED', 'T13 INV-GW-04 blocked provider cannot be configured');
  PERFORM tp_expect(format($q$INSERT INTO treasury.gateway_account (tenant_id, company_id, code, name, provider_code, credentials_sealed, credentials_key_ref,
                     callback_base_url, settlement_bank_account_id) VALUES (core.current_tenant_id(), %L, 'GWX', 'x', 'zarinpal', decode(repeat('aa', 32), 'hex'),
                     'kms:tenant/a/gw', 'http://a.example.ir/cb', %L)$q$, CA, v_bk),
                    'gateway_account_callback_base_url_check', 'T13 callback must be https');
  INSERT INTO treasury.gateway_account (tenant_id, id, company_id, code, name, provider_code, credentials_sealed, credentials_key_ref, callback_base_url, settlement_bank_account_id)
  VALUES (core.current_tenant_id(), v_ga, CA, 'ZP', 'زرین‌پال', 'zarinpal', decode(repeat('aa', 32), 'hex'), 'kms:tenant/a/gw', 'https://a.example.ir/cb', v_bk),
         (core.current_tenant_id(), v_ga2, CA, 'PP', 'پی‌پینگ', 'payping', decode(repeat('bb', 32), 'hex'), 'kms:tenant/a/gw2', 'https://a.example.ir/cb', v_bk);
  PERFORM tp_expect(format($q$INSERT INTO treasury.gateway_payment (tenant_id, company_id, gateway_account_id, provider_code, order_id, amount, api_amount, api_amount_unit, expires_at)
                     VALUES (core.current_tenant_id(), %L, %L, 'zibal', 'ORD-000001', 50000, 50000, 'IRR', now() + interval '1 hour')$q$, CA, v_ga),
                    'HK_GW_ACCOUNT', 'T13 provider code copied from the account');
  PERFORM tp_expect(format($q$INSERT INTO treasury.gateway_payment (tenant_id, company_id, gateway_account_id, provider_code, order_id, amount, api_amount, api_amount_unit, expires_at)
                     VALUES (core.current_tenant_id(), %L, %L, 'payping', 'ORD-000002', 50000, 50000, 'IRT', now() + interval '1 hour')$q$, CA, v_ga2),
                    'HK_GW_AMOUNT_UNIT', 'T13 INV-GW-06 toman provider gets amount/10');
  INSERT INTO treasury.gateway_payment (tenant_id, id, company_id, gateway_account_id, provider_code, order_id, amount, api_amount, api_amount_unit, expires_at)
  VALUES (core.current_tenant_id(), v_gm2, CA, v_ga2, 'payping', 'ORD-000003', 50000, 5000, 'IRT', now() + interval '1 hour');
  PERFORM tp_expect(format($q$INSERT INTO treasury.gateway_payment (tenant_id, company_id, gateway_account_id, provider_code, order_id, amount, api_amount, api_amount_unit, expires_at)
                     VALUES (core.current_tenant_id(), %L, %L, 'zarinpal', 'ORD-000004', 500.5, 500.5, 'IRR', now() + interval '1 hour')$q$, CA, v_ga),
                    'gateway_payment_amount_check|HK_GW_AMOUNT_UNIT', 'T13 whole rials only');
  INSERT INTO treasury.gateway_payment (tenant_id, id, company_id, gateway_account_id, provider_code, party_id, order_id, amount, api_amount, api_amount_unit, expires_at)
  VALUES (core.current_tenant_id(), v_gp, CA, v_ga, 'zarinpal', PC, 'ORD-000005', 2500000, 2500000, 'IRR', now() + interval '1 hour');
  PERFORM tp_expect(format($q$UPDATE treasury.gateway_payment SET state = 'verified', provider_ref = 'A0001', provider_txn_ref = 'R1', verified_at = now(),
                     verified_amount = 2500000 WHERE id = %L$q$, v_gp), 'HK_GW_TRANSITION', 'T13 INV-GW-01 created -> verified not allowed');
  UPDATE treasury.gateway_payment SET state = 'redirected', provider_ref = 'A0001', redirected_at = now() WHERE id = v_gp;
  PERFORM tp_expect(format($q$UPDATE treasury.gateway_payment SET provider_ref = 'A0002' WHERE id = %L$q$, v_gp), 'HK_TRS_IMMUTABLE_FIELD', 'T13 provider ref set once');
  PERFORM tp_expect(format($q$INSERT INTO treasury.gateway_payment (tenant_id, company_id, gateway_account_id, provider_code, order_id, amount, api_amount, api_amount_unit, expires_at, provider_ref)
                     VALUES (core.current_tenant_id(), %L, %L, 'zarinpal', 'ORD-000006', 10, 10, 'IRR', now() + interval '1 hour', 'A0001')$q$, CA, v_ga),
                    'gateway_payment_provider_ref_uq', 'T13 INV-GW-02 unique (provider, provider_ref)');
  UPDATE treasury.gateway_payment SET state = 'callback_received', callback_at = now() WHERE id = v_gp;
  PERFORM tp_expect(format($q$UPDATE treasury.gateway_payment SET state = 'verified', provider_txn_ref = 'R1', verified_at = now(), verified_amount = 2400000 WHERE id = %L$q$, v_gp),
                    'gateway_payment_verified', 'T13 INV-GW-01 verified amount equals the requested amount');
  -- رسید درگاه پیش از verify ممنوع
  INSERT INTO treasury.money_document (tenant_id, id, company_id, direction, doc_date, party_id, total_amount, origin, origin_ref)
  VALUES (core.current_tenant_id(), v_doc, CA, 'receipt', DATE '2026-04-08', PC, 2500000, 'gateway', v_gp);
  PERFORM tp_expect(format($q$INSERT INTO treasury.money_instrument (tenant_id, document_id, line_no, kind, amount, gateway_payment_id)
                     VALUES (core.current_tenant_id(), %L, 1, 'gateway', 2500000, %L)$q$, v_doc, v_gp),
                    'HK_GW_NOT_VERIFIED', 'T13 INV-GW-03 receipt only for a verified payment');
  UPDATE treasury.gateway_payment SET state = 'verified', provider_txn_ref = 'R1', verified_at = now(), verified_amount = 2500000, card_masked = '603799******1234'
   WHERE id = v_gp;
  INSERT INTO treasury.money_instrument (tenant_id, document_id, line_no, kind, amount, gateway_payment_id)
  VALUES (core.current_tenant_id(), v_doc, 1, 'gateway', 2500000, v_gp);
  INSERT INTO treasury.money_counter_line (tenant_id, document_id, line_no, kind, party_id, party_role, amount)
  VALUES (core.current_tenant_id(), v_doc, 1, 'party', PC, 'customer', 2500000);
  UPDATE treasury.gateway_payment SET money_document_id = v_doc WHERE id = v_gp;
  PERFORM tp_expect(format($q$UPDATE treasury.gateway_payment SET state = 'reversed' WHERE id = %L$q$, v_gp),
                    'HK_GW_REVERSE_WITH_RECEIPT', 'T13 INV-GW-05 reversing a credited payment needs the receipt cancelled first');
  PERFORM tp_expect(format($q$UPDATE treasury.gateway_payment SET amount = 1 WHERE id = %L$q$, v_gp), 'HK_TRS_IMMUTABLE_FIELD', 'T13 amount immutable');
  -- سناریوی کد ۴۸ ملت: callback → reversed، هرگز verified
  INSERT INTO treasury.gateway_payment (tenant_id, id, company_id, gateway_account_id, provider_code, order_id, amount, api_amount, api_amount_unit, expires_at)
  VALUES (core.current_tenant_id(), v_gm, CA, v_ga, 'zarinpal', 'ORD-000007', 900000, 900000, 'IRR', now() + interval '1 hour');
  UPDATE treasury.gateway_payment SET state = 'redirected', provider_ref = 'A0007' WHERE id = v_gm;
  UPDATE treasury.gateway_payment SET state = 'callback_received', last_response_code = '48' WHERE id = v_gm;
  UPDATE treasury.gateway_payment SET state = 'reversed', failure_reason = 'transaction reversed (code 48)' WHERE id = v_gm;
  PERFORM tp_expect(format($q$UPDATE treasury.gateway_payment SET state = 'verified', provider_txn_ref = 'R7', verified_at = now(), verified_amount = 900000 WHERE id = %L$q$, v_gm),
                    'HK_GW_TRANSITION', 'T13 INV-GW-01 reversed is final');
  -- انقضا و verify دیرهنگام فقط با پرچم
  UPDATE treasury.gateway_payment SET state = 'redirected', provider_ref = 'P0003' WHERE id = v_gm2;
  UPDATE treasury.gateway_payment SET state = 'expired' WHERE id = v_gm2;
  PERFORM tp_expect(format($q$UPDATE treasury.gateway_payment SET state = 'verified', provider_txn_ref = 'R3', verified_at = now(), verified_amount = 50000 WHERE id = %L$q$, v_gm2),
                    'HK_GW_TRANSITION', 'T13 late verification must be flagged');
  UPDATE treasury.gateway_payment SET state = 'verified', provider_txn_ref = 'R3', verified_at = now(), verified_amount = 50000, late_verification = true WHERE id = v_gm2;
  INSERT INTO treasury.gateway_event (tenant_id, gateway_payment_id, kind, outcome, provider_code, response_code)
  VALUES (core.current_tenant_id(), v_gm, 'verify', 'reversed', 'mellat', '48');
  PERFORM tp_expect(format($q$UPDATE treasury.gateway_event SET outcome = 'success' WHERE gateway_payment_id = %L$q$, v_gm),
                    'permission denied|HK_IMMUTABLE', 'T13 gateway log append-only');
END $$;

-- ---------- T14 (INV-BNK-01..07): صورتحساب بانک و مغایرت‌گیری ----------
DO $$
DECLARE CA uuid := '4a000000-0000-7000-8000-0000000000c1'; v_bk uuid := '4a000000-0000-7000-8000-000000000101'; v_bdim uuid;
        v_att uuid := uuidv7(); v_att2 uuid := uuidv7(); v_i1 uuid := uuidv7(); v_i2 uuid := uuidv7(); v_i3 uuid := uuidv7();
        v_j1 uuid; v_j2 uuid; v_l1 uuid; v_l3 uuid; v_m1 uuid := uuidv7();
BEGIN
  PERFORM tp_ctx('A');
  SELECT dimension_value_id INTO v_bdim FROM treasury.bank_account WHERE id = v_bk;
  INSERT INTO core.attachment (tenant_id, id, storage_backend, bucket, object_key, file_name, encryption_key_ref)
  VALUES (core.current_tenant_id(), v_att, 's3', 'hk', 't/' || core.current_tenant_id() || '/2026/04/' || v_att, 'mellat-1405-01.xlsx', 'dek:a'),
         (core.current_tenant_id(), v_att2, 's3', 'hk', 't/' || core.current_tenant_id() || '/2026/04/' || v_att2, 'mellat-1405-02.xls', 'dek:a');
  INSERT INTO treasury.statement_import (tenant_id, id, company_id, bank_account_id, attachment_id, file_sha256, file_kind, amount_unit,
                                         global_profile_code, global_profile_version, opening_balance, closing_balance)
  VALUES (core.current_tenant_id(), v_i1, CA, v_bk, v_att, sha256('file-1'::bytea), 'xlsx', 'IRR', 'generic.split', 1, 5000000, 6150000);
  INSERT INTO treasury.statement_line (tenant_id, id, import_id, bank_account_id, line_no, txn_date, description_raw, debit, credit, balance, dedupe_hash)
  VALUES (core.current_tenant_id(), uuidv7(), v_i1, v_bk, 1, DATE '2026-04-05', 'واريز پايا از مشتري يک', 0, 1000000, 6000000, sha256('l1'::bytea)),
         (core.current_tenant_id(), uuidv7(), v_i1, v_bk, 2, DATE '2026-04-06', 'کارمزد خدمات', 50000, 0, 5950000, sha256('l2'::bytea)),
         (core.current_tenant_id(), uuidv7(), v_i1, v_bk, 3, DATE '2026-04-07', 'تسويه شاپرک پايانه 00012345', 0, 200000, 6150000, sha256('l3'::bytea));
  SELECT id INTO v_l1 FROM treasury.statement_line WHERE import_id = v_i1 AND line_no = 1;
  SELECT id INTO v_l3 FROM treasury.statement_line WHERE import_id = v_i1 AND line_no = 3;
  PERFORM tp_assert((SELECT description_norm FROM treasury.statement_line WHERE id = v_l1) = core.fa_search_key('واریز پایا از مشتری یک'),
                    'T14 INV-BNK-07 description normalized (Arabic ya/kaf)');
  PERFORM tp_expect(format($q$INSERT INTO treasury.statement_line (tenant_id, import_id, bank_account_id, line_no, txn_date, description_raw, debit, credit, dedupe_hash)
                     VALUES (core.current_tenant_id(), %L, %L, 9, DATE '2026-04-05', 'x', 10, 10, sha256('l9'::bytea))$q$, v_i1, v_bk),
                    'statement_line_one_side', 'T14 INV-BNK-01 exactly one of debit/credit');
  PERFORM tp_expect(format($q$INSERT INTO treasury.statement_line (tenant_id, import_id, bank_account_id, line_no, txn_date, description_raw, debit, dedupe_hash)
                     VALUES (core.current_tenant_id(), %L, %L, 9, DATE '2026-04-05', 'x', 10, sha256('l1'::bytea))$q$, v_i1, v_bk),
                    'statement_line_dedupe_uq', 'T14 INV-BNK-02 duplicate line in the same account');
  PERFORM tp_expect(format($q$INSERT INTO treasury.statement_import (tenant_id, company_id, bank_account_id, attachment_id, file_sha256, file_kind, amount_unit)
                     VALUES (core.current_tenant_id(), %L, %L, %L, sha256('file-1'::bytea), 'xls', 'IRR')$q$, CA, v_bk, v_att2),
                    'statement_import_file_uq', 'T14 INV-BNK-02 same file imported twice');
  PERFORM tp_expect(format($q$UPDATE treasury.statement_import SET status = 'committed', committed_at = now() WHERE id = %L$q$, v_i1),
                    'HK_BNK_IMPORT_TRANSITION', 'T14 import must be parsed and validated first');
  UPDATE treasury.statement_import SET status = 'parsed' WHERE id = v_i1;
  UPDATE treasury.statement_import SET status = 'validated' WHERE id = v_i1;
  UPDATE treasury.statement_import SET status = 'committed', committed_at = now() WHERE id = v_i1;
  PERFORM tp_assert((SELECT continuity_ok FROM treasury.statement_import WHERE id = v_i1), 'T14 INV-BNK-03 continuity computed on commit');
  PERFORM tp_expect(format($q$UPDATE treasury.statement_line SET credit = 2000000 WHERE id = %L$q$, v_l1), 'HK_BNK_LINE_STATE', 'T14 INV-BNK-04 committed line immutable');
  PERFORM tp_expect(format($q$DELETE FROM treasury.statement_line WHERE id = %L$q$, v_l1), 'HK_BNK_LINE_STATE', 'T14 INV-BNK-04 committed line not deletable');
  -- ورود دوم با شکست پیوستگی مانده
  INSERT INTO treasury.statement_import (tenant_id, id, company_id, bank_account_id, attachment_id, file_sha256, file_kind, amount_unit, opening_balance)
  VALUES (core.current_tenant_id(), v_i2, CA, v_bk, v_att2, sha256('file-2'::bytea), 'html_xls', 'IRT', 6150000);
  INSERT INTO treasury.statement_line (tenant_id, import_id, bank_account_id, line_no, txn_date, description_raw, debit, credit, balance, dedupe_hash)
  VALUES (core.current_tenant_id(), v_i2, v_bk, 1, DATE '2026-04-08', 'برداشت چک 100002', 300000, 0, 5850000, sha256('m1'::bytea)),
         (core.current_tenant_id(), v_i2, v_bk, 2, DATE '2026-04-09', 'واریز', 0, 100000, 5900000, sha256('m2'::bytea));
  UPDATE treasury.statement_import SET status = 'parsed' WHERE id = v_i2;
  UPDATE treasury.statement_import SET status = 'validated' WHERE id = v_i2;
  PERFORM tp_assert((SELECT count(*) FROM treasury.statement_continuity_breaks(v_i2)) = 1, 'T14 INV-BNK-03 one balance break detected');
  PERFORM tp_expect(format($q$UPDATE treasury.statement_import SET status = 'committed', committed_at = now() WHERE id = %L$q$, v_i2),
                    'HK_BNK_CONTINUITY', 'T14 INV-BNK-03 broken running balance blocks commit');
  PERFORM tp_ok(format($q$UPDATE treasury.statement_import SET status = 'committed', committed_at = now(), continuity_override_reason = 'ردیف حذف‌شده توسط بانک',
                  continuity_overridden_by = '4a000000-0000-7000-8000-00000000a002' WHERE id = %L$q$, v_i2), 'T14 INV-BNK-03 override with reason');
  -- رد ورود دوم ← سطرها جایگزین می‌شوند و همان سطرها دوباره وارد می‌شوند
  UPDATE treasury.statement_import SET status = 'rejected', rejected_reason = 'پروفایل اشتباه' WHERE id = v_i2;
  PERFORM tp_assert((SELECT bool_and(is_superseded) FROM treasury.statement_line WHERE import_id = v_i2), 'T14 rejected import supersedes its lines');
  INSERT INTO treasury.statement_import (tenant_id, id, company_id, bank_account_id, attachment_id, file_sha256, file_kind, amount_unit)
  VALUES (core.current_tenant_id(), v_i3, CA, v_bk, v_att2, sha256('file-2'::bytea), 'html_xls', 'IRR');
  INSERT INTO treasury.statement_line (tenant_id, import_id, bank_account_id, line_no, txn_date, description_raw, debit, credit, dedupe_hash)
  VALUES (core.current_tenant_id(), v_i3, v_bk, 1, DATE '2026-04-08', 'برداشت چک 100002', 300000, 0, sha256('m1'::bytea));
  PERFORM tp_expect(format($q$UPDATE treasury.statement_import SET status = 'parsed', amount_unit = 'IRT' WHERE id = %L$q$, v_i3),
                    'HK_TRS_IMMUTABLE_FIELD', 'T14 INV-BNK-06 declared amount unit immutable');
  -- تطبیق: سطر صورتحساب ↔ سطر دفتر کل حساب بانک
  v_j1 := tp_jr(CA, DATE '2026-04-05', jsonb_build_array(jsonb_build_object('a','1102','dr',1000000,'d1',v_bdim), jsonb_build_object('a','5101','cr',1000000)));
  v_j2 := tp_jr(CA, DATE '2026-04-07', jsonb_build_array(jsonb_build_object('a','1102','dr',150000,'d1',v_bdim), jsonb_build_object('a','5101','cr',150000)));
  INSERT INTO treasury.recon_match (tenant_id, id, company_id, bank_account_id, method, confidence)
  VALUES (core.current_tenant_id(), v_m1, CA, v_bk, 'exact', 1);
  INSERT INTO treasury.recon_match_item (tenant_id, match_id, side, statement_line_id, amount) VALUES (core.current_tenant_id(), v_m1, 'statement', v_l1, 1000000);
  INSERT INTO treasury.recon_match_item (tenant_id, match_id, side, journal_line_id, amount) VALUES (core.current_tenant_id(), v_m1, 'book', tp_jl(v_j1, 1), 1000000);
  PERFORM tp_assert((SELECT match_status FROM treasury.statement_line WHERE id = v_l1) = 'matched', 'T14 INV-BNK-05 line marked matched');
  PERFORM tp_expect(format($q$WITH m AS (INSERT INTO treasury.recon_match (tenant_id, company_id, bank_account_id, method) VALUES (core.current_tenant_id(), %L, %L, 'manual') RETURNING id),
                     a AS (INSERT INTO treasury.recon_match_item (tenant_id, match_id, side, statement_line_id, amount) SELECT core.current_tenant_id(), id, 'statement', %L, 200000 FROM m)
                     INSERT INTO treasury.recon_match_item (tenant_id, match_id, side, journal_line_id, amount) SELECT core.current_tenant_id(), id, 'book', %L, 150000 FROM m$q$,
                     CA, v_bk, v_l3, tp_jl(v_j2, 1)),
                    'HK_BNK_MATCH_UNBALANCED', 'T14 INV-BNK-05 match sides balance');
  PERFORM tp_expect(format($q$WITH m AS (INSERT INTO treasury.recon_match (tenant_id, company_id, bank_account_id, method) VALUES (core.current_tenant_id(), %L, %L, 'manual') RETURNING id)
                     INSERT INTO treasury.recon_match_item (tenant_id, match_id, side, statement_line_id, amount) SELECT core.current_tenant_id(), id, 'statement', %L, 1000000 FROM m$q$,
                     CA, v_bk, v_l1),
                    'recon_item_statement_active_uq', 'T14 INV-BNK-05 a line is in at most one active match');
  PERFORM tp_expect(format($q$WITH m AS (INSERT INTO treasury.recon_match (tenant_id, company_id, bank_account_id, method) VALUES (core.current_tenant_id(), %L, %L, 'manual') RETURNING id)
                     INSERT INTO treasury.recon_match_item (tenant_id, match_id, side, journal_line_id, amount) SELECT core.current_tenant_id(), id, 'book', %L, -150000 FROM m$q$,
                     CA, v_bk, tp_jl(v_j2, 2)),
                    'HK_BNK_MATCH_BOOK', 'T14 INV-BNK-05 book item must be on the bank GL account');
  PERFORM tp_expect(format($q$WITH m AS (INSERT INTO treasury.recon_match (tenant_id, company_id, bank_account_id, method) VALUES (core.current_tenant_id(), %L, %L, 'manual') RETURNING id)
                     INSERT INTO treasury.recon_match_item (tenant_id, match_id, side, statement_line_id, amount) SELECT core.current_tenant_id(), id, 'statement', %L, 100000 FROM m$q$,
                     CA, v_bk, v_l3),
                    'HK_BNK_MATCH_LINE', 'T14 INV-BNK-05 whole statement line amount');
  PERFORM tp_expect(format($q$UPDATE treasury.statement_line SET match_status = 'ignored', ignored_reason = 'x' WHERE id = %L$q$, v_l1),
                    'HK_BNK_MATCH_STATUS', 'T14 a matched line cannot be ignored');
  PERFORM tp_expect(format($q$UPDATE treasury.statement_line SET match_status = 'matched' WHERE id = %L$q$, v_l3),
                    'HK_BNK_MATCH_STATUS', 'T14 matched only via a match');
  PERFORM tp_expect(format($q$UPDATE treasury.recon_match SET method = 'manual' WHERE id = %L$q$, v_m1), 'HK_BNK_MATCH_IMMUTABLE', 'T14 match immutable');
  PERFORM tp_expect(format($q$UPDATE treasury.statement_import SET status = 'rejected', rejected_reason = 'x' WHERE id = %L$q$, v_i1),
                    'HK_BNK_IMPORT_MATCHED', 'T14 matched import cannot be rejected');
  -- صورت مغایرت قطعی: اتحاد مانده‌ها؛ قفل تطبیق‌های تا تاریخ
  PERFORM tp_expect(format($q$INSERT INTO treasury.bank_reconciliation (tenant_id, company_id, bank_account_id, as_of, statement_balance, book_balance,
                     unmatched_statement_signed, unmatched_book_signed, status, finalized_by, finalized_at)
                     VALUES (core.current_tenant_id(), %L, %L, DATE '2026-04-04', 5000000, 0, 0, 0, 'finalized', '4a000000-0000-7000-8000-00000000a002', now())$q$, CA, v_bk),
                    'bank_recon_identity', 'T14 INV-BNK-07 finalized reconciliation identity');
  INSERT INTO treasury.bank_reconciliation (tenant_id, company_id, bank_account_id, as_of, statement_balance, book_balance,
                                            unmatched_statement_signed, unmatched_book_signed, status, finalized_by, finalized_at)
  VALUES (core.current_tenant_id(), CA, v_bk, DATE '2026-04-04', 5000000, 0, 5000000, 0, 'finalized', '4a000000-0000-7000-8000-00000000a002', now());
  PERFORM tp_ok(format($q$UPDATE treasury.recon_match SET status = 'undone', undone_at = now(), undo_reason = 'اشتباه' WHERE id = %L$q$, v_m1),
                'T14 match after the finalized date can be undone');
  INSERT INTO treasury.bank_reconciliation (tenant_id, company_id, bank_account_id, as_of, statement_balance, book_balance,
                                            unmatched_statement_signed, unmatched_book_signed, status, finalized_by, finalized_at)
  VALUES (core.current_tenant_id(), CA, v_bk, DATE '2026-04-10', 6150000, 1150000, 5150000, 150000, 'finalized', '4a000000-0000-7000-8000-00000000a002', now());
  PERFORM tp_expect(format($q$UPDATE treasury.recon_match SET status = 'undone', undone_at = now(), undo_reason = 'اشتباه' WHERE id = %L$q$, v_m1),
                    'HK_BNK_RECON_FINALIZED', 'T14 INV-BNK-07 finalized reconciliation locks its matches');
  PERFORM tp_expect(format($q$UPDATE treasury.bank_reconciliation SET statement_balance = 1 WHERE as_of = DATE '2026-04-10' AND bank_account_id = %L$q$, v_bk),
                    'HK_BNK_RECON_FINALIZED', 'T14 finalized reconciliation immutable');
  PERFORM tp_expect(format($q$INSERT INTO treasury.recon_rule (tenant_id, company_id, name, pattern, action) VALUES (core.current_tenant_id(), %L, 'r', 'کارمزد(', 'suggest')$q$, CA),
                    'HK_BNK_RULE_PATTERN', 'T14 rule pattern must compile');
  PERFORM tp_expect(format($q$INSERT INTO treasury.recon_rule (tenant_id, company_id, name, pattern, action) VALUES (core.current_tenant_id(), %L, 'r', 'کارمزد', 'auto_post')$q$, CA),
                    'recon_rule_auto_post', 'T14 auto-post rule names its account');
  INSERT INTO treasury.recon_rule (tenant_id, company_id, name, pattern, action, posting_key, direction)
  VALUES (core.current_tenant_id(), CA, 'کارمزد بانکی', 'کارمزد', 'auto_post', 'treasury.bank_fee', 'out');
END $$;

-- ---------- T15 (INV-POS-01): پایانهٔ صندوق ----------
DO $$
DECLARE CA uuid := '4a000000-0000-7000-8000-0000000000c1'; BA uuid := '4a000000-0000-7000-8000-0000000000b1';
        v_cb uuid := '4a000000-0000-7000-8000-000000000201'; v_cb3 uuid := '4a000000-0000-7000-8000-000000000203';
        DA1 uuid := '4a000000-0000-7000-8000-0000000000d1'; DA2 uuid := '4a000000-0000-7000-8000-0000000000d2';
        DA3 uuid := '4a000000-0000-7000-8000-0000000000d3'; PW uuid := '4a000000-0000-7000-8000-0000000000e3';
        PC uuid := '4a000000-0000-7000-8000-0000000000e1'; T1 uuid := '4a000000-0000-7000-8000-000000000701';
        T2 uuid := '4a000000-0000-7000-8000-000000000702';
BEGIN
  PERFORM tp_ctx('A');
  INSERT INTO treasury.cash_box (tenant_id, id, company_id, branch_id, code, name, kind)
  VALUES (core.current_tenant_id(), v_cb3, CA, BA, 'POS2', 'کشوی صندوق ۲', 'pos_drawer');
  PERFORM tp_expect(format($q$INSERT INTO pos.terminal (tenant_id, company_id, branch_id, code, name, device_id, cash_box_id, receipt_series_id, walk_in_party_id)
                     VALUES (core.current_tenant_id(), %L, %L, 'TX', 'x', %L, %L, '4a000000-0000-7000-8000-000000000501', %L)$q$, CA, BA, DA3, v_cb, PW),
                    'HK_POS_TERMINAL_DEVICE', 'T15 INV-POS-01 device of another branch');
  PERFORM tp_expect(format($q$INSERT INTO pos.terminal (tenant_id, company_id, branch_id, code, name, device_id, cash_box_id, receipt_series_id, walk_in_party_id)
                     VALUES (core.current_tenant_id(), %L, %L, 'TX', 'x', %L, %L, '4a000000-0000-7000-8000-000000000502', %L)$q$, CA, BA, DA1, v_cb, PW),
                    'HK_POS_TERMINAL_SERIES', 'T15 INV-POS-02 receipt series must be the device pos.ticket series');
  PERFORM tp_expect(format($q$INSERT INTO pos.terminal (tenant_id, company_id, branch_id, code, name, device_id, cash_box_id, receipt_series_id, walk_in_party_id)
                     VALUES (core.current_tenant_id(), %L, %L, 'TX', 'x', %L, '4a000000-0000-7000-8000-000000000202', '4a000000-0000-7000-8000-000000000501', %L)$q$, CA, BA, DA1, PW),
                    'HK_POS_TERMINAL_CASH_BOX', 'T15 terminal uses a pos_drawer cash box');
  PERFORM tp_expect(format($q$INSERT INTO pos.terminal (tenant_id, company_id, branch_id, code, name, device_id, cash_box_id, receipt_series_id, walk_in_party_id)
                     VALUES (core.current_tenant_id(), %L, %L, 'TX', 'x', %L, %L, '4a000000-0000-7000-8000-000000000501', %L)$q$, CA, BA, DA1, v_cb, PC),
                    'HK_POS_TERMINAL_WALK_IN', 'T15 walk-in customer is anonymous');
  PERFORM tp_expect(format($q$INSERT INTO pos.terminal (tenant_id, company_id, branch_id, code, name, device_id, cash_box_id, receipt_series_id, walk_in_party_id, tax_mode)
                     VALUES (core.current_tenant_id(), %L, %L, 'TX', 'x', %L, %L, '4a000000-0000-7000-8000-000000000501', %L, 'device_memory')$q$, CA, BA, DA1, v_cb, PW),
                    'terminal_tax_memory', 'T15 offline tax mode names its memory');
  INSERT INTO pos.terminal (tenant_id, id, company_id, branch_id, code, name, device_id, cash_box_id, receipt_series_id, walk_in_party_id,
                            default_card_terminal_id, service_modes)
  VALUES (core.current_tenant_id(), T1, CA, BA, 'T1', 'صندوق ۱', DA1, v_cb, '4a000000-0000-7000-8000-000000000501', PW,
          '4a000000-0000-7000-8000-000000000301', '{retail,dine_in,takeaway}'),
         (core.current_tenant_id(), T2, CA, BA, 'T2', 'تبلت گارسون', DA2, v_cb3, '4a000000-0000-7000-8000-000000000503', PW, NULL, '{dine_in}');
  PERFORM tp_expect(format($q$INSERT INTO pos.terminal (tenant_id, company_id, branch_id, code, name, device_id, cash_box_id, receipt_series_id, walk_in_party_id)
                     VALUES (core.current_tenant_id(), %L, %L, 'T9', 'x', %L, %L, '4a000000-0000-7000-8000-000000000501', %L)$q$, CA, BA, DA1, v_cb, PW),
                    'terminal_device_active_uq|terminal_cash_box_active_uq', 'T15 INV-POS-01 one active terminal per device and per drawer');
  PERFORM tp_expect(format($q$UPDATE pos.terminal SET branch_id = '4a000000-0000-7000-8000-0000000000b2' WHERE id = %L$q$, T1), 'HK_TRS_IMMUTABLE_FIELD', 'T15 branch fixed');
  INSERT INTO pos.device_sync_state (tenant_id, device_id, terminal_id, last_hash)
  VALUES (core.current_tenant_id(), DA1, T1, pos.genesis_hash(DA1)), (core.current_tenant_id(), DA2, T2, pos.genesis_hash(DA2));
  PERFORM tp_expect(format($q$INSERT INTO pos.device_sync_state (tenant_id, device_id, last_hash) VALUES (core.current_tenant_id(), %L, %L)$q$,
                     DA3, pos.genesis_hash(DA1)),
                    'HK_SYNC_STATE_INIT', 'T15 INV-SYNC-01 chain starts at the device genesis hash');
END $$;

-- ---------- T16 (INV-POS-03/04): روز کاری، شیفت، جابه‌جایی نقد ----------
DO $$
DECLARE CA uuid := '4a000000-0000-7000-8000-0000000000c1'; BA uuid := '4a000000-0000-7000-8000-0000000000b1';
        T1 uuid := '4a000000-0000-7000-8000-000000000701'; v_cb uuid := '4a000000-0000-7000-8000-000000000201';
        BD uuid := '4a000000-0000-7000-8000-000000000801'; S1 uuid := '4a000000-0000-7000-8000-000000000901';
        U1 uuid := '4a000000-0000-7000-8000-00000000a001';
BEGIN
  PERFORM tp_ctx('A');
  INSERT INTO pos.business_day (tenant_id, id, company_id, branch_id, business_date, opened_at, opened_by)
  VALUES (core.current_tenant_id(), BD, CA, BA, DATE '2026-04-05', timestamptz '2026-04-05 08:00+03:30', U1);
  PERFORM tp_expect(format($q$INSERT INTO pos.business_day (tenant_id, company_id, branch_id, business_date, opened_at) VALUES (core.current_tenant_id(), %L, %L, DATE '2026-04-06', now())$q$, CA, BA),
                    'business_day_one_open_uq', 'T16 INV-POS-04 one open business day per branch');
  INSERT INTO pos.shift (tenant_id, id, company_id, branch_id, terminal_id, business_day_id, cash_box_id, opened_by, opened_at, opening_float, open_cmd_id)
  VALUES (core.current_tenant_id(), S1, CA, BA, T1, BD, v_cb, U1, timestamptz '2026-04-05 08:05+03:30', 2000000, uuidv7());
  PERFORM tp_expect(format($q$INSERT INTO pos.shift (tenant_id, id, company_id, branch_id, terminal_id, business_day_id, cash_box_id, opened_by, opened_at, opening_float, open_cmd_id)
                     VALUES (core.current_tenant_id(), uuidv7(), %L, %L, %L, %L, %L, %L, now(), 0, uuidv7())$q$, CA, BA, T1, BD, v_cb, U1),
                    'shift_one_open_uq', 'T16 INV-POS-03 one open shift per terminal');
  PERFORM tp_expect(format($q$INSERT INTO pos.shift (tenant_id, id, company_id, branch_id, terminal_id, business_day_id, cash_box_id, opened_by, opened_at, opening_float, open_cmd_id)
                     VALUES (core.current_tenant_id(), uuidv7(), %L, %L, '4a000000-0000-7000-8000-000000000702', %L, %L, %L, now(), 0, uuidv7())$q$, CA, BA, BD, v_cb, U1),
                    'HK_POS_SHIFT_CONTEXT', 'T16 shift uses its terminal cash box');
  PERFORM tp_expect(format($q$UPDATE pos.business_day SET status = 'closed', closed_at = now() WHERE id = %L$q$, BD),
                    'HK_POS_DAY_OPEN_SHIFTS', 'T16 INV-POS-04 close shifts before the business day');
  PERFORM tp_expect(format($q$INSERT INTO pos.cash_movement (tenant_id, id, shift_id, kind, amount, reason, occurred_at, cmd_id) VALUES (core.current_tenant_id(), uuidv7(), %L, 'drop', 10, 'انتقال', now(), uuidv7())$q$, S1),
                    'cash_movement_target', 'T16 drop names the target cash box');
  PERFORM tp_expect(format($q$INSERT INTO pos.cash_movement (tenant_id, id, shift_id, kind, amount, reason, occurred_at, cmd_id) VALUES (core.current_tenant_id(), uuidv7(), %L, 'pay_out', 10, 'خرید نان', now(), uuidv7())$q$, S1),
                    'cash_movement_counter', 'T16 pay-out names its counter account');
  INSERT INTO pos.cash_movement (tenant_id, id, shift_id, kind, amount, reason, occurred_at, posting_key, cmd_id)
  VALUES (core.current_tenant_id(), uuidv7(), S1, 'pay_out', 80000, 'خرید یخ', now(), 'purchase.expense', uuidv7());
  PERFORM tp_expect(format($q$UPDATE pos.cash_movement SET amount = 1 WHERE shift_id = %L$q$, S1), 'HK_TRS_IMMUTABLE_FIELD', 'T16 cash movement immutable');
  PERFORM tp_expect(format($q$UPDATE pos.shift SET opening_float = 1 WHERE id = %L$q$, S1), 'HK_TRS_IMMUTABLE_FIELD', 'T16 opening data fixed');
END $$;

-- ---------- T17 (INV-SYNC-01..07): فرمان امضاشده، زنجیره، ترتیب، دستگاه باطل‌شده، نتیجه ----------
DO $$
DECLARE DA1 uuid := '4a000000-0000-7000-8000-0000000000d1'; DA2 uuid := '4a000000-0000-7000-8000-0000000000d2';
        v_b uuid; v_b2 uuid; v_c1 uuid; v_c2 uuid; v_body text; v_id1 uuid; v_id2 uuid; v_cmd uuid := uuidv7(); v_rev timestamptz;
BEGIN
  PERFORM tp_ctx('A');
  v_b := tp_batch(DA1, 1, 3);
  v_c1 := tp_cmd(DA1, 'device.clock_report', '{"ntp_ok": true}', v_b);
  PERFORM tp_assert((SELECT last_seq FROM pos.device_sync_state WHERE device_id = DA1) = 1
                    AND (SELECT status FROM pos.command_outcome o JOIN pos.device_command c ON c.id = o.command_id WHERE c.cmd_id = v_c1) = 'pending',
                    'T17 INV-SYNC-05 command stored, head advanced, outcome pending');
  PERFORM tp_expect(format($q$SELECT tp_cmd(%L, 'device.clock_report', '{}', %L, now(), NULL, 3)$q$, DA1, v_b),
                    'HK_SYNC_SEQ_GAP', 'T17 INV-SYNC-01 contiguous device_seq');
  PERFORM tp_expect(format($q$SELECT tp_cmd(%L, 'device.clock_report', '{}', %L, now(), NULL, NULL, sha256('forged'::bytea))$q$, DA1, v_b),
                    'HK_SYNC_CHAIN_BROKEN', 'T17 INV-SYNC-01 prev_hash links to the stored head');
  PERFORM tp_expect(format($q$SELECT tp_cmd(%L, 'no.such_type', '{}', %L)$q$, DA1, v_b), 'foreign key|violates', 'T17 INV-SYNC-08 command type must be known');
  PERFORM tp_expect(format($q$SELECT tp_cmd(%L, 'device.clock_report', '{}', %L, now(), %L)$q$, DA1, v_b, v_c1),
                    'device_command_tenant_id_cmd_id_key', 'T17 INV-SYNC-02 cmd_id unique (idempotency key)');
  -- hash باید sha256 بدنه باشد؛ ستون‌ها باید با بدنه بخوانند
  v_body := tp_body(DA1, 2, v_cmd, 'device.clock_report', now(), (SELECT last_hash FROM pos.device_sync_state WHERE device_id = DA1), '{}');
  PERFORM tp_expect(format($q$INSERT INTO pos.device_command (tenant_id, device_id, device_seq, cmd_id, type, schema_version, occurred_at, body, prev_hash, hash, sig, sig_alg, batch_id)
                     VALUES (core.current_tenant_id(), %L, 2, %L, 'device.clock_report', 1, (%L::jsonb ->> 'occurred_at')::timestamptz, %L, %L, sha256('x'::bytea), decode(repeat('ab', 64), 'hex'), 'ed25519', %L)$q$,
                     DA1, v_cmd, v_body, v_body, (SELECT last_hash FROM pos.device_sync_state WHERE device_id = DA1), v_b),
                    'device_command_hash', 'T17 INV-SYNC-02 hash = sha256(body)');
  PERFORM tp_expect(format($q$INSERT INTO pos.device_command (tenant_id, device_id, device_seq, cmd_id, type, schema_version, occurred_at, body, prev_hash, hash, sig, sig_alg, batch_id)
                     VALUES (core.current_tenant_id(), %L, 2, uuidv7(), 'device.clock_report', 1, (%L::jsonb ->> 'occurred_at')::timestamptz, %L, %L, sha256(convert_to(%L, 'UTF8')), decode(repeat('ab', 64), 'hex'), 'ed25519', %L)$q$,
                     DA1, v_body, v_body, (SELECT last_hash FROM pos.device_sync_state WHERE device_id = DA1), v_body, v_b),
                    'HK_SYNC_BODY_MISMATCH', 'T17 INV-SYNC-02 columns equal the signed body');
  PERFORM tp_expect(format($q$INSERT INTO pos.device_command (tenant_id, device_id, device_seq, cmd_id, type, schema_version, occurred_at, body, prev_hash, hash, sig, sig_alg, batch_id)
                     VALUES (core.current_tenant_id(), %L, 2, %L, 'device.clock_report', 1, (%L::jsonb ->> 'occurred_at')::timestamptz, %L, %L, sha256(convert_to(%L, 'UTF8')), decode(repeat('ab', 64), 'hex'), 'ecdsa_p256', %L)$q$,
                     DA1, v_cmd, v_body, v_body, (SELECT last_hash FROM pos.device_sync_state WHERE device_id = DA1), v_body, v_b),
                    'HK_SYNC_DEVICE_REVOKED', 'T17 signature algorithm must be the device key algorithm');
  v_c2 := tp_cmd(DA1, 'device.clock_report', '{"ntp_ok": false}', v_b);
  PERFORM tp_expect(format($q$UPDATE pos.device_command SET body = body WHERE cmd_id = %L$q$, v_c1), 'permission denied|HK_IMMUTABLE', 'T17 INV-SYNC-03 commands append-only');
  PERFORM tp_expect(format($q$UPDATE pos.device_sync_state SET last_seq = 9 WHERE device_id = %L$q$, DA1), 'HK_SYNC_STATE_ADVANCE', 'T17 INV-SYNC-07 head advances only with commands');
  PERFORM tp_expect(format($q$SELECT tp_cmd(%L, 'device.clock_report', '{}', %L)$q$, DA1, tp_batch(DA2, 1, 1)), 'HK_SYNC_BATCH_MISMATCH', 'T17 command belongs to its batch device');
  PERFORM tp_assert(NOT EXISTS (SELECT 1 FROM pos.verify_device_chain(DA1)), 'T17 INV-SYNC-01 independent chain verification is clean');
  -- ترتیب پردازش و حل «نیازمند بررسی»
  SELECT o.id INTO v_id1 FROM pos.command_outcome o WHERE o.device_id = DA1 AND o.device_seq = 1;
  SELECT o.id INTO v_id2 FROM pos.command_outcome o WHERE o.device_id = DA1 AND o.device_seq = 2;
  PERFORM tp_expect(format($q$UPDATE pos.command_outcome SET status = 'applied', processed_at = now() WHERE id = %L$q$, v_id2),
                    'HK_SYNC_OUT_OF_ORDER', 'T17 INV-SYNC-06 processed in device_seq order');
  UPDATE pos.command_outcome SET status = 'applied', processed_at = now() WHERE id = v_id1;
  PERFORM tp_expect(format($q$UPDATE pos.command_outcome SET status = 'review', processed_at = now() WHERE id = %L$q$, v_id2), 'outcome_error', 'T17 review needs an error code');
  UPDATE pos.command_outcome SET status = 'review', processed_at = now(), error_code = 'pos.sync.clock_skew' WHERE id = v_id2;
  PERFORM tp_expect(format($q$UPDATE pos.command_outcome SET status = 'applied' WHERE id = %L$q$, v_id2), 'HK_SYNC_REVIEW_RESOLUTION', 'T17 review resolution needs resolver and note');
  UPDATE pos.command_outcome SET status = 'applied', resolved_by = '4a000000-0000-7000-8000-00000000a002', resolved_at = now(),
         resolution_note = 'ساعت دستگاه اصلاح شد' WHERE id = v_id2;
  PERFORM tp_expect(format($q$UPDATE pos.command_outcome SET status = 'rejected' WHERE id = %L$q$, v_id1), 'HK_SYNC_OUTCOME', 'T17 final outcomes immutable');
  PERFORM tp_expect(format($q$INSERT INTO pos.command_outcome (tenant_id, command_id, device_id, device_seq, status, processed_at)
                     SELECT tenant_id, id, device_id, device_seq, 'applied', now() FROM pos.device_command WHERE cmd_id = %L$q$, v_c1),
                    'HK_SYNC_OUTCOME|command_outcome_tenant_id_command_id_key', 'T17 outcome rows are created by the command trigger only');
  -- دستگاه باطل‌شده: فرمان پیش از ابطال پذیرفته، پس از آن رد
  v_rev := now();
  UPDATE core.device SET status = 'revoked', revoked_at = v_rev, revoke_reason = 'گم شد' WHERE id = DA2;
  v_b2 := tp_batch(DA2, 1, 2);
  PERFORM tp_cmd(DA2, 'device.clock_report', '{}', v_b2, v_rev - interval '1 hour');
  PERFORM tp_expect(format($q$SELECT tp_cmd(%L, 'device.clock_report', '{}', %L, %L::timestamptz + interval '1 minute')$q$, DA2, v_b2, v_rev),
                    'HK_SYNC_DEVICE_REVOKED', 'T17 INV-SYNC-04 commands after revocation rejected');
  UPDATE pos.device_sync_state SET status = 'quarantined', quarantine_reason = 'fork detected' WHERE device_id = DA2;
  PERFORM tp_expect(format($q$SELECT tp_cmd(%L, 'device.clock_report', '{}', %L, %L::timestamptz - interval '1 minute')$q$, DA2, v_b2, v_rev),
                    'HK_SYNC_QUARANTINED', 'T17 quarantined device stops ingestion');
END $$;

-- ---------- T18 (INV-POS-05..09): رسید تغییرناپذیر از فرمان امضاشده؛ جمع‌ها؛ مرجوعی؛ تقسیم صورتحساب ----------
RESET ROLE;
CREATE OR REPLACE FUNCTION public.tp_ticket(p_kind text, p_no int, p_lines jsonb, p_payments jsonb, p_total numeric, p_tax numeric,
                                            p_tip numeric DEFAULT 0, p_original uuid DEFAULT NULL, p_cmd_type text DEFAULT NULL,
                                            p_subtotal numeric DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE CA uuid := '4a000000-0000-7000-8000-0000000000c1'; BA uuid := '4a000000-0000-7000-8000-0000000000b1';
        DA1 uuid := '4a000000-0000-7000-8000-0000000000d1'; v_t uuid := uuidv7(); v_cmd uuid; v_num uuid; v_sub numeric;
BEGIN
  v_cmd := tp_cmd(DA1, coalesce(p_cmd_type, p_kind || '.completed'), jsonb_build_object('ticket_id', v_t), tp_batch(DA1, (SELECT last_seq + 1 FROM pos.device_sync_state WHERE device_id = DA1), 1));
  v_num := core.number_record_external('4a000000-0000-7000-8000-000000000501', 'all', p_no, 'R1-' || lpad(p_no::text, 6, '0'), 'pos.ticket', v_t, DA1);
  SELECT coalesce(sum(CASE l->>'dir' WHEN 'return' THEN -((l->>'net')::numeric) ELSE (l->>'net')::numeric END), 0) INTO v_sub FROM jsonb_array_elements(p_lines) l;
  INSERT INTO pos.ticket (tenant_id, id, company_id, branch_id, terminal_id, shift_id, business_day_id, device_id, cmd_id, kind, order_type, ticket_no,
                          number_issued_id, original_ticket_id, customer_party_id, subtotal, tax_total, tip_amount, total, occurred_at, cashier_user_id)
  VALUES (core.current_tenant_id(), v_t, CA, BA, '4a000000-0000-7000-8000-000000000701', '4a000000-0000-7000-8000-000000000901',
          '4a000000-0000-7000-8000-000000000801', DA1, v_cmd, p_kind, 'retail', 'R1-' || lpad(p_no::text, 6, '0'), v_num, p_original,
          '4a000000-0000-7000-8000-0000000000e3', coalesce(p_subtotal, v_sub), p_tax, p_tip, p_total, now(), '4a000000-0000-7000-8000-00000000a001');
  INSERT INTO pos.ticket_line (tenant_id, ticket_id, line_no, direction, item_id, variant_id, uom_id, qty, unit_price, price_source, line_gross, line_net,
                               tax_amount, parent_line_no, original_line_id, open_order_line_id)
  SELECT core.current_tenant_id(), v_t, (l->>'no')::smallint, coalesce(l->>'dir', 'sale'), (l->>'item')::uuid, (l->>'var')::uuid,
         '4a000000-0000-7000-8000-0000000000f1', (l->>'qty')::numeric, (l->>'price')::numeric, coalesce(l->>'src', 'list'),
         coalesce((l->>'gross')::numeric, (l->>'net')::numeric), (l->>'net')::numeric, coalesce((l->>'tax')::numeric, 0),
         (l->>'parent')::smallint, (l->>'orig')::uuid, (l->>'ool')::uuid
    FROM jsonb_array_elements(p_lines) l;
  INSERT INTO pos.ticket_payment (tenant_id, ticket_id, line_no, method, amount, tendered, change_given, card_terminal_id, card_result, rrn)
  SELECT core.current_tenant_id(), v_t, o.ord::smallint, x->>'m', (x->>'amt')::numeric, (x->>'tend')::numeric, coalesce((x->>'chg')::numeric, 0),
         CASE WHEN x->>'m' = 'card_pos' THEN '4a000000-0000-7000-8000-000000000301'::uuid END,
         CASE WHEN x->>'m' = 'card_pos' THEN 'approved' END, x->>'rrn'
    FROM jsonb_array_elements(p_payments) WITH ORDINALITY o(x, ord);
  RETURN v_t;
END $$;
GRANT EXECUTE ON FUNCTION public.tp_ticket(text, int, jsonb, jsonb, numeric, numeric, numeric, uuid, text, numeric) TO hk_app;
SET ROLE hk_app;

DO $$
DECLARE ESP uuid := '4a000000-0000-7000-8000-0000000000f2'; ESPV uuid := '4a000000-0000-7000-8000-0000000000f3';
        SHOT uuid := '4a000000-0000-7000-8000-0000000000f4'; SHOTV uuid := '4a000000-0000-7000-8000-0000000000f5';
        v_t1 uuid; v_r uuid; v_l1 uuid; v_lines jsonb; v_pays jsonb;
BEGIN
  PERFORM tp_ctx('A');
  -- فروش: ۲ اسپرسو × ۴۵۰٬۰۰۰ + شات اضافه (modifier)، مالیات ۱۰۰٬۰۰۰، انعام ۵۰٬۰۰۰؛ پرداخت نقد (با باقی‌مانده) + کارت
  v_lines := jsonb_build_array(
    jsonb_build_object('no',1,'item',ESP,'var',ESPV,'qty',2,'price',450000,'net',900000,'tax',90000),
    jsonb_build_object('no',2,'item',SHOT,'var',SHOTV,'qty',1,'price',100000,'net',100000,'tax',10000,'parent',1,'src','modifier'));
  v_pays := '[{"m":"cash","amt":650000,"tend":700000,"chg":50000},{"m":"card_pos","amt":500000,"rrn":"000000009999"}]';
  v_t1 := tp_ticket('sale', 1, v_lines, v_pays, 1100000, 100000, 50000);
  PERFORM tp_expect(format($q$SELECT tp_ticket('sale', 2, %L, %L, 1100001, 100000, 50000)$q$, v_lines, '[{"m":"cash","amt":1150001,"tend":1150001}]'),
                    'HK_POS_TICKET_TOTALS', 'T18 INV-POS-05 ticket total = lines - discount + service + tax + rounding');
  PERFORM tp_expect(format($q$SELECT tp_ticket('sale', 2, %L, %L, 1100000, 100000, 50000)$q$, v_lines, '[{"m":"cash","amt":1100000,"tend":1100000}]'),
                    'HK_POS_TICKET_PAYMENTS', 'T18 INV-POS-05 payments = total + tip');
  PERFORM tp_expect(format($q$SELECT tp_ticket('sale', 2, %L, %L, 1000000, 0)$q$,
                     jsonb_build_array(jsonb_build_object('no',1,'item',ESP,'var',ESPV,'qty',2,'price',450000,'net',1000000)), '[{"m":"cash","amt":1000000,"tend":1000000}]'),
                    'HK_POS_TICKET_LINES', 'T18 INV-POS-05 line gross = trunc(qty x price)');
  PERFORM tp_expect(format($q$SELECT tp_ticket('sale', 2, %L, %L, 1100000, 100000, 50000)$q$, v_lines, '[{"m":"card_pos","amt":-1},{"m":"cash","amt":1150001,"tend":1150001}]'),
                    'payment_card_no_refund', 'T18 INV-POS-07 no card refunds at the POS');
  PERFORM tp_expect(format($q$SELECT tp_ticket('sale', 2, %L, %L, 1100000, 100000, 50000, NULL, 'shift.opened')$q$, v_lines, v_pays),
                    'HK_POS_TICKET_SOURCE', 'T18 INV-POS-06 ticket comes from a matching sale command');
  PERFORM tp_expect(format($q$SELECT tp_ticket('sale', 1, %L, %L, 1100000, 100000, 50000)$q$, v_lines, v_pays),
                    'number_issued|duplicate key', 'T18 INV-POS-06 device receipt number used once');
  -- تغییرناپذیری و ثبت
  PERFORM tp_expect(format($q$UPDATE pos.ticket SET total = 1 WHERE id = %L$q$, v_t1), 'HK_POS_TICKET_IMMUTABLE', 'T18 INV-POS-08 ticket immutable');
  PERFORM tp_expect(format($q$UPDATE pos.ticket SET posting_status = 'posted', posted_at = now() WHERE id = %L$q$, v_t1), 'ticket_posted', 'T18 posted ticket names its sales document');
  UPDATE pos.ticket SET posting_status = 'review' WHERE id = v_t1;
  PERFORM tp_expect(format($q$UPDATE pos.ticket SET posting_status = 'pending' WHERE id = %L$q$, v_t1), 'HK_POS_TICKET_POSTING', 'T18 posting status forward only');
  UPDATE pos.ticket SET posting_status = 'posted', posted_at = now(), sales_doc_id = uuidv7() WHERE id = v_t1;
  PERFORM tp_expect(format($q$UPDATE pos.ticket SET sales_doc_id = uuidv7() WHERE id = %L$q$, v_t1), 'HK_POS_TICKET_IMMUTABLE', 'T18 posting links set once');
  PERFORM tp_expect(format($q$DELETE FROM pos.ticket WHERE id = %L$q$, v_t1), 'permission denied|HK_IMMUTABLE', 'T18 ticket not deletable');
END $$;

-- خط و پرداخت رسید در تراکنش دیگر نوشته نمی‌شود؛ مرجوعی و سقف آن
DO $$
DECLARE ESP uuid := '4a000000-0000-7000-8000-0000000000f2'; ESPV uuid := '4a000000-0000-7000-8000-0000000000f3';
        v_t1 uuid; v_l1 uuid; v_r uuid;
BEGIN
  PERFORM tp_ctx('A');
  SELECT id INTO v_t1 FROM pos.ticket WHERE ticket_no = 'R1-000001';
  SELECT id INTO v_l1 FROM pos.ticket_line WHERE ticket_id = v_t1 AND line_no = 1;
  PERFORM tp_expect(format($q$INSERT INTO pos.ticket_line (tenant_id, ticket_id, line_no, direction, item_id, variant_id, uom_id, qty, unit_price, price_source, line_gross, line_net)
                     VALUES (core.current_tenant_id(), %L, 9, 'sale', %L, %L, '4a000000-0000-7000-8000-0000000000f1', 1, 0, 'zero', 0, 0)$q$, v_t1, ESP, ESPV),
                    'HK_POS_TICKET_IMMUTABLE', 'T18 INV-POS-08 lines are written only with their ticket');
  PERFORM tp_expect(format($q$UPDATE pos.ticket_payment SET amount = 1 WHERE ticket_id = %L AND line_no = 1$q$, v_t1), 'HK_POS_TICKET_IMMUTABLE', 'T18 payments immutable');
  UPDATE pos.ticket_payment SET card_txn_id = NULL WHERE false;
  -- مرجوعی یک اسپرسو (۴۵۰٬۰۰۰ + ۴۵٬۰۰۰ مالیات)
  v_r := tp_ticket('return', 2, jsonb_build_array(jsonb_build_object('no',1,'dir','return','item',ESP,'var',ESPV,'qty',1,'price',450000,'net',450000,'tax',45000,'orig',v_l1)),
                   '[{"m":"cash","amt":-495000}]', -495000, -45000, 0, v_t1);
  PERFORM tp_assert((SELECT kind FROM pos.ticket WHERE id = v_r) = 'return', 'T18 return ticket stored');
  PERFORM tp_expect(format($q$SELECT tp_ticket('return', 3, %L, '[{"m":"cash","amt":-990000}]', -990000, -90000, 0, %L)$q$,
                     jsonb_build_array(jsonb_build_object('no',1,'dir','return','item',ESP,'var',ESPV,'qty',2,'price',450000,'net',900000,'tax',90000,'orig',v_l1)), v_t1),
                    'HK_POS_RETURN_EXCEEDS', 'T18 INV-POS-09 returned quantity never exceeds the sale');
  PERFORM tp_expect(format($q$SELECT tp_ticket('return', 3, %L, '[{"m":"cash","amt":495000,"tend":495000}]', 495000, 45000, 0, %L)$q$,
                     jsonb_build_array(jsonb_build_object('no',1,'dir','sale','item',ESP,'var',ESPV,'qty',1,'price',450000,'net',450000,'tax',45000)), v_t1),
                    'ticket_sign|HK_POS_TICKET_LINES', 'T18 return ticket carries return lines with non-positive totals');
END $$;

-- ---------- T19 (INV-POS-10/11, INV-SYNC-09): سفارش باز رستوران، تقسیم صورتحساب، جریان‌ها ----------
DO $$
DECLARE CA uuid := '4a000000-0000-7000-8000-0000000000c1'; BA uuid := '4a000000-0000-7000-8000-0000000000b1';
        T1 uuid := '4a000000-0000-7000-8000-000000000701'; ESP uuid := '4a000000-0000-7000-8000-0000000000f2';
        ESPV uuid := '4a000000-0000-7000-8000-0000000000f3'; v_fl uuid := uuidv7(); v_tb uuid := uuidv7(); v_o uuid := uuidv7();
        v_ol1 uuid := uuidv7(); v_ol2 uuid := uuidv7(); v_scope text := 'branch:4a000000-0000-7000-8000-0000000000b1'; v_ver bigint;
BEGIN
  PERFORM tp_ctx('A');
  INSERT INTO pos.floor (tenant_id, id, company_id, branch_id, code, name) VALUES (core.current_tenant_id(), v_fl, CA, BA, 'F1', 'سالن');
  INSERT INTO pos.dining_table (tenant_id, id, floor_id, code, seats) VALUES (core.current_tenant_id(), v_tb, v_fl, 'T7', 4);
  PERFORM tp_expect(format($q$INSERT INTO pos.open_order (tenant_id, id, company_id, branch_id, terminal_id, order_type, opened_at, last_cmd_id)
                     VALUES (core.current_tenant_id(), uuidv7(), %L, %L, %L, 'dine_in', now(), uuidv7())$q$, CA, BA, T1),
                    'open_order_table', 'T19 dine-in order names its table');
  INSERT INTO pos.open_order (tenant_id, id, company_id, branch_id, terminal_id, table_id, order_type, guest_count, opened_at, last_cmd_id)
  VALUES (core.current_tenant_id(), v_o, CA, BA, T1, v_tb, 'dine_in', 2, now(), uuidv7());
  INSERT INTO pos.open_order_line (tenant_id, id, order_id, line_no, item_id, variant_id, uom_id, qty, unit_price, seat_no) VALUES
    (core.current_tenant_id(), v_ol1, v_o, 1, ESP, ESPV, '4a000000-0000-7000-8000-0000000000f1', 2, 450000, 1),
    (core.current_tenant_id(), v_ol2, v_o, 2, ESP, ESPV, '4a000000-0000-7000-8000-0000000000f1', 1, 450000, 2);
  PERFORM tp_expect(format($q$UPDATE pos.open_order SET guest_count = 3 WHERE id = %L$q$, v_o), 'HK_POS_ORDER_VERSION', 'T19 INV-POS-10 every change advances the version');
  UPDATE pos.open_order SET guest_count = 3, version = 2 WHERE id = v_o;
  UPDATE pos.open_order_line SET status = 'sent', sent_at = now() WHERE id = v_ol2;
  PERFORM tp_expect(format($q$DELETE FROM pos.open_order_line WHERE id = %L$q$, v_ol2), 'HK_POS_ORDER_LINE_SENT', 'T19 INV-POS-10 sent line is voided, never deleted');
  PERFORM tp_expect(format($q$UPDATE pos.open_order_line SET qty = 3 WHERE id = %L$q$, v_ol2), 'HK_POS_ORDER_LINE_SENT', 'T19 sent line quantity fixed');
  PERFORM tp_expect(format($q$UPDATE pos.open_order_line SET status = 'voided' WHERE id = %L$q$, v_ol2), 'open_line_void', 'T19 void needs a reason');
  UPDATE pos.open_order_line SET status = 'voided', void_reason = 'مشتری منصرف شد' WHERE id = v_ol2;
  PERFORM tp_assert((SELECT voided_after_send FROM pos.open_order_line WHERE id = v_ol2), 'T19 INV-POS-10 waste flag derived for voided-after-send');
  -- تقسیم صورتحساب: سطر ۲تایی بین دو رسید؛ رسید سوم بیش از مقدار
  PERFORM tp_ticket('sale', 10, jsonb_build_array(jsonb_build_object('no',1,'item',ESP,'var',ESPV,'qty',1,'price',450000,'net',450000,'ool',v_ol1)),
                    '[{"m":"cash","amt":450000,"tend":450000}]', 450000, 0);
  PERFORM tp_ticket('sale', 11, jsonb_build_array(jsonb_build_object('no',1,'item',ESP,'var',ESPV,'qty',1,'price',450000,'net',450000,'ool',v_ol1)),
                    '[{"m":"card_pos","amt":450000}]', 450000, 0);
  PERFORM tp_expect(format($q$SELECT tp_ticket('sale', 12, %L, '[{"m":"cash","amt":450000,"tend":450000}]', 450000, 0)$q$,
                     jsonb_build_array(jsonb_build_object('no',1,'item',ESP,'var',ESPV,'qty',1,'price',450000,'net',450000,'ool',v_ol1))),
                    'HK_POS_SPLIT_EXCEEDS', 'T19 INV-POS-11 split bills never exceed the order line');
  PERFORM tp_expect(format($q$SELECT tp_ticket('sale', 12, %L, '[{"m":"cash","amt":450000,"tend":450000}]', 450000, 0)$q$,
                     jsonb_build_array(jsonb_build_object('no',1,'item',ESP,'var',ESPV,'qty',1,'price',450000,'net',450000,'ool',v_ol2))),
                    'HK_POS_SPLIT_EXCEEDS', 'T19 INV-POS-11 voided order line cannot be billed');
  UPDATE pos.open_order SET status = 'paid', closed_at = now(), version = 3 WHERE id = v_o;
  PERFORM tp_expect(format($q$UPDATE pos.open_order SET note = 'x', version = 4 WHERE id = %L$q$, v_o), 'HK_POS_ORDER_CLOSED', 'T19 closed order immutable');
  PERFORM tp_expect(format($q$INSERT INTO pos.open_order_line (tenant_id, id, order_id, line_no, item_id, variant_id, uom_id, qty, unit_price)
                     VALUES (core.current_tenant_id(), uuidv7(), %L, 3, %L, %L, '4a000000-0000-7000-8000-0000000000f1', 1, 1)$q$, v_o, ESP, ESPV),
                    'HK_POS_ORDER_CLOSED', 'T19 no lines on a closed order');
  -- جریان دادهٔ پایه: نسخهٔ یکنواخت، تغییر فقط در نسخهٔ جاری، فشرده‌سازی فقط پشت snapshot
  v_ver := pos.bump_stream('prices', v_scope);
  INSERT INTO pos.stream_change (tenant_id, stream, scope_key, version, entity_type, entity_id, op, payload)
  VALUES (core.current_tenant_id(), 'prices', v_scope, v_ver, 'catalog.price', ESPV, 'upsert', '{"price":"450000"}');
  PERFORM tp_expect(format($q$INSERT INTO pos.stream_change (tenant_id, stream, scope_key, version, entity_type, entity_id, op, payload)
                     VALUES (core.current_tenant_id(), 'prices', %L, %s, 'catalog.price', %L, 'upsert', '{}')$q$, v_scope, v_ver + 1, ESPV),
                    'HK_SYNC_STREAM_VERSION', 'T19 INV-SYNC-09 changes use the current stream version');
  PERFORM tp_assert(pos.bump_stream('prices', v_scope) = v_ver + 1, 'T19 INV-SYNC-09 stream version increments');
  PERFORM tp_expect(format($q$UPDATE pos.sync_stream_version SET version = 0 WHERE stream = 'prices' AND scope_key = %L$q$, v_scope),
                    'HK_SYNC_STREAM_VERSION', 'T19 versions never go back');
  PERFORM tp_expect(format($q$DELETE FROM pos.stream_change WHERE stream = 'prices' AND scope_key = %L$q$, v_scope),
                    'HK_SYNC_STREAM_COMPACTION', 'T19 compaction only behind a snapshot');
  UPDATE pos.sync_stream_version SET snapshot_version = v_ver WHERE stream = 'prices' AND scope_key = v_scope;
  DELETE FROM pos.stream_change WHERE stream = 'prices' AND scope_key = v_scope AND version <= v_ver;
  PERFORM tp_expect(format($q$UPDATE pos.stream_change SET op = 'delete' WHERE stream = 'prices'$q$), 'HK_IMMUTABLE|permission denied', 'T19 stream changes append-only');
END $$;

-- بستن شیفت: شمارش، کسری/اضافه = شمارش‌شده − مورد انتظار؛ شیفت بسته تغییرناپذیر
DO $$
DECLARE S1 uuid := '4a000000-0000-7000-8000-000000000901'; BD uuid := '4a000000-0000-7000-8000-000000000801';
BEGIN
  PERFORM tp_ctx('A');
  PERFORM tp_expect(format($q$UPDATE pos.shift SET status = 'closed', closed_at = now(), closed_by = '4a000000-0000-7000-8000-00000000a001', close_cmd_id = uuidv7(),
                     expected_cash = 2570000, counted_cash = 2560000, over_short = 10000 WHERE id = %L$q$, S1),
                    'shift_over_short', 'T19 INV-POS-12 over/short = counted - expected');
  UPDATE pos.shift SET status = 'closed', closed_at = now(), closed_by = '4a000000-0000-7000-8000-00000000a001', close_cmd_id = uuidv7(),
                       expected_cash = 2570000, counted_cash = 2560000, over_short = -10000 WHERE id = S1;
  PERFORM tp_expect(format($q$UPDATE pos.shift SET counted_cash = 2570000, over_short = 0 WHERE id = %L$q$, S1), 'HK_POS_SHIFT_CLOSED', 'T19 closed shift immutable');
  UPDATE pos.business_day SET status = 'closed', closed_at = now() WHERE id = BD;
  PERFORM tp_expect(format($q$UPDATE pos.business_day SET status = 'open', closed_at = NULL WHERE id = %L$q$, BD), 'HK_POS_DAY_CLOSED', 'T19 closed business day final');
END $$;

-- ---------- T23: قیدهای جزئی پیکربندی (قالب چاپ چک، لبه، چاپگر، ایستگاه، modifier، نشست آفلاین، نام مستعار، کسری دنباله) ----------
DO $$
DECLARE CA uuid := '4a000000-0000-7000-8000-0000000000c1'; BA uuid := '4a000000-0000-7000-8000-0000000000b1';
        v_tpl uuid := uuidv7(); v_ch uuid; DA1 uuid := '4a000000-0000-7000-8000-0000000000d1';
BEGIN
  PERFORM tp_ctx('A');
  PERFORM tp_expect($q$INSERT INTO treasury.cheque_print_template (tenant_id, code, name, page_width_mm, page_height_mm, layout)
                     VALUES (core.current_tenant_id(), 'X', 'x', 180, 80, '[{"field":"password","x_mm":1,"y_mm":1}]')$q$,
                    'cheque_print_layout_fields', 'T23 print layout fields are whitelisted');
  PERFORM tp_expect($q$INSERT INTO treasury.cheque_print_template (tenant_id, code, name, page_width_mm, page_height_mm, layout)
                     VALUES (core.current_tenant_id(), 'X', 'x', 180, 80, '[{"field":"amount_words","y_mm":1}]')$q$,
                    'cheque_print_layout_fields', 'T23 print layout fields need coordinates');
  INSERT INTO treasury.cheque_print_template (tenant_id, id, code, name, bank_code, page_width_mm, page_height_mm, layout, is_default)
  VALUES (core.current_tenant_id(), v_tpl, 'SAYAD-A', 'برگ صیادی استاندارد', 'mellat', 180, 80,
          '[{"field":"date_digits","x_mm":20,"y_mm":10,"font_pt":11},{"field":"amount_words","x_mm":40,"y_mm":30,"w_mm":120},{"field":"payee_name","x_mm":40,"y_mm":40}]', true);
  SELECT id INTO v_ch FROM treasury.cheque WHERE direction = 'issued' LIMIT 1;
  INSERT INTO treasury.cheque_print_log (tenant_id, cheque_id, template_id, rendered_sha256) VALUES (core.current_tenant_id(), v_ch, v_tpl, sha256('pdf'::bytea));
  PERFORM tp_expect($q$UPDATE treasury.cheque_print_log SET copies = 2$q$, 'permission denied|HK_IMMUTABLE', 'T23 print log append-only');
  PERFORM tp_expect(format($q$INSERT INTO pos.edge_node (tenant_id, company_id, branch_id, name, key_alg, public_key, status)
                     VALUES (core.current_tenant_id(), %L, %L, 'لبه', 'ed25519', decode(repeat('55', 31), 'hex'), 'active')$q$, CA, BA),
                    'edge_key', 'T23 edge key length per algorithm');
  PERFORM tp_expect(format($q$INSERT INTO pos.printer (tenant_id, company_id, branch_id, name, purpose, transport) VALUES (core.current_tenant_id(), %L, %L, 'p', 'receipt', 'tcp')$q$, CA, BA),
                    'printer_host', 'T23 printer hangs off a terminal or an edge node');
  PERFORM tp_expect(format($q$INSERT INTO pos.printer (tenant_id, company_id, branch_id, name, purpose, transport, terminal_id)
                     VALUES (core.current_tenant_id(), %L, %L, 'p', 'station', 'tcp', '4a000000-0000-7000-8000-000000000701')$q$, CA, BA),
                    'printer_station', 'T23 station printer names its station');
  PERFORM tp_expect($q$INSERT INTO pos.modifier_group (tenant_id, code, name, min_select, max_select) VALUES (core.current_tenant_id(), 'MG', 'شیر', 2, 1)$q$,
                    'modifier_group_range', 'T23 modifier min <= max');
  INSERT INTO pos.station (tenant_id, id, company_id, branch_id, code, name, kind)
  VALUES (core.current_tenant_id(), '4a000000-0000-7000-8000-000000000a01', CA, BA, 'BAR', 'بار قهوه', 'bar');
  PERFORM tp_expect($q$INSERT INTO pos.station_route (tenant_id, station_id) VALUES (core.current_tenant_id(), '4a000000-0000-7000-8000-000000000a01')$q$,
                    'station_route_target', 'T23 station route names an item or a category');
  INSERT INTO pos.station_route (tenant_id, station_id, item_id)
  VALUES (core.current_tenant_id(), '4a000000-0000-7000-8000-000000000a01', '4a000000-0000-7000-8000-0000000000f2');
  PERFORM tp_expect(format($q$INSERT INTO pos.client_id_alias (tenant_id, entity_type, client_id, canonical_id, device_id, reason)
                     VALUES (core.current_tenant_id(), 'party', %1$L, %1$L, %2$L, 'manual')$q$, uuidv7(), DA1),
                    'alias_not_self', 'T23 alias differs from the canonical id');
  PERFORM tp_expect(format($q$INSERT INTO pos.device_seq_gap (tenant_id, device_id, from_seq, to_seq, reason, declared_by)
                     VALUES (core.current_tenant_id(), %L, 10, 5, 'دستگاه پاک‌سازی شد', '4a000000-0000-7000-8000-00000000a002')$q$, DA1),
                    'seq_gap_range', 'T23 declared gap range');
  PERFORM tp_expect(format($q$INSERT INTO pos.offline_session (tenant_id, id, device_id, terminal_id, started_at, ended_at, max_hours, start_cmd_id)
                     VALUES (core.current_tenant_id(), uuidv7(), %L, '4a000000-0000-7000-8000-000000000701', now(), now() - interval '1 hour', 72, uuidv7())$q$, DA1),
                    'offline_session_end', 'T23 offline session end after start (with its command)');
  PERFORM tp_expect(format($q$INSERT INTO treasury.money_document (tenant_id, company_id, direction, doc_date, total_amount, status)
                     VALUES (core.current_tenant_id(), %L, 'receipt', DATE '2026-04-05', 10, 'posted')$q$, CA),
                    'money_doc_posted_cols', 'T23 a document cannot be born posted without journal and number');
END $$;

-- ---------- T24: مسیرهای خطای باقی‌مانده (هر کد خطای فایل دست‌کم یک آزمون دارد) ----------
DO $$
DECLARE CA uuid := '4a000000-0000-7000-8000-0000000000c1'; CA2 uuid := '4a000000-0000-7000-8000-0000000000c2'; BA uuid := '4a000000-0000-7000-8000-0000000000b1';
        PC uuid := '4a000000-0000-7000-8000-0000000000e1'; PS uuid := '4a000000-0000-7000-8000-0000000000e2';
        v_bk uuid := '4a000000-0000-7000-8000-000000000101'; v_bdim uuid; v_c uuid; v_e2 uuid; v_doc uuid := uuidv7(); v_t uuid;
        v_o uuid := uuidv7(); v_edge uuid := uuidv7(); v_m uuid; v_d1 uuid := uuidv7(); v_c2 uuid := uuidv7();
        DA1 uuid := '4a000000-0000-7000-8000-0000000000d1'; DA3 uuid := '4a000000-0000-7000-8000-0000000000d3'; v_cmd uuid; v_bd2 uuid := uuidv7();
BEGIN
  PERFORM tp_ctx('A');
  SELECT dimension_value_id INTO v_bdim FROM treasury.bank_account WHERE id = v_bk;
  -- چک: یافت‌نشده، طرف لازم، undo غیرآخر
  PERFORM tp_expect($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, to_state, event_date, collected_after, long_term_after)
                     VALUES (core.current_tenant_id(), uuidv7(), 1, 'transition', 'R1', 'in_hand', DATE '2026-04-10', 0, false)$q$,
                    'HK_CHQ_NOT_FOUND', 'T24 event for an unknown cheque');
  v_c := tp_recv_cheque('2020202020202020', 1000000, PC, tp_jr(CA, DATE '2026-04-10'));
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date, collected_after,
                     long_term_after, journal_id) VALUES (core.current_tenant_id(), %L, 2, 'transition', 'R9', 'in_hand', 'endorsed', DATE '2026-04-11', 0, false, %L)$q$,
                     v_c, tp_jr(CA, DATE '2026-04-11')),
                    'HK_CHQ_COUNTERPARTY_REQUIRED', 'T24 endorsement names the endorsee');
  INSERT INTO treasury.cheque_event (tenant_id, id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date, collected_after, long_term_after,
                                     journal_id, bank_account_id, deposit_bank_after, holding_account_id, holding_dim_value_id, holding_amount, holding_amount_base)
  VALUES (core.current_tenant_id(), uuidv7(), v_c, 2, 'transition', 'R2', 'in_hand', 'deposited', DATE '2026-04-11', 0, false,
          tp_jr(CA, DATE '2026-04-11'), v_bk, v_bk, tp_acc(CA, '1203'), v_bdim, 1000000, 1000000) RETURNING id INTO v_e2;
  INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date, collected_after, long_term_after,
                                     journal_id, holding_account_id, holding_amount, holding_amount_base)
  VALUES (core.current_tenant_id(), v_c, 3, 'transition', 'R12', 'deposited', 'in_hand', DATE '2026-04-12', 0, false,
          tp_jr(CA, DATE '2026-04-12'), tp_acc(CA, '1202'), 1000000, 1000000);
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, undoes_event_id, from_state, to_state, event_date,
                     collected_after, long_term_after, journal_id, holding_account_id, holding_amount, holding_amount_base)
                     VALUES (core.current_tenant_id(), %L, 4, 'undo', %L, 'in_hand', 'in_hand', DATE '2026-04-13', 0, false, %L, %L, 1000000, 1000000)$q$,
                     v_c, v_e2, tp_jr(CA, DATE '2026-04-13'), tp_acc(CA, '1202')),
                    'HK_CHQ_UNDO_NOT_LAST', 'T24 only the latest effective transition can be undone');
  -- سند: یافت‌نشده، چک ناسازگار، طرف چک برگشتی، چک پیش‌نویس هنگام ثبت
  PERFORM tp_expect($q$INSERT INTO treasury.money_instrument (tenant_id, document_id, line_no, kind, amount, cash_box_id)
                     VALUES (core.current_tenant_id(), uuidv7(), 1, 'cash', 1, '4a000000-0000-7000-8000-000000000202')$q$,
                    'HK_TRS_DOC_NOT_FOUND', 'T24 line for an unknown document');
  INSERT INTO treasury.money_document (tenant_id, id, company_id, direction, doc_date, party_id, total_amount)
  VALUES (core.current_tenant_id(), v_doc, CA, 'receipt', DATE '2026-04-12', PC, 1000000);
  PERFORM tp_expect(format($q$INSERT INTO treasury.money_instrument (tenant_id, document_id, line_no, kind, amount, cheque_id)
                     VALUES (core.current_tenant_id(), %L, 1, 'cheque', 999, %L)$q$, v_doc, v_c),
                    'HK_TRS_INSTRUMENT_CHEQUE', 'T24 cheque instrument amount equals the cheque');
  PERFORM tp_expect(format($q$INSERT INTO treasury.money_counter_line (tenant_id, document_id, line_no, kind, party_id, cheque_id, amount)
                     VALUES (core.current_tenant_id(), %L, 1, 'bounced_cheque', %L, %L, 1000000)$q$, v_doc, PC, v_c),
                    'HK_TRS_COUNTER_CHEQUE', 'T24 bounced-cheque settlement needs a bounced cheque');
  INSERT INTO treasury.money_instrument (tenant_id, document_id, line_no, kind, amount, cheque_draft)
  VALUES (core.current_tenant_id(), v_doc, 1, 'cheque', 1000000, '{"sayad_id":"3030303030303030"}');
  INSERT INTO treasury.money_counter_line (tenant_id, document_id, line_no, kind, party_id, party_role, amount)
  VALUES (core.current_tenant_id(), v_doc, 1, 'party', PC, 'customer', 1000000);
  PERFORM tp_expect(format($q$UPDATE treasury.money_document SET status = 'posted', journal_id = tp_jr(%L, DATE '2026-04-12'),
                     number_issued_id = (SELECT number_id FROM core.number_next('4a000000-0000-7000-8000-000000000502', 'all', 'RC-{seq}', 'treasury.receipt', %L)),
                     doc_no = 'RC-X', posted_at = now() WHERE id = %L$q$, CA, v_doc, v_doc),
                    'HK_TRS_DOC_CHEQUE_MISSING', 'T24 posted cheque instruments reference their cheque record');
  -- تسویه بین دو شرکت
  INSERT INTO treasury.open_item (tenant_id, id, company_id, party_id, party_role, account_class, direction, source_module, source_doc_type,
                                  source_doc_id, doc_date, due_date, currency, amount, amount_base)
  VALUES (core.current_tenant_id(), v_d1, CA, PC, 'customer', 'receivable', 'debit', 'sales', 'sales.invoice', uuidv7(), DATE '2026-04-01', DATE '2026-04-30', 'IRR', 10, 10),
         (core.current_tenant_id(), v_c2, CA2, PC, 'customer', 'receivable', 'credit', 'treasury', 'treasury.receipt', uuidv7(), DATE '2026-04-01', DATE '2026-04-01', 'IRR', 10, 10);
  PERFORM tp_expect(format($q$INSERT INTO treasury.allocation (tenant_id, company_id, debit_item_id, credit_item_id, amount, currency, allocation_date)
                     VALUES (core.current_tenant_id(), %L, %L, %L, 10, 'IRR', DATE '2026-04-02')$q$, CA, v_d1, v_c2),
                    'HK_TRS_ALLOC_COMPANY', 'T24 allocation stays inside one company');
  -- کارت: گذار نامعتبر
  SELECT id INTO v_t FROM treasury.card_txn WHERE rrn = '000000000124';
  UPDATE treasury.card_txn SET status = 'reversed' WHERE id = v_t;
  PERFORM tp_expect(format($q$UPDATE treasury.card_txn SET status = 'approved' WHERE id = %L$q$, v_t), 'HK_CRD_TRANSITION', 'T24 reversed card transaction is final');
  -- مغایرت: قلم غیرفعال در گروه فعال
  SELECT id INTO v_m FROM treasury.recon_match WHERE status = 'active' LIMIT 1;
  PERFORM tp_expect(format($q$INSERT INTO treasury.recon_match_item (tenant_id, match_id, side, statement_line_id, amount, is_active)
                     SELECT core.current_tenant_id(), %L, 'statement', id, signed_amount, false FROM treasury.statement_line WHERE line_no = 3 AND NOT is_superseded LIMIT 1$q$, v_m),
                    'HK_BNK_MATCH_STATE', 'T24 items are added active to an active match');
  -- صندوق: لبهٔ شعبهٔ دیگر، وضعیت سطر سفارش، دستگاه بدون وضعیت همگام‌سازی، زمینهٔ رسید
  INSERT INTO pos.edge_node (tenant_id, id, company_id, branch_id, name) VALUES (core.current_tenant_id(), v_edge, CA, '4a000000-0000-7000-8000-0000000000b2', 'لبه شعبه ۲');
  PERFORM tp_expect(format($q$UPDATE pos.terminal SET edge_node_id = %L WHERE id = '4a000000-0000-7000-8000-000000000701'$q$, v_edge),
                    'HK_POS_TERMINAL_EDGE', 'T24 terminal edge node in its own branch');
  INSERT INTO pos.open_order (tenant_id, id, company_id, branch_id, terminal_id, order_type, opened_at, last_cmd_id)
  VALUES (core.current_tenant_id(), v_o, CA, BA, '4a000000-0000-7000-8000-000000000701', 'takeaway', now(), uuidv7());
  PERFORM tp_expect(format($q$INSERT INTO pos.open_order_line (tenant_id, id, order_id, line_no, item_id, variant_id, uom_id, qty, unit_price, status, sent_at)
                     VALUES (core.current_tenant_id(), uuidv7(), %L, 1, '4a000000-0000-7000-8000-0000000000f2', '4a000000-0000-7000-8000-0000000000f3',
                             '4a000000-0000-7000-8000-0000000000f1', 1, 1, 'sent', now())$q$, v_o),
                    'HK_POS_ORDER_LINE_STATE', 'T24 new order lines are pending');
  PERFORM tp_expect(format($q$SELECT tp_cmd(%L, 'device.clock_report', '{}', tp_batch(%L, 1, 1))$q$, DA3, DA3), 'HK_SYNC_NO_STATE', 'T24 device must be provisioned for sync');
  INSERT INTO pos.business_day (tenant_id, id, company_id, branch_id, business_date, opened_at) VALUES (core.current_tenant_id(), v_bd2, CA, BA, DATE '2026-04-06', now());
  v_cmd := tp_cmd(DA1, 'sale.completed', '{}', tp_batch(DA1, (SELECT last_seq + 1 FROM pos.device_sync_state WHERE device_id = DA1), 1));
  PERFORM tp_expect(format($q$INSERT INTO pos.ticket (tenant_id, id, company_id, branch_id, terminal_id, shift_id, business_day_id, device_id, cmd_id, kind, order_type,
                     ticket_no, number_issued_id, customer_party_id, subtotal, total, occurred_at, cashier_user_id)
                     VALUES (core.current_tenant_id(), uuidv7(), %L, %L, '4a000000-0000-7000-8000-000000000701', '4a000000-0000-7000-8000-000000000901', %L, %L, %L,
                     'sale', 'retail', 'R1-000099', core.number_record_external('4a000000-0000-7000-8000-000000000501', 'all', 99, 'R1-000099', 'pos.ticket', uuidv7(), %L),
                     '4a000000-0000-7000-8000-0000000000e3', 0, 0, now(), '4a000000-0000-7000-8000-00000000a001')$q$, CA, BA, v_bd2, DA1, v_cmd, DA1),
                    'HK_POS_TICKET_CONTEXT', 'T24 ticket shift and business day agree');
END $$;

-- ---------- T22 (INV-CHQ-14): زیردفتر چک = دفتر کل (ledger.check_control_accounts) در شرکت تمیز CA2 ----------
DO $$
DECLARE CA2 uuid := '4a000000-0000-7000-8000-0000000000c2'; PC uuid := '4a000000-0000-7000-8000-0000000000e1';
        v_bk uuid := uuidv7(); v_bdim uuid; v_pdim uuid; v_c uuid := uuidv7(); v_n int;
BEGIN
  PERFORM tp_ctx('A');
  PERFORM ledger.apply_coa_template(CA2, 'ir.general', 1);
  PERFORM tp_make_year(CA2, '1405', DATE '2026-03-21');
  v_pdim := tp_pdim(PC);
  INSERT INTO treasury.bank_account (tenant_id, id, company_id, code, name, bank_code, sheba, account_type)
  VALUES (core.current_tenant_id(), v_bk, CA2, 'BK2', 'ملت دوم', 'mellat', 'IR510120000000000007654321', 'current');
  v_bdim := tp_dim('bank_account', 'treasury', v_bk, 'BK2');
  UPDATE treasury.bank_account SET dimension_value_id = v_bdim WHERE id = v_bk;
  -- R1: دریافت چک — بدهکار اسناد دریافتنی [شخص] / بستانکار دریافتنی تجاری [شخص]
  INSERT INTO treasury.cheque (tenant_id, id, company_id, direction, state, medium, sayad_id, amount, amount_base, due_date, received_from_party_id,
                               sayad_state, origin)
  VALUES (core.current_tenant_id(), v_c, CA2, 'received', 'in_hand', 'electronic', '6060606060606060', 7000000, 7000000, DATE '2026-06-01', PC,
          'not_inquired', 'receipt');
  INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, to_state, event_date, collected_after, long_term_after, journal_id,
                                     holding_account_id, holding_dim_value_id, holding_amount, holding_amount_base)
  VALUES (core.current_tenant_id(), v_c, 1, 'transition', 'R1', 'in_hand', DATE '2026-04-10', 0, false,
          tp_jr(CA2, DATE '2026-04-10', jsonb_build_array(jsonb_build_object('a','1202','dr',7000000,'d1',v_pdim), jsonb_build_object('a','1201','cr',7000000,'d1',v_pdim))),
          tp_acc(CA2, '1202'), v_pdim, 7000000, 7000000);
  -- R2: واگذاری — بدهکار در جریان وصول [بانک] / بستانکار اسناد دریافتنی [شخص]
  INSERT INTO treasury.cheque_event (tenant_id, cheque_id, seq, kind, transition_code, from_state, to_state, event_date, collected_after, long_term_after,
                                     journal_id, bank_account_id, deposit_bank_after, holding_account_id, holding_dim_value_id, holding_amount, holding_amount_base)
  VALUES (core.current_tenant_id(), v_c, 2, 'transition', 'R2', 'in_hand', 'deposited', DATE '2026-04-20', 0, false,
          tp_jr(CA2, DATE '2026-04-20', jsonb_build_array(jsonb_build_object('a','1203','dr',7000000,'d1',v_bdim), jsonb_build_object('a','1202','cr',7000000,'d1',v_pdim))),
          v_bk, v_bk, tp_acc(CA2, '1203'), v_bdim, 7000000, 7000000);
END $$;

DO $$
DECLARE CA2 uuid := '4a000000-0000-7000-8000-0000000000c2'; PC uuid := '4a000000-0000-7000-8000-0000000000e1'; v_n int;
BEGIN
  PERFORM tp_ctx('A');
  SELECT count(*) INTO v_n FROM ledger.check_control_accounts(CA2, DATE '2026-04-15') WHERE subledger_kind = 'cheque_receivable';
  PERFORM tp_assert(v_n = 0, 'T22 INV-CHQ-14 cheque subledger = GL as of 2026-04-15 (in hand)');
  SELECT count(*) INTO v_n FROM ledger.check_control_accounts(CA2, DATE '2026-04-30') WHERE subledger_kind = 'cheque_receivable';
  PERFORM tp_assert(v_n = 0, 'T22 INV-CHQ-14 cheque subledger = GL as of 2026-04-30 (deposited)');
  PERFORM tp_assert((SELECT sum(balance_base) FROM treasury.subledger_cheque_receivable(CA2, DATE '2026-04-30')) = 7000000, 'T22 subledger function total');
  -- سند دستی/خارج از چک روی ۱۲۰۲ کشف می‌شود
  BEGIN
    PERFORM tp_jr(CA2, DATE '2026-04-25', jsonb_build_array(jsonb_build_object('a','1202','dr',1000,'d1',tp_pdim(PC)), jsonb_build_object('a','1201','cr',1000,'d1',tp_pdim(PC))));
    SELECT count(*) INTO v_n FROM ledger.check_control_accounts(CA2, DATE '2026-04-30') WHERE subledger_kind = 'cheque_receivable';
    PERFORM tp_assert(v_n >= 1, 'T22 INV-CHQ-14 GL posting without a cheque event is detected');
    RAISE EXCEPTION 'tp_rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'tp_rollback' THEN RAISE; END IF;
  END;
END $$;

-- ---------- T20 (INV-SEC-01): جداسازی مستأجر ----------
DO $$
DECLARE CB uuid := '4b000000-0000-7000-8000-0000000000c1'; v_bkb uuid := uuidv7();
BEGIN
  PERFORM tp_ctx('B');
  PERFORM tp_assert((SELECT count(*) FROM treasury.cheque) = 0 AND (SELECT count(*) FROM treasury.money_document) = 0
                    AND (SELECT count(*) FROM treasury.open_item) = 0 AND (SELECT count(*) FROM treasury.bank_account) = 0
                    AND (SELECT count(*) FROM treasury.statement_line) = 0 AND (SELECT count(*) FROM treasury.gateway_payment) = 0
                    AND (SELECT count(*) FROM pos.ticket) = 0 AND (SELECT count(*) FROM pos.device_command) = 0
                    AND (SELECT count(*) FROM pos.terminal) = 0 AND (SELECT count(*) FROM treasury.cheque_event) = 0,
                    'T20 tenant B sees none of tenant A rows');
  PERFORM tp_expect($q$INSERT INTO treasury.cash_box (tenant_id, company_id, code, name)
                     VALUES ('4a000000-0000-7000-8000-000000000001', '4a000000-0000-7000-8000-0000000000c1', 'HACK', 'x')$q$,
                    'row-level security', 'T20 cannot write another tenant rows');
  INSERT INTO treasury.bank_account (tenant_id, id, company_id, code, name, bank_code, account_no, account_type)
  VALUES (core.current_tenant_id(), v_bkb, CB, 'BKB', 'حساب ب', 'melli', '0100200300', 'current');
  PERFORM tp_expect(format($q$INSERT INTO treasury.card_terminal (tenant_id, company_id, psp_code, terminal_no, name, settlement_bank_account_id)
                     VALUES (core.current_tenant_id(), %L, 'sep', '99990000', 'x', '4a000000-0000-7000-8000-000000000101')$q$, CB),
                    'foreign key|violates', 'T20 composite FK blocks a reference to another tenant bank account');
  PERFORM tp_expect(format($q$INSERT INTO treasury.cheque (tenant_id, company_id, direction, state, medium, sayad_id, amount, amount_base, due_date,
                     received_from_party_id, sayad_state, origin) VALUES (core.current_tenant_id(), %L, 'received', 'in_hand', 'paper', '1111222233334444',
                     1, 1, DATE '2026-05-01', '4a000000-0000-7000-8000-0000000000e1', 'not_inquired', 'receipt')$q$, CB),
                    'foreign key|violates', 'T20 composite FK blocks another tenant party');
  PERFORM tp_expect(format($q$INSERT INTO pos.terminal (tenant_id, company_id, branch_id, code, name, cash_box_id, receipt_series_id, walk_in_party_id, status)
                     VALUES (core.current_tenant_id(), %L, '4b000000-0000-7000-8000-0000000000b1', 'TB', 'x', '4a000000-0000-7000-8000-000000000201',
                             '4b000000-0000-7000-8000-000000000501', '4b000000-0000-7000-8000-0000000000e3', 'disabled')$q$, CB),
                    'foreign key|violates|HK_POS_TERMINAL', 'T20 composite FK blocks another tenant cash box');
END $$;
DO $$
DECLARE v_n int;
BEGIN
  PERFORM tp_ctx('B');
  UPDATE treasury.bank_account SET name = 'x' WHERE id = '4a000000-0000-7000-8000-000000000101';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  PERFORM tp_assert(v_n = 0, 'T20 update of another tenant row touches nothing');
  PERFORM tp_ctx('');
  PERFORM tp_assert((SELECT count(*) FROM treasury.bank_account) = 0 AND (SELECT count(*) FROM pos.terminal) = 0, 'T20 no tenant context sees nothing');
END $$;

-- ---------- T21: hk_readonly — خواندن بدون ستون راز، بدون نوشتن ----------
RESET ROLE;
SET ROLE hk_readonly;
DO $$
BEGIN
  PERFORM tp_ctx('A');
  PERFORM tp_assert((SELECT count(*) FROM treasury.cheque) > 0 AND (SELECT count(*) FROM pos.ticket) > 0, 'T21 readonly sees tenant rows');
  PERFORM tp_assert((SELECT count(*) FROM treasury.gateway_account WHERE code IS NOT NULL) = 2, 'T21 readonly reads non-secret gateway columns');
  PERFORM tp_expect($q$SELECT credentials_sealed FROM treasury.gateway_account$q$, 'permission denied', 'T21 readonly cannot read sealed credentials');
  PERFORM tp_expect($q$INSERT INTO treasury.recon_rule (tenant_id, company_id, name, pattern, action)
                     VALUES (core.current_tenant_id(), '4a000000-0000-7000-8000-0000000000c1', 'r', 'x', 'suggest')$q$, 'permission denied', 'T21 readonly cannot write');
END $$;
RESET ROLE;

SELECT 'ALL 40_treasury_pos TESTS PASSED' AS result;
