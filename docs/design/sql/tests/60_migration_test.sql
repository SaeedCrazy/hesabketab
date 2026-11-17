-- =====================================================================
-- آزمون پایگاه داده‌ای 60_migration.sql (سند: docs/design/08-migration.md §۷ و §۹)
--
-- اجرا (از ریشهٔ مخزن؛ پایگاه دادهٔ تازه با UTF8):
--   export PGPASSWORD=postgres
--   psql -h localhost -p 5433 -U postgres -d postgres -c "DROP DATABASE IF EXISTS ds_migration"
--   psql -h localhost -p 5433 -U postgres -d postgres -c "CREATE DATABASE ds_migration ENCODING 'UTF8' TEMPLATE template0 LC_COLLATE 'C' LC_CTYPE 'C.UTF-8'"
--   for f in 00_foundation 10_core 20_ledger 25_masterdata 60_migration; do
--     psql -h localhost -p 5433 -U postgres -d ds_migration -v ON_ERROR_STOP=1 -q -f docs/design/sql/$f.sql; done
--   psql -h localhost -p 5433 -U postgres -d ds_migration -v ON_ERROR_STOP=1 -f docs/design/sql/tests/60_migration_test.sql
--
-- ساختار (یک نشست psql که با superuser وصل می‌شود):
--   بخش ۱ (fixture، نقش postgres): مستأجر A و B، چهار شرکت، سه کاربر و عضویت، سال مالی ۱۴۰۵ هر شرکت،
--          یک رضایت پشتیبانی، و توابع کمکی public.mg_* (همه SECURITY INVOKER؛ با نقش فراخوان اجرا می‌شوند).
--   بخش ۲ (assert، «SET ROLE hk_app»: نه مالک، NOBYPASSRLS): T01..T27 و T21b. هر DO block مستأجر و کاربر را با
--          set_config('app.tenant_id'/'app.user_id', ..., true) تنظیم می‌کند. موارد deferred با
--          SET CONSTRAINTS ... IMMEDIATE درون زیرتراکنش آزموده می‌شوند.
--   بخش ۳ (hk_readonly): T28 فقط خواندن و پنهان بودن ستون‌های راز.
--   بخش ۴ (postgres): T29 کاتالوگ پروفایل و مترادف و لایهٔ دوم تریگرها (حتی برای مالک جدول‌ها)،
--          T30 lint امنیتی هسته، رجیستری صدور، مجوزها و grantهای فقط‌افزودنی.
-- پوشش: هر محل RAISE در 60_migration.sql دست‌کم یک ادعا دارد؛ آزمون جهش (بی‌اثر کردن تک‌تک RAISEها) ۱۱۵ از ۱۱۷
-- را می‌کشد و دو بازمانده دسترس‌ناپذیرند (سند §۹-۷).
-- خروجی موفق با «ALL 60_migration TESTS PASSED» پایان می‌یابد؛ هر شکست «TEST FAILED [...]» می‌دهد
-- و psql با کد ≠ ۰ خارج می‌شود. بردارهای مشترک با همتای پایتون:
--   -v hdr_vectors_file=docs/design/sql/tests/mig_header_norm_v1.json  -v taxid_vectors_file=docs/design/sql/tests/mig_taxid_v1.json
-- =====================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
\pset tuples_only on
\pset format unaligned
\if :{?hdr_vectors_file}
\else
  \set hdr_vectors_file docs/design/sql/tests/mig_header_norm_v1.json
\endif
\if :{?taxid_vectors_file}
\else
  \set taxid_vectors_file docs/design/sql/tests/mig_taxid_v1.json
\endif
\set hdr_vectors `cat :hdr_vectors_file`
\set taxid_vectors `cat :taxid_vectors_file`

-- =====================================================================
-- بخش ۱: fixture (postgres)
-- =====================================================================
RESET ROLE;
BEGIN;
INSERT INTO core.tenant (id, slug, display_name) VALUES
  ('60a00000-0000-7000-8000-000000000001', 'mg-tenant-a', 'A'),
  ('60b00000-0000-7000-8000-000000000001', 'mg-tenant-b', 'B');
INSERT INTO core.company (tenant_id, id, code, name) VALUES
  ('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-0000000000c1', 'C1', 'کافه الف'),
  ('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-0000000000c2', 'C2', 'کفش الف'),
  ('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-0000000000c3', 'C3', 'شرکت تمرینی'),
  ('60b00000-0000-7000-8000-000000000001', '60b00000-0000-7000-8000-0000000000c1', 'C1', 'برق ب');
INSERT INTO core.app_user (id, kind, display_name) VALUES
  ('60a00000-0000-7000-8000-0000000000a1', 'human', 'مالک الف'),
  ('60a00000-0000-7000-8000-0000000000a2', 'human', 'حسابدار الف'),
  ('60b00000-0000-7000-8000-0000000000b1', 'human', 'مالک ب');
INSERT INTO core.tenant_membership (tenant_id, user_id, status, is_owner, joined_at) VALUES
  ('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-0000000000a1', 'active', true,  now()),
  ('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-0000000000a2', 'active', false, now()),
  ('60b00000-0000-7000-8000-000000000001', '60b00000-0000-7000-8000-0000000000b1', 'active', true,  now());
INSERT INTO core.support_access_grant (tenant_id, id, granted_by, access_mode, reason, expires_at) VALUES
  ('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-00000000600d', '60a00000-0000-7000-8000-0000000000a1',
   'read_write', 'assisted migration service', now() + interval '2 days');
COMMIT;

