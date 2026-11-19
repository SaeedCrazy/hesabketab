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

-- انتظار دقیق (R-QUALITY، RV-MD-07): p_expect یکی از این‌هاست —
--   * پیشوند پیام «HK_…» (کد خطای همان بررسی)،
--   * نام قید یا ایندکس یکتا (حروف کوچک؛ با CONSTRAINT_NAME خطا مقایسه می‌شود، نه فقط SQLSTATE)،
--   * SQLSTATE پنج‌نویسه‌ای فقط برای خطای دسترسی (42501) که قید ندارد.
CREATE OR REPLACE FUNCTION public.md_expect_error(p_label text, p_sql text, p_expect text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_state text; v_msg text; v_con text;
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_con = CONSTRAINT_NAME;
    IF p_expect ~ '^[a-z][a-z0-9_]*$' THEN
      IF v_con = p_expect THEN RETURN; END IF;
    ELSIF p_expect ~ '^[0-9A-Z]{5}$' THEN
      IF v_state = p_expect THEN RETURN; END IF;
    ELSIF v_msg LIKE p_expect || '%' THEN
      RETURN;
    END IF;
    RAISE EXCEPTION 'TEST FAILED [%]: expected %, got % % (constraint %)', p_label, p_expect, v_state, v_msg, coalesce(v_con, '-');
  END;
  RAISE EXCEPTION 'TEST FAILED [%]: statement succeeded but % was expected', p_label, p_expect;
END $$;
CREATE OR REPLACE FUNCTION public.md_assert(p_cond boolean, p_label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond IS NOT TRUE THEN RAISE EXCEPTION 'TEST FAILED [%]', p_label; END IF;
END $$;
-- RV-MD-19: کلیدهای posting_attributes باید همان دستور شرط ledger باشند ('attr:<name>' با مقدار رشته). اگر 20_ledger
-- اعمال شده، خود ledger.valid_conditions هم سنجیده می‌شود.
CREATE OR REPLACE FUNCTION public.md_attr_keys_ok(p jsonb) RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
DECLARE v boolean;
BEGIN
  IF jsonb_typeof(p) <> 'object' OR EXISTS (SELECT 1 FROM jsonb_each(p) e
       WHERE e.key !~ '^attr:[a-z][a-z0-9_.]{1,60}$' OR jsonb_typeof(e.value) <> 'string') THEN
    RETURN false;
  END IF;
  IF to_regprocedure('ledger.valid_conditions(jsonb)') IS NOT NULL THEN
    EXECUTE 'SELECT ledger.valid_conditions($1)' INTO v USING p;
    RETURN v;
  END IF;
  RETURN true;
END $$;
GRANT EXECUTE ON FUNCTION public.md_expect_error(text, text, text), public.md_assert(boolean, text),
                          public.md_attr_keys_ok(jsonb) TO hk_app, hk_readonly;
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
       VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a011',3,1,'document_date',5,2,10)$q$, 'payment_term_line_check1');
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
       VALUES ('25a00000-0000-7000-8000-000000000001','X1','natural','x','0013542418','valid')$q$, 'party_national_id_valid');
  PERFORM public.md_expect_error('INV-PTY-02 override of a valid code',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, national_id, national_id_status, national_id_override_reason, national_id_override_at)
       VALUES ('25a00000-0000-7000-8000-000000000001','X2','natural','x','0067749828','override','بدون دلیل واقعی',now())$q$, 'party_national_id_valid');
  PERFORM public.md_expect_error('INV-PTY-02 override without reason',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, national_id, national_id_status, national_id_override_at)
       VALUES ('25a00000-0000-7000-8000-000000000001','X3','natural','x','0013542417','override',now())$q$, 'party_national_id_override');
  PERFORM public.md_expect_error('INV-PTY-02 override of all-same digits',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, national_id, national_id_status, national_id_override_reason, national_id_override_at)
       VALUES ('25a00000-0000-7000-8000-000000000001','X4','natural','x','1111111111','override','دلیل طولانی کافی',now())$q$, 'party_national_id_valid');
  PERFORM public.md_expect_error('INV-PTY-02 override fields on valid',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, national_id, national_id_status, national_id_override_reason)
       VALUES ('25a00000-0000-7000-8000-000000000001','X5','natural','x','0499370899','valid','دلیل اضافی')$q$, 'party_national_id_override');
  PERFORM public.md_expect_error('INV-PTY-01 legal id with 10 digits',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, national_id, national_id_status)
       VALUES ('25a00000-0000-7000-8000-000000000001','X6','legal','x','1400377899','valid')$q$, 'party_national_id_valid');
  PERFORM public.md_expect_error('INV-PTY-01 civil partnership marked valid',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, national_id, national_id_status)
       VALUES ('25a00000-0000-7000-8000-000000000001','X7','civil_partnership','x','12345678902','valid')$q$, 'party_national_id_valid');
  PERFORM public.md_expect_error('INV-PTY-01 foreign legal with national id',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, national_id, national_id_status)
       VALUES ('25a00000-0000-7000-8000-000000000001','X8','foreign_legal','x','123456789013','format_only')$q$, 'party_national_id_valid');
  PERFORM public.md_expect_error('INV-PTY-01 national id without status',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, national_id)
       VALUES ('25a00000-0000-7000-8000-000000000001','X9','natural','x','0499370899')$q$, 'party_national_id_presence');
  PERFORM public.md_expect_error('INV-PTY-03 duplicate national id',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, national_id, national_id_status)
       VALUES ('25a00000-0000-7000-8000-000000000001','X10','natural','دیگری','0013542419','valid')$q$, 'party_national_id_uq');
  PERFORM public.md_expect_error('INV-PTY-04 economic code 12 digits',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, economic_code)
       VALUES ('25a00000-0000-7000-8000-000000000001','X11','legal','x','123456789012')$q$, 'party_economic_code_check');
  PERFORM public.md_expect_error('INV-PTY-05 natural with registration no',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, registration_no)
       VALUES ('25a00000-0000-7000-8000-000000000001','X12','natural','x','123')$q$, 'party_legal_fields');
  PERFORM public.md_expect_error('INV-PTY-05 legal with first name',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, first_name)
       VALUES ('25a00000-0000-7000-8000-000000000001','X13','legal','x','علی')$q$, 'party_natural_fields');
  PERFORM public.md_expect_error('INV-PTY-05 birth certificate on foreign natural',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, birth_cert_issue_place) VALUES ('25a00000-0000-7000-8000-000000000001','X17','foreign_natural','x','تهران')$q$, 'party_birth_cert_iranian');
  PERFORM public.md_expect_error('INV-PTY-05 birth certificate issued before birth',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, birth_date, birth_cert_issue_date) VALUES ('25a00000-0000-7000-8000-000000000001','X18','natural','x','1990-01-01','1989-12-31')$q$, 'party_birth_cert_dates');
  PERFORM public.md_expect_error('INV-PTY-05 anonymous with id',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, is_anonymous, national_id, national_id_status)
       VALUES ('25a00000-0000-7000-8000-000000000001','X14','natural','x',true,'0499370899','valid')$q$, 'party_anonymous');
  PERFORM public.md_expect_error('INV-PTY-14 insert as merged',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, status, merged_into_id, merged_at)
       VALUES ('25a00000-0000-7000-8000-000000000001','X15','natural','x','merged','25a00000-0000-7000-8000-00000000a101',now())$q$, 'HK_PARTY_MERGED_ONLY_VIA_MERGE');
  PERFORM public.md_expect_error('INV-MD-05 unnormalized name (Arabic yeh)',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name) VALUES ('25a00000-0000-7000-8000-000000000001','X16','natural','علي')$q$, 'party_name_check');
  PERFORM public.md_expect_error('INV-MD-05 duplicate party code',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name) VALUES ('25a00000-0000-7000-8000-000000000001','P101','natural','x')$q$, 'party_tenant_id_code_key');
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
       ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a103','customer','25a00000-0000-7000-8000-00000000a002')$q$, 'party_role_tenant_id_group_id_role_fkey');
  PERFORM public.md_expect_error('INV-PTY-07 duplicate role/company',
    $q$INSERT INTO parties.party_role (tenant_id, party_id, role) VALUES
       ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101','supplier')$q$, 'party_role_tenant_id_party_id_role_company_id_key');
  PERFORM public.md_expect_error('INV-PTY-07 role for a company outside party scope',
    $q$INSERT INTO parties.party_role (tenant_id, party_id, role, company_id) VALUES
       ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a108','supplier','25a00000-0000-7000-8000-0000000000c2')$q$, 'HK_PARTY_ROLE_COMPANY_SCOPE');
  PERFORM public.md_expect_error('INV-PTY-07 anonymous as supplier',
    $q$INSERT INTO parties.party_role (tenant_id, party_id, role) VALUES
       ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a107','supplier')$q$, 'HK_PARTY_ANONYMOUS_ROLE');
  PERFORM public.md_expect_error('INV-PTY-08 credit limit without currency',
    $q$INSERT INTO parties.party_role (tenant_id, party_id, role, credit_limit) VALUES
       ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a103','customer',1000)$q$, 'party_role_credit_pair');
  PERFORM public.md_expect_error('INV-PTY-08 block without limit',
    $q$INSERT INTO parties.party_role (tenant_id, party_id, role, credit_control) VALUES
       ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a103','customer','block')$q$, 'party_role_credit_control');
  PERFORM public.md_expect_error('INV-PTY-08 credit on employee role',
    $q$INSERT INTO parties.party_role (tenant_id, party_id, role, credit_limit, credit_currency) VALUES
       ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a103','employee',1000,'IRR')$q$, 'party_role_credit_roles');
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
    $q$INSERT INTO parties.party_contact (tenant_id, party_id, kind, value) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101','mobile','9121234567')$q$, 'contact_mobile_format');
  PERFORM public.md_expect_error('INV-PTY-10 +98 must be normalized',
    $q$INSERT INTO parties.party_contact (tenant_id, party_id, kind, value) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101','mobile','+989121234560')$q$, 'contact_mobile_format');
  PERFORM public.md_expect_error('INV-PTY-10 email upper case',
    $q$INSERT INTO parties.party_contact (tenant_id, party_id, kind, value) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101','email','Ali@Example.ir')$q$, 'contact_email_format');
  PERFORM public.md_expect_error('INV-PTY-10 second primary mobile',
    $q$INSERT INTO parties.party_contact (tenant_id, party_id, kind, value, is_primary) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101','mobile','09121234568',true)$q$, 'party_contact_one_primary');

  INSERT INTO parties.party_address (tenant_id, party_id, is_primary, is_billing, province_code, city_code, address_line, postal_code, moadian_branch_code) VALUES
    (t, '25a00000-0000-7000-8000-00000000a102', true, true, 'T23', 'T2301', 'خیابان ولیعصر، کوچهٔ یکم', '1193653471', '0001');
  INSERT INTO parties.party_address (tenant_id, party_id, country_code, address_line, postal_code) VALUES
    (t, '25a00000-0000-7000-8000-00000000a106', 'TR', 'Istiklal Cd. 1, Istanbul', '34430');
  PERFORM public.md_expect_error('INV-PTY-11 city outside province',
    $q$INSERT INTO parties.party_address (tenant_id, party_id, province_code, city_code, address_line) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a102','T04','T2301','نشانی')$q$, 'party_address_province_code_city_code_fkey');
  PERFORM public.md_expect_error('INV-PTY-11 postal 9 digits',
    $q$INSERT INTO parties.party_address (tenant_id, party_id, address_line, postal_code) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a102','نشانی','119365347')$q$, 'address_postal_iran');
  PERFORM public.md_expect_error('INV-PTY-11 foreign address with Iranian province',
    $q$INSERT INTO parties.party_address (tenant_id, party_id, country_code, province_code, address_line) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a106','TR','T23','x street')$q$, 'address_iran_divisions');

  INSERT INTO parties.party_bank_account (tenant_id, id, party_id, sheba, holder_name, is_primary) VALUES
    (t, '25a00000-0000-7000-8000-00000000a301', '25a00000-0000-7000-8000-00000000a102', 'IR820540102680020817909002', 'شرکت نمونه', true);
  PERFORM public.md_assert((SELECT bank_code FROM parties.party_bank_account WHERE id = '25a00000-0000-7000-8000-00000000a301') = 'parsian',
                           'INV-PTY-12 bank derived from SHEBA');
  INSERT INTO parties.party_bank_account (tenant_id, id, party_id, card_number) VALUES
    (t, '25a00000-0000-7000-8000-00000000a302', '25a00000-0000-7000-8000-00000000a101', '6037701689095443');
  PERFORM public.md_assert((SELECT bank_code FROM parties.party_bank_account WHERE id = '25a00000-0000-7000-8000-00000000a302') = 'keshavarzi',
                           'INV-PTY-12 bank from card BIN (display only)');
  PERFORM public.md_expect_error('INV-PTY-12 invalid SHEBA',
    $q$INSERT INTO parties.party_bank_account (tenant_id, party_id, sheba) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101','IR820540102680020817909003')$q$, 'party_bank_account_sheba_check');
  PERFORM public.md_expect_error('INV-PTY-12 invalid card',
    $q$INSERT INTO parties.party_bank_account (tenant_id, party_id, card_number) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101','6037701689095444')$q$, 'party_bank_account_card_number_check');
  PERFORM public.md_expect_error('INV-PTY-12 SHEBA/bank mismatch',
    $q$INSERT INTO parties.party_bank_account (tenant_id, party_id, sheba, bank_code) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101','IR550570022080013447370101','melli')$q$, 'HK_PARTY_BANK_MISMATCH');
  PERFORM public.md_expect_error('INV-PTY-12 no identifier',
    $q$INSERT INTO parties.party_bank_account (tenant_id, party_id, branch_name) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101','شعبه')$q$, 'bank_account_identifier');
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
    $q$INSERT INTO parties.party_hold (tenant_id, party_id, scope, source, reason) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a103','sales','manual','تکراری')$q$, 'party_hold_one_active');
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
    $q$INSERT INTO parties.party_legacy_code (tenant_id, party_id, source_system, source_scope, legacy_code) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a102','holoo','Holoo1','10001')$q$, 'party_legacy_code_tenant_id_source_system_source_scope_lega_key');
  PERFORM public.md_expect_error('INV-PTY-18 legacy code immutable',
    $q$UPDATE parties.party_legacy_code SET legacy_code = '10002' WHERE id = '25a00000-0000-7000-8000-00000000a501'$q$, 'HK_PARTY_LEGACY_CODE_IMMUTABLE');

  INSERT INTO parties.party_taxpayer_inquiry (tenant_id, party_id, economic_code, outcome, taxpayer_name, adapter) VALUES
    (t, '25a00000-0000-7000-8000-00000000a102', '14003778990', 'found', 'شرکت نمونه', 'mock');
  PERFORM public.md_expect_error('INV-PTY-19 inquiry update',
    $q$UPDATE parties.party_taxpayer_inquiry SET outcome = 'error'$q$, '42501');
  PERFORM public.md_expect_error('INV-PTY-20 dismissal order',
    $q$INSERT INTO parties.duplicate_dismissal (tenant_id, party_a_id, party_b_id) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a102','25a00000-0000-7000-8000-00000000a101')$q$, 'duplicate_dismissal_check');
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
  -- D-M25/RV-MD-20: شخص حذف فیزیکی ندارد (hk_app بدون DELETE)؛ نگهبان ردیف ادغام‌شده برای نقش‌های دیگر در T10c
  PERFORM public.md_expect_error('INV-PTY-14 delete merged party',
    $q$DELETE FROM parties.party WHERE id = '25a00000-0000-7000-8000-00000000a111'$q$, '42501');
  PERFORM public.md_expect_error('D-M25 no physical delete of a party by the app role',
    $q$DELETE FROM parties.party WHERE id = '25a00000-0000-7000-8000-00000000a113'$q$, '42501');
  PERFORM public.md_expect_error('INV-PTY-16 merge already merged',
    $q$SELECT parties.merge_parties('25a00000-0000-7000-8000-00000000a113','25a00000-0000-7000-8000-00000000a111','دوباره ادغام',NULL)$q$, 'HK_PARTY_ALREADY_MERGED');
  PERFORM public.md_expect_error('INV-PTY-17 merge record immutable',
    $q$UPDATE parties.party_merge SET reason = 'x' WHERE true$q$, '42501');
  -- شناسهٔ ملی بازنده دیگر یکتایی را اشغال نمی‌کند؛ ولی شخص فعال تازه با همان شناسه رد می‌شود
  PERFORM public.md_expect_error('INV-PTY-03 duplicate of adopted id',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, national_id, national_id_status) VALUES ('25a00000-0000-7000-8000-000000000001','X20','natural','x','0067749828','valid')$q$, 'party_national_id_uq');

  -- فشرده‌سازی مسیر: ادغام P110 در P113 ← P111 مستقیم به P113
  PERFORM parties.merge_parties('25a00000-0000-7000-8000-00000000a113', '25a00000-0000-7000-8000-00000000a110', 'ادغام دوم برای آزمون زنجیره', NULL);
  PERFORM public.md_assert((SELECT merged_into_id FROM parties.party WHERE id = '25a00000-0000-7000-8000-00000000a111')
                           = '25a00000-0000-7000-8000-00000000a113', 'INV-PTY-15 path compression');
  PERFORM public.md_assert(NOT EXISTS (SELECT 1 FROM parties.party c JOIN parties.party w ON w.tenant_id = c.tenant_id AND w.id = c.merged_into_id
                                        WHERE w.status = 'merged'), 'INV-PTY-15 no merge chains');
  PERFORM public.md_assert((SELECT national_id FROM parties.party WHERE id = '25a00000-0000-7000-8000-00000000a113') = '0067749828',
                           'INV-PTY-16 identity travels along the chain');
END $$;

-- ---------- T10b (RV-MD-02/03/06/11/14/21، INV-PTY-07/13..17/24): بازبینی ادغام، پس‌شرط‌ها و محدودهٔ شرکت ----------
DO $$
DECLARE t uuid := '25a00000-0000-7000-8000-000000000001'; v_merge uuid; a jsonb; r record;
  W uuid := '25a00000-0000-7000-8000-00000000a601'; L uuid := '25a00000-0000-7000-8000-00000000a602';
  X uuid := '25a00000-0000-7000-8000-00000000a603'; L2 uuid := '25a00000-0000-7000-8000-00000000a604';
  L3 uuid := '25a00000-0000-7000-8000-00000000a605'; S uuid := '25a00000-0000-7000-8000-00000000a606';
  G uuid := '25a00000-0000-7000-8000-00000000a607';
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  INSERT INTO parties.party (tenant_id, id, code, person_type, name) VALUES
    (t, W, 'M601', 'natural', 'وحید شاکری'), (t, L, 'M602', 'natural', 'وحید شاکری دوم'), (t, X, 'M603', 'natural', 'شخص بی‌ربط'),
    (t, L2, 'M604', 'natural', 'بازندهٔ ناقص'), (t, L3, 'M605', 'natural', 'سابقهٔ ساختگی'), (t, S, 'M606', 'legal', 'تأمین‌کنندهٔ دوشرکتی'),
    (t, G, 'M607', 'legal', 'همکار عمده');
  -- بازنده: توقیف قضایی (برنده ندارد) و توقیف دستی خرید (برنده هم دارد)؛ نقش مشتری که بازاریابش خودِ برنده است
  INSERT INTO parties.party_hold (tenant_id, party_id, scope, source, reason) VALUES
    (t, L, 'sales', 'legal', 'دستور قضایی شمارهٔ ۱۲'), (t, L, 'purchase', 'manual', 'چک برگشتی'), (t, W, 'purchase', 'manual', 'چک برگشتی برنده');
  INSERT INTO parties.party_role (tenant_id, party_id, role, default_agent_party_id) VALUES (t, L, 'customer', W);
  INSERT INTO parties.party_contact (tenant_id, party_id, kind, value) VALUES
    (t, W, 'email', 'shakeri@example.ir'), (t, L, 'email', 'shakeri@example.ir'), (t, L, 'mobile', '09125550502');

  v_merge := parties.merge_parties(W, L, 'یک شخص با دو کارت', NULL);
  -- RV-MD-02: توقیف فعال گم نمی‌شود و ادغام با توقیف بازنده متوقف نمی‌شود
  PERFORM public.md_assert((SELECT count(*) FROM parties.party_hold WHERE party_id = W AND released_at IS NULL
                               AND scope = 'sales' AND source = 'legal' AND reason = 'دستور قضایی شمارهٔ ۱۲') = 1,
                           'RV-MD-02 loser legal hold re-placed on the winner');
  PERFORM public.md_assert((SELECT count(*) FROM parties.party_hold WHERE party_id = W AND released_at IS NULL
                               AND scope = 'purchase' AND source = 'manual') = 1,
                           'RV-MD-02 equivalent hold not duplicated on the winner');
  PERFORM public.md_assert((SELECT count(*) FROM parties.party_hold WHERE party_id = L AND released_at IS NULL) = 0
                           AND (SELECT bool_and(release_note LIKE 'آزاد در ادغام%') FROM parties.party_hold WHERE party_id = L),
                           'RV-MD-02 loser holds released with a merge note (history kept)');
  PERFORM public.md_assert((SELECT sales_hold AND purchase_hold FROM parties.v_party_hold_state WHERE party_id = W),
                           'RV-MD-02 winner hold state covers the loser holds');
  -- RV-MD-21: بازاریابِ برابر با برنده پاک می‌شود، نه خطای خام CHECK
  SELECT * INTO r FROM parties.party_role WHERE party_id = W AND role = 'customer';
  PERFORM public.md_assert(r.id IS NOT NULL AND r.default_agent_party_id IS NULL, 'RV-MD-21 moved role drops the winner as its own agent');
  PERFORM public.md_assert((SELECT (moved ->> 'party_hold')::int = 1 AND (moved ->> 'party_role_agent_cleared')::int = 1
                              AND (moved ->> 'party_contact')::int = 1 FROM parties.party_merge WHERE id = v_merge),
                           'INV-PTY-17 merge record counts holds, cleared agents and contacts');
  -- ردیف کهنهٔ بازنده (ایمیل تکراری غیرفعال‌شده): بازنشسته می‌ماند، زنده نمی‌شود (INV-PTY-14)
  PERFORM public.md_expect_error('INV-PTY-14 stale child of a merged party cannot be reactivated',
    format($q$UPDATE parties.party_contact SET is_active = true WHERE party_id = %L AND kind = 'email'$q$, L), 'HK_PARTY_MERGED');
  UPDATE parties.party_contact SET label = 'قدیمی' WHERE party_id = L AND kind = 'email';
  PERFORM public.md_assert((SELECT label = 'قدیمی' AND NOT is_active FROM parties.party_contact WHERE party_id = L AND kind = 'email'),
                           'INV-PTY-14 retired child of a merged party stays editable while inactive');
  -- RV-MD-06: ردیف ادغام‌شده به شخص بی‌ربط نشانه نمی‌رود؛ فقط فشرده‌سازی مسیر
  PERFORM public.md_expect_error('RV-MD-06 repoint merged party to an unrelated party',
    format($q$UPDATE parties.party SET merged_into_id = %L WHERE id = %L$q$, X, L), 'HK_PARTY_MERGE_REPOINT');
  PERFORM public.md_assert((SELECT canonical_party_id FROM parties.v_party_canonical WHERE party_id = L) = W,
                           'RV-MD-06 canonical successor unchanged');

  -- RV-MD-11: «merged» بدون ادغام واقعی — GUC قدیمی دیگر کاری نمی‌کند؛ پس‌شرط‌ها در پایگاه داده
  INSERT INTO parties.party_contact (tenant_id, party_id, kind, value) VALUES (t, L2, 'mobile', '09125550604');
  INSERT INTO parties.party_hold (tenant_id, party_id, scope, source, reason) VALUES (t, L2, 'payment', 'compliance', 'استعلام');
  PERFORM set_config('hk.parties_merge', L2::text, true);
  PERFORM public.md_expect_error('RV-MD-11 status merged via GUC without a merge record',
    format($q$UPDATE parties.party SET status = 'merged', merged_into_id = %L, merged_at = now() WHERE id = %L$q$, W, L2),
    'HK_PARTY_MERGED_ONLY_VIA_MERGE');
  PERFORM set_config('hk.parties_merge', '', true);
  BEGIN
    INSERT INTO parties.party_merge (tenant_id, winner_party_id, loser_party_id, reason, loser_snapshot, winner_before, moved)
    VALUES (t, W, L2, 'سابقهٔ ساختگی برای دور زدن', '{}', '{}', '{}');
    UPDATE parties.party SET status = 'merged', merged_into_id = W, merged_at = now() WHERE id = L2;
    RAISE EXCEPTION 'TEST FAILED [RV-MD-11 incomplete merge accepted]';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'HK_PARTY_MERGE_INCOMPLETE: loser % still has live party_contact rows%' THEN RAISE; END IF;
  END;
  BEGIN
    UPDATE parties.party_contact SET is_active = false WHERE party_id = L2;
    INSERT INTO parties.party_merge (tenant_id, winner_party_id, loser_party_id, reason, loser_snapshot, winner_before, moved)
    VALUES (t, W, L2, 'سابقهٔ ساختگی برای دور زدن', '{}', '{}', '{}');
    UPDATE parties.party SET status = 'merged', merged_into_id = W, merged_at = now() WHERE id = L2;
    RAISE EXCEPTION 'TEST FAILED [RV-MD-11 merge with an active hold left on the loser accepted]';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'HK_PARTY_MERGE_INCOMPLETE: loser % still has live party_hold rows%' THEN RAISE; END IF;
  END;
  BEGIN
    INSERT INTO parties.party_merge (tenant_id, winner_party_id, loser_party_id, reason, loser_snapshot, winner_before, moved)
    VALUES (t, W, L3, 'سابقهٔ بدون ادغام', '{}', '{}', '{}');
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'TEST FAILED [INV-PTY-17 orphan merge record accepted]';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'HK_PARTY_MERGE_RECORD_ORPHAN%' THEN RAISE; END IF;
  END;
  PERFORM public.md_assert((SELECT status FROM parties.party WHERE id = L2) = 'active'
                           AND NOT EXISTS (SELECT 1 FROM parties.party_merge WHERE loser_party_id IN (L2, L3)),
                           'RV-MD-11 no partial merge persisted');

  -- RV-MD-14: تنگ کردن محدودهٔ شرکت شخصی که نقش شرکت دیگر دارد
  INSERT INTO parties.party_role (tenant_id, party_id, role, company_id) VALUES (t, S, 'supplier', '25a00000-0000-7000-8000-0000000000c2');
  PERFORM public.md_expect_error('RV-MD-14 narrowing a party below its company role rows',
    format($q$UPDATE parties.party SET company_id = '25a00000-0000-7000-8000-0000000000c1' WHERE id = %L$q$, S), 'HK_PARTY_ROLE_COMPANY_SCOPE');
  UPDATE parties.party SET company_id = '25a00000-0000-7000-8000-0000000000c2' WHERE id = S;
  UPDATE parties.party SET company_id = NULL WHERE id = S;

  -- RV-MD-03: ردیف شرکت بدون گروه (فقط سقف اعتبار) گروه ردیف پیش‌فرض را می‌گیرد
  INSERT INTO parties.party_role (tenant_id, party_id, role, group_id) VALUES (t, G, 'customer', '25a00000-0000-7000-8000-00000000a003');
  INSERT INTO parties.party_role (tenant_id, party_id, role, company_id, credit_limit, credit_currency, credit_control) VALUES
    (t, G, 'customer', '25a00000-0000-7000-8000-0000000000c2', 100000000, 'IRR', 'warn');
  a := parties.posting_attributes(G, 'customer', '25a00000-0000-7000-8000-0000000000c2');
  PERFORM public.md_assert(a ->> 'attr:customer_group' = 'WHOLESALE', 'RV-MD-03 company row without group inherits the default-row group');
  PERFORM public.md_assert((SELECT group_id = '25a00000-0000-7000-8000-00000000a003' AND credit_limit = 100000000 AND credit_control = 'warn'
                              FROM parties.role_settings(G, 'customer', '25a00000-0000-7000-8000-0000000000c2')),
                           'RV-MD-03 role_settings: credit from the company row, group inherited');
  PERFORM public.md_assert((SELECT credit_limit IS NULL AND group_id = '25a00000-0000-7000-8000-00000000a003'
                              FROM parties.role_settings(G, 'customer', '25a00000-0000-7000-8000-0000000000c1')),
                           'RV-MD-03 role_settings falls back to the default row for another company');
END $$;

-- T10c: نگهبان‌ها برای نقش‌های غیر hk_app و مسیر درون‌ریزی (replica) — postgres
RESET ROLE;
DO $$
BEGIN
  PERFORM set_config('app.tenant_id', '25a00000-0000-7000-8000-000000000001', true);
  -- trg_party_guard: ردیف ادغام‌شده برای هیچ نقشی حذف نمی‌شود
  PERFORM public.md_expect_error('INV-PTY-14 delete merged party (owner role, trigger path)',
    $q$DELETE FROM parties.party WHERE id = '25a00000-0000-7000-8000-00000000a111'$q$, 'HK_PARTY_MERGED_IMMUTABLE');
  -- trg_immutable روی جدول‌های فقط‌افزودنی (مستقل از grant)
  PERFORM public.md_expect_error('INV-PTY-17 merge record immutable (owner role, trigger path)',
    $q$UPDATE parties.party_merge SET reason = 'تغییر سابقه' WHERE true$q$, 'HK_IMMUTABLE');
  PERFORM public.md_expect_error('INV-PTY-19 inquiry immutable (owner role, trigger path)',
    $q$DELETE FROM parties.party_taxpayer_inquiry WHERE true$q$, 'HK_IMMUTABLE');
END $$;
DO $$
BEGIN
  -- R-IMPORT: درون‌ریزی با session_replication_role=replica تریگرها را خاموش می‌کند؛ CHECKهای ادغام همچنان می‌ایستند
  PERFORM set_config('session_replication_role', 'replica', true);
  PERFORM public.md_expect_error('INV-PTY-15 merged into itself (import path)',
    $q$UPDATE parties.party SET status = 'merged', merged_into_id = id, merged_at = now() WHERE id = '25a00000-0000-7000-8000-00000000a603'$q$,
    'party_merge_self');
  PERFORM public.md_expect_error('INV-PTY-15 merged without target (import path)',
    $q$UPDATE parties.party SET status = 'merged' WHERE id = '25a00000-0000-7000-8000-00000000a603'$q$, 'party_merge_cols');
  PERFORM set_config('session_replication_role', 'origin', true);
END $$;
SET ROLE hk_app;

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
    $q$INSERT INTO catalog.item_variant (tenant_id, item_id, code, axis1_value_id, axis2_value_id) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c102','SH-100-40-BLK-2','25a00000-0000-7000-8000-00000000c021','25a00000-0000-7000-8000-00000000c024')$q$, 'item_variant_tenant_id_item_id_axis1_value_id_axis2_value_i_key');
  PERFORM public.md_expect_error('INV-CAT-20 duplicate SKU code',
    $q$INSERT INTO catalog.item_variant (tenant_id, item_id, code, axis1_value_id, axis2_value_id) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c102','CABLE-1','25a00000-0000-7000-8000-00000000c023','25a00000-0000-7000-8000-00000000c025')$q$, 'item_variant_tenant_id_code_key');
  PERFORM public.md_expect_error('INV-CAT-04 non-axis attribute as axis',
    $q$INSERT INTO catalog.item (tenant_id, code, name, item_type, base_uom_id, has_variants, variant_axis1_id) VALUES ('25a00000-0000-7000-8000-000000000001','AX-1','x','stock','25a00000-0000-7000-8000-00000000c001',true,'25a00000-0000-7000-8000-00000000c013')$q$, 'HK_CATALOG_ATTRIBUTE_NOT_AXIS');
  PERFORM public.md_expect_error('INV-CAT-04 axes without has_variants',
    $q$INSERT INTO catalog.item (tenant_id, code, name, item_type, base_uom_id, has_variants, variant_axis1_id) VALUES ('25a00000-0000-7000-8000-000000000001','AX-2','x','stock','25a00000-0000-7000-8000-00000000c001',false,'25a00000-0000-7000-8000-00000000c011')$q$, 'item_axes_shape');
  PERFORM public.md_expect_error('INV-CAT-04 same axis twice',
    $q$INSERT INTO catalog.item (tenant_id, code, name, item_type, base_uom_id, has_variants, variant_axis1_id, variant_axis2_id) VALUES ('25a00000-0000-7000-8000-000000000001','AX-3','x','stock','25a00000-0000-7000-8000-00000000c001',true,'25a00000-0000-7000-8000-00000000c011','25a00000-0000-7000-8000-00000000c011')$q$, 'item_axes_distinct');
  PERFORM public.md_expect_error('INV-CAT-04 axis member must be axis-capable',
    $q$INSERT INTO catalog.attribute_set_member (tenant_id, attribute_set_id, attribute_id, usage, axis_position) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c031','25a00000-0000-7000-8000-00000000c014','variant_axis',3)$q$, 'HK_CATALOG_ATTRIBUTE_NOT_AXIS');
  PERFORM public.md_expect_error('INV-CAT-05 serial on service',
    $q$INSERT INTO catalog.item (tenant_id, code, name, item_type, base_uom_id, track_serial) VALUES ('25a00000-0000-7000-8000-000000000001','SRV-1','نصب','service','25a00000-0000-7000-8000-00000000c001',true)$q$, 'item_tracking_stock_only');
  PERFORM public.md_expect_error('INV-CAT-05 expiry without batch',
    $q$INSERT INTO catalog.item (tenant_id, code, name, item_type, base_uom_id, track_expiry) VALUES ('25a00000-0000-7000-8000-000000000001','EXP-1','x','stock','25a00000-0000-7000-8000-00000000c001',true)$q$, 'item_expiry_needs_batch');
  PERFORM public.md_expect_error('INV-CAT-19 sstid 12 digits',
    $q$UPDATE catalog.item SET sstid = '271000013862' WHERE id = '25a00000-0000-7000-8000-00000000c101'$q$, 'item_sstid_check');
  PERFORM public.md_expect_error('INV-CAT-19 sstid without kind',
    $q$UPDATE catalog.item SET sstid_kind = NULL WHERE id = '25a00000-0000-7000-8000-00000000c101'$q$, 'item_sstid_pair');
  PERFORM public.md_expect_error('INV-CAT-18 value type mismatch',
    $q$INSERT INTO catalog.item_attribute_value (tenant_id, item_id, attribute_id, value_text) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c101','25a00000-0000-7000-8000-00000000c014','۲۲۰')$q$, 'HK_CATALOG_ATTRIBUTE_VALUE_TYPE');
  PERFORM public.md_expect_error('INV-CAT-18 descriptive value on an axis attribute',
    $q$INSERT INTO catalog.item_attribute_value (tenant_id, item_id, attribute_id, value_id) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c102','25a00000-0000-7000-8000-00000000c011','25a00000-0000-7000-8000-00000000c021')$q$, 'HK_CATALOG_ATTRIBUTE_IS_AXIS');
  PERFORM public.md_expect_error('INV-CAT-01 base row with factor <> 1',
    $q$INSERT INTO catalog.item_uom (tenant_id, item_id, uom_id, factor, is_base) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c108','25a00000-0000-7000-8000-00000000c002',12,true)$q$, 'item_uom_base_factor');
  PERFORM public.md_expect_error('INV-CAT-21 posting group code immutable',
    $q$UPDATE catalog.item_posting_group SET code = 'GOODS2' WHERE id = '25a00000-0000-7000-8000-00000000c041'$q$, 'HK_CATALOG_POSTING_GROUP_CODE_IMMUTABLE');
  PERFORM public.md_expect_error('INV-CAT-07 category cycle',
    $q$UPDATE catalog.item_category SET parent_id = '25a00000-0000-7000-8000-00000000c052' WHERE id = '25a00000-0000-7000-8000-00000000c051'$q$, 'HK_CATALOG_CATEGORY_CYCLE');
END $$;

-- ---------- T12b (RV-MD-07): هر قید، ایندکس یکتای جزئی و تریگر با کد یا نام دقیق خودش ----------
DO $$
DECLARE t uuid := '25a00000-0000-7000-8000-000000000001';
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  -- INV-PTY-09: ویرایش خط موجود (فقط trg_payment_term_sum آن را می‌بیند؛ trg_payment_term_has_lines فقط روی درج سرسند است)
  BEGIN
    UPDATE parties.payment_term_line SET portion_percent = 40
     WHERE payment_term_id = '25a00000-0000-7000-8000-00000000a011' AND line_no = 2;
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'TEST FAILED [INV-PTY-09 line edit to sum 90 accepted]';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'HK_PARTY_PAYMENT_TERM_SUM%' THEN RAISE; END IF;
  END;
  BEGIN
    DELETE FROM parties.payment_term_line WHERE payment_term_id = '25a00000-0000-7000-8000-00000000a011' AND line_no = 2;
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'TEST FAILED [INV-PTY-09 line delete accepted]';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'HK_PARTY_PAYMENT_TERM_SUM%' THEN RAISE; END IF;
  END;
  -- INV-PTY-01/05/08/10/11/12 و گروه پیش‌فرض
  PERFORM public.md_expect_error('INV-PTY-01 status without national id',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, national_id_status) VALUES ('25a00000-0000-7000-8000-000000000001','X21','natural','x','valid')$q$,
    'party_national_id_presence');
  PERFORM public.md_expect_error('INV-PTY-05 passport without country',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, passport_no) VALUES ('25a00000-0000-7000-8000-000000000001','X22','foreign_natural','x','P1234567')$q$,
    'party_passport_pair');
  PERFORM public.md_expect_error('INV-PTY-08 agent on a supplier role',
    $q$INSERT INTO parties.party_role (tenant_id, party_id, role, default_agent_party_id) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a103','supplier','25a00000-0000-7000-8000-00000000a101')$q$,
    'party_role_agent');
  PERFORM public.md_expect_error('INV-PTY-08 party as its own agent',
    $q$INSERT INTO parties.party_role (tenant_id, party_id, role, default_agent_party_id) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a103','customer','25a00000-0000-7000-8000-00000000a103')$q$,
    'party_role_agent');
  PERFORM public.md_expect_error('INV-PTY-10 phone format',
    $q$INSERT INTO parties.party_contact (tenant_id, party_id, kind, value) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101','phone','12345')$q$,
    'contact_phone_format');
  INSERT INTO parties.party_address (tenant_id, party_id, is_primary, address_line, moadian_branch_code) VALUES
    (t, '25a00000-0000-7000-8000-00000000a101', true, 'خیابان اول', '0007');
  PERFORM public.md_expect_error('INV-PTY-11 second primary address',
    $q$INSERT INTO parties.party_address (tenant_id, party_id, is_primary, address_line) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101',true,'خیابان دوم')$q$,
    'party_address_one_primary');
  PERFORM public.md_expect_error('INV-PTY-11 duplicate moadian branch code',
    $q$INSERT INTO parties.party_address (tenant_id, party_id, address_line, moadian_branch_code) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101','خیابان سوم','0007')$q$,
    'party_address_branch_code');
  INSERT INTO parties.party_bank_account (tenant_id, party_id, sheba, is_primary) VALUES
    (t, '25a00000-0000-7000-8000-00000000a113', 'IR820540102680020817909002', true);
  PERFORM public.md_expect_error('INV-PTY-12 second primary bank account',
    $q$INSERT INTO parties.party_bank_account (tenant_id, party_id, card_number, is_primary) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a113','6037701689095443',true)$q$,
    'party_bank_account_one_primary');
  PERFORM public.md_expect_error('INV-PTY-12 verification without holder name',
    $q$UPDATE parties.party_bank_account SET verified_at = now(), verification_provider = 'x' WHERE party_id = '25a00000-0000-7000-8000-00000000a113'$q$,
    'bank_account_verification');
  PERFORM public.md_expect_error('INV-PTY-06 second default group of a role',
    $q$INSERT INTO parties.party_group (tenant_id, role, code, name, is_default) VALUES ('25a00000-0000-7000-8000-000000000001','customer','VIP','ویژه',true)$q$,
    'party_group_one_default');
  -- INV-PTY-14: هر جدول فرزند parties و catalog نگهبان شخص ادغام‌شده دارد (a111 ادغام‌شده است)
  PERFORM public.md_expect_error('INV-PTY-14 role for merged party',
    $q$INSERT INTO parties.party_role (tenant_id, party_id, role) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a111','other')$q$, 'HK_PARTY_MERGED');
  PERFORM public.md_expect_error('INV-PTY-14 address for merged party',
    $q$INSERT INTO parties.party_address (tenant_id, party_id, address_line) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a111','نشانی')$q$, 'HK_PARTY_MERGED');
  PERFORM public.md_expect_error('INV-PTY-14 bank account for merged party',
    $q$INSERT INTO parties.party_bank_account (tenant_id, party_id, account_number) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a111','12345')$q$, 'HK_PARTY_MERGED');
  PERFORM public.md_expect_error('INV-PTY-14 hold for merged party',
    $q$INSERT INTO parties.party_hold (tenant_id, party_id, scope, source, reason) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a111','sales','manual','توقیف')$q$, 'HK_PARTY_MERGED');
  PERFORM public.md_expect_error('INV-PTY-14 legacy code for merged party',
    $q$INSERT INTO parties.party_legacy_code (tenant_id, party_id, source_system, legacy_code) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a111','excel','X-1')$q$, 'HK_PARTY_MERGED');
  PERFORM public.md_expect_error('INV-PTY-14 relation from merged party',
    $q$INSERT INTO parties.party_relation (tenant_id, party_id, related_party_id, relation) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a111','25a00000-0000-7000-8000-00000000a101','family')$q$, 'HK_PARTY_MERGED');
  PERFORM public.md_expect_error('INV-PTY-14 relation to merged party',
    $q$INSERT INTO parties.party_relation (tenant_id, party_id, related_party_id, relation) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101','25a00000-0000-7000-8000-00000000a111','family')$q$, 'HK_PARTY_MERGED');
  PERFORM public.md_expect_error('INV-PTY-14 taxpayer inquiry for merged party',
    $q$INSERT INTO parties.party_taxpayer_inquiry (tenant_id, party_id, economic_code, outcome, adapter) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a111','14003778990','found','mock')$q$, 'HK_PARTY_MERGED');
  PERFORM public.md_expect_error('INV-PTY-14 item supplier is a merged party',
    $q$INSERT INTO catalog.item_supplier (tenant_id, item_id, supplier_party_id) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c101','25a00000-0000-7000-8000-00000000a111')$q$, 'HK_PARTY_MERGED');
  PERFORM public.md_expect_error('INV-PTY-14 warranty provider is a merged party',
    $q$UPDATE catalog.item SET warranty_days = 365, warranty_provider_party_id = '25a00000-0000-7000-8000-00000000a111' WHERE id = '25a00000-0000-7000-8000-00000000c104'$q$, 'HK_PARTY_MERGED');

  -- INV-CAT-01/03/05/08/10/19: ایندکس‌های جزئی و CHECKهای نام‌دار
  PERFORM public.md_expect_error('INV-CAT-01 second base unit row',
    $q$INSERT INTO catalog.item_uom (tenant_id, item_id, uom_id, factor, is_base) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c103','25a00000-0000-7000-8000-00000000c001',1,true)$q$,
    'item_uom_one_base');
  PERFORM public.md_expect_error('INV-CAT-02 second default variant',
    $q$INSERT INTO catalog.item_variant (tenant_id, item_id, code, is_default) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c103','MILK-2',true)$q$,
    'item_variant_tenant_id_item_id_axis1_value_id_axis2_value_i_key');
  PERFORM public.md_expect_error('INV-CAT-03 default variant with an axis value',
    $q$INSERT INTO catalog.item_variant (tenant_id, item_id, code, is_default, axis1_value_id) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c102','SH-100-D',true,'25a00000-0000-7000-8000-00000000c023')$q$,
    'variant_default_no_axes');
  PERFORM public.md_expect_error('INV-CAT-10 duplicate PLU',
    $q$UPDATE catalog.item_variant SET plu_code = '123' WHERE id = '25a00000-0000-7000-8000-00000000c131'$q$, 'item_variant_plu');
  PERFORM public.md_expect_error('INV-CAT-19 variant sstid without kind',
    $q$UPDATE catalog.item_variant SET sstid = '2710000138624' WHERE id = '25a00000-0000-7000-8000-00000000c121'$q$, 'variant_sstid_pair');
  PERFORM public.md_expect_error('INV-CAT-05 shelf life without expiry tracking',
    $q$UPDATE catalog.item SET shelf_life_days = 10 WHERE id = '25a00000-0000-7000-8000-00000000c103'$q$, 'item_shelf_life_needs_expiry');
  INSERT INTO catalog.item_supplier (tenant_id, item_id, supplier_party_id, supplier_item_code) VALUES
    (t, '25a00000-0000-7000-8000-00000000c101', '25a00000-0000-7000-8000-00000000a102', 'K-15');
  PERFORM public.md_expect_error('INV-CAT-24 supplier item code unique per supplier',
    $q$INSERT INTO catalog.item_supplier (tenant_id, item_id, supplier_party_id, supplier_item_code) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c104','25a00000-0000-7000-8000-00000000a102','K-15')$q$,
    'item_supplier_code');
  -- تریگر یکپارچگی کالا (deferred): تغییر فقط روی کالا یا فقط روی واحد کالا
  BEGIN
    UPDATE catalog.item SET base_uom_id = '25a00000-0000-7000-8000-00000000c008' WHERE id = '25a00000-0000-7000-8000-00000000c103';
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'TEST FAILED [INV-CAT-01 base_uom change without base row accepted]';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'HK_CATALOG_ITEM_BASE_UOM%' THEN RAISE; END IF;
  END;
  BEGIN
    UPDATE catalog.item SET has_variants = true, variant_axis1_id = '25a00000-0000-7000-8000-00000000c011' WHERE id = '25a00000-0000-7000-8000-00000000c106';
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'TEST FAILED [INV-CAT-03 axes without variant values accepted]';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'HK_CATALOG_VARIANT_AXES%' THEN RAISE; END IF;
  END;
  BEGIN
    DELETE FROM catalog.item_uom WHERE item_id = '25a00000-0000-7000-8000-00000000c103' AND uom_id = '25a00000-0000-7000-8000-00000000c007';
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'TEST FAILED [INV-CAT-01 base unit row deleted]';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'HK_CATALOG_ITEM_BASE_UOM%' THEN RAISE; END IF;
  END;
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

-- ---------- T13b (RV-MD-15، RV-MD-18): حذف و ردیابی انقضای کالای قفل‌شده ----------
DO $$
DECLARE t uuid := '25a00000-0000-7000-8000-000000000001';
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  PERFORM public.md_expect_error('RV-MD-15 locked item cannot be deleted',
    $q$DELETE FROM catalog.item WHERE id = '25a00000-0000-7000-8000-00000000c101'$q$, 'HK_CATALOG_ITEM_LOCKED');
  PERFORM public.md_assert((SELECT count(*) FROM catalog.item_uom WHERE item_id = '25a00000-0000-7000-8000-00000000c101') = 2,
                           'RV-MD-15 units of the locked item survive');
  -- کالای بچ‌دار بدون انقضا پس از قفل انقضا نمی‌گیرد (بچ‌های موجود تاریخ انقضا ندارند)
  INSERT INTO catalog.item (tenant_id, id, code, name, item_type, base_uom_id, track_batch) VALUES
    (t, '25a00000-0000-7000-8000-00000000c109', 'BOLT', 'پیچ بچ‌دار', 'stock', '25a00000-0000-7000-8000-00000000c001', true);
  INSERT INTO catalog.item_uom (tenant_id, item_id, uom_id, factor, is_base) VALUES
    (t, '25a00000-0000-7000-8000-00000000c109', '25a00000-0000-7000-8000-00000000c001', 1, true);
  INSERT INTO catalog.item_variant (tenant_id, id, item_id, code, is_default) VALUES
    (t, '25a00000-0000-7000-8000-00000000c137', '25a00000-0000-7000-8000-00000000c109', 'BOLT', true);
  UPDATE catalog.item SET usage_locked_at = now() WHERE id = '25a00000-0000-7000-8000-00000000c109';
  PERFORM public.md_expect_error('RV-MD-18 expiry tracking frozen after use',
    $q$UPDATE catalog.item SET track_expiry = true, shelf_life_days = 30 WHERE id = '25a00000-0000-7000-8000-00000000c109'$q$, 'HK_CATALOG_ITEM_LOCKED');
  -- مجاز پیش از قفل: کالای ساده و استفاده‌نشده با فرزندانش حذف می‌شود
  INSERT INTO catalog.item (tenant_id, id, code, name, item_type, base_uom_id) VALUES
    (t, '25a00000-0000-7000-8000-00000000c1f9', 'TMP-DEL', 'کالای موقت', 'stock', '25a00000-0000-7000-8000-00000000c001');
  INSERT INTO catalog.item_uom (tenant_id, item_id, uom_id, factor, is_base) VALUES
    (t, '25a00000-0000-7000-8000-00000000c1f9', '25a00000-0000-7000-8000-00000000c001', 1, true);
  INSERT INTO catalog.item_variant (tenant_id, item_id, code, is_default) VALUES (t, '25a00000-0000-7000-8000-00000000c1f9', 'TMP-DEL', true);
  DELETE FROM catalog.item WHERE id = '25a00000-0000-7000-8000-00000000c1f9';
  PERFORM public.md_assert(NOT EXISTS (SELECT 1 FROM catalog.item_variant WHERE item_id = '25a00000-0000-7000-8000-00000000c1f9'),
                           'D-M25 an unused item is deleted with its children');
END $$;
DO $$
BEGIN
  PERFORM set_config('app.tenant_id', '25a00000-0000-7000-8000-000000000001', true);
  -- انقضای کالایی که قفل نیست هنوز قابل تغییر است (CHEESE)
  UPDATE catalog.item SET shelf_life_days = 45 WHERE id = '25a00000-0000-7000-8000-00000000c107';
  PERFORM public.md_assert((SELECT shelf_life_days FROM catalog.item WHERE id = '25a00000-0000-7000-8000-00000000c107') = 45,
                           'D-M15 shelf life is editable before use');
  UPDATE catalog.item SET usage_locked_at = now() WHERE id = '25a00000-0000-7000-8000-00000000c107';
  PERFORM public.md_expect_error('RV-MD-18 expiry tracking cannot be dropped after use',
    $q$UPDATE catalog.item SET track_expiry = false, shelf_life_days = NULL WHERE id = '25a00000-0000-7000-8000-00000000c107'$q$,
    'HK_CATALOG_ITEM_LOCKED');
  UPDATE catalog.item SET shelf_life_days = 30 WHERE id = '25a00000-0000-7000-8000-00000000c107';
  PERFORM public.md_assert((SELECT shelf_life_days FROM catalog.item WHERE id = '25a00000-0000-7000-8000-00000000c107') = 30,
                           'D-M15 shelf life stays a default for new batches after use');
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
    $q$INSERT INTO catalog.barcode (tenant_id, item_id, variant_id, uom_id, code, symbology, source) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c101','25a00000-0000-7000-8000-00000000c111','25a00000-0000-7000-8000-00000000c001','5901234123458','ean13','manufacturer')$q$, 'barcode_gtin_check_digit');
  PERFORM public.md_expect_error('INV-CAT-08 duplicate barcode',
    $q$INSERT INTO catalog.barcode (tenant_id, item_id, variant_id, uom_id, code, symbology, source) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c102','25a00000-0000-7000-8000-00000000c121','25a00000-0000-7000-8000-00000000c005','5901234123457','ean13','manufacturer')$q$, 'barcode_tenant_id_code_key');
  PERFORM public.md_expect_error('INV-CAT-08 variant of another item',
    $q$INSERT INTO catalog.barcode (tenant_id, item_id, variant_id, uom_id, code, symbology, source) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c101','25a00000-0000-7000-8000-00000000c121','25a00000-0000-7000-8000-00000000c001','4006381333931','ean13','manufacturer')$q$, 'barcode_tenant_id_item_id_variant_id_fkey');
  PERFORM public.md_expect_error('INV-CAT-08 unit not allowed for item',
    $q$INSERT INTO catalog.barcode (tenant_id, item_id, variant_id, uom_id, code, symbology, source) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c101','25a00000-0000-7000-8000-00000000c111','25a00000-0000-7000-8000-00000000c003','4006381333931','ean13','manufacturer')$q$, 'barcode_tenant_id_item_id_uom_id_fkey');
  PERFORM public.md_expect_error('INV-CAT-09 internal barcode outside 04',
    $q$INSERT INTO catalog.barcode (tenant_id, item_id, variant_id, uom_id, code, symbology, source) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c101','25a00000-0000-7000-8000-00000000c111','25a00000-0000-7000-8000-00000000c001','4006381333931','ean13','internal')$q$, 'barcode_internal_rcn');
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
    $q$INSERT INTO catalog.scale_barcode_pattern (tenant_id, code, name, prefix, plu_start, plu_length, value_kind, value_start, value_length, weight_uom_id) VALUES ('25a00000-0000-7000-8000-000000000001','P19','x','19',3,5,'weight',8,5,'25a00000-0000-7000-8000-00000000c003')$q$, 'scale_barcode_pattern_prefix_check');
  PERFORM public.md_expect_error('INV-CAT-10 prefix 04 (internal RCN space) rejected',
    $q$INSERT INTO catalog.scale_barcode_pattern (tenant_id, code, name, prefix, plu_start, plu_length, value_kind, value_start, value_length, weight_uom_id) VALUES ('25a00000-0000-7000-8000-000000000001','P04','x','04',3,5,'weight',8,5,'25a00000-0000-7000-8000-00000000c003')$q$, 'HK_CATALOG_SCALE_PREFIX_CONFLICT');
  PERFORM public.md_expect_error('INV-CAT-10 overlapping ranges',
    $q$INSERT INTO catalog.scale_barcode_pattern (tenant_id, code, name, prefix, plu_start, plu_length, value_kind, value_start, value_length, weight_uom_id) VALUES ('25a00000-0000-7000-8000-000000000001','P23','x','23',3,6,'weight',8,5,'25a00000-0000-7000-8000-00000000c003')$q$, 'scale_ranges_disjoint');
  PERFORM public.md_expect_error('INV-CAT-10 second active pattern on prefix',
    $q$INSERT INTO catalog.scale_barcode_pattern (tenant_id, code, name, prefix, plu_start, plu_length, value_kind, value_start, value_length, weight_uom_id) VALUES ('25a00000-0000-7000-8000-000000000001','W21B','x','21',3,4,'weight',7,5,'25a00000-0000-7000-8000-00000000c003')$q$, 'scale_pattern_active_prefix');
  PERFORM public.md_expect_error('INV-CAT-10 price pattern needs explicit amount unit',
    $q$INSERT INTO catalog.scale_barcode_pattern (tenant_id, code, name, prefix, plu_start, plu_length, value_kind, value_start, value_length, price_currency) VALUES ('25a00000-0000-7000-8000-000000000001','P25','x','25',3,5,'price',8,5,'IRR')$q$, 'scale_price_unit');
  PERFORM public.md_expect_error('INV-CAT-10 weight unit must be mass',
    $q$INSERT INTO catalog.scale_barcode_pattern (tenant_id, code, name, prefix, plu_start, plu_length, value_kind, value_start, value_length, weight_uom_id) VALUES ('25a00000-0000-7000-8000-000000000001','W26','x','26',3,5,'weight',8,5,'25a00000-0000-7000-8000-00000000c001')$q$, 'HK_CATALOG_SCALE_WEIGHT_UOM');
END $$;

-- ---------- T14b (RV-MD-07): قیدهای الگوی ترازو و بارکد اصلی با نام دقیق ----------
DO $$
DECLARE t uuid := '25a00000-0000-7000-8000-000000000001';
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  PERFORM public.md_expect_error('INV-CAT-08 second primary barcode of a (variant, unit)',
    $q$INSERT INTO catalog.barcode (tenant_id, item_id, variant_id, uom_id, code, symbology, source, is_primary) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c101','25a00000-0000-7000-8000-00000000c111','25a00000-0000-7000-8000-00000000c001','4006381333931','ean13','manufacturer',true)$q$,
    'barcode_one_primary');
  PERFORM public.md_expect_error('INV-CAT-10 PLU range starts inside the prefix',
    $q$INSERT INTO catalog.scale_barcode_pattern (tenant_id, code, name, prefix, plu_start, plu_length, value_kind, value_start, value_length, weight_uom_id) VALUES ('25a00000-0000-7000-8000-000000000001','P24A','x','24',2,5,'weight',8,5,'25a00000-0000-7000-8000-00000000c003')$q$,
    'scale_plu_range');
  PERFORM public.md_expect_error('INV-CAT-10 value range reaches the check digit',
    $q$INSERT INTO catalog.scale_barcode_pattern (tenant_id, code, name, prefix, plu_start, plu_length, value_kind, value_start, value_length, weight_uom_id) VALUES ('25a00000-0000-7000-8000-000000000001','P24B','x','24',3,5,'weight',9,5,'25a00000-0000-7000-8000-00000000c003')$q$,
    'scale_value_range');
  PERFORM public.md_expect_error('INV-CAT-10 weight pattern without a weight unit',
    $q$INSERT INTO catalog.scale_barcode_pattern (tenant_id, code, name, prefix, plu_start, plu_length, value_kind, value_start, value_length) VALUES ('25a00000-0000-7000-8000-000000000001','P24C','x','24',3,5,'weight',8,5)$q$,
    'scale_weight_uom');
  PERFORM public.md_expect_error('INV-CAT-10 Rial/Toman unit on a foreign-currency price pattern',
    $q$INSERT INTO catalog.scale_barcode_pattern (tenant_id, code, name, prefix, plu_start, plu_length, value_kind, value_start, value_length, price_currency, price_amount_unit) VALUES ('25a00000-0000-7000-8000-000000000001','P24D','x','24',3,5,'price',8,5,'USD','IRT')$q$,
    'scale_irr_units');
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
    format($q$INSERT INTO catalog.price_list_item (tenant_id, price_list_id, item_id, uom_id, min_qty, valid_from, price) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c301','25a00000-0000-7000-8000-00000000c101','25a00000-0000-7000-8000-00000000c001',0,%L,51000)$q$, d + 10), 'price_list_item_no_overlap');
  PERFORM public.md_expect_error('INV-CAT-12 precision of IRR list',
    format($q$INSERT INTO catalog.price_list_item (tenant_id, price_list_id, item_id, uom_id, min_qty, valid_from, price) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c301','25a00000-0000-7000-8000-00000000c104','25a00000-0000-7000-8000-00000000c004',0,%L,1200.5)$q$, d), 'HK_CATALOG_PRICE_PRECISION');
  PERFORM public.md_expect_error('INV-CAT-13 backdated insert',
    format($q$INSERT INTO catalog.price_list_item (tenant_id, price_list_id, item_id, uom_id, min_qty, valid_from, price) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c303','25a00000-0000-7000-8000-00000000c101','25a00000-0000-7000-8000-00000000c001',0,%L,40000)$q$, d - 3), 'HK_CATALOG_PRICE_BACKDATED');
  PERFORM public.md_expect_error('INV-CAT-14 base list of other kind',
    $q$INSERT INTO catalog.price_list (tenant_id, code, name, kind, currency, price_precision, base_price_list_id, base_adjust_percent) VALUES ('25a00000-0000-7000-8000-000000000001','X1','x','purchase','IRR',0,'25a00000-0000-7000-8000-00000000c301',5)$q$, 'HK_CATALOG_PRICE_LIST_BASE_MISMATCH');
  PERFORM public.md_expect_error('INV-CAT-14 derived cycle',
    $q$UPDATE catalog.price_list SET base_price_list_id = '25a00000-0000-7000-8000-00000000c302', base_adjust_percent = 1 WHERE id = '25a00000-0000-7000-8000-00000000c301'$q$, 'HK_CATALOG_PRICE_LIST_CYCLE');
  PERFORM public.md_expect_error('INV-CAT-14 second default list',
    $q$INSERT INTO catalog.price_list (tenant_id, code, name, kind, currency, price_precision, is_default) VALUES ('25a00000-0000-7000-8000-000000000001','X2','x','sales','IRR',0,true)$q$, 'price_list_one_default');
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

-- ---------- T15b (RV-MD-04، RV-MD-11، RV-MD-22): قاعدهٔ فهرست، پرچم پس‌تاریخ، گرد کردن تبدیل واحد ----------
DO $$
DECLARE t uuid := '25a00000-0000-7000-8000-000000000001'; d date;
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  d := catalog.tenant_today(t);
  INSERT INTO catalog.price_list (tenant_id, id, code, name, kind, currency, price_precision) VALUES
    (t, '25a00000-0000-7000-8000-00000000c331', 'HIST', 'فهرست با تاریخچه', 'sales', 'IRR', 2),
    (t, '25a00000-0000-7000-8000-00000000c333', 'SOLO', 'فهرست بی‌تاریخچه', 'sales', 'IRR', 0),
    (t, '25a00000-0000-7000-8000-00000000c334', 'PREC', 'فهرست وزنی', 'sales', 'IRR', 0);
  INSERT INTO catalog.price_list (tenant_id, id, code, name, kind, currency, price_precision, base_price_list_id, base_adjust_percent, rounding_increment, rounding_mode) VALUES
    (t, '25a00000-0000-7000-8000-00000000c332', 'HISTW', 'مشتق از تاریخچه', 'sales', 'IRR', 0, '25a00000-0000-7000-8000-00000000c331', -7, 1000, 'nearest'),
    (t, '25a00000-0000-7000-8000-00000000c335', 'PRECW', 'مشتق وزنی', 'sales', 'IRR', 0, '25a00000-0000-7000-8000-00000000c334', -7, 1000, 'nearest');
  INSERT INTO catalog.price_list_assignment (tenant_id, price_list_id, party_group_id) VALUES
    (t, '25a00000-0000-7000-8000-00000000c333', '25a00000-0000-7000-8000-00000000a003');
  INSERT INTO catalog.price_list_item (tenant_id, price_list_id, item_id, uom_id, min_qty, valid_from, price) VALUES
    (t, '25a00000-0000-7000-8000-00000000c334', '25a00000-0000-7000-8000-00000000c104', '25a00000-0000-7000-8000-00000000c003', 0, d, 12345678);
  PERFORM set_config('hk.catalog_allow_backdate', 'on', true);       -- UoW مهاجرت: درج تاریخچه
  INSERT INTO catalog.price_list_item (tenant_id, id, price_list_id, item_id, uom_id, min_qty, valid_from, price) VALUES
    (t, '25a00000-0000-7000-8000-00000000c336', '25a00000-0000-7000-8000-00000000c331', '25a00000-0000-7000-8000-00000000c101',
     '25a00000-0000-7000-8000-00000000c001', 0, d - 30, 1500000.25);
END $$;
DO $$
DECLARE t uuid := '25a00000-0000-7000-8000-000000000001'; d date; p_before numeric;
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  d := catalog.tenant_today(t);
  p_before := (SELECT price FROM catalog.resolve_price('25a00000-0000-7000-8000-00000000c332','25a00000-0000-7000-8000-00000000c111','25a00000-0000-7000-8000-00000000c001',1,d - 10));
  PERFORM public.md_assert(p_before = 1395000, 'RV-MD-04 derived price of a past day: ' || coalesce(p_before::text, '-'));
  -- RV-MD-04: قاعدهٔ فهرستی که تاریخچه دارد (خودش، پایه یا مشتق) منجمد است
  PERFORM public.md_expect_error('RV-MD-04 derived percent frozen once its base has effective prices',
    $q$UPDATE catalog.price_list SET base_adjust_percent = -20 WHERE id = '25a00000-0000-7000-8000-00000000c332'$q$, 'HK_CATALOG_PRICE_LIST_RULE_FROZEN');
  PERFORM public.md_expect_error('RV-MD-04 derived rounding frozen',
    $q$UPDATE catalog.price_list SET rounding_increment = 500 WHERE id = '25a00000-0000-7000-8000-00000000c332'$q$, 'HK_CATALOG_PRICE_LIST_RULE_FROZEN');
  PERFORM public.md_expect_error('RV-MD-04 tax inclusion frozen on a list with history',
    $q$UPDATE catalog.price_list SET prices_include_tax = true WHERE id = '25a00000-0000-7000-8000-00000000c331'$q$, 'HK_CATALOG_PRICE_LIST_RULE_FROZEN');
  PERFORM public.md_expect_error('RV-MD-04 list validity start frozen',
    format($q$UPDATE catalog.price_list SET valid_from = %L WHERE id = '25a00000-0000-7000-8000-00000000c331'$q$, d), 'HK_CATALOG_PRICE_LIST_RULE_FROZEN');
  PERFORM public.md_expect_error('RV-MD-04 list closed into the past',
    format($q$UPDATE catalog.price_list SET valid_to = %L WHERE id = '25a00000-0000-7000-8000-00000000c332'$q$, d - 5), 'HK_CATALOG_PRICE_LIST_RULE_FROZEN');
  PERFORM public.md_expect_error('RV-MD-04 base currency change orphans a derived list',
    $q$UPDATE catalog.price_list SET currency = 'USD' WHERE id = '25a00000-0000-7000-8000-00000000c331'$q$, 'HK_CATALOG_PRICE_LIST_BASE_MISMATCH');
  PERFORM public.md_expect_error('RV-MD-04 base kind change orphans a derived list',
    $q$UPDATE catalog.price_list SET kind = 'purchase' WHERE id = '25a00000-0000-7000-8000-00000000c331'$q$, 'HK_CATALOG_PRICE_LIST_BASE_MISMATCH');
  PERFORM public.md_expect_error('RV-MD-04 kind change against a customer-group assignment',
    $q$UPDATE catalog.price_list SET kind = 'purchase', is_default = false WHERE id = '25a00000-0000-7000-8000-00000000c333'$q$, 'HK_CATALOG_ASSIGNMENT_GROUP_ROLE');
  PERFORM public.md_expect_error('RV-MD-04 precision lowered below existing entries',
    $q$UPDATE catalog.price_list SET price_precision = 0 WHERE id = '25a00000-0000-7000-8000-00000000c331'$q$, 'HK_CATALOG_PRICE_PRECISION');
  PERFORM public.md_assert((SELECT price FROM catalog.resolve_price('25a00000-0000-7000-8000-00000000c332','25a00000-0000-7000-8000-00000000c111','25a00000-0000-7000-8000-00000000c001',1,d - 10)) = p_before,
                           'RV-MD-04 past derived price unchanged');
  -- مجاز: فهرست بی‌تاریخچه قاعده‌اش را عوض می‌کند؛ فهرست با تاریخچه فقط از دیروز بسته می‌شود
  UPDATE catalog.price_list SET prices_include_tax = true, price_precision = 2 WHERE id = '25a00000-0000-7000-8000-00000000c333';
  UPDATE catalog.price_list SET valid_to = d - 1 WHERE id = '25a00000-0000-7000-8000-00000000c332';
  UPDATE catalog.price_list SET valid_to = NULL WHERE id = '25a00000-0000-7000-8000-00000000c332';

  -- RV-MD-11: پرچم پس‌تاریخ فقط درج را باز می‌کند، نه ویرایش یا حذف سطر اثرگذار
  PERFORM set_config('hk.catalog_allow_backdate', 'on', true);
  PERFORM public.md_expect_error('RV-MD-11 backdate flag does not allow editing an effective price',
    $q$UPDATE catalog.price_list_item SET price = 1600000 WHERE id = '25a00000-0000-7000-8000-00000000c336'$q$, 'HK_CATALOG_PRICE_PAST_IMMUTABLE');
  PERFORM public.md_expect_error('RV-MD-11 backdate flag does not allow deleting an effective price',
    $q$DELETE FROM catalog.price_list_item WHERE id = '25a00000-0000-7000-8000-00000000c336'$q$, 'HK_CATALOG_PRICE_PAST_IMMUTABLE');
  INSERT INTO catalog.price_list_item (tenant_id, id, price_list_id, item_id, uom_id, min_qty, valid_from, price) VALUES
    (t, '25a00000-0000-7000-8000-00000000c337', '25a00000-0000-7000-8000-00000000c331', '25a00000-0000-7000-8000-00000000c104',
     '25a00000-0000-7000-8000-00000000c003', 0, d + 3, 900000);
  PERFORM public.md_expect_error('RV-MD-11 backdate flag does not move a future price into the past',
    format($q$UPDATE catalog.price_list_item SET valid_from = %L WHERE id = '25a00000-0000-7000-8000-00000000c337'$q$, d - 3), 'HK_CATALOG_PRICE_BACKDATED');
  PERFORM set_config('hk.catalog_allow_backdate', '', true);

  -- RV-MD-22: تبدیل واحد گرد نمی‌شود؛ مبلغ سطر = round(qty × price)
  PERFORM public.md_assert((SELECT price = 12345.678 AND via = 'base_uom' FROM catalog.resolve_price('25a00000-0000-7000-8000-00000000c334','25a00000-0000-7000-8000-00000000c132','25a00000-0000-7000-8000-00000000c004',250,d)),
                           'RV-MD-22 per-gram price is the exact conversion');
  PERFORM public.md_assert((SELECT round(250 * price, 0) FROM catalog.resolve_price('25a00000-0000-7000-8000-00000000c334','25a00000-0000-7000-8000-00000000c132','25a00000-0000-7000-8000-00000000c004',250,d)) = 3086420,
                           'RV-MD-22 250 g line amount = round(250 x 12,345.678) = 3,086,420');
  -- گرد کردن فهرست مشتق روی واحدِ قیمت‌گذاری‌شده (کیلوگرم) اعمال می‌شود، نه روی گرم
  PERFORM public.md_assert((SELECT price FROM catalog.resolve_price('25a00000-0000-7000-8000-00000000c335','25a00000-0000-7000-8000-00000000c132','25a00000-0000-7000-8000-00000000c004',250,d)) = 11481,
                           'RV-MD-22 derived per-gram price = (12,345,678 x 0.93 rounded to 1000) / 1000');
  PERFORM public.md_assert((SELECT price FROM catalog.resolve_price('25a00000-0000-7000-8000-00000000c302','25a00000-0000-7000-8000-00000000c132','25a00000-0000-7000-8000-00000000c004',1,d)) = 1116,
                           'RV-MD-22 derived wholesale per-gram price from a per-kg retail price');
END $$;

-- ---------- T15c (RV-MD-09، INV-PTY-14): ارجاع‌های catalog پس از ادغام ----------
DO $$
DECLARE t uuid := '25a00000-0000-7000-8000-000000000001'; v_merge uuid; r jsonb;
  W uuid := '25a00000-0000-7000-8000-00000000a608'; L uuid := '25a00000-0000-7000-8000-00000000a609';
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  INSERT INTO parties.party (tenant_id, id, code, person_type, name) VALUES
    (t, W, 'M608', 'legal', 'پخش البرز'), (t, L, 'M609', 'legal', 'پخش البرز قدیم');
  INSERT INTO catalog.price_list_assignment (tenant_id, id, price_list_id, party_id) VALUES
    (t, '25a00000-0000-7000-8000-00000000c341', '25a00000-0000-7000-8000-00000000c302', L);
  INSERT INTO catalog.item_supplier (tenant_id, id, item_id, supplier_party_id, supplier_item_code) VALUES
    (t, '25a00000-0000-7000-8000-00000000c342', '25a00000-0000-7000-8000-00000000c101', L, 'AL-15'),
    (t, '25a00000-0000-7000-8000-00000000c343', '25a00000-0000-7000-8000-00000000c104', L, 'AL-BEANS'),
    (t, '25a00000-0000-7000-8000-00000000c344', '25a00000-0000-7000-8000-00000000c104', W, NULL);
  INSERT INTO catalog.price_list_assignment (tenant_id, id, price_list_id, party_id, channel) VALUES
    (t, '25a00000-0000-7000-8000-00000000c345', '25a00000-0000-7000-8000-00000000c302', L, 'pos');
  UPDATE catalog.item SET warranty_days = 365, warranty_provider_party_id = L WHERE id = '25a00000-0000-7000-8000-00000000c103';
  v_merge := parties.merge_parties(W, L, 'دو کد برای یک پخش‌کننده', NULL);
  UPDATE catalog.price_list_assignment SET is_active = false WHERE id = '25a00000-0000-7000-8000-00000000c345';
  PERFORM public.md_expect_error('RV-MD-09 a retired stale assignment cannot be revived',
    $q$UPDATE catalog.price_list_assignment SET is_active = true WHERE id = '25a00000-0000-7000-8000-00000000c345'$q$, 'HK_PARTY_MERGED');
  -- پیش از جابه‌جایی: ردیف فعال کهنه ویرایش نمی‌شود، ولی غیرفعال کردن آزاد است
  PERFORM public.md_expect_error('RV-MD-09 active stale assignment cannot be edited',
    $q$UPDATE catalog.price_list_assignment SET priority = 5 WHERE id = '25a00000-0000-7000-8000-00000000c341'$q$, 'HK_PARTY_MERGED');
  UPDATE catalog.item_supplier SET is_active = false WHERE id = '25a00000-0000-7000-8000-00000000c343';
  PERFORM public.md_assert(NOT (SELECT is_active FROM catalog.item_supplier WHERE id = '25a00000-0000-7000-8000-00000000c343'),
                           'RV-MD-09 a stale row pointing to the loser can be deactivated');
  PERFORM public.md_expect_error('RV-MD-09 new assignment to the loser',
    format($q$INSERT INTO catalog.price_list_assignment (tenant_id, price_list_id, party_id) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c301',%L)$q$, L), 'HK_PARTY_MERGED');
  -- مشترک catalog.party_merge
  r := catalog.rewire_merged_party(v_merge);
  PERFORM public.md_assert((r ->> 'price_list_assignment')::int = 2 AND (r ->> 'item_supplier')::int = 1 AND (r ->> 'item_warranty_provider')::int = 1,
                           'RV-MD-09 rewire counts: ' || r::text);
  PERFORM public.md_assert((SELECT party_id = W AND NOT is_active FROM catalog.price_list_assignment WHERE id = '25a00000-0000-7000-8000-00000000c345'),
                           'RV-MD-09 a retired assignment moves but stays inactive');
  PERFORM public.md_assert((SELECT party_id = W AND is_active FROM catalog.price_list_assignment WHERE id = '25a00000-0000-7000-8000-00000000c341'),
                           'RV-MD-09 customer price list follows the successor');
  PERFORM public.md_assert((SELECT supplier_party_id = W FROM catalog.item_supplier WHERE id = '25a00000-0000-7000-8000-00000000c342')
                           AND (SELECT supplier_party_id = L AND NOT is_active FROM catalog.item_supplier WHERE id = '25a00000-0000-7000-8000-00000000c343'),
                           'RV-MD-09 supplier rows moved; the duplicate stays retired on the loser');
  PERFORM public.md_assert((SELECT warranty_provider_party_id FROM catalog.item WHERE id = '25a00000-0000-7000-8000-00000000c103') = W,
                           'RV-MD-09 warranty provider follows the successor');
  r := catalog.rewire_merged_party(v_merge);
  PERFORM public.md_assert((r ->> 'price_list_assignment')::int = 0 AND (r ->> 'item_supplier')::int = 0 AND (r ->> 'item_warranty_provider')::int = 0,
                           'RV-MD-09 rewire is idempotent');
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
    format($q$UPDATE catalog.bom SET status = 'active', valid_from = %L, activated_at = now() WHERE id = '25a00000-0000-7000-8000-00000000c402'$q$, d + 1), 'bom_active_no_overlap');
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

-- ---------- T16b (RV-MD-16، RV-MD-07): دستور در حال اجرای گذشته جابه‌جا نمی‌شود ----------
DO $$
DECLARE t uuid := '25a00000-0000-7000-8000-000000000001'; d date;
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  d := catalog.tenant_today(t);
  -- فعال‌سازی پس‌تاریخ فقط با پرچم مهاجرت (کیت هدیه از ۳۰ روز پیش)
  PERFORM public.md_expect_error('RV-MD-16 backdated activation',
    format($q$UPDATE catalog.bom SET status = 'active', valid_from = %L, activated_at = now() WHERE id = '25a00000-0000-7000-8000-00000000c403'$q$, d - 30),
    'HK_CATALOG_BOM_BACKDATED');
  PERFORM set_config('hk.catalog_allow_backdate', 'on', true);
  UPDATE catalog.bom SET status = 'active', valid_from = d - 30, activated_at = now() WHERE id = '25a00000-0000-7000-8000-00000000c403';
  PERFORM set_config('hk.catalog_allow_backdate', '', true);
  PERFORM public.md_expect_error('RV-MD-16 active BOM closed into the past',
    format($q$UPDATE catalog.bom SET valid_to = %L WHERE id = '25a00000-0000-7000-8000-00000000c403'$q$, d - 10), 'HK_CATALOG_BOM_PAST_IMMUTABLE');
  PERFORM public.md_expect_error('RV-MD-16 archive with a past end date',
    format($q$UPDATE catalog.bom SET status = 'archived', archived_at = now(), valid_to = %L WHERE id = '25a00000-0000-7000-8000-00000000c403'$q$, d - 10),
    'HK_CATALOG_BOM_PAST_IMMUTABLE');
  UPDATE catalog.bom SET valid_to = d - 1 WHERE id = '25a00000-0000-7000-8000-00000000c403';
  -- بستن از دیروز هنوز قابل تمدید است (همان قاعدهٔ سطر قیمت: valid_to ≥ دیروز)
  UPDATE catalog.bom SET valid_to = d + 5 WHERE id = '25a00000-0000-7000-8000-00000000c403';
  UPDATE catalog.bom SET valid_to = d - 1 WHERE id = '25a00000-0000-7000-8000-00000000c403';
  PERFORM public.md_assert((SELECT valid_from = d - 30 AND valid_to = d - 1 FROM catalog.bom WHERE id = '25a00000-0000-7000-8000-00000000c403'),
                           'RV-MD-16 past window of the active BOM preserved');
  -- قیدهای نام‌دار BOM (RV-MD-07)
  PERFORM public.md_expect_error('INV-CAT-17 archived without archived_at',
    $q$UPDATE catalog.bom SET status = 'archived' WHERE id = '25a00000-0000-7000-8000-00000000c402'$q$, 'bom_check1');
  INSERT INTO catalog.bom (tenant_id, id, item_id, kind, version_no, yield_uom_id) VALUES
    (t, '25a00000-0000-7000-8000-00000000c405', '25a00000-0000-7000-8000-00000000c105', 'recipe', 3, '25a00000-0000-7000-8000-00000000c006');
  PERFORM public.md_expect_error('INV-CAT-17 draft with end before start',
    format($q$UPDATE catalog.bom SET valid_from = %L, valid_to = %L WHERE id = '25a00000-0000-7000-8000-00000000c405'$q$, d + 5, d + 1), 'bom_check2');
  PERFORM public.md_expect_error('INV-CAT-17 component quantity must be positive',
    $q$INSERT INTO catalog.bom_line (tenant_id, bom_id, line_no, component_item_id, qty, uom_id) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c405',1,'25a00000-0000-7000-8000-00000000c103',0,'25a00000-0000-7000-8000-00000000c008')$q$,
    'bom_line_qty_check');
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
    $q$INSERT INTO parties.code_series (tenant_id, role, group_id, prefix) VALUES ('25a00000-0000-7000-8000-000000000001','supplier','25a00000-0000-7000-8000-00000000a003','S')$q$, 'code_series_tenant_id_group_id_role_fkey');
  PERFORM public.md_expect_error('INV-PTY-23 group series without role',
    $q$INSERT INTO parties.code_series (tenant_id, group_id, prefix) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a003','S')$q$, 'code_series_check');
  PERFORM public.md_expect_error('INV-PTY-23 second default series',
    $q$INSERT INTO parties.code_series (tenant_id, prefix) VALUES ('25a00000-0000-7000-8000-000000000001','D')$q$, 'code_series_tenant_id_role_group_id_key');

  -- INV-PTY-24: ویژگی‌های نگاشت حساب شخص
  a := parties.posting_attributes('25a00000-0000-7000-8000-00000000a101', 'customer', '25a00000-0000-7000-8000-0000000000c1');
  PERFORM public.md_assert(a = '{"attr:customer_group":"WHOLESALE","attr:party_role":"customer","attr:party_person_type":"natural"}'::jsonb,
                           'INV-PTY-24 company-specific group (attr: keys)');
  PERFORM public.md_assert(public.md_attr_keys_ok(a), 'INV-PTY-24 keys accepted by ledger condition grammar');
  a := parties.posting_attributes('25a00000-0000-7000-8000-00000000a101', 'customer', '25a00000-0000-7000-8000-0000000000c2');
  PERFORM public.md_assert(a ->> 'attr:customer_group' = 'RETAIL', 'INV-PTY-24 default role row group');
  a := parties.posting_attributes('25a00000-0000-7000-8000-00000000a103', 'customer', NULL);
  PERFORM public.md_assert(a ->> 'attr:customer_group' = 'RETAIL', 'INV-PTY-24 default group of the role when no role row');
  a := parties.posting_attributes('25a00000-0000-7000-8000-00000000a102', 'employee', NULL);
  PERFORM public.md_assert(a = '{"attr:party_role":"employee","attr:party_person_type":"legal"}'::jsonb, 'INV-PTY-24 no group -> key omitted');
  a := parties.posting_attributes('25a00000-0000-7000-8000-00000000a111', 'customer', NULL);
  PERFORM public.md_assert(a ->> 'attr:customer_group' = 'RETAIL' AND a ->> 'attr:party_person_type' = 'natural', 'INV-PTY-24 merged party resolves to successor');
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
                           = '{"attr:item_posting_group":"GOODS","attr:item_type":"stock","attr:item_category":"SHOES"}'::jsonb, 'INV-CAT-22 item posting attributes');
  PERFORM public.md_assert(public.md_attr_keys_ok(catalog.posting_attributes('25a00000-0000-7000-8000-00000000c121')),
                           'INV-CAT-22 item posting attribute keys follow ledger condition grammar');

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
    $q$INSERT INTO catalog.code_series (tenant_id, category_id, prefix) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c052','X')$q$, 'code_series_tenant_id_category_id_key');
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
    $q$INSERT INTO parties.party_role (tenant_id, party_id, role) VALUES ('25b00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101','customer')$q$, 'party_role_tenant_id_party_id_fkey');
  PERFORM public.md_expect_error('INV-MD-02 barcode for another tenant''s variant',
    $q$INSERT INTO catalog.barcode (tenant_id, item_id, variant_id, uom_id, code, symbology, source) VALUES ('25b00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c101','25a00000-0000-7000-8000-00000000c111','25a00000-0000-7000-8000-00000000c001','4006381333931','ean13','manufacturer')$q$, 'barcode_tenant_id_item_id_variant_id_fkey');
  UPDATE parties.party SET name = 'hacked' WHERE id = '25a00000-0000-7000-8000-00000000a101';
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM public.md_assert(n = 0, 'barcode_tenant_id_item_id_variant_id_fkey');
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

-- =====================================================================
-- بخش ۴: همروندی واقعی با دو نشست (postgres + dblink؛ نشست‌ها با نقش hk_app) — T20
-- RV-MD-05 (درج فرزند هم‌زمان با ادغام)، RV-MD-14 (نقش شرکت هم‌زمان با تنگ کردن محدوده)، RV-MD-17 (بارکد و الگوی
-- ترازو). نشست اول کار را در تراکنش باز نگه می‌دارد؛ دومی باید منتظر بماند و پس از commit اولی با snapshot تازه رد شود.
-- پیش‌نیاز: افزونهٔ contrib «dblink» و اتصال محلی؛ در نبود آن NOTICE «SKIP».
-- =====================================================================
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'dblink') THEN
    CREATE SCHEMA IF NOT EXISTS md_cc;
    CREATE EXTENSION IF NOT EXISTS dblink SCHEMA md_cc;
  ELSE
    RAISE NOTICE 'SKIP T20: the contrib extension dblink is not installed';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.md_cc_open(p_name text) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_pid integer;
BEGIN
  PERFORM md_cc.dblink_connect(p_name, format('dbname=%s user=%s host=%s port=%s', current_database(), current_user,
                                             split_part(current_setting('unix_socket_directories'), ',', 1), current_setting('port')));
  PERFORM md_cc.dblink_exec(p_name, 'SET ROLE hk_app');
  PERFORM md_cc.dblink_exec(p_name, 'BEGIN');
  PERFORM 1 FROM md_cc.dblink(p_name, $q$SELECT set_config('app.tenant_id', '25a00000-0000-7000-8000-000000000001', true)$q$) AS x(v text);
  SELECT x.pid INTO v_pid FROM md_cc.dblink(p_name, 'SELECT pg_backend_pid()') AS x(pid integer);
  RETURN v_pid;
END $$;
CREATE OR REPLACE FUNCTION public.md_cc_blocked(p_pid integer) RETURNS boolean
LANGUAGE plpgsql AS $$
BEGIN
  FOR i IN 1..200 LOOP
    IF EXISTS (SELECT 1 FROM pg_locks WHERE pid = p_pid AND NOT granted) THEN RETURN true; END IF;
    PERFORM pg_sleep(0.02);
  END LOOP;
  RETURN false;
END $$;
CREATE OR REPLACE FUNCTION public.md_cc_finish(p_name text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v text; e text;
BEGIN
  SELECT x.v INTO v FROM md_cc.dblink_get_result(p_name, false) AS x(v text);
  e := md_cc.dblink_error_message(p_name);
  PERFORM 1 FROM md_cc.dblink_get_result(p_name, false) AS x(v text);
  RETURN CASE WHEN e = 'OK' THEN coalesce(v, 'OK') ELSE 'ERROR: ' || regexp_replace(e, '^ERROR:\s+', '') END;
END $$;

-- داده: شخص‌های همروندی (commitشده)
DO $$
DECLARE t uuid := '25a00000-0000-7000-8000-000000000001';
BEGIN
  IF to_regnamespace('md_cc') IS NULL THEN RETURN; END IF;
  PERFORM set_config('app.tenant_id', t::text, true);
  INSERT INTO parties.party (tenant_id, id, code, person_type, name) VALUES
    (t, '25a00000-0000-7000-8000-00000000a6a1', 'M6A1', 'natural', 'برندهٔ همروند'),
    (t, '25a00000-0000-7000-8000-00000000a6a2', 'M6A2', 'natural', 'بازندهٔ همروند'),
    (t, '25a00000-0000-7000-8000-00000000a6a3', 'M6A3', 'legal', 'تأمین‌کنندهٔ همروند'),
    (t, '25a00000-0000-7000-8000-00000000a6a4', 'M6A4', 'natural', 'بازاریاب قدیم');
END $$;

-- RV-MD-05: درج راه ارتباطی برای بازنده هم‌زمان با ادغام
DO $$
DECLARE pid_c integer; v text;
BEGIN
  IF to_regnamespace('md_cc') IS NULL THEN RETURN; END IF;
  PERFORM public.md_cc_open('m'); pid_c := public.md_cc_open('c');
  PERFORM 1 FROM md_cc.dblink('m', $q$SELECT parties.merge_parties('25a00000-0000-7000-8000-00000000a6a1','25a00000-0000-7000-8000-00000000a6a2','ادغام هم‌زمان',NULL)::text$q$) AS x(v text);
  PERFORM md_cc.dblink_send_query('c', $q$INSERT INTO parties.party_contact (tenant_id, party_id, kind, value, is_primary)
     VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a6a2','mobile','09125550502',true) RETURNING id::text$q$);
  PERFORM public.md_assert(public.md_cc_blocked(pid_c), 'RV-MD-05 child insert waits for an in-flight merge of its party');
  PERFORM md_cc.dblink_exec('m', 'COMMIT');
  v := public.md_cc_finish('c');
  PERFORM public.md_assert(v LIKE 'ERROR: HK_PARTY_MERGED:%', 'RV-MD-05 child insert sees the committed merge and is refused: ' || coalesce(v, '-'));
  PERFORM md_cc.dblink_exec('c', 'ROLLBACK');
  PERFORM md_cc.dblink_disconnect('m'); PERFORM md_cc.dblink_disconnect('c');
  PERFORM public.md_assert(NOT EXISTS (SELECT 1 FROM parties.party_contact WHERE party_id = '25a00000-0000-7000-8000-00000000a6a2' AND is_active),
                           'RV-MD-05 merged party has no live child');
END $$;

-- RV-MD-05 (بازاریاب): نقش مشتری با بازاریابی که هم‌زمان ادغام می‌شود
DO $$
DECLARE pid_c integer; v text;
BEGIN
  IF to_regnamespace('md_cc') IS NULL THEN RETURN; END IF;
  PERFORM public.md_cc_open('m'); pid_c := public.md_cc_open('c');
  PERFORM 1 FROM md_cc.dblink('m', $q$SELECT parties.merge_parties('25a00000-0000-7000-8000-00000000a6a1','25a00000-0000-7000-8000-00000000a6a4','بازاریاب تکراری',NULL)::text$q$) AS x(v text);
  PERFORM md_cc.dblink_send_query('c', $q$INSERT INTO parties.party_role (tenant_id, party_id, role, default_agent_party_id)
     VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a101','other','25a00000-0000-7000-8000-00000000a6a4') RETURNING id::text$q$);
  PERFORM public.md_assert(public.md_cc_blocked(pid_c), 'RV-MD-05 role with an agent waits for an in-flight merge of the agent');
  PERFORM md_cc.dblink_exec('m', 'COMMIT');
  v := public.md_cc_finish('c');
  PERFORM public.md_assert(v LIKE 'ERROR: HK_PARTY_MERGED:%', 'RV-MD-05 role insert sees the merged agent: ' || coalesce(v, '-'));
  PERFORM md_cc.dblink_exec('c', 'ROLLBACK');
  PERFORM md_cc.dblink_disconnect('m'); PERFORM md_cc.dblink_disconnect('c');
END $$;

-- RV-MD-14: نقش شرکت دو هم‌زمان با محدود کردن شخص به شرکت یک
DO $$
DECLARE pid_n integer; v text;
BEGIN
  IF to_regnamespace('md_cc') IS NULL THEN RETURN; END IF;
  PERFORM public.md_cc_open('r'); pid_n := public.md_cc_open('n');
  PERFORM 1 FROM md_cc.dblink('r', $q$INSERT INTO parties.party_role (tenant_id, party_id, role, company_id)
     VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a6a3','supplier','25a00000-0000-7000-8000-0000000000c2') RETURNING id::text$q$) AS x(v text);
  PERFORM md_cc.dblink_send_query('n', $q$UPDATE parties.party SET company_id = '25a00000-0000-7000-8000-0000000000c1'
     WHERE id = '25a00000-0000-7000-8000-00000000a6a3' RETURNING id::text$q$);
  PERFORM public.md_assert(public.md_cc_blocked(pid_n), 'RV-MD-14 scope narrowing waits for an in-flight company role');
  PERFORM md_cc.dblink_exec('r', 'COMMIT');
  v := public.md_cc_finish('n');
  PERFORM public.md_assert(v LIKE 'ERROR: HK_PARTY_ROLE_COMPANY_SCOPE:%', 'RV-MD-14 narrowing sees the committed role and is refused: ' || coalesce(v, '-'));
  PERFORM md_cc.dblink_exec('n', 'ROLLBACK');
  PERFORM md_cc.dblink_disconnect('r'); PERFORM md_cc.dblink_disconnect('n');
END $$;

-- RV-MD-14 (ترتیب وارون): محدود کردن شخص در جریان، سپس درج نقش شرکت دیگر
DO $$
DECLARE pid_r integer; v text;
BEGIN
  IF to_regnamespace('md_cc') IS NULL THEN RETURN; END IF;
  PERFORM public.md_cc_open('n'); pid_r := public.md_cc_open('r');
  PERFORM 1 FROM md_cc.dblink('n', $q$UPDATE parties.party SET company_id = '25a00000-0000-7000-8000-0000000000c1'
     WHERE id = '25a00000-0000-7000-8000-00000000a6a1' RETURNING id::text$q$) AS x(v text);
  PERFORM md_cc.dblink_send_query('r', $q$INSERT INTO parties.party_role (tenant_id, party_id, role, company_id)
     VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000a6a1','supplier','25a00000-0000-7000-8000-0000000000c2') RETURNING id::text$q$);
  PERFORM public.md_assert(public.md_cc_blocked(pid_r), 'RV-MD-14 company role insert waits for an in-flight scope narrowing');
  PERFORM md_cc.dblink_exec('n', 'COMMIT');
  v := public.md_cc_finish('r');
  PERFORM public.md_assert(v LIKE 'ERROR: HK_PARTY_ROLE_COMPANY_SCOPE:%', 'RV-MD-14 role insert sees the committed scope and is refused: ' || coalesce(v, '-'));
  PERFORM md_cc.dblink_exec('r', 'ROLLBACK');
  PERFORM md_cc.dblink_disconnect('n'); PERFORM md_cc.dblink_disconnect('r');
END $$;

-- RV-MD-17: بارکد ۱۳ رقمی با پیشوند ۲۷ هم‌زمان با فعال کردن الگوی ترازوی ۲۷
DO $$
DECLARE pid_p integer; v text; v_code text := '271234567890' || ref.gtin_check_digit('271234567890')::text;
BEGIN
  IF to_regnamespace('md_cc') IS NULL THEN RETURN; END IF;
  PERFORM public.md_cc_open('b'); pid_p := public.md_cc_open('p');
  PERFORM 1 FROM md_cc.dblink('b', format($q$INSERT INTO catalog.barcode (tenant_id, item_id, variant_id, uom_id, code, symbology, source)
     VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c101','25a00000-0000-7000-8000-00000000c111','25a00000-0000-7000-8000-00000000c001',%L,'ean13','manufacturer') RETURNING id::text$q$, v_code)) AS x(v text);
  PERFORM md_cc.dblink_send_query('p', $q$INSERT INTO catalog.scale_barcode_pattern (tenant_id, code, name, prefix, plu_start, plu_length, value_kind, value_start, value_length, weight_uom_id)
     VALUES ('25a00000-0000-7000-8000-000000000001','W27','ترازوی ۲۷','27',3,5,'weight',8,5,'25a00000-0000-7000-8000-00000000c003') RETURNING id::text$q$);
  PERFORM public.md_assert(public.md_cc_blocked(pid_p), 'RV-MD-17 pattern activation waits for an in-flight barcode with its prefix');
  PERFORM md_cc.dblink_exec('b', 'COMMIT');
  v := public.md_cc_finish('p');
  PERFORM public.md_assert(v LIKE 'ERROR: HK_CATALOG_SCALE_PREFIX_CONFLICT:%', 'RV-MD-17 activation sees the committed barcode: ' || coalesce(v, '-'));
  PERFORM md_cc.dblink_exec('p', 'ROLLBACK');
  PERFORM md_cc.dblink_disconnect('b'); PERFORM md_cc.dblink_disconnect('p');
  PERFORM public.md_assert(NOT EXISTS (SELECT 1 FROM catalog.scale_barcode_pattern WHERE prefix = '27' AND is_active), 'RV-MD-17 no active pattern 27');
END $$;
DROP SCHEMA IF EXISTS md_cc CASCADE;

-- =====================================================================
-- بخش ۵: ثبت در کاتالوگ‌های core — T21 (فقط وقتی 10_core پیش‌تر اعمال شده: R-ORDER)
-- RV-IT-01 (R-EXPORT)، RV-IT-02 (مجوز، محافظ فیلد، قالب نقش)، RV-X1-23 (تنظیمات)، RV-IT-CUSTOM، RV-MD-09 (مشترک)
-- =====================================================================
DO $$
DECLARE v text; n int;
BEGIN
  IF to_regclass('core.export_table_registry') IS NULL THEN
    RAISE NOTICE 'SKIP T21: 10_core.sql is not applied (standalone chain 00 -> 25)';
    RETURN;
  END IF;
  SELECT string_agg(c.oid::regclass::text, ', ') INTO v
    FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
   WHERE ns.nspname IN ('parties','catalog') AND c.relkind IN ('r','p')
     AND NOT EXISTS (SELECT 1 FROM core.export_table_registry r WHERE r.schema_name = ns.nspname AND r.table_name = c.relname);
  PERFORM public.md_assert(v IS NULL, 'RV-IT-01 every parties/catalog tenant table is in core.export_table_registry; missing: ' || coalesce(v, '-'));
  PERFORM public.md_assert((SELECT count(*) FROM core.export_table_registry WHERE schema_name IN ('parties','catalog')) = 39
                           AND (SELECT pii_columns @> '{national_id}' FROM core.export_table_registry WHERE schema_name = 'parties' AND table_name = 'party')
                           AND (SELECT pii_columns @> '{sheba,card_number}' FROM core.export_table_registry WHERE schema_name = 'parties' AND table_name = 'party_bank_account'),
                           'RV-IT-01 registry rows and PII columns');
  IF to_regprocedure('core.security_lint()') IS NOT NULL THEN
    SELECT string_agg(object || '|' || problem, '; ') INTO v FROM core.security_lint()
     WHERE object LIKE 'parties.%' OR object LIKE 'catalog.%' OR object LIKE 'ref.%';
    PERFORM public.md_assert(v IS NULL, 'RV-IT-01 core.security_lint() is clean for parties/catalog/ref: ' || coalesce(v, '-'));
  END IF;
  SELECT string_agg(x, ', ') INTO v FROM unnest(ARRAY[
      'parties.party.read','parties.party.create','parties.party.update','parties.party.identity.read','parties.party.override_id',
      'parties.party.merge','parties.bank_account.read','parties.bank_account.manage','parties.bank_account.verify','parties.hold.manage',
      'parties.setup.manage','catalog.item.read','catalog.item.manage','catalog.item.delete','catalog.setup.manage','catalog.price.read',
      'catalog.price.manage','catalog.price.purchase.read','catalog.price.backdate','catalog.bom.read','catalog.bom.manage','catalog.bom.activate']) x
   WHERE NOT EXISTS (SELECT 1 FROM core.permission p WHERE p.code = x);
  PERFORM public.md_assert(v IS NULL, 'RV-IT-02 every §5-12 permission is registered; missing: ' || coalesce(v, '-'));
  PERFORM public.md_assert((SELECT count(*) FROM core.field_guard WHERE resource IN ('parties.party','parties.party_bank_account')
                              AND mask_style = 'partial_last4') = 6,
                           'RV-IT-02 national id and bank identifiers are field-guarded');
  PERFORM public.md_assert(EXISTS (SELECT 1 FROM core.role_template_permission WHERE template_code = 'accountant' AND permission_code = 'parties.party.read')
                           AND EXISTS (SELECT 1 FROM core.role_template_permission WHERE template_code = 'cashier' AND permission_code = 'catalog.price.read')
                           AND NOT EXISTS (SELECT 1 FROM core.role_template_permission WHERE template_code = 'cashier' AND permission_code = 'parties.party.identity.read')
                           AND NOT EXISTS (SELECT 1 FROM core.role_template_permission WHERE permission_code = 'catalog.price.backdate'),
                           'RV-IT-02 standard role templates carry masterdata permissions (no backdate, cashier without identity)');
  PERFORM public.md_assert((SELECT default_value = '92'::jsonb AND min_value = 80 AND max_value = 100 FROM core.setting_def WHERE key = 'parties.duplicate.threshold'),
                           'RV-X1-23 parties.duplicate.threshold is a registered setting');
  PERFORM public.md_assert(EXISTS (SELECT 1 FROM core.event_subscription WHERE event_type = 'parties.party.merged' AND subscriber = 'catalog.party_merge'),
                           'RV-MD-09 catalog subscribes to parties.party.merged');
  SELECT count(*) INTO n FROM pg_trigger WHERE tgname = 'trg_custom_fields_check' AND tgrelid IN ('parties.party'::regclass, 'catalog.item'::regclass);
  PERFORM public.md_assert(n = 2 AND (SELECT count(*) FROM core.custom_field_entity WHERE entity_type IN ('parties.party','catalog.item')) = 2,
                           'RV-IT-CUSTOM custom fields attached to party and item');
END $$;
SET ROLE hk_app;
DO $$
BEGIN
  IF to_regclass('core.custom_field_entity') IS NULL THEN RETURN; END IF;
  PERFORM set_config('app.tenant_id', '25a00000-0000-7000-8000-000000000001', true);
  PERFORM public.md_expect_error('RV-IT-CUSTOM undefined custom key on a party',
    $q$INSERT INTO parties.party (tenant_id, code, person_type, name, custom) VALUES ('25a00000-0000-7000-8000-000000000001','CF1','natural','x','{"undefined_key":1}')$q$,
    'HK_CF_UNKNOWN_FIELD');
  PERFORM public.md_expect_error('RV-IT-CUSTOM undefined custom key on an item',
    $q$UPDATE catalog.item SET custom = '{"undefined_key":1}' WHERE id = '25a00000-0000-7000-8000-00000000c104'$q$, 'HK_CF_UNKNOWN_FIELD');
END $$;
RESET ROLE;

-- =====================================================================
-- بخش ۶: مقیاس — T22 (RV-MD-12، RV-MD-13): مسیرهای داغ بر ایندکس، نه پیمایش کامل
-- مستأجر C با ۲۰ هزار شخص هم‌نام‌گونه و ۳۳۳۰ دسته (۳۰ × ۱۰ × ۱۰). معیار قطعی: شمار seq scan تراکنش روی جدول‌ها صفر است
-- و طرح v_sku پیمایش بازگشتی درخت ندارد (زمان فقط گزارش می‌شود؛ معیار زمانی در bench شبانه است).
-- =====================================================================
DO $$
DECLARE t uuid := '25c00000-0000-7000-8000-000000000001';
BEGIN
  INSERT INTO core.tenant (id, slug, display_name) VALUES (t, 'md-tenant-c', 'C');
  PERFORM set_config('app.tenant_id', t::text, true);
  INSERT INTO parties.party (tenant_id, code, person_type, name)
  SELECT t, 'B' || g, 'natural',
         (ARRAY['علی','رضا','مریم','زهرا','حسین','فاطمه','محمد','سارا'])[1 + g % 8] || ' '
         || (ARRAY['رضایی','محمدی','کریمی','حسینی','احمدی','موسوی','جعفری','قاسمی','صادقی','رحیمی'])[1 + (g / 8) % 10] || ' ' || g
    FROM generate_series(1, 20000) g;
  INSERT INTO parties.party_contact (tenant_id, party_id, kind, value)
  SELECT p.tenant_id, p.id, 'mobile', '0912' || lpad(substr(p.code, 2), 7, '0') FROM parties.party p WHERE p.tenant_id = t;
  INSERT INTO catalog.uom (tenant_id, id, code, name, dimension) VALUES (t, '25c00000-0000-7000-8000-00000000c001', 'PCS', 'عدد', 'count');
  INSERT INTO catalog.item_posting_group (tenant_id, id, code, name) VALUES (t, '25c00000-0000-7000-8000-00000000c041', 'GOODS', 'کالا');
  INSERT INTO catalog.item_category (tenant_id, id, code, name, default_posting_group_id)
  SELECT t, ('25c00000-0000-7000-8000-' || lpad(to_hex(g), 12, '0'))::uuid, 'L1-' || g, 'سطح یک ' || g,
         CASE WHEN g = 1 THEN '25c00000-0000-7000-8000-00000000c041'::uuid END
    FROM generate_series(1, 30) g;
  INSERT INTO catalog.item_category (tenant_id, id, parent_id, code, name)
  SELECT t, ('25c00000-0000-7000-8001-' || lpad(to_hex(a * 100 + b), 12, '0'))::uuid, ('25c00000-0000-7000-8000-' || lpad(to_hex(a), 12, '0'))::uuid,
         'L2-' || a || '-' || b, 'سطح دو ' || a || '-' || b
    FROM generate_series(1, 30) a, generate_series(1, 10) b;
  INSERT INTO catalog.item_category (tenant_id, id, parent_id, code, name)
  SELECT t, ('25c00000-0000-7000-8002-' || lpad(to_hex(a * 10000 + b * 100 + c), 12, '0'))::uuid,
         ('25c00000-0000-7000-8001-' || lpad(to_hex(a * 100 + b), 12, '0'))::uuid,
         'L3-' || a || '-' || b || '-' || c, 'سطح سه ' || a || '-' || b || '-' || c
    FROM generate_series(1, 30) a, generate_series(1, 10) b, generate_series(1, 10) c;
  INSERT INTO catalog.item (tenant_id, id, code, name, item_type, category_id, base_uom_id) VALUES
    (t, '25c00000-0000-7000-8000-00000000c101', 'DEEP', 'کالای عمیق', 'stock', ('25c00000-0000-7000-8002-' || lpad(to_hex(1 * 10000 + 5 * 100 + 7), 12, '0'))::uuid,
     '25c00000-0000-7000-8000-00000000c001');
  INSERT INTO catalog.item_uom (tenant_id, item_id, uom_id, factor, is_base) VALUES (t, '25c00000-0000-7000-8000-00000000c101', '25c00000-0000-7000-8000-00000000c001', 1, true);
  INSERT INTO catalog.item_variant (tenant_id, id, item_id, code, is_default) VALUES (t, '25c00000-0000-7000-8000-00000000c111', '25c00000-0000-7000-8000-00000000c101', 'DEEP', true);
END $$;
ANALYZE parties.party; ANALYZE parties.party_contact; ANALYZE catalog.item_category; ANALYZE catalog.item; ANALYZE catalog.item_variant;
SET ROLE hk_app;
DO $$
DECLARE t uuid := '25c00000-0000-7000-8000-000000000001'; v_pid uuid; s_party bigint; s_contact bigint; s_cat bigint; n int;
        v_t0 timestamptz; v_plan text; r record; a jsonb;
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  SELECT id INTO v_pid FROM parties.party WHERE tenant_id = t AND code = 'B500';
  SELECT seq_scan INTO s_party FROM pg_stat_xact_user_tables WHERE relid = 'parties.party'::regclass;
  SELECT seq_scan INTO s_contact FROM pg_stat_xact_user_tables WHERE relid = 'parties.party_contact'::regclass;
  v_t0 := clock_timestamp();
  SELECT count(*) INTO n FROM parties.find_duplicate_candidates(v_pid);
  RAISE NOTICE 'T22 find_duplicate_candidates over 20000 parties: % ms, % candidates',
    round(extract(epoch FROM clock_timestamp() - v_t0) * 1000), n;
  PERFORM public.md_assert(n = 20, 'RV-MD-12 candidates returned up to the limit');
  PERFORM public.md_assert((SELECT seq_scan FROM pg_stat_xact_user_tables WHERE relid = 'parties.party'::regclass) = s_party
                           AND (SELECT seq_scan FROM pg_stat_xact_user_tables WHERE relid = 'parties.party_contact'::regclass) = s_contact,
                           'RV-MD-12 duplicate blocking never scans the whole party table');
  SELECT * INTO r FROM parties.find_duplicate_candidates(v_pid) LIMIT 1;
  PERFORM public.md_assert(r.reasons @> ARRAY['name'] AND r.name_similarity >= 0.5, 'RV-MD-12 nearest name candidate found by KNN');
  -- RV-MD-13: v_sku و posting_attributes درخت ۳۳۳۰ دسته را نمی‌سازند
  EXECUTE $q$EXPLAIN (COSTS OFF) SELECT * FROM catalog.v_sku WHERE variant_id = '25c00000-0000-7000-8000-00000000c111'$q$ INTO v_plan;
  FOR r IN EXECUTE $q$EXPLAIN (COSTS OFF) SELECT * FROM catalog.v_sku WHERE variant_id = '25c00000-0000-7000-8000-00000000c111'$q$ LOOP
    v_plan := v_plan || E'\n' || r."QUERY PLAN";
  END LOOP;
  PERFORM public.md_assert(v_plan NOT LIKE '%Recursive Union%' AND v_plan NOT LIKE '%CTE Scan%', 'RV-MD-13 v_sku plan has no recursive tree build');
  SELECT seq_scan INTO s_cat FROM pg_stat_xact_user_tables WHERE relid = 'catalog.item_category'::regclass;
  a := catalog.posting_attributes('25c00000-0000-7000-8000-00000000c111');
  PERFORM public.md_assert(a ->> 'attr:item_posting_group' = 'GOODS', 'RV-MD-13 posting group inherited from a depth-3 ancestor');
  PERFORM public.md_assert((SELECT seq_scan FROM pg_stat_xact_user_tables WHERE relid = 'catalog.item_category'::regclass) = s_cat,
                           'RV-MD-13 posting attributes walk up by key, no category table scan');
  SELECT seq_scan INTO s_cat FROM pg_stat_xact_user_tables WHERE relid = 'catalog.item_category'::regclass;
  PERFORM public.md_assert(catalog.next_item_code(('25c00000-0000-7000-8002-' || lpad(to_hex(1 * 10000 + 5 * 100 + 7), 12, '0'))::uuid) = '00001',
                           'RV-MD-13 item code from the default series for a deep category');
  PERFORM public.md_assert((SELECT seq_scan FROM pg_stat_xact_user_tables WHERE relid = 'catalog.item_category'::regclass) = s_cat,
                           'RV-MD-13 next_item_code walks up by key, no category table scan');
  PERFORM public.md_assert(catalog.category_path(t, ('25c00000-0000-7000-8002-' || lpad(to_hex(1 * 10000 + 5 * 100 + 7), 12, '0'))::uuid)
                           = ARRAY[('25c00000-0000-7000-8000-' || lpad(to_hex(1), 12, '0'))::uuid,
                                   ('25c00000-0000-7000-8001-' || lpad(to_hex(105), 12, '0'))::uuid,
                                   ('25c00000-0000-7000-8002-' || lpad(to_hex(10507), 12, '0'))::uuid],
                           'RV-MD-13 category_path root-first');
END $$;
RESET ROLE;

-- =====================================================================
-- بخش ۷: هر قید CHECK با نام دقیقش — T23 (RV-MD-07، R-QUALITY)
-- مسیر درون‌ریزی .hkx با session_replication_role=replica اجرا می‌شود (R-IMPORT): تریگرها و FKها خاموش‌اند و CHECKها تنها
-- نگهبان داده‌اند. پس هر CHECK جداگانه روی یک ردیف موجود با مقدار ناقض آزموده می‌شود و خطا باید همان نام قید را داشته
-- باشد. فهرست زیر همهٔ CHECKهای دو اسکیما را پوشش می‌دهد (شمارش در پایان)؛ fixtureهای لازم در همین تراکنش ساخته و
-- با ROLLBACK برگردانده می‌شوند.
-- =====================================================================
BEGIN;
SELECT set_config('session_replication_role', 'replica', true) AS srr \gset
SELECT set_config('app.tenant_id', '25a00000-0000-7000-8000-000000000001', true) AS tid \gset
INSERT INTO parties.party_relation (tenant_id, party_id, related_party_id, relation) VALUES
  ('25a00000-0000-7000-8000-000000000001', '25a00000-0000-7000-8000-00000000a101', '25a00000-0000-7000-8000-00000000a102', 'director');
INSERT INTO parties.duplicate_dismissal (tenant_id, party_a_id, party_b_id) VALUES
  ('25a00000-0000-7000-8000-000000000001', '25a00000-0000-7000-8000-00000000a101', '25a00000-0000-7000-8000-00000000a102');
INSERT INTO catalog.item_image (tenant_id, item_id, attachment_id) VALUES
  ('25a00000-0000-7000-8000-000000000001', '25a00000-0000-7000-8000-00000000c101', '25a00000-0000-7000-8000-0000000000f1');
INSERT INTO catalog.brand (tenant_id, code, name) VALUES ('25a00000-0000-7000-8000-000000000001', 'BR1', 'برند');
INSERT INTO catalog.item_legacy_code (tenant_id, item_id, source_system, legacy_code) VALUES
  ('25a00000-0000-7000-8000-000000000001', '25a00000-0000-7000-8000-00000000c101', 'holoo', '1001');
INSERT INTO parties.payment_term_line (tenant_id, payment_term_id, line_no, portion_percent, due_basis, due_days, early_discount_percent, early_discount_days)
  SELECT tenant_id, payment_term_id, 59, 1, 'document_date', 10, 2, 5 FROM parties.payment_term_line LIMIT 1;
UPDATE catalog.price_list SET valid_from = catalog.tenant_today('25a00000-0000-7000-8000-000000000001') - 400
 WHERE id = '25a00000-0000-7000-8000-00000000c333';
DO $$
DECLARE r record; v_con text; v_msg text; v_n int := 0; v_ctid tid; v_fail text[] := '{}';
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('parties.party_group', 'code = ''!!''', 'true', 'party_group_code_check'),
    ('parties.party_group', 'name = ''علي''', 'true', 'party_group_name_check'),
    ('parties.party_group', 'role = ''zz_bad''', 'true', 'party_group_role_check'),
    ('parties.payment_term', 'code = ''!!''', 'true', 'payment_term_code_check'),
    ('parties.payment_term', 'name = ''علي''', 'true', 'payment_term_name_check'),
    ('parties.payment_term_line', 'due_basis = ''zz_bad''', 'true', 'payment_term_line_due_basis_check'),
    ('parties.payment_term_line', 'due_days = 3651', 'true', 'payment_term_line_due_days_check'),
    ('parties.payment_term_line', 'early_discount_days = -1', 'early_discount_percent IS NOT NULL', 'payment_term_line_early_discount_days_check'),
    ('parties.payment_term_line', 'early_discount_percent = -1', 'early_discount_days IS NOT NULL', 'payment_term_line_early_discount_percent_check'),
    ('parties.payment_term_line', 'line_no = 61', 'true', 'payment_term_line_line_no_check'),
    ('parties.payment_term_line', 'portion_percent = 101', 'true', 'payment_term_line_portion_percent_check'),
    ('parties.party', 'birth_cert_issue_place = ''علي''', 'person_type = ''natural''', 'party_birth_cert_issue_place_check'),
    ('parties.party', 'birth_cert_no = ''!!''', 'person_type = ''natural''', 'party_birth_cert_no_check'),
    ('parties.party', 'birth_date = ''1800-01-01''', 'person_type = ''natural'' AND birth_cert_issue_date IS NULL', 'party_birth_date_check'),
    ('parties.party', 'code = ''!!''', 'true', 'party_code_check'),
    ('parties.party', 'custom = ''[]''', 'true', 'party_custom_check'),
    ('parties.party', 'economic_code = ''123''', 'NOT is_anonymous', 'party_economic_code_check'),
    ('parties.party', 'father_name = ''علي''', 'person_type = ''natural''', 'party_father_name_check'),
    ('parties.party', 'first_name = ''علي''', 'person_type = ''natural''', 'party_first_name_check'),
    ('parties.party', 'gender = ''zz_bad''', 'person_type = ''natural''', 'party_gender_check'),
    ('parties.party', 'last_name = ''علي''', 'person_type = ''natural''', 'party_last_name_check'),
    ('parties.party', 'name = ''علي''', 'true', 'party_name_check'),
    ('parties.party', 'national_id_status = ''zz_bad''', 'national_id IS NOT NULL AND national_id_status = ''valid''', 'party_national_id_status_check'),
    ('parties.party', 'notes = ''علي''', 'true', 'party_notes_check'),
    ('parties.party', 'passport_no = ''!!'', passport_country = ''TR''', 'passport_no IS NULL', 'party_passport_no_check'),
    ('parties.party', 'person_type = ''zz_bad''', 'national_id IS NULL AND registration_no IS NULL AND first_name IS NULL AND last_name IS NULL AND birth_date IS NULL AND birth_cert_no IS NULL AND NOT is_anonymous AND status = ''active''', 'party_person_type_check'),
    ('parties.party', 'registration_no = ''!!''', 'person_type = ''legal''', 'party_registration_no_check'),
    ('parties.party', 'status = ''zz_bad''', 'status = ''active''', 'party_status_check'),
    ('parties.party', 'trade_name = ''علي''', 'true', 'party_trade_name_check'),
    ('parties.party_role', 'credit_control = ''zz_bad''', 'credit_limit IS NOT NULL', 'party_role_credit_control_check'),
    ('parties.party_role', 'credit_limit = -1', 'credit_limit IS NOT NULL', 'party_role_credit_limit_check'),
    ('parties.party_role', 'role = ''zz_bad''', 'credit_limit IS NULL AND default_agent_party_id IS NULL AND bank_code IS NULL', 'party_role_role_check'),
    ('parties.party_contact', 'job_title = ''علي''', 'true', 'party_contact_job_title_check'),
    ('parties.party_contact', 'kind = ''zz_bad''', 'true', 'party_contact_kind_check'),
    ('parties.party_contact', 'label = ''علي''', 'true', 'party_contact_label_check'),
    ('parties.party_contact', 'person_name = ''علي''', 'true', 'party_contact_person_name_check'),
    ('parties.party_contact', 'kind = ''other'', value = repeat(''x'', 255)', 'true', 'party_contact_value_check'),
    ('parties.party_address', 'address_line = ''علي''', 'true', 'party_address_address_line_check'),
    ('parties.party_address', 'city_name = ''علي''', 'true', 'party_address_city_name_check'),
    ('parties.party_address', 'district = ''علي''', 'true', 'party_address_district_check'),
    ('parties.party_address', 'floor = ''xxxxxxxxxxx''', 'true', 'party_address_floor_check'),
    ('parties.party_address', 'label = ''علي''', 'true', 'party_address_label_check'),
    ('parties.party_address', 'latitude = 91, longitude = 0', 'true', 'party_address_latitude_check'),
    ('parties.party_address', 'latitude = 0, longitude = 181', 'true', 'party_address_longitude_check'),
    ('parties.party_address', 'moadian_branch_code = ''!!''', 'true', 'party_address_moadian_branch_code_check'),
    ('parties.party_address', 'phone = ''!!''', 'true', 'party_address_phone_check'),
    ('parties.party_address', 'plate = ''xxxxxxxxxxxxxxxxxxxxx''', 'true', 'party_address_plate_check'),
    ('parties.party_address', 'unit = ''xxxxxxxxxxxxxxxxxxxxx''', 'true', 'party_address_unit_check'),
    ('parties.party_bank_account', 'account_number = ''!!''', 'true', 'party_bank_account_account_number_check'),
    ('parties.party_bank_account', 'branch_code = ''!!''', 'true', 'party_bank_account_branch_code_check'),
    ('parties.party_bank_account', 'branch_name = ''علي''', 'true', 'party_bank_account_branch_name_check'),
    ('parties.party_bank_account', 'card_number = ''1111111111111111''', 'true', 'party_bank_account_card_number_check'),
    ('parties.party_bank_account', 'holder_name = ''علي''', 'true', 'party_bank_account_holder_name_check'),
    ('parties.party_bank_account', 'sheba = ''IR000000000000000000000000''', 'true', 'party_bank_account_sheba_check'),
    ('parties.party_relation', 'note = ''علي''', 'true', 'party_relation_note_check'),
    ('parties.party_relation', 'relation = ''zz_bad''', 'true', 'party_relation_relation_check'),
    ('parties.party_relation', 'relation = ''shareholder'', share_percent = 101', 'true', 'party_relation_share_percent_check'),
    ('parties.party_hold', 'reason = ''علي''', 'true', 'party_hold_reason_check'),
    ('parties.party_hold', 'release_note = ''علي''', 'true', 'party_hold_release_note_check'),
    ('parties.party_hold', 'scope = ''zz_bad''', 'true', 'party_hold_scope_check'),
    ('parties.party_hold', 'source = ''zz_bad''', 'true', 'party_hold_source_check'),
    ('parties.party_legacy_code', 'legacy_code = ''علي''', 'true', 'party_legacy_code_legacy_code_check'),
    ('parties.party_legacy_code', 'legacy_kind = ''xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx''', 'true', 'party_legacy_code_legacy_kind_check'),
    ('parties.party_legacy_code', 'source_scope = ''xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx''', 'true', 'party_legacy_code_source_scope_check'),
    ('parties.party_legacy_code', 'source_system = ''!!''', 'true', 'party_legacy_code_source_system_check'),
    ('parties.party_merge', 'participants = ''{}''', 'true', 'party_merge_participants_check'),
    ('parties.duplicate_dismissal', 'reason = ''علي''', 'true', 'duplicate_dismissal_reason_check'),
    ('parties.party_taxpayer_inquiry', 'economic_code = ''123''', 'true', 'party_taxpayer_inquiry_economic_code_check'),
    ('parties.party_taxpayer_inquiry', 'outcome = ''zz_bad''', 'true', 'party_taxpayer_inquiry_outcome_check'),
    ('parties.code_series', 'next_value = 1000000000000', 'true', 'code_series_next_value_check'),
    ('parties.code_series', 'pad_width = 13', 'true', 'code_series_pad_width_check'),
    ('parties.code_series', 'prefix = ''!!''', 'true', 'code_series_prefix_check'),
    ('parties.code_series', 'role = ''zz_bad''', 'true', 'code_series_role_check'),
    ('catalog.uom', 'code = ''!!''', 'true', 'uom_code_check'),
    ('catalog.uom', 'dimension = ''zz_bad''', 'true', 'uom_dimension_check'),
    ('catalog.uom', 'dimension_factor = -1', 'true', 'uom_dimension_factor_check'),
    ('catalog.uom', 'name = ''علي''', 'true', 'uom_name_check'),
    ('catalog.uom', 'qty_decimals = 7', 'true', 'uom_qty_decimals_check'),
    ('catalog.uom', 'symbol = ''xxxxxxxxxxx''', 'true', 'uom_symbol_check'),
    ('catalog.item_posting_group', 'code = ''!!''', 'true', 'item_posting_group_code_check'),
    ('catalog.item_posting_group', 'name = ''علي''', 'true', 'item_posting_group_name_check'),
    ('catalog.attribute', 'code = ''!!''', 'true', 'attribute_code_check'),
    ('catalog.attribute', 'name = ''علي''', 'true', 'attribute_name_check'),
    ('catalog.attribute', 'unit_label = ''xxxxxxxxxxxxxxxxxxxxx''', 'true', 'attribute_unit_label_check'),
    ('catalog.attribute', 'value_type = ''zz_bad''', 'NOT can_be_variant_axis', 'attribute_value_type_check'),
    ('catalog.attribute_value', 'code = ''!!''', 'true', 'attribute_value_code_check'),
    ('catalog.attribute_value', 'name = ''علي''', 'true', 'attribute_value_name_check'),
    ('catalog.attribute_value', 'swatch_hex = ''!!''', 'true', 'attribute_value_swatch_hex_check'),
    ('catalog.attribute_set', 'code = ''!!''', 'true', 'attribute_set_code_check'),
    ('catalog.attribute_set', 'name = ''علي''', 'true', 'attribute_set_name_check'),
    ('catalog.attribute_set_member', 'axis_position = 4', 'usage = ''variant_axis''', 'attribute_set_member_axis_position_check'),
    ('catalog.attribute_set_member', 'usage = ''zz_bad''', 'usage = ''descriptive''', 'attribute_set_member_usage_check'),
    ('catalog.brand', 'code = ''!!''', 'true', 'brand_code_check'),
    ('catalog.brand', 'name = ''علي''', 'true', 'brand_name_check'),
    ('catalog.item_category', 'code = ''!!''', 'true', 'item_category_code_check'),
    ('catalog.item_category', 'default_tax_category_code = ''!!''', 'true', 'item_category_default_tax_category_code_check'),
    ('catalog.item_category', 'name = ''علي''', 'true', 'item_category_name_check'),
    ('catalog.item', 'code = ''!!''', 'true', 'item_code_check'),
    ('catalog.item', 'custom = ''[]''', 'true', 'item_custom_check'),
    ('catalog.item', 'description = ''علي''', 'true', 'item_description_check'),
    ('catalog.item', 'item_type = ''zz_bad''', 'true', 'item_item_type_check'),
    ('catalog.item', 'moadian_title = ''علي''', 'true', 'item_moadian_title_check'),
    ('catalog.item', 'name = ''علي''', 'true', 'item_name_check'),
    ('catalog.item', 'other_tax_category_code = ''!!''', 'true', 'item_other_tax_category_code_check'),
    ('catalog.item', 'shelf_life_days = 36501', 'track_expiry', 'item_shelf_life_days_check'),
    ('catalog.item', 'short_name = ''علي''', 'true', 'item_short_name_check'),
    ('catalog.item', 'sstid = ''!!''', 'sstid IS NOT NULL', 'item_sstid_check'),
    ('catalog.item', 'sstid_kind = ''zz_bad''', 'sstid IS NOT NULL', 'item_sstid_kind_check'),
    ('catalog.item', 'status = ''zz_bad''', 'true', 'item_status_check'),
    ('catalog.item', 'tax_category_code = ''!!''', 'true', 'item_tax_category_code_check'),
    ('catalog.item', 'warranty_days = 36501', 'true', 'item_warranty_days_check'),
    ('catalog.item_variant', 'code = ''!!''', 'true', 'item_variant_code_check'),
    ('catalog.item_variant', 'name_suffix = ''علي''', 'true', 'item_variant_name_suffix_check'),
    ('catalog.item_variant', 'plu_code = ''!!''', 'true', 'item_variant_plu_code_check'),
    ('catalog.item_variant', 'sstid = ''!!'', sstid_kind = ''general''', 'true', 'item_variant_sstid_check'),
    ('catalog.item_variant', 'sstid = ''2710000138624'', sstid_kind = ''zz_bad''', 'true', 'item_variant_sstid_kind_check'),
    ('catalog.item_variant', 'status = ''zz_bad''', 'true', 'item_variant_status_check'),
    ('catalog.item_uom', 'factor = -1', 'NOT is_base', 'item_uom_factor_check'),
    ('catalog.item_attribute_value', 'value_id = NULL, value_text = ''علي''', 'value_id IS NOT NULL', 'item_attribute_value_value_text_check'),
    ('catalog.barcode', 'code = ''a b''', 'true', 'barcode_code_check'),
    ('catalog.barcode', 'source = ''zz_bad''', 'true', 'barcode_source_check'),
    ('catalog.barcode', 'symbology = ''zz_bad''', 'true', 'barcode_symbology_check'),
    ('catalog.barcode_counter', 'next_value = 10000000001', 'true', 'barcode_counter_next_value_check'),
    ('catalog.barcode_counter', 'prefix = ''05''', 'true', 'barcode_counter_prefix_check'),
    ('catalog.scale_barcode_pattern', 'code = ''!!''', 'true', 'scale_barcode_pattern_code_check'),
    ('catalog.scale_barcode_pattern', 'name = ''علي''', 'true', 'scale_barcode_pattern_name_check'),
    ('catalog.scale_barcode_pattern', 'plu_length = 7', 'true', 'scale_barcode_pattern_plu_length_check'),
    ('catalog.scale_barcode_pattern', 'prefix = ''!!''', 'true', 'scale_barcode_pattern_prefix_check'),
    ('catalog.scale_barcode_pattern', 'value_decimals = 5', 'true', 'scale_barcode_pattern_value_decimals_check'),
    ('catalog.scale_barcode_pattern', 'value_kind = ''zz_bad''', 'true', 'scale_barcode_pattern_value_kind_check'),
    ('catalog.scale_barcode_pattern', 'value_length = 8', 'true', 'scale_barcode_pattern_value_length_check'),
    ('catalog.price_list', 'base_adjust_percent = 10001', 'base_price_list_id IS NOT NULL', 'price_list_base_adjust_percent_check'),
    ('catalog.price_list', 'code = ''!!''', 'true', 'price_list_code_check'),
    ('catalog.price_list', 'kind = ''zz_bad''', 'true', 'price_list_kind_check'),
    ('catalog.price_list', 'name = ''علي''', 'true', 'price_list_name_check'),
    ('catalog.price_list', 'price_precision = 5', 'true', 'price_list_price_precision_check'),
    ('catalog.price_list', 'rounding_increment = -1', 'rounding_mode IS NOT NULL', 'price_list_rounding_increment_check'),
    ('catalog.price_list', 'rounding_mode = ''zz_bad''', 'rounding_increment IS NOT NULL', 'price_list_rounding_mode_check'),
    ('catalog.price_list_item', 'min_qty = -1', 'true', 'price_list_item_min_qty_check'),
    ('catalog.price_list_item', 'price = -1', 'true', 'price_list_item_price_check'),
    ('catalog.price_list_assignment', 'channel = ''zz_bad''', 'true', 'price_list_assignment_channel_check'),
    ('catalog.price_list_assignment', 'priority = 1001', 'true', 'price_list_assignment_priority_check'),
    ('catalog.item_supplier', 'lead_time_days = 3651', 'true', 'item_supplier_lead_time_days_check'),
    ('catalog.item_supplier', 'min_order_qty = -1', 'true', 'item_supplier_min_order_qty_check'),
    ('catalog.item_supplier', 'supplier_item_code = ''علي''', 'true', 'item_supplier_supplier_item_code_check'),
    ('catalog.item_supplier', 'supplier_item_name = ''علي''', 'true', 'item_supplier_supplier_item_name_check'),
    ('catalog.item_image', 'alt_text = ''علي''', 'true', 'item_image_alt_text_check'),
    ('catalog.item_image', 'position = 101', 'true', 'item_image_position_check'),
    ('catalog.item_legacy_code', 'legacy_code = ''علي''', 'true', 'item_legacy_code_legacy_code_check'),
    ('catalog.item_legacy_code', 'source_scope = ''xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx''', 'true', 'item_legacy_code_source_scope_check'),
    ('catalog.item_legacy_code', 'source_system = ''!!''', 'true', 'item_legacy_code_source_system_check'),
    ('catalog.code_series', 'next_value = 1000000000000', 'true', 'code_series_next_value_check'),
    ('catalog.code_series', 'pad_width = 13', 'true', 'code_series_pad_width_check'),
    ('catalog.code_series', 'prefix = ''!!''', 'true', 'code_series_prefix_check'),
    ('catalog.bom', 'kind = ''zz_bad''', 'true', 'bom_kind_check'),
    ('catalog.bom', 'note = ''علي''', 'true', 'bom_note_check'),
    ('catalog.bom', 'status = ''zz_bad''', 'status = ''active''', 'bom_status_check'),
    ('catalog.bom', 'version_no = 0', 'true', 'bom_version_no_check'),
    ('catalog.bom', 'yield_qty = -1', 'true', 'bom_yield_qty_check'),
    ('catalog.bom_line', 'line_no = 501', 'true', 'bom_line_line_no_check'),
    ('catalog.bom_line', 'note = ''علي''', 'true', 'bom_line_note_check'),
    ('catalog.bom_line', 'qty = -1', 'true', 'bom_line_qty_check'),
    ('catalog.bom_line', 'waste_percent = -1', 'true', 'bom_line_waste_percent_check'),
    ('parties.party_merge', 'reason = ''abc''', 'true', 'party_merge_reason_check'),
    ('parties.payment_term_line', 'early_discount_percent = 1', 'early_discount_days IS NULL', 'payment_term_line_check'),
    ('parties.payment_term_line', 'early_discount_percent = 1, early_discount_days = due_days + 1', 'due_days < 3650', 'payment_term_line_check1'),
    ('parties.party', 'economic_code = ''14003778990''', 'is_anonymous', 'party_anonymous'),
    ('parties.party', 'birth_date = ''2000-01-01'', birth_cert_issue_date = ''1999-01-01''', 'person_type = ''natural''', 'party_birth_cert_dates'),
    ('parties.party', 'birth_cert_no = ''123''', 'person_type = ''foreign_natural''', 'party_birth_cert_iranian'),
    ('parties.party', 'registration_no = ''123''', 'person_type = ''natural''', 'party_legal_fields'),
    ('parties.party', 'status = ''merged''', 'status = ''active''', 'party_merge_cols'),
    ('parties.party', 'status = ''merged'', merged_into_id = id, merged_at = now()', 'status = ''active''', 'party_merge_self'),
    ('parties.party', 'national_id_override_reason = ''دلیل اضافی''', 'national_id_status = ''valid''', 'party_national_id_override'),
    ('parties.party', 'national_id_status = NULL', 'national_id IS NOT NULL', 'party_national_id_presence'),
    ('parties.party', 'national_id = ''0013542418''', 'national_id_status = ''valid'' AND person_type = ''natural''', 'party_national_id_valid'),
    ('parties.party', 'first_name = ''علی''', 'person_type = ''legal''', 'party_natural_fields'),
    ('parties.party', 'passport_no = ''P1234567''', 'passport_no IS NULL', 'party_passport_pair'),
    ('parties.party_role', 'default_agent_party_id = party_id', 'role = ''customer''', 'party_role_agent'),
    ('parties.party_role', 'bank_code = ''melli''', 'role <> ''bank''', 'party_role_bank_code'),
    ('parties.party_role', 'credit_control = ''block'', credit_limit = NULL, credit_currency = NULL', 'true', 'party_role_credit_control'),
    ('parties.party_role', 'credit_currency = NULL', 'credit_limit IS NOT NULL', 'party_role_credit_pair'),
    ('parties.party_role', 'role = ''employee''', 'credit_limit IS NOT NULL AND default_agent_party_id IS NULL', 'party_role_credit_roles'),
    ('parties.party_contact', 'kind = ''email'', value = ''BAD''', 'true', 'contact_email_format'),
    ('parties.party_contact', 'kind = ''mobile'', value = ''123''', 'true', 'contact_mobile_format'),
    ('parties.party_contact', 'kind = ''phone'', value = ''123''', 'true', 'contact_phone_format'),
    ('parties.party_contact', 'kind = ''website'', value = ''ftp://x''', 'true', 'contact_website_format'),
    ('parties.party_address', 'province_code = NULL', 'city_code IS NOT NULL', 'address_city_needs_province'),
    ('parties.party_address', 'latitude = 1', 'longitude IS NULL', 'address_geo_pair'),
    ('parties.party_address', 'country_code = ''TR''', 'province_code IS NOT NULL', 'address_iran_divisions'),
    ('parties.party_address', 'postal_code = ''123''', 'country_code = ''IR''', 'address_postal_iran'),
    ('parties.party_address', 'postal_code = ''!!''', 'country_code <> ''IR''', 'address_postal_other'),
    ('parties.party_bank_account', 'sheba = NULL, card_number = NULL, account_number = NULL', 'true', 'bank_account_identifier'),
    ('parties.party_bank_account', 'verified_at = now()', 'verified_at IS NULL', 'bank_account_verification'),
    ('parties.party_relation', 'related_party_id = party_id', 'true', 'party_relation_check'),
    ('parties.party_relation', 'share_percent = 10', 'relation <> ''shareholder''', 'party_relation_check1'),
    ('parties.party_relation', 'valid_from = ''2020-01-02'', valid_to = ''2020-01-01''', 'true', 'party_relation_check2'),
    ('parties.party_hold', 'released_at = placed_at - interval ''1 day'', release_note = ''تسویه شد''', 'released_at IS NULL', 'party_hold_check'),
    ('parties.party_hold', 'released_by = uuidv7()', 'released_at IS NULL', 'party_hold_check1'),
    ('parties.party_merge', 'loser_party_id = winner_party_id', 'true', 'party_merge_check'),
    ('parties.duplicate_dismissal', 'party_a_id = party_b_id', 'true', 'duplicate_dismissal_check'),
    ('parties.code_series', 'role = NULL', 'group_id IS NOT NULL', 'code_series_check'),
    ('catalog.uom', 'dimension = ''other''', 'dimension_factor IS NOT NULL', 'uom_check'),
    ('catalog.attribute', 'value_type = ''text''', 'can_be_variant_axis', 'attribute_check'),
    ('catalog.attribute_set', 'source_pack_version = NULL', 'source_pack IS NOT NULL', 'attribute_set_check'),
    ('catalog.attribute_set_member', 'axis_position = NULL', 'usage = ''variant_axis''', 'attribute_set_member_check'),
    ('catalog.item_category', 'parent_id = id', 'true', 'item_category_check'),
    ('catalog.item', 'variant_axis2_id = variant_axis1_id', 'variant_axis2_id IS NOT NULL', 'item_axes_distinct'),
    ('catalog.item', 'has_variants = false', 'has_variants', 'item_axes_shape'),
    ('catalog.item', 'track_batch = false', 'track_expiry', 'item_expiry_needs_batch'),
    ('catalog.item', 'track_expiry = false', 'shelf_life_days IS NOT NULL', 'item_shelf_life_needs_expiry'),
    ('catalog.item', 'sstid_kind = NULL', 'sstid IS NOT NULL', 'item_sstid_pair'),
    ('catalog.item', 'item_type = ''service''', 'track_serial OR track_batch', 'item_tracking_stock_only'),
    ('catalog.item', 'warranty_days = NULL', 'warranty_provider_party_id IS NOT NULL', 'item_warranty_provider'),
    ('catalog.item_variant', 'axis1_value_id = NULL', 'axis2_value_id IS NOT NULL', 'variant_axes_shape'),
    ('catalog.item_variant', 'axis1_value_id = ''25a00000-0000-7000-8000-00000000c021''', 'is_default', 'variant_default_no_axes'),
    ('catalog.item_variant', 'sstid = ''2710000138624''', 'sstid IS NULL', 'variant_sstid_pair'),
    ('catalog.item_uom', 'factor = 2', 'is_base', 'item_uom_base_factor'),
    ('catalog.item_uom', 'is_sales_default = true, allow_sales = false', 'true', 'item_uom_check'),
    ('catalog.item_uom', 'is_purchase_default = true, allow_purchase = false', 'true', 'item_uom_check1'),
    ('catalog.item_attribute_value', 'value_text = ''x''', 'value_id IS NOT NULL', 'item_attribute_value_check'),
    ('catalog.barcode', 'code = ''5901234123458''', 'symbology = ''ean13''', 'barcode_gtin_check_digit'),
    ('catalog.barcode', 'code = ''96385074''', 'symbology = ''ean13''', 'barcode_gtin_shape'),
    ('catalog.barcode', 'source = ''internal''', 'symbology = ''ean13'' AND code !~ ''^04''', 'barcode_internal_rcn'),
    ('catalog.scale_barcode_pattern', 'value_check_position = 4', 'plu_start = 3 AND plu_length = 5', 'scale_check_position'),
    ('catalog.scale_barcode_pattern', 'value_kind = ''price'', weight_uom_id = NULL, price_currency = ''USD'', price_amount_unit = ''IRT''', 'true', 'scale_irr_units'),
    ('catalog.scale_barcode_pattern', 'plu_start = 2', 'plu_start = 3 AND value_start >= 8', 'scale_plu_range'),
    ('catalog.scale_barcode_pattern', 'price_currency = ''IRR''', 'value_kind = ''weight''', 'scale_price_unit'),
    ('catalog.scale_barcode_pattern', 'value_start = 5', 'plu_start = 3 AND plu_length = 5', 'scale_ranges_disjoint'),
    ('catalog.scale_barcode_pattern', 'value_start = 9', 'value_length = 5', 'scale_value_range'),
    ('catalog.scale_barcode_pattern', 'weight_uom_id = NULL', 'value_kind = ''weight''', 'scale_weight_uom'),
    ('catalog.price_list', 'base_adjust_percent = 5', 'base_price_list_id IS NULL', 'price_list_check'),
    ('catalog.price_list', 'rounding_mode = NULL', 'rounding_increment IS NOT NULL', 'price_list_check1'),
    ('catalog.price_list', 'base_price_list_id = id, base_adjust_percent = 1', 'base_price_list_id IS NULL', 'price_list_check2'),
    ('catalog.price_list', 'valid_from = ''2020-01-02'', valid_to = ''2020-01-01''', 'true', 'price_list_check3'),
    ('catalog.price_list_item', 'valid_to = valid_from - 1', 'true', 'price_list_item_check'),
    ('catalog.price_list_assignment', 'party_id = ''25a00000-0000-7000-8000-00000000a101''', 'party_group_id IS NOT NULL', 'price_list_assignment_check'),
    ('catalog.price_list_assignment', 'party_id = NULL, party_group_id = NULL, branch_id = NULL, company_id = NULL, channel = NULL', 'true', 'price_list_assignment_check1'),
    ('catalog.price_list_assignment', 'valid_from = ''2020-01-02'', valid_to = ''2020-01-01''', 'true', 'price_list_assignment_check2'),
    ('catalog.bom', 'status = ''active'', valid_from = NULL', 'status = ''draft''', 'bom_check'),
    ('catalog.bom', 'status = ''archived''', 'status = ''active''', 'bom_check1'),
    ('catalog.bom', 'valid_to = ''2020-01-01''', 'valid_from > ''2020-01-01''', 'bom_check2')
  ) AS v(tbl, set_clause, where_clause, con) LOOP
    v_ctid := NULL;
    EXECUTE format('SELECT ctid FROM %s WHERE tenant_id = %L AND (%s) LIMIT 1', r.tbl, '25a00000-0000-7000-8000-000000000001', r.where_clause)
      INTO v_ctid;
    IF v_ctid IS NULL THEN
      v_fail := v_fail || format('%s %s: no fixture row matches %s', r.tbl, r.con, r.where_clause);
      CONTINUE;
    END IF;
    v_con := NULL; v_msg := NULL;
    BEGIN
      EXECUTE format('UPDATE %s SET %s WHERE ctid = %L', r.tbl, r.set_clause, v_ctid);
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME, v_msg = MESSAGE_TEXT;
    END;
    IF v_con IS DISTINCT FROM r.con THEN
      v_fail := v_fail || format('%s %s: got %s (%s)', r.tbl, r.con, coalesce(v_con, 'no error'), coalesce(v_msg, '-'));
      CONTINUE;
    END IF;
    v_n := v_n + 1;
  END LOOP;
  IF cardinality(v_fail) > 0 THEN
    RAISE EXCEPTION 'TEST FAILED [T23 CHECK by name]: %', array_to_string(v_fail, E'\n  ');
  END IF;
  PERFORM public.md_assert(v_n = (SELECT count(*) FROM pg_constraint
                                    WHERE connamespace IN ('parties'::regnamespace, 'catalog'::regnamespace) AND contype = 'c'),
                           'T23 every CHECK of parties and catalog is exercised by name (' || v_n || ')');
END $$;
-- ایندکس‌های یکتای جزئی که مسیر hk_app آن‌ها را جدا نمی‌آزماید (یکتایی در مسیر درون‌ریزی هم برقرار است)
DO $$
DECLARE r record; v_con text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ($q$INSERT INTO catalog.attribute (tenant_id, id, code, name, value_type, can_be_variant_axis) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c015','width','عرض','option',true);
        INSERT INTO catalog.attribute_set_member (tenant_id, attribute_set_id, attribute_id, usage, axis_position) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c031','25a00000-0000-7000-8000-00000000c015','variant_axis',1)$q$,
     'attribute_set_axis_position'),
    ($q$INSERT INTO catalog.item_image (tenant_id, item_id, attachment_id, is_primary) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c104','25a00000-0000-7000-8000-0000000000f2',true),
        ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c104','25a00000-0000-7000-8000-0000000000f3',true)$q$,
     'item_image_one_primary'),
    ($q$INSERT INTO catalog.item_supplier (tenant_id, item_id, supplier_party_id, is_preferred) VALUES ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c103','25a00000-0000-7000-8000-00000000a101',true),
        ('25a00000-0000-7000-8000-000000000001','25a00000-0000-7000-8000-00000000c103','25a00000-0000-7000-8000-00000000a113',true)$q$,
     'item_supplier_one_preferred'),
    ($q$UPDATE catalog.item_uom SET is_sales_default = true WHERE item_id = '25a00000-0000-7000-8000-00000000c101'$q$, 'item_uom_one_sales_default'),
    ($q$UPDATE catalog.item_uom SET is_purchase_default = true WHERE item_id = '25a00000-0000-7000-8000-00000000c101'$q$, 'item_uom_one_purchase_default')
  ) AS v(stmt, con) LOOP
    v_con := NULL;
    BEGIN
      EXECUTE r.stmt;
    EXCEPTION WHEN unique_violation THEN
      GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
    END;
    PERFORM public.md_assert(v_con IS NOT DISTINCT FROM r.con, 'T23 unique index ' || r.con || ' (got ' || coalesce(v_con, 'no error') || ')');
  END LOOP;
END $$;
ROLLBACK;

\echo 'ALL 25_masterdata TESTS PASSED'
