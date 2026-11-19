-- =====================================================================
-- آزمون پایگاه داده‌ای 10_core.sql (سند: docs/design/02-core-platform.md §۷ و §۹)
--
-- اجرا (از ریشهٔ مخزن؛ پایگاه دادهٔ تازه با UTF8):
--   export PGPASSWORD=postgres
--   psql -h localhost -p 5433 -U postgres -d postgres -c "DROP DATABASE IF EXISTS ds_core"
--   psql -h localhost -p 5433 -U postgres -d postgres -c "CREATE DATABASE ds_core ENCODING 'UTF8' TEMPLATE template0 LC_COLLATE 'C' LC_CTYPE 'C.UTF-8'"
--   psql -h localhost -p 5433 -U postgres -d ds_core -v ON_ERROR_STOP=1 -f docs/design/sql/00_foundation.sql
--   psql -h localhost -p 5433 -U postgres -d ds_core -v ON_ERROR_STOP=1 -f docs/design/sql/10_core.sql
--   psql -h localhost -p 5433 -U postgres -d ds_core -v ON_ERROR_STOP=1 -f docs/design/sql/tests/10_core_test.sql
--
-- ساختار فایل (یک نشست psql که با superuser وصل می‌شود):
--   بخش ۱ (fixture)  — با نقش postgres: مستأجر A و B، شرکت، شعبه، کاربر، عضویت، نقش، دستگاه، سری شماره،
--                      جدول آزمایشی public.cf_demo برای فیلد سفارشی، و توابع کمکی expect_error/assert_true.
--   بخش ۲ (assert)   — پس از «SET ROLE hk_app» (نقش برنامه: نه مالک، NOBYPASSRLS). همهٔ ناوردایی‌ها
--                      با DO block و set_config('app.tenant_id'|'app.user_id', ..., true) آزموده می‌شوند.
--                      بخش‌های صف/رله‌گر/زمان‌بند با «SET LOCAL ROLE hk_dispatcher» درون همان DO اجرا می‌شوند
--                      و T19 با «SET ROLE hk_readonly» است.
--   بخش ۳ (tamper)   — با نقش postgres: دست‌کاری مستقیم ردیف ممیزی (با غیرفعال کردن تریگر) و سپس
--                      راستی‌آزمایی با hk_app؛ همه در یک تراکنش ROLLBACK‌شده.
-- مسیر بردارهای نرمال‌سازی را می‌توان با -v fa_vectors_file=<path> تغییر داد.
-- خروجی موفق با «ALL 10_core TESTS PASSED» پایان می‌یابد؛ هر شکست «TEST FAILED: ...» می‌دهد و psql با کد ≠ ۰ خارج می‌شود.
-- =====================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
\if :{?fa_vectors_file}
\else
  \set fa_vectors_file docs/design/sql/tests/fa_text_norm_v1.json
\endif
\set fa_vectors `cat :fa_vectors_file`

-- شناسه‌های ثابت
\set A    '0a000000-0000-7000-8000-000000000001'
\set B    '0b000000-0000-7000-8000-000000000001'
\set CA   '0a000000-0000-7000-8000-0000000000c1'
\set BA   '0a000000-0000-7000-8000-0000000000b1'
\set CB   '0b000000-0000-7000-8000-0000000000c1'
\set BB   '0b000000-0000-7000-8000-0000000000b1'
\set UA1  '0a000000-0000-7000-8000-00000000a001'
\set UA2  '0a000000-0000-7000-8000-00000000a002'
\set UA3  '0a000000-0000-7000-8000-00000000a003'
\set UB1  '0b000000-0000-7000-8000-00000000b001'
\set UC1  '0c000000-0000-7000-8000-00000000c001'

-- =====================================================================
-- بخش ۱: fixture (postgres)
-- =====================================================================
RESET ROLE;
BEGIN;
INSERT INTO core.tenant (id, slug, display_name) VALUES (:'A', 'tenant-a', 'A'), (:'B', 'tenant-b', 'B');
INSERT INTO core.company (tenant_id, id, code, name) VALUES (:'A', :'CA', 'C1', 'شرکت الف'), (:'B', :'CB', 'C1', 'شرکت ب');
INSERT INTO core.branch (tenant_id, id, company_id, code, name) VALUES (:'A', :'BA', :'CA', 'BR1', 'شعبه ۱'), (:'B', :'BB', :'CB', 'BR1', 'شعبه ۱');
INSERT INTO core.app_user (id, display_name) VALUES
  (:'UA1', 'مالک الف'), (:'UA2', 'کارمند الف'), (:'UA3', 'تأییدکننده الف'), (:'UB1', 'مالک ب'), (:'UC1', 'حسابدار مشترک');
INSERT INTO core.user_login_identifier (user_id, kind, value, verified_at) VALUES
  (:'UA1', 'phone', '09120000001', now()), (:'UC1', 'phone', '09120000009', now());
INSERT INTO core.tenant_membership (tenant_id, id, user_id, status, is_owner, joined_at) VALUES
  (:'A', '0a000000-0000-7000-8000-0000000e0001', :'UA1', 'active', true,  now()),
  (:'A', '0a000000-0000-7000-8000-0000000e0002', :'UA2', 'active', false, now()),
  (:'A', '0a000000-0000-7000-8000-0000000e0003', :'UA3', 'active', false, now()),
  (:'A', '0a000000-0000-7000-8000-0000000e0004', :'UC1', 'active', false, now()),
  (:'B', '0b000000-0000-7000-8000-0000000e0001', :'UB1', 'active', true,  now()),
  (:'B', '0b000000-0000-7000-8000-0000000e0004', :'UC1', 'active', false, now());
SELECT set_config('app.system_role_sync', 'on', true) \gset
INSERT INTO core.role (tenant_id, id, code, name, template_code, is_system, grants_all) VALUES
  (:'A', '0a000000-0000-7000-8000-0000000f0001', 'owner',    'مالک',        'owner', true,  true),
  (:'A', '0a000000-0000-7000-8000-0000000f0002', 'approver', 'تأییدکننده',  NULL,    false, false),
  (:'A', '0a000000-0000-7000-8000-0000000f0003', 'clerk',    'کارمند',      NULL,    false, false),
  (:'B', '0b000000-0000-7000-8000-0000000f0001', 'owner',    'مالک',        'owner', true,  true);
INSERT INTO core.role_permission (tenant_id, role_id, permission_code) VALUES
  (:'A', '0a000000-0000-7000-8000-0000000f0002', 'core.approval.request.decide');
INSERT INTO core.role_assignment (tenant_id, membership_id, role_id) VALUES
  (:'A', '0a000000-0000-7000-8000-0000000e0001', '0a000000-0000-7000-8000-0000000f0001'),
  (:'A', '0a000000-0000-7000-8000-0000000e0003', '0a000000-0000-7000-8000-0000000f0002'),
  (:'A', '0a000000-0000-7000-8000-0000000e0002', '0a000000-0000-7000-8000-0000000f0003'),
  (:'B', '0b000000-0000-7000-8000-0000000e0001', '0b000000-0000-7000-8000-0000000f0001');
INSERT INTO core.device (tenant_id, id, company_id, branch_id, kind, name, status, enrollment_code_hash, enrollment_expires_at, registered_by) VALUES
  (:'A', '0a000000-0000-7000-8000-0000000d0001', :'CA', :'BA', 'pos', 'صندوق ۱', 'pending', sha256('code1'), now() + interval '1 hour', :'UA1'),
  (:'A', '0a000000-0000-7000-8000-0000000d0002', :'CA', :'BA', 'pos', 'صندوق ۲', 'pending', sha256('code2'), now() - interval '1 minute', :'UA1'),
  (:'B', '0b000000-0000-7000-8000-0000000d0001', :'CB', :'BB', 'pos', 'صندوق ۱', 'pending', sha256('code3'), now() + interval '1 hour', :'UB1');
UPDATE core.device SET status = 'active', public_key = sha256('pk1'), activated_at = now() WHERE id = '0a000000-0000-7000-8000-0000000d0001';
INSERT INTO core.number_series (tenant_id, id, company_id, code, name, doc_type, scope, branch_id, device_id, allocation, pattern, reset_policy) VALUES
  (:'A', '0a000000-0000-7000-8000-000000050001', :'CA', 'jv',   'سند حسابداری', 'ledger.journal', 'company', NULL, NULL, 'server', 'JV-{jy}-{seq:6}', 'jalali_year'),
  (:'A', '0a000000-0000-7000-8000-000000050002', :'CA', 'rc',   'رسید شعبه',    'pos.receipt',    'branch',  :'BA', NULL, 'reserved_ranges', '{branch}-{seq:5}', 'never'),
  (:'A', '0a000000-0000-7000-8000-000000050003', :'CA', 'dev1', 'سری دستگاه',   'pos.sale',       'device',  :'BA', '0a000000-0000-7000-8000-0000000d0001', 'device', '{device}-{jy}-{seq}', 'jalali_year'),
  (:'B', '0b000000-0000-7000-8000-000000050001', :'CB', 'jv',   'سند حسابداری', 'ledger.journal', 'company', NULL, NULL, 'server', 'JV-{jy}-{seq:6}', 'jalali_year');

-- جدول آزمایشی مالک فیلد سفارشی
CREATE TABLE public.cf_demo (
  tenant_id uuid NOT NULL REFERENCES core.tenant(id),
  id        uuid PRIMARY KEY DEFAULT uuidv7(),
  name      text,
  custom    jsonb NOT NULL DEFAULT '{}',
  UNIQUE (tenant_id, id)
);
SELECT core.enable_tenant_rls('public.cf_demo') \gset
GRANT SELECT, INSERT, UPDATE, DELETE ON public.cf_demo TO hk_app;
INSERT INTO core.custom_field_entity (entity_type, module, table_name, description_key) VALUES ('test.cf_demo', 'test', 'public.cf_demo', 'cf.test');
SELECT core.attach_custom_fields('public.cf_demo', 'test.cf_demo') \gset

INSERT INTO core.event_subscriber (subscriber, ordered, max_attempts, introduced_in) VALUES
  ('test.ordered', true, 3, 'test'), ('test.wild', false, 3, 'test');
INSERT INTO core.event_subscription (event_type, subscriber) VALUES
  ('test.thing.created', 'test.ordered'), ('test.thing.*', 'test.wild');

-- مدل چاپ آزمایشی (هر ماژول مدل خودش را منتشر می‌کند؛ RV-X3-05)
INSERT INTO core.print_model (code, module, schema_version, json_schema, allowed_papers, read_permission, description_key) VALUES
  ('test.doc', 'test', 1, '{"type":"object"}', '{a4,a5}', 'core.attachment.read', 'print.test.doc');
INSERT INTO core.print_template_def (code, model_code, paper, body, is_official, rules_param_key, introduced_in) VALUES
  ('test.doc.basic',    'test.doc', 'a5', '<p>{{ total }}</p>', false, NULL, 'test'),
  ('test.doc.official', 'test.doc', 'a4', '<p>{{ taxid }}</p>', true, 'tax.einvoice.layout_version', 'test');

-- جدول ثبت قطعی آزمایشی با نگهبان دستیار (C-AS-02؛ RV-AST-19)
CREATE TABLE public.post_demo (
  tenant_id uuid NOT NULL REFERENCES core.tenant(id),
  id        uuid PRIMARY KEY DEFAULT uuidv7(),
  note      text,
  UNIQUE (tenant_id, id)
);
CREATE TRIGGER trg_freeze BEFORE UPDATE ON public.post_demo FOR EACH ROW EXECUTE FUNCTION core.freeze_columns('note');
SELECT core.enable_tenant_rls('public.post_demo') \gset
GRANT SELECT, INSERT, UPDATE ON public.post_demo TO hk_app;
SELECT core.attach_actor_via_guard('public.post_demo') \gset

-- ردیف استقرار (ساعت سرور On-prem/لبه؛ RV-ARCH-17)
INSERT INTO core.deployment_info (profile, app_version, schema_head, max_seen_at)
VALUES ('onprem', '2026.11.0', 'test', now()) ON CONFLICT DO NOTHING;

-- دو نشست واقعی برای آزمون ترتیب outbox (RV-CORE-08)
CREATE EXTENSION IF NOT EXISTS dblink;