-- سال مالی ۱۴۰۵ برای هر شرکت (۱۲ دورهٔ جلالی). هر شرکت در تراکنش جدا، چون تریگرهای deferred دفتر کل
-- تعویض مستأجر وسط تراکنش را رد می‌کنند (ledger.assert_tenant_context).
CREATE OR REPLACE FUNCTION public.mg_make_year(p_tenant uuid, p_company uuid, p_fy uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE lens int[] := ARRAY[31,31,31,31,31,31,30,30,30,30,30,29]; d date := DATE '2026-03-21'; i int;
BEGIN
  PERFORM set_config('app.tenant_id', p_tenant::text, true);
  INSERT INTO ledger.fiscal_year (tenant_id, id, company_id, code, name, start_date, end_date, base_currency)
  VALUES (p_tenant, p_fy, p_company, '1405', 'سال ۱۴۰۵', d, d + 364, 'IRR');
  FOR i IN 1..12 LOOP
    INSERT INTO ledger.fiscal_period (tenant_id, company_id, fiscal_year_id, period_no, name, start_date, end_date)
    VALUES (p_tenant, p_company, p_fy, i, 'ماه ' || i, d, d + lens[i] - 1);
    d := d + lens[i];
  END LOOP;
END $$;
SELECT public.mg_make_year('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-0000000000c1', '60a00000-0000-7000-8000-0000000000f1');
SELECT public.mg_make_year('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-0000000000c2', '60a00000-0000-7000-8000-0000000000f2');
SELECT public.mg_make_year('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-0000000000c3', '60a00000-0000-7000-8000-0000000000f3');
SELECT public.mg_make_year('60b00000-0000-7000-8000-000000000001', '60b00000-0000-7000-8000-0000000000c1', '60b00000-0000-7000-8000-0000000000f1');

-- ---------- توابع کمکی آزمون ----------
CREATE OR REPLACE FUNCTION public.mg_expect_error(p_label text, p_sql text, p_expect text) RETURNS void
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

CREATE OR REPLACE FUNCTION public.mg_assert(p_cond boolean, p_label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond IS NOT TRUE THEN RAISE EXCEPTION 'TEST FAILED [%]', p_label; END IF;
END $$;

CREATE OR REPLACE FUNCTION public.mg_ctx(p_tenant uuid, p_user uuid) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('app.tenant_id', p_tenant::text, true);
  PERFORM set_config('app.user_id', coalesce(p_user::text, ''), true);
END $$;

CREATE OR REPLACE FUNCTION public.mg_sha(p text) RETURNS bytea
LANGUAGE sql IMMUTABLE AS $$ SELECT sha256(convert_to(p, 'UTF8')) $$;

CREATE OR REPLACE FUNCTION public.mg_new_job(p_company uuid, p_source text, p_channel text, p_mode text,
                                             p_rehearsal boolean DEFAULT false, p_grant uuid DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
  INSERT INTO migration.job (tenant_id, company_id, title, source_system, channel, mode, cutover_date, amount_unit,
                             is_rehearsal, assisted, support_grant_id, created_by)
  VALUES (core.current_tenant_id(), p_company, 'انتقال آزمایشی', p_source, p_channel, p_mode, DATE '2026-09-23', 'IRR',
          p_rehearsal, p_grant IS NOT NULL, p_grant, core.current_user_id())
  RETURNING id INTO v;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION public.mg_consent(p_job uuid, p_kind text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
  INSERT INTO migration.consent (tenant_id, job_id, kind, statement_code, statement_version, statement_sha256, signer_user_id,
                                 signer_full_name, signer_capacity, valid_until, client_ip)
  VALUES (core.current_tenant_id(), p_job, p_kind, 'mig.consent.' || p_kind, 1, public.mg_sha('متن رضایت ' || p_kind),
          core.current_user_id(), 'مالک الف', 'owner', now() + interval '90 days', '10.0.0.1')
  RETURNING id INTO v;
  RETURN v;
END $$;

-- رضایت‌های لازم + draft → awaiting_source
CREATE OR REPLACE FUNCTION public.mg_open(p_job uuid) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE j record; c uuid;
BEGIN
  SELECT * INTO j FROM migration.job WHERE id = p_job;
  c := public.mg_consent(p_job, 'data_owner_migration');
  IF j.channel = 'agent' THEN PERFORM public.mg_consent(p_job, 'agent_execution'); END IF;
  IF j.channel = 'backup' THEN PERFORM public.mg_consent(p_job, 'backup_processing'); END IF;
  IF j.channel = 'api' THEN PERFORM public.mg_consent(p_job, 'third_party_api'); END IF;
  IF j.assisted THEN PERFORM public.mg_consent(p_job, 'assisted_access'); END IF;
  UPDATE migration.job SET consent_id = c, status = 'awaiting_source' WHERE id = p_job;
  RETURN c;
END $$;

-- بارگذاری فایل پذیرفته‌شده
CREATE OR REPLACE FUNCTION public.mg_upload(p_job uuid, p_kind text, p_format text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE u uuid := uuidv7(); t uuid := core.current_tenant_id();
BEGIN
  INSERT INTO migration.upload (tenant_id, id, job_id, kind, file_name, storage_backend, bucket, object_key, encryption_key_ref,
                                purge_after, uploaded_by)
  VALUES (t, u, p_job, p_kind, 'source.' || p_kind, 'fs', 'local', 't/' || t || '/migration/' || p_job || '/' || u, 'dek:test',
          now() + interval '30 days', core.current_user_id());
  UPDATE migration.upload SET status = 'uploaded', size_bytes = 1024, sha256 = public.mg_sha(u::text), uploaded_at = now() WHERE id = u;
  UPDATE migration.upload SET status = 'scanning', sniffed_format = p_format WHERE id = u;
  UPDATE migration.upload SET status = 'accepted' WHERE id = u;
  RETURN u;
END $$;

-- بستهٔ HIF با p_rows ردیف خام، تأیید، و staged → mapping
CREATE OR REPLACE FUNCTION public.mg_stage(p_job uuid, p_rows integer, p_to_mapping boolean DEFAULT true) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE j record; u uuid; p uuid := uuidv7(); a uuid; i int; t uuid := core.current_tenant_id();
BEGIN
  SELECT * INTO j FROM migration.job WHERE id = p_job;
  u := public.mg_upload(p_job, 'hif', 'hif');
  IF j.channel = 'agent' THEN
    a := uuidv7();
    INSERT INTO migration.agent_session (tenant_id, id, job_id, pairing_code_hash, expires_at, created_by)
    VALUES (t, a, p_job, public.mg_sha('pair' || a), now() + interval '1 hour', core.current_user_id());
    UPDATE migration.agent_session SET status = 'paired', agent_public_key = substr(public.mg_sha('key' || a), 1, 32),
           paired_at = now(), agent_version = '2027.1.0', db_driver = 'pytds', trust_server_certificate = true WHERE id = a;
  END IF;
  INSERT INTO migration.package (tenant_id, id, job_id, upload_id, producer, agent_session_id, format_version, manifest, manifest_sha256,
                                 signer_key_id, source_system, source_db, extractor, amount_unit, date_mode, extracted_at, row_count_total)
  VALUES (t, p, p_job, u, CASE WHEN a IS NULL THEN 'server_file' ELSE 'agent' END, a, 'hif/1',
          jsonb_build_object('format', 'hif/1', 'rows', p_rows), public.mg_sha(p::text), coalesce('agent:' || a, 'server:k1'),
          j.source_system, 'Holoo1', 'hk-test/1', 'IRR', 'gregorian_datetime', now(), p_rows);
  FOR i IN 1..p_rows LOOP
    INSERT INTO migration.raw_record (tenant_id, job_id, package_id, source_system, source_db, source_table, source_key, row_no, payload, content_hash)
    VALUES (t, p_job, p, j.source_system, 'Holoo1', 'SANAD', i::text, i, jsonb_build_object('Sanad_Code', i), public.mg_sha(p || ':' || i));
  END LOOP;
  UPDATE migration.package SET status = 'verified', signature_verified_at = now(), verified_at = now() WHERE id = p;
  UPDATE migration.job SET status = 'staged' WHERE id = p_job;
  IF p_to_mapping THEN UPDATE migration.job SET status = 'mapping' WHERE id = p_job; END IF;
  RETURN p;
END $$;

-- یک رکورد مرحله‌ای ساده (شخص)
CREATE OR REPLACE FUNCTION public.mg_party(p_job uuid, p_key text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
  INSERT INTO migration.staged_record (tenant_id, job_id, entity, source_system, source_db, source_table, source_key, legacy_code, normalized)
  VALUES (core.current_tenant_id(), p_job, 'party', 'holoo', 'Holoo1', 'CUSTOMER', p_key, p_key, jsonb_build_object('name', 'شخص ' || p_key))
  RETURNING id INTO v;
  RETURN v;
END $$;

-- همهٔ ردیف‌های pending ← valid (فرزندان پیش از والد)، تأیید واحد، سال مالی، mapping → validated
CREATE OR REPLACE FUNCTION public.mg_validate(p_job uuid, p_fy uuid) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE migration.staged_record SET status = 'valid' WHERE job_id = p_job AND status = 'pending' AND parent_id IS NOT NULL;
  UPDATE migration.staged_record SET status = 'valid' WHERE job_id = p_job AND status = 'pending' AND parent_id IS NULL;
  UPDATE migration.job SET fiscal_year_id = p_fy, amount_unit_confirmed_by = core.current_user_id(), amount_unit_confirmed_at = now()
   WHERE id = p_job;
  UPDATE migration.job SET status = 'validated' WHERE id = p_job;
END $$;

-- hash ورودی، dry-run موفق، previewed و پذیرش پیش‌نمایش
CREATE OR REPLACE FUNCTION public.mg_preview(p_job uuid) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE h bytea := public.mg_sha('inputs:' || p_job); d uuid := uuidv7(); s int;
BEGIN
  UPDATE migration.job SET inputs_hash = h WHERE id = p_job;
  SELECT coalesce(max(seq), 0) + 1 INTO s FROM migration.dry_run WHERE job_id = p_job;
  INSERT INTO migration.dry_run (tenant_id, id, job_id, seq, run_mode, inputs_hash, started_at, outcome, report, report_sha256, started_by)
  VALUES (core.current_tenant_id(), d, p_job, s, 'full_tx', h, now(), 'ok', '{"tb":"balanced"}', h, core.current_user_id());
  UPDATE migration.job SET preview_dry_run_id = d, status = 'previewed' WHERE id = p_job;
  UPDATE migration.job SET preview_accepted_by = core.current_user_id(), preview_accepted_at = now() WHERE id = p_job;
  RETURN d;
END $$;

-- یک تکه برای همهٔ ردیف‌ها؛ committing؛ اجرای تکه؛ ثبت ردیف‌ها؛ done؛ committed
CREATE OR REPLACE FUNCTION public.mg_commit_all(p_job uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM migration.staged_record WHERE job_id = p_job AND status IN ('valid','warning');
  INSERT INTO migration.commit_chunk (tenant_id, job_id, chunk_no, stage, item_count) VALUES (core.current_tenant_id(), p_job, 1, 'masterdata', n);
  UPDATE migration.job SET status = 'committing' WHERE id = p_job;
  UPDATE migration.commit_chunk SET status = 'running' WHERE job_id = p_job AND chunk_no = 1;
  INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
                                 target_module, target_doc_type, target_doc_id, gl_effect)
  SELECT tenant_id, job_id, 1, id, source_system, source_db, source_table, source_key, 'parties', 'parties.party', uuidv7(), 'none'
    FROM migration.staged_record WHERE job_id = p_job AND status IN ('valid','warning') AND entity = 'party';
  UPDATE migration.staged_record SET status = 'committed', committed_chunk = 1 WHERE job_id = p_job AND status IN ('valid','warning') AND parent_id IS NOT NULL;
  UPDATE migration.staged_record SET status = 'committed', committed_chunk = 1 WHERE job_id = p_job AND status IN ('valid','warning');
  UPDATE migration.commit_chunk SET done_count = n, status = 'done' WHERE job_id = p_job AND chunk_no = 1;
  UPDATE migration.job SET status = 'committed' WHERE id = p_job;
END $$;

GRANT EXECUTE ON FUNCTION public.mg_expect_error(text, text, text), public.mg_assert(boolean, text), public.mg_ctx(uuid, uuid),
  public.mg_sha(text), public.mg_new_job(uuid, text, text, text, boolean, uuid), public.mg_consent(uuid, text), public.mg_open(uuid),
  public.mg_upload(uuid, text, text), public.mg_stage(uuid, integer, boolean), public.mg_party(uuid, text),
  public.mg_validate(uuid, uuid), public.mg_preview(uuid), public.mg_commit_all(uuid)
  TO hk_app, hk_readonly;

-- =====================================================================
-- بخش ۲: ادعاها با نقش برنامه
-- =====================================================================
SET ROLE hk_app;

-- T01: کاتالوگ‌ها برای hk_app فقط‌خواندنی‌اند
DO $$
BEGIN
  PERFORM public.mg_ctx('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_assert((SELECT count(*) FROM migration.source_system) >= 16, 'T01 source systems readable');
  PERFORM public.mg_assert((SELECT count(*) FROM migration.template_column WHERE template_version = 1) >= 150, 'T01 template v1 seeded');
  PERFORM public.mg_assert((SELECT count(DISTINCT sheet_code) FROM migration.template_column WHERE template_version = 1) = 19, 'T01 sheets T00..T17 + T11b');
  PERFORM public.mg_expect_error('T01 catalog insert source_system',
    $q$INSERT INTO migration.source_system (code, name_fa, name_en, kind, channels, support_status, phase, introduced_in)
       VALUES ('xx', 'x', 'x', 'generic', '{file}', 'supported', 'v1', '1.0')$q$, '42501');
  PERFORM public.mg_expect_error('T01 catalog update issue_code',
    $q$UPDATE migration.issue_code SET overridable = true WHERE code = 'MIG_VOUCHER_UNBALANCED'$q$, '42501');
  PERFORM public.mg_expect_error('T01 catalog insert synonym',
    $q$INSERT INTO migration.header_synonym (field_key, synonym_norm, dict_version, origin) VALUES ('debit', 'بد', 1, 'seed')$q$, '42501');
  PERFORM public.mg_expect_error('T01 catalog insert partition rule',
    $q$INSERT INTO migration.partition_rule (partition_class, disposition, phase, description_key) VALUES ('MANUAL', 'skip', 'v1', 'x')$q$, '42501');
  PERFORM public.mg_expect_error('T01 catalog insert profile',
    $q$INSERT INTO migration.profile (code, version, source_system, title, channel, source_versions, fingerprint, spec, spec_sha256, confidence)
       VALUES ('holoo_x', 1, 'holoo', 'x', 'agent', 'x', '{}', '{}', sha256('x'), 'low')$q$, '42501');
END $$;

-- T02: بردارهای مشترک با همتای پایتون (نرمال‌سازی سرستون و taxid)
SELECT public.mg_assert(bool_and(migration.norm_header(x.input) IS NOT DISTINCT FROM x.expected), 'T02 norm_header vectors')
  FROM jsonb_to_recordset((:'hdr_vectors')::jsonb -> 'vectors') AS x(input text, expected text);
SELECT public.mg_assert(count(*) >= 20, 'T02 norm_header vector count')
  FROM jsonb_to_recordset((:'hdr_vectors')::jsonb -> 'vectors') AS x(input text, expected text);
SELECT public.mg_assert(bool_and(migration.taxid_is_valid(x.taxid) = x.valid), 'T02 taxid Verhoeff vectors')
  FROM jsonb_to_recordset((:'taxid_vectors')::jsonb -> 'vectors') AS x(taxid text, valid boolean);
SELECT public.mg_assert(count(*) FILTER (WHERE x.valid) >= 3 AND count(*) FILTER (WHERE NOT x.valid) >= 3, 'T02 taxid vector mix')
  FROM jsonb_to_recordset((:'taxid_vectors')::jsonb -> 'vectors') AS x(taxid text, valid boolean);
SELECT public.mg_assert(migration.verhoeff_digit('236') = 3 AND migration.verhoeff_digit('12345') = 1, 'T02 Verhoeff reference digits');

-- T03: ساخت کار؛ حالت آغازین؛ کانال مجاز مبدأ؛ حذف ممنوع؛ مهاجرت همراه بدون رضایت پشتیبانی ممنوع
DO $$
DECLARE j uuid;
BEGIN
  PERFORM public.mg_ctx('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T03 job must start as draft',
    $q$INSERT INTO migration.job (tenant_id, company_id, title, source_system, channel, mode, cutover_date, amount_unit, status, created_by)
       VALUES ('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-0000000000c3', 't', 'holoo', 'agent', 'opening',
               '2026-03-21', 'IRR', 'mapping', '60a00000-0000-7000-8000-0000000000a2')$q$, 'HK_MIG_JOB_INITIAL');
  PERFORM public.mg_expect_error('T03 hesabfa has no agent channel',
    $q$SELECT public.mg_new_job('60a00000-0000-7000-8000-0000000000c3', 'hesabfa', 'agent', 'opening')$q$, 'HK_MIG_CHANNEL');
  PERFORM public.mg_expect_error('T03 assisted needs a support grant',
    $q$INSERT INTO migration.job (tenant_id, company_id, title, source_system, channel, mode, cutover_date, amount_unit, assisted, created_by)
       VALUES ('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-0000000000c3', 't', 'holoo', 'agent', 'opening',
               '2026-03-21', 'IRR', true, '60a00000-0000-7000-8000-0000000000a2')$q$, '23514');
  PERFORM public.mg_expect_error('T03 unknown source system',
    $q$SELECT public.mg_new_job('60a00000-0000-7000-8000-0000000000c3', 'nosuch', 'file', 'opening')$q$, 'HK_MIG_CHANNEL');
  PERFORM public.mg_expect_error('T03 creator must be a member',
    $q$INSERT INTO migration.job (tenant_id, company_id, title, source_system, channel, mode, cutover_date, amount_unit, created_by)
       VALUES ('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-0000000000c3', 't', 'holoo', 'agent', 'opening',
               '2026-03-21', 'IRR', '60b00000-0000-7000-8000-0000000000b1')$q$, '23503');
  j := public.mg_new_job('60a00000-0000-7000-8000-0000000000c3', 'template', 'file', 'opening');
  PERFORM public.mg_expect_error('T03 file job needs the data-owner consent',
    format($q$UPDATE migration.job SET status = 'awaiting_source' WHERE id = %L$q$, j), 'HK_MIG_CONSENT_REQUIRED: an active data-owner consent');
  UPDATE migration.job SET status = 'cancelled' WHERE id = j;
  j := public.mg_new_job('60a00000-0000-7000-8000-0000000000c1', 'holoo', 'agent', 'current_fy');
  PERFORM set_config('test.j1', j::text, false);
  PERFORM public.mg_assert((SELECT status FROM migration.job WHERE id = j) = 'draft', 'T03 job created as draft');
  PERFORM public.mg_expect_error('T03 job delete forbidden (no grant)', format($q$DELETE FROM migration.job WHERE id = %L$q$, j), '42501');
  PERFORM public.mg_expect_error('T03 company immutable',
    format($q$UPDATE migration.job SET company_id = '60a00000-0000-7000-8000-0000000000c2' WHERE id = %L$q$, j), 'HK_MIG_JOB_IMMUTABLE');
  PERFORM public.mg_expect_error('T03 draft cannot skip to staged',
    format($q$UPDATE migration.job SET status = 'staged' WHERE id = %L$q$, j), 'HK_MIG_JOB_TRANSITION');
END $$;

-- T04: رضایت مالک داده (INV-MIG-01)
DO $$
DECLARE j uuid := current_setting('test.j1')::uuid; c uuid; c2 uuid;
BEGIN
  PERFORM public.mg_ctx('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T04 no consent → no awaiting_source',
    format($q$UPDATE migration.job SET status = 'awaiting_source' WHERE id = %L$q$, j), 'HK_MIG_CONSENT_REQUIRED');
  PERFORM public.mg_expect_error('T04 upload before consent forbidden',
    format($q$SELECT public.mg_upload(%L, 'excel', 'xlsx')$q$, j), 'HK_MIG_JOB_STATE');
  PERFORM public.mg_expect_error('T04 signer must be the acting user',
    format($q$INSERT INTO migration.consent (tenant_id, job_id, kind, statement_code, statement_version, statement_sha256, signer_user_id,
               signer_full_name, signer_capacity, valid_until)
              VALUES ('60a00000-0000-7000-8000-000000000001', %L, 'data_owner_migration', 'mig.consent', 1, sha256('x'),
                      '60a00000-0000-7000-8000-0000000000a1', 'مالک الف', 'owner', now() + interval '1 day')$q$, j), 'HK_MIG_CONSENT_SIGNER');
  PERFORM public.mg_expect_error('T04 consent validity at most a year',
    format($q$INSERT INTO migration.consent (tenant_id, job_id, kind, statement_code, statement_version, statement_sha256, signer_user_id,
               signer_full_name, signer_capacity, valid_until)
              VALUES ('60a00000-0000-7000-8000-000000000001', %L, 'data_owner_migration', 'mig.consent', 1, sha256('x'),
                      '60a00000-0000-7000-8000-0000000000a2', 'مالک الف', 'owner', now() + interval '400 days')$q$, j), '23514');
  PERFORM public.mg_expect_error('T04 signer name must be normalized',
    format($q$INSERT INTO migration.consent (tenant_id, job_id, kind, statement_code, statement_version, statement_sha256, signer_user_id,
               signer_full_name, signer_capacity, valid_until)
              VALUES ('60a00000-0000-7000-8000-000000000001', %L, 'data_owner_migration', 'mig.consent', 1, sha256('x'),
                      '60a00000-0000-7000-8000-0000000000a2', 'مالك الف', 'owner', now() + interval '1 day')$q$, j), '23514');
  PERFORM public.mg_expect_error('T04 consent is recorded un-revoked',
    format($q$INSERT INTO migration.consent (tenant_id, job_id, kind, statement_code, statement_version, statement_sha256, signer_user_id,
               signer_full_name, signer_capacity, valid_until, revoked_at, revoked_by, revoke_reason)
              VALUES ('60a00000-0000-7000-8000-000000000001', %L, 'data_owner_migration', 'mig.consent', 1, sha256('x'),
                      '60a00000-0000-7000-8000-0000000000a2', 'مالک الف', 'owner', now() + interval '1 day',
                      now(), '60a00000-0000-7000-8000-0000000000a2', 'لغو از پیش ثبت‌شده')$q$, j), 'HK_MIG_CONSENT_IMMUTABLE: a consent is recorded');
  c := public.mg_consent(j, 'data_owner_migration');
  UPDATE migration.job SET consent_id = c WHERE id = j;
  -- کانال عامل رضایت اجرای عامل هم می‌خواهد
  PERFORM public.mg_expect_error('T04 agent channel needs agent_execution consent',
    format($q$UPDATE migration.job SET status = 'awaiting_source' WHERE id = %L$q$, j), 'HK_MIG_CONSENT_REQUIRED');
  c2 := public.mg_consent(j, 'agent_execution');
  -- رضایت تغییرناپذیر است؛ فقط یک‌بار و با دلیل لغو می‌شود
  PERFORM public.mg_expect_error('T04 consent immutable',
    format($q$UPDATE migration.consent SET valid_until = now() + interval '200 days' WHERE id = %L$q$, c2), 'HK_MIG_CONSENT_IMMUTABLE');
  PERFORM public.mg_expect_error('T04 consent delete forbidden (no grant)', format($q$DELETE FROM migration.consent WHERE id = %L$q$, c2), '42501');
  PERFORM public.mg_expect_error('T04 revoke reason ≥ 10 chars',
    format($q$UPDATE migration.consent SET revoked_at = now(), revoked_by = '60a00000-0000-7000-8000-0000000000a2', revoke_reason = 'no' WHERE id = %L$q$, c2), '23514');
  UPDATE migration.consent SET revoked_at = now(), revoked_by = '60a00000-0000-7000-8000-0000000000a2',
         revoke_reason = 'مالک اجرای عامل را لغو کرد' WHERE id = c2;
  PERFORM public.mg_expect_error('T04 revoked consent is final',
    format($q$UPDATE migration.consent SET revoked_at = NULL, revoked_by = NULL, revoke_reason = NULL WHERE id = %L$q$, c2), 'HK_MIG_CONSENT_IMMUTABLE');
  PERFORM public.mg_expect_error('T04 revoked agent consent blocks progress',
    format($q$UPDATE migration.job SET status = 'awaiting_source' WHERE id = %L$q$, j), 'HK_MIG_CONSENT_REQUIRED');
  PERFORM public.mg_consent(j, 'agent_execution');
  UPDATE migration.job SET status = 'awaiting_source' WHERE id = j;
  PERFORM public.mg_assert((SELECT count(*) FROM migration.job_event WHERE job_id = j AND to_status = 'awaiting_source'
                              AND actor_id = '60a00000-0000-7000-8000-0000000000a2') = 1, 'T04 transition logged with actor');
  PERFORM public.mg_expect_error('T04 job_event append-only',
    format($q$UPDATE migration.job_event SET note = 'x' WHERE job_id = %L$q$, j), '42501');
END $$;

-- T05: فایل بارگذاری‌شده (INV-MIG-29، INV-MIG-30)
DO $$
DECLARE j uuid := current_setting('test.j1')::uuid; u uuid := uuidv7(); u2 uuid; t uuid := '60a00000-0000-7000-8000-000000000001';
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T05 object key must be in the tenant/job namespace',
    format($q$INSERT INTO migration.upload (tenant_id, id, job_id, kind, file_name, storage_backend, bucket, object_key, encryption_key_ref, purge_after)
              VALUES (%L, %L, %L, 'backup', 'h.bak', 'fs', 'local', 't/other/migration/x/y', 'dek', now() + interval '30 days')$q$, t, u, j), '23514');
  PERFORM public.mg_expect_error('T05 file name without slashes',
    format($q$INSERT INTO migration.upload (tenant_id, id, job_id, kind, file_name, storage_backend, bucket, object_key, encryption_key_ref, purge_after)
              VALUES (%L, %L, %L, 'backup', '../h.bak', 'fs', 'local', %L, 'dek', now() + interval '30 days')$q$,
           t, u, j, 't/' || t || '/migration/' || j || '/' || u), '23514');
  INSERT INTO migration.upload (tenant_id, id, job_id, kind, file_name, storage_backend, bucket, object_key, encryption_key_ref, purge_after)
  VALUES (t, u, j, 'backup', 'Holoo.bak', 'fs', 'local', 't/' || t || '/migration/' || j || '/' || u, 'dek', now() + interval '30 days');
  PERFORM public.mg_expect_error('T05 uploaded needs size/sha',
    format($q$UPDATE migration.upload SET status = 'uploaded' WHERE id = %L$q$, u), '23514');
  UPDATE migration.upload SET status = 'uploaded', size_bytes = 4096, sha256 = public.mg_sha('bak'), uploaded_at = now() WHERE id = u;
  UPDATE migration.upload SET status = 'scanning', sniffed_format = 'unknown' WHERE id = u;
  PERFORM public.mg_expect_error('T05 backup with unknown header is never accepted (INV-MIG-30)',
    format($q$UPDATE migration.upload SET status = 'accepted' WHERE id = %L$q$, u), '23514');
  PERFORM public.mg_expect_error('T05 upload identity immutable',
    format($q$UPDATE migration.upload SET job_id = uuidv7() WHERE id = %L$q$, u), 'HK_MIG_IMMUTABLE_FIELD: identity');
  PERFORM public.mg_expect_error('T05 sha256 immutable',
    format($q$UPDATE migration.upload SET sha256 = sha256('other') WHERE id = %L$q$, u), 'HK_MIG_IMMUTABLE_FIELD');
  PERFORM public.mg_expect_error('T05 rejection needs a code',
    format($q$UPDATE migration.upload SET status = 'rejected' WHERE id = %L$q$, u), '23514');
  UPDATE migration.upload SET status = 'rejected', reject_code = 'MIG_BACKUP_FORMAT_UNKNOWN' WHERE id = u;
  PERFORM public.mg_expect_error('T05 rejected cannot be accepted',
    format($q$UPDATE migration.upload SET status = 'accepted', reject_code = NULL WHERE id = %L$q$, u), 'HK_MIG_UPLOAD_TRANSITION');
  UPDATE migration.upload SET status = 'purged', purged_at = now() WHERE id = u;
  PERFORM public.mg_expect_error('T05 purged is final',
    format($q$UPDATE migration.upload SET file_name = 'x.bak' WHERE id = %L$q$, u), 'HK_MIG_PURGED');
  PERFORM public.mg_expect_error('T05 upload delete forbidden (no grant)', format($q$DELETE FROM migration.upload WHERE id = %L$q$, u), '42501');
  u2 := uuidv7();
  PERFORM public.mg_expect_error('T05 64 GiB hard cap',
    format($q$INSERT INTO migration.upload (tenant_id, id, job_id, kind, file_name, size_bytes, storage_backend, bucket, object_key, encryption_key_ref, purge_after)
              VALUES (%L, %L, %L, 'backup', 'big.bak', 70000000000, 'fs', 'local', %L, 'dek', now() + interval '30 days')$q$,
           t, u2, j, 't/' || t || '/migration/' || j || '/' || u2), '23514');
  -- بکاپ با سرآیند MTF پذیرفته می‌شود
  u2 := public.mg_upload(j, 'backup', 'mtf');
  PERFORM public.mg_assert((SELECT status FROM migration.upload WHERE id = u2) = 'accepted', 'T05 MTF backup accepted');
END $$;

-- T06: نشست عامل (INV-MIG-32) و اعتبارنامهٔ API (INV-MIG-31)
DO $$
DECLARE j uuid := current_setting('test.j1')::uuid; a uuid := uuidv7(); t uuid := '60a00000-0000-7000-8000-000000000001';
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T06 pairing window ≤ 24h',
    format($q$INSERT INTO migration.agent_session (tenant_id, job_id, pairing_code_hash, expires_at, created_by)
              VALUES (%L, %L, sha256('p'), now() + interval '2 days', '60a00000-0000-7000-8000-0000000000a2')$q$, t, j), '23514');
  INSERT INTO migration.agent_session (tenant_id, id, job_id, pairing_code_hash, expires_at, created_by)
  VALUES (t, a, j, public.mg_sha('pair-x'), now() + interval '1 hour', '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T06 paired needs a key',
    format($q$UPDATE migration.agent_session SET status = 'paired', paired_at = now() WHERE id = %L$q$, a), '23514');
  PERFORM public.mg_expect_error('T06 Ed25519 key is 32 bytes',
    format($q$UPDATE migration.agent_session SET status = 'paired', paired_at = now(), agent_public_key = '\x0102'::bytea WHERE id = %L$q$, a), '23514');
  UPDATE migration.agent_session SET status = 'paired', paired_at = now(), agent_public_key = public.mg_sha('k1') WHERE id = a;
  PERFORM public.mg_expect_error('T06 pairing code single-use',
    format($q$UPDATE migration.agent_session SET pairing_code_hash = sha256('again') WHERE id = %L$q$, a), 'HK_MIG_IMMUTABLE_FIELD: pairing code');
  PERFORM public.mg_expect_error('T06 agent key bound once',
    format($q$UPDATE migration.agent_session SET agent_public_key = sha256('k2') WHERE id = %L$q$, a), 'HK_MIG_IMMUTABLE_FIELD');
  PERFORM public.mg_expect_error('T06 agent token ≤ 1h',
    format($q$UPDATE migration.agent_session SET token_hash = sha256('t'), token_expires_at = now() + interval '3 hours' WHERE id = %L$q$, a), 'HK_MIG_AGENT_TOKEN_TTL');
  UPDATE migration.agent_session SET token_hash = public.mg_sha('t'), token_expires_at = now() + interval '50 minutes' WHERE id = a;
  INSERT INTO migration.agent_session (tenant_id, id, job_id, pairing_code_hash, expires_at, created_by)
  VALUES (t, '60a00000-0000-7000-8000-00000000a9e0', j, public.mg_sha('old'), now() - interval '1 minute', '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T06 expired pairing code cannot pair',
    $q$UPDATE migration.agent_session SET status = 'paired', paired_at = now(), agent_public_key = sha256('k9')
        WHERE id = '60a00000-0000-7000-8000-00000000a9e0'$q$, 'HK_MIG_AGENT_PAIRING_EXPIRED');
  UPDATE migration.agent_session SET status = 'expired' WHERE id = '60a00000-0000-7000-8000-00000000a9e0';
  PERFORM public.mg_expect_error('T06 paired session cannot return to pending',
    format($q$UPDATE migration.agent_session SET status = 'pending' WHERE id = %L$q$, a), 'HK_MIG_AGENT_TRANSITION');
  -- اعتبارنامه: فقط ارجاع راز، https، حداکثر ۳۰ روز
  PERFORM public.mg_expect_error('T06 credential must be a secret reference',
    format($q$INSERT INTO migration.source_credential (tenant_id, job_id, kind, endpoint_base, secret_ref, purge_after, created_by)
              VALUES (%L, %L, 'hesabfa_api', 'https://api.hesabfa.com/', 'plain-api-key', now() + interval '7 days',
                      '60a00000-0000-7000-8000-0000000000a2')$q$, t, j), '23514');
  PERFORM public.mg_expect_error('T06 credential endpoint https',
    format($q$INSERT INTO migration.source_credential (tenant_id, job_id, kind, endpoint_base, secret_ref, purge_after, created_by)
              VALUES (%L, %L, 'hesabfa_api', 'http://api.hesabfa.ir/', 'secret://t/mig/hesabfa', now() + interval '7 days',
                      '60a00000-0000-7000-8000-0000000000a2')$q$, t, j), '23514');
  PERFORM public.mg_expect_error('T06 credential purge ≤ 30 days',
    format($q$INSERT INTO migration.source_credential (tenant_id, job_id, kind, endpoint_base, secret_ref, purge_after, created_by)
              VALUES (%L, %L, 'hesabfa_api', 'https://api.hesabfa.com/', 'secret://t/mig/hesabfa', now() + interval '60 days',
                      '60a00000-0000-7000-8000-0000000000a2')$q$, t, j), '23514');
  INSERT INTO migration.source_credential (tenant_id, job_id, kind, endpoint_base, secret_ref, purge_after, created_by)
  VALUES (t, j, 'hesabfa_api', 'https://api.hesabfa.com/', 'secret://t/mig/hesabfa', now() + interval '7 days', '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T06 credential reference immutable',
    $q$UPDATE migration.source_credential SET secret_ref = 'secret://t/mig/other'$q$, 'HK_MIG_IMMUTABLE_FIELD');
  UPDATE migration.source_credential SET status = 'revoked';
  PERFORM public.mg_expect_error('T06 revoked credential is final',
    $q$UPDATE migration.source_credential SET status = 'active'$q$, 'HK_MIG_PURGED');
END $$;

-- T07: بستهٔ HIF و snapshot خام (INV-MIG-04، INV-MIG-05)
DO $$
DECLARE j uuid := current_setting('test.j1')::uuid; t uuid := '60a00000-0000-7000-8000-000000000001'; u uuid; p uuid := uuidv7();
        a uuid; p2 uuid := uuidv7(); r uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T07 staged needs a verified package',
    format($q$UPDATE migration.job SET status = 'staged' WHERE id = %L$q$, j), 'HK_MIG_NO_PACKAGE');
  u := public.mg_upload(j, 'hif', 'hif');
  SELECT id INTO a FROM migration.agent_session WHERE job_id = j AND status = 'paired' LIMIT 1;
  PERFORM public.mg_expect_error('T07 agent package needs an agent session',
    format($q$INSERT INTO migration.package (tenant_id, job_id, upload_id, producer, format_version, manifest, manifest_sha256, signer_key_id,
               source_system, extractor, amount_unit, date_mode, extracted_at, row_count_total)
              VALUES (%L, %L, %L, 'agent', 'hif/1', '{}', sha256('m'), 'k', 'holoo', 'hk-agent/1', 'IRR', 'gregorian_datetime', now(), 3)$q$, t, j, u), '23514');
  INSERT INTO migration.agent_session (tenant_id, id, job_id, pairing_code_hash, expires_at, created_by)
  VALUES (t, '60a00000-0000-7000-8000-00000000a9e1', j, public.mg_sha('unpaired'), now() + interval '1 hour', '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T07 agent package needs a paired session',
    format($q$INSERT INTO migration.package (tenant_id, job_id, upload_id, producer, agent_session_id, format_version, manifest, manifest_sha256,
               signer_key_id, source_system, extractor, amount_unit, date_mode, extracted_at, row_count_total)
              VALUES (%L, %L, %L, 'agent', '60a00000-0000-7000-8000-00000000a9e1', 'hif/1', '{}', sha256('m'), 'k', 'holoo', 'hk-agent/1', 'IRR',
                      'gregorian_datetime', now(), 1)$q$, t, j, u), 'HK_MIG_AGENT_NOT_PAIRED');
  UPDATE migration.agent_session SET status = 'revoked' WHERE id = '60a00000-0000-7000-8000-00000000a9e1';
  PERFORM public.mg_expect_error('T07 HIF format version',
    format($q$INSERT INTO migration.package (tenant_id, job_id, upload_id, producer, agent_session_id, format_version, manifest, manifest_sha256,
               signer_key_id, source_system, extractor, amount_unit, date_mode, extracted_at, row_count_total)
              VALUES (%L, %L, %L, 'agent', %L, 'hif/2', '{}', sha256('m'), 'k', 'holoo', 'hk-agent/1', 'IRR', 'gregorian_datetime', now(), 3)$q$,
           t, j, u, a), '23514');
  INSERT INTO migration.package (tenant_id, id, job_id, upload_id, producer, agent_session_id, format_version, manifest, manifest_sha256,
                                 signer_key_id, source_system, source_db, extractor, amount_unit, date_mode, extracted_at, row_count_total)
  VALUES (t, p, j, u, 'agent', a, 'hif/1', '{"format":"hif/1"}', public.mg_sha('m1'), 'agent:' || a, 'holoo', 'Holoo1', 'hk-agent/2027.1.0',
          'IRR', 'gregorian_datetime', now(), 3);
  PERFORM public.mg_expect_error('T07 one active package per job',
    format($q$INSERT INTO migration.package (tenant_id, id, job_id, upload_id, producer, agent_session_id, format_version, manifest, manifest_sha256,
               signer_key_id, source_system, extractor, amount_unit, date_mode, extracted_at, row_count_total)
              VALUES (%L, %L, %L, %L, 'agent', %L, 'hif/1', '{}', sha256('m2'), 'k', 'holoo', 'x', 'IRR', 'gregorian_datetime', now(), 1)$q$,
           t, p2, j, u, a), '23505');
  INSERT INTO migration.raw_record (tenant_id, job_id, package_id, source_system, source_db, source_table, source_key, row_no, payload, content_hash)
  VALUES (t, j, p, 'holoo', 'Holoo1', 'SANAD', '101', 1, '{"Sanad_Code":101,"Sanad_Type":4}', public.mg_sha('r1')),
         (t, j, p, 'holoo', 'Holoo1', 'SANAD', '102', 2, '{"Sanad_Code":102,"Sanad_Type":13,"SaveFromFacture":1}', public.mg_sha('r2'));
  PERFORM public.mg_expect_error('T07 duplicate source key in a package',
    format($q$INSERT INTO migration.raw_record (tenant_id, job_id, package_id, source_system, source_db, source_table, source_key, row_no, payload, content_hash)
              VALUES (%L, %L, %L, 'holoo', 'Holoo1', 'SANAD', '101', 3, '{}', sha256('x'))$q$, t, j, p), '23505');
  PERFORM public.mg_expect_error('T07 row count must match the manifest (INV-MIG-04)',
    format($q$UPDATE migration.package SET status = 'verified', signature_verified_at = now(), verified_at = now() WHERE id = %L$q$, p),
    'HK_MIG_ROW_COUNT_MISMATCH');
  INSERT INTO migration.raw_record (tenant_id, job_id, package_id, source_system, source_db, source_table, source_key, row_no, payload, content_hash)
  VALUES (t, j, p, 'holoo', 'Holoo1', 'SANAD', '103', 3, '{"Sanad_Code":103,"Sanad_Type":99}', public.mg_sha('r3'));
  PERFORM public.mg_expect_error('T07 verified needs a signature check',
    format($q$UPDATE migration.package SET status = 'verified', verified_at = now() WHERE id = %L$q$, p), '23514');
  UPDATE migration.package SET status = 'verified', signature_verified_at = now(), verified_at = now() WHERE id = p;
  PERFORM public.mg_expect_error('T07 manifest immutable',
    format($q$UPDATE migration.package SET manifest = '{"x":1}' WHERE id = %L$q$, p), 'HK_MIG_IMMUTABLE_FIELD');
  PERFORM public.mg_expect_error('T07 verified package cannot return to received',
    format($q$UPDATE migration.package SET status = 'received' WHERE id = %L$q$, p), 'HK_MIG_PACKAGE_TRANSITION');
  PERFORM public.mg_expect_error('T07 packages start received',
    format($q$INSERT INTO migration.package (tenant_id, job_id, upload_id, producer, format_version, manifest, manifest_sha256, signer_key_id,
               source_system, extractor, amount_unit, date_mode, extracted_at, row_count_total, status, signature_verified_at, verified_at)
              VALUES (%L, %L, %L, 'server_file', 'hif/1', '{}', sha256('m'), 'k', 'holoo', 'x', 'IRR', 'gregorian_datetime', now(), 0, 'verified', now(), now())$q$,
           t, j, u), 'HK_MIG_PACKAGE_TRANSITION');
  PERFORM public.mg_expect_error('T07 raw rows only while received',
    format($q$INSERT INTO migration.raw_record (tenant_id, job_id, package_id, source_system, source_db, source_table, source_key, row_no, payload, content_hash)
              VALUES (%L, %L, %L, 'holoo', 'Holoo1', 'SANAD', '104', 4, '{}', sha256('x'))$q$, t, j, p), 'HK_MIG_RAW_IMMUTABLE');
  SELECT id INTO r FROM migration.raw_record WHERE package_id = p AND source_key = '101';
  PERFORM public.mg_expect_error('T07 raw rows immutable (no grant)', format($q$UPDATE migration.raw_record SET payload = '{}' WHERE id = %L$q$, r), '42501');
  PERFORM public.mg_expect_error('T07 raw delete only by retention purge', format($q$DELETE FROM migration.raw_record WHERE id = %L$q$, r), 'HK_MIG_RAW_IMMUTABLE');
  PERFORM set_config('hk.migration_purge', 'on', true);
  PERFORM public.mg_expect_error('T07 purge waits for job end', format($q$DELETE FROM migration.raw_record WHERE id = %L$q$, r), 'HK_MIG_RETENTION');
  PERFORM set_config('hk.migration_purge', '', true);
  PERFORM public.mg_expect_error('T07 package delete forbidden (no grant)', format($q$DELETE FROM migration.package WHERE id = %L$q$, p), '42501');
  UPDATE migration.job SET status = 'staged' WHERE id = j;
  PERFORM public.mg_expect_error('T07 staged cannot jump to validated',
    format($q$UPDATE migration.job SET status = 'previewed' WHERE id = %L$q$, j), 'HK_MIG_JOB_TRANSITION');
  PERFORM set_config('test.p1', p::text, false);
END $$;

-- T08: رکورد مرحله‌ای: lineage، واحد مبلغ، طرف سطر، بهای نامعلوم (INV-MIG-02، 06، 11)
DO $$
DECLARE j uuid := current_setting('test.j1')::uuid; t uuid := '60a00000-0000-7000-8000-000000000001'; v uuid; s uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  UPDATE migration.job SET status = 'mapping' WHERE id = j;
  s := public.mg_party(j, 'C001');
  PERFORM public.mg_expect_error('T08 lineage unique per entity (INV-MIG-06)', format($q$SELECT public.mg_party(%L, 'C001')$q$, j), '23505');
  PERFORM public.mg_expect_error('T08 lineage immutable',
    format($q$UPDATE migration.staged_record SET source_key = 'C002' WHERE id = %L$q$, s), 'HK_MIG_IMMUTABLE_FIELD');
  PERFORM public.mg_expect_error('T08 monetary rows declare their unit (INV-MIG-02)',
    format($q$INSERT INTO migration.staged_record (tenant_id, job_id, entity, source_system, source_db, source_table, source_key, amount)
              VALUES (%L, %L, 'open_document', 'holoo', 'Holoo1', 'FACTURE', 'F1', 1000)$q$, t, j), '23514');
  PERFORM public.mg_expect_error('T08 line needs a parent',
    format($q$INSERT INTO migration.staged_record (tenant_id, job_id, entity, source_system, source_db, source_table, source_key, debit, amount_unit)
              VALUES (%L, %L, 'voucher_line', 'holoo', 'Holoo1', 'SND_LIST', 'x:1', 10, 'IRR')$q$, t, j), '23514');
  PERFORM public.mg_expect_error('T08 line parent must be a voucher',
    format($q$INSERT INTO migration.staged_record (tenant_id, job_id, parent_id, entity, source_system, source_db, source_table, source_key, debit, amount_unit)
              VALUES (%L, %L, %L, 'voucher_line', 'holoo', 'Holoo1', 'SND_LIST', 'x:1', 10, 'IRR')$q$, t, j, s), 'HK_MIG_PARENT_KIND');
  INSERT INTO migration.staged_record (tenant_id, id, job_id, entity, source_system, source_db, source_table, source_key, amount_unit)
  VALUES (t, uuidv7(), j, 'voucher', 'holoo', 'Holoo1', 'SANAD', '900', 'IRR') RETURNING id INTO v;
  PERFORM public.mg_expect_error('T08 line has exactly one positive side (both)',
    format($q$INSERT INTO migration.staged_record (tenant_id, job_id, parent_id, entity, source_system, source_db, source_table, source_key, debit, credit, amount_unit)
              VALUES (%L, %L, %L, 'voucher_line', 'holoo', 'Holoo1', 'SND_LIST', '900:1', 10, 10, 'IRR')$q$, t, j, v), '23514');
  PERFORM public.mg_expect_error('T08 line has exactly one positive side (zero)',
    format($q$INSERT INTO migration.staged_record (tenant_id, job_id, parent_id, entity, source_system, source_db, source_table, source_key, debit, amount_unit)
              VALUES (%L, %L, %L, 'voucher_line', 'holoo', 'Holoo1', 'SND_LIST', '900:1', 0, 'IRR')$q$, t, j, v), '23514');
  PERFORM public.mg_expect_error('T08 excluded rows need a reason',
    format($q$INSERT INTO migration.staged_record (tenant_id, job_id, parent_id, entity, source_system, source_db, source_table, source_key, debit, amount_unit, status)
              VALUES (%L, %L, %L, 'voucher_line', 'holoo', 'Holoo1', 'SND_LIST', '900:1', 0, 'IRR', 'excluded')$q$, t, j, v), '23514');
  -- بهای نامعلوم: NULL می‌ماند، نه صفر (INV-MIG-11)
  PERFORM public.mg_expect_error('T08 stock opening needs a cost status',
    format($q$INSERT INTO migration.staged_record (tenant_id, job_id, entity, source_system, source_db, source_table, source_key, qty, amount_unit)
              VALUES (%L, %L, 'stock_opening', 'holoo', 'Holoo1', 'ARTICLE', 'A1:W1', 5, 'IRR')$q$, t, j), '23514');
  PERFORM public.mg_expect_error('T08 unknown cost cannot carry a cost',
    format($q$INSERT INTO migration.staged_record (tenant_id, job_id, entity, source_system, source_db, source_table, source_key, qty, unit_cost, cost_status, amount_unit)
              VALUES (%L, %L, 'stock_opening', 'holoo', 'Holoo1', 'ARTICLE', 'A1:W1', 5, 0, 'unknown', 'IRR')$q$, t, j), '23514');
  PERFORM public.mg_expect_error('T08 zero cost is never assumed (known 0)',
    format($q$INSERT INTO migration.staged_record (tenant_id, job_id, entity, source_system, source_db, source_table, source_key, qty, unit_cost, cost_status, amount_unit)
              VALUES (%L, %L, 'stock_opening', 'holoo', 'Holoo1', 'ARTICLE', 'A1:W1', 5, 0, 'known', 'IRR')$q$, t, j), '23514');
  PERFORM public.mg_expect_error('T08 known cost needs a value',
    format($q$INSERT INTO migration.staged_record (tenant_id, job_id, entity, source_system, source_db, source_table, source_key, qty, cost_status, amount_unit)
              VALUES (%L, %L, 'stock_opening', 'holoo', 'Holoo1', 'ARTICLE', 'A1:W1', 5, 'known', 'IRR')$q$, t, j), '23514');
  INSERT INTO migration.staged_record (tenant_id, job_id, entity, source_system, source_db, source_table, source_key, qty, cost_status, amount_unit)
  VALUES (t, j, 'stock_opening', 'holoo', 'Holoo1', 'ARTICLE', 'A1:W1', 5, 'unknown', 'IRR');
  INSERT INTO migration.staged_record (tenant_id, job_id, entity, source_system, source_db, source_table, source_key, qty, unit_cost, cost_status, amount_unit)
  VALUES (t, j, 'stock_opening', 'holoo', 'Holoo1', 'ARTICLE', 'A2:W1', 2, 0, 'user_provided', 'IRR');
  PERFORM set_config('test.v900', v::text, false);
END $$;

-- T09: پارتیشن انحصاری و سیاست کلاس (INV-MIG-08)
DO $$
DECLARE j uuid := current_setting('test.j1')::uuid; t uuid := '60a00000-0000-7000-8000-000000000001'; v uuid := current_setting('test.v900')::uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T09 class without policy',
    format($q$UPDATE migration.staged_record SET partition_class = 'MANUAL', disposition = 'history_gl' WHERE id = %L$q$, v), 'HK_MIG_PARTITION_POLICY: no disposition policy');
  PERFORM public.mg_expect_error('T09 disposition must be allowed for the class',
    format($q$INSERT INTO migration.job_partition_policy (tenant_id, job_id, partition_class, disposition) VALUES (%L, %L, 'MANUAL', 'regenerate')$q$, t, j),
    '23503');
  PERFORM public.mg_expect_error('T09 unclassified can only be blocked',
    format($q$INSERT INTO migration.job_partition_policy (tenant_id, job_id, partition_class, disposition) VALUES (%L, %L, 'UNCLASSIFIED', 'history_gl')$q$, t, j),
    '23503');
  INSERT INTO migration.job_partition_policy (tenant_id, job_id, partition_class, disposition, chosen_by) VALUES
    (t, j, 'MANUAL', 'history_gl', '60a00000-0000-7000-8000-0000000000a2'),
    (t, j, 'INVOICE', 'regenerate', '60a00000-0000-7000-8000-0000000000a2'),
    (t, j, 'UNCLASSIFIED', 'blocked', '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T09 policy key immutable',
    format($q$UPDATE migration.job_partition_policy SET partition_class = 'CHEQUE' WHERE job_id = %L AND partition_class = 'INVOICE'$q$, j), 'HK_MIG_IMMUTABLE_FIELD');
  PERFORM public.mg_expect_error('T09 one disposition per class per job',
    format($q$INSERT INTO migration.job_partition_policy (tenant_id, job_id, partition_class, disposition) VALUES (%L, %L, 'MANUAL', 'archive')$q$, t, j), '23505');
  PERFORM public.mg_expect_error('T09 voucher disposition must equal the job policy',
    format($q$UPDATE migration.staged_record SET partition_class = 'INVOICE', disposition = 'history_gl' WHERE id = %L$q$, v), 'HK_MIG_PARTITION_POLICY');
  PERFORM public.mg_expect_error('T09 class without disposition',
    format($q$UPDATE migration.staged_record SET partition_class = 'MANUAL' WHERE id = %L$q$, v), 'HK_MIG_PARTITION_POLICY');
  PERFORM public.mg_expect_error('T09 only vouchers are partitioned',
    format($q$UPDATE migration.staged_record SET partition_class = 'MANUAL', disposition = 'history_gl' WHERE job_id = %L AND entity = 'party'$q$, j), '23514');
  UPDATE migration.staged_record SET partition_class = 'MANUAL', disposition = 'history_gl' WHERE id = v;
  PERFORM public.mg_expect_error('T09 a non-pending voucher needs a class',
    format($q$UPDATE migration.staged_record SET partition_class = NULL, disposition = NULL, status = 'blocked' WHERE id = %L$q$, v), '23514');
END $$;

-- T10: سند مسدود و نامتوازن هرگز معتبر نمی‌شود (INV-MIG-12، INV-MIG-15)
DO $$
DECLARE j uuid := current_setting('test.j1')::uuid; t uuid := '60a00000-0000-7000-8000-000000000001'; v uuid := current_setting('test.v900')::uuid;
        l1 uuid; l2 uuid; vu uuid; vi uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T10 staged rows start pending',
    format($q$INSERT INTO migration.staged_record (tenant_id, job_id, parent_id, entity, source_system, source_db, source_table, source_key, line_no, debit, amount_unit, status)
              VALUES (%L, %L, %L, 'voucher_line', 'holoo', 'Holoo1', 'SND_LIST', '900:1', 1, 1000, 'IRR', 'valid')$q$, t, j, v), 'HK_MIG_STAGED_TRANSITION');
  INSERT INTO migration.staged_record (tenant_id, id, job_id, parent_id, entity, source_system, source_db, source_table, source_key, line_no, debit, amount_unit)
  VALUES (t, uuidv7(), j, v, 'voucher_line', 'holoo', 'Holoo1', 'SND_LIST', '900:1', 1, 1000, 'IRR') RETURNING id INTO l1;
  INSERT INTO migration.staged_record (tenant_id, id, job_id, parent_id, entity, source_system, source_db, source_table, source_key, line_no, credit, amount_unit)
  VALUES (t, uuidv7(), j, v, 'voucher_line', 'holoo', 'Holoo1', 'SND_LIST', '900:2', 2, 900, 'IRR') RETURNING id INTO l2;
  UPDATE migration.staged_record SET status = 'valid' WHERE id IN (l1, l2);
  PERFORM public.mg_expect_error('T10 unbalanced voucher never valid',
    format($q$UPDATE migration.staged_record SET status = 'valid' WHERE id = %L$q$, v), 'HK_MIG_VOUCHER_UNBALANCED');
  UPDATE migration.staged_record SET credit = 1000 WHERE id = l2;
  UPDATE migration.staged_record SET status = 'valid' WHERE id = v;
  -- سطر بی‌نگاشت کل سند را مسدود می‌کند (rule: reject rather than guess)
  UPDATE migration.staged_record SET status = 'blocked' WHERE id = l2;
  PERFORM public.mg_assert((SELECT status FROM migration.staged_record WHERE id = v) = 'blocked', 'T10 blocked line blocks its voucher');
  PERFORM public.mg_expect_error('T10 voucher with blocked line cannot be valid',
    format($q$UPDATE migration.staged_record SET status = 'valid' WHERE id = %L$q$, v), 'HK_MIG_VOUCHER_BLOCKED');
  UPDATE migration.staged_record SET status = 'valid', mapped = '{"account":"1101"}' WHERE id = l2;
  UPDATE migration.staged_record SET status = 'valid' WHERE id = v;
  -- تغییر محتوای سطر، سند معتبر را به pending برمی‌گرداند
  UPDATE migration.staged_record SET mapped = '{"account":"1102"}' WHERE id = l2;
  PERFORM public.mg_assert((SELECT status FROM migration.staged_record WHERE id = v) = 'pending', 'T10 line change re-opens voucher validation');
  UPDATE migration.staged_record SET status = 'valid' WHERE id = v;
  -- سند فاکتوری (regenerate) و سند ناشناس
  INSERT INTO migration.staged_record (tenant_id, id, job_id, entity, source_system, source_db, source_table, source_key, amount_unit, partition_class, disposition)
  VALUES (t, uuidv7(), j, 'voucher', 'holoo', 'Holoo1', 'SANAD', '102', 'IRR', 'INVOICE', 'regenerate') RETURNING id INTO vi;
  INSERT INTO migration.staged_record (tenant_id, job_id, parent_id, entity, source_system, source_db, source_table, source_key, line_no, debit, amount_unit) VALUES
    (t, j, vi, 'voucher_line', 'holoo', 'Holoo1', 'SND_LIST', '102:1', 1, 500, 'IRR');
  INSERT INTO migration.staged_record (tenant_id, job_id, parent_id, entity, source_system, source_db, source_table, source_key, line_no, credit, amount_unit) VALUES
    (t, j, vi, 'voucher_line', 'holoo', 'Holoo1', 'SND_LIST', '102:2', 2, 500, 'IRR');
  UPDATE migration.staged_record SET status = 'valid' WHERE parent_id = vi;
  UPDATE migration.staged_record SET status = 'valid' WHERE id = vi;
  INSERT INTO migration.staged_record (tenant_id, id, job_id, entity, source_system, source_db, source_table, source_key, amount_unit, partition_class, disposition, status)
  VALUES (t, uuidv7(), j, 'voucher', 'holoo', 'Holoo1', 'SANAD', '103', 'IRR', 'UNCLASSIFIED', 'blocked', 'blocked') RETURNING id INTO vu;
  PERFORM public.mg_expect_error('T10 unclassified voucher stays blocked',
    format($q$UPDATE migration.staged_record SET status = 'valid' WHERE id = %L$q$, vu), 'HK_MIG_UNCLASSIFIED');
  PERFORM public.mg_expect_error('T10 policy frozen once vouchers are classified',
    format($q$UPDATE migration.job_partition_policy SET disposition = 'archive' WHERE job_id = %L AND partition_class = 'MANUAL'$q$, j), 'HK_MIG_PARTITION_POLICY');
  PERFORM public.mg_expect_error('T10 policy cannot be deleted once vouchers are classified',
    format($q$DELETE FROM migration.job_partition_policy WHERE job_id = %L AND partition_class = 'MANUAL'$q$, j), 'HK_MIG_PARTITION_POLICY: reset the vouchers');
  -- فاکتور تاریخچه با سطر مسدود
  INSERT INTO migration.staged_record (tenant_id, id, job_id, entity, source_system, source_db, source_table, source_key, amount_unit)
  VALUES (t, '60a00000-0000-7000-8000-00000000f100', j, 'invoice_history', 'holoo', 'Holoo1', 'FACTURE', 'F:100', 'IRR');
  INSERT INTO migration.staged_record (tenant_id, id, job_id, parent_id, entity, source_system, source_db, source_table, source_key, line_no, amount, amount_unit, status)
  VALUES (t, '60a00000-0000-7000-8000-00000000f101', j, '60a00000-0000-7000-8000-00000000f100', 'invoice_line_history', 'holoo', 'Holoo1', 'FACTART', 'F:100:1', 1, 500, 'IRR', 'blocked');
  PERFORM public.mg_assert((SELECT status FROM migration.staged_record WHERE id = '60a00000-0000-7000-8000-00000000f100') = 'blocked', 'T10 blocked invoice line blocks the invoice');
  PERFORM public.mg_expect_error('T10 invoice with a blocked line cannot be valid',
    $q$UPDATE migration.staged_record SET status = 'valid' WHERE id = '60a00000-0000-7000-8000-00000000f100'$q$, 'HK_MIG_VOUCHER_BLOCKED: an invoice');
  UPDATE migration.staged_record SET status = 'valid' WHERE id = '60a00000-0000-7000-8000-00000000f101';
  UPDATE migration.staged_record SET status = 'valid' WHERE id = '60a00000-0000-7000-8000-00000000f100';
  PERFORM set_config('test.vu', vu::text, false);
  PERFORM set_config('test.vi', vi::text, false);
END $$;

-- T11: نگاشت‌ها (INV-MIG-09، INV-MIG-10، INV-MIG-25)
DO $$
DECLARE j uuid := current_setting('test.j1')::uuid; t uuid := '60a00000-0000-7000-8000-000000000001'; m uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T11 fuzzy suggestion needs a human to confirm',
    format($q$INSERT INTO migration.mapping (tenant_id, job_id, kind, scope, source_value, source_value_norm, target_value, method, confidence, status)
              VALUES (%L, %L, 'column', 'T03', 'نام مشتری', 'نام مشتری', 'party_name', 'fuzzy', 0.9, 'confirmed')$q$, t, j), '23514');
  PERFORM public.mg_expect_error('T11 bank mapping never by synonym alone (no first-bank guess)',
    format($q$INSERT INTO migration.mapping (tenant_id, job_id, kind, scope, source_value, source_value_norm, target_ref, method, confidence, status)
              VALUES (%L, %L, 'bank_account', 'ACOUND_N', 'ملت', 'ملت', uuidv7(), 'synonym', 1, 'confirmed')$q$, t, j), '23514');
  PERFORM public.mg_expect_error('T11 account mapping by tenant memory still needs confirmation',
    format($q$INSERT INTO migration.mapping (tenant_id, job_id, kind, scope, source_value, source_value_norm, target_ref, method, confidence, status)
              VALUES (%L, %L, 'account', 'SARFASL', '102-0001', '102-0001', uuidv7(), 'tenant_memory', 1, 'confirmed')$q$, t, j), '23514');
  INSERT INTO migration.mapping (tenant_id, job_id, kind, scope, source_value, source_value_norm, target_ref, method, confidence, status)
  VALUES (t, j, 'bank_account', 'ACOUND_N', '0101234567', '0101234567', uuidv7(), 'exact_identifier', 1, 'confirmed');
  INSERT INTO migration.mapping (tenant_id, job_id, kind, scope, source_value, source_value_norm, target_ref, method, confidence, status, confirmed_by, confirmed_at)
  VALUES (t, j, 'account', 'SARFASL', '901', '901', uuidv7(), 'profile', 0.95, 'confirmed', '60a00000-0000-7000-8000-0000000000a2', now());
  PERFORM public.mg_expect_error('T11 assistant suggestions are job-scoped',
    format($q$INSERT INTO migration.mapping (tenant_id, job_id, kind, scope, source_value, source_value_norm, target_value, method, confidence)
              VALUES (%L, NULL, 'column', 'T03', 'نام', 'نام', 'first_name', 'ai_suggestion', 0.7)$q$, t), '23514');
  INSERT INTO migration.mapping (tenant_id, id, job_id, kind, scope, source_value, source_value_norm, target_value, method, confidence)
  VALUES (t, uuidv7(), j, 'column', 'T03', 'نام خانوادگي', migration.norm_header('نام خانوادگي'), 'last_name', 'ai_suggestion', 0.7) RETURNING id INTO m;
  PERFORM public.mg_expect_error('T11 assistant suggestion confirm without human',
    format($q$UPDATE migration.mapping SET status = 'confirmed' WHERE id = %L$q$, m), '23514');
  UPDATE migration.mapping SET status = 'confirmed', confirmed_by = '60a00000-0000-7000-8000-0000000000a2', confirmed_at = now() WHERE id = m;
  PERFORM public.mg_expect_error('T11 mapping key immutable',
    format($q$UPDATE migration.mapping SET scope = 'T04' WHERE id = %L$q$, m), 'HK_MIG_IMMUTABLE_FIELD');
  PERFORM public.mg_expect_error('T11 column mapping keyed by normalized header',
    format($q$INSERT INTO migration.mapping (tenant_id, job_id, kind, scope, source_value, source_value_norm, target_value, method, confidence)
              VALUES (%L, %L, 'column', 'T03', 'كد ملي', 'كد ملي', 'national_code', 'synonym', 1)$q$, t, j), 'HK_MIG_HEADER_NORM');
  PERFORM public.mg_expect_error('T11 one active mapping per key',
    format($q$INSERT INTO migration.mapping (tenant_id, job_id, kind, scope, source_value, source_value_norm, target_value, method, confidence)
              VALUES (%L, %L, 'column', 'T03', 'نام خانوادگی', 'نام خانوادگی', 'party_name', 'manual', 1)$q$, t, j), '23505');
  -- حافظهٔ مستأجر (job_id NULL)
  INSERT INTO migration.mapping (tenant_id, kind, source_system, scope, source_value, source_value_norm, target_value, method, confidence, status, confirmed_by, confirmed_at)
  VALUES (t, 'value_unit', 'holoo', 'UNIT', 'عدد', 'عدد', 'PCS', 'manual', 1, 'confirmed', '60a00000-0000-7000-8000-0000000000a2', now());
END $$;

-- T12: مشکل اعتبارسنجی و override (INV-MIG-16)
DO $$
DECLARE j uuid := current_setting('test.j1')::uuid; t uuid := '60a00000-0000-7000-8000-000000000001'; i1 uuid; i2 uuid; s uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  SELECT id INTO s FROM migration.staged_record WHERE job_id = j AND entity = 'party' LIMIT 1;
  PERFORM public.mg_expect_error('T12 severity comes from the catalog',
    format($q$INSERT INTO migration.issue (tenant_id, job_id, staged_record_id, code, severity) VALUES (%L, %L, %L, 'MIG_VOUCHER_UNBALANCED', 'warning')$q$, t, j, s),
    'HK_MIG_ISSUE_SEVERITY');
  PERFORM public.mg_expect_error('T12 issues start open',
    format($q$INSERT INTO migration.issue (tenant_id, job_id, staged_record_id, code, severity, status, resolved_at) VALUES (%L, %L, %L, 'MIG_ACCOUNT_UNMAPPED', 'error', 'resolved', now())$q$, t, j, s),
    'HK_MIG_ISSUE_TRANSITION: issues start open');
  INSERT INTO migration.issue (tenant_id, id, job_id, staged_record_id, code, severity, field, params)
  VALUES (t, uuidv7(), j, s, 'MIG_NATIONAL_CODE_CHECKSUM', 'error', 'national_code', '{"value":"0012345678"}') RETURNING id INTO i1;
  INSERT INTO migration.issue (tenant_id, id, job_id, staged_record_id, code, severity)
  VALUES (t, uuidv7(), j, s, 'MIG_ACCOUNT_UNMAPPED', 'error') RETURNING id INTO i2;
  PERFORM public.mg_expect_error('T12 non-overridable error cannot be overridden',
    format($q$UPDATE migration.issue SET status = 'overridden', override_reason = 'حساب را بعداً درست می‌کنیم', overridden_by = '60a00000-0000-7000-8000-0000000000a2', overridden_at = now() WHERE id = %L$q$, i2),
    'HK_MIG_NOT_OVERRIDABLE');
  PERFORM public.mg_expect_error('T12 override needs a reason ≥ 10 chars',
    format($q$UPDATE migration.issue SET status = 'overridden', override_reason = 'ok', overridden_by = '60a00000-0000-7000-8000-0000000000a2', overridden_at = now() WHERE id = %L$q$, i1),
    '23514');
  UPDATE migration.issue SET status = 'overridden', override_reason = 'کد ملی از کارت ملی بررسی و تأیید شد',
         overridden_by = '60a00000-0000-7000-8000-0000000000a2', overridden_at = now() WHERE id = i1;
  PERFORM public.mg_expect_error('T12 overridden is final',
    format($q$UPDATE migration.issue SET status = 'open', override_reason = NULL, overridden_by = NULL, overridden_at = NULL WHERE id = %L$q$, i1),
    'HK_MIG_ISSUE_TRANSITION');
  PERFORM public.mg_expect_error('T12 issue immutable', format($q$UPDATE migration.issue SET params = '{"x":1}' WHERE id = %L$q$, i2), 'HK_MIG_IMMUTABLE_FIELD');
  PERFORM public.mg_expect_error('T12 issue delete forbidden (no grant)', format($q$DELETE FROM migration.issue WHERE id = %L$q$, i2), '42501');
  PERFORM set_config('test.i2', i2::text, false);
END $$;

-- T13: دروازهٔ اعتبارسنجی (validated)
DO $$
DECLARE j uuid := current_setting('test.j1')::uuid; t uuid := '60a00000-0000-7000-8000-000000000001';
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T13 unit must be confirmed',
    format($q$UPDATE migration.job SET status = 'validated', fiscal_year_id = '60a00000-0000-7000-8000-0000000000f1' WHERE id = %L$q$, j), 'HK_MIG_UNIT_UNCONFIRMED');
  UPDATE migration.job SET amount_unit_confirmed_by = '60a00000-0000-7000-8000-0000000000a2', amount_unit_confirmed_at = now() WHERE id = j;
  UPDATE migration.job SET amount_unit = 'IRT' WHERE id = j;
  PERFORM public.mg_assert((SELECT amount_unit_confirmed_at IS NULL AND amount_unit_confirmed_by IS NULL FROM migration.job WHERE id = j),
                           'T13 changing the unit drops the confirmation');
  UPDATE migration.job SET amount_unit = 'IRR', amount_unit_confirmed_by = '60a00000-0000-7000-8000-0000000000a2', amount_unit_confirmed_at = now() WHERE id = j;
  PERFORM public.mg_expect_error('T13 fiscal year required',
    format($q$UPDATE migration.job SET status = 'validated' WHERE id = %L$q$, j), 'HK_MIG_NO_FISCAL_YEAR');
  PERFORM public.mg_expect_error('T13 fiscal year must belong to the job company',
    format($q$UPDATE migration.job SET fiscal_year_id = '60a00000-0000-7000-8000-0000000000f2' WHERE id = %L$q$, j), '23503');
  UPDATE migration.job SET fiscal_year_id = '60a00000-0000-7000-8000-0000000000f1' WHERE id = j;
  PERFORM public.mg_expect_error('T13 open error issues block validation',
    format($q$UPDATE migration.job SET status = 'validated' WHERE id = %L$q$, j), 'HK_MIG_OPEN_ERRORS');
  UPDATE migration.issue SET status = 'resolved', resolved_at = now() WHERE id = current_setting('test.i2')::uuid;
  PERFORM public.mg_expect_error('T13 pending or blocked rows block validation',
    format($q$UPDATE migration.job SET status = 'validated' WHERE id = %L$q$, j), 'HK_MIG_UNRESOLVED_RECORDS');
  UPDATE migration.staged_record SET status = 'excluded', exclusion_reason = 'سند ناشناس به آرشیو منتقل شد'
   WHERE id = current_setting('test.vu')::uuid;
  UPDATE migration.staged_record SET status = 'valid' WHERE job_id = j AND status = 'pending' AND parent_id IS NULL;
  PERFORM public.mg_expect_error('T13 rows are committed only by the commit stage',
    format($q$UPDATE migration.staged_record SET status = 'committed', committed_chunk = 1 WHERE job_id = %L AND entity = 'party'$q$, j),
    'HK_MIG_STAGED_FROZEN: rows are committed only');
  PERFORM public.mg_expect_error('T13 only committed rows are rolled back',
    format($q$UPDATE migration.staged_record SET status = 'rolled_back' WHERE job_id = %L AND entity = 'party'$q$, j),
    'HK_MIG_STAGED_TRANSITION: only committed');
  UPDATE migration.job SET status = 'validated' WHERE id = j;
  -- INV-MIG-13: پس از validated ورودی‌ها منجمدند
  PERFORM public.mg_expect_error('T13 staged rows frozen after validation',
    format($q$UPDATE migration.staged_record SET normalized = '{"x":1}' WHERE job_id = %L AND entity = 'party'$q$, j), 'HK_MIG_INPUTS_FROZEN');
  PERFORM public.mg_expect_error('T13 mappings frozen after validation',
    format($q$INSERT INTO migration.mapping (tenant_id, job_id, kind, scope, source_value, source_value_norm, target_value, method, confidence)
              VALUES (%L, %L, 'column', 'T04', 'بارکد', 'بارکد', 'barcode', 'synonym', 1)$q$, t, j), 'HK_MIG_JOB_STATE');
  PERFORM public.mg_expect_error('T13 staging blocked after validation', format($q$SELECT public.mg_party(%L, 'C999')$q$, j), 'HK_MIG_JOB_STATE');
