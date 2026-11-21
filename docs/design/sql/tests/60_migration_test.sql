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
--   بخش ۱ (fixture، نقش postgres): مستأجر A و B، چهار شرکت، سه کاربر و عضویت، سال مالی ۱۴۰۵ هر شرکت، سه رضایت
--          پشتیبانی، پروفایل منتشرشده، پیوست فرم کتبی، چند سند دفتر کل با منشأهای گوناگون (پیش از T15) و توابع
--          کمکی public.mg_* (همه SECURITY INVOKER؛ با نقش فراخوان اجرا می‌شوند).
--   بخش ۲ (assert، «SET ROLE hk_app»: نه مالک، NOBYPASSRLS): T01..T27، T21b و T31. هر DO block مستأجر و کاربر را با
--          set_config('app.tenant_id'/'app.user_id', ..., true) تنظیم می‌کند. موارد deferred با
--          SET CONSTRAINTS ... IMMEDIATE درون زیرتراکنش آزموده می‌شوند.
--   بخش ۳ (hk_readonly): T28 فقط خواندن و پنهان بودن ستون‌های راز.
--   بخش ۴ (postgres): T29 کاتالوگ پروفایل و مترادف و لایهٔ دوم تریگرها (حتی برای مالک جدول‌ها)، T30 lint امنیتی هسته،
--          رجیستری صدور و بستار FK آن، تحویل uplink، مجوزها و grantهای فقط‌افزودنی؛ T32 هم‌روندی با دو نشست واقعی
--          (dblink؛ در نبود افزونه SKIP)؛ T33 موجودی اشیای اسکیما و «زنده بودن» هر CHECK، FK و تریگر touch.
-- پوشش (RV-MG-11): جهش هر raise_error، هر assert_job_status/assert_human_act، فهرست دستی شرط‌های گیت، و حذف هر CHECK،
-- UNIQUE و تریگر؛ نتیجه و بازمانده‌های دسترس‌ناپذیر در سند §۹-۷.
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
   'read_write', 'assisted migration service', now() + interval '2 days'),
  -- RV-MG-17: رضایت فقط‌خواندنی و رضایتی که در آزمون لغو می‌شود
  ('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-00000000600e', '60a00000-0000-7000-8000-0000000000a1',
   'read_only', 'read-only support', now() + interval '2 days'),
  ('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-00000000600f', '60a00000-0000-7000-8000-0000000000a1',
   'read_write', 'assisted migration, revoked later', now() + interval '2 days');
INSERT INTO migration.profile (code, version, source_system, title, channel, source_versions, fingerprint, spec, spec_sha256, confidence, status,
                               golden_dataset_ref, real_sample_verified_at, published_at)
VALUES ('holoo_std', 1, 'holoo', 'هلو استاندارد', 'agent', 'Holoo1', '{"tables":["SANAD"]}', '{"queries":{}}', sha256('hs'), 'high', 'published',
        'golden/holoo/std', now(), now());
INSERT INTO core.attachment (tenant_id, id, storage_backend, bucket, object_key, file_name, encryption_key_ref, purpose)
VALUES ('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-0000000a7701', 'fs', 'local',
        't/60a00000-0000-7000-8000-000000000001/2026/09/60a00000-0000-7000-8000-0000000a7701', 'consent.pdf', 'dek:test', 'migration');
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

