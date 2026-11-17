-- =====================================================================
-- آزمون پایگاه داده‌ای 25_masterdata.sql (سند: docs/design/04-masterdata.md §۷ و §۹)
--
-- اجرا (از ریشهٔ مخزن؛ پایگاه دادهٔ تازه با UTF8):
--   export PGPASSWORD=postgres
--   psql -h localhost -p 5433 -U postgres -d postgres -c "DROP DATABASE IF EXISTS ds_masterdata"
--   psql -h localhost -p 5433 -U postgres -d postgres -c "CREATE DATABASE ds_masterdata ENCODING 'UTF8' TEMPLATE template0 LC_COLLATE 'C' LC_CTYPE 'C.UTF-8'"
--   psql -h localhost -p 5433 -U postgres -d ds_masterdata -v ON_ERROR_STOP=1 -f docs/design/sql/00_foundation.sql
--   psql -h localhost -p 5433 -U postgres -d ds_masterdata -v ON_ERROR_STOP=1 -f docs/design/sql/25_masterdata.sql
--   psql -h localhost -p 5433 -U postgres -d ds_masterdata -v ON_ERROR_STOP=1 -f docs/design/sql/tests/25_masterdata_test.sql
-- (در پایگاه یکپارچه، 10_core.sql و 20_ledger.sql بین 00 و 25 اجرا می‌شوند و سپس FKهای سند §۱۲؛ این آزمون در هر دو حالت سبز است.)
--
-- ساختار (یک نشست psql که با superuser وصل می‌شود):
--   بخش ۱ (fixture)  — با نقش postgres: مستأجر A و B، دو شرکت A، شعبه، استان/شهر آزمایشی در ref،
--                      توابع کمکی md_expect_error / md_assert.
--   بخش ۲ (assert)   — T01..T18 پس از «SET ROLE hk_app» (نه مالک، NOBYPASSRLS). هر DO block مستأجر را با
--                      set_config('app.tenant_id', '<uuid>', true) تنظیم می‌کند. موارد deferred با
--                      SET CONSTRAINTS ALL IMMEDIATE درون زیرتراکنش آزموده می‌شوند.
--   بخش ۳ (readonly) — T19: «SET ROLE hk_readonly»: فقط خواندن.
-- خروجی موفق با «ALL 25_masterdata TESTS PASSED» پایان می‌یابد؛ هر شکست «TEST FAILED [...]» می‌دهد
-- و psql با کد ≠ ۰ خارج می‌شود. مسیر بردارها: -v id_vectors_file=... و -v fa_vectors_file=...
-- =====================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
\if :{?id_vectors_file}
\else
  \set id_vectors_file docs/design/sql/tests/iran_id_vectors_v1.json
\endif
\if :{?fa_vectors_file}
\else
  \set fa_vectors_file docs/design/sql/tests/fa_text_norm_v1.json
\endif
\set id_vectors `cat :id_vectors_file`
\set fa_vectors `cat :fa_vectors_file`

-- =====================================================================
-- بخش ۱: fixture (postgres)
-- =====================================================================
RESET ROLE;
BEGIN;
INSERT INTO core.tenant (id, slug, display_name) VALUES
  ('25a00000-0000-7000-8000-000000000001', 'md-tenant-a', 'A'),
  ('25b00000-0000-7000-8000-000000000001', 'md-tenant-b', 'B');
INSERT INTO core.company (tenant_id, id, code, name) VALUES
  ('25a00000-0000-7000-8000-000000000001', '25a00000-0000-7000-8000-0000000000c1', 'C1', 'شرکت الف'),
  ('25a00000-0000-7000-8000-000000000001', '25a00000-0000-7000-8000-0000000000c2', 'C2', 'شرکت الف دو'),
  ('25b00000-0000-7000-8000-000000000001', '25b00000-0000-7000-8000-0000000000c1', 'C1', 'شرکت ب');
INSERT INTO core.branch (tenant_id, id, company_id, code, name) VALUES
  ('25a00000-0000-7000-8000-000000000001', '25a00000-0000-7000-8000-0000000000b1', '25a00000-0000-7000-8000-0000000000c1', 'BR1', 'شعبه ۱');
INSERT INTO ref.province (code, country_code, name_fa, divisions_version) VALUES
  ('T23', 'IR', 'تهران', 'test-v1'), ('T04', 'IR', 'اصفهان', 'test-v1')
ON CONFLICT (code) DO NOTHING;
INSERT INTO ref.city (province_code, code, name_fa, divisions_version) VALUES
  ('T23', 'T2301', 'تهران', 'test-v1'), ('T04', 'T0401', 'اصفهان', 'test-v1')
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public.md_expect_error(p_label text, p_sql text, p_expect text) RETURNS void
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
CREATE OR REPLACE FUNCTION public.md_assert(p_cond boolean, p_label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond IS NOT TRUE THEN RAISE EXCEPTION 'TEST FAILED [%]', p_label; END IF;
END $$;
GRANT EXECUTE ON FUNCTION public.md_expect_error(text, text, text), public.md_assert(boolean, text) TO hk_app, hk_readonly;
COMMIT;

-- =====================================================================
-- بخش ۲: ادعاها با نقش برنامه
-- =====================================================================
SET ROLE hk_app;
SELECT public.md_assert(current_user = 'hk_app', 'running as hk_app') \gset

-- ---------- T01 (INV-REF-01): توابع اعتبارسنجی SQL = بردارهای مشترک ----------
CREATE TEMP TABLE md_vec AS
  SELECT * FROM jsonb_to_recordset((:'id_vectors')::jsonb -> 'vectors') AS x(id text, kind text, input text, valid boolean);
DO $$
DECLARE r record; got boolean; n int := 0;
BEGIN
  FOR r IN SELECT * FROM md_vec LOOP
    got := CASE r.kind
      WHEN 'national_code'     THEN ref.is_valid_national_code(r.input)
      WHEN 'legal_national_id' THEN ref.is_valid_legal_national_id(r.input)
      WHEN 'economic_code'     THEN ref.is_valid_economic_code(r.input)
      WHEN 'sheba'             THEN ref.is_valid_sheba(r.input)
      WHEN 'card_number'       THEN ref.is_valid_card_number(r.input)
      WHEN 'postal_code'       THEN ref.is_valid_postal_code(r.input)
      WHEN 'gtin'              THEN ref.is_valid_gtin(r.input) END;
    IF got IS DISTINCT FROM r.valid THEN
      RAISE EXCEPTION 'TEST FAILED [INV-REF-01 %]: % expected % got %', r.id, r.input, r.valid, got;
    END IF;
    n := n + 1;
  END LOOP;
  PERFORM public.md_assert(n >= 50, 'INV-REF-01 vector count');
  -- NULL هرگز «معتبر» یا NULL برنمی‌گرداند (ایمنی CHECK)
  PERFORM public.md_assert(ref.is_valid_national_code(NULL) = false AND ref.is_valid_sheba(NULL) = false
                           AND ref.is_valid_card_number(NULL) = false AND ref.is_valid_gtin(NULL) = false
                           AND ref.is_valid_legal_national_id(NULL) = false, 'INV-REF-01 null is false');
  PERFORM public.md_assert(ref.gtin_check_digit('040000000001') = 5, 'INV-REF-01 rcn check digit');
  PERFORM public.md_assert(ref.sheba_bank_code('IR820540102680020817909002') = '054', 'INV-REF-01 sheba bank code');
END $$;

-- ---------- T02 (INV-MD-05): نرمال‌سازی fa-norm-v1 (shim یا 10_core) = بردارهای هسته ----------
CREATE TEMP TABLE md_fa AS
  SELECT * FROM jsonb_to_recordset((:'fa_vectors')::jsonb -> 'vectors') AS x(id text, input text, text text, ident text, search text);
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM md_fa LOOP
    IF core.fa_normalize_text(r.input) IS DISTINCT FROM r.text OR core.fa_normalize_ident(r.input) IS DISTINCT FROM r.ident
       OR core.fa_search_key(r.input) IS DISTINCT FROM r.search THEN
      RAISE EXCEPTION 'TEST FAILED [INV-MD-05 fa-norm %]', r.id;
    END IF;
  END LOOP;
  PERFORM public.md_assert((SELECT count(*) FROM md_fa) > 10, 'INV-MD-05 fa vectors loaded');
  PERFORM public.md_assert(parties.dedup_name_key('شرکت  بازرگانی آریا (سهامی خاص)') = 'اریا', 'INV-PTY-21 dedup key strips legal forms');
  PERFORM public.md_assert(parties.dedup_name_key('فروشگاه علی رضایی') = parties.dedup_name_key('آقای علی رضائی'), 'INV-PTY-21 dedup key honorifics');
END $$;

-- ---------- T03 (INV-REF-02): ref فقط‌خواندنی ----------
DO $$
BEGIN
  PERFORM public.md_assert((SELECT count(*) FROM ref.bank) >= 30, 'INV-REF-02 banks seeded');
  PERFORM public.md_assert((SELECT bank_code FROM ref.bank_sheba_code WHERE sheba_code = '017') = 'melli', 'INV-REF-02 sheba 017 = melli');
  PERFORM public.md_assert((SELECT count(*) FROM ref.moadian_unit) >= 20, 'INV-REF-02 moadian units seeded');
  PERFORM public.md_expect_error('INV-REF-02 insert bank', $q$INSERT INTO ref.bank (code, name_fa, name_en, source, confidence, data_version) VALUES ('x','x','x','t','low','t')$q$, '42501');
  PERFORM public.md_expect_error('INV-REF-02 update unit', $q$UPDATE ref.moadian_unit SET name_fa = 'x'$q$, '42501');
END $$;

-- ---------- T04: fixture مستأجر A (گروه‌ها، شرایط پرداخت) ----------
DO $$
BEGIN
  PERFORM set_config('app.tenant_id', '25a00000-0000-7000-8000-000000000001', true);
  INSERT INTO parties.party_group (tenant_id, id, role, code, name, is_default) VALUES
    ('25a00000-0000-7000-8000-000000000001', '25a00000-0000-7000-8000-00000000a001', 'customer', 'RETAIL', 'مشتریان خرده', true),
    ('25a00000-0000-7000-8000-000000000001', '25a00000-0000-7000-8000-00000000a002', 'supplier', 'DOMESTIC', 'تأمین‌کنندگان داخلی', true),
    ('25a00000-0000-7000-8000-000000000001', '25a00000-0000-7000-8000-00000000a003', 'customer', 'WHOLESALE', 'همکاران', false);
  INSERT INTO parties.payment_term (tenant_id, id, code, name) VALUES
    ('25a00000-0000-7000-8000-000000000001', '25a00000-0000-7000-8000-00000000a011', 'N30', 'نسیه سی‌روزه');
  INSERT INTO parties.payment_term_line (tenant_id, payment_term_id, line_no, portion_percent, due_basis, due_days) VALUES
    ('25a00000-0000-7000-8000-000000000001', '25a00000-0000-7000-8000-00000000a011', 1, 50, 'document_date', 0),
    ('25a00000-0000-7000-8000-000000000001', '25a00000-0000-7000-8000-00000000a011', 2, 50, 'end_of_jalali_month', 30);
END $$;

-- ---------- T05 (INV-PTY-09): جمع خطوط شرایط پرداخت = ۱۰۰ ----------
DO $$
BEGIN
  PERFORM set_config('app.tenant_id', '25a00000-0000-7000-8000-000000000001', true);
  BEGIN
    INSERT INTO parties.payment_term (tenant_id, id, code, name) VALUES
      ('25a00000-0000-7000-8000-000000000001', '25a00000-0000-7000-8000-00000000a012', 'BAD', 'ناقص');
    INSERT INTO parties.payment_term_line (tenant_id, payment_term_id, line_no, portion_percent, due_basis, due_days) VALUES
      ('25a00000-0000-7000-8000-000000000001', '25a00000-0000-7000-8000-00000000a012', 1, 60, 'document_date', 0),
      ('25a00000-0000-7000-8000-000000000001', '25a00000-0000-7000-8000-00000000a012', 2, 30, 'document_date', 30);
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'TEST FAILED [INV-PTY-09 sum 90 accepted]';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'HK_PARTY_PAYMENT_TERM_SUM%' THEN RAISE; END IF;
  END;
  BEGIN
    INSERT INTO parties.payment_term (tenant_id, id, code, name) VALUES
      ('25a00000-0000-7000-8000-000000000001', '25a00000-0000-7000-8000-00000000a013', 'EMPTY', 'بی‌خط');
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'TEST FAILED [INV-PTY-09 term without lines accepted]';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'HK_PARTY_PAYMENT_TERM_SUM%' THEN RAISE; END IF;
  END;
  PERFORM public.md_expect_error('INV-PTY-22 party group code immutable',
    $q$UPDATE parties.party_group SET code = 'RETAIL2' WHERE id = '25a00000-0000-7000-8000-00000000a001'$q$, 'HK_PARTY_GROUP_CODE_IMMUTABLE');
  PERFORM public.md_expect_error('INV-PTY-22 party group role immutable',
    $q$UPDATE parties.party_group SET role = 'supplier', is_default = false WHERE id = '25a00000-0000-7000-8000-00000000a003'$q$, 'HK_PARTY_GROUP_CODE_IMMUTABLE');
  UPDATE parties.party_group SET name = 'مشتریان خرده‌فروشی' WHERE id = '25a00000-0000-7000-8000-00000000a001';
  PERFORM public.md_expect_error('INV-PTY-09 discount days > due days',
    $q$INSERT INTO parties.payment_term_line (tenant_id, payment_term_id, line_no, portion_percent, due_basis, due_days, early_discount_percent, early_discount_days)
       VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a011',3,1,'document_date',5,2,10)$q$, '23514');
END $$;

-- ---------- T06 (INV-PTY-01..05): هویت شخص ----------
DO $$
DECLARE t uuid := '25a00000-0000-7000-8000-000000000001';
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  -- مثبت‌ها
  INSERT INTO parties.party (tenant_id, id, code, person_type, name, first_name, last_name, national_id, national_id_status, gender) VALUES
    (t, '25a00000-0000-7000-8000-00000000a101', 'P101', 'natural', 'علی محمدی', 'علی', 'محمدی', '0013542419', 'valid', 'male');
  INSERT INTO parties.party (tenant_id, id, code, person_type, name, national_id, national_id_status, economic_code, registration_no) VALUES
    (t, '25a00000-0000-7000-8000-00000000a102', 'P102', 'legal', 'شرکت نمونه', '14003778990', 'valid', '14003778990', '12345');
  INSERT INTO parties.party (tenant_id, id, code, person_type, name, national_id, national_id_status,
                             national_id_override_reason, national_id_override_at) VALUES
    (t, '25a00000-0000-7000-8000-00000000a103', 'P103', 'natural', 'حسن کریمی', '0013542418', 'override', 'کارت ملی دیده شد؛ داده‌های قدیمی', now());
  INSERT INTO parties.party (tenant_id, id, code, person_type, name, national_id, national_id_status) VALUES
    (t, '25a00000-0000-7000-8000-00000000a104', 'P104', 'civil_partnership', 'مشارکت مدنی الف', '12345678901', 'format_only'),
    (t, '25a00000-0000-7000-8000-00000000a105', 'P105', 'foreign_natural', 'Ahmad Karimi', '123456789012', 'format_only');
  INSERT INTO parties.party (tenant_id, id, code, person_type, name, passport_no, passport_country) VALUES
    (t, '25a00000-0000-7000-8000-00000000a106', 'P106', 'foreign_legal', 'Istanbul Trading Ltd', NULL, NULL);
  INSERT INTO parties.party (tenant_id, id, code, person_type, name, is_anonymous) VALUES
    (t, '25a00000-0000-7000-8000-00000000a107', 'WALKIN', 'natural', 'مشتری عمومی', true);
  INSERT INTO parties.party (tenant_id, id, code, person_type, name, company_id) VALUES
    (t, '25a00000-0000-7000-8000-00000000a108', 'P108', 'legal', 'تأمین‌کنندهٔ فقط شرکت یک', '25a00000-0000-7000-8000-0000000000c1');

  -- منفی‌ها
  PERFORM public.md_expect_error('INV-PTY-02 bad checksum marked valid',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, national_id, national_id_status)
       VALUES ('25a00000-0000-7000-8000-000000000001','X1','natural','x','0013542418','valid')$q$, '23514');
  PERFORM public.md_expect_error('INV-PTY-02 override of a valid code',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, national_id, national_id_status, national_id_override_reason, national_id_override_at)
       VALUES ('25a00000-0000-7000-8000-000000000001','X2','natural','x','0067749828','override','بدون دلیل واقعی',now())$q$, '23514');
  PERFORM public.md_expect_error('INV-PTY-02 override without reason',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, national_id, national_id_status, national_id_override_at)
       VALUES ('25a00000-0000-7000-8000-000000000001','X3','natural','x','0013542417','override',now())$q$, '23514');
  PERFORM public.md_expect_error('INV-PTY-02 override of all-same digits',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, national_id, national_id_status, national_id_override_reason, national_id_override_at)
       VALUES ('25a00000-0000-7000-8000-000000000001','X4','natural','x','1111111111','override','دلیل طولانی کافی',now())$q$, '23514');
  PERFORM public.md_expect_error('INV-PTY-02 override fields on valid',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, national_id, national_id_status, national_id_override_reason)
       VALUES ('25a00000-0000-7000-8000-000000000001','X5','natural','x','0499370899','valid','دلیل اضافی')$q$, '23514');
  PERFORM public.md_expect_error('INV-PTY-01 legal id with 10 digits',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, national_id, national_id_status)
       VALUES ('25a00000-0000-7000-8000-000000000001','X6','legal','x','1400377899','valid')$q$, '23514');
  PERFORM public.md_expect_error('INV-PTY-01 civil partnership marked valid',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, national_id, national_id_status)
       VALUES ('25a00000-0000-7000-8000-000000000001','X7','civil_partnership','x','12345678902','valid')$q$, '23514');
  PERFORM public.md_expect_error('INV-PTY-01 foreign legal with national id',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, national_id, national_id_status)
       VALUES ('25a00000-0000-7000-8000-000000000001','X8','foreign_legal','x','123456789013','format_only')$q$, '23514');
  PERFORM public.md_expect_error('INV-PTY-01 national id without status',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, national_id)
       VALUES ('25a00000-0000-7000-8000-000000000001','X9','natural','x','0499370899')$q$, '23514');
  PERFORM public.md_expect_error('INV-PTY-03 duplicate national id',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, national_id, national_id_status)
       VALUES ('25a00000-0000-7000-8000-000000000001','X10','natural','دیگری','0013542419','valid')$q$, '23505');
  PERFORM public.md_expect_error('INV-PTY-04 economic code 12 digits',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, economic_code)
       VALUES ('25a00000-0000-7000-8000-000000000001','X11','legal','x','123456789012')$q$, '23514');
  PERFORM public.md_expect_error('INV-PTY-05 natural with registration no',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, registration_no)
       VALUES ('25a00000-0000-7000-8000-000000000001','X12','natural','x','123')$q$, '23514');
  PERFORM public.md_expect_error('INV-PTY-05 legal with first name',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, first_name)
       VALUES ('25a00000-0000-7000-8000-000000000001','X13','legal','x','علی')$q$, '23514');
  PERFORM public.md_expect_error('INV-PTY-05 birth certificate on foreign natural',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, birth_cert_issue_place) VALUES ('25a00000-0000-7000-8000-000000000001','X17','foreign_natural','x','تهران')$q$, '23514');
  PERFORM public.md_expect_error('INV-PTY-05 birth certificate issued before birth',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, birth_date, birth_cert_issue_date) VALUES ('25a00000-0000-7000-8000-000000000001','X18','natural','x','1990-01-01','1989-12-31')$q$, '23514');
  PERFORM public.md_expect_error('INV-PTY-05 anonymous with id',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, is_anonymous, national_id, national_id_status)
       VALUES ('25a00000-0000-7000-8000-000000000001','X14','natural','x',true,'0499370899','valid')$q$, '23514');
  PERFORM public.md_expect_error('INV-PTY-14 insert as merged',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, status, merged_into_id, merged_at)
       VALUES ('25a00000-0000-7000-8000-000000000001','X15','natural','x','merged','25a00000-0000-7000-8000-00000000a101',now())$q$, 'HK_PARTY_MERGED_ONLY_VIA_MERGE');
  PERFORM public.md_expect_error('INV-MD-05 unnormalized name (Arabic yeh)',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name) VALUES ('25a00000-0000-7000-8000-000000000001','X16','natural','علي')$q$, '23514');
  PERFORM public.md_expect_error('INV-MD-05 duplicate party code',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name) VALUES ('25a00000-0000-7000-8000-000000000001','P101','natural','x')$q$, '23505');
  PERFORM public.md_expect_error('INV-PTY-14 direct status merged',
    $q$UPDATE parties.party SET status = 'merged', merged_into_id = '25a00000-0000-7000-8000-00000000a102', merged_at = now()
       WHERE id = '25a00000-0000-7000-8000-00000000a101'$q$, 'HK_PARTY_MERGED_ONLY_VIA_MERGE');
  -- بازگشت‌پذیری active ↔ inactive و row_version
  UPDATE parties.party SET status = 'inactive' WHERE id = '25a00000-0000-7000-8000-00000000a104';
  UPDATE parties.party SET status = 'active' WHERE id = '25a00000-0000-7000-8000-00000000a104';
  PERFORM public.md_assert((SELECT row_version FROM parties.party WHERE id = '25a00000-0000-7000-8000-00000000a104') = 3, 'INV-MD-06 row_version increments');