END $$;

-- T14: dry-run و پیش‌نمایش (INV-MIG-13)
DO $$
DECLARE j uuid := current_setting('test.j1')::uuid; t uuid := '60a00000-0000-7000-8000-000000000001'; h bytea := public.mg_sha('in-1');
        d1 uuid := uuidv7(); d2 uuid := uuidv7();
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  UPDATE migration.job SET inputs_hash = h WHERE id = j;
  PERFORM public.mg_expect_error('T14 dry-run seq gapless',
    format($q$INSERT INTO migration.dry_run (tenant_id, job_id, seq, run_mode, inputs_hash, started_at, outcome, report, report_sha256)
              VALUES (%L, %L, 2, 'full_tx', %L, now(), 'ok', '{}', sha256('r'))$q$, t, j, h), 'HK_MIG_SEQ');
  INSERT INTO migration.dry_run (tenant_id, id, job_id, seq, run_mode, inputs_hash, started_at, outcome, report, report_sha256, error_code)
  VALUES (t, d1, j, 1, 'full_tx', h, now(), 'failed', '{"error":"unbalanced"}', public.mg_sha('r1'), 'HK_LEDGER_JOURNAL_UNBALANCED');
  PERFORM public.mg_expect_error('T14 failed dry-run cannot be previewed',
    format($q$UPDATE migration.job SET preview_dry_run_id = %L, status = 'previewed' WHERE id = %L$q$, d1, j), 'HK_MIG_DRY_RUN_REQUIRED');
  INSERT INTO migration.dry_run (tenant_id, id, job_id, seq, run_mode, inputs_hash, started_at, outcome, report, report_sha256)
  VALUES (t, d2, j, 2, 'full_tx', public.mg_sha('stale'), now(), 'ok', '{}', public.mg_sha('r2'));
  PERFORM public.mg_expect_error('T14 dry-run over other inputs cannot be previewed',
    format($q$UPDATE migration.job SET preview_dry_run_id = %L, status = 'previewed' WHERE id = %L$q$, d2, j), 'HK_MIG_DRY_RUN_REQUIRED');
  PERFORM public.mg_expect_error('T14 dry-run is append-only (no grant)', format($q$UPDATE migration.dry_run SET outcome = 'ok' WHERE id = %L$q$, d1), '42501');
  PERFORM public.mg_expect_error('T14 accept preview only while previewed',
    format($q$UPDATE migration.job SET preview_accepted_by = '60a00000-0000-7000-8000-0000000000a2', preview_accepted_at = now() WHERE id = %L$q$, j),
    'HK_MIG_PREVIEW_STATE');
  INSERT INTO migration.dry_run (tenant_id, id, job_id, seq, run_mode, inputs_hash, started_at, outcome, report, report_sha256)
  VALUES (t, uuidv7(), j, 3, 'full_tx', h, now(), 'ok', '{"tb":"balanced"}', public.mg_sha('r3'));
  UPDATE migration.job SET preview_dry_run_id = (SELECT id FROM migration.dry_run WHERE job_id = j AND seq = 3), status = 'previewed' WHERE id = j;
  PERFORM public.mg_expect_error('T14 inputs frozen after preview',
    format($q$UPDATE migration.job SET cutover_date = DATE '2026-06-22' WHERE id = %L$q$, j), 'HK_MIG_INPUTS_FROZEN');
  PERFORM public.mg_expect_error('T14 dry-run only on validated jobs',
    format($q$INSERT INTO migration.dry_run (tenant_id, job_id, seq, run_mode, inputs_hash, started_at, outcome, report, report_sha256)
              VALUES (%L, %L, 4, 'full_tx', %L, now(), 'ok', '{}', sha256('r'))$q$, t, j, h), 'HK_MIG_JOB_STATE');
  PERFORM public.mg_expect_error('T14 commit needs an accepted preview',
    format($q$UPDATE migration.job SET status = 'committing' WHERE id = %L$q$, j), 'HK_MIG_PREVIEW_NOT_ACCEPTED');
  UPDATE migration.job SET preview_accepted_by = '60a00000-0000-7000-8000-0000000000a2', preview_accepted_at = now() WHERE id = j;
  UPDATE migration.job SET preview_dry_run_id = d2 WHERE id = j;
  PERFORM public.mg_expect_error('T14 commit refuses a preview whose dry-run is over other inputs',
    format($q$UPDATE migration.job SET status = 'committing' WHERE id = %L$q$, j), 'HK_MIG_DRY_RUN_REQUIRED: inputs changed');
  UPDATE migration.job SET preview_dry_run_id = (SELECT id FROM migration.dry_run WHERE job_id = j AND seq = 3) WHERE id = j;