-- نگهبان dry-run (RV-MG-22): p_sql با GUC تراکنشی hk.migration_dry_run='on' اجرا می‌شود و COMMIT (SET CONSTRAINTS IMMEDIATE)
-- باید با HK_MIG_DRY_RUN_COMMIT رد شود؛ همه‌چیز در زیرتراکنش برمی‌گردد
CREATE OR REPLACE FUNCTION public.mg_expect_dry_run_blocks(p_label text, p_sql text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    PERFORM set_config('hk.migration_dry_run', 'on', true);
    EXECUTE p_sql;
    SET CONSTRAINTS migration.trg_dry_run_sentinel IMMEDIATE;
    RAISE EXCEPTION 'TEST FAILED [%]: the dry-run write could commit', p_label;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'HK_MIG_DRY_RUN_COMMIT%' THEN
      RAISE EXCEPTION 'TEST FAILED [%]: expected HK_MIG_DRY_RUN_COMMIT, got %', p_label, SQLERRM;
    END IF;
  END;
  PERFORM set_config('hk.migration_dry_run', '', true);
END $$;

-- manifest معتبر HIF (§۵-۲): row_count_total = جمع files[].rows فایل‌های raw (CHECK manifest_rows_ok؛ RV-MG-18)
CREATE OR REPLACE FUNCTION public.mg_manifest(p_rows integer, p_table text DEFAULT 'SANAD') RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('format', 'hif/1', 'row_count_total', p_rows,
                            'files', jsonb_build_array(jsonb_build_object('kind', 'raw', 'table', p_table, 'rows', p_rows)))
$$;

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
          public.mg_manifest(p_rows), public.mg_sha(p::text), coalesce('agent:' || a, 'server:k1'),
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

GRANT EXECUTE ON FUNCTION public.mg_manifest(integer, text), public.mg_expect_dry_run_blocks(text, text) TO hk_app, hk_readonly;
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
  PERFORM public.mg_assert((SELECT count(DISTINCT sheet_code) FROM migration.template_column WHERE template_version = 1) = 21, 'T01 sheets T00..T17 + T11b, T12b, T15b');
  -- RV-MG-20: سرآیند و سطر فاکتور تاریخی همهٔ فیلدهای لازم صورتحساب مؤدیان را دارند؛ sstid سطر با taxid سرآیند اجباری می‌شود
  PERFORM public.mg_assert((SELECT count(*) FROM migration.template_column WHERE template_version = 1 AND sheet_code = 'T15'
                              AND column_key IN ('moadian_inno','inv_type','inv_pattern','inv_subject','settlement_method','ref_taxid',
                                                 'buyer_type','buyer_national_id','buyer_economic_code','total_vat','total_amount')) = 11,
                           'T01 T15 header carries the Moadian header fields');
  PERFORM public.mg_assert((SELECT count(*) FROM migration.template_column WHERE template_version = 1 AND sheet_code = 'T15b'
                              AND column_key IN ('line_no','moadian_unit','vat_amount','other_duty_code','other_duty_rate','other_duty_amount',
                                                 'other_levy_code','other_levy_rate','other_levy_amount','line_total')) = 10,
                           'T01 T15b lines carry mu, vam, od*, ol* and tsstam');
  PERFORM public.mg_assert((SELECT required_if FROM migration.template_column WHERE template_version = 1 AND sheet_code = 'T15b'
                              AND column_key = 'moadian_product_id') = 'T15.moadian_taxid', 'T01 sstid required when the invoice has a taxid');
  PERFORM public.mg_assert((SELECT count(*) FROM migration.template_column WHERE template_version = 1 AND sheet_code IN ('T09','T10')
                              AND column_key IN ('currency','fx_amount','fx_rate')) = 6, 'T01 open documents and cheques carry FX');
  PERFORM public.mg_assert((SELECT count(*) FROM migration.template_column WHERE template_version = 1
                              AND ((sheet_code = 'T04' AND column_key IN ('warranty_days','warranty_basis'))
                                OR (sheet_code = 'T12b' AND column_key IN ('serial_no','sale_date','warranty_end')))) = 5,
                           'T01 warranty terms and sold serials (RV-MG-26)');
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
  -- RV-MG-27: ساخت کار (— → draft) با کنشگر در job_event
  PERFORM public.mg_assert((SELECT count(*) FROM migration.job_event WHERE job_id = j AND from_status = '—' AND to_status = 'draft'
                              AND actor_id = '60a00000-0000-7000-8000-0000000000a2') = 1, 'T03 job creation logged');
  PERFORM public.mg_expect_error('T03 the unit is confirmed at creation only by the acting user',
    $q$INSERT INTO migration.job (tenant_id, company_id, title, source_system, channel, mode, cutover_date, amount_unit,
                                 amount_unit_confirmed_by, amount_unit_confirmed_at, created_by)
       VALUES ('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-0000000000c3', 't', 'holoo', 'agent', 'opening',
               '2026-03-21', 'IRR', '60a00000-0000-7000-8000-0000000000a1', now(), '60a00000-0000-7000-8000-0000000000a2')$q$, 'HK_MIG_ACTOR');
  PERFORM public.mg_expect_error('T03 status timestamps are gate-managed',
    format($q$UPDATE migration.job SET status_changed_at = now() - interval '1 day' WHERE id = %L$q$, j), 'HK_MIG_JOB_IMMUTABLE: status timestamps');
  PERFORM public.mg_expect_error('T03 locked_at only with go-live (live ⇔ locked_at)',
    $q$INSERT INTO migration.job (tenant_id, company_id, title, source_system, channel, mode, cutover_date, amount_unit, locked_at, created_by)
       VALUES ('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-0000000000c3', 't', 'holoo', 'agent', 'opening',
               '2026-03-21', 'IRR', now(), '60a00000-0000-7000-8000-0000000000a2')$q$, 'HK_MIG_JOB_INITIAL');
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
  -- RV-MG-13: زمینهٔ سیستمی (بی app.user_id) یا دستیار به نام کسی امضا نمی‌کند
  PERFORM set_config('app.user_id', '', true);
  PERFORM public.mg_expect_error('T04 consent cannot be signed without an acting user',
    format($q$INSERT INTO migration.consent (tenant_id, job_id, kind, statement_code, statement_version, statement_sha256, signer_user_id,
               signer_full_name, signer_capacity, valid_until)
              VALUES ('60a00000-0000-7000-8000-000000000001', %L, 'data_owner_migration', 'mig.consent', 1, sha256('x'),
                      '60a00000-0000-7000-8000-0000000000a1', 'مالک الف', 'owner', now() + interval '1 day')$q$, j), 'HK_MIG_CONSENT_SIGNER');
  PERFORM public.mg_ctx('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-0000000000a2');
  PERFORM set_config('app.actor_via', 'assistant_confirm', true);
  PERFORM public.mg_expect_error('T04 consent is never signed through the assistant',
    format($q$INSERT INTO migration.consent (tenant_id, job_id, kind, statement_code, statement_version, statement_sha256, signer_user_id,
               signer_full_name, signer_capacity, valid_until)
              VALUES ('60a00000-0000-7000-8000-000000000001', %L, 'data_owner_migration', 'mig.consent', 1, sha256('x'),
                      '60a00000-0000-7000-8000-0000000000a2', 'مالک الف', 'owner', now() + interval '1 day')$q$, j), 'HK_MIG_ACTOR');
  PERFORM set_config('app.actor_via', '', true);
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
  INSERT INTO migration.consent (tenant_id, id, job_id, kind, statement_code, statement_version, statement_sha256, signer_user_id,
                                 signer_full_name, signer_capacity, accepted_at, valid_until)
  VALUES ('60a00000-0000-7000-8000-000000000001', uuidv7(), j, 'data_owner_migration', 'mig.consent.data_owner_migration', 1, sha256('x'),
          '60a00000-0000-7000-8000-0000000000a2', 'مالک الف', 'owner', now() - interval '10 days', now() + interval '30 days')
  RETURNING id INTO c;
  PERFORM public.mg_assert((SELECT accepted_at = now() FROM migration.consent WHERE id = c), 'T04 consent time is the server time');
  INSERT INTO migration.consent (tenant_id, job_id, kind, statement_code, statement_version, statement_sha256, signer_user_id,
                                 signer_full_name, signer_capacity, written_form_attachment_id, valid_until)
  VALUES ('60a00000-0000-7000-8000-000000000001', j, 'raw_retention_extended', 'mig.consent.raw', 1, sha256('w'),
          '60a00000-0000-7000-8000-0000000000a2', 'مالک الف', 'owner', '60a00000-0000-7000-8000-0000000a7701', now() + interval '30 days');
  UPDATE migration.job SET consent_id = c WHERE id = j;
  -- کانال عامل رضایت اجرای عامل هم می‌خواهد
  PERFORM public.mg_expect_error('T04 agent channel needs agent_execution consent',
    format($q$UPDATE migration.job SET status = 'awaiting_source' WHERE id = %L$q$, j), 'HK_MIG_CONSENT_REQUIRED');
  c2 := public.mg_consent(j, 'agent_execution');
  -- رضایت تغییرناپذیر است؛ فقط یک‌بار و با دلیل لغو می‌شود
  PERFORM public.mg_expect_error('T04 consent immutable',
    format($q$UPDATE migration.consent SET valid_until = now() + interval '200 days' WHERE id = %L$q$, c2), 'HK_MIG_CONSENT_IMMUTABLE');
  PERFORM public.mg_expect_error('T04 consent delete forbidden (no grant)', format($q$DELETE FROM migration.consent WHERE id = %L$q$, c2), '42501');
  PERFORM public.mg_expect_error('T04 revocation is the acting user''s own act',
    format($q$UPDATE migration.consent SET revoked_at = now(), revoked_by = '60a00000-0000-7000-8000-0000000000a1', revoke_reason = 'لغو به نام کاربر دیگر' WHERE id = %L$q$, c2), 'HK_MIG_ACTOR');
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
  -- RV-MG-14: فایل از pending_upload شروع می‌شود (اسکن و sniff دور زده نمی‌شود)
  PERFORM public.mg_expect_error('T05 an upload starts pending_upload',
    format($q$INSERT INTO migration.upload (tenant_id, id, job_id, kind, file_name, storage_backend, bucket, object_key, encryption_key_ref, purge_after,
               status, size_bytes, sha256, uploaded_at, sniffed_format)
              VALUES (%L, %L, %L, 'backup', 'h.bak', 'fs', 'local', %L, 'dek', now() + interval '30 days', 'accepted', 10, sha256('b'), now(), 'mtf')$q$,
           t, u, j, 't/' || t || '/migration/' || j || '/' || u), 'HK_MIG_INTAKE_INITIAL');
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
  -- INV-MIG-30: بستهٔ HIF فقط با سرآیند HIF پذیرفته می‌شود
  u2 := uuidv7();
  INSERT INTO migration.upload (tenant_id, id, job_id, kind, file_name, storage_backend, bucket, object_key, encryption_key_ref, purge_after)
  VALUES (t, u2, j, 'hif', 'p.hif', 'fs', 'local', 't/' || t || '/migration/' || j || '/' || u2, 'dek', now() + interval '30 days');
  UPDATE migration.upload SET status = 'uploaded', size_bytes = 10, sha256 = public.mg_sha('hif-x'), uploaded_at = now() WHERE id = u2;
  UPDATE migration.upload SET status = 'scanning', sniffed_format = 'xlsx' WHERE id = u2;
  PERFORM public.mg_expect_error('T05 HIF upload needs an HIF header',
    format($q$UPDATE migration.upload SET status = 'accepted' WHERE id = %L$q$, u2), '23514');
  UPDATE migration.upload SET status = 'rejected', reject_code = 'MIG_FILE_UNSAFE' WHERE id = u2;
END $$;

-- T06: نشست عامل (INV-MIG-32) و اعتبارنامهٔ API (INV-MIG-31)
DO $$
DECLARE j uuid := current_setting('test.j1')::uuid; a uuid := uuidv7(); t uuid := '60a00000-0000-7000-8000-000000000001';
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T06 pairing window ≤ 24h',
    format($q$INSERT INTO migration.agent_session (tenant_id, job_id, pairing_code_hash, expires_at, created_by)
              VALUES (%L, %L, sha256('p'), now() + interval '2 days', '60a00000-0000-7000-8000-0000000000a2')$q$, t, j), '23514');
  -- RV-MG-14: نشست عامل pending، بی‌کلید و بی‌توکن متولد می‌شود؛ زمان ساخت زمان سرور است
  PERFORM public.mg_expect_error('T06 agent session cannot be born paired',
    format($q$INSERT INTO migration.agent_session (tenant_id, job_id, pairing_code_hash, expires_at, created_at, status, agent_public_key,
               paired_at, token_hash, token_expires_at, created_by)
              VALUES (%L, %L, sha256('p0'), now() - interval '10 days', now() - interval '11 days', 'paired', sha256('k0'), now(),
                      sha256('t0'), now() + interval '365 days', '60a00000-0000-7000-8000-0000000000a2')$q$, t, j), 'HK_MIG_INTAKE_INITIAL');
  PERFORM public.mg_expect_error('T06 a forged creation time cannot widen the 24h pairing window',
    format($q$INSERT INTO migration.agent_session (tenant_id, job_id, pairing_code_hash, expires_at, created_at, created_by)
              VALUES (%L, %L, sha256('p1'), now() + interval '10 days', now() + interval '10 days', '60a00000-0000-7000-8000-0000000000a2')$q$, t, j),
    '23514');
  INSERT INTO migration.agent_session (tenant_id, id, job_id, pairing_code_hash, expires_at, created_by)
  VALUES (t, a, j, public.mg_sha('pair-x'), now() + interval '1 hour', '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T06 a token needs a paired session',
    format($q$UPDATE migration.agent_session SET token_hash = sha256('t'), token_expires_at = now() + interval '10 minutes' WHERE id = %L$q$, a), '23514');
  PERFORM public.mg_expect_error('T06 pairing window is fixed',
    format($q$UPDATE migration.agent_session SET expires_at = now() + interval '20 hours' WHERE id = %L$q$, a), 'HK_MIG_IMMUTABLE_FIELD');
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
  PERFORM public.mg_expect_error('T06 a credential starts active',
    format($q$INSERT INTO migration.source_credential (tenant_id, job_id, kind, endpoint_base, secret_ref, purge_after, created_by, status)
              VALUES (%L, %L, 'hesabfa_api', 'https://api.hesabfa.com/', 'secret://t/mig/x', now() + interval '7 days',
                      '60a00000-0000-7000-8000-0000000000a2', 'revoked')$q$, t, j), 'HK_MIG_INTAKE_INITIAL');
  PERFORM public.mg_expect_error('T06 a forged creation time cannot stretch the 30-day credential purge',
    format($q$INSERT INTO migration.source_credential (tenant_id, job_id, kind, endpoint_base, secret_ref, purge_after, created_by, created_at)
              VALUES (%L, %L, 'hesabfa_api', 'https://api.hesabfa.com/', 'secret://t/mig/y', now() + interval '80 days',
                      '60a00000-0000-7000-8000-0000000000a2', now() + interval '60 days')$q$, t, j), '23514');
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
              VALUES (%L, %L, %L, 'agent', 'hif/1', public.mg_manifest(3), sha256('m'), 'k', 'holoo', 'hk-agent/1', 'IRR', 'gregorian_datetime', now(), 3)$q$, t, j, u), '23514');
  INSERT INTO migration.agent_session (tenant_id, id, job_id, pairing_code_hash, expires_at, created_by)
  VALUES (t, '60a00000-0000-7000-8000-00000000a9e1', j, public.mg_sha('unpaired'), now() + interval '1 hour', '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T07 agent package needs a paired session',
    format($q$INSERT INTO migration.package (tenant_id, job_id, upload_id, producer, agent_session_id, format_version, manifest, manifest_sha256,
               signer_key_id, source_system, extractor, amount_unit, date_mode, extracted_at, row_count_total)
              VALUES (%L, %L, %L, 'agent', '60a00000-0000-7000-8000-00000000a9e1', 'hif/1', public.mg_manifest(1), sha256('m'), 'k', 'holoo', 'hk-agent/1', 'IRR',
                      'gregorian_datetime', now(), 1)$q$, t, j, u), 'HK_MIG_AGENT_NOT_PAIRED');
  UPDATE migration.agent_session SET status = 'revoked' WHERE id = '60a00000-0000-7000-8000-00000000a9e1';
  PERFORM public.mg_expect_error('T07 HIF format version',
    format($q$INSERT INTO migration.package (tenant_id, job_id, upload_id, producer, agent_session_id, format_version, manifest, manifest_sha256,
               signer_key_id, source_system, extractor, amount_unit, date_mode, extracted_at, row_count_total)
              VALUES (%L, %L, %L, 'agent', %L, 'hif/2', public.mg_manifest(3), sha256('m'), 'k', 'holoo', 'hk-agent/1', 'IRR', 'gregorian_datetime', now(), 3)$q$,
           t, j, u, a), '23514');
  -- RV-MG-18 / INV-MIG-04: ستون row_count_total همان manifest است
  PERFORM public.mg_expect_error('T07 declared row count equals the manifest',
    format($q$INSERT INTO migration.package (tenant_id, job_id, upload_id, producer, agent_session_id, format_version, manifest, manifest_sha256,
               signer_key_id, source_system, extractor, amount_unit, date_mode, extracted_at, row_count_total)
              VALUES (%L, %L, %L, 'agent', %L, 'hif/1',
                      '{"format":"hif/1","row_count_total":136242,"files":[{"kind":"raw","table":"SANAD","rows":136242}]}',
                      sha256('m'), 'k', 'holoo', 'hk-agent/1', 'IRR', 'gregorian_datetime', now(), 1)$q$, t, j, u, a), '23514');
  PERFORM public.mg_expect_error('T07 manifest total equals the sum of its raw files',
    format($q$INSERT INTO migration.package (tenant_id, job_id, upload_id, producer, agent_session_id, format_version, manifest, manifest_sha256,
               signer_key_id, source_system, extractor, amount_unit, date_mode, extracted_at, row_count_total)
              VALUES (%L, %L, %L, 'agent', %L, 'hif/1',
                      '{"format":"hif/1","row_count_total":3,"files":[{"kind":"raw","table":"SANAD","rows":2}]}',
                      sha256('m'), 'k', 'holoo', 'hk-agent/1', 'IRR', 'gregorian_datetime', now(), 3)$q$, t, j, u, a), '23514');
  PERFORM public.mg_expect_error('T07 manifest total is a JSON number',
    format($q$INSERT INTO migration.package (tenant_id, job_id, upload_id, producer, agent_session_id, format_version, manifest, manifest_sha256,
               signer_key_id, source_system, extractor, amount_unit, date_mode, extracted_at, row_count_total)
              VALUES (%L, %L, %L, 'agent', %L, 'hif/1',
                      '{"format":"hif/1","row_count_total":"3","files":[{"kind":"raw","table":"SANAD","rows":3}]}',
                      sha256('m'), 'k', 'holoo', 'hk-agent/1', 'IRR', 'gregorian_datetime', now(), 3)$q$, t, j, u, a), '23514');
  PERFORM public.mg_expect_error('T07 manifest needs a files list',
    format($q$INSERT INTO migration.package (tenant_id, job_id, upload_id, producer, agent_session_id, format_version, manifest, manifest_sha256,
               signer_key_id, source_system, extractor, amount_unit, date_mode, extracted_at, row_count_total)
              VALUES (%L, %L, %L, 'agent', %L, 'hif/1', '{"format":"hif/1","row_count_total":0}',
                      sha256('m'), 'k', 'holoo', 'hk-agent/1', 'IRR', 'gregorian_datetime', now(), 0)$q$, t, j, u, a), '23514');
  INSERT INTO migration.package (tenant_id, id, job_id, upload_id, producer, agent_session_id, format_version, manifest, manifest_sha256,
                                 signer_key_id, source_system, source_db, extractor, amount_unit, date_mode, extracted_at, row_count_total,
                                 profile_code, profile_version)
  VALUES (t, p, j, u, 'agent', a, 'hif/1', public.mg_manifest(3), public.mg_sha('m1'), 'agent:' || a, 'holoo', 'Holoo1', 'hk-agent/2027.1.0',
          'IRR', 'gregorian_datetime', now(), 3, 'holoo_std', 1);
  PERFORM public.mg_expect_error('T07 one active package per job',
    format($q$INSERT INTO migration.package (tenant_id, id, job_id, upload_id, producer, agent_session_id, format_version, manifest, manifest_sha256,
               signer_key_id, source_system, extractor, amount_unit, date_mode, extracted_at, row_count_total)
              VALUES (%L, %L, %L, %L, 'agent', %L, 'hif/1', public.mg_manifest(1), sha256('m2'), 'k', 'holoo', 'x', 'IRR', 'gregorian_datetime', now(), 1)$q$,
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
              VALUES (%L, %L, %L, 'server_file', 'hif/1', public.mg_manifest(0), sha256('m'), 'k', 'holoo', 'x', 'IRR', 'gregorian_datetime', now(), 0, 'verified', now(), now())$q$,
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
  VALUES (t, '60a00000-0000-7000-8000-00000000d900', j, 'voucher', 'holoo', 'Holoo1', 'SANAD', '900', 'IRR') RETURNING id INTO v;
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
  -- RV-MG-06: حذف سطر هم سند معتبر را به pending برمی‌گرداند (سند نامتوازن یا خالی معتبر نمی‌ماند)
  INSERT INTO migration.staged_record (tenant_id, job_id, parent_id, entity, source_system, source_db, source_table, source_key, line_no, debit, amount_unit, status)
  VALUES (t, j, v, 'voucher_line', 'holoo', 'Holoo1', 'SND_LIST', '900:3', 3, 7, 'IRR', 'pending');
  INSERT INTO migration.staged_record (tenant_id, job_id, parent_id, entity, source_system, source_db, source_table, source_key, line_no, credit, amount_unit, status)
  VALUES (t, j, v, 'voucher_line', 'holoo', 'Holoo1', 'SND_LIST', '900:4', 4, 7, 'IRR', 'pending');
  UPDATE migration.staged_record SET status = 'valid' WHERE parent_id = v AND status = 'pending';
  UPDATE migration.staged_record SET status = 'valid' WHERE id = v;
  DELETE FROM migration.staged_record WHERE parent_id = v AND source_key = '900:4';
  PERFORM public.mg_assert((SELECT status FROM migration.staged_record WHERE id = v) = 'pending', 'T10 deleting a line re-opens its voucher (RV-MG-06)');
  PERFORM public.mg_expect_error('T10 the voucher left unbalanced by the delete cannot be valid',
    format($q$UPDATE migration.staged_record SET status = 'valid' WHERE id = %L$q$, v), 'HK_MIG_VOUCHER_UNBALANCED');
  DELETE FROM migration.staged_record WHERE parent_id = v AND source_key = '900:3';
  UPDATE migration.staged_record SET status = 'valid' WHERE id = v;
  -- INV-MIG-15: سند بی سطر (جمع صفر) هرگز معتبر نیست
  INSERT INTO migration.staged_record (tenant_id, job_id, entity, source_system, source_db, source_table, source_key, amount_unit)
  VALUES (t, j, 'voucher', 'holoo', 'Holoo1', 'SANAD', '901', 'IRR');
  PERFORM public.mg_expect_error('T10 an empty (zero-total) voucher is never valid',
    format($q$UPDATE migration.staged_record SET status = 'valid' WHERE job_id = %L AND source_table = 'SANAD' AND source_key = '901'$q$, j),
    'HK_MIG_VOUCHER_UNBALANCED');
  DELETE FROM migration.staged_record WHERE job_id = j AND source_table = 'SANAD' AND source_key = '901';
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
  -- RV-MG-13: «تأیید انسانی» کنش خود کاربر جاری است
  PERFORM public.mg_expect_error('T11 a mapping is confirmed only by the acting user',
    format($q$UPDATE migration.mapping SET status = 'confirmed', confirmed_by = '60a00000-0000-7000-8000-0000000000a1', confirmed_at = now() WHERE id = %L$q$, m),
    'HK_MIG_ACTOR');
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
  PERFORM public.mg_expect_error('T12 override is the acting user''s own act',
    format($q$UPDATE migration.issue SET status = 'overridden', override_reason = 'کد ملی از کارت ملی بررسی و تأیید شد', overridden_by = '60a00000-0000-7000-8000-0000000000a1', overridden_at = now() WHERE id = %L$q$, i1),
    'HK_MIG_ACTOR');
  UPDATE migration.issue SET status = 'overridden', override_reason = 'کد ملی از کارت ملی بررسی و تأیید شد',
         overridden_by = '60a00000-0000-7000-8000-0000000000a2', overridden_at = now() WHERE id = i1;
  PERFORM public.mg_expect_error('T12 overridden is final',
    format($q$UPDATE migration.issue SET status = 'open', override_reason = NULL, overridden_by = NULL, overridden_at = NULL WHERE id = %L$q$, i1),
    'HK_MIG_ISSUE_TRANSITION');
  PERFORM public.mg_expect_error('T12 issue immutable', format($q$UPDATE migration.issue SET params = '{"x":1}' WHERE id = %L$q$, i2), 'HK_MIG_IMMUTABLE_FIELD');
  PERFORM public.mg_expect_error('T12 issue delete only by the retention purge', format($q$DELETE FROM migration.issue WHERE id = %L$q$, i2), 'HK_MIG_NO_DELETE');
  PERFORM set_config('test.i2', i2::text, false);
END $$;

-- T13: دروازهٔ اعتبارسنجی (validated)
DO $$
DECLARE j uuid := current_setting('test.j1')::uuid; t uuid := '60a00000-0000-7000-8000-000000000001';
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T13 unit must be confirmed',
    format($q$UPDATE migration.job SET status = 'validated', fiscal_year_id = '60a00000-0000-7000-8000-0000000000f1' WHERE id = %L$q$, j), 'HK_MIG_UNIT_UNCONFIRMED');
  PERFORM public.mg_expect_error('T13 the unit is confirmed by the acting user only',
    format($q$UPDATE migration.job SET amount_unit_confirmed_by = '60a00000-0000-7000-8000-0000000000a1', amount_unit_confirmed_at = now() WHERE id = %L$q$, j),
    'HK_MIG_ACTOR');
  UPDATE migration.job SET amount_unit_confirmed_by = '60a00000-0000-7000-8000-0000000000a2', amount_unit_confirmed_at = now() - interval '3 days' WHERE id = j;
  PERFORM public.mg_assert((SELECT amount_unit_confirmed_at = now() FROM migration.job WHERE id = j), 'T13 confirmation time is the server time');
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
  -- INV-MIG-13: پس از validated ورودی‌ها منجمدند (RV-MG-05: تنظیمات کار و تأیید واحد هم)
  PERFORM public.mg_expect_error('T13 amount unit frozen after validation',
    format($q$UPDATE migration.job SET amount_unit = 'IRR_NEW' WHERE id = %L$q$, j), 'HK_MIG_INPUTS_FROZEN');
  PERFORM public.mg_expect_error('T13 unit confirmation frozen after validation',
    format($q$UPDATE migration.job SET amount_unit_confirmed_by = NULL, amount_unit_confirmed_at = NULL WHERE id = %L$q$, j), 'HK_MIG_INPUTS_FROZEN');
  PERFORM public.mg_expect_error('T13 cut-over date frozen after validation',
    format($q$UPDATE migration.job SET cutover_date = DATE '2026-06-22' WHERE id = %L$q$, j), 'HK_MIG_INPUTS_FROZEN');
  PERFORM public.mg_expect_error('T13 the partition policy is frozen after validation',
    format($q$INSERT INTO migration.job_partition_policy (tenant_id, job_id, partition_class, disposition) VALUES (%L, %L, 'CLOSING', 'skip')$q$, t, j),
    'HK_MIG_JOB_STATE');
  PERFORM public.mg_expect_error('T13 a setting cannot change together with the step back',
    format($q$UPDATE migration.job SET status = 'mapping', amount_unit = 'IRT' WHERE id = %L$q$, j), 'HK_MIG_INPUTS_FROZEN');
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
  INSERT INTO migration.dry_run (tenant_id, id, job_id, seq, run_mode, inputs_hash, started_at, outcome, report, report_sha256)
  VALUES (t, uuidv7(), j, 4, 'full_tx', h, now(), 'ok', '{"tb":"balanced"}', public.mg_sha('r4'));
  PERFORM public.mg_expect_error('T14 only the latest dry-run can be previewed',
    format($q$UPDATE migration.job SET preview_dry_run_id = (SELECT id FROM migration.dry_run WHERE job_id = %L AND seq = 3), status = 'previewed' WHERE id = %L$q$, j, j),
    'HK_MIG_DRY_RUN_REQUIRED');
  UPDATE migration.job SET preview_dry_run_id = (SELECT id FROM migration.dry_run WHERE job_id = j AND seq = 4), status = 'previewed' WHERE id = j;
  PERFORM public.mg_expect_error('T14 inputs frozen after preview',
    format($q$UPDATE migration.job SET cutover_date = DATE '2026-06-22' WHERE id = %L$q$, j), 'HK_MIG_INPUTS_FROZEN');
  PERFORM public.mg_expect_error('T14 the inputs hash is fixed once previewed',
    format($q$UPDATE migration.job SET inputs_hash = sha256('other') WHERE id = %L$q$, j), 'HK_MIG_INPUTS_FROZEN: inputs are frozen');
  PERFORM public.mg_expect_error('T14 dry-run only on validated jobs',
    format($q$INSERT INTO migration.dry_run (tenant_id, job_id, seq, run_mode, inputs_hash, started_at, outcome, report, report_sha256)
              VALUES (%L, %L, 5, 'full_tx', %L, now(), 'ok', '{}', sha256('r'))$q$, t, j, h), 'HK_MIG_JOB_STATE');
  PERFORM public.mg_expect_error('T14 commit needs an accepted preview',
    format($q$UPDATE migration.job SET status = 'committing' WHERE id = %L$q$, j), 'HK_MIG_PREVIEW_NOT_ACCEPTED');
  PERFORM public.mg_expect_error('T14 the preview is accepted by the acting user only',
    format($q$UPDATE migration.job SET preview_accepted_by = '60a00000-0000-7000-8000-0000000000a1', preview_accepted_at = now() WHERE id = %L$q$, j),
    'HK_MIG_ACTOR');
  UPDATE migration.job SET preview_accepted_by = '60a00000-0000-7000-8000-0000000000a2', preview_accepted_at = now() WHERE id = j;
  PERFORM public.mg_expect_error('T14 the preview is accepted once',
    format($q$UPDATE migration.job SET preview_accepted_at = now() - interval '1 day' WHERE id = %L$q$, j), 'HK_MIG_PREVIEW_STATE');
  UPDATE migration.job SET preview_dry_run_id = d2 WHERE id = j;
  PERFORM public.mg_expect_error('T14 commit refuses a preview whose dry-run is over other inputs',
    format($q$UPDATE migration.job SET status = 'committing' WHERE id = %L$q$, j), 'HK_MIG_DRY_RUN_REQUIRED: inputs changed');
  UPDATE migration.job SET preview_dry_run_id = (SELECT id FROM migration.dry_run WHERE job_id = j AND seq = 4) WHERE id = j;
  -- RV-MG-15: برنامهٔ ثبت پیش از commit ساخته می‌شود
  PERFORM public.mg_expect_error('T14 commit needs a commit plan',
    format($q$UPDATE migration.job SET status = 'committing' WHERE id = %L$q$, j), 'HK_MIG_CHUNKS_PENDING: plan');
END $$;

-- fixture (postgres): چند سند دفتر کل برای آزمون منشأ سند ثبت (RV-MG-07). ردیف‌ها با session_replication_role=replica
-- و بی سطر درج می‌شوند (آزمون فقط کلید، شرکت و منشأ سند را می‌خواهد؛ قواعد دفتر کل را آزمون بخش ۰۳ می‌سنجد).
RESET ROLE;
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; p1 uuid; p2 uuid;
BEGIN
  PERFORM set_config('session_replication_role', 'replica', true);
  PERFORM set_config('app.tenant_id', t::text, true);
  SELECT id INTO p1 FROM ledger.fiscal_period WHERE fiscal_year_id = '60a00000-0000-7000-8000-0000000000f1' AND DATE '2026-09-01' BETWEEN start_date AND end_date;
  SELECT id INTO p2 FROM ledger.fiscal_period WHERE fiscal_year_id = '60a00000-0000-7000-8000-0000000000f2' AND DATE '2026-09-01' BETWEEN start_date AND end_date;
  INSERT INTO ledger.journal (tenant_id, id, company_id, fiscal_year_id, period_id, journal_date, journal_type, entry_class, class_rank, status,
                              reference_no, reference_text, source_module, source_doc_type, source_doc_id, base_currency, line_count,
                              total_debit_base, total_credit_base)
  VALUES
    (t, '60a00000-0000-7000-8000-0000000001a1', '60a00000-0000-7000-8000-0000000000c1', '60a00000-0000-7000-8000-0000000000f1', p1, '2026-09-01',
     'history_import', 'regular', 1, 'temporary', 9001, 'mig-900', 'migration', 'migration.voucher', '60a00000-0000-7000-8000-00000000d900', 'IRR', 2, 1000, 1000),
    (t, '60a00000-0000-7000-8000-0000000001a2', '60a00000-0000-7000-8000-0000000000c1', '60a00000-0000-7000-8000-0000000000f1', p1, '2026-09-01',
     'history_import', 'regular', 1, 'temporary', 9002, 'mig-other', 'migration', 'migration.voucher', uuidv7(), 'IRR', 2, 1000, 1000),
    (t, '60a00000-0000-7000-8000-0000000001a3', '60a00000-0000-7000-8000-0000000000c1', '60a00000-0000-7000-8000-0000000000f1', p1, '2026-09-01',
     'module', 'regular', 1, 'temporary', 9003, 'purchase', 'purchase', 'purchase.invoice', uuidv7(), 'IRR', 2, 1000, 1000),
    (t, '60a00000-0000-7000-8000-0000000001a4', '60a00000-0000-7000-8000-0000000000c2', '60a00000-0000-7000-8000-0000000000f2', p2, '2026-09-01',
     'history_import', 'regular', 1, 'temporary', 9004, 'mig-c2', 'migration', 'migration.voucher', '60a00000-0000-7000-8000-00000000d900', 'IRR', 2, 1000, 1000),
    (t, '60a00000-0000-7000-8000-0000000001a5', '60a00000-0000-7000-8000-0000000000c1', '60a00000-0000-7000-8000-0000000000f1', p1, '2026-09-01',
     'module', 'regular', 1, 'temporary', 9005, 'sales', 'sales', 'sales.invoice', '60a00000-0000-7000-8000-0000000005a1', 'IRR', 2, 500, 500),
    (t, '60a00000-0000-7000-8000-0000000001a6', '60a00000-0000-7000-8000-0000000000c1', '60a00000-0000-7000-8000-0000000000f1', p1, '2026-09-01',
     'history_import', 'regular', 1, 'temporary', 9006, 'mig-w', 'migration', 'migration.voucher', '60a00000-0000-7000-8000-00000000d901', 'IRR', 2, 300, 300),
    (t, '60a00000-0000-7000-8000-0000000001a7', '60a00000-0000-7000-8000-0000000000c1', '60a00000-0000-7000-8000-0000000000f1', p1, '2026-09-01',
     'module', 'regular', 1, 'temporary', 9007, 'sales-fx', 'sales', 'sales.invoice', '60a00000-0000-7000-8000-0000000005a2', 'IRR', 2, 400, 400),
    (t, '60a00000-0000-7000-8000-0000000001a8', '60a00000-0000-7000-8000-0000000000c1', '60a00000-0000-7000-8000-0000000000f1', p1, '2026-09-01',
     'module', 'regular', 1, 'temporary', 9008, 'purchase-900', 'purchase', 'purchase.invoice', '60a00000-0000-7000-8000-00000000d900', 'IRR', 2, 1000, 1000);
END $$;
SET ROLE hk_app;

-- T15: ثبت تکه‌ای، ترتیب وابستگی، دفتر اثرها (INV-MIG-03، 08، 14، 18)
DO $$
DECLARE j uuid := current_setting('test.j1')::uuid; t uuid := '60a00000-0000-7000-8000-000000000001'; v uuid := current_setting('test.v900')::uuid;
        vi uuid := current_setting('test.vi')::uuid; s uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  INSERT INTO migration.commit_chunk (tenant_id, job_id, chunk_no, stage, item_count) VALUES (t, j, 1, 'masterdata', 1), (t, j, 2, 'history_gl', 2);
  -- RV-MG-15 / D-MG17: ترتیب ثابت مرحله‌ها با شمارهٔ تکه هم‌جهت است؛ مرحلهٔ آرشیو فقط در کار آرشیو
  PERFORM public.mg_expect_error('T15 stages keep the fixed order',
    format($q$INSERT INTO migration.commit_chunk (tenant_id, job_id, chunk_no, stage, item_count) VALUES (%L, %L, 3, 'masterdata', 1)$q$, t, j),
    'HK_MIG_CHUNK_ORDER: stage masterdata');
  PERFORM public.mg_expect_error('T15 archive chunks only in archive jobs',
    format($q$INSERT INTO migration.commit_chunk (tenant_id, job_id, chunk_no, stage, item_count) VALUES (%L, %L, 3, 'archive', 1)$q$, t, j),
    'HK_MIG_CHUNK_STAGE');
  PERFORM public.mg_expect_error('T15 unknown stage',
    format($q$INSERT INTO migration.commit_chunk (tenant_id, job_id, chunk_no, stage, item_count) VALUES (%L, %L, 3, 'magic', 1)$q$, t, j), '23514');
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
  -- CR-MG05: در committing صدور .hkx مستأجر با مانع core بسته است
  PERFORM public.mg_assert((SELECT count(*) FROM core.export_blocker WHERE module = 'migration' AND resource_id = j
                              AND reason_code = 'migration.job.committing' AND released_at IS NULL) = 1, 'T15 committing blocks tenant export');
  PERFORM public.mg_expect_error('T15 the previewed dry-run is fixed once committing',
    format($q$UPDATE migration.job SET preview_dry_run_id = (SELECT id FROM migration.dry_run WHERE job_id = %L AND seq = 3) WHERE id = %L$q$, j, j),
    'HK_MIG_INPUTS_FROZEN: the previewed dry-run');
  PERFORM public.mg_expect_error('T15 the commit plan is fixed once committing',
    format($q$INSERT INTO migration.commit_chunk (tenant_id, job_id, chunk_no, stage, item_count) VALUES (%L, %L, 3, 'payroll', 1)$q$, t, j),
    'HK_MIG_JOB_STATE: planning commit chunks');
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
  PERFORM public.mg_expect_error('T15 master data never posts to the GL (D-MG10)',
    format($q$INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
               target_module, target_doc_type, target_doc_id, journal_id, gl_effect)
              VALUES (%L, %L, 1, %L, 'holoo', 'Holoo1', 'CUSTOMER', 'C001', 'parties', 'parties.party', uuidv7(),
                      '60a00000-0000-7000-8000-0000000001a1', 'posted')$q$, t, j, s), 'HK_MIG_DOUBLE_POSTING: party rows never post');
  INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
                                 target_module, target_doc_type, target_doc_id, gl_effect)
  VALUES (t, j, 1, s, 'holoo', 'Holoo1', 'CUSTOMER', 'C001', 'parties', 'parties.party', uuidv7(), 'none');
  -- RV-MG-01/08/19: شرکت از کار و lineage از ردیف مرحله‌ای در خود posting کپی می‌شود
  PERFORM public.mg_assert((SELECT company_id = '60a00000-0000-7000-8000-0000000000c1' AND staged_entity = 'party' AND legacy_code = 'C001'
                              FROM migration.posting WHERE staged_record_id = s), 'T15 posting carries company and lineage');
  PERFORM public.mg_expect_error('T15 posting company equals the job company',
    format($q$INSERT INTO migration.posting (tenant_id, job_id, company_id, chunk_no, source_system, source_db, source_table, source_key,
               target_module, target_doc_type, target_doc_id, gl_effect)
              VALUES (%L, %L, '60a00000-0000-7000-8000-0000000000c2', 1, 'holoo', 'Holoo1', 'X', '1', 'parties', 'parties.party', uuidv7(), 'none')$q$, t, j),
    '23503');
  PERFORM public.mg_expect_error('T15 excluded rows are never committed',
    format($q$UPDATE migration.staged_record SET status = 'committed', committed_chunk = 1 WHERE id = %L$q$, current_setting('test.vu')),
    'HK_MIG_STAGED_TRANSITION: cannot commit');
  PERFORM public.mg_expect_error('T15 each source record lives once per target type (INV-MIG-03)',
    format($q$INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
               target_module, target_doc_type, target_doc_id, gl_effect)
              VALUES (%L, %L, 1, %L, 'holoo', 'Holoo1', 'CUSTOMER', 'C001', 'parties', 'parties.party', uuidv7(), 'none')$q$, t, j, s), '23505');
  -- RV-MG-07: ثبت GL بی رکورد مرحله‌ای فقط برای سندهای مشتق خود migration
  PERFORM public.mg_expect_error('T15 a GL posting names its staged record',
    format($q$INSERT INTO migration.posting (tenant_id, job_id, chunk_no, source_system, source_db, source_table, source_key,
               target_module, target_doc_type, target_doc_id, journal_id, gl_effect)
              VALUES (%L, %L, 1, 'holoo', 'Holoo1', 'SANAD', '900', 'ledger', 'ledger.journal', '60a00000-0000-7000-8000-0000000001a1',
                      '60a00000-0000-7000-8000-0000000001a1', 'posted')$q$, t, j), 'HK_MIG_LINEAGE: a GL posting names');
  PERFORM public.mg_expect_error('T15 GL posting needs a journal',
    format($q$INSERT INTO migration.posting (tenant_id, job_id, chunk_no, source_system, source_db, source_table, source_key,
               target_module, target_doc_type, target_doc_id, gl_effect)
              VALUES (%L, %L, 1, 'holoo', 'Holoo1', '@period_summary', '1405-01', 'migration', 'migration.period_summary', uuidv7(), 'posted')$q$, t, j), '23514');
  PERFORM public.mg_expect_error('T15 posting journal must exist in the ledger of the job company',
    format($q$INSERT INTO migration.posting (tenant_id, job_id, chunk_no, source_system, source_db, source_table, source_key,
               target_module, target_doc_type, target_doc_id, journal_id, gl_effect)
              VALUES (%L, %L, 1, 'holoo', 'Holoo1', '@period_summary', '1405-01', 'migration', 'migration.period_summary',
                      '60a00000-0000-7000-8000-0000000001a4', '60a00000-0000-7000-8000-0000000001a4', 'posted')$q$, t, j), '23503');
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
  -- RV-MG-07 / INV-MIG-36: سند GL هر ثبت سند migration همان شرکت است، از منشأ migration و برای همان رکورد مرحله‌ای
  PERFORM public.mg_expect_error('T15 a migration voucher cannot point at a purchase journal',
    format($q$INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
               target_module, target_doc_type, target_doc_id, journal_id, gl_effect)
              VALUES (%L, %L, 2, %L, 'holoo', 'Holoo1', 'SANAD', '900', 'ledger', 'ledger.journal', '60a00000-0000-7000-8000-0000000001a3',
                      '60a00000-0000-7000-8000-0000000001a3', 'posted')$q$, t, j, v), 'HK_MIG_JOURNAL_SOURCE');
  PERFORM public.mg_expect_error('T15 a migration voucher needs a migration import journal',
    format($q$INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
               target_module, target_doc_type, target_doc_id, journal_id, gl_effect)
              VALUES (%L, %L, 2, %L, 'holoo', 'Holoo1', 'SANAD', '900', 'ledger', 'ledger.journal', '60a00000-0000-7000-8000-0000000001a8',
                      '60a00000-0000-7000-8000-0000000001a8', 'posted')$q$, t, j, v), 'HK_MIG_JOURNAL_SOURCE');
  PERFORM public.mg_expect_error('T15 a migration voucher points at its own journal',
    format($q$INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
               target_module, target_doc_type, target_doc_id, journal_id, gl_effect)
              VALUES (%L, %L, 2, %L, 'holoo', 'Holoo1', 'SANAD', '900', 'ledger', 'ledger.journal', '60a00000-0000-7000-8000-0000000001a2',
                      '60a00000-0000-7000-8000-0000000001a2', 'posted')$q$, t, j, v), 'HK_MIG_JOURNAL_SOURCE');
  PERFORM public.mg_expect_error('T15 the target of a ledger posting is its journal',
    format($q$INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
               target_module, target_doc_type, target_doc_id, journal_id, gl_effect)
              VALUES (%L, %L, 2, %L, 'holoo', 'Holoo1', 'SANAD', '900', 'ledger', 'ledger.journal', uuidv7(),
                      '60a00000-0000-7000-8000-0000000001a1', 'posted')$q$, t, j, v), 'HK_MIG_JOURNAL_SOURCE');
  INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
                                 target_module, target_doc_type, target_doc_id, journal_id, gl_effect)
  VALUES (t, j, 2, v, 'holoo', 'Holoo1', 'SANAD', '900', 'ledger', 'ledger.journal', '60a00000-0000-7000-8000-0000000001a1',
          '60a00000-0000-7000-8000-0000000001a1', 'posted');
  -- فاکتور بازسازی‌شده (کلاس INVOICE در این کار regenerate است): سند GL آن متعلق به همان فاکتور در ماژول فروش است
  PERFORM public.mg_expect_error('T15 a regenerated invoice points at its own sales journal',
    $q$INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
               target_module, target_doc_type, target_doc_id, journal_id, gl_effect)
       SELECT tenant_id, job_id, 2, id, source_system, source_db, source_table, source_key, 'sales', 'sales.invoice', uuidv7(),
              '60a00000-0000-7000-8000-0000000001a5', 'posted'
         FROM migration.staged_record WHERE id = '60a00000-0000-7000-8000-00000000f100'$q$, 'HK_MIG_JOURNAL_SOURCE');
  INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
                                 target_module, target_doc_type, target_doc_id, journal_id, gl_effect)
  SELECT tenant_id, job_id, 2, id, source_system, source_db, source_table, source_key, 'sales', 'sales.invoice',
         '60a00000-0000-7000-8000-0000000005a1', '60a00000-0000-7000-8000-0000000001a5', 'posted'
    FROM migration.staged_record WHERE id = '60a00000-0000-7000-8000-00000000f100';
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
  PERFORM public.mg_assert(NOT EXISTS (SELECT 1 FROM core.export_blocker WHERE module = 'migration' AND resource_id = j AND released_at IS NULL),
                           'T15 the export blocker is released once committed');
  PERFORM public.mg_expect_error('T15 committed rows are rolled back only during a rollback',
    format($q$UPDATE migration.staged_record SET status = 'rolled_back' WHERE id = %L$q$, s), 'HK_MIG_STAGED_FROZEN');
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
  -- RV-MG-21 / INV-MIG-38: حساب کنترل تلورانس صفر دارد؛ فقط بهای نامعلوم (GL معوق) توضیح‌پذیر است
  PERFORM public.mg_expect_error('T16 control-account gaps are never explained as periodic vs perpetual',
    format($q$INSERT INTO migration.explanation (tenant_id, job_id, check_kind, key, category, amount, description, created_by)
              VALUES (%L, %L, 'control_account', '1401', 'perpetual_vs_periodic', 500000, 'بهای فروش ادواری ثبت نشده بود', '60a00000-0000-7000-8000-0000000000a2')$q$, t, j), '23514');
  PERFORM public.mg_expect_error('T16 control-account gaps are never explained as source drift',
    format($q$INSERT INTO migration.explanation (tenant_id, job_id, check_kind, key, category, amount, description, created_by)
              VALUES (%L, %L, 'control_account', '1103', 'source_summary_drift', 73000, 'جدول خلاصهٔ مبدأ ناهمخوان است', '60a00000-0000-7000-8000-0000000000a2')$q$, t, j), '23514');
  PERFORM public.mg_expect_error('T16 periodic vs perpetual explains only a source cross-check',
    format($q$INSERT INTO migration.explanation (tenant_id, job_id, check_kind, key, category, amount, description, created_by)
              VALUES (%L, %L, 'stock_value', 'W1', 'perpetual_vs_periodic', 500000, 'اختلاف موجودی ادواری و دائمی', '60a00000-0000-7000-8000-0000000000a2')$q$, t, j), '23514');
  PERFORM public.mg_expect_error('T16 unknown cost explains only stock value and control accounts',
    format($q$INSERT INTO migration.explanation (tenant_id, job_id, check_kind, key, category, amount, description, created_by)
              VALUES (%L, %L, 'party', 'C001', 'unknown_cost', 5, 'توضیح نادرست برای مانده شخص', '60a00000-0000-7000-8000-0000000000a2')$q$, t, j), '23514');
  INSERT INTO migration.explanation (tenant_id, job_id, check_kind, key, category, amount, description, created_by)
  VALUES (t, j, 'source_cross_check', '105', 'perpetual_vs_periodic', 500000, 'مانده ۱۰۵ ادواری در برابر گزارش موجودی دائمی', '60a00000-0000-7000-8000-0000000000a2');
  INSERT INTO migration.explanation (tenant_id, job_id, check_kind, key, category, amount, description, created_by)
  VALUES (t, j, 'control_account', '1401', 'unknown_cost', -2500, 'ارزش کالای بی‌بها با GL معوق انبار', '60a00000-0000-7000-8000-0000000000a2');
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
  -- RV-MG-13: تأیید توضیح کنش خود حسابدار است
  PERFORM public.mg_expect_error('T16 explanation approved only by the acting user',
    format($q$UPDATE migration.explanation SET status = 'approved', approved_by = '60a00000-0000-7000-8000-0000000000a1', approved_at = now() WHERE id = %L$q$, e),
    'HK_MIG_ACTOR');
  PERFORM public.mg_expect_error('T16 approved explanation names its approver',
    format($q$UPDATE migration.explanation SET status = 'approved' WHERE id = %L$q$, e), '23514');
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a1');
  UPDATE migration.explanation SET status = 'approved', approved_by = '60a00000-0000-7000-8000-0000000000a1', approved_at = now() WHERE id = e;
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T16 approval time is recorded with the status change',
    format($q$UPDATE migration.explanation SET approved_at = now() - interval '1 day' WHERE id = %L$q$, e), 'HK_MIG_EXPLANATION_TRANSITION: approval is recorded');
  PERFORM public.mg_expect_error('T16 approved explanation cannot go back to proposed',
    format($q$UPDATE migration.explanation SET status = 'proposed' WHERE id = %L$q$, e), 'HK_MIG_EXPLANATION_TRANSITION');
  -- توضیح با مبلغ متفاوت
  INSERT INTO migration.explanation (tenant_id, id, job_id, check_kind, key, category, amount, description, created_by, status)
  VALUES (t, uuidv7(), j, 'stock_value', 'W2', 'unknown_cost', -10, 'توضیح با مبلغ نادرست برای آزمون', '60a00000-0000-7000-8000-0000000000a2', 'proposed')
  RETURNING id INTO e2;
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a1');
  UPDATE migration.explanation SET status = 'approved', approved_by = '60a00000-0000-7000-8000-0000000000a1', approved_at = now() WHERE id = e2;
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
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