END $$;

-- ---------- T07 (INV-PTY-06..08): نقش‌ها ----------
DO $$
DECLARE t uuid := '25a00000-0000-7000-8000-000000000001';
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  INSERT INTO parties.party_role (tenant_id, id, party_id, role, group_id, credit_limit, credit_currency, credit_control, payment_term_id) VALUES
    (t, '25a00000-0000-7000-8000-00000000a201', '25a00000-0000-7000-8000-00000000a101', 'customer', '25a00000-0000-7000-8000-00000000a001',
     500000000, 'IRR', 'block', '25a00000-0000-7000-8000-00000000a011');
  INSERT INTO parties.party_role (tenant_id, party_id, role, company_id, group_id, credit_limit, credit_currency, credit_control) VALUES
    (t, '25a00000-0000-7000-8000-00000000a101', 'customer', '25a00000-0000-7000-8000-0000000000c1', '25a00000-0000-7000-8000-00000000a003',
     900000000, 'IRR', 'warn');
  INSERT INTO parties.party_role (tenant_id, party_id, role, group_id) VALUES
    (t, '25a00000-0000-7000-8000-00000000a101', 'supplier', '25a00000-0000-7000-8000-00000000a002'),
    (t, '25a00000-0000-7000-8000-00000000a102', 'supplier', '25a00000-0000-7000-8000-00000000a002'),
    (t, '25a00000-0000-7000-8000-00000000a107', 'customer', '25a00000-0000-7000-8000-00000000a001');
  PERFORM public.md_assert((SELECT credit_limit FROM parties.role_settings('25a00000-0000-7000-8000-00000000a101','customer','25a00000-0000-7000-8000-0000000000c1')) = 900000000,
                           'INV-PTY-07 company-specific role settings win');
  PERFORM public.md_assert((SELECT credit_limit FROM parties.role_settings('25a00000-0000-7000-8000-00000000a101','customer','25a00000-0000-7000-8000-0000000000c2')) = 500000000,
                           'INV-PTY-07 default role settings as fallback');
  PERFORM public.md_expect_error('INV-PTY-06 customer role with supplier group',
    $q$INSERT INTO parties.party_role (tenant_id, party_id, role, group_id) VALUES
       ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a103','customer','25a00000-0000-7000-8000-00000000a002')$q$, '23503');
  PERFORM public.md_expect_error('INV-PTY-07 duplicate role/company',
    $q$INSERT INTO parties.party_role (tenant_id, party_id, role) VALUES
       ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101','supplier')$q$, '23505');
  PERFORM public.md_expect_error('INV-PTY-07 role for a company outside party scope',
    $q$INSERT INTO parties.party_role (tenant_id, party_id, role, company_id) VALUES
       ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a108','supplier','25a00000-0000-7000-8000-0000000000c2')$q$, 'HK_PARTY_ROLE_COMPANY_SCOPE');
  PERFORM public.md_expect_error('INV-PTY-07 anonymous as supplier',
    $q$INSERT INTO parties.party_role (tenant_id, party_id, role) VALUES
       ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a107','supplier')$q$, 'HK_PARTY_ANONYMOUS_ROLE');
  PERFORM public.md_expect_error('INV-PTY-08 credit limit without currency',
    $q$INSERT INTO parties.party_role (tenant_id, party_id, role, credit_limit) VALUES
       ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a103','customer',1000)$q$, '23514');
  PERFORM public.md_expect_error('INV-PTY-08 block without limit',
    $q$INSERT INTO parties.party_role (tenant_id, party_id, role, credit_control) VALUES
       ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a103','customer','block')$q$, '23514');
  PERFORM public.md_expect_error('INV-PTY-08 credit on employee role',
    $q$INSERT INTO parties.party_role (tenant_id, party_id, role, credit_limit, credit_currency) VALUES
       ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a103','employee',1000,'IRR')$q$, '23514');
END $$;

-- ---------- T08 (INV-PTY-10..12): ارتباط، نشانی، حساب بانکی ----------
DO $$
DECLARE t uuid := '25a00000-0000-7000-8000-000000000001';
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  INSERT INTO parties.party_contact (tenant_id, party_id, kind, value, is_primary) VALUES
    (t, '25a00000-0000-7000-8000-00000000a101', 'mobile', '09121234567', true),
    (t, '25a00000-0000-7000-8000-00000000a101', 'email', 'ali@example.ir', true),
    (t, '25a00000-0000-7000-8000-00000000a105', 'mobile', '+905321234567', false);
  PERFORM public.md_expect_error('INV-PTY-10 mobile without leading zero',
    $q$INSERT INTO parties.party_contact (tenant_id, party_id, kind, value) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101','mobile','9121234567')$q$, '23514');
  PERFORM public.md_expect_error('INV-PTY-10 +98 must be normalized',
    $q$INSERT INTO parties.party_contact (tenant_id, party_id, kind, value) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101','mobile','+989121234560')$q$, '23514');
  PERFORM public.md_expect_error('INV-PTY-10 email upper case',
    $q$INSERT INTO parties.party_contact (tenant_id, party_id, kind, value) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101','email','Ali@Example.ir')$q$, '23514');
  PERFORM public.md_expect_error('INV-PTY-10 second primary mobile',
    $q$INSERT INTO parties.party_contact (tenant_id, party_id, kind, value, is_primary) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101','mobile','09121234568',true)$q$, '23505');

  INSERT INTO parties.party_address (tenant_id, party_id, is_primary, is_billing, province_code, city_code, address_line, postal_code, moadian_branch_code) VALUES
    (t, '25a00000-0000-7000-8000-00000000a102', true, true, 'T23', 'T2301', 'خیابان ولیعصر، کوچهٔ یکم', '1193653471', '0001');
  INSERT INTO parties.party_address (tenant_id, party_id, country_code, address_line, postal_code) VALUES
    (t, '25a00000-0000-7000-8000-00000000a106', 'TR', 'Istiklal Cd. 1, Istanbul', '34430');
  PERFORM public.md_expect_error('INV-PTY-11 city outside province',
    $q$INSERT INTO parties.party_address (tenant_id, party_id, province_code, city_code, address_line) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a102','T04','T2301','نشانی')$q$, '23503');
  PERFORM public.md_expect_error('INV-PTY-11 postal 9 digits',
    $q$INSERT INTO parties.party_address (tenant_id, party_id, address_line, postal_code) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a102','نشانی','119365347')$q$, '23514');
  PERFORM public.md_expect_error('INV-PTY-11 foreign address with Iranian province',
    $q$INSERT INTO parties.party_address (tenant_id, party_id, country_code, province_code, address_line) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a106','TR','T23','x street')$q$, '23514');

  INSERT INTO parties.party_bank_account (tenant_id, id, party_id, sheba, holder_name, is_primary) VALUES
    (t, '25a00000-0000-7000-8000-00000000a301', '25a00000-0000-7000-8000-00000000a102', 'IR820540102680020817909002', 'شرکت نمونه', true);
  PERFORM public.md_assert((SELECT bank_code FROM parties.party_bank_account WHERE id = '25a00000-0000-7000-8000-00000000a301') = 'parsian',
                           'INV-PTY-12 bank derived from SHEBA');
  INSERT INTO parties.party_bank_account (tenant_id, id, party_id, card_number) VALUES
    (t, '25a00000-0000-7000-8000-00000000a302', '25a00000-0000-7000-8000-00000000a101', '6037701689095443');
  PERFORM public.md_assert((SELECT bank_code FROM parties.party_bank_account WHERE id = '25a00000-0000-7000-8000-00000000a302') = 'keshavarzi',
                           'INV-PTY-12 bank from card BIN (display only)');
  PERFORM public.md_expect_error('INV-PTY-12 invalid SHEBA',
    $q$INSERT INTO parties.party_bank_account (tenant_id, party_id, sheba) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101','IR820540102680020817909003')$q$, '23514');
  PERFORM public.md_expect_error('INV-PTY-12 invalid card',
    $q$INSERT INTO parties.party_bank_account (tenant_id, party_id, card_number) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101','6037701689095444')$q$, '23514');
  PERFORM public.md_expect_error('INV-PTY-12 SHEBA/bank mismatch',
    $q$INSERT INTO parties.party_bank_account (tenant_id, party_id, sheba, bank_code) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101','IR550570022080013447370101','melli')$q$, 'HK_PARTY_BANK_MISMATCH');
  PERFORM public.md_expect_error('INV-PTY-12 no identifier',
    $q$INSERT INTO parties.party_bank_account (tenant_id, party_id, branch_name) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101','شعبه')$q$, '23514');
  UPDATE parties.party_bank_account SET verified_holder_name = 'شرکت نمونه', verified_at = now(), verification_provider = 'test'
   WHERE id = '25a00000-0000-7000-8000-00000000a301';
  UPDATE parties.party_bank_account SET sheba = 'IR550570022080013447370101', bank_code = NULL WHERE id = '25a00000-0000-7000-8000-00000000a301';
  PERFORM public.md_assert((SELECT verified_at IS NULL AND bank_code = 'pasargad' FROM parties.party_bank_account
                             WHERE id = '25a00000-0000-7000-8000-00000000a301'), 'INV-PTY-12 SHEBA change clears verification');
END $$;

-- ---------- T09 (INV-PTY-13, 18..20): توقیف، کد قدیمی، استعلام، رد تکراری ----------
DO $$
DECLARE t uuid := '25a00000-0000-7000-8000-000000000001';
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  INSERT INTO parties.party_hold (tenant_id, id, party_id, scope, source, reason) VALUES
    (t, '25a00000-0000-7000-8000-00000000a401', '25a00000-0000-7000-8000-00000000a103', 'sales', 'manual', 'چک برگشتی');
  PERFORM public.md_expect_error('INV-PTY-13 second active hold',
    $q$INSERT INTO parties.party_hold (tenant_id, party_id, scope, source, reason) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a103','sales','manual','تکراری')$q$, '23505');
  PERFORM public.md_assert((SELECT sales_hold AND NOT purchase_hold FROM parties.v_party_hold_state
                             WHERE party_id = '25a00000-0000-7000-8000-00000000a103'), 'INV-PTY-13 hold state view');
  PERFORM public.md_expect_error('INV-PTY-13 edit hold reason',
    $q$UPDATE parties.party_hold SET reason = 'دلیل دیگر' WHERE id = '25a00000-0000-7000-8000-00000000a401'$q$, 'HK_PARTY_HOLD_IMMUTABLE');
  UPDATE parties.party_hold SET released_at = now(), release_note = 'تسویه شد' WHERE id = '25a00000-0000-7000-8000-00000000a401';
  PERFORM public.md_expect_error('INV-PTY-13 release twice',
    $q$UPDATE parties.party_hold SET release_note = 'باز هم' WHERE id = '25a00000-0000-7000-8000-00000000a401'$q$, 'HK_PARTY_HOLD_RELEASED');
  PERFORM public.md_expect_error('INV-PTY-13 delete hold',
    $q$DELETE FROM parties.party_hold WHERE id = '25a00000-0000-7000-8000-00000000a401'$q$, '42501');

  INSERT INTO parties.party_legacy_code (tenant_id, id, party_id, source_system, source_scope, legacy_code, legacy_name) VALUES
    (t, '25a00000-0000-7000-8000-00000000a501', '25a00000-0000-7000-8000-00000000a101', 'holoo', 'Holoo1', '10001', 'علي محمدي');
  PERFORM public.md_expect_error('INV-PTY-18 duplicate legacy code',
    $q$INSERT INTO parties.party_legacy_code (tenant_id, party_id, source_system, source_scope, legacy_code) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a102','holoo','Holoo1','10001')$q$, '23505');
  PERFORM public.md_expect_error('INV-PTY-18 legacy code immutable',
    $q$UPDATE parties.party_legacy_code SET legacy_code = '10002' WHERE id = '25a00000-0000-7000-8000-00000000a501'$q$, 'HK_PARTY_LEGACY_CODE_IMMUTABLE');

  INSERT INTO parties.party_taxpayer_inquiry (tenant_id, party_id, economic_code, outcome, taxpayer_name, adapter) VALUES
    (t, '25a00000-0000-7000-8000-00000000a102', '14003778990', 'found', 'شرکت نمونه', 'mock');
  PERFORM public.md_expect_error('INV-PTY-19 inquiry update',
    $q$UPDATE parties.party_taxpayer_inquiry SET outcome = 'error'$q$, '42501');
  PERFORM public.md_expect_error('INV-PTY-20 dismissal order',
    $q$INSERT INTO parties.duplicate_dismissal (tenant_id, party_a_id, party_b_id) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a102','25a00000-0000-7000-8000-00000000a101')$q$, '23514');
END $$;

-- ---------- T10 (INV-PTY-14..17, 21): تکراری و ادغام ----------
DO $$
DECLARE t uuid := '25a00000-0000-7000-8000-000000000001'; v_merge uuid; r record;
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  INSERT INTO parties.party (tenant_id, id, code, person_type, name) VALUES
    (t, '25a00000-0000-7000-8000-00000000a110', 'P110', 'natural', 'فروشگاه علی رضایی');
  INSERT INTO parties.party (tenant_id, id, code, person_type, name, national_id, national_id_status) VALUES
    (t, '25a00000-0000-7000-8000-00000000a111', 'P111', 'natural', 'علی رضائی', '0067749828', 'valid');
  INSERT INTO parties.party (tenant_id, id, code, person_type, name) VALUES
    (t, '25a00000-0000-7000-8000-00000000a113', 'P113', 'natural', 'علی رضایی تهرانی');
  INSERT INTO parties.party_contact (tenant_id, party_id, kind, value, is_primary) VALUES
    (t, '25a00000-0000-7000-8000-00000000a110', 'mobile', '09121111111', true),
    (t, '25a00000-0000-7000-8000-00000000a111', 'mobile', '09121111111', true),
    (t, '25a00000-0000-7000-8000-00000000a111', 'email', 'reza@example.ir', false);
  INSERT INTO parties.party_bank_account (tenant_id, party_id, sheba) VALUES
    (t, '25a00000-0000-7000-8000-00000000a111', 'IR790610000000700796858044');
  INSERT INTO parties.party_role (tenant_id, party_id, role, group_id) VALUES
    (t, '25a00000-0000-7000-8000-00000000a111', 'customer', '25a00000-0000-7000-8000-00000000a001');
  INSERT INTO parties.party_legacy_code (tenant_id, party_id, source_system, source_scope, legacy_code) VALUES
    (t, '25a00000-0000-7000-8000-00000000a110', 'holoo', 'Holoo1', '1001'),
    (t, '25a00000-0000-7000-8000-00000000a111', 'holoo', 'Holoo1', '1002');

  -- INV-PTY-21: نامزد تکراری با موبایل و نام
  SELECT * INTO r FROM parties.find_duplicate_candidates('25a00000-0000-7000-8000-00000000a110') c
   WHERE c.candidate_id = '25a00000-0000-7000-8000-00000000a111';
  PERFORM public.md_assert(r.reasons @> ARRAY['mobile','name'], 'INV-PTY-21 duplicate found by mobile + name');

  -- پیش‌شرط‌های ادغام
  PERFORM public.md_expect_error('INV-PTY-16 merge same',
    $q$SELECT parties.merge_parties('25a00000-0000-7000-8000-00000000a110','25a00000-0000-7000-8000-00000000a110','دلیل کافی',NULL)$q$, 'HK_PARTY_MERGE_SAME');
  PERFORM public.md_expect_error('INV-PTY-16 short reason',
    $q$SELECT parties.merge_parties('25a00000-0000-7000-8000-00000000a110','25a00000-0000-7000-8000-00000000a111','کم',NULL)$q$, 'HK_PARTY_MERGE_REASON');
  PERFORM public.md_expect_error('INV-PTY-16 identity conflict',
    $q$SELECT parties.merge_parties('25a00000-0000-7000-8000-00000000a101','25a00000-0000-7000-8000-00000000a111','دو شخص متفاوت',NULL)$q$, 'HK_PARTY_MERGE_IDENTITY_CONFLICT');
  PERFORM public.md_expect_error('INV-PTY-16 anonymous',
    $q$SELECT parties.merge_parties('25a00000-0000-7000-8000-00000000a110','25a00000-0000-7000-8000-00000000a107','مشتری عمومی',NULL)$q$, 'HK_PARTY_MERGE_ANONYMOUS');

  -- ادغام P111 در P110
  v_merge := parties.merge_parties('25a00000-0000-7000-8000-00000000a110', '25a00000-0000-7000-8000-00000000a111',
                                   'یک شخص با دو کد در هلو', NULL, '[{"module":"test","rewired":0}]'::jsonb);
  PERFORM public.md_assert((SELECT status = 'merged' AND merged_into_id = '25a00000-0000-7000-8000-00000000a110'
                              FROM parties.party WHERE id = '25a00000-0000-7000-8000-00000000a111'), 'INV-PTY-14 loser merged');
  PERFORM public.md_assert((SELECT national_id = '0067749828' AND national_id_status = 'valid' FROM parties.party
                             WHERE id = '25a00000-0000-7000-8000-00000000a110'), 'INV-PTY-16 winner adopts identity');
  PERFORM public.md_assert((SELECT count(*) FROM parties.party_contact WHERE party_id = '25a00000-0000-7000-8000-00000000a110') = 2,
                           'INV-PTY-16 contacts moved without duplicates');
  PERFORM public.md_assert((SELECT count(*) FROM parties.party_contact WHERE party_id = '25a00000-0000-7000-8000-00000000a111' AND is_active) = 0,
                           'INV-PTY-16 loser contacts deactivated');
  PERFORM public.md_assert((SELECT count(*) FROM parties.party_bank_account WHERE party_id = '25a00000-0000-7000-8000-00000000a110') = 1,
                           'INV-PTY-16 bank account moved');
  PERFORM public.md_assert((SELECT count(*) FROM parties.party_role WHERE party_id = '25a00000-0000-7000-8000-00000000a110' AND role = 'customer') = 1,
                           'INV-PTY-16 role moved');
  PERFORM public.md_assert((SELECT count(*) FROM parties.party_legacy_code WHERE party_id = '25a00000-0000-7000-8000-00000000a110') = 3,
                           'INV-PTY-16 legacy codes moved + loser code recorded');
  PERFORM public.md_assert((SELECT canonical_party_id FROM parties.v_party_canonical WHERE party_id = '25a00000-0000-7000-8000-00000000a111')
                           = '25a00000-0000-7000-8000-00000000a110', 'INV-PTY-15 canonical view');
  PERFORM public.md_assert((SELECT (moved ->> 'party_contact')::int = 1 AND jsonb_array_length(participants) = 1 FROM parties.party_merge WHERE id = v_merge),
                           'INV-PTY-17 merge record');
  -- ردیف ادغام‌شده فقط‌خواندنی و بدون فرزند تازه
  PERFORM public.md_expect_error('INV-PTY-14 merged row immutable',
    $q$UPDATE parties.party SET name = 'نام تازه' WHERE id = '25a00000-0000-7000-8000-00000000a111'$q$, 'HK_PARTY_MERGED_IMMUTABLE');
  PERFORM public.md_expect_error('INV-PTY-14 child for merged party',
    $q$INSERT INTO parties.party_contact (tenant_id, party_id, kind, value) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a111','mobile','09129999999')$q$, 'HK_PARTY_MERGED');
  PERFORM public.md_expect_error('INV-PTY-14 delete merged party',
    $q$DELETE FROM parties.party WHERE id = '25a00000-0000-7000-8000-00000000a111'$q$, 'HK_PARTY_MERGED_IMMUTABLE');
  PERFORM public.md_expect_error('INV-PTY-16 merge already merged',
    $q$SELECT parties.merge_parties('25a00000-0000-7000-8000-00000000a113','25a00000-0000-7000-8000-00000000a111','دوباره ادغام',NULL)$q$, 'HK_PARTY_ALREADY_MERGED');
  PERFORM public.md_expect_error('INV-PTY-17 merge record immutable',
    $q$UPDATE parties.party_merge SET reason = 'x' WHERE true$q$, '42501');
  -- شناسهٔ ملی بازنده دیگر یکتایی را اشغال نمی‌کند؛ ولی شخص فعال تازه با همان شناسه رد می‌شود
  PERFORM public.md_expect_error('INV-PTY-03 duplicate of adopted id',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, national_id, national_id_status) VALUES ('25a00000-0000-7000-8000-000000000001','X20','natural','x','0067749828','valid')$q$, '23505');

  -- فشرده‌سازی مسیر: ادغام P110 در P113 ← P111 مستقیم به P113
  PERFORM parties.merge_parties('25a00000-0000-7000-8000-00000000a113', '25a00000-0000-7000-8000-00000000a110', 'ادغام دوم برای آزمون زنجیره', NULL);
  PERFORM public.md_assert((SELECT merged_into_id FROM parties.party WHERE id = '25a00000-0000-7000-8000-00000000a111')
                           = '25a00000-0000-7000-8000-00000000a113', 'INV-PTY-15 path compression');
  PERFORM public.md_assert(NOT EXISTS (SELECT 1 FROM parties.party c JOIN parties.party w ON w.tenant_id = c.tenant_id AND w.id = c.merged_into_id
                                        WHERE w.status = 'merged'), 'INV-PTY-15 no merge chains');
  PERFORM public.md_assert((SELECT national_id FROM parties.party WHERE id = '25a00000-0000-7000-8000-00000000a113') = '0067749828',
                           'INV-PTY-16 identity travels along the chain');
END $$;

-- ---------- T11: fixture کاتالوگ (مستأجر A) ----------
DO $$
DECLARE t uuid := '25a00000-0000-7000-8000-000000000001';
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  INSERT INTO catalog.uom (tenant_id, id, code, name, dimension, dimension_factor, qty_decimals, moadian_unit_code) VALUES
    (t, '25a00000-0000-7000-8000-00000000c001', 'PCS', 'عدد', 'count', 1, 0, '1627'),
    (t, '25a00000-0000-7000-8000-00000000c002', 'CTN', 'کارتن', 'count', NULL, 0, '1624'),
    (t, '25a00000-0000-7000-8000-00000000c003', 'KG', 'کیلوگرم', 'mass', 1, 3, '164'),
    (t, '25a00000-0000-7000-8000-00000000c004', 'G', 'گرم', 'mass', 0.001, 0, '1622'),
    (t, '25a00000-0000-7000-8000-00000000c005', 'PAIR', 'جفت', 'count', 2, 0, '1643'),
    (t, '25a00000-0000-7000-8000-00000000c006', 'CUP', 'لیوان', 'count', NULL, 0, '16108'),
    (t, '25a00000-0000-7000-8000-00000000c007', 'L', 'لیتر', 'volume', 1, 3, '1637'),
    (t, '25a00000-0000-7000-8000-00000000c008', 'ML', 'میلی‌لیتر', 'volume', 0.001, 0, NULL);
  INSERT INTO catalog.attribute (tenant_id, id, code, name, value_type, can_be_variant_axis) VALUES
    (t, '25a00000-0000-7000-8000-00000000c011', 'size', 'سایز', 'option', true),
    (t, '25a00000-0000-7000-8000-00000000c012', 'color', 'رنگ', 'option', true),
    (t, '25a00000-0000-7000-8000-00000000c013', 'material', 'جنس', 'option', false),
    (t, '25a00000-0000-7000-8000-00000000c014', 'voltage', 'ولتاژ', 'number', false);
  INSERT INTO catalog.attribute_value (tenant_id, id, attribute_id, code, name, sort_order) VALUES
    (t, '25a00000-0000-7000-8000-00000000c021', '25a00000-0000-7000-8000-00000000c011', '40', '۴۰', 1),
    (t, '25a00000-0000-7000-8000-00000000c022', '25a00000-0000-7000-8000-00000000c011', '41', '۴۱', 2),
    (t, '25a00000-0000-7000-8000-00000000c023', '25a00000-0000-7000-8000-00000000c011', '42', '۴۲', 3),
    (t, '25a00000-0000-7000-8000-00000000c024', '25a00000-0000-7000-8000-00000000c012', 'BLK', 'مشکی', 1),
    (t, '25a00000-0000-7000-8000-00000000c025', '25a00000-0000-7000-8000-00000000c012', 'BRN', 'قهوه‌ای', 2),
    (t, '25a00000-0000-7000-8000-00000000c026', '25a00000-0000-7000-8000-00000000c013', 'LTH', 'چرم', 1);
  INSERT INTO catalog.attribute_set (tenant_id, id, code, name, source_pack, source_pack_version) VALUES
    (t, '25a00000-0000-7000-8000-00000000c031', 'shoes', 'کفش', 'retail_apparel', '1.0');
  INSERT INTO catalog.attribute_set_member (tenant_id, attribute_set_id, attribute_id, usage, axis_position) VALUES
    (t, '25a00000-0000-7000-8000-00000000c031', '25a00000-0000-7000-8000-00000000c011', 'variant_axis', 1),
    (t, '25a00000-0000-7000-8000-00000000c031', '25a00000-0000-7000-8000-00000000c012', 'variant_axis', 2),
    (t, '25a00000-0000-7000-8000-00000000c031', '25a00000-0000-7000-8000-00000000c013', 'descriptive', NULL);
  INSERT INTO catalog.item_posting_group (tenant_id, id, code, name) VALUES
    (t, '25a00000-0000-7000-8000-00000000c041', 'GOODS', 'کالای تجاری');
  INSERT INTO catalog.item_category (tenant_id, id, parent_id, code, name, default_posting_group_id) VALUES
    (t, '25a00000-0000-7000-8000-00000000c051', NULL, 'ROOT', 'همه', '25a00000-0000-7000-8000-00000000c041'),
    (t, '25a00000-0000-7000-8000-00000000c052', '25a00000-0000-7000-8000-00000000c051', 'SHOES', 'کفش', NULL),
    (t, '25a00000-0000-7000-8000-00000000c053', '25a00000-0000-7000-8000-00000000c051', 'CAFE', 'کافه', NULL);

  -- کالای ساده (سیم): واحد پایه عدد، کارتن = ۲۴ عدد
  INSERT INTO catalog.item (tenant_id, id, code, name, item_type, category_id, base_uom_id, sstid, sstid_kind, tax_category_code) VALUES
    (t, '25a00000-0000-7000-8000-00000000c101', 'CABLE-1', 'سیم ۱.۵ مفتولی', 'stock', '25a00000-0000-7000-8000-00000000c051',
     '25a00000-0000-7000-8000-00000000c001', '2710000138624', 'general', 'standard');
  INSERT INTO catalog.item_uom (tenant_id, item_id, uom_id, factor, is_base) VALUES
    (t, '25a00000-0000-7000-8000-00000000c101', '25a00000-0000-7000-8000-00000000c001', 1, true),
    (t, '25a00000-0000-7000-8000-00000000c101', '25a00000-0000-7000-8000-00000000c002', 24, false);
  INSERT INTO catalog.item_variant (tenant_id, id, item_id, code, is_default) VALUES
    (t, '25a00000-0000-7000-8000-00000000c111', '25a00000-0000-7000-8000-00000000c101', 'CABLE-1', true);

  -- کالای variantدار (کفش): سایز × رنگ
  INSERT INTO catalog.item (tenant_id, id, code, name, item_type, category_id, attribute_set_id, base_uom_id, has_variants, variant_axis1_id, variant_axis2_id) VALUES
    (t, '25a00000-0000-7000-8000-00000000c102', 'SH-100', 'کفش چرم مردانه', 'stock', '25a00000-0000-7000-8000-00000000c052',
     '25a00000-0000-7000-8000-00000000c031', '25a00000-0000-7000-8000-00000000c005', true,
     '25a00000-0000-7000-8000-00000000c011', '25a00000-0000-7000-8000-00000000c012');
  INSERT INTO catalog.item_uom (tenant_id, item_id, uom_id, factor, is_base) VALUES
    (t, '25a00000-0000-7000-8000-00000000c102', '25a00000-0000-7000-8000-00000000c005', 1, true);
  INSERT INTO catalog.item_variant (tenant_id, id, item_id, code, axis1_value_id, axis2_value_id, name_suffix) VALUES
    (t, '25a00000-0000-7000-8000-00000000c121', '25a00000-0000-7000-8000-00000000c102', 'SH-100-40-BLK', '25a00000-0000-7000-8000-00000000c021', '25a00000-0000-7000-8000-00000000c024', '۴۰ / مشکی'),
    (t, '25a00000-0000-7000-8000-00000000c122', '25a00000-0000-7000-8000-00000000c102', 'SH-100-41-BLK', '25a00000-0000-7000-8000-00000000c022', '25a00000-0000-7000-8000-00000000c024', '۴۱ / مشکی'),
    (t, '25a00000-0000-7000-8000-00000000c123', '25a00000-0000-7000-8000-00000000c102', 'SH-100-40-BRN', '25a00000-0000-7000-8000-00000000c021', '25a00000-0000-7000-8000-00000000c025', '۴۰ / قهوه‌ای');
  INSERT INTO catalog.item_attribute_value (tenant_id, item_id, attribute_id, value_id) VALUES
    (t, '25a00000-0000-7000-8000-00000000c102', '25a00000-0000-7000-8000-00000000c013', '25a00000-0000-7000-8000-00000000c026');

  -- کافه: شیر و قهوه (انباری)، لاته (غیرانباری با دستور پخت)
  INSERT INTO catalog.item (tenant_id, id, code, name, item_type, category_id, base_uom_id, is_sellable) VALUES
    (t, '25a00000-0000-7000-8000-00000000c103', 'MILK', 'شیر', 'stock', '25a00000-0000-7000-8000-00000000c053', '25a00000-0000-7000-8000-00000000c007', false),
    (t, '25a00000-0000-7000-8000-00000000c104', 'BEANS', 'دانهٔ قهوه', 'stock', '25a00000-0000-7000-8000-00000000c053', '25a00000-0000-7000-8000-00000000c003', true);
  INSERT INTO catalog.item (tenant_id, id, code, name, item_type, category_id, base_uom_id, is_purchasable) VALUES
    (t, '25a00000-0000-7000-8000-00000000c105', 'LATTE', 'لاته', 'non_stock', '25a00000-0000-7000-8000-00000000c053', '25a00000-0000-7000-8000-00000000c006', false),
    (t, '25a00000-0000-7000-8000-00000000c106', 'GIFT', 'بستهٔ هدیه', 'non_stock', '25a00000-0000-7000-8000-00000000c053', '25a00000-0000-7000-8000-00000000c001', false);
  INSERT INTO catalog.item (tenant_id, id, code, name, item_type, base_uom_id, track_batch, track_expiry, shelf_life_days) VALUES
    (t, '25a00000-0000-7000-8000-00000000c107', 'CHEESE', 'پنیر وزنی', 'stock', '25a00000-0000-7000-8000-00000000c003', true, true, 30);
  INSERT INTO catalog.item (tenant_id, id, code, name, item_type, base_uom_id) VALUES
    (t, '25a00000-0000-7000-8000-00000000c108', 'TSHIRT', 'تی‌شرت', 'stock', '25a00000-0000-7000-8000-00000000c001');
  INSERT INTO catalog.item_uom (tenant_id, item_id, uom_id, factor, is_base) VALUES
    (t, '25a00000-0000-7000-8000-00000000c103', '25a00000-0000-7000-8000-00000000c007', 1, true),
    (t, '25a00000-0000-7000-8000-00000000c103', '25a00000-0000-7000-8000-00000000c008', 0.001, false),
    (t, '25a00000-0000-7000-8000-00000000c104', '25a00000-0000-7000-8000-00000000c003', 1, true),
    (t, '25a00000-0000-7000-8000-00000000c104', '25a00000-0000-7000-8000-00000000c004', 0.001, false),
    (t, '25a00000-0000-7000-8000-00000000c105', '25a00000-0000-7000-8000-00000000c006', 1, true),
    (t, '25a00000-0000-7000-8000-00000000c106', '25a00000-0000-7000-8000-00000000c001', 1, true),
    (t, '25a00000-0000-7000-8000-00000000c107', '25a00000-0000-7000-8000-00000000c003', 1, true),
    (t, '25a00000-0000-7000-8000-00000000c108', '25a00000-0000-7000-8000-00000000c001', 1, true);
  INSERT INTO catalog.item_variant (tenant_id, id, item_id, code, is_default, plu_code) VALUES
    (t, '25a00000-0000-7000-8000-00000000c131', '25a00000-0000-7000-8000-00000000c103', 'MILK', true, NULL),
    (t, '25a00000-0000-7000-8000-00000000c132', '25a00000-0000-7000-8000-00000000c104', 'BEANS', true, NULL),
    (t, '25a00000-0000-7000-8000-00000000c133', '25a00000-0000-7000-8000-00000000c105', 'LATTE', true, NULL),
    (t, '25a00000-0000-7000-8000-00000000c134', '25a00000-0000-7000-8000-00000000c106', 'GIFT', true, NULL),
    (t, '25a00000-0000-7000-8000-00000000c135', '25a00000-0000-7000-8000-00000000c107', 'CHEESE', true, '123'),
    (t, '25a00000-0000-7000-8000-00000000c136', '25a00000-0000-7000-8000-00000000c108', 'TSHIRT', true, NULL);
END $$;

-- ---------- T12 (INV-CAT-01..05, 07, 18..21): یکپارچگی کالا ----------
DO $$
DECLARE t uuid := '25a00000-0000-7000-8000-000000000001';
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  PERFORM public.md_assert((SELECT posting_group_id FROM catalog.v_sku WHERE variant_id = '25a00000-0000-7000-8000-00000000c111')
                           = '25a00000-0000-7000-8000-00000000c041', 'INV-CAT-01 posting group inherited from category in v_sku');
  PERFORM public.md_assert((SELECT moadian_unit_code FROM catalog.v_item_uom_effective WHERE item_id = '25a00000-0000-7000-8000-00000000c101'
                              AND uom_id = '25a00000-0000-7000-8000-00000000c002') = '1624', 'INV-CAT-19 moadian unit via uom');
  PERFORM public.md_assert(catalog.convert_qty('25a00000-0000-7000-8000-00000000c101', 3, '25a00000-0000-7000-8000-00000000c002',
                                               '25a00000-0000-7000-8000-00000000c001') = 72, 'INV-CAT-01 carton -> pieces');
  PERFORM public.md_assert(catalog.convert_qty('25a00000-0000-7000-8000-00000000c104', 250, '25a00000-0000-7000-8000-00000000c004',
                                               '25a00000-0000-7000-8000-00000000c003') = 0.25, 'INV-CAT-01 grams -> kg');
  -- base uom row mismatch (deferred)
  BEGIN
    INSERT INTO catalog.item (tenant_id, id, code, name, item_type, base_uom_id) VALUES
      (t, '25a00000-0000-7000-8000-00000000c1f1', 'BAD-1', 'نادرست', 'stock', '25a00000-0000-7000-8000-00000000c001');
    INSERT INTO catalog.item_uom (tenant_id, item_id, uom_id, factor, is_base) VALUES
      (t, '25a00000-0000-7000-8000-00000000c1f1', '25a00000-0000-7000-8000-00000000c003', 1, true);
    INSERT INTO catalog.item_variant (tenant_id, item_id, code, is_default) VALUES (t, '25a00000-0000-7000-8000-00000000c1f1', 'BAD-1', true);
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'TEST FAILED [INV-CAT-01 base uom mismatch accepted]';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'HK_CATALOG_ITEM_BASE_UOM%' THEN RAISE; END IF;
  END;
  -- item without variant
  BEGIN
    INSERT INTO catalog.item (tenant_id, id, code, name, item_type, base_uom_id) VALUES
      (t, '25a00000-0000-7000-8000-00000000c1f2', 'BAD-2', 'بی‌variant', 'stock', '25a00000-0000-7000-8000-00000000c001');
    INSERT INTO catalog.item_uom (tenant_id, item_id, uom_id, factor, is_base) VALUES
      (t, '25a00000-0000-7000-8000-00000000c1f2', '25a00000-0000-7000-8000-00000000c001', 1, true);
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'TEST FAILED [INV-CAT-02 item without variant accepted]';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'HK_CATALOG_ITEM_NO_VARIANT%' THEN RAISE; END IF;
  END;
  -- default variant code must equal item code
  BEGIN
    INSERT INTO catalog.item (tenant_id, id, code, name, item_type, base_uom_id) VALUES
      (t, '25a00000-0000-7000-8000-00000000c1f3', 'BAD-3', 'کد متفاوت', 'stock', '25a00000-0000-7000-8000-00000000c001');
    INSERT INTO catalog.item_uom (tenant_id, item_id, uom_id, factor, is_base) VALUES
      (t, '25a00000-0000-7000-8000-00000000c1f3', '25a00000-0000-7000-8000-00000000c001', 1, true);
    INSERT INTO catalog.item_variant (tenant_id, item_id, code, is_default) VALUES (t, '25a00000-0000-7000-8000-00000000c1f3', 'OTHER-3', true);
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'TEST FAILED [INV-CAT-02 default variant code accepted]';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'HK_CATALOG_ITEM_DEFAULT_VARIANT%' THEN RAISE; END IF;
  END;
  -- variant missing an axis value
  BEGIN
    INSERT INTO catalog.item_variant (tenant_id, item_id, code, axis1_value_id) VALUES
      (t, '25a00000-0000-7000-8000-00000000c102', 'SH-100-42', '25a00000-0000-7000-8000-00000000c023');
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'TEST FAILED [INV-CAT-03 missing axis value accepted]';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'HK_CATALOG_VARIANT_AXES%' THEN RAISE; END IF;
  END;
  -- value of a different attribute on an axis
  BEGIN
    INSERT INTO catalog.item_variant (tenant_id, item_id, code, axis1_value_id, axis2_value_id) VALUES
      (t, '25a00000-0000-7000-8000-00000000c102', 'SH-100-X', '25a00000-0000-7000-8000-00000000c026', '25a00000-0000-7000-8000-00000000c024');
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'TEST FAILED [INV-CAT-03 wrong attribute value accepted]';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'HK_CATALOG_VARIANT_AXES%' THEN RAISE; END IF;
  END;
  -- default variant on a variant item
  BEGIN
    INSERT INTO catalog.item_variant (tenant_id, item_id, code, is_default) VALUES (t, '25a00000-0000-7000-8000-00000000c102', 'SH-100', true);
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'TEST FAILED [INV-CAT-03 default variant on variant item accepted]';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'HK_CATALOG_VARIANT_AXES%' THEN RAISE; END IF;
  END;
  PERFORM public.md_expect_error('INV-CAT-03 duplicate combination',
    $q$INSERT INTO catalog.item_variant (tenant_id, item_id, code, axis1_value_id, axis2_value_id) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c102','SH-100-40-BLK-2','25a00000-0000-7000-8000-00000000c021','25a00000-0000-7000-8000-00000000c024')$q$, '23505');
  PERFORM public.md_expect_error('INV-CAT-20 duplicate SKU code',
    $q$INSERT INTO catalog.item_variant (tenant_id, item_id, code, axis1_value_id, axis2_value_id) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c102','CABLE-1','25a00000-0000-7000-8000-00000000c023','25a00000-0000-7000-8000-00000000c025')$q$, '23505');
  PERFORM public.md_expect_error('INV-CAT-04 non-axis attribute as axis',
    $q$INSERT INTO catalog.item (tenant_id, code, name, item_type, base_uom_id, has_variants, variant_axis1_id) VALUES ('25a00000-0000-7000-8000-000000000001','AX-1','x','stock','25a00000-0000-7000-8000-00000000c001',true,'25a00000-0000-7000-8000-00000000c013')$q$, 'HK_CATALOG_ATTRIBUTE_NOT_AXIS');
  PERFORM public.md_expect_error('INV-CAT-04 axes without has_variants',
    $q$INSERT INTO catalog.item (tenant_id, code, name, item_type, base_uom_id, has_variants, variant_axis1_id) VALUES ('25a00000-0000-7000-8000-000000000001','AX-2','x','stock','25a00000-0000-7000-8000-00000000c001',false,'25a00000-0000-7000-8000-00000000c011')$q$, '23514');
  PERFORM public.md_expect_error('INV-CAT-04 same axis twice',
    $q$INSERT INTO catalog.item (tenant_id, code, name, item_type, base_uom_id, has_variants, variant_axis1_id, variant_axis2_id) VALUES ('25a00000-0000-7000-8000-000000000001','AX-3','x','stock','25a00000-0000-7000-8000-00000000c001',true,'25a00000-0000-7000-8000-00000000c011','25a00000-0000-7000-8000-00000000c011')$q$, '23514');
  PERFORM public.md_expect_error('INV-CAT-04 axis member must be axis-capable',
    $q$INSERT INTO catalog.attribute_set_member (tenant_id, attribute_set_id, attribute_id, usage, axis_position) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c031','25a00000-0000-7000-8000-00000000c014','variant_axis',3)$q$, 'HK_CATALOG_ATTRIBUTE_NOT_AXIS');
  PERFORM public.md_expect_error('INV-CAT-05 serial on service',
    $q$INSERT INTO catalog.item (tenant_id, code, name, item_type, base_uom_id, track_serial) VALUES ('25a00000-0000-7000-8000-000000000001','SRV-1','نصب','service','25a00000-0000-7000-8000-00000000c001',true)$q$, '23514');
  PERFORM public.md_expect_error('INV-CAT-05 expiry without batch',
    $q$INSERT INTO catalog.item (tenant_id, code, name, item_type, base_uom_id, track_expiry) VALUES ('25a00000-0000-7000-8000-000000000001','EXP-1','x','stock','25a00000-0000-7000-8000-00000000c001',true)$q$, '23514');
  PERFORM public.md_expect_error('INV-CAT-19 sstid 12 digits',
    $q$UPDATE catalog.item SET sstid = '271000013862' WHERE id = '25a00000-0000-7000-8000-00000000c101'$q$, '23514');
  PERFORM public.md_expect_error('INV-CAT-19 sstid without kind',
    $q$UPDATE catalog.item SET sstid_kind = NULL WHERE id = '25a00000-0000-7000-8000-00000000c101'$q$, '23514');
  PERFORM public.md_expect_error('INV-CAT-18 value type mismatch',
    $q$INSERT INTO catalog.item_attribute_value (tenant_id, item_id, attribute_id, value_text) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c101','25a00000-0000-7000-8000-00000000c014','۲۲۰')$q$, 'HK_CATALOG_ATTRIBUTE_VALUE_TYPE');
  PERFORM public.md_expect_error('INV-CAT-18 descriptive value on an axis attribute',
    $q$INSERT INTO catalog.item_attribute_value (tenant_id, item_id, attribute_id, value_id) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c102','25a00000-0000-7000-8000-00000000c011','25a00000-0000-7000-8000-00000000c021')$q$, 'HK_CATALOG_ATTRIBUTE_IS_AXIS');
  PERFORM public.md_expect_error('INV-CAT-01 base row with factor <> 1',
    $q$INSERT INTO catalog.item_uom (tenant_id, item_id, uom_id, factor, is_base) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c108','25a00000-0000-7000-8000-00000000c002',12,true)$q$, '23514');
  PERFORM public.md_expect_error('INV-CAT-21 posting group code immutable',
    $q$UPDATE catalog.item_posting_group SET code = 'GOODS2' WHERE id = '25a00000-0000-7000-8000-00000000c041'$q$, 'HK_CATALOG_POSTING_GROUP_CODE_IMMUTABLE');
  PERFORM public.md_expect_error('INV-CAT-07 category cycle',
    $q$UPDATE catalog.item_category SET parent_id = '25a00000-0000-7000-8000-00000000c052' WHERE id = '25a00000-0000-7000-8000-00000000c051'$q$, 'HK_CATALOG_CATEGORY_CYCLE');
END $$;

-- ---------- T13 (INV-CAT-06): قفل پس از استفاده ----------
DO $$
DECLARE t uuid := '25a00000-0000-7000-8000-000000000001';
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  PERFORM public.md_expect_error('INV-CAT-06 lock on insert',
    $q$INSERT INTO catalog.item (tenant_id, code, name, item_type, base_uom_id, usage_locked_at) VALUES ('25a00000-0000-7000-8000-000000000001','LK-1','x','stock','25a00000-0000-7000-8000-00000000c001',now())$q$, 'HK_CATALOG_ITEM_LOCK_ON_INSERT');
  UPDATE catalog.item SET usage_locked_at = now()
   WHERE id IN ('25a00000-0000-7000-8000-00000000c101','25a00000-0000-7000-8000-00000000c102','25a00000-0000-7000-8000-00000000c108');
  PERFORM public.md_expect_error('INV-CAT-06 base uom frozen',
    $q$UPDATE catalog.item SET base_uom_id = '25a00000-0000-7000-8000-00000000c002' WHERE id = '25a00000-0000-7000-8000-00000000c101'$q$, 'HK_CATALOG_ITEM_LOCKED');
  PERFORM public.md_expect_error('INV-CAT-06 unlock',
    $q$UPDATE catalog.item SET usage_locked_at = NULL WHERE id = '25a00000-0000-7000-8000-00000000c101'$q$, 'HK_CATALOG_ITEM_LOCKED');
  PERFORM public.md_expect_error('INV-CAT-06 tracking frozen',
    $q$UPDATE catalog.item SET track_serial = true WHERE id = '25a00000-0000-7000-8000-00000000c101'$q$, 'HK_CATALOG_ITEM_LOCKED');
  PERFORM public.md_expect_error('INV-CAT-06 factor frozen',
    $q$UPDATE catalog.item_uom SET factor = 20 WHERE item_id = '25a00000-0000-7000-8000-00000000c101' AND uom_id = '25a00000-0000-7000-8000-00000000c002'$q$, 'HK_CATALOG_ITEM_LOCKED');
  PERFORM public.md_expect_error('INV-CAT-06 unit delete',
    $q$DELETE FROM catalog.item_uom WHERE item_id = '25a00000-0000-7000-8000-00000000c101' AND uom_id = '25a00000-0000-7000-8000-00000000c002'$q$, 'HK_CATALOG_ITEM_LOCKED');
  PERFORM public.md_expect_error('INV-CAT-06 variant axis value frozen',
    $q$UPDATE catalog.item_variant SET axis1_value_id = '25a00000-0000-7000-8000-00000000c023' WHERE id = '25a00000-0000-7000-8000-00000000c121'$q$, 'HK_CATALOG_VARIANT_LOCKED');
  PERFORM public.md_expect_error('INV-CAT-06 existing axis frozen',
    $q$UPDATE catalog.item SET variant_axis2_id = NULL WHERE id = '25a00000-0000-7000-8000-00000000c102'$q$, 'HK_CATALOG_ITEM_LOCKED');
  -- مجاز: غیرفعال کردن واحد و نام‌گذاری
  UPDATE catalog.item_uom SET is_active = false WHERE item_id = '25a00000-0000-7000-8000-00000000c101' AND uom_id = '25a00000-0000-7000-8000-00000000c002';
  UPDATE catalog.item_uom SET is_active = true WHERE item_id = '25a00000-0000-7000-8000-00000000c101' AND uom_id = '25a00000-0000-7000-8000-00000000c002';
  -- مجاز: تبدیل کالای سادهٔ استفاده‌شده به variantدار (variant پیش‌فرض محور می‌گیرد)
  UPDATE catalog.item SET has_variants = true, variant_axis1_id = '25a00000-0000-7000-8000-00000000c011'
   WHERE id = '25a00000-0000-7000-8000-00000000c108';
  UPDATE catalog.item_variant SET is_default = false, code = 'TSHIRT-40', axis1_value_id = '25a00000-0000-7000-8000-00000000c021'
   WHERE id = '25a00000-0000-7000-8000-00000000c136';
  INSERT INTO catalog.item_variant (tenant_id, item_id, code, axis1_value_id) VALUES
    (t, '25a00000-0000-7000-8000-00000000c108', 'TSHIRT-41', '25a00000-0000-7000-8000-00000000c022');
END $$;
DO $$
BEGIN
  PERFORM set_config('app.tenant_id', '25a00000-0000-7000-8000-000000000001', true);
  PERFORM public.md_assert((SELECT count(*) FROM catalog.item_variant WHERE item_id = '25a00000-0000-7000-8000-00000000c108') = 2,
                           'INV-CAT-06 simple -> variant conversion after use');
  PERFORM public.md_expect_error('INV-CAT-06 variant -> simple after use',
    $q$UPDATE catalog.item SET has_variants = false, variant_axis1_id = NULL WHERE id = '25a00000-0000-7000-8000-00000000c108'$q$, 'HK_CATALOG_ITEM_LOCKED');
END $$;

-- ---------- T14 (INV-CAT-08..10): بارکد و ترازو ----------
DO $$
DECLARE t uuid := '25a00000-0000-7000-8000-000000000001'; c1 text; c2 text; c3 text; c4 text; r record; v_scale text;
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  INSERT INTO catalog.barcode (tenant_id, item_id, variant_id, uom_id, code, symbology, source, is_primary) VALUES
    (t, '25a00000-0000-7000-8000-00000000c101', '25a00000-0000-7000-8000-00000000c111', '25a00000-0000-7000-8000-00000000c001', '5901234123457', 'ean13', 'manufacturer', true),
    (t, '25a00000-0000-7000-8000-00000000c101', '25a00000-0000-7000-8000-00000000c111', '25a00000-0000-7000-8000-00000000c002', '00012345600012', 'gtin14', 'manufacturer', true);
  PERFORM public.md_assert((SELECT factor FROM catalog.v_barcode_lookup WHERE code = '00012345600012') = 24, 'INV-CAT-08 carton barcode resolves factor 24');
  PERFORM public.md_expect_error('INV-CAT-08 bad EAN check digit',
    $q$INSERT INTO catalog.barcode (tenant_id, item_id, variant_id, uom_id, code, symbology, source) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c101','25a00000-0000-7000-8000-00000000c111','25a00000-0000-7000-8000-00000000c001','5901234123458','ean13','manufacturer')$q$, '23514');
  PERFORM public.md_expect_error('INV-CAT-08 duplicate barcode',
    $q$INSERT INTO catalog.barcode (tenant_id, item_id, variant_id, uom_id, code, symbology, source) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c102','25a00000-0000-7000-8000-00000000c121','25a00000-0000-7000-8000-00000000c005','5901234123457','ean13','manufacturer')$q$, '23505');
  PERFORM public.md_expect_error('INV-CAT-08 variant of another item',
    $q$INSERT INTO catalog.barcode (tenant_id, item_id, variant_id, uom_id, code, symbology, source) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c101','25a00000-0000-7000-8000-00000000c121','25a00000-0000-7000-8000-00000000c001','4006381333931','ean13','manufacturer')$q$, '23503');
  PERFORM public.md_expect_error('INV-CAT-08 unit not allowed for item',
    $q$INSERT INTO catalog.barcode (tenant_id, item_id, variant_id, uom_id, code, symbology, source) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c101','25a00000-0000-7000-8000-00000000c111','25a00000-0000-7000-8000-00000000c003','4006381333931','ean13','manufacturer')$q$, '23503');
  PERFORM public.md_expect_error('INV-CAT-09 internal barcode outside 04',
    $q$INSERT INTO catalog.barcode (tenant_id, item_id, variant_id, uom_id, code, symbology, source) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c101','25a00000-0000-7000-8000-00000000c111','25a00000-0000-7000-8000-00000000c001','4006381333931','ean13','internal')$q$, '23514');
  PERFORM public.md_expect_error('INV-CAT-08 barcode identity immutable',
    $q$UPDATE catalog.barcode SET code = '4006381333931' WHERE code = '5901234123457'$q$, 'HK_CATALOG_BARCODE_IMMUTABLE');

  -- بارکد داخلی: شمارنده، رقم کنترل، پرش از کدی که دستی گرفته شده
  c1 := catalog.allocate_internal_barcode();
  PERFORM public.md_assert(c1 = '0400000000015', 'INV-CAT-09 first internal barcode');
  c2 := catalog.allocate_internal_barcode();
  c3 := '040000000003' || ref.gtin_check_digit('040000000003')::text;
  INSERT INTO catalog.barcode (tenant_id, item_id, variant_id, uom_id, code, symbology, source) VALUES
    (t, '25a00000-0000-7000-8000-00000000c102', '25a00000-0000-7000-8000-00000000c121', '25a00000-0000-7000-8000-00000000c005', c1, 'ean13', 'internal'),
    (t, '25a00000-0000-7000-8000-00000000c102', '25a00000-0000-7000-8000-00000000c122', '25a00000-0000-7000-8000-00000000c005', c2, 'ean13', 'internal'),
    (t, '25a00000-0000-7000-8000-00000000c102', '25a00000-0000-7000-8000-00000000c123', '25a00000-0000-7000-8000-00000000c005', c3, 'ean13', 'legacy');
  c4 := catalog.allocate_internal_barcode();
  PERFORM public.md_assert(c4 = '040000000004' || ref.gtin_check_digit('040000000004')::text AND ref.is_valid_gtin(c4),
                           'INV-CAT-09 allocator skips manually used code');

  -- الگوی ترازو
  INSERT INTO catalog.scale_barcode_pattern (tenant_id, id, code, name, prefix, plu_start, plu_length, value_kind, value_start, value_length, value_decimals, weight_uom_id) VALUES
    (t, '25a00000-0000-7000-8000-00000000c201', 'W21', 'ترازوی پنیر', '21', 3, 5, 'weight', 8, 5, 3, '25a00000-0000-7000-8000-00000000c003');
  v_scale := '210012301250' || ref.gtin_check_digit('210012301250')::text;
  SELECT * INTO r FROM catalog.parse_scale_barcode(v_scale);
  PERFORM public.md_assert(r.plu_code = '123' AND r.value = 1.250 AND r.variant_id = '25a00000-0000-7000-8000-00000000c135',
                           'INV-CAT-10 parse weight barcode');
  PERFORM public.md_assert(NOT EXISTS (SELECT 1 FROM catalog.parse_scale_barcode('2100123012500')), 'INV-CAT-10 bad check digit not parsed');
  PERFORM public.md_expect_error('INV-CAT-10 barcode collides with scale prefix',
    format($q$INSERT INTO catalog.barcode (tenant_id, item_id, variant_id, uom_id, code, symbology, source) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c107','25a00000-0000-7000-8000-00000000c135','25a00000-0000-7000-8000-00000000c003',%L,'ean13','legacy')$q$, v_scale),
    'HK_CATALOG_BARCODE_SCALE_PREFIX');
  INSERT INTO catalog.barcode (tenant_id, item_id, variant_id, uom_id, code, symbology, source) VALUES
    (t, '25a00000-0000-7000-8000-00000000c107', '25a00000-0000-7000-8000-00000000c135', '25a00000-0000-7000-8000-00000000c003',
     '220000000001' || ref.gtin_check_digit('220000000001')::text, 'ean13', 'legacy');
  PERFORM public.md_expect_error('INV-CAT-10 pattern collides with existing barcode',
    $q$INSERT INTO catalog.scale_barcode_pattern (tenant_id, code, name, prefix, plu_start, plu_length, value_kind, value_start, value_length, price_currency, price_amount_unit) VALUES ('25a00000-0000-7000-8000-000000000001','P22','قیمتی','22',3,5,'price',8,5,'IRR','IRT')$q$,
    'HK_CATALOG_SCALE_PREFIX_CONFLICT');
  PERFORM public.md_expect_error('INV-CAT-10 prefix outside 02/20-29 (19)',
    $q$INSERT INTO catalog.scale_barcode_pattern (tenant_id, code, name, prefix, plu_start, plu_length, value_kind, value_start, value_length, weight_uom_id) VALUES ('25a00000-0000-7000-8000-000000000001','P19','x','19',3,5,'weight',8,5,'25a00000-0000-7000-8000-00000000c003')$q$, '23514');
  PERFORM public.md_expect_error('INV-CAT-10 prefix 04 (internal RCN space) rejected',
    $q$INSERT INTO catalog.scale_barcode_pattern (tenant_id, code, name, prefix, plu_start, plu_length, value_kind, value_start, value_length, weight_uom_id) VALUES ('25a00000-0000-7000-8000-000000000001','P04','x','04',3,5,'weight',8,5,'25a00000-0000-7000-8000-00000000c003')$q$, 'HK_CATALOG_SCALE_PREFIX_CONFLICT');
  PERFORM public.md_expect_error('INV-CAT-10 overlapping ranges',
    $q$INSERT INTO catalog.scale_barcode_pattern (tenant_id, code, name, prefix, plu_start, plu_length, value_kind, value_start, value_length, weight_uom_id) VALUES ('25a00000-0000-7000-8000-000000000001','P23','x','23',3,6,'weight',8,5,'25a00000-0000-7000-8000-00000000c003')$q$, '23514');
  PERFORM public.md_expect_error('INV-CAT-10 second active pattern on prefix',
    $q$INSERT INTO catalog.scale_barcode_pattern (tenant_id, code, name, prefix, plu_start, plu_length, value_kind, value_start, value_length, weight_uom_id) VALUES ('25a00000-0000-7000-8000-000000000001','W21B','x','21',3,4,'weight',7,5,'25a00000-0000-7000-8000-00000000c003')$q$, '23505');
  PERFORM public.md_expect_error('INV-CAT-10 price pattern needs explicit amount unit',
    $q$INSERT INTO catalog.scale_barcode_pattern (tenant_id, code, name, prefix, plu_start, plu_length, value_kind, value_start, value_length, price_currency) VALUES ('25a00000-0000-7000-8000-000000000001','P25','x','25',3,5,'price',8,5,'IRR')$q$, '23514');
  PERFORM public.md_expect_error('INV-CAT-10 weight unit must be mass',
    $q$INSERT INTO catalog.scale_barcode_pattern (tenant_id, code, name, prefix, plu_start, plu_length, value_kind, value_start, value_length, weight_uom_id) VALUES ('25a00000-0000-7000-8000-000000000001','W26','x','26',3,5,'weight',8,5,'25a00000-0000-7000-8000-00000000c001')$q$, 'HK_CATALOG_SCALE_WEIGHT_UOM');
END $$;

-- ---------- T15 (INV-CAT-11..16): قیمت ----------
DO $$
DECLARE t uuid := '25a00000-0000-7000-8000-000000000001'; d date;
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  d := catalog.tenant_today(t);
  INSERT INTO catalog.price_list (tenant_id, id, code, name, kind, currency, price_precision, is_default) VALUES
    (t, '25a00000-0000-7000-8000-00000000c301', 'RETAIL', 'خرده‌فروشی', 'sales', 'IRR', 0, true),
    (t, '25a00000-0000-7000-8000-00000000c303', 'BUY', 'خرید', 'purchase', 'IRR', 0, true);
  INSERT INTO catalog.price_list (tenant_id, id, code, name, kind, currency, price_precision, base_price_list_id, base_adjust_percent, rounding_increment, rounding_mode) VALUES
    (t, '25a00000-0000-7000-8000-00000000c302', 'WHOLESALE', 'عمده', 'sales', 'IRR', 0, '25a00000-0000-7000-8000-00000000c301', -7, 1000, 'nearest');
  INSERT INTO catalog.price_list_item (tenant_id, id, price_list_id, item_id, variant_id, uom_id, min_qty, valid_from, price) VALUES
    (t, '25a00000-0000-7000-8000-00000000c311', '25a00000-0000-7000-8000-00000000c301', '25a00000-0000-7000-8000-00000000c101', NULL, '25a00000-0000-7000-8000-00000000c001', 0, d, 50000),
    (t, '25a00000-0000-7000-8000-00000000c312', '25a00000-0000-7000-8000-00000000c301', '25a00000-0000-7000-8000-00000000c101', NULL, '25a00000-0000-7000-8000-00000000c001', 100, d, 45000),
    (t, '25a00000-0000-7000-8000-00000000c313', '25a00000-0000-7000-8000-00000000c301', '25a00000-0000-7000-8000-00000000c101', NULL, '25a00000-0000-7000-8000-00000000c002', 0, d, 1100000),
    (t, '25a00000-0000-7000-8000-00000000c314', '25a00000-0000-7000-8000-00000000c301', '25a00000-0000-7000-8000-00000000c102', NULL, '25a00000-0000-7000-8000-00000000c005', 0, d, 3500000),
    (t, '25a00000-0000-7000-8000-00000000c315', '25a00000-0000-7000-8000-00000000c301', '25a00000-0000-7000-8000-00000000c102', '25a00000-0000-7000-8000-00000000c123', '25a00000-0000-7000-8000-00000000c005', 0, d, 3900000),
    (t, '25a00000-0000-7000-8000-00000000c316', '25a00000-0000-7000-8000-00000000c301', '25a00000-0000-7000-8000-00000000c104', NULL, '25a00000-0000-7000-8000-00000000c003', 0, d, 1200000);
  -- قیمت‌یابی
  PERFORM public.md_assert((SELECT price = 50000 AND via = 'direct' FROM catalog.resolve_price('25a00000-0000-7000-8000-00000000c301','25a00000-0000-7000-8000-00000000c111','25a00000-0000-7000-8000-00000000c001',1,d)), 'INV-CAT-15 direct');
  PERFORM public.md_assert((SELECT price FROM catalog.resolve_price('25a00000-0000-7000-8000-00000000c301','25a00000-0000-7000-8000-00000000c111','25a00000-0000-7000-8000-00000000c001',150,d)) = 45000, 'INV-CAT-15 quantity break');
  PERFORM public.md_assert((SELECT price FROM catalog.resolve_price('25a00000-0000-7000-8000-00000000c301','25a00000-0000-7000-8000-00000000c111','25a00000-0000-7000-8000-00000000c002',1,d)) = 1100000, 'INV-CAT-15 exact unit wins');
  PERFORM public.md_assert((SELECT price FROM catalog.resolve_price('25a00000-0000-7000-8000-00000000c301','25a00000-0000-7000-8000-00000000c111','25a00000-0000-7000-8000-00000000c002',5,d)) = 1100000, 'INV-CAT-15 exact unit beats base-unit break');
  PERFORM public.md_assert((SELECT price FROM catalog.resolve_price('25a00000-0000-7000-8000-00000000c301','25a00000-0000-7000-8000-00000000c121','25a00000-0000-7000-8000-00000000c005',1,d)) = 3500000, 'INV-CAT-15 item-level price for variant');
  PERFORM public.md_assert((SELECT price FROM catalog.resolve_price('25a00000-0000-7000-8000-00000000c301','25a00000-0000-7000-8000-00000000c123','25a00000-0000-7000-8000-00000000c005',1,d)) = 3900000, 'INV-CAT-15 variant-specific price wins');
  PERFORM public.md_assert((SELECT price = 1200 AND via = 'base_uom' FROM catalog.resolve_price('25a00000-0000-7000-8000-00000000c301','25a00000-0000-7000-8000-00000000c132','25a00000-0000-7000-8000-00000000c004',250,d)), 'INV-CAT-15 base unit x factor');
  PERFORM public.md_assert((SELECT price = 47000 AND via = 'derived' FROM catalog.resolve_price('25a00000-0000-7000-8000-00000000c302','25a00000-0000-7000-8000-00000000c111','25a00000-0000-7000-8000-00000000c001',1,d)), 'INV-CAT-15 derived -7% rounded to 1000');
  PERFORM public.md_assert(NOT EXISTS (SELECT 1 FROM catalog.resolve_price('25a00000-0000-7000-8000-00000000c301','25a00000-0000-7000-8000-00000000c111','25a00000-0000-7000-8000-00000000c001',1,d - 1)), 'INV-CAT-15 no price before validity');
  -- فهرست پایهٔ غیرفعال هنوز منبع فهرست مشتق است؛ فهرست درخواستیِ غیرفعال قیمت نمی‌دهد
  UPDATE catalog.price_list SET is_default = false, is_active = false WHERE id = '25a00000-0000-7000-8000-00000000c301';
  PERFORM public.md_assert((SELECT price FROM catalog.resolve_price('25a00000-0000-7000-8000-00000000c302','25a00000-0000-7000-8000-00000000c111','25a00000-0000-7000-8000-00000000c001',1,d)) = 47000, 'INV-CAT-15 inactive base still feeds derived');
  PERFORM public.md_assert(NOT EXISTS (SELECT 1 FROM catalog.resolve_price('25a00000-0000-7000-8000-00000000c301','25a00000-0000-7000-8000-00000000c111','25a00000-0000-7000-8000-00000000c001',1,d)), 'INV-CAT-15 inactive requested list yields nothing');
  UPDATE catalog.price_list SET is_default = true, is_active = true WHERE id = '25a00000-0000-7000-8000-00000000c301';
  -- منفی‌ها
  PERFORM public.md_expect_error('INV-CAT-11 overlapping validity',
    format($q$INSERT INTO catalog.price_list_item (tenant_id, price_list_id, item_id, uom_id, min_qty, valid_from, price) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c301','25a00000-0000-7000-8000-00000000c101','25a00000-0000-7000-8000-00000000c001',0,%L,51000)$q$, d + 10), '23P01');
  PERFORM public.md_expect_error('INV-CAT-12 precision of IRR list',
    format($q$INSERT INTO catalog.price_list_item (tenant_id, price_list_id, item_id, uom_id, min_qty, valid_from, price) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c301','25a00000-0000-7000-8000-00000000c104','25a00000-0000-7000-8000-00000000c004',0,%L,1200.5)$q$, d), 'HK_CATALOG_PRICE_PRECISION');
  PERFORM public.md_expect_error('INV-CAT-13 backdated insert',
    format($q$INSERT INTO catalog.price_list_item (tenant_id, price_list_id, item_id, uom_id, min_qty, valid_from, price) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c303','25a00000-0000-7000-8000-00000000c101','25a00000-0000-7000-8000-00000000c001',0,%L,40000)$q$, d - 3), 'HK_CATALOG_PRICE_BACKDATED');
  PERFORM public.md_expect_error('INV-CAT-14 base list of other kind',
    $q$INSERT INTO catalog.price_list (tenant_id, code, name, kind, currency, price_precision, base_price_list_id, base_adjust_percent) VALUES ('25a00000-0000-7000-8000-000000000001','X1','x','purchase','IRR',0,'25a00000-0000-7000-8000-00000000c301',5)$q$, 'HK_CATALOG_PRICE_LIST_BASE_MISMATCH');
  PERFORM public.md_expect_error('INV-CAT-14 derived cycle',
    $q$UPDATE catalog.price_list SET base_price_list_id = '25a00000-0000-7000-8000-00000000c302', base_adjust_percent = 1 WHERE id = '25a00000-0000-7000-8000-00000000c301'$q$, 'HK_CATALOG_PRICE_LIST_CYCLE');
  PERFORM public.md_expect_error('INV-CAT-14 second default list',
    $q$INSERT INTO catalog.price_list (tenant_id, code, name, kind, currency, price_precision, is_default) VALUES ('25a00000-0000-7000-8000-000000000001','X2','x','sales','IRR',0,true)$q$, '23505');
  -- انتساب
  INSERT INTO catalog.price_list_assignment (tenant_id, price_list_id, party_group_id) VALUES
    (t, '25a00000-0000-7000-8000-00000000c302', '25a00000-0000-7000-8000-00000000a003');
  PERFORM public.md_expect_error('INV-CAT-16 sales list to supplier group',
    $q$INSERT INTO catalog.price_list_assignment (tenant_id, price_list_id, party_group_id) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c301','25a00000-0000-7000-8000-00000000a002')$q$, 'HK_CATALOG_ASSIGNMENT_GROUP_ROLE');
  PERFORM public.md_expect_error('INV-PTY-14 assignment to merged party',
    $q$INSERT INTO catalog.price_list_assignment (tenant_id, price_list_id, party_id) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c301','25a00000-0000-7000-8000-00000000a111')$q$, 'HK_PARTY_MERGED');
END $$;

-- INV-CAT-13: سطر قیمتِ اثرگذار در گذشته
DO $$
DECLARE t uuid := '25a00000-0000-7000-8000-000000000001'; d date;
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  PERFORM set_config('hk.catalog_allow_backdate', 'on', true);       -- فقط در UoW مهاجرت با مجوز catalog.price.backdate
  d := catalog.tenant_today(t);
  INSERT INTO catalog.price_list_item (tenant_id, id, price_list_id, item_id, uom_id, min_qty, valid_from, price) VALUES
    (t, '25a00000-0000-7000-8000-00000000c321', '25a00000-0000-7000-8000-00000000c303', '25a00000-0000-7000-8000-00000000c101',
     '25a00000-0000-7000-8000-00000000c001', 0, d - 30, 40000);
END $$;
DO $$
DECLARE t uuid := '25a00000-0000-7000-8000-000000000001'; d date;
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  d := catalog.tenant_today(t);
  PERFORM public.md_expect_error('INV-CAT-13 change past price',
    $q$UPDATE catalog.price_list_item SET price = 41000 WHERE id = '25a00000-0000-7000-8000-00000000c321'$q$, 'HK_CATALOG_PRICE_PAST_IMMUTABLE');
  PERFORM public.md_expect_error('INV-CAT-13 delete effective entry',
    $q$DELETE FROM catalog.price_list_item WHERE id = '25a00000-0000-7000-8000-00000000c321'$q$, 'HK_CATALOG_PRICE_PAST_IMMUTABLE');
  PERFORM public.md_expect_error('INV-CAT-13 close into the past',
    format($q$UPDATE catalog.price_list_item SET valid_to = %L WHERE id = '25a00000-0000-7000-8000-00000000c321'$q$, d - 5), 'HK_CATALOG_PRICE_PAST_IMMUTABLE');
  PERFORM public.md_expect_error('INV-CAT-13 identity immutable',
    $q$UPDATE catalog.price_list_item SET min_qty = 5 WHERE id = '25a00000-0000-7000-8000-00000000c321'$q$, 'HK_CATALOG_PRICE_IDENTITY_IMMUTABLE');
  -- مجاز: بستن از دیروز و قیمت تازه از امروز
  UPDATE catalog.price_list_item SET valid_to = d - 1 WHERE id = '25a00000-0000-7000-8000-00000000c321';
  INSERT INTO catalog.price_list_item (tenant_id, price_list_id, item_id, uom_id, min_qty, valid_from, price) VALUES
    (t, '25a00000-0000-7000-8000-00000000c303', '25a00000-0000-7000-8000-00000000c101', '25a00000-0000-7000-8000-00000000c001', 0, d, 42000);
  PERFORM public.md_assert((SELECT price FROM catalog.resolve_price('25a00000-0000-7000-8000-00000000c303','25a00000-0000-7000-8000-00000000c111','25a00000-0000-7000-8000-00000000c001',1,d - 2)) = 40000
                       AND (SELECT price FROM catalog.resolve_price('25a00000-0000-7000-8000-00000000c303','25a00000-0000-7000-8000-00000000c111','25a00000-0000-7000-8000-00000000c001',1,d)) = 42000,
                           'INV-CAT-13 history preserved, new price from today');
  -- سطر آینده قابل ویرایش/حذف است
  INSERT INTO catalog.price_list_item (tenant_id, id, price_list_id, item_id, uom_id, min_qty, valid_from, price) VALUES
    (t, '25a00000-0000-7000-8000-00000000c322', '25a00000-0000-7000-8000-00000000c303', '25a00000-0000-7000-8000-00000000c104',
     '25a00000-0000-7000-8000-00000000c003', 0, d + 7, 900000);
  UPDATE catalog.price_list_item SET price = 950000 WHERE id = '25a00000-0000-7000-8000-00000000c322';
  DELETE FROM catalog.price_list_item WHERE id = '25a00000-0000-7000-8000-00000000c322';
END $$;

-- ---------- T16 (INV-CAT-17): BOM ----------
DO $$
DECLARE t uuid := '25a00000-0000-7000-8000-000000000001'; d date;
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  d := catalog.tenant_today(t);
  INSERT INTO catalog.bom (tenant_id, id, item_id, kind, version_no, yield_qty, yield_uom_id) VALUES
    (t, '25a00000-0000-7000-8000-00000000c401', '25a00000-0000-7000-8000-00000000c105', 'recipe', 1, 1, '25a00000-0000-7000-8000-00000000c006');
  INSERT INTO catalog.bom_line (tenant_id, bom_id, line_no, component_item_id, qty, uom_id) VALUES
    (t, '25a00000-0000-7000-8000-00000000c401', 1, '25a00000-0000-7000-8000-00000000c103', 200, '25a00000-0000-7000-8000-00000000c008'),
    (t, '25a00000-0000-7000-8000-00000000c401', 2, '25a00000-0000-7000-8000-00000000c104', 18, '25a00000-0000-7000-8000-00000000c004');
  UPDATE catalog.bom SET status = 'active', valid_from = d, activated_at = now() WHERE id = '25a00000-0000-7000-8000-00000000c401';
  PERFORM public.md_expect_error('INV-CAT-17 recipe for stock item',
    $q$INSERT INTO catalog.bom (tenant_id, item_id, kind, version_no, yield_uom_id) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c103','recipe',1,'25a00000-0000-7000-8000-00000000c007')$q$, 'HK_CATALOG_BOM_KIND');
  PERFORM public.md_expect_error('INV-CAT-17 production for non-stock item',
    $q$INSERT INTO catalog.bom (tenant_id, item_id, kind, version_no, yield_uom_id) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c105','production',1,'25a00000-0000-7000-8000-00000000c006')$q$, 'HK_CATALOG_BOM_KIND');
  PERFORM public.md_expect_error('INV-CAT-17 created active',
    $q$INSERT INTO catalog.bom (tenant_id, item_id, kind, version_no, yield_uom_id, status, valid_from, activated_at) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c105','recipe',9,'25a00000-0000-7000-8000-00000000c006','active',current_date,now())$q$, 'HK_CATALOG_BOM_NOT_DRAFT');
  PERFORM public.md_expect_error('INV-CAT-17 line on active BOM',
    $q$INSERT INTO catalog.bom_line (tenant_id, bom_id, line_no, component_item_id, qty, uom_id) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c401',3,'25a00000-0000-7000-8000-00000000c103',10,'25a00000-0000-7000-8000-00000000c008')$q$, 'HK_CATALOG_BOM_NOT_DRAFT');
  PERFORM public.md_expect_error('INV-CAT-17 edit active BOM',
    $q$UPDATE catalog.bom SET yield_qty = 2 WHERE id = '25a00000-0000-7000-8000-00000000c401'$q$, 'HK_CATALOG_BOM_ACTIVE_IMMUTABLE');
  PERFORM public.md_expect_error('INV-CAT-17 delete active BOM',
    $q$DELETE FROM catalog.bom WHERE id = '25a00000-0000-7000-8000-00000000c401'$q$, 'HK_CATALOG_BOM_NOT_DRAFT');
  -- نسخهٔ ۲: فعال‌سازی هم‌پوشان رد؛ پس از بستن نسخهٔ ۱ مجاز
  INSERT INTO catalog.bom (tenant_id, id, item_id, kind, version_no, yield_uom_id) VALUES
    (t, '25a00000-0000-7000-8000-00000000c402', '25a00000-0000-7000-8000-00000000c105', 'recipe', 2, '25a00000-0000-7000-8000-00000000c006');
  PERFORM public.md_expect_error('INV-CAT-17 activate empty BOM',
    format($q$UPDATE catalog.bom SET status = 'active', valid_from = %L, activated_at = now() WHERE id = '25a00000-0000-7000-8000-00000000c402'$q$, d + 1), 'HK_CATALOG_BOM_EMPTY');
  INSERT INTO catalog.bom_line (tenant_id, bom_id, line_no, component_item_id, qty, uom_id) VALUES
    (t, '25a00000-0000-7000-8000-00000000c402', 1, '25a00000-0000-7000-8000-00000000c103', 220, '25a00000-0000-7000-8000-00000000c008');
  PERFORM public.md_expect_error('INV-CAT-17 overlapping active versions',
    format($q$UPDATE catalog.bom SET status = 'active', valid_from = %L, activated_at = now() WHERE id = '25a00000-0000-7000-8000-00000000c402'$q$, d + 1), '23P01');
  UPDATE catalog.bom SET valid_to = d WHERE id = '25a00000-0000-7000-8000-00000000c401';
  UPDATE catalog.bom SET status = 'active', valid_from = d + 1, activated_at = now() WHERE id = '25a00000-0000-7000-8000-00000000c402';
  UPDATE catalog.bom SET status = 'archived', archived_at = now() WHERE id = '25a00000-0000-7000-8000-00000000c401';
  PERFORM public.md_expect_error('INV-CAT-17 archived is final',
    $q$UPDATE catalog.bom SET status = 'active', archived_at = NULL WHERE id = '25a00000-0000-7000-8000-00000000c401'$q$, 'HK_CATALOG_BOM_TRANSITION');
  -- چرخه: کیت هدیه شامل لاته، و کیت لاته شامل هدیه
  INSERT INTO catalog.bom (tenant_id, id, item_id, kind, version_no, yield_uom_id) VALUES
    (t, '25a00000-0000-7000-8000-00000000c403', '25a00000-0000-7000-8000-00000000c106', 'kit', 1, '25a00000-0000-7000-8000-00000000c001'),
    (t, '25a00000-0000-7000-8000-00000000c404', '25a00000-0000-7000-8000-00000000c105', 'kit', 1, '25a00000-0000-7000-8000-00000000c006');
  INSERT INTO catalog.bom_line (tenant_id, bom_id, line_no, component_item_id, qty, uom_id) VALUES
    (t, '25a00000-0000-7000-8000-00000000c403', 1, '25a00000-0000-7000-8000-00000000c105', 2, '25a00000-0000-7000-8000-00000000c006');
  PERFORM public.md_expect_error('INV-CAT-17 cycle',
    $q$INSERT INTO catalog.bom_line (tenant_id, bom_id, line_no, component_item_id, qty, uom_id) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c404',1,'25a00000-0000-7000-8000-00000000c106',1,'25a00000-0000-7000-8000-00000000c001')$q$, 'HK_CATALOG_BOM_CYCLE');
  PERFORM public.md_expect_error('INV-CAT-17 component variant required',
    $q$INSERT INTO catalog.bom_line (tenant_id, bom_id, line_no, component_item_id, qty, uom_id) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c403',2,'25a00000-0000-7000-8000-00000000c102',1,'25a00000-0000-7000-8000-00000000c005')$q$, 'HK_CATALOG_BOM_COMPONENT_VARIANT');
  DELETE FROM catalog.bom WHERE id = '25a00000-0000-7000-8000-00000000c404';     -- پیش‌نویس حذف‌شدنی است
END $$;

-- ---------- T18 (INV-PTY-23..24, INV-CAT-22..23): سری کد، ویژگی‌های نگاشت حساب، ارث‌بری دسته ----------
-- (پیش از T17 اجرا می‌شود تا شمارش جداسازی مستأجر جدول‌های سری را هم پوشش دهد)
DO $$
DECLARE t uuid := '25a00000-0000-7000-8000-000000000001'; c text; a jsonb;
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  -- INV-PTY-23: سری کد اشخاص
  c := parties.next_party_code();
  PERFORM public.md_assert(c = '00001', 'INV-PTY-23 default series created on demand');
  INSERT INTO parties.party (tenant_id, code, person_type, name) VALUES (t, '00002', 'natural', 'کد دستی');
  PERFORM public.md_assert(parties.next_party_code() = '00003', 'INV-PTY-23 allocator skips manually used code');
  INSERT INTO parties.code_series (tenant_id, role, prefix, pad_width) VALUES (t, 'customer', 'C', 4);
  INSERT INTO parties.code_series (tenant_id, role, group_id, prefix, pad_width, next_value) VALUES
    (t, 'customer', '25a00000-0000-7000-8000-00000000a003', 'W', 3, 998);
  PERFORM public.md_assert(parties.next_party_code('customer') = 'C0001', 'INV-PTY-23 role series');
  PERFORM public.md_assert(parties.next_party_code('customer', '25a00000-0000-7000-8000-00000000a003') = 'W998', 'INV-PTY-23 group series beats role series');
  PERFORM public.md_assert(parties.next_party_code('customer', '25a00000-0000-7000-8000-00000000a003') = 'W999', 'INV-PTY-23 sequential');
  PERFORM public.md_assert(parties.next_party_code('customer', '25a00000-0000-7000-8000-00000000a003') = 'W1000', 'INV-PTY-23 no truncation past pad width');
  PERFORM public.md_assert(parties.next_party_code('supplier') = '00004', 'INV-PTY-23 fallback to default series');
  PERFORM public.md_expect_error('INV-PTY-23 group series with other role',
    $q$INSERT INTO parties.code_series (tenant_id, role, group_id, prefix) VALUES ('25a00000-0000-7000-8000-000000000001','supplier','25a00000-0000-7000-8000-00000000a003','S')$q$, '23503');
  PERFORM public.md_expect_error('INV-PTY-23 group series without role',
    $q$INSERT INTO parties.code_series (tenant_id, group_id, prefix) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a003','S')$q$, '23514');
  PERFORM public.md_expect_error('INV-PTY-23 second default series',
    $q$INSERT INTO parties.code_series (tenant_id, prefix) VALUES ('25a00000-0000-7000-8000-000000000001','D')$q$, '23505');

  -- INV-PTY-24: ویژگی‌های نگاشت حساب شخص
  a := parties.posting_attributes('25a00000-0000-7000-8000-00000000a101', 'customer', '25a00000-0000-7000-8000-0000000000c1');
  PERFORM public.md_assert(a = '{"customer_group":"WHOLESALE","party_person_type":"natural"}'::jsonb, 'INV-PTY-24 company-specific group');
  a := parties.posting_attributes('25a00000-0000-7000-8000-00000000a101', 'customer', '25a00000-0000-7000-8000-0000000000c2');
  PERFORM public.md_assert(a ->> 'customer_group' = 'RETAIL', 'INV-PTY-24 default role row group');
  a := parties.posting_attributes('25a00000-0000-7000-8000-00000000a103', 'customer', NULL);
  PERFORM public.md_assert(a ->> 'customer_group' = 'RETAIL', 'INV-PTY-24 default group of the role when no role row');
  a := parties.posting_attributes('25a00000-0000-7000-8000-00000000a102', 'employee', NULL);
  PERFORM public.md_assert(a = '{"party_person_type":"legal"}'::jsonb, 'INV-PTY-24 no group -> key omitted');
  a := parties.posting_attributes('25a00000-0000-7000-8000-00000000a111', 'customer', NULL);
  PERFORM public.md_assert(a ->> 'customer_group' = 'RETAIL' AND a ->> 'party_person_type' = 'natural', 'INV-PTY-24 merged party resolves to successor');
  PERFORM public.md_expect_error('INV-PTY-24 invalid role',
    $q$SELECT parties.posting_attributes('25a00000-0000-7000-8000-00000000a101','vip',NULL)$q$, 'HK_PARTY_ROLE_INVALID');
  PERFORM public.md_assert((SELECT canonical_party_id = '25a00000-0000-7000-8000-00000000a113' AND code = 'P111'
                              FROM parties.v_party_ledger_identity WHERE party_id = '25a00000-0000-7000-8000-00000000a111'),
                           'INV-PTY-24 ledger identity view');

  -- INV-CAT-22: ارث‌بری گروه ثبت از نزدیک‌ترین نیا و ویژگی‌های نگاشت کالا
  PERFORM public.md_assert((SELECT posting_group_id FROM catalog.v_sku WHERE variant_id = '25a00000-0000-7000-8000-00000000c121')
                           = '25a00000-0000-7000-8000-00000000c041', 'INV-CAT-22 posting group inherited from ancestor category');
  PERFORM public.md_assert((SELECT path_codes = 'ROOT/SHOES' AND depth = 2 FROM catalog.v_category_effective
                             WHERE category_id = '25a00000-0000-7000-8000-00000000c052'), 'INV-CAT-22 category path');
  PERFORM public.md_assert(catalog.posting_attributes('25a00000-0000-7000-8000-00000000c121')
                           = '{"item_posting_group":"GOODS","item_type":"stock","item_category":"SHOES"}'::jsonb, 'INV-CAT-22 item posting attributes');

  -- INV-CAT-23: سری کد کالا
  PERFORM public.md_assert(catalog.next_item_code() = '00001', 'INV-CAT-23 default series created on demand');
  INSERT INTO catalog.code_series (tenant_id, category_id, prefix, pad_width) VALUES
    (t, '25a00000-0000-7000-8000-00000000c052', 'SH', 3),
    (t, '25a00000-0000-7000-8000-00000000c051', 'CABLE-', 1);
  PERFORM public.md_assert(catalog.next_item_code('25a00000-0000-7000-8000-00000000c052') = 'SH001', 'INV-CAT-23 own category series');
  PERFORM public.md_assert(catalog.next_item_code('25a00000-0000-7000-8000-00000000c053') = 'CABLE-2', 'INV-CAT-23 nearest ancestor series; skips used item/SKU code');
  PERFORM public.md_assert(catalog.next_item_code('25a00000-0000-7000-8000-00000000c052') = 'SH002', 'INV-CAT-23 own series beats ancestor');
  PERFORM public.md_expect_error('INV-CAT-23 unknown category',
    $q$SELECT catalog.next_item_code('25b00000-0000-7000-8000-0000000000c1')$q$, 'HK_CATALOG_CATEGORY_NOT_FOUND');
  PERFORM public.md_expect_error('INV-CAT-23 second series for one category',
    $q$INSERT INTO catalog.code_series (tenant_id, category_id, prefix) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c052','X')$q$, '23505');
END $$;

-- ---------- T17 (INV-MD-01..03): جداسازی مستأجر ----------
DO $$
DECLARE n int;
BEGIN
  PERFORM set_config('app.tenant_id', '25b00000-0000-7000-8000-000000000001', true);
  SELECT count(*) INTO n FROM (
    SELECT id FROM parties.party UNION ALL SELECT id FROM parties.party_role UNION ALL SELECT id FROM parties.party_contact
    UNION ALL SELECT id FROM parties.party_address UNION ALL SELECT id FROM parties.party_bank_account
    UNION ALL SELECT id FROM parties.party_merge UNION ALL SELECT id FROM parties.party_hold UNION ALL SELECT id FROM parties.payment_term
    UNION ALL SELECT id FROM catalog.item UNION ALL SELECT id FROM catalog.item_variant UNION ALL SELECT id FROM catalog.barcode
    UNION ALL SELECT id FROM catalog.price_list UNION ALL SELECT id FROM catalog.price_list_item UNION ALL SELECT id FROM catalog.bom
    UNION ALL SELECT id FROM catalog.uom UNION ALL SELECT id FROM catalog.scale_barcode_pattern
    UNION ALL SELECT id FROM parties.code_series UNION ALL SELECT id FROM catalog.code_series) x;
  PERFORM public.md_assert(n = 0, 'INV-MD-01 tenant B sees nothing of tenant A');
  PERFORM public.md_assert((SELECT count(*) FROM parties.v_party_canonical) = 0 AND (SELECT count(*) FROM catalog.v_sku) = 0
                           AND (SELECT count(*) FROM catalog.v_barcode_lookup) = 0 AND (SELECT count(*) FROM parties.v_party_moadian_profile) = 0
                           AND (SELECT count(*) FROM parties.v_party_ledger_identity) = 0 AND (SELECT count(*) FROM catalog.v_category_effective) = 0,
                           'INV-MD-03 views are security_invoker');
  PERFORM public.md_assert(NOT EXISTS (SELECT 1 FROM catalog.resolve_price('25a00000-0000-7000-8000-00000000c301','25a00000-0000-7000-8000-00000000c111','25a00000-0000-7000-8000-00000000c001',1,current_date)),
                           'INV-MD-01 price function respects RLS');
  PERFORM public.md_assert(NOT EXISTS (SELECT 1 FROM catalog.parse_scale_barcode('210012301250' || ref.gtin_check_digit('210012301250')::text)),
                           'INV-MD-01 scale parse respects RLS');
  PERFORM public.md_expect_error('INV-MD-01 insert with foreign tenant_id',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name) VALUES ('25a00000-0000-7000-8000-000000000001','EVIL','natural','x')$q$, '42501');
  PERFORM public.md_expect_error('INV-MD-02 reference to another tenant''s party',
    $q$INSERT INTO parties.party_role (tenant_id, party_id, role) VALUES ('25b00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101','customer')$q$, '23503');
  PERFORM public.md_expect_error('INV-MD-02 barcode for another tenant''s variant',
    $q$INSERT INTO catalog.barcode (tenant_id, item_id, variant_id, uom_id, code, symbology, source) VALUES ('25b00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c101','25a00000-0000-7000-8000-00000000c111','25a00000-0000-7000-8000-00000000c001','4006381333931','ean13','manufacturer')$q$, '23503');
  UPDATE parties.party SET name = 'hacked' WHERE id = '25a00000-0000-7000-8000-00000000a101';
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM public.md_assert(n = 0, 'INV-MD-01 cross-tenant update affects no rows');
  PERFORM public.md_expect_error('INV-MD-01 merge across tenants',
    $q$SELECT parties.merge_parties('25a00000-0000-7000-8000-00000000a101','25a00000-0000-7000-8000-00000000a102','عبور از مرز مستأجر',NULL)$q$, 'HK_PARTY_NOT_FOUND');
  -- همان کد ملی در مستأجر دیگر مجاز است
  INSERT INTO parties.party (tenant_id, code, person_type, name, national_id, national_id_status) VALUES
    ('25b00000-0000-7000-8000-000000000001', 'P101', 'natural', 'علی محمدی', '0013542419', 'valid');
END $$;
DO $$
BEGIN
  PERFORM public.md_expect_error('INV-MD-01 no tenant context: merge', $q$SELECT parties.merge_parties(uuidv7(), uuidv7(), 'بدون مستأجر', NULL)$q$, 'HK_TENANT_CONTEXT_MISSING');
  PERFORM public.md_expect_error('INV-MD-01 no tenant context: barcode allocation', $q$SELECT catalog.allocate_internal_barcode()$q$, 'HK_TENANT_CONTEXT_MISSING');
  PERFORM public.md_expect_error('INV-MD-01 no tenant context: party code', $q$SELECT parties.next_party_code()$q$, 'HK_TENANT_CONTEXT_MISSING');
  PERFORM public.md_expect_error('INV-MD-01 no tenant context: item code', $q$SELECT catalog.next_item_code()$q$, 'HK_TENANT_CONTEXT_MISSING');
  PERFORM public.md_assert((SELECT count(*) FROM parties.party) = 0, 'INV-MD-01 no tenant context sees nothing');
END $$;

-- =====================================================================
-- بخش ۳: نقش فقط‌خواندنی — T19 (INV-MD-04)
-- =====================================================================
RESET ROLE;
SET ROLE hk_readonly;
DO $$
BEGIN
  PERFORM set_config('app.tenant_id', '25a00000-0000-7000-8000-000000000001', true);
  PERFORM public.md_assert((SELECT count(*) FROM parties.party) > 5 AND (SELECT count(*) FROM catalog.item) > 5, 'INV-MD-04 readonly can read');
  PERFORM public.md_expect_error('INV-MD-04 readonly cannot write',
    $q$INSERT INTO catalog.brand (tenant_id, code, name) VALUES ('25a00000-0000-7000-8000-000000000001','B1','برند')$q$, '42501');
END $$;
RESET ROLE;

\echo 'ALL 25_masterdata TESTS PASSED'