END $$;

-- T15: ثبت تکه‌ای، ترتیب وابستگی، دفتر اثرها (INV-MIG-03، 08، 14، 18)
DO $$
DECLARE j uuid := current_setting('test.j1')::uuid; t uuid := '60a00000-0000-7000-8000-000000000001'; v uuid := current_setting('test.v900')::uuid;
        vi uuid := current_setting('test.vi')::uuid; s uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  INSERT INTO migration.commit_chunk (tenant_id, job_id, chunk_no, stage, item_count) VALUES (t, j, 1, 'masterdata', 1), (t, j, 2, 'history_gl', 2);
  PERFORM public.mg_expect_error('T15 chunks start pending',
    format($q$INSERT INTO migration.commit_chunk (tenant_id, job_id, chunk_no, stage, item_count, status) VALUES (%L, %L, 3, 'payroll', 0, 'done')$q$, t, j),
    'HK_MIG_CHUNK_TRANSITION');
  PERFORM public.mg_expect_error('T15 commit plan immutable',
    format($q$UPDATE migration.commit_chunk SET item_count = 5 WHERE job_id = %L AND chunk_no = 2$q$, j), 'HK_MIG_IMMUTABLE_FIELD: the commit plan');
  PERFORM public.mg_expect_error('T15 pending chunk cannot fail directly',
    format($q$UPDATE migration.commit_chunk SET status = 'failed', last_error = '{"e":1}' WHERE job_id = %L AND chunk_no = 2$q$, j), 'HK_MIG_CHUNK_TRANSITION');
  PERFORM public.mg_expect_error('T15 chunk runs only while committing',
    format($q$UPDATE migration.commit_chunk SET status = 'running' WHERE job_id = %L AND chunk_no = 1$q$, j), 'HK_MIG_JOB_STATE');
  UPDATE migration.job SET status = 'committing' WHERE id = j;
  PERFORM public.mg_expect_error('T15 dependency order: chunk 2 waits for chunk 1',
    format($q$UPDATE migration.commit_chunk SET status = 'running' WHERE job_id = %L AND chunk_no = 2$q$, j), 'HK_MIG_CHUNK_ORDER');
  SELECT id INTO s FROM migration.staged_record WHERE job_id = j AND entity = 'party' LIMIT 1;
  PERFORM public.mg_expect_error('T15 postings only inside a running chunk',
    format($q$INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
               target_module, target_doc_type, target_doc_id, gl_effect)
              VALUES (%L, %L, 1, %L, 'holoo', 'Holoo1', 'CUSTOMER', 'C001', 'parties', 'parties.party', uuidv7(), 'none')$q$, t, j, s), 'HK_MIG_CHUNK_STATE');
  UPDATE migration.commit_chunk SET status = 'running' WHERE job_id = j AND chunk_no = 1;
  PERFORM public.mg_assert((SELECT attempts FROM migration.commit_chunk WHERE job_id = j AND chunk_no = 1) = 1, 'T15 attempts counted');
  PERFORM public.mg_expect_error('T15 posting lineage equals staged lineage',
    format($q$INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
               target_module, target_doc_type, target_doc_id, gl_effect)
              VALUES (%L, %L, 1, %L, 'holoo', 'Holoo1', 'CUSTOMER', 'C777', 'parties', 'parties.party', uuidv7(), 'none')$q$, t, j, s), 'HK_MIG_LINEAGE');
  PERFORM public.mg_expect_error('T15 postings start live',
    format($q$INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
               target_module, target_doc_type, target_doc_id, gl_effect, state, compensated_at)
              VALUES (%L, %L, 1, %L, 'holoo', 'Holoo1', 'CUSTOMER', 'C001', 'parties', 'parties.party', uuidv7(), 'none', 'compensated', now())$q$, t, j, s),
    'HK_MIG_POSTING_TRANSITION: postings start live');
  INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
                                 target_module, target_doc_type, target_doc_id, gl_effect)
  VALUES (t, j, 1, s, 'holoo', 'Holoo1', 'CUSTOMER', 'C001', 'parties', 'parties.party', uuidv7(), 'none');
  PERFORM public.mg_expect_error('T15 excluded rows are never committed',
    format($q$UPDATE migration.staged_record SET status = 'committed', committed_chunk = 1 WHERE id = %L$q$, current_setting('test.vu')),
    'HK_MIG_STAGED_TRANSITION: cannot commit');
  PERFORM public.mg_expect_error('T15 each source record lives once per target type (INV-MIG-03)',
    format($q$INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
               target_module, target_doc_type, target_doc_id, gl_effect)
              VALUES (%L, %L, 1, %L, 'holoo', 'Holoo1', 'CUSTOMER', 'C001', 'parties', 'parties.party', uuidv7(), 'none')$q$, t, j, s), '23505');
  PERFORM public.mg_expect_error('T15 GL posting needs a journal',
    format($q$INSERT INTO migration.posting (tenant_id, job_id, chunk_no, source_system, source_db, source_table, source_key,
               target_module, target_doc_type, target_doc_id, gl_effect)
              VALUES (%L, %L, 1, 'holoo', 'Holoo1', 'SANAD', '1', 'ledger', 'ledger.journal', uuidv7(), 'posted')$q$, t, j), '23514');
  PERFORM public.mg_expect_error('T15 posting journal must exist in the ledger',
    format($q$INSERT INTO migration.posting (tenant_id, job_id, chunk_no, source_system, source_db, source_table, source_key,
               target_module, target_doc_type, target_doc_id, journal_id, gl_effect)
              VALUES (%L, %L, 1, 'holoo', 'Holoo1', 'SANAD', '1', 'ledger', 'ledger.journal', uuidv7(), uuidv7(), 'posted')$q$, t, j), '23503');
  UPDATE migration.staged_record SET status = 'committed', committed_chunk = 1 WHERE id = s;
  PERFORM public.mg_expect_error('T15 committed row is frozen (INV-MIG-14)',
    format($q$UPDATE migration.staged_record SET normalized = '{"name":"x"}' WHERE id = %L$q$, s), 'HK_MIG_STAGED_FROZEN');
  PERFORM public.mg_expect_error('T15 committed row cannot be deleted',
    format($q$DELETE FROM migration.staged_record WHERE id = %L$q$, s), 'HK_MIG_STAGED_FROZEN');
  PERFORM public.mg_expect_error('T15 done needs all items',
    format($q$UPDATE migration.commit_chunk SET status = 'done' WHERE job_id = %L AND chunk_no = 1$q$, j), '23514');
  UPDATE migration.commit_chunk SET done_count = 1, status = 'done' WHERE job_id = j AND chunk_no = 1;
  PERFORM public.mg_expect_error('T15 done chunk is final',
    format($q$UPDATE migration.commit_chunk SET last_error = '{"x":1}' WHERE job_id = %L AND chunk_no = 1$q$, j), 'HK_MIG_CHUNK_TRANSITION');
  PERFORM public.mg_expect_error('T15 committed needs every chunk done',
    format($q$UPDATE migration.job SET status = 'committed' WHERE id = %L$q$, j), 'HK_MIG_CHUNKS_PENDING');
  UPDATE migration.commit_chunk SET status = 'running' WHERE job_id = j AND chunk_no = 2;
  -- INV-MIG-08: سند فاکتوری (regenerate) دوباره در دفتر کل ثبت نمی‌شود؛ ماژول فروش سند را از فاکتور می‌سازد
  PERFORM public.mg_expect_error('T15 invoice-derived voucher is never re-posted to the GL',
    format($q$INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
               target_module, target_doc_type, target_doc_id, gl_effect)
              VALUES (%L, %L, 2, %L, 'holoo', 'Holoo1', 'SANAD', '102', 'ledger', 'ledger.journal', uuidv7(), 'none')$q$, t, j, vi), 'HK_MIG_DOUBLE_POSTING');
  UPDATE migration.staged_record SET status = 'committed', committed_chunk = 2 WHERE job_id = j AND parent_id IN (v, vi);
  UPDATE migration.staged_record SET status = 'committed', committed_chunk = 2 WHERE id IN (v, vi);
  UPDATE migration.staged_record SET status = 'committed', committed_chunk = 2 WHERE job_id = j AND status IN ('valid','warning');
  UPDATE migration.commit_chunk SET done_count = 2, status = 'done' WHERE job_id = j AND chunk_no = 2;
  UPDATE migration.job SET status = 'committed' WHERE id = j;
  PERFORM public.mg_expect_error('T15 cannot post after commit',
    format($q$INSERT INTO migration.posting (tenant_id, job_id, chunk_no, source_system, source_db, source_table, source_key,
               target_module, target_doc_type, target_doc_id, gl_effect)
              VALUES (%L, %L, 2, 'holoo', 'Holoo1', 'X', '1', 'parties', 'parties.party', uuidv7(), 'none')$q$, t, j), 'HK_MIG_JOB_STATE');