-- RV-MG-04 / INV-MIG-19: تطبیق پس از تراکنش سازنده‌اش سطر تازه نمی‌پذیرد (line_no یکتا در ۱..line_count)
DO $$
DECLARE j uuid := current_setting('test.j1')::uuid; t uuid := '60a00000-0000-7000-8000-000000000001'; r2 uuid := current_setting('test.r2')::uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_assert((SELECT array_agg(line_no ORDER BY line_no) FROM migration.reconciliation_line WHERE reconciliation_id = r2) = ARRAY[1,2],
                           'T17 line numbers fill 1..line_count');
  PERFORM public.mg_expect_error('T17 a late line cannot be added to a completed reconciliation',
    format($q$INSERT INTO migration.reconciliation_line (tenant_id, job_id, reconciliation_id, check_kind, key, source_value, target_value)
              VALUES (%L, %L, %L, 'clearing', 'OPENING_BALANCE_CLEARING', 0, 987654321)$q$, t, j, r2), 'HK_MIG_RECONCILIATION_TOTALS: reconciliation already holds');
  PERFORM public.mg_expect_error('T17 a late line cannot take an existing line number',
    format($q$INSERT INTO migration.reconciliation_line (tenant_id, job_id, reconciliation_id, line_no, check_kind, key, source_value, target_value)
              VALUES (%L, %L, %L, 1, 'clearing', 'OPENING_BALANCE_CLEARING', 0, 987654321)$q$, t, j, r2), '23505');
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
        e uuid := current_setting('test.e')::uuid; e3 uuid; r3 uuid := uuidv7();
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  UPDATE migration.job SET reconciliation_id = r2, status = 'reconciled' WHERE id = j;
  PERFORM public.mg_expect_error('T18 reconciliation cannot be swapped while reconciled',
    format($q$UPDATE migration.job SET reconciliation_id = (SELECT id FROM migration.reconciliation WHERE job_id = %L AND seq = 1) WHERE id = %L$q$, j, j),
    'HK_MIG_NOT_RECONCILED: move the job back');
  PERFORM public.mg_expect_error('T18 approved explanation cannot be withdrawn while reconciled',
    format($q$UPDATE migration.explanation SET status = 'withdrawn' WHERE id = %L$q$, e), 'HK_MIG_JOB_STATE');
  -- RV-MG-03 / INV-MIG-19: پس‌گرفتن توضیح در committed، همان تطبیق را برای reconciled و live بی‌اعتبار می‌کند
  UPDATE migration.job SET status = 'committed' WHERE id = j;
  UPDATE migration.explanation SET status = 'withdrawn' WHERE id = e;
  PERFORM public.mg_expect_error('T18 a withdrawn explanation invalidates the reconciliation that used it',
    format($q$UPDATE migration.job SET status = 'reconciled' WHERE id = %L$q$, j), 'HK_MIG_NOT_RECONCILED: an explanation');
  INSERT INTO migration.explanation (tenant_id, id, job_id, check_kind, key, category, amount, description, created_by)
  VALUES (t, uuidv7(), j, 'stock_value', 'W1', 'unknown_cost', -2500, 'ارزش ۵ عدد کالای A1 در مبدأ بها ندارد (نسخهٔ دوم)', '60a00000-0000-7000-8000-0000000000a2')
  RETURNING id INTO e3;
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a1');
  UPDATE migration.explanation SET status = 'approved', approved_by = '60a00000-0000-7000-8000-0000000000a1', approved_at = now() WHERE id = e3;
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  INSERT INTO migration.reconciliation (tenant_id, id, job_id, seq, as_of, status, line_count, unexplained_count, report_sha256, created_by)
  VALUES (t, r3, j, 3, '2026-09-22', 'balanced', 2, 0, public.mg_sha('rec3'), '60a00000-0000-7000-8000-0000000000a2');
  INSERT INTO migration.reconciliation_line (tenant_id, job_id, reconciliation_id, check_kind, key, source_value, target_value, explanation_id)
  VALUES (t, j, r3, 'trial_balance', '1101', 1000, 1000, NULL), (t, j, r3, 'stock_value', 'W1', 2500, 0, e3);
  INSERT INTO migration.explanation (tenant_id, id, job_id, check_kind, key, category, amount, description, created_by)
  VALUES (t, '60a00000-0000-7000-8000-00000000e004', j, 'party', 'C001', 'source_rounding', 1, 'گرد کردن مبلغ شخص در مبدأ', '60a00000-0000-7000-8000-0000000000a2');
  UPDATE migration.job SET reconciliation_id = r3, status = 'reconciled' WHERE id = j;
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a1');
  PERFORM public.mg_expect_error('T18 explanations are not approved while reconciled',
    $q$UPDATE migration.explanation SET status = 'approved', approved_by = '60a00000-0000-7000-8000-0000000000a1' WHERE id = '60a00000-0000-7000-8000-00000000e004'$q$,
    'HK_MIG_JOB_STATE: approving an explanation');
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T18 go-live needs the accountant approval',
    format($q$UPDATE migration.job SET status = 'live' WHERE id = %L$q$, j), 'HK_MIG_GOLIVE_APPROVAL');
  PERFORM public.mg_expect_error('T18 go-live approval only with the transition',
    format($q$UPDATE migration.job SET golive_approved_by = '60a00000-0000-7000-8000-0000000000a1', golive_approved_at = now() WHERE id = %L$q$, j),
    'HK_MIG_GOLIVE_STATE');
  -- RV-MG-13 / D-MG20: تأیید زنده شدن کنش خود حسابدار است؛ نه به نام دیگری، نه با ورود به‌جای کاربر
  PERFORM public.mg_expect_error('T18 go-live approval is the acting user''s own act',
    format($q$UPDATE migration.job SET golive_approved_by = '60a00000-0000-7000-8000-0000000000a1', golive_approved_at = now(), status = 'live' WHERE id = %L$q$, j),
    'HK_MIG_ACTOR');
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a1');
  PERFORM set_config('app.impersonation_session_id', uuidv7()::text, true);
  PERFORM public.mg_expect_error('T18 go-live is never approved through impersonation',
    format($q$UPDATE migration.job SET golive_approved_by = '60a00000-0000-7000-8000-0000000000a1', golive_approved_at = now(), status = 'live' WHERE id = %L$q$, j),
    'HK_MIG_ACTOR: go-live approval is never done through impersonation');
  PERFORM set_config('app.impersonation_session_id', '', true);
  UPDATE migration.job SET golive_approved_by = '60a00000-0000-7000-8000-0000000000a1', golive_approved_at = now() - interval '1 day',
         golive_client_ip = '10.0.0.7', status = 'live' WHERE id = j;
  PERFORM public.mg_assert((SELECT locked_at IS NOT NULL AND golive_approved_at = now() FROM migration.job WHERE id = j),
                           'T18 locked_at and approval time set by the server at go-live');
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T18 no rollback after go-live (INV-MIG-20)',
    format($q$UPDATE migration.job SET status = 'rolling_back' WHERE id = %L$q$, j), 'HK_MIG_JOB_TERMINAL');
  PERFORM public.mg_expect_error('T18 live job is terminal',
    format($q$UPDATE migration.job SET title = title, cutover_date = DATE '2026-03-21' WHERE id = %L$q$, j), 'HK_MIG_JOB_TERMINAL');
  -- RV-MG-12: شواهد پایانی (زمان و IP تأیید، پذیرش پیش‌نمایش، تأیید واحد) بازنویسی یا پاک نمی‌شوند
  PERFORM public.mg_expect_error('T18 go-live evidence cannot be rewritten',
    format($q$UPDATE migration.job SET golive_approved_at = '2026-01-01', golive_client_ip = '203.0.113.9' WHERE id = %L$q$, j), 'HK_MIG_JOB_TERMINAL');
  PERFORM public.mg_expect_error('T18 unit confirmation cannot be erased after go-live',
    format($q$UPDATE migration.job SET amount_unit_confirmed_by = NULL, amount_unit_confirmed_at = NULL WHERE id = %L$q$, j), 'HK_MIG_JOB_TERMINAL');
  PERFORM public.mg_expect_error('T18 preview acceptance cannot be rewritten after go-live',
    format($q$UPDATE migration.job SET preview_accepted_at = '2026-01-01' WHERE id = %L$q$, j), 'HK_MIG_JOB_TERMINAL');
  PERFORM public.mg_expect_error('T18 the title of a live job is fixed',
    format($q$UPDATE migration.job SET title = 'عنوان دیگر' WHERE id = %L$q$, j), 'HK_MIG_JOB_TERMINAL');
  UPDATE migration.job SET raw_retain_until = now() + interval '1 day' WHERE id = j;
  PERFORM public.mg_assert((SELECT count(*) FROM migration.job_event WHERE job_id = j) >= 9, 'T18 every transition logged');
  PERFORM public.mg_assert((SELECT row_version > 1 AND updated_at = now() FROM migration.job WHERE id = j), 'T18 job rows are touched on update');
