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
  -- INV-TXT-03: نام نمایشی باید نرمال باشد
  PERFORM public.expect_error('T03 unnormalized display name',
    $q$INSERT INTO core.app_user (display_name) VALUES ('علي')$q$, '23514');
END $$;

-- ---------- T04: عضویت — ماشین حالت و حداقل یک مالک فعال ----------
DO $$
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
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
  PERFORM public.expect_error('T06 direct insert beyond counter',
    $q$INSERT INTO core.number_issued (tenant_id, series_id, period_key, value, formatted, status, doc_type, doc_id)
       VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-000000050001', 'jy:1405', 99, 'JV-99', 'used', 'ledger.journal', gen_random_uuid())$q$, 'HK_NUM_OUT_OF_RANGE');
  PERFORM public.expect_error('T06 issued numbers immutable', $q$UPDATE core.number_issued SET formatted = 'x'$q$, '42501');
  PERFORM public.expect_error('T06 counter cannot go back',
    $q$UPDATE core.number_counter SET next_value = 1 WHERE period_key = 'jy:1405'$q$, 'HK_NUM_COUNTER');
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
  PERFORM public.expect_error('T06 overlapping reservation',
    format($q$INSERT INTO core.number_reservation (tenant_id, series_id, period_key, device_id, range_start, range_end)
              VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-000000050002', 'all', '0a000000-0000-7000-8000-0000000d0001', 5, 12)$q$), '23P01');
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
  steps := jsonb_build_array(jsonb_build_object('step_no', 1, 'approver_kind', 'role', 'role_id', '0a000000-0000-7000-8000-0000000f0002', 'min_approvals', 1));
  INSERT INTO core.approval_request (tenant_id, company_id, subject_type, subject_id, amount, currency, requested_by, subject_created_by,
                                     policy_id, policy_version, steps_snapshot, enforce_sod, distinct_approvers)
  VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000000c1', 'ledger.journal', s, 500000000, 'IRR',
          '0a000000-0000-7000-8000-00000000a002', '0a000000-0000-7000-8000-00000000a002', p, 1, steps, true, true) RETURNING id INTO r;
  PERFORM public.expect_error('T09 one pending request per subject',
    format($q$INSERT INTO core.approval_request (tenant_id, company_id, subject_type, subject_id, requested_by, policy_id, policy_version, steps_snapshot, enforce_sod, distinct_approvers)
              VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000000c1', 'ledger.journal', %L, '0a000000-0000-7000-8000-00000000a002', %L, 1, %L, true, true)$q$, s, p, steps), '23505');
  PERFORM public.expect_error('T09 snapshot steps must be 1..n',
    format($q$INSERT INTO core.approval_request (tenant_id, company_id, subject_type, subject_id, requested_by, policy_id, policy_version, steps_snapshot, enforce_sod, distinct_approvers)
              VALUES ('0a000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000000c1', 'ledger.journal', gen_random_uuid(), '0a000000-0000-7000-8000-00000000a002', %L, 1, '[{"step_no":2,"min_approvals":1}]', true, true)$q$, p), 'HK_APPROVAL_INVALID');
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
  VALUES ('0a000000-0000-7000-8000-000000000001', 'test.sched', 'report', '30 23 * * *', now() - interval '1 minute', 'test.month_end', 'month_end')
  RETURNING id INTO sid;
  SET LOCAL ROLE hk_dispatcher;
  PERFORM public.assert_true(EXISTS (SELECT 1 FROM core.schedule_due(100) s WHERE s.id = sid), 'T11 schedule due');
  fired := core.schedule_fire(sid, '2026-03-20 20:00:00+00', '2026-04-19 20:00:00+00');
  again := core.schedule_fire(sid, '2026-03-20 20:00:00+00', '2026-04-20 20:00:00+00');
  PERFORM public.assert_true(fired IS NOT NULL AND again IS NULL, 'T11 schedule fire is deduplicated per fire time');
  PERFORM public.expect_error('T11 next fire must be later',
    format($q$SELECT core.schedule_fire(%L, '2026-05-01 00:00:00+00', '2026-04-01 00:00:00+00')$q$, sid), 'HK_SCHEDULE_NEXT');
  SET LOCAL ROLE hk_app;
  PERFORM public.expect_error('T11 app cannot claim jobs', $q$SELECT * FROM core.job_claim(ARRAY['default'], 'x', 1)$q$, '42501');
END $$;

-- ---------- T12: اعلان ----------
DO $$
DECLARE nid uuid;
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  INSERT INTO core.notification (tenant_id, category, template_code, channel, recipient_address, params)
  VALUES ('0a000000-0000-7000-8000-000000000001', 'core.security', 'core.otp', 'sms', '09120000001', '{"code":"123456"}') RETURNING id INTO nid;
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
  UPDATE core.idempotency_key SET response_status = 409, response_body = '{"code":"conflict"}' WHERE id = k2;
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
    $q$INSERT INTO core.user_session (user_id, token_hash, active_tenant_id, device_id, client_kind, amr, idle_timeout_seconds, absolute_expires_at) VALUES ('0c000000-0000-7000-8000-00000000c001', sha256('p3'), '0b000000-0000-7000-8000-000000000001', '0a000000-0000-7000-8000-0000000d0001', 'pos', '{device_key,pin}', 600, now() + interval '8 hours')$q$, '23503');
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
BEGIN
  PERFORM set_config('app.tenant_id', '0a000000-0000-7000-8000-000000000001', true);
  PERFORM public.expect_error('T16 retention below class minimum',
    $q$INSERT INTO core.retention_override (tenant_id, class_code, period, set_by) VALUES ('0a000000-0000-7000-8000-000000000001', 'technical_log', interval '30 days', '0a000000-0000-7000-8000-00000000a001')$q$, 'HK_RET_TOO_SHORT');
  PERFORM public.expect_error('T16 legal retention not tenant-settable',
    $q$INSERT INTO core.retention_override (tenant_id, class_code, period, set_by) VALUES ('0a000000-0000-7000-8000-000000000001', 'accounting_records', interval '20 years', '0a000000-0000-7000-8000-00000000a001')$q$, 'HK_RET_LEGAL');
  INSERT INTO core.retention_override (tenant_id, class_code, period, set_by)
  VALUES ('0a000000-0000-7000-8000-000000000001', 'technical_log', interval '400 days', '0a000000-0000-7000-8000-00000000a001');
  PERFORM public.expect_error('T16 DSR: approver differs from requester',
    $q$INSERT INTO core.data_subject_request (tenant_id, subject_type, subject_id, request_type, requested_via, requested_by, approved_by, status, decided_at)
       VALUES ('0a000000-0000-7000-8000-000000000001', 'party', gen_random_uuid(), 'erase', 'tenant_admin', '0a000000-0000-7000-8000-00000000a001', '0a000000-0000-7000-8000-00000000a001', 'approved', now())$q$, '23514');
  PERFORM public.expect_error('T16 legal hold scope shape',
    $q$INSERT INTO core.legal_hold (tenant_id, scope, company_id, reason, placed_by) VALUES ('0a000000-0000-7000-8000-000000000001', 'tenant', '0a000000-0000-7000-8000-0000000000c1', 'حسابرسی مالیاتی', '0a000000-0000-7000-8000-00000000a001')$q$, '23514');
  PERFORM public.expect_error('T16 completed export must be signed',
    $q$INSERT INTO core.tenant_export (tenant_id, purpose, status, requested_by, object_key, sha256, manifest, completed_at)
       VALUES ('0a000000-0000-7000-8000-000000000001', 'backup', 'completed', '0a000000-0000-7000-8000-00000000a001', 't/0a000000-0000-7000-8000-000000000001/exports/x.hkx', sha256('z'), '{}', now())$q$, '23514');
  PERFORM public.expect_error('T16 export key namespace',
    $q$INSERT INTO core.tenant_export (tenant_id, purpose, requested_by, object_key) VALUES ('0a000000-0000-7000-8000-000000000001', 'backup', '0a000000-0000-7000-8000-00000000a001', 't/0b000000-0000-7000-8000-000000000001/exports/x.hkx')$q$, '23514');
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
END $$;
RESET ROLE;

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

\echo 'ALL 10_core TESTS PASSED'