END $$;

-- T16: ارقام مبدأ، توضیح اختلاف و تطبیق (INV-MIG-19، INV-MIG-23)
DO $$
DECLARE j uuid := current_setting('test.j1')::uuid; t uuid := '60a00000-0000-7000-8000-000000000001'; e uuid; e2 uuid; r1 uuid := uuidv7(); r2 uuid := uuidv7();
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T16 money figures need a unit',
    format($q$INSERT INTO migration.source_balance (tenant_id, job_id, origin, as_of, key_kind, key, debit) VALUES (%L, %L, 'tncholoo_api', '2026-09-22', 'account', '101', 1)$q$, t, j),
    '23514');
  INSERT INTO migration.source_balance (tenant_id, job_id, origin, as_of, key_kind, key, debit, raw_text, amount_unit)
  VALUES (t, j, 'tncholoo_api', '2026-09-22', 'account', '102', 325787252, '3.25787252E8', 'IRR'),
         (t, j, 'source_db_query', '2026-09-22', 'account', '102', 325787252, NULL, 'IRR');
  INSERT INTO migration.source_balance (tenant_id, job_id, origin, as_of, key_kind, key, value)
  VALUES (t, j, 'source_db_query', '2026-09-22', 'item_wh_qty', 'A1@W1', 5);
  PERFORM public.mg_expect_error('T16 source figures are append-only',
    format($q$UPDATE migration.source_balance SET debit = 1 WHERE job_id = %L$q$, j), '42501');
  PERFORM public.mg_expect_error('T16 trial-balance gaps cannot be explained as unknown cost',
    format($q$INSERT INTO migration.explanation (tenant_id, job_id, check_kind, key, category, amount, description, created_by)
              VALUES (%L, %L, 'trial_balance', '1401', 'unknown_cost', 100, 'کالاهای بدون بها در مبدأ', '60a00000-0000-7000-8000-0000000000a2')$q$, t, j), '23514');
  PERFORM public.mg_expect_error('T16 explanation needs a real description',
    format($q$INSERT INTO migration.explanation (tenant_id, job_id, check_kind, key, category, amount, description, created_by)
              VALUES (%L, %L, 'stock_value', 'W1', 'unknown_cost', 100, 'کوتاه', '60a00000-0000-7000-8000-0000000000a2')$q$, t, j), '23514');
  PERFORM public.mg_expect_error('T16 explanations start proposed',
    format($q$INSERT INTO migration.explanation (tenant_id, job_id, check_kind, key, category, amount, description, created_by, status, approved_by, approved_at)
              VALUES (%L, %L, 'stock_value', 'W9', 'unknown_cost', 5, 'توضیح آزمون برای حالت آغازین', '60a00000-0000-7000-8000-0000000000a2',
                      'approved', '60a00000-0000-7000-8000-0000000000a2', now())$q$, t, j), 'HK_MIG_EXPLANATION_TRANSITION');
  INSERT INTO migration.explanation (tenant_id, id, job_id, check_kind, key, category, amount, description, created_by)
  VALUES (t, uuidv7(), j, 'stock_value', 'W1', 'unknown_cost', -2500, 'ارزش ۵ عدد کالای A1 در مبدأ بها ندارد', '60a00000-0000-7000-8000-0000000000a2')
  RETURNING id INTO e;
  -- تطبیق با سطر توضیح‌داده‌نشده: نامتوازن
  INSERT INTO migration.reconciliation (tenant_id, id, job_id, seq, as_of, status, line_count, unexplained_count, report_sha256, created_by)
  VALUES (t, r1, j, 1, '2026-09-22', 'differences', 2, 1, public.mg_sha('rec1'), '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T16 proposed explanation does not count',
    format($q$INSERT INTO migration.reconciliation_line (tenant_id, job_id, reconciliation_id, check_kind, key, source_value, target_value, explanation_id)
              VALUES (%L, %L, %L, 'stock_value', 'W1', 2500, 0, %L)$q$, t, j, r1, e), 'HK_MIG_EXPLANATION_MISMATCH');
  INSERT INTO migration.reconciliation_line (tenant_id, job_id, reconciliation_id, check_kind, key, source_value, target_value)
  VALUES (t, j, r1, 'trial_balance', '1101', 1000, 1000), (t, j, r1, 'stock_value', 'W1', 2500, 0);
  PERFORM public.mg_assert((SELECT line_status FROM migration.reconciliation_line WHERE reconciliation_id = r1 AND key = 'W1') = 'unexplained', 'T16 difference unexplained');
  PERFORM public.mg_assert((SELECT difference FROM migration.reconciliation_line WHERE reconciliation_id = r1 AND key = 'W1') = -2500, 'T16 difference = target - source');
  PERFORM public.mg_expect_error('T16 reconciled needs a balanced reconciliation',
    format($q$UPDATE migration.job SET reconciliation_id = %L, status = 'reconciled' WHERE id = %L$q$, r1, j), 'HK_MIG_NOT_RECONCILED');
  PERFORM public.mg_expect_error('T16 reconciliation lines append-only',
    format($q$UPDATE migration.reconciliation_line SET target_value = 2500 WHERE reconciliation_id = %L$q$, r1), '42501');
  PERFORM public.mg_expect_error('T16 reconciliation seq gapless',
    format($q$INSERT INTO migration.reconciliation (tenant_id, job_id, seq, as_of, status, line_count, unexplained_count, report_sha256)
              VALUES (%L, %L, 7, '2026-09-22', 'balanced', 1, 0, sha256('x'))$q$, t, j), 'HK_MIG_SEQ');
  PERFORM public.mg_expect_error('T16 explanation immutable',
    format($q$UPDATE migration.explanation SET description = 'توضیح دیگری برای همین اختلاف' WHERE id = %L$q$, e), 'HK_MIG_IMMUTABLE_FIELD');
  UPDATE migration.explanation SET status = 'approved', approved_by = '60a00000-0000-7000-8000-0000000000a1', approved_at = now() WHERE id = e;
  PERFORM public.mg_expect_error('T16 approved explanation cannot go back to proposed',
    format($q$UPDATE migration.explanation SET status = 'proposed' WHERE id = %L$q$, e), 'HK_MIG_EXPLANATION_TRANSITION');
  -- توضیح با مبلغ متفاوت
  INSERT INTO migration.explanation (tenant_id, id, job_id, check_kind, key, category, amount, description, created_by, status)
  VALUES (t, uuidv7(), j, 'stock_value', 'W2', 'unknown_cost', -10, 'توضیح با مبلغ نادرست برای آزمون', '60a00000-0000-7000-8000-0000000000a2', 'proposed')
  RETURNING id INTO e2;
  UPDATE migration.explanation SET status = 'approved', approved_by = '60a00000-0000-7000-8000-0000000000a1', approved_at = now() WHERE id = e2;
  INSERT INTO migration.reconciliation (tenant_id, id, job_id, seq, as_of, status, line_count, unexplained_count, report_sha256, created_by)
  VALUES (t, r2, j, 2, '2026-09-22', 'balanced', 2, 0, public.mg_sha('rec2'), '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T16 explanation must equal the exact difference',
    format($q$INSERT INTO migration.reconciliation_line (tenant_id, job_id, reconciliation_id, check_kind, key, source_value, target_value, explanation_id)
              VALUES (%L, %L, %L, 'stock_value', 'W2', 2500, 0, %L)$q$, t, j, r2, e2), 'HK_MIG_EXPLANATION_MISMATCH');
  INSERT INTO migration.reconciliation_line (tenant_id, job_id, reconciliation_id, check_kind, key, source_value, target_value, explanation_id)
  VALUES (t, j, r2, 'trial_balance', '1101', 1000, 1000, NULL), (t, j, r2, 'stock_value', 'W1', 2500, 0, e);
  PERFORM public.mg_assert((SELECT line_status FROM migration.reconciliation_line WHERE reconciliation_id = r2 AND key = 'W1') = 'explained', 'T16 explained line');
  PERFORM set_config('test.r2', r2::text, false);
  PERFORM set_config('test.e', e::text, false);