END $$;

-- T19: پاک‌سازی نگهداری کار زنده (INV-MIG-33؛ RV-MG-08): فقط با GUC تراکنشی و پس از مهلت؛ به ترتیب مشکل‌ها، نگاشت‌های کاری،
-- ردیف‌های مرحله‌ای (حتی ثبت‌شده) و snapshot خام. lineage در posting می‌ماند و staged_record_id به NULL می‌رود.
DO $$
DECLARE j uuid := current_setting('test.j1')::uuid; t uuid := '60a00000-0000-7000-8000-000000000001'; n int;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  PERFORM set_config('hk.migration_purge', 'on', true);
  PERFORM public.mg_expect_error('T19 raw purge waits for the retention period',
    format($q$DELETE FROM migration.raw_record WHERE job_id = %L$q$, j), 'HK_MIG_RETENTION: raw rows are kept');
  PERFORM public.mg_expect_error('T19 staged purge waits for the retention period',
    format($q$DELETE FROM migration.staged_record WHERE job_id = %L AND status = 'committed'$q$, j), 'HK_MIG_STAGED_FROZEN');
  PERFORM public.mg_expect_error('T19 issue purge waits for the retention period',
    format($q$DELETE FROM migration.issue WHERE job_id = %L$q$, j), 'HK_MIG_NO_DELETE');
  UPDATE migration.job SET raw_retain_until = now() - interval '1 second' WHERE id = j;
  PERFORM set_config('hk.migration_purge', '', true);
  PERFORM public.mg_expect_error('T19 committed staged rows are purged only by the retention purge',
    format($q$DELETE FROM migration.staged_record WHERE job_id = %L AND status = 'committed'$q$, j), 'HK_MIG_STAGED_FROZEN');
  PERFORM set_config('hk.migration_purge', 'on', true);
  DELETE FROM migration.issue WHERE job_id = j;
  DELETE FROM migration.mapping WHERE job_id = j;
  DELETE FROM migration.staged_record WHERE job_id = j;
  DELETE FROM migration.raw_record WHERE job_id = j;
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM public.mg_assert(n = 3, 'T19 raw rows purged after job end and retention');
  PERFORM public.mg_assert(NOT EXISTS (SELECT 1 FROM migration.staged_record WHERE job_id = j)
                           AND NOT EXISTS (SELECT 1 FROM migration.issue WHERE job_id = j)
                           AND NOT EXISTS (SELECT 1 FROM migration.mapping WHERE job_id = j), 'T19 personal working data of the live job is gone');
  PERFORM public.mg_assert((SELECT count(*) FILTER (WHERE staged_record_id IS NULL) = count(*) AND count(*) = 3
                              AND bool_or(legacy_code = 'C001') FROM migration.posting WHERE job_id = j), 'T19 postings keep their lineage after the purge');
  PERFORM public.mg_assert((SELECT staged_entity = 'voucher' AND partition_class = 'MANUAL' AND disposition = 'history_gl' AND source_key = '900'
                              FROM migration.v_journal_lineage WHERE journal_id = '60a00000-0000-7000-8000-0000000001a1'),
                           'T19 journal drill-down survives the purge');
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
    format($q$UPDATE migration.job SET golive_approved_by = '60a00000-0000-7000-8000-0000000000a2', golive_approved_at = now(), status = 'live' WHERE id = %L$q$, jr),
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
    format($q$UPDATE migration.job SET golive_approved_by = '60a00000-0000-7000-8000-0000000000a2', golive_approved_at = now(), status = 'live' WHERE id = %L$q$, jr),
    'HK_MIG_NOT_RECONCILED: go-live requires');
  -- INV-MIG-23: گیت reconciled هم فقط «آخرین» تطبیق را می‌پذیرد (تطبیق متوازن قدیمی‌تر کافی نیست)
  UPDATE migration.job SET status = 'committed' WHERE id = jr;
  PERFORM public.mg_expect_error('T20 an older balanced reconciliation does not reconcile the job',
    format($q$UPDATE migration.job SET status = 'reconciled' WHERE id = %L$q$, jr), 'HK_MIG_NOT_RECONCILED: the latest');
END $$;

-- T21: rollback پیش از قفل با جبران (INV-MIG-20)
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; jr uuid := current_setting('test.jr')::uuid; pid uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  SELECT id INTO pid FROM migration.posting WHERE job_id = jr LIMIT 1;
  PERFORM public.mg_expect_error('T21 compensation only while rolling back',
    format($q$UPDATE migration.posting SET state = 'compensated', compensated_at = now(), compensation_kind = 'deactivate' WHERE id = %L$q$, pid), 'HK_MIG_JOB_STATE');
  PERFORM public.mg_expect_error('T21 a posting keeps its staged reference outside the purge',
    format($q$UPDATE migration.posting SET staged_record_id = NULL WHERE id = %L$q$, pid), 'HK_MIG_IMMUTABLE_FIELD');
  UPDATE migration.job SET status = 'rolling_back' WHERE id = jr;
  PERFORM public.mg_expect_error('T21 rolled_back needs every posting compensated',
    format($q$UPDATE migration.job SET status = 'rolled_back' WHERE id = %L$q$, jr), 'HK_MIG_ROLLBACK_INCOMPLETE: live postings');
  PERFORM public.mg_expect_error('T21 posting immutable',
    format($q$UPDATE migration.posting SET target_doc_id = uuidv7() WHERE id = %L$q$, pid), 'HK_MIG_IMMUTABLE_FIELD');
  PERFORM public.mg_expect_error('T21 compensation is recorded with the state change',
    format($q$UPDATE migration.posting SET compensation_doc_id = uuidv7() WHERE id = %L$q$, pid), 'HK_MIG_IMMUTABLE_FIELD: compensation');
  -- RV-MG-15: جبران همیشه نوع دارد و جز غیرفعال‌سازی دادهٔ پایه سند جبران می‌خواهد
  PERFORM public.mg_expect_error('T21 compensation names its kind',
    format($q$UPDATE migration.posting SET state = 'compensated', compensation_doc_id = uuidv7() WHERE id = %L$q$, pid), '23514');
  PERFORM public.mg_expect_error('T21 a cancellation needs its compensating document',
    format($q$UPDATE migration.posting SET state = 'compensated', compensation_kind = 'cancel' WHERE id = %L$q$, pid), '23514');
  UPDATE migration.posting SET state = 'compensated', compensation_kind = 'deactivate' WHERE job_id = jr;
  PERFORM public.mg_assert((SELECT bool_and(compensated_at = now()) FROM migration.posting WHERE job_id = jr), 'T21 compensation time is the server time');
  PERFORM public.mg_expect_error('T21 compensated is final',
    format($q$UPDATE migration.posting SET state = 'live', compensated_at = NULL WHERE id = %L$q$, pid), 'HK_MIG_POSTING_TRANSITION');
  PERFORM public.mg_expect_error('T21 posting delete forbidden (no grant)', format($q$DELETE FROM migration.posting WHERE id = %L$q$, pid), '42501');
  PERFORM public.mg_expect_error('T21 rolled_back needs every committed staged row rolled back (INV-MIG-14)',
    format($q$UPDATE migration.job SET status = 'rolled_back' WHERE id = %L$q$, jr), 'HK_MIG_ROLLBACK_INCOMPLETE: committed staged');
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

-- T23: تداوم مؤدیان (INV-MIG-17)
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; j2 uuid := current_setting('test.j2')::uuid; m uuid; c_old uuid; c_new uuid;
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
  INSERT INTO migration.staged_record (tenant_id, job_id, entity, source_system, source_db, source_table, source_key, qty, cost_status, amount_unit)
  VALUES (t, j2, 'stock_opening', 'template', 'T12', 'T12', 'S1', 5, 'unknown', 'IRR');
  INSERT INTO migration.staged_record (tenant_id, job_id, entity, source_system, source_db, source_table, source_key, qty, unit_cost, cost_status, amount_unit)
  VALUES (t, j2, 'stock_opening', 'template', 'T12', 'T12', 'S2', 2, 0, 'user_provided', 'IRR'),
         (t, j2, 'stock_opening', 'template', 'T12', 'T12', 'S3', 2, 15, 'known', 'IRR');
  INSERT INTO migration.mapping (tenant_id, kind, scope, source_value, source_value_norm, target_ref, method, confidence, status)
  VALUES (t, 'bank_account', 'T11', '0102030405', '0102030405', uuidv7(), 'exact_identifier', 1, 'confirmed');
  INSERT INTO migration.staged_record (tenant_id, job_id, raw_record_id, entity, source_system, source_db, source_table, source_key)
  SELECT t, j2, r.id, 'party', 'template', 'Holoo1', 'SANAD', 'raw:' || r.source_key FROM migration.raw_record r WHERE r.job_id = j2 LIMIT 1;
  INSERT INTO migration.issue (tenant_id, job_id, raw_record_id, upload_id, code, severity)
  SELECT t, j2, r.id, p.upload_id, 'MIG_NORMALIZED', 'info'
    FROM migration.raw_record r JOIN migration.package p ON p.id = r.package_id WHERE r.job_id = j2 LIMIT 1;
  INSERT INTO migration.issue (tenant_id, id, job_id, code, severity, field)
  VALUES (t, '60a00000-0000-7000-8000-0000000015e1', j2, 'MIG_NATIONAL_CODE_CHECKSUM', 'error', 'national_code');
  UPDATE migration.issue SET status = 'overridden', override_reason = 'کد ملی با کارت ملی بررسی شد',
         overridden_by = '60a00000-0000-7000-8000-0000000000a2' WHERE id = '60a00000-0000-7000-8000-0000000015e1';
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
  PERFORM public.mg_expect_dry_run_blocks('T23 a continuity write under the dry-run flag never commits',
    format($q$UPDATE migration.moadian_continuity SET status = 'committed' WHERE id = %L$q$, m));
  UPDATE migration.moadian_continuity SET status = 'committed' WHERE id = m;
  PERFORM public.mg_expect_error('T23 committed continuity is frozen',
    format($q$UPDATE migration.moadian_continuity SET connection_mode = 'trusted_company' WHERE id = %L$q$, m), 'HK_MIG_STAGED_FROZEN: committed continuity');
  -- RV-MG-16: رضایت لغوشده کار در حال ثبت را زندانی نمی‌کند؛ رضایت تازه در هر وضعیت غیرپایانی ثبت و جایگزین می‌شود
  c_old := (SELECT consent_id FROM migration.job WHERE id = j2);
  UPDATE migration.consent SET revoked_at = now(), revoked_by = '60a00000-0000-7000-8000-0000000000a2',
         revoke_reason = 'مالک رضایت را با متن تازه جایگزین کرد' WHERE id = c_old;
  c_new := public.mg_consent(j2, 'raw_retention_extended');
  PERFORM public.mg_expect_error('T23 a running job switches only to a data-owner consent',
    format($q$UPDATE migration.job SET consent_id = %L WHERE id = %L$q$, c_new, j2), 'HK_MIG_CONSENT_FIXED');
  c_new := public.mg_consent(j2, 'data_owner_migration');
  UPDATE migration.job SET consent_id = c_new WHERE id = j2;
  PERFORM public.mg_expect_error('T23 a running job never switches back to a revoked consent',
    format($q$UPDATE migration.job SET consent_id = %L WHERE id = %L$q$, c_old, j2), 'HK_MIG_CONSENT_FIXED');
  PERFORM public.mg_assert((SELECT count(*) FROM migration.job_event WHERE job_id = j2 AND note = 'consent:' || c_new) = 1, 'T23 consent switch logged');
END $$;

-- T24: آرشیو فقط با کار آرشیو در حال ثبت؛ فقط‌افزودنی
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; j3 uuid := current_setting('test.j3')::uuid; j2 uuid := current_setting('test.j2')::uuid; a uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T24 archive only by an archive job',
    format($q$INSERT INTO migration.archive_entry (tenant_id, job_id, company_id, fiscal_label, doc_kind, doc_no, amount_unit, payload, source_system, source_table, source_key)
              VALUES (%L, %L, '60a00000-0000-7000-8000-0000000000c2', '1403', 'voucher', '12', 'IRR', '{}', 'template', 'SANAD', '12')$q$, t, j2), 'HK_MIG_ARCHIVE_ONLY');
  PERFORM public.mg_open(j3);
  PERFORM public.mg_stage(j3, 1);
  PERFORM public.mg_party(j3, 'A1');
  UPDATE migration.job SET amount_unit_confirmed_by = '60a00000-0000-7000-8000-0000000000a2', amount_unit_confirmed_at = now() WHERE id = j3;
  UPDATE migration.staged_record SET status = 'valid' WHERE job_id = j3;
  UPDATE migration.job SET status = 'validated' WHERE id = j3;      -- آرشیو سال مالی هدف نمی‌خواهد
  PERFORM public.mg_preview(j3);
  INSERT INTO migration.commit_chunk (tenant_id, job_id, chunk_no, stage, item_count) VALUES (t, j3, 1, 'archive', 1);
  UPDATE migration.job SET status = 'committing' WHERE id = j3;
  INSERT INTO migration.archive_entry (tenant_id, id, job_id, company_id, fiscal_label, doc_kind, doc_no, doc_date, party_name, amount, amount_unit, description, payload,
                                       source_system, source_db, source_table, source_key)
  VALUES (t, uuidv7(), j3, '60a00000-0000-7000-8000-0000000000c2', '1403', 'sales_invoice', '۱۲', '2024-05-01', 'علي رضايي', 1200000, 'IRR', 'فروش', '{"lines":[]}',
          'holoo', 'Holoo1', 'FACTURE', 'F12')
  RETURNING id INTO a;
  PERFORM public.mg_expect_dry_run_blocks('T24 an archive write under the dry-run flag never commits',
    format($q$INSERT INTO migration.archive_entry (tenant_id, job_id, company_id, fiscal_label, doc_kind, amount_unit, payload, source_system, source_db, source_table, source_key)
              VALUES (%L, %L, '60a00000-0000-7000-8000-0000000000c2', '1402', 'voucher', 'IRR', '{}', 'holoo', 'Holoo1', 'SANAD', 'S1')$q$, t, j3));
  -- RV-MG-27: کلید آرشیو پایگاه مبدأ را دارد؛ دو پایگاه هلو (Holoo1/Holoo2) با هم برخورد نمی‌کنند
  INSERT INTO migration.archive_entry (tenant_id, job_id, company_id, fiscal_label, doc_kind, doc_no, amount_unit, payload, source_system, source_db, source_table, source_key)
  VALUES (t, j3, '60a00000-0000-7000-8000-0000000000c2', '1403', 'sales_invoice', '۱۲', 'IRR', '{}', 'holoo', 'Holoo2', 'FACTURE', 'F12');
  PERFORM public.mg_expect_error('T24 one archive entry per source record and year',
    format($q$INSERT INTO migration.archive_entry (tenant_id, job_id, company_id, fiscal_label, doc_kind, amount_unit, payload, source_system, source_db, source_table, source_key)
              VALUES (%L, %L, '60a00000-0000-7000-8000-0000000000c2', '1403', 'sales_invoice', 'IRR', '{}', 'holoo', 'Holoo1', 'FACTURE', 'F12')$q$, t, j3), '23505');
  PERFORM public.mg_expect_error('T24 archive entry carries the job source system',
    format($q$INSERT INTO migration.archive_entry (tenant_id, job_id, company_id, fiscal_label, doc_kind, amount_unit, payload, source_system, source_table, source_key)
              VALUES (%L, %L, '60a00000-0000-7000-8000-0000000000c2', '1403', 'voucher', 'IRR', '{}', 'sepidar', 'SANAD', '77')$q$, t, j3), 'HK_MIG_LINEAGE');
  PERFORM public.mg_assert((SELECT search_key FROM migration.archive_entry WHERE id = a) = core.fa_search_key('۱۲ علي رضايي فروش'), 'T24 archive search key normalized');
  PERFORM public.mg_expect_error('T24 archive append-only (no grant)', format($q$UPDATE migration.archive_entry SET doc_no = '13' WHERE id = %L$q$, a), '42501');
  PERFORM public.mg_expect_error('T24 archive entry company equals job company',
    format($q$INSERT INTO migration.archive_entry (tenant_id, job_id, company_id, fiscal_label, doc_kind, amount_unit, payload, source_system, source_table, source_key)
              VALUES (%L, %L, '60a00000-0000-7000-8000-0000000000c1', '1403', 'voucher', 'IRR', '{}', 'holoo', 'SANAD', '13')$q$, t, j3), '23503');
  UPDATE migration.commit_chunk SET status = 'running' WHERE job_id = j3 AND chunk_no = 1;
  UPDATE migration.commit_chunk SET done_count = 1, status = 'done' WHERE job_id = j3 AND chunk_no = 1;
  UPDATE migration.job SET status = 'committed' WHERE id = j3;
  PERFORM public.mg_expect_error('T24 archive entries only while the archive job is committing',
    format($q$INSERT INTO migration.archive_entry (tenant_id, job_id, company_id, fiscal_label, doc_kind, amount_unit, payload, source_system, source_table, source_key)
              VALUES (%L, %L, '60a00000-0000-7000-8000-0000000000c2', '1403', 'voucher', 'IRR', '{}', 'holoo', 'SANAD', '14')$q$, t, j3), 'HK_MIG_ARCHIVE_ONLY');
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
  -- RV-MG-17 / D-MG24: فقط رضایت پشتیبانی نوشتنی، لغونشده و معتبر
  PERFORM public.mg_expect_error('T25 a read-only support grant cannot back an assisted job',
    $q$SELECT public.mg_new_job('60a00000-0000-7000-8000-0000000000c1', 'sepidar', 'backup', 'opening', false, '60a00000-0000-7000-8000-00000000600e')$q$,
    'HK_MIG_SUPPORT_GRANT');
  j := public.mg_new_job('60a00000-0000-7000-8000-0000000000c1', 'sepidar', 'backup', 'opening', false, '60a00000-0000-7000-8000-00000000600f');
  PERFORM set_config('test.jg', j::text, false);