-- کمکی‌ها (SECURITY INVOKER: با نقش فراخوان اجرا می‌شوند)
CREATE FUNCTION public.expect_error(p_label text, p_sql text, p_expect text) RETURNS void
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
CREATE FUNCTION public.assert_true(p_cond boolean, p_label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond IS NOT TRUE THEN RAISE EXCEPTION 'TEST FAILED [%]', p_label; END IF;
END $$;
GRANT EXECUTE ON FUNCTION public.expect_error(text, text, text), public.assert_true(boolean, text) TO hk_app, hk_readonly;
COMMIT;

-- =====================================================================
-- بخش ۲: ادعاها با نقش برنامه
-- =====================================================================
SET ROLE hk_app;
SELECT public.assert_true(current_user = 'hk_app', 'running as hk_app') \gset

-- INV-TEN-01/02/03, INV-AUD-..., INV-TEN-06: بازرسی ساختاری (RLS/FORCE/policy، UNIQUE(tenant_id,id)، FK ترکیبی،
-- security_invoker، SECURITY DEFINER بازبینی‌شده، grant جدول‌های فقط‌افزودنی، رجیستری صدور)
SELECT public.assert_true((SELECT count(*) FROM core.security_lint()) = 0, 'security_lint is empty') \gset

-- ---------- T01: بدون زمینهٔ مستأجر هیچ‌چیز دیده/نوشته نمی‌شود (fail-closed) ----------
DO $$
BEGIN
  PERFORM public.assert_true((SELECT count(*) FROM core.tenant_membership) = 0, 'T01 no context: membership invisible');
  PERFORM public.assert_true((SELECT count(*) FROM core.role) = 0, 'T01 no context: role invisible');
  PERFORM public.assert_true((SELECT count(*) FROM core.app_user) = 0, 'T01 no context: app_user invisible');
  PERFORM public.expect_error('T01 insert without tenant',
    $q$INSERT INTO core.role (tenant_id, code, name) VALUES ('0a000000-0000-7000-8000-000000000001', 'x', 'x')$q$, '42501');
END $$;

-- ---------- T02: جداسازی نوشتن بین مستأجرها ----------
DO $$
DECLARE n int;
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  UPDATE core.role SET name = 'هک' WHERE tenant_id = '0b000000-0000-7000-8000-000000000001';
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM public.assert_true(n = 0, 'T02 update of foreign tenant rows affects 0 rows');
  PERFORM public.expect_error('T02 insert row for other tenant',
    $q$INSERT INTO core.role (tenant_id, code, name) VALUES ('0b000000-0000-7000-8000-000000000001', 'x', 'x')$q$, '42501');
  -- INV-TEN-03: FK ترکیبی؛ ارجاع به عضویت مستأجر B ناممکن است
  PERFORM public.expect_error('T02 composite FK across tenants',
    $q$INSERT INTO core.role_assignment (tenant_id, membership_id, role_id)
       VALUES ('0a000000-0000-7000-8000-000000000001', '0b000000-0000-7000-8000-0000000e0001', '0a000000-0000-7000-8000-0000000f0003')$q$, '23503');
END $$;

-- ---------- T03: سیاست‌های سطح کاربر (هویت سراسری قلمرو) ----------
DO $$
BEGIN
  -- حسابدار مشترک بدون مستأجر: عضویت‌ها و مستأجرهای خودش را می‌بیند
  PERFORM set_config('app.user_id', '0c000000-0000-7000-8000-00000000c001', true);
  PERFORM public.assert_true((SELECT count(*) FROM core.tenant_membership) = 2, 'T03 accountant sees own 2 memberships');
  PERFORM public.assert_true((SELECT count(*) FROM core.tenant) = 2, 'T03 accountant sees 2 tenants');
  PERFORM public.assert_true((SELECT count(*) FROM core.app_user) = 1, 'T03 user sees only self without tenant');
  INSERT INTO core.user_credential (user_id, password_hash, password_changed_at)
  VALUES ('0c000000-0000-7000-8000-00000000c001', '$argon2id$v=19$m=65536,t=3,p=1$c2FsdA$aGFzaA', now());
  PERFORM public.expect_error('T03 credential for another user',
    $q$INSERT INTO core.user_credential (user_id) VALUES ('0a000000-0000-7000-8000-00000000a001')$q$, '42501');
  PERFORM public.expect_error('T03 non-argon2id hash',
    $q$UPDATE core.user_credential SET password_hash = 'md5abc' WHERE user_id = '0c000000-0000-7000-8000-00000000c001'$q$, '23514');
END $$;
DO $$
BEGIN
  PERFORM set_config('app.user_id', '0a000000-0000-7000-8000-00000000a002', true);
  PERFORM public.assert_true((SELECT count(*) FROM core.tenant) = 1, 'T03 clerk sees 1 tenant');
  PERFORM public.assert_true((SELECT count(*) FROM core.user_credential) = 0, 'T03 clerk cannot see others credentials');
  PERFORM set_config('app.user_id', '', true);
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  PERFORM public.assert_true((SELECT count(*) FROM core.app_user) = 4, 'T03 tenant A sees its 4 members');
  PERFORM public.assert_true((SELECT count(*) FROM core.user_login_identifier) = 2, 'T03 tenant A sees members identifiers');
  PERFORM set_config('app.tenant_id', '0b000000-0000-7000-8000-000000000001', true);
  PERFORM public.assert_true((SELECT count(*) FROM core.app_user) = 2, 'T03 tenant B sees its 2 members');
  -- INV-TXT-03: نام نمایشی باید نرمال باشد (مسیر خودثبت‌نامی: id = app.user_id)
  PERFORM set_config('app.tenant_id', '', true);
  PERFORM set_config('app.user_id', '0d000000-0000-7000-8000-00000000d001', true);
  PERFORM public.expect_error('T03 unnormalized display name',
    $q$INSERT INTO core.app_user (id, display_name) VALUES ('0d000000-0000-7000-8000-00000000d001', 'علي')$q$, '23514');
END $$;

-- ---------- T04: عضویت — ماشین حالت و حداقل یک مالک فعال ----------
DO $$
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  PERFORM set_config('app.user_id', '0a000000-0000-7000-8000-00000000a001', true);   -- مالک فعال (انتقال مالکیت)
  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM public.expect_error('T04 last owner cannot be demoted',
    $q$UPDATE core.tenant_membership SET is_owner = false WHERE id = '0a000000-0000-7000-8000-0000000e0001'$q$, 'HK_CORE_LAST_OWNER');
  PERFORM public.expect_error('T04 owner cannot be suspended (check)',
    $q$UPDATE core.tenant_membership SET status = 'suspended' WHERE id = '0a000000-0000-7000-8000-0000000e0001'$q$, '23514');
  PERFORM public.expect_error('T04 invalid transition active->invited',
    $q$UPDATE core.tenant_membership SET status = 'invited' WHERE id = '0a000000-0000-7000-8000-0000000e0002'$q$, 'HK_CORE_INVALID_TRANSITION');
  -- انتقال مالکیت در یک تراکنش مجاز است (سپس برگردانده می‌شود)
  BEGIN
    UPDATE core.tenant_membership SET is_owner = true  WHERE id = '0a000000-0000-7000-8000-0000000e0003';
    UPDATE core.tenant_membership SET is_owner = false WHERE id = '0a000000-0000-7000-8000-0000000e0001';
    RAISE EXCEPTION USING ERRCODE = 'HKR01';
  EXCEPTION WHEN SQLSTATE 'HKR01' THEN NULL;
  END;
END $$;

-- ---------- T05: ممیزی — زنجیره، seq بی‌فاصله، فقط‌افزودنی ----------
DO $$
DECLARE r1 core.audit_log; r2 core.audit_log; r3 core.audit_log; n int;
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  PERFORM set_config('app.user_id', '0a000000-0000-7000-8000-00000000a001', true);
  -- برنامه نمی‌تواند seq/hash را جعل کند: تریگر بازنویسی می‌کند
  INSERT INTO core.audit_log (tenant_id, actor_kind, actor_user_id, action, resource_type, resource_id, details,
                              seq, prev_hash, row_hash, details_sha256, recorded_at, ip)
  VALUES ('0a000000-0000-7000-8000-000000000001', 'user', '0a000000-0000-7000-8000-00000000a001', 'core.role.create', 'core.role',
          '0a000000-0000-7000-8000-0000000f0003', '{"name":"clerk"}', 999, '\x00', '\x00', '\x00', now() - interval '1 year', '10.1.2.3'),
         ('0a000000-0000-7000-8000-000000000001', 'user', '0a000000-0000-7000-8000-00000000a001', 'core.member.invite', 'core.member',
          '0a000000-0000-7000-8000-0000000e0002', '{"phone":"0912***0002"}', 5, '\x00', '\x00', '\x00', now(), NULL),
         ('0a000000-0000-7000-8000-000000000001', 'system', NULL, 'core.audit.selftest', NULL, NULL, '{}', 7, '\x00', '\x00', '\x00', now(), NULL);
  SELECT * INTO r1 FROM core.audit_log WHERE seq = 1;
  SELECT * INTO r2 FROM core.audit_log WHERE seq = 2;
  SELECT * INTO r3 FROM core.audit_log WHERE seq = 3;
  PERFORM public.assert_true((SELECT array_agg(seq ORDER BY seq) FROM core.audit_log) = ARRAY[1,2,3]::bigint[], 'T05 seq is 1..3');
  PERFORM public.assert_true(r1.prev_hash = core.audit_genesis_hash('0a000000-0000-7000-8000-000000000001', 0::smallint), 'T05 genesis');
  PERFORM public.assert_true(r2.prev_hash = r1.row_hash AND r3.prev_hash = r2.row_hash, 'T05 chained');
  PERFORM public.assert_true(r1.row_hash = sha256(r1.prev_hash || convert_to(core.audit_canonical(r1), 'UTF8')), 'T05 row hash recomputes');
  PERFORM public.assert_true((SELECT last_seq FROM core.audit_chain_head) = 3, 'T05 head advanced');
  SELECT count(*) INTO n FROM core.audit_verify();
  PERFORM public.assert_true(n = 0, 'T05 verify clean');
  PERFORM public.expect_error('T05 update audit', $q$UPDATE core.audit_log SET reason = 'x'$q$, '42501');
  PERFORM public.expect_error('T05 delete audit', $q$DELETE FROM core.audit_log$q$, '42501');
  PERFORM public.expect_error('T05 update chain head', $q$UPDATE core.audit_chain_head SET last_seq = 0$q$, '42501');
  PERFORM public.expect_error('T05 audit row for another tenant',
    $q$INSERT INTO core.audit_log (tenant_id, actor_kind, action) VALUES ('0b000000-0000-7000-8000-000000000001', 'system', 'core.audit.selftest')$q$, '42501');
  PERFORM public.expect_error('T05 details must be a JSON object',
    $q$INSERT INTO core.audit_log (tenant_id, actor_kind, action, details) VALUES ('0a000000-0000-7000-8000-000000000001', 'system', 'core.audit.selftest', '[1]')$q$, '23514');
  PERFORM public.expect_error('T05 impersonation fields come together',
    $q$INSERT INTO core.audit_log (tenant_id, actor_kind, action, act_staff_id) VALUES ('0a000000-0000-7000-8000-000000000001', 'system', 'core.audit.selftest', gen_random_uuid())$q$, '23514');
  -- مستأجر B زنجیرهٔ مستقل از ۱ دارد
  PERFORM set_config('app.tenant_id', '0b000000-0000-7000-8000-000000000001', true);
  INSERT INTO core.audit_log (tenant_id, actor_kind, action) VALUES ('0b000000-0000-7000-8000-000000000001', 'system', 'core.audit.selftest');
  PERFORM public.assert_true((SELECT max(seq) FROM core.audit_log) = 1, 'T05 tenant B chain starts at 1');
END $$;

-- ---------- T06: شماره‌گذاری بی‌فاصله ----------
DO $$
DECLARE r record; v bigint[] := '{}'; d uuid := gen_random_uuid();
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  FOR i IN 1..3 LOOP
    SELECT * INTO r FROM core.number_next('0a000000-0000-7000-8000-000000050001', 'jy:1405', 'JV-1405-{seq:6}', 'ledger.journal', gen_random_uuid());
    v := v || r.value;
  END LOOP;
  PERFORM public.assert_true(v = ARRAY[1,2,3]::bigint[], 'T06 sequential 1..3');
  PERFORM public.assert_true(r.formatted = 'JV-1405-000003', 'T06 formatted with padding');
  -- rollback شمارهٔ گرفته‌شده فاصله نمی‌سازد
  BEGIN
    PERFORM core.number_next('0a000000-0000-7000-8000-000000050001', 'jy:1405', 'JV-1405-{seq:6}', 'ledger.journal', gen_random_uuid());
    RAISE EXCEPTION USING ERRCODE = 'HKR01';
  EXCEPTION WHEN SQLSTATE 'HKR01' THEN NULL;
  END;
  SELECT * INTO r FROM core.number_next('0a000000-0000-7000-8000-000000050001', 'jy:1405', 'JV-1405-{seq:6}', 'ledger.journal', d);
  PERFORM public.assert_true(r.value = 4, 'T06 rollback leaves no gap');
  PERFORM public.assert_true(NOT EXISTS (SELECT 1 FROM core.number_gaps('0a000000-0000-7000-8000-000000050001', 'jy:1405')), 'T06 no gaps');
  SELECT * INTO r FROM core.number_next('0a000000-0000-7000-8000-000000050001', 'jy:1406', 'JV-1406-{seq:6}', 'ledger.journal', gen_random_uuid());
  PERFORM public.assert_true(r.value = 1, 'T06 new period restarts at start_value');
  PERFORM public.assert_true(core.number_render('X{seq:2}', 12345) = 'X12345', 'T06 padding never truncates');
  PERFORM public.expect_error('T06 same document numbered twice',
    format($q$SELECT core.number_next('0a000000-0000-7000-8000-000000050001', 'jy:1405', 'JV-1405-{seq:6}', 'ledger.journal', %L)$q$, d), '23505');
  PERFORM public.expect_error('T06 period does not match reset policy',
    $q$SELECT core.number_next('0a000000-0000-7000-8000-000000050001', 'all', 'JV-{seq}', 'ledger.journal', gen_random_uuid())$q$, 'HK_NUM_BAD_PERIOD');
  PERFORM public.expect_error('T06 unrendered token in template',
    $q$SELECT core.number_next('0a000000-0000-7000-8000-000000050001', 'jy:1405', 'JV-{jy}-{seq}', 'ledger.journal', gen_random_uuid())$q$, 'HK_NUM_BAD_TEMPLATE');
  PERFORM public.expect_error('T06 doc type mismatch',
    $q$SELECT core.number_next('0a000000-0000-7000-8000-000000050001', 'jy:1405', 'JV-{seq}', 'sales.invoice', gen_random_uuid())$q$, 'HK_NUM_DOC_TYPE');
  PERFORM public.expect_error('T06 range series is not server-allocated',
    $q$SELECT core.number_next('0a000000-0000-7000-8000-000000050002', 'all', 'R-{seq}', 'pos.receipt', gen_random_uuid())$q$, 'HK_NUM_NOT_SERVER_ALLOCATED');
  -- RV-CORE-05: hk_app هیچ نوشتن مستقیمی در شمارنده/دفتر شماره ندارد (فقط توابع definer)
  PERFORM public.expect_error('T06 app cannot insert issued numbers directly',
    $q$INSERT INTO core.number_issued (tenant_id, series_id, period_key, value, formatted, status, doc_type, doc_id)
       VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-000000050001', 'jy:1405', 2, 'JV-2', 'used', 'ledger.journal', gen_random_uuid())$q$, '42501');
  PERFORM public.expect_error('T06 app cannot advance a counter (gap)',
    $q$UPDATE core.number_counter SET next_value = next_value + 3 WHERE period_key = 'jy:1405'$q$, '42501');
  PERFORM public.expect_error('T06 app cannot write reservations directly',
    $q$INSERT INTO core.number_reservation (tenant_id, series_id, period_key, device_id, range_start, range_end)
       VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-000000050002', 'all', '0a000000-0000-7000-8000-0000000d0001', 500, 510)$q$, '42501');
  -- لایهٔ دوم (تریگرها) با نقشی که امتیاز نوشتن دارد (مالک توابع definer)
  SET LOCAL ROLE hk_core_definer;
  PERFORM public.expect_error('T06 direct insert beyond counter',
    $q$INSERT INTO core.number_issued (tenant_id, series_id, period_key, value, formatted, status, doc_type, doc_id)
       VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-000000050001', 'jy:1405', 99, 'JV-99', 'used', 'ledger.journal', gen_random_uuid())$q$, 'HK_NUM_OUT_OF_RANGE');
  PERFORM public.expect_error('T06 server series never holds a voided number (trigger)',
    $q$INSERT INTO core.number_issued (tenant_id, series_id, period_key, value, formatted, status, void_reason)
       VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-000000050001', 'jy:1406', 1, '#void:1', 'voided', 'gap filler')$q$, 'HK_NUM_SERVER_ALLOCATED');
  PERFORM public.expect_error('T06 counter cannot go back',
    $q$UPDATE core.number_counter SET next_value = 1 WHERE period_key = 'jy:1405'$q$, 'HK_NUM_COUNTER');
  SET LOCAL ROLE hk_app;
  PERFORM public.expect_error('T06 issued numbers immutable', $q$UPDATE core.number_issued SET formatted = 'x'$q$, '42501');
  PERFORM public.expect_error('T06 counter cannot be deleted', $q$DELETE FROM core.number_counter$q$, '42501');
  PERFORM public.expect_error('T06 pattern must have one seq and known tokens',
    $q$INSERT INTO core.number_series (tenant_id, company_id, code, name, doc_type, scope, pattern, reset_policy)
       VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000000c1', 'bad', 'bad', 'sales.invoice', 'company', 'INV-{foo}-{seq}', 'never')$q$, '23514');
  PERFORM public.expect_error('T06 structural change of used series',
    $q$UPDATE core.number_series SET reset_policy = 'never' WHERE id = '0a000000-0000-7000-8000-000000050001'$q$, 'HK_NUM_SERIES_IN_USE');
END $$;

-- رزرو بازه و سری دستگاه
DO $$
DECLARE r1 core.number_reservation; r2 core.number_reservation; n int;
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  r1 := core.number_reserve_range('0a000000-0000-7000-8000-000000050002', 'all', '0a000000-0000-7000-8000-0000000d0001', 10);
  r2 := core.number_reserve_range('0a000000-0000-7000-8000-000000050002', 'all', '0a000000-0000-7000-8000-0000000d0001', 5);
  PERFORM public.assert_true(r1.range_start = 1 AND r1.range_end = 10 AND r2.range_start = 11 AND r2.range_end = 15, 'T06 ranges are consecutive');
  SET LOCAL ROLE hk_core_definer;
  PERFORM public.expect_error('T06 overlapping reservation',
    format($q$INSERT INTO core.number_reservation (tenant_id, series_id, period_key, device_id, range_start, range_end)
              VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-000000050002', 'all', '0a000000-0000-7000-8000-0000000d0001', 5, 12)$q$), '23P01');
  SET LOCAL ROLE hk_app;
  PERFORM core.number_record_external('0a000000-0000-7000-8000-000000050002', 'all', 3, 'BR1-00003', 'pos.receipt', gen_random_uuid(),
                                      '0a000000-0000-7000-8000-0000000d0001', r1.id);
  PERFORM public.expect_error('T06 value outside reservation',
    format($q$SELECT core.number_record_external('0a000000-0000-7000-8000-000000050002', 'all', 12, 'BR1-00012', 'pos.receipt', gen_random_uuid(), '0a000000-0000-7000-8000-0000000d0001', %L)$q$, r1.id),
    'HK_NUM_NOT_IN_RESERVATION');
  PERFORM public.expect_error('T06 duplicate device number',
    format($q$SELECT core.number_record_external('0a000000-0000-7000-8000-000000050002', 'all', 3, 'BR1-00003b', 'pos.receipt', gen_random_uuid(), '0a000000-0000-7000-8000-0000000d0001', %L)$q$, r1.id),
    '23505');
  n := core.number_close_reservation(r1.id, 'shift closed');
  PERFORM public.assert_true(n = 9, 'T06 closing reservation voids 9 unused numbers');
  PERFORM public.assert_true(NOT EXISTS (SELECT 1 FROM core.number_gaps('0a000000-0000-7000-8000-000000050002', 'all')), 'T06 ranges fully accounted');
  -- سری دستگاه: شماره‌ها خارج از ترتیب می‌رسند؛ کسری قابل تشخیص و ابطال است
  PERFORM core.number_record_external('0a000000-0000-7000-8000-000000050003', 'jy:1405', v, 'D1-1405-' || v, 'pos.sale', gen_random_uuid(),
                                      '0a000000-0000-7000-8000-0000000d0001') FROM unnest(ARRAY[1,2,4]) v;
  PERFORM public.assert_true((SELECT array_agg(g) FROM core.number_gaps('0a000000-0000-7000-8000-000000050003', 'jy:1405') g) = ARRAY[3]::bigint[],
                             'T06 device gap detected');
  PERFORM core.number_void('0a000000-0000-7000-8000-000000050003', 'jy:1405', 3, 'device lost before sync');
  PERFORM public.assert_true(NOT EXISTS (SELECT 1 FROM core.number_gaps('0a000000-0000-7000-8000-000000050003', 'jy:1405')), 'T06 voided gap accounted');
  PERFORM public.expect_error('T06 server series never voided',
    $q$SELECT core.number_void('0a000000-0000-7000-8000-000000050001', 'jy:1405', 2, 'not allowed here')$q$, 'HK_NUM_SERVER_ALLOCATED');
  PERFORM public.expect_error('T06 device series bound to its device',
    $q$SELECT core.number_record_external('0a000000-0000-7000-8000-000000050003', 'jy:1405', 9, 'X', 'pos.sale', gen_random_uuid(), '0a000000-0000-7000-8000-0000000d0002')$q$, 'HK_NUM_DEVICE');
END $$;

-- ---------- T07: تنظیمات ----------
DO $$
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  PERFORM set_config('app.user_id', '0a000000-0000-7000-8000-00000000a001', true);
  INSERT INTO core.setting_value (tenant_id, setting_key, level, value, updated_by)
  VALUES ('0a000000-0000-7000-8000-000000000001', 'core.security.session_idle_s', 'tenant', '600', '0a000000-0000-7000-8000-00000000a001');
  UPDATE core.setting_value SET value = '900' WHERE setting_key = 'core.security.session_idle_s';
  PERFORM public.assert_true((SELECT count(*) FROM core.setting_history WHERE setting_key = 'core.security.session_idle_s') = 2, 'T07 history per change');
  PERFORM public.assert_true((SELECT max(version) FROM core.setting_history WHERE setting_key = 'core.security.session_idle_s') = 2, 'T07 version increments');
  PERFORM public.expect_error('T07 below min',
    $q$UPDATE core.setting_value SET value = '10' WHERE setting_key = 'core.security.session_idle_s'$q$, 'HK_SETTING_TYPE');
  PERFORM public.expect_error('T07 wrong type',
    $q$UPDATE core.setting_value SET value = '"abc"' WHERE setting_key = 'core.security.session_idle_s'$q$, 'HK_SETTING_TYPE');
  PERFORM public.expect_error('T07 level not allowed',
    $q$INSERT INTO core.setting_value (tenant_id, setting_key, level, user_id, value) VALUES ('0a000000-0000-7000-8000-000000000001', 'core.security.mfa_required', 'user', '0a000000-0000-7000-8000-00000000a002', 'true')$q$, 'HK_SETTING_LEVEL');
  PERFORM public.expect_error('T07 enum value',
    $q$INSERT INTO core.setting_value (tenant_id, setting_key, level, value) VALUES ('0a000000-0000-7000-8000-000000000001', 'core.locale', 'tenant', '"de-DE"')$q$, 'HK_SETTING_TYPE');
  PERFORM public.expect_error('T07 level/scope columns consistent',
    $q$INSERT INTO core.setting_value (tenant_id, setting_key, level, value) VALUES ('0a000000-0000-7000-8000-000000000001', 'core.amount_display_unit', 'company', '"IRT"')$q$, '23514');
  PERFORM public.expect_error('T07 history immutable', $q$UPDATE core.setting_history SET new_value = 'null'$q$, '42501');
  INSERT INTO core.setting_value (tenant_id, setting_key, level, value) VALUES ('0a000000-0000-7000-8000-000000000001', 'core.locale', 'tenant', '"fa-IR"');
  INSERT INTO core.setting_value (tenant_id, setting_key, level, user_id, value) VALUES ('0a000000-0000-7000-8000-000000000001', 'core.locale', 'user', '0c000000-0000-7000-8000-00000000c001', '"en-US"');
  PERFORM public.assert_true(core.setting_effective('core.locale', NULL, NULL, '0c000000-0000-7000-8000-00000000c001') = '"en-US"', 'T07 user overrides tenant');
  PERFORM public.assert_true(core.setting_effective('core.locale', NULL, NULL, '0a000000-0000-7000-8000-00000000a002') = '"fa-IR"', 'T07 tenant value');
  PERFORM public.assert_true(core.setting_effective('core.calendar_display') = '"jalali"', 'T07 default from definition');
  PERFORM public.expect_error('T07 duplicate scope row',
    $q$INSERT INTO core.setting_value (tenant_id, setting_key, level, value) VALUES ('0a000000-0000-7000-8000-000000000001', 'core.locale', 'tenant', '"en-US"')$q$, '23505');
END $$;

-- ---------- T08: فیلد سفارشی ----------
DO $$
DECLARE c jsonb; rid uuid;
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  INSERT INTO core.custom_field_def (tenant_id, entity_type, code, label_fa, data_type, options, is_indexed) VALUES
    ('0a000000-0000-7000-8000-000000000001', 'test.cf_demo', 'color', 'رنگ', 'enum', '[{"code":"red","label_fa":"قرمز"},{"code":"blue","label_fa":"آبی"}]', true);
  INSERT INTO core.custom_field_def (tenant_id, entity_type, code, label_fa, data_type, min_value, max_value, is_indexed) VALUES
    ('0a000000-0000-7000-8000-000000000001', 'test.cf_demo', 'warranty_months', 'گارانتی', 'int', 0, 60, true);
  INSERT INTO core.custom_field_def (tenant_id, entity_type, code, label_fa, data_type, is_required, default_value) VALUES
    ('0a000000-0000-7000-8000-000000000001', 'test.cf_demo', 'size', 'سایز', 'text', true, '"M"');
  INSERT INTO public.cf_demo (tenant_id, name, custom) VALUES ('0a000000-0000-7000-8000-000000000001', 'x', '{"color":"red","warranty_months":12}')
  RETURNING id, custom INTO rid, c;
  PERFORM public.assert_true(c = '{"color":"red","warranty_months":12,"size":"M"}', 'T08 required default applied');
  PERFORM public.assert_true((SELECT count(*) FROM core.custom_field_index WHERE entity_id = rid) = 2, 'T08 two indexed values');
  PERFORM public.expect_error('T08 unknown field',
    $q$INSERT INTO public.cf_demo (tenant_id, custom) VALUES ('0a000000-0000-7000-8000-000000000001', '{"colour":"red"}')$q$, 'HK_CF_UNKNOWN_FIELD');
  PERFORM public.expect_error('T08 enum not in options',
    $q$INSERT INTO public.cf_demo (tenant_id, custom) VALUES ('0a000000-0000-7000-8000-000000000001', '{"color":"green"}')$q$, 'HK_CF_INVALID_VALUE');
  PERFORM public.expect_error('T08 int above max',
    $q$INSERT INTO public.cf_demo (tenant_id, custom) VALUES ('0a000000-0000-7000-8000-000000000001', '{"warranty_months":100}')$q$, 'HK_CF_INVALID_VALUE');
  PERFORM public.expect_error('T08 int as string',
    $q$INSERT INTO public.cf_demo (tenant_id, custom) VALUES ('0a000000-0000-7000-8000-000000000001', '{"warranty_months":"12"}')$q$, 'HK_CF_INVALID_VALUE');
  PERFORM public.expect_error('T08 custom must be object',
    $q$INSERT INTO public.cf_demo (tenant_id, custom) VALUES ('0a000000-0000-7000-8000-000000000001', '[]')$q$, 'HK_CF_NOT_OBJECT');
  PERFORM public.expect_error('T08 data_type immutable',
    $q$UPDATE core.custom_field_def SET data_type = 'text', options = NULL WHERE code = 'color'$q$, 'HK_CF_IMMUTABLE');
  PERFORM public.expect_error('T08 enum option cannot be removed',
    $q$UPDATE core.custom_field_def SET options = '[{"code":"red","label_fa":"قرمز"}]' WHERE code = 'color'$q$, 'HK_CF_OPTION_REMOVED');
  UPDATE public.cf_demo SET custom = '{"color":"blue","warranty_months":null,"size":"L"}' WHERE id = rid RETURNING custom INTO c;
  PERFORM public.assert_true(c = '{"color":"blue","size":"L"}', 'T08 null removes key');
  PERFORM public.assert_true((SELECT array_agg(value_text) FROM core.custom_field_index WHERE entity_id = rid) = ARRAY['blue'], 'T08 index resynced');
  -- مستأجر B تعریف‌های A را ندارد
  PERFORM set_config('app.tenant_id', '0b000000-0000-7000-8000-000000000001', true);
  PERFORM public.expect_error('T08 definitions are per tenant',
    $q$INSERT INTO public.cf_demo (tenant_id, custom) VALUES ('0b000000-0000-7000-8000-000000000001', '{"color":"red"}')$q$, 'HK_CF_UNKNOWN_FIELD');
END $$;

-- ---------- T09: گردش تأیید و تفکیک وظایف ----------
DO $$
DECLARE p uuid; r uuid; r2 uuid; s uuid := gen_random_uuid(); steps jsonb;
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  INSERT INTO core.approval_policy (tenant_id, subject_type, company_id, name) VALUES
    ('0a000000-0000-7000-8000-000000000001', 'ledger.journal', '0a000000-0000-7000-8000-0000000000c1', 'سند بالای سقف') RETURNING id INTO p;
  INSERT INTO core.approval_policy_step (tenant_id, policy_id, step_no, approver_kind, role_id, min_approvals)
  VALUES ('0a000000-0000-7000-8000-000000000001', p, 1, 'role', '0a000000-0000-7000-8000-0000000f0002', 1);
  PERFORM public.assert_true((SELECT version FROM core.approval_policy WHERE id = p) = 2, 'T09 changing policy steps bumps the policy version');
  steps := jsonb_build_array(jsonb_build_object('step_no', 1, 'approver_kind', 'role', 'role_id', '0a000000-0000-7000-8000-0000000f0002',
                                                'user_id', NULL, 'permission_code', NULL, 'min_approvals', 1));
  INSERT INTO core.approval_request (tenant_id, company_id, subject_type, subject_id, amount, currency, requested_by, subject_created_by,
                                     policy_id, policy_version, steps_snapshot, enforce_sod, distinct_approvers)
  VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000000c1', 'ledger.journal', s, 500000000, 'IRR',
          '0a000000-0000-7000-8000-00000000a002', '0a000000-0000-7000-8000-00000000a002', p, 1, steps, true, true) RETURNING id INTO r;
  PERFORM public.expect_error('T09 one pending request per subject',
    format($q$INSERT INTO core.approval_request (tenant_id, company_id, subject_type, subject_id, requested_by, policy_id, policy_version, steps_snapshot, enforce_sod, distinct_approvers)
              VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000000c1', 'ledger.journal', %L, '0a000000-0000-7000-8000-00000000a002', %L, 1, %L, true, true)$q$, s, p, steps), '23505');
  PERFORM public.assert_true((SELECT steps_snapshot = steps AND policy_version = 2 FROM core.approval_request WHERE id = r),
                             'T09 snapshot and version come from the policy');
  -- RV-CORE-06: snapshot، نسخه و پرچم‌های ارسالی برنامه نادیده گرفته می‌شوند؛ پایگاه داده از خود سیاست می‌سازد
  INSERT INTO core.approval_request (tenant_id, company_id, subject_type, subject_id, requested_by, policy_id, policy_version, steps_snapshot, enforce_sod, distinct_approvers)
  VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000000c1', 'ledger.journal', gen_random_uuid(),
          '0a000000-0000-7000-8000-00000000a002', p, 99, '[{"step_no":1,"min_approvals":1}]', false, false) RETURNING id INTO r2;
  PERFORM public.assert_true((SELECT steps_snapshot = steps AND policy_version = 2 AND enforce_sod AND distinct_approvers
                                FROM core.approval_request WHERE id = r2), 'T09 app-supplied snapshot/version/flags are replaced');
  PERFORM public.expect_error('T09 decider without the policy role (forged snapshot ignored)',
    format($q$INSERT INTO core.approval_decision (tenant_id, request_id, step_no, decided_by, decision) VALUES ('0a000000-0000-7000-8000-000000000001', %L, 1, '0c000000-0000-7000-8000-00000000c001', 'approve')$q$, r2), 'HK_APPROVAL_NOT_ELIGIBLE');
  UPDATE core.approval_request SET status = 'cancelled', cancel_reason = 'آزمون' WHERE id = r2;
  PERFORM public.expect_error('T09 policy must cover the subject type',
    format($q$INSERT INTO core.approval_request (tenant_id, company_id, subject_type, subject_id, requested_by, policy_id, policy_version, steps_snapshot, enforce_sod, distinct_approvers)
              VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000000c1', 'treasury.payment', gen_random_uuid(), '0a000000-0000-7000-8000-00000000a002', %L, 1, '[]', true, true)$q$, p), 'HK_APPROVAL_POLICY_MISMATCH');
  PERFORM public.expect_error('T09 SoD: creator cannot approve',
    format($q$INSERT INTO core.approval_decision (tenant_id, request_id, step_no, decided_by, decision) VALUES ('0a000000-0000-7000-8000-000000000001', %L, 1, '0a000000-0000-7000-8000-00000000a002', 'approve')$q$, r), 'HK_SOD_VIOLATION');
  PERFORM public.expect_error('T09 approver must hold role',
    format($q$INSERT INTO core.approval_decision (tenant_id, request_id, step_no, decided_by, decision) VALUES ('0a000000-0000-7000-8000-000000000001', %L, 1, '0a000000-0000-7000-8000-00000000a001', 'approve')$q$, r), 'HK_APPROVAL_NOT_ELIGIBLE');
  PERFORM public.expect_error('T09 wrong step',
    format($q$INSERT INTO core.approval_decision (tenant_id, request_id, step_no, decided_by, decision) VALUES ('0a000000-0000-7000-8000-000000000001', %L, 2, '0a000000-0000-7000-8000-00000000a003', 'approve')$q$, r), 'HK_APPROVAL_WRONG_STEP');
  PERFORM public.expect_error('T09 cannot approve without quorum',
    format($q$UPDATE core.approval_request SET status = 'approved' WHERE id = %L$q$, r), 'HK_APPROVAL_QUORUM');
  INSERT INTO core.approval_decision (tenant_id, request_id, step_no, decided_by, decision)
  VALUES ('0a000000-0000-7000-8000-000000000001', r, 1, '0a000000-0000-7000-8000-00000000a003', 'approve');
  UPDATE core.approval_request SET status = 'approved' WHERE id = r;
  PERFORM public.assert_true((SELECT decided_at IS NOT NULL FROM core.approval_request WHERE id = r), 'T09 decided_at set');
  PERFORM public.expect_error('T09 closed request immutable',
    format($q$UPDATE core.approval_request SET status = 'cancelled', cancel_reason = 'x' WHERE id = %L$q$, r), 'HK_APPROVAL_CLOSED');
  PERFORM public.expect_error('T09 no decisions on closed request',
    format($q$INSERT INTO core.approval_decision (tenant_id, request_id, step_no, decided_by, decision, comment) VALUES ('0a000000-0000-7000-8000-000000000001', %L, 1, '0a000000-0000-7000-8000-00000000a003', 'reject', 'late')$q$, r), 'HK_APPROVAL_CLOSED');
  PERFORM public.expect_error('T09 decisions immutable', $q$UPDATE core.approval_decision SET comment = 'x'$q$, '42501');
  -- مسیر رد
  INSERT INTO core.approval_request (tenant_id, company_id, subject_type, subject_id, requested_by, policy_id, policy_version, steps_snapshot, enforce_sod, distinct_approvers)
  VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000000c1', 'ledger.journal', gen_random_uuid(),
          '0a000000-0000-7000-8000-00000000a002', p, 1, steps, true, true) RETURNING id INTO r2;
  PERFORM public.expect_error('T09 reject needs comment',
    format($q$INSERT INTO core.approval_decision (tenant_id, request_id, step_no, decided_by, decision) VALUES ('0a000000-0000-7000-8000-000000000001', %L, 1, '0a000000-0000-7000-8000-00000000a003', 'reject')$q$, r2), '23514');
  PERFORM public.expect_error('T09 rejected status needs reject decision',
    format($q$UPDATE core.approval_request SET status = 'rejected' WHERE id = %L$q$, r2), 'HK_APPROVAL_INVALID');
  INSERT INTO core.approval_decision (tenant_id, request_id, step_no, decided_by, decision, comment)
  VALUES ('0a000000-0000-7000-8000-000000000001', r2, 1, '0a000000-0000-7000-8000-00000000a003', 'reject', 'مدرک ناقص');
  UPDATE core.approval_request SET status = 'rejected' WHERE id = r2;
  PERFORM public.expect_error('T09 static SoD rule shape',
    $q$INSERT INTO core.sod_rule (tenant_id, code, name, kind) VALUES ('0a000000-0000-7000-8000-000000000001', 'x', 'x', 'static_conflict')$q$, '23514');
  PERFORM public.expect_error('T09 system role permissions locked',
    $q$INSERT INTO core.role_permission (tenant_id, role_id, permission_code) VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000f0001', 'core.audit.read')$q$, 'HK_CORE_SYSTEM_ROLE_LOCKED');
  PERFORM public.expect_error('T09 unknown permission',
    $q$INSERT INTO core.role_permission (tenant_id, role_id, permission_code) VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000f0003', 'core.nothing.here')$q$, '23503');
  PERFORM public.expect_error('T09 scope dimension must match column',
    $q$INSERT INTO core.role_assignment_scope (tenant_id, assignment_id, dimension, company_id)
       SELECT tenant_id, id, 'branch', '0a000000-0000-7000-8000-0000000000c1' FROM core.role_assignment LIMIT 1$q$, '23514');
END $$;

-- ---------- T10: رضایت پشتیبانی و ورود به‌جای کاربر ----------
DO $$
DECLARE g uuid; g2 uuid; s uuid;
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  INSERT INTO core.support_access_grant (tenant_id, granted_by, access_mode, max_session_minutes, expires_at, reason)
  VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-00000000a001', 'read_only', 60, now() + interval '24 hours', 'تیکت ۱۲')
  RETURNING id INTO g;
  INSERT INTO core.impersonation_session (tenant_id, grant_id, staff_id, staff_display_name, assertion_jti, token_hash, reason, ticket_ref, mode, expires_at)
  VALUES ('0a000000-0000-7000-8000-000000000001', g, gen_random_uuid(), 'پشتیبان', 'jti-1', sha256('jti-1'), 'بررسی خطای گزارش تراز', 'T-12', 'read_only', now() + interval '30 minutes')
  RETURNING id INTO s;
  PERFORM public.assert_true(core.impersonation_check(s) = 'read_only', 'T10 active read-only session');
  PERFORM public.expect_error('T10 longer than max_session_minutes',
    format($q$INSERT INTO core.impersonation_session (tenant_id, grant_id, staff_id, staff_display_name, assertion_jti, token_hash, reason, ticket_ref, mode, expires_at)
              VALUES ('0a000000-0000-7000-8000-000000000001', %L, gen_random_uuid(), 'x', 'jti-2', sha256('jti-2'), 'بررسی خطای گزارش تراز', 'T-12', 'read_only', now() + interval '2 hours')$q$, g), 'HK_IMP_TOO_LONG');
  PERFORM public.expect_error('T10 write without write consent',
    format($q$INSERT INTO core.impersonation_session (tenant_id, grant_id, staff_id, staff_display_name, assertion_jti, token_hash, reason, ticket_ref, mode, expires_at, write_approver_staff_id, target_user_id)
              VALUES ('0a000000-0000-7000-8000-000000000001', %L, gen_random_uuid(), 'x', 'jti-3', sha256('jti-3'), 'اصلاح دادهٔ مهاجرت', 'T-12', 'read_write', now() + interval '30 minutes', gen_random_uuid(), '0a000000-0000-7000-8000-00000000a002')$q$, g), 'HK_IMP_WRITE_NOT_CONSENTED');
  PERFORM public.expect_error('T10 reason is mandatory and meaningful',
    format($q$INSERT INTO core.impersonation_session (tenant_id, grant_id, staff_id, staff_display_name, assertion_jti, token_hash, reason, ticket_ref, mode, expires_at)
              VALUES ('0a000000-0000-7000-8000-000000000001', %L, gen_random_uuid(), 'x', 'jti-4', sha256('jti-4'), 'short', 'T-12', 'read_only', now() + interval '30 minutes')$q$, g), '23514');
  PERFORM public.expect_error('T10 no backdating',
    format($q$INSERT INTO core.impersonation_session (tenant_id, grant_id, staff_id, staff_display_name, assertion_jti, token_hash, reason, ticket_ref, mode, started_at, expires_at)
              VALUES ('0a000000-0000-7000-8000-000000000001', %L, gen_random_uuid(), 'x', 'jti-5', sha256('jti-5'), 'بررسی خطای گزارش تراز', 'T-12', 'read_only', now() - interval '1 hour', now())$q$, g), 'HK_IMP_CLOCK');
  PERFORM public.expect_error('T10 assertion replay',
    format($q$INSERT INTO core.impersonation_session (tenant_id, grant_id, staff_id, staff_display_name, assertion_jti, token_hash, reason, ticket_ref, mode, expires_at)
              VALUES ('0a000000-0000-7000-8000-000000000001', %L, gen_random_uuid(), 'x', 'jti-1', sha256('jti-1'), 'بررسی خطای گزارش تراز', 'T-12', 'read_only', now() + interval '10 minutes')$q$, g), '23505');
  PERFORM public.expect_error('T10 session cannot be extended',
    format($q$UPDATE core.impersonation_session SET expires_at = expires_at + interval '1 minute' WHERE id = %L$q$, s), 'HK_CORE_IMMUTABLE_FIELD');
  PERFORM public.expect_error('T10 grant cannot be extended',
    format($q$UPDATE core.support_access_grant SET expires_at = expires_at + interval '1 hour' WHERE id = %L$q$, g), 'HK_CORE_IMMUTABLE_FIELD');
  PERFORM public.expect_error('T10 reseller cannot use a platform-support consent',
    format($q$INSERT INTO core.impersonation_session (tenant_id, grant_id, grantee_kind, staff_id, staff_display_name, assertion_jti, token_hash, reason, ticket_ref, mode, expires_at)
              VALUES ('0a000000-0000-7000-8000-000000000001', %L, 'reseller', gen_random_uuid(), 'x', 'jti-9', sha256('jti-9'), 'بررسی خطای گزارش تراز', 'T-12', 'read_only', now() + interval '10 minutes')$q$, g), 'HK_IMP_NO_CONSENT');
  PERFORM public.expect_error('T10 grant window <= 7 days',
    $q$INSERT INTO core.support_access_grant (tenant_id, granted_by, expires_at) VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-00000000a001', now() + interval '8 days')$q$, '23514');
  -- لغو رضایت ← پایان فوری نشست
  UPDATE core.support_access_grant SET revoked_at = now(), revoked_by = '0a000000-0000-7000-8000-00000000a001' WHERE id = g;
  PERFORM public.assert_true((SELECT end_reason FROM core.impersonation_session WHERE id = s) = 'grant_revoked', 'T10 revoke ends session');
  PERFORM public.expect_error('T10 ended session is not active', format($q$SELECT core.impersonation_check(%L)$q$, s), 'HK_IMP_NOT_ACTIVE');
  PERFORM public.expect_error('T10 no session after revoke',
    format($q$INSERT INTO core.impersonation_session (tenant_id, grant_id, staff_id, staff_display_name, assertion_jti, token_hash, reason, ticket_ref, mode, expires_at)
              VALUES ('0a000000-0000-7000-8000-000000000001', %L, gen_random_uuid(), 'x', 'jti-6', sha256('jti-6'), 'بررسی خطای گزارش تراز', 'T-12', 'read_only', now() + interval '10 minutes')$q$, g), 'HK_IMP_NO_CONSENT');
  -- نوشتن: رضایت نوشتن + تأییدکنندهٔ دوم متفاوت + کاربر هدف
  INSERT INTO core.support_access_grant (tenant_id, granted_by, access_mode, expires_at)
  VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-00000000a001', 'read_write', now() + interval '4 hours') RETURNING id INTO g2;
  PERFORM public.expect_error('T10 second approver must differ',
    format($q$INSERT INTO core.impersonation_session (tenant_id, grant_id, staff_id, staff_display_name, assertion_jti, token_hash, reason, ticket_ref, mode, expires_at, write_approver_staff_id, target_user_id)
              VALUES ('0a000000-0000-7000-8000-000000000001', %L, '0f000000-0000-7000-8000-000000000001', 'x', 'jti-7', sha256('jti-7'), 'اصلاح دادهٔ مهاجرت', 'T-13', 'read_write', now() + interval '30 minutes', '0f000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-00000000a002')$q$, g2), '23514');
  INSERT INTO core.impersonation_session (tenant_id, grant_id, staff_id, staff_display_name, assertion_jti, token_hash, reason, ticket_ref, mode, expires_at, write_approver_staff_id, target_user_id)
  VALUES ('0a000000-0000-7000-8000-000000000001', g2, '0f000000-0000-7000-8000-000000000001', 'پشتیبان', 'jti-8', sha256('jti-8'), 'اصلاح دادهٔ مهاجرت', 'T-13', 'read_write',
          now() + interval '30 minutes', '0f000000-0000-7000-8000-000000000002', '0a000000-0000-7000-8000-00000000a002');
END $$;

-- ---------- T11: outbox → تحویل (fan-out هم‌تراکنش)، رله‌گر مرتب، صف job، انصاف، fencing، زمان‌بند ----------
DO $$
DECLARE agg uuid := gen_random_uuid(); e1 core.outbox_event; e2 core.outbox_event; d record; claimed text[] := '{}';
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  INSERT INTO core.outbox_event (tenant_id, event_type, aggregate_type, aggregate_id, payload)
  VALUES ('0a000000-0000-7000-8000-000000000001', 'test.thing.created', 'test.thing', agg, '{"n":1}') RETURNING * INTO e1;
  INSERT INTO core.outbox_event (tenant_id, event_type, aggregate_type, aggregate_id, payload)
  VALUES ('0a000000-0000-7000-8000-000000000001', 'test.thing.created', 'test.thing', agg, '{"n":2}') RETURNING * INTO e2;
  PERFORM public.assert_true((SELECT count(*) FROM core.outbox_delivery WHERE event_id IN (e1.id, e2.id)) = 4, 'T11 2 events x 2 subscribers deliveries');
  PERFORM public.assert_true(NOT EXISTS (SELECT 1 FROM core.outbox_delivery WHERE subscriber = 'core.webhooks'), 'T11 no webhook delivery without endpoint');
  PERFORM public.assert_true(e2.seq > e1.seq AND e1.tx_id IS NOT NULL, 'T11 seq and tx_id assigned');
  PERFORM public.expect_error('T11 outbox immutable', $q$UPDATE core.outbox_event SET payload = '{}'$q$, '42501');
  PERFORM public.expect_error('T11 outbox not deletable by app', $q$DELETE FROM core.outbox_event$q$, '42501');
  PERFORM public.expect_error('T11 delivery starts pending',
    format($q$INSERT INTO core.outbox_delivery (tenant_id, event_id, subscriber, event_seq, aggregate_id, status, lease_owner, lease_expires_at)
              VALUES ('0a000000-0000-7000-8000-000000000001', %L, 'uplink', %s, %L, 'running', 'x', now())$q$, e1.id, e1.seq, agg), 'HK_OUTBOX_STATE');
  -- رله‌گر روی نقش dispatcher (بدون زمینهٔ مستأجر)
  SET LOCAL ROLE hk_dispatcher;
  PERFORM set_config('app.tenant_id', '', true);
  FOR d IN SELECT * FROM core.outbox_claim(ARRAY['test.ordered','test.wild'], 'r1', 10) LOOP
    claimed := claimed || (d.subscriber || ':' || d.event_seq);
  END LOOP;
  PERFORM public.assert_true(cardinality(claimed) = 3, 'T11 relay claims 3 (ordered head only + 2 unordered)');
  PERFORM public.assert_true(NOT (('test.ordered:' || e2.seq) = ANY (claimed)), 'T11 ordered subscriber waits for earlier event');
  PERFORM public.assert_true((SELECT count(*) FROM core.outbox_claim(ARRAY['test.ordered'], 'r2', 10)) = 0, 'T11 nothing more claimable');
  PERFORM public.expect_error('T11 dispatcher cannot purge undelivered event',
    format($q$DELETE FROM core.outbox_event WHERE id = %L$q$, e1.id), 'HK_IMMUTABLE');
  SET LOCAL ROLE hk_app;
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  UPDATE core.outbox_delivery SET status = 'done', done_at = now(), lease_owner = NULL, lease_expires_at = NULL
   WHERE event_id = e1.id AND subscriber = 'test.ordered';
  PERFORM public.expect_error('T11 done delivery is final',
    format($q$UPDATE core.outbox_delivery SET status = 'pending', done_at = NULL WHERE event_id = %L AND subscriber = 'test.ordered'$q$, e1.id), 'HK_CORE_INVALID_TRANSITION');
  SET LOCAL ROLE hk_dispatcher;
  PERFORM public.assert_true((SELECT array_agg(x.event_id) FROM core.outbox_claim(ARRAY['test.ordered'], 'r3', 10) x) = ARRAY[e2.id],
                             'T11 next ordered event becomes claimable');
  SET LOCAL ROLE hk_app;
END $$;

-- webhook (قرارداد ۰۱ §۴-۴) و تحویل آن
DO $$
DECLARE w uuid; ev uuid;
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  PERFORM public.expect_error('T11 http webhook only on private network',
    $q$INSERT INTO core.webhook_endpoint (tenant_id, url, event_types, api_version, secret_sealed, created_by)
       VALUES ('0a000000-0000-7000-8000-000000000001', 'http://erp.example.ir/hook', '{test.thing.created}', '2026-11', '\x01', '0a000000-0000-7000-8000-00000000a001')$q$, '23514');
  INSERT INTO core.webhook_endpoint (tenant_id, url, event_types, api_version, secret_sealed, created_by)
  VALUES ('0a000000-0000-7000-8000-000000000001', 'https://erp.example.ir/hook', '{test.thing.created}', '2026-11', '\x01', '0a000000-0000-7000-8000-00000000a001')
  RETURNING id INTO w;
  INSERT INTO core.outbox_event (tenant_id, event_type, aggregate_type, aggregate_id, payload)
  VALUES ('0a000000-0000-7000-8000-000000000001', 'test.thing.created', 'test.thing', gen_random_uuid(), '{}') RETURNING id INTO ev;
  PERFORM public.assert_true(EXISTS (SELECT 1 FROM core.outbox_delivery WHERE event_id = ev AND subscriber = 'core.webhooks'), 'T11 webhook subscriber delivery when endpoint exists');
  INSERT INTO core.webhook_delivery (tenant_id, endpoint_id, event_id) VALUES ('0a000000-0000-7000-8000-000000000001', w, ev);
  PERFORM public.expect_error('T11 one webhook delivery per endpoint and event',
    format($q$INSERT INTO core.webhook_delivery (tenant_id, endpoint_id, event_id) VALUES ('0a000000-0000-7000-8000-000000000001', %L, %L)$q$, w, ev), '23505');
END $$;

-- صف job: سقف هر مستأجر، concurrency_key، fencing، reaper
DO $$
DECLARE j core.job; ids uuid[] := '{}'; k1 uuid; nxt core.job; other uuid;
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  INSERT INTO core.job (tenant_id, queue, kind, concurrency_key) SELECT '0a000000-0000-7000-8000-000000000001', 'default', 'test.conc', 'k1' FROM generate_series(1, 3);
  INSERT INTO core.job (tenant_id, queue, kind) SELECT '0a000000-0000-7000-8000-000000000001', 'default', 'test.free' FROM generate_series(1, 3);
  INSERT INTO core.job (tenant_id, queue, kind, dedupe_key) VALUES ('0a000000-0000-7000-8000-000000000001', 'default', 'test.dedupe', 'd1');
  PERFORM public.expect_error('T11 active dedupe key unique',
    $q$INSERT INTO core.job (tenant_id, queue, kind, dedupe_key) VALUES ('0a000000-0000-7000-8000-000000000001', 'default', 'test.dedupe', 'd1')$q$, '23505');
  PERFORM public.expect_error('T11 queued -> succeeded is invalid',
    $q$UPDATE core.job SET status = 'succeeded', finished_at = now() WHERE kind = 'test.dedupe'$q$, 'HK_CORE_INVALID_TRANSITION');
  PERFORM public.expect_error('T11 new job must be queued',
    $q$INSERT INTO core.job (tenant_id, queue, kind, status, lock_token, lease_owner, lease_expires_at) VALUES ('0a000000-0000-7000-8000-000000000001', 'default', 'x.y', 'running', gen_random_uuid(), 'w', now())$q$, 'HK_JOB_STATE');
  PERFORM public.expect_error('T11 unknown queue',
    $q$INSERT INTO core.job (tenant_id, queue, kind) VALUES ('0a000000-0000-7000-8000-000000000001', 'nope', 'x.y')$q$, '23514');
  INSERT INTO core.job_tenant_state (tenant_id, queue, max_running) VALUES ('0a000000-0000-7000-8000-000000000001', 'default', 3);
  SET LOCAL ROLE hk_dispatcher;
  PERFORM set_config('app.tenant_id', '', true);
  FOR j IN SELECT * FROM core.job_claim(ARRAY['default'], 'w1', 10, 60, 10) LOOP ids := ids || j.id; END LOOP;
  PERFORM public.assert_true(cardinality(ids) = 3, 'T11 per-tenant cap (3) respected');
  PERFORM public.assert_true((SELECT count(*) FROM core.job WHERE id = ANY (ids) AND concurrency_key = 'k1') = 1, 'T11 one running per concurrency_key');
  PERFORM public.assert_true((SELECT count(*) FROM core.job_claim(ARRAY['default'], 'w2', 10, 60, 10)) = 0, 'T11 cap holds for further claims');
  SELECT id INTO k1 FROM core.job WHERE id = ANY (ids) AND concurrency_key = 'k1';
  SELECT id INTO other FROM core.job WHERE concurrency_key = 'k1' AND status = 'queued' ORDER BY id LIMIT 1;
  PERFORM public.expect_error('T11 concurrency_key hard guard (unique running)',
    format($q$UPDATE core.job SET status = 'running', lock_token = gen_random_uuid(), lease_owner = 'rogue', lease_expires_at = now() + interval '1 minute', attempts = attempts + 1 WHERE id = %L$q$, other), '23505');
  -- پایان کار در تراکنش handler (نقش برنامه و زمینهٔ مستأجر)
  SET LOCAL ROLE hk_app;
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  PERFORM public.expect_error('T11 completion without lock token',
    format($q$UPDATE core.job SET status = 'succeeded', finished_at = now(), lock_token = NULL, lease_owner = NULL, lease_expires_at = NULL WHERE id = %L$q$, k1), 'HK_JOB_LEASE_LOST');
  PERFORM set_config('app.job_lock_token', (SELECT lock_token::text FROM core.job WHERE id = k1), true);
  UPDATE core.job SET status = 'succeeded', finished_at = now(), result = '{"ok":true}', lock_token = NULL, lease_owner = NULL, lease_expires_at = NULL WHERE id = k1;
  SET LOCAL ROLE hk_dispatcher;
  SELECT * INTO nxt FROM core.job_claim(ARRAY['default'], 'w3', 1, 60, 1);
  PERFORM public.assert_true(nxt.concurrency_key = 'k1', 'T11 next job of the key becomes claimable');
  -- lease منقضی ← reaper
  SET LOCAL ROLE hk_app;
  UPDATE core.job SET lease_expires_at = now() - interval '1 second' WHERE id = nxt.id;
  SET LOCAL ROLE hk_dispatcher;
  PERFORM public.assert_true(core.job_reap_expired(100) >= 1, 'T11 reaper reaps');
  PERFORM public.assert_true((SELECT status FROM core.job WHERE id = nxt.id) = 'queued', 'T11 reaper requeues expired lease');
  SET LOCAL ROLE hk_app;
END $$;

-- انصاف بین مستأجرها، شکست تجاری، پایان تلاش‌ها، زمان‌بند
DO $$
DECLARE tenants uuid[]; j core.job; jid uuid; sid uuid; fired uuid; again uuid;
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  INSERT INTO core.job (tenant_id, queue, kind) SELECT '0a000000-0000-7000-8000-000000000001', 'report', 'test.fair' FROM generate_series(1, 5);
  PERFORM set_config('app.tenant_id', '0b000000-0000-7000-8000-000000000001', true);
  INSERT INTO core.job (tenant_id, queue, kind) SELECT '0b000000-0000-7000-8000-000000000001', 'report', 'test.fair' FROM generate_series(1, 5);
  SET LOCAL ROLE hk_dispatcher;
  PERFORM set_config('app.tenant_id', '', true);
  SELECT array_agg(DISTINCT x.tenant_id) INTO tenants FROM core.job_claim(ARRAY['report'], 'w', 2, 60, 1) x;
  PERFORM public.assert_true(cardinality(tenants) = 2, 'T11 fair claim serves both tenants');
  SET LOCAL ROLE hk_app;
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  INSERT INTO core.job (tenant_id, queue, kind, max_attempts) VALUES ('0a000000-0000-7000-8000-000000000001', 'maintenance', 'test.once', 1) RETURNING id INTO jid;
  SET LOCAL ROLE hk_dispatcher;
  SELECT * INTO j FROM core.job_claim(ARRAY['maintenance'], 'w', 1, 60, 1);
  SET LOCAL ROLE hk_app;
  PERFORM set_config('app.job_lock_token', j.lock_token::text, true);
  PERFORM public.expect_error('T11 exhausted attempts cannot retry',
    format($q$UPDATE core.job SET status = 'queued', lock_token = NULL, lease_owner = NULL, lease_expires_at = NULL WHERE id = %L$q$, jid), 'HK_JOB_STATE');
  UPDATE core.job SET status = 'dead', finished_at = now(), lock_token = NULL, lease_owner = NULL, lease_expires_at = NULL,
                      last_error = '{"code":"boom"}' WHERE id = jid;
  PERFORM public.expect_error('T11 requeue resets attempts',
    format($q$UPDATE core.job SET status = 'queued', finished_at = NULL WHERE id = %L$q$, jid), 'HK_JOB_STATE');
  UPDATE core.job SET status = 'queued', finished_at = NULL, attempts = 0 WHERE id = jid;
  -- زمان‌بند: dedupe_key = '<schedule_id>:<fire_at>'
  PERFORM public.expect_error('T11 cron must have 5 fields',
    $q$INSERT INTO core.job_schedule (tenant_id, kind, cron, next_fire_at) VALUES ('0a000000-0000-7000-8000-000000000001', 'test.sched', '* * *', now())$q$, '23514');
  INSERT INTO core.job_schedule (tenant_id, kind, queue, cron, next_fire_at, code, jalali_filter)
  VALUES ('0a000000-0000-7000-8000-000000000001', 'test.sched', 'report', '30 23 * * *', '2026-03-20 20:00:00+00', 'test.month_end', 'month_end')
  RETURNING id INTO sid;
  SET LOCAL ROLE hk_dispatcher;
  PERFORM public.assert_true(EXISTS (SELECT 1 FROM core.schedule_due(100) s WHERE s.id = sid), 'T11 schedule due');
  -- RV-CORE-11: فقط همان next_fire_at ردیف شلیک می‌شود؛ زمان دلخواه گذشته رد می‌شود
  PERFORM public.expect_error('T11 arbitrary past fire time rejected',
    format($q$SELECT core.schedule_fire(%L, '2026-01-01 00:00:00+00', '2026-01-02 00:00:00+00')$q$, sid), 'HK_SCHEDULE_FIRE_MISMATCH');
  SET LOCAL TimeZone = 'Asia/Tehran';
  fired := core.schedule_fire(sid, '2026-03-20 20:00:00+00', '2026-04-19 20:00:00+00');
  PERFORM public.assert_true((SELECT dedupe_key FROM core.job WHERE id = fired) = sid::text || ':2026-03-20T20:00:00.000000Z',
                             'T11 dedupe key is UTC regardless of session TimeZone');
  SET LOCAL TimeZone = 'UTC';
  PERFORM public.expect_error('T11 re-firing the same slot (other scheduler/TimeZone) rejected',
    format($q$SELECT core.schedule_fire(%L, '2026-03-20 20:00:00+00', '2026-04-20 20:00:00+00')$q$, sid), 'HK_SCHEDULE_FIRE_MISMATCH');
  PERFORM public.assert_true((SELECT next_fire_at FROM core.job_schedule WHERE id = sid) = '2026-04-19 20:00:00+00', 'T11 next_fire_at advanced');
  PERFORM public.expect_error('T11 next fire must be later',
    format($q$SELECT core.schedule_fire(%L, '2026-04-19 20:00:00+00', '2026-04-01 00:00:00+00')$q$, sid), 'HK_SCHEDULE_NEXT');
  PERFORM public.expect_error('T11 next_fire_at cannot move backwards (trigger)',
    format($q$UPDATE core.job_schedule SET next_fire_at = '2026-01-02 00:00:00+00' WHERE id = %L$q$, sid), 'HK_SCHEDULE_NEXT');
  again := core.schedule_fire(sid, '2026-04-19 20:00:00+00', '2026-05-19 20:00:00+00', false);
  PERFORM public.assert_true(again IS NULL AND (SELECT next_fire_at FROM core.job_schedule WHERE id = sid) = '2026-05-19 20:00:00+00',
                             'T11 skipped slot (jalali filter) only advances');
  SET LOCAL ROLE hk_app;
  PERFORM public.expect_error('T11 app cannot claim jobs', $q$SELECT * FROM core.job_claim(ARRAY['default'], 'x', 1)$q$, '42501');
END $$;

-- ---------- T12: اعلان ----------
DO $$
DECLARE nid uuid;
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  -- RV-CORE-03: کد OTP هرگز ذخیره نمی‌شود؛ فقط ارجاع به چالش (job ارسال کد را بیرون از پایگاه داده بازمی‌سازد)
  PERFORM public.expect_error('T12 OTP code is never stored in params',
    $q$INSERT INTO core.notification (tenant_id, category, template_code, channel, recipient_address, params)
       VALUES ('0a000000-0000-7000-8000-000000000001', 'core.security', 'core.otp', 'sms', '09120000001', '{"code":"123456"}')$q$, 'HK_NTF_SECRET_PARAM');
  PERFORM public.expect_error('T12 OTP is never stored rendered',
    $q$INSERT INTO core.notification (tenant_id, category, template_code, channel, recipient_address, params, rendered_body)
       VALUES ('0a000000-0000-7000-8000-000000000001', 'core.security', 'core.otp', 'sms', '09120000001', '{}', 'کد ورود شما: 123456')$q$, 'HK_NTF_SECRET_PARAM');
  INSERT INTO core.notification (tenant_id, category, template_code, channel, recipient_address, params)
  VALUES ('0a000000-0000-7000-8000-000000000001', 'core.security', 'core.otp', 'sms', '09120000001',
          jsonb_build_object('otp_challenge_id', gen_random_uuid())) RETURNING id INTO nid;
  PERFORM public.expect_error('T12 OTP code cannot be added later',
    format($q$UPDATE core.notification SET params = params || '{"code":"123456"}' WHERE id = %L$q$, nid), 'HK_NTF_SECRET_PARAM');
  PERFORM public.assert_true((SELECT count(*) FROM core.job WHERE kind = 'core.notification.send' AND dedupe_key = 'ntf:' || nid) = 1, 'T12 sms enqueued in same tx');
  PERFORM public.expect_error('T12 mandatory category cannot be disabled',
    $q$INSERT INTO core.notification_preference (tenant_id, user_id, category, channel, enabled) VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-00000000a001', 'core.security', 'sms', false)$q$, 'HK_NTF_MANDATORY');
  INSERT INTO core.notification_preference (tenant_id, user_id, category, channel, enabled)
  VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-00000000a001', 'core.approval', 'in_app', false);
  PERFORM public.expect_error('T12 OTP template not overridable',
    $q$INSERT INTO core.notification_template (tenant_id, code, channel, locale, body) VALUES ('0a000000-0000-7000-8000-000000000001', 'core.otp', 'sms', 'fa-IR', 'کد: {code}')$q$, 'HK_NTF_NOT_OVERRIDABLE');
  INSERT INTO core.notification_template (tenant_id, code, channel, locale, body)
  VALUES ('0a000000-0000-7000-8000-000000000001', 'core.approval_needed', 'in_app', 'fa-IR', '{subject} را بررسی کنید');
  PERFORM public.expect_error('T12 in-app needs a member recipient',
    $q$INSERT INTO core.notification (tenant_id, category, template_code, channel, recipient_address) VALUES ('0a000000-0000-7000-8000-000000000001', 'core.system', 'core.job_dead', 'in_app', '09120000001')$q$, '23514');
END $$;

-- ---------- T13: پیوست ----------
DO $$
DECLARE a uuid := gen_random_uuid(); bad uuid := gen_random_uuid(); l uuid; k text;
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  k := 't/0a000000-0000-7000-8000-000000000001/' || to_char(now() AT TIME ZONE 'UTC', 'YYYY/MM') || '/' || a;
  PERFORM public.expect_error('T13 object key outside tenant namespace',
    format($q$INSERT INTO core.attachment (tenant_id, id, storage_backend, bucket, object_key, file_name, encryption_key_ref)
              VALUES ('0a000000-0000-7000-8000-000000000001', %L, 's3', 'hk', %L, 'a.pdf', 'dek/1')$q$, bad,
           't/0b000000-0000-7000-8000-000000000001/2026/11/' || bad), '23514');
  PERFORM public.expect_error('T13 must start pending_upload',
    format($q$INSERT INTO core.attachment (tenant_id, id, storage_backend, bucket, object_key, file_name, encryption_key_ref, status, size_bytes, sha256, uploaded_at, scanned_at, av_engine)
              VALUES ('0a000000-0000-7000-8000-000000000001', %L, 's3', 'hk', %L, 'a.pdf', 'dek/1', 'clean', 10, sha256('x'), now(), now(), 'clamav')$q$, a, k), 'HK_ATT_STATE');
  INSERT INTO core.attachment (tenant_id, id, storage_backend, bucket, object_key, file_name, encryption_key_ref)
  VALUES ('0a000000-0000-7000-8000-000000000001', a, 's3', 'hk', k, 'فاکتور خرید.pdf', 'dek/1');
  PERFORM public.expect_error('T13 cannot skip scanning',
    format($q$UPDATE core.attachment SET status = 'clean', size_bytes = 10, sha256 = sha256('x'), uploaded_at = now(), scanned_at = now(), av_engine = 'clamav' WHERE id = %L$q$, a), 'HK_CORE_INVALID_TRANSITION');
  UPDATE core.attachment SET status = 'uploaded', size_bytes = 10, sha256 = sha256('x'), uploaded_at = now() WHERE id = a;
  UPDATE core.attachment SET status = 'scanning' WHERE id = a;
  UPDATE core.attachment SET status = 'clean', scanned_at = now(), av_engine = 'clamav' WHERE id = a;
  PERFORM public.expect_error('T13 content immutable',
    format($q$UPDATE core.attachment SET sha256 = sha256('y') WHERE id = %L$q$, a), 'HK_CORE_IMMUTABLE_FIELD');
  INSERT INTO core.attachment_link (tenant_id, attachment_id, owner_module, owner_type, owner_id)
  VALUES ('0a000000-0000-7000-8000-000000000001', a, 'sales', 'sales.invoice', gen_random_uuid()) RETURNING id INTO l;
  UPDATE core.attachment_link SET is_locked = true WHERE id = l;
  PERFORM public.expect_error('T13 locked link cannot be unlocked', format($q$UPDATE core.attachment_link SET is_locked = false WHERE id = %L$q$, l), 'HK_ATT_LOCKED');
  PERFORM public.expect_error('T13 locked link cannot be deleted', format($q$DELETE FROM core.attachment_link WHERE id = %L$q$, l), 'HK_ATT_LOCKED');
  PERFORM public.expect_error('T13 locked attachment cannot be deleted',
    format($q$UPDATE core.attachment SET status = 'deleted', deleted_at = now() WHERE id = %L$q$, a), 'HK_ATT_LOCKED');
END $$;

-- ---------- T14: idempotency (قرارداد ۰۱ §۴-۱) ----------
DO $$
DECLARE k uuid; k2 uuid; n int;
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM public.expect_error('T14 key cannot commit without response',
    $q$INSERT INTO core.idempotency_key (tenant_id, principal_id, idem_key, method, route, request_hash, expires_at)
       VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-00000000a001', 'key-incomplete-000001', 'POST', '/api/v1/x', sha256('b'), now() + interval '1 day')$q$,
    'HK_IDEMPOTENCY_INCOMPLETE');
  SET CONSTRAINTS ALL DEFERRED;
  -- جریان درست: درج کلید (اولین نوشتن)، کار، پر کردن پاسخ، COMMIT
  INSERT INTO core.idempotency_key (tenant_id, principal_id, idem_key, method, route, request_hash, expires_at)
  VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-00000000a001', 'key-0000000000000001', 'POST',
          '/api/v1/ledger/journals', sha256('body'), now() + interval '7 days') RETURNING id INTO k;
  UPDATE core.idempotency_key SET response_status = 201, response_body = '{"id":"x"}' WHERE id = k;
  PERFORM public.expect_error('T14 completed key immutable',
    format($q$UPDATE core.idempotency_key SET response_status = 200 WHERE id = %L$q$, k), 'HK_IMMUTABLE');
  PERFORM public.expect_error('T14 same key twice',
    $q$INSERT INTO core.idempotency_key (tenant_id, principal_id, idem_key, method, route, request_hash, expires_at)
       VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-00000000a001', 'key-0000000000000001', 'POST', '/api/v1/ledger/journals', sha256('other'), now() + interval '1 day')$q$, '23505');
  INSERT INTO core.idempotency_key (tenant_id, principal_id, idem_key, method, route, request_hash, expires_at)
  VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-00000000a001', 'key-0000000000000001', 'POST',
          '/api/v1/ledger/journals', sha256('other'), now() + interval '1 day') ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM public.assert_true(n = 0, 'T14 ON CONFLICT DO NOTHING detects existing key');
  INSERT INTO core.idempotency_key (tenant_id, principal_id, idem_key, method, route, request_hash, expires_at)
  VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-00000000a001', 'key-0000000000000002', 'POST',
          '/api/v1/x', sha256('b2'), now() + interval '1 day') RETURNING id INTO k2;
  PERFORM public.expect_error('T14 identity columns immutable',
    format($q$UPDATE core.idempotency_key SET request_hash = sha256('changed') WHERE id = %L$q$, k2), 'HK_IMMUTABLE');
  -- RV-CORE-24 (۰۱ §۵-۸): پاسخ خطا ذخیره نمی‌شود؛ خطا تراکنش را برمی‌گرداند
  PERFORM public.expect_error('T14 error response is never stored',
    format($q$UPDATE core.idempotency_key SET response_status = 409, response_body = '{"code":"conflict"}' WHERE id = %L$q$, k2), '23514');
  -- RV-CORE-03: بدنهٔ بازپخش راز یک‌بارمصرف ندارد (نسخهٔ redacted ذخیره می‌شود)
  PERFORM public.expect_error('T14 replay body must not hold a one-time secret',
    format($q$UPDATE core.idempotency_key SET response_status = 201, response_body = '{"id":"w1","secret":"whsec_PLAINTEXT"}' WHERE id = %L$q$, k2), 'HK_IDEMPOTENCY_SECRET');
  PERFORM public.expect_error('T14 nested secret also refused',
    format($q$UPDATE core.idempotency_key SET response_status = 201, response_body = '{"data":[{"api_key":"hk_live_x"}]}' WHERE id = %L$q$, k2), 'HK_IDEMPOTENCY_SECRET');
  UPDATE core.idempotency_key SET response_status = 201, response_body = '{"id":"w1","secret_shown_once":true}' WHERE id = k2;
  PERFORM public.expect_error('T14 not deletable by app', $q$DELETE FROM core.idempotency_key$q$, '42501');
  PERFORM public.expect_error('T14 key format',
    $q$INSERT INTO core.idempotency_key (tenant_id, principal_id, idem_key, method, route, request_hash, response_status, expires_at)
       VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-00000000a001', 'short key', 'POST', '/x', sha256('b'), 201, now() + interval '1 day')$q$, '23514');
END $$;

-- ---------- T15: نشست (توکن کدر)، دستگاه و توکن دستگاه، PIN، کلید API ----------
DO $$
DECLARE s uuid; t uuid; k uuid;
BEGIN
  PERFORM set_config('app.user_id', '0c000000-0000-7000-8000-00000000c001', true);
  INSERT INTO core.user_session (user_id, token_hash, active_tenant_id, client_kind, amr, idle_timeout_seconds, absolute_expires_at)
  VALUES ('0c000000-0000-7000-8000-00000000c001', sha256('sess-c1'), '0a000000-0000-7000-8000-000000000001', 'web', '{pwd,totp}', 1800,
          now() + interval '12 hours') RETURNING id INTO s;
  PERFORM public.expect_error('T15 session token hash unique',
    $q$INSERT INTO core.user_session (user_id, token_hash, client_kind, amr, idle_timeout_seconds, absolute_expires_at) VALUES ('0c000000-0000-7000-8000-00000000c001', sha256('sess-c1'), 'web', '{pwd}', 600, now() + interval '8 hours')$q$, '23505');
  UPDATE core.user_session SET token_hash = sha256('sess-c1-rotated'), token_rotated_at = now() WHERE id = s;
  PERFORM public.expect_error('T15 PIN only on registered POS device',
    $q$INSERT INTO core.user_session (user_id, token_hash, client_kind, amr, idle_timeout_seconds, absolute_expires_at) VALUES ('0c000000-0000-7000-8000-00000000c001', sha256('p1'), 'pos', '{pin}', 600, now() + interval '8 hours')$q$, '23514');
  PERFORM public.expect_error('T15 session for another user',
    $q$INSERT INTO core.user_session (user_id, token_hash, client_kind, amr, idle_timeout_seconds, absolute_expires_at) VALUES ('0a000000-0000-7000-8000-00000000a001', sha256('p2'), 'web', '{pwd}', 600, now() + interval '8 hours')$q$, '42501');
  PERFORM public.expect_error('T15 device must belong to session tenant',
    $q$INSERT INTO core.user_session (user_id, token_hash, active_tenant_id, device_id, client_kind, amr, idle_timeout_seconds, absolute_expires_at) VALUES ('0c000000-0000-7000-8000-00000000c001', sha256('p3'), '0b000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000d0001', 'pos', '{device_key,pin}', 600, now() + interval '8 hours')$q$, 'HK_CORE_DEVICE_INACTIVE');
  PERFORM set_config('app.user_id', '0a000000-0000-7000-8000-00000000a002', true);
  PERFORM public.assert_true((SELECT count(*) FROM core.user_session) = 0, 'T15 sessions private');
  -- دستگاه و توکن دستگاه
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  PERFORM public.expect_error('T15 expired enrollment',
    $q$UPDATE core.device SET status = 'active', public_key = sha256('pk2'), activated_at = now() WHERE id = '0a000000-0000-7000-8000-0000000d0002'$q$, 'HK_CORE_ENROLLMENT_EXPIRED');
  PERFORM public.expect_error('T15 device key immutable',
    $q$UPDATE core.device SET public_key = sha256('other') WHERE id = '0a000000-0000-7000-8000-0000000d0001'$q$, 'HK_CORE_IMMUTABLE_FIELD');
  PERFORM public.assert_true((SELECT enrollment_code_hash IS NULL FROM core.device WHERE id = '0a000000-0000-7000-8000-0000000d0001'), 'T15 enrollment code consumed');
  PERFORM public.expect_error('T15 ecdsa_p256 key must be 65-byte SEC1',
    $q$UPDATE core.device SET key_alg = 'ecdsa_p256' WHERE id = '0a000000-0000-7000-8000-0000000d0001'$q$, '23514');
  INSERT INTO core.device_token (tenant_id, device_id, token_hash, expires_at)
  VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000d0001', sha256('devtok-1'), now() + interval '1 hour') RETURNING id INTO t;
  PERFORM public.expect_error('T15 device token at most 1 hour',
    $q$INSERT INTO core.device_token (tenant_id, device_id, token_hash, expires_at) VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000d0001', sha256('devtok-2'), now() + interval '2 hours')$q$, '23514');
  PERFORM public.expect_error('T15 device token immutable',
    format($q$UPDATE core.device_token SET token_hash = sha256('x') WHERE id = %L$q$, t), 'HK_CORE_IMMUTABLE_FIELD');
  INSERT INTO core.device_token (tenant_id, device_id, token_hash, expires_at, revoked_at)
  VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000d0001', sha256('devtok-revoked'), now() + interval '1 hour', now());
  PERFORM public.expect_error('T15 PIN must be argon2id',
    $q$INSERT INTO core.member_pin (tenant_id, membership_id, pin_hash) VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000e0002', '1234')$q$, '23514');
  -- کلید API: hk_<env>_<base32>
  INSERT INTO core.api_key (tenant_id, user_id, name, prefix, secret_hash, permissions, expires_at, created_by)
  VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-00000000a001', 'اتصال فروشگاه', 'hk_live_abcdefghijklmnop', sha256('secret'),
          '{core.attachment.read}', now() + interval '90 days', '0a000000-0000-7000-8000-00000000a001') RETURNING id INTO k;
  PERFORM public.expect_error('T15 api key prefix format',
    $q$INSERT INTO core.api_key (tenant_id, user_id, name, prefix, secret_hash, expires_at, created_by) VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-00000000a001', 'x', 'hk_abcdefghijklmnop', sha256('s'), now() + interval '1 day', '0a000000-0000-7000-8000-00000000a001')$q$, '23514');
  PERFORM public.expect_error('T15 api key unknown permission',
    $q$INSERT INTO core.api_key (tenant_id, user_id, name, prefix, secret_hash, permissions, expires_at, created_by) VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-00000000a001', 'x', 'hk_live_bbbbbbbbbbbbbbbb', sha256('s'), '{core.root.all}', now() + interval '1 day', '0a000000-0000-7000-8000-00000000a001')$q$, 'HK_CORE_UNKNOWN_PERMISSION');
  PERFORM public.expect_error('T15 api key secret immutable',
    format($q$UPDATE core.api_key SET secret_hash = sha256('new') WHERE id = %L$q$, k), 'HK_CORE_IMMUTABLE_FIELD');
  PERFORM public.expect_error('T15 api key lifetime <= 400 days',
    $q$INSERT INTO core.api_key (tenant_id, user_id, name, prefix, secret_hash, expires_at, created_by) VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-00000000a001', 'x', 'hk_live_cccccccccccccccc', sha256('s'), now() + interval '2 years', '0a000000-0000-7000-8000-00000000a001')$q$, '23514');
END $$;

-- توابع definer: حل شناسهٔ ورود، کلید API و توکن‌های کدر بدون زمینه
DO $$
DECLARE r record;
BEGIN
  PERFORM public.assert_true(core.auth_resolve_login('phone', '09120000009') = '0c000000-0000-7000-8000-00000000c001', 'T15 resolve login');
  PERFORM public.assert_true(core.auth_resolve_login('phone', '09129999999') IS NULL, 'T15 unknown login is NULL');
  SELECT * INTO r FROM core.auth_resolve_api_key('hk_live_abcdefghijklmnop');
  PERFORM public.assert_true(r.tenant_id = '0a000000-0000-7000-8000-000000000001', 'T15 resolve api key tenant');
  SELECT * INTO r FROM core.auth_resolve_token('session', sha256('sess-c1-rotated'));
  PERFORM public.assert_true(r.user_id = '0c000000-0000-7000-8000-00000000c001' AND r.tenant_id = '0a000000-0000-7000-8000-000000000001', 'T15 resolve session token');
  PERFORM public.assert_true(NOT EXISTS (SELECT 1 FROM core.auth_resolve_token('session', sha256('sess-c1'))), 'T15 rotated-out session token is dead');
  SELECT * INTO r FROM core.auth_resolve_token('device', sha256('devtok-1'));
  PERFORM public.assert_true(r.ref_id = '0a000000-0000-7000-8000-0000000d0001' AND r.tenant_id = '0a000000-0000-7000-8000-000000000001', 'T15 resolve device token');
  PERFORM public.assert_true(NOT EXISTS (SELECT 1 FROM core.auth_resolve_token('device', sha256('devtok-revoked'))), 'T15 revoked device token is dead');
  PERFORM public.assert_true(NOT EXISTS (SELECT 1 FROM core.auth_resolve_token('impersonation', sha256('jti-1'))), 'T15 ended impersonation token is dead');
  SELECT * INTO r FROM core.auth_resolve_token('impersonation', sha256('jti-8'));
  PERFORM public.assert_true(r.user_id = '0a000000-0000-7000-8000-00000000a002', 'T15 active impersonation token resolves to target user');
  PERFORM public.assert_true((SELECT count(*) FROM core.api_key) = 0 AND (SELECT count(*) FROM core.user_session) = 0, 'T15 tables still RLS-protected');
END $$;

-- ---------- T16: نگهداری، توقیف، درخواست دادهٔ شخصی، صدور ----------
DO $$
DECLARE dsr uuid; hold uuid;
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  PERFORM public.expect_error('T16 retention below class minimum',
    $q$INSERT INTO core.retention_override (tenant_id, class_code, period, set_by) VALUES ('0a000000-0000-7000-8000-000000000001', 'technical_log', interval '30 days', '0a000000-0000-7000-8000-00000000a001')$q$, 'HK_RET_TOO_SHORT');
  PERFORM public.expect_error('T16 legal retention not tenant-settable',
    $q$INSERT INTO core.retention_override (tenant_id, class_code, period, set_by) VALUES ('0a000000-0000-7000-8000-000000000001', 'accounting_records', interval '20 years', '0a000000-0000-7000-8000-00000000a001')$q$, 'HK_RET_LEGAL');
  INSERT INTO core.retention_override (tenant_id, class_code, period, set_by)
  VALUES ('0a000000-0000-7000-8000-000000000001', 'technical_log', interval '400 days', '0a000000-0000-7000-8000-00000000a001');
  -- RV-CORE-27: ماشین حالت درخواست دادهٔ شخصی در پایگاه داده
  PERFORM public.expect_error('T16 DSR starts received',
    $q$INSERT INTO core.data_subject_request (tenant_id, subject_type, subject_id, request_type, requested_via, requested_by, approved_by, status, decided_at)
       VALUES ('0a000000-0000-7000-8000-000000000001', 'party', gen_random_uuid(), 'erase', 'tenant_admin', '0a000000-0000-7000-8000-00000000a001', '0a000000-0000-7000-8000-00000000a003', 'approved', now())$q$, 'HK_RET_DSR_STATE');
  INSERT INTO core.data_subject_request (tenant_id, subject_type, subject_id, request_type, requested_via, requested_by)
  VALUES ('0a000000-0000-7000-8000-000000000001', 'party', gen_random_uuid(), 'erase', 'tenant_admin', '0a000000-0000-7000-8000-00000000a001') RETURNING id INTO dsr;
  PERFORM public.expect_error('T16 DSR cannot skip review',
    format($q$UPDATE core.data_subject_request SET status = 'approved', approved_by = '0a000000-0000-7000-8000-00000000a003' WHERE id = %L$q$, dsr), 'HK_CORE_INVALID_TRANSITION');
  UPDATE core.data_subject_request SET status = 'in_review' WHERE id = dsr;
  PERFORM public.expect_error('T16 DSR: approver differs from requester',
    format($q$UPDATE core.data_subject_request SET status = 'approved', approved_by = '0a000000-0000-7000-8000-00000000a001' WHERE id = %L$q$, dsr), '23514');
  UPDATE core.data_subject_request SET status = 'approved', approved_by = '0a000000-0000-7000-8000-00000000a003' WHERE id = dsr;
  UPDATE core.data_subject_request SET status = 'completed', result = '{"erased":3}' WHERE id = dsr;
  PERFORM public.assert_true((SELECT decided_at IS NOT NULL AND completed_at IS NOT NULL FROM core.data_subject_request WHERE id = dsr), 'T16 DSR timestamps set by the DB');
  PERFORM public.expect_error('T16 completed DSR is final',
    format($q$UPDATE core.data_subject_request SET status = 'received', approved_by = NULL, decided_at = NULL, completed_at = NULL WHERE id = %L$q$, dsr), 'HK_RET_DSR_STATE');
  -- RV-CORE-27: توقیف قانونی فقط آزاد می‌شود؛ آزادسازی پایانی است
  INSERT INTO core.legal_hold (tenant_id, scope, resource_type, resource_id, reason, placed_by)
  VALUES ('0a000000-0000-7000-8000-000000000001', 'resource', 'ledger.journal', gen_random_uuid(), 'رسیدگی مالیاتی ۱۴۰۴', '0a000000-0000-7000-8000-00000000a001') RETURNING id INTO hold;
  PERFORM public.expect_error('T16 legal hold reason immutable',
    format($q$UPDATE core.legal_hold SET reason = 'something else' WHERE id = %L$q$, hold), 'HK_CORE_IMMUTABLE_FIELD');
  PERFORM public.expect_error('T16 legal hold cannot be backdated',
    $q$INSERT INTO core.legal_hold (tenant_id, scope, reason, placed_by, placed_at) VALUES ('0a000000-0000-7000-8000-000000000001', 'tenant', 'رسیدگی مالیاتی', '0a000000-0000-7000-8000-00000000a001', now() - interval '3 years')$q$, 'HK_RET_HOLD');
  UPDATE core.legal_hold SET released_at = now(), released_by = '0a000000-0000-7000-8000-00000000a001' WHERE id = hold;
  PERFORM public.expect_error('T16 legal hold release is final',
    format($q$UPDATE core.legal_hold SET released_at = NULL, released_by = NULL WHERE id = %L$q$, hold), 'HK_RET_HOLD');
  PERFORM public.expect_error('T16 legal hold scope shape',
    $q$INSERT INTO core.legal_hold (tenant_id, scope, company_id, reason, placed_by) VALUES ('0a000000-0000-7000-8000-000000000001', 'tenant', '0a000000-0000-7000-8000-0000000000c1', 'حسابرسی مالیاتی', '0a000000-0000-7000-8000-00000000a001')$q$, '23514');
  PERFORM public.expect_error('T16 completed export must be signed',
    $q$INSERT INTO core.tenant_export (tenant_id, purpose, status, requested_by, object_key, sha256, manifest, completed_at)
       VALUES ('0a000000-0000-7000-8000-000000000001', 'backup', 'completed', '0a000000-0000-7000-8000-00000000a001', 't/0a000000-0000-7000-8000-000000000001/exports/x.hkx', sha256('z'), '{}', now())$q$, '23514');
  PERFORM public.expect_error('T16 export key namespace',
    $q$INSERT INTO core.tenant_export (tenant_id, purpose, requested_by, object_key) VALUES ('0a000000-0000-7000-8000-000000000001', 'backup', '0a000000-0000-7000-8000-00000000a001', 't/0b000000-0000-7000-8000-000000000001/exports/x.hkx')$q$, '23514');
END $$;

-- =====================================================================
-- T21..T28: آزمون‌های بازگشت یافته‌های دور بازبینی (هر کدام پیش از اصلاح شکست می‌خورد)
-- =====================================================================

-- ---------- T21: هویت سراسری — درج فقط برای خود، شناسهٔ تأییدشده، ستون‌های امنیتی (RV-IT2-07، RV-CORE-01/25/29) ----------
DO $$
DECLARE svc uuid := '0a000000-0000-7000-8000-00000000a0f1';
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  PERFORM set_config('app.user_id', '0a000000-0000-7000-8000-00000000a001', true);
  PERFORM public.expect_error('T21 tenant A cannot attach a verified identifier to a user of tenant B',
    $q$INSERT INTO core.user_login_identifier (user_id, kind, value, verified_at) VALUES ('0b000000-0000-7000-8000-00000000b001', 'email', 'attacker@example.ir', now())$q$, '42501');
  PERFORM public.expect_error('T21 tenant A cannot attach an unverified identifier to another user',
    $q$INSERT INTO core.user_login_identifier (user_id, kind, value) VALUES ('0b000000-0000-7000-8000-00000000b001', 'email', 'attacker@example.ir')$q$, '42501');
  PERFORM public.assert_true(core.auth_resolve_login('email', 'attacker@example.ir') IS NULL, 'T21 planted identifier does not resolve');
  PERFORM public.expect_error('T21 tenant A cannot plant a service account in tenant B',
    $q$INSERT INTO core.app_user (id, kind, home_tenant_id, display_name) VALUES ('0d000000-0000-7000-8000-0000000000d1', 'service', '0b000000-0000-7000-8000-000000000001', 'سرویس کاشته')$q$, '42501');
  PERFORM public.expect_error('T21 tenant context cannot create another human user',
    $q$INSERT INTO core.app_user (id, display_name) VALUES ('0d000000-0000-7000-8000-0000000000d2', 'کاربر کاشته')$q$, '42501');
  -- حساب سرویس خانهٔ همین مستأجر مجاز است و بی‌دعوت عضو فعال می‌شود
  INSERT INTO core.app_user (id, kind, home_tenant_id, display_name) VALUES (svc, 'service', '0a000000-0000-7000-8000-000000000001', 'اتصال فروشگاه');
  INSERT INTO core.tenant_membership (tenant_id, user_id, status) VALUES ('0a000000-0000-7000-8000-000000000001', svc, 'active');
  PERFORM public.expect_error('T21 service account home tenant is immutable',
    format($q$UPDATE core.app_user SET home_tenant_id = '0b000000-0000-7000-8000-000000000001' WHERE id = %L$q$, svc), 'HK_CORE_IMMUTABLE_FIELD');
END $$;
-- (هر بلوک DO یک تراکنش با یک زمینهٔ مستأجر است؛ R-TX — نگهبان deferred مالک در COMMIT همان زمینه را می‌بیند)
DO $$
DECLARE ch uuid; ch2 uuid;
BEGIN
  -- ثبت شمارهٔ دیگری بدون تأیید (squatting) کسی را بیرون نمی‌کند و به ورود حل نمی‌شود
  PERFORM set_config('app.tenant_id', '', true);
  PERFORM set_config('app.user_id', '0a000000-0000-7000-8000-00000000a002', true);
  INSERT INTO core.user_login_identifier (user_id, kind, value) VALUES ('0a000000-0000-7000-8000-00000000a002', 'phone', '09121111111');
  PERFORM public.assert_true(core.auth_resolve_login('phone', '09121111111') IS NULL, 'T21 unverified identifier never resolves');
  PERFORM public.expect_error('T21 self-declared verification without OTP',
    $q$UPDATE core.user_login_identifier SET verified_at = now() WHERE value = '09121111111'$q$, 'HK_CORE_UNVERIFIED');
  PERFORM public.expect_error('T21 cannot insert an already consumed OTP challenge',
    $q$INSERT INTO core.otp_challenge (user_id, purpose, channel, destination, code_hash, expires_at, consumed_at)
       VALUES ('0a000000-0000-7000-8000-00000000a002', 'verify_phone', 'sms', '09121111111', sha256('x'), now() + interval '5 minutes', now())$q$, 'HK_CORE_OTP');
  INSERT INTO core.otp_challenge (user_id, purpose, channel, destination, code_hash, expires_at, attempts, max_attempts)
  VALUES ('0a000000-0000-7000-8000-00000000a002', 'verify_phone', 'sms', '09121111111', sha256('y'), now() + interval '5 minutes', 0, 1) RETURNING id INTO ch2;
  UPDATE core.otp_challenge SET attempts = 1 WHERE id = ch2;
  PERFORM public.expect_error('T21 exhausted OTP challenge cannot be consumed',
    format($q$UPDATE core.otp_challenge SET consumed_at = now() WHERE id = %L$q$, ch2), 'HK_CORE_OTP');
  PERFORM public.expect_error('T21 OTP destination immutable',
    format($q$UPDATE core.otp_challenge SET destination = '09129999999' WHERE id = %L$q$, ch2), 'HK_CORE_IMMUTABLE_FIELD');
  -- صاحب واقعی شماره (UC1) با OTP مصرف‌شده آن را تأیید می‌کند؛ ردیف تأییدنشدهٔ UA2 مانع نیست
  PERFORM set_config('app.user_id', '0c000000-0000-7000-8000-00000000c001', true);
  INSERT INTO core.otp_challenge (user_id, purpose, channel, destination, code_hash, expires_at)
  VALUES ('0c000000-0000-7000-8000-00000000c001', 'verify_phone', 'sms', '09121111111', sha256('c'), now() + interval '5 minutes') RETURNING id INTO ch;
  UPDATE core.otp_challenge SET attempts = 1, consumed_at = now() WHERE id = ch;
  PERFORM public.expect_error('T21 OTP consumed only once',
    format($q$UPDATE core.otp_challenge SET consumed_at = now() + interval '1 second' WHERE id = %L$q$, ch), 'HK_CORE_OTP');
  INSERT INTO core.user_login_identifier (user_id, kind, value, verified_at) VALUES ('0c000000-0000-7000-8000-00000000c001', 'phone', '09121111111', now());
  PERFORM public.assert_true(core.auth_resolve_login('phone', '09121111111') = '0c000000-0000-7000-8000-00000000c001', 'T21 number resolves to its verified owner');
  -- شمارهٔ تأییدشده فقط مال یک کاربر است
  PERFORM set_config('app.user_id', '0a000000-0000-7000-8000-00000000a002', true);
  INSERT INTO core.otp_challenge (user_id, purpose, channel, destination, code_hash, expires_at)
  VALUES ('0a000000-0000-7000-8000-00000000a002', 'verify_phone', 'sms', '09121111111', sha256('d'), now() + interval '5 minutes') RETURNING id INTO ch;
  UPDATE core.otp_challenge SET attempts = 1, consumed_at = now() WHERE id = ch;
  PERFORM public.expect_error('T21 a verified identifier belongs to one user',
    $q$UPDATE core.user_login_identifier SET verified_at = now() WHERE value = '09121111111' AND user_id = '0a000000-0000-7000-8000-00000000a002'$q$, '23505');
  PERFORM public.expect_error('T21 identifier value immutable',
    $q$UPDATE core.user_login_identifier SET value = '09121111112' WHERE value = '09121111111' AND user_id = '0a000000-0000-7000-8000-00000000a002'$q$, 'HK_CORE_IMMUTABLE_FIELD');

  -- ستون‌های امنیتی app_user (RV-CORE-29)
  PERFORM public.expect_error('T21 user cannot turn into a service account of another tenant',
    $q$UPDATE core.app_user SET kind = 'service', home_tenant_id = '0b000000-0000-7000-8000-000000000001' WHERE id = '0a000000-0000-7000-8000-00000000a002'$q$, 'HK_CORE_IMMUTABLE_FIELD');
  PERFORM public.expect_error('T21 security_epoch moves forward by one only',
    $q$UPDATE core.app_user SET security_epoch = security_epoch + 2 WHERE id = '0a000000-0000-7000-8000-00000000a002'$q$, 'HK_CORE_SECURITY_EPOCH');
  PERFORM public.expect_error('T21 user cannot change own account status',
    $q$UPDATE core.app_user SET status = 'anonymized' WHERE id = '0a000000-0000-7000-8000-00000000a002'$q$, 'HK_CORE_USER_STATUS');
  UPDATE core.app_user SET locale = 'en-US' WHERE id = '0a000000-0000-7000-8000-00000000a002';
  UPDATE core.app_user SET locale = 'fa-IR' WHERE id = '0a000000-0000-7000-8000-00000000a002';
  PERFORM public.expect_error('T21 session tenant must be a membership of the user',
    $q$INSERT INTO core.user_session (user_id, token_hash, active_tenant_id, client_kind, amr, idle_timeout_seconds, absolute_expires_at)
       VALUES ('0a000000-0000-7000-8000-00000000a002', sha256('t21-b'), '0b000000-0000-7000-8000-000000000001', 'web', '{pwd}', 600, now() + interval '1 hour')$q$, '23503');
END $$;

-- ---------- T22: عضویت — درج فقط دعوت، پذیرش فقط خود کاربر، دعوت بدون افشای هویت (RV-IT2-08، RV-CORE-04، RV-CORE-15) ----------
DO $$
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  PERFORM set_config('app.user_id', '0a000000-0000-7000-8000-00000000a001', true);
  PERFORM public.expect_error('T22 tenant A cannot enrol a user of tenant B as active member without acceptance',
    $q$INSERT INTO core.tenant_membership (tenant_id, user_id, status, is_owner, joined_at) VALUES ('0a000000-0000-7000-8000-000000000001', '0b000000-0000-7000-8000-00000000b001', 'active', false, now())$q$, 'HK_CORE_MEMBERSHIP_INSERT');
  PERFORM public.expect_error('T22 a new membership is never an owner',
    $q$INSERT INTO core.tenant_membership (tenant_id, user_id, status, is_owner) VALUES ('0a000000-0000-7000-8000-000000000001', '0b000000-0000-7000-8000-00000000b001', 'invited', true)$q$, 'HK_CORE_MEMBERSHIP_INSERT');
  PERFORM public.assert_true((SELECT count(*) FROM core.app_user WHERE id = '0b000000-0000-7000-8000-00000000b001') = 0, 'T22 foreign user stays invisible');
  -- چند مستأجری: در زمینهٔ مستأجر A هیچ ردیف مستأجر دیگری دیده نمی‌شود (RV-CORE-15)
  PERFORM set_config('app.user_id', '0c000000-0000-7000-8000-00000000c001', true);
  PERFORM public.assert_true((SELECT count(*) FROM core.tenant_membership WHERE tenant_id <> '0a000000-0000-7000-8000-000000000001') = 0,
                             'T22 shared accountant sees no foreign membership inside tenant A');
  PERFORM public.assert_true((SELECT count(*) FROM core.tenant) = 1, 'T22 shared accountant sees only tenant A inside tenant A');
END $$;
DO $$
DECLARE m uuid; u_new uuid;
BEGIN
  -- دعوت کاربر موجود (UA1) به مستأجر B: پیش از پذیرش هیچ هویتی افشا نمی‌شود (RV-CORE-04)
  PERFORM set_config('app.tenant_id', '0b000000-0000-7000-8000-000000000001', true);
  PERFORM set_config('app.user_id', '0b000000-0000-7000-8000-00000000b001', true);
  m := core.member_invite('phone', '09120000001', 'هرچه');
  PERFORM public.assert_true((SELECT status FROM core.tenant_membership WHERE id = m) = 'invited', 'T22 invitation creates an invited membership');
  PERFORM public.assert_true((SELECT count(*) FROM core.app_user WHERE id = '0a000000-0000-7000-8000-00000000a001') = 0, 'T22 invited user profile is hidden');
  PERFORM public.assert_true((SELECT count(*) FROM core.user_login_identifier WHERE user_id = '0a000000-0000-7000-8000-00000000a001') = 0, 'T22 invited user identifiers are hidden');
  PERFORM public.expect_error('T22 only the invitee accepts',
    format($q$UPDATE core.tenant_membership SET status = 'active' WHERE id = %L$q$, m), 'HK_CORE_NOT_INVITEE');
  PERFORM set_config('app.user_id', '0a000000-0000-7000-8000-00000000a001', true);
  UPDATE core.tenant_membership SET status = 'active' WHERE id = m;
  PERFORM set_config('app.user_id', '0b000000-0000-7000-8000-00000000b001', true);
  PERFORM public.assert_true((SELECT count(*) FROM core.app_user WHERE id = '0a000000-0000-7000-8000-00000000a001') = 1, 'T22 accepted member is visible');
  PERFORM public.assert_true((SELECT count(*) FROM core.user_login_identifier WHERE user_id = '0a000000-0000-7000-8000-00000000a001') = 1,
                             'T22 only verified identifiers of an active member are visible');
  PERFORM public.expect_error('T22 owner grant needs an active owner',
    format($q$SELECT set_config('app.user_id', '0a000000-0000-7000-8000-00000000a001', true); UPDATE core.tenant_membership SET is_owner = true WHERE id = %L$q$, m), 'HK_CORE_OWNER_GRANT');
  PERFORM set_config('app.user_id', '0b000000-0000-7000-8000-00000000b001', true);
  UPDATE core.tenant_membership SET status = 'removed' WHERE id = m;
  PERFORM public.assert_true((SELECT count(*) FROM core.app_user WHERE id = '0a000000-0000-7000-8000-00000000a001') = 0, 'T22 removed member is hidden again');

  -- دعوت شمارهٔ ناشناخته: کاربر «سایه» با شناسهٔ تأییدنشده؛ دعوت دوم همان کاربر را به کار می‌برد
  m := core.member_invite('phone', '09123334444', 'عضو تازه');
  SELECT user_id INTO u_new FROM core.tenant_membership WHERE id = m;
  PERFORM public.assert_true(core.auth_resolve_login('phone', '09123334444') IS NULL, 'T22 invited (unverified) number does not log in');
  PERFORM set_config('app.t22_user', u_new::text, false);
END $$;
DO $$
DECLARE m2 uuid; u_new2 uuid;
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  PERFORM set_config('app.user_id', '0a000000-0000-7000-8000-00000000a001', true);
  m2 := core.member_invite('phone', '09123334444', 'عضو تازه');
  SELECT user_id INTO u_new2 FROM core.tenant_membership WHERE id = m2;
  PERFORM public.assert_true(current_setting('app.t22_user')::uuid = u_new2, 'T22 second invitation reuses the same pending user');
  PERFORM public.expect_error('T22 non-member cannot invite',
    $q$SELECT set_config('app.user_id', '0b000000-0000-7000-8000-00000000b001', true); SELECT core.member_invite('phone', '09125550000', 'x')$q$, 'HK_CORE_NOT_MEMBER');
END $$;

-- ---------- T23: شماره‌گذاری — دستگاه اجباری، رزرو فعال، پنجره، بازه‌ها (RV-CORE-05، RV-CORE-30، RV-CORE-10) ----------
DO $$
DECLARE r core.number_reservation; n int;
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  PERFORM set_config('app.user_id', '0a000000-0000-7000-8000-00000000a001', true);
  PERFORM public.expect_error('T23 device series needs the issuing device (NULL device)',
    $q$SELECT core.number_record_external('0a000000-0000-7000-8000-000000050003', 'jy:1405', 5, 'D1-1405-5', 'pos.sale', gen_random_uuid(), NULL)$q$, 'HK_NUM_DEVICE');
  r := core.number_reserve_range('0a000000-0000-7000-8000-000000050002', 'all', '0a000000-0000-7000-8000-0000000d0001', 10);
  PERFORM public.expect_error('T23 reservation number needs its device (NULL device)',
    format($q$SELECT core.number_record_external('0a000000-0000-7000-8000-000000050002', 'all', %s, 'X', 'pos.receipt', gen_random_uuid(), NULL, %L)$q$, r.range_start, r.id), 'HK_NUM_DEVICE');
  PERFORM public.expect_error('T23 cannot void a value inside an active reservation',
    format($q$SELECT core.number_void('0a000000-0000-7000-8000-000000050002', 'all', %s, 'دفترچه گم شد')$q$, r.range_start + 1), 'HK_NUM_RESERVED');
  PERFORM core.number_record_external('0a000000-0000-7000-8000-000000050002', 'all', r.range_start + 1, 'BR1-' || (r.range_start + 1), 'pos.receipt',
                                      gen_random_uuid(), '0a000000-0000-7000-8000-0000000d0001', r.id);
  n := core.number_close_reservation(r.id, 'shift closed');
  PERFORM public.assert_true(n = 9, 'T23 close voids the 9 unused numbers');
  PERFORM public.expect_error('T23 closing a reservation is final',
    format($q$SELECT core.number_close_reservation(%L, 'closed twice')$q$, r.id), 'HK_NUM_RESERVATION');
  PERFORM public.expect_error('T23 closed reservation accepts no number',
    format($q$SELECT core.number_record_external('0a000000-0000-7000-8000-000000050002', 'all', %s, 'X2', 'pos.receipt', gen_random_uuid(), '0a000000-0000-7000-8000-0000000d0001', %L)$q$, r.range_start + 2, r.id),
    'HK_NUM_NOT_IN_RESERVATION');
  PERFORM public.expect_error('T23 reservation only for an active device',
    $q$SELECT core.number_reserve_range('0a000000-0000-7000-8000-000000050002', 'all', '0a000000-0000-7000-8000-0000000d0002', 5)$q$, 'HK_NUM_DEVICE');
  SET LOCAL ROLE hk_core_definer;
  PERFORM public.expect_error('T23 closed reservation cannot be reopened (trigger)',
    format($q$UPDATE core.number_reservation SET status = 'active', closed_at = NULL, close_reason = NULL WHERE id = %L$q$, r.id), 'HK_NUM_RESERVATION');
  SET LOCAL ROLE hk_app;
  -- RV-CORE-30: مقدار دستگاه حداکثر core.numbering.device_window جلوتر از شمارنده؛ کسری به‌صورت بازه
  PERFORM public.expect_error('T23 device value far ahead of the counter',
    $q$SELECT core.number_record_external('0a000000-0000-7000-8000-000000050003', 'jy:1405', 10000000, 'D1-1405-10000000', 'pos.sale', gen_random_uuid(), '0a000000-0000-7000-8000-0000000d0001')$q$,
    'HK_NUM_OUT_OF_WINDOW');
  PERFORM core.number_record_external('0a000000-0000-7000-8000-000000050003', 'jy:1405', 50, 'D1-1405-50', 'pos.sale', gen_random_uuid(),
                                      '0a000000-0000-7000-8000-0000000d0001');
  PERFORM public.assert_true((SELECT array_agg(gap_start || '-' || gap_end) FROM core.number_gap_ranges('0a000000-0000-7000-8000-000000050003', 'jy:1405'))
                             = ARRAY['5-49'], 'T23 gaps are reported as ranges');
  n := core.number_void_range('0a000000-0000-7000-8000-000000050003', 'jy:1405', 5, 49, 'device lost before sync');
  PERFORM public.assert_true(n = 45 AND NOT EXISTS (SELECT 1 FROM core.number_gap_ranges('0a000000-0000-7000-8000-000000050003', 'jy:1405')),
                             'T23 a range void accounts for the whole gap');
  PERFORM public.expect_error('T23 cannot void an issued value',
    $q$SELECT core.number_void('0a000000-0000-7000-8000-000000050003', 'jy:1405', 50, 'already used one')$q$, 'HK_NUM_ALREADY_ISSUED');
END $$;

-- ---------- T24: گردش تأیید — حد نصاب، گام به گام، کاربر معین، مجوز، انقضا، قرارداد مصرف‌کننده (RV-CORE-06/07/10/26) ----------
DO $$
DECLARE p uuid; p3 uuid; p4 uuid; r uuid; r3 uuid; r4 uuid; s uuid := gen_random_uuid();
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  PERFORM set_config('app.user_id', '0a000000-0000-7000-8000-00000000a001', true);
  INSERT INTO core.role_assignment (tenant_id, membership_id, role_id)
  VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000e0004', '0a000000-0000-7000-8000-0000000f0002');
  INSERT INTO core.approval_policy (tenant_id, subject_type, company_id, name)
  VALUES ('0a000000-0000-7000-8000-000000000001', 'treasury.payment', '0a000000-0000-7000-8000-0000000000c1', 'پرداخت بزرگ') RETURNING id INTO p;
  INSERT INTO core.approval_policy_step (tenant_id, policy_id, step_no, approver_kind, role_id, user_id, min_approvals) VALUES
    ('0a000000-0000-7000-8000-000000000001', p, 1, 'role', '0a000000-0000-7000-8000-0000000f0002', NULL, 2),
    ('0a000000-0000-7000-8000-000000000001', p, 2, 'user', NULL, '0a000000-0000-7000-8000-00000000a001', 1);
  INSERT INTO core.approval_request (tenant_id, company_id, subject_type, subject_id, requested_by, policy_id, policy_version, steps_snapshot, enforce_sod, distinct_approvers)
  VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000000c1', 'treasury.payment', s,
          '0a000000-0000-7000-8000-00000000a002', p, 1, '[]', true, true) RETURNING id INTO r;
  INSERT INTO core.approval_decision (tenant_id, request_id, step_no, decided_by, decision)
  VALUES ('0a000000-0000-7000-8000-000000000001', r, 1, '0a000000-0000-7000-8000-00000000a003', 'approve');
  PERFORM public.expect_error('T24 step advances only after quorum',
    format($q$UPDATE core.approval_request SET current_step = 2 WHERE id = %L$q$, r), 'HK_APPROVAL_QUORUM');
  INSERT INTO core.approval_decision (tenant_id, request_id, step_no, decided_by, decision)
  VALUES ('0a000000-0000-7000-8000-000000000001', r, 1, '0c000000-0000-7000-8000-00000000c001', 'approve');
  PERFORM public.expect_error('T24 step advances by one',
    format($q$UPDATE core.approval_request SET current_step = 3 WHERE id = %L$q$, r), 'HK_APPROVAL_INVALID');
  PERFORM public.expect_error('T24 approval needs every step quorum',
    format($q$UPDATE core.approval_request SET status = 'approved' WHERE id = %L$q$, r), 'HK_APPROVAL_QUORUM');
  UPDATE core.approval_request SET current_step = 2 WHERE id = r;
  PERFORM public.expect_error('T24 a person decides once per request (also at a later step)',
    format($q$INSERT INTO core.approval_decision (tenant_id, request_id, step_no, decided_by, decision) VALUES ('0a000000-0000-7000-8000-000000000001', %L, 2, '0a000000-0000-7000-8000-00000000a003', 'approve')$q$, r),
    'HK_APPROVAL_DUPLICATE_APPROVER');
  PERFORM public.expect_error('T24 designated approver only',
    format($q$INSERT INTO core.approval_decision (tenant_id, request_id, step_no, decided_by, decision) VALUES ('0a000000-0000-7000-8000-000000000001', %L, 2, '0a000000-0000-7000-8000-00000000a0f1', 'approve')$q$, r),
    'HK_APPROVAL_NOT_ELIGIBLE');
  PERFORM public.expect_error('T24 consumer cannot rely on a pending request',
    format($q$SELECT core.approval_assert_approved(%L, 'treasury.payment', %L)$q$, r, s), 'HK_APPROVAL_REQUIRED');
  INSERT INTO core.approval_decision (tenant_id, request_id, step_no, decided_by, decision)
  VALUES ('0a000000-0000-7000-8000-000000000001', r, 2, '0a000000-0000-7000-8000-00000000a001', 'approve');
  UPDATE core.approval_request SET status = 'approved' WHERE id = r;
  PERFORM core.approval_assert_approved(r, 'treasury.payment', s);
  PERFORM public.expect_error('T24 approval of another subject cannot be reused',
    format($q$SELECT core.approval_assert_approved(%L, 'treasury.payment', gen_random_uuid())$q$, r), 'HK_APPROVAL_NOT_FOUND');
  PERFORM public.assert_true(EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'approval_request_subject_key'),
                             'T24 consumers can FK (tenant_id, id, subject_type, subject_id)');

  -- کاربر معین ولی عضو غیرفعال (RV-CORE-07)
  INSERT INTO core.approval_policy (tenant_id, subject_type, company_id, name)
  VALUES ('0a000000-0000-7000-8000-000000000001', 'treasury.refund', NULL, 'بازپرداخت') RETURNING id INTO p3;
  INSERT INTO core.approval_policy_step (tenant_id, policy_id, step_no, approver_kind, user_id)
  VALUES ('0a000000-0000-7000-8000-000000000001', p3, 1, 'user', '0c000000-0000-7000-8000-00000000c001');
  INSERT INTO core.approval_request (tenant_id, company_id, subject_type, subject_id, requested_by, policy_id, policy_version, steps_snapshot, enforce_sod, distinct_approvers)
  VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000000c1', 'treasury.refund', gen_random_uuid(),
          '0a000000-0000-7000-8000-00000000a002', p3, 1, '[]', true, true) RETURNING id INTO r3;
  UPDATE core.tenant_membership SET status = 'suspended' WHERE id = '0a000000-0000-7000-8000-0000000e0004';
  PERFORM public.expect_error('T24 suspended designated approver cannot decide',
    format($q$INSERT INTO core.approval_decision (tenant_id, request_id, step_no, decided_by, decision) VALUES ('0a000000-0000-7000-8000-000000000001', %L, 1, '0c000000-0000-7000-8000-00000000c001', 'approve')$q$, r3),
    'HK_APPROVAL_NOT_ELIGIBLE');
  UPDATE core.tenant_membership SET status = 'active' WHERE id = '0a000000-0000-7000-8000-0000000e0004';
  PERFORM public.expect_error('T24 cancel_reason only with cancelled',
    format($q$UPDATE core.approval_request SET cancel_reason = 'x' WHERE id = %L$q$, r3), 'HK_APPROVAL_INVALID');
  PERFORM public.expect_error('T24 a request without expiry cannot expire',
    format($q$UPDATE core.approval_request SET status = 'expired' WHERE id = %L$q$, r3), 'HK_APPROVAL_INVALID');
  UPDATE core.approval_request SET status = 'cancelled', cancel_reason = 'آزمون' WHERE id = r3;

  -- گام از نوع مجوز (پیش‌تر فقط در سرویس سنجیده می‌شد)
  INSERT INTO core.approval_policy (tenant_id, subject_type, company_id, name, expires_after)
  VALUES ('0a000000-0000-7000-8000-000000000001', 'sales.discount', NULL, 'تخفیف', interval '1 second') RETURNING id INTO p4;
  INSERT INTO core.approval_policy_step (tenant_id, policy_id, step_no, approver_kind, permission_code)
  VALUES ('0a000000-0000-7000-8000-000000000001', p4, 1, 'permission', 'core.approval.request.decide');
  INSERT INTO core.approval_request (tenant_id, company_id, subject_type, subject_id, requested_by, policy_id, policy_version, steps_snapshot, enforce_sod, distinct_approvers, created_at)
  VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000000c1', 'sales.discount', '0a000000-0000-7000-8000-0000000aa004',
          '0a000000-0000-7000-8000-00000000a002', p4, 1, '[]', true, true, now() + interval '10 years') RETURNING id INTO r4;
  PERFORM public.assert_true((SELECT expires_at = now() + interval '1 second' FROM core.approval_request WHERE id = r4),
                             'T24 expiry is computed from the DB clock, not from a supplied created_at');
  PERFORM public.expect_error('T24 decider must hold the step permission',
    format($q$INSERT INTO core.approval_decision (tenant_id, request_id, step_no, decided_by, decision) VALUES ('0a000000-0000-7000-8000-000000000001', %L, 1, '0a000000-0000-7000-8000-00000000a0f1', 'approve')$q$, r4),
    'HK_APPROVAL_NOT_ELIGIBLE');
  PERFORM public.expect_error('T24 expiry is immutable',
    format($q$UPDATE core.approval_request SET expires_at = NULL WHERE id = %L$q$, r4), 'HK_CORE_IMMUTABLE_FIELD');
  INSERT INTO core.approval_decision (tenant_id, request_id, step_no, decided_by, decision)
  VALUES ('0a000000-0000-7000-8000-000000000001', r4, 1, '0a000000-0000-7000-8000-00000000a003', 'approve');
  PERFORM public.expect_error('T24 non-positive expiry window rejected',
    $q$INSERT INTO core.approval_policy (tenant_id, subject_type, name, expires_after) VALUES ('0a000000-0000-7000-8000-000000000001', 'sales.discount', 'x', interval '-1 minute')$q$, '23514');
END $$;
SELECT pg_sleep(1.2) \gset
DO $$
DECLARE r4 uuid;
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  PERFORM set_config('app.user_id', '0a000000-0000-7000-8000-00000000a001', true);
  SELECT id INTO r4 FROM core.approval_request WHERE subject_id = '0a000000-0000-7000-8000-0000000aa004';
  PERFORM public.expect_error('T24 expired request takes no decision',
    format($q$INSERT INTO core.approval_decision (tenant_id, request_id, step_no, decided_by, decision) VALUES ('0a000000-0000-7000-8000-000000000001', %L, 1, '0c000000-0000-7000-8000-00000000c001', 'approve')$q$, r4),
    'HK_APPROVAL_EXPIRED');
  PERFORM public.expect_error('T24 expired request cannot be approved even with quorum',
    format($q$UPDATE core.approval_request SET status = 'approved' WHERE id = %L$q$, r4), 'HK_APPROVAL_EXPIRED');
  UPDATE core.approval_request SET status = 'expired' WHERE id = r4;
END $$;

-- ---------- T25: ممیزی — checkpoint فقط از تابع، hash منطبق، یک زنجیره، کنشگر عضو (RV-CORE-09، RV-CORE-22، R-AI-PRINCIPAL) ----------
DO $$
DECLARE c core.audit_checkpoint; c2 core.audit_checkpoint; c3 core.audit_checkpoint;
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  PERFORM set_config('app.user_id', '0a000000-0000-7000-8000-00000000a001', true);
  PERFORM public.expect_error('T25 app cannot write checkpoints directly',
    $q$INSERT INTO core.audit_checkpoint (tenant_id, chain_no, seq, row_hash, verified_from_seq, result) SELECT tenant_id, 0, seq, row_hash, 1, 'ok' FROM core.audit_log WHERE seq = 1$q$, '42501');
  c := core.audit_checkpoint_create();
  PERFORM public.assert_true(c.result = 'ok' AND c.verified_from_seq = 1 AND c.seq = (SELECT last_seq FROM core.audit_chain_head), 'T25 first checkpoint covers the chain');
  INSERT INTO core.audit_log (tenant_id, actor_kind, action) VALUES ('0a000000-0000-7000-8000-000000000001', 'system', 'core.audit.selftest');
  c2 := core.audit_checkpoint_create();
  PERFORM public.assert_true(c2.verified_from_seq = c.seq + 1 AND c2.result = 'ok', 'T25 daily checkpoint is incremental');
  c3 := core.audit_checkpoint_create(true);
  PERFORM public.assert_true(c3.verified_from_seq = 1 AND c3.result = 'ok', 'T25 weekly checkpoint re-verifies from seq 1');
  PERFORM public.expect_error('T25 only chain 0 in v1',
    $q$INSERT INTO core.audit_log (tenant_id, chain_no, actor_kind, action) VALUES ('0a000000-0000-7000-8000-000000000001', 5, 'system', 'core.audit.selftest')$q$, '23514');
  PERFORM public.expect_error('T25 audit actor must be a member of the tenant (R-ACTOR)',
    $q$INSERT INTO core.audit_log (tenant_id, actor_kind, actor_user_id, action) VALUES ('0a000000-0000-7000-8000-000000000001', 'user', '0b000000-0000-7000-8000-00000000b001', 'core.audit.selftest')$q$, '23503');
  INSERT INTO core.audit_log (tenant_id, actor_kind, actor_user_id, action)
  VALUES ('0a000000-0000-7000-8000-000000000001', 'assistant', '0a000000-0000-7000-8000-00000000a001', 'core.audit.selftest');
  PERFORM public.expect_error('T25 assistant actor names the delegating user',
    $q$INSERT INTO core.audit_log (tenant_id, actor_kind, action) VALUES ('0a000000-0000-7000-8000-000000000001', 'assistant', 'core.audit.selftest')$q$, '23514');
  SET LOCAL ROLE hk_audit_writer;
  PERFORM public.expect_error('T25 forged checkpoint hash rejected',
    $q$INSERT INTO core.audit_checkpoint (tenant_id, chain_no, seq, row_hash, verified_from_seq, result) VALUES ('0a000000-0000-7000-8000-000000000001', 0, 1, sha256('forged'), 1, 'ok')$q$, 'HK_AUDIT_CHECKPOINT');
  SET LOCAL ROLE hk_app;
END $$;

-- ---------- T26: outbox و job — قفل ترتیب، CHECKهای تحویل، صف مرده، فیلتر endpoint (RV-CORE-08/10/14، RV-ARCH-09) ----------
DO $$
DECLARE agg uuid := gen_random_uuid(); e core.outbox_event; e2 core.outbox_event; d record; jid uuid; j core.job; n int;
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  INSERT INTO core.outbox_event (tenant_id, event_type, aggregate_type, aggregate_id, payload)
  VALUES ('0a000000-0000-7000-8000-000000000001', 'test.thing.updated', 'test.thing', agg, '{}') RETURNING * INTO e;
  PERFORM public.assert_true(EXISTS (SELECT 1 FROM pg_locks l WHERE l.locktype = 'advisory' AND l.pid = pg_backend_pid() AND l.granted
                                        AND l.classid = 1330597960::oid
                                        AND l.objid = (core.outbox_order_lock_key(e.tenant_id, agg)::bigint & 4294967295)::text::oid),
                             'T26 the producing transaction holds the per-aggregate ordering lock');
  PERFORM public.assert_true(NOT EXISTS (SELECT 1 FROM core.outbox_delivery WHERE event_id = e.id AND subscriber = 'core.webhooks'),
                             'T26 webhook delivery only for an endpoint subscribed to that event type');
  PERFORM public.assert_true(EXISTS (SELECT 1 FROM core.outbox_delivery WHERE event_id = e.id AND subscriber = 'test.wild'), 'T26 wildcard subscriber matched');
  SET LOCAL ROLE hk_dispatcher;
  PERFORM set_config('app.tenant_id', '', true);
  SELECT * INTO d FROM core.outbox_claim(ARRAY['test.wild'], 'r9', 50) x WHERE x.event_id = e.id;
  PERFORM public.assert_true(d.attempts = 1, 'T26 claim increments attempts');
  SET LOCAL ROLE hk_app;
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  PERFORM public.expect_error('T26 done delivery needs done_at',
    format($q$UPDATE core.outbox_delivery SET status = 'done', lease_owner = NULL, lease_expires_at = NULL WHERE event_id = %L AND subscriber = 'test.wild'$q$, e.id), '23514');
  PERFORM public.expect_error('T26 running delivery needs its lease',
    format($q$UPDATE core.outbox_delivery SET lease_owner = NULL WHERE event_id = %L AND subscriber = 'test.wild'$q$, e.id), '23514');
  UPDATE core.outbox_delivery SET status = 'dead', lease_owner = NULL, lease_expires_at = NULL, last_error = '{"code":"x"}'
   WHERE event_id = e.id AND subscriber = 'test.wild';
  PERFORM public.expect_error('T26 dead requeue resets attempts',
    format($q$UPDATE core.outbox_delivery SET status = 'pending' WHERE event_id = %L AND subscriber = 'test.wild'$q$, e.id), 'HK_OUTBOX_STATE');
  UPDATE core.outbox_delivery SET status = 'pending', attempts = 0 WHERE event_id = e.id AND subscriber = 'test.wild';
  SET LOCAL ROLE hk_dispatcher;
  PERFORM set_config('app.tenant_id', '', true);
  PERFORM count(*) FROM core.outbox_claim(ARRAY['test.wild'], 'r10', 50);
  SET LOCAL ROLE hk_app;
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  UPDATE core.outbox_delivery SET status = 'done', done_at = now(), lease_owner = NULL, lease_expires_at = NULL
   WHERE event_id = e.id AND subscriber = 'test.wild';
  PERFORM public.expect_error('T26 done delivery is final (no field change)',
    format($q$UPDATE core.outbox_delivery SET done_at = now() - interval '1 day' WHERE event_id = %L AND subscriber = 'test.wild'$q$, e.id), 'HK_CORE_IMMUTABLE_FIELD');

  -- job: شناسه و payload تغییرناپذیر؛ برداشتن بدون افزایش تلاش رد می‌شود
  INSERT INTO core.job (tenant_id, queue, kind, payload, max_attempts) VALUES ('0a000000-0000-7000-8000-000000000001', 'heavy', 'test.dl', '{"a":1}', 1) RETURNING id INTO jid;
  PERFORM public.expect_error('T26 job payload immutable',
    format($q$UPDATE core.job SET payload = '{"a":2}' WHERE id = %L$q$, jid), 'HK_CORE_IMMUTABLE_FIELD');
  SET LOCAL ROLE hk_dispatcher;
  PERFORM set_config('app.tenant_id', '', true);
  PERFORM public.expect_error('T26 claim must increment attempts',
    format($q$UPDATE core.job SET status = 'running', lock_token = gen_random_uuid(), lease_owner = 'w', lease_expires_at = now() + interval '1 minute' WHERE id = %L$q$, jid), 'HK_JOB_STATE');
  SELECT * INTO j FROM core.job_claim(ARRAY['heavy'], 'w-dl', 1, 60, 1);
  PERFORM public.assert_true(j.id = jid, 'T26 claimed the job');
  SET LOCAL ROLE hk_app;
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  UPDATE core.job SET lease_expires_at = now() - interval '1 second' WHERE id = jid;
  SET LOCAL ROLE hk_dispatcher;
  PERFORM set_config('app.tenant_id', '', true);
  n := core.job_reap_expired(100);
  PERFORM public.assert_true((SELECT status FROM core.job WHERE id = jid) = 'dead', 'T26 reaper dead-letters an exhausted job');
  PERFORM public.assert_true(EXISTS (SELECT 1 FROM core.job WHERE kind = 'core.job.dead_letter_notify' AND dedupe_key = 'dead:' || jid
                                        AND payload ->> 'job_id' = jid::text AND tenant_id = '0a000000-0000-7000-8000-000000000001'),
                             'T26 dead-lettering is never silent (notice job in the same tx)');
  SET LOCAL ROLE hk_app;
END $$;

-- ---------- T27: فیلد سفارشی، حالت مطلوب، provisioning، قالب چاپ، نگهبان دستیار، ساعت (RV-CORE-16، RV-X2-10/11، RV-X4-03، RV-X3-05، RV-AST-19، RV-ARCH-17) ----------
DO $$
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  -- RV-CORE-16: نمایه = تصویر دقیق فیلدهای is_indexed
  UPDATE core.custom_field_def SET is_indexed = true WHERE code = 'size';
  PERFORM public.assert_true((SELECT count(*) FROM core.custom_field_index i JOIN core.custom_field_def d ON d.id = i.field_id WHERE d.code = 'size')
                             = (SELECT count(*) FROM public.cf_demo WHERE custom ? 'size') AND (SELECT count(*) FROM public.cf_demo WHERE custom ? 'size') > 0,
                             'T27 turning is_indexed on back-fills the index');
  UPDATE core.custom_field_def SET is_indexed = false WHERE code = 'color';
  PERFORM public.assert_true(NOT EXISTS (SELECT 1 FROM core.custom_field_index i JOIN core.custom_field_def d ON d.id = i.field_id WHERE d.code = 'color'),
                             'T27 turning is_indexed off removes stale index rows');
  PERFORM public.assert_true(core.custom_field_reindex('test.cf_demo') = (SELECT count(*) FROM core.custom_field_index), 'T27 full reindex is idempotent');
END $$;

DO $$
DECLARE doc text; sig bytea := decode(repeat('ab', 64), 'hex');
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  PERFORM set_config('app.user_id', '', true);
  PERFORM public.expect_error('T27 app cannot change tenant status directly (R-GRANT)',
    $q$UPDATE core.tenant SET status = 'read_only' WHERE id = '0a000000-0000-7000-8000-000000000001'$q$, '42501');
  doc := jsonb_build_object('format', 'hkstate/1', 'tenant_id', '0a000000-0000-7000-8000-000000000001', 'version', 1, 'status', 'read_only',
                            'entitlements', jsonb_build_array(jsonb_build_object('key', 'core.members.active', 'limit', 10, 'enforcement', 'hard')))::text;
  PERFORM public.assert_true(core.apply_desired_state(doc, sig, 'plt-2026-1') = 'applied', 'T27 desired state applied');
  PERFORM public.assert_true((SELECT status FROM core.tenant) = 'read_only', 'T27 desired state sets read_only (dunning)');
  PERFORM public.assert_true(core.apply_desired_state(doc, sig, 'plt-2026-1') = 'ignored', 'T27 replayed desired state ignored');
  doc := jsonb_build_object('format', 'hkstate/1', 'tenant_id', '0a000000-0000-7000-8000-000000000001', 'version', 2, 'status', 'active',
                            'entitlements', jsonb_build_array(jsonb_build_object('key', 'core.members.active', 'limit', 4, 'enforcement', 'hard')))::text;
  PERFORM public.assert_true(core.apply_desired_state(doc, sig, 'plt-2026-1') = 'applied', 'T27 newer version applied');
  PERFORM public.assert_true((SELECT status FROM core.tenant) = 'active', 'T27 reactivation');
  doc := jsonb_build_object('format', 'hkstate/1', 'tenant_id', '0a000000-0000-7000-8000-000000000001', 'version', 1, 'status', 'suspended')::text;
  PERFORM public.assert_true(core.apply_desired_state(doc, sig, 'plt-2026-1') = 'ignored' AND (SELECT status FROM core.tenant) = 'active', 'T27 rollback to an older version ignored');
  PERFORM public.expect_error('T27 desired state for another tenant',
    $q$SELECT core.apply_desired_state(jsonb_build_object('format','hkstate/1','tenant_id','0b000000-0000-7000-8000-000000000001','version',9,'status','suspended')::text, decode(repeat('ab', 64), 'hex'), 'k')$q$,
    'HK_CORE_DESIRED_STATE');
  PERFORM public.expect_error('T27 desired state only in the system unit of work',
    $q$SELECT set_config('app.user_id', '0a000000-0000-7000-8000-00000000a001', true); SELECT core.apply_desired_state('{}', decode(repeat('ab', 64), 'hex'), 'k')$q$, 'HK_CORE_SYSTEM_ONLY');
  PERFORM public.expect_error('T27 entitlements written only by apply_desired_state',
    $q$UPDATE core.tenant_entitlement SET limit_value = 1000$q$, '42501');
  -- سقف سخت در خود پایگاه داده: پنجمین عضو فعال انسانی رد می‌شود (D-P09)
  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM public.expect_error('T27 hard member limit enforced in the database',
    $q$SELECT set_config('app.user_id', (SELECT user_id::text FROM core.tenant_membership WHERE status = 'invited' LIMIT 1), true);
       UPDATE core.tenant_membership SET status = 'active' WHERE status = 'invited' AND user_id = core.current_user_id()$q$, 'HK_CORE_ENTITLEMENT_LIMIT');
  SET CONSTRAINTS ALL DEFERRED;
  doc := jsonb_build_object('format', 'hkstate/1', 'tenant_id', '0a000000-0000-7000-8000-000000000001', 'version', 3, 'status', 'active', 'entitlements', '[]'::jsonb)::text;
  PERFORM public.assert_true(core.apply_desired_state(doc, sig, 'plt-2026-1') = 'applied', 'T27 version 3 applied');
  PERFORM public.assert_true(NOT EXISTS (SELECT 1 FROM core.tenant_entitlement), 'T27 entitlements replaced by the document');
  PERFORM public.assert_true(EXISTS (SELECT 1 FROM core.audit_log WHERE action = 'core.tenant.desired_state_applied'), 'T27 desired state audited');
END $$;

DO $$
DECLARE r record; r2 record; doc text;
BEGIN
  PERFORM set_config('app.user_id', '', true);
  PERFORM set_config('app.tenant_id', '0e000000-0000-7000-8000-000000000001', true);
  SELECT * INTO r FROM core.provision_tenant('0e000000-0000-7000-8000-0000000c0001', 'tenant-e', 'مستأجر ه', '09127778888', 'مالک ه', 'C1', 'شرکت ه');
  PERFORM public.assert_true(r.created AND r.tenant_id = '0e000000-0000-7000-8000-000000000001', 'T27 provisioning creates the tenant (hk_app, system UoW)');
  SELECT * INTO r2 FROM core.provision_tenant('0e000000-0000-7000-8000-0000000c0001', 'tenant-e', 'مستأجر ه', '09127778888', 'مالک ه', 'C1', 'شرکت ه');
  PERFORM public.assert_true(NOT r2.created AND r2.owner_user_id = r.owner_user_id AND r2.company_id = r.company_id, 'T27 redelivered provisioning command is idempotent');
  PERFORM public.assert_true((SELECT status FROM core.tenant) = 'provisioning', 'T27 new tenant starts provisioning');
  PERFORM public.assert_true(EXISTS (SELECT 1 FROM core.tenant_membership m JOIN core.role_assignment ra ON ra.membership_id = m.id
                                       JOIN core.role ro ON ro.id = ra.role_id
                                      WHERE m.user_id = r.owner_user_id AND m.is_owner AND m.status = 'active' AND ro.template_code = 'owner'),
                             'T27 owner membership with the owner role');
  PERFORM public.assert_true(core.auth_resolve_login('phone', '09127778888') = r.owner_user_id, 'T27 owner logs in with the signed-up mobile');
  doc := jsonb_build_object('format', 'hkstate/1', 'tenant_id', '0e000000-0000-7000-8000-000000000001', 'version', 1, 'status', 'active')::text;
  PERFORM public.assert_true(core.apply_desired_state(doc, decode(repeat('ab', 64), 'hex'), 'k') = 'applied', 'T27 first desired state of a new tenant');
  PERFORM public.assert_true((SELECT status FROM core.tenant) = 'active', 'T27 provisioning -> active through the desired state');
  PERFORM public.expect_error('T27 provisioning only in the system unit of work',
    $q$SELECT set_config('app.user_id', '0a000000-0000-7000-8000-00000000a001', true); SELECT * FROM core.provision_tenant(gen_random_uuid(), 'tenant-f', 'f', '09120000000', 'f', 'C1', 'f')$q$,
    'HK_CORE_SYSTEM_ONLY');
END $$;

DO $$
DECLARE tpl uuid; tpo uuid;
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  PERFORM set_config('app.user_id', '0a000000-0000-7000-8000-00000000a001', true);
  INSERT INTO core.print_template (tenant_id, model_code, code, name, paper, source, base_def_code, created_by)
  VALUES ('0a000000-0000-7000-8000-000000000001', 'test.doc', 'inv-a5', 'فاکتور A5', 'a5', 'tenant', 'test.doc.basic', '0a000000-0000-7000-8000-00000000a001') RETURNING id INTO tpl;
  INSERT INTO core.print_template_version (tenant_id, template_id, version_no, body, body_sha256, created_by)
  VALUES ('0a000000-0000-7000-8000-000000000001', tpl, 1, '<p>{{ total }}</p>', sha256('x'), '0a000000-0000-7000-8000-00000000a001');
  PERFORM public.assert_true((SELECT body_sha256 = sha256(convert_to('<p>{{ total }}</p>', 'UTF8')) FROM core.print_template_version WHERE template_id = tpl),
                             'T27 template body hash computed by the DB');
  PERFORM public.expect_error('T27 template versions are gapless',
    format($q$INSERT INTO core.print_template_version (tenant_id, template_id, version_no, body, body_sha256) VALUES ('0a000000-0000-7000-8000-000000000001', %L, 3, 'x', sha256('x'))$q$, tpl), 'HK_PRINT_VERSION');
  PERFORM public.expect_error('T27 template versions are append-only',
    $q$UPDATE core.print_template_version SET body = 'x'$q$, '42501');
  PERFORM public.expect_error('T27 paper must be allowed by the print model',
    $q$INSERT INTO core.print_template (tenant_id, model_code, code, name, paper, source) VALUES ('0a000000-0000-7000-8000-000000000001', 'test.doc', 'lbl', 'برچسب', 'label', 'tenant')$q$, 'HK_PRINT_PAPER');
  INSERT INTO core.print_template (tenant_id, model_code, code, name, paper, source, base_def_code)
  VALUES ('0a000000-0000-7000-8000-000000000001', 'test.doc', 'inv-official', 'صورتحساب رسمی', 'a4', 'system', 'test.doc.official') RETURNING id INTO tpo;
  PERFORM public.expect_error('T27 official layout is versioned by the rules engine only',
    format($q$INSERT INTO core.print_template_version (tenant_id, template_id, version_no, body, body_sha256) VALUES ('0a000000-0000-7000-8000-000000000001', %L, 1, 'x', sha256('x'))$q$, tpo), 'HK_PRINT_OFFICIAL');
  PERFORM public.expect_error('T27 letterhead postal code is 10 digits',
    $q$INSERT INTO core.letterhead (tenant_id, company_id, address, postal_code) VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000000c1', 'تهران، خیابان آزادی', '123456789')$q$, '23514');
  INSERT INTO core.letterhead (tenant_id, company_id, address, postal_code, phone, registration_no)
  VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000000c1', 'تهران، خیابان آزادی', '1234567890', '02166000000', '12345');

  -- RV-AST-19: جدول ثبت قطعی در تراکنش دستیار درج نمی‌پذیرد
  INSERT INTO public.post_demo (tenant_id) VALUES ('0a000000-0000-7000-8000-000000000001');
  PERFORM set_config('app.actor_via', 'assistant', true);
  PERFORM public.expect_error('T27 posting table refuses inserts in an assistant transaction',
    $q$INSERT INTO public.post_demo (tenant_id) VALUES ('0a000000-0000-7000-8000-000000000001')$q$, 'HK_CORE_ACTOR_VIA');
  PERFORM set_config('app.actor_via', 'assistant_confirm', true);
  PERFORM public.expect_error('T27 posting table refuses inserts while materializing an assistant draft',
    $q$INSERT INTO public.post_demo (tenant_id) VALUES ('0a000000-0000-7000-8000-000000000001')$q$, 'HK_CORE_ACTOR_VIA');
  PERFORM set_config('app.actor_via', 'bogus', true);
  PERFORM public.expect_error('T27 unknown actor_via fails closed',
    $q$INSERT INTO public.post_demo (tenant_id) VALUES ('0a000000-0000-7000-8000-000000000001')$q$, 'HK_CORE_ACTOR_VIA');
  PERFORM set_config('app.actor_via', 'direct', true);
  INSERT INTO public.post_demo (tenant_id) VALUES ('0a000000-0000-7000-8000-000000000001');
  PERFORM set_config('app.actor_via', '', true);

  -- RV-ARCH-17: max_seen_at فقط جلو می‌رود
  PERFORM public.expect_error('T27 clock rollback guard',
    $q$UPDATE core.deployment_info SET max_seen_at = '2001-01-01'$q$, 'HK_CORE_CLOCK_ROLLBACK');
  PERFORM public.expect_error('T27 runtime changes only max_seen_at',
    $q$UPDATE core.deployment_info SET app_version = '2027.1.0'$q$, '42501');
  UPDATE core.deployment_info SET max_seen_at = now() + interval '1 second';
END $$;

-- ---------- T28: نشست — نسخهٔ security_epoch، کاربر غیرفعال، دستگاه گم‌شده (RV-CORE-02، RV-X4-05، RV-CORE-10) ----------
-- آخرین بلوک بخش ۲: دستگاه d0001 در این‌جا «گم‌شده» می‌شود.
DO $$
DECLARE svc uuid := '0a000000-0000-7000-8000-00000000a0f1'; n int;
BEGIN
  PERFORM set_config('app.tenant_id', '', true);
  PERFORM set_config('app.user_id', '0a000000-0000-7000-8000-00000000a002', true);
  INSERT INTO core.user_session (user_id, token_hash, active_tenant_id, client_kind, amr, idle_timeout_seconds, absolute_expires_at, security_epoch)
  VALUES ('0a000000-0000-7000-8000-00000000a002', sha256('t28-web'), '0a000000-0000-7000-8000-000000000001', 'web', '{pwd}', 1800, now() + interval '8 hours', 99);
  PERFORM public.assert_true((SELECT security_epoch FROM core.user_session WHERE token_hash = sha256('t28-web'))
                             = (SELECT security_epoch FROM core.app_user WHERE id = '0a000000-0000-7000-8000-00000000a002'), 'T28 session epoch is snapshotted by the DB');
  PERFORM public.assert_true(EXISTS (SELECT 1 FROM core.auth_resolve_token('session', sha256('t28-web'))), 'T28 session resolves');
  UPDATE core.app_user SET security_epoch = security_epoch + 1 WHERE id = '0a000000-0000-7000-8000-00000000a002';   -- خروج از همه‌جا
  PERFORM public.assert_true(NOT EXISTS (SELECT 1 FROM core.auth_resolve_token('session', sha256('t28-web'))), 'T28 epoch bump kills old sessions');
  INSERT INTO core.user_session (user_id, token_hash, active_tenant_id, client_kind, amr, idle_timeout_seconds, absolute_expires_at)
  VALUES ('0a000000-0000-7000-8000-00000000a002', sha256('t28-web2'), '0a000000-0000-7000-8000-000000000001', 'web', '{pwd}', 1800, now() + interval '8 hours');
  PERFORM public.assert_true(EXISTS (SELECT 1 FROM core.auth_resolve_token('session', sha256('t28-web2'))), 'T28 a new session after the bump resolves');
  PERFORM public.expect_error('T28 session lifetime only shrinks',
    $q$UPDATE core.user_session SET absolute_expires_at = absolute_expires_at + interval '1 day' WHERE token_hash = sha256('t28-web2')$q$, 'HK_CORE_IMMUTABLE_FIELD');
  -- نشست PIN صندوق روی دستگاه فعال (ورود PIN در زمینهٔ مستأجر دستگاه)
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  INSERT INTO core.user_session (user_id, token_hash, active_tenant_id, device_id, client_kind, amr, idle_timeout_seconds, absolute_expires_at)
  VALUES ('0a000000-0000-7000-8000-00000000a002', sha256('t28-pin'), '0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000d0001',
          'pos', '{device_key,pin}', 600, now() + interval '12 hours');
  PERFORM public.assert_true(EXISTS (SELECT 1 FROM core.auth_resolve_token('session', sha256('t28-pin'))), 'T28 PIN session resolves');
  -- مدیر مستأجر به نشست کاربر دیگر دسترسی ندارد (RLS کاربرمحور)؛ گم شدن دستگاه نشست‌ها و توکن‌هایش را باطل می‌کند
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  PERFORM set_config('app.user_id', '0a000000-0000-7000-8000-00000000a001', true);
  UPDATE core.user_session SET revoked_at = now(), revoke_reason = 'x' WHERE device_id = '0a000000-0000-7000-8000-0000000d0001';
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM public.assert_true(n = 0, 'T28 admin cannot touch another user session directly');
  UPDATE core.device SET status = 'lost', revoked_at = now(), revoke_reason = 'دزدیده شد' WHERE id = '0a000000-0000-7000-8000-0000000d0001';
  PERFORM public.assert_true(NOT EXISTS (SELECT 1 FROM core.auth_resolve_token('session', sha256('t28-pin'))), 'T28 lost device kills its PIN sessions');
  PERFORM public.assert_true(NOT EXISTS (SELECT 1 FROM core.auth_resolve_token('device', sha256('devtok-1'))), 'T28 lost device kills its device tokens');
  PERFORM public.expect_error('T28 lost device cannot come back',
    $q$UPDATE core.device SET status = 'active' WHERE id = '0a000000-0000-7000-8000-0000000d0001'$q$, 'HK_CORE_INVALID_TRANSITION');
  PERFORM set_config('app.tenant_id', '', true);
  PERFORM set_config('app.user_id', '0a000000-0000-7000-8000-00000000a002', true);
  PERFORM public.assert_true((SELECT revoked_at IS NOT NULL AND revoke_reason = 'device_lost' FROM core.user_session WHERE token_hash = sha256('t28-pin')),
                             'T28 session revoked with the device reason');
  PERFORM public.expect_error('T28 revoked session is final',
    $q$UPDATE core.user_session SET revoked_at = NULL, revoke_reason = NULL WHERE token_hash = sha256('t28-pin')$q$, 'HK_CORE_IMMUTABLE_FIELD');
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  PERFORM public.expect_error('T28 no PIN session on a lost device',
    $q$INSERT INTO core.user_session (user_id, token_hash, active_tenant_id, device_id, client_kind, amr, idle_timeout_seconds, absolute_expires_at)
       VALUES ('0a000000-0000-7000-8000-00000000a002', sha256('t28-pin2'), '0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000d0001', 'pos', '{device_key,pin}', 600, now() + interval '8 hours')$q$,
    'HK_CORE_DEVICE_INACTIVE');
  -- حساب غیرفعال: نشست‌هایش حل نمی‌شوند (حساب سرویس را مدیر مستأجر خانه غیرفعال می‌کند)
  PERFORM set_config('app.user_id', svc::text, true);
  INSERT INTO core.user_session (user_id, token_hash, active_tenant_id, client_kind, amr, idle_timeout_seconds, absolute_expires_at)
  VALUES (svc, sha256('t28-svc'), '0a000000-0000-7000-8000-000000000001', 'web', '{pwd}', 600, now() + interval '1 hour');
  PERFORM public.assert_true(EXISTS (SELECT 1 FROM core.auth_resolve_token('session', sha256('t28-svc'))), 'T28 service session resolves');
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  PERFORM set_config('app.user_id', '0a000000-0000-7000-8000-00000000a001', true);
  UPDATE core.app_user SET status = 'disabled' WHERE id = svc;
  PERFORM public.assert_true(NOT EXISTS (SELECT 1 FROM core.auth_resolve_token('session', sha256('t28-svc'))), 'T28 disabled account sessions die');
  PERFORM public.expect_error('T28 disabled account cannot open a session',
    format($q$SELECT set_config('app.user_id', %L, true);
              INSERT INTO core.user_session (user_id, token_hash, client_kind, amr, idle_timeout_seconds, absolute_expires_at)
              VALUES (%L, sha256('t28-svc2'), 'web', '{pwd}', 600, now() + interval '1 hour')$q$, svc, svc), 'HK_CORE_USER_INACTIVE');
  -- ابطال کلید API و رضایت پشتیبانی پایانی است (RV-CORE-10)
  UPDATE core.api_key SET revoked_at = now(), revoked_by = '0a000000-0000-7000-8000-00000000a001' WHERE prefix = 'hk_live_abcdefghijklmnop';
  PERFORM public.expect_error('T28 api key revocation is final',
    $q$UPDATE core.api_key SET revoked_at = NULL, revoked_by = NULL WHERE prefix = 'hk_live_abcdefghijklmnop'$q$, 'HK_CORE_IMMUTABLE_FIELD');
  PERFORM public.assert_true(NOT EXISTS (SELECT 1 FROM core.auth_resolve_api_key('hk_live_abcdefghijklmnop')), 'T28 revoked api key does not resolve');
  PERFORM public.expect_error('T28 support grant revocation is final',
    $q$UPDATE core.support_access_grant SET revoked_at = NULL, revoked_by = NULL WHERE revoked_at IS NOT NULL$q$, 'HK_CORE_IMMUTABLE_FIELD');
  UPDATE core.support_access_grant SET expires_at = now() + interval '10 minutes' WHERE access_mode = 'read_write' AND revoked_at IS NULL;
  PERFORM public.assert_true((SELECT bool_and(expires_at <= now() + interval '10 minutes') FROM core.impersonation_session WHERE ended_at IS NULL),
                             'T28 shortening a grant shortens its open sessions');
  -- پیوست آلوده پیوند نمی‌گیرد
  INSERT INTO core.attachment (tenant_id, id, storage_backend, bucket, object_key, file_name, encryption_key_ref)
  VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000a7701', 's3', 'hk',
          't/0a000000-0000-7000-8000-000000000001/' || to_char(now() AT TIME ZONE 'UTC', 'YYYY/MM') || '/0a000000-0000-7000-8000-0000000a7701', 'eicar.pdf', 'dek/1');
  UPDATE core.attachment SET status = 'uploaded', size_bytes = 68, sha256 = sha256('eicar'), uploaded_at = now() WHERE id = '0a000000-0000-7000-8000-0000000a7701';
  UPDATE core.attachment SET status = 'scanning' WHERE id = '0a000000-0000-7000-8000-0000000a7701';
  UPDATE core.attachment SET status = 'infected', scanned_at = now(), av_engine = 'clamav', av_result = 'Eicar-Test-Signature'
   WHERE id = '0a000000-0000-7000-8000-0000000a7701';
  PERFORM public.expect_error('T28 infected attachment cannot be linked',
    $q$INSERT INTO core.attachment_link (tenant_id, attachment_id, owner_module, owner_type, owner_id)
       VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000a7701', 'sales', 'sales.invoice', gen_random_uuid())$q$, 'HK_ATT_STATE');
END $$;

-- ---------- T29: پوشش جهش (RV-CORE-10) — هر نگهبان دسترس‌پذیر با کد دقیق خودش ----------
DO $$
DECLARE pol uuid; tpl uuid; eb uuid; g uuid; c core.audit_checkpoint;
BEGIN
  PERFORM set_config('app.tenant_id', '', true);
  PERFORM set_config('app.user_id', '0d000000-0000-7000-8000-00000000d0a1', true);
  PERFORM public.expect_error('T29 a new user starts active',
    $q$INSERT INTO core.app_user (id, display_name, status) VALUES ('0d000000-0000-7000-8000-00000000d0a1', 'کاربر', 'disabled')$q$, 'HK_CORE_USER_INSERT');
  PERFORM set_config('app.user_id', '0c000000-0000-7000-8000-00000000c001', true);
  PERFORM public.expect_error('T29 verified_at cannot be rewritten',
    $q$UPDATE core.user_login_identifier SET verified_at = verified_at - interval '1 day' WHERE value = '09120000009'$q$, 'HK_CORE_IMMUTABLE_FIELD');
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  PERFORM set_config('app.user_id', '0a000000-0000-7000-8000-00000000a001', true);
  PERFORM public.expect_error('T29 only the user changes their own mfa_required',
    $q$UPDATE core.app_user SET mfa_required = true WHERE id = '0a000000-0000-7000-8000-00000000a0f1'$q$, 'HK_CORE_IMMUTABLE_FIELD');
  PERFORM public.expect_error('T29 membership identity immutable',
    $q$UPDATE core.tenant_membership SET user_id = '0b000000-0000-7000-8000-00000000b001' WHERE id = '0a000000-0000-7000-8000-0000000e0002'$q$, 'HK_CORE_IMMUTABLE_FIELD');
  PERFORM public.expect_error('T29 member_invite needs a tenant and a user',
    $q$SELECT set_config('app.tenant_id', '', true); SELECT core.member_invite('phone', '09125550001', 'x')$q$, 'HK_TENANT_CONTEXT_MISSING');
  -- گردش تأیید
  INSERT INTO core.approval_policy (tenant_id, subject_type, name) VALUES ('0a000000-0000-7000-8000-000000000001', 'sales.return', 'بی‌گام') RETURNING id INTO pol;
  PERFORM public.expect_error('T29 a policy without steps cannot open a request',
    format($q$INSERT INTO core.approval_request (tenant_id, company_id, subject_type, subject_id, requested_by, policy_id, policy_version, steps_snapshot, enforce_sod, distinct_approvers)
              VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000000c1', 'sales.return', gen_random_uuid(), '0a000000-0000-7000-8000-00000000a002', %L, 1, '[]', true, true)$q$, pol), 'HK_APPROVAL_INVALID');
  INSERT INTO core.approval_policy_step (tenant_id, policy_id, step_no, approver_kind, role_id)
  VALUES ('0a000000-0000-7000-8000-000000000001', pol, 1, 'role', '0a000000-0000-7000-8000-0000000f0002');
  PERFORM public.expect_error('T29 a new request starts pending at step 1',
    format($q$INSERT INTO core.approval_request (tenant_id, company_id, subject_type, subject_id, requested_by, policy_id, policy_version, steps_snapshot, enforce_sod, distinct_approvers, status, decided_at)
              VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000000c1', 'sales.return', gen_random_uuid(), '0a000000-0000-7000-8000-00000000a002', %L, 1, '[]', true, true, 'approved', now())$q$, pol), 'HK_APPROVAL_INVALID');
  PERFORM public.expect_error('T29 decision on an unknown request',
    $q$INSERT INTO core.approval_decision (tenant_id, request_id, step_no, decided_by, decision) VALUES ('0a000000-0000-7000-8000-000000000001', gen_random_uuid(), 1, '0a000000-0000-7000-8000-00000000a003', 'approve')$q$, 'HK_APPROVAL_NOT_FOUND');
  -- شماره‌گذاری: شاخه‌های ورودی
  PERFORM public.expect_error('T29 unknown series', $q$SELECT core.number_next(gen_random_uuid(), 'jy:1405', 'X{seq}', 'ledger.journal', gen_random_uuid())$q$, 'HK_NUM_SERIES_NOT_FOUND');
  PERFORM public.expect_error('T29 unknown series (external)', $q$SELECT core.number_record_external(gen_random_uuid(), 'all', 1, 'X', 'pos.sale', gen_random_uuid(), '0a000000-0000-7000-8000-0000000d0001')$q$, 'HK_NUM_SERIES_NOT_FOUND');
  PERFORM public.expect_error('T29 unknown series (void)', $q$SELECT core.number_void(gen_random_uuid(), 'all', 1, 'reason here')$q$, 'HK_NUM_SERIES_NOT_FOUND');
  PERFORM public.expect_error('T29 unknown series (reserve)', $q$SELECT core.number_reserve_range(gen_random_uuid(), 'all', '0a000000-0000-7000-8000-0000000d0001', 5)$q$, 'HK_NUM_SERIES_NOT_FOUND');
  PERFORM public.expect_error('T29 reservation size bounds', $q$SELECT core.number_reserve_range('0a000000-0000-7000-8000-000000050002', 'all', '0a000000-0000-7000-8000-0000000d0001', 0)$q$, 'HK_NUM_RANGE_SIZE');
  PERFORM public.expect_error('T29 reserve only on a range series', $q$SELECT core.number_reserve_range('0a000000-0000-7000-8000-000000050001', 'jy:1405', '0a000000-0000-7000-8000-0000000d0001', 5)$q$, 'HK_NUM_NOT_RANGE_ALLOCATED');
  PERFORM public.expect_error('T29 server series takes no external numbers',
    $q$SELECT core.number_record_external('0a000000-0000-7000-8000-000000050001', 'jy:1405', 1, 'X', 'ledger.journal', gen_random_uuid(), '0a000000-0000-7000-8000-0000000d0001')$q$, 'HK_NUM_SERVER_ALLOCATED');
  PERFORM public.expect_error('T29 external number doc type must match',
    $q$SELECT core.number_record_external('0a000000-0000-7000-8000-000000050003', 'jy:1405', 51, 'X', 'sales.invoice', gen_random_uuid(), '0a000000-0000-7000-8000-0000000d0001')$q$, 'HK_NUM_DOC_TYPE');
  PERFORM public.expect_error('T29 void needs a reason', $q$SELECT core.number_void('0a000000-0000-7000-8000-000000050003', 'jy:1405', 60, 'x')$q$, 'HK_NUM_VOID_REASON');
  PERFORM public.expect_error('T29 void range bounds', $q$SELECT core.number_void_range('0a000000-0000-7000-8000-000000050003', 'jy:1405', 60, 50, 'reversed range')$q$, 'HK_NUM_RANGE_SIZE');
  PERFORM public.expect_error('T29 closing needs a reason',
    $q$SELECT core.number_close_reservation((SELECT id FROM core.number_reservation WHERE status = 'active' LIMIT 1), 'x')$q$, 'HK_NUM_VOID_REASON');
  UPDATE core.number_series SET is_active = false WHERE id = '0a000000-0000-7000-8000-000000050001';
  PERFORM public.expect_error('T29 inactive series', $q$SELECT core.number_next('0a000000-0000-7000-8000-000000050001', 'jy:1405', 'JV-1405-{seq:6}', 'ledger.journal', gen_random_uuid())$q$, 'HK_NUM_SERIES_INACTIVE');
  UPDATE core.number_series SET is_active = true WHERE id = '0a000000-0000-7000-8000-000000050001';
  -- ممیزی بدون زمینه و آرگومان
  PERFORM public.expect_error('T29 audit_verify starts at seq 1', $q$SELECT * FROM core.audit_verify(0::smallint, 0)$q$, 'HK_AUDIT_ARGS');
  PERFORM public.expect_error('T29 audit_verify needs a tenant', $q$SELECT set_config('app.tenant_id', '', true); SELECT * FROM core.audit_verify()$q$, 'HK_TENANT_CONTEXT_MISSING');
  PERFORM public.expect_error('T29 checkpoint needs a tenant', $q$SELECT set_config('app.tenant_id', '', true); SELECT core.audit_checkpoint_create()$q$, 'HK_TENANT_CONTEXT_MISSING');
  -- تنظیمات، فیلد سفارشی
  PERFORM public.expect_error('T29 setting scope immutable',
    $q$UPDATE core.setting_value SET user_id = '0a000000-0000-7000-8000-00000000a002' WHERE setting_key = 'core.locale' AND level = 'user'$q$, 'HK_CORE_IMMUTABLE_FIELD');
  PERFORM public.expect_error('T29 reindex of an unknown entity', $q$SELECT core.custom_field_reindex('nope.nothing')$q$, 'HK_CF_UNKNOWN_ENTITY');
  PERFORM public.expect_error('T29 reindex needs a tenant', $q$SELECT set_config('app.tenant_id', '', true); SELECT core.custom_field_reindex('test.cf_demo')$q$, 'HK_TENANT_CONTEXT_MISSING');
  -- توقیف، درخواست دادهٔ شخصی، مانع صدور
  PERFORM public.expect_error('T29 a legal hold starts active',
    $q$INSERT INTO core.legal_hold (tenant_id, scope, reason, placed_by, released_at, released_by) VALUES ('0a000000-0000-7000-8000-000000000001', 'tenant', 'رسیدگی مالیاتی', '0a000000-0000-7000-8000-00000000a001', now(), '0a000000-0000-7000-8000-00000000a001')$q$, 'HK_RET_HOLD');
  INSERT INTO core.legal_hold (tenant_id, scope, resource_type, resource_id, reason, placed_by)
  VALUES ('0a000000-0000-7000-8000-000000000001', 'resource', 'sales.invoice', gen_random_uuid(), 'شکایت مشتری', '0a000000-0000-7000-8000-00000000a001');
  PERFORM public.expect_error('T29 hold release time is not in the future (fresh hold)',
    $q$UPDATE core.legal_hold SET released_at = now() + interval '1 day', released_by = '0a000000-0000-7000-8000-00000000a001' WHERE released_at IS NULL$q$, 'HK_RET_HOLD');
  INSERT INTO core.data_subject_request (tenant_id, subject_type, subject_id, request_type, requested_via, requested_by)
  VALUES ('0a000000-0000-7000-8000-000000000001', 'party', '0a000000-0000-7000-8000-0000000d5a01', 'access', 'tenant_admin', '0a000000-0000-7000-8000-00000000a001');
  UPDATE core.data_subject_request SET status = 'in_review' WHERE subject_id = '0a000000-0000-7000-8000-0000000d5a01';
  UPDATE core.data_subject_request SET status = 'approved', approved_by = '0a000000-0000-7000-8000-00000000a003' WHERE subject_id = '0a000000-0000-7000-8000-0000000d5a01';
  PERFORM public.expect_error('T29 DSR approver immutable',
    $q$UPDATE core.data_subject_request SET approved_by = '0c000000-0000-7000-8000-00000000c001' WHERE subject_id = '0a000000-0000-7000-8000-0000000d5a01'$q$, 'HK_CORE_IMMUTABLE_FIELD');
  PERFORM public.expect_error('T29 DSR identity immutable',
    $q$UPDATE core.data_subject_request SET subject_id = gen_random_uuid()$q$, 'HK_CORE_IMMUTABLE_FIELD');
  INSERT INTO core.export_blocker (tenant_id, module, reason_code) VALUES ('0a000000-0000-7000-8000-000000000001', 'migration', 'migration.committing') RETURNING id INTO eb;
  PERFORM public.expect_error('T29 export blocked while a module holds a blocker',
    $q$INSERT INTO core.tenant_export (tenant_id, purpose, requested_by) VALUES ('0a000000-0000-7000-8000-000000000001', 'backup', '0a000000-0000-7000-8000-00000000a001')$q$, 'HK_EXPORT_BLOCKED');
  UPDATE core.export_blocker SET released_at = now() WHERE id = eb;
  PERFORM public.expect_error('T29 an export blocker is released once',
    format($q$UPDATE core.export_blocker SET released_at = now() + interval '1 second' WHERE id = %L$q$, eb), 'HK_CORE_IMMUTABLE_FIELD');
  INSERT INTO core.tenant_export (tenant_id, purpose, requested_by) VALUES ('0a000000-0000-7000-8000-000000000001', 'backup', '0a000000-0000-7000-8000-00000000a001');
  -- قالب چاپ
  SELECT id INTO tpl FROM core.print_template WHERE code = 'inv-a5';
  PERFORM public.expect_error('T29 template paper immutable', format($q$UPDATE core.print_template SET paper = 'a4' WHERE id = %L$q$, tpl), 'HK_CORE_IMMUTABLE_FIELD');
  PERFORM public.expect_error('T29 current version must exist', format($q$UPDATE core.print_template SET current_version = 7 WHERE id = %L$q$, tpl), 'HK_PRINT_VERSION');
  PERFORM public.expect_error('T29 base template of the same model',
    $q$INSERT INTO core.print_template (tenant_id, model_code, code, name, paper, source, base_def_code) VALUES ('0a000000-0000-7000-8000-000000000001', 'test.doc', 'x2', 'x', 'a5', 'tenant', 'nope.def')$q$, 'HK_PRINT_MODEL');
  -- ستون‌های منجمد (06:CR-T12)
  INSERT INTO public.post_demo (tenant_id, note) VALUES ('0a000000-0000-7000-8000-000000000001', 'اول');
  PERFORM public.expect_error('T29 frozen column', $q$UPDATE public.post_demo SET note = 'دوم' WHERE note = 'اول'$q$, 'HK_CORE_IMMUTABLE_FIELD');
  -- job و تحویل
  PERFORM public.expect_error('T29 delivery identity immutable',
    $q$UPDATE core.outbox_delivery SET aggregate_id = gen_random_uuid() WHERE status = 'pending'$q$, 'HK_CORE_IMMUTABLE_FIELD');
  -- ورود به‌جای کاربر
  SELECT id INTO g FROM core.support_access_grant WHERE access_mode = 'read_write' AND revoked_at IS NULL LIMIT 1;
  PERFORM public.expect_error('T29 impersonation session cannot start ended',
    format($q$INSERT INTO core.impersonation_session (tenant_id, grant_id, staff_id, staff_display_name, assertion_jti, token_hash, reason, ticket_ref, mode, expires_at, ended_at, end_reason)
              VALUES ('0a000000-0000-7000-8000-000000000001', %L, gen_random_uuid(), 'x', 'jti-29', sha256('jti-29'), 'بررسی خطای گزارش تراز', 'T-29', 'read_only', now() + interval '5 minutes', now(), 'staff_ended')$q$, g), 'HK_IMP_INVALID');
  -- حالت مطلوب و provisioning (UoW سیستمی: بدون app.user_id)
  PERFORM set_config('app.user_id', '', true);
  PERFORM public.expect_error('T29 desired state cannot target provisioning',
    $q$SELECT core.apply_desired_state(jsonb_build_object('format','hkstate/1','tenant_id','0a000000-0000-7000-8000-000000000001','version',50,'status','provisioning')::text, decode(repeat('ab', 64), 'hex'), 'k')$q$,
    'HK_CORE_INVALID_TRANSITION');
  PERFORM public.expect_error('T29 desired state needs a tenant', $q$SELECT set_config('app.tenant_id', '', true); SELECT core.apply_desired_state('{}', decode(repeat('ab', 64), 'hex'), 'k')$q$, 'HK_TENANT_CONTEXT_MISSING');
  PERFORM public.expect_error('T29 provisioning an existing tenant with a new command',
    $q$SELECT set_config('app.user_id', '', true); SELECT * FROM core.provision_tenant(gen_random_uuid(), 'tenant-a2', 'a', '09120000001', 'a', 'C9', 'a')$q$, 'HK_CORE_TENANT_EXISTS');
  -- زمان‌بند
  PERFORM public.expect_error('T29 last_fired_at only moves forward',
    $q$UPDATE core.job_schedule SET last_fired_at = '2001-01-01' WHERE code = 'test.month_end'$q$, 'HK_SCHEDULE_NEXT');
  PERFORM public.expect_error('T29 schedule identity immutable',
    $q$UPDATE core.job_schedule SET id = gen_random_uuid() WHERE code = 'test.month_end'$q$, 'HK_CORE_IMMUTABLE_FIELD');
END $$;
-- نقش‌های مالک توابع و dispatcher (نگهبان‌های لایهٔ دوم)
DO $$
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  SET LOCAL ROLE hk_audit_writer;
  PERFORM public.expect_error('T29 audit chain head advances by one only',
    $q$UPDATE core.audit_chain_head SET last_seq = last_seq + 5$q$, 'HK_AUDIT_HEAD');
  SET LOCAL ROLE hk_core_definer;
  PERFORM public.expect_error('T29 counter starts at the series start value',
    $q$INSERT INTO core.number_counter (tenant_id, series_id, period_key, next_value) VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-000000050001', 'jy:1407', 7)$q$, 'HK_NUM_COUNTER');
  PERFORM public.expect_error('T29 desired-state version only moves forward',
    $q$UPDATE core.tenant_desired_state SET version = 1$q$, 'HK_CORE_DESIRED_STATE');
  PERFORM public.expect_error('T29 desired-state hash must match the document',
    $q$UPDATE core.tenant_desired_state SET version = version + 1, doc_sha256 = sha256('x')$q$, 'HK_CORE_DESIRED_STATE');
  SET LOCAL ROLE hk_app;
  PERFORM public.expect_error('T29 provisioning log transitions',
    $q$SELECT set_config('app.tenant_id', '0e000000-0000-7000-8000-000000000001', true); UPDATE core.tenant_provisioning SET status = 'completed'$q$, 'HK_CORE_INVALID_TRANSITION');
  SET LOCAL ROLE hk_dispatcher;
  PERFORM set_config('app.tenant_id', '', true);
  PERFORM public.expect_error('T29 job claim arguments', $q$SELECT * FROM core.job_claim(ARRAY['default'], 'w', 0)$q$, 'HK_JOB_ARGS');
  PERFORM public.expect_error('T29 outbox claim arguments', $q$SELECT * FROM core.outbox_claim(ARRAY['test.wild'], 'w', 0)$q$, 'HK_OUTBOX_ARGS');
  PERFORM public.expect_error('T29 unknown schedule', $q$SELECT core.schedule_fire(gen_random_uuid(), now(), now() + interval '1 day')$q$, 'HK_SCHEDULE_NOT_FOUND');
  SET LOCAL ROLE hk_app;
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  INSERT INTO core.job (tenant_id, queue, kind) VALUES ('0a000000-0000-7000-8000-000000000001', 'sync', 'test.lock');
  SET LOCAL ROLE hk_dispatcher;
  PERFORM set_config('app.tenant_id', '', true);
  PERFORM count(*) FROM core.job_claim(ARRAY['sync'], 'w-lock', 5, 60, 5);
  PERFORM public.expect_error('T29 running job lock cannot be reassigned',
    $q$UPDATE core.job SET lock_token = gen_random_uuid() WHERE kind = 'test.lock' AND status = 'running'$q$, 'HK_JOB_STATE');
  SET LOCAL ROLE hk_app;
END $$;

-- ---------- T17: بردارهای مشترک نرمال‌سازی (همان فایل آزمون پایتون) ----------
SELECT public.assert_true(count(*) = 0, 'T17 fa-norm-v1 vectors (SQL)')
  FROM jsonb_array_elements((:'fa_vectors')::jsonb -> 'vectors') v
 WHERE core.fa_normalize_text(v->>'input')  IS DISTINCT FROM v->>'text'
    OR core.fa_normalize_ident(v->>'input') IS DISTINCT FROM v->>'ident'
    OR core.fa_search_key(v->>'input')      IS DISTINCT FROM v->>'search' \gset
SELECT public.assert_true(jsonb_array_length((:'fa_vectors')::jsonb -> 'vectors') >= 15, 'T17 vectors loaded') \gset
SELECT public.assert_true(core.fa_search_key(core.fa_search_key('ي ك ۱')) = core.fa_search_key('ي ك ۱'), 'T17 idempotent') \gset

-- ---------- T18: جداسازی خواندن در همهٔ جدول‌های مستأجری (پس از ساخت داده در هر دو مستأجر) ----------
DO $$
DECLARE t record; n bigint; total_b bigint := 0;
BEGIN
  -- با کاربر چندمستأجری در زمینه (هر درخواست احرازشده؛ RV-CORE-15)
  PERFORM set_config('app.user_id', '0c000000-0000-7000-8000-00000000c001', true);
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  FOR t IN SELECT c.oid::regclass AS rel FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
             JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
            WHERE ns.nspname IN ('core','public') AND c.relkind = 'r'
  LOOP
    EXECUTE format('SELECT count(*) FROM %s WHERE tenant_id <> %L', t.rel, '0a000000-0000-7000-8000-000000000001') INTO n;
    IF n <> 0 THEN RAISE EXCEPTION 'TEST FAILED [T18]: % shows % rows of another tenant', t.rel, n; END IF;
  END LOOP;
  PERFORM set_config('app.tenant_id', '0b000000-0000-7000-8000-000000000001', true);
  FOR t IN SELECT c.oid::regclass AS rel FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
             JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
            WHERE ns.nspname IN ('core','public') AND c.relkind = 'r'
  LOOP
    EXECUTE format('SELECT count(*) FROM %s WHERE tenant_id <> %L', t.rel, '0b000000-0000-7000-8000-000000000001') INTO n;
    IF n <> 0 THEN RAISE EXCEPTION 'TEST FAILED [T18]: % shows % rows of another tenant', t.rel, n; END IF;
    EXECUTE format('SELECT count(*) FROM %s', t.rel) INTO n;
    total_b := total_b + n;
  END LOOP;
  PERFORM public.assert_true(total_b > 10, 'T18 tenant B sees its own rows');
END $$;

-- ---------- T19: نقش فقط‌خواندنی ستون‌های راز را نمی‌بیند ----------
RESET ROLE;
SET ROLE hk_readonly;
DO $$
BEGIN
  PERFORM set_config('app.user_id', '0c000000-0000-7000-8000-00000000c001', true);
  PERFORM public.assert_true((SELECT count(*) FROM (SELECT user_id, failed_count FROM core.user_credential) x) = 1, 'T19 readonly sees non-secret columns');
  PERFORM public.expect_error('T19 readonly cannot read password hash', $q$SELECT password_hash FROM core.user_credential$q$, '42501');
  PERFORM public.expect_error('T19 readonly cannot read api key hash', $q$SELECT secret_hash FROM core.api_key$q$, '42501');
  PERFORM public.expect_error('T19 readonly cannot read session token hash', $q$SELECT token_hash FROM core.user_session$q$, '42501');
  PERFORM public.expect_error('T19 readonly cannot read webhook secret', $q$SELECT secret_sealed FROM core.webhook_endpoint$q$, '42501');
  PERFORM public.expect_error('T19 readonly cannot write', $q$UPDATE core.app_user SET locale = 'en-US'$q$, '42501');
  -- RV-CORE-03: بدنهٔ بازپخش idempotency و پارامتر اعلان راز ندارند و بدنهٔ بازپخش برای پشتیبانی خوانا نیست
  PERFORM public.expect_error('T19 readonly cannot read idempotency replay body', $q$SELECT response_body FROM core.idempotency_key$q$, '42501');
  PERFORM public.expect_error('T19 readonly cannot read impersonation token hash', $q$SELECT token_hash FROM core.impersonation_session$q$, '42501');
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  PERFORM public.assert_true((SELECT count(*) FROM (SELECT idem_key, response_status FROM core.idempotency_key) x) >= 1, 'T19 readonly reads idempotency metadata');
END $$;
RESET ROLE;
-- dispatcher: فقط ستون‌های لازم صف و پاک‌سازی (RV-ARCH-09، RV-CORE-03)
SET ROLE hk_dispatcher;
DO $$
BEGIN
  PERFORM public.expect_error('T19 dispatcher cannot read webhook endpoints', $q$SELECT secret_sealed FROM core.webhook_endpoint$q$, '42501');
  PERFORM public.expect_error('T19 dispatcher cannot read replay bodies', $q$SELECT response_body FROM core.idempotency_key$q$, '42501');
  PERFORM public.expect_error('T19 dispatcher cannot read event payloads', $q$SELECT payload FROM core.outbox_event$q$, '42501');
  PERFORM public.expect_error('T19 dispatcher cannot read business tables', $q$SELECT count(*) FROM core.role$q$, '42501');
  PERFORM public.expect_error('T19 dispatcher cannot change tenant status', $q$UPDATE core.tenant SET status = 'active'$q$, '42501');
END $$;
RESET ROLE;
SELECT public.assert_true((SELECT secret_columns @> '{token_hash}' FROM core.export_table_registry
                            WHERE schema_name = 'core' AND table_name = 'impersonation_session'), 'T19 impersonation token hash is a secret column (RV-IT2-12)') \gset
SELECT public.assert_true((SELECT secret_columns @> '{response_body}' FROM core.export_table_registry
                            WHERE schema_name = 'core' AND table_name = 'idempotency_key'), 'T19 replay body is a secret column') \gset
SELECT public.assert_true(NOT has_column_privilege('hk_app', 'core.tenant', 'status', 'UPDATE')
                          AND NOT has_column_privilege('hk_app', 'core.tenant', 'slug', 'UPDATE')
                          AND NOT has_column_privilege('hk_app', 'core.tenant', 'deployment', 'UPDATE'), 'T19 hk_app cannot update tenant control columns (R-GRANT)') \gset

-- =====================================================================
-- بخش ۳: کشف دست‌کاری (postgres دست‌کاری می‌کند، hk_app راستی‌آزمایی می‌کند) — ROLLBACK
-- =====================================================================
BEGIN;
ALTER TABLE core.audit_log DISABLE TRIGGER trg_immutable;
UPDATE core.audit_log SET reason = 'tampered' WHERE tenant_id = :'A' AND seq = 2;
DELETE FROM core.audit_log WHERE tenant_id = :'B' AND seq = 1;
ALTER TABLE core.audit_log ENABLE TRIGGER trg_immutable;
SET LOCAL ROLE hk_app;
SELECT set_config('app.tenant_id', :'A', true) \gset
SELECT public.assert_true((SELECT array_agg(problem ORDER BY problem) FROM core.audit_verify() WHERE seq = 2) = ARRAY['row_hash_mismatch'],
                          'T20 modified audit row detected') \gset
SELECT public.assert_true((SELECT count(*) FROM core.audit_verify() WHERE seq <> 2) = 0, 'T20 other rows still verify') \gset
SELECT set_config('app.tenant_id', :'B', true) \gset
SELECT public.assert_true((SELECT count(*) FROM core.audit_verify() WHERE problem = 'head_mismatch') = 1, 'T20 deleted tail detected via head') \gset
ROLLBACK;

-- RV-CORE-09: بازنویسی کل زنجیره با hashهای از نو حساب‌شده در راستی‌آزمایی افزایشی روزانه از راه checkpoint آشکار است
BEGIN;
ALTER TABLE core.audit_log DISABLE TRIGGER trg_immutable;
ALTER TABLE core.audit_chain_head DISABLE TRIGGER trg_guard;
UPDATE core.audit_log SET reason = 'rewritten' WHERE tenant_id = :'A' AND seq = 1;
DO $$
DECLARE r core.audit_log; prev bytea := core.audit_genesis_hash('0a000000-0000-7000-8000-000000000001', 0::smallint); h bytea;
BEGIN
  FOR r IN SELECT * FROM core.audit_log WHERE tenant_id = '0a000000-0000-7000-8000-000000000001' AND chain_no = 0 ORDER BY seq LOOP
    r.prev_hash := prev;
    h := sha256(prev || convert_to(core.audit_canonical(r), 'UTF8'));
    UPDATE core.audit_log SET prev_hash = prev, row_hash = h WHERE tenant_id = r.tenant_id AND id = r.id;
    prev := h;
  END LOOP;
  UPDATE core.audit_chain_head SET last_hash = prev WHERE tenant_id = '0a000000-0000-7000-8000-000000000001' AND chain_no = 0;
END $$;
ALTER TABLE core.audit_log ENABLE TRIGGER trg_immutable;
ALTER TABLE core.audit_chain_head ENABLE TRIGGER trg_guard;
SET LOCAL ROLE hk_app;
SELECT set_config('app.tenant_id', :'A', true) \gset
SELECT public.assert_true(NOT EXISTS (SELECT 1 FROM core.audit_verify() WHERE problem <> 'checkpoint_mismatch'),
                          'T20 a fully rewritten chain has consistent hashes (only checkpoints disagree)') \gset
SELECT public.assert_true(EXISTS (SELECT 1 FROM core.audit_verify(0::smallint,
                                   (SELECT max(seq) FROM core.audit_checkpoint WHERE result = 'ok') + 1) WHERE problem = 'checkpoint_mismatch'),
                          'T20 daily incremental verify detects a rewritten chain through the checkpoint') \gset
ROLLBACK;

-- RV-CORE-09: دست‌کاری محتوای ردیفی که checkpoint پوشانده با راستی‌آزمایی کامل هفتگی آشکار است
BEGIN;
ALTER TABLE core.audit_log DISABLE TRIGGER trg_immutable;
UPDATE core.audit_log SET reason = 'tampered after checkpoint' WHERE tenant_id = :'A' AND seq = 1;
ALTER TABLE core.audit_log ENABLE TRIGGER trg_immutable;
SET LOCAL ROLE hk_app;
SELECT set_config('app.tenant_id', :'A', true) \gset
SELECT public.assert_true((core.audit_checkpoint_create(true)).result = 'broken', 'T20 weekly full verification flags a tampered covered row') \gset
ROLLBACK;

-- RV-ARCH-09: تریگرهای فقط‌افزودنی حتی برای نقشی که GRANT دارد (مالک جدول) کار می‌کنند
BEGIN;
SELECT public.expect_error('T20 outbox event immutable even for the table owner', $q$UPDATE core.outbox_event SET payload = '{}'$q$, 'HK_IMMUTABLE') \gset
SELECT public.expect_error('T20 audit log immutable even for the table owner', $q$UPDATE core.audit_log SET reason = 'x'$q$, 'HK_IMMUTABLE') \gset
ROLLBACK;

-- RV-IT-05 و RV-ARCH-09: security_lint اسکیمای تازه، امتیاز خارج از فهرست dispatcher و ستون کنترلی مستأجر را می‌گیرد
BEGIN;
CREATE SCHEMA zz_probe;
CREATE TABLE zz_probe.t (tenant_id uuid NOT NULL, id uuid NOT NULL, note text);
GRANT SELECT ON core.webhook_endpoint TO hk_dispatcher;
GRANT SELECT ON core.role TO hk_dispatcher;
GRANT UPDATE (status) ON core.tenant TO hk_app;
SELECT public.assert_true((SELECT count(*) FROM core.security_lint() WHERE object = 'zz_probe.t') >= 3, 'T20 lint covers a schema it was never told about') \gset
SELECT public.assert_true(EXISTS (SELECT 1 FROM core.security_lint() WHERE object = 'core.webhook_endpoint' AND problem = 'dispatcher_privilege_outside_allowlist'),
                          'T20 lint flags a dispatcher grant on webhook endpoints') \gset
SELECT public.assert_true(EXISTS (SELECT 1 FROM core.security_lint() WHERE object = 'core.role' AND problem = 'dispatcher_privilege_outside_allowlist'),
                          'T20 lint flags a dispatcher grant on a business table') \gset
SELECT public.assert_true(EXISTS (SELECT 1 FROM core.security_lint() WHERE object = 'core.tenant.status' AND problem = 'app_can_update_tenant_control_column'),
                          'T20 lint flags hk_app UPDATE on tenant status') \gset
ROLLBACK;

-- RV-X4-01: راستی‌آزمایی درون‌ریزی .hkx ردیف نوشته‌شده در مستأجر دیگر و FK آویزانِ حالت replica را می‌گیرد
BEGIN;
SET LOCAL session_replication_role = replica;
SELECT set_config('app.tenant_id', :'B', true) \gset
INSERT INTO core.role (tenant_id, code, name) VALUES (:'A', 'imported_x', 'نقش واردشده');
INSERT INTO core.tenant_membership (tenant_id, user_id, status, is_owner, joined_at) VALUES (:'B', '0d000000-0000-7000-8000-0000000dead1', 'active', true, now());
SELECT public.assert_true(EXISTS (SELECT 1 FROM core.import_verify(:'B') WHERE object = 'core.role' AND problem LIKE 'foreign_tenant_row:%'),
                          'T20 import verification finds a row written into another tenant') \gset
SELECT public.assert_true(EXISTS (SELECT 1 FROM core.import_verify(:'B') WHERE object LIKE 'core.tenant_membership%' AND problem LIKE 'dangling_fk:%'),
                          'T20 import verification finds FKs left dangling by replica mode') \gset
ROLLBACK;
SELECT public.expect_error('T20 import verification runs for the context tenant only',
  format('SELECT * FROM core.import_verify(%L)', :'A'), 'HK_TENANT_CONTEXT_MISSING') \gset
BEGIN;
UPDATE core.setting_def SET deprecated_at = now() WHERE key = 'core.calendar_display';
SET LOCAL ROLE hk_app;
SELECT set_config('app.tenant_id', :'A', true) \gset
SELECT public.expect_error('T20 deprecated setting cannot be set',
  $q$INSERT INTO core.setting_value (tenant_id, setting_key, level, value) VALUES ('0a000000-0000-7000-8000-000000000001', 'core.calendar_display', 'tenant', '"jalali"')$q$, 'HK_SETTING_DEPRECATED') \gset
ROLLBACK;
BEGIN;
CREATE TABLE public.freeze_bad (id int PRIMARY KEY, a int);
CREATE TRIGGER trg_freeze BEFORE UPDATE ON public.freeze_bad FOR EACH ROW EXECUTE FUNCTION core.freeze_columns('nope');
INSERT INTO public.freeze_bad VALUES (1, 1);
SELECT public.expect_error('T20 freeze_columns rejects a misconfigured column list', $q$UPDATE public.freeze_bad SET a = 2$q$, 'HK_CORE_FREEZE_ARGS') \gset
ROLLBACK;
SET ROLE hk_app;
SELECT public.expect_error('T20 import verification is not callable at runtime', $q$SELECT * FROM core.import_verify('0b000000-0000-7000-8000-000000000001')$q$, '42501') \gset
SELECT public.expect_error('T20 tenant purge is not callable at runtime', $q$SELECT core.purge_tenant('0b000000-0000-7000-8000-000000000001', 'tenant-b')$q$, '42501') \gset
RESET ROLE;

-- RV-CORE-17: پاک‌سازی نهایی مستأجر هیچ ردیف سطح کاربر آویزان و دادهٔ شخصی بی‌عضویت باقی نمی‌گذارد
BEGIN;
INSERT INTO core.app_user (id, kind, home_tenant_id, display_name) VALUES ('0b000000-0000-7000-8000-00000000b0f1', 'service', :'B', 'سرویس ب');
INSERT INTO core.tenant_membership (tenant_id, user_id, status) VALUES (:'B', '0b000000-0000-7000-8000-00000000b0f1', 'active');
INSERT INTO core.user_login_identifier (user_id, kind, value) VALUES ('0b000000-0000-7000-8000-00000000b0f1', 'username', 'svc.b');
INSERT INTO core.user_session (user_id, token_hash, active_tenant_id, client_kind, amr, idle_timeout_seconds, absolute_expires_at)
VALUES (:'UC1', sha256('purge-s'), :'B', 'web', '{pwd}', 600, now() + interval '1 hour');
SELECT public.expect_error('T20 purge needs replica mode', format('SELECT core.purge_tenant(%L, %L)', :'B', 'tenant-b'), 'HK_CORE_PURGE_MODE') \gset
SET LOCAL session_replication_role = replica;
SELECT public.expect_error('T20 purge needs the matching slug', format('SELECT core.purge_tenant(%L, %L)', :'B', 'tenant-a'), 'HK_CORE_PURGE_CONFIRM') \gset
SELECT core.purge_tenant(:'B', 'tenant-b') AS purge_result \gset
SELECT public.assert_true(NOT EXISTS (SELECT 1 FROM core.tenant WHERE id = :'B')
                          AND NOT EXISTS (SELECT 1 FROM core.app_user WHERE home_tenant_id = :'B')
                          AND NOT EXISTS (SELECT 1 FROM core.user_login_identifier WHERE user_id = '0b000000-0000-7000-8000-00000000b0f1')
                          AND NOT EXISTS (SELECT 1 FROM core.user_session WHERE active_tenant_id = :'B'), 'T20 purge leaves no dangling user-level rows') \gset
SELECT public.assert_true((SELECT status FROM core.app_user WHERE id = :'UB1') = 'anonymized'
                          AND (SELECT status FROM core.app_user WHERE id = :'UC1') = 'active', 'T20 purge anonymizes only users left without a membership') \gset
ROLLBACK;

-- RV-CORE-12/13 و RV-ARCH-18: پاک‌سازی دوره‌ای توقیف و دورهٔ مستأجر را رعایت می‌کند و webhook_delivery پایان‌یافته را هم پاک می‌کند
BEGIN;
INSERT INTO core.legal_hold (tenant_id, scope, reason, placed_by) VALUES (:'A', 'tenant', 'رسیدگی مالیاتی', :'UA1');
INSERT INTO core.auth_event (occurred_at, context_tenant_id, event) VALUES
  (now() - interval '410 days', :'A', 'login_succeeded'), (now() - interval '370 days', :'B', 'login_succeeded');
INSERT INTO core.webhook_endpoint (tenant_id, id, url, event_types, api_version, secret_sealed, created_by)
VALUES (:'B', '0b000000-0000-7000-8000-0000000ee001', 'https://erp-b.example.ir/hook', '{test.thing.created}', '2026-11', '\x01', :'UB1');
SET LOCAL session_replication_role = replica;
INSERT INTO core.outbox_event (tenant_id, id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
VALUES (:'B', '0b000000-0000-7000-8000-0000000ee0e1', 'test.thing.created', 'test.thing', gen_random_uuid(), '{}', now() - interval '200 days');
INSERT INTO core.outbox_delivery (tenant_id, event_id, subscriber, event_seq, aggregate_id, status, done_at)
SELECT tenant_id, id, 'core.webhooks', seq, aggregate_id, 'done', now() - interval '150 days' FROM core.outbox_event WHERE id = '0b000000-0000-7000-8000-0000000ee0e1';
INSERT INTO core.webhook_delivery (tenant_id, endpoint_id, event_id, status, created_at, succeeded_at)
VALUES (:'B', '0b000000-0000-7000-8000-0000000ee001', '0b000000-0000-7000-8000-0000000ee0e1', 'succeeded', now() - interval '199 days', now() - interval '199 days');
SET LOCAL session_replication_role = origin;
SET LOCAL ROLE hk_dispatcher;
SELECT core.purge_ephemeral(5000) AS purge_counts \gset
RESET ROLE;
SELECT public.assert_true(EXISTS (SELECT 1 FROM core.auth_event WHERE context_tenant_id = :'A' AND occurred_at < now() - interval '400 days'),
                          'T20 legal hold stops the purge of the tenant security log') \gset
SELECT public.assert_true(NOT EXISTS (SELECT 1 FROM core.auth_event WHERE context_tenant_id = :'B' AND occurred_at < now() - interval '365 days'),
                          'T20 security log purged after the class period when no hold') \gset
SELECT public.assert_true(NOT EXISTS (SELECT 1 FROM core.webhook_delivery WHERE event_id = '0b000000-0000-7000-8000-0000000ee0e1')
                          AND NOT EXISTS (SELECT 1 FROM core.outbox_event WHERE id = '0b000000-0000-7000-8000-0000000ee0e1'),
                          'T20 finished webhook deliveries and their events are purged') \gset
ROLLBACK;

-- RV-CORE-08: ترتیب commit-safe با دو نشست واقعی (dblink): تولیدکنندهٔ دوم همان aggregate تا commit اولی منتظر است
SELECT dblink_connect('t20_order', format('dbname=%s port=%s user=postgres', current_database(), current_setting('port'))) \gset
BEGIN;
SET LOCAL ROLE hk_app;
SELECT set_config('app.tenant_id', :'A', true) \gset
INSERT INTO core.outbox_event (tenant_id, event_type, aggregate_type, aggregate_id, payload)
VALUES (:'A', 'test.thing.created', 'test.thing', '0a000000-0000-7000-8000-0000000aaa01', '{"n":"first"}');
SELECT dblink_send_query('t20_order', $q$SET ROLE hk_app; SELECT set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', false);
  INSERT INTO core.outbox_event (tenant_id, event_type, aggregate_type, aggregate_id, payload)
  VALUES ('0a000000-0000-7000-8000-000000000001', 'test.thing.created', 'test.thing', '0a000000-0000-7000-8000-0000000aaa01', '{"n":"second"}')$q$) AS sent \gset
SELECT pg_sleep(0.5) \gset
SELECT public.assert_true(dblink_is_busy('t20_order') = 1, 'T20 second producer of the same aggregate waits for the first to commit') \gset
COMMIT;
SELECT count(*) AS drained FROM dblink_get_result('t20_order') AS x(r text) \gset
SELECT count(*) AS drained FROM dblink_get_result('t20_order') AS x(r text) \gset
SELECT dblink_disconnect('t20_order') \gset
SELECT public.assert_true((SELECT array_agg(payload ->> 'n' ORDER BY seq) FROM core.outbox_event
                            WHERE aggregate_id = '0a000000-0000-7000-8000-0000000aaa01') = ARRAY['first','second'],
                          'T20 commit order equals seq order per aggregate') \gset

\echo 'ALL 10_core TESTS PASSED'