END $$;

-- T17: سرآیند تطبیق با سطرها سازگار (deferred) و دامنهٔ تراز آزمایشی
DO $$
DECLARE j uuid := current_setting('test.j1')::uuid; t uuid := '60a00000-0000-7000-8000-000000000001'; r uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  BEGIN
    r := uuidv7();
    INSERT INTO migration.reconciliation (tenant_id, id, job_id, seq, as_of, status, line_count, unexplained_count, report_sha256)
    VALUES (t, r, j, 3, '2026-09-22', 'balanced', 1, 0, public.mg_sha('rec3'));
    INSERT INTO migration.reconciliation_line (tenant_id, job_id, reconciliation_id, check_kind, key, source_value, target_value)
    VALUES (t, j, r, 'trial_balance', '1101', 1000, 999);
    SET CONSTRAINTS migration.trg_reconciliation_check IMMEDIATE;
    RAISE EXCEPTION 'TEST FAILED [T17 header claims balanced but a line is unexplained]';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'HK_MIG_RECONCILIATION_TOTALS%' THEN RAISE; END IF;
  END;
  BEGIN
    r := uuidv7();
    INSERT INTO migration.reconciliation (tenant_id, id, job_id, seq, as_of, status, line_count, unexplained_count, report_sha256)
    VALUES (t, r, j, 3, '2026-09-22', 'balanced', 1, 0, public.mg_sha('rec3'));
    INSERT INTO migration.reconciliation_line (tenant_id, job_id, reconciliation_id, check_kind, key, source_value, target_value)
    VALUES (t, j, r, 'party', 'C001', 10, 10);
    SET CONSTRAINTS migration.trg_reconciliation_check IMMEDIATE;
    RAISE EXCEPTION 'TEST FAILED [T17 ledger job reconciled without trial balance]';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'HK_MIG_RECONCILIATION_SCOPE%' THEN RAISE; END IF;
  END;
  PERFORM public.mg_expect_error('T17 header status agrees with counts',
    format($q$INSERT INTO migration.reconciliation (tenant_id, job_id, seq, as_of, status, line_count, unexplained_count, report_sha256)
              VALUES (%L, %L, 3, '2026-09-22', 'balanced', 2, 1, sha256('x'))$q$, t, j), '23514');
END $$;