END $$;
RESET ROLE;
UPDATE core.support_access_grant SET revoked_at = now(), revoked_by = '60a00000-0000-7000-8000-0000000000a1'
 WHERE id = '60a00000-0000-7000-8000-00000000600f';
SET ROLE hk_app;
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; j uuid := current_setting('test.jg')::uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T25 a revoked support grant stops the assisted job',
    format($q$SELECT public.mg_open(%L)$q$, j), 'HK_MIG_SUPPORT_GRANT');
  PERFORM public.mg_expect_error('T25 the grant is renewed only with a valid one',
    format($q$UPDATE migration.job SET support_grant_id = '60a00000-0000-7000-8000-00000000600e' WHERE id = %L$q$, j), 'HK_MIG_SUPPORT_GRANT');
  UPDATE migration.job SET support_grant_id = '60a00000-0000-7000-8000-00000000600d' WHERE id = j;
  PERFORM public.mg_open(j);
  PERFORM public.mg_assert((SELECT status FROM migration.job WHERE id = j) = 'awaiting_source', 'T25 a renewed grant lets the job continue');
  PERFORM public.mg_expect_error('T25 the assisted flag is fixed',
    format($q$UPDATE migration.job SET assisted = false, support_grant_id = NULL WHERE id = %L$q$, j), 'HK_MIG_JOB_IMMUTABLE');
  UPDATE migration.job SET status = 'cancelled' WHERE id = j;
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

-- =====================================================================
-- T31: بازبینی یکپارچه (RV-MG-01/05/06/07/11/22): شرکت در کلید lineage، گیت‌های validated و previewed، dry-run با همان
-- گیت‌های commit، ثبت دوبل کلاس‌محور، نگاشت شناسه (همان T22 پیشین) و رضایت منقضی. شرکت C1 پس از زنده شدن j1 آزاد است.
-- =====================================================================
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; jd uuid; w uuid := '60a00000-0000-7000-8000-00000000d901';
        fx uuid := '60a00000-0000-7000-8000-00000000f200'; x1 uuid; jf uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  -- گذار failed → validated حذف شد (RV-MG-06)؛ failed بی failure_code ممنوع است
  jf := public.mg_new_job('60a00000-0000-7000-8000-0000000000c3', 'template', 'file', 'opening');
  PERFORM public.mg_open(jf);
  PERFORM public.mg_stage(jf, 1);
  PERFORM public.mg_party(jf, 'F1');
  PERFORM public.mg_validate(jf, '60a00000-0000-7000-8000-0000000000f3');
  PERFORM public.mg_expect_error('T31 a failed job names its failure',
    format($q$UPDATE migration.job SET status = 'failed' WHERE id = %L$q$, jf), '23514');
  UPDATE migration.job SET status = 'failed', failure_code = 'MIG_WORKER_CRASH' WHERE id = jf;
  PERFORM public.mg_expect_error('T31 failed never jumps back to validated (RV-MG-06)',
    format($q$UPDATE migration.job SET status = 'validated' WHERE id = %L$q$, jf), 'HK_MIG_JOB_TRANSITION');
  PERFORM public.mg_assert((SELECT note FROM migration.job_event WHERE job_id = jf AND to_status = 'failed') = 'MIG_WORKER_CRASH', 'T31 failure code logged');
  UPDATE migration.job SET status = 'cancelled' WHERE id = jf;

  jd := public.mg_new_job('60a00000-0000-7000-8000-0000000000c1', 'holoo', 'file', 'current_fy');
  PERFORM set_config('test.jd', jd::text, false);
  PERFORM public.mg_open(jd);
  PERFORM public.mg_stage(jd, 1);
  INSERT INTO migration.job_partition_policy (tenant_id, job_id, partition_class, disposition) VALUES
    (t, jd, 'MANUAL', 'history_gl'), (t, jd, 'INVOICE', 'history_gl');
  UPDATE migration.job SET profile_code = 'holoo_std', profile_version = 1 WHERE id = jd;
  x1 := public.mg_party(jd, 'X1');
  INSERT INTO migration.issue (tenant_id, job_id, staged_record_id, code, severity) VALUES (t, jd, x1, 'MIG_DUPLICATE_CANDIDATE', 'warning');
  INSERT INTO migration.mapping (tenant_id, job_id, kind, scope, source_value, source_value_norm, target_value, method, confidence)
  VALUES (t, jd, 'column', 'T03', 'کد', migration.norm_header('کد'), 'code', 'synonym', 1);
  INSERT INTO migration.staged_record (tenant_id, id, job_id, entity, source_system, source_db, source_table, source_key, amount_unit, partition_class, disposition)
  VALUES (t, w, jd, 'voucher', 'holoo', 'Holoo1', 'SANAD', '4512', 'IRR', 'MANUAL', 'history_gl');
  INSERT INTO migration.staged_record (tenant_id, job_id, parent_id, entity, source_system, source_db, source_table, source_key, line_no, debit, amount_unit) VALUES
    (t, jd, w, 'voucher_line', 'holoo', 'Holoo1', 'SND_LIST', '4512:1', 1, 300, 'IRR');
  INSERT INTO migration.staged_record (tenant_id, job_id, parent_id, entity, source_system, source_db, source_table, source_key, line_no, credit, amount_unit) VALUES
    (t, jd, w, 'voucher_line', 'holoo', 'Holoo1', 'SND_LIST', '4512:2', 2, 300, 'IRR');
  INSERT INTO migration.staged_record (tenant_id, id, job_id, entity, source_system, source_db, source_table, source_key, amount_unit)
  VALUES (t, fx, jd, 'invoice_history', 'holoo', 'Holoo1', 'FACTURE', '77', 'IRR');
  UPDATE migration.staged_record SET status = 'valid' WHERE job_id = jd AND parent_id IS NOT NULL;
  UPDATE migration.staged_record SET status = 'valid' WHERE job_id = jd AND parent_id IS NULL;
  -- RV-MG-06: سطر حذف‌شده در وضعیتی که والد را باز نمی‌کند (استخراج دوباره) را گیت validated مجموعه‌ای می‌گیرد
  INSERT INTO migration.staged_record (tenant_id, id, job_id, entity, source_system, source_db, source_table, source_key, amount_unit, partition_class, disposition)
  VALUES (t, '60a00000-0000-7000-8000-00000000d902', jd, 'voucher', 'holoo', 'Holoo1', 'SANAD', '4513', 'IRR', 'MANUAL', 'history_gl');
  INSERT INTO migration.staged_record (tenant_id, job_id, parent_id, entity, source_system, source_db, source_table, source_key, line_no, debit, amount_unit) VALUES
    (t, jd, '60a00000-0000-7000-8000-00000000d902', 'voucher_line', 'holoo', 'Holoo1', 'SND_LIST', '4513:1', 1, 50, 'IRR');
  INSERT INTO migration.staged_record (tenant_id, job_id, parent_id, entity, source_system, source_db, source_table, source_key, line_no, credit, amount_unit) VALUES
    (t, jd, '60a00000-0000-7000-8000-00000000d902', 'voucher_line', 'holoo', 'Holoo1', 'SND_LIST', '4513:2', 2, 50, 'IRR');
  UPDATE migration.staged_record SET status = 'valid' WHERE parent_id = '60a00000-0000-7000-8000-00000000d902';
  UPDATE migration.staged_record SET status = 'valid' WHERE id = '60a00000-0000-7000-8000-00000000d902';
  UPDATE migration.job SET status = 'awaiting_source' WHERE id = jd;
  DELETE FROM migration.staged_record WHERE job_id = jd AND parent_id = '60a00000-0000-7000-8000-00000000d902';
  UPDATE migration.job SET status = 'staged' WHERE id = jd;
  UPDATE migration.job SET status = 'mapping' WHERE id = jd;
  PERFORM public.mg_expect_error('T31 the validated gate rejects a valid voucher left without lines',
    format($q$SELECT public.mg_validate(%L, '60a00000-0000-7000-8000-0000000000f1')$q$, jd), 'HK_MIG_VOUCHER_UNBALANCED: a valid voucher');
  DELETE FROM migration.staged_record WHERE id = '60a00000-0000-7000-8000-00000000d902';
  UPDATE migration.job SET status = 'awaiting_source' WHERE id = jd;
  DELETE FROM migration.staged_record WHERE job_id = jd AND source_key = '4512:2';
  PERFORM public.mg_assert((SELECT status FROM migration.staged_record WHERE id = w) = 'valid', 'T31 re-extraction left the voucher marked valid');
  UPDATE migration.job SET status = 'staged' WHERE id = jd;
  UPDATE migration.job SET status = 'mapping' WHERE id = jd;
  PERFORM public.mg_expect_error('T31 the validated gate re-checks every valid voucher',
    format($q$SELECT public.mg_validate(%L, '60a00000-0000-7000-8000-0000000000f1')$q$, jd), 'HK_MIG_VOUCHER_UNBALANCED: a valid voucher');
  INSERT INTO migration.staged_record (tenant_id, job_id, parent_id, entity, source_system, source_db, source_table, source_key, line_no, credit, amount_unit) VALUES
    (t, jd, w, 'voucher_line', 'holoo', 'Holoo1', 'SND_LIST', '4512:2', 2, 300, 'IRR');
  PERFORM public.mg_validate(jd, '60a00000-0000-7000-8000-0000000000f1');
  PERFORM public.mg_assert((SELECT status FROM migration.job WHERE id = jd) = 'validated', 'T31 job validated');

  -- RV-MG-22: dry-run حالت full_tx همان گیت‌های commit را روی کار validated اجرا می‌کند و هرگز commit نمی‌شود
  PERFORM public.mg_expect_error('T31 without the dry-run flag a validated job takes no commit plan',
    format($q$INSERT INTO migration.commit_chunk (tenant_id, job_id, chunk_no, stage, item_count) VALUES (%L, %L, 1, 'masterdata', 1)$q$, t, jd),
    'HK_MIG_JOB_STATE: planning commit chunks');
  BEGIN
    PERFORM set_config('hk.migration_dry_run', 'on', true);
    INSERT INTO migration.commit_chunk (tenant_id, job_id, chunk_no, stage, item_count) VALUES
      (t, jd, 1, 'masterdata', 1), (t, jd, 2, 'history_gl', 1), (t, jd, 3, 'regenerated_docs', 1);
    UPDATE migration.commit_chunk SET status = 'running' WHERE job_id = jd AND chunk_no = 1;
    INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
                                   target_module, target_doc_type, target_doc_id, gl_effect)
    VALUES (t, jd, 1, x1, 'holoo', 'Holoo1', 'CUSTOMER', 'X1', 'parties', 'parties.party', uuidv7(), 'none');
    UPDATE migration.staged_record SET status = 'committed', committed_chunk = 1 WHERE id = x1;
    UPDATE migration.commit_chunk SET done_count = 1, status = 'done' WHERE job_id = jd AND chunk_no = 1;
    UPDATE migration.commit_chunk SET status = 'running' WHERE job_id = jd AND chunk_no = 2;
    PERFORM public.mg_expect_error('T31 the dry-run exercises the class double-posting guard',
      format($q$INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
                 target_module, target_doc_type, target_doc_id, journal_id, gl_effect)
                VALUES (%L, %L, 2, %L, 'holoo', 'Holoo1', 'FACTURE', '77', 'sales', 'sales.invoice', '60a00000-0000-7000-8000-0000000005a2',
                        '60a00000-0000-7000-8000-0000000001a7', 'posted')$q$, t, jd, fx), 'HK_MIG_DOUBLE_POSTING: class INVOICE is history_gl');
    SET CONSTRAINTS migration.trg_dry_run_sentinel IMMEDIATE;
    RAISE EXCEPTION 'TEST FAILED [T31 a dry-run transaction never commits]';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'HK_MIG_DRY_RUN_COMMIT%' THEN RAISE; END IF;
  END;
  PERFORM public.mg_assert(NOT EXISTS (SELECT 1 FROM migration.commit_chunk WHERE job_id = jd)
                           AND (SELECT status FROM migration.staged_record WHERE id = x1) = 'valid', 'T31 the dry-run left nothing behind');

  -- previewed، سپس بازگشت به mapping پیش‌نمایش را پاک می‌کند (RV-MG-11)
  UPDATE migration.job SET inputs_hash = public.mg_sha('jd-inputs') WHERE id = jd;
  INSERT INTO migration.dry_run (tenant_id, job_id, seq, run_mode, inputs_hash, started_at, outcome, report, report_sha256)
  VALUES (t, jd, 1, 'full_tx', public.mg_sha('jd-inputs'), now(), 'ok', '{}', public.mg_sha('jd-r1'));
  UPDATE migration.job SET preview_dry_run_id = (SELECT id FROM migration.dry_run WHERE job_id = jd AND seq = 1), status = 'previewed' WHERE id = jd;
  UPDATE migration.job SET preview_accepted_by = '60a00000-0000-7000-8000-0000000000a2' WHERE id = jd;
  UPDATE migration.job SET status = 'mapping' WHERE id = jd;
  PERFORM public.mg_assert((SELECT preview_dry_run_id IS NULL AND preview_accepted_by IS NULL AND preview_accepted_at IS NULL FROM migration.job WHERE id = jd),
                           'T31 going back to mapping clears the preview');
  PERFORM public.mg_expect_error('T31 an accepted preview cannot be smuggled into mapping',
    format($q$UPDATE migration.job SET preview_accepted_by = '60a00000-0000-7000-8000-0000000000a2', preview_accepted_at = now() WHERE id = %L$q$, jd),
    'HK_MIG_PREVIEW_STATE');
END $$;

-- RV-MG-06: تراکنش بعدی (زمان سرور دیگر): dry-run ثبت‌شده پیش از آخرین ورود به validated برای پیش‌نمایش پذیرفته نمی‌شود
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; jd uuid := current_setting('test.jd')::uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  UPDATE migration.job SET status = 'validated' WHERE id = jd;
  PERFORM public.mg_expect_error('T31 a dry-run older than the current validation cannot be previewed',
    format($q$UPDATE migration.job SET preview_dry_run_id = (SELECT id FROM migration.dry_run WHERE job_id = %L AND seq = 1), status = 'previewed' WHERE id = %L$q$, jd, jd),
    'HK_MIG_DRY_RUN_REQUIRED');
  INSERT INTO migration.dry_run (tenant_id, job_id, seq, run_mode, inputs_hash, started_at, finished_at, outcome, report, report_sha256)
  VALUES (t, jd, 2, 'full_tx', public.mg_sha('jd-inputs'), now() - interval '1 day', now() + interval '30 days', 'ok', '{}', public.mg_sha('jd-r2'));
  PERFORM public.mg_assert((SELECT finished_at = now() FROM migration.dry_run WHERE job_id = jd AND seq = 2), 'T31 dry-run finish time is the server time');
  UPDATE migration.job SET preview_dry_run_id = (SELECT id FROM migration.dry_run WHERE job_id = jd AND seq = 2), status = 'previewed' WHERE id = jd;
  UPDATE migration.job SET preview_accepted_by = '60a00000-0000-7000-8000-0000000000a2' WHERE id = jd;
  -- برنامهٔ ثبت؛ ترتیب ثابت مرحله‌ها از هر دو سو (RV-MG-15)
  INSERT INTO migration.commit_chunk (tenant_id, job_id, chunk_no, stage, item_count) VALUES (t, jd, 1, 'masterdata', 1), (t, jd, 3, 'regenerated_docs', 2);
  PERFORM public.mg_expect_error('T31 a chunk cannot precede an earlier stage',
    format($q$INSERT INTO migration.commit_chunk (tenant_id, job_id, chunk_no, stage, item_count) VALUES (%L, %L, 2, 'payroll', 1)$q$, t, jd),
    'HK_MIG_CHUNK_ORDER: stage payroll');
  INSERT INTO migration.commit_chunk (tenant_id, job_id, chunk_no, stage, item_count) VALUES (t, jd, 2, 'history_gl', 1);
  UPDATE migration.job SET status = 'committing' WHERE id = jd;
  UPDATE migration.commit_chunk SET status = 'running' WHERE job_id = jd AND chunk_no = 1;
  INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
                                 target_module, target_doc_type, target_doc_id, gl_effect)
  SELECT tenant_id, job_id, 1, id, source_system, source_db, source_table, source_key, 'parties', 'parties.party', uuidv7(), 'none'
    FROM migration.staged_record WHERE job_id = jd AND entity = 'party';
END $$;

-- RV-MG-01: شرکت تمرینی همان مستأجر همان رکوردهای مبدأ را مستقل از شرکت واقعی ثبت می‌کند؛ هرگز حافظهٔ مؤدیان نمی‌گیرد
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; jd uuid := current_setting('test.jd')::uuid; jr2 uuid; px uuid; n int;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  jr2 := public.mg_new_job('60a00000-0000-7000-8000-0000000000c3', 'holoo', 'file', 'opening', true);
  PERFORM set_config('test.jr2', jr2::text, false);
  PERFORM public.mg_open(jr2);
  PERFORM public.mg_stage(jr2, 1);
  px := public.mg_party(jr2, 'X1');
  PERFORM public.mg_expect_error('T31 a rehearsal never stages Moadian continuity',
    format($q$INSERT INTO migration.moadian_continuity (tenant_id, job_id, company_id, memory_id, last_inno, last_taxid, connection_mode, origin)
              VALUES (%L, %L, '60a00000-0000-7000-8000-0000000000c3', 'DEF5GH', '000000000C', 'DEF5GH0481F000000000C2', 'direct', 'template_t17')$q$, t, jr2),
    'HK_MIG_REHEARSAL_SCOPE');
  PERFORM public.mg_validate(jr2, '60a00000-0000-7000-8000-0000000000f3');
  PERFORM public.mg_preview(jr2);
  PERFORM public.mg_expect_error('T31 a rehearsal plans no Moadian stage',
    format($q$INSERT INTO migration.commit_chunk (tenant_id, job_id, chunk_no, stage, item_count) VALUES (%L, %L, 1, 'tax_continuity', 1)$q$, t, jr2),
    'HK_MIG_REHEARSAL_SCOPE');
  INSERT INTO migration.commit_chunk (tenant_id, job_id, chunk_no, stage, item_count) VALUES (t, jr2, 1, 'masterdata', 1);
  UPDATE migration.job SET status = 'committing' WHERE id = jr2;
  UPDATE migration.commit_chunk SET status = 'running' WHERE job_id = jr2 AND chunk_no = 1;
  INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
                                 target_module, target_doc_type, target_doc_id, gl_effect)
  VALUES (t, jr2, 1, px, 'holoo', 'Holoo1', 'CUSTOMER', 'X1', 'parties', 'parties.party', uuidv7(), 'none');
  SELECT count(*) INTO n FROM migration.posting WHERE source_table = 'CUSTOMER' AND source_key = 'X1' AND state = 'live';
  PERFORM public.mg_assert(n = 2, 'T31 the same source record lives once per company (RV-MG-01)');
  PERFORM public.mg_expect_error('T31 a rehearsal never creates tenant-shared targets',
    format($q$INSERT INTO migration.id_map (tenant_id, company_id, source_system, source_db, source_table, source_key, target_kind, target_id, link_method, content_hash, first_job_id, last_job_id)
              VALUES (%L, NULL, 'holoo', 'Holoo1', 'CUSTOMER', 'X1', 'parties.party', uuidv7(), 'created', sha256('x'), %L, %L)$q$, t, jr2, jr2),
    'HK_MIG_REHEARSAL_SCOPE');
  INSERT INTO migration.id_map (tenant_id, company_id, source_system, source_db, source_table, source_key, target_kind, target_id, link_method, content_hash, first_job_id, last_job_id)
  VALUES (t, '60a00000-0000-7000-8000-0000000000c3', 'holoo', 'Holoo1', 'CUSTOMER', 'X1', 'parties.party', uuidv7(), 'created', public.mg_sha('x1'), jr2, jr2);
  UPDATE migration.staged_record SET status = 'committed', committed_chunk = 1 WHERE id = px;
  UPDATE migration.commit_chunk SET done_count = 1, status = 'done' WHERE job_id = jr2 AND chunk_no = 1;
  UPDATE migration.job SET status = 'committed' WHERE id = jr2;
