-- =====================================================================
-- آزمون پایگاه داده‌ای 50_compliance.sql (سند: docs/design/07-compliance.md §۷ و §۹)
--
-- اجرا (از ریشهٔ مخزن؛ پایگاه دادهٔ تازه با UTF8):
--   export PGPASSWORD=postgres
--   P="psql -h localhost -p 5433 -U postgres"
--   $P -d postgres -c "DROP DATABASE IF EXISTS ds_compliance"
--   $P -d postgres -c "CREATE DATABASE ds_compliance ENCODING 'UTF8' TEMPLATE template0 LC_COLLATE 'C' LC_CTYPE 'C.UTF-8'"
--   for f in 00_foundation 10_core 20_ledger 25_masterdata 50_compliance; do
--     $P -d ds_compliance -v ON_ERROR_STOP=1 -f docs/design/sql/$f.sql; done
--   $P -d ds_compliance -v ON_ERROR_STOP=1 -f docs/design/sql/tests/50_compliance_test.sql
--
-- ساختار (یک نشست psql با superuser؛ نقش‌ها با SET ROLE عوض می‌شوند):
--   بخش ۱ (postgres = نقش migrator/نصب‌کنندهٔ بسته) — fixture مستأجرها، کاربران، دستگاه، کدینگ و سال مالی؛
--          نصب و فعال‌سازی بسته‌های قواعد آزمایشی (ارقام «TEST-ONLY»، ساختگی) و آزمون ناوردایی‌های جدول‌های
--          سراسری rules (G01..G09). این جدول‌ها را hk_app هرگز نمی‌نویسد، پس ناوردایی‌شان با مالک آزموده می‌شود.
--   بخش ۲ (SET ROLE hk_app؛ نه مالک، NOBYPASSRLS) — T01..T18 روی جدول‌های مستأجری. هر DO block مستأجر را با
--          set_config('app.tenant_id', '<uuid>', true) تنظیم می‌کند؛ موارد deferred با SET CONSTRAINTS ALL IMMEDIATE
--          درون زیرتراکنش آزموده می‌شوند.
--   بخش ۳ (postgres) — فعال‌سازی بستهٔ جدید (جایگزینی و عطف به ماسبق) و آزمون‌های سراسری باقی‌مانده.
--   بخش ۴ (hk_app) — T19، T19b، T20: پیشنهاد بازمحاسبه، snapshot با بستهٔ جایگزین‌شده، گذارهای باقی‌مانده، جداسازی مستأجر.
--   بخش ۵ (SET ROLE hk_readonly) — T21: فقط خواندن و پنهان بودن رمزینهٔ کلید.
-- خروجی موفق با «ALL 50_compliance TESTS PASSED» پایان می‌یابد؛ هر شکست «TEST FAILED [...]» می‌دهد.
-- بردارهای taxid: -v tax_vectors_file=... (پیش‌فرض docs/design/sql/tests/moadian_taxid_vectors_v1.json).
-- =====================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
\if :{?tax_vectors_file}
\else
  \set tax_vectors_file docs/design/sql/tests/moadian_taxid_vectors_v1.json
\endif
\set tax_vectors `cat :tax_vectors_file`

-- =====================================================================
-- بخش ۱: fixture (postgres)
-- =====================================================================
RESET ROLE;
SELECT set_config('cp.vectors', :'tax_vectors', false) \gset