-- T18: آشتی و زنده شدن (INV-MIG-23، INV-MIG-24)
DO $$
DECLARE j uuid := current_setting('test.j1')::uuid; t uuid := '60a00000-0000-7000-8000-000000000001'; r2 uuid := current_setting('test.r2')::uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  UPDATE migration.job SET reconciliation_id = r2, status = 'reconciled' WHERE id = j;
  PERFORM public.mg_expect_error('T18 reconciliation cannot be swapped while reconciled',
    format($q$UPDATE migration.job SET reconciliation_id = (SELECT id FROM migration.reconciliation WHERE job_id = %L AND seq = 1) WHERE id = %L$q$, j, j),
    'HK_MIG_NOT_RECONCILED: move the job back');
  PERFORM public.mg_expect_error('T18 approved explanation cannot be withdrawn while reconciled',
    format($q$UPDATE migration.explanation SET status = 'withdrawn' WHERE id = %L$q$, current_setting('test.e')), 'HK_MIG_JOB_STATE');
  PERFORM public.mg_expect_error('T18 go-live needs the accountant approval',
    format($q$UPDATE migration.job SET status = 'live' WHERE id = %L$q$, j), 'HK_MIG_GOLIVE_APPROVAL');
  PERFORM public.mg_expect_error('T18 go-live approval only with the transition',
    format($q$UPDATE migration.job SET golive_approved_by = '60a00000-0000-7000-8000-0000000000a1', golive_approved_at = now() WHERE id = %L$q$, j),
    'HK_MIG_GOLIVE_STATE');
  UPDATE migration.job SET golive_approved_by = '60a00000-0000-7000-8000-0000000000a1', golive_approved_at = now(),
         golive_client_ip = '10.0.0.7', status = 'live' WHERE id = j;
  PERFORM public.mg_assert((SELECT locked_at IS NOT NULL FROM migration.job WHERE id = j), 'T18 locked_at set at go-live');
  PERFORM public.mg_expect_error('T18 no rollback after go-live (INV-MIG-20)',
    format($q$UPDATE migration.job SET status = 'rolling_back' WHERE id = %L$q$, j), 'HK_MIG_JOB_TERMINAL');
  PERFORM public.mg_expect_error('T18 live job is terminal',
    format($q$UPDATE migration.job SET title = title, cutover_date = DATE '2026-03-21' WHERE id = %L$q$, j), 'HK_MIG_JOB_TERMINAL');
  UPDATE migration.job SET raw_retain_until = now() - interval '1 second' WHERE id = j;
  PERFORM public.mg_assert((SELECT count(*) FROM migration.job_event WHERE job_id = j) >= 9, 'T18 every transition logged');
END $$;

-- T19: پاک‌سازی snapshot خام پس از پایان و مهلت (GUC تراکنشی)
DO $$
DECLARE j uuid := current_setting('test.j1')::uuid; t uuid := '60a00000-0000-7000-8000-000000000001'; n int;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  PERFORM set_config('hk.migration_purge', 'on', true);
  DELETE FROM migration.raw_record WHERE job_id = j AND NOT EXISTS (SELECT 1 FROM migration.staged_record s WHERE s.raw_record_id = raw_record.id);
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM public.mg_assert(n = 3, 'T19 raw rows purged after job end and retention');
END $$;

-- T20: یک کار ثبت‌کننده در هر شرکت؛ آرشیو مجاز (INV-MIG-21) و آزمایشی هرگز زنده نمی‌شود (INV-MIG-22)
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; j2 uuid; j3 uuid; jr uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  j2 := public.mg_new_job('60a00000-0000-7000-8000-0000000000c2', 'template', 'file', 'opening');
  PERFORM public.mg_expect_error('T20 one active posting job per company',
    $q$SELECT public.mg_new_job('60a00000-0000-7000-8000-0000000000c2', 'sepidar', 'backup', 'opening')$q$, '23505');
  j3 := public.mg_new_job('60a00000-0000-7000-8000-0000000000c2', 'holoo', 'file', 'archive');
  PERFORM set_config('test.j2', j2::text, false);
  PERFORM set_config('test.j3', j3::text, false);
  -- آزمایشی
  jr := public.mg_new_job('60a00000-0000-7000-8000-0000000000c3', 'template', 'file', 'opening', true);
  PERFORM public.mg_open(jr);
  PERFORM public.mg_stage(jr, 1);
  PERFORM public.mg_party(jr, 'R1');
  PERFORM public.mg_validate(jr, '60a00000-0000-7000-8000-0000000000f3');
  PERFORM public.mg_preview(jr);
  PERFORM public.mg_commit_all(jr);
  INSERT INTO migration.reconciliation (tenant_id, id, job_id, seq, as_of, status, line_count, unexplained_count, report_sha256)
  VALUES (t, '60a00000-0000-7000-8000-00000000ec01', jr, 1, '2026-09-22', 'balanced', 1, 0, public.mg_sha('rr'));
  INSERT INTO migration.reconciliation_line (tenant_id, job_id, reconciliation_id, check_kind, key, source_value, target_value)
  VALUES (t, jr, '60a00000-0000-7000-8000-00000000ec01', 'trial_balance', 'total', 0, 0);
  UPDATE migration.job SET reconciliation_id = '60a00000-0000-7000-8000-00000000ec01', status = 'reconciled' WHERE id = jr;
  PERFORM public.mg_expect_error('T20 rehearsal job never goes live',
    format($q$UPDATE migration.job SET golive_approved_by = '60a00000-0000-7000-8000-0000000000a1', golive_approved_at = now(), status = 'live' WHERE id = %L$q$, jr),
    '23514');
  PERFORM set_config('test.jr', jr::text, false);
END $$;
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; jr uuid := current_setting('test.jr')::uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  INSERT INTO migration.reconciliation (tenant_id, id, job_id, seq, as_of, status, line_count, unexplained_count, report_sha256)
  VALUES (t, '60a00000-0000-7000-8000-00000000ec02', jr, 2, '2026-09-22', 'differences', 1, 1, public.mg_sha('rr2'));
  INSERT INTO migration.reconciliation_line (tenant_id, job_id, reconciliation_id, check_kind, key, source_value, target_value)
  VALUES (t, jr, '60a00000-0000-7000-8000-00000000ec02', 'trial_balance', 'total', 10, 0);
END $$;
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; jr uuid := current_setting('test.jr')::uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T20 go-live re-checks that the latest reconciliation is balanced',
    format($q$UPDATE migration.job SET golive_approved_by = '60a00000-0000-7000-8000-0000000000a1', golive_approved_at = now(), status = 'live' WHERE id = %L$q$, jr),
    'HK_MIG_NOT_RECONCILED: go-live requires');
END $$;

-- T21: rollback پیش از قفل با جبران (INV-MIG-20)
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; jr uuid := current_setting('test.jr')::uuid; pid uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  SELECT id INTO pid FROM migration.posting WHERE job_id = jr LIMIT 1;
  PERFORM public.mg_expect_error('T21 compensation only while rolling back',
    format($q$UPDATE migration.posting SET state = 'compensated', compensated_at = now(), compensation_doc_id = uuidv7() WHERE id = %L$q$, pid), 'HK_MIG_JOB_STATE');
  UPDATE migration.job SET status = 'rolling_back' WHERE id = jr;
  PERFORM public.mg_expect_error('T21 rolled_back needs every posting compensated',
    format($q$UPDATE migration.job SET status = 'rolled_back' WHERE id = %L$q$, jr), 'HK_MIG_ROLLBACK_INCOMPLETE');
  PERFORM public.mg_expect_error('T21 posting immutable',
    format($q$UPDATE migration.posting SET target_doc_id = uuidv7() WHERE id = %L$q$, pid), 'HK_MIG_IMMUTABLE_FIELD');
  PERFORM public.mg_expect_error('T21 compensation is recorded with the state change',
    format($q$UPDATE migration.posting SET compensation_doc_id = uuidv7() WHERE id = %L$q$, pid), 'HK_MIG_IMMUTABLE_FIELD: compensation');
  UPDATE migration.posting SET state = 'compensated', compensated_at = now(), compensation_doc_id = uuidv7() WHERE job_id = jr;
  PERFORM public.mg_expect_error('T21 compensated is final',
    format($q$UPDATE migration.posting SET state = 'live', compensated_at = NULL WHERE id = %L$q$, pid), 'HK_MIG_POSTING_TRANSITION');
  PERFORM public.mg_expect_error('T21 posting delete forbidden (no grant)', format($q$DELETE FROM migration.posting WHERE id = %L$q$, pid), '42501');
  UPDATE migration.staged_record SET status = 'rolled_back' WHERE job_id = jr AND status = 'committed';
  UPDATE migration.job SET status = 'rolled_back' WHERE id = jr;
  PERFORM public.mg_assert((SELECT rolled_back_at IS NOT NULL FROM migration.job WHERE id = jr), 'T21 rolled_back_at set');
  -- پس از rollback شرکت آزاد است و کار تازه ساخته می‌شود
  PERFORM set_config('test.jx', public.mg_new_job('60a00000-0000-7000-8000-0000000000c3', 'template', 'file', 'opening', true)::text, false);
END $$;

-- T21b: ترتیب پاک‌سازی: ردیف مرحله‌ای پیش از snapshot خام (INV-MIG-33)
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; jx uuid := current_setting('test.jx')::uuid; r uuid; n int;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_open(jx);
  PERFORM public.mg_stage(jx, 1);
  SELECT id INTO r FROM migration.raw_record WHERE job_id = jx;
  INSERT INTO migration.staged_record (tenant_id, job_id, raw_record_id, entity, source_system, source_db, source_table, source_key)
  VALUES (t, jx, r, 'party', 'template', 'T03', 'T03', 'row:1');
  UPDATE migration.job SET status = 'cancelled' WHERE id = jx;
  UPDATE migration.job SET raw_retain_until = now() - interval '1 second' WHERE id = jx;
  PERFORM set_config('hk.migration_purge', 'on', true);
  PERFORM public.mg_expect_error('T21b staged rows are purged before raw rows',
    format($q$DELETE FROM migration.raw_record WHERE id = %L$q$, r), 'HK_MIG_RETENTION: purge staged rows first');
  DELETE FROM migration.staged_record WHERE job_id = jx;
  DELETE FROM migration.raw_record WHERE job_id = jx;
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM public.mg_assert(n = 1, 'T21b raw row purged after its staged row');
END $$;

-- T22: نگاشت شناسه (INV-MIG-07)
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; j uuid := current_setting('test.j1')::uuid; m uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  INSERT INTO migration.id_map (tenant_id, id, source_system, source_db, source_table, source_key, target_kind, target_id, link_method, content_hash, first_job_id, last_job_id)
  VALUES (t, uuidv7(), 'holoo', 'Holoo1', 'CUSTOMER', 'C001', 'parties.party', uuidv7(), 'created', public.mg_sha('c1'), j, j) RETURNING id INTO m;
  PERFORM public.mg_expect_error('T22 a source record maps once per target kind',
    format($q$INSERT INTO migration.id_map (tenant_id, source_system, source_db, source_table, source_key, target_kind, target_id, link_method, content_hash, first_job_id, last_job_id)
              VALUES (%L, 'holoo', 'Holoo1', 'CUSTOMER', 'C001', 'parties.party', uuidv7(), 'created', sha256('x'), %L, %L)$q$, t, j, j), '23505');
  INSERT INTO migration.id_map (tenant_id, source_system, source_db, source_table, source_key, target_kind, target_id, link_method, content_hash, first_job_id, last_job_id)
  VALUES (t, 'holoo', 'Holoo1', 'CUSTOMER', 'C001', 'ledger.dimension_value', uuidv7(), 'created', public.mg_sha('c1'), j, j);
  PERFORM public.mg_expect_error('T22 target never re-pointed',
    format($q$UPDATE migration.id_map SET target_id = uuidv7() WHERE id = %L$q$, m), 'HK_MIG_IMMUTABLE_FIELD');
  UPDATE migration.id_map SET content_hash = public.mg_sha('c1-v2'), last_job_id = j WHERE id = m;
  PERFORM public.mg_expect_error('T22 id map delete forbidden (no grant)', format($q$DELETE FROM migration.id_map WHERE id = %L$q$, m), '42501');
  PERFORM public.mg_expect_error('T22 target kind shape',
    format($q$INSERT INTO migration.id_map (tenant_id, source_system, source_db, source_table, source_key, target_kind, target_id, link_method, content_hash, first_job_id, last_job_id)
              VALUES (%L, 'holoo', 'Holoo1', 'ARTICLE', 'A1', 'item', uuidv7(), 'created', sha256('x'), %L, %L)$q$, t, j, j), '23514');
END $$;

-- T23: تداوم مؤدیان (INV-MIG-17)
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; j2 uuid := current_setting('test.j2')::uuid; m uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_open(j2);
  PERFORM public.mg_stage(j2, 2);
  PERFORM public.mg_expect_error('T23 taxid check digit (Verhoeff)',
    format($q$INSERT INTO migration.moadian_continuity (tenant_id, job_id, company_id, memory_id, last_inno, last_taxid, connection_mode, origin)
              VALUES (%L, %L, '60a00000-0000-7000-8000-0000000000c2', 'DEF5GH', '000000000C', 'DEF5GH0481F000000000C3', 'direct', 'template_t17')$q$, t, j2),
    '23514');
  PERFORM public.mg_expect_error('T23 taxid belongs to the memory',
    format($q$INSERT INTO migration.moadian_continuity (tenant_id, job_id, company_id, memory_id, last_inno, last_taxid, connection_mode, origin)
              VALUES (%L, %L, '60a00000-0000-7000-8000-0000000000c2', 'ABCDEF', '000000000C', 'DEF5GH0481F000000000C2', 'direct', 'template_t17')$q$, t, j2),
    '23514');
  PERFORM public.mg_expect_error('T23 last inno is the taxid serial',
    format($q$INSERT INTO migration.moadian_continuity (tenant_id, job_id, company_id, memory_id, last_inno, last_taxid, connection_mode, origin)
              VALUES (%L, %L, '60a00000-0000-7000-8000-0000000000c2', 'DEF5GH', '000000000D', 'DEF5GH0481F000000000C2', 'direct', 'template_t17')$q$, t, j2),
    '23514');
  PERFORM public.mg_expect_error('T23 inno is 10 hex characters',
    format($q$INSERT INTO migration.moadian_continuity (tenant_id, job_id, company_id, memory_id, last_inno, last_taxid, connection_mode, origin)
              VALUES (%L, %L, '60a00000-0000-7000-8000-0000000000c2', 'DEF5GH', '12', 'DEF5GH0481F000000000C2', 'direct', 'template_t17')$q$, t, j2),
    '23514');
  PERFORM public.mg_expect_error('T23 continuity company equals job company',
    format($q$INSERT INTO migration.moadian_continuity (tenant_id, job_id, company_id, memory_id, last_inno, last_taxid, connection_mode, origin)
              VALUES (%L, %L, '60a00000-0000-7000-8000-0000000000c1', 'DEF5GH', '000000000C', 'DEF5GH0481F000000000C2', 'direct', 'template_t17')$q$, t, j2),
    '23503');
  INSERT INTO migration.moadian_continuity (tenant_id, id, job_id, company_id, memory_id, last_inno, last_taxid, connection_mode, origin)
  VALUES (t, uuidv7(), j2, '60a00000-0000-7000-8000-0000000000c2', 'DEF5GH', '000000000C', 'DEF5GH0481F000000000C2', 'direct', 'template_t17')
  RETURNING id INTO m;
  PERFORM public.mg_expect_error('T23 one row per memory',
    format($q$INSERT INTO migration.moadian_continuity (tenant_id, job_id, company_id, memory_id, last_inno, last_taxid, connection_mode, origin)
              VALUES (%L, %L, '60a00000-0000-7000-8000-0000000000c2', 'DEF5GH', '0000001FED', 'DEF5GH0481F0000001FED8', 'direct', 'template_t17')$q$, t, j2),
    '23505');
  PERFORM public.mg_expect_error('T23 continuity rows start staged',
    format($q$INSERT INTO migration.moadian_continuity (tenant_id, job_id, company_id, memory_id, last_inno, last_taxid, connection_mode, origin, status)
              VALUES (%L, %L, '60a00000-0000-7000-8000-0000000000c2', 'ZZZZZZ', '0000000001', 'ZZZZZZFFFFF00000000010', 'direct', 'template_t17', 'committed')$q$, t, j2),
    'HK_MIG_JOB_STATE');
  PERFORM public.mg_expect_error('T23 continuity identity immutable',
    format($q$UPDATE migration.moadian_continuity SET company_id = '60a00000-0000-7000-8000-0000000000c1' WHERE id = %L$q$, m), 'HK_MIG_IMMUTABLE_FIELD');
  PERFORM public.mg_expect_error('T23 committed only by the commit stage',
    format($q$UPDATE migration.moadian_continuity SET status = 'committed' WHERE id = %L$q$, m), 'HK_MIG_STAGED_TRANSITION');
  PERFORM public.mg_party(j2, 'P1');
  PERFORM public.mg_validate(j2, '60a00000-0000-7000-8000-0000000000f2');
  PERFORM public.mg_expect_error('T23 continuity frozen after validation',
    format($q$UPDATE migration.moadian_continuity SET connection_mode = 'trusted_company' WHERE id = %L$q$, m), 'HK_MIG_INPUTS_FROZEN');
  PERFORM public.mg_expect_error('T23 consent of a running job cannot be swapped',
    format($q$UPDATE migration.job SET consent_id = NULL WHERE id = %L$q$, j2), 'HK_MIG_CONSENT_FIXED');
  -- ثبت تداوم در مرحلهٔ commit؛ پس از آن منجمد
  PERFORM public.mg_preview(j2);
  INSERT INTO migration.commit_chunk (tenant_id, job_id, chunk_no, stage, item_count) VALUES (t, j2, 1, 'tax_continuity', 1);
  UPDATE migration.job SET status = 'committing' WHERE id = j2;
  UPDATE migration.commit_chunk SET status = 'running' WHERE job_id = j2 AND chunk_no = 1;
  UPDATE migration.moadian_continuity SET status = 'committed' WHERE id = m;
  PERFORM public.mg_expect_error('T23 committed continuity is frozen',
    format($q$UPDATE migration.moadian_continuity SET connection_mode = 'trusted_company' WHERE id = %L$q$, m), 'HK_MIG_STAGED_FROZEN: committed continuity');