END $$;

-- نگاشت شناسه (INV-MIG-07؛ T22 پیشین) در کار در حال ثبت؛ کلید شرکت‌دار (RV-MG-01)
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; jd uuid := current_setting('test.jd')::uuid; jr2 uuid := current_setting('test.jr2')::uuid;
        m uuid; c1 uuid := '60a00000-0000-7000-8000-0000000000c1';
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  INSERT INTO migration.id_map (tenant_id, id, company_id, source_system, source_db, source_table, source_key, target_kind, target_id, link_method, content_hash, first_job_id, last_job_id)
  VALUES (t, uuidv7(), c1, 'holoo', 'Holoo1', 'CUSTOMER', 'X1', 'parties.party', uuidv7(), 'created', public.mg_sha('c1'), jd, jd) RETURNING id INTO m;
  PERFORM public.mg_expect_error('T31 a source record maps once per target kind and company',
    format($q$INSERT INTO migration.id_map (tenant_id, company_id, source_system, source_db, source_table, source_key, target_kind, target_id, link_method, content_hash, first_job_id, last_job_id)
              VALUES (%L, %L, 'holoo', 'Holoo1', 'CUSTOMER', 'X1', 'parties.party', uuidv7(), 'created', sha256('x'), %L, %L)$q$, t, c1, jd, jd), '23505');
  PERFORM public.mg_expect_error('T31 a source record maps to a shared target or to company targets, not both',
    format($q$INSERT INTO migration.id_map (tenant_id, company_id, source_system, source_db, source_table, source_key, target_kind, target_id, link_method, content_hash, first_job_id, last_job_id)
              VALUES (%L, NULL, 'holoo', 'Holoo1', 'CUSTOMER', 'X1', 'parties.party', uuidv7(), 'linked_existing', sha256('x'), %L, %L)$q$, t, jd, jd),
    'HK_MIG_IDMAP_SCOPE');
  INSERT INTO migration.id_map (tenant_id, company_id, source_system, source_db, source_table, source_key, target_kind, target_id, link_method, content_hash, first_job_id, last_job_id)
  VALUES (t, c1, 'holoo', 'Holoo1', 'CUSTOMER', 'X1', 'ledger.dimension_value', uuidv7(), 'created', public.mg_sha('c1'), jd, jd);
  INSERT INTO migration.id_map (tenant_id, company_id, source_system, source_db, source_table, source_key, target_kind, target_id, link_method, content_hash, first_job_id, last_job_id)
  VALUES (t, NULL, 'holoo', 'Holoo1', 'ARTICLE', 'A9', 'catalog.item', uuidv7(), 'created', public.mg_sha('a9'), jd, jd);
  PERFORM public.mg_expect_error('T31 the id map row company equals the job company',
    format($q$INSERT INTO migration.id_map (tenant_id, company_id, source_system, source_db, source_table, source_key, target_kind, target_id, link_method, content_hash, first_job_id, last_job_id)
              VALUES (%L, '60a00000-0000-7000-8000-0000000000c2', 'holoo', 'Holoo1', 'ARTICLE', 'A8', 'catalog.item', uuidv7(), 'created', sha256('x'), %L, %L)$q$, t, jd, jd),
    '23503');
  PERFORM public.mg_expect_error('T31 a new id map row names one job',
    format($q$INSERT INTO migration.id_map (tenant_id, company_id, source_system, source_db, source_table, source_key, target_kind, target_id, link_method, content_hash, first_job_id, last_job_id)
              VALUES (%L, NULL, 'holoo', 'Holoo1', 'ARTICLE', 'A7', 'catalog.item', uuidv7(), 'created', sha256('x'), %L, %L)$q$, t, jr2, jd),
    'HK_MIG_LINEAGE: a new id map row');
  PERFORM public.mg_expect_error('T31 the id map is written only by a committing job',
    format($q$INSERT INTO migration.id_map (tenant_id, company_id, source_system, source_db, source_table, source_key, target_kind, target_id, link_method, content_hash, first_job_id, last_job_id)
              VALUES (%L, '60a00000-0000-7000-8000-0000000000c3', 'holoo', 'Holoo1', 'ARTICLE', 'A7', 'catalog.item', uuidv7(), 'created', sha256('x'), %L, %L)$q$, t, jr2, jr2),
    'HK_MIG_JOB_STATE: writing the id map');
  PERFORM public.mg_expect_error('T31 target never re-pointed',
    format($q$UPDATE migration.id_map SET target_id = uuidv7() WHERE id = %L$q$, m), 'HK_MIG_IMMUTABLE_FIELD');
  UPDATE migration.id_map SET content_hash = public.mg_sha('c1-v2'), last_job_id = jd WHERE id = m;
  PERFORM public.mg_expect_error('T31 id map delete forbidden (no grant)', format($q$DELETE FROM migration.id_map WHERE id = %L$q$, m), '42501');
  PERFORM public.mg_expect_error('T31 target kind shape',
    format($q$INSERT INTO migration.id_map (tenant_id, company_id, source_system, source_db, source_table, source_key, target_kind, target_id, link_method, content_hash, first_job_id, last_job_id)
              VALUES (%L, %L, 'holoo', 'Holoo1', 'ARTICLE', 'A1', 'item', uuidv7(), 'created', sha256('x'), %L, %L)$q$, t, c1, jd, jd), '23514');
END $$;

-- RV-MG-07: کلاس INVOICE در این کار history_gl است؛ فاکتور تاریخی فقط بی‌GL ثبت می‌شود. سپس تطبیق با حساب کنترل (RV-MG-21).
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; jd uuid := current_setting('test.jd')::uuid; w uuid := '60a00000-0000-7000-8000-00000000d901';
        fx uuid := '60a00000-0000-7000-8000-00000000f200'; r uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  UPDATE migration.staged_record SET status = 'committed', committed_chunk = 1 WHERE job_id = jd AND entity = 'party';
  UPDATE migration.commit_chunk SET done_count = 1, status = 'done' WHERE job_id = jd AND chunk_no = 1;
  UPDATE migration.commit_chunk SET status = 'running' WHERE job_id = jd AND chunk_no = 2;
  INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
                                 target_module, target_doc_type, target_doc_id, journal_id, gl_effect)
  VALUES (t, jd, 2, w, 'holoo', 'Holoo1', 'SANAD', '4512', 'ledger', 'ledger.journal', '60a00000-0000-7000-8000-0000000001a6',
          '60a00000-0000-7000-8000-0000000001a6', 'posted');
  UPDATE migration.staged_record SET status = 'committed', committed_chunk = 2 WHERE job_id = jd AND parent_id = w;
  UPDATE migration.staged_record SET status = 'committed', committed_chunk = 2 WHERE id = w;
  UPDATE migration.commit_chunk SET done_count = 1, status = 'done' WHERE job_id = jd AND chunk_no = 2;
  UPDATE migration.commit_chunk SET status = 'running' WHERE job_id = jd AND chunk_no = 3;
  PERFORM public.mg_expect_error('T31 a sale already in the GL voucher is never regenerated with its own GL (538 doubled Holoo invoices)',
    format($q$INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
               target_module, target_doc_type, target_doc_id, journal_id, gl_effect)
              VALUES (%L, %L, 3, %L, 'holoo', 'Holoo1', 'FACTURE', '77', 'sales', 'sales.invoice', '60a00000-0000-7000-8000-0000000005a2',
                      '60a00000-0000-7000-8000-0000000001a7', 'posted')$q$, t, jd, fx), 'HK_MIG_DOUBLE_POSTING: class INVOICE is history_gl');
  INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
                                 target_module, target_doc_type, target_doc_id, gl_effect)
  VALUES (t, jd, 3, fx, 'holoo', 'Holoo1', 'FACTURE', '77', 'sales', 'sales.invoice', uuidv7(), 'none');
  INSERT INTO migration.posting (tenant_id, job_id, chunk_no, source_system, source_db, source_table, source_key,
                                 target_module, target_doc_type, target_doc_id, gl_effect)
  VALUES (t, jd, 3, 'holoo', 'Holoo1', 'FACTURE', '77', 'treasury', 'treasury.open_item', uuidv7(), 'none');
  UPDATE migration.staged_record SET status = 'committed', committed_chunk = 3 WHERE id = fx;
  UPDATE migration.commit_chunk SET done_count = 2, status = 'done' WHERE job_id = jd AND chunk_no = 3;
  UPDATE migration.job SET status = 'committed' WHERE id = jd;
  -- RV-MG-21 / INV-MIG-38: کاری که موقعیت زیردفتر ساخته، حساب‌های کنترل را هم تطبیق می‌دهد
  BEGIN
    r := uuidv7();
    INSERT INTO migration.reconciliation (tenant_id, id, job_id, seq, as_of, status, line_count, unexplained_count, report_sha256)
    VALUES (t, r, jd, 1, '2026-09-22', 'balanced', 1, 0, public.mg_sha('jd-rec'));
    INSERT INTO migration.reconciliation_line (tenant_id, job_id, reconciliation_id, check_kind, key, source_value, target_value)
    VALUES (t, jd, r, 'trial_balance', 'total', 300, 300);
    SET CONSTRAINTS migration.trg_reconciliation_check IMMEDIATE;
    RAISE EXCEPTION 'TEST FAILED [T31 sub-ledger positions need a control-account reconciliation]';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'HK_MIG_RECONCILIATION_SCOPE: a job with sub-ledger positions%' THEN RAISE; END IF;
  END;
  r := uuidv7();
  INSERT INTO migration.reconciliation (tenant_id, id, job_id, seq, as_of, status, line_count, unexplained_count, report_sha256)
  VALUES (t, r, jd, 1, '2026-09-22', 'balanced', 2, 0, public.mg_sha('jd-rec'));
  INSERT INTO migration.reconciliation_line (tenant_id, job_id, reconciliation_id, check_kind, key, source_value, target_value) VALUES
    (t, jd, r, 'trial_balance', 'total', 300, 300), (t, jd, r, 'control_account', '1103', 0, 0);
  PERFORM set_config('test.jd_rec', r::text, false);
END $$;
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; jd uuid := current_setting('test.jd')::uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  UPDATE migration.job SET reconciliation_id = current_setting('test.jd_rec')::uuid, status = 'reconciled' WHERE id = jd;
  PERFORM public.mg_assert((SELECT status FROM migration.job WHERE id = jd) = 'reconciled', 'T31 job reconciled');
END $$;

-- رضایت منقضی (RV-MG-11: valid_until > now() در هر دو بررسی). گذر زمان با درج شاهد قدیمی (postgres، replica) شبیه‌سازی می‌شود.
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; je uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  je := public.mg_new_job('60a00000-0000-7000-8000-0000000000c3', 'holoo', 'agent', 'archive');
  PERFORM set_config('test.je', je::text, false);
END $$;
RESET ROLE;
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; je uuid := current_setting('test.je')::uuid;
BEGIN
  PERFORM set_config('session_replication_role', 'replica', true);
  INSERT INTO migration.consent (tenant_id, id, job_id, kind, statement_code, statement_version, statement_sha256, signer_user_id,
                                 signer_full_name, signer_capacity, accepted_at, valid_until)
  VALUES (t, '60a00000-0000-7000-8000-00000000ce01', je, 'data_owner_migration', 'mig.consent.old', 1, sha256('old'),
          '60a00000-0000-7000-8000-0000000000a2', 'مالک الف', 'owner', now() - interval '200 days', now() - interval '1 day'),
         (t, '60a00000-0000-7000-8000-00000000ce02', je, 'agent_execution', 'mig.consent.old', 1, sha256('old'),
          '60a00000-0000-7000-8000-0000000000a2', 'مالک الف', 'owner', now() - interval '200 days', now() - interval '1 day');
END $$;
SET ROLE hk_app;
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; je uuid := current_setting('test.je')::uuid; c uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  UPDATE migration.job SET consent_id = '60a00000-0000-7000-8000-00000000ce01' WHERE id = je;
  PERFORM public.mg_expect_error('T31 an expired data-owner consent blocks progress',
    format($q$UPDATE migration.job SET status = 'awaiting_source' WHERE id = %L$q$, je), 'HK_MIG_CONSENT_REQUIRED: an active data-owner');
  c := public.mg_consent(je, 'data_owner_migration');
  UPDATE migration.job SET consent_id = c WHERE id = je;
  PERFORM public.mg_expect_error('T31 an expired channel consent blocks progress',
    format($q$UPDATE migration.job SET status = 'awaiting_source' WHERE id = %L$q$, je), 'HK_MIG_CONSENT_REQUIRED: an active agent_execution');
  PERFORM public.mg_consent(je, 'agent_execution');
  UPDATE migration.job SET status = 'awaiting_source' WHERE id = je;
  INSERT INTO migration.package (tenant_id, id, job_id, producer, format_version, manifest, manifest_sha256, signer_key_id, source_system,
                                 extractor, amount_unit, date_mode, extracted_at, row_count_total)
  VALUES (t, '60a00000-0000-7000-8000-0000000004e1', je, 'server_file', 'hif/1', public.mg_manifest(0), sha256('je'), 'k', 'holoo', 'x', 'IRR',
          'gregorian_datetime', now(), 0);
  UPDATE migration.package SET status = 'rejected', reject_code = 'MIG_PACKAGE_SIGNATURE' WHERE id = '60a00000-0000-7000-8000-0000000004e1';
  PERFORM public.mg_expect_error('T31 a running job never switches to an expired consent',
    format($q$UPDATE migration.job SET consent_id = '60a00000-0000-7000-8000-00000000ce01' WHERE id = %L$q$, je), 'HK_MIG_CONSENT_FIXED');
  -- منبع و کنار گذاشتن: ثبت ارقام مبدأ، مشکل و بسته فقط در وضعیت‌های مجاز (RV-MG-11)
  UPDATE migration.job SET status = 'cancelled' WHERE id = je;
  PERFORM public.mg_expect_error('T31 no source figures for a cancelled job',
    format($q$INSERT INTO migration.source_balance (tenant_id, job_id, origin, as_of, key_kind, key, value) VALUES (%L, %L, 'user_declared', '2026-09-22', 'doc_count', 'SANAD', 1)$q$, t, je),
    'HK_MIG_JOB_STATE');
  PERFORM public.mg_expect_error('T31 no issues on a cancelled job',
    format($q$INSERT INTO migration.issue (tenant_id, job_id, code, severity) VALUES (%L, %L, 'MIG_NORMALIZED', 'info')$q$, t, je), 'HK_MIG_JOB_STATE');
  PERFORM public.mg_expect_error('T31 no consent on a cancelled job',
    format($q$SELECT public.mg_consent(%L, 'data_owner_migration')$q$, je), 'HK_MIG_JOB_STATE');
END $$;

-- حالت‌های مجاز نوشتن فرزندان کار j2 (در حال ثبت) و کار jd (reconciled) (RV-MG-11)
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; j2 uuid := current_setting('test.j2')::uuid; jd uuid := current_setting('test.jd')::uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  PERFORM public.mg_expect_error('T31 no new package while committing',
    format($q$INSERT INTO migration.package (tenant_id, job_id, producer, format_version, manifest, manifest_sha256, signer_key_id, source_system,
               extractor, amount_unit, date_mode, extracted_at, row_count_total)
              VALUES (%L, %L, 'server_file', 'hif/1', public.mg_manifest(0), sha256('m'), 'k', 'template', 'x', 'IRR', 'gregorian_datetime', now(), 0)$q$, t, j2),
    'HK_MIG_JOB_STATE');
  PERFORM public.mg_expect_error('T31 no reconciliation while committing',
    format($q$INSERT INTO migration.reconciliation (tenant_id, job_id, seq, as_of, status, line_count, unexplained_count, report_sha256)
              VALUES (%L, %L, 1, '2026-09-22', 'balanced', 1, 0, sha256('x'))$q$, t, j2), 'HK_MIG_JOB_STATE');
  PERFORM public.mg_expect_error('T31 continuity rows are kept once mapping is over',
    format($q$DELETE FROM migration.moadian_continuity WHERE job_id = %L$q$, j2), 'HK_MIG_JOB_STATE');
  PERFORM public.mg_expect_error('T31 job mappings are frozen while committing (delete)',
    format($q$DELETE FROM migration.mapping WHERE job_id = %L$q$, jd), 'HK_MIG_JOB_STATE');
  PERFORM public.mg_expect_error('T31 the partition policy is frozen (delete)',
    format($q$DELETE FROM migration.job_partition_policy WHERE job_id = %L$q$, jd), 'HK_MIG_JOB_STATE');
  PERFORM public.mg_expect_error('T31 an issue resolution is recorded with its status change',
    format($q$UPDATE migration.issue SET overridden_at = now() WHERE job_id = %L$q$, jd), 'HK_MIG_ISSUE_TRANSITION: the resolution');
  PERFORM public.mg_expect_error('T31 no explanation on a cancelled job',
    format($q$INSERT INTO migration.explanation (tenant_id, job_id, check_kind, key, category, amount, description, created_by)
              VALUES (%L, %L, 'party', 'P', 'source_rounding', 1, 'توضیح برای کار لغوشده', '60a00000-0000-7000-8000-0000000000a2')$q$,
           t, current_setting('test.je')), 'HK_MIG_JOB_STATE');
  -- INV-MIG-33: مهلت گذشته کافی نیست؛ پاک‌سازی فقط برای کار پایانی
  UPDATE migration.job SET raw_retain_until = now() - interval '1 day' WHERE id = jd;
  PERFORM set_config('hk.migration_purge', 'on', true);
  PERFORM public.mg_expect_error('T31 the purge never touches a job that has not ended',
    format($q$DELETE FROM migration.staged_record WHERE job_id = %L$q$, jd), 'HK_MIG_STAGED_FROZEN');
  PERFORM set_config('hk.migration_purge', '', true);
  -- RV-MG-04: سطر تطبیق فقط در committed/reconciled؛ اگر کار در همان تراکنش به rolling_back برود سطر بعدی رد می‌شود
  BEGIN
    INSERT INTO migration.reconciliation (tenant_id, id, job_id, seq, as_of, status, line_count, unexplained_count, report_sha256)
    VALUES (t, '60a00000-0000-7000-8000-00000000ec31', current_setting('test.jr2')::uuid, 1, '2026-09-22', 'balanced', 2, 0, sha256('jr2'));
    INSERT INTO migration.reconciliation_line (tenant_id, job_id, reconciliation_id, check_kind, key, source_value, target_value)
    VALUES (t, current_setting('test.jr2')::uuid, '60a00000-0000-7000-8000-00000000ec31', 'trial_balance', 'total', 0, 0);
    UPDATE migration.job SET status = 'rolling_back' WHERE id = current_setting('test.jr2')::uuid;
    PERFORM public.mg_expect_error('T31 no reconciliation lines once the job is rolling back',
      format($q$INSERT INTO migration.reconciliation_line (tenant_id, job_id, reconciliation_id, check_kind, key, source_value, target_value)
                VALUES (%L, %L, '60a00000-0000-7000-8000-00000000ec31', 'party', 'X1', 0, 0)$q$, t, current_setting('test.jr2')),
      'HK_MIG_JOB_STATE: adding reconciliation lines');
    RAISE EXCEPTION 'MG_ROLLBACK_SUBTX';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'MG_ROLLBACK_SUBTX' THEN RAISE; END IF;
  END;
  -- RV-MG-22: نگهبان تأخیری روی هر جدول نوشتنی commit (حتی در کار committing، پرچم dry-run یعنی بی COMMIT)
  PERFORM public.mg_expect_dry_run_blocks('T31 a posting under the dry-run flag never commits',
    format($q$INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db, source_table, source_key,
               target_module, target_doc_type, target_doc_id, gl_effect)
              SELECT tenant_id, job_id, 1, id, source_system, source_db, source_table, source_key, 'parties', 'parties.party', uuidv7(), 'none'
                FROM migration.staged_record WHERE job_id = %L AND entity = 'party'$q$, j2));
  PERFORM public.mg_expect_dry_run_blocks('T31 a staged commit under the dry-run flag never commits',
    format($q$UPDATE migration.staged_record SET status = 'committed', committed_chunk = 1 WHERE job_id = %L AND entity = 'party'$q$, j2));
  PERFORM public.mg_expect_dry_run_blocks('T31 an id map write under the dry-run flag never commits',
    format($q$INSERT INTO migration.id_map (tenant_id, company_id, source_system, source_db, source_table, source_key, target_kind, target_id, link_method, content_hash, first_job_id, last_job_id)
              VALUES (%L, '60a00000-0000-7000-8000-0000000000c2', 'template', 'Holoo1', 'CUSTOMER', 'P1', 'parties.party', uuidv7(), 'created', sha256('p1'), %L, %L)$q$, t, j2, j2));
  PERFORM public.mg_expect_dry_run_blocks('T31 a chunk update under the dry-run flag never commits',
    format($q$UPDATE migration.commit_chunk SET done_count = 1, status = 'done' WHERE job_id = %L AND chunk_no = 1$q$, j2));
  PERFORM public.mg_expect_error('T31 no source figures after reconciliation is over',
    format($q$INSERT INTO migration.source_balance (tenant_id, job_id, origin, as_of, key_kind, key, value) VALUES (%L, %L, 'user_declared', '2026-09-22', 'doc_count', 'SANAD', 1)$q$,
           t, current_setting('test.j1')), 'HK_MIG_JOB_STATE');
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
  INSERT INTO migration.profile (code, version, source_system, title, channel, source_versions, fingerprint, spec, spec_sha256, confidence, status,
                                 golden_dataset_ref, real_sample_verified_at, published_at)
  VALUES ('sepidar_std', 1, 'sepidar', 'سپیدار', 'agent', 'Sepidar01', '{"tables":["ACC.Voucher"]}', '{"queries":{}}', sha256('sp'), 'high', 'published',
          'golden/sepidar/v1', now(), now()),
         ('holoo_apex', 1, 'holoo', 'هلو APEX', 'agent', 'APEX', '{"tables":[]}', '{"queries":{}}', sha256('ap'), 'low', 'draft', NULL, NULL, NULL);
  PERFORM public.mg_expect_error('T29 retired profile cannot be republished',
    $q$UPDATE migration.profile SET status = 'published' WHERE code = 'holoo_classic'$q$, 'HK_MIG_PROFILE_IMMUTABLE');
  INSERT INTO migration.header_synonym (field_key, entity, source_system, synonym_norm, dict_version, origin)
  VALUES ('voucher_no', 'voucher', 'holoo', migration.norm_header('Sanad_Code'), 1, 'seed');
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
  -- RV-MG-27 / R-APPEND: هیچ جدول مستأجری migration حتی برای مالک TRUNCATE نمی‌شود
  PERFORM public.mg_expect_error('T29 trigger: postings never truncated', $q$TRUNCATE migration.posting$q$, 'HK_IMMUTABLE');
  PERFORM public.mg_expect_error('T29 trigger: id map never truncated', $q$TRUNCATE migration.id_map$q$, 'HK_IMMUTABLE');
  PERFORM public.mg_expect_error('T29 trigger: job events never truncated', $q$TRUNCATE migration.job_event$q$, 'HK_IMMUTABLE');
  PERFORM public.mg_expect_error('T29 trigger: reconciliation lines never truncated', $q$TRUNCATE migration.reconciliation_line$q$, 'HK_IMMUTABLE');
  PERFORM public.mg_assert((SELECT count(*) FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                             WHERE n.nspname = 'migration' AND tg.tgname = 'trg_no_truncate') =
                           (SELECT count(*) FROM pg_tables t JOIN pg_attribute a ON a.attrelid = (t.schemaname || '.' || t.tablename)::regclass
                             AND a.attname = 'tenant_id' WHERE t.schemaname = 'migration'), 'T29 every migration tenant table forbids TRUNCATE');
  PERFORM public.mg_expect_error('T29 overridable codes name a permission',
    $q$INSERT INTO migration.issue_code (code, category, default_severity, overridable, message_key, introduced_in) VALUES ('MIG_X_TEST', 'business', 'error', true, 'x', '1.0')$q$, '23514');