CREATE OR REPLACE FUNCTION public.cp_expect_error(p_label text, p_sql text, p_expect text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_state text; v_msg text;
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state = p_expect OR v_msg LIKE p_expect || '%' THEN RETURN; END IF;
    RAISE EXCEPTION 'TEST FAILED [%]: expected %, got % %', p_label, p_expect, v_state, v_msg;
  END;
  RAISE EXCEPTION 'TEST FAILED [%]: statement succeeded but % was expected', p_label, p_expect;
END $$;
-- همان، ولی پس از اجرای دستور، قیدهای deferred را درون همان زیرتراکنش اجرا می‌کند (پیش از آن cp_flush)
CREATE OR REPLACE FUNCTION public.cp_expect_error_deferred(p_label text, p_sql text, p_expect text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public.cp_expect_error(p_label, p_sql || '; SET CONSTRAINTS ALL IMMEDIATE; SET CONSTRAINTS ALL DEFERRED', p_expect);
END $$;
-- نقطهٔ وارسی: بررسی‌های deferred معوق همین حالا اجرا شوند و حالت deferred برگردد
CREATE OR REPLACE FUNCTION public.cp_flush() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
END $$;
CREATE OR REPLACE FUNCTION public.cp_assert(p_cond boolean, p_label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond IS NOT TRUE THEN RAISE EXCEPTION 'TEST FAILED [%]', p_label; END IF;
END $$;
CREATE OR REPLACE FUNCTION public.cp_ms(p_ts timestamptz) RETURNS bigint
LANGUAGE sql IMMUTABLE AS $$ SELECT (extract(epoch FROM p_ts) * 1000)::bigint $$;

-- Verhoeff درسی (فقط برای آزمون منفی: نباید با پیاده‌سازی رسمی هم‌خوان باشد)
CREATE OR REPLACE FUNCTION public.cp_std_verhoeff(p_digits text) RETURNS smallint
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  d smallint[] := ARRAY[[0,1,2,3,4,5,6,7,8,9],[1,2,3,4,0,6,7,8,9,5],[2,3,4,0,1,7,8,9,5,6],[3,4,0,1,2,8,9,5,6,7],
                        [4,0,1,2,3,9,5,6,7,8],[5,9,8,7,6,0,4,3,2,1],[6,5,9,8,7,1,0,4,3,2],[7,6,5,9,8,2,1,0,4,3],
                        [8,7,6,5,9,3,2,1,0,4],[9,8,7,6,5,4,3,2,1,0]];
  p smallint[] := ARRAY[[0,1,2,3,4,5,6,7,8,9],[1,5,7,6,2,8,3,0,9,4],[5,8,0,3,7,9,6,1,4,2],[8,9,1,6,0,4,3,5,2,7],
                        [9,4,5,3,1,2,7,6,8,0],[4,2,8,6,5,7,3,9,0,1],[2,7,9,3,8,0,6,4,1,5],[7,0,4,6,9,1,5,2,3,8]];
  inv smallint[] := ARRAY[0,4,3,2,1,5,6,7,8,9]; c int := 0; n int := length(p_digits); i int;
BEGIN
  FOR i IN 0 .. n - 1 LOOP
    c := d[c + 1][p[((i + 1) % 8) + 1][substr(p_digits, n - i, 1)::int + 1] + 1];
  END LOOP;
  RETURN inv[c + 1];
END $$;

-- صورتحساب الکترونیکی آزمایشی (در تولید: TaxDocumentService). همهٔ مقادیر را سازگار می‌سازد مگر کلید «خرابی» داده شود.
-- p: {"invoice","issue_no","indatim","lines":[{"sstid","am","fee","dis","vra"}],"setm","buyer_type","buyer_tin","buyer_nid",
--     "buyer_postal","irtaxid", خرابی‌ها: "bad_taxid","drop_last_line_from_header","tamper_tbill","no_lines","serial_doc"}
CREATE OR REPLACE FUNCTION public.cp_issue(p jsonb) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE inv tax.invoice; m tax.memory; v_id uuid := coalesce((p->>'id')::uuid, uuidv7()); n record; v_day int; v_taxid text;
        v_ind bigint := (p->>'indatim')::bigint; l jsonb; i int := 0; v_prdis numeric; v_adis numeric; v_vam numeric;
        t_prdis numeric := 0; t_dis numeric := 0; t_adis numeric := 0; t_vam numeric := 0; t_tsstam numeric := 0;
        v_lines jsonb := '[]'; v_body jsonb := '[]'; v_snap uuid; v_n_lines int; v_setm smallint := coalesce((p->>'setm')::smallint, 1);
BEGIN
  SELECT * INTO inv FROM tax.invoice WHERE id = (p->>'invoice')::uuid;
  SELECT * INTO m FROM tax.memory WHERE id = inv.memory_ref;
  SELECT id INTO v_snap FROM rules.calc_snapshot WHERE calculator = 'tax.moadian_invoice' ORDER BY created_at LIMIT 1;
  SELECT * INTO n FROM core.number_next(m.serial_series_id, 'all', '{seq}', 'tax.moadian_serial',
                                        CASE WHEN p ? 'serial_doc' THEN (p->>'serial_doc')::uuid ELSE v_id END);
  v_day := (v_ind / 86400000)::int;
  v_taxid := coalesce(p->>'bad_taxid', tax.taxid_build(m.memory_id, v_day, n.value));
  v_n_lines := jsonb_array_length(p->'lines');
  FOR l IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
    i := i + 1;
    v_prdis := trunc((l->>'am')::numeric * (l->>'fee')::numeric, 0);
    v_adis := v_prdis - coalesce((l->>'dis')::numeric, 0);
    v_vam := trunc(v_adis * (l->>'vra')::numeric / 100, 0);
    IF NOT (p ? 'drop_last_line_from_header' AND i = v_n_lines) THEN
      t_prdis := t_prdis + v_prdis; t_dis := t_dis + coalesce((l->>'dis')::numeric, 0); t_adis := t_adis + v_adis;
      t_vam := t_vam + v_vam; t_tsstam := t_tsstam + v_adis + v_vam;
    END IF;
    v_lines := v_lines || jsonb_build_object('line_no', i, 'sstid', l->>'sstid', 'am', l->>'am', 'fee', l->>'fee', 'prdis', v_prdis,
                                             'dis', coalesce((l->>'dis')::numeric, 0), 'adis', v_adis, 'vra', l->>'vra', 'vam', v_vam,
                                             'tsstam', v_adis + v_vam);
    v_body := v_body || jsonb_build_object('sstid', l->>'sstid', 'am', (l->>'am')::numeric, 'fee', (l->>'fee')::numeric,
                                           'prdis', v_prdis, 'dis', coalesce((l->>'dis')::numeric, 0), 'adis', v_adis,
                                           'vra', (l->>'vra')::numeric, 'vam', v_vam, 'tsstam', v_adis + v_vam, 'mu', '1627');
  END LOOP;
  INSERT INTO tax.invoice_issue (tenant_id, id, company_id, invoice_id, issue_no, memory_ref, memory_id, serial, number_issued_id, allocation,
       indatim_ms, issue_date, taxid, irtaxid, subject, inv_type, pattern, setm, tprdis, tdis, tadis, tvam, todam, tolam, tbill,
       seller_tin, buyer_type, buyer_national_id, buyer_tin, buyer_postal_code, payload, payload_sha256, rule_snapshot_id, send_deadline_at)
  VALUES (inv.tenant_id, v_id, inv.company_id, inv.id, coalesce((p->>'issue_no')::smallint, 1), m.id, m.memory_id, n.value, n.number_id, 'server',
       v_ind, (to_timestamp(v_ind / 1000.0) AT TIME ZONE 'Asia/Tehran')::date, v_taxid, p->>'irtaxid', inv.subject, inv.inv_type, inv.pattern,
       v_setm, t_prdis, t_dis, t_adis, t_vam, 0, 0, t_tsstam, '14003778990',
       (p->>'buyer_type')::smallint, p->>'buyer_nid', p->>'buyer_tin', p->>'buyer_postal',
       jsonb_build_object('header', jsonb_strip_nulls(jsonb_build_object('taxid', v_taxid, 'indatim', v_ind, 'inno', substr(v_taxid, 12, 10),
            'inty', inv.inv_type, 'inp', inv.pattern, 'ins', inv.subject, 'irtaxid', p->>'irtaxid',
            'tbill', t_tsstam + coalesce((p->>'tamper_tbill')::numeric, 0), 'tvam', t_vam, 'setm', v_setm)),
          'body', CASE WHEN p ? 'drop_last_line_from_header' THEN v_body - (v_n_lines - 1) ELSE v_body END),
       sha256(convert_to(v_body::text, 'UTF8')), v_snap, to_timestamp(v_ind / 1000.0) + interval '7 days');
  IF NOT p ? 'no_lines' THEN
    INSERT INTO tax.invoice_issue_line (tenant_id, issue_id, line_no, sstid, sstt, mu, am, fee, amount_scale, prdis, dis, adis, vra, vam, tsstam, rate_source)
    SELECT inv.tenant_id, v_id, (x->>'line_no')::int, x->>'sstid', 'کالای آزمایشی', '1627', (x->>'am')::numeric, (x->>'fee')::numeric, 0,
           (x->>'prdis')::numeric, (x->>'dis')::numeric, (x->>'adis')::numeric, (x->>'vra')::numeric, (x->>'vam')::numeric,
           (x->>'tsstam')::numeric, 'sstid_catalog'
      FROM jsonb_array_elements(v_lines) x;
  END IF;
  RETURN v_id;
END $$;

-- ارسال/پاسخ آزمایشی (در تولید: MoadianOutboxWorker)
CREATE OR REPLACE FUNCTION public.cp_sign(p_issue uuid) RETURNS void
LANGUAGE sql AS $$
  UPDATE tax.invoice_issue SET status = 'signed', signed_at = now(), signer = 'server_kms', jws_sha256 = sha256(convert_to(p_issue::text, 'UTF8'))
   WHERE id = p_issue
$$;
CREATE OR REPLACE FUNCTION public.cp_attempt(p_issue uuid, p_batch uuid, p_outcome text, p_ref text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE i tax.invoice_issue; v_no smallint;
BEGIN
  SELECT * INTO i FROM tax.invoice_issue WHERE id = p_issue;
  SELECT coalesce(max(attempt_no), 0) + 1 INTO v_no FROM tax.submission_attempt WHERE issue_id = p_issue;
  INSERT INTO tax.submission_attempt (tenant_id, company_id, issue_id, batch_id, attempt_no, request_trace_id, adapter, environment, sent_at,
                                      transport_outcome, http_status, reference_number, error_codes, request_sha256)
  VALUES (i.tenant_id, i.company_id, p_issue, p_batch, v_no, uuidv7(), 'direct_v1_self_tsp', 'production', now(), p_outcome,
          CASE p_outcome WHEN 'accepted' THEN 200 WHEN 'rejected_sync' THEN 400 WHEN 'http_error' THEN 503 END,
          CASE WHEN p_outcome = 'accepted' THEN coalesce(p_ref, 'REF-' || v_no) END,
          CASE WHEN p_outcome = 'rejected_sync' THEN ARRAY['4143'] ELSE '{}' END, sha256(convert_to(p_issue::text || v_no, 'UTF8')));
END $$;
CREATE OR REPLACE FUNCTION public.cp_inquiry(p_issue uuid, p_result text, p_ref text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE i tax.invoice_issue;
BEGIN
  SELECT * INTO i FROM tax.invoice_issue WHERE id = p_issue;
  INSERT INTO tax.inquiry_log (tenant_id, company_id, issue_id, kind, by_key, result, reference_number, error_codes, sign_jws)
  VALUES (i.tenant_id, i.company_id, p_issue,
          CASE WHEN p_result IN ('SUCCESS','FAILED','IN_PROGRESS','NOT_FOUND','TIMEOUT') THEN 'status' ELSE 'reaction' END, 'uid', p_result,
          coalesce(p_ref, i.last_reference_number), CASE WHEN p_result = 'FAILED' THEN ARRAY['0304401'] ELSE '{}' END,
          CASE WHEN p_result = 'SUCCESS' THEN 'eyJhbGciOiJSUzI1NiJ9.e30.c2ln' END);
END $$;

-- سند حسابداری آزمایشی با سطرهای داده‌شده (در تولید: LedgerPostingService.post)
-- p_lines: [{"code","dr","cr","dim1"}]
CREATE OR REPLACE FUNCTION public.cp_journal(p_company uuid, p_date date, p_module text, p_doc_type text, p_lines jsonb) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid := uuidv7(); v_fy uuid; v_ref bigint; l jsonb; i int := 0; v_tot numeric := 0;
BEGIN
  SELECT f.id INTO v_fy FROM ledger.fiscal_year f WHERE f.company_id = p_company AND p_date BETWEEN f.start_date AND f.end_date;
  SELECT coalesce(max(j.reference_no), 0) + 1 INTO v_ref FROM ledger.journal j WHERE j.company_id = p_company AND j.fiscal_year_id = v_fy;
  SELECT coalesce(sum((x->>'dr')::numeric), 0) INTO v_tot FROM jsonb_array_elements(p_lines) x;
  INSERT INTO ledger.journal (tenant_id, id, company_id, fiscal_year_id, journal_date, journal_type, status, reference_no, reference_text,
                              source_module, source_doc_type, source_doc_id, source_event, base_currency, line_count,
                              total_debit_base, total_credit_base, description)
  VALUES (core.current_tenant_id(), v_id, p_company, v_fy, p_date, 'module', 'temporary', v_ref, 'T-' || v_ref,
          p_module, p_doc_type, uuidv7(), 'post', 'IRR', jsonb_array_length(p_lines), v_tot, v_tot, 'آزمون انطباق');
  FOR l IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    i := i + 1;
    INSERT INTO ledger.journal_line (tenant_id, journal_id, line_no, account_id, dim1_id, currency, exchange_rate, debit_txn, credit_txn, debit_base, credit_base)
    VALUES (core.current_tenant_id(), v_id, i, (SELECT id FROM ledger.account WHERE company_id = p_company AND code = l->>'code'),
            (l->>'dim1')::uuid, 'IRR', 1, coalesce((l->>'dr')::numeric, 0), coalesce((l->>'cr')::numeric, 0),
            coalesce((l->>'dr')::numeric, 0), coalesce((l->>'cr')::numeric, 0));
  END LOOP;
  RETURN v_id;
END $$;
CREATE OR REPLACE FUNCTION public.cp_account(p_company uuid, p_code text) RETURNS uuid
LANGUAGE sql STABLE AS $$ SELECT id FROM ledger.account WHERE company_id = p_company AND code = p_code $$;

GRANT EXECUTE ON FUNCTION public.cp_expect_error(text, text, text), public.cp_expect_error_deferred(text, text, text), public.cp_flush(),
  public.cp_assert(boolean, text), public.cp_ms(timestamptz), public.cp_std_verhoeff(text), public.cp_issue(jsonb),
  public.cp_sign(uuid), public.cp_attempt(uuid, uuid, text, text), public.cp_inquiry(uuid, text, text),
  public.cp_journal(uuid, date, text, text, jsonb), public.cp_account(uuid, text) TO hk_app, hk_readonly;

BEGIN;
INSERT INTO core.deployment_info (profile, app_version, schema_head) VALUES ('test', '2026.11.0', '50_compliance')
ON CONFLICT (singleton) DO NOTHING;

INSERT INTO core.tenant (id, slug, display_name) VALUES
  ('c5a00000-0000-7000-8000-000000000001', 'cp-tenant-a', 'A'),
  ('c5b00000-0000-7000-8000-000000000001', 'cp-tenant-b', 'B');
INSERT INTO core.company (tenant_id, id, code, name, national_id, economic_code) VALUES
  ('c5a00000-0000-7000-8000-000000000001', 'c5a00000-0000-7000-8000-0000000000c1', 'C1', 'کافهٔ الف', '14003778990', '14003778990'),
  ('c5a00000-0000-7000-8000-000000000001', 'c5a00000-0000-7000-8000-0000000000c2', 'C2', 'فروشگاه الف', '10100302746', '10100302746'),
  ('c5b00000-0000-7000-8000-000000000001', 'c5b00000-0000-7000-8000-0000000000c1', 'C1', 'شرکت ب', NULL, NULL);
INSERT INTO core.branch (tenant_id, id, company_id, code, name) VALUES
  ('c5a00000-0000-7000-8000-000000000001', 'c5a00000-0000-7000-8000-0000000000b1', 'c5a00000-0000-7000-8000-0000000000c1', 'BR1', 'شعبهٔ مرکزی');
INSERT INTO core.app_user (id, display_name) VALUES
  ('c5000000-0000-7000-8000-0000000000e1', 'کاربر یک'),
  ('c5000000-0000-7000-8000-0000000000e2', 'کاربر دو'),
  ('c5000000-0000-7000-8000-0000000000e3', 'کاربر سه');
INSERT INTO core.tenant_membership (tenant_id, user_id, status, joined_at, is_owner) VALUES
  ('c5a00000-0000-7000-8000-000000000001', 'c5000000-0000-7000-8000-0000000000e1', 'active', now(), true),
  ('c5a00000-0000-7000-8000-000000000001', 'c5000000-0000-7000-8000-0000000000e2', 'active', now(), false),
  ('c5b00000-0000-7000-8000-000000000001', 'c5000000-0000-7000-8000-0000000000e3', 'active', now(), true);
INSERT INTO core.device (tenant_id, id, company_id, branch_id, kind, name, public_key, status, registered_by, activated_at) VALUES
  ('c5a00000-0000-7000-8000-000000000001', 'c5a00000-0000-7000-8000-0000000000d1', 'c5a00000-0000-7000-8000-0000000000c1',
   'c5a00000-0000-7000-8000-0000000000b1', 'windows', 'امضاکنندهٔ دفتر', decode(repeat('11', 32), 'hex'), 'active',
   'c5000000-0000-7000-8000-0000000000e1', now());
INSERT INTO ref.sstid (sstid, kind, title, snapshot_version, synced_at) VALUES
  ('2710000138624', 'general', 'کالای آزمایشی یک', 'test-v1', now()),
  ('2710000138625', 'general', 'کالای آزمایشی دو', 'test-v1', now())
ON CONFLICT (sstid) DO NOTHING;
INSERT INTO ref.ssi_job_code (code, title, list_version) VALUES ('123456', 'شغل آزمایشی', 'test-v1') ON CONFLICT DO NOTHING;
COMMIT;

-- کدینگ، سال مالی ۱۴۰۵ (۲۰۲۶-۰۳-۲۱ تا ۲۰۲۷-۰۳-۲۰)، اشخاص (با زمینهٔ مستأجر؛ هنوز postgres)
DO $$
DECLARE t uuid := 'c5a00000-0000-7000-8000-000000000001'; c uuid := 'c5a00000-0000-7000-8000-0000000000c1'; v_fy uuid := uuidv7();
        lens int[] := ARRAY[31,31,31,31,31,31,30,30,30,30,30,29]; d date := DATE '2026-03-21'; i int;
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  PERFORM ledger.provision_tenant();
  PERFORM ledger.apply_coa_template(c, 'ir.general', 1);
  INSERT INTO ledger.fiscal_year (tenant_id, id, company_id, code, name, start_date, end_date, base_currency)
  VALUES (t, v_fy, c, '1405', 'سال ۱۴۰۵', d, d + 364, 'IRR');
  FOR i IN 1..12 LOOP
    INSERT INTO ledger.fiscal_period (tenant_id, company_id, fiscal_year_id, period_no, name, start_date, end_date)
    VALUES (t, c, v_fy, i, 'ماه ' || i, d, d + lens[i] - 1);
    d := d + lens[i];
  END LOOP;
  INSERT INTO parties.party (tenant_id, id, code, person_type, name, first_name, last_name, national_id, national_id_status) VALUES
    (t, 'c5a00000-0000-7000-8000-00000000a101', 'E101', 'natural', 'علی محمدی', 'علی', 'محمدی', '0013542419', 'valid'),
    (t, 'c5a00000-0000-7000-8000-00000000a102', 'E102', 'natural', 'مریم احمدی', 'مریم', 'احمدی', '0067749828', 'valid'),
    (t, 'c5a00000-0000-7000-8000-00000000a103', 'E103', 'natural', 'رضا بی‌کد', 'رضا', 'بی‌کد', NULL, NULL),
    (t, 'c5a00000-0000-7000-8000-00000000a104', 'S104', 'legal', 'شرکت تأمین', NULL, NULL, '14003778990', 'valid'),
    (t, 'c5a00000-0000-7000-8000-00000000a105', 'E105', 'natural', 'سارا پاره‌وقت', 'سارا', 'پاره‌وقت', '0499370899', 'valid');
  INSERT INTO parties.party_role (tenant_id, party_id, role) VALUES
    (t, 'c5a00000-0000-7000-8000-00000000a101', 'employee'), (t, 'c5a00000-0000-7000-8000-00000000a102', 'employee'),
    (t, 'c5a00000-0000-7000-8000-00000000a103', 'employee'), (t, 'c5a00000-0000-7000-8000-00000000a104', 'supplier'),
    (t, 'c5a00000-0000-7000-8000-00000000a105', 'employee');
END $$;

-- ---------- بسته‌های قواعد آزمایشی (ارقام TEST-ONLY و ساختگی؛ هیچ‌کدام رقم قانونی نیست) ----------
\set engine '2026.11.0'
SELECT app_version AS engine FROM core.deployment_info \gset
SELECT set_config('cp.engine', :'engine', false) \gset

INSERT INTO rules.package (id, code, version, seq, covers_from, min_engine_version, payload_sha256, hksb_sha256, signer_kid,
                           published_at, authored_by, approved_by, changelog_fa, installed_via) VALUES
  ('c5000000-0000-7000-8000-00000000f001', 'ir.payroll', '1405.1', 2, '2026-03-21', '2026.1.0', sha256('p1'), sha256('h1'), 'rules-test-a',
   now(), 'author@platform', '{approver@platform}', 'بستهٔ آزمایشی حقوق TEST-ONLY', 'test_fixture'),
  ('c5000000-0000-7000-8000-00000000f002', 'ir.tax', '1405.1', 1, '2026-03-21', '2026.1.0', sha256('p2'), sha256('h2'), 'rules-test-a',
   now(), 'author@platform', '{approver@platform}', 'بستهٔ آزمایشی مالیات TEST-ONLY', 'test_fixture'),
  ('c5000000-0000-7000-8000-00000000f003', 'ir.assets', '1405.1', 1, '2026-03-21', '2026.1.0', sha256('p3'), sha256('h3'), 'rules-test-a',
   now(), 'author@platform', '{approver@platform}', 'بستهٔ آزمایشی دارایی TEST-ONLY', 'test_fixture');

INSERT INTO rules.param_value (id, package_id, key, qualifier, effective_from, value, approved_on, source_ref, confidence) VALUES
  ('c5000000-0000-7000-8000-00000000f101', 'c5000000-0000-7000-8000-00000000f001', 'payroll.wage.min_daily', '', '2026-03-21',
   '{"amount":"1000000","unit":"IRR"}', '2026-03-15', 'TEST-ONLY', 'high'),
  ('c5000000-0000-7000-8000-00000000f102', 'c5000000-0000-7000-8000-00000000f001', 'payroll.time.weekly_hours', '', '2026-03-21',
   '{"v":"44"}', NULL, 'TEST-ONLY', 'high'),
  ('c5000000-0000-7000-8000-00000000f103', 'c5000000-0000-7000-8000-00000000f001', 'payroll.time.hourly_divisor', '', '2026-03-21',
   '{"v":"7.33"}', NULL, 'TEST-ONLY', 'medium'),
  ('c5000000-0000-7000-8000-00000000f104', 'c5000000-0000-7000-8000-00000000f001', 'payroll.tax.brackets_monthly', '', '2026-03-21',
   '{"rows":[{"from":"0","to":"10000000","rate":"0"},{"from":"10000000","to":"20000000","rate":"0.10"},{"from":"20000000","to":null,"rate":"0.20"}]}',
   NULL, 'TEST-ONLY', 'high'),
  ('c5000000-0000-7000-8000-00000000f105', 'c5000000-0000-7000-8000-00000000f001', 'payroll.tax.rounding', '', '2026-03-21',
   '{"v":"truncate"}', NULL, 'TEST-ONLY', 'high'),
  ('c5000000-0000-7000-8000-00000000f106', 'c5000000-0000-7000-8000-00000000f001', 'payroll.allowance.housing_monthly', '', '2026-03-21',
   '{"amount":"3000000","unit":"IRR"}', NULL, 'TEST-ONLY', 'low'),
  ('c5000000-0000-7000-8000-00000000f107', 'c5000000-0000-7000-8000-00000000f001', 'payroll.rate.shift', 'me', '2026-03-21',
   '{"v":"0.10"}', NULL, 'TEST-ONLY', 'high'),
  ('c5000000-0000-7000-8000-00000000f201', 'c5000000-0000-7000-8000-00000000f002', 'tax.moadian.send_deadline_days', '', '2026-03-21',
   '{"v":7}', NULL, 'TEST-ONLY', 'high'),
  ('c5000000-0000-7000-8000-00000000f202', 'c5000000-0000-7000-8000-00000000f002', 'tax.vat.general_rate', '', '2026-03-21',
   '{"v":"10"}', NULL, 'TEST-ONLY', 'unverified'),
  ('c5000000-0000-7000-8000-00000000f301', 'c5000000-0000-7000-8000-00000000f003', 'assets.art149.classes', '', '2016-03-20',
   '{"rows":[{"code":"T-FURN","title":"اثاثهٔ آزمایشی","methods":["straight_line"],"straight_years":"10"}]}', NULL, 'TEST-ONLY', 'low'),
  ('c5000000-0000-7000-8000-00000000f302', 'c5000000-0000-7000-8000-00000000f003', 'assets.depreciation.start_rule', '', '2016-03-20',
   '{"v":"first_day_next_month"}', NULL, 'TEST-ONLY', 'low');

INSERT INTO rules.golden_test (package_id, code, calculator, as_of, input, expected, signed_by) VALUES
  ('c5000000-0000-7000-8000-00000000f001', 'min-single', 'payroll.payslip', '2026-04-20', '{"days":31}', '{"net":"1"}', 'حسابدار آزمون'),
  ('c5000000-0000-7000-8000-00000000f001', 'bracket-2',  'payroll.salary_tax', '2026-04-20', '{"taxable":"30000000"}', '{"tax":"3000000"}', 'حسابدار آزمون'),
  ('c5000000-0000-7000-8000-00000000f002', 'rc-tics',    'tax.vat_line', '2026-04-20', '{"am":"2","fee":"10000","dis":"500","vra":"9"}', '{"vam":"1755"}', 'حسابدار آزمون'),
  ('c5000000-0000-7000-8000-00000000f003', 'sl-month',   'assets.depreciation_schedule', '2026-04-20', '{"cost":"120000000","months":120}', '{"monthly":"1000000"}', 'حسابدار آزمون');

-- ---------- G01..G09: ناوردایی‌های جدول‌های سراسری rules (نقش مالک/نصب‌کننده) ----------
DO $$
BEGIN
  -- G01 تعریف پارامتر: نوع/واحد/مالک تغییرناپذیر، حذف ممنوع؛ گسترش enum مجاز
  PERFORM public.cp_expect_error('INV-RUL-01 def type immutable',
    $q$UPDATE rules.param_def SET value_type = 'decimal' WHERE key = 'payroll.wage.min_daily'$q$, 'HK_RULES_DEF_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-RUL-01 def owner immutable',
    $q$UPDATE rules.param_def SET package_code = 'ir.tax' WHERE key = 'payroll.wage.min_daily'$q$, 'HK_RULES_DEF_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-RUL-01 def no delete', $q$DELETE FROM rules.param_def WHERE key = 'payroll.wage.min_daily'$q$, 'HK_RULES_DEF_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-RUL-01 enum shrink',
    $q$UPDATE rules.param_def SET enum_values = '{half_up}' WHERE key = 'payroll.ssi.rounding'$q$, 'HK_RULES_DEF_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-RUL-01 money needs IRR unit',
    $q$INSERT INTO rules.param_def (key, domain, package_code, value_type, unit, description_key, introduced_in)
       VALUES ('payroll.test.x', 'payroll', 'ir.payroll', 'money', 'percent', 'k', '1.0')$q$, '23514');
  PERFORM public.cp_expect_error('INV-RUL-01 key prefix = domain',
    $q$INSERT INTO rules.param_def (key, domain, package_code, value_type, description_key, introduced_in)
       VALUES ('tax.test.x', 'payroll', 'ir.payroll', 'boolean', 'k', '1.0')$q$, '23514');
  -- G02 بسته: درج فقط installing؛ تأیید دونفره؛ حذف/تغییر محتوا ممنوع
  PERFORM public.cp_expect_error('INV-RUL-02 install as active',
    $q$INSERT INTO rules.package (id, code, version, seq, covers_from, status, min_engine_version, payload_sha256, hksb_sha256, signer_kid,
         published_at, authored_by, approved_by, changelog_fa, installed_via, activated_at)
       VALUES (uuidv7(), 'ir.general', '1405.1', 1, '2026-03-21', 'active', '2026.1.0', sha256('x'), sha256('y'), 'k-1', now(), 'a1', '{b1}', 'x', 'test_fixture', now())$q$,
    'HK_RULES_PACKAGE_TRANSITION');
  PERFORM public.cp_expect_error('INV-RUL-03 two-person approval',
    $q$INSERT INTO rules.package (id, code, version, seq, covers_from, min_engine_version, payload_sha256, hksb_sha256, signer_kid,
         published_at, authored_by, approved_by, changelog_fa, installed_via)
       VALUES (uuidv7(), 'ir.general', '1405.1', 1, '2026-03-21', '2026.1.0', sha256('x'), sha256('y'), 'k-1', now(), 'a1', '{a1}', 'x', 'test_fixture')$q$,
    '23514');
  PERFORM public.cp_expect_error('INV-RUL-03 approval required',
    $q$INSERT INTO rules.package (id, code, version, seq, covers_from, min_engine_version, payload_sha256, hksb_sha256, signer_kid,
         published_at, authored_by, approved_by, changelog_fa, installed_via)
       VALUES (uuidv7(), 'ir.general', '1405.1', 1, '2026-03-21', '2026.1.0', sha256('x'), sha256('y'), 'k-1', now(), 'a1', '{}', 'x', 'test_fixture')$q$,
    '23514');
  -- G03 مقدار: نوع، qualifier، هم‌پوشانی بازه
  PERFORM public.cp_expect_error('INV-RUL-04 money without unit',
    $q$INSERT INTO rules.param_value (package_id, key, effective_from, value, source_ref, confidence)
       VALUES ('c5000000-0000-7000-8000-00000000f001', 'payroll.allowance.grocery_monthly', '2026-03-21', '{"amount":"10"}', 'TT', 'high')$q$,
    'HK_RULES_VALUE_INVALID');
  PERFORM public.cp_expect_error('INV-RUL-04 money as number',
    $q$INSERT INTO rules.param_value (package_id, key, effective_from, value, source_ref, confidence)
       VALUES ('c5000000-0000-7000-8000-00000000f001', 'payroll.allowance.grocery_monthly', '2026-03-21', '{"amount":10,"unit":"IRR"}', 'TT', 'high')$q$,
    'HK_RULES_VALUE_INVALID');
  PERFORM public.cp_expect_error('INV-RUL-04 ratio as float number',
    $q$INSERT INTO rules.param_value (package_id, key, effective_from, value, source_ref, confidence)
       VALUES ('c5000000-0000-7000-8000-00000000f001', 'payroll.ssi.employee_rate', '2026-03-21', '{"v":0.07}', 'TT', 'high')$q$,
    'HK_RULES_VALUE_INVALID');
  PERFORM public.cp_expect_error('INV-RUL-04 enum outside list',
    $q$INSERT INTO rules.param_value (package_id, key, effective_from, value, source_ref, confidence)
       VALUES ('c5000000-0000-7000-8000-00000000f001', 'payroll.ssi.rounding', '2026-03-21', '{"v":"ceil"}', 'TT', 'high')$q$,
    'HK_RULES_VALUE_INVALID');
  PERFORM public.cp_expect_error('INV-RUL-04 invalid date',
    $q$INSERT INTO rules.param_value (package_id, key, qualifier, effective_from, value, source_ref, confidence)
       VALUES ('c5000000-0000-7000-8000-00000000f001', 'calendar.extension', 'x:jq:1405Q2', '2026-03-21', '{"v":"2026-02-30"}', 'TT', 'high')$q$,
    'HK_RULES_');
  PERFORM public.cp_expect_error('INV-RUL-04 qualifier required',
    $q$INSERT INTO rules.param_value (package_id, key, effective_from, value, source_ref, confidence)
       VALUES ('c5000000-0000-7000-8000-00000000f001', 'payroll.rate.shift', '2026-03-21', '{"v":"0.15"}', 'TT', 'high')$q$,
    'HK_RULES_QUALIFIER');
  PERFORM public.cp_expect_error('INV-RUL-04 qualifier forbidden',
    $q$INSERT INTO rules.param_value (package_id, key, qualifier, effective_from, value, source_ref, confidence)
       VALUES ('c5000000-0000-7000-8000-00000000f001', 'payroll.ssi.employee_rate', 'x', '2026-03-21', '{"v":"0.07"}', 'TT', 'high')$q$,
    'HK_RULES_QUALIFIER');
  PERFORM public.cp_expect_error('INV-RUL-05 overlapping ranges',
    $q$INSERT INTO rules.param_value (package_id, key, effective_from, value, source_ref, confidence)
       VALUES ('c5000000-0000-7000-8000-00000000f001', 'payroll.wage.min_daily', '2026-06-01', '{"amount":"5","unit":"IRR"}', 'TT', 'high')$q$,
    '23P01');
  PERFORM public.cp_expect_error('INV-RUL-04 verified needs confidence',
    $q$INSERT INTO rules.param_value (package_id, key, effective_from, value, source_ref, confidence, verified_official)
       VALUES ('c5000000-0000-7000-8000-00000000f001', 'payroll.ssi.employee_rate', '2026-03-21', '{"v":"0.07"}', 'TT', 'low', true)$q$,
    '23514');
END $$;

-- G04 مالکیت کلید: بستهٔ حقوق نمی‌تواند مقدار کلید مالیاتی داشته باشد (بستهٔ جدا که رد می‌شود)
INSERT INTO rules.package (id, code, version, seq, covers_from, min_engine_version, payload_sha256, hksb_sha256, signer_kid,
                           published_at, authored_by, approved_by, changelog_fa, installed_via) VALUES
  ('c5000000-0000-7000-8000-00000000f009', 'ir.payroll', '1405.9', 9, '2026-03-21', '2026.1.0', sha256('p9'), sha256('h9'), 'rules-test-a',
   now(), 'author@platform', '{approver@platform}', 'بستهٔ آزمایشی نادرست', 'test_fixture');
INSERT INTO rules.param_value (package_id, key, effective_from, value, source_ref, confidence) VALUES
  ('c5000000-0000-7000-8000-00000000f009', 'tax.vat.general_rate', '2026-03-21', '{"v":"10"}', 'TT', 'high');
DO $$
BEGIN
  PERFORM public.cp_expect_error('INV-RUL-02 incomplete package',
    $q$UPDATE rules.package SET status = 'installed' WHERE id = 'c5000000-0000-7000-8000-00000000f009'$q$, 'HK_RULES_PACKAGE_INCOMPLETE');
END $$;
INSERT INTO rules.golden_test (package_id, code, calculator, as_of, input, expected, signed_by) VALUES
  ('c5000000-0000-7000-8000-00000000f009', 'x', 'payroll.payslip', '2026-04-20', '{}', '{}', 'حسابدار آزمون');
DO $$
BEGIN
  PERFORM public.cp_expect_error('INV-RUL-06 key owned by another package code',
    $q$UPDATE rules.package SET status = 'installed' WHERE id = 'c5000000-0000-7000-8000-00000000f009'$q$, 'HK_RULES_KEY_NOT_OWNED');
  PERFORM public.cp_expect_error('INV-RUL-02 reject needs reason',
    $q$UPDATE rules.package SET status = 'rejected', end_reason = 'بد' WHERE id = 'c5000000-0000-7000-8000-00000000f009'$q$, 'HK_RULES_REASON_REQUIRED');
  UPDATE rules.package SET status = 'rejected', end_reason = 'مالکیت کلید نادرست است' WHERE id = 'c5000000-0000-7000-8000-00000000f009';
  PERFORM public.cp_assert((SELECT ended_at IS NOT NULL FROM rules.package WHERE id = 'c5000000-0000-7000-8000-00000000f009'), 'INV-RUL-02 rejected stamped');
  PERFORM public.cp_expect_error('INV-RUL-02 rejected is terminal',
    $q$UPDATE rules.package SET status = 'installed', ended_at = NULL, end_reason = NULL WHERE id = 'c5000000-0000-7000-8000-00000000f009'$q$, 'HK_RULES_PACKAGE_TRANSITION');
END $$;

-- G05 نصب ← installed؛ محتوا مهر می‌شود؛ فعال‌سازی فقط با آزمون طلایی کامل و موفق روی نسخهٔ جاری موتور
UPDATE rules.package SET status = 'installed' WHERE id IN ('c5000000-0000-7000-8000-00000000f001','c5000000-0000-7000-8000-00000000f002',
                                                           'c5000000-0000-7000-8000-00000000f003');
DO $$
DECLARE v_engine text := current_setting('cp.engine');
BEGIN
  PERFORM public.cp_expect_error('INV-RUL-02 sealed content',
    $q$INSERT INTO rules.param_value (package_id, key, effective_from, value, source_ref, confidence)
       VALUES ('c5000000-0000-7000-8000-00000000f001', 'payroll.ssi.employee_rate', '2026-03-21', '{"v":"0.07"}', 'TT', 'high')$q$,
    'HK_RULES_PACKAGE_SEALED');
  PERFORM public.cp_expect_error('INV-RUL-02 sealed golden tests',
    $q$INSERT INTO rules.golden_test (package_id, code, calculator, as_of, input, expected, signed_by)
       VALUES ('c5000000-0000-7000-8000-00000000f001', 'late', 'payroll.payslip', '2026-04-20', '{}', '{}', 'x1')$q$,
    'HK_RULES_PACKAGE_SEALED');
  PERFORM public.cp_expect_error('INV-RUL-02 value immutable',
    $q$UPDATE rules.param_value SET value = '{"amount":"1","unit":"IRR"}' WHERE id = 'c5000000-0000-7000-8000-00000000f101'$q$, 'HK_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-RUL-02 value no delete',
    $q$DELETE FROM rules.param_value WHERE id = 'c5000000-0000-7000-8000-00000000f101'$q$, 'HK_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-RUL-02 package no delete',
    $q$DELETE FROM rules.package WHERE id = 'c5000000-0000-7000-8000-00000000f001'$q$, 'HK_RULES_PACKAGE_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-RUL-02 package content columns immutable',
    $q$UPDATE rules.package SET changelog_fa = 'دستکاری' WHERE id = 'c5000000-0000-7000-8000-00000000f001'$q$, 'HK_RULES_PACKAGE_IMMUTABLE');
  -- G06 دروازهٔ طلایی
  PERFORM public.cp_expect_error('INV-RUL-07 activation without golden run',
    $q$UPDATE rules.package SET status = 'active' WHERE id = 'c5000000-0000-7000-8000-00000000f001'$q$, 'HK_RULES_GOLDEN_NOT_PASSED');
  PERFORM public.cp_expect_error('INV-RUL-07 partial golden run',
    format($q$INSERT INTO rules.golden_run (package_id, engine_version, runner, total, passed, failed, outcome, started_at)
              VALUES ('c5000000-0000-7000-8000-00000000f001', %L, 'install', 1, 1, 0, 'passed', now())$q$, v_engine), 'HK_RULES_GOLDEN_RUN_PARTIAL');
  PERFORM public.cp_expect_error('INV-RUL-07 outcome consistent with counts',
    format($q$INSERT INTO rules.golden_run (package_id, engine_version, runner, total, passed, failed, outcome, started_at)
              VALUES ('c5000000-0000-7000-8000-00000000f001', %L, 'install', 2, 1, 1, 'passed', now())$q$, v_engine), '23514');
  INSERT INTO rules.golden_run (package_id, engine_version, runner, total, passed, failed, outcome, failures, started_at)
  VALUES ('c5000000-0000-7000-8000-00000000f001', v_engine, 'install', 2, 1, 1, 'failed', '[{"code":"min-single"}]', now());
  PERFORM public.cp_expect_error('INV-RUL-07 failed golden run blocks',
    $q$UPDATE rules.package SET status = 'active' WHERE id = 'c5000000-0000-7000-8000-00000000f001'$q$, 'HK_RULES_GOLDEN_NOT_PASSED');
  INSERT INTO rules.golden_run (package_id, engine_version, runner, total, passed, failed, outcome, started_at)
  VALUES ('c5000000-0000-7000-8000-00000000f001', '2025.1.0', 'ci', 2, 2, 0, 'passed', now());
  PERFORM public.cp_expect_error('INV-RUL-07 golden run of another engine version',
    $q$UPDATE rules.package SET status = 'active' WHERE id = 'c5000000-0000-7000-8000-00000000f001'$q$, 'HK_RULES_GOLDEN_NOT_PASSED');
  PERFORM public.cp_expect_error('INV-RUL-07 golden run immutable',
    $q$UPDATE rules.golden_run SET outcome = 'passed', passed = 2, failed = 0 WHERE outcome = 'failed'$q$, 'HK_IMMUTABLE');
  INSERT INTO rules.golden_run (package_id, engine_version, runner, total, passed, failed, outcome, started_at)
  SELECT p, v_engine, 'install', (SELECT count(*) FROM rules.golden_test WHERE package_id = p), (SELECT count(*) FROM rules.golden_test WHERE package_id = p),
         0, 'passed', now()
    FROM unnest(ARRAY['c5000000-0000-7000-8000-00000000f001','c5000000-0000-7000-8000-00000000f002','c5000000-0000-7000-8000-00000000f003']::uuid[]) p;
  UPDATE rules.package SET status = 'active' WHERE id IN ('c5000000-0000-7000-8000-00000000f001','c5000000-0000-7000-8000-00000000f002',
                                                         'c5000000-0000-7000-8000-00000000f003');
  PERFORM public.cp_assert((SELECT count(*) FROM rules.package WHERE status = 'active') = 3, 'INV-RUL-07 three packages active');
  PERFORM public.cp_assert((SELECT count(*) FROM rules.package_event WHERE package_id = 'c5000000-0000-7000-8000-00000000f001') = 3,
                           'INV-RUL-08 lifecycle events logged (installing, installed, active)');
  PERFORM public.cp_expect_error('INV-RUL-08 package events immutable',
    $q$DELETE FROM rules.package_event$q$, 'HK_IMMUTABLE');
  -- G07 ارزیابی
  PERFORM public.cp_assert((rules.value_at('payroll.wage.min_daily', '2026-04-01')).value ->> 'amount' = '1000000', 'INV-RUL-09 value_at');
  PERFORM public.cp_assert((rules.value_at('payroll.rate.shift', '2026-04-01', 'me')).value ->> 'v' = '0.10', 'INV-RUL-09 value_at qualifier');
  PERFORM public.cp_expect_error('INV-RUL-09 no value before range', $q$SELECT rules.value_at('payroll.wage.min_daily', '2020-01-01')$q$, 'HK_RULES_NO_VALUE');
  PERFORM public.cp_expect_error('INV-RUL-09 no active package', $q$SELECT rules.value_at('calendar.due_rule', '2026-04-01', 'tax.vat.quarterly_return')$q$, 'HK_RULES_NO_ACTIVE_PACKAGE');
  PERFORM public.cp_expect_error('INV-RUL-09 unknown key', $q$SELECT rules.value_at('payroll.nope', '2026-04-01')$q$, 'HK_RULES_KEY_UNKNOWN');
END $$;

-- G08 بستهٔ قدیمی‌تر پس از فعال‌سازی نسخهٔ بالاتر فعال نمی‌شود؛ موتور قدیمی‌تر از حداقل
INSERT INTO rules.package (id, code, version, seq, covers_from, min_engine_version, payload_sha256, hksb_sha256, signer_kid,
                           published_at, authored_by, approved_by, changelog_fa, installed_via) VALUES
  ('c5000000-0000-7000-8000-00000000f004', 'ir.payroll', '1404.9', 1, '2025-03-21', '2026.1.0', sha256('p4'), sha256('h4'), 'rules-test-a',
   now(), 'author@platform', '{approver@platform}', 'بستهٔ قدیمی', 'test_fixture'),
  ('c5000000-0000-7000-8000-00000000f005', 'ir.calendar', '1405.1', 1, '2026-03-21', '2099.1.0', sha256('p5'), sha256('h5'), 'rules-test-a',
   now(), 'author@platform', '{approver@platform}', 'تقویم برای موتور آینده', 'test_fixture');
INSERT INTO rules.param_value (package_id, key, effective_from, value, source_ref, confidence) VALUES
  ('c5000000-0000-7000-8000-00000000f004', 'payroll.wage.min_daily', '2025-03-21', '{"amount":"900000","unit":"IRR"}', 'TEST-ONLY', 'high');
INSERT INTO rules.param_value (package_id, key, qualifier, effective_from, value, source_ref, confidence) VALUES
  ('c5000000-0000-7000-8000-00000000f005', 'calendar.due_rule', 'tax.vat.quarterly_return', '2026-03-21',
   '{"v":{"anchor":"period_end","offset_months":1,"align":"end_of_month"}}', 'TEST-ONLY', 'medium');
INSERT INTO rules.golden_test (package_id, code, calculator, as_of, input, expected, signed_by) VALUES
  ('c5000000-0000-7000-8000-00000000f004', 'old', 'payroll.payslip', '2025-04-20', '{}', '{}', 'حسابدار آزمون'),
  ('c5000000-0000-7000-8000-00000000f005', 'due', 'calendar.due_date', '2026-06-21', '{}', '{}', 'حسابدار آزمون');
UPDATE rules.package SET status = 'installed' WHERE id IN ('c5000000-0000-7000-8000-00000000f004','c5000000-0000-7000-8000-00000000f005');
INSERT INTO rules.golden_run (package_id, engine_version, runner, total, passed, failed, outcome, started_at)
SELECT p, :'engine', 'install', 1, 1, 0, 'passed', now()
  FROM unnest(ARRAY['c5000000-0000-7000-8000-00000000f004','c5000000-0000-7000-8000-00000000f005']::uuid[]) p;
DO $$
BEGIN
  PERFORM public.cp_expect_error('INV-RUL-10 older seq cannot be activated',
    $q$UPDATE rules.package SET status = 'active' WHERE id = 'c5000000-0000-7000-8000-00000000f004'$q$, 'HK_RULES_PACKAGE_OUTDATED');
  PERFORM public.cp_expect_error('INV-RUL-10 engine too old',
    $q$UPDATE rules.package SET status = 'active' WHERE id = 'c5000000-0000-7000-8000-00000000f005'$q$, 'HK_RULES_ENGINE_TOO_OLD');
  PERFORM public.cp_expect_error('INV-RUL-10 one active per code (direct supersede forbidden)',
    $q$UPDATE rules.package SET status = 'superseded', superseded_at = now(), superseded_by = 'c5000000-0000-7000-8000-00000000f004'
        WHERE id = 'c5000000-0000-7000-8000-00000000f001'$q$, 'HK_RULES_PACKAGE_TRANSITION');
END $$;

-- G09 دادهٔ مرجع تازه: نرخ sstid بدون هم‌پوشانی
INSERT INTO ref.sstid_vat_rate (sstid, effective_from, vat_rate, snapshot_version, synced_at) VALUES ('2710000138624', '2026-03-21', 10, 'test-v1', now());
DO $$
BEGIN
  PERFORM public.cp_expect_error('INV-TAX-20 sstid rate overlap',
    $q$INSERT INTO ref.sstid_vat_rate (sstid, effective_from, vat_rate, snapshot_version, synced_at) VALUES ('2710000138624', '2026-06-01', 9, 'test-v2', now())$q$,
    '23P01');
END $$;

-- =====================================================================
-- بخش ۲: ادعاها با نقش برنامه (hk_app)
-- =====================================================================
SET ROLE hk_app;
SELECT public.cp_assert(current_user = 'hk_app', 'running as hk_app') \gset

-- ---------- T00: hk_app جدول‌های سراسری rules را نمی‌نویسد (INV-RUL-11) ----------
DO $$
BEGIN
  PERFORM public.cp_expect_error('INV-RUL-11 app cannot install packages',
    $q$INSERT INTO rules.package (id, code, version, seq, covers_from, min_engine_version, payload_sha256, hksb_sha256, signer_kid,
         published_at, authored_by, approved_by, changelog_fa, installed_via)
       VALUES (uuidv7(), 'ir.general', '1405.1', 1, '2026-03-21', '2026.1.0', sha256('x'), sha256('y'), 'k-1', now(), 'a1', '{b1}', 'x', 'test_fixture')$q$, '42501');
  PERFORM public.cp_expect_error('INV-RUL-11 app cannot write values',
    $q$INSERT INTO rules.param_value (package_id, key, effective_from, value, source_ref, confidence)
       VALUES ('c5000000-0000-7000-8000-00000000f001', 'payroll.ssi.employee_rate', '2026-03-21', '{"v":"0.07"}', 'TT', 'high')$q$, '42501');
  PERFORM public.cp_expect_error('INV-RUL-11 app cannot activate', $q$UPDATE rules.package SET status = 'withdrawn'$q$, '42501');
  PERFORM public.cp_expect_error('INV-RUL-11 app cannot record golden runs',
    $q$INSERT INTO rules.golden_run (package_id, engine_version, runner, total, passed, failed, outcome, started_at)
       VALUES ('c5000000-0000-7000-8000-00000000f004', '2026.11.0', 'manual', 1, 1, 0, 'passed', now())$q$, '42501');
  PERFORM public.cp_expect_error('INV-RUL-11 app cannot change ref data',
    $q$INSERT INTO ref.sstid_vat_rate (sstid, effective_from, vat_rate, snapshot_version, synced_at) VALUES ('2710000138625', '2026-03-21', 10, 't', now())$q$, '42501');
  PERFORM public.cp_assert((SELECT count(*) FROM rules.param_def) > 60, 'INV-RUL-11 app reads definitions');
  PERFORM public.cp_assert((SELECT count(*) FROM rules.tax_category WHERE code = 'standard') = 1, 'INV-RUL-11 app reads tax categories');
  PERFORM public.cp_expect_error('INV-RUL-11 app cannot add tax categories',
    $q$INSERT INTO rules.tax_category (code, kind, title_key, introduced_in) VALUES ('luxury', 'vat', 'x', '1.0')$q$, '42501');
END $$;

-- ---------- T01: جایگزینی مجاز پارامتر و مقدار مؤثر (INV-RUL-12) ----------
DO $$
DECLARE t uuid := 'c5a00000-0000-7000-8000-000000000001'; c uuid := 'c5a00000-0000-7000-8000-0000000000c1';
        u1 uuid := 'c5000000-0000-7000-8000-0000000000e1'; u2 uuid := 'c5000000-0000-7000-8000-0000000000e2';
        w2 uuid := 'c5a00000-0000-7000-8000-000000001002'; w3 uuid := 'c5a00000-0000-7000-8000-000000001003';
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  PERFORM public.cp_expect_error('INV-RUL-12 level not allowed',
    format($q$INSERT INTO rules.param_override (tenant_id, scope_level, key, effective_from, value, basis_kind, basis_ref, created_by, approved_by)
              VALUES (%L, 'tenant', 'payroll.wage.min_daily', '2026-03-21', '{"amount":"1200000","unit":"IRR"}', 'company_policy', 'سیاست', %L, %L)$q$, t, u1, u1),
    'HK_RULES_OVERRIDE_NOT_ALLOWED');
  PERFORM public.cp_expect_error('INV-RUL-12 key not overridable',
    format($q$INSERT INTO rules.param_override (tenant_id, scope_level, company_id, key, effective_from, value, basis_kind, basis_ref, created_by, approved_by)
              VALUES (%L, 'company', %L, 'payroll.ssi.employee_rate', '2026-03-21', '{"v":"0.05"}', 'company_policy', 'سیاست', %L, %L)$q$, t, c, u1, u1),
    'HK_RULES_OVERRIDE_NOT_ALLOWED');
  PERFORM public.cp_expect_error('INV-RUL-12 below floor without collective agreement',
    format($q$INSERT INTO rules.param_override (tenant_id, scope_level, company_id, workshop_ref, key, effective_from, value, basis_kind, basis_ref, created_by, approved_by)
              VALUES (%L, 'workshop', %L, %L, 'payroll.wage.min_daily', '2026-03-21', '{"amount":"800000","unit":"IRR"}', 'company_policy', 'سیاست', %L, %L)$q$, t, c, w2, u1, u2),
    'HK_RULES_OVERRIDE_BELOW_FLOOR');
  PERFORM public.cp_expect_error('INV-RUL-12 collective agreement needs a second approver',
    format($q$INSERT INTO rules.param_override (tenant_id, scope_level, company_id, workshop_ref, key, effective_from, value, basis_kind, basis_ref, created_by, approved_by)
              VALUES (%L, 'workshop', %L, %L, 'payroll.wage.min_daily', '2026-03-21', '{"amount":"800000","unit":"IRR"}', 'collective_agreement', 'پیمان ۱۲', %L, %L)$q$, t, c, w2, u1, u1),
    '23514');
  PERFORM public.cp_expect_error('INV-RUL-12 override value type',
    format($q$INSERT INTO rules.param_override (tenant_id, scope_level, company_id, workshop_ref, key, effective_from, value, basis_kind, basis_ref, created_by, approved_by)
              VALUES (%L, 'workshop', %L, %L, 'payroll.wage.min_daily', '2026-03-21', '{"v":"800000"}', 'collective_agreement', 'پیمان ۱۲', %L, %L)$q$, t, c, w2, u1, u2),
    'HK_RULES_VALUE_INVALID');
  PERFORM public.cp_expect_error('INV-RUL-12 scope shape',
    format($q$INSERT INTO rules.param_override (tenant_id, scope_level, company_id, key, effective_from, value, basis_kind, basis_ref, created_by, approved_by)
              VALUES (%L, 'workshop', %L, 'payroll.wage.min_daily', '2026-03-21', '{"amount":"1200000","unit":"IRR"}', 'company_policy', 'سیاست', %L, %L)$q$, t, c, u1, u1),
    '23514');
  INSERT INTO rules.param_override (tenant_id, id, scope_level, company_id, workshop_ref, key, effective_from, value, basis_kind, basis_ref, created_by, approved_by)
  VALUES (t, 'c5a00000-0000-7000-8000-000000000501', 'workshop', c, w2, 'payroll.wage.min_daily', '2026-03-21', '{"amount":"800000","unit":"IRR"}',
          'collective_agreement', 'پیمان دسته‌جمعی ۱۲', u1, u2),
         (t, 'c5a00000-0000-7000-8000-000000000502', 'workshop', c, w3, 'payroll.wage.min_daily', '2026-03-21', '{"amount":"1200000","unit":"IRR"}',
          'company_policy', 'سیاست مزد کارگاه ۳', u1, u1);
  PERFORM public.cp_expect_error('INV-RUL-12 overlapping active overrides',
    format($q$INSERT INTO rules.param_override (tenant_id, scope_level, company_id, workshop_ref, key, effective_from, value, basis_kind, basis_ref, created_by, approved_by)
              VALUES (%L, 'workshop', %L, %L, 'payroll.wage.min_daily', '2026-05-01', '{"amount":"1300000","unit":"IRR"}', 'company_policy', 'سیاست', %L, %L)$q$, t, c, w3, u1, u1),
    '23P01');
  PERFORM public.cp_assert(rules.effective_value('payroll.wage.min_daily', '2026-04-01', '', c, w2) ->> 'amount' = '800000', 'INV-RUL-12 workshop agreement wins');
  PERFORM public.cp_assert(rules.effective_value('payroll.wage.min_daily', '2026-04-01', '', c, w3) ->> 'amount' = '1200000', 'INV-RUL-12 workshop policy wins');
  PERFORM public.cp_assert(rules.effective_value('payroll.wage.min_daily', '2026-04-01', '', c, uuidv7()) ->> 'amount' = '1000000', 'INV-RUL-12 statutory otherwise');
  PERFORM public.cp_expect_error('INV-RUL-12 override immutable',
    $q$UPDATE rules.param_override SET value = '{"amount":"1250000","unit":"IRR"}' WHERE id = 'c5a00000-0000-7000-8000-000000000502'$q$, 'HK_RULES_OVERRIDE_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-RUL-12 override no delete',
    $q$DELETE FROM rules.param_override WHERE id = 'c5a00000-0000-7000-8000-000000000502'$q$, '42501');
  UPDATE rules.param_override SET status = 'revoked', revoked_by = u2, revoked_at = now(), revoke_reason = 'سیاست لغو شد'
   WHERE id = 'c5a00000-0000-7000-8000-000000000502';
  PERFORM public.cp_assert(rules.effective_value('payroll.wage.min_daily', '2026-04-01', '', c, w3) ->> 'amount' = '1000000', 'INV-RUL-12 revoked override ignored');
END $$;

-- ---------- T02: snapshot قواعد (INV-RUL-13) ----------
DO $$
DECLARE t uuid := 'c5a00000-0000-7000-8000-000000000001'; c uuid := 'c5a00000-0000-7000-8000-0000000000c1'; e text := current_setting('cp.engine');
        v_br jsonb := (SELECT value FROM rules.param_value WHERE id = 'c5000000-0000-7000-8000-00000000f104');
        v_content jsonb;
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  v_content := jsonb_build_object('payroll.tax.brackets_monthly', jsonb_build_object('_', v_br),
                                  'payroll.tax.rounding', jsonb_build_object('_', '{"v":"truncate"}'::jsonb),
                                  'payroll.wage.min_daily', jsonb_build_object('_', '{"amount":"1000000","unit":"IRR"}'::jsonb));
  INSERT INTO rules.calc_snapshot (tenant_id, id, company_id, calculator, engine_version, as_of_from, as_of_to, package_ids, value_ids, content, min_confidence, content_sha256)
  VALUES (t, 'c5a00000-0000-7000-8000-000000005001', c, 'payroll.run', e, '2026-03-21', '2026-04-20', ARRAY['c5000000-0000-7000-8000-00000000f001']::uuid[],
          ARRAY['c5000000-0000-7000-8000-00000000f101','c5000000-0000-7000-8000-00000000f104','c5000000-0000-7000-8000-00000000f105']::uuid[],
          v_content, 'high', '\x00'),
         (t, 'c5a00000-0000-7000-8000-000000005002', c, 'payroll.run', e, '2026-03-21', '2026-04-20', ARRAY['c5000000-0000-7000-8000-00000000f001']::uuid[],
          ARRAY['c5000000-0000-7000-8000-00000000f101','c5000000-0000-7000-8000-00000000f104','c5000000-0000-7000-8000-00000000f105','c5000000-0000-7000-8000-00000000f106']::uuid[],
          v_content || '{"payroll.allowance.housing_monthly":{"_":{"amount":"3000000","unit":"IRR"}}}', 'low', '\x00'),
         (t, 'c5a00000-0000-7000-8000-000000005003', c, 'payroll.run', '2099.1.0', '2026-03-21', '2026-04-20', ARRAY['c5000000-0000-7000-8000-00000000f001']::uuid[],
          ARRAY['c5000000-0000-7000-8000-00000000f104','c5000000-0000-7000-8000-00000000f105']::uuid[], v_content, 'high', '\x00'),
         (t, 'c5a00000-0000-7000-8000-000000005004', c, 'tax.moadian_invoice', e, '2026-03-21', '2026-04-20', ARRAY['c5000000-0000-7000-8000-00000000f002']::uuid[],
          ARRAY['c5000000-0000-7000-8000-00000000f201']::uuid[], '{"tax.moadian.send_deadline_days":{"_":{"v":7}}}', 'high', '\x00'),
         (t, 'c5a00000-0000-7000-8000-000000005005', c, 'assets.depreciation', e, '2026-03-21', '2027-03-20', ARRAY['c5000000-0000-7000-8000-00000000f003']::uuid[],
          ARRAY['c5000000-0000-7000-8000-00000000f301','c5000000-0000-7000-8000-00000000f302']::uuid[], '{"assets.depreciation.start_rule":{"_":{"v":"first_day_next_month"}}}', 'low', '\x00');
  PERFORM public.cp_assert((SELECT octet_length(content_sha256) = 32 FROM rules.calc_snapshot WHERE id = 'c5a00000-0000-7000-8000-000000005001'),
                           'INV-RUL-13 hash computed by the database');
  PERFORM public.cp_expect_error('INV-RUL-13 inactive package',
    format($q$INSERT INTO rules.calc_snapshot (tenant_id, company_id, calculator, engine_version, as_of_from, as_of_to, package_ids, value_ids, content, min_confidence, content_sha256)
              VALUES (%L, %L, 'payroll.run', %L, '2025-04-01', '2025-04-30', ARRAY['c5000000-0000-7000-8000-00000000f004']::uuid[],
                      (SELECT array_agg(id) FROM rules.param_value WHERE package_id = 'c5000000-0000-7000-8000-00000000f004'), '{}', 'high', '\x00')$q$, t, c, e),
    'HK_RULES_SNAPSHOT_PACKAGE');
  PERFORM public.cp_expect_error('INV-RUL-13 value outside packages',
    format($q$INSERT INTO rules.calc_snapshot (tenant_id, company_id, calculator, engine_version, as_of_from, as_of_to, package_ids, value_ids, content, min_confidence, content_sha256)
              VALUES (%L, %L, 'payroll.run', %L, '2026-04-01', '2026-04-30', ARRAY['c5000000-0000-7000-8000-00000000f001']::uuid[],
                      ARRAY['c5000000-0000-7000-8000-00000000f201']::uuid[], '{}', 'high', '\x00')$q$, t, c, e),
    'HK_RULES_SNAPSHOT_VALUE');
  PERFORM public.cp_expect_error('INV-RUL-13 confidence must be the minimum',
    format($q$INSERT INTO rules.calc_snapshot (tenant_id, company_id, calculator, engine_version, as_of_from, as_of_to, package_ids, value_ids, content, min_confidence, content_sha256)
              VALUES (%L, %L, 'payroll.run', %L, '2026-04-01', '2026-04-30', ARRAY['c5000000-0000-7000-8000-00000000f001']::uuid[],
                      ARRAY['c5000000-0000-7000-8000-00000000f101','c5000000-0000-7000-8000-00000000f106']::uuid[], '{"x":1}', 'high', '\x00')$q$, t, c, e),
    'HK_RULES_SNAPSHOT_CONFIDENCE');
  PERFORM public.cp_expect_error('INV-RUL-13 revoked override',
    format($q$INSERT INTO rules.calc_snapshot (tenant_id, company_id, calculator, engine_version, as_of_from, as_of_to, package_ids, value_ids, override_ids, content, min_confidence, content_sha256)
              VALUES (%L, %L, 'payroll.run', %L, '2026-04-01', '2026-04-30', ARRAY['c5000000-0000-7000-8000-00000000f001']::uuid[],
                      ARRAY['c5000000-0000-7000-8000-00000000f101']::uuid[], ARRAY['c5a00000-0000-7000-8000-000000000502']::uuid[], '{"y":1}', 'high', '\x00')$q$, t, c, e),
    'HK_RULES_SNAPSHOT_OVERRIDE');
  PERFORM public.cp_expect_error('INV-RUL-13 identical content deduplicated',
    format($q$INSERT INTO rules.calc_snapshot (tenant_id, company_id, calculator, engine_version, as_of_from, as_of_to, package_ids, value_ids, content, min_confidence, content_sha256)
              SELECT tenant_id, company_id, calculator, engine_version, as_of_from, as_of_to, package_ids, value_ids, content, min_confidence, '\x01'
                FROM rules.calc_snapshot WHERE id = 'c5a00000-0000-7000-8000-000000005004'$q$), '23505');
  PERFORM public.cp_expect_error('INV-RUL-13 snapshot immutable',
    $q$UPDATE rules.calc_snapshot SET min_confidence = 'low' WHERE id = 'c5a00000-0000-7000-8000-000000005001'$q$, '42501');
  PERFORM public.cp_expect_error('INV-RUL-13 snapshot no delete',
    $q$DELETE FROM rules.calc_snapshot WHERE id = 'c5a00000-0000-7000-8000-000000005001'$q$, '42501');
END $$;

-- ---------- T03: تقویم انطباق (INV-RUL-14) ----------
DO $$
DECLARE t uuid := 'c5a00000-0000-7000-8000-000000000001'; c uuid := 'c5a00000-0000-7000-8000-0000000000c1';
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  INSERT INTO rules.compliance_item (tenant_id, id, company_id, obligation_code, period_key, period_start, period_end, base_due_date, due_date, rule_snapshot_id)
  VALUES (t, 'c5a00000-0000-7000-8000-000000000601', c, 'tax.vat.quarterly_return', 'jq:1405Q1', '2026-03-21', '2026-06-21', '2026-07-22', '2026-07-22',
          'c5a00000-0000-7000-8000-000000005004');
  PERFORM public.cp_expect_error('INV-RUL-14 due before base due',
    format($q$INSERT INTO rules.compliance_item (tenant_id, company_id, obligation_code, period_key, period_start, period_end, base_due_date, due_date, rule_snapshot_id)
              VALUES (%L, %L, 'tax.art169.quarterly_list', 'jq:1405Q1', '2026-03-21', '2026-06-21', '2026-08-05', '2026-08-01', 'c5a00000-0000-7000-8000-000000005004')$q$, t, c),
    '23514');
  PERFORM public.cp_expect_error('INV-RUL-14 invalid period key',
    format($q$INSERT INTO rules.compliance_item (tenant_id, company_id, obligation_code, period_key, period_start, period_end, base_due_date, due_date, rule_snapshot_id)
              VALUES (%L, %L, 'tax.art169.quarterly_list', 'q:1405-1', '2026-03-21', '2026-06-21', '2026-08-05', '2026-08-05', 'c5a00000-0000-7000-8000-000000005004')$q$, t, c),
    '23514');
  PERFORM public.cp_expect_error('INV-RUL-14 one item per obligation and period',
    format($q$INSERT INTO rules.compliance_item (tenant_id, company_id, obligation_code, period_key, period_start, period_end, base_due_date, due_date, rule_snapshot_id)
              VALUES (%L, %L, 'tax.vat.quarterly_return', 'jq:1405Q1', '2026-03-21', '2026-06-21', '2026-07-22', '2026-07-22', 'c5a00000-0000-7000-8000-000000005004')$q$, t, c),
    '23505');
  PERFORM public.cp_expect_error('INV-RUL-14 due date never moves backward',
    $q$UPDATE rules.compliance_item SET due_date = '2026-07-20' WHERE id = 'c5a00000-0000-7000-8000-000000000601'$q$, 'HK_RULES_COMPLIANCE_DUE_BACKWARD');
  UPDATE rules.compliance_item SET due_date = '2026-08-15' WHERE id = 'c5a00000-0000-7000-8000-000000000601';
  PERFORM public.cp_expect_error('INV-RUL-14 done needs evidence',
    $q$UPDATE rules.compliance_item SET status = 'done', completed_at = now() WHERE id = 'c5a00000-0000-7000-8000-000000000601'$q$, '23514');
  PERFORM public.cp_expect_error('INV-RUL-14 n/a needs reason',
    $q$UPDATE rules.compliance_item SET status = 'not_applicable' WHERE id = 'c5a00000-0000-7000-8000-000000000601'$q$, '23514');
  UPDATE rules.compliance_item SET status = 'done', completed_at = now(), evidence_module = 'tax', evidence_ref = uuidv7()
   WHERE id = 'c5a00000-0000-7000-8000-000000000601';
  PERFORM public.cp_expect_error('INV-RUL-14 done item frozen',
    $q$UPDATE rules.compliance_item SET due_date = '2026-09-01' WHERE id = 'c5a00000-0000-7000-8000-000000000601'$q$, 'HK_RULES_COMPLIANCE_IMMUTABLE');
  UPDATE rules.compliance_item SET last_reminded_at = now() WHERE id = 'c5a00000-0000-7000-8000-000000000601';
  PERFORM public.cp_expect_error('INV-RUL-14 done item kept',
    $q$DELETE FROM rules.compliance_item WHERE id = 'c5a00000-0000-7000-8000-000000000601'$q$, 'HK_RULES_COMPLIANCE_IMMUTABLE');
END $$;

-- ---------- T04: taxid با جدول Verhoeff رسمی و بردارهای مشترک (INV-TAX-01) ----------
DO $$
DECLARE v jsonb := current_setting('cp.vectors')::jsonb; x jsonb; s text;
BEGIN
  FOR x IN SELECT * FROM jsonb_array_elements(v->'official') LOOP
    PERFORM public.cp_assert(tax.taxid_control_string(x->>'memory', (x->>'day')::int, (x->>'serial')::bigint) = x->>'control',
                             'INV-TAX-01 control string ' || (x->>'taxid'));
    PERFORM public.cp_assert(tax.taxid_build(x->>'memory', (x->>'day')::int, (x->>'serial')::bigint) = x->>'taxid', 'INV-TAX-01 official vector ' || (x->>'taxid'));
    PERFORM public.cp_assert(tax.taxid_valid(x->>'taxid'), 'INV-TAX-01 official vector valid ' || (x->>'taxid'));
    -- آزمون منفی اجباری: Verhoeff درسی رقم دیگری می‌دهد و آن رقم رد می‌شود
    s := substr(x->>'taxid', 1, 21) || public.cp_std_verhoeff(x->>'control')::text;
    PERFORM public.cp_assert(s = x->>'standard_verhoeff_taxid', 'INV-TAX-01 textbook Verhoeff reproduces the wrong digit ' || s);
    PERFORM public.cp_assert(s <> x->>'taxid' AND NOT tax.taxid_valid(s), 'INV-TAX-01 textbook Verhoeff digit must be rejected ' || s);
  END LOOP;
  FOR x IN SELECT * FROM jsonb_array_elements(v->'accepted') LOOP
    PERFORM public.cp_assert(tax.taxid_valid(x #>> '{}'), 'INV-TAX-01 accepted taxid ' || (x #>> '{}'));
  END LOOP;
  FOR x IN SELECT * FROM jsonb_array_elements(v->'invalid') LOOP
    PERFORM public.cp_assert(NOT coalesce(tax.taxid_valid(x #>> '{}'), false), 'INV-TAX-01 invalid taxid ' || (x #>> '{}'));
  END LOOP;
  FOR x IN SELECT * FROM jsonb_array_elements(v->'line_math') LOOP
    PERFORM public.cp_assert(trunc((x->>'am')::numeric * (x->>'fee')::numeric, 0) = (x->>'prdis')::numeric, 'INV-TAX-03 prdis ' || (x->>'label'));
    PERFORM public.cp_assert(tax.moadian_part((x->>'adis')::numeric, (x->>'vra')::numeric, 0::smallint) = (x->>'vam')::numeric, 'INV-TAX-03 vam ' || (x->>'label'));
  END LOOP;
  PERFORM public.cp_assert(tax.verhoeff_check_digit('12a') IS NULL, 'INV-TAX-01 non-digit input');
END $$;

-- ---------- T05: حافظهٔ مالیاتی و کلید امضا (INV-TAX-02، INV-TAX-12، INV-TAX-13) ----------
DO $$
DECLARE t uuid := 'c5a00000-0000-7000-8000-000000000001'; c uuid := 'c5a00000-0000-7000-8000-0000000000c1';
        u1 uuid := 'c5000000-0000-7000-8000-0000000000e1'; d1 uuid := 'c5a00000-0000-7000-8000-0000000000d1';
        spki bytea := decode(repeat('30', 294), 'hex');
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  INSERT INTO core.number_series (tenant_id, id, company_id, code, name, doc_type, scope, allocation, pattern, reset_policy, start_value, is_default) VALUES
    (t, 'c5a00000-0000-7000-8000-000000006101', c, 'tax-def5gh', 'سریال DEF5GH', 'tax.moadian_serial', 'company', 'server', '{seq}', 'never', 1, false),
    (t, 'c5a00000-0000-7000-8000-000000006102', c, 'tax-a2hp31', 'سریال A2HP31', 'tax.moadian_serial', 'company', 'server', '{seq}', 'never', 500, false),
    (t, 'c5a00000-0000-7000-8000-000000006103', c, 'tax-wrong', 'نوع اشتباه', 'tax.other_serial', 'company', 'server', '{seq}', 'never', 1, false),
    (t, 'c5a00000-0000-7000-8000-000000006104', c, 'tax-dev', 'سریال دستگاه', 'tax.moadian_serial', 'company', 'server', '{seq}', 'never', 1, false),
    (t, 'c5a00000-0000-7000-8000-000000006105', c, 'tax-v2', 'سریال v2', 'tax.moadian_serial', 'company', 'server', '{seq}', 'never', 1, false),
    (t, 'c5a00000-0000-7000-8000-000000006106', c, 'tax-spare', 'سریال یدک', 'tax.moadian_serial', 'company', 'server', '{seq}', 'never', 1, false);
  INSERT INTO tax.memory (tenant_id, id, company_id, memory_id, label, send_mode, adapter, environment, key_custody, allocation, serial_series_id, created_by)
  VALUES (t, 'c5a00000-0000-7000-8000-000000006001', c, 'DEF5GH', 'حافظهٔ اصلی', 'taxpayer', 'direct_v1_self_tsp', 'production', 'server_kms', 'server',
          'c5a00000-0000-7000-8000-000000006101', u1),
         (t, 'c5a00000-0000-7000-8000-000000006002', c, 'A2HP31', 'حافظهٔ دوم (راه‌اندازی‌نشده)', 'taxpayer', 'direct_v1_self_tsp', 'production', 'server_kms', 'server',
          'c5a00000-0000-7000-8000-000000006102', u1),
         (t, 'c5a00000-0000-7000-8000-000000006004', c, 'A11216', 'حافظهٔ API v2', 'taxpayer', 'direct_v2_cert', 'production', 'server_kms', 'server',
          'c5a00000-0000-7000-8000-000000006105', u1);
  INSERT INTO tax.memory (tenant_id, id, company_id, memory_id, label, send_mode, adapter, environment, key_custody, signer_device_id, allocation, serial_series_id, created_by)
  VALUES (t, 'c5a00000-0000-7000-8000-000000006003', c, 'A111DW', 'حافظه با کلید روی دستگاه مشتری', 'taxpayer', 'direct_v1_self_tsp', 'production', 'device_agent', d1,
          'server', 'c5a00000-0000-7000-8000-000000006104', u1);
  PERFORM public.cp_expect_error('INV-TAX-02 forbidden letter I',
    format($q$INSERT INTO tax.memory (tenant_id, company_id, memory_id, label, send_mode, adapter, key_custody, serial_series_id)
              VALUES (%L, %L, 'DEF5GI', 'x', 'taxpayer', 'direct_v1_self_tsp', 'server_kms', 'c5a00000-0000-7000-8000-000000006106')$q$, t, c), '23514');
  PERFORM public.cp_expect_error('INV-TAX-02 reserved letter B',
    format($q$INSERT INTO tax.memory (tenant_id, company_id, memory_id, label, send_mode, adapter, key_custody, serial_series_id)
              VALUES (%L, %L, 'BEF5GH', 'x', 'taxpayer', 'direct_v1_self_tsp', 'server_kms', 'c5a00000-0000-7000-8000-000000006106')$q$, t, c), '23514');
  PERFORM public.cp_expect_error('INV-TAX-02 mock adapter only in mock environment',
    format($q$INSERT INTO tax.memory (tenant_id, company_id, memory_id, label, send_mode, adapter, environment, key_custody, serial_series_id)
              VALUES (%L, %L, 'DEF5GK', 'x', 'taxpayer', 'mock', 'production', 'server_kms', 'c5a00000-0000-7000-8000-000000006106')$q$, t, c), '23514');
  PERFORM public.cp_expect_error('INV-TAX-02 TSP mode needs TSP adapter',
    format($q$INSERT INTO tax.memory (tenant_id, company_id, memory_id, label, send_mode, adapter, key_custody, serial_series_id)
              VALUES (%L, %L, 'DEF5GK', 'x', 'tsp_taxpayer_key', 'direct_v1_self_tsp', 'server_kms', 'c5a00000-0000-7000-8000-000000006106')$q$, t, c), '23514');
  PERFORM public.cp_expect_error('INV-TAX-12 device custody needs a signer device',
    format($q$INSERT INTO tax.memory (tenant_id, company_id, memory_id, label, send_mode, adapter, key_custody, serial_series_id)
              VALUES (%L, %L, 'DEF5GK', 'x', 'taxpayer', 'direct_v1_self_tsp', 'device_agent', 'c5a00000-0000-7000-8000-000000006106')$q$, t, c), '23514');
  PERFORM public.cp_expect_error('INV-TAX-02 serial series must be a Moadian serial series',
    format($q$INSERT INTO tax.memory (tenant_id, company_id, memory_id, label, send_mode, adapter, key_custody, serial_series_id)
              VALUES (%L, %L, 'DEF5GK', 'x', 'taxpayer', 'direct_v1_self_tsp', 'server_kms', 'c5a00000-0000-7000-8000-000000006103')$q$, t, c), 'HK_TAX_MEMORY_SERIES');
  PERFORM public.cp_expect_error('INV-TAX-02 allocation must fit the series',
    $q$UPDATE tax.memory SET allocation = 'device_ranges' WHERE id = 'c5a00000-0000-7000-8000-000000006001'$q$, 'HK_TAX_MEMORY_SERIES');
  PERFORM public.cp_expect_error('INV-TAX-02 one memory per serial series',
    format($q$INSERT INTO tax.memory (tenant_id, company_id, memory_id, label, send_mode, adapter, key_custody, serial_series_id)
              VALUES (%L, %L, 'DEF5GK', 'x', 'taxpayer', 'direct_v1_self_tsp', 'server_kms', 'c5a00000-0000-7000-8000-000000006101')$q$, t, c), '23505');
  PERFORM public.cp_expect_error('INV-TAX-12 activation needs an active key',
    $q$UPDATE tax.memory SET status = 'active', activated_at = now() WHERE id = 'c5a00000-0000-7000-8000-000000006001'$q$, 'HK_TAX_MEMORY_NO_KEY');
  PERFORM public.cp_expect_error('INV-TAX-02 setup cannot be suspended',
    $q$UPDATE tax.memory SET status = 'suspended', activated_at = now() WHERE id = 'c5a00000-0000-7000-8000-000000006001'$q$, 'HK_TAX_MEMORY_TRANSITION');
  -- کلیدها
  PERFORM public.cp_expect_error('INV-TAX-13 server custody needs the liability contract',
    format($q$INSERT INTO tax.memory_key (tenant_id, memory_ref, kind, custody, public_key_spki, key_bits, fingerprint_sha256, private_key_sealed)
              VALUES (%L, 'c5a00000-0000-7000-8000-000000006001', 'rsa_key', 'server_kms', %L, 2048, sha256('k0'), '\x01')$q$, t, spki), '23514');
  PERFORM public.cp_expect_error('INV-TAX-13 sealed blob xor KMS reference',
    format($q$INSERT INTO tax.memory_key (tenant_id, memory_ref, kind, custody, public_key_spki, key_bits, fingerprint_sha256, private_key_sealed, kms_key_ref,
                                          custody_contract_version, custody_contract_accepted_by, custody_contract_accepted_at)
              VALUES (%L, 'c5a00000-0000-7000-8000-000000006001', 'rsa_key', 'server_kms', %L, 2048, sha256('k0'), '\x01', 'transit/x', 'v1', %L, now())$q$, t, spki, u1), '23514');
  PERFORM public.cp_expect_error('INV-TAX-12 key custody must match memory custody',
    format($q$INSERT INTO tax.memory_key (tenant_id, memory_ref, kind, custody, public_key_spki, key_bits, fingerprint_sha256, device_id)
              VALUES (%L, 'c5a00000-0000-7000-8000-000000006001', 'rsa_key', 'device_agent', %L, 2048, sha256('k0'), %L)$q$, t, spki, d1), 'HK_TAX_KEY_CUSTODY');
  PERFORM public.cp_expect_error('INV-TAX-13 keys start pending',
    format($q$INSERT INTO tax.memory_key (tenant_id, memory_ref, kind, custody, public_key_spki, key_bits, fingerprint_sha256, private_key_sealed,
                                          custody_contract_version, custody_contract_accepted_by, custody_contract_accepted_at, status, activated_at, registered_confirmed_at)
              VALUES (%L, 'c5a00000-0000-7000-8000-000000006001', 'rsa_key', 'server_kms', %L, 2048, sha256('k0'), '\x01', 'v1', %L, now(), 'active', now(), now())$q$, t, spki, u1),
    'HK_TAX_KEY_TRANSITION');
  PERFORM public.cp_expect_error('INV-TAX-13 v2 adapter needs a certificate',
    format($q$INSERT INTO tax.memory_key (tenant_id, memory_ref, kind, custody, public_key_spki, key_bits, fingerprint_sha256, private_key_sealed,
                                          custody_contract_version, custody_contract_accepted_by, custody_contract_accepted_at)
              VALUES (%L, 'c5a00000-0000-7000-8000-000000006004', 'rsa_key', 'server_kms', %L, 2048, sha256('k9'), '\x01', 'v1', %L, now())$q$, t, spki, u1),
    'HK_TAX_KEY_CERT_REQUIRED');
  INSERT INTO tax.memory_key (tenant_id, id, memory_ref, kind, custody, public_key_spki, key_bits, fingerprint_sha256, private_key_sealed,
                              custody_contract_version, custody_contract_accepted_by, custody_contract_accepted_at) VALUES
    (t, 'c5a00000-0000-7000-8000-000000006201', 'c5a00000-0000-7000-8000-000000006001', 'rsa_key', 'server_kms', spki, 2048, sha256('k1'), '\x01', 'custody-v1', u1, now()),
    (t, 'c5a00000-0000-7000-8000-000000006202', 'c5a00000-0000-7000-8000-000000006001', 'rsa_key', 'server_kms', spki, 2048, sha256('k2'), '\x02', 'custody-v1', u1, now());
  INSERT INTO tax.memory_key (tenant_id, id, memory_ref, kind, custody, public_key_spki, key_bits, fingerprint_sha256, device_id) VALUES
    (t, 'c5a00000-0000-7000-8000-000000006203', 'c5a00000-0000-7000-8000-000000006003', 'rsa_key', 'device_agent', spki, 2048, sha256('k3'), d1);
  INSERT INTO tax.memory_key (tenant_id, id, memory_ref, kind, custody, public_key_spki, key_bits, fingerprint_sha256, private_key_sealed,
                              certificate_der, cert_subject_serial, cert_not_before, cert_not_after,
                              custody_contract_version, custody_contract_accepted_by, custody_contract_accepted_at) VALUES
    (t, 'c5a00000-0000-7000-8000-000000006204', 'c5a00000-0000-7000-8000-000000006004', 'certificate', 'server_kms', spki, 2048, sha256('k4'), '\x03',
     '\x3082', '14003778990', now() - interval '2 years', now() - interval '1 day', 'custody-v1', u1, now());
  PERFORM public.cp_expect_error('INV-TAX-13 expired certificate cannot be activated',
    $q$UPDATE tax.memory_key SET status = 'active', activated_at = now(), registered_confirmed_at = now() WHERE id = 'c5a00000-0000-7000-8000-000000006204'$q$,
    'HK_TAX_KEY_CERT_EXPIRED');
  PERFORM public.cp_expect_error('INV-TAX-13 active key needs registration confirmation',
    $q$UPDATE tax.memory_key SET status = 'active', activated_at = now() WHERE id = 'c5a00000-0000-7000-8000-000000006201'$q$, '23514');
  UPDATE tax.memory_key SET status = 'active', activated_at = now(), registered_confirmed_at = now()
   WHERE id IN ('c5a00000-0000-7000-8000-000000006201','c5a00000-0000-7000-8000-000000006203');
  PERFORM public.cp_expect_error('INV-TAX-13 one active key per memory',
    $q$UPDATE tax.memory_key SET status = 'active', activated_at = now(), registered_confirmed_at = now() WHERE id = 'c5a00000-0000-7000-8000-000000006202'$q$, '23505');
  PERFORM public.cp_expect_error('INV-TAX-13 key material immutable',
    $q$UPDATE tax.memory_key SET private_key_sealed = '\x09' WHERE id = 'c5a00000-0000-7000-8000-000000006201'$q$, 'HK_TAX_KEY_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-TAX-13 used key never deleted',
    $q$DELETE FROM tax.memory_key WHERE id = 'c5a00000-0000-7000-8000-000000006201'$q$, '42501');
  PERFORM public.cp_expect_error('INV-TAX-13 retire needs reason',
    $q$UPDATE tax.memory_key SET status = 'revoked' WHERE id = 'c5a00000-0000-7000-8000-000000006202'$q$, '23514');
  UPDATE tax.memory_key SET status = 'revoked', retired_at = now(), retire_reason = 'کلید آزمایشی' WHERE id = 'c5a00000-0000-7000-8000-000000006202';
  UPDATE tax.memory SET status = 'active', activated_at = now()
   WHERE id IN ('c5a00000-0000-7000-8000-000000006001','c5a00000-0000-7000-8000-000000006003');
  PERFORM public.cp_expect_error('INV-TAX-02 identity fixed after activation',
    $q$UPDATE tax.memory SET memory_id = 'DEF5GK' WHERE id = 'c5a00000-0000-7000-8000-000000006001'$q$, 'HK_TAX_MEMORY_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-TAX-02 active memory never deleted',
    $q$DELETE FROM tax.memory WHERE id = 'c5a00000-0000-7000-8000-000000006001'$q$, 'HK_TAX_MEMORY_IMMUTABLE');
END $$;

-- ---------- T06: سند مالیاتی و نسخهٔ صادرشده (INV-TAX-01..07) ----------
DO $$
DECLARE t uuid := 'c5a00000-0000-7000-8000-000000000001'; c uuid := 'c5a00000-0000-7000-8000-0000000000c1';
        m1 uuid := 'c5a00000-0000-7000-8000-000000006001'; d10 bigint := public.cp_ms('2026-04-10 06:30:00+00'); v_day int; v_good text;
        l1 jsonb := '[{"sstid":"2710000138624","am":"2","fee":"10000","dis":"500","vra":"9"}]';
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  v_day := (d10 / 86400000)::int;
  INSERT INTO tax.invoice (tenant_id, id, company_id, memory_ref, source_kind, sales_invoice_id, subject, inv_type, pattern, instruction_version) VALUES
    (t, 'c5a00000-0000-7000-8000-000000007001', c, m1, 'sales_invoice', 'c5a00000-0000-7000-8000-0000000b0001', 1, 2, 1, 'RC_IITP.IS-7.8'),
    (t, 'c5a00000-0000-7000-8000-000000007002', c, m1, 'sales_invoice', 'c5a00000-0000-7000-8000-0000000b0002', 1, 1, 1, 'RC_IITP.IS-7.8'),
    (t, 'c5a00000-0000-7000-8000-000000007006', c, m1, 'sales_invoice', 'c5a00000-0000-7000-8000-0000000b0006', 1, 2, 1, 'RC_IITP.IS-7.8'),
    (t, 'c5a00000-0000-7000-8000-000000007007', c, m1, 'sales_invoice', 'c5a00000-0000-7000-8000-0000000b0007', 1, 1, 1, 'RC_IITP.IS-7.8'),
    (t, 'c5a00000-0000-7000-8000-000000007008', c, m1, 'sales_invoice', 'c5a00000-0000-7000-8000-0000000b0008', 1, 2, 1, 'RC_IITP.IS-7.8'),
    (t, 'c5a00000-0000-7000-8000-000000007010', c, m1, 'sales_invoice', 'c5a00000-0000-7000-8000-0000000b0010', 1, 1, 7, 'RC_IITP.IS-7.8'),
    (t, 'c5a00000-0000-7000-8000-000000007011', c, 'c5a00000-0000-7000-8000-000000006002', 'sales_invoice', 'c5a00000-0000-7000-8000-0000000b0011', 1, 2, 1, 'RC_IITP.IS-7.8');
  PERFORM public.cp_expect_error('INV-TAX-04 documents start pending',
    format($q$INSERT INTO tax.invoice (tenant_id, company_id, memory_ref, source_kind, sales_invoice_id, subject, inv_type, pattern, instruction_version, status)
              VALUES (%L, %L, %L, 'sales_invoice', uuidv7(), 1, 2, 1, 'RC_IITP.IS-7.8', 'in_progress')$q$, t, c, m1), 'HK_TAX_INVOICE_TRANSITION');
  PERFORM public.cp_expect_error('INV-TAX-05 original has no reference',
    format($q$INSERT INTO tax.invoice (tenant_id, company_id, memory_ref, source_kind, sales_invoice_id, subject, inv_type, pattern, instruction_version, ref_invoice_id)
              VALUES (%L, %L, %L, 'sales_invoice', uuidv7(), 1, 2, 1, 'RC_IITP.IS-7.8', 'c5a00000-0000-7000-8000-000000007006')$q$, t, c, m1), '23514');
  PERFORM public.cp_expect_error('INV-TAX-05 type 2 not allowed for export pattern',
    format($q$INSERT INTO tax.invoice (tenant_id, company_id, memory_ref, source_kind, sales_invoice_id, subject, inv_type, pattern, instruction_version)
              VALUES (%L, %L, %L, 'sales_invoice', uuidv7(), 1, 2, 7, 'RC_IITP.IS-7.8')$q$, t, c, m1), '23514');
  PERFORM public.cp_expect_error('INV-TAX-05 type 3 only for sales pattern',
    format($q$INSERT INTO tax.invoice (tenant_id, company_id, memory_ref, source_kind, sales_invoice_id, subject, inv_type, pattern, instruction_version)
              VALUES (%L, %L, %L, 'sales_invoice', uuidv7(), 1, 3, 3, 'RC_IITP.IS-7.8')$q$, t, c, m1), '23514');
  PERFORM public.cp_expect_error('INV-TAX-05 no return from sale for export',
    format($q$INSERT INTO tax.invoice (tenant_id, company_id, memory_ref, source_kind, sales_invoice_id, subject, inv_type, pattern, instruction_version, ref_invoice_id, root_invoice_id)
              VALUES (%L, %L, %L, 'sales_invoice', uuidv7(), 4, 1, 7, 'RC_IITP.IS-7.8', 'c5a00000-0000-7000-8000-000000007010', 'c5a00000-0000-7000-8000-000000007010')$q$, t, c, m1), '23514');
  PERFORM public.cp_expect_error('INV-TAX-04 migration has no sales document',
    format($q$INSERT INTO tax.invoice (tenant_id, company_id, memory_ref, source_kind, sales_invoice_id, subject, inv_type, pattern, instruction_version)
              VALUES (%L, %L, %L, 'migration', uuidv7(), 1, 2, 1, 'RC_IITP.IS-7.8')$q$, t, c, m1), '23514');
  PERFORM public.cp_expect_error('INV-TAX-04 one tax document per sales document and subject',
    format($q$INSERT INTO tax.invoice (tenant_id, company_id, memory_ref, source_kind, sales_invoice_id, subject, inv_type, pattern, instruction_version)
              VALUES (%L, %L, %L, 'sales_invoice', 'c5a00000-0000-7000-8000-0000000b0001', 1, 2, 1, 'RC_IITP.IS-7.8')$q$, t, c, m1), '23505');

  -- نسخهٔ معتبر
  PERFORM public.cp_issue(jsonb_build_object('id', 'c5a00000-0000-7000-8000-000000007101', 'invoice', 'c5a00000-0000-7000-8000-000000007001',
                                             'indatim', d10, 'lines', l1));
  PERFORM public.cp_flush();
  PERFORM public.cp_assert((SELECT serial = 1 AND taxid = tax.taxid_build('DEF5GH', v_day, 1) AND tbill = 21255 AND tvam = 1755
                              FROM tax.invoice_issue WHERE id = 'c5a00000-0000-7000-8000-000000007101'), 'INV-TAX-01 taxid built from memory/UTC day/serial');
  PERFORM public.cp_assert((SELECT status FROM tax.invoice WHERE id = 'c5a00000-0000-7000-8000-000000007001') = 'in_progress', 'INV-TAX-04 issuing moves the document in progress');
  PERFORM public.cp_assert((SELECT issue_status = 'prepared' FROM tax.v_sales_moadian_status WHERE sales_invoice_id = 'c5a00000-0000-7000-8000-0000000b0001'),
                           'INV-TAX-04 published status view');

  -- خرابی‌های taxid و سریال
  v_good := tax.taxid_build('DEF5GH', v_day, 2);
  PERFORM public.cp_expect_error('INV-TAX-01 wrong check digit',
    format($q$SELECT public.cp_issue(jsonb_build_object('invoice','c5a00000-0000-7000-8000-000000007006','indatim',%s,'lines',%L::jsonb,'bad_taxid',%L))$q$,
           d10, l1, substr(v_good, 1, 21) || ((substr(v_good, 22, 1)::int + 1) % 10)::text), '23514');
  PERFORM public.cp_expect_error('INV-TAX-01 serial part must equal the serial',
    format($q$SELECT public.cp_issue(jsonb_build_object('invoice','c5a00000-0000-7000-8000-000000007006','indatim',%s,'lines',%L::jsonb,'bad_taxid',%L))$q$,
           d10, l1, tax.taxid_build('DEF5GH', v_day, 99)), '23514');
  PERFORM public.cp_expect_error('INV-TAX-01 day part must equal the UTC day of indatim',
    format($q$SELECT public.cp_issue(jsonb_build_object('invoice','c5a00000-0000-7000-8000-000000007006','indatim',%s,'lines',%L::jsonb,'bad_taxid',%L))$q$,
           d10, l1, tax.taxid_build('DEF5GH', v_day - 1, 2)), '23514');
  PERFORM public.cp_expect_error('INV-TAX-01 memory part must equal the memory',
    format($q$SELECT public.cp_issue(jsonb_build_object('invoice','c5a00000-0000-7000-8000-000000007006','indatim',%s,'lines',%L::jsonb,'bad_taxid',%L))$q$,
           d10, l1, tax.taxid_build('DEF5GK', v_day, 2)), '23514');
  PERFORM public.cp_expect_error('INV-TAX-02 serial must be issued for this issue',
    format($q$SELECT public.cp_issue(jsonb_build_object('invoice','c5a00000-0000-7000-8000-000000007006','indatim',%s,'lines',%L::jsonb,'serial_doc',uuidv7()))$q$,
           d10, l1), 'HK_TAX_SERIAL_NOT_ISSUED');
  PERFORM public.cp_expect_error('INV-TAX-02 memory must be active',
    format($q$SELECT public.cp_issue(jsonb_build_object('invoice','c5a00000-0000-7000-8000-000000007011','indatim',%s,'lines',%L::jsonb))$q$, d10, l1),
    'HK_TAX_MEMORY_NOT_ACTIVE');
  PERFORM public.cp_expect_error('INV-TAX-04 one open issue per document',
    format($q$SELECT public.cp_issue(jsonb_build_object('invoice','c5a00000-0000-7000-8000-000000007001','issue_no',2,'indatim',%s,'lines',%L::jsonb))$q$, d10, l1),
    'HK_TAX_ISSUE_STATE');
  PERFORM public.cp_expect_error('INV-TAX-04 issue numbers are consecutive',
    format($q$SELECT public.cp_issue(jsonb_build_object('invoice','c5a00000-0000-7000-8000-000000007006','issue_no',3,'indatim',%s,'lines',%L::jsonb))$q$, d10, l1),
    'HK_TAX_ISSUE_NO');
  PERFORM public.cp_expect_error('INV-TAX-05 type 2 is cash only',
    format($q$SELECT public.cp_issue(jsonb_build_object('invoice','c5a00000-0000-7000-8000-000000007006','indatim',%s,'lines',%L::jsonb,'setm',2))$q$, d10, l1),
    '23514');
  PERFORM public.cp_expect_error('INV-TAX-05 type 1 natural buyer needs TIN or national id + postal code',
    format($q$SELECT public.cp_issue(jsonb_build_object('invoice','c5a00000-0000-7000-8000-000000007007','indatim',%s,'lines',%L::jsonb,
              'buyer_type',1,'buyer_nid','0013542419'))$q$, d10, l1), '23514');
  PERFORM public.cp_expect_error('INV-TAX-05 type 1 legal buyer needs TIN',
    format($q$SELECT public.cp_issue(jsonb_build_object('invoice','c5a00000-0000-7000-8000-000000007007','indatim',%s,'lines',%L::jsonb,
              'buyer_type',2,'buyer_nid','14003778990','buyer_postal','1234567890'))$q$, d10, l1), '23514');
  -- راستی‌آزمایی deferred
  PERFORM public.cp_expect_error_deferred('INV-TAX-03 at least one line',
    format($q$SELECT public.cp_issue(jsonb_build_object('invoice','c5a00000-0000-7000-8000-000000007006','indatim',%s,'lines',%L::jsonb,'no_lines',true))$q$, d10, l1),
    'HK_TAX_ISSUE_NO_LINES');
  PERFORM public.cp_expect_error_deferred('INV-TAX-03 header totals equal the sum of lines',
    format($q$SELECT public.cp_issue(jsonb_build_object('invoice','c5a00000-0000-7000-8000-000000007006','indatim',%s,'drop_last_line_from_header',true,
              'lines','[{"sstid":"2710000138624","am":"1","fee":"1000","vra":"10"},{"sstid":"2710000138625","am":"1","fee":"2000","vra":"10"}]'::jsonb))$q$, d10),
    'HK_TAX_ISSUE_TOTALS');
  PERFORM public.cp_expect_error_deferred('INV-TAX-06 payload must match the stored columns',
    format($q$SELECT public.cp_issue(jsonb_build_object('invoice','c5a00000-0000-7000-8000-000000007006','indatim',%s,'lines',%L::jsonb,'tamper_tbill',1))$q$, d10, l1),
    'HK_TAX_PAYLOAD_MISMATCH');
  -- حساب سطر (قطع، نه گرد)
  PERFORM public.cp_expect_error('INV-TAX-03 vam is truncated, never rounded',
    format($q$INSERT INTO tax.invoice_issue_line (tenant_id, issue_id, line_no, sstid, sstt, mu, am, fee, amount_scale, prdis, dis, adis, vra, vam, tsstam, rate_source)
              VALUES (%L, 'c5a00000-0000-7000-8000-000000007101', 2, '2710000138624', 'x', '1627', 1, 99999, 0, 99999, 0, 99999, 10, 10000, 109999, 'sstid_catalog')$q$, t),
    '23514');
  PERFORM public.cp_expect_error('INV-TAX-03 discount cannot exceed the line amount',
    format($q$INSERT INTO tax.invoice_issue_line (tenant_id, issue_id, line_no, sstid, sstt, mu, am, fee, amount_scale, prdis, dis, adis, vra, vam, tsstam, rate_source)
              VALUES (%L, 'c5a00000-0000-7000-8000-000000007101', 2, '2710000138624', 'x', '1627', 1, 100, 0, 100, 200, -100, 0, 0, -100, 'sstid_catalog')$q$, t),
    '23514');
  PERFORM public.cp_expect_error('INV-TAX-03 zero-rate source implies zero rate',
    format($q$INSERT INTO tax.invoice_issue_line (tenant_id, issue_id, line_no, sstid, sstt, mu, am, fee, amount_scale, prdis, dis, adis, vra, vam, tsstam, rate_source)
              VALUES (%L, 'c5a00000-0000-7000-8000-000000007101', 2, '2710000138624', 'x', '1627', 1, 100, 0, 100, 0, 100, 10, 10, 110, 'not_called_in_zero')$q$, t),
    '23514');
  -- تغییرناپذیری
  PERFORM public.cp_expect_error('INV-TAX-06 payload immutable',
    $q$UPDATE tax.invoice_issue SET payload = payload || '{"x":1}' WHERE id = 'c5a00000-0000-7000-8000-000000007101'$q$, 'HK_TAX_ISSUE_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-TAX-06 serial immutable',
    $q$UPDATE tax.invoice_issue SET serial = 7 WHERE id = 'c5a00000-0000-7000-8000-000000007101'$q$, 'HK_TAX_ISSUE_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-TAX-06 issues are never deleted',
    $q$DELETE FROM tax.invoice_issue WHERE id = 'c5a00000-0000-7000-8000-000000007101'$q$, '42501');
  PERFORM public.cp_expect_error('INV-TAX-06 lines are append-only',
    $q$UPDATE tax.invoice_issue_line SET vam = 0 WHERE issue_id = 'c5a00000-0000-7000-8000-000000007101'$q$, '42501');
  PERFORM public.cp_expect_error('INV-TAX-04 document identity immutable',
    $q$UPDATE tax.invoice SET pattern = 3 WHERE id = 'c5a00000-0000-7000-8000-000000007001'$q$, 'HK_TAX_INVOICE_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-TAX-04 registered needs a successful issue',
    $q$UPDATE tax.invoice SET status = 'registered', registered_issue_id = 'c5a00000-0000-7000-8000-000000007101' WHERE id = 'c5a00000-0000-7000-8000-000000007001'$q$,
    'HK_TAX_INVOICE_EVIDENCE');
  PERFORM public.cp_expect_error('INV-TAX-04 documents are never deleted',
    $q$DELETE FROM tax.invoice WHERE id = 'c5a00000-0000-7000-8000-000000007006'$q$, '42501');
  -- خریدار حقیقی نوع ۱ با کد ملی و کد پستی
  PERFORM public.cp_issue(jsonb_build_object('id', 'c5a00000-0000-7000-8000-000000007107', 'invoice', 'c5a00000-0000-7000-8000-000000007007',
                                             'indatim', d10, 'lines', l1, 'buyer_type', 1, 'buyer_nid', '0013542419', 'buyer_postal', '1234567890'));
END $$;

-- ---------- T07: ارسال، استعلام، ثبت، رد و صدور دوباره (INV-TAX-07..10) ----------
DO $$
DECLARE t uuid := 'c5a00000-0000-7000-8000-000000000001'; c uuid := 'c5a00000-0000-7000-8000-0000000000c1';
        m1 uuid := 'c5a00000-0000-7000-8000-000000006001'; i1 uuid := 'c5a00000-0000-7000-8000-000000007101';
        i2 uuid := 'c5a00000-0000-7000-8000-000000007102'; b1 uuid := 'c5a00000-0000-7000-8000-000000007201'; b2 uuid := 'c5a00000-0000-7000-8000-000000007202';
        l1 jsonb := '[{"sstid":"2710000138624","am":"2","fee":"10000","dis":"500","vra":"9"}]';
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  INSERT INTO tax.send_batch (tenant_id, id, company_id, memory_ref, adapter, environment, item_count, max_items) VALUES
    (t, b1, c, m1, 'direct_v1_self_tsp', 'production', 1, 1000),
    (t, b2, c, m1, 'direct_v1_self_tsp', 'production', 20, 1000);
  PERFORM public.cp_expect_error('INV-TAX-08 batch above the API limit',
    format($q$INSERT INTO tax.send_batch (tenant_id, company_id, memory_ref, adapter, environment, item_count, max_items)
              VALUES (%L, %L, %L, 'direct_v1_self_tsp', 'production', 1001, 1000)$q$, t, c, m1), '23514');
  PERFORM public.cp_expect_error('INV-TAX-07 no inquiry before sending', format($q$SELECT public.cp_inquiry(%L, 'SUCCESS', 'R')$q$, i1), 'HK_TAX_ISSUE_STATE');
  PERFORM public.cp_expect_error('INV-TAX-07 unsigned issue is not sent', format($q$SELECT public.cp_attempt(%L, %L, 'accepted')$q$, i1, b2), 'HK_TAX_ISSUE_STATE');
  PERFORM public.cp_expect_error('INV-TAX-07 prepared cannot jump to sent',
    format($q$UPDATE tax.invoice_issue SET status = 'sent' WHERE id = %L$q$, i1), 'HK_TAX_ISSUE_TRANSITION');
  PERFORM public.cp_sign(i1);
  PERFORM public.cp_expect_error('INV-TAX-06 signature fixed once stored',
    format($q$UPDATE tax.invoice_issue SET jws_sha256 = sha256('other') WHERE id = %L$q$, i1), 'HK_TAX_ISSUE_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-TAX-07 sent needs an archived attempt',
    format($q$UPDATE tax.invoice_issue SET status = 'sent' WHERE id = %L$q$, i1), 'HK_TAX_ISSUE_EVIDENCE');
  PERFORM public.cp_attempt(i1, b1, 'accepted', 'REF-A');
  PERFORM public.cp_assert((SELECT status = 'sent' AND last_reference_number = 'REF-A' FROM tax.invoice_issue WHERE id = i1), 'INV-TAX-07 accepted ⇒ sent');
  PERFORM public.cp_expect_error('INV-TAX-09 inquire before resending', format($q$SELECT public.cp_attempt(%L, %L, 'accepted')$q$, i1, b2), 'HK_TAX_INQUIRE_FIRST');
  PERFORM public.cp_inquiry(i1, 'IN_PROGRESS');
  PERFORM public.cp_assert((SELECT status FROM tax.invoice_issue WHERE id = i1) = 'sent', 'INV-TAX-07 in progress stays sent');
  PERFORM public.cp_expect_error('INV-TAX-07 success needs an archived SUCCESS inquiry',
    format($q$UPDATE tax.invoice_issue SET status = 'success', success_at = now(), success_reference_number = 'FAKE', success_sign_jws = 'x' WHERE id = %L$q$, i1),
    'HK_TAX_ISSUE_EVIDENCE');
  PERFORM public.cp_inquiry(i1, 'SUCCESS', 'REF-A');
  PERFORM public.cp_assert((SELECT status = 'success' AND success_sign_jws IS NOT NULL FROM tax.invoice_issue WHERE id = i1), 'INV-TAX-07 success archived with signed receipt');
  PERFORM public.cp_assert((SELECT status = 'registered' AND registered_issue_id = i1 FROM tax.invoice WHERE id = 'c5a00000-0000-7000-8000-000000007001'),
                           'INV-TAX-04 document registered');
  PERFORM public.cp_expect_error('INV-TAX-09 a registered taxid is never resent', format($q$SELECT public.cp_attempt(%L, %L, 'accepted')$q$, i1, b2), 'HK_TAX_ALREADY_REGISTERED');
  PERFORM public.cp_expect_error('INV-TAX-07 no status inquiry after success', format($q$SELECT public.cp_inquiry(%L, 'SUCCESS', 'REF-A')$q$, i1), 'HK_TAX_ISSUE_STATE');
  PERFORM public.cp_inquiry(i1, 'APPROVED');
  PERFORM public.cp_assert((SELECT buyer_reaction FROM tax.invoice_issue WHERE id = i1) = 'approved', 'INV-TAX-10 buyer reaction tracked');
  PERFORM public.cp_expect_error('INV-TAX-06 attempts append-only', $q$UPDATE tax.submission_attempt SET http_status = 500$q$, '42501');
  PERFORM public.cp_expect_error('INV-TAX-06 inquiries append-only', $q$DELETE FROM tax.inquiry_log$q$, '42501');
  PERFORM public.cp_expect_error('INV-TAX-09 reusing a trace on a registered issue',
    format($q$INSERT INTO tax.submission_attempt (tenant_id, company_id, issue_id, batch_id, attempt_no, request_trace_id, adapter, environment, sent_at,
                                                  transport_outcome, request_sha256)
              SELECT tenant_id, company_id, issue_id, %L, 2, request_trace_id, adapter, environment, now(), 'network_error', request_sha256
                FROM tax.submission_attempt WHERE issue_id = %L$q$, b2, i1), 'HK_TAX_ALREADY_REGISTERED');

  -- مسیر خطای شبکه ← استعلام ← ارسال دوباره ← رد ← صدور دوباره با سریال تازه
  PERFORM public.cp_issue(jsonb_build_object('id', i2, 'invoice', 'c5a00000-0000-7000-8000-000000007002', 'indatim', public.cp_ms('2026-04-11 07:00:00+00'),
                                             'lines', l1, 'buyer_type', 2, 'buyer_tin', '10100302746'));
  PERFORM public.cp_sign(i2);
  PERFORM public.cp_expect_error('INV-TAX-08 batch capacity', format($q$SELECT public.cp_attempt(%L, %L, 'accepted')$q$, i2, b1), 'HK_TAX_BATCH_FULL');
  PERFORM public.cp_attempt(i2, b2, 'network_error');
  PERFORM public.cp_assert((SELECT status FROM tax.invoice_issue WHERE id = i2) = 'unknown', 'INV-TAX-09 network error ⇒ unknown');
  PERFORM public.cp_expect_error('INV-TAX-09 unknown outcome blocks resend', format($q$SELECT public.cp_attempt(%L, %L, 'accepted')$q$, i2, b2), 'HK_TAX_INQUIRE_FIRST');
  PERFORM public.cp_inquiry(i2, 'NOT_FOUND');
  PERFORM public.cp_assert((SELECT status FROM tax.invoice_issue WHERE id = i2) = 'not_received', 'INV-TAX-09 not found ⇒ not received');
  PERFORM public.cp_attempt(i2, b2, 'rejected_sync');
  PERFORM public.cp_assert((SELECT status FROM tax.invoice_issue WHERE id = i2) = 'not_received', 'INV-TAX-09 sync rejection ⇒ not received');
  PERFORM public.cp_attempt(i2, b2, 'accepted', 'REF-B');
  PERFORM public.cp_inquiry(i2, 'FAILED');
  PERFORM public.cp_assert((SELECT status = 'failed' AND failure_codes = ARRAY['0304401'] FROM tax.invoice_issue WHERE id = i2), 'INV-TAX-07 failed with codes');
  PERFORM public.cp_assert((SELECT status FROM tax.invoice WHERE id = 'c5a00000-0000-7000-8000-000000007002') = 'rejected', 'INV-TAX-04 document rejected');
  PERFORM public.cp_expect_error('INV-TAX-09 failed issue is terminal',
    format($q$UPDATE tax.invoice_issue SET status = 'signed' WHERE id = %L$q$, i2), 'HK_TAX_ISSUE_TRANSITION');
  PERFORM public.cp_issue(jsonb_build_object('id', 'c5a00000-0000-7000-8000-000000007103', 'invoice', 'c5a00000-0000-7000-8000-000000007002', 'issue_no', 2,
                                             'indatim', public.cp_ms('2026-04-12 07:00:00+00'), 'lines', l1, 'buyer_type', 2, 'buyer_tin', '10100302746'));
  PERFORM public.cp_flush();
  PERFORM public.cp_assert((SELECT count(DISTINCT serial) = 2 AND count(DISTINCT taxid) = 2 FROM tax.invoice_issue
                             WHERE invoice_id = 'c5a00000-0000-7000-8000-000000007002'), 'INV-TAX-09 reissue uses a new serial and taxid');
  PERFORM public.cp_expect_error('INV-TAX-11 withdraw needs a reason',
    $q$UPDATE tax.invoice SET status = 'withdrawn', withdrawn_at = now(), withdrawn_reason = 'x' WHERE id = 'c5a00000-0000-7000-8000-000000007002'$q$, '23514');
  UPDATE tax.invoice SET status = 'withdrawn', withdrawn_at = now(), withdrawn_reason = 'فاکتور فروش ابطال شد' WHERE id = 'c5a00000-0000-7000-8000-000000007002';
  PERFORM public.cp_assert((SELECT status FROM tax.invoice_issue WHERE id = 'c5a00000-0000-7000-8000-000000007103') = 'abandoned', 'INV-TAX-11 open issue abandoned');
  -- withdraw در حین ارسال ممنوع
  PERFORM public.cp_issue(jsonb_build_object('id', 'c5a00000-0000-7000-8000-000000007108', 'invoice', 'c5a00000-0000-7000-8000-000000007008',
                                             'indatim', public.cp_ms('2026-04-12 08:00:00+00'), 'lines', l1));
  PERFORM public.cp_sign('c5a00000-0000-7000-8000-000000007108');
  PERFORM public.cp_attempt('c5a00000-0000-7000-8000-000000007108', b2, 'accepted');
  PERFORM public.cp_expect_error('INV-TAX-11 no withdraw while in flight',
    $q$UPDATE tax.invoice SET status = 'withdrawn', withdrawn_at = now(), withdrawn_reason = 'ابطال فاکتور فروش' WHERE id = 'c5a00000-0000-7000-8000-000000007008'$q$,
    'HK_TAX_WITHDRAW_IN_FLIGHT');
END $$;

-- ---------- T08: اصلاحی، ابطالی، برگشت از فروش و تاریخچهٔ منتقل‌شده (INV-TAX-05، INV-TAX-14، INV-TAX-15) ----------
DO $$
DECLARE t uuid := 'c5a00000-0000-7000-8000-000000000001'; c uuid := 'c5a00000-0000-7000-8000-0000000000c1';
        m1 uuid := 'c5a00000-0000-7000-8000-000000006001'; b2 uuid := 'c5a00000-0000-7000-8000-000000007202';
        t1 uuid := 'c5a00000-0000-7000-8000-000000007001'; t3 uuid := 'c5a00000-0000-7000-8000-000000007003'; t4 uuid := 'c5a00000-0000-7000-8000-000000007004';
        tx1 text; tx7 text; d13 bigint := public.cp_ms('2026-04-13 07:00:00+00'); d14 bigint := public.cp_ms('2026-04-14 07:00:00+00');
        l3 jsonb := '[{"sstid":"2710000138624","am":"2","fee":"9000","dis":"0","vra":"9"}]';
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  SELECT taxid INTO tx1 FROM tax.invoice_issue WHERE id = 'c5a00000-0000-7000-8000-000000007101';
  INSERT INTO tax.invoice (tenant_id, id, company_id, memory_ref, source_kind, sales_invoice_id, subject, inv_type, pattern, instruction_version, ref_invoice_id, root_invoice_id)
  VALUES (t, t3, c, m1, 'sales_invoice', 'c5a00000-0000-7000-8000-0000000b0003', 2, 2, 1, 'RC_IITP.IS-7.8', t1, t1);
  PERFORM public.cp_expect_error('INV-TAX-14 reference keeps type and pattern',
    format($q$INSERT INTO tax.invoice (tenant_id, company_id, memory_ref, source_kind, sales_invoice_id, subject, inv_type, pattern, instruction_version, ref_invoice_id, root_invoice_id)
              VALUES (%L, %L, %L, 'sales_invoice', uuidv7(), 4, 1, 1, 'RC_IITP.IS-7.8', %L, %L)$q$, t, c, m1, t3, t1), 'HK_TAX_REF_CHANGES_TYPE');
  PERFORM public.cp_expect_error('INV-TAX-14 root is the chain original',
    format($q$INSERT INTO tax.invoice (tenant_id, company_id, memory_ref, source_kind, sales_invoice_id, subject, inv_type, pattern, instruction_version, ref_invoice_id, root_invoice_id)
              VALUES (%L, %L, %L, 'sales_invoice', uuidv7(), 4, 2, 1, 'RC_IITP.IS-7.8', %L, %L)$q$, t, c, m1, t3, t3), 'HK_TAX_REF_ROOT');
  PERFORM public.cp_expect_error('INV-TAX-14 refer to the latest version',
    format($q$INSERT INTO tax.invoice (tenant_id, company_id, memory_ref, source_kind, sales_invoice_id, subject, inv_type, pattern, instruction_version, ref_invoice_id, root_invoice_id)
              VALUES (%L, %L, %L, 'sales_cancellation', 'c5a00000-0000-7000-8000-0000000b0001', 3, 2, 1, 'RC_IITP.IS-7.8', %L, %L)$q$, t, c, m1, t1, t1), 'HK_TAX_REF_NOT_HEAD');
  PERFORM public.cp_expect_error('INV-TAX-14 irtaxid is the registered taxid of the reference',
    format($q$SELECT public.cp_issue(jsonb_build_object('invoice',%L,'indatim',%s,'lines',%L::jsonb,'irtaxid',%L))$q$,
           t3, d13, l3, (SELECT taxid FROM tax.invoice_issue WHERE id = 'c5a00000-0000-7000-8000-000000007102')), 'HK_TAX_IRTAXID');
  PERFORM public.cp_expect_error('INV-TAX-14 issued after the reference',
    format($q$SELECT public.cp_issue(jsonb_build_object('invoice',%L,'indatim',%s,'lines',%L::jsonb,'irtaxid',%L))$q$,
           t3, public.cp_ms('2026-04-09 07:00:00+00'), l3, tx1), 'HK_TAX_REF_DATE');
  PERFORM public.cp_flush();
  PERFORM public.cp_expect_error_deferred('INV-TAX-14 corrective keeps item ids and rates',
    format($q$SELECT public.cp_issue(jsonb_build_object('invoice',%L,'indatim',%s,'irtaxid',%L,
              'lines','[{"sstid":"2710000138625","am":"2","fee":"9000","vra":"9"}]'::jsonb))$q$, t3, d13, tx1), 'HK_TAX_CORRECTIVE_ITEMS');
  PERFORM public.cp_issue(jsonb_build_object('id', 'c5a00000-0000-7000-8000-000000007113', 'invoice', t3, 'indatim', d13, 'lines', l3, 'irtaxid', tx1));
  PERFORM public.cp_flush();
  -- برگشت روی نسخهٔ ثبت‌نشده ممنوع
  INSERT INTO tax.invoice (tenant_id, id, company_id, memory_ref, source_kind, sales_invoice_id, subject, inv_type, pattern, instruction_version, ref_invoice_id, root_invoice_id)
  VALUES (t, t4, c, m1, 'sales_invoice', 'c5a00000-0000-7000-8000-0000000b0004', 4, 2, 1, 'RC_IITP.IS-7.8', t3, t1);
  PERFORM public.cp_expect_error('INV-TAX-14 reference must be registered first',
    format($q$SELECT public.cp_issue(jsonb_build_object('invoice',%L,'indatim',%s,'lines',%L::jsonb,'irtaxid',%L))$q$, t4, d14, l3,
           (SELECT taxid FROM tax.invoice_issue WHERE id = 'c5a00000-0000-7000-8000-000000007113')), 'HK_TAX_REF_NOT_REGISTERED');
  PERFORM public.cp_sign('c5a00000-0000-7000-8000-000000007113');
  PERFORM public.cp_attempt('c5a00000-0000-7000-8000-000000007113', b2, 'accepted', 'REF-C');
  PERFORM public.cp_inquiry('c5a00000-0000-7000-8000-000000007113', 'SUCCESS', 'REF-C');
  PERFORM public.cp_expect_error_deferred('INV-TAX-15 return keeps unit price and rate',
    format($q$SELECT public.cp_issue(jsonb_build_object('invoice',%L,'indatim',%s,'irtaxid',%L,
              'lines','[{"sstid":"2710000138624","am":"1","fee":"8000","vra":"9"}]'::jsonb))$q$, t4, d14,
           (SELECT taxid FROM tax.invoice_issue WHERE id = 'c5a00000-0000-7000-8000-000000007113')), 'HK_TAX_RETURN_ITEMS');
  PERFORM public.cp_expect_error_deferred('INV-TAX-15 full return must be a cancellation',
    format($q$SELECT public.cp_issue(jsonb_build_object('invoice',%L,'indatim',%s,'irtaxid',%L,'lines',%L::jsonb))$q$, t4, d14,
           (SELECT taxid FROM tax.invoice_issue WHERE id = 'c5a00000-0000-7000-8000-000000007113'), l3), 'HK_TAX_RETURN_NOTHING');
  PERFORM public.cp_expect_error_deferred('INV-TAX-15 return cannot exceed the sold quantity',
    format($q$SELECT public.cp_issue(jsonb_build_object('invoice',%L,'indatim',%s,'irtaxid',%L,
              'lines','[{"sstid":"2710000138624","am":"3","fee":"9000","vra":"9"}]'::jsonb))$q$, t4, d14,
           (SELECT taxid FROM tax.invoice_issue WHERE id = 'c5a00000-0000-7000-8000-000000007113')), 'HK_TAX_RETURN_ITEMS');
  PERFORM public.cp_issue(jsonb_build_object('id', 'c5a00000-0000-7000-8000-000000007114', 'invoice', t4, 'indatim', d14,
                                             'irtaxid', (SELECT taxid FROM tax.invoice_issue WHERE id = 'c5a00000-0000-7000-8000-000000007113'),
                                             'lines', '[{"sstid":"2710000138624","am":"1","fee":"9000","vra":"9"}]'::jsonb));
  PERFORM public.cp_flush();

  -- اصلاحی نوع ۱ خریدار را عوض نمی‌کند
  PERFORM public.cp_sign('c5a00000-0000-7000-8000-000000007107');
  PERFORM public.cp_attempt('c5a00000-0000-7000-8000-000000007107', b2, 'accepted', 'REF-D');
  PERFORM public.cp_inquiry('c5a00000-0000-7000-8000-000000007107', 'SUCCESS', 'REF-D');
  SELECT taxid INTO tx7 FROM tax.invoice_issue WHERE id = 'c5a00000-0000-7000-8000-000000007107';
  INSERT INTO tax.invoice (tenant_id, id, company_id, memory_ref, source_kind, sales_invoice_id, subject, inv_type, pattern, instruction_version, ref_invoice_id, root_invoice_id)
  VALUES (t, 'c5a00000-0000-7000-8000-000000007009', c, m1, 'sales_invoice', 'c5a00000-0000-7000-8000-0000000b0009', 2, 1, 1, 'RC_IITP.IS-7.8',
          'c5a00000-0000-7000-8000-000000007007', 'c5a00000-0000-7000-8000-000000007007');
  PERFORM public.cp_expect_error_deferred('INV-TAX-14 corrective cannot change the buyer',
    format($q$SELECT public.cp_issue(jsonb_build_object('invoice','c5a00000-0000-7000-8000-000000007009','indatim',%s,'irtaxid',%L,'lines',%L::jsonb,
              'buyer_type',1,'buyer_tin','12345678901'))$q$, d14, tx7, l3), 'HK_TAX_CORRECTIVE_BUYER');
END $$;

-- تاریخچهٔ منتقل‌شده از نرم‌افزار قبلی (پیوستگی taxid؛ سریال‌ها زیر start_value سری)
DO $$
DECLARE t uuid := 'c5a00000-0000-7000-8000-000000000001'; c uuid := 'c5a00000-0000-7000-8000-0000000000c1';
        m2 uuid := 'c5a00000-0000-7000-8000-000000006002'; ind bigint := public.cp_ms('2026-03-25 07:00:00+00'); v_tax text;
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  INSERT INTO tax.invoice (tenant_id, id, company_id, memory_ref, source_kind, subject, inv_type, pattern, instruction_version)
  VALUES (t, 'c5a00000-0000-7000-8000-000000007020', c, m2, 'migration', 1, 2, 1, 'RC_IITP.IS-7.8');
  PERFORM public.cp_expect_error('INV-TAX-16 migrated serial below the series start',
    format($q$INSERT INTO tax.invoice_issue (tenant_id, company_id, invoice_id, issue_no, memory_ref, memory_id, serial, allocation, indatim_ms, issue_date, taxid,
                subject, inv_type, pattern, setm, tprdis, tdis, tadis, tvam, todam, tolam, tbill, seller_tin, payload, payload_sha256, rule_snapshot_id,
                send_deadline_at, status, success_at, success_reference_number)
              VALUES (%L, %L, 'c5a00000-0000-7000-8000-000000007020', 1, %L, 'A2HP31', 600, 'migration', %s, '2026-03-25', %L, 1, 2, 1, 1,
                      1000, 0, 1000, 100, 0, 0, 1100, '14003778990', '{"header":{},"body":[]}', sha256('m'), 'c5a00000-0000-7000-8000-000000005004',
                      now() + interval '1 day', 'success', now(), 'OLD-600')$q$, t, c, m2, ind, tax.taxid_build('A2HP31', (ind / 86400000)::int, 600)),
    'HK_TAX_MIGRATION_SERIAL');
  v_tax := tax.taxid_build('A2HP31', (ind / 86400000)::int, 450);
  INSERT INTO tax.invoice_issue (tenant_id, id, company_id, invoice_id, issue_no, memory_ref, memory_id, serial, allocation, indatim_ms, issue_date, taxid,
              subject, inv_type, pattern, setm, tprdis, tdis, tadis, tvam, todam, tolam, tbill, seller_tin, payload, payload_sha256, rule_snapshot_id,
              send_deadline_at, status, success_at, success_reference_number)
  VALUES (t, 'c5a00000-0000-7000-8000-000000007120', c, 'c5a00000-0000-7000-8000-000000007020', 1, m2, 'A2HP31', 450, 'migration', ind, '2026-03-25', v_tax,
          1, 2, 1, 1, 1000, 0, 1000, 100, 0, 0, 1100, '14003778990',
          jsonb_build_object('header', jsonb_build_object('taxid', v_tax, 'indatim', ind, 'inno', substr(v_tax, 12, 10), 'inty', 2, 'inp', 1, 'ins', 1,
                                                          'tbill', 1100, 'tvam', 100, 'setm', 1),
                             'body', '[{"sstid":"2710000138624"}]'::jsonb),
          sha256('m'), 'c5a00000-0000-7000-8000-000000005004', now() + interval '1 day', 'success', now(), 'OLD-450');
  INSERT INTO tax.invoice_issue_line (tenant_id, issue_id, line_no, sstid, sstt, mu, am, fee, amount_scale, prdis, dis, adis, vra, vam, tsstam, rate_source)
  VALUES (t, 'c5a00000-0000-7000-8000-000000007120', 1, '2710000138624', 'منتقل‌شده', '1627', 1, 1000, 0, 1000, 0, 1000, 10, 100, 1100, 'migration');
  PERFORM public.cp_flush();
  PERFORM public.cp_assert((SELECT status FROM tax.invoice WHERE id = 'c5a00000-0000-7000-8000-000000007020') = 'registered', 'INV-TAX-16 migrated history registered');
  PERFORM public.cp_expect_error('INV-TAX-16 only migration inserts success',
    format($q$INSERT INTO tax.invoice_issue (tenant_id, company_id, invoice_id, issue_no, memory_ref, memory_id, serial, number_issued_id, allocation, indatim_ms, issue_date, taxid,
                subject, inv_type, pattern, setm, tprdis, tdis, tadis, tvam, todam, tolam, tbill, seller_tin, payload, payload_sha256, rule_snapshot_id,
                send_deadline_at, status, success_at, success_reference_number, success_sign_jws, signed_at, signer, jws_sha256)
              SELECT tenant_id, company_id, 'c5a00000-0000-7000-8000-000000007006', 1, memory_ref, memory_id, 77, number_issued_id, 'server', indatim_ms,
                     issue_date, tax.taxid_build('DEF5GH', (indatim_ms / 86400000)::int, 77), subject, inv_type, pattern, setm, tprdis, tdis, tadis, tvam, todam,
                     tolam, tbill, seller_tin, payload, payload_sha256, rule_snapshot_id, send_deadline_at, 'success', now(), 'X', 'Y', now(), 'server_kms', sha256('j')
                FROM tax.invoice_issue WHERE id = 'c5a00000-0000-7000-8000-000000007101'$q$), 'HK_TAX_ISSUE_STATE');
END $$;

-- ---------- T09: دفتر مالیات خرید و اعتبار مالیاتی (INV-TAX-17) ----------
DO $$
DECLARE t uuid := 'c5a00000-0000-7000-8000-000000000001'; c uuid := 'c5a00000-0000-7000-8000-0000000000c1';
        sup uuid := 'c5a00000-0000-7000-8000-00000000a104'; tx text := 'A1121604C220002F095011';
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  INSERT INTO tax.purchase_entry (tenant_id, id, company_id, source_module, source_doc_type, source_doc_id, entry_kind, supplier_party_id, supplier_tin,
                                  doc_date, period_key, sign, net_amount, vat_amount, moadian_taxid, moadian_inv_type, moadian_status)
  VALUES (t, 'c5a00000-0000-7000-8000-000000007301', c, 'purchase', 'purchase.invoice', uuidv7(), 'invoice', sup, '14003778990',
          '2026-04-15', 'jq:1405Q1', 1, 1000000, 100000, tx, 1, 'awaiting_reaction');
  PERFORM public.cp_expect_error('INV-TAX-17 credit only for approved type-1 e-invoices',
    $q$UPDATE tax.purchase_entry SET credit_eligibility = 'eligible', eligibility_reason = 'x', eligibility_snapshot_id = 'c5a00000-0000-7000-8000-000000005004'
        WHERE id = 'c5a00000-0000-7000-8000-000000007301'$q$, '23514');
  PERFORM public.cp_expect_error('INV-TAX-17 decision needs reason and rule snapshot',
    $q$UPDATE tax.purchase_entry SET moadian_status = 'approved', credit_eligibility = 'eligible' WHERE id = 'c5a00000-0000-7000-8000-000000007301'$q$, '23514');
  UPDATE tax.purchase_entry SET moadian_status = 'approved', credit_eligibility = 'eligible', eligibility_reason = 'نوع ۱ تأییدشده در کارپوشه',
                                eligibility_snapshot_id = 'c5a00000-0000-7000-8000-000000005004'
   WHERE id = 'c5a00000-0000-7000-8000-000000007301';
  PERFORM public.cp_expect_error('INV-TAX-17 registered status needs the taxid',
    format($q$INSERT INTO tax.purchase_entry (tenant_id, company_id, source_module, source_doc_type, source_doc_id, entry_kind, supplier_party_id,
                doc_date, period_key, sign, net_amount, vat_amount, moadian_status)
              VALUES (%L, %L, 'purchase', 'purchase.invoice', uuidv7(), 'invoice', %L, '2026-04-15', 'jq:1405Q1', 1, 10, 1, 'registered')$q$, t, c, sup), '23514');
  PERFORM public.cp_expect_error('INV-TAX-17 returns are negative',
    format($q$INSERT INTO tax.purchase_entry (tenant_id, company_id, source_module, source_doc_type, source_doc_id, entry_kind, supplier_party_id,
                doc_date, period_key, sign, net_amount, vat_amount)
              VALUES (%L, %L, 'purchase', 'purchase.invoice', uuidv7(), 'return', %L, '2026-04-15', 'jq:1405Q1', 1, 10, 1)$q$, t, c, sup), '23514');
  PERFORM public.cp_expect_error('INV-TAX-17 one entry per supplier taxid',
    format($q$INSERT INTO tax.purchase_entry (tenant_id, company_id, source_module, source_doc_type, source_doc_id, entry_kind, supplier_party_id,
                doc_date, period_key, sign, net_amount, vat_amount, moadian_taxid, moadian_status)
              VALUES (%L, %L, 'purchase', 'purchase.invoice', uuidv7(), 'invoice', %L, '2026-04-15', 'jq:1405Q1', 1, 10, 1, %L, 'registered')$q$, t, c, sup, tx), '23505');
  PERFORM public.cp_expect_error('INV-TAX-17 amounts immutable',
    $q$UPDATE tax.purchase_entry SET vat_amount = 1 WHERE id = 'c5a00000-0000-7000-8000-000000007301'$q$, 'HK_TAX_PURCHASE_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-TAX-17 entries are never deleted',
    $q$DELETE FROM tax.purchase_entry WHERE id = 'c5a00000-0000-7000-8000-000000007301'$q$, '42501');
END $$;

-- ---------- T10: پایش حد ماده ۶ و سقف ماده ۱۴ مکرر (INV-TAX-18) ----------
DO $$
DECLARE t uuid := 'c5a00000-0000-7000-8000-000000000001'; c uuid := 'c5a00000-0000-7000-8000-0000000000c1';
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  INSERT INTO tax.threshold_monitor (tenant_id, id, company_id, kind, tax_year, limit_amount, limit_basis, rule_snapshot_id, warn_ratio, cumulative_amount, status)
  VALUES (t, 'c5a00000-0000-7000-8000-000000007401', c, 'art14m_ceiling', 1405, 1000000, '{"source":"param"}', 'c5a00000-0000-7000-8000-000000005004', 0.8, 100000, 'ok');
  PERFORM public.cp_expect_error('INV-TAX-18 status follows the amounts',
    $q$UPDATE tax.threshold_monitor SET cumulative_amount = 850000 WHERE id = 'c5a00000-0000-7000-8000-000000007401'$q$, '23514');
  UPDATE tax.threshold_monitor SET cumulative_amount = 850000, status = 'warning' WHERE id = 'c5a00000-0000-7000-8000-000000007401';
  PERFORM public.cp_expect_error('INV-TAX-18 exceeded needs the crossing date',
    $q$UPDATE tax.threshold_monitor SET cumulative_amount = 1200000, status = 'exceeded' WHERE id = 'c5a00000-0000-7000-8000-000000007401'$q$, '23514');
  UPDATE tax.threshold_monitor SET cumulative_amount = 1200000, status = 'exceeded', crossed_on = '2026-09-01', consequence_from = '2026-09-23'
   WHERE id = 'c5a00000-0000-7000-8000-000000007401';
  PERFORM public.cp_expect_error('INV-TAX-18 cumulative never decreases',
    $q$UPDATE tax.threshold_monitor SET cumulative_amount = 1100000 WHERE id = 'c5a00000-0000-7000-8000-000000007401'$q$, 'HK_TAX_THRESHOLD_BACKWARD');
  PERFORM public.cp_expect_error('INV-TAX-18 crossing date fixed',
    $q$UPDATE tax.threshold_monitor SET crossed_on = '2026-08-01' WHERE id = 'c5a00000-0000-7000-8000-000000007401'$q$, 'HK_TAX_THRESHOLD_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-TAX-18 one monitor per kind and year',
    format($q$INSERT INTO tax.threshold_monitor (tenant_id, company_id, kind, tax_year, limit_amount, limit_basis, rule_snapshot_id, warn_ratio)
              VALUES (%L, %L, 'art14m_ceiling', 1405, 5, '{}', 'c5a00000-0000-7000-8000-000000005004', 0.5)$q$, t, c), '23505');
END $$;

-- ---------- T11: اظهارنامهٔ فصلی ارزش افزوده (INV-TAX-19) ----------
DO $$
DECLARE t uuid := 'c5a00000-0000-7000-8000-000000000001'; c uuid := 'c5a00000-0000-7000-8000-0000000000c1'; u1 uuid := 'c5000000-0000-7000-8000-0000000000e1';
        r1 uuid := 'c5a00000-0000-7000-8000-000000007501'; r2 uuid := 'c5a00000-0000-7000-8000-000000007502';
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  INSERT INTO tax.vat_return (tenant_id, id, company_id, period_key, period_start, period_end) VALUES (t, r1, c, 'jq:1405Q1', '2026-03-21', '2026-06-21');
  PERFORM public.cp_expect_error('INV-TAX-19 returns start draft',
    format($q$INSERT INTO tax.vat_return (tenant_id, company_id, period_key, period_start, period_end, status) VALUES (%L, %L, 'jq:1405Q2', '2026-06-22', '2026-09-22', 'computed')$q$, t, c),
    'HK_TAX_RETURN_TRANSITION');
  PERFORM public.cp_expect_error('INV-TAX-19 computed needs all figures',
    format($q$UPDATE tax.vat_return SET status = 'computed', computed_at = now(), rule_snapshot_id = 'c5a00000-0000-7000-8000-000000005004' WHERE id = %L$q$, r1), '23514');
  PERFORM public.cp_expect_error('INV-TAX-19 payable = registered output − eligible input',
    format($q$UPDATE tax.vat_return SET status = 'computed', computed_at = now(), rule_snapshot_id = 'c5a00000-0000-7000-8000-000000005004',
              output_vat_registered = 1000, output_vat_unregistered = 0, output_vat_gl = 1000, input_vat_eligible = 300, input_vat_ineligible = 0,
              input_vat_gl = 300, other_tax_output = 0, payable_amount = 800 WHERE id = %L$q$, r1), '23514');
  UPDATE tax.vat_return SET status = 'computed', computed_at = now(), rule_snapshot_id = 'c5a00000-0000-7000-8000-000000005004',
         output_vat_registered = 1000, output_vat_unregistered = 0, output_vat_gl = 1000, input_vat_eligible = 300, input_vat_ineligible = 0,
         input_vat_gl = 300, other_tax_output = 0, payable_amount = 700 WHERE id = r1;
  INSERT INTO tax.vat_return_line (tenant_id, vat_return_id, section, category, base_amount, vat_amount, doc_count) VALUES
    (t, r1, 'output', 'rate:10', 10000, 1000, 3);
  PERFORM public.cp_expect_error('INV-TAX-19 filing needs the portal figures',
    format($q$UPDATE tax.vat_return SET status = 'filed', filed_at = now(), filed_by = %L WHERE id = %L$q$, u1, r1), '23514');
  UPDATE tax.vat_return SET status = 'filed', filed_at = now(), filed_by = u1, portal_output_vat = 1000, portal_input_credit = 300, portal_tracking_no = 'TRK-1' WHERE id = r1;
  UPDATE tax.purchase_entry SET vat_return_id = r1 WHERE id = 'c5a00000-0000-7000-8000-000000007301';
  PERFORM public.cp_expect_error('INV-TAX-19 filed return immutable',
    format($q$UPDATE tax.vat_return SET payable_amount = 1 WHERE id = %L$q$, r1), 'HK_TAX_RETURN_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-TAX-19 filed return lines immutable',
    format($q$INSERT INTO tax.vat_return_line (tenant_id, vat_return_id, section, category, base_amount, vat_amount, doc_count) VALUES (%L, %L, 'input', 'rate:10', 1, 1, 1)$q$, t, r1),
    'HK_TAX_RETURN_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-TAX-17 register locked after filing',
    $q$UPDATE tax.purchase_entry SET credit_eligibility = 'ineligible' WHERE id = 'c5a00000-0000-7000-8000-000000007301'$q$, 'HK_TAX_PURCHASE_LOCKED');
  PERFORM public.cp_expect_error('INV-TAX-19 amendment follows a filed version',
    format($q$INSERT INTO tax.vat_return (tenant_id, company_id, period_key, period_start, period_end, version) VALUES (%L, %L, 'jq:1405Q2', '2026-06-22', '2026-09-22', 2)$q$, t, c),
    'HK_TAX_RETURN_AMEND');
  INSERT INTO tax.vat_return (tenant_id, id, company_id, period_key, period_start, period_end, version) VALUES (t, r2, c, 'jq:1405Q1', '2026-03-21', '2026-06-21', 2);
  PERFORM public.cp_expect_error('INV-TAX-19 one open draft per period',
    format($q$INSERT INTO tax.vat_return (tenant_id, company_id, period_key, period_start, period_end, version) VALUES (%L, %L, 'jq:1405Q1', '2026-03-21', '2026-06-21', 3)$q$, t, c),
    'HK_TAX_RETURN_AMEND');
  UPDATE tax.vat_return SET status = 'superseded', superseded_by = r2 WHERE id = r1;
  PERFORM public.cp_expect_error('INV-TAX-19 superseded is terminal',
    format($q$UPDATE tax.vat_return SET status = 'filed' WHERE id = %L$q$, r1), 'HK_TAX_RETURN_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-TAX-17 entry joins only its own quarter',
    format($q$UPDATE tax.purchase_entry SET vat_return_id = %L WHERE id = 'c5a00000-0000-7000-8000-000000007301'$q$,
           (SELECT id FROM tax.vat_return WHERE period_key = 'jq:1405Q1' AND version = 2)), 'HK_TAX_PURCHASE_LOCKED');
END $$;

-- ---------- T12: گزارش‌های قانونی نسخه‌دار (INV-TAX-21) ----------
DO $$
DECLARE t uuid := 'c5a00000-0000-7000-8000-000000000001'; c uuid := 'c5a00000-0000-7000-8000-0000000000c1'; a uuid := uuidv7();
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  INSERT INTO core.attachment (tenant_id, id, company_id, storage_backend, bucket, object_key, file_name, encryption_key_ref)
  VALUES (t, a, c, 'fs', 'files', 't/' || t || '/2026/07/' || a, 'art169-1405Q1.xlsx', 'kek-1');
  INSERT INTO tax.legal_report (tenant_id, id, company_id, report_kind, period_key, period_start, period_end, format_key, format_version, rule_snapshot_id,
                                row_count, total_amount, total_vat, file_attachment_id, file_sha256)
  VALUES (t, 'c5a00000-0000-7000-8000-000000007601', c, 'art169_quarterly', 'jq:1405Q1', '2026-03-21', '2026-06-21', 'tax.art169.format', 'portal-1405',
          'c5a00000-0000-7000-8000-000000005004', 12, 5000000, 450000, a, sha256('f'));
  PERFORM public.cp_expect_error('INV-TAX-21 format key from the tax domain',
    format($q$INSERT INTO tax.legal_report (tenant_id, company_id, report_kind, period_key, period_start, period_end, format_key, format_version, rule_snapshot_id,
                row_count, total_amount, total_vat, file_attachment_id, file_sha256)
              VALUES (%L, %L, 'vat_summary', 'jq:1405Q1', '2026-03-21', '2026-06-21', 'payroll.format.salary_tax', 'v1', 'c5a00000-0000-7000-8000-000000005004',
                      1, 1, 1, %L, sha256('f'))$q$, t, c, a), '23514');
  PERFORM public.cp_expect_error('INV-TAX-21 content immutable',
    $q$UPDATE tax.legal_report SET total_amount = 1 WHERE id = 'c5a00000-0000-7000-8000-000000007601'$q$, 'HK_TAX_REPORT_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-TAX-21 submission needs the tracking reference',
    $q$UPDATE tax.legal_report SET status = 'submitted', submitted_at = now() WHERE id = 'c5a00000-0000-7000-8000-000000007601'$q$, '23514');
  UPDATE tax.legal_report SET status = 'submitted', submitted_at = now(), submission_ref = 'KP-123' WHERE id = 'c5a00000-0000-7000-8000-000000007601';
  PERFORM public.cp_expect_error('INV-TAX-21 submitted cannot go back',
    $q$UPDATE tax.legal_report SET status = 'generated' WHERE id = 'c5a00000-0000-7000-8000-000000007601'$q$, 'HK_TAX_REPORT_TRANSITION');
END $$;

-- ---------- T13: کارگاه، کارمند، قرارداد، حکم و کف قانونی مزد (INV-PAY-01..05) ----------
DO $$
DECLARE t uuid := 'c5a00000-0000-7000-8000-000000000001'; c uuid := 'c5a00000-0000-7000-8000-0000000000c1';
        u1 uuid := 'c5000000-0000-7000-8000-0000000000e1'; u2 uuid := 'c5000000-0000-7000-8000-0000000000e2';
        w1 uuid := 'c5a00000-0000-7000-8000-000000001001'; w2 uuid := 'c5a00000-0000-7000-8000-000000001002';
        e1 uuid := 'c5a00000-0000-7000-8000-000000002001'; e2 uuid := 'c5a00000-0000-7000-8000-000000002002';
        e3 uuid := 'c5a00000-0000-7000-8000-000000002003'; e5 uuid := 'c5a00000-0000-7000-8000-000000002005';
        snap uuid := 'c5a00000-0000-7000-8000-000000005001';
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  INSERT INTO parties.party (tenant_id, id, code, person_type, name, first_name, last_name, national_id, national_id_status, national_id_override_reason, national_id_override_at) VALUES
    (t, 'c5a00000-0000-7000-8000-00000000a106', 'E106', 'natural', 'بدون نقش', 'بی', 'نقش', '1234567890', 'override', 'کد قدیمی کارت ملی', now()),
    (t, 'c5a00000-0000-7000-8000-00000000a107', 'E107', 'natural', 'کارگر ساعتی', 'کارگر', 'ساعتی', '1234567891', 'valid', NULL, NULL);
  INSERT INTO parties.party_role (tenant_id, party_id, role) VALUES (t, 'c5a00000-0000-7000-8000-00000000a107', 'employee');
  INSERT INTO payroll.workshop (tenant_id, id, company_id, code, name, employer_name, address, dsk_rate, salary_tax_format, opened_on) VALUES
    (t, w1, c, '1234567890', 'کافه', 'کافهٔ الف', 'تهران', 23, 'wh-1-7', '2026-03-21'),
    (t, w2, c, '1234567891', 'انبار', 'کافهٔ الف', 'کرج', 23, 'wh-1-7', '2026-03-21');
  PERFORM public.cp_expect_error('INV-PAY-01 workshop code is 10 digits',
    format($q$INSERT INTO payroll.workshop (tenant_id, company_id, code, name, employer_name, address, dsk_rate, salary_tax_format, opened_on)
              VALUES (%L, %L, '12345', 'x', 'x', 'x', 23, 'wh-1-7', '2026-03-21')$q$, t, c), '23514');
  INSERT INTO payroll.employee (tenant_id, id, company_id, party_id, employee_no, insurance_no, ssi_job_code, hire_date) VALUES
    (t, e1, c, 'c5a00000-0000-7000-8000-00000000a101', 'P001', '1234567890', '123456', '2026-03-21'),
    (t, e2, c, 'c5a00000-0000-7000-8000-00000000a102', 'P002', '1234567891', '123456', '2026-03-21'),
    (t, e3, c, 'c5a00000-0000-7000-8000-00000000a107', 'P003', NULL, NULL, '2026-03-21'),
    (t, e5, c, 'c5a00000-0000-7000-8000-00000000a105', 'P005', NULL, NULL, '2026-03-21');
  PERFORM public.cp_expect_error('INV-PAY-01 employee is a natural person',
    format($q$INSERT INTO payroll.employee (tenant_id, company_id, party_id, employee_no, hire_date) VALUES (%L, %L, 'c5a00000-0000-7000-8000-00000000a104', 'P9', '2026-03-21')$q$, t, c),
    'HK_PAYROLL_EMPLOYEE_PERSON');
  PERFORM public.cp_expect_error('INV-PAY-01 Iranian employee needs a national code',
    format($q$INSERT INTO payroll.employee (tenant_id, company_id, party_id, employee_no, hire_date) VALUES (%L, %L, 'c5a00000-0000-7000-8000-00000000a103', 'P9', '2026-03-21')$q$, t, c),
    'HK_PAYROLL_EMPLOYEE_NATIONAL_ID');
  PERFORM public.cp_expect_error('INV-PAY-01 employee role required',
    format($q$INSERT INTO payroll.employee (tenant_id, company_id, party_id, employee_no, hire_date) VALUES (%L, %L, 'c5a00000-0000-7000-8000-00000000a106', 'P9', '2026-03-21')$q$, t, c),
    'HK_PAYROLL_EMPLOYEE_ROLE');
  PERFORM public.cp_expect_error('INV-PAY-01 one employee record per person and company',
    format($q$INSERT INTO payroll.employee (tenant_id, company_id, party_id, employee_no, hire_date) VALUES (%L, %L, 'c5a00000-0000-7000-8000-00000000a101', 'P9', '2026-03-21')$q$, t, c),
    '23505');
  PERFORM public.cp_expect_error('INV-PAY-01 termination needs date and reason',
    format($q$UPDATE payroll.employee SET status = 'terminated' WHERE id = %L$q$, e5), '23514');
  -- افراد تحت تکفل
  INSERT INTO payroll.employee_dependent (tenant_id, employee_id, relation, full_name, valid_from) VALUES (t, e1, 'spouse', 'همسر یک', '2020-01-01');
  PERFORM public.cp_expect_error('INV-PAY-01 one spouse at a time',
    format($q$INSERT INTO payroll.employee_dependent (tenant_id, employee_id, relation, full_name, valid_from) VALUES (%L, %L, 'spouse', 'همسر دو', '2024-01-01')$q$, t, e1), '23P01');
  PERFORM public.cp_expect_error('INV-PAY-01 child needs birth date',
    format($q$INSERT INTO payroll.employee_dependent (tenant_id, employee_id, relation, full_name, valid_from) VALUES (%L, %L, 'child', 'فرزند', '2024-01-01')$q$, t, e1), '23514');
  -- قرارداد
  INSERT INTO payroll.contract (tenant_id, id, company_id, employee_id, workshop_id, contract_no, kind, employment_type, weekly_hours, start_date, status, signed_on) VALUES
    (t, 'c5a00000-0000-7000-8000-000000003001', c, e1, w1, 'C-1', 'indefinite', 'full_time', NULL, '2026-03-21', 'active', '2026-03-21'),
    (t, 'c5a00000-0000-7000-8000-000000003002', c, e2, w2, 'C-2', 'indefinite', 'full_time', NULL, '2026-03-21', 'active', '2026-03-21'),
    (t, 'c5a00000-0000-7000-8000-000000003003', c, e3, w1, 'C-3', 'indefinite', 'hourly', NULL, '2026-03-21', 'active', '2026-03-21'),
    (t, 'c5a00000-0000-7000-8000-000000003005', c, e5, w1, 'C-5', 'indefinite', 'part_time', 22, '2026-03-21', 'active', '2026-03-21');
  PERFORM public.cp_expect_error('INV-PAY-02 one effective contract at a time',
    format($q$INSERT INTO payroll.contract (tenant_id, company_id, employee_id, workshop_id, contract_no, kind, employment_type, start_date, end_date, status, signed_on)
              VALUES (%L, %L, %L, %L, 'C-1b', 'fixed_term', 'full_time', '2026-06-01', '2027-06-01', 'active', '2026-06-01')$q$, t, c, e1, w2), '23P01');
  PERFORM public.cp_expect_error('INV-PAY-02 part-time needs agreed hours',
    format($q$INSERT INTO payroll.contract (tenant_id, company_id, employee_id, workshop_id, contract_no, kind, employment_type, start_date, status)
              VALUES (%L, %L, %L, %L, 'C-x', 'indefinite', 'part_time', '2027-06-01', 'draft')$q$, t, c, e1, w1), '23514');
  PERFORM public.cp_expect_error('INV-PAY-02 fixed-term needs an end',
    format($q$INSERT INTO payroll.contract (tenant_id, company_id, employee_id, workshop_id, contract_no, kind, employment_type, start_date, status)
              VALUES (%L, %L, %L, %L, 'C-y', 'fixed_term', 'full_time', '2027-06-01', 'draft')$q$, t, c, e1, w1), '23514');
  PERFORM public.cp_expect_error('INV-PAY-02 active contract is signed',
    format($q$INSERT INTO payroll.contract (tenant_id, company_id, employee_id, workshop_id, contract_no, kind, employment_type, start_date, end_date, status)
              VALUES (%L, %L, %L, %L, 'C-z', 'fixed_term', 'full_time', '2028-06-01', '2029-01-01', 'active')$q$, t, c, e1, w1), '23514');
  -- حکم و کف مزد
  INSERT INTO payroll.decree (tenant_id, id, company_id, employee_id, contract_id, decree_no, effective_from, reason, wage_basis, daily_wage, hourly_wage, created_by) VALUES
    (t, 'c5a00000-0000-7000-8000-000000004001', c, e1, 'c5a00000-0000-7000-8000-000000003001', 'D-1', '2026-03-21', 'hire', 'daily', 1200000, NULL, u1),
    (t, 'c5a00000-0000-7000-8000-000000004002', c, e2, 'c5a00000-0000-7000-8000-000000003002', 'D-2', '2026-03-21', 'hire', 'daily', 900000, NULL, u1),
    (t, 'c5a00000-0000-7000-8000-000000004003', c, e3, 'c5a00000-0000-7000-8000-000000003003', 'D-3', '2026-03-21', 'hire', 'hourly', NULL, 100000, u1),
    (t, 'c5a00000-0000-7000-8000-000000004004', c, e3, 'c5a00000-0000-7000-8000-000000003003', 'D-4', '2026-04-01', 'correction', 'hourly', NULL, 150000, u1),
    (t, 'c5a00000-0000-7000-8000-000000004005', c, e5, 'c5a00000-0000-7000-8000-000000003005', 'D-5', '2026-03-21', 'hire', 'daily', 400000, NULL, u1),
    (t, 'c5a00000-0000-7000-8000-000000004006', c, e5, 'c5a00000-0000-7000-8000-000000003005', 'D-6', '2026-04-01', 'correction', 'daily', 600000, NULL, u1),
    (t, 'c5a00000-0000-7000-8000-000000004007', c, e1, 'c5a00000-0000-7000-8000-000000003001', 'D-7', '2026-05-01', 'other', 'daily', 900000, NULL, u1),
    (t, 'c5a00000-0000-7000-8000-000000004008', c, e2, 'c5a00000-0000-7000-8000-000000003002', 'D-8', '2026-05-01', 'other', 'daily', 700000, NULL, u1);
  PERFORM public.cp_expect_error('INV-PAY-03 decrees start draft',
    format($q$INSERT INTO payroll.decree (tenant_id, company_id, employee_id, contract_id, decree_no, effective_from, reason, wage_basis, daily_wage, status)
              VALUES (%L, %L, %L, 'c5a00000-0000-7000-8000-000000003001', 'D-x', '2026-03-21', 'hire', 'daily', 1, 'approved')$q$, t, c, e1), 'HK_PAYROLL_DECREE_TRANSITION');
  PERFORM public.cp_expect_error('INV-PAY-03 hourly basis follows the contract',
    format($q$INSERT INTO payroll.decree (tenant_id, company_id, employee_id, contract_id, decree_no, effective_from, reason, wage_basis, hourly_wage)
              VALUES (%L, %L, %L, 'c5a00000-0000-7000-8000-000000003001', 'D-x', '2026-03-21', 'hire', 'hourly', 200000)$q$, t, c, e1), 'HK_PAYROLL_DECREE_BASIS');
  PERFORM public.cp_expect_error('INV-PAY-03 decree inside the contract',
    format($q$INSERT INTO payroll.decree (tenant_id, company_id, employee_id, contract_id, decree_no, effective_from, reason, wage_basis, daily_wage)
              VALUES (%L, %L, %L, 'c5a00000-0000-7000-8000-000000003001', 'D-x', '2026-01-01', 'hire', 'daily', 2000000)$q$, t, c, e1), 'HK_PAYROLL_DECREE_CONTRACT');
  PERFORM public.cp_expect_error('INV-PAY-03 decree of another employee contract',
    format($q$INSERT INTO payroll.decree (tenant_id, company_id, employee_id, contract_id, decree_no, effective_from, reason, wage_basis, daily_wage)
              VALUES (%L, %L, %L, 'c5a00000-0000-7000-8000-000000003001', 'D-x', '2026-04-01', 'hire', 'daily', 2000000)$q$, t, c, e2), 'HK_PAYROLL_DECREE_CONTRACT');
  PERFORM public.cp_expect_error('INV-PAY-03 approval needs approver and snapshot',
    $q$UPDATE payroll.decree SET status = 'approved' WHERE id = 'c5a00000-0000-7000-8000-000000004001'$q$, '23514');
  UPDATE payroll.decree SET status = 'approved', approved_by = u2, approved_at = now(), rule_snapshot_id = snap
   WHERE id IN ('c5a00000-0000-7000-8000-000000004001','c5a00000-0000-7000-8000-000000004002','c5a00000-0000-7000-8000-000000004004',
                'c5a00000-0000-7000-8000-000000004006');
  PERFORM public.cp_expect_error('INV-PAY-04 full-time wage below the statutory floor',
    format($q$UPDATE payroll.decree SET status = 'approved', approved_by = %L, approved_at = now(), rule_snapshot_id = %L WHERE id = 'c5a00000-0000-7000-8000-000000004007'$q$, u2, snap),
    'HK_PAYROLL_BELOW_MIN_WAGE');
  PERFORM public.cp_expect_error('INV-PAY-04 collective agreement floor still binds',
    format($q$UPDATE payroll.decree SET status = 'approved', approved_by = %L, approved_at = now(), rule_snapshot_id = %L WHERE id = 'c5a00000-0000-7000-8000-000000004008'$q$, u2, snap),
    'HK_PAYROLL_BELOW_MIN_WAGE');
  PERFORM public.cp_expect_error('INV-PAY-04 hourly wage below floor / hourly divisor',
    format($q$UPDATE payroll.decree SET status = 'approved', approved_by = %L, approved_at = now(), rule_snapshot_id = %L WHERE id = 'c5a00000-0000-7000-8000-000000004003'$q$, u2, snap),
    'HK_PAYROLL_BELOW_MIN_WAGE');
  PERFORM public.cp_expect_error('INV-PAY-04 part-time floor pro-rated by hours',
    format($q$UPDATE payroll.decree SET status = 'approved', approved_by = %L, approved_at = now(), rule_snapshot_id = %L WHERE id = 'c5a00000-0000-7000-8000-000000004005'$q$, u2, snap),
    'HK_PAYROLL_BELOW_MIN_WAGE');
  PERFORM public.cp_expect_error('INV-PAY-03 approved decree immutable',
    $q$UPDATE payroll.decree SET daily_wage = 1300000 WHERE id = 'c5a00000-0000-7000-8000-000000004001'$q$, 'HK_PAYROLL_DECREE_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-PAY-03 one approved decree per effective date',
    format($q$INSERT INTO payroll.decree (tenant_id, id, company_id, employee_id, contract_id, decree_no, effective_from, reason, wage_basis, daily_wage)
              VALUES (%L, 'c5a00000-0000-7000-8000-000000004009', %L, %L, 'c5a00000-0000-7000-8000-000000003001', 'D-9', '2026-03-21', 'correction', 'daily', 1250000);
              UPDATE payroll.decree SET status = 'approved', approved_by = %L, approved_at = now(), rule_snapshot_id = %L WHERE id = 'c5a00000-0000-7000-8000-000000004009'$q$,
           t, c, e1, u2, snap), '23505');
  PERFORM public.cp_expect_error('INV-PAY-03 superseded only by a draft of the same employee',
    format($q$UPDATE payroll.decree SET status = 'superseded', superseded_by = 'c5a00000-0000-7000-8000-000000004002' WHERE id = 'c5a00000-0000-7000-8000-000000004001'$q$),
    'HK_PAYROLL_DECREE_TRANSITION');
  PERFORM public.cp_expect_error('INV-PAY-03 approved decree is never deleted',
    $q$DELETE FROM payroll.decree WHERE id = 'c5a00000-0000-7000-8000-000000004001'$q$, 'HK_PAYROLL_DECREE_IMMUTABLE');
  -- تعریف اقلام
  INSERT INTO payroll.pay_item (tenant_id, id, company_id, code, name, statutory_class, calc_method) VALUES
    (t, 'c5a00000-0000-7000-8000-000000002101', c, 'BASE', 'مزد پایه', 'base_wage', 'decree_daily'),
    (t, 'c5a00000-0000-7000-8000-000000002102', c, 'HOUSING', 'حق مسکن', 'housing', 'statutory'),
    (t, 'c5a00000-0000-7000-8000-000000002103', c, 'CHILD', 'حق اولاد', 'child', 'statutory'),
    (t, 'c5a00000-0000-7000-8000-000000002104', c, 'LOAN', 'قسط وام', 'loan_repayment', 'loan'),
    (t, 'c5a00000-0000-7000-8000-000000002105', c, 'BONUS', 'پاداش موردی', 'bonus_occasional', 'manual_input');
  PERFORM public.cp_expect_error('INV-PAY-05 formula items carry a formula',
    format($q$INSERT INTO payroll.pay_item (tenant_id, company_id, code, name, statutory_class, calc_method) VALUES (%L, %L, 'F1', 'فرمول', 'welfare_incentive', 'formula')$q$, t, c), '23514');
  PERFORM public.cp_expect_error('INV-PAY-05 unknown statutory class',
    format($q$INSERT INTO payroll.pay_item (tenant_id, company_id, code, name, statutory_class, calc_method) VALUES (%L, %L, 'F2', 'ناشناخته', 'secret_bonus', 'manual_input')$q$, t, c), '23503');
  INSERT INTO payroll.decree_item (tenant_id, company_id, decree_id, pay_item_id, basis, amount)
  VALUES (t, c, 'c5a00000-0000-7000-8000-000000004007', 'c5a00000-0000-7000-8000-000000002102', 'monthly', 3000000);
  PERFORM public.cp_expect_error('INV-PAY-03 items of an approved decree are frozen',
    format($q$INSERT INTO payroll.decree_item (tenant_id, company_id, decree_id, pay_item_id, basis, amount)
              VALUES (%L, %L, 'c5a00000-0000-7000-8000-000000004001', 'c5a00000-0000-7000-8000-000000002102', 'monthly', 3000000)$q$, t, c), 'HK_PAYROLL_DECREE_IMMUTABLE');
END $$;

-- ---------- T14: کارکرد، تردد خام و شیفت (INV-PAY-06) ----------
DO $$
DECLARE t uuid := 'c5a00000-0000-7000-8000-000000000001'; c uuid := 'c5a00000-0000-7000-8000-0000000000c1';
        w1 uuid := 'c5a00000-0000-7000-8000-000000001001'; w2 uuid := 'c5a00000-0000-7000-8000-000000001002';
        e1 uuid := 'c5a00000-0000-7000-8000-000000002001'; e2 uuid := 'c5a00000-0000-7000-8000-000000002002';
        dev uuid := 'c5a00000-0000-7000-8000-000000002201';
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  INSERT INTO payroll.attendance_summary (tenant_id, id, company_id, workshop_id, employee_id, period_key, period_start, period_end, calendar_days, work_days, source) VALUES
    (t, 'c5a00000-0000-7000-8000-000000002301', c, w1, e1, 'jm:1405-01', '2026-03-21', '2026-04-20', 31, 31, 'manual'),
    (t, 'c5a00000-0000-7000-8000-000000002302', c, w2, e2, 'jm:1405-01', '2026-03-21', '2026-04-20', 31, 31, 'manual');
  PERFORM public.cp_expect_error('INV-PAY-06 days cannot exceed the month',
    format($q$INSERT INTO payroll.attendance_summary (tenant_id, company_id, workshop_id, employee_id, period_key, period_start, period_end, calendar_days, work_days, absence_days, source)
              VALUES (%L, %L, %L, %L, 'jm:1405-02', '2026-04-21', '2026-05-21', 31, 30, 2, 'manual')$q$, t, c, w1, e1), '23514');
  PERFORM public.cp_expect_error('INV-PAY-06 calendar days equal the period length',
    format($q$INSERT INTO payroll.attendance_summary (tenant_id, company_id, workshop_id, employee_id, period_key, period_start, period_end, calendar_days, work_days, source)
              VALUES (%L, %L, %L, %L, 'jm:1405-02', '2026-04-21', '2026-05-21', 30, 30, 'manual')$q$, t, c, w1, e1), '23514');
  PERFORM public.cp_expect_error('INV-PAY-06 Excel rows reference their import',
    format($q$INSERT INTO payroll.attendance_summary (tenant_id, company_id, workshop_id, employee_id, period_key, period_start, period_end, calendar_days, work_days, source)
              VALUES (%L, %L, %L, %L, 'jm:1405-02', '2026-04-21', '2026-05-21', 31, 31, 'excel')$q$, t, c, w1, e1), '23514');
  PERFORM public.cp_expect_error('INV-PAY-06 confirmation needs confirmer',
    $q$UPDATE payroll.attendance_summary SET status = 'confirmed' WHERE id = 'c5a00000-0000-7000-8000-000000002301'$q$, '23514');
  INSERT INTO payroll.clock_device (tenant_id, id, company_id, code, vendor) VALUES (t, dev, c, 'ZK-1', 'zkteco');
  INSERT INTO payroll.clock_user_map (tenant_id, device_id, device_user_code, employee_id, valid_from) VALUES (t, dev, '17', e1, '2026-03-21');
  PERFORM public.cp_expect_error('INV-PAY-06 device user maps to one employee at a time',
    format($q$INSERT INTO payroll.clock_user_map (tenant_id, device_id, device_user_code, employee_id, valid_from) VALUES (%L, %L, '17', %L, '2026-04-01')$q$, t, dev, e2), '23P01');
  INSERT INTO payroll.clock_event (tenant_id, device_id, device_user_code, punched_at, state) VALUES
    (t, dev, '17', '2026-04-01 05:00+00', 'in'), (t, dev, '17', '2026-04-01 13:30+00', 'out');
  PERFORM public.cp_expect_error('INV-PAY-06 re-importing a punch is a no-op (unique)',
    format($q$INSERT INTO payroll.clock_event (tenant_id, device_id, device_user_code, punched_at, state) VALUES (%L, %L, '17', '2026-04-01 05:00+00', 'in')$q$, t, dev), '23505');
  PERFORM public.cp_expect_error('INV-PAY-06 raw punches are append-only',
    $q$UPDATE payroll.clock_event SET state = 'out'$q$, '42501');
  INSERT INTO payroll.shift_def (tenant_id, id, company_id, code, name, start_time, end_time, break_minutes) VALUES
    (t, 'c5a00000-0000-7000-8000-000000002401', c, 'DAY', 'روز', '08:30', '17:00', 30);
  INSERT INTO payroll.shift_assignment (tenant_id, employee_id, pattern, cycle_anchor, valid_from)
  VALUES (t, e1, '["c5a00000-0000-7000-8000-000000002401"]', '2026-03-21', '2026-03-21');
  PERFORM public.cp_expect_error('INV-PAY-06 one shift pattern at a time',
    format($q$INSERT INTO payroll.shift_assignment (tenant_id, employee_id, pattern, cycle_anchor, valid_from) VALUES (%L, %L, '[null]', '2026-04-01', '2026-04-01')$q$, t, e1), '23P01');
  INSERT INTO payroll.attendance_day (tenant_id, employee_id, work_date, shift_def_id, first_in, last_out, worked_minutes, overtime_minutes, day_kind, engine_version)
  VALUES (t, e1, '2026-04-01', 'c5a00000-0000-7000-8000-000000002401', '2026-04-01 05:00+00', '2026-04-01 13:30+00', 480, 0, 'work', current_setting('cp.engine'));
  PERFORM public.cp_expect_error('INV-PAY-06 overtime within worked time',
    format($q$INSERT INTO payroll.attendance_day (tenant_id, employee_id, work_date, worked_minutes, overtime_minutes, day_kind, engine_version)
              VALUES (%L, %L, '2026-04-02', 60, 90, 'work', 'x')$q$, t, e1), '23514');
  PERFORM public.cp_expect_error('INV-PAY-06 edited day records the editor',
    format($q$UPDATE payroll.attendance_day SET status = 'edited' WHERE employee_id = %L AND work_date = '2026-04-01'$q$, e1), '23514');
END $$;

-- ---------- T15: وام، اجرای حقوق، فیش، تأیید، فایل‌های دولتی (INV-PAY-07..14) ----------
DO $$
DECLARE t uuid := 'c5a00000-0000-7000-8000-000000000001'; c uuid := 'c5a00000-0000-7000-8000-0000000000c1';
        u1 uuid := 'c5000000-0000-7000-8000-0000000000e1'; u2 uuid := 'c5000000-0000-7000-8000-0000000000e2';
        w1 uuid := 'c5a00000-0000-7000-8000-000000001001'; e1 uuid := 'c5a00000-0000-7000-8000-000000002001';
        l1 uuid := 'c5a00000-0000-7000-8000-000000008201'; i1 uuid := 'c5a00000-0000-7000-8000-000000008301';
        r1 uuid := 'c5a00000-0000-7000-8000-000000008001'; p1 uuid := 'c5a00000-0000-7000-8000-000000008101';
        e text := current_setting('cp.engine');
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  -- وام
  INSERT INTO payroll.loan (tenant_id, id, company_id, employee_id, kind, principal, installment_count, start_period_key) VALUES
    (t, l1, c, e1, 'loan', 2000000, 2, 'jm:1405-01'),
    (t, 'c5a00000-0000-7000-8000-000000008202', c, e1, 'loan', 1000000, 1, 'jm:1405-01');
  INSERT INTO payroll.loan_installment (tenant_id, id, loan_id, seq, period_key, amount) VALUES
    (t, i1, l1, 1, 'jm:1405-01', 1000000), (t, 'c5a00000-0000-7000-8000-000000008302', l1, 2, 'jm:1405-02', 1000000),
    (t, 'c5a00000-0000-7000-8000-000000008303', 'c5a00000-0000-7000-8000-000000008202', 1, 'jm:1405-01', 500000);
  PERFORM public.cp_expect_error('INV-PAY-07 an advance is one installment',
    format($q$INSERT INTO payroll.loan (tenant_id, company_id, employee_id, kind, principal, installment_count, start_period_key) VALUES (%L, %L, %L, 'advance', 10, 2, 'jm:1405-01')$q$, t, c, e1),
    '23514');
  PERFORM public.cp_expect_error('INV-PAY-07 activation needs approval',
    $q$UPDATE payroll.loan SET status = 'active' WHERE id = 'c5a00000-0000-7000-8000-000000008201'$q$, '23514');
  UPDATE payroll.loan SET status = 'active', approved_by = u2, approved_at = now() WHERE id = l1;
  PERFORM public.cp_flush();
  PERFORM public.cp_expect_error_deferred('INV-PAY-07 installments sum to the principal',
    $q$UPDATE payroll.loan SET status = 'active', approved_by = 'c5000000-0000-7000-8000-0000000000e2', approved_at = now() WHERE id = 'c5a00000-0000-7000-8000-000000008202'$q$,
    'HK_PAYROLL_LOAN_SCHEDULE');
  PERFORM public.cp_expect_error('INV-PAY-07 active schedule frozen',
    format($q$UPDATE payroll.loan_installment SET amount = 900000 WHERE id = %L$q$, i1), 'HK_PAYROLL_LOAN_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-PAY-07 no new installment on an active loan',
    format($q$INSERT INTO payroll.loan_installment (tenant_id, loan_id, seq, period_key, amount) VALUES (%L, %L, 3, 'jm:1405-03', 1)$q$, t, l1), 'HK_PAYROLL_LOAN_IMMUTABLE');

  -- اجرای حقوق
  PERFORM public.cp_expect_error('INV-PAY-08 runs start draft',
    format($q$INSERT INTO payroll.run (tenant_id, company_id, workshop_id, kind, period_key, period_start, period_end, payment_date, status)
              VALUES (%L, %L, %L, 'regular', 'jm:1405-01', '2026-03-21', '2026-04-20', '2026-04-21', 'approved')$q$, t, c, w1), 'HK_PAYROLL_RUN_TRANSITION');
  INSERT INTO payroll.run (tenant_id, id, company_id, workshop_id, kind, period_key, period_start, period_end, payment_date, rule_snapshot_id, engine_version, created_by)
  VALUES (t, r1, c, w1, 'regular', 'jm:1405-01', '2026-03-21', '2026-04-20', '2026-04-21', 'c5a00000-0000-7000-8000-000000005001', e, u1);
  -- قیدهای حساب فیش (فوری)
  PERFORM public.cp_expect_error('INV-PAY-09 insurance base is capped',
    format($q$INSERT INTO payroll.payslip (tenant_id, company_id, run_id, employee_id, contract_id, decree_id, calendar_days, paid_days, insurance_days, daily_wage, monthly_wage,
                gross_earnings, insurable_raw, insurable_benefits, ssi_cap_amount, ssi_base, ssi_rounding, ssi_employee_rate, ssi_employee, ssi_employer_rate, ssi_employer,
                unemployment_rate, unemployment, total_paid_all, taxable_income, salary_tax, other_deductions, net_pay)
              VALUES (%L, %L, %L, %L, 'c5a00000-0000-7000-8000-000000003001', 'c5a00000-0000-7000-8000-000000004001', 31, 31, 31, 1200000, 37200000,
                      300000000, 300000000, 262800000, 217000000, 300000000, 'half_up', 0.07, 21000000, 0.20, 60000000, 0.03, 9000000, 300000000, 0, 0, 0, 279000000)$q$,
           t, c, r1, e1), '23514');
  PERFORM public.cp_expect_error('INV-PAY-09 contributions follow rate and rounding',
    format($q$INSERT INTO payroll.payslip (tenant_id, company_id, run_id, employee_id, contract_id, decree_id, calendar_days, paid_days, insurance_days, daily_wage, monthly_wage,
                gross_earnings, insurable_raw, insurable_benefits, ssi_cap_amount, ssi_base, ssi_rounding, ssi_employee_rate, ssi_employee, ssi_employer_rate, ssi_employer,
                unemployment_rate, unemployment, total_paid_all, taxable_income, salary_tax, other_deductions, net_pay)
              VALUES (%L, %L, %L, %L, 'c5a00000-0000-7000-8000-000000003001', 'c5a00000-0000-7000-8000-000000004001', 31, 31, 31, 1200000, 37200000,
                      37200000, 37200000, 0, 217000000, 37200000, 'half_up', 0.07, 2604001, 0.20, 7440000, 0.03, 1116000, 37200000, 0, 0, 0, 34595999)$q$,
           t, c, r1, e1), '23514');
  PERFORM public.cp_expect_error('INV-PAY-09 monthly wage = daily wage × insurance days',
    format($q$INSERT INTO payroll.payslip (tenant_id, company_id, run_id, employee_id, contract_id, decree_id, calendar_days, paid_days, insurance_days, daily_wage, monthly_wage,
                gross_earnings, insurable_raw, insurable_benefits, ssi_cap_amount, ssi_base, ssi_rounding, ssi_employee_rate, ssi_employee, ssi_employer_rate, ssi_employer,
                unemployment_rate, unemployment, total_paid_all, taxable_income, salary_tax, other_deductions, net_pay)
              VALUES (%L, %L, %L, %L, 'c5a00000-0000-7000-8000-000000003001', 'c5a00000-0000-7000-8000-000000004001', 31, 31, 31, 1200000, 36000000,
                      37200000, 37200000, 1200000, 217000000, 37200000, 'half_up', 0.07, 2604000, 0.20, 7440000, 0.03, 1116000, 37200000, 0, 0, 0, 34596000)$q$,
           t, c, r1, e1), '23514');
  PERFORM public.cp_expect_error('INV-PAY-09 net pay never negative',
    format($q$INSERT INTO payroll.payslip (tenant_id, company_id, run_id, employee_id, contract_id, decree_id, calendar_days, paid_days, insurance_days, daily_wage, monthly_wage,
                gross_earnings, insurable_raw, insurable_benefits, ssi_cap_amount, ssi_base, ssi_rounding, ssi_employee_rate, ssi_employee, ssi_employer_rate, ssi_employer,
                unemployment_rate, unemployment, total_paid_all, taxable_income, salary_tax, other_deductions, net_pay)
              VALUES (%L, %L, %L, %L, 'c5a00000-0000-7000-8000-000000003001', 'c5a00000-0000-7000-8000-000000004001', 31, 31, 0, 1200000, 0,
                      1000, 0, 0, 217000000, 0, 'half_up', 0.07, 0, 0.20, 0, 0.03, 0, 1000, 0, 0, 2000, -1000)$q$,
           t, c, r1, e1), '23514');
  -- فیش معتبر با سطرها
  INSERT INTO payroll.payslip (tenant_id, id, company_id, run_id, employee_id, contract_id, decree_id, calendar_days, paid_days, insurance_days, daily_wage, monthly_wage,
              gross_earnings, insurable_raw, insurable_benefits, ssi_cap_amount, ssi_base, ssi_rounding, ssi_employee_rate, ssi_employee, ssi_employer_rate, ssi_employer,
              unemployment_rate, unemployment, total_paid_all, taxable_income, salary_tax, other_deductions, net_pay)
  VALUES (t, p1, c, r1, e1, 'c5a00000-0000-7000-8000-000000003001', 'c5a00000-0000-7000-8000-000000004001', 31, 31, 31, 1200000, 37200000,
          42200000, 40200000, 3000000, 217000000, 40200000, 'half_up', 0.07, 2814000, 0.20, 8040000, 0.03, 1206000, 42200000, 30000000, 3000000, 1000000, 35386000);
  INSERT INTO payroll.payslip_line (tenant_id, payslip_id, line_no, pay_item_id, statutory_class, kind, amount, ssi_insurable, tax_treatment, is_continuous, is_cash,
                                    wh_column, dsk_bucket, source, loan_installment_id) VALUES
    (t, p1, 1, 'c5a00000-0000-7000-8000-000000002101', 'base_wage', 'earning', 37200000, true, 'progressive', true, true, 'continuous_cash', 'ROOZ', 'decree', NULL),
    (t, p1, 2, 'c5a00000-0000-7000-8000-000000002102', 'housing', 'earning', 3000000, true, 'progressive', true, true, 'continuous_cash', 'MAZ', 'statutory', NULL),
    (t, p1, 3, 'c5a00000-0000-7000-8000-000000002103', 'child', 'earning', 2000000, false, 'exempt', true, true, 'continuous_cash', 'NONINSURABLE', 'statutory', NULL),
    (t, p1, 4, 'c5a00000-0000-7000-8000-000000002104', 'loan_repayment', 'deduction', 1000000, false, 'not_applicable', false, true, NULL, 'NONE', 'loan', i1);
  PERFORM public.cp_flush();
  PERFORM public.cp_expect_error('INV-PAY-10 insurable line must land in an insurance bucket',
    format($q$INSERT INTO payroll.payslip_line (tenant_id, payslip_id, line_no, statutory_class, kind, amount, ssi_insurable, tax_treatment, is_continuous, is_cash, dsk_bucket, source)
              VALUES (%L, %L, 9, 'overtime', 'earning', 1, true, 'progressive', false, true, 'NONINSURABLE', 'attendance')$q$, t, p1), '23514');
  PERFORM public.cp_expect_error_deferred('INV-PAY-10 payslip totals equal its lines',
    format($q$INSERT INTO payroll.payslip_line (tenant_id, payslip_id, line_no, statutory_class, kind, amount, ssi_insurable, tax_treatment, is_continuous, is_cash, dsk_bucket, source)
              VALUES (%L, %L, 9, 'overtime', 'earning', 1, true, 'progressive', false, true, 'MAZ', 'attendance')$q$, t, p1), 'HK_PAYROLL_PAYSLIP_TOTALS');
  PERFORM public.cp_expect_error_deferred('INV-PAY-10 line kind follows its statutory class',
    format($q$INSERT INTO payroll.payslip_line (tenant_id, payslip_id, line_no, statutory_class, kind, amount, ssi_insurable, tax_treatment, is_continuous, is_cash, dsk_bucket, source)
              VALUES (%L, %L, 9, 'loan_repayment', 'earning', 1, false, 'progressive', false, true, 'NONINSURABLE', 'manual')$q$, t, p1), 'HK_PAYROLL_LINE_CLASS');
  PERFORM public.cp_expect_error_deferred('INV-PAY-11 salary tax equals the snapshot brackets',
    format($q$UPDATE payroll.payslip SET salary_tax = 2999000, net_pay = 35387000 WHERE id = %L$q$, p1), 'HK_PAYROLL_TAX_MISMATCH');
  PERFORM public.cp_expect_error_deferred('INV-PAY-07 loan deduction equals the installment',
    format($q$UPDATE payroll.payslip_line SET amount = 900000 WHERE payslip_id = %L AND line_no = 4;
              UPDATE payroll.payslip SET other_deductions = 900000, net_pay = 35486000 WHERE id = %L$q$, p1, p1), 'HK_PAYROLL_LOAN_LINE');
  PERFORM public.cp_expect_error('INV-PAY-12 run totals equal its payslips',
    format($q$UPDATE payroll.run SET status = 'calculated', calculated_by = %L, calculated_at = now(), employee_count = 1, gross_total = 42200000 WHERE id = %L$q$, u1, r1),
    'HK_PAYROLL_RUN_TOTALS');
  UPDATE payroll.run SET status = 'calculated', calculated_by = u1, calculated_at = now(), employee_count = 1, gross_total = 42200000, ssi_employee_total = 2814000,
         ssi_employer_total = 8040000, unemployment_total = 1206000, tax_total = 3000000, deduction_total = 1000000, net_total = 35386000 WHERE id = r1;
  PERFORM public.cp_expect_error('INV-PAY-13 attendance confirmed before approval',
    format($q$UPDATE payroll.run SET status = 'approved', approved_by = %L, approved_at = now() WHERE id = %L$q$, u2, r1), 'HK_PAYROLL_ATTENDANCE_UNCONFIRMED');
  UPDATE payroll.attendance_summary SET status = 'confirmed', confirmed_by = u2, confirmed_at = now() WHERE id = 'c5a00000-0000-7000-8000-000000002301';
  PERFORM public.cp_expect_error('INV-PAY-13 approver differs from calculator (or a recorded reason)',
    format($q$UPDATE payroll.run SET status = 'approved', approved_by = %L, approved_at = now() WHERE id = %L$q$, u1, r1), '23514');
  UPDATE payroll.run SET status = 'approved', approved_by = u2, approved_at = now() WHERE id = r1;
  PERFORM public.cp_expect_error('INV-PAY-08 approved payslip immutable',
    format($q$UPDATE payroll.payslip SET taxable_income = 1 WHERE id = %L$q$, p1), 'HK_PAYROLL_RUN_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-PAY-08 no new lines after approval',
    format($q$INSERT INTO payroll.payslip_line (tenant_id, payslip_id, line_no, statutory_class, kind, amount, ssi_insurable, tax_treatment, is_continuous, is_cash, dsk_bucket, source)
              VALUES (%L, %L, 9, 'info', 'info', 0, false, 'not_applicable', false, true, 'NONE', 'manual')$q$, t, p1), 'HK_PAYROLL_RUN_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-PAY-08 approved run immutable',
    format($q$UPDATE payroll.run SET payment_date = '2026-04-25' WHERE id = %L$q$, r1), 'HK_PAYROLL_RUN_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-PAY-06 attendance locked by an approved run',
    $q$UPDATE payroll.attendance_summary SET overtime_hours = 5 WHERE id = 'c5a00000-0000-7000-8000-000000002301'$q$, 'HK_PAYROLL_ATTENDANCE_LOCKED');
  PERFORM public.cp_expect_error('INV-PAY-08 one regular run per workshop and month',
    format($q$INSERT INTO payroll.run (tenant_id, company_id, workshop_id, kind, period_key, period_start, period_end, payment_date)
              VALUES (%L, %L, %L, 'regular', 'jm:1405-01', '2026-03-21', '2026-04-20', '2026-04-21')$q$, t, c, w1), '23505');
  UPDATE payroll.payslip SET payment_status = 'paid', payment_doc_ref = uuidv7() WHERE id = p1;
  -- فایل‌های دولتی
  PERFORM public.cp_expect_error('INV-PAY-14 list totals equal the approved payslips',
    format($q$INSERT INTO payroll.gov_file (tenant_id, company_id, workshop_id, run_id, kind, format_key, format_version, code_page, list_no, rule_snapshot_id, control_totals)
              VALUES (%L, %L, %L, %L, 'ssi_list', 'payroll.format.ssi_list', 'listdisk_6', 'cp1256', '1', 'c5a00000-0000-7000-8000-000000005001',
                      '{"DSK_NUM":1,"DSK_TDD":31,"DSK_TMASH":40200000,"DSK_TBIME":2814001,"DSK_TKOSO":8040000,"DSK_BIC":1206000}')$q$, t, c, w1, r1),
    'HK_PAYROLL_FILE_TOTALS');
  PERFORM public.cp_expect_error('INV-PAY-14 format key follows file kind',
    format($q$INSERT INTO payroll.gov_file (tenant_id, company_id, workshop_id, run_id, kind, format_key, format_version, code_page, list_no, rule_snapshot_id, control_totals)
              VALUES (%L, %L, %L, %L, 'ssi_list', 'payroll.format.salary_tax', 'listdisk_6', 'cp1256', '1', 'c5a00000-0000-7000-8000-000000005001',
                      '{"DSK_NUM":1,"DSK_TDD":31,"DSK_TMASH":40200000,"DSK_TBIME":2814000,"DSK_TKOSO":8040000,"DSK_BIC":1206000}')$q$, t, c, w1, r1),
    '23514');
  INSERT INTO payroll.gov_file (tenant_id, id, company_id, workshop_id, run_id, kind, format_key, format_version, code_page, list_no, rule_snapshot_id, control_totals) VALUES
    (t, 'c5a00000-0000-7000-8000-000000008401', c, w1, r1, 'ssi_list', 'payroll.format.ssi_list', 'listdisk_6', 'cp1256', '1', 'c5a00000-0000-7000-8000-000000005001',
     '{"DSK_NUM":1,"DSK_TDD":31,"DSK_TMASH":40200000,"DSK_TBIME":2814000,"DSK_TKOSO":8040000,"DSK_BIC":1206000}'),
    (t, 'c5a00000-0000-7000-8000-000000008402', c, w1, r1, 'salary_tax', 'payroll.format.salary_tax', 'wh-1-7', 'utf-8', NULL, 'c5a00000-0000-7000-8000-000000005001',
     '{"tax_total":3000000,"employees":1}');
  PERFORM public.cp_expect_error('INV-PAY-14 file content immutable',
    $q$UPDATE payroll.gov_file SET control_totals = '{}' WHERE id = 'c5a00000-0000-7000-8000-000000008401'$q$, 'HK_PAYROLL_FILE_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-PAY-14 upload needs a timestamp',
    $q$UPDATE payroll.gov_file SET status = 'uploaded' WHERE id = 'c5a00000-0000-7000-8000-000000008401'$q$, '23514');
  PERFORM public.cp_expect_error('INV-PAY-14 file part names are the official ones',
    format($q$INSERT INTO payroll.gov_file_part (tenant_id, gov_file_id, file_name, attachment_id, sha256, byte_size, record_count)
              VALUES (%L, 'c5a00000-0000-7000-8000-000000008401', 'list.dbf', uuidv7(), sha256('x'), 10, 1)$q$, t), '23514');
  INSERT INTO core.attachment (tenant_id, id, company_id, storage_backend, bucket, object_key, file_name, encryption_key_ref)
  VALUES (t, 'c5a00000-0000-7000-8000-000000008501', c, 'fs', 'files', 't/' || t || '/2026/04/c5a00000-0000-7000-8000-000000008501', 'DSKWOR00.DBF', 'kek-1');
  INSERT INTO payroll.gov_file_part (tenant_id, gov_file_id, file_name, attachment_id, sha256, byte_size, record_count)
  VALUES (t, 'c5a00000-0000-7000-8000-000000008401', 'DSKWOR00.DBF', 'c5a00000-0000-7000-8000-000000008501', sha256('dbf'), 801, 1);
  UPDATE payroll.gov_file SET status = 'uploaded', uploaded_at = now(), portal_ref = 'ES-778899' WHERE id = 'c5a00000-0000-7000-8000-000000008401';
  -- ثبت در دفتر کل و لغو
  PERFORM public.cp_expect_error('INV-PAY-08 posted run references its journal',
    format($q$UPDATE payroll.run SET status = 'posted', posted_at = now() WHERE id = %L$q$, r1), '23514');
  UPDATE payroll.run SET status = 'posted', posted_at = now(),
         gl_journal_id = public.cp_journal(c, '2026-04-20', 'payroll', 'payroll.run', '[{"code":"7303","dr":"1"},{"code":"6202","cr":"1"}]')
   WHERE id = r1;
  PERFORM public.cp_expect_error('INV-PAY-08 cancellation needs a reason',
    format($q$UPDATE payroll.run SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'اشتباه' WHERE id = %L$q$, r1), 'HK_PAYROLL_REASON_REQUIRED');
  PERFORM public.cp_expect_error('INV-PAY-14 uploaded files block cancellation',
    format($q$UPDATE payroll.run SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'محاسبهٔ دوباره لازم است', cancel_journal_id = gl_journal_id WHERE id = %L$q$, r1),
    'HK_PAYROLL_RUN_FILED');
  PERFORM public.cp_expect_error('INV-PAY-08 approved/posted runs are never deleted',
    format($q$DELETE FROM payroll.run WHERE id = %L$q$, r1), 'HK_PAYROLL_RUN_IMMUTABLE');
END $$;

-- ---------- T16: دروازه‌های تأیید: اطمینان پایین، نسخهٔ موتور، آزمون طلایی (INV-PAY-13) ----------
DO $$
DECLARE t uuid := 'c5a00000-0000-7000-8000-000000000001'; c uuid := 'c5a00000-0000-7000-8000-0000000000c1';
        u1 uuid := 'c5000000-0000-7000-8000-0000000000e1'; u2 uuid := 'c5000000-0000-7000-8000-0000000000e2';
        w1 uuid := 'c5a00000-0000-7000-8000-000000001001'; w2 uuid := 'c5a00000-0000-7000-8000-000000001002';
        e1 uuid := 'c5a00000-0000-7000-8000-000000002001'; e2 uuid := 'c5a00000-0000-7000-8000-000000002002';
        r2 uuid := 'c5a00000-0000-7000-8000-000000008002'; r3 uuid := 'c5a00000-0000-7000-8000-000000008003'; e text := current_setting('cp.engine');
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  -- اطمینان پایین ⇒ پذیرش صریح
  INSERT INTO payroll.run (tenant_id, id, company_id, workshop_id, kind, period_key, period_start, period_end, payment_date, rule_snapshot_id, engine_version)
  VALUES (t, r2, c, w2, 'regular', 'jm:1405-01', '2026-03-21', '2026-04-20', '2026-04-21', 'c5a00000-0000-7000-8000-000000005002', e);
  INSERT INTO payroll.payslip (tenant_id, id, company_id, run_id, employee_id, contract_id, decree_id, calendar_days, paid_days, insurance_days, daily_wage, monthly_wage,
              gross_earnings, insurable_raw, insurable_benefits, ssi_cap_amount, ssi_base, ssi_rounding, ssi_employee_rate, ssi_employee, ssi_employer_rate, ssi_employer,
              unemployment_rate, unemployment, total_paid_all, taxable_income, salary_tax, other_deductions, net_pay)
  VALUES (t, 'c5a00000-0000-7000-8000-000000008102', c, r2, e2, 'c5a00000-0000-7000-8000-000000003002', 'c5a00000-0000-7000-8000-000000004002', 31, 31, 31, 900000, 27900000,
          27900000, 27900000, 0, 217000000, 27900000, 'half_up', 0.07, 1953000, 0.20, 5580000, 0.03, 837000, 27900000, 27900000, 2580000, 0, 23367000);
  INSERT INTO payroll.payslip_line (tenant_id, payslip_id, line_no, pay_item_id, statutory_class, kind, amount, ssi_insurable, tax_treatment, is_continuous, is_cash, dsk_bucket, source)
  VALUES (t, 'c5a00000-0000-7000-8000-000000008102', 1, 'c5a00000-0000-7000-8000-000000002101', 'base_wage', 'earning', 27900000, true, 'progressive', true, true, 'ROOZ', 'decree');
  UPDATE payroll.run SET status = 'calculated', calculated_by = u1, calculated_at = now(), employee_count = 1, gross_total = 27900000, ssi_employee_total = 1953000,
         ssi_employer_total = 5580000, unemployment_total = 837000, tax_total = 2580000, net_total = 23367000 WHERE id = r2;
  UPDATE payroll.attendance_summary SET status = 'confirmed', confirmed_by = u2, confirmed_at = now() WHERE id = 'c5a00000-0000-7000-8000-000000002302';
  PERFORM public.cp_flush();
  PERFORM public.cp_expect_error('INV-PAY-13 low-confidence parameters need explicit acknowledgment',
    format($q$UPDATE payroll.run SET status = 'approved', approved_by = %L, approved_at = now() WHERE id = %L$q$, u2, r2), 'HK_PAYROLL_LOW_CONFIDENCE');
  UPDATE payroll.run SET status = 'approved', approved_by = u2, approved_at = now(), low_confidence_ack_by = u2 WHERE id = r2;
  -- نسخهٔ موتور بدون آزمون طلایی موفق
  INSERT INTO payroll.run (tenant_id, id, company_id, workshop_id, kind, period_key, period_start, period_end, payment_date, rule_snapshot_id, engine_version)
  VALUES (t, r3, c, w1, 'off_cycle', 'jm:1405-02', '2026-04-21', '2026-05-21', '2026-05-22', 'c5a00000-0000-7000-8000-000000005003', '2099.1.0');
  INSERT INTO payroll.payslip (tenant_id, id, company_id, run_id, employee_id, contract_id, decree_id, calendar_days, paid_days, insurance_days, daily_wage, monthly_wage,
              gross_earnings, insurable_raw, insurable_benefits, ssi_cap_amount, ssi_base, ssi_rounding, ssi_employee_rate, ssi_employee, ssi_employer_rate, ssi_employer,
              unemployment_rate, unemployment, total_paid_all, taxable_income, salary_tax, other_deductions, net_pay)
  VALUES (t, 'c5a00000-0000-7000-8000-000000008103', c, r3, e1, 'c5a00000-0000-7000-8000-000000003001', 'c5a00000-0000-7000-8000-000000004001', 31, 0, 0, 1200000, 0,
          10000000, 0, 0, 217000000, 0, 'half_up', 0.07, 0, 0.20, 0, 0.03, 0, 10000000, 10000000, 0, 0, 10000000);
  INSERT INTO payroll.payslip_line (tenant_id, payslip_id, line_no, pay_item_id, statutory_class, kind, amount, ssi_insurable, tax_treatment, is_continuous, is_cash, dsk_bucket, source)
  VALUES (t, 'c5a00000-0000-7000-8000-000000008103', 1, 'c5a00000-0000-7000-8000-000000002105', 'bonus_occasional', 'earning', 10000000, false, 'progressive', false, true, 'NONINSURABLE', 'manual');
  UPDATE payroll.run SET status = 'calculated', calculated_by = u1, calculated_at = now(), employee_count = 1, gross_total = 10000000, net_total = 10000000 WHERE id = r3;
  PERFORM public.cp_flush();
  PERFORM public.cp_expect_error('INV-PAY-13 golden tests must pass on the computing engine',
    format($q$UPDATE payroll.run SET status = 'approved', approved_by = %L, approved_at = now() WHERE id = %L$q$, u2, r3), 'HK_PAYROLL_GOLDEN_NOT_PASSED');
  PERFORM public.cp_expect_error('INV-PAY-13 run engine equals snapshot engine',
    format($q$UPDATE payroll.run SET status = 'draft' WHERE id = %L; UPDATE payroll.run SET engine_version = %L WHERE id = %L;
              UPDATE payroll.run SET status = 'calculated' WHERE id = %L; UPDATE payroll.run SET status = 'approved', approved_by = %L, approved_at = now() WHERE id = %L$q$,
           r3, e, r3, r3, u2, r3), 'HK_PAYROLL_ENGINE_MISMATCH');
  PERFORM public.cp_expect_error('INV-PAY-14 files only from approved runs',
    format($q$INSERT INTO payroll.gov_file (tenant_id, company_id, workshop_id, run_id, kind, format_key, format_version, rule_snapshot_id, control_totals)
              VALUES (%L, %L, %L, %L, 'salary_tax', 'payroll.format.salary_tax', 'wh-1-7', 'c5a00000-0000-7000-8000-000000005001', '{"tax_total":0,"employees":1}')$q$, t, c, w1, r3),
    'HK_PAYROLL_FILE_RUN');
END $$;

-- ---------- T17: ذخایر و مرخصی (INV-PAY-15) ----------
DO $$
DECLARE t uuid := 'c5a00000-0000-7000-8000-000000000001'; c uuid := 'c5a00000-0000-7000-8000-0000000000c1';
        e1 uuid := 'c5a00000-0000-7000-8000-000000002001'; r1 uuid := 'c5a00000-0000-7000-8000-000000008001';
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  INSERT INTO payroll.accrual_entry (tenant_id, company_id, employee_id, kind, entry_type, period_key, work_year, amount, run_id, rule_snapshot_id) VALUES
    (t, c, e1, 'eidi', 'provision', 'jm:1405-01', 1405, 6000000, r1, 'c5a00000-0000-7000-8000-000000005001'),
    (t, c, e1, 'severance', 'opening', 'jm:1405-01', 1404, 30000000, NULL, NULL);
  PERFORM public.cp_expect_error('INV-PAY-15 provision is positive',
    format($q$INSERT INTO payroll.accrual_entry (tenant_id, company_id, employee_id, kind, entry_type, period_key, work_year, amount, run_id, rule_snapshot_id)
              VALUES (%L, %L, %L, 'eidi', 'provision', 'jm:1405-01', 1405, -1, %L, 'c5a00000-0000-7000-8000-000000005001')$q$, t, c, e1, r1), '23514');
  PERFORM public.cp_expect_error('INV-PAY-15 provision snapshots its rules',
    format($q$INSERT INTO payroll.accrual_entry (tenant_id, company_id, employee_id, kind, entry_type, period_key, work_year, amount, run_id)
              VALUES (%L, %L, %L, 'eidi', 'provision', 'jm:1405-01', 1405, 1, %L)$q$, t, c, e1, r1), '23514');
  PERFORM public.cp_expect_error('INV-PAY-15 accruals append-only', $q$UPDATE payroll.accrual_entry SET amount = 1$q$, '42501');
  INSERT INTO payroll.leave_entry (tenant_id, employee_id, entry_type, leave_year, days, period_key, source, run_id) VALUES
    (t, e1, 'accrual', 1405, 2.5, 'jm:1405-01', 'run', r1),
    (t, e1, 'usage', 1405, -1, 'jm:1405-01', 'attendance', NULL);
  PERFORM public.cp_expect_error('INV-PAY-15 usage reduces the balance',
    format($q$INSERT INTO payroll.leave_entry (tenant_id, employee_id, entry_type, leave_year, days, source) VALUES (%L, %L, 'usage', 1405, 1, 'manual')$q$, t, e1), '23514');
  PERFORM public.cp_expect_error('INV-PAY-15 manual adjustment needs a reason',
    format($q$INSERT INTO payroll.leave_entry (tenant_id, employee_id, entry_type, leave_year, days, source) VALUES (%L, %L, 'adjustment', 1405, 1, 'manual')$q$, t, e1), '23514');
  PERFORM public.cp_assert((SELECT balance_days FROM payroll.v_leave_balance WHERE employee_id = e1 AND leave_year = 1405) = 1.5, 'INV-PAY-15 leave balance view');
  PERFORM public.cp_assert((SELECT balance FROM payroll.v_accrual_balance WHERE employee_id = e1 AND kind = 'eidi') = 6000000, 'INV-PAY-15 accrual balance view');
END $$;

-- ---------- T18: دارایی ثابت: دو دفتر، استهلاک، واگذاری، تطبیق زیردفتر با دفتر کل (INV-AST-01..12) ----------
DO $$
DECLARE t uuid := 'c5a00000-0000-7000-8000-000000000001'; c uuid := 'c5a00000-0000-7000-8000-0000000000c1';
        u1 uuid := 'c5000000-0000-7000-8000-0000000000e1'; e text := current_setting('cp.engine');
        cl1 uuid := 'c5a00000-0000-7000-8000-000000009001'; cl2 uuid := 'c5a00000-0000-7000-8000-000000009002';
        bg uuid := 'c5a00000-0000-7000-8000-000000009101'; bt uuid := 'c5a00000-0000-7000-8000-000000009102';
        a1 uuid := 'c5a00000-0000-7000-8000-000000009201'; a2 uuid := 'c5a00000-0000-7000-8000-000000009202';
        a3 uuid := 'c5a00000-0000-7000-8000-000000009203'; al uuid := 'c5a00000-0000-7000-8000-000000009209';
        ab1 uuid := 'c5a00000-0000-7000-8000-000000009301'; ab1t uuid := 'c5a00000-0000-7000-8000-000000009302';
        ab2t uuid := 'c5a00000-0000-7000-8000-000000009303'; ab3t uuid := 'c5a00000-0000-7000-8000-000000009304';
        dv1 uuid := 'c5a00000-0000-7000-8000-000000009701'; snap uuid := 'c5a00000-0000-7000-8000-000000005005';
        r0 uuid := 'c5a00000-0000-7000-8000-000000009400'; r1 uuid := 'c5a00000-0000-7000-8000-000000009401'; rt uuid := 'c5a00000-0000-7000-8000-000000009402';
        jacq uuid; jdep uuid; jdisp uuid; a_cost uuid; a_acc uuid; v_acq uuid;
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  a_cost := public.cp_account(c, '2102'); a_acc := public.cp_account(c, '2190');
  INSERT INTO assets.asset_class (tenant_id, id, company_id, code, name, is_land, default_method, default_life_months, tax_class_code, posting_group_code) VALUES
    (t, cl1, c, 'FURN', 'اثاثه', false, 'straight_line', 120, 'T-FURN', 'furniture'),
    (t, cl2, c, 'LAND', 'زمین', true, 'none', NULL, NULL, 'land');
  PERFORM public.cp_expect_error('INV-AST-01 land is never depreciated (class)',
    format($q$INSERT INTO assets.asset_class (tenant_id, company_id, code, name, is_land, default_method, default_life_months, posting_group_code)
              VALUES (%L, %L, 'L2', 'زمین ۲', true, 'straight_line', 10, 'land')$q$, t, c), '23514');
  PERFORM public.cp_expect_error('INV-AST-02 straight line needs a useful life',
    format($q$INSERT INTO assets.asset_class (tenant_id, company_id, code, name, default_method, posting_group_code) VALUES (%L, %L, 'X', 'x', 'straight_line', 'x')$q$, t, c), '23514');
  INSERT INTO assets.book (tenant_id, id, company_id, code, name, kind, posts_to_gl) VALUES
    (t, bg, c, 'GL', 'دفتر حسابداری', 'accounting', true),
    (t, bt, c, 'TAX', 'دفتر مالیاتی', 'tax', false);
  PERFORM public.cp_expect_error('INV-AST-03 tax book never posts to the GL',
    format($q$INSERT INTO assets.book (tenant_id, company_id, code, name, kind, posts_to_gl) VALUES (%L, %L, 'T2', 'x', 'tax', true)$q$, t, c), '23514');
  PERFORM public.cp_expect_error('INV-AST-03 one GL book per company',
    format($q$INSERT INTO assets.book (tenant_id, company_id, code, name, kind, posts_to_gl) VALUES (%L, %L, 'GL2', 'x', 'accounting', true)$q$, t, c), '23505');
  INSERT INTO assets.asset (tenant_id, id, company_id, branch_id, class_id, tag_no, name, is_land, acquisition_date, available_date, acquisition_cost, created_by) VALUES
    (t, a1, c, 'c5a00000-0000-7000-8000-0000000000b1', cl1, 'FA-001', 'میز و صندلی', false, '2026-04-05', '2026-04-05', 120000000, u1),
    (t, a2, c, NULL, cl1, 'FA-002', 'یخچال', false, '2026-04-05', '2026-04-05', 10000000, u1),
    (t, a3, c, NULL, cl1, 'FA-003', 'قهوه‌ساز', false, '2026-04-05', '2026-04-05', 10000000, u1),
    (t, al, c, NULL, cl2, 'LAND-1', 'زمین', true, '2026-04-05', '2026-04-05', 500000000, u1);
  PERFORM public.cp_expect_error('INV-AST-01 land flag follows the class',
    format($q$INSERT INTO assets.asset (tenant_id, company_id, class_id, tag_no, name, is_land, acquisition_date, acquisition_cost) VALUES (%L, %L, %L, 'X1', 'x', true, '2026-04-05', 1)$q$, t, c, cl1),
    'HK_ASSETS_CLASS_MISMATCH');
  PERFORM public.cp_expect_error('INV-AST-04 assets start as draft',
    format($q$INSERT INTO assets.asset (tenant_id, company_id, class_id, tag_no, name, acquisition_date, available_date, acquisition_cost, status, activated_at)
              VALUES (%L, %L, %L, 'X2', 'x', '2026-04-05', '2026-04-05', 1, 'active', now())$q$, t, c, cl1), 'HK_ASSETS_TRANSITION');
  PERFORM public.cp_expect_error('INV-AST-04 tag unique per company',
    format($q$INSERT INTO assets.asset (tenant_id, company_id, class_id, tag_no, name, acquisition_date, acquisition_cost) VALUES (%L, %L, %L, 'FA-001', 'x', '2026-04-05', 1)$q$, t, c, cl1),
    '23505');
  INSERT INTO ledger.dimension_value (tenant_id, id, dimension_type_id, slot, code, name, company_id, source_module, source_entity_id)
  SELECT t, dv1, dt.id, dt.slot, 'FA-001', 'میز و صندلی', c, 'assets', a1 FROM ledger.dimension_type dt WHERE dt.code = 'fixed_asset';
  UPDATE assets.asset SET status = 'active', activated_at = now(), dimension_value_id = dv1 WHERE id = a1;
  UPDATE assets.asset SET status = 'active', activated_at = now() WHERE id IN (a2, a3, al);
  PERFORM public.cp_expect_error('INV-AST-04 financial identity fixed after activation',
    format($q$UPDATE assets.asset SET acquisition_cost = 1 WHERE id = %L$q$, a1), 'HK_ASSETS_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-AST-04 active asset is never deleted', format($q$DELETE FROM assets.asset WHERE id = %L$q$, a1), 'HK_ASSETS_IMMUTABLE');
  -- دفتر هر دارایی
  INSERT INTO assets.asset_book (tenant_id, id, company_id, asset_id, book_id, method, useful_life_months, depreciation_start, start_rule, tax_class_code,
                                 tax_table_value_id, rule_snapshot_id) VALUES
    (t, ab1,  c, a1, bg, 'straight_line', 120, '2026-04-21', 'first_day_next_month', NULL, NULL, snap),
    (t, ab1t, c, a1, bt, 'straight_line', 120, '2026-04-21', 'first_day_next_month', 'T-FURN', 'c5000000-0000-7000-8000-00000000f301', snap),
    (t, ab2t, c, a2, bt, 'straight_line', 120, '2026-04-21', 'first_day_next_month', 'T-FURN', 'c5000000-0000-7000-8000-00000000f301', snap),
    (t, ab3t, c, a3, bt, 'straight_line', 120, '2026-04-21', 'first_day_next_month', 'T-FURN', 'c5000000-0000-7000-8000-00000000f301', snap);
  PERFORM public.cp_expect_error('INV-AST-01 land is never depreciated (book)',
    format($q$INSERT INTO assets.asset_book (tenant_id, company_id, asset_id, book_id, method, useful_life_months, depreciation_start, start_rule, rule_snapshot_id)
              VALUES (%L, %L, %L, %L, 'straight_line', 10, '2026-05-01', 'first_day_next_month', %L)$q$, t, c, al, bg, snap), 'HK_ASSETS_LAND_NOT_DEPRECIABLE');
  PERFORM public.cp_expect_error('INV-AST-05 no depreciation before available for use',
    format($q$INSERT INTO assets.asset_book (tenant_id, company_id, asset_id, book_id, method, useful_life_months, depreciation_start, start_rule, rule_snapshot_id)
              VALUES (%L, %L, %L, %L, 'straight_line', 10, '2026-04-01', 'available_date', %L)$q$, t, c, a2, bg, snap), 'HK_ASSETS_START_BEFORE_AVAILABLE');
  PERFORM public.cp_expect_error('INV-AST-06 tax book uses a versioned Article 149 table value',
    format($q$INSERT INTO assets.asset_book (tenant_id, company_id, asset_id, book_id, method, useful_life_months, depreciation_start, start_rule, rule_snapshot_id,
                                             tax_class_code, tax_table_value_id)
              VALUES (%L, %L, %L, %L, 'straight_line', 10, '2026-05-01', 'first_day_next_month', %L, 'T-FURN', 'c5000000-0000-7000-8000-00000000f302')$q$, t, c, a2, bt, snap),
    'HK_ASSETS_TAX_CLASS_REQUIRED');
  PERFORM public.cp_expect_error('INV-AST-06 tax book needs the table value',
    format($q$INSERT INTO assets.asset_book (tenant_id, company_id, asset_id, book_id, method, useful_life_months, depreciation_start, start_rule, rule_snapshot_id, tax_class_code)
              VALUES (%L, %L, %L, %L, 'straight_line', 10, '2026-05-01', 'first_day_next_month', %L, 'T-FURN')$q$, t, c, a2, bt, snap), 'HK_ASSETS_TAX_CLASS_REQUIRED');
  PERFORM public.cp_expect_error('INV-AST-02 declining balance needs a rate',
    format($q$INSERT INTO assets.asset_book (tenant_id, company_id, asset_id, book_id, method, depreciation_start, start_rule, rule_snapshot_id)
              VALUES (%L, %L, %L, %L, 'declining_balance', '2026-05-01', 'first_day_next_month', %L)$q$, t, c, a2, bg, snap), '23514');
  PERFORM public.cp_expect_error('INV-AST-02 non-depreciable book has no start',
    format($q$INSERT INTO assets.asset_book (tenant_id, company_id, asset_id, book_id, method, depreciation_start, start_rule, rule_snapshot_id)
              VALUES (%L, %L, %L, %L, 'none', '2026-05-01', 'first_day_next_month', %L)$q$, t, c, al, bg, snap), '23514');
  -- تحصیل: دفتر GL با سند، دفتر مالیاتی بی‌سند
  jacq := public.cp_journal(c, '2026-04-05', 'assets', 'assets.asset',
            jsonb_build_array(jsonb_build_object('code','2102','dr','120000000','dim1',dv1), jsonb_build_object('code','1304','cr','120000000')));
  PERFORM public.cp_expect_error('INV-AST-07 GL-book transaction needs journal and accounts',
    format($q$INSERT INTO assets.asset_txn (tenant_id, company_id, asset_id, asset_book_id, book_id, kind, txn_date, cost_delta) VALUES (%L, %L, %L, %L, %L, 'acquisition', '2026-04-05', 120000000)$q$,
           t, c, a1, ab1, bg), 'HK_ASSETS_GL_REQUIRED');
  PERFORM public.cp_expect_error('INV-AST-07 tax book never posts',
    format($q$INSERT INTO assets.asset_txn (tenant_id, company_id, asset_id, asset_book_id, book_id, kind, txn_date, cost_delta, gl_journal_id) VALUES (%L, %L, %L, %L, %L, 'acquisition', '2026-04-05', 1, %L)$q$,
           t, c, a1, ab1t, bt, jacq), 'HK_ASSETS_GL_FORBIDDEN');
  PERFORM public.cp_expect_error('INV-AST-08 transaction shape by kind',
    format($q$INSERT INTO assets.asset_txn (tenant_id, company_id, asset_id, asset_book_id, book_id, kind, txn_date, cost_delta, accum_delta) VALUES (%L, %L, %L, %L, %L, 'acquisition', '2026-04-05', 1, 1)$q$,
           t, c, a1, ab1t, bt), '23514');
  PERFORM public.cp_expect_error('INV-AST-08 transaction book matches the asset book',
    format($q$INSERT INTO assets.asset_txn (tenant_id, company_id, asset_id, asset_book_id, book_id, kind, txn_date, cost_delta) VALUES (%L, %L, %L, %L, %L, 'acquisition', '2026-04-05', 1)$q$,
           t, c, a1, ab1, bt), 'HK_ASSETS_TXN_BOOK');
  PERFORM public.cp_expect_error('INV-AST-08 revaluation is v2',
    format($q$INSERT INTO assets.asset_txn (tenant_id, company_id, asset_id, asset_book_id, book_id, kind, txn_date, cost_delta) VALUES (%L, %L, %L, %L, %L, 'revaluation', '2026-04-05', 1)$q$,
           t, c, a1, ab1t, bt), 'HK_ASSETS_NOT_IN_V1');
  INSERT INTO assets.asset_txn (tenant_id, company_id, asset_id, asset_book_id, book_id, kind, txn_date, cost_delta, cost_account_id, accum_account_id, gl_journal_id, created_by)
  VALUES (t, c, a1, ab1, bg, 'acquisition', '2026-04-05', 120000000, a_cost, a_acc, jacq, u1);
  INSERT INTO assets.asset_txn (tenant_id, id, company_id, asset_id, asset_book_id, book_id, kind, txn_date, cost_delta) VALUES
    (t, 'c5a00000-0000-7000-8000-000000009501', c, a1, ab1t, bt, 'acquisition', '2026-04-05', 120000000),
    (t, 'c5a00000-0000-7000-8000-000000009502', c, a2, ab2t, bt, 'acquisition', '2026-04-05', 10000000),
    (t, 'c5a00000-0000-7000-8000-000000009503', c, a3, ab3t, bt, 'acquisition', '2026-04-05', 10000000);
  PERFORM public.cp_flush();
  PERFORM public.cp_expect_error('INV-AST-08 transactions append-only', $q$UPDATE assets.asset_txn SET cost_delta = 1$q$, '42501');
  PERFORM public.cp_expect_error('INV-AST-08 reversal mirrors exactly',
    format($q$INSERT INTO assets.asset_txn (tenant_id, company_id, asset_id, asset_book_id, book_id, kind, txn_date, cost_delta, reverses_txn_id)
              VALUES (%L, %L, %L, %L, %L, 'reversal', '2026-04-06', -1, 'c5a00000-0000-7000-8000-000000009502')$q$, t, c, a2, ab2t, bt), 'HK_ASSETS_REVERSAL');
  -- اجرای استهلاک
  INSERT INTO assets.depreciation_run (tenant_id, id, company_id, book_id, period_key, period_start, period_end, rule_snapshot_id, engine_version) VALUES
    (t, r0, c, bg, 'jm:1405-01', '2026-03-21', '2026-04-20', snap, e),
    (t, r1, c, bg, 'jm:1405-02', '2026-04-21', '2026-05-21', snap, e),
    (t, rt, c, bt, 'jm:1405-02', '2026-04-21', '2026-05-21', snap, e);
  INSERT INTO assets.depreciation_line (tenant_id, id, company_id, run_id, asset_book_id, asset_id, period_start, period_end, method, basis_amount, months, amount, nbv_before, nbv_after) VALUES
    (t, 'c5a00000-0000-7000-8000-000000009600', c, r0, ab1, a1, '2026-04-05', '2026-04-20', 'straight_line', 120000000, 0.5, 500000, 120000000, 119500000);
  PERFORM public.cp_expect_error('INV-AST-05 no depreciation before the start date',
    format($q$INSERT INTO assets.asset_txn (tenant_id, company_id, asset_id, asset_book_id, book_id, kind, txn_date, accum_delta, depreciation_line_id, cost_account_id, accum_account_id, gl_journal_id)
              VALUES (%L, %L, %L, %L, %L, 'depreciation', '2026-04-20', 500000, 'c5a00000-0000-7000-8000-000000009600', %L, %L, %L)$q$, t, c, a1, ab1, bg, a_cost, a_acc, jacq),
    'HK_ASSETS_DEPRECIATION_BEFORE_START');
  DELETE FROM assets.depreciation_line WHERE id = 'c5a00000-0000-7000-8000-000000009600';
  UPDATE assets.depreciation_run SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'دوره پیش از شروع استهلاک' WHERE id = r0;
  PERFORM public.cp_expect_error('INV-AST-09 net book value arithmetic',
    format($q$INSERT INTO assets.depreciation_line (tenant_id, company_id, run_id, asset_book_id, asset_id, period_start, period_end, method, basis_amount, months, amount, nbv_before, nbv_after)
              VALUES (%L, %L, %L, %L, %L, '2026-04-21', '2026-05-21', 'straight_line', 120000000, 1, 1000000, 120000000, 118000000)$q$, t, c, r1, ab1, a1), '23514');
  PERFORM public.cp_expect_error('INV-AST-09 line inside the run period',
    format($q$INSERT INTO assets.depreciation_line (tenant_id, company_id, run_id, asset_book_id, asset_id, period_start, period_end, method, basis_amount, months, amount, nbv_before, nbv_after)
              VALUES (%L, %L, %L, %L, %L, '2026-04-10', '2026-05-21', 'straight_line', 120000000, 1, 1000000, 120000000, 119000000)$q$, t, c, r1, ab1, a1), 'HK_ASSETS_LINE_PERIOD');
  PERFORM public.cp_expect_error('INV-AST-09 line book belongs to the run book',
    format($q$INSERT INTO assets.depreciation_line (tenant_id, company_id, run_id, asset_book_id, asset_id, period_start, period_end, method, basis_amount, months, amount, nbv_before, nbv_after)
              VALUES (%L, %L, %L, %L, %L, '2026-04-21', '2026-05-21', 'straight_line', 120000000, 1, 1000000, 120000000, 119000000)$q$, t, c, r1, ab1t, a1), 'HK_ASSETS_TXN_BOOK');
  INSERT INTO assets.depreciation_line (tenant_id, id, company_id, run_id, asset_book_id, asset_id, period_start, period_end, method, basis_amount, months, amount, nbv_before, nbv_after) VALUES
    (t, 'c5a00000-0000-7000-8000-000000009601', c, r1, ab1, a1, '2026-04-21', '2026-05-21', 'straight_line', 120000000, 1, 1000000, 120000000, 119000000),
    (t, 'c5a00000-0000-7000-8000-000000009602', c, rt, ab1t, a1, '2026-04-21', '2026-05-21', 'straight_line', 120000000, 1, 1000000, 120000000, 119000000);
  PERFORM public.cp_expect_error('INV-AST-10 one depreciation per period and book',
    format($q$INSERT INTO assets.depreciation_run (tenant_id, id, company_id, book_id, period_key, period_start, period_end, rule_snapshot_id, engine_version)
              VALUES (%L, 'c5a00000-0000-7000-8000-000000009409', %L, %L, 'jy:1405', '2026-03-21', '2027-03-20', %L, %L);
              INSERT INTO assets.depreciation_line (tenant_id, company_id, run_id, asset_book_id, asset_id, period_start, period_end, method, basis_amount, months, amount, nbv_before, nbv_after)
              VALUES (%L, %L, 'c5a00000-0000-7000-8000-000000009409', %L, %L, '2026-04-21', '2026-06-20', 'straight_line', 120000000, 2, 2000000, 120000000, 118000000)$q$,
           t, c, bg, snap, e, t, c, ab1, a1), 'HK_ASSETS_DOUBLE_DEPRECIATION');
  jdep := public.cp_journal(c, '2026-05-21', 'assets', 'assets.depreciation_run',
            jsonb_build_array(jsonb_build_object('code','7204','dr','1000000'), jsonb_build_object('code','2190','cr','1000000','dim1',dv1)));
  PERFORM public.cp_expect_error('INV-AST-09 depreciation transaction mirrors its line',
    format($q$INSERT INTO assets.asset_txn (tenant_id, company_id, asset_id, asset_book_id, book_id, kind, txn_date, accum_delta, depreciation_line_id, cost_account_id, accum_account_id, gl_journal_id)
              VALUES (%L, %L, %L, %L, %L, 'depreciation', '2026-05-21', 900000, 'c5a00000-0000-7000-8000-000000009601', %L, %L, %L)$q$, t, c, a1, ab1, bg, a_cost, a_acc, jdep),
    'HK_ASSETS_TXN_LINE');
  INSERT INTO assets.asset_txn (tenant_id, company_id, asset_id, asset_book_id, book_id, kind, txn_date, accum_delta, depreciation_line_id, cost_account_id, accum_account_id, gl_journal_id)
  VALUES (t, c, a1, ab1, bg, 'depreciation', '2026-05-21', 1000000, 'c5a00000-0000-7000-8000-000000009601', a_cost, a_acc, jdep);
  INSERT INTO assets.asset_txn (tenant_id, company_id, asset_id, asset_book_id, book_id, kind, txn_date, accum_delta, depreciation_line_id)
  VALUES (t, c, a1, ab1t, bt, 'depreciation', '2026-05-21', 1000000, 'c5a00000-0000-7000-8000-000000009602');
  PERFORM public.cp_expect_error('INV-AST-09 run totals equal its lines',
    format($q$UPDATE assets.depreciation_run SET status = 'posted', posted_at = now(), gl_journal_id = %L WHERE id = %L$q$, jdep, r1), 'HK_ASSETS_RUN_TOTALS');
  PERFORM public.cp_expect_error('INV-AST-07 GL run posts with its journal',
    format($q$UPDATE assets.depreciation_run SET status = 'posted', posted_at = now(), line_count = 1, total_amount = 1000000 WHERE id = %L$q$, r1), 'HK_ASSETS_GL_REQUIRED');
  UPDATE assets.depreciation_run SET status = 'posted', posted_at = now(), line_count = 1, total_amount = 1000000, gl_journal_id = jdep, posted_by = u1 WHERE id = r1;
  PERFORM public.cp_expect_error('INV-AST-07 tax run never posts to the GL',
    format($q$UPDATE assets.depreciation_run SET status = 'posted', posted_at = now(), line_count = 1, total_amount = 1000000, gl_journal_id = %L WHERE id = %L$q$, jdep, rt), 'HK_ASSETS_GL_FORBIDDEN');
  UPDATE assets.depreciation_run SET status = 'posted', posted_at = now(), line_count = 1, total_amount = 1000000 WHERE id = rt;
  PERFORM public.cp_expect_error('INV-AST-09 posted lines immutable',
    $q$UPDATE assets.depreciation_line SET amount = 0, nbv_after = nbv_before WHERE id = 'c5a00000-0000-7000-8000-000000009601'$q$, 'HK_ASSETS_RUN_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-AST-09 posted run immutable',
    format($q$UPDATE assets.depreciation_run SET total_amount = 0 WHERE id = %L$q$, r1), 'HK_ASSETS_RUN_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-AST-05 start fixed after first depreciation',
    format($q$UPDATE assets.asset_book SET salvage_value = 1000 WHERE id = %L$q$, ab1), 'HK_ASSETS_BOOK_LOCKED');
  -- سقف استهلاک انباشته (deferred)
  PERFORM public.cp_flush();
  PERFORM public.cp_expect_error_deferred('INV-AST-11 accumulated depreciation never exceeds the depreciable base',
    format($q$INSERT INTO assets.depreciation_run (tenant_id, id, company_id, book_id, period_key, period_start, period_end, rule_snapshot_id, engine_version)
              VALUES (%L, 'c5a00000-0000-7000-8000-000000009408', %L, %L, 'jm:1405-03', '2026-05-22', '2026-06-21', %L, %L);
              INSERT INTO assets.depreciation_line (tenant_id, id, company_id, run_id, asset_book_id, asset_id, period_start, period_end, method, basis_amount, months, amount, nbv_before, nbv_after)
              VALUES (%L, 'c5a00000-0000-7000-8000-000000009608', %L, 'c5a00000-0000-7000-8000-000000009408', %L, %L, '2026-05-22', '2026-06-21', 'straight_line', 10000000, 1, 20000000, 10000000, -10000000);
              INSERT INTO assets.asset_txn (tenant_id, company_id, asset_id, asset_book_id, book_id, kind, txn_date, accum_delta, depreciation_line_id)
              VALUES (%L, %L, %L, %L, %L, 'depreciation', '2026-06-21', 20000000, 'c5a00000-0000-7000-8000-000000009608')$q$,
           t, c, bt, snap, e, t, c, ab2t, a2, t, c, a2, ab2t, bt), 'HK_ASSETS_OVER_DEPRECIATED');
  -- تطبیق زیردفتر دارایی با دفتر کل (قرارداد بخش ۰۳ §۵-۱۴)
  PERFORM public.cp_assert((SELECT count(*) = 2 AND sum(balance_base) FILTER (WHERE account_id = a_cost) = 120000000
                                    AND sum(balance_base) FILTER (WHERE account_id = a_acc) = -1000000 AND bool_and(dim_value_id = dv1)
                              FROM assets.ledger_subledger_fixed_assets(c, '2026-06-01')), 'INV-AST-12 subledger balances by account and dimension');
  PERFORM public.cp_assert((SELECT count(*) FROM ledger.check_control_accounts(c, '2026-06-01') x WHERE x.subledger_kind = 'fixed_asset') = 0,
                           'INV-AST-12 fixed-asset subledger reconciles to the GL');
  PERFORM public.cp_assert((SELECT net_book_value FROM assets.v_asset_book_balance WHERE asset_book_id = ab1) = 119000000, 'INV-AST-12 book balance view');
  -- واگذاری
  PERFORM public.cp_expect_error('INV-AST-10 sale needs a sales invoice (Moadian)',
    format($q$INSERT INTO assets.disposal (tenant_id, company_id, asset_id, kind, disposal_date, proceeds) VALUES (%L, %L, %L, 'sale', '2026-06-01', 5000000)$q$, t, c, a2), '23514');
  PERFORM public.cp_expect_error('INV-AST-10 scrap has no proceeds',
    format($q$INSERT INTO assets.disposal (tenant_id, company_id, asset_id, kind, disposal_date, proceeds) VALUES (%L, %L, %L, 'scrap', '2026-06-01', 5)$q$, t, c, a2), '23514');
  INSERT INTO assets.disposal (tenant_id, id, company_id, asset_id, kind, disposal_date) VALUES
    (t, 'c5a00000-0000-7000-8000-000000009801', c, a2, 'scrap', '2026-06-01'),
    (t, 'c5a00000-0000-7000-8000-000000009802', c, a3, 'scrap', '2026-06-01');
  PERFORM public.cp_expect_error('INV-AST-10 disposal posts with its journal',
    $q$UPDATE assets.disposal SET status = 'posted', posted_at = now(), gain_loss = -10000000 WHERE id = 'c5a00000-0000-7000-8000-000000009801'$q$, 'HK_ASSETS_GL_REQUIRED');
  jdisp := public.cp_journal(c, '2026-06-01', 'assets', 'assets.disposal', '[{"code":"7303","dr":"1"},{"code":"6202","cr":"1"}]');
  UPDATE assets.disposal SET status = 'posted', posted_at = now(), gain_loss = -10000000, gl_journal_id = jdisp
   WHERE id IN ('c5a00000-0000-7000-8000-000000009801','c5a00000-0000-7000-8000-000000009802');
  PERFORM public.cp_expect_error('INV-AST-10 asset disposed only by a posted disposal',
    format($q$UPDATE assets.asset SET status = 'disposed', disposed_on = '2026-06-01' WHERE id = %L$q$, a1), 'HK_ASSETS_DISPOSAL_REQUIRED');
  INSERT INTO assets.asset_txn (tenant_id, company_id, asset_id, asset_book_id, book_id, kind, txn_date, cost_delta, accum_delta, disposal_id)
  VALUES (t, c, a2, ab2t, bt, 'disposal', '2026-06-01', -10000000, 0, 'c5a00000-0000-7000-8000-000000009801');
  UPDATE assets.asset SET status = 'disposed', disposed_on = '2026-06-01' WHERE id = a2;
  PERFORM public.cp_flush();
  PERFORM public.cp_expect_error_deferred('INV-AST-10 disposal removes the full cost and accumulation',
    format($q$INSERT INTO assets.asset_txn (tenant_id, company_id, asset_id, asset_book_id, book_id, kind, txn_date, cost_delta, accum_delta, disposal_id)
              VALUES (%L, %L, %L, %L, %L, 'disposal', '2026-06-01', -5000000, 0, 'c5a00000-0000-7000-8000-000000009802')$q$, t, c, a3, ab3t, bt), 'HK_ASSETS_DISPOSAL_INCOMPLETE');
  PERFORM public.cp_expect_error('INV-AST-10 no depreciation after disposal',
    format($q$INSERT INTO assets.depreciation_run (tenant_id, id, company_id, book_id, period_key, period_start, period_end, rule_snapshot_id, engine_version)
              VALUES (%L, 'c5a00000-0000-7000-8000-000000009410', %L, %L, 'jm:1405-04', '2026-06-22', '2026-07-22', %L, %L);
              INSERT INTO assets.depreciation_line (tenant_id, id, company_id, run_id, asset_book_id, asset_id, period_start, period_end, method, basis_amount, months, amount, nbv_before, nbv_after)
              VALUES (%L, 'c5a00000-0000-7000-8000-000000009607', %L, 'c5a00000-0000-7000-8000-000000009410', %L, %L, '2026-06-22', '2026-07-22', 'straight_line', 10000000, 1, 1, 0, -1);
              INSERT INTO assets.asset_txn (tenant_id, company_id, asset_id, asset_book_id, book_id, kind, txn_date, accum_delta, depreciation_line_id)
              VALUES (%L, %L, %L, %L, %L, 'depreciation', '2026-07-22', 1, 'c5a00000-0000-7000-8000-000000009607')$q$,
           t, c, bt, snap, e, t, c, ab2t, a2, t, c, a2, ab2t, bt), 'HK_ASSETS_DEPRECIATION_AFTER_DISPOSAL');
  -- رویدادهای غیرمالی
  INSERT INTO assets.asset_movement (tenant_id, company_id, asset_id, moved_on, to_location, reason) VALUES (t, c, a1, '2026-06-01', 'سالن دوم', 'جابه‌جایی چیدمان');
  PERFORM public.cp_expect_error('INV-AST-04 movement names a destination',
    format($q$INSERT INTO assets.asset_movement (tenant_id, company_id, asset_id, moved_on, reason) VALUES (%L, %L, %L, '2026-06-01', 'جابه‌جایی')$q$, t, c, a1), '23514');
  INSERT INTO assets.idle_period (tenant_id, company_id, asset_id, from_date, to_date, reason) VALUES (t, c, a1, '2026-07-01', '2026-08-01', 'تعطیلی موقت');
  PERFORM public.cp_expect_error('INV-AST-11 idle periods do not overlap',
    format($q$INSERT INTO assets.idle_period (tenant_id, company_id, asset_id, from_date, reason) VALUES (%L, %L, %L, '2026-07-15', 'تعطیلی دوم')$q$, t, c, a1), '23P01');
  INSERT INTO assets.asset_tag (tenant_id, company_id, asset_id, tag_no, assigned_on) VALUES (t, c, a1, 'FA-001', '2026-04-05');
  PERFORM public.cp_expect_error('INV-AST-04 one active tag per asset',
    format($q$INSERT INTO assets.asset_tag (tenant_id, company_id, asset_id, tag_no, assigned_on) VALUES (%L, %L, %L, 'FA-001B', '2026-05-01')$q$, t, c, a1), '23505');
END $$;

-- =====================================================================
-- بخش ۳: نصب‌کننده (postgres) — بستهٔ تازهٔ عطف به ماسبق؛ نگهبان‌های فقط‌افزودنی در سطح trigger
-- =====================================================================
RESET ROLE;
INSERT INTO rules.package (id, code, version, seq, covers_from, min_engine_version, payload_sha256, hksb_sha256, signer_kid,
                           published_at, authored_by, approved_by, changelog_fa, installed_via, review_due_on) VALUES
  ('c5000000-0000-7000-8000-00000000f006', 'ir.payroll', '1405.2', 3, '2026-03-21', '2026.1.0', sha256('p6'), sha256('h6'), 'rules-test-a',
   now(), 'author@platform', '{approver@platform,reviewer@platform}', 'مزد عطف به ماسبق (TEST-ONLY)', 'test_fixture', '2027-03-21');
INSERT INTO rules.param_value (id, package_id, key, qualifier, effective_from, value, approved_on, source_ref, confidence) VALUES
  ('c5000000-0000-7000-8000-00000000f601', 'c5000000-0000-7000-8000-00000000f006', 'payroll.wage.min_daily', '', '2026-03-21',
   '{"amount":"1100000","unit":"IRR"}', '2026-05-01', 'TEST-ONLY', 'high'),
  ('c5000000-0000-7000-8000-00000000f602', 'c5000000-0000-7000-8000-00000000f006', 'payroll.time.weekly_hours', '', '2026-03-21', '{"v":"44"}', NULL, 'TEST-ONLY', 'high'),
  ('c5000000-0000-7000-8000-00000000f603', 'c5000000-0000-7000-8000-00000000f006', 'payroll.time.hourly_divisor', '', '2026-03-21', '{"v":"7.33"}', NULL, 'TEST-ONLY', 'medium'),
  ('c5000000-0000-7000-8000-00000000f604', 'c5000000-0000-7000-8000-00000000f006', 'payroll.tax.brackets_monthly', '', '2026-03-21',
   '{"rows":[{"from":"0","to":"10000000","rate":"0"},{"from":"10000000","to":"20000000","rate":"0.10"},{"from":"20000000","to":null,"rate":"0.20"}]}', NULL, 'TEST-ONLY', 'high'),
  ('c5000000-0000-7000-8000-00000000f605', 'c5000000-0000-7000-8000-00000000f006', 'payroll.tax.rounding', '', '2026-03-21', '{"v":"truncate"}', NULL, 'TEST-ONLY', 'high');
INSERT INTO rules.golden_test (package_id, code, calculator, as_of, input, expected, signed_by) VALUES
  ('c5000000-0000-7000-8000-00000000f006', 'min-single', 'payroll.payslip', '2026-04-20', '{"days":31}', '{"net":"2"}', 'حسابدار آزمون');
UPDATE rules.package SET status = 'installed' WHERE id = 'c5000000-0000-7000-8000-00000000f006';
INSERT INTO rules.golden_run (package_id, engine_version, runner, total, passed, failed, outcome, started_at)
VALUES ('c5000000-0000-7000-8000-00000000f006', :'engine', 'install', 1, 1, 0, 'passed', now());
UPDATE rules.package SET status = 'active' WHERE id = 'c5000000-0000-7000-8000-00000000f006';
INSERT INTO rules.industry_pack (code, name_fa, kind, introduced_in) VALUES ('cafe', 'کافه و رستوران', 'industry', '1.0');
INSERT INTO rules.industry_pack_version (pack_code, version, manifest, manifest_sha256, hksb_sha256, min_app_version, status, reviewed_by, published_at)
VALUES ('cafe', '1.0.0', '{"format":"hkpack/1","pack":"cafe","version":"1.0.0"}', sha256('m'), sha256('h'), '2026.11.0', 'published', 'reviewer', now());

DO $$
BEGIN
  PERFORM public.cp_assert((SELECT status = 'superseded' AND superseded_by = 'c5000000-0000-7000-8000-00000000f006'
                              FROM rules.package WHERE id = 'c5000000-0000-7000-8000-00000000f001'), 'INV-RUL-10 activation supersedes the previous version');
  PERFORM public.cp_assert((SELECT count(*) FROM rules.package WHERE code = 'ir.payroll' AND status = 'active') = 1, 'INV-RUL-10 one active package per code');
  PERFORM public.cp_assert((rules.value_at('payroll.wage.min_daily', '2026-04-01')).value ->> 'amount' = '1100000', 'INV-RUL-09 retroactive value now effective');
  PERFORM public.cp_assert(EXISTS (SELECT 1 FROM rules.package_event WHERE package_id = 'c5000000-0000-7000-8000-00000000f001' AND to_status = 'superseded'),
                           'INV-RUL-08 supersession logged');
  PERFORM public.cp_expect_error('INV-RUL-02 superseded only toward withdrawn',
    $q$UPDATE rules.package SET status = 'active' WHERE id = 'c5000000-0000-7000-8000-00000000f001'$q$, 'HK_RULES_PACKAGE_TRANSITION');
  PERFORM public.cp_expect_error('INV-RUL-02 withdraw needs reason',
    $q$UPDATE rules.package SET status = 'withdrawn', end_reason = 'خطا' WHERE id = 'c5000000-0000-7000-8000-00000000f003'$q$, 'HK_RULES_REASON_REQUIRED');
  UPDATE rules.package SET status = 'withdrawn', end_reason = 'جدول آزمایشی کنار گذاشته شد' WHERE id = 'c5000000-0000-7000-8000-00000000f003';
  PERFORM public.cp_expect_error('INV-RUL-09 withdrawn package leaves no silent fallback',
    $q$SELECT rules.value_at('assets.depreciation.start_rule', '2026-04-01')$q$, 'HK_RULES_NO_ACTIVE_PACKAGE');
  PERFORM public.cp_expect_error('INV-RUL-07 no golden run for a withdrawn package',
    format($q$INSERT INTO rules.golden_run (package_id, engine_version, runner, total, passed, failed, outcome, started_at)
              VALUES ('c5000000-0000-7000-8000-00000000f003', %L, 'manual', 1, 1, 0, 'passed', now())$q$, current_setting('cp.engine')), 'HK_RULES_GOLDEN_RUN_STATE');
  -- نگهبان‌های trigger روی جدول‌های فقط‌افزودنی (مستقل از GRANT؛ حتی مالک/migrator)
  PERFORM set_config('app.tenant_id', 'c5a00000-0000-7000-8000-000000000001', true);
  PERFORM public.cp_expect_error('INV-RUL-13 snapshot immutable for the owner too',
    $q$UPDATE rules.calc_snapshot SET min_confidence = 'low' WHERE id = 'c5a00000-0000-7000-8000-000000005001'$q$, 'HK_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-RUL-12 override never deleted (trigger)',
    $q$DELETE FROM rules.param_override WHERE id = 'c5a00000-0000-7000-8000-000000000501'$q$, 'HK_RULES_OVERRIDE_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-TAX-06 issue never deleted (trigger)',
    $q$DELETE FROM tax.invoice_issue WHERE id = 'c5a00000-0000-7000-8000-000000007101'$q$, 'HK_TAX_ISSUE_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-TAX-06 lines immutable (trigger)',
    $q$UPDATE tax.invoice_issue_line SET vam = 0 WHERE issue_id = 'c5a00000-0000-7000-8000-000000007101'$q$, 'HK_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-TAX-04 document never deleted (trigger)',
    $q$DELETE FROM tax.invoice WHERE id = 'c5a00000-0000-7000-8000-000000007001'$q$, 'HK_TAX_INVOICE_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-TAX-06 attempts immutable (trigger)', $q$UPDATE tax.submission_attempt SET http_status = 500$q$, 'HK_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-TAX-06 inquiries immutable (trigger)', $q$DELETE FROM tax.inquiry_log$q$, 'HK_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-TAX-13 used key never deleted (trigger)',
    $q$DELETE FROM tax.memory_key WHERE id = 'c5a00000-0000-7000-8000-000000006201'$q$, 'HK_TAX_KEY_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-TAX-17 register entry never deleted (trigger)',
    $q$DELETE FROM tax.purchase_entry WHERE id = 'c5a00000-0000-7000-8000-000000007301'$q$, 'HK_TAX_PURCHASE_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-PAY-15 accruals immutable (trigger)', $q$UPDATE payroll.accrual_entry SET amount = 1$q$, 'HK_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-PAY-06 raw punches immutable (trigger)', $q$DELETE FROM payroll.clock_event$q$, 'HK_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-PAY-14 file parts immutable (trigger)', $q$DELETE FROM payroll.gov_file_part$q$, 'HK_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-AST-08 asset transactions immutable (trigger)', $q$UPDATE assets.asset_txn SET cost_delta = 1$q$, 'HK_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-AST-04 movements immutable (trigger)', $q$UPDATE assets.asset_movement SET reason = 'x'$q$, 'HK_IMMUTABLE');
END $$;

-- =====================================================================
-- بخش ۴: hk_app — پیشنهاد بازمحاسبه (مابه‌التفاوت)، snapshot با بستهٔ جایگزین‌شده، جداسازی مستأجر
-- =====================================================================
SET ROLE hk_app;

-- ---------- T19: عطف به ماسبق ← پیشنهاد بازمحاسبه ← اجرای مابه‌التفاوت (INV-RUL-15، INV-PAY-16) ----------
DO $$
DECLARE t uuid := 'c5a00000-0000-7000-8000-000000000001'; c uuid := 'c5a00000-0000-7000-8000-0000000000c1';
        u1 uuid := 'c5000000-0000-7000-8000-0000000000e1'; u2 uuid := 'c5000000-0000-7000-8000-0000000000e2';
        rp uuid := 'c5a00000-0000-7000-8000-000000000701'; r1 uuid := 'c5a00000-0000-7000-8000-000000008001';
        r4 uuid := 'c5a00000-0000-7000-8000-000000008004'; e text := current_setting('cp.engine');
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  PERFORM public.cp_expect_error('INV-RUL-13 new snapshots use active packages only',
    format($q$INSERT INTO rules.calc_snapshot (tenant_id, company_id, calculator, engine_version, as_of_from, as_of_to, package_ids, value_ids, content, min_confidence, content_sha256)
              VALUES (%L, %L, 'payroll.run', %L, '2026-04-21', '2026-05-21', ARRAY['c5000000-0000-7000-8000-00000000f001']::uuid[],
                      ARRAY['c5000000-0000-7000-8000-00000000f101']::uuid[], '{"z":1}', 'high', '\x00')$q$, t, c, e), 'HK_RULES_SNAPSHOT_PACKAGE');
  PERFORM public.cp_expect_error('INV-RUL-15 proposals only for the active package',
    format($q$INSERT INTO rules.recalc_proposal (tenant_id, company_id, trigger_package_id, consumer, target_id, target_snapshot_id, changed_keys, affected_from, affected_to)
              VALUES (%L, %L, 'c5000000-0000-7000-8000-00000000f001', 'payroll.run', %L, 'c5a00000-0000-7000-8000-000000005001', '{payroll.wage.min_daily}', '2026-03-21', '2026-04-20')$q$,
           t, c, r1), 'HK_RULES_PROPOSAL_PACKAGE');
  PERFORM public.cp_expect_error('INV-RUL-15 target used an older version of the same package',
    format($q$INSERT INTO rules.recalc_proposal (tenant_id, company_id, trigger_package_id, consumer, target_id, target_snapshot_id, changed_keys, affected_from, affected_to)
              VALUES (%L, %L, 'c5000000-0000-7000-8000-00000000f006', 'payroll.run', %L, 'c5a00000-0000-7000-8000-000000005004', '{payroll.wage.min_daily}', '2026-03-21', '2026-04-20')$q$,
           t, c, r1), 'HK_RULES_PROPOSAL_IRRELEVANT');
  PERFORM public.cp_expect_error('INV-RUL-15 proposals start open',
    format($q$INSERT INTO rules.recalc_proposal (tenant_id, company_id, trigger_package_id, consumer, target_id, target_snapshot_id, changed_keys, affected_from, affected_to, status, decided_by, decided_at)
              VALUES (%L, %L, 'c5000000-0000-7000-8000-00000000f006', 'payroll.run', %L, 'c5a00000-0000-7000-8000-000000005001', '{payroll.wage.min_daily}', '2026-03-21', '2026-04-20', 'accepted', %L, now())$q$,
           t, c, r1, u2), 'HK_RULES_PROPOSAL_TRANSITION');
  INSERT INTO rules.recalc_proposal (tenant_id, id, company_id, trigger_package_id, consumer, target_id, target_snapshot_id, changed_keys, affected_from, affected_to, estimated_delta)
  VALUES (t, rp, c, 'c5000000-0000-7000-8000-00000000f006', 'payroll.run', r1, 'c5a00000-0000-7000-8000-000000005001', '{payroll.wage.min_daily}', '2026-03-21', '2026-04-20',
          '{"employees":1,"gross":"0"}');
  PERFORM public.cp_expect_error('INV-RUL-15 one proposal per package and target',
    format($q$INSERT INTO rules.recalc_proposal (tenant_id, company_id, trigger_package_id, consumer, target_id, target_snapshot_id, changed_keys, affected_from, affected_to)
              VALUES (%L, %L, 'c5000000-0000-7000-8000-00000000f006', 'payroll.run', %L, 'c5a00000-0000-7000-8000-000000005001', '{payroll.wage.min_daily}', '2026-03-21', '2026-04-20')$q$,
           t, c, r1), '23505');
  PERFORM public.cp_expect_error('INV-RUL-15 open cannot jump to applied',
    format($q$UPDATE rules.recalc_proposal SET status = 'applied', decided_by = %L, decided_at = now(), resolution_ref = uuidv7() WHERE id = %L$q$, u2, rp), 'HK_RULES_PROPOSAL_TRANSITION');
  PERFORM public.cp_expect_error('INV-RUL-15 dismissal needs a reason',
    format($q$UPDATE rules.recalc_proposal SET status = 'dismissed', decided_by = %L, decided_at = now(), decision_reason = 'نه' WHERE id = %L$q$, u2, rp), '23514');
  PERFORM public.cp_expect_error('INV-RUL-15 proposal facts immutable',
    format($q$UPDATE rules.recalc_proposal SET changed_keys = '{x}' WHERE id = %L$q$, rp), 'HK_RULES_PROPOSAL_IMMUTABLE');
  UPDATE rules.recalc_proposal SET status = 'accepted', decided_by = u2, decided_at = now() WHERE id = rp;
  -- اجرای مابه‌التفاوت
  PERFORM public.cp_expect_error('INV-PAY-16 difference run references the proposal and base run',
    format($q$INSERT INTO payroll.run (tenant_id, company_id, workshop_id, kind, period_key, period_start, period_end, payment_date)
              VALUES (%L, %L, 'c5a00000-0000-7000-8000-000000001001', 'retro_difference', 'jm:1405-03', '2026-05-22', '2026-06-21', '2026-06-22')$q$, t, c), '23514');
  INSERT INTO payroll.run (tenant_id, id, company_id, workshop_id, kind, period_key, period_start, period_end, payment_date, retro_proposal_id, base_run_id)
  VALUES (t, r4, c, 'c5a00000-0000-7000-8000-000000001001', 'retro_difference', 'jm:1405-03', '2026-05-22', '2026-06-21', '2026-06-22', rp, r1);
  UPDATE rules.recalc_proposal SET status = 'applied', resolution_ref = r4 WHERE id = rp;
  PERFORM public.cp_assert((SELECT status FROM rules.recalc_proposal WHERE id = rp) = 'applied', 'INV-RUL-15 proposal applied by a difference run');
  PERFORM public.cp_expect_error('INV-RUL-15 proposals never deleted', format($q$DELETE FROM rules.recalc_proposal WHERE id = %L$q$, rp), '42501');
  -- مقدار تازه بر تأییدهای تازه حاکم است
  INSERT INTO payroll.decree (tenant_id, id, company_id, employee_id, contract_id, decree_no, effective_from, reason, wage_basis, daily_wage, created_by)
  VALUES (t, 'c5a00000-0000-7000-8000-000000004010', c, 'c5a00000-0000-7000-8000-000000002001', 'c5a00000-0000-7000-8000-000000003001', 'D-10', '2026-06-01', 'annual_adjustment',
          'daily', 1050000, u1);
  PERFORM public.cp_expect_error('INV-PAY-04 floor follows the newly active package',
    format($q$UPDATE payroll.decree SET status = 'approved', approved_by = %L, approved_at = now(), rule_snapshot_id = 'c5a00000-0000-7000-8000-000000005001'
              WHERE id = 'c5a00000-0000-7000-8000-000000004010'$q$, u2), 'HK_PAYROLL_BELOW_MIN_WAGE');
  -- بستهٔ صنفی نصب‌شده در مستأجر
  INSERT INTO rules.tenant_pack (tenant_id, id, company_id, pack_code, installed_version, status, installed_by)
  VALUES (t, 'c5a00000-0000-7000-8000-000000000801', c, 'cafe', '1.0.0', 'active', u1);
  INSERT INTO rules.tenant_pack_event (tenant_id, tenant_pack_id, action, to_version, outcome, plan, actor_user_id)
  VALUES (t, 'c5a00000-0000-7000-8000-000000000801', 'install', '1.0.0', 'succeeded', '{"changes":3}', u1);
  PERFORM public.cp_expect_error('INV-RUL-16 pack events append-only', $q$UPDATE rules.tenant_pack_event SET outcome = 'failed'$q$, '42501');
  PERFORM public.cp_expect_error('INV-RUL-16 artifact entity belongs to its module',
    format($q$INSERT INTO rules.pack_artifact (tenant_id, tenant_pack_id, module, entity_type, artifact_key, entity_id, installed_version, content_sha256)
              VALUES (%L, 'c5a00000-0000-7000-8000-000000000801', 'catalog', 'sales.pricing_rule', 'r1', uuidv7(), '1.0.0', sha256('a'))$q$, t), '23514');
END $$;

-- ---------- T19b: پروفایل مؤدی، وضعیت فراخوان، قفل سطرها پس از امضا، لغو اجرا، واگذاری ثبت‌شده ----------
DO $$
DECLARE t uuid := 'c5a00000-0000-7000-8000-000000000001'; c uuid := 'c5a00000-0000-7000-8000-0000000000c1';
        u1 uuid := 'c5000000-0000-7000-8000-0000000000e1'; v uuid := 'c5a00000-0000-7000-8000-000000007701';
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  INSERT INTO tax.taxpayer_profile (tenant_id, company_id, moadian_enabled, seller_branch_code, prior_year_sales, prior_year_sales_unit, prior_year_sales_year)
  VALUES (t, c, true, '0001', 50000000000, 'IRR', 1404);
  PERFORM public.cp_expect_error('INV-TAX-22 declared prior-year sales carry unit and year',
    format($q$INSERT INTO tax.taxpayer_profile (tenant_id, company_id, prior_year_sales) VALUES (%L, 'c5a00000-0000-7000-8000-0000000000c2', 1)$q$, t), '23514');
  PERFORM public.cp_expect_error('INV-TAX-22 one profile per company',
    format($q$INSERT INTO tax.taxpayer_profile (tenant_id, company_id) VALUES (%L, %L)$q$, t, c), '23505');
  INSERT INTO tax.vat_registration (tenant_id, id, company_id, effective_from, call_status, basis_ref, created_by)
  VALUES (t, v, c, '2026-03-21', 'not_called_in', 'اعلام کارپوشه', u1);
  PERFORM public.cp_expect_error('INV-TAX-22 call-in status ranges do not overlap',
    format($q$INSERT INTO tax.vat_registration (tenant_id, company_id, effective_from, call_status, basis_ref) VALUES (%L, %L, '2026-09-23', 'called_in', 'فراخوان ۱۰')$q$, t, c), '23P01');
  PERFORM public.cp_expect_error('INV-TAX-22 status rows are not edited',
    format($q$UPDATE tax.vat_registration SET call_status = 'called_in' WHERE id = %L$q$, v), 'HK_TAX_REGISTRATION_IMMUTABLE');
  UPDATE tax.vat_registration SET effective_to = '2026-09-23' WHERE id = v;
  INSERT INTO tax.vat_registration (tenant_id, company_id, effective_from, call_status, basis_ref) VALUES (t, c, '2026-09-23', 'called_in', 'فراخوان ۱۰');
  PERFORM public.cp_expect_error('INV-TAX-22 a closed range stays closed',
    format($q$UPDATE tax.vat_registration SET effective_to = '2026-10-01' WHERE id = %L$q$, v), 'HK_TAX_REGISTRATION_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-TAX-06 lines only while prepared',
    format($q$INSERT INTO tax.invoice_issue_line (tenant_id, issue_id, line_no, sstid, sstt, mu, am, fee, amount_scale, prdis, dis, adis, vra, vam, tsstam, rate_source)
              VALUES (%L, 'c5a00000-0000-7000-8000-000000007101', 5, '2710000138624', 'x', '1627', 1, 100, 0, 100, 0, 100, 10, 10, 110, 'sstid_catalog')$q$, t),
    'HK_TAX_ISSUE_IMMUTABLE');
  UPDATE payroll.run SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'اجرای آزمایشی با پارامتر کم‌اطمینان' WHERE id = 'c5a00000-0000-7000-8000-000000008002';
  PERFORM public.cp_expect_error('INV-PAY-08 cancelled run is terminal',
    $q$UPDATE payroll.run SET status = 'approved' WHERE id = 'c5a00000-0000-7000-8000-000000008002'$q$, 'HK_PAYROLL_RUN_TRANSITION');
  PERFORM public.cp_expect_error('INV-AST-10 posted disposal is not edited',
    $q$UPDATE assets.disposal SET proceeds = 1 WHERE id = 'c5a00000-0000-7000-8000-000000009801'$q$, 'HK_ASSETS_IMMUTABLE');
  PERFORM public.cp_expect_error('INV-AST-10 posted disposal reversal is v2',
    $q$UPDATE assets.disposal SET status = 'cancelled', cancel_reason = 'اشتباه' WHERE id = 'c5a00000-0000-7000-8000-000000009801'$q$, 'HK_ASSETS_TRANSITION');
  UPDATE payroll.gov_file SET status = 'accepted' WHERE id = 'c5a00000-0000-7000-8000-000000008401';
  PERFORM public.cp_expect_error('INV-PAY-14 accepted file is final',
    $q$UPDATE payroll.gov_file SET status = 'generated' WHERE id = 'c5a00000-0000-7000-8000-000000008401'$q$, 'HK_PAYROLL_FILE_TRANSITION');
END $$;

-- ---------- T20: جداسازی مستأجر (INV-CMP-01) ----------
DO $$
DECLARE tb uuid := 'c5b00000-0000-7000-8000-000000000001'; cb uuid := 'c5b00000-0000-7000-8000-0000000000c1'; n int;
BEGIN
  PERFORM set_config('app.tenant_id', tb::text, true);
  SELECT (SELECT count(*) FROM rules.calc_snapshot) + (SELECT count(*) FROM rules.param_override) + (SELECT count(*) FROM rules.compliance_item)
       + (SELECT count(*) FROM rules.recalc_proposal) + (SELECT count(*) FROM tax.memory) + (SELECT count(*) FROM tax.memory_key)
       + (SELECT count(*) FROM tax.invoice) + (SELECT count(*) FROM tax.invoice_issue) + (SELECT count(*) FROM tax.invoice_issue_line)
       + (SELECT count(*) FROM tax.submission_attempt) + (SELECT count(*) FROM tax.inquiry_log) + (SELECT count(*) FROM tax.purchase_entry)
       + (SELECT count(*) FROM tax.vat_return) + (SELECT count(*) FROM tax.legal_report) + (SELECT count(*) FROM tax.threshold_monitor)
       + (SELECT count(*) FROM payroll.workshop) + (SELECT count(*) FROM payroll.employee) + (SELECT count(*) FROM payroll.decree)
       + (SELECT count(*) FROM payroll.run) + (SELECT count(*) FROM payroll.payslip) + (SELECT count(*) FROM payroll.payslip_line)
       + (SELECT count(*) FROM payroll.gov_file) + (SELECT count(*) FROM payroll.leave_entry) + (SELECT count(*) FROM assets.asset)
       + (SELECT count(*) FROM assets.asset_txn) + (SELECT count(*) FROM assets.depreciation_run) + (SELECT count(*) FROM tax.v_sales_moadian_status)
       + (SELECT count(*) FROM assets.v_asset_book_balance) + (SELECT count(*) FROM payroll.v_leave_balance)
    INTO n;
  PERFORM public.cp_assert(n = 0, 'INV-CMP-01 tenant B sees none of tenant A rows (tables and security_invoker views)');
  PERFORM public.cp_assert((SELECT count(*) FROM assets.ledger_subledger_fixed_assets('c5a00000-0000-7000-8000-0000000000c1', '2026-06-01')) = 0,
                           'INV-CMP-01 subledger function sees no other tenant data');
  PERFORM public.cp_assert((SELECT count(*) FROM rules.package) > 0 AND (SELECT count(*) FROM rules.param_def) > 0, 'INV-CMP-01 global rules visible to all tenants');
  PERFORM public.cp_expect_error('INV-CMP-01 composite FK blocks cross-tenant references',
    format($q$INSERT INTO tax.invoice (tenant_id, company_id, memory_ref, source_kind, subject, inv_type, pattern, instruction_version)
              VALUES (%L, %L, 'c5a00000-0000-7000-8000-000000006001', 'migration', 1, 2, 1, 'RC_IITP.IS-7.8')$q$, tb, cb), '23503');
  PERFORM public.cp_expect_error('INV-CMP-01 another tenant snapshot cannot be referenced',
    format($q$INSERT INTO tax.threshold_monitor (tenant_id, company_id, kind, tax_year, limit_amount, limit_basis, rule_snapshot_id, warn_ratio)
              VALUES (%L, %L, 'article6_limit', 1405, 10, '{}', 'c5a00000-0000-7000-8000-000000005004', 0.5)$q$, tb, cb), '23503');
  PERFORM public.cp_expect_error('INV-CMP-01 RLS rejects rows of another tenant',
    $q$INSERT INTO payroll.workshop (tenant_id, company_id, code, name, employer_name, address, dsk_rate, salary_tax_format, opened_on)
       VALUES ('c5a00000-0000-7000-8000-000000000001', 'c5a00000-0000-7000-8000-0000000000c1', '9999999999', 'x', 'x', 'x', 23, 'wh-1-7', '2026-03-21')$q$, '42501');
  UPDATE tax.invoice SET withdrawn_reason = 'hack' WHERE id = 'c5a00000-0000-7000-8000-000000007006';
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM public.cp_assert(n = 0, 'INV-CMP-01 updates cannot reach another tenant');
END $$;
DO $$
BEGIN
  PERFORM public.cp_assert((SELECT count(*) FROM tax.invoice) + (SELECT count(*) FROM payroll.run) + (SELECT count(*) FROM assets.asset) = 0,
                           'INV-CMP-01 no tenant context sees nothing');
END $$;

-- =====================================================================
-- بخش ۵: hk_readonly — T21
-- =====================================================================
RESET ROLE;
SET ROLE hk_readonly;
DO $$
BEGIN
  PERFORM set_config('app.tenant_id', 'c5a00000-0000-7000-8000-000000000001', true);
  PERFORM public.cp_assert((SELECT count(*) FROM tax.invoice_issue) > 3 AND (SELECT count(*) FROM payroll.payslip) > 1 AND (SELECT count(*) FROM assets.asset_txn) > 3,
                           'INV-CMP-02 readonly reads compliance data');
  PERFORM public.cp_assert((SELECT count(*) FROM tax.memory_key WHERE fingerprint_sha256 IS NOT NULL) > 0, 'INV-CMP-02 readonly reads key metadata');
  PERFORM public.cp_expect_error('INV-CMP-02 readonly never reads sealed private keys', $q$SELECT private_key_sealed FROM tax.memory_key$q$, '42501');
  PERFORM public.cp_expect_error('INV-CMP-02 readonly cannot write',
    $q$INSERT INTO tax.vat_registration (tenant_id, company_id, effective_from, call_status, basis_ref)
       VALUES ('c5a00000-0000-7000-8000-000000000001', 'c5a00000-0000-7000-8000-0000000000c1', '2026-03-21', 'called_in', 'xx')$q$, '42501');
END $$;
RESET ROLE;

\echo 'ALL 50_compliance TESTS PASSED'