END $$;

-- T24: آرشیو فقط با کار آرشیو در حال ثبت؛ فقط‌افزودنی
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; j3 uuid := current_setting('test.j3')::uuid; j2 uuid := current_setting('test.j2')::uuid; a uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T24 archive only by an archive job',
    format($q$INSERT INTO migration.archive_entry (tenant_id, job_id, company_id, fiscal_label, doc_kind, doc_no, amount_unit, payload, source_table, source_key)
              VALUES (%L, %L, '60a00000-0000-7000-8000-0000000000c2', '1403', 'voucher', '12', 'IRR', '{}', 'SANAD', '12')$q$, t, j2), 'HK_MIG_ARCHIVE_ONLY');
  PERFORM public.mg_open(j3);
  PERFORM public.mg_stage(j3, 1);
  PERFORM public.mg_party(j3, 'A1');
  UPDATE migration.job SET amount_unit_confirmed_by = '60a00000-0000-7000-8000-0000000000a2', amount_unit_confirmed_at = now() WHERE id = j3;
  UPDATE migration.staged_record SET status = 'valid' WHERE job_id = j3;
  UPDATE migration.job SET status = 'validated' WHERE id = j3;      -- آرشیو سال مالی هدف نمی‌خواهد
  PERFORM public.mg_preview(j3);
  INSERT INTO migration.commit_chunk (tenant_id, job_id, chunk_no, stage, item_count) VALUES (t, j3, 1, 'archive', 1);
  UPDATE migration.job SET status = 'committing' WHERE id = j3;
  INSERT INTO migration.archive_entry (tenant_id, id, job_id, company_id, fiscal_label, doc_kind, doc_no, doc_date, party_name, amount, amount_unit, description, payload, source_table, source_key)
  VALUES (t, uuidv7(), j3, '60a00000-0000-7000-8000-0000000000c2', '1403', 'sales_invoice', '۱۲', '2024-05-01', 'علي رضايي', 1200000, 'IRR', 'فروش', '{"lines":[]}', 'FACTURE', 'F12')
  RETURNING id INTO a;
  PERFORM public.mg_assert((SELECT search_key FROM migration.archive_entry WHERE id = a) = core.fa_search_key('۱۲ علي رضايي فروش'), 'T24 archive search key normalized');
  PERFORM public.mg_expect_error('T24 archive append-only (no grant)', format($q$UPDATE migration.archive_entry SET doc_no = '13' WHERE id = %L$q$, a), '42501');
  PERFORM public.mg_expect_error('T24 archive entry company equals job company',
    format($q$INSERT INTO migration.archive_entry (tenant_id, job_id, company_id, fiscal_label, doc_kind, amount_unit, payload, source_table, source_key)
              VALUES (%L, %L, '60a00000-0000-7000-8000-0000000000c1', '1403', 'voucher', 'IRR', '{}', 'SANAD', '13')$q$, t, j3), '23503');
END $$;

-- T25: مهاجرت همراه‌با‌کارشناس: رضایت پشتیبانی لازم است
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; j uuid; c uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  j := public.mg_new_job('60a00000-0000-7000-8000-0000000000c1', 'sepidar', 'backup', 'opening', false, '60a00000-0000-7000-8000-00000000600d');
  c := public.mg_consent(j, 'data_owner_migration');
  PERFORM public.mg_consent(j, 'backup_processing');
  UPDATE migration.job SET consent_id = c WHERE id = j;
  PERFORM public.mg_expect_error('T25 assisted job needs assisted_access consent',
    format($q$UPDATE migration.job SET status = 'awaiting_source' WHERE id = %L$q$, j), 'HK_MIG_CONSENT_REQUIRED');
  PERFORM public.mg_consent(j, 'assisted_access');
  UPDATE migration.job SET status = 'awaiting_source' WHERE id = j;
  UPDATE migration.job SET status = 'cancelled' WHERE id = j;
  PERFORM public.mg_assert((SELECT cancelled_at IS NOT NULL FROM migration.job WHERE id = j), 'T25 cancelled_at set');
  PERFORM public.mg_expect_error('T25 cancelled job is terminal',
    format($q$UPDATE migration.job SET consent_id = NULL WHERE id = %L$q$, j), 'HK_MIG_JOB_TERMINAL');
END $$;

-- T26: جداسازی مستأجرها (RLS و FK ترکیبی)
DO $$
DECLARE ja uuid := current_setting('test.j1')::uuid; jb uuid; n int;
BEGIN
  PERFORM public.mg_ctx('60b00000-0000-7000-8000-000000000001', '60b00000-0000-7000-8000-0000000000b1');
  SELECT count(*) INTO n FROM migration.job;            PERFORM public.mg_assert(n = 0, 'T26 B sees no jobs of A');
  SELECT count(*) INTO n FROM migration.staged_record;  PERFORM public.mg_assert(n = 0, 'T26 B sees no staged rows of A');
  SELECT count(*) INTO n FROM migration.consent;        PERFORM public.mg_assert(n = 0, 'T26 B sees no consents of A');
  SELECT count(*) INTO n FROM migration.mapping;        PERFORM public.mg_assert(n = 0, 'T26 B sees no mapping memory of A');
  SELECT count(*) INTO n FROM migration.reconciliation; PERFORM public.mg_assert(n = 0, 'T26 B sees no reconciliations of A');
  SELECT count(*) INTO n FROM migration.v_job_blockers; PERFORM public.mg_assert(n = 0, 'T26 views are security invoker');
  UPDATE migration.job SET title = 'hijack' WHERE id = ja;
  GET DIAGNOSTICS n = ROW_COUNT;                         PERFORM public.mg_assert(n = 0, 'T26 B cannot update A job');
  PERFORM public.mg_expect_error('T26 cannot insert rows for another tenant',
    $q$INSERT INTO migration.job (tenant_id, company_id, title, source_system, channel, mode, cutover_date, amount_unit, created_by)
       VALUES ('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-0000000000c1', 'x', 'holoo', 'agent', 'opening', '2026-03-21', 'IRR',
               '60a00000-0000-7000-8000-0000000000a2')$q$, '42501');
  PERFORM public.mg_expect_error('T26 B job cannot point at A company',
    $q$INSERT INTO migration.job (tenant_id, company_id, title, source_system, channel, mode, cutover_date, amount_unit, created_by)
       VALUES ('60b00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-0000000000c1', 'x', 'holoo', 'agent', 'opening', '2026-03-21', 'IRR',
               '60b00000-0000-7000-8000-0000000000b1')$q$, '23503');
  jb := public.mg_new_job('60b00000-0000-7000-8000-0000000000c1', 'hesabfa', 'api', 'opening');
  PERFORM public.mg_expect_error('T26 B row cannot hang under A job',
    format($q$INSERT INTO migration.consent (tenant_id, job_id, kind, statement_code, statement_version, statement_sha256, signer_user_id,
               signer_full_name, signer_capacity, valid_until)
              VALUES ('60b00000-0000-7000-8000-000000000001', %L, 'data_owner_migration', 'mig.consent', 1, sha256('x'),
                      '60b00000-0000-7000-8000-0000000000b1', 'مالک ب', 'owner', now() + interval '1 day')$q$, ja), 'HK_MIG_JOB_STATE');
  PERFORM public.mg_open(jb);
  PERFORM public.mg_assert((SELECT count(*) FROM migration.job) = 1, 'T26 B sees only its own job');
  -- بدون زمینهٔ مستأجر هیچ ردیفی دیده نمی‌شود
  PERFORM set_config('app.tenant_id', '', true);
  SELECT count(*) INTO n FROM migration.job;            PERFORM public.mg_assert(n = 0, 'T26 no tenant context, no rows');
END $$;

-- T27: v_job_blockers و v_job_progress
DO $$
DECLARE j2 uuid := current_setting('test.j2')::uuid; j uuid := current_setting('test.j1')::uuid;
BEGIN
  PERFORM public.mg_ctx('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_assert((SELECT open_errors = 0 AND blocked_records = 0 FROM migration.v_job_blockers WHERE job_id = j2), 'T27 clean job has no blockers');
  PERFORM public.mg_assert((SELECT chunks_total = 2 AND chunks_done = 2 AND items_done = 3 FROM migration.v_job_progress WHERE job_id = j), 'T27 progress view');
  PERFORM public.mg_assert((SELECT status FROM migration.v_reconciliation_latest WHERE job_id = j) = 'balanced', 'T27 latest reconciliation view');
END $$;

-- =====================================================================
-- بخش ۳: hk_readonly
-- =====================================================================
RESET ROLE;
SET ROLE hk_readonly;
DO $$
DECLARE n int;
BEGIN
  PERFORM public.mg_ctx('60a00000-0000-7000-8000-000000000001', NULL);
  SELECT count(*) INTO n FROM migration.job;  PERFORM public.mg_assert(n >= 5, 'T28 readonly can read jobs');
  SELECT count(*) INTO n FROM (SELECT id, kind, status FROM migration.source_credential) x; PERFORM public.mg_assert(n = 1, 'T28 readonly reads credential metadata');
  PERFORM public.mg_expect_error('T28 readonly cannot read secret references', $q$SELECT secret_ref FROM migration.source_credential$q$, '42501');
  PERFORM public.mg_expect_error('T28 readonly cannot read agent token hashes', $q$SELECT token_hash FROM migration.agent_session$q$, '42501');
  PERFORM public.mg_expect_error('T28 readonly cannot write', $q$UPDATE migration.job SET title = 'x'$q$, '42501');
END $$;

-- =====================================================================
-- بخش ۴: postgres (کاتالوگ و lint)
-- =====================================================================
RESET ROLE;
DO $$
BEGIN
  INSERT INTO migration.profile (code, version, source_system, title, channel, source_versions, fingerprint, spec, spec_sha256, confidence, status)
  VALUES ('holoo_classic', 1, 'holoo', 'هلو کلاسیک', 'agent', 'Holoo classic (Holoo1)', '{"tables":["SARFASL","SANAD"]}', '{"queries":{}}', sha256('s'), 'medium', 'draft');
  PERFORM public.mg_expect_error('T29 published profile needs golden + real sample',
    $q$UPDATE migration.profile SET status = 'published', published_at = now() WHERE code = 'holoo_classic'$q$, '23514');
  PERFORM public.mg_expect_error('T29 beta profile needs a golden dataset',
    $q$UPDATE migration.profile SET status = 'beta' WHERE code = 'holoo_classic'$q$, '23514');
  UPDATE migration.profile SET status = 'published', published_at = now(), golden_dataset_ref = 'golden/holoo/v1',
         real_sample_verified_at = now() WHERE code = 'holoo_classic';
  PERFORM public.mg_expect_error('T29 published profile immutable',
    $q$UPDATE migration.profile SET spec = '{"queries":{"x":1}}' WHERE code = 'holoo_classic'$q$, 'HK_MIG_PROFILE_IMMUTABLE');
  PERFORM public.mg_expect_error('T29 published profile cannot be deleted',
    $q$DELETE FROM migration.profile WHERE code = 'holoo_classic'$q$, 'HK_MIG_PROFILE_IMMUTABLE');
  UPDATE migration.profile SET status = 'retired' WHERE code = 'holoo_classic';
  PERFORM public.mg_expect_error('T29 retired profile cannot be republished',
    $q$UPDATE migration.profile SET status = 'published' WHERE code = 'holoo_classic'$q$, 'HK_MIG_PROFILE_IMMUTABLE');
  PERFORM public.mg_expect_error('T29 synonym stored normalized',
    $q$INSERT INTO migration.header_synonym (field_key, synonym_norm, dict_version, origin) VALUES ('debit', 'بدهكار', 1, 'seed')$q$, '23514');
  PERFORM public.mg_expect_error('T29 one field per synonym (INV-MIG-25)',
    $q$INSERT INTO migration.header_synonym (field_key, synonym_norm, dict_version, origin) VALUES ('credit', 'بدهکار', 1, 'promoted')$q$, '23505');
  PERFORM public.mg_expect_error('T29 one default disposition per class',
    $q$UPDATE migration.partition_rule SET is_default = true WHERE partition_class = 'INVOICE' AND disposition = 'history_gl'$q$, '23505');
  -- لایهٔ دوم (تریگر) حتی برای مالک جدول‌ها
  PERFORM public.mg_expect_error('T29 trigger: dry-run append-only', $q$UPDATE migration.dry_run SET outcome = outcome$q$, 'HK_IMMUTABLE');
  PERFORM public.mg_expect_error('T29 trigger: reconciliation lines append-only', $q$DELETE FROM migration.reconciliation_line$q$, 'HK_IMMUTABLE');
  PERFORM public.mg_expect_error('T29 trigger: raw rows immutable', $q$UPDATE migration.raw_record SET row_no = row_no$q$, 'HK_MIG_RAW_IMMUTABLE: raw source rows');
  PERFORM public.mg_expect_error('T29 trigger: uploads never deleted', $q$DELETE FROM migration.upload$q$, 'HK_MIG_NO_DELETE: upload rows');
  PERFORM public.mg_expect_error('T29 trigger: packages never deleted', $q$DELETE FROM migration.package$q$, 'HK_MIG_NO_DELETE: packages');
  PERFORM public.mg_expect_error('T29 trigger: issues never deleted', $q$DELETE FROM migration.issue$q$, 'HK_MIG_NO_DELETE: issues');
  PERFORM public.mg_expect_error('T29 trigger: chunks never deleted', $q$DELETE FROM migration.commit_chunk$q$, 'HK_MIG_NO_DELETE: commit chunks');
  PERFORM public.mg_expect_error('T29 trigger: explanations never deleted', $q$DELETE FROM migration.explanation$q$, 'HK_MIG_NO_DELETE: explanations');
  PERFORM public.mg_expect_error('T29 trigger: jobs never deleted', $q$DELETE FROM migration.job$q$, 'HK_MIG_JOB_DELETE');
  PERFORM public.mg_expect_error('T29 trigger: consents never deleted', $q$DELETE FROM migration.consent$q$, 'HK_MIG_CONSENT_IMMUTABLE: consents are evidence');
  PERFORM public.mg_expect_error('T29 trigger: postings never deleted', $q$DELETE FROM migration.posting$q$, 'HK_MIG_NO_DELETE');
  PERFORM public.mg_expect_error('T29 trigger: id map never deleted', $q$DELETE FROM migration.id_map$q$, 'HK_MIG_NO_DELETE');
  PERFORM public.mg_expect_error('T29 overridable codes name a permission',
    $q$INSERT INTO migration.issue_code (code, category, default_severity, overridable, message_key, introduced_in) VALUES ('MIG_X_TEST', 'business', 'error', true, 'x', '1.0')$q$, '23514');
END $$;

SELECT public.mg_assert(NOT EXISTS (SELECT 1 FROM core.security_lint() WHERE object LIKE 'migration.%'), 'T30 core.security_lint clean for schema migration');
SELECT public.mg_assert((SELECT count(*) FROM core.export_table_registry WHERE schema_name = 'migration') =
                        (SELECT count(*) FROM pg_tables t JOIN pg_attribute a ON a.attrelid = (t.schemaname || '.' || t.tablename)::regclass
                          AND a.attname = 'tenant_id' WHERE t.schemaname = 'migration'), 'T30 every migration tenant table is in the export registry');
SELECT public.mg_assert((SELECT count(*) FROM core.permission WHERE module = 'migration') = 13, 'T30 migration permissions registered');
SELECT public.mg_assert((SELECT allow_impersonation_write FROM core.permission WHERE code = 'migration.job.golive') = false, 'T30 go-live never by impersonation');
SELECT public.mg_assert(NOT has_table_privilege('hk_app', 'migration.dry_run', 'UPDATE') AND NOT has_table_privilege('hk_app', 'migration.reconciliation_line', 'DELETE')
                        AND NOT has_table_privilege('hk_app', 'migration.job', 'DELETE'), 'T30 append-only grants');

\echo 'ALL 60_migration TESTS PASSED'