END $$;

SELECT public.mg_assert(NOT EXISTS (SELECT 1 FROM core.security_lint() WHERE object LIKE 'migration.%'), 'T30 core.security_lint clean for schema migration');
SELECT public.mg_assert((SELECT count(*) FROM core.export_table_registry WHERE schema_name = 'migration') =
                        (SELECT count(*) FROM pg_tables t JOIN pg_attribute a ON a.attrelid = (t.schemaname || '.' || t.tablename)::regclass
                          AND a.attname = 'tenant_id' WHERE t.schemaname = 'migration'), 'T30 every migration tenant table is in the export registry');
-- RV-MG-19 / R-EXPORT: هیچ جدول migration که با ردیف‌هایش صادر می‌شود به جدول skip ارجاع FK ندارد؛ جدول hook فقط با ستونی
-- که هنگام صدور NULL می‌شود (ON DELETE SET NULL) — پس بستهٔ .hkx هرگز FK آویزان نمی‌سازد (core.import_verify: dangling_fk)
SELECT public.mg_assert(NOT EXISTS (
  SELECT 1 FROM pg_constraint con
    JOIN core.export_table_registry rs ON (rs.schema_name || '.' || rs.table_name)::regclass = con.conrelid
    JOIN core.export_table_registry rd ON (rd.schema_name || '.' || rd.table_name)::regclass = con.confrelid
   WHERE con.contype = 'f' AND rs.schema_name = 'migration' AND rd.mode = 'skip'
     AND (rs.mode = 'rows' OR (rs.mode = 'hook' AND con.confdeltype <> 'n'))), 'T30 exported migration rows never reference skipped tables');
SELECT public.mg_assert((SELECT mode FROM core.export_table_registry WHERE schema_name = 'migration' AND table_name = 'posting') = 'hook',
                        'T30 postings are exported by the migration hook (staged reference nulled)');
-- RV-MG-09 / RV-X1-06: هر دو خانوادهٔ رویداد migration به uplink تحویل می‌شوند
SELECT public.mg_assert((SELECT count(*) FROM core.event_subscription WHERE subscriber = 'uplink'
                           AND event_type IN ('migration.job.*','migration.mapping.confirmed')) = 2, 'T30 migration uplink subscriptions');
SELECT public.mg_assert((SELECT count(*) FROM core.permission WHERE module = 'migration') = 13, 'T30 migration permissions registered');
SELECT public.mg_assert((SELECT allow_impersonation_write FROM core.permission WHERE code = 'migration.job.golive') = false, 'T30 go-live never by impersonation');
SELECT public.mg_assert(NOT has_table_privilege('hk_app', 'migration.dry_run', 'UPDATE') AND NOT has_table_privilege('hk_app', 'migration.reconciliation_line', 'DELETE')
                        AND NOT has_table_privilege('hk_app', 'migration.job', 'DELETE'), 'T30 append-only grants');

-- RV-MG-09 / RV-X1-06: رویدادهای migration.job.* و migration.mapping.confirmed هر دو به uplink (صف نامزد فرهنگ پنل مالک) می‌رسند
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; e1 uuid := uuidv7(); e2 uuid := uuidv7();
BEGIN
  PERFORM set_config('app.tenant_id', t::text, true);
  INSERT INTO core.outbox_event (tenant_id, id, event_type, aggregate_type, aggregate_id, payload) VALUES
    (t, e1, 'migration.mapping.confirmed', 'migration.mapping', uuidv7(), '{"kind":"column","dict_kind":"header_synonym"}'),
    (t, e2, 'migration.job.live', 'migration.job', uuidv7(), '{}');
  PERFORM public.mg_assert((SELECT count(*) FROM core.outbox_delivery WHERE event_id IN (e1, e2) AND subscriber = 'uplink') = 2,
                           'T30 both migration event families are delivered to uplink');
END $$;

-- =====================================================================
-- T32: همروندی واقعی (RV-MG-02) با دو نشست (postgres + dblink؛ نشست‌ها با نقش hk_app). نشست اول نوشتن فرزند یا گذار را
-- باز نگه می‌دارد؛ دومی باید منتظر بماند (قفل نگرفته در pg_locks) و پس از commit اولی با وضعیت تازه رد شود.
-- پیش‌نیاز: افزونهٔ contrib «dblink» و احراز trust روی سوکت محلی؛ در نبود آن NOTICE «SKIP».
-- =====================================================================
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'dblink') THEN
    CREATE SCHEMA IF NOT EXISTS mgc;
    CREATE EXTENSION IF NOT EXISTS dblink SCHEMA mgc;
  ELSE
    RAISE NOTICE 'SKIP T32: the contrib extension dblink is not installed';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.mgc_open(p_name text, p_user uuid, p_tenant uuid DEFAULT '60a00000-0000-7000-8000-000000000001') RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_pid integer;
BEGIN
  PERFORM mgc.dblink_connect(p_name, format('dbname=%s user=%s host=%s port=%s', current_database(), current_user,
                                            split_part(current_setting('unix_socket_directories'), ',', 1), current_setting('port')));
  PERFORM mgc.dblink_exec(p_name, 'SET ROLE hk_app');
  PERFORM mgc.dblink_exec(p_name, 'BEGIN');
  PERFORM 1 FROM mgc.dblink(p_name, format($q$SELECT public.mg_ctx(%L, %L)::text$q$, p_tenant, p_user)) AS x(v text);
  SELECT x.pid INTO v_pid FROM mgc.dblink(p_name, 'SELECT pg_backend_pid()') AS x(pid integer);
  RETURN v_pid;
END $$;

CREATE OR REPLACE FUNCTION public.mgc_blocked(p_pid integer) RETURNS boolean
LANGUAGE plpgsql AS $$
BEGIN
  FOR i IN 1..200 LOOP
    IF EXISTS (SELECT 1 FROM pg_locks WHERE pid = p_pid AND NOT granted) THEN RETURN true; END IF;
    PERFORM pg_sleep(0.02);
  END LOOP;
  RETURN false;
END $$;

CREATE OR REPLACE FUNCTION public.mgc_finish(p_name text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v text; e text;
BEGIN
  SELECT x.v INTO v FROM mgc.dblink_get_result(p_name, false) AS x(v text);
  e := mgc.dblink_error_message(p_name);
  PERFORM 1 FROM mgc.dblink_get_result(p_name, false) AS x(v text);
  RETURN CASE WHEN e = 'OK' THEN coalesce(v, 'OK') ELSE 'ERROR: ' || regexp_replace(e, '^ERROR:\s+', '') END;
END $$;

-- (الف) INV-MIG-23: زنده شدن منتظر تطبیق تازهٔ در جریان می‌ماند و پس از commit آن (با اختلاف) رد می‌شود
DO $$
DECLARE jd uuid := current_setting('test.jd')::uuid; pid_g integer; v text; r uuid := uuidv7();
BEGIN
  IF to_regnamespace('mgc') IS NULL THEN RETURN; END IF;
  PERFORM public.mgc_open('r', '60a00000-0000-7000-8000-0000000000a2');
  pid_g := public.mgc_open('g', '60a00000-0000-7000-8000-0000000000a1');
  PERFORM mgc.dblink_exec('r', format($q$INSERT INTO migration.reconciliation (tenant_id, id, job_id, seq, as_of, status, line_count, unexplained_count, report_sha256)
                                         VALUES ('60a00000-0000-7000-8000-000000000001', %L, %L, 2, '2026-09-22', 'differences', 2, 1, sha256('race'))$q$, r, jd));
  PERFORM mgc.dblink_exec('r', format($q$INSERT INTO migration.reconciliation_line (tenant_id, job_id, reconciliation_id, check_kind, key, source_value, target_value)
                                         VALUES ('60a00000-0000-7000-8000-000000000001', %L, %L, 'trial_balance', 'total', 5000000, 0),
                                                ('60a00000-0000-7000-8000-000000000001', %L, %L, 'control_account', '1103', 0, 0)$q$, jd, r, jd, r));
  PERFORM mgc.dblink_send_query('g', format($q$UPDATE migration.job SET golive_approved_by = '60a00000-0000-7000-8000-0000000000a1',
                                                 status = 'live' WHERE id = %L RETURNING status$q$, jd));
  PERFORM public.mg_assert(public.mgc_blocked(pid_g), 'T32 go-live waits for an in-flight reconciliation of the job (RV-MG-02)');
  PERFORM mgc.dblink_exec('r', 'COMMIT');
  v := public.mgc_finish('g');
  PERFORM public.mg_assert(v LIKE 'ERROR: HK_MIG_NOT_RECONCILED%', 'T32 go-live sees the new unbalanced reconciliation: ' || coalesce(v, '-'));
  PERFORM mgc.dblink_exec('g', 'ROLLBACK');
  PERFORM mgc.dblink_disconnect('r'); PERFORM mgc.dblink_disconnect('g');
  PERFORM public.mg_assert((SELECT status FROM migration.job WHERE id = jd) = 'reconciled', 'T32 the job did not go live on a stale reconciliation');
END $$;

-- (ب) INV-MIG-20: ثبت در تکهٔ در حال اجرا منتظر گذار rollback هم‌زمان می‌ماند و پس از آن رد می‌شود
DO $$
DECLARE j2 uuid := current_setting('test.j2')::uuid; pid_q integer; v text;
BEGIN
  IF to_regnamespace('mgc') IS NULL THEN RETURN; END IF;
  PERFORM public.mgc_open('p', '60a00000-0000-7000-8000-0000000000a2');
  pid_q := public.mgc_open('q', '60a00000-0000-7000-8000-0000000000a2');
  PERFORM mgc.dblink_exec('p', format($q$UPDATE migration.job SET status = 'rolling_back' WHERE id = %L$q$, j2));
  PERFORM mgc.dblink_send_query('q', format($q$INSERT INTO migration.posting (tenant_id, job_id, chunk_no, staged_record_id, source_system, source_db,
                                                 source_table, source_key, target_module, target_doc_type, target_doc_id, gl_effect)
                                               SELECT tenant_id, job_id, 1, id, source_system, source_db, source_table, source_key, 'parties',
                                                      'parties.party', uuidv7(), 'none'
                                                 FROM migration.staged_record WHERE job_id = %L AND entity = 'party'
                                               RETURNING id::text$q$, j2));
  PERFORM public.mg_assert(public.mgc_blocked(pid_q), 'T32 a posting waits for a concurrent rollback transition (RV-MG-02)');
  PERFORM mgc.dblink_exec('p', 'COMMIT');
  v := public.mgc_finish('q');
  PERFORM public.mg_assert(v LIKE 'ERROR: HK_MIG_JOB_STATE: recording a posting is not allowed while the job is rolling_back%',
                           'T32 the posting sees the rollback: ' || coalesce(v, '-'));
  PERFORM mgc.dblink_exec('q', 'ROLLBACK');
  PERFORM mgc.dblink_disconnect('p'); PERFORM mgc.dblink_disconnect('q');
  PERFORM public.mg_assert(NOT EXISTS (SELECT 1 FROM migration.posting WHERE job_id = j2), 'T32 no posting slipped into the rolled-back job');
END $$;

-- (پ) RV-MG-02: بارگذاری ردیف خام بستهٔ received و تأیید هم‌زمان سریالی‌اند (FOR SHARE روی بسته): تأیید منتظر ردیف در جریان
-- می‌ماند و پس از commit آن شمار درست را می‌بیند. کار jb مستأجر B در awaiting_source است (T26).
DO $$
DECLARE t uuid := '60b00000-0000-7000-8000-000000000001'; jb uuid; u uuid := uuidv7(); p uuid := uuidv7();
BEGIN
  IF to_regnamespace('mgc') IS NULL THEN RETURN; END IF;
  PERFORM set_config('app.tenant_id', t::text, true);
  SELECT id INTO jb FROM migration.job WHERE tenant_id = t AND status = 'awaiting_source';
  INSERT INTO migration.upload (tenant_id, id, job_id, kind, file_name, storage_backend, bucket, object_key, encryption_key_ref, purge_after)
  VALUES (t, u, jb, 'hif', 'b.hif', 'fs', 'local', 't/' || t || '/migration/' || jb || '/' || u, 'dek', now() + interval '30 days');
  UPDATE migration.upload SET status = 'uploaded', size_bytes = 10, sha256 = sha256('b'), uploaded_at = now() WHERE id = u;
  UPDATE migration.upload SET status = 'scanning', sniffed_format = 'hif' WHERE id = u;
  UPDATE migration.upload SET status = 'accepted' WHERE id = u;
  INSERT INTO migration.package (tenant_id, id, job_id, upload_id, producer, format_version, manifest, manifest_sha256, signer_key_id,
                                 source_system, source_db, extractor, amount_unit, date_mode, extracted_at, row_count_total)
  VALUES (t, p, jb, u, 'server_api', 'hif/1', public.mg_manifest(2, 'contact'), sha256('mb'), 'server:k1', 'hesabfa', 'biz-1',
          'hk-extract/1', 'IRR', 'gregorian_datetime', now(), 2);
  INSERT INTO migration.raw_record (tenant_id, job_id, package_id, source_system, source_db, source_table, source_key, row_no, payload, content_hash)
  VALUES (t, jb, p, 'hesabfa', 'biz-1', 'contact', 'k1', 1, '{"Code":1}', sha256('k1'));
  PERFORM set_config('test.pb', p::text, false);
  PERFORM set_config('test.jb', jb::text, false);
END $$;
DO $$
DECLARE t uuid := '60b00000-0000-7000-8000-000000000001'; jb uuid := current_setting('test.jb')::uuid; p uuid := current_setting('test.pb')::uuid;
        pid_v integer; v text;
BEGIN
  IF to_regnamespace('mgc') IS NULL THEN RETURN; END IF;
  PERFORM public.mgc_open('a', '60b00000-0000-7000-8000-0000000000b1', t);
  pid_v := public.mgc_open('v', '60b00000-0000-7000-8000-0000000000b1', t);
  PERFORM mgc.dblink_exec('a', format($q$INSERT INTO migration.raw_record (tenant_id, job_id, package_id, source_system, source_db, source_table,
                                           source_key, row_no, payload, content_hash)
                                         VALUES (%L, %L, %L, 'hesabfa', 'biz-1', 'contact', 'k2', 2, '{"Code":2}', sha256('k2'))$q$, t, jb, p));
  PERFORM mgc.dblink_send_query('v', format($q$UPDATE migration.package SET status = 'verified', signature_verified_at = now() WHERE id = %L
                                               RETURNING status$q$, p));
  PERFORM public.mg_assert(public.mgc_blocked(pid_v), 'T32 package verification waits for an in-flight raw row (RV-MG-02)');
  PERFORM mgc.dblink_exec('a', 'COMMIT');
  v := public.mgc_finish('v');
  PERFORM public.mg_assert(v = 'verified', 'T32 verification counts the committed raw row: ' || coalesce(v, '-'));
  PERFORM mgc.dblink_exec('v', 'COMMIT');
  PERFORM mgc.dblink_disconnect('a'); PERFORM mgc.dblink_disconnect('v');
END $$;

-- INV-MIG-14 (RV-MG-15): rolled_back تا وقتی تداوم ثبت‌شده باقی است ممکن نیست (کار j2 پس از (ب) در rolling_back است)
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001'; j2 uuid := current_setting('test.j2')::uuid;
BEGIN
  PERFORM public.mg_ctx(t, '60a00000-0000-7000-8000-0000000000a2');
  IF (SELECT status FROM migration.job WHERE id = j2) <> 'rolling_back' THEN
    UPDATE migration.job SET status = 'rolling_back' WHERE id = j2;
  END IF;
  PERFORM public.mg_expect_error('T32 rolled_back waits for the committed continuity to be reverted',
    format($q$UPDATE migration.job SET status = 'rolled_back' WHERE id = %L$q$, j2), 'HK_MIG_ROLLBACK_INCOMPLETE: committed staged or continuity');
  UPDATE migration.moadian_continuity SET status = 'rolled_back' WHERE job_id = j2;
  UPDATE migration.job SET status = 'rolled_back' WHERE id = j2;
END $$;

-- =====================================================================
-- T33: پوشش ساختاری (RV-MG-11). موجودی اشیای اسکیما (برای هر جدول: شمار CHECK، FK، کلید اصلی، UNIQUE، ایندکس یکتای
-- بی‌قید و تریگر کاربر) دقیقاً همین است؛ حذف یا افزودن هر قید، ایندکس یا تریگری بی بازبینی همین آزمون قرمز می‌شود.
-- =====================================================================
SELECT public.mg_assert((
  SELECT string_agg(x, ';' ORDER BY x) FROM (
    SELECT c.relname || ':' || string_agg(k || n, ',' ORDER BY k) AS x
      FROM (SELECT con.conrelid AS rel, con.contype::text AS k, count(*) AS n FROM pg_constraint con
              JOIN pg_namespace ns ON ns.oid = con.connamespace WHERE ns.nspname = 'migration' AND con.contype IN ('c','f','u','p')
             GROUP BY 1, 2
            UNION ALL
            SELECT i.indrelid, 'i', count(*) FROM pg_index i JOIN pg_class t ON t.oid = i.indrelid JOIN pg_namespace ns ON ns.oid = t.relnamespace
             WHERE ns.nspname = 'migration' AND NOT EXISTS (SELECT 1 FROM pg_constraint c2 WHERE c2.conindid = i.indexrelid) GROUP BY 1
            UNION ALL
            SELECT tg.tgrelid, 't', count(*) FROM pg_trigger tg JOIN pg_class t ON t.oid = tg.tgrelid JOIN pg_namespace ns ON ns.oid = t.relnamespace
             WHERE ns.nspname = 'migration' AND NOT tg.tgisinternal GROUP BY 1) q
      JOIN pg_class c ON c.oid = q.rel GROUP BY c.relname) z)
  = 'agent_session:c11,f3,p1,t3,u2;archive_entry:c3,f2,i2,p1,t4,u2;commit_chunk:c9,f2,p1,t4,u2;consent:c11,f5,i1,p1,t2,u2;dry_run:c8,f3,p1,t3,u3;explanation:c11,f4,p1,t3,u2;header_synonym:c5,f1,i1,p1;id_map:c5,f6,i1,p1,t4,u2;issue:c6,f7,i2,p1,t3,u1;issue_code:c5,f1,p1;job:c16,f13,i2,p1,t4,u2;job_event:f3,i1,p1,t2,u1;job_partition_policy:f4,p1,t2,u2;mapping:c13,f4,i1,p1,t3,u1;moadian_continuity:c7,f2,p1,t4,u2;package:c15,f7,i1,p1,t2,u2;partition_rule:c4,i1,p1;posting:c9,f6,i3,p1,t3,u1;profile:c10,f1,p1,t1;raw_record:c5,f2,p1,t2,u3;reconciliation:c7,f3,p1,t4,u3;reconciliation_line:c2,f3,p1,t3,u3;source_balance:c4,f2,i1,p1,t3,u1;source_credential:c6,f3,p1,t3,u1;source_system:c5,p1;staged_record:c24,f5,i2,p1,t6,u3;template_column:c8,p1,u1;upload:c14,f4,i1,p1,t3,u3',
  'T33 schema object inventory of migration (CHECK/FK/PK/UNIQUE/index/trigger per table) is the reviewed one');

-- =====================================================================
-- T33 (ادامه): هر شیء موجودی بالا «زنده» است. هر CHECK، FK و تریگر touch اسکیما باید «زنده» باشد: برای هر CHECK یک تغییر تک‌ستونی روی ردیفی
-- موجود پیدا می‌شود که دقیقاً همان قید را می‌شکند؛ برای هر FK مقدار ناموجود در آخرین ستونش همان FK را می‌شکند (تریگرهای کاربر
-- خاموش، RI روشن؛ همه در زیرتراکنش برمی‌گردد). حذف هر قید یا تریگری این آزمون را قرمز می‌کند.
-- =====================================================================
DO $$
DECLARE c record; r record; v_con text; v_hit boolean; v_missing text[] := '{}'; v_lit text[]; v_cands text[]; v_col text; v_typ text;
        v_ctids tid[]; v_ctid tid; cand text; v_n int := 0;
BEGIN
  BEGIN
    FOR r IN SELECT c2.oid::regclass AS rel FROM pg_class c2 JOIN pg_namespace n ON n.oid = c2.relnamespace
              WHERE n.nspname = 'migration' AND c2.relkind = 'r' LOOP
      EXECUTE format('ALTER TABLE %s DISABLE TRIGGER USER', r.rel);
    END LOOP;
    FOR c IN SELECT con.oid, con.conrelid::regclass AS rel, con.conname, con.conkey, pg_get_constraintdef(con.oid) AS def
               FROM pg_constraint con JOIN pg_namespace n ON n.oid = con.connamespace
              WHERE n.nspname = 'migration' AND con.contype = 'c' ORDER BY 2, 3 LOOP
      v_n := v_n + 1;
      v_hit := false;
      v_lit := ARRAY(SELECT DISTINCT m[1] FROM regexp_matches(c.def, '''([^'']*)''', 'g') m);
      EXECUTE format('SELECT array_agg(ctid) FROM (SELECT ctid FROM %s LIMIT 25) x', c.rel) INTO v_ctids;
      <<cols>>
      FOR v_col, v_typ IN SELECT a.attname, format_type(a.atttypid, a.atttypmod) FROM unnest(c.conkey) k(attnum)
                            JOIN pg_attribute a ON a.attrelid = c.rel AND a.attnum = k.attnum WHERE a.attgenerated = '' LOOP
        v_cands := v_lit || ARRAY[NULL::text] || CASE
          WHEN v_typ IN ('text','character varying') THEN ARRAY['', 'zz invalid !', repeat('x', 600), '-1']
          WHEN v_typ = 'bytea' THEN ARRAY['\x00']
          WHEN v_typ = 'jsonb' THEN ARRAY['[]', '"x"', '{}', '1']
          WHEN v_typ = 'text[]' THEN ARRAY['{}', '{zz}']
          WHEN v_typ LIKE 'timestamp%' OR v_typ = 'date' THEN ARRAY['infinity', '-infinity']
          WHEN v_typ = 'boolean' THEN ARRAY['true', 'false']
          ELSE ARRAY['-1', '0', '1000000000', '0.5'] END;
        FOREACH v_ctid IN ARRAY coalesce(v_ctids, '{}') LOOP
          IF v_typ IN ('text','character varying') THEN
            EXECUTE format('SELECT left(%I, -1) FROM %s WHERE ctid = $1', v_col, c.rel) INTO cand USING v_ctid;
            v_cands := v_cands || ARRAY[cand || '0', cand || '1', cand || '7', cand || 'Z'];
          END IF;
          FOREACH cand IN ARRAY v_cands LOOP
            BEGIN
              EXECUTE format('UPDATE %s SET %I = $1::%s WHERE ctid = $2', c.rel, v_col, v_typ) USING cand, v_ctid;
              RAISE EXCEPTION 'MG_NO_VIOLATION';
            EXCEPTION
              WHEN check_violation THEN
                GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
                IF v_con = c.conname THEN v_hit := true; EXIT cols; END IF;
              WHEN OTHERS THEN NULL;
            END;
          END LOOP;
        END LOOP;
      END LOOP;
      IF NOT v_hit THEN v_missing := v_missing || (c.rel::text || '.' || c.conname); END IF;
    END LOOP;
    RAISE EXCEPTION 'MG_T33_DONE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'MG_T33_DONE' THEN RAISE; END IF;
  END;
  PERFORM public.mg_assert(v_n >= 200, 'T33 CHECK inventory is non-trivial');
  PERFORM public.mg_assert(cardinality(v_missing) = 0, 'T33 every CHECK rejects a single-column change of a real row; not exercised: ' || v_missing::text);
END $$;

DO $$
DECLARE c record; v_con text; v_hit boolean; v_missing text[] := '{}'; v_col text; v_typ text; v_ctid tid; v_n int := 0; v_val text;
        v_vals text[]; v_lead text; v_dlead text;
BEGIN
  BEGIN
    FOR c IN SELECT c2.oid::regclass AS rel FROM pg_class c2 JOIN pg_namespace n ON n.oid = c2.relnamespace
              WHERE n.nspname = 'migration' AND c2.relkind = 'r' LOOP
      EXECUTE format('ALTER TABLE %s DISABLE TRIGGER USER', c.rel);
    END LOOP;
    FOR c IN SELECT con.conrelid::regclass AS rel, con.confrelid::regclass AS drel, con.conname, con.conkey, con.confkey
               FROM pg_constraint con JOIN pg_namespace n ON n.oid = con.connamespace
              WHERE n.nspname = 'migration' AND con.contype = 'f'
                -- تک‌ستون tenant_id → core.tenant از FKهای ترکیبی همان ردیف (که با tenant_id شروع می‌شوند) نتیجه می‌شود
                AND NOT (array_length(con.conkey, 1) = 1 AND con.confrelid = 'core.tenant'::regclass)
                -- این‌ها را آزمون هدفمند می‌سنجد (تغییر تک‌ستون FK ضعیف‌تر هم‌ستون را زودتر می‌شکند یا CHECK جلوتر است):
                AND con.conname NOT IN ('id_map_tenant_id_company_id_first_job_id_fkey',   -- T31 the id map row company equals the job company
                                        'id_map_tenant_id_company_id_last_job_id_fkey',    -- T33 id map last job company (پایین)
                                        'posting_tenant_id_company_id_job_id_fkey',        -- T15 posting company equals the job company
                                        'upload_tenant_id_job_id_fkey',                    -- T33 upload job (پایین؛ CHECK object_key)
                                        'reconciliation_tenant_id_job_id_fkey')            -- T33 درج (پایین؛ FKهای ورودی سطرها جلوترند)
              ORDER BY 1, 3 LOOP
      v_n := v_n + 1;
      v_hit := false;
      SELECT a.attname, format_type(a.atttypid, a.atttypmod) INTO v_col, v_typ
        FROM pg_attribute a WHERE a.attrelid = c.rel AND a.attnum = c.conkey[array_length(c.conkey, 1)];
      -- نامزدها: مقدار موجود ستون مقصد با کلید پیشین دیگر (همان مستأجر، کار یا شرکت دیگر)، سپس مقدار ناموجود
      SELECT string_agg(format('%I', a.attname), ',' ORDER BY k.i), string_agg(format('d.%I', da.attname), ',' ORDER BY k.i)
        INTO v_lead, v_dlead
        FROM unnest(c.conkey[1:array_length(c.conkey, 1) - 1], c.confkey[1:array_length(c.confkey, 1) - 1]) WITH ORDINALITY k(sk, dk, i)
        JOIN pg_attribute a ON a.attrelid = c.rel AND a.attnum = k.sk
        JOIN pg_attribute da ON da.attrelid = c.drel AND da.attnum = k.dk;
      FOR v_ctid IN EXECUTE format('SELECT ctid FROM %s WHERE %s LIMIT 25', c.rel,
                                   (SELECT string_agg(format('%I IS NOT NULL', a.attname), ' AND ')
                                      FROM unnest(c.conkey) k(attnum) JOIN pg_attribute a ON a.attrelid = c.rel AND a.attnum = k.attnum)) LOOP
        v_vals := ARRAY[CASE WHEN v_typ = 'uuid' THEN uuidv7()::text WHEN v_typ IN ('integer','bigint','smallint') THEN '-987654' ELSE 'zz-none' END];
        IF v_lead IS NOT NULL THEN
          EXECUTE format('SELECT array_agg(x::text) FROM (SELECT d.%I AS x FROM %s d, %s s WHERE s.ctid = $1 AND (%s) IS DISTINCT FROM (%s) %s LIMIT 3) q',
                         (SELECT attname FROM pg_attribute WHERE attrelid = c.drel AND attnum = c.confkey[array_length(c.confkey, 1)]),
                         c.drel, c.rel, v_dlead, (SELECT string_agg('s.' || x, ',') FROM unnest(string_to_array(v_lead, ',')) x),
                         CASE WHEN EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = c.drel AND attname = 'tenant_id')
                              THEN 'AND d.tenant_id = s.tenant_id' ELSE '' END)
            INTO v_vals USING v_ctid;
          v_vals := coalesce(v_vals, '{}') || ARRAY[CASE WHEN v_typ = 'uuid' THEN uuidv7()::text WHEN v_typ IN ('integer','bigint','smallint') THEN '-987654' ELSE 'zz-none' END];
        END IF;
        FOREACH v_val IN ARRAY v_vals LOOP
          BEGIN
            EXECUTE format('UPDATE %s SET %I = $1::%s WHERE ctid = $2', c.rel, v_col, v_typ) USING v_val, v_ctid;
            RAISE EXCEPTION 'MG_NO_VIOLATION';
          EXCEPTION
            WHEN foreign_key_violation THEN
              GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
              IF v_con = c.conname THEN v_hit := true; END IF;
            WHEN OTHERS THEN NULL;
          END;
          EXIT WHEN v_hit;
        END LOOP;
        EXIT WHEN v_hit;
      END LOOP;
      IF NOT v_hit THEN v_missing := v_missing || (c.rel::text || '.' || c.conname); END IF;
    END LOOP;
    -- upload: کلید شیء شناسهٔ کار را دارد، پس کار ناموجود با کلید هم‌خوان درج می‌شود و فقط FK آن را رد می‌کند
    BEGIN
      INSERT INTO migration.upload (tenant_id, id, job_id, kind, file_name, storage_backend, bucket, object_key, encryption_key_ref, purge_after)
      VALUES ('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-00000000ffa1', '60a00000-0000-7000-8000-00000000ffa2', 'csv', 'x.csv',
              'fs', 'local', 't/60a00000-0000-7000-8000-000000000001/migration/60a00000-0000-7000-8000-00000000ffa2/60a00000-0000-7000-8000-00000000ffa1',
              'dek', now() + interval '1 day');
      v_missing := v_missing || 'migration.upload.upload_tenant_id_job_id_fkey'::text;
    EXCEPTION WHEN foreign_key_violation THEN
      GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
      IF v_con <> 'upload_tenant_id_job_id_fkey' THEN v_missing := v_missing || ('upload FK reported ' || v_con); END IF;
    END;
    BEGIN
      INSERT INTO migration.reconciliation (tenant_id, job_id, seq, as_of, status, line_count, unexplained_count, report_sha256)
      VALUES ('60a00000-0000-7000-8000-000000000001', '60a00000-0000-7000-8000-00000000ffa2', 1, '2026-09-22', 'balanced', 1, 0, sha256('x'));
      v_missing := v_missing || 'migration.reconciliation.reconciliation_tenant_id_job_id_fkey'::text;
    EXCEPTION WHEN foreign_key_violation THEN
      GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
      IF v_con <> 'reconciliation_tenant_id_job_id_fkey' THEN v_missing := v_missing || ('reconciliation FK reported ' || v_con); END IF;
    END;
    -- id_map: آخرین کار باید از همان شرکت ردیف باشد
    BEGIN
      UPDATE migration.id_map SET last_job_id = (SELECT j.id FROM migration.job j WHERE j.company_id <> id_map.company_id AND j.tenant_id = id_map.tenant_id LIMIT 1)
       WHERE company_id IS NOT NULL;
      v_missing := v_missing || 'migration.id_map.id_map_tenant_id_company_id_last_job_id_fkey'::text;
    EXCEPTION WHEN foreign_key_violation THEN
      GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
      IF v_con <> 'id_map_tenant_id_company_id_last_job_id_fkey' THEN v_missing := v_missing || ('id_map FK reported ' || v_con); END IF;
    END;
    RAISE EXCEPTION 'MG_T33_DONE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'MG_T33_DONE' THEN RAISE; END IF;
  END;
  PERFORM public.mg_assert(v_n >= 60, 'T33 FK inventory is non-trivial');
  PERFORM public.mg_assert(cardinality(v_missing) = 0, 'T33 every FK (incl. same-job composite keys) is enforced; not exercised: ' || v_missing::text);
END $$;

-- تریگر touch: هر جدول تغییرپذیر updated_at و row_version را با هر UPDATE جلو می‌برد (نگهبان‌ها در زیرتراکنش خاموش، touch روشن)
DO $$
DECLARE r record; v_ok boolean; v_missing text[] := '{}'; v_rv int; v_rv2 int; v_at timestamptz; v_n int := 0;
BEGIN
  FOR r IN SELECT tg.tgrelid::regclass AS rel FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'migration' AND tg.tgname = 'trg_touch' LOOP
    v_n := v_n + 1;
    v_ok := false;
    BEGIN
      EXECUTE format('ALTER TABLE %s DISABLE TRIGGER USER', r.rel);
      EXECUTE format('ALTER TABLE %s ENABLE TRIGGER trg_touch', r.rel);
      EXECUTE format('SELECT row_version FROM %s LIMIT 1', r.rel) INTO v_rv;
      EXECUTE format('UPDATE %s SET row_version = row_version WHERE ctid = (SELECT ctid FROM %s LIMIT 1) RETURNING row_version, updated_at', r.rel, r.rel)
        INTO v_rv2, v_at;
      v_ok := v_rv2 = v_rv + 1 AND v_at = now();
      RAISE EXCEPTION 'MG_UNDO';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM <> 'MG_UNDO' THEN v_ok := false; END IF;
    END;
    IF NOT v_ok THEN v_missing := v_missing || r.rel::text; END IF;
  END LOOP;
  PERFORM public.mg_assert(cardinality(v_missing) = 0 AND v_n = 11 AND (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                             JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'row_version' WHERE n.nspname = 'migration' AND c.relkind = 'r') = v_n,
                           'T33 every table with row_version is touched on update; not exercised: ' || v_missing::text);
END $$;

-- فقط‌افزودنی‌ها حتی برای مالک، و یکتایی‌هایی که تریگر جلوترشان می‌ایستد (با تریگرهای کاربر خاموش)
DO $$
DECLARE t uuid := '60a00000-0000-7000-8000-000000000001';
BEGIN
  PERFORM public.mg_expect_error('T33 trigger: job events append-only', $q$UPDATE migration.job_event SET note = note$q$, 'HK_IMMUTABLE');
  PERFORM public.mg_expect_error('T33 trigger: reconciliations append-only', $q$UPDATE migration.reconciliation SET as_of = as_of$q$, 'HK_IMMUTABLE');
  PERFORM public.mg_expect_error('T33 trigger: source figures append-only', $q$DELETE FROM migration.source_balance$q$, 'HK_IMMUTABLE');
  PERFORM public.mg_expect_error('T33 trigger: archive append-only', $q$UPDATE migration.archive_entry SET doc_no = doc_no$q$, 'HK_IMMUTABLE');
  BEGIN
    ALTER TABLE migration.dry_run DISABLE TRIGGER USER;
    ALTER TABLE migration.reconciliation DISABLE TRIGGER USER;
    ALTER TABLE migration.commit_chunk DISABLE TRIGGER USER;
    ALTER TABLE migration.reconciliation_line DISABLE TRIGGER USER;
    PERFORM public.mg_expect_error('T33 dry-run sequence unique even under a race',
      $q$INSERT INTO migration.dry_run (tenant_id, job_id, seq, run_mode, inputs_hash, started_at, outcome, report, report_sha256, error_code)
         SELECT tenant_id, job_id, seq, run_mode, inputs_hash, started_at, outcome, report, report_sha256, error_code FROM migration.dry_run LIMIT 1$q$, '23505');
    PERFORM public.mg_expect_error('T33 reconciliation sequence unique even under a race',
      $q$INSERT INTO migration.reconciliation (tenant_id, job_id, seq, as_of, status, line_count, unexplained_count, report_sha256)
         SELECT tenant_id, job_id, seq, as_of, status, line_count, unexplained_count, report_sha256 FROM migration.reconciliation LIMIT 1$q$, '23505');
    PERFORM public.mg_expect_error('T33 one chunk per number',
      $q$INSERT INTO migration.commit_chunk (tenant_id, job_id, chunk_no, stage, item_count)
         SELECT tenant_id, job_id, chunk_no, stage, item_count FROM migration.commit_chunk LIMIT 1$q$, '23505');
    PERFORM public.mg_expect_error('T33 one line per check and key',
      $q$INSERT INTO migration.reconciliation_line (tenant_id, job_id, reconciliation_id, line_no, check_kind, key, source_value, target_value)
         SELECT tenant_id, job_id, reconciliation_id, 999, check_kind, key, source_value, target_value FROM migration.reconciliation_line LIMIT 1$q$, '23505');
    RAISE EXCEPTION 'MG_T33_DONE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'MG_T33_DONE' THEN RAISE; END IF;
  END;
  PERFORM public.mg_expect_error('T33 one template column per ordinal',
    $q$INSERT INTO migration.template_column (template_version, sheet_code, sheet_entity, column_key, ordinal, is_required, data_type, title_key)
       VALUES (1, 'T00', 'file_settings', 'zz_extra', 1, false, 'text', 'x')$q$, '23505');
END $$;

\echo 'ALL 60_migration TESTS PASSED'
