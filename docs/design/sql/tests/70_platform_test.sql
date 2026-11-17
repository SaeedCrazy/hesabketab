-- =====================================================================
-- آزمون پایگاه داده‌ای 70_platform.sql (صفحهٔ کنترل؛ سند: docs/design/09-owner-platform.md §۷ و §۹)
--
-- اجرا (از ریشهٔ مخزن؛ پایگاه دادهٔ «جدا»؛ 00_foundation روی آن اجرا نمی‌شود):
--   export PGPASSWORD=postgres
--   psql -h localhost -p 5433 -U postgres -d postgres -c "DROP DATABASE IF EXISTS ds_platform"
--   psql -h localhost -p 5433 -U postgres -d postgres -c "CREATE DATABASE ds_platform ENCODING 'UTF8' TEMPLATE template0 LC_COLLATE 'C' LC_CTYPE 'C.UTF-8'"
--   psql -h localhost -p 5433 -U postgres -d ds_platform -v ON_ERROR_STOP=1 -q -f docs/design/sql/70_platform.sql
--   psql -h localhost -p 5433 -U postgres -d ds_platform -v ON_ERROR_STOP=1 -f docs/design/sql/tests/70_platform_test.sql
--
-- ساختار (یک نشست psql با superuser؛ نقش با SET ROLE عوض می‌شود):
--   بخش ۱ (fixture، نقش postgres): اسکیمای کمکی plt_t (شناسه‌ها، توابع کمکی SECURITY INVOKER)، جغرافیا، کارکنان،
--          انتساب نقش راه‌اندازی، نشست با MFA تازه، سطح و نماینده، سلول‌ها، مستأجر خانه، کاتالوگ کلید قواعد.
--   بخش ۲ (SET ROLE hk_platform_app؛ نه مالک، NOBYPASSRLS): T01..T24. هر DO block کنشگر را با
--          set_config('app.staff_id'/'app.staff_session_id', ..., true) تنظیم می‌کند (plt_t.as_staff).
--   بخش ۳ (SET ROLE hk_platform_ingest): بخش‌های uplink در T17، T18، T22، T23 و T26.
--   بخش ۴ (SET ROLE hk_partner_app): T25 جداسازی نماینده‌ها با RLS (app.reseller_id) — همتای «جداسازی بین‌مستأجری».
--   بخش ۵ (SET ROLE hk_platform_readonly): T27 ستون‌های راز.
--   بخش ۶ (postgres): T28 lint امنیتی، تغییرناپذیری حتی برای مالک، تشخیص دستکاری زنجیرهٔ ممیزی، بی‌فاصلگی شماره‌ها.
-- هر ادعای منفی الگوی دقیق پیام خطا (کد HK_PLT_* یا نام قید) را بررسی می‌کند (plt_t.fails).
-- خروجی موفق با «ALL 70_platform TESTS PASSED» پایان می‌یابد؛ هر شکست «TEST FAILED [...]» می‌دهد و psql با کد ≠ ۰ خارج می‌شود.
-- =====================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
\pset tuples_only on
\pset format unaligned
SET client_min_messages = warning;

-- =====================================================================
-- بخش ۱: fixture (postgres)
-- =====================================================================
RESET ROLE;
DROP SCHEMA IF EXISTS plt_t CASCADE;
CREATE SCHEMA plt_t;
GRANT USAGE ON SCHEMA plt_t TO hk_platform_app, hk_platform_ingest, hk_partner_app, hk_platform_readonly;

CREATE TABLE plt_t.ids (name text PRIMARY KEY, id uuid NOT NULL UNIQUE);
CREATE TABLE plt_t.sess (staff_id uuid PRIMARY KEY, session_id uuid NOT NULL);
GRANT SELECT ON plt_t.ids, plt_t.sess TO hk_platform_app, hk_platform_ingest, hk_partner_app, hk_platform_readonly;

INSERT INTO plt_t.ids (name, id)
SELECT n, ('70000000-0000-7000-8000-' || lpad(h, 12, '0'))::uuid FROM (VALUES
  ('O','a001'),('A','a002'),('F','a003'),('S','a004'),('T','a005'),('P','a006'),('R','a007'),('M','a008'),('I','a009'),
  ('F2','a00a'),('SL','a00b'),('T2','a00c'),
  ('R1','c001'),('R2','c002'),('RU1','c101'),('RU2','c102'),
  ('TA','0001'),('TB','0002'),('TC','0003'),('TH','0004'),('TD','0005'),('TE','0006'),('TF','0007'),
  ('PV1','d001'),('PV2','d002'),('PV3','d003'),('PV4','d004'),('PV5','d005'),
  ('BA_A','e001'),('BA_B','e002'),('BA_C','e003'),('BA_R1','e004'),
  ('SUB_A','f001'),('SUB_B','f002'),
  ('INV1','1001'),('INV2','1002'),('INV4','1004'),('INV5','1005'),('INV6','1006'),('INV7','1007'),('INV8','1008'),('INV9','1009'),
  ('INV0','1010'),('INVR','1011'),('CN1','1101'),
  ('L1','2001'),('L2','2002'),('L4','2004'),('L6','2006'),('L7','2007'),('L8','2008'),('L9','2009'),('L0','2010'),('LR','2011'),('CL1','2101'),
  ('GW1','3901'),('GW2','3902'),
  ('PAY1','3001'),('PAY2','3002'),('PAY3','3003'),('PAY4','3004'),('PAY5','3005'),
  ('INST1','5001'),('INST2','5002'),
  ('LIC1','4001'),('LIC2','4002'),('LIC3','4003'),('LIC4','4004'),('LIC5','4005'),('LICT','4006'),
  ('RP1','6001'),('RP2','6002'),
  ('G1','7001'),('G2','7002'),('G3','7003'),('G4','7004'),
  ('IMP1','7101'),('IMP2','7102'),('IMP3','7103'),
  ('TK1','7201'),('TK2','7202'),('AN1','7301'),('AN2','7302'),
  ('SO1','7401'),('C1','7501'),('DR1','7601'),('DR2','7602'),
  ('UB1','8001'),('UB2','8002'),('PO1','8101'),('PO2','8102'),('RF1','8201'),('RF2','8202'),
  ('U1','9001'),('ACT1','9101'),('ACT2','9102')
) v(n, h);

CREATE FUNCTION plt_t.u(p text) RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT id FROM plt_t.ids WHERE name = p $$;

CREATE FUNCTION plt_t.as_staff(p uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('app.staff_id', coalesce(p::text, ''), true);
  PERFORM set_config('app.staff_session_id', coalesce((SELECT session_id::text FROM plt_t.sess WHERE staff_id = p), ''), true);
END $$;

CREATE FUNCTION plt_t.fails(p_label text, p_sql text, p_pattern text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_msg text; v_state text;
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
    IF v_msg NOT LIKE p_pattern THEN
      RAISE EXCEPTION 'TEST FAILED [%]: expected error like "%" but got "%" (SQLSTATE %)', p_label, p_pattern, v_msg, v_state;
    END IF;
    RETURN;
  END;
  RAISE EXCEPTION 'TEST FAILED [%]: statement succeeded but must fail', p_label;
END $$;

CREATE FUNCTION plt_t.ok(p_label text, p_cond boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST FAILED [%]', p_label;
  END IF;
END $$;

-- درخواست تأیید چهارچشمی و تصمیم آن (کنشگر جاری را برمی‌گرداند)
CREATE FUNCTION plt_t.approve(p_action text, p_subject_type text, p_subject uuid, p_requester uuid, p_approver uuid) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v uuid;
  v_prev text := current_setting('app.staff_id', true);
BEGIN
  PERFORM plt_t.as_staff(p_requester);
  INSERT INTO platform.approval_request (action, subject_type, subject_id, requested_by, reason)
  VALUES (p_action, p_subject_type, p_subject, p_requester, 'test approval reason') RETURNING id INTO v;
  PERFORM plt_t.as_staff(p_approver);
  UPDATE platform.approval_request SET status = 'approved', decided_by = p_approver WHERE id = v;
  PERFORM plt_t.as_staff(NULLIF(v_prev, '')::uuid);
  RETURN v;
END $$;

CREATE FUNCTION plt_t.sig() RETURNS bytea LANGUAGE sql IMMUTABLE AS $$ SELECT decode(repeat('ab', 64), 'hex') $$;
CREATE FUNCTION plt_t.h(p text) RETURNS bytea LANGUAGE sql IMMUTABLE AS $$ SELECT sha256(convert_to(p, 'UTF8')) $$;
CREATE FUNCTION plt_t.fp(p text) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('dmi_uuid', encode(sha256(convert_to(p || 'd', 'UTF8')), 'hex'),
                            'machine_id', encode(sha256(convert_to(p || 'm', 'UTF8')), 'hex'),
                            'pg_sysid', encode(sha256(convert_to(p || 'p', 'UTF8')), 'hex'),
                            'rootfs_uuid', encode(sha256(convert_to(p || 'r', 'UTF8')), 'hex'),
                            'primary_mac', encode(sha256(convert_to(p || 'n', 'UTF8')), 'hex'))
$$;

BEGIN;
INSERT INTO platform.geo_province (code, name_fa) VALUES ('THR', 'تهران'), ('ESF', 'اصفهان');
INSERT INTO platform.geo_city (province_code, code, name_fa) VALUES ('THR', '01', 'تهران'), ('THR', '02', 'شمیرانات'), ('ESF', '01', 'اصفهان');

INSERT INTO platform.staff (id, oidc_subject, email, display_name, status, mfa_methods, mfa_enrolled_at)
SELECT plt_t.u(n), 'kc-' || lower(n), lower(n) || '@hk.test', 'کارمند ' || n, 'active', '{webauthn}', now()
  FROM unnest(ARRAY['O','A','F','S','T','P','R','M','F2','SL','T2']) n;
INSERT INTO platform.staff (id, email, display_name, status) VALUES (plt_t.u('I'), 'i@hk.test', 'دعوت‌شده', 'invited');

INSERT INTO platform.staff_role_assignment (staff_id, role_code) VALUES
  (plt_t.u('O'), 'owner'), (plt_t.u('A'), 'admin'), (plt_t.u('F'), 'finance'), (plt_t.u('S'), 'support'),
  (plt_t.u('T'), 'compliance_tax'), (plt_t.u('P'), 'compliance_payroll'), (plt_t.u('R'), 'read_only'),
  (plt_t.u('M'), 'release_manager'), (plt_t.u('F2'), 'finance'), (plt_t.u('SL'), 'sales'), (plt_t.u('T2'), 'compliance_tax');

INSERT INTO platform.staff_session (id, staff_id, token_hash, amr, mfa_at, expires_at)
SELECT ('70000000-0000-7000-8000-00000000b' || substr(i.id::text, 34, 3))::uuid, i.id, plt_t.h(i.name), '{hwk}', now(), now() + interval '8 hours'
  FROM plt_t.ids i WHERE i.name IN ('O','A','F','S','T','P','R','M','F2','SL','T2');
INSERT INTO plt_t.sess (staff_id, session_id)
SELECT s.staff_id, s.id FROM platform.staff_session s;

INSERT INTO platform.reseller_tier (code, name_fa, rank) VALUES ('gold', 'طلایی', 1), ('silver', 'نقره‌ای', 2);
INSERT INTO platform.reseller (id, code, legal_name, person_type, national_id, kinds, tier_code, status, contract_ref,
                               contract_valid_from, referral_code, sheba, is_taxpayer) VALUES
  (plt_t.u('R1'), 'R-ONE', 'نمایندگی یک', 'legal', '10101010101', '{sales,support,migration,onprem_install}', 'gold', 'active',
   'CT-1', '2026-01-01', 'rone', 'IR000000000000000000000001', true),
  (plt_t.u('R2'), 'R-TWO', 'نمایندگی دو', 'natural', '0012345678', '{sales}', 'silver', 'active',
   'CT-2', '2026-01-01', 'rtwo', 'IR000000000000000000000002', false);
INSERT INTO platform.reseller_user (id, reseller_id, oidc_subject, display_name, mobile, role, status, mfa_enrolled_at) VALUES
  (plt_t.u('RU1'), plt_t.u('R1'), 'kc-ru1', 'کاربر یک', '09120000001', 'reseller_admin', 'active', now()),
  (plt_t.u('RU2'), plt_t.u('R2'), 'kc-ru2', 'کاربر دو', '09120000002', 'reseller_admin', 'active', now());

INSERT INTO platform.cell (id, kind, provider, region, status, dsn_ref, control_pubkey, control_kid, app_version) VALUES
  ('cell-01', 'pooled', 'prov-a', 'thr', 'active', 'openbao://kv/cells/cell-01/dsn', decode(repeat('11', 32), 'hex'), 'cell-01-k1', '2026.11.0'),
  ('cell-02', 'pooled', 'prov-b', 'tbz', 'active', 'openbao://kv/cells/cell-02/dsn', decode(repeat('12', 32), 'hex'), 'cell-02-k1', '2026.11.0'),
  ('cell-ded', 'dedicated', 'prov-a', 'thr', 'provisioning', 'openbao://kv/cells/cell-ded/dsn', NULL, NULL, NULL);

INSERT INTO platform.tenant (id, slug, display_name, deployment, is_internal, is_house)
VALUES (plt_t.u('TH'), 'hesabketab-co', 'شرکت حساب‌کتاب', 'saas_shared', true, true);

INSERT INTO platform.rules_param_catalog (key, value_type, unit, package_code, qualifier_kind, enum_values, introduced_in) VALUES
  ('tax.vat.standard_rate', 'percent', 'percent', 'ir.tax', 'none', NULL, '2026.11.0'),
  ('tax.threshold.article6', 'money', 'IRR', 'ir.tax', 'none', NULL, '2026.11.0'),
  ('tax.vat.rounding', 'enum', NULL, 'ir.tax', 'none', ARRAY['trunc','round'], '2026.11.0'),
  ('payroll.wage.min_daily', 'money', 'IRR', 'ir.payroll', 'none', NULL, '2026.11.0');
COMMIT;

-- =====================================================================
-- بخش ۲: ادعاها با hk_platform_app
-- =====================================================================
SET ROLE hk_platform_app;

-- T01 کارکنان، ۲FA اجباری، نشست
DO $$
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('O'));
  PERFORM plt_t.fails('T01 active staff without MFA',
    $q$INSERT INTO platform.staff (email, display_name, status, oidc_subject) VALUES ('x@hk.test', 'بدون MFA', 'active', 'kc-x')$q$,
    '%staff_active_requires_mfa%');
  PERFORM plt_t.fails('T01 non-invited staff needs OIDC subject',
    $q$INSERT INTO platform.staff (email, display_name, status) VALUES ('y@hk.test', 'بدون شناسه', 'suspended')$q$,
    '%staff_non_invited_has_subject%');
  PERFORM plt_t.fails('T01 session for invited staff',
    format($q$INSERT INTO platform.staff_session (staff_id, token_hash, amr, mfa_at, expires_at)
              VALUES (%L, plt_t.h('i1'), '{hwk}', now(), now() + interval '1 hour')$q$, plt_t.u('I')),
    'HK_PLT_STAFF_NOT_ACTIVE%');
  PERFORM plt_t.fails('T01 session longer than 12h',
    format($q$INSERT INTO platform.staff_session (staff_id, token_hash, amr, mfa_at, expires_at)
              VALUES (%L, plt_t.h('a13'), '{hwk}', now(), now() + interval '13 hours')$q$, plt_t.u('A')),
    '%staff_session_lifetime%');
  PERFORM plt_t.fails('T01 session without MFA method',
    format($q$INSERT INTO platform.staff_session (staff_id, token_hash, amr, mfa_at, expires_at)
              VALUES (%L, plt_t.h('apwd'), '{pwd}', now(), now() + interval '1 hour')$q$, plt_t.u('A')),
    '%staff_session_mfa%');
  PERFORM plt_t.fails('T01 session cannot be extended',
    format($q$UPDATE platform.staff_session SET expires_at = expires_at + interval '1 hour' WHERE staff_id = %L$q$, plt_t.u('A')),
    'HK_PLT_SESSION_EXTEND%');
  -- نشست MFA کهنه برای F2 (در T03 به کار می‌رود)
  INSERT INTO platform.staff_session (id, staff_id, token_hash, amr, mfa_at, expires_at, created_at)
  VALUES ('70000000-0000-7000-8000-00000000bfaa', plt_t.u('F2'), plt_t.h('f2-stale'), '{otp}', now() - interval '1 hour', now() + interval '6 hours', now());
  PERFORM plt_t.ok('T01 staff_has_permission owner grants all', platform.staff_has_permission(plt_t.u('O'), 'platform.tenant.purge.approve'));
  PERFORM plt_t.ok('T01 support lacks purge approval', NOT platform.staff_has_permission(plt_t.u('S'), 'platform.tenant.purge.approve'));
END $$;

-- T02 نقش‌ها: بدون خوداعطا، نقش ممتاز با تأیید دونفره، راه‌اندازی فقط با مالک پایگاه داده، آخرین owner
DO $$
DECLARE
  v_appr uuid;
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('A'));
  PERFORM plt_t.fails('T02 self grant',
    format($q$INSERT INTO platform.staff_role_assignment (staff_id, role_code, granted_by) VALUES (%L, 'support', %L)$q$, plt_t.u('A'), plt_t.u('A')),
    '%role_assignment_no_self_grant%');
  PERFORM plt_t.fails('T02 bootstrap by app role',
    format($q$INSERT INTO platform.staff_role_assignment (staff_id, role_code) VALUES (%L, 'support')$q$, plt_t.u('F')),
    'HK_PLT_BOOTSTRAP_ONLY%');
  PERFORM plt_t.fails('T02 granted_by must be actor',
    format($q$INSERT INTO platform.staff_role_assignment (staff_id, role_code, granted_by) VALUES (%L, 'support', %L)$q$, plt_t.u('F'), plt_t.u('O')),
    'HK_PLT_ACTOR_MISMATCH%');
  PERFORM plt_t.fails('T02 privileged role without approval',
    format($q$INSERT INTO platform.staff_role_assignment (staff_id, role_code, granted_by) VALUES (%L, 'admin', %L)$q$, plt_t.u('S'), plt_t.u('A')),
    'HK_PLT_APPROVAL_REQUIRED%');
  -- admin لازم دارد owner تأیید کند (admin مجوز platform.staff.role.approve ندارد)
  PERFORM plt_t.fails('T02 admin cannot approve privileged grant',
    format($q$SELECT plt_t.approve('staff.grant_privileged_role', 'staff', %L, %L, %L)$q$, plt_t.u('S'), plt_t.u('F'), plt_t.u('A')),
    'HK_PLT_APPROVER_NOT_ELIGIBLE%');
  v_appr := plt_t.approve('staff.grant_privileged_role', 'staff', plt_t.u('S'), plt_t.u('A'), plt_t.u('O'));
  INSERT INTO platform.staff_role_assignment (staff_id, role_code, granted_by, approval_id) VALUES (plt_t.u('S'), 'admin', plt_t.u('A'), v_appr);
  PERFORM plt_t.ok('T02 approval consumed', (SELECT status = 'consumed' FROM platform.approval_request WHERE id = v_appr));
  PERFORM plt_t.fails('T02 approval reuse',
    format($q$INSERT INTO platform.staff_role_assignment (staff_id, role_code, granted_by, approval_id) VALUES (%L, 'admin', %L, %L)$q$,
           plt_t.u('F'), plt_t.u('A'), v_appr),
    'HK_PLT_APPROVAL_%');
  PERFORM plt_t.fails('T02 approval for another subject',
    format($q$INSERT INTO platform.staff_role_assignment (staff_id, role_code, granted_by, approval_id) VALUES (%L, 'owner', %L, %L)$q$,
           plt_t.u('F'), plt_t.u('A'), plt_t.approve('staff.grant_privileged_role', 'staff', plt_t.u('M'), plt_t.u('A'), plt_t.u('O'))),
    'HK_PLT_APPROVAL_MISMATCH%');
  PERFORM plt_t.as_staff(plt_t.u('F'));
  PERFORM plt_t.fails('T02 grantor without staff.manage',
    format($q$INSERT INTO platform.staff_role_assignment (staff_id, role_code, granted_by) VALUES (%L, 'read_only', %L)$q$,
           plt_t.u('M'), plt_t.u('F')),
    'HK_PLT_PERMISSION%');
  PERFORM plt_t.as_staff(plt_t.u('O'));
  PERFORM plt_t.fails('T02 last owner cannot be revoked',
    format($q$UPDATE platform.staff_role_assignment SET revoked_at = now(), revoked_by = %L, revoke_reason = 'leaving company'
              WHERE staff_id = %L AND role_code = 'owner'$q$, plt_t.u('O'), plt_t.u('O')),
    'HK_PLT_LAST_OWNER%');
  -- لغو عادی: نقش admin کارمند S
  UPDATE platform.staff_role_assignment SET revoked_at = now(), revoked_by = plt_t.u('O'), revoke_reason = 'temporary only'
   WHERE staff_id = plt_t.u('S') AND role_code = 'admin';
  PERFORM plt_t.fails('T02 revoked assignment is final',
    format($q$UPDATE platform.staff_role_assignment SET revoked_at = NULL, revoked_by = NULL, revoke_reason = NULL
              WHERE staff_id = %L AND role_code = 'admin'$q$, plt_t.u('S')),
    'HK_PLT_INVALID_TRANSITION%');
  PERFORM plt_t.fails('T02 assignment identity immutable',
    format($q$UPDATE platform.staff_role_assignment SET role_code = 'owner' WHERE staff_id = %L AND role_code = 'support'$q$, plt_t.u('S')),
    'HK_PLT_IMMUTABLE_FIELD%');
  PERFORM plt_t.fails('T02 delete assignment', $q$DELETE FROM platform.staff_role_assignment$q$, '%permission denied%');
END $$;

-- T03 تأیید چهارچشمی
DO $$
DECLARE
  v uuid;
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('F'));
  PERFORM plt_t.fails('T03 requester must be actor',
    format($q$INSERT INTO platform.approval_request (action, subject_type, subject_id, requested_by, reason)
              VALUES ('refund.execute', 'refund', gen_random_uuid(), %L, 'some long reason')$q$, plt_t.u('A')),
    'HK_PLT_ACTOR_MISMATCH%');
  PERFORM plt_t.fails('T03 reason too short',
    format($q$INSERT INTO platform.approval_request (action, subject_type, subject_id, requested_by, reason)
              VALUES ('refund.execute', 'refund', gen_random_uuid(), %L, 'short')$q$, plt_t.u('F')),
    '%approval_request_reason_check%');
  PERFORM plt_t.fails('T03 subject type must match action',
    format($q$INSERT INTO platform.approval_request (action, subject_type, subject_id, requested_by, reason)
              VALUES ('refund.execute', 'tenant', gen_random_uuid(), %L, 'some long reason')$q$, plt_t.u('F')),
    'HK_PLT_APPROVAL_MISMATCH%');
  INSERT INTO platform.approval_request (action, subject_type, subject_id, payload, requested_by, reason)
  VALUES ('refund.execute', 'refund', plt_t.u('RF1'), '{"amount": "1000"}', plt_t.u('F'), 'refund to customer card') RETURNING id INTO v;
  PERFORM plt_t.ok('T03 payload hash computed', (SELECT payload_sha256 = sha256(convert_to(payload::text, 'UTF8'))
                                                   AND expires_at = created_at + interval '24 hours' FROM platform.approval_request WHERE id = v));
  PERFORM plt_t.fails('T03 self approval',
    format($q$UPDATE platform.approval_request SET status = 'approved', decided_by = %L WHERE id = %L$q$, plt_t.u('F'), v),
    'HK_PLT_FOUR_EYES%');
  PERFORM plt_t.fails('T03 payload immutable',
    format($q$UPDATE platform.approval_request SET payload = '{"amount": "9999"}' WHERE id = %L$q$, v),
    'HK_PLT_IMMUTABLE_FIELD%');
  PERFORM plt_t.as_staff(plt_t.u('S'));
  PERFORM plt_t.fails('T03 decider without approver permission',
    format($q$UPDATE platform.approval_request SET status = 'approved', decided_by = %L WHERE id = %L$q$, plt_t.u('S'), v),
    'HK_PLT_APPROVER_NOT_ELIGIBLE%');
  PERFORM plt_t.fails('T03 decided_by must be actor',
    format($q$UPDATE platform.approval_request SET status = 'approved', decided_by = %L WHERE id = %L$q$, plt_t.u('F2'), v),
    'HK_PLT_ACTOR_MISMATCH%');
  -- F2 با نشست MFA کهنه
  PERFORM set_config('app.staff_id', plt_t.u('F2')::text, true);
  PERFORM set_config('app.staff_session_id', '70000000-0000-7000-8000-00000000bfaa', true);
  PERFORM plt_t.fails('T03 stale MFA',
    format($q$UPDATE platform.approval_request SET status = 'approved', decided_by = %L WHERE id = %L$q$, plt_t.u('F2'), v),
    'HK_PLT_MFA_STALE%');
  PERFORM plt_t.as_staff(plt_t.u('F2'));
  PERFORM plt_t.fails('T03 reject needs a note',
    format($q$UPDATE platform.approval_request SET status = 'rejected', decided_by = %L WHERE id = %L$q$, plt_t.u('F2'), v),
    '%approval_reject_note%');
  UPDATE platform.approval_request SET status = 'approved', decided_by = plt_t.u('F2') WHERE id = v;
  PERFORM plt_t.ok('T03 decided_at set', (SELECT decided_at IS NOT NULL FROM platform.approval_request WHERE id = v));
  PERFORM plt_t.fails('T03 direct consume',
    format($q$UPDATE platform.approval_request SET status = 'consumed', consumed_at = now(), consumed_ref = 'x' WHERE id = %L$q$, v),
    'HK_PLT_APPROVAL_CONSUME_DIRECT%');
  PERFORM plt_t.fails('T03 approved -> pending', format($q$UPDATE platform.approval_request SET status = 'pending' WHERE id = %L$q$, v),
    'HK_PLT_INVALID_TRANSITION%');
  PERFORM plt_t.fails('T03 not yet expired', format($q$UPDATE platform.approval_request SET status = 'expired' WHERE id = %L$q$, v),
    'HK_PLT_APPROVAL_STATE%');
  PERFORM plt_t.fails('T03 delete approval', format($q$DELETE FROM platform.approval_request WHERE id = %L$q$, v), '%permission denied%');
  PERFORM plt_t.fails('T03 direct consume_approval call',
    format($q$SELECT platform.consume_approval(%L, 'refund.execute', 'refund', %L, 'direct')$q$, v, plt_t.u('RF1')),
    'HK_PLT_APPROVAL_CONSUME_DIRECT%');
  -- لغو توسط درخواست‌دهنده
  PERFORM plt_t.as_staff(plt_t.u('F'));
  INSERT INTO platform.approval_request (action, subject_type, subject_id, requested_by, reason)
  VALUES ('refund.execute', 'refund', plt_t.u('RF2'), plt_t.u('F'), 'second refund request') RETURNING id INTO v;
  PERFORM plt_t.as_staff(plt_t.u('F2'));
  PERFORM plt_t.fails('T03 only requester cancels', format($q$UPDATE platform.approval_request SET status = 'cancelled' WHERE id = %L$q$, v),
    'HK_PLT_ACTOR_MISMATCH%');
  PERFORM plt_t.as_staff(plt_t.u('F'));
  UPDATE platform.approval_request SET status = 'cancelled' WHERE id = v;
END $$;

-- T04 ممیزی پلتفرم: فقط‌افزودنی، زنجیرهٔ hash، کنشگر = کنشگر جاری
DO $$
DECLARE
  v_head bigint;
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('A'));
  SELECT coalesce(max(seq), 0) INTO v_head FROM platform.audit_log;
  INSERT INTO platform.audit_log (actor_kind, actor_id, action, subject_type, subject_id, details)
  VALUES ('staff', plt_t.u('A'), 'platform.tenant.viewed', 'tenant', 'x', '{"k": 1}'),
         ('staff', plt_t.u('A'), 'platform.tenant.updated', 'tenant', 'x', '{"k": 2, "note": "سلام"}'),
         ('system', NULL, 'platform.job.finished', 'job', 'j', '{}');
  PERFORM plt_t.ok('T04 seq contiguous', (SELECT array_agg(seq ORDER BY seq) = ARRAY[v_head + 1, v_head + 2, v_head + 3]
                                            FROM platform.audit_log WHERE seq > v_head));
  PERFORM plt_t.ok('T04 chain links', (SELECT bool_and(a.prev_hash = b.row_hash) FROM platform.audit_log a
                                         JOIN platform.audit_log b ON b.seq = a.seq - 1 WHERE a.seq > v_head + 1));
  PERFORM plt_t.ok('T04 verify clean', NOT EXISTS (SELECT 1 FROM platform.audit_verify()));
  PERFORM plt_t.fails('T04 actor must be acting staff',
    format($q$INSERT INTO platform.audit_log (actor_kind, actor_id, action) VALUES ('staff', %L, 'platform.x.y')$q$, plt_t.u('O')),
    'HK_PLT_AUDIT_ACTOR%');
  PERFORM plt_t.fails('T04 details must be a JSON object',
    $q$INSERT INTO platform.audit_log (actor_kind, action, details) VALUES ('system', 'platform.x.y', '[1]')$q$,
    '%audit_log_details_check%');
  PERFORM plt_t.fails('T04 non-system actor needs id',
    $q$INSERT INTO platform.audit_log (actor_kind, action) VALUES ('cell', 'platform.x.y')$q$, '%audit_log_check%');
  PERFORM plt_t.fails('T04 app cannot update audit', $q$UPDATE platform.audit_log SET reason = 'x'$q$, '%permission denied%');
  PERFORM plt_t.fails('T04 app cannot move the chain head', $q$UPDATE platform.audit_chain_head SET last_seq = last_seq + 1$q$, '%permission denied%');
  PERFORM plt_t.fails('T04 app cannot truncate audit', $q$TRUNCATE platform.audit_log$q$, '%permission denied%');
  INSERT INTO platform.audit_checkpoint (verified_to_seq, head_hash, result, problems)
  SELECT last_seq, last_hash, 'ok', '[]' FROM platform.audit_chain_head;
  PERFORM plt_t.fails('T04 checkpoint result consistency',
    $q$INSERT INTO platform.audit_checkpoint (verified_to_seq, head_hash, result, problems) VALUES (1, decode(repeat('00',32),'hex'), 'ok', '["gap"]')$q$,
    '%audit_checkpoint_check%');
END $$;

-- T05 idempotency
DO $$
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('F'));
  BEGIN
    SET CONSTRAINTS ALL IMMEDIATE;
    INSERT INTO platform.idempotency_key (principal_kind, principal_id, key, method, path, request_sha256, expires_at)
    VALUES ('staff', plt_t.u('F'), 'key-without-response-01', 'POST', '/platform/v1/refunds', plt_t.h('r'), now() + interval '1 day');
    RAISE EXCEPTION 'TEST FAILED [T05 key without response committed]';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'HK_PLT_IDEMPOTENCY_INCOMPLETE%' THEN RAISE; END IF;
  END;
  SET CONSTRAINTS ALL DEFERRED;
  INSERT INTO platform.idempotency_key (principal_kind, principal_id, key, method, path, request_sha256, expires_at, response_status, response_body)
  VALUES ('staff', plt_t.u('F'), 'key-with-response-0001', 'POST', '/platform/v1/refunds', plt_t.h('r'), now() + interval '1 day', 201, '{"id": 1}');
  PERFORM plt_t.fails('T05 completed record immutable',
    $q$UPDATE platform.idempotency_key SET response_status = 500 WHERE key = 'key-with-response-0001'$q$,
    'HK_PLT_IDEMPOTENCY_COMPLETED%');
  PERFORM plt_t.fails('T05 expiry at most 7 days',
    format($q$INSERT INTO platform.idempotency_key (principal_kind, principal_id, key, method, path, request_sha256, expires_at, response_status)
              VALUES ('staff', %L, 'key-long-expiry-00001', 'POST', '/x', plt_t.h('r'), now() + interval '8 days', 200)$q$, plt_t.u('F')),
    '%idempotency_key_check%');
  PERFORM plt_t.fails('T05 key format',
    format($q$INSERT INTO platform.idempotency_key (principal_kind, principal_id, key, method, path, request_sha256, expires_at, response_status)
              VALUES ('staff', %L, 'short', 'POST', '/x', plt_t.h('r'), now() + interval '1 day', 200)$q$, plt_t.u('F')),
    '%idempotency_key_key_check%');
END $$;

-- T06 سلول، مستأجر، جای‌گذاری، چرخهٔ عمر
DO $$
DECLARE
  v_jobs int;
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('A'));
  PERFORM plt_t.fails('T06 raw DSN in cell',
    $q$INSERT INTO platform.cell (id, kind, provider, region, dsn_ref) VALUES ('cell-bad', 'pooled', 'p', 'r', 'postgres://u:p@h/db')$q$,
    '%cell_dsn_ref_check%');
  PERFORM plt_t.fails('T06 active cell needs control key',
    $q$INSERT INTO platform.cell (id, kind, provider, region, status, dsn_ref) VALUES ('cell-nokey', 'pooled', 'p', 'r', 'active', 'openbao://kv/x')$q$,
    '%cell_active_has_key%');
  INSERT INTO platform.tenant (id, slug, display_name, deployment, reseller_id, reseller_attributed_at, attribution_source, province_code, city_code)
  VALUES (plt_t.u('TA'), 'cafe-a', 'کافه الف', 'saas_shared', plt_t.u('R1'), now(), 'referral_code', 'THR', '01'),
         (plt_t.u('TB'), 'shoes-b', 'کفش ب', 'saas_shared', plt_t.u('R2'), now(), 'reseller_portal', 'ESF', '01'),
         (plt_t.u('TC'), 'elec-c', 'برق ج', 'onprem', plt_t.u('R1'), now(), 'staff', 'THR', '02'),
         (plt_t.u('TD'), 'gone-d', 'خروجی د', 'saas_shared', NULL, NULL, NULL, NULL, NULL),
         (plt_t.u('TE'), 'big-e', 'شرکت بزرگ ه', 'saas_shared', NULL, NULL, NULL, NULL, NULL),
         (plt_t.u('TF'), 'elec-f', 'برق و', 'onprem', plt_t.u('R2'), now(), 'reseller_portal', NULL, NULL);
  PERFORM plt_t.ok('T06 creation event + runtime', (SELECT count(*) = 6 FROM platform.tenant_lifecycle_event e JOIN platform.tenant_runtime r USING (tenant_id)
                                                     WHERE e.seq = 1 AND e.to_status = 'provisioning' AND e.from_status IS NULL
                                                       AND tenant_id IN (SELECT id FROM plt_t.ids WHERE name IN ('TA','TB','TC','TD','TE','TF'))));
  PERFORM plt_t.ok('T06 creation enqueues desired-state build', (SELECT count(*) = 6 FROM platform.job WHERE kind = 'control.desired_state.build'
                                                                  AND dedupe_key LIKE 'lifecycle:%:1' AND (payload->>'tenant_id')::uuid <> plt_t.u('TH')));
  PERFORM plt_t.fails('T06 tenant created active', $q$INSERT INTO platform.tenant (slug, display_name, deployment, status) VALUES ('x-active', 'x', 'saas_shared', 'active')$q$,
    'HK_PLT_INVALID_TRANSITION%');
  PERFORM plt_t.fails('T06 app cannot create the house tenant', $q$INSERT INTO platform.tenant (slug, display_name, deployment, is_internal, is_house) VALUES ('x-house', 'x', 'saas_shared', true, true)$q$,
    'HK_PLT_IMMUTABLE_FIELD%');
  PERFORM plt_t.fails('T06 reseller attribution complete', format($q$INSERT INTO platform.tenant (slug, display_name, deployment, reseller_id) VALUES ('x-attr', 'x', 'saas_shared', %L)$q$, plt_t.u('R1')),
    '%tenant_check%');
  PERFORM plt_t.fails('T06 status only via lifecycle event', format($q$UPDATE platform.tenant SET status = 'active' WHERE id = %L$q$, plt_t.u('TA')),
    'HK_PLT_STATUS_VIA_EVENT%');
  PERFORM plt_t.fails('T06 deployment only via placement', format($q$UPDATE platform.tenant SET deployment = 'onprem' WHERE id = %L$q$, plt_t.u('TA')),
    'HK_PLT_DEPLOYMENT_VIA_PLACEMENT%');
  PERFORM plt_t.fails('T06 tenants are never deleted', format($q$DELETE FROM platform.tenant WHERE id = %L$q$, plt_t.u('TA')), '%permission denied%');

  -- جای‌گذاری
  INSERT INTO platform.tenant_placement (tenant_id, slug, cell_id, mode) VALUES
    (plt_t.u('TA'), 'cafe-a', 'cell-01', 'pooled'), (plt_t.u('TB'), 'shoes-b', 'cell-01', 'pooled'),
    (plt_t.u('TC'), 'elec-c', NULL, 'onprem'), (plt_t.u('TD'), 'gone-d', 'cell-01', 'pooled'),
    (plt_t.u('TF'), 'elec-f', NULL, 'onprem');
  PERFORM plt_t.fails('T06 placement starts pending', format($q$INSERT INTO platform.tenant_placement (tenant_id, slug, cell_id, mode, state) VALUES (%L, 'big-e', 'cell-01', 'pooled', 'active')$q$, plt_t.u('TE')),
    'HK_PLT_INVALID_TRANSITION%');
  PERFORM plt_t.fails('T06 SaaS placement needs a cell', format($q$INSERT INTO platform.tenant_placement (tenant_id, slug, cell_id, mode) VALUES (%L, 'big-e', NULL, 'pooled')$q$, plt_t.u('TE')),
    '%placement_onprem_no_cell%');
  PERFORM plt_t.fails('T06 onprem placement cannot use a cell', format($q$INSERT INTO platform.tenant_placement (tenant_id, slug, cell_id, mode) VALUES (%L, 'big-e', 'cell-01', 'onprem')$q$, plt_t.u('TE')),
    'HK_PLT_PLACEMENT_CELL_KIND%');
  PERFORM plt_t.fails('T06 slug must match tenant', format($q$INSERT INTO platform.tenant_placement (tenant_id, slug, cell_id, mode) VALUES (%L, 'other-slug', 'cell-01', 'pooled')$q$, plt_t.u('TE')),
    '%tenant_placement_tenant_id_slug_fkey%');
  PERFORM plt_t.fails('T06 dedicated mode on pooled cell', format($q$INSERT INTO platform.tenant_placement (tenant_id, slug, cell_id, mode) VALUES (%L, 'big-e', 'cell-01', 'dedicated')$q$, plt_t.u('TE')),
    'HK_PLT_PLACEMENT_CELL_KIND%');
  PERFORM plt_t.fails('T06 dedicated cell of another tenant', format($q$INSERT INTO platform.tenant_placement (tenant_id, slug, cell_id, mode) VALUES (%L, 'big-e', 'cell-ded', 'dedicated')$q$, plt_t.u('TE')),
    'HK_PLT_PLACEMENT_CELL_KIND%');
  UPDATE platform.cell SET dedicated_tenant_id = plt_t.u('TE') WHERE id = 'cell-ded';
  INSERT INTO platform.tenant_placement (tenant_id, slug, cell_id, mode) VALUES (plt_t.u('TE'), 'big-e', 'cell-ded', 'dedicated');
  PERFORM plt_t.ok('T06 deployment mirrors placement mode',
    (SELECT deployment = 'saas_dedicated' FROM platform.tenant WHERE id = plt_t.u('TE')));
  UPDATE platform.tenant_placement SET state = 'active' WHERE tenant_id IN (plt_t.u('TA'), plt_t.u('TB'), plt_t.u('TC'), plt_t.u('TD'), plt_t.u('TE'), plt_t.u('TF'));
  PERFORM plt_t.fails('T06 cell change without move', format($q$UPDATE platform.tenant_placement SET cell_id = 'cell-02' WHERE tenant_id = %L$q$, plt_t.u('TA')),
    'HK_PLT_PLACEMENT_MOVE%');
  PERFORM plt_t.fails('T06 moving needs a target', format($q$UPDATE platform.tenant_placement SET state = 'moving' WHERE tenant_id = %L$q$, plt_t.u('TA')),
    '%placement_moving_target%');
  PERFORM plt_t.fails('T06 move target must accept tenant', format($q$UPDATE platform.tenant_placement SET state = 'moving', move_target_mode = 'pooled', move_target_cell_id = 'cell-ded' WHERE tenant_id = %L$q$, plt_t.u('TA')),
    'HK_PLT_PLACEMENT_CELL_KIND%');
  UPDATE platform.tenant_placement SET state = 'moving', move_target_mode = 'pooled', move_target_cell_id = 'cell-02' WHERE tenant_id = plt_t.u('TA');
  PERFORM plt_t.fails('T06 complete move to undeclared cell', format($q$UPDATE platform.tenant_placement SET state = 'active', cell_id = 'cell-ded', mode = 'dedicated' WHERE tenant_id = %L$q$, plt_t.u('TA')),
    'HK_PLT_PLACEMENT_MOVE%');
  SELECT count(*) INTO v_jobs FROM platform.job WHERE kind = 'control.routing_snapshot.build';
  UPDATE platform.tenant_placement SET state = 'active', cell_id = 'cell-02' WHERE tenant_id = plt_t.u('TA');
  PERFORM plt_t.ok('T06 move completed', (SELECT cell_id = 'cell-02' AND move_target_cell_id IS NULL AND move_target_mode IS NULL
                                           FROM platform.tenant_placement WHERE tenant_id = plt_t.u('TA')));
  PERFORM plt_t.ok('T06 placement change enqueues routing snapshot', (SELECT count(*) > v_jobs FROM platform.job WHERE kind = 'control.routing_snapshot.build'));
  PERFORM plt_t.fails('T06 placement never deleted', format($q$DELETE FROM platform.tenant_placement WHERE tenant_id = %L$q$, plt_t.u('TA')), '%permission denied%');
END $$;

-- T06b چرخهٔ عمر: کاتالوگ گذار، کنشگر، دلیل، خروج، توقیف قانونی، پاک‌سازی با تأیید دونفره
DO $$
DECLARE
  v_appr uuid;
  v_hold uuid;
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('A'));
  INSERT INTO platform.tenant_lifecycle_event (tenant_id, seq, to_status, actor_kind, reason_code)
  SELECT id, 0, 'trial', 'system', 'provisioned' FROM plt_t.ids WHERE name IN ('TA','TB','TD');
  INSERT INTO platform.tenant_lifecycle_event (tenant_id, seq, to_status, actor_kind, actor_staff_id, reason_code, reason)
  SELECT id, 0, 'active', 'staff', plt_t.u('A'), 'onprem_sold', 'on-prem license sold by reseller' FROM plt_t.ids WHERE name IN ('TC','TE','TF');
  PERFORM plt_t.ok('T06b status applied by event', (SELECT status = 'trial' FROM platform.tenant WHERE id = plt_t.u('TA'))
                                                    AND (SELECT status = 'active' FROM platform.tenant WHERE id = plt_t.u('TC')));
  PERFORM plt_t.ok('T06b event seq and from_status', (SELECT seq = 2 AND from_status = 'provisioning' FROM platform.tenant_lifecycle_event
                                                       WHERE tenant_id = plt_t.u('TA') AND to_status = 'trial'));
  PERFORM plt_t.ok('T06b lifecycle enqueues desired-state build', EXISTS (SELECT 1 FROM platform.job WHERE kind = 'control.desired_state.build'
                                                                          AND dedupe_key = 'lifecycle:' || plt_t.u('TA') || ':2'));
  PERFORM plt_t.fails('T06b transition not in catalog',
    format($q$INSERT INTO platform.tenant_lifecycle_event (tenant_id, seq, to_status, actor_kind, reason_code) VALUES (%L, 0, 'purged', 'system', 'x_reason')$q$, plt_t.u('TA')),
    'HK_PLT_INVALID_TRANSITION%');
  PERFORM plt_t.fails('T06b actor not allowed for transition',
    format($q$INSERT INTO platform.tenant_lifecycle_event (tenant_id, seq, to_status, actor_kind, reason_code) VALUES (%L, 0, 'suspended', 'tenant', 'abuse')$q$, plt_t.u('TA')),
    'HK_PLT_INVALID_TRANSITION%');
  PERFORM plt_t.fails('T06b staff event needs a reason',
    format($q$INSERT INTO platform.tenant_lifecycle_event (tenant_id, seq, to_status, actor_kind, actor_staff_id, reason_code, reason) VALUES (%L, 0, 'suspended', 'staff', %L, 'abuse', 'short')$q$, plt_t.u('TA'), plt_t.u('A')),
    '%lifecycle_staff_reason%');
  PERFORM plt_t.fails('T06b staff event actor must be acting staff',
    format($q$INSERT INTO platform.tenant_lifecycle_event (tenant_id, seq, to_status, actor_kind, actor_staff_id, reason_code, reason) VALUES (%L, 0, 'suspended', 'staff', %L, 'abuse', 'abusive usage of sms')$q$, plt_t.u('TA'), plt_t.u('O')),
    'HK_PLT_ACTOR_MISMATCH%');
  PERFORM plt_t.fails('T06b approval on a transition without approval',
    format($q$INSERT INTO platform.tenant_lifecycle_event (tenant_id, seq, to_status, actor_kind, reason_code, approval_id) VALUES (%L, 0, 'cancelled', 'tenant', 'customer_request', %L)$q$,
           plt_t.u('TA'), plt_t.approve('tenant.purge', 'tenant', plt_t.u('TA'), plt_t.u('A'), plt_t.u('O'))),
    'HK_PLT_APPROVAL_MISMATCH%');
  PERFORM plt_t.fails('T06b creation event only by trigger',
    format($q$INSERT INTO platform.tenant_lifecycle_event (tenant_id, seq, to_status, actor_kind, reason_code) VALUES (%L, 0, 'provisioning', 'system', 'created')$q$, plt_t.u('TH')),
    'HK_PLT_INVALID_TRANSITION%');
  PERFORM plt_t.fails('T06b events are append-only', $q$UPDATE platform.tenant_lifecycle_event SET reason = 'x'$q$, '%permission denied%');

  -- TD: خروج، بایگانی و پاک‌سازی
  INSERT INTO platform.tenant_lifecycle_event (tenant_id, seq, to_status, actor_kind, reason_code) VALUES (plt_t.u('TD'), 0, 'cancelled', 'tenant', 'customer_request');
  PERFORM plt_t.fails('T06b archive needs offboarding record',
    format($q$INSERT INTO platform.tenant_lifecycle_event (tenant_id, seq, to_status, actor_kind, reason_code) VALUES (%L, 0, 'archived', 'system', 'window_over')$q$, plt_t.u('TD')),
    'HK_PLT_OFFBOARDING_REQUIRED%');
  INSERT INTO platform.tenant_offboarding (tenant_id, requested_via, export_window_ends, retention_until)
  VALUES (plt_t.u('TD'), 'tenant_owner', now() + interval '90 days', current_date + 3650);
  PERFORM plt_t.fails('T06b archive while export window open',
    format($q$INSERT INTO platform.tenant_lifecycle_event (tenant_id, seq, to_status, actor_kind, reason_code) VALUES (%L, 0, 'archived', 'system', 'window_over')$q$, plt_t.u('TD')),
    'HK_PLT_EXPORT_WINDOW_OPEN%');
  PERFORM plt_t.fails('T06b delivered export needs its hash',
    format($q$UPDATE platform.tenant_offboarding SET export_delivered_at = now() WHERE tenant_id = %L$q$, plt_t.u('TD')),
    '%tenant_offboarding_check%');
  UPDATE platform.tenant_offboarding SET export_delivered_at = now(), export_sha256 = plt_t.h('hkx-td') WHERE tenant_id = plt_t.u('TD');
  INSERT INTO platform.tenant_lifecycle_event (tenant_id, seq, to_status, actor_kind, reason_code) VALUES (plt_t.u('TD'), 0, 'archived', 'system', 'export_delivered');
  PERFORM plt_t.fails('T06b purge without approval',
    format($q$INSERT INTO platform.tenant_lifecycle_event (tenant_id, seq, to_status, actor_kind, actor_staff_id, reason_code, reason) VALUES (%L, 0, 'purging', 'staff', %L, 'retention_done', 'customer asked in writing')$q$, plt_t.u('TD'), plt_t.u('A')),
    'HK_PLT_APPROVAL_REQUIRED%');
  INSERT INTO platform.tenant_legal_hold (tenant_id, case_ref, reason, placed_by)
  VALUES (plt_t.u('TD'), 'CASE-77', 'court order for tax audit', plt_t.u('A')) RETURNING id INTO v_hold;
  v_appr := plt_t.approve('tenant.purge', 'tenant', plt_t.u('TD'), plt_t.u('A'), plt_t.u('O'));
  PERFORM plt_t.fails('T06b purge under legal hold',
    format($q$INSERT INTO platform.tenant_lifecycle_event (tenant_id, seq, to_status, actor_kind, actor_staff_id, reason_code, reason, approval_id) VALUES (%L, 0, 'purging', 'staff', %L, 'retention_done', 'customer asked in writing', %L)$q$, plt_t.u('TD'), plt_t.u('A'), v_appr),
    'HK_PLT_LEGAL_HOLD%');
  PERFORM plt_t.ok('T06b failed purge did not consume approval', (SELECT status = 'approved' FROM platform.approval_request WHERE id = v_appr));
  PERFORM plt_t.fails('T06b legal hold content immutable', format($q$UPDATE platform.tenant_legal_hold SET case_ref = 'X' WHERE id = %L$q$, v_hold), 'HK_PLT_IMMUTABLE_FIELD%');
  PERFORM plt_t.fails('T06b legal hold release needs approval',
    format($q$UPDATE platform.tenant_legal_hold SET released_at = now(), released_by = %L WHERE id = %L$q$, plt_t.u('A'), v_hold),
    'HK_PLT_APPROVAL_REQUIRED%');
  PERFORM plt_t.fails('T06b legal hold release approval must be approved',
    format($q$UPDATE platform.tenant_legal_hold SET released_at = now(), released_by = %L, release_approval_id = %L WHERE id = %L$q$, plt_t.u('A'), v_appr, v_hold),
    'HK_PLT_APPROVAL_MISMATCH%');
  UPDATE platform.tenant_legal_hold SET released_at = now(), released_by = plt_t.u('A'),
         release_approval_id = plt_t.approve('tenant.legal_hold_release', 'legal_hold', v_hold, plt_t.u('A'), plt_t.u('O'))
   WHERE id = v_hold;
  PERFORM plt_t.fails('T06b released hold is final', format($q$UPDATE platform.tenant_legal_hold SET released_at = now() + interval '1 day' WHERE id = %L$q$, v_hold),
    'HK_PLT_INVALID_TRANSITION%');
  PERFORM plt_t.fails('T06b hold never deleted', format($q$DELETE FROM platform.tenant_legal_hold WHERE id = %L$q$, v_hold), '%permission denied%');
  -- خروجی تحویل شده ولی نامهٔ کتبی و بایگانی تأییدشده نیست
  PERFORM plt_t.fails('T06b purge precondition',
    format($q$INSERT INTO platform.tenant_lifecycle_event (tenant_id, seq, to_status, actor_kind, actor_staff_id, reason_code, reason, approval_id) VALUES (%L, 0, 'purging', 'staff', %L, 'retention_done', 'customer asked in writing', %L)$q$, plt_t.u('TD'), plt_t.u('A'), v_appr),
    'HK_PLT_PURGE_PRECONDITION%');
  UPDATE platform.tenant_offboarding SET written_request_ref = 'LETTER-1405-12' WHERE tenant_id = plt_t.u('TD');
  INSERT INTO platform.tenant_lifecycle_event (tenant_id, seq, to_status, actor_kind, actor_staff_id, reason_code, reason, approval_id)
  VALUES (plt_t.u('TD'), 0, 'purging', 'staff', plt_t.u('A'), 'retention_done', 'customer asked in writing', v_appr);
  PERFORM plt_t.ok('T06b purge consumed approval', (SELECT status = 'consumed' FROM platform.approval_request WHERE id = v_appr)
                                                   AND (SELECT status = 'purging' FROM platform.tenant WHERE id = plt_t.u('TD')));
END $$;

-- T07 کانال کنترل: حالت مطلوب، runtime، نمای مسیریابی، حالت سلول، نگاشت وضعیت صفحهٔ داده
DO $$
DECLARE
  v_doc jsonb;
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('A'));
  v_doc := jsonb_build_object('format', 'hkstate/1', 'version', 1, 'tenant_id', plt_t.u('TA'), 'status', 'active',
                              'entitlements', '{}'::jsonb);
  INSERT INTO platform.desired_state (tenant_id, version, document, document_sha256, signature, kid, cause)
  VALUES (plt_t.u('TA'), 1, v_doc, plt_t.h(v_doc::text), plt_t.sig(), 'control-2026a', 'lifecycle');
  PERFORM plt_t.ok('T07 runtime follows desired state', (SELECT desired_version = 1 FROM platform.tenant_runtime WHERE tenant_id = plt_t.u('TA')));
  PERFORM plt_t.fails('T07 version gap',
    format($q$INSERT INTO platform.desired_state (tenant_id, version, document, document_sha256, signature, kid, cause)
              VALUES (%L, 3, jsonb_build_object('format','hkstate/1','version',3,'tenant_id',%L,'status','active','entitlements','{}'::jsonb), plt_t.h('x'), plt_t.sig(), 'k', 'manual')$q$,
           plt_t.u('TA'), plt_t.u('TA')),
    'HK_PLT_VERSION_SEQUENCE%');
  PERFORM plt_t.fails('T07 document must name the tenant',
    format($q$INSERT INTO platform.desired_state (tenant_id, version, document, document_sha256, signature, kid, cause)
              VALUES (%L, 2, jsonb_build_object('format','hkstate/1','version',2,'tenant_id',%L,'status','active','entitlements','{}'::jsonb), plt_t.h('x'), plt_t.sig(), 'k', 'manual')$q$,
           plt_t.u('TA'), plt_t.u('TB')),
    '%desired_state_document_shape%');
  PERFORM plt_t.fails('T07 desired status must be a data-plane status',
    format($q$INSERT INTO platform.desired_state (tenant_id, version, document, document_sha256, signature, kid, cause)
              VALUES (%L, 2, jsonb_build_object('format','hkstate/1','version',2,'tenant_id',%L,'status','trial','entitlements','{}'::jsonb), plt_t.h('x'), plt_t.sig(), 'k', 'manual')$q$,
           plt_t.u('TA'), plt_t.u('TA')),
    'HK_PLT_DOCUMENT_MISMATCH%');
  PERFORM plt_t.fails('T07 signature length',
    format($q$INSERT INTO platform.desired_state (tenant_id, version, document, document_sha256, signature, kid, cause)
              VALUES (%L, 2, jsonb_build_object('format','hkstate/1','version',2,'tenant_id',%L,'status','active','entitlements','{}'::jsonb), plt_t.h('x'), '\x00', 'k', 'manual')$q$,
           plt_t.u('TA'), plt_t.u('TA')),
    '%desired_state_signature_check%');
  PERFORM plt_t.fails('T07 desired state append-only', $q$UPDATE platform.desired_state SET kid = 'x'$q$, '%permission denied%');
  PERFORM plt_t.fails('T07 desired_version is derived', format($q$UPDATE platform.tenant_runtime SET desired_version = 5 WHERE tenant_id = %L$q$, plt_t.u('TA')),
    'HK_PLT_DERIVED_COLUMN%');
  PERFORM plt_t.fails('T07 applied <= desired', format($q$UPDATE platform.tenant_runtime SET applied_version = 2 WHERE tenant_id = %L$q$, plt_t.u('TA')),
    '%runtime_applied_le_desired%');
  UPDATE platform.tenant_runtime SET applied_version = 1, applied_at = now() WHERE tenant_id = plt_t.u('TA');
  PERFORM plt_t.fails('T07 stale ack', format($q$UPDATE platform.tenant_runtime SET applied_version = 0 WHERE tenant_id = %L$q$, plt_t.u('TA')),
    'HK_PLT_STALE_ACK%');
  -- نگاشت وضعیت به core.tenant.status
  PERFORM plt_t.ok('T07 data-plane status mapping',
       platform.data_plane_status('trial', 'active') = 'active' AND platform.data_plane_status('past_due', 'active') = 'active'
   AND platform.data_plane_status('cancelled', 'active') = 'read_only' AND platform.data_plane_status('read_only', 'active') = 'read_only'
   AND platform.data_plane_status('suspended', 'active') = 'suspended' AND platform.data_plane_status('archived', 'active') = 'archived'
   AND platform.data_plane_status('active', 'moving') = 'exporting' AND platform.data_plane_status('provisioning', 'pending') = 'provisioning'
   AND platform.data_plane_status('purging', 'active') = 'purge');
  -- نمای مسیریابی
  INSERT INTO platform.routing_snapshot (version, entries, document, sha256, signature, kid)
  VALUES (1, 1, jsonb_build_object('format','hkroute/1','version',1,'entries', jsonb_build_object('cafe-a', jsonb_build_object('cell','cell-02'))),
          plt_t.h('r1'), plt_t.sig(), 'control-2026a');
  PERFORM plt_t.fails('T07 routing version gap',
    $q$INSERT INTO platform.routing_snapshot (version, entries, document, sha256, signature, kid)
       VALUES (3, 0, jsonb_build_object('format','hkroute/1','version',3,'entries','{}'::jsonb), plt_t.h('r3'), plt_t.sig(), 'k')$q$,
    'HK_PLT_VERSION_SEQUENCE%');
  PERFORM plt_t.fails('T07 routing entry count',
    $q$INSERT INTO platform.routing_snapshot (version, entries, document, sha256, signature, kid)
       VALUES (2, 5, jsonb_build_object('format','hkroute/1','version',2,'entries','{}'::jsonb), plt_t.h('r2'), plt_t.sig(), 'k')$q$,
    'HK_PLT_DOCUMENT_MISMATCH%');
  -- حالت سلول
  INSERT INTO platform.cell_state (cell_id, version, document, document_sha256, signature, kid)
  VALUES ('cell-01', 1, jsonb_build_object('format','hkcellstate/1','version',1,'cell_id','cell-01','rules_packages','[]'::jsonb), plt_t.h('c1'), plt_t.sig(), 'control-2026a');
  PERFORM plt_t.fails('T07 cell state version gap',
    $q$INSERT INTO platform.cell_state (cell_id, version, document, document_sha256, signature, kid)
       VALUES ('cell-01', 5, jsonb_build_object('format','hkcellstate/1','version',5,'cell_id','cell-01'), plt_t.h('c5'), plt_t.sig(), 'k')$q$,
    'HK_PLT_VERSION_SEQUENCE%');
  PERFORM plt_t.fails('T07 cell state names its cell',
    $q$INSERT INTO platform.cell_state (cell_id, version, document, document_sha256, signature, kid)
       VALUES ('cell-01', 2, jsonb_build_object('format','hkcellstate/1','version',2,'cell_id','cell-02'), plt_t.h('c2'), plt_t.sig(), 'k')$q$,
    '%cell_state_check%');
END $$;

-- T08 فرمان سلول
DO $$
DECLARE
  v uuid;
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('A'));
  PERFORM plt_t.fails('T08 command must target tenant cell',
    format($q$INSERT INTO platform.cell_command (cell_id, tenant_id, kind, signature, kid, expires_at) VALUES ('cell-01', %L, 'tenant.export', plt_t.sig(), 'k', now() + interval '1 day')$q$, plt_t.u('TA')),
    'HK_PLT_COMMAND_WRONG_CELL%');
  PERFORM plt_t.fails('T08 provision only for provisioning tenant',
    format($q$INSERT INTO platform.cell_command (cell_id, tenant_id, kind, signature, kid, expires_at) VALUES ('cell-02', %L, 'tenant.provision', plt_t.sig(), 'k', now() + interval '1 day')$q$, plt_t.u('TA')),
    'HK_PLT_INVALID_TRANSITION%');
  PERFORM plt_t.fails('T08 purge only for purging tenant',
    format($q$INSERT INTO platform.cell_command (cell_id, tenant_id, kind, signature, kid, expires_at) VALUES ('cell-02', %L, 'tenant.purge', plt_t.sig(), 'k', now() + interval '1 day')$q$, plt_t.u('TA')),
    'HK_PLT_PURGE_PRECONDITION%');
  PERFORM plt_t.fails('T08 tenant command needs tenant',
    $q$INSERT INTO platform.cell_command (cell_id, kind, signature, kid, expires_at) VALUES ('cell-01', 'tenant.export', plt_t.sig(), 'k', now() + interval '1 day')$q$,
    '%cell_command_check%');
  INSERT INTO platform.cell_command (cell_id, tenant_id, kind, payload, signature, kid, expires_at, created_by)
  VALUES ('cell-01', plt_t.u('TD'), 'tenant.purge', '{"crypto_shred": true}', plt_t.sig(), 'control-2026a', now() + interval '1 day', plt_t.u('A'))
  RETURNING id INTO v;
  PERFORM plt_t.fails('T08 one open command per tenant/kind',
    format($q$INSERT INTO platform.cell_command (cell_id, tenant_id, kind, signature, kid, expires_at) VALUES ('cell-01', %L, 'tenant.purge', plt_t.sig(), 'k', now() + interval '1 day')$q$, plt_t.u('TD')),
    '%cell_command_one_open%');
  PERFORM plt_t.fails('T08 signed payload immutable', format($q$UPDATE platform.cell_command SET payload = '{}' WHERE id = %L$q$, v), 'HK_PLT_IMMUTABLE_FIELD%');
  PERFORM plt_t.fails('T08 queued -> succeeded', format($q$UPDATE platform.cell_command SET status = 'succeeded' WHERE id = %L$q$, v), 'HK_PLT_INVALID_TRANSITION%');
  UPDATE platform.cell_command SET status = 'delivered' WHERE id = v;
  UPDATE platform.cell_command SET status = 'succeeded', result = '{"rows_deleted": 1234}' WHERE id = v;
  PERFORM plt_t.ok('T08 command timestamps', (SELECT delivered_at IS NOT NULL AND finished_at IS NOT NULL FROM platform.cell_command WHERE id = v));
  PERFORM plt_t.fails('T08 finished command final', format($q$UPDATE platform.cell_command SET status = 'delivered' WHERE id = %L$q$, v), 'HK_PLT_INVALID_TRANSITION%');
  PERFORM plt_t.fails('T08 failed needs error',
    format($q$INSERT INTO platform.cell_command (cell_id, tenant_id, kind, signature, kid, expires_at, status) VALUES ('cell-02', %L, 'tenant.export', plt_t.sig(), 'k', now() + interval '1 day', 'failed')$q$, plt_t.u('TA')),
    'HK_PLT_INVALID_TRANSITION%');
  -- پایان پاک‌سازی: purging → purged و انجماد رکورد
  INSERT INTO platform.tenant_lifecycle_event (tenant_id, seq, to_status, actor_kind, reason_code) VALUES (plt_t.u('TD'), 0, 'purged', 'system', 'purge_confirmed');
  UPDATE platform.tenant_placement SET state = 'retired' WHERE tenant_id = plt_t.u('TD');
  PERFORM plt_t.fails('T08 purged tenant frozen', format($q$UPDATE platform.tenant SET display_name = 'x' WHERE id = %L$q$, plt_t.u('TD')), 'HK_PLT_TENANT_PURGED%');
END $$;

-- T09 انتشار، rollout، نسخهٔ کلاینت
DO $$
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('M'));
  PERFORM plt_t.fails('T09 min_from after version',
    $q$INSERT INTO platform.release (version, channel, release_date, min_from_version, schema_heads, manifest_sha256)
       VALUES ('2026.12.0', 'stable', '2026-12-01', '2027.1.0', '{"data_plane":"a","control_plane":"b"}', plt_t.h('m'))$q$,
    '%release_min_from_le_version%');
  PERFORM plt_t.fails('T09 published release must be signed',
    $q$INSERT INTO platform.release (version, channel, release_date, min_from_version, schema_heads, manifest_sha256, status)
       VALUES ('2026.12.0', 'stable', '2026-12-01', '2026.9.0', '{"data_plane":"a","control_plane":"b"}', plt_t.h('m'), 'published')$q$,
    '%release_check%');
  PERFORM plt_t.fails('T09 lts needs lts_until',
    $q$INSERT INTO platform.release (version, channel, release_date, min_from_version, schema_heads, manifest_sha256)
       VALUES ('2026.12.1', 'lts', '2026-12-01', '2026.9.0', '{"data_plane":"a","control_plane":"b"}', plt_t.h('m'))$q$,
    '%release_check%');
  INSERT INTO platform.release (version, channel, release_date, min_from_version, schema_heads, manifest_sha256)
  VALUES ('2026.12.0', 'stable', current_date, '2026.9.0', '{"data_plane":"a1","control_plane":"b1"}', plt_t.h('m12'));
  INSERT INTO platform.cell_rollout (release_version, cell_id, ring) VALUES ('2026.12.0', 'cell-01', 0), ('2026.12.0', 'cell-02', 2);
  PERFORM plt_t.fails('T09 rollout of unpublished release',
    $q$UPDATE platform.cell_rollout SET state = 'expanding' WHERE cell_id = 'cell-01'$q$, 'HK_PLT_RELEASE_NOT_PUBLISHED%');
  UPDATE platform.release SET status = 'published', released_at = now(), signature = plt_t.sig(), kid = 'release-2026a' WHERE version = '2026.12.0';
  UPDATE platform.cell_rollout SET state = 'expanding' WHERE release_version = '2026.12.0';
  UPDATE platform.cell_rollout SET state = 'expanded' WHERE cell_id = 'cell-01';
  PERFORM plt_t.fails('T09 roll before every cell expanded',
    $q$UPDATE platform.cell_rollout SET state = 'rolling' WHERE cell_id = 'cell-01'$q$, 'HK_PLT_ROLLOUT_ORDER%');
  UPDATE platform.cell_rollout SET state = 'expanded' WHERE cell_id = 'cell-02';
  PERFORM plt_t.fails('T09 higher ring before lower ring done',
    $q$UPDATE platform.cell_rollout SET state = 'rolling' WHERE cell_id = 'cell-02'$q$, 'HK_PLT_ROLLOUT_ORDER%');
  PERFORM plt_t.fails('T09 skip states', $q$UPDATE platform.cell_rollout SET state = 'done' WHERE cell_id = 'cell-01'$q$, 'HK_PLT_INVALID_TRANSITION%');
  UPDATE platform.cell_rollout SET state = 'rolling' WHERE cell_id = 'cell-01';
  UPDATE platform.cell_rollout SET state = 'paused' WHERE cell_id = 'cell-01';
  PERFORM plt_t.ok('T09 pause remembers state', (SELECT paused_from = 'rolling' FROM platform.cell_rollout WHERE cell_id = 'cell-01'));
  PERFORM plt_t.fails('T09 resume to other state', $q$UPDATE platform.cell_rollout SET state = 'rolled' WHERE cell_id = 'cell-01'$q$, 'HK_PLT_INVALID_TRANSITION%');
  UPDATE platform.cell_rollout SET state = 'rolling' WHERE cell_id = 'cell-01';
  UPDATE platform.cell_rollout SET state = 'rolled' WHERE cell_id = 'cell-01';
  UPDATE platform.cell_rollout SET state = 'verifying' WHERE cell_id = 'cell-01';
  UPDATE platform.cell_rollout SET state = 'done' WHERE cell_id = 'cell-01';
  UPDATE platform.cell_rollout SET state = 'rolling' WHERE cell_id = 'cell-02';
  UPDATE platform.cell_rollout SET state = 'rolled' WHERE cell_id = 'cell-02';
  UPDATE platform.cell_rollout SET state = 'verifying' WHERE cell_id = 'cell-02';
  PERFORM plt_t.fails('T09 ring 2 needs manual approval',
    $q$UPDATE platform.cell_rollout SET state = 'done' WHERE cell_id = 'cell-02'$q$, 'HK_PLT_ROLLOUT_MANUAL_APPROVAL%');
  PERFORM plt_t.fails('T09 manual approver must be acting release approver',
    format($q$UPDATE platform.cell_rollout SET state = 'done', manual_approved_by = %L WHERE cell_id = 'cell-02'$q$, plt_t.u('O')),
    'HK_PLT_ROLLOUT_MANUAL_APPROVAL%');
  UPDATE platform.cell_rollout SET state = 'done', manual_approved_by = plt_t.u('M') WHERE cell_id = 'cell-02';
  PERFORM plt_t.fails('T09 done is final', $q$UPDATE platform.cell_rollout SET state = 'paused' WHERE cell_id = 'cell-02'$q$, 'HK_PLT_INVALID_TRANSITION%');
  PERFORM plt_t.fails('T09 client min_supported after version',
    $q$INSERT INTO platform.client_release (app, platform, channel, version, min_supported_version, artifact_ref, sha256, size_bytes, signature, kid)
       VALUES ('pos', 'android', 'stable', '2026.12.0', '2027.1.0', 'files/x.apk', plt_t.h('a'), 100, plt_t.sig(), 'release-2026a')$q$,
    '%client_release_check%');
  INSERT INTO platform.client_release (app, platform, flavor, channel, version, min_supported_version, artifact_ref, sha256, size_bytes, signature, kid, status, released_at, rollout_percent)
  VALUES ('pos', 'android', 'direct', 'stable', '2026.12.0', '2026.10.0', 'files/pos.apk', plt_t.h('apk'), 41234567, plt_t.sig(), 'release-2026a', 'published', now(), 25);
  PERFORM plt_t.fails('T09 rollout percent range',
    $q$UPDATE platform.client_release SET rollout_percent = 150$q$, '%client_release_rollout_percent_check%');
END $$;

-- T10 کاتالوگ: پلن، افزونه، لایسنس، خدمت؛ پیش‌نویس → بازبینی → انتشار با تأیید «تغییر قیمت»
DO $$
DECLARE
  v_price uuid;
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('SL'));
  INSERT INTO platform.product (code, kind, name_fa, deployment, sstid) VALUES
    ('pro', 'plan', 'پلن حرفه‌ای', 'saas', '2710000138624'),
    ('extra_pos', 'addon', 'صندوق اضافه', 'saas', '2710000138624'),
    ('onprem_pro', 'license', 'لایسنس نصبی حرفه‌ای', 'onprem', '2710000138624'),
    ('assisted_migration', 'service', 'انتقال همراه کارشناس', 'any', '2710000138624'),
    ('sms_pack', 'credit_pack', 'بستهٔ پیامک', 'saas', NULL);
  PERFORM plt_t.fails('T10 license product must be onprem',
    $q$INSERT INTO platform.product (code, kind, name_fa, deployment) VALUES ('bad_lic', 'license', 'x', 'saas')$q$, '%product_check%');
  INSERT INTO platform.product_version (id, product_code, version, available_from, trial_days, created_by) VALUES
    (plt_t.u('PV1'), 'pro', 1, current_date - 30, 14, plt_t.u('SL')),
    (plt_t.u('PV2'), 'extra_pos', 1, current_date - 30, 0, plt_t.u('SL')),
    (plt_t.u('PV4'), 'assisted_migration', 1, current_date - 30, 0, plt_t.u('SL')),
    (plt_t.u('PV5'), 'pro', 2, current_date + 30, 14, plt_t.u('SL'));
  INSERT INTO platform.product_version (id, product_code, version, available_from, license_model, updates_months, created_by)
  VALUES (plt_t.u('PV3'), 'onprem_pro', 1, current_date - 30, 'perpetual', 12, plt_t.u('SL'));
  PERFORM plt_t.fails('T10 license version needs license model',
    $q$INSERT INTO platform.product_version (product_code, version, available_from) VALUES ('onprem_pro', 9, current_date)$q$, 'HK_PLT_PRODUCT_SHAPE%');
  PERFORM plt_t.fails('T10 only plans have trials',
    $q$INSERT INTO platform.product_version (product_code, version, available_from, trial_days) VALUES ('extra_pos', 9, current_date, 7)$q$, 'HK_PLT_PRODUCT_SHAPE%');
  PERFORM plt_t.fails('T10 versions start as draft',
    $q$INSERT INTO platform.product_version (product_code, version, available_from, status) VALUES ('pro', 9, current_date, 'published')$q$, 'HK_PLT_INVALID_TRANSITION%');
  PERFORM plt_t.fails('T10 review needs a price', format($q$UPDATE platform.product_version SET status = 'in_review' WHERE id = %L$q$, plt_t.u('PV1')), 'HK_PLT_PRODUCT_SHAPE%');
  INSERT INTO platform.price (product_version_id, billing_period) VALUES (plt_t.u('PV1'), 'P1M') RETURNING id INTO v_price;
  PERFORM plt_t.fails('T10 price needs a component', format($q$UPDATE platform.product_version SET status = 'in_review' WHERE id = %L$q$, plt_t.u('PV1')), 'HK_PLT_PRODUCT_SHAPE%');
  INSERT INTO platform.price_component (price_id, line_no, kind, unit_amount) VALUES (v_price, 1, 'flat', 10000000);
  PERFORM plt_t.fails('T10 tiers ascending',
    format($q$INSERT INTO platform.price_component (price_id, line_no, kind, metric_key, tiers)
              VALUES (%L, 2, 'tiered', 'limit.users', '[{"up_to": 10, "unit_amount": "500000"}, {"up_to": 5, "unit_amount": "400000"}, {"up_to": null, "unit_amount": "300000"}]')$q$, v_price),
    'HK_PLT_PRICE_SHAPE%');
  PERFORM plt_t.fails('T10 last tier open-ended',
    format($q$INSERT INTO platform.price_component (price_id, line_no, kind, metric_key, tiers)
              VALUES (%L, 2, 'tiered', 'limit.users', '[{"up_to": 10, "unit_amount": "500000"}]')$q$, v_price),
    'HK_PLT_PRICE_SHAPE%');
  PERFORM plt_t.fails('T10 tier amount is an integer-rial string',
    format($q$INSERT INTO platform.price_component (price_id, line_no, kind, metric_key, tiers)
              VALUES (%L, 2, 'tiered', 'limit.users', '[{"up_to": null, "unit_amount": 300000.5}]')$q$, v_price),
    'HK_PLT_PRICE_SHAPE%');
  PERFORM plt_t.fails('T10 pricing metric not a flag',
    format($q$INSERT INTO platform.price_component (price_id, line_no, kind, metric_key, unit_amount) VALUES (%L, 2, 'per_unit', 'module.pos', 1000)$q$, v_price),
    'HK_PLT_PRICE_SHAPE%');
  INSERT INTO platform.price_component (price_id, line_no, kind, metric_key, included_qty, tiers) VALUES
    (v_price, 2, 'tiered', 'limit.users', 5, '[{"up_to": 10, "unit_amount": "500000"}, {"up_to": null, "unit_amount": "300000"}]');
  PERFORM plt_t.fails('T10 flag entitlement shape',
    format($q$INSERT INTO platform.product_entitlement (product_version_id, feature_key, enabled, limit_value) VALUES (%L, 'module.pos', true, 3)$q$, plt_t.u('PV1')),
    'HK_PLT_ENTITLEMENT_SHAPE%');
  PERFORM plt_t.fails('T10 plan entitlements are set',
    format($q$INSERT INTO platform.product_entitlement (product_version_id, feature_key, limit_value, combine) VALUES (%L, 'limit.users', 3, 'add')$q$, plt_t.u('PV1')),
    'HK_PLT_ENTITLEMENT_SHAPE%');
  INSERT INTO platform.product_entitlement (product_version_id, feature_key, enabled, limit_value, enforcement, overage_pct) VALUES
    (plt_t.u('PV1'), 'module.accounting', true, NULL, 'hard', 0), (plt_t.u('PV1'), 'module.pos', true, NULL, 'hard', 0),
    (plt_t.u('PV1'), 'limit.users', NULL, 5, 'soft', 10), (plt_t.u('PV1'), 'limit.pos_devices', NULL, 2, 'hard', 0),
    (plt_t.u('PV1'), 'limit.companies', NULL, 1, 'hard', 0), (plt_t.u('PV1'), 'limit.invoices_per_month', NULL, NULL, 'hard', 0);
  INSERT INTO platform.price (product_version_id, billing_period) VALUES (plt_t.u('PV2'), 'P1M') RETURNING id INTO v_price;
  INSERT INTO platform.price_component (price_id, line_no, kind, unit_amount) VALUES (v_price, 1, 'flat', 2000000);
  PERFORM plt_t.fails('T10 addon limits add',
    format($q$INSERT INTO platform.product_entitlement (product_version_id, feature_key, limit_value, combine) VALUES (%L, 'limit.pos_devices', 1, 'set')$q$, plt_t.u('PV2')),
    'HK_PLT_ENTITLEMENT_SHAPE%');
  INSERT INTO platform.product_entitlement (product_version_id, feature_key, limit_value, combine) VALUES (plt_t.u('PV2'), 'limit.pos_devices', 1, 'add_per_unit');
  PERFORM plt_t.fails('T10 services carry no entitlements',
    format($q$INSERT INTO platform.product_entitlement (product_version_id, feature_key, enabled) VALUES (%L, 'module.pos', true)$q$, plt_t.u('PV4')),
    'HK_PLT_ENTITLEMENT_SHAPE%');
  INSERT INTO platform.price (product_version_id, billing_period) VALUES (plt_t.u('PV3'), 'ONCE') RETURNING id INTO v_price;
  INSERT INTO platform.price_component (price_id, line_no, kind, unit_amount) VALUES (v_price, 1, 'flat', 500000000);
  INSERT INTO platform.product_entitlement (product_version_id, feature_key, limit_value) VALUES (plt_t.u('PV3'), 'limit.users', 10);
  INSERT INTO platform.price (product_version_id, billing_period) VALUES (plt_t.u('PV4'), 'ONCE') RETURNING id INTO v_price;
  INSERT INTO platform.price_component (price_id, line_no, kind, unit_amount) VALUES (v_price, 1, 'flat', 30000000);

  UPDATE platform.product_version SET status = 'in_review' WHERE id IN (plt_t.u('PV1'), plt_t.u('PV2'), plt_t.u('PV3'), plt_t.u('PV4'));
  PERFORM plt_t.fails('T10 price frozen in review', format($q$UPDATE platform.price_component SET unit_amount = 1 WHERE price_id IN (SELECT id FROM platform.price WHERE product_version_id = %L)$q$, plt_t.u('PV1')),
    'HK_PLT_PRODUCT_FROZEN%');
  PERFORM plt_t.fails('T10 entitlement frozen in review', format($q$DELETE FROM platform.product_entitlement WHERE product_version_id = %L$q$, plt_t.u('PV1')),
    'HK_PLT_PRODUCT_FROZEN%');
  PERFORM plt_t.fails('T10 version content frozen in review', format($q$UPDATE platform.product_version SET grace_days = 1 WHERE id = %L$q$, plt_t.u('PV1')),
    'HK_PLT_PRODUCT_FROZEN%');
  PERFORM plt_t.fails('T10 publish without approval',
    format($q$UPDATE platform.product_version SET status = 'published', published_by = %L WHERE id = %L$q$, plt_t.u('SL'), plt_t.u('PV1')),
    'HK_PLT_APPROVAL_REQUIRED%');
  PERFORM plt_t.fails('T10 published_by must be actor',
    format($q$UPDATE platform.product_version SET status = 'published', published_by = %L WHERE id = %L$q$, plt_t.u('O'), plt_t.u('PV1')),
    'HK_PLT_ACTOR_MISMATCH%');
  UPDATE platform.product_version SET status = 'published', published_by = plt_t.u('SL'),
         approval_id = plt_t.approve('price.publish', 'product_version', id, plt_t.u('SL'), plt_t.u('A'))
   WHERE id IN (plt_t.u('PV1'), plt_t.u('PV2'), plt_t.u('PV3'), plt_t.u('PV4'));
  PERFORM plt_t.ok('T10 published', (SELECT count(*) = 4 FROM platform.product_version WHERE status = 'published' AND published_at IS NOT NULL));
  PERFORM plt_t.fails('T10 published version frozen', format($q$UPDATE platform.product_version SET trial_days = 30 WHERE id = %L$q$, plt_t.u('PV1')),
    'HK_PLT_PRODUCT_FROZEN%');
  PERFORM plt_t.fails('T10 published price frozen', format($q$INSERT INTO platform.price (product_version_id, billing_period) VALUES (%L, 'P1Y')$q$, plt_t.u('PV1')),
    'HK_PLT_PRODUCT_FROZEN%');
  PERFORM plt_t.fails('T10 published version not deletable', format($q$DELETE FROM platform.product_version WHERE id = %L$q$, plt_t.u('PV1')),
    'HK_PLT_IMMUTABLE%');
  PERFORM plt_t.fails('T10 published -> draft', format($q$UPDATE platform.product_version SET status = 'draft' WHERE id = %L$q$, plt_t.u('PV1')),
    'HK_PLT_INVALID_TRANSITION%');
END $$;

-- T11 حساب صورتحساب، اشتراک، دورهٔ آزمایشی، اقلام
DO $$
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('F'));
  INSERT INTO platform.billing_account (id, owner_kind, tenant_id, reseller_id, buyer_type, legal_name, national_id, economic_code, postal_code, billing_mobile) VALUES
    (plt_t.u('BA_A'), 'tenant', plt_t.u('TA'), NULL, 'legal', 'کافه الف', '10320000001', '411111111111', '1234567890', '09121111111'),
    (plt_t.u('BA_B'), 'tenant', plt_t.u('TB'), NULL, 'unregistered', 'کفش ب', NULL, NULL, NULL, '09122222222'),
    (plt_t.u('BA_C'), 'tenant', plt_t.u('TC'), NULL, 'natural', 'برق ج', '0012345679', NULL, NULL, '09123333333'),
    (plt_t.u('BA_R1'), 'reseller', NULL, plt_t.u('R1'), 'legal', 'نمایندگی یک', '10101010101', NULL, NULL, '09124444444');
  PERFORM plt_t.fails('T11 legal buyer needs 11-digit national id',
    format($q$INSERT INTO platform.billing_account (owner_kind, tenant_id, buyer_type, legal_name, national_id, billing_mobile) VALUES ('tenant', %L, 'legal', 'x', '0012345679', '09120000000')$q$, plt_t.u('TE')),
    '%billing_buyer_identity%');
  PERFORM plt_t.fails('T11 single owner',
    format($q$INSERT INTO platform.billing_account (owner_kind, tenant_id, reseller_id, buyer_type, legal_name, billing_mobile) VALUES ('tenant', %L, %L, 'unregistered', 'x', '09120000000')$q$, plt_t.u('TE'), plt_t.u('R2')),
    '%billing_account_check%');
  PERFORM plt_t.fails('T11 plan not yet available',
    format($q$INSERT INTO platform.subscription (tenant_id, billing_account_id, plan_version_id, billing_period, trial_ends_on) VALUES (%L, %L, %L, 'P1M', current_date)$q$, plt_t.u('TA'), plt_t.u('BA_A'), plt_t.u('PV5')),
    'HK_PLT_PLAN_NOT_AVAILABLE%');
  PERFORM plt_t.fails('T11 addon is not a plan',
    format($q$INSERT INTO platform.subscription (tenant_id, billing_account_id, plan_version_id, billing_period, trial_ends_on) VALUES (%L, %L, %L, 'P1M', current_date)$q$, plt_t.u('TA'), plt_t.u('BA_A'), plt_t.u('PV2')),
    'HK_PLT_PLAN_NOT_AVAILABLE%');
  PERFORM plt_t.fails('T11 billing account of another tenant',
    format($q$INSERT INTO platform.subscription (tenant_id, billing_account_id, plan_version_id, billing_period, trial_ends_on) VALUES (%L, %L, %L, 'P1M', current_date)$q$, plt_t.u('TA'), plt_t.u('BA_B'), plt_t.u('PV1')),
    'HK_PLT_BILLING_ACCOUNT_MISMATCH%');
  INSERT INTO platform.subscription (id, tenant_id, billing_account_id, plan_version_id, billing_period, trial_ends_on, reseller_id) VALUES
    (plt_t.u('SUB_A'), plt_t.u('TA'), plt_t.u('BA_A'), plt_t.u('PV1'), 'P1M', current_date, plt_t.u('R1')),
    (plt_t.u('SUB_B'), plt_t.u('TB'), plt_t.u('BA_B'), plt_t.u('PV1'), 'P1M', current_date + 14, plt_t.u('R2'));
  PERFORM plt_t.fails('T11 one live subscription per tenant',
    format($q$INSERT INTO platform.subscription (tenant_id, billing_account_id, plan_version_id, billing_period, trial_ends_on) VALUES (%L, %L, %L, 'P1M', current_date)$q$, plt_t.u('TA'), plt_t.u('BA_A'), plt_t.u('PV1')),
    '%subscription_one_live%');
  PERFORM plt_t.fails('T11 trial needs a claim',
    format($q$INSERT INTO platform.subscription_term (subscription_id, kind, period_start, period_end) VALUES (%L, 'trial', current_date - 14, current_date)$q$, plt_t.u('SUB_A')),
    'HK_PLT_TRIAL_CLAIM_REQUIRED%');
  INSERT INTO platform.trial_claim (identity_kind, identity_hmac, tenant_id) VALUES ('mobile', plt_t.h('09121111111'), plt_t.u('TA'));
  PERFORM plt_t.fails('T11 one trial per identity',
    format($q$INSERT INTO platform.trial_claim (identity_kind, identity_hmac, tenant_id) VALUES ('mobile', plt_t.h('09121111111'), %L)$q$, plt_t.u('TB')),
    '%trial_claim_pkey%');
  PERFORM plt_t.fails('T11 trial too long',
    format($q$INSERT INTO platform.subscription_term (subscription_id, kind, period_start, period_end) VALUES (%L, 'trial', current_date - 20, current_date)$q$, plt_t.u('SUB_A')),
    'HK_PLT_TRIAL_TOO_LONG%');
  INSERT INTO platform.subscription_term (subscription_id, kind, period_start, period_end) VALUES (plt_t.u('SUB_A'), 'trial', current_date - 14, current_date);
  PERFORM plt_t.ok('T11 trial active and covered', (SELECT covered_through = current_date FROM platform.subscription WHERE id = plt_t.u('SUB_A'))
                                                   AND (SELECT status = 'active' FROM platform.subscription_term WHERE subscription_id = plt_t.u('SUB_A') AND kind = 'trial'));
  INSERT INTO platform.trial_claim (identity_kind, identity_hmac, tenant_id) VALUES ('national_id', plt_t.h('10320000001'), plt_t.u('TA'));
  PERFORM plt_t.fails('T11 second trial for tenant',
    format($q$INSERT INTO platform.subscription_term (subscription_id, kind, period_start, period_end) VALUES (%L, 'trial', current_date + 100, current_date + 101)$q$, plt_t.u('SUB_A')),
    'HK_PLT_TRIAL_USED%');
  PERFORM plt_t.fails('T11 covered_through is derived', format($q$UPDATE platform.subscription SET covered_through = current_date + 365 WHERE id = %L$q$, plt_t.u('SUB_A')),
    'HK_PLT_DERIVED_COLUMN%');
  PERFORM plt_t.fails('T11 comp term needs approval',
    format($q$INSERT INTO platform.subscription_term (subscription_id, kind, period_start, period_end) VALUES (%L, 'comp', current_date + 200, current_date + 230)$q$, plt_t.u('SUB_B')),
    'HK_PLT_APPROVAL_REQUIRED%');
  PERFORM plt_t.fails('T11 subscription owner immutable', format($q$UPDATE platform.subscription SET tenant_id = %L WHERE id = %L$q$, plt_t.u('TB'), plt_t.u('SUB_A')),
    'HK_PLT_IMMUTABLE_FIELD%');
  -- اقلام: افزونه و واحد اضافهٔ پلن
  PERFORM plt_t.fails('T11 metric item must be own plan',
    format($q$INSERT INTO platform.subscription_item (subscription_id, product_version_id, metric_key, quantity, valid_from) VALUES (%L, %L, 'limit.users', 2, current_date)$q$, plt_t.u('SUB_A'), plt_t.u('PV2')),
    'HK_PLT_ITEM_SHAPE%');
  PERFORM plt_t.fails('T11 non-metric item must be addon',
    format($q$INSERT INTO platform.subscription_item (subscription_id, product_version_id, quantity, valid_from) VALUES (%L, %L, 1, current_date)$q$, plt_t.u('SUB_A'), plt_t.u('PV4')),
    'HK_PLT_ITEM_SHAPE%');
  INSERT INTO platform.subscription_item (subscription_id, product_version_id, metric_key, quantity, valid_from) VALUES
    (plt_t.u('SUB_A'), plt_t.u('PV2'), NULL, 3, current_date - 1), (plt_t.u('SUB_A'), plt_t.u('PV1'), 'limit.users', 2, current_date - 1);
  PERFORM plt_t.fails('T11 items do not overlap',
    format($q$INSERT INTO platform.subscription_item (subscription_id, product_version_id, quantity, valid_from) VALUES (%L, %L, 1, current_date + 5)$q$, plt_t.u('SUB_A'), plt_t.u('PV2')),
    '%subscription_item_no_overlap%');
  PERFORM plt_t.fails('T11 items change only by closing',
    format($q$UPDATE platform.subscription_item SET quantity = 9 WHERE subscription_id = %L AND metric_key IS NULL$q$, plt_t.u('SUB_A')),
    'HK_PLT_IMMUTABLE_FIELD%');
END $$;

-- T12 صورتحساب، شماره‌گذاری بی‌فاصله، پیش‌پرداخت، پرداخت درگاه (زرین‌پال، ملت ۴۸، دیرهنگام، بانکی)، ابطال، یادداشت اعتباری
DO $$
DECLARE
  v_n int;
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('F'));
  INSERT INTO platform.gateway_account (id, provider, role, merchant_secret_ref, callback_base_url, api_amount_unit) VALUES
    (plt_t.u('GW1'), 'zarinpal', 'primary', 'openbao://kv/platform/gw/zarinpal', 'https://pay.hk.test/cb', 'IRT'),
    (plt_t.u('GW2'), 'mellat', 'fallback', 'openbao://kv/platform/gw/mellat', 'https://pay.hk.test/cb', 'IRR');
  PERFORM plt_t.fails('T12 one primary gateway',
    $q$INSERT INTO platform.gateway_account (provider, role, merchant_secret_ref, callback_base_url, api_amount_unit) VALUES ('zibal', 'primary', 'openbao://kv/platform/gw/zibal', 'https://pay.hk.test/cb', 'IRR')$q$,
    '%gateway_one_primary%');
  PERFORM plt_t.fails('T12 gateway secret is a reference',
    $q$INSERT INTO platform.gateway_account (provider, role, merchant_secret_ref, callback_base_url, api_amount_unit) VALUES ('zibal', 'fallback', 'merchant-xyz-secret', 'https://pay.hk.test/cb', 'IRR')$q$,
    '%gateway_account_merchant_secret_ref_check%');

  INSERT INTO platform.invoice (id, billing_account_id, tenant_id, period_key, due_date) VALUES
    (plt_t.u('INV1'), plt_t.u('BA_A'), plt_t.u('TA'), 'jy:1405', current_date + 3),
    (plt_t.u('INV2'), plt_t.u('BA_A'), plt_t.u('TA'), NULL, current_date + 3),
    (plt_t.u('INV8'), plt_t.u('BA_B'), plt_t.u('TB'), 'jy:1405', current_date + 3),
    (plt_t.u('INV6'), plt_t.u('BA_B'), plt_t.u('TB'), 'jy:1405', current_date + 3),
    (plt_t.u('INV9'), plt_t.u('BA_A'), plt_t.u('TA'), 'jy:1405', current_date + 3);
  PERFORM plt_t.fails('T12 invoice billing account must match tenant',
    format($q$INSERT INTO platform.invoice (billing_account_id, tenant_id) VALUES (%L, %L)$q$, plt_t.u('BA_B'), plt_t.u('TA')),
    'HK_PLT_BILLING_ACCOUNT_MISMATCH%');
  PERFORM plt_t.fails('T12 invoices start as drafts',
    format($q$INSERT INTO platform.invoice (billing_account_id, tenant_id, status) VALUES (%L, %L, 'issued')$q$, plt_t.u('BA_A'), plt_t.u('TA')),
    'HK_PLT_INVALID_TRANSITION%');
  PERFORM plt_t.fails('T12 line amount = trunc(qty x unit)',
    format($q$INSERT INTO platform.invoice_line (invoice_id, line_no, line_kind, description, quantity, unit_amount, amount, vat_rate_pct, vat_amount, total)
              VALUES (%L, 1, 'subscription', 'x', 1, 10000000, 9000000, 10, 900000, 9900000)$q$, plt_t.u('INV1')),
    '%invoice_line_amount%');
  PERFORM plt_t.fails('T12 VAT is truncated, never rounded up',
    format($q$INSERT INTO platform.invoice_line (invoice_id, line_no, line_kind, description, quantity, unit_amount, amount, vat_rate_pct, vat_amount, total)
              VALUES (%L, 1, 'subscription', 'x', 1, 999, 999, 10, 100, 1099)$q$, plt_t.u('INV1')),
    '%invoice_line_vat%');
  PERFORM plt_t.fails('T12 line total',
    format($q$INSERT INTO platform.invoice_line (invoice_id, line_no, line_kind, description, quantity, unit_amount, amount, vat_rate_pct, vat_amount, total)
              VALUES (%L, 1, 'subscription', 'x', 1, 999, 999, 10, 99, 1000)$q$, plt_t.u('INV1')),
    '%invoice_line_total%');
  PERFORM plt_t.fails('T12 discount at most amount',
    format($q$INSERT INTO platform.invoice_line (invoice_id, line_no, line_kind, description, quantity, unit_amount, amount, discount, vat_rate_pct, vat_amount, total)
              VALUES (%L, 1, 'subscription', 'x', 1, 999, 999, 1000, 10, 0, -1)$q$, plt_t.u('INV1')),
    '%invoice_line_discount%');
  INSERT INTO platform.invoice_line (id, invoice_id, line_no, line_kind, product_version_id, description, sstid, period_start, period_end,
                                     quantity, unit_amount, amount, discount, vat_rate_pct, vat_amount, total) VALUES
    (plt_t.u('L1'), plt_t.u('INV1'), 1, 'subscription', plt_t.u('PV1'), 'اشتراک ماهانهٔ پلن حرفه‌ای', '2710000138624', current_date, current_date + 30,
     1, 10000000, 10000000, 0, 10, 1000000, 11000000),
    (plt_t.u('L2'), plt_t.u('INV2'), 1, 'adjustment', NULL, 'تعدیل', NULL, NULL, NULL, 1, 1000000, 1000000, 0, 10, 100000, 1100000);
  PERFORM plt_t.fails('T12 header totals equal lines',
    format($q$UPDATE platform.invoice SET status = 'issued', issued_by = %L WHERE id = %L$q$, plt_t.u('F'), plt_t.u('INV1')),
    'HK_PLT_INVOICE_TOTALS%');
  PERFORM plt_t.fails('T12 header arithmetic',
    format($q$UPDATE platform.invoice SET subtotal = 10000000, vat_total = 1000000, total = 1 WHERE id = %L$q$, plt_t.u('INV1')),
    '%invoice_totals%');
  UPDATE platform.invoice SET subtotal = 10000000, vat_total = 1000000, total = 11000000 WHERE id = plt_t.u('INV1');
  UPDATE platform.invoice SET subtotal = 1000000, vat_total = 100000, total = 1100000 WHERE id = plt_t.u('INV2');
  PERFORM plt_t.fails('T12 empty invoice', format($q$UPDATE platform.invoice SET status = 'issued' WHERE id = %L$q$, plt_t.u('INV9')), 'HK_PLT_INVOICE_EMPTY%');
  PERFORM plt_t.fails('T12 numbering needs period', format($q$UPDATE platform.invoice SET status = 'issued' WHERE id = %L$q$, plt_t.u('INV2')), 'HK_PLT_INVOICE_PERIOD%');
  PERFORM plt_t.fails('T12 issued_by must be actor', format($q$UPDATE platform.invoice SET status = 'issued', issued_by = %L WHERE id = %L$q$, plt_t.u('O'), plt_t.u('INV1')),
    'HK_PLT_ACTOR_MISMATCH%');
  PERFORM plt_t.fails('T12 direct number draw', $q$SELECT platform.number_next('invoice', 'jy:1405', 'INV-1405-')$q$, 'HK_PLT_NUMBER_DIRECT%');
  UPDATE platform.invoice SET status = 'issued', issued_by = plt_t.u('F') WHERE id = plt_t.u('INV1');
  PERFORM plt_t.ok('T12 issued fields', (SELECT number = 'INV-1405-000001' AND issued_at IS NOT NULL AND issue_date = current_date
                                           AND reseller_id = plt_t.u('R1') AND buyer_snapshot->>'legal_name' = 'کافه الف'
                                           FROM platform.invoice WHERE id = plt_t.u('INV1')));
  PERFORM plt_t.ok('T12 issue creates house sync + job', EXISTS (SELECT 1 FROM platform.house_sync WHERE doc_type = 'invoice' AND doc_id = plt_t.u('INV1')
                                                                   AND status = 'pending' AND house_tenant_id = plt_t.u('TH'))
                                                        AND EXISTS (SELECT 1 FROM platform.job WHERE kind = 'billing.house_sync' AND dedupe_key = 'house:' || plt_t.u('INV1')));
  PERFORM plt_t.fails('T12 direct counter move', $q$UPDATE platform.number_counter SET next_value = next_value + 1$q$, 'HK_PLT_NUMBER_DIRECT%');
  -- یک صدور که rollback می‌شود شماره را نمی‌سوزاند
  UPDATE platform.invoice SET period_key = 'jy:1405' WHERE id = plt_t.u('INV2');
  BEGIN
    UPDATE platform.invoice SET status = 'issued' WHERE id = plt_t.u('INV2');
    RAISE EXCEPTION 'rollback-probe';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'rollback-probe' THEN RAISE; END IF;
  END;
  UPDATE platform.invoice SET status = 'issued' WHERE id = plt_t.u('INV2');
  PERFORM plt_t.ok('T12 gapless after rollback', (SELECT number = 'INV-1405-000002' FROM platform.invoice WHERE id = plt_t.u('INV2')));
  PERFORM plt_t.fails('T12 issued line frozen', format($q$UPDATE platform.invoice_line SET description = 'x' WHERE id = %L$q$, plt_t.u('L1')), 'HK_PLT_INVOICE_FROZEN%');
  PERFORM plt_t.fails('T12 issued header frozen', format($q$UPDATE platform.invoice SET due_date = current_date + 30 WHERE id = %L$q$, plt_t.u('INV1')), 'HK_PLT_INVOICE_FROZEN%');
  PERFORM plt_t.fails('T12 paid_amount derived', format($q$UPDATE platform.invoice SET paid_amount = 11000000 WHERE id = %L$q$, plt_t.u('INV1')), 'HK_PLT_DERIVED_COLUMN%');
  PERFORM plt_t.fails('T12 paid only via settlement', format($q$UPDATE platform.invoice SET status = 'paid' WHERE id = %L$q$, plt_t.u('INV1')), 'HK_PLT_DERIVED_COLUMN%');
  PERFORM plt_t.fails('T12 issued invoice not deletable', format($q$DELETE FROM platform.invoice WHERE id = %L$q$, plt_t.u('INV1')), 'HK_PLT_IMMUTABLE%');

  -- دورهٔ پرداختی (پیش‌پرداخت)
  INSERT INTO platform.subscription_term (subscription_id, kind, period_start, period_end, invoice_id)
  VALUES (plt_t.u('SUB_A'), 'paid', current_date, current_date + 30, plt_t.u('INV1'));
  PERFORM plt_t.ok('T12 paid term pending until payment', (SELECT status = 'pending' FROM platform.subscription_term WHERE invoice_id = plt_t.u('INV1')));
  PERFORM plt_t.fails('T12 terms do not overlap',
    format($q$INSERT INTO platform.subscription_term (subscription_id, kind, period_start, period_end, invoice_id) VALUES (%L, 'paid', current_date + 20, current_date + 50, %L)$q$, plt_t.u('SUB_A'), plt_t.u('INV2')),
    '%term_no_overlap%');
  PERFORM plt_t.fails('T12 term invoice of another tenant',
    format($q$INSERT INTO platform.subscription_term (subscription_id, kind, period_start, period_end, invoice_id) VALUES (%L, 'paid', current_date + 60, current_date + 90, %L)$q$, plt_t.u('SUB_A'), plt_t.u('INV8')),
    'HK_PLT_TERM_INVOICE%');
  PERFORM plt_t.fails('T12 prepaid only',
    format($q$UPDATE platform.subscription_term SET status = 'active' WHERE invoice_id = %L$q$, plt_t.u('INV1')), 'HK_PLT_PREPAID_ONLY%');

  -- پرداخت درگاه
  PERFORM plt_t.fails('T12 payment amount = outstanding',
    format($q$INSERT INTO platform.payment (payer_kind, billing_account_id, tenant_id, purpose, invoice_id, method, gateway_account_id, provider, order_id, amount, api_amount, api_amount_unit, expires_at)
              VALUES ('tenant', %L, %L, 'invoice', %L, 'gateway', %L, 'zarinpal', 'ORD-BAD-1', 10, 1, 'IRT', now() + interval '30 minutes')$q$,
           plt_t.u('BA_A'), plt_t.u('TA'), plt_t.u('INV1'), plt_t.u('GW1')),
    'HK_PLT_PAYMENT_AMOUNT%');
  PERFORM plt_t.fails('T12 toman conversion exact',
    format($q$INSERT INTO platform.payment (payer_kind, billing_account_id, tenant_id, purpose, invoice_id, method, gateway_account_id, provider, order_id, amount, api_amount, api_amount_unit, expires_at)
              VALUES ('tenant', %L, %L, 'invoice', %L, 'gateway', %L, 'zarinpal', 'ORD-BAD-2', 11000000, 11000000, 'IRT', now() + interval '30 minutes')$q$,
           plt_t.u('BA_A'), plt_t.u('TA'), plt_t.u('INV1'), plt_t.u('GW1')),
    '%payment_api_unit%');
  PERFORM plt_t.fails('T12 gateway unit mismatch',
    format($q$INSERT INTO platform.payment (payer_kind, billing_account_id, tenant_id, purpose, invoice_id, method, gateway_account_id, provider, order_id, amount, api_amount, api_amount_unit, expires_at)
              VALUES ('tenant', %L, %L, 'invoice', %L, 'gateway', %L, 'zarinpal', 'ORD-BAD-3', 11000000, 11000000, 'IRR', now() + interval '30 minutes')$q$,
           plt_t.u('BA_A'), plt_t.u('TA'), plt_t.u('INV1'), plt_t.u('GW1')),
    'HK_PLT_GATEWAY_MISMATCH%');
  PERFORM plt_t.fails('T12 payment for draft invoice',
    format($q$INSERT INTO platform.payment (payer_kind, billing_account_id, tenant_id, purpose, invoice_id, method, gateway_account_id, provider, order_id, amount, api_amount, api_amount_unit, expires_at)
              VALUES ('tenant', %L, %L, 'invoice', %L, 'gateway', %L, 'mellat', 'ORD-BAD-4', 1, 1, 'IRR', now() + interval '30 minutes')$q$,
           plt_t.u('BA_B'), plt_t.u('TB'), plt_t.u('INV8'), plt_t.u('GW2')),
    'HK_PLT_PAYMENT_TARGET%');
  INSERT INTO platform.payment (id, payer_kind, billing_account_id, tenant_id, purpose, invoice_id, method, gateway_account_id, provider, order_id,
                                amount, api_amount, api_amount_unit, expires_at)
  VALUES (plt_t.u('PAY1'), 'tenant', plt_t.u('BA_A'), plt_t.u('TA'), 'invoice', plt_t.u('INV1'), 'gateway', plt_t.u('GW1'), 'zarinpal', 'ORD-000001',
          11000000, 1100000, 'IRT', now() + interval '30 minutes');
  PERFORM plt_t.fails('T12 gateway payment cannot skip verify', format($q$UPDATE platform.payment SET state = 'verified', verified_amount = amount, provider_txn_ref = 'x' WHERE id = %L$q$, plt_t.u('PAY1')),
    'HK_PLT_INVALID_TRANSITION%');
  UPDATE platform.payment SET state = 'redirected', provider_ref = 'A00000000000000000000000000000000001' WHERE id = plt_t.u('PAY1');
  UPDATE platform.payment SET state = 'callback_received' WHERE id = plt_t.u('PAY1');
  PERFORM plt_t.fails('T12 verified amount must equal amount',
    format($q$UPDATE platform.payment SET state = 'verified', verified_amount = 10000000, provider_txn_ref = 'ZP1' WHERE id = %L$q$, plt_t.u('PAY1')),
    'HK_PLT_AMOUNT_MISMATCH%');
  PERFORM plt_t.fails('T12 verified needs txn ref',
    format($q$UPDATE platform.payment SET state = 'verified', verified_amount = 11000000 WHERE id = %L$q$, plt_t.u('PAY1')),
    '%payment_verified_fields%');
  UPDATE platform.payment SET state = 'verified', verified_amount = 11000000, provider_txn_ref = 'ZP-REF-1', card_masked = '603799******1234',
                              last_response_code = '100' WHERE id = plt_t.u('PAY1');
  PERFORM plt_t.ok('T12 verify settles invoice', (SELECT status = 'paid' AND paid_amount = 11000000 FROM platform.invoice WHERE id = plt_t.u('INV1'))
                                                AND (SELECT count(*) = 1 FROM platform.invoice_settlement WHERE payment_id = plt_t.u('PAY1')));
  PERFORM plt_t.ok('T12 payment activates prepaid term and subscription',
    (SELECT status = 'active' FROM platform.subscription_term WHERE invoice_id = plt_t.u('INV1'))
    AND (SELECT status = 'active' AND covered_through = current_date + 30 FROM platform.subscription WHERE id = plt_t.u('SUB_A')));
  PERFORM plt_t.ok('T12 payment restores tenant access', (SELECT status = 'active' FROM platform.tenant WHERE id = plt_t.u('TA'))
                                                        AND EXISTS (SELECT 1 FROM platform.tenant_lifecycle_event WHERE tenant_id = plt_t.u('TA')
                                                                    AND reason_code = 'payment_received' AND from_status = 'trial' AND to_status = 'active'));
  PERFORM plt_t.fails('T12 provider_ref set once', format($q$UPDATE platform.payment SET provider_ref = 'other' WHERE id = %L$q$, plt_t.u('PAY1')), 'HK_PLT_IMMUTABLE_FIELD%');
  PERFORM plt_t.fails('T12 verified -> redirected', format($q$UPDATE platform.payment SET state = 'redirected' WHERE id = %L$q$, plt_t.u('PAY1')), 'HK_PLT_INVALID_TRANSITION%');
  PERFORM plt_t.fails('T12 payment amount immutable', format($q$UPDATE platform.payment SET amount = 1, api_amount = 1 WHERE id = %L$q$, plt_t.u('PAY1')), 'HK_PLT_IMMUTABLE_FIELD%');

  -- INV4 (افزونه): ملت ۴۸، تکراری، دیرهنگام، واریز بانکی
  INSERT INTO platform.invoice (id, billing_account_id, tenant_id, period_key, subtotal, vat_total, total) VALUES
    (plt_t.u('INV4'), plt_t.u('BA_A'), plt_t.u('TA'), 'jy:1405', 6000000, 600000, 6600000);
  INSERT INTO platform.invoice_line (id, invoice_id, line_no, line_kind, product_version_id, description, quantity, unit_amount, amount, vat_rate_pct, vat_amount, total)
  VALUES (plt_t.u('L4'), plt_t.u('INV4'), 1, 'addon', plt_t.u('PV2'), 'سه صندوق اضافه', 3, 2000000, 6000000, 10, 600000, 6600000);
  UPDATE platform.invoice SET status = 'issued', issued_by = plt_t.u('F') WHERE id = plt_t.u('INV4');
  INSERT INTO platform.payment (id, payer_kind, billing_account_id, tenant_id, purpose, invoice_id, method, gateway_account_id, provider, order_id, amount, api_amount, api_amount_unit, expires_at) VALUES
    (plt_t.u('PAY2'), 'tenant', plt_t.u('BA_A'), plt_t.u('TA'), 'invoice', plt_t.u('INV4'), 'gateway', plt_t.u('GW1'), 'zarinpal', 'ORD-000002', 6600000, 660000, 'IRT', now() + interval '30 minutes'),
    (plt_t.u('PAY3'), 'tenant', plt_t.u('BA_A'), plt_t.u('TA'), 'invoice', plt_t.u('INV4'), 'gateway', plt_t.u('GW2'), 'mellat', 'ORD-000003', 6600000, 6600000, 'IRR', now() + interval '30 minutes');
  PERFORM plt_t.fails('T12 unique (provider, provider_ref)',
    format($q$UPDATE platform.payment SET state = 'redirected', provider_ref = 'A00000000000000000000000000000000001' WHERE id = %L$q$, plt_t.u('PAY2')),
    '%payment_provider_ref_unique%');
  UPDATE platform.payment SET state = 'redirected', provider_ref = 'A00000000000000000000000000000000002' WHERE id = plt_t.u('PAY2');
  UPDATE platform.payment SET state = 'redirected', provider_ref = 'MELLAT-REF-1' WHERE id = plt_t.u('PAY3');
  UPDATE platform.payment SET state = 'callback_received' WHERE id = plt_t.u('PAY3');
  PERFORM plt_t.fails('T12 Mellat 48 is never paid',
    format($q$UPDATE platform.payment SET state = 'verified', verified_amount = 6600000, provider_txn_ref = 'M48', last_response_code = '48' WHERE id = %L$q$, plt_t.u('PAY3')),
    '%payment_mellat_48%');
  UPDATE platform.payment SET state = 'reversed', last_response_code = '48' WHERE id = plt_t.u('PAY3');
  UPDATE platform.payment SET state = 'expired' WHERE id = plt_t.u('PAY2');
  INSERT INTO platform.payment (id, payer_kind, billing_account_id, tenant_id, purpose, invoice_id, method, order_id, amount, api_amount, api_amount_unit, expires_at)
  VALUES (plt_t.u('PAY5'), 'tenant', plt_t.u('BA_A'), plt_t.u('TA'), 'invoice', plt_t.u('INV4'), 'bank_transfer', 'ORD-000005', 6600000, 6600000, 'IRR', now() + interval '7 days');
  PERFORM plt_t.as_staff(plt_t.u('S'));
  PERFORM plt_t.fails('T12 bank transfer recorded by finance only',
    format($q$UPDATE platform.payment SET state = 'verified', verified_amount = 6600000, bank_ref = 'BT-1' WHERE id = %L$q$, plt_t.u('PAY5')),
    'HK_PLT_PERMISSION%');
  PERFORM plt_t.as_staff(plt_t.u('F'));
  PERFORM plt_t.fails('T12 bank transfer needs bank ref',
    format($q$UPDATE platform.payment SET state = 'verified', verified_amount = 6600000 WHERE id = %L$q$, plt_t.u('PAY5')),
    '%payment_check%');
  UPDATE platform.payment SET state = 'verified', verified_amount = 6600000, bank_ref = 'BT-1' WHERE id = plt_t.u('PAY5');
  PERFORM plt_t.ok('T12 bank transfer settles', (SELECT status = 'paid' FROM platform.invoice WHERE id = plt_t.u('INV4')));
  PERFORM plt_t.fails('T12 late verify needs flag',
    format($q$UPDATE platform.payment SET state = 'verified', verified_amount = 6600000, provider_txn_ref = 'ZP-REF-2' WHERE id = %L$q$, plt_t.u('PAY2')),
    'HK_PLT_INVALID_TRANSITION%');
  UPDATE platform.payment SET state = 'verified', verified_amount = 6600000, provider_txn_ref = 'ZP-REF-2', late_verification = true WHERE id = plt_t.u('PAY2');
  PERFORM plt_t.ok('T12 late money goes to wallet', (SELECT balance = 6600000 FROM platform.wallet WHERE tenant_id = plt_t.u('TA'))
                                                   AND NOT EXISTS (SELECT 1 FROM platform.invoice_settlement WHERE payment_id = plt_t.u('PAY2'))
                                                   AND EXISTS (SELECT 1 FROM platform.wallet_entry WHERE payment_id = plt_t.u('PAY2') AND kind = 'overpayment'));
  PERFORM plt_t.fails('T12 settlement over outstanding',
    format($q$INSERT INTO platform.invoice_settlement (invoice_id, source_kind, payment_id, amount) VALUES (%L, 'payment', %L, 2000000)$q$, plt_t.u('INV2'), plt_t.u('PAY3')),
    'HK_PLT_OVERPAYMENT%');
  PERFORM plt_t.fails('T12 settlement of a draft',
    format($q$INSERT INTO platform.invoice_settlement (invoice_id, source_kind, payment_id, amount) VALUES (%L, 'payment', %L, 1)$q$, plt_t.u('INV8'), plt_t.u('PAY3')),
    'HK_PLT_SETTLEMENT_STATE%');
  PERFORM plt_t.fails('T12 settlements append-only', $q$DELETE FROM platform.invoice_settlement$q$, '%permission denied%');

  -- ابطال صورتحساب پرداخت‌نشده با تأیید دونفره
  PERFORM plt_t.fails('T12 paid invoice cannot be voided',
    format($q$UPDATE platform.invoice SET status = 'void', void_reason = 'mistake', void_approval_id = %L WHERE id = %L$q$,
           plt_t.approve('invoice.void', 'invoice', plt_t.u('INV1'), plt_t.u('F'), plt_t.u('F2')), plt_t.u('INV1')),
    'HK_PLT_INVALID_TRANSITION%');
  -- صورتحساب بخشی پرداخت‌شده هم باطل نمی‌شود (یادداشت اعتباری لازم است)
  INSERT INTO platform.invoice (id, billing_account_id, tenant_id, period_key, subtotal, vat_total, total)
  VALUES (plt_t.u('INV5'), plt_t.u('BA_A'), plt_t.u('TA'), 'jy:1405', 1000000, 100000, 1100000);
  INSERT INTO platform.invoice_line (invoice_id, line_no, line_kind, description, quantity, unit_amount, amount, vat_rate_pct, vat_amount, total)
  VALUES (plt_t.u('INV5'), 1, 'service', 'آموزش', 1, 1000000, 1000000, 10, 100000, 1100000);
  UPDATE platform.invoice SET status = 'issued' WHERE id = plt_t.u('INV5');
  INSERT INTO platform.wallet_entry (wallet_id, seq, kind, amount, balance_after, invoice_id, idempotency_key)
  SELECT id, 0, 'invoice_payment', -100000, 0, plt_t.u('INV5'), 'partial-inv5' FROM platform.wallet WHERE tenant_id = plt_t.u('TA');
  PERFORM plt_t.ok('T12 partial settlement', (SELECT status = 'issued' AND paid_amount = 100000 FROM platform.invoice WHERE id = plt_t.u('INV5')));
  PERFORM plt_t.fails('T12 partially paid invoice cannot be voided',
    format($q$UPDATE platform.invoice SET status = 'void', void_reason = 'mistake', void_approval_id = %L WHERE id = %L$q$,
           plt_t.approve('invoice.void', 'invoice', plt_t.u('INV5'), plt_t.u('F'), plt_t.u('F2')), plt_t.u('INV5')),
    'HK_PLT_INVOICE_VOID%');
  PERFORM plt_t.fails('T12 void needs approval',
    format($q$UPDATE platform.invoice SET status = 'void', void_reason = 'duplicate' WHERE id = %L$q$, plt_t.u('INV2')),
    'HK_PLT_APPROVAL_REQUIRED%');
  UPDATE platform.invoice SET status = 'void', void_reason = 'duplicate invoice',
         void_approval_id = plt_t.approve('invoice.void', 'invoice', plt_t.u('INV2'), plt_t.u('F'), plt_t.u('F2'))
   WHERE id = plt_t.u('INV2');

  -- یادداشت اعتباری
  INSERT INTO platform.invoice (id, kind, billing_account_id, tenant_id, period_key, original_invoice_id, subtotal, vat_total, total)
  VALUES (plt_t.u('CN1'), 'credit_note', plt_t.u('BA_A'), plt_t.u('TA'), 'jy:1405', plt_t.u('INV1'), 5000000, 500000, 5500000);
  PERFORM plt_t.fails('T12 credit line from original invoice',
    format($q$INSERT INTO platform.invoice_line (invoice_id, line_no, line_kind, original_line_id, description, quantity, unit_amount, amount, vat_rate_pct, vat_amount, total)
              VALUES (%L, 1, 'addon', %L, 'x', 1, 1000, 1000, 10, 100, 1100)$q$, plt_t.u('CN1'), plt_t.u('L4')),
    'HK_PLT_CREDIT_NOTE_LINE%');
  PERFORM plt_t.fails('T12 credit not above original',
    format($q$INSERT INTO platform.invoice_line (invoice_id, line_no, line_kind, original_line_id, description, quantity, unit_amount, amount, vat_rate_pct, vat_amount, total)
              VALUES (%L, 1, 'subscription', %L, 'x', 1, 20000000, 20000000, 10, 2000000, 22000000)$q$, plt_t.u('CN1'), plt_t.u('L1')),
    'HK_PLT_CREDIT_EXCEEDS_ORIGINAL%');
  PERFORM plt_t.fails('T12 credit keeps VAT rate',
    format($q$INSERT INTO platform.invoice_line (invoice_id, line_no, line_kind, original_line_id, description, quantity, unit_amount, amount, vat_rate_pct, vat_amount, total)
              VALUES (%L, 1, 'subscription', %L, 'x', 1, 1000, 1000, 9, 90, 1090)$q$, plt_t.u('CN1'), plt_t.u('L1')),
    'HK_PLT_CREDIT_NOTE_LINE%');
  PERFORM plt_t.fails('T12 invoice lines do not reference originals',
    format($q$INSERT INTO platform.invoice_line (invoice_id, line_no, line_kind, original_line_id, description, quantity, unit_amount, amount, vat_rate_pct, vat_amount, total)
              VALUES (%L, 1, 'subscription', %L, 'x', 1, 1000, 1000, 10, 100, 1100)$q$, plt_t.u('INV9'), plt_t.u('L1')),
    'HK_PLT_CREDIT_NOTE_LINE%');
  INSERT INTO platform.invoice_line (id, invoice_id, line_no, line_kind, product_version_id, original_line_id, description, quantity, unit_amount, amount, vat_rate_pct, vat_amount, total)
  VALUES (plt_t.u('CL1'), plt_t.u('CN1'), 1, 'subscription', plt_t.u('PV1'), plt_t.u('L1'), 'برگشت بخشی اشتراک', 1, 5000000, 5000000, 10, 500000, 5500000);
  UPDATE platform.invoice SET status = 'issued', issued_by = plt_t.u('F') WHERE id = plt_t.u('CN1');
  PERFORM plt_t.ok('T12 credit note numbered and credited to wallet',
    (SELECT number = 'CN-1405-000001' FROM platform.invoice WHERE id = plt_t.u('CN1'))
    AND (SELECT balance = 12000000 FROM platform.wallet WHERE tenant_id = plt_t.u('TA'))
    AND EXISTS (SELECT 1 FROM platform.house_sync WHERE doc_type = 'credit_note' AND doc_id = plt_t.u('CN1')));
  INSERT INTO platform.invoice (id, kind, billing_account_id, tenant_id, period_key, original_invoice_id, subtotal, vat_total, total)
  VALUES (plt_t.u('INVR'), 'credit_note', plt_t.u('BA_A'), plt_t.u('TA'), 'jy:1405', plt_t.u('INV2'), 1000, 100, 1100);
  INSERT INTO platform.invoice_line (invoice_id, line_no, line_kind, original_line_id, description, quantity, unit_amount, amount, vat_rate_pct, vat_amount, total)
  VALUES (plt_t.u('INVR'), 1, 'adjustment', plt_t.u('L2'), 'x', 1, 1000, 1000, 10, 100, 1100);
  PERFORM plt_t.fails('T12 credit note of a void invoice',
    format($q$UPDATE platform.invoice SET status = 'issued' WHERE id = %L$q$, plt_t.u('INVR')), 'HK_PLT_CREDIT_NOTE_ORIGINAL%');
  DELETE FROM platform.invoice_line WHERE invoice_id = plt_t.u('INVR');
  DELETE FROM platform.invoice WHERE id = plt_t.u('INVR');
  UPDATE platform.subscription_term SET status = 'void' WHERE invoice_id = plt_t.u('INV1');
  PERFORM plt_t.ok('T12 voiding the term recomputes coverage', (SELECT covered_through = current_date FROM platform.subscription WHERE id = plt_t.u('SUB_A')));

  -- صورتحساب صفر (تخفیف کامل) بلافاصله پرداخت‌شده
  INSERT INTO platform.invoice (id, billing_account_id, tenant_id, period_key, subtotal, discount_total, vat_total, total)
  VALUES (plt_t.u('INV0'), plt_t.u('BA_B'), plt_t.u('TB'), 'jy:1405', 1000000, 1000000, 0, 0);
  INSERT INTO platform.invoice_line (id, invoice_id, line_no, line_kind, product_version_id, description, quantity, unit_amount, amount, discount, vat_rate_pct, vat_amount, total)
  VALUES (plt_t.u('L0'), plt_t.u('INV0'), 1, 'service', plt_t.u('PV4'), 'مشاورهٔ رایگان', 1, 1000000, 1000000, 1000000, 10, 0, 0);
  UPDATE platform.invoice SET status = 'issued', issued_by = plt_t.u('F') WHERE id = plt_t.u('INV0');
  PERFORM plt_t.ok('T12 zero invoice paid on issue', (SELECT status = 'paid' AND number = 'INV-1405-000005' FROM platform.invoice WHERE id = plt_t.u('INV0')));
  PERFORM plt_t.ok('T12 invoice numbers contiguous',
    (SELECT array_agg(number ORDER BY number) = ARRAY['INV-1405-000001','INV-1405-000002','INV-1405-000003','INV-1405-000004','INV-1405-000005']
       FROM platform.invoice WHERE kind = 'invoice' AND number IS NOT NULL));
END $$;

-- T13 حق استفادهٔ مؤثر، جایگزین مستأجر، پرچم ویژگی
DO $$
DECLARE
  r record;
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('SL'));
  -- پایه: users 5 + واحد اضافه 2؛ pos_devices 2 + افزونه 3×1
  SELECT * INTO r FROM platform.effective_entitlements(plt_t.u('TA')) WHERE feature_key = 'limit.users';
  PERFORM plt_t.ok('T13 users = plan + extra units', r.limit_value = 7 AND NOT r.unlimited AND r.enforcement = 'soft' AND r.overage_pct = 10);
  SELECT * INTO r FROM platform.effective_entitlements(plt_t.u('TA')) WHERE feature_key = 'limit.pos_devices';
  PERFORM plt_t.ok('T13 pos devices = plan + addon x qty', r.limit_value = 5);
  SELECT * INTO r FROM platform.effective_entitlements(plt_t.u('TA')) WHERE feature_key = 'limit.invoices_per_month';
  PERFORM plt_t.ok('T13 unlimited limit', r.unlimited AND r.limit_value IS NULL);
  SELECT * INTO r FROM platform.effective_entitlements(plt_t.u('TA')) WHERE feature_key = 'module.pos';
  PERFORM plt_t.ok('T13 flag enabled', r.enabled);
  PERFORM plt_t.fails('T13 override shape',
    format($q$INSERT INTO platform.tenant_entitlement_override (tenant_id, feature_key, mode, enabled, limit_value, valid_to, reason, granted_by)
              VALUES (%L, 'module.pos', 'set', true, 3, now() + interval '30 days', 'gift for pilot customer', %L)$q$, plt_t.u('TA'), plt_t.u('SL')),
    'HK_PLT_ENTITLEMENT_SHAPE%');
  PERFORM plt_t.fails('T13 override granted by actor',
    format($q$INSERT INTO platform.tenant_entitlement_override (tenant_id, feature_key, mode, limit_value, valid_to, reason, granted_by)
              VALUES (%L, 'limit.companies', 'set', 3, now() + interval '30 days', 'gift for pilot customer', %L)$q$, plt_t.u('TA'), plt_t.u('O')),
    'HK_PLT_ACTOR_MISMATCH%');
  PERFORM plt_t.fails('T13 override at most 400 days',
    format($q$INSERT INTO platform.tenant_entitlement_override (tenant_id, feature_key, mode, limit_value, valid_to, reason, granted_by)
              VALUES (%L, 'limit.companies', 'set', 3, now() + interval '500 days', 'gift for pilot customer', %L)$q$, plt_t.u('TA'), plt_t.u('SL')),
    '%tenant_entitlement_override_check%');
  INSERT INTO platform.tenant_entitlement_override (tenant_id, feature_key, mode, limit_value, valid_from, valid_to, reason, granted_by) VALUES
    (plt_t.u('TA'), 'limit.companies', 'set', 3, now() - interval '1 day', now() + interval '30 days', 'pilot customer needs three companies', plt_t.u('SL')),
    (plt_t.u('TA'), 'limit.users', 'add', 1, now() - interval '1 day', now() + interval '30 days', 'one extra seat for the accountant', plt_t.u('SL'));
  INSERT INTO platform.tenant_entitlement_override (tenant_id, feature_key, mode, enabled, valid_from, valid_to, reason, granted_by) VALUES
    (plt_t.u('TA'), 'module.pos', 'set', false, now() - interval '1 day', now() + interval '30 days', 'pos disabled during dispute', plt_t.u('SL'));
  PERFORM plt_t.fails('T13 overrides do not overlap',
    format($q$INSERT INTO platform.tenant_entitlement_override (tenant_id, feature_key, mode, limit_value, valid_to, reason, granted_by)
              VALUES (%L, 'limit.companies', 'add', 1, now() + interval '10 days', 'another overlapping gift', %L)$q$, plt_t.u('TA'), plt_t.u('SL')),
    '%override_no_overlap%');
  PERFORM plt_t.ok('T13 override set replaces base',
    (SELECT limit_value = 3 FROM platform.effective_entitlements(plt_t.u('TA')) WHERE feature_key = 'limit.companies'));
  PERFORM plt_t.ok('T13 override add accumulates',
    (SELECT limit_value = 8 FROM platform.effective_entitlements(plt_t.u('TA')) WHERE feature_key = 'limit.users'));
  PERFORM plt_t.ok('T13 flag override wins',
    (SELECT enabled = false FROM platform.effective_entitlements(plt_t.u('TA')) WHERE feature_key = 'module.pos'));
  PERFORM plt_t.fails('T13 overrides change only by revocation',
    format($q$UPDATE platform.tenant_entitlement_override SET limit_value = 99 WHERE tenant_id = %L AND feature_key = 'limit.companies'$q$, plt_t.u('TA')),
    'HK_PLT_IMMUTABLE_FIELD%');
  UPDATE platform.tenant_entitlement_override SET revoked_at = now(), revoked_by = plt_t.u('SL')
   WHERE tenant_id = plt_t.u('TA') AND feature_key = 'module.pos';
  PERFORM plt_t.ok('T13 revoked override ignored',
    (SELECT enabled FROM platform.effective_entitlements(plt_t.u('TA')) WHERE feature_key = 'module.pos'));
  PERFORM plt_t.fails('T13 overrides never deleted', $q$DELETE FROM platform.tenant_entitlement_override$q$, '%permission denied%');
  -- پرچم ویژگی
  INSERT INTO platform.feature_flag (key, description, kind, default_on, rollout_percent, created_by) VALUES
    ('ff.new_dashboard', 'داشبورد تازه', 'release', false, 0, plt_t.u('SL')),
    ('ff.fast_sync', 'همگام‌سازی سریع', 'release', true, 0, plt_t.u('SL'));
  INSERT INTO platform.feature_flag_target (flag_key, target_kind, target_id, is_on) VALUES
    ('ff.new_dashboard', 'tenant', plt_t.u('TA')::text, true), ('ff.new_dashboard', 'plan', 'pro', false);
  PERFORM plt_t.ok('T13 tenant target wins', platform.flag_on_for_tenant('ff.new_dashboard', plt_t.u('TA'), 'pro'));
  PERFORM plt_t.ok('T13 plan target', NOT platform.flag_on_for_tenant('ff.new_dashboard', plt_t.u('TB'), 'pro'));
  PERFORM plt_t.ok('T13 default', platform.flag_on_for_tenant('ff.fast_sync', plt_t.u('TB'), NULL));
  UPDATE platform.feature_flag SET rollout_percent = 100, default_on = false WHERE key = 'ff.fast_sync';
  PERFORM plt_t.ok('T13 rollout 100%', platform.flag_on_for_tenant('ff.fast_sync', plt_t.u('TB'), NULL));
  UPDATE platform.feature_flag SET kill_switch = true WHERE key = 'ff.new_dashboard';
  PERFORM plt_t.ok('T13 kill switch beats targets', NOT platform.flag_on_for_tenant('ff.new_dashboard', plt_t.u('TA'), 'pro'));
  PERFORM plt_t.fails('T13 flag key pattern', $q$INSERT INTO platform.feature_flag (key, description, kind) VALUES ('newdash', 'x', 'release')$q$,
    '%feature_flag_key_check%');
END $$;

-- T14 کیف پول، بازپرداخت، رزرو اعتبار، کوپن
DO $$
DECLARE
  v_wa uuid;
  v_wb uuid;
  v_n int;
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('F'));
  SELECT id INTO v_wa FROM platform.wallet WHERE tenant_id = plt_t.u('TA');
  PERFORM plt_t.fails('T14 balance only via entries', format($q$UPDATE platform.wallet SET balance = 999999999 WHERE id = %L$q$, v_wa), 'HK_PLT_DERIVED_COLUMN%');
  PERFORM plt_t.fails('T14 wallets start empty',
    format($q$INSERT INTO platform.wallet (owner_kind, tenant_id, balance) VALUES ('tenant', %L, 100)$q$, plt_t.u('TE')), 'HK_PLT_DERIVED_COLUMN%');
  PERFORM plt_t.fails('T14 entry sign by kind',
    format($q$INSERT INTO platform.wallet_entry (wallet_id, seq, kind, amount, balance_after, idempotency_key) VALUES (%L, 0, 'credit_reservation', 100, 0, 'bad-sign-0001')$q$, v_wa),
    '%wallet_entry_sign%');
  PERFORM plt_t.fails('T14 adjustment needs approval',
    format($q$INSERT INTO platform.wallet_entry (wallet_id, seq, kind, amount, balance_after, idempotency_key) VALUES (%L, 0, 'adjustment', 1000, 0, 'adj-0000001')$q$, v_wa),
    'HK_PLT_APPROVAL_REQUIRED%');
  INSERT INTO platform.wallet_entry (wallet_id, seq, kind, amount, balance_after, idempotency_key, approval_id, memo, created_by_staff)
  VALUES (v_wa, 0, 'adjustment', 1000, 0, 'adj-0000001', plt_t.approve('wallet.manual_adjustment', 'wallet', v_wa, plt_t.u('F'), plt_t.u('F2')), 'goodwill', plt_t.u('F'));
  PERFORM plt_t.fails('T14 idempotent entry key',
    format($q$INSERT INTO platform.wallet_entry (wallet_id, seq, kind, amount, balance_after, idempotency_key) VALUES (%L, 0, 'refund_out', -1, 0, 'adj-0000001')$q$, v_wa),
    '%wallet_entry_wallet_id_idempotency_key_key%');
  PERFORM plt_t.fails('T14 insufficient balance',
    format($q$INSERT INTO platform.wallet_entry (wallet_id, seq, kind, amount, balance_after, idempotency_key) VALUES (%L, 0, 'refund_out', -100000000, 0, 'big-out-001')$q$, v_wa),
    'HK_PLT_INSUFFICIENT_BALANCE%');
  -- پرداخت صورتحساب از کیف پول
  INSERT INTO platform.invoice (id, billing_account_id, tenant_id, period_key, subtotal, vat_total, total)
  VALUES (plt_t.u('INV7'), plt_t.u('BA_A'), plt_t.u('TA'), 'jy:1405', 1000000, 100000, 1100000);
  INSERT INTO platform.invoice_line (id, invoice_id, line_no, line_kind, description, quantity, unit_amount, amount, vat_rate_pct, vat_amount, total)
  VALUES (plt_t.u('L7'), plt_t.u('INV7'), 1, 'credit_pack', 'بستهٔ پیامک', 1, 1000000, 1000000, 10, 100000, 1100000);
  UPDATE platform.invoice SET status = 'issued' WHERE id = plt_t.u('INV7');
  INSERT INTO platform.wallet_entry (wallet_id, seq, kind, amount, balance_after, invoice_id, idempotency_key) VALUES (v_wa, 0, 'invoice_payment', -1100000, 0, plt_t.u('INV7'), 'pay-inv7-0001');
  PERFORM plt_t.ok('T14 wallet pays invoice', (SELECT status = 'paid' FROM platform.invoice WHERE id = plt_t.u('INV7')));
  PERFORM plt_t.ok('T14 wallet ledger consistent', NOT EXISTS (SELECT 1 FROM platform.v_wallet_integrity)
                                                   AND (SELECT balance = 12000000 + 1000 - 1100000 FROM platform.wallet WHERE id = v_wa));
  PERFORM plt_t.ok('T14 seq gapless', (SELECT bool_and(seq = rn) FROM (SELECT seq, row_number() OVER (ORDER BY seq) AS rn
                                                                         FROM platform.wallet_entry WHERE wallet_id = v_wa) x));
  PERFORM plt_t.fails('T14 entries append-only', $q$UPDATE platform.wallet_entry SET memo = 'x'$q$, '%permission denied%');
  INSERT INTO platform.wallet (owner_kind, tenant_id, status) VALUES ('tenant', plt_t.u('TB'), 'frozen') RETURNING id INTO v_wb;
  PERFORM plt_t.fails('T14 frozen wallet cannot pay out',
    format($q$INSERT INTO platform.wallet_entry (wallet_id, seq, kind, amount, balance_after, idempotency_key) VALUES (%L, 0, 'refund_out', -1, 0, 'frozen-out-01')$q$, v_wb),
    'HK_PLT_WALLET_NOT_ACTIVE%');
  PERFORM plt_t.fails('T14 tenant credit limit', format($q$UPDATE platform.wallet SET credit_limit = -1 WHERE id = %L$q$, v_wb), '%wallet_credit_limit%');

  -- بازپرداخت
  PERFORM plt_t.fails('T14 refund requester is actor',
    format($q$INSERT INTO platform.refund (wallet_id, amount, method, destination_sheba, requested_by) VALUES (%L, 1000000, 'paya', 'IR000000000000000000000009', %L)$q$, v_wa, plt_t.u('F2')),
    'HK_PLT_ACTOR_MISMATCH%');
  PERFORM plt_t.fails('T14 paya refund needs sheba',
    format($q$INSERT INTO platform.refund (wallet_id, amount, method, requested_by) VALUES (%L, 1000000, 'paya', %L)$q$, v_wa, plt_t.u('F')),
    '%refund_check%');
  INSERT INTO platform.refund (id, wallet_id, amount, method, destination_sheba, requested_by)
  VALUES (plt_t.u('RF1'), v_wa, 1000000, 'paya', 'IR000000000000000000000009', plt_t.u('F'));
  PERFORM plt_t.fails('T14 gateway refund above refundable',
    format($q$INSERT INTO platform.refund (wallet_id, payment_id, amount, method, requested_by) VALUES (%L, %L, 20000000, 'gateway_refund', %L)$q$, v_wa, plt_t.u('PAY1'), plt_t.u('F')),
    'HK_PLT_REFUND_EXCEEDS%');
  INSERT INTO platform.refund (id, wallet_id, payment_id, amount, method, requested_by)
  VALUES (plt_t.u('RF2'), v_wa, plt_t.u('PAY1'), 2000000, 'gateway_refund', plt_t.u('F'));
  PERFORM plt_t.fails('T14 refund approval required', format($q$UPDATE platform.refund SET status = 'approved' WHERE id = %L$q$, plt_t.u('RF1')), 'HK_PLT_APPROVAL_REQUIRED%');
  UPDATE platform.refund SET status = 'approved', approval_id = plt_t.approve('refund.execute', 'refund', id, plt_t.u('F'), plt_t.u('F2'))
   WHERE id IN (plt_t.u('RF1'), plt_t.u('RF2'));
  PERFORM plt_t.fails('T14 refund content immutable', format($q$UPDATE platform.refund SET amount = 5 WHERE id = %L$q$, plt_t.u('RF1')), 'HK_PLT_IMMUTABLE_FIELD%');
  PERFORM plt_t.fails('T14 completed refund needs bank ref', format($q$UPDATE platform.refund SET status = 'completed' WHERE id = %L$q$, plt_t.u('RF1')), '%refund_check%');
  UPDATE platform.refund SET status = 'completed', bank_ref = 'PAYA-778899' WHERE id = plt_t.u('RF1');
  UPDATE platform.refund SET status = 'completed', bank_ref = 'ZP-RFD-1' WHERE id = plt_t.u('RF2');
  PERFORM plt_t.ok('T14 refunds debit wallet and mark payment',
    (SELECT balance = 12000000 + 1000 - 1100000 - 1000000 - 2000000 FROM platform.wallet WHERE id = v_wa)
    AND (SELECT state = 'partially_refunded' AND refunded_amount = 2000000 FROM platform.payment WHERE id = plt_t.u('PAY1')));
  PERFORM plt_t.fails('T14 refunded_amount derived', format($q$UPDATE platform.payment SET refunded_amount = 11000000 WHERE id = %L$q$, plt_t.u('PAY1')), 'HK_PLT_DERIVED_COLUMN%');
  PERFORM plt_t.fails('T14 completed refund final', format($q$UPDATE platform.refund SET status = 'cancelled' WHERE id = %L$q$, plt_t.u('RF1')), 'HK_PLT_INVALID_TRANSITION%');

  -- رزرو اعتبار پیامک از کیف پول
  INSERT INTO platform.service_tariff (service_key, unit_amount, valid_from, created_by) VALUES ('meter.sms_parts', 500, now() - interval '1 day', plt_t.u('F'));
  PERFORM plt_t.fails('T14 tariffs do not overlap',
    $q$INSERT INTO platform.service_tariff (service_key, unit_amount, valid_from) VALUES ('meter.sms_parts', 600, now())$q$, '%tariff_no_overlap%');
  PERFORM plt_t.fails('T14 reservation at current tariff',
    format($q$INSERT INTO platform.credit_reservation (tenant_id, service_key, seq, kind, units, unit_amount, cumulative_units) VALUES (%L, 'meter.sms_parts', 0, 'reserve', 1000, 400, 0)$q$, plt_t.u('TA')),
    'HK_PLT_TARIFF_MISMATCH%');
  PERFORM plt_t.fails('T14 reservations are for meters',
    format($q$INSERT INTO platform.credit_reservation (tenant_id, service_key, seq, kind, units, unit_amount, cumulative_units) VALUES (%L, 'module.pos', 0, 'reserve', 1, 1, 0)$q$, plt_t.u('TA')),
    'HK_PLT_RESERVATION_SHAPE%');
  INSERT INTO platform.credit_reservation (tenant_id, service_key, seq, kind, units, unit_amount, cumulative_units) VALUES (plt_t.u('TA'), 'meter.sms_parts', 0, 'reserve', 1000, 500, 0);
  PERFORM plt_t.ok('T14 reservation debits wallet',
    (SELECT cumulative_units = 1000 AND seq = 1 FROM platform.credit_reservation WHERE tenant_id = plt_t.u('TA'))
    AND EXISTS (SELECT 1 FROM platform.wallet_entry WHERE wallet_id = v_wa AND kind = 'credit_reservation' AND amount = -500000));
  PERFORM plt_t.fails('T14 release at most unused',
    format($q$INSERT INTO platform.credit_reservation (tenant_id, service_key, seq, kind, units, unit_amount, cumulative_units) VALUES (%L, 'meter.sms_parts', 0, 'release', 2000, 500, 0)$q$, plt_t.u('TA')),
    'HK_PLT_RELEASE_EXCEEDS%');
  INSERT INTO platform.credit_reservation (tenant_id, service_key, seq, kind, units, unit_amount, cumulative_units) VALUES (plt_t.u('TA'), 'meter.sms_parts', 0, 'release', 100, 500, 0);
  PERFORM plt_t.ok('T14 release credits wallet', (SELECT cumulative_units = 900 FROM platform.credit_reservation WHERE tenant_id = plt_t.u('TA') AND seq = 2));

  -- کوپن
  PERFORM plt_t.as_staff(plt_t.u('SL'));
  INSERT INTO platform.coupon (code, kind, percent_off, duration, max_redemptions, created_by) VALUES ('WELCOME50', 'percent', 50, 'once', 1, plt_t.u('SL'));
  INSERT INTO platform.coupon (code, kind, amount_off, duration, max_redemptions, per_tenant_limit, created_by) VALUES ('MINUS1000', 'amount', 1000, 'once', 10, 1, plt_t.u('SL'));
  INSERT INTO platform.coupon (code, kind, percent_off, duration, reseller_id, created_by) VALUES ('RONE10', 'percent', 10, 'once', plt_t.u('R1'), plt_t.u('SL'));
  INSERT INTO platform.coupon (code, kind, percent_off, duration, first_purchase_only, created_by) VALUES ('FIRST20', 'percent', 20, 'once', true, plt_t.u('SL'));
  PERFORM plt_t.fails('T14 coupon shape', $q$INSERT INTO platform.coupon (code, kind, percent_off, amount_off, duration) VALUES ('BADSHAPE', 'percent', 10, 100, 'once')$q$, '%coupon_check%');
  PERFORM plt_t.fails('T14 repeating needs periods', $q$INSERT INTO platform.coupon (code, kind, percent_off, duration) VALUES ('BADREPEAT', 'percent', 10, 'repeating')$q$, '%coupon_check%');
  INSERT INTO platform.coupon_redemption (coupon_id, tenant_id, invoice_id) SELECT id, plt_t.u('TB'), plt_t.u('INV8') FROM platform.coupon WHERE code = 'WELCOME50';
  PERFORM plt_t.ok('T14 redemption counted', (SELECT redemptions_count = 1 FROM platform.coupon WHERE code = 'WELCOME50'));
  PERFORM plt_t.fails('T14 coupon cap', format($q$INSERT INTO platform.coupon_redemption (coupon_id, tenant_id, invoice_id) SELECT id, %L, %L FROM platform.coupon WHERE code = 'WELCOME50'$q$, plt_t.u('TA'), plt_t.u('INV9')),
    'HK_PLT_COUPON_EXHAUSTED%');
  INSERT INTO platform.coupon_redemption (coupon_id, tenant_id, invoice_id) SELECT id, plt_t.u('TB'), plt_t.u('INV8') FROM platform.coupon WHERE code = 'MINUS1000';
  PERFORM plt_t.fails('T14 coupon per tenant', format($q$INSERT INTO platform.coupon_redemption (coupon_id, tenant_id, invoice_id) SELECT id, %L, %L FROM platform.coupon WHERE code = 'MINUS1000'$q$, plt_t.u('TB'), plt_t.u('INV6')),
    'HK_PLT_COUPON_PER_TENANT%');
  PERFORM plt_t.fails('T14 reseller coupon for other reseller''s tenant', format($q$INSERT INTO platform.coupon_redemption (coupon_id, tenant_id, invoice_id) SELECT id, %L, %L FROM platform.coupon WHERE code = 'RONE10'$q$, plt_t.u('TB'), plt_t.u('INV6')),
    'HK_PLT_COUPON_INVALID%');
  PERFORM plt_t.fails('T14 first purchase only', format($q$INSERT INTO platform.coupon_redemption (coupon_id, tenant_id, invoice_id) SELECT id, %L, %L FROM platform.coupon WHERE code = 'FIRST20'$q$, plt_t.u('TA'), plt_t.u('INV9')),
    'HK_PLT_COUPON_INVALID%');
  PERFORM plt_t.fails('T14 coupons apply to drafts', format($q$INSERT INTO platform.coupon_redemption (coupon_id, tenant_id, invoice_id) SELECT id, %L, %L FROM platform.coupon WHERE code = 'RONE10'$q$, plt_t.u('TA'), plt_t.u('INV7')),
    'HK_PLT_COUPON_INVALID%');
  PERFORM plt_t.fails('T14 redemption count derived', $q$UPDATE platform.coupon SET redemptions_count = 0 WHERE code = 'WELCOME50'$q$, 'HK_PLT_DERIVED_COLUMN%');
  PERFORM plt_t.fails('T14 coupon terms immutable', $q$UPDATE platform.coupon SET percent_off = 90 WHERE code = 'RONE10'$q$, 'HK_PLT_IMMUTABLE_FIELD%');
  UPDATE platform.coupon SET status = 'disabled' WHERE code = 'RONE10';
  PERFORM plt_t.fails('T14 disabled coupon', format($q$INSERT INTO platform.coupon_redemption (coupon_id, tenant_id, invoice_id) SELECT id, %L, %L FROM platform.coupon WHERE code = 'RONE10'$q$, plt_t.u('TA'), plt_t.u('INV9')),
    'HK_PLT_COUPON_INVALID%');
END $$;

-- T15 همگام‌سازی با مستأجر خانه و یادآور
DO $$
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('F'));
  PERFORM plt_t.ok('T15 one house-sync row per issued document',
    (SELECT count(*) FROM platform.house_sync WHERE doc_type IN ('invoice','credit_note'))
    = (SELECT count(*) FROM platform.invoice WHERE status <> 'draft'));
  PERFORM plt_t.fails('T15 pending -> confirmed', format($q$UPDATE platform.house_sync SET status = 'confirmed', house_ref = 'X' WHERE doc_id = %L$q$, plt_t.u('INV1')),
    'HK_PLT_INVALID_TRANSITION%');
  UPDATE platform.house_sync SET status = 'sent', attempts = 1 WHERE doc_id = plt_t.u('INV1');
  PERFORM plt_t.fails('T15 confirmed needs house ref', format($q$UPDATE platform.house_sync SET status = 'confirmed' WHERE doc_id = %L$q$, plt_t.u('INV1')),
    '%house_sync_check%');
  UPDATE platform.house_sync SET status = 'confirmed', house_ref = 'sales.invoice:0193f0', moadian_status = 'accepted',
         moadian_taxid = 'A11111111111111111111A' WHERE doc_id = plt_t.u('INV1');
  PERFORM plt_t.fails('T15 house ref set once', format($q$UPDATE platform.house_sync SET house_ref = 'other' WHERE doc_id = %L$q$, plt_t.u('INV1')),
    'HK_PLT_IMMUTABLE_FIELD%');
  PERFORM plt_t.fails('T15 house sync kept', $q$DELETE FROM platform.house_sync$q$, '%permission denied%');
  INSERT INTO platform.reminder (subject_type, subject_id, tenant_id, kind, anchor_date, channel, scheduled_for)
  VALUES ('subscription', plt_t.u('SUB_A'), plt_t.u('TA'), 'renewal_7d', current_date + 30, 'sms', now() + interval '23 days');
  PERFORM plt_t.fails('T15 reminder at most once',
    format($q$INSERT INTO platform.reminder (subject_type, subject_id, tenant_id, kind, anchor_date, channel, scheduled_for) VALUES ('subscription', %L, %L, 'renewal_7d', current_date + 30, 'sms', now())$q$,
           plt_t.u('SUB_A'), plt_t.u('TA')),
    '%reminder_once%');
END $$;

-- T16 نمایندگان: قلمرو، قاعدهٔ کمیسیون، تعهد کمیسیون، تسویه، سهمیهٔ لایسنس
DO $$
DECLARE
  v_rule_tier uuid;
  v_rule_res uuid;
  v_ce uuid;
  v_w uuid;
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('A'));
  PERFORM plt_t.fails('T16 active reseller needs contract',
    $q$INSERT INTO platform.reseller (code, legal_name, person_type, national_id, kinds, tier_code, status, referral_code) VALUES ('R-BAD', 'x', 'natural', '0012345678', '{sales}', 'gold', 'active', 'rbad')$q$,
    '%reseller_active_has_contract%');
  PERFORM plt_t.fails('T16 reseller user active needs MFA',
    format($q$INSERT INTO platform.reseller_user (reseller_id, oidc_subject, display_name, mobile, role, status) VALUES (%L, 'kc-x', 'x', '09120000009', 'reseller_agent', 'active')$q$, plt_t.u('R1')),
    '%reseller_user_active_requires_mfa%');
  INSERT INTO platform.reseller_territory (reseller_id, province_code, city_code, exclusive, valid_from) VALUES (plt_t.u('R1'), 'THR', '01', true, '2026-01-01');
  PERFORM plt_t.fails('T16 exclusive territory overlap',
    format($q$INSERT INTO platform.reseller_territory (reseller_id, province_code, city_code, exclusive, valid_from) VALUES (%L, 'THR', '01', true, '2026-06-01')$q$, plt_t.u('R2')),
    '%reseller_territory_exclusive%');
  PERFORM plt_t.fails('T16 province exclusivity vs city exclusivity',
    format($q$INSERT INTO platform.reseller_territory (reseller_id, province_code, exclusive, valid_from) VALUES (%L, 'THR', true, '2026-06-01')$q$, plt_t.u('R2')),
    'HK_PLT_TERRITORY_CONFLICT%');
  INSERT INTO platform.reseller_territory (reseller_id, province_code, city_code, exclusive, valid_from) VALUES (plt_t.u('R2'), 'THR', '01', false, '2026-06-01');
  INSERT INTO platform.reseller_territory (reseller_id, province_code, exclusive, valid_from) VALUES (plt_t.u('R2'), 'ESF', true, '2026-01-01');

  INSERT INTO platform.commission_rule (scope, tier_code, event, rate_pct, valid_from, created_by) VALUES
    ('tier', 'gold', 'first_sale', 20, '2026-01-01', plt_t.u('A')), ('tier', 'gold', 'renewal', 10, '2026-01-01', plt_t.u('A')),
    ('tier', 'gold', 'addon', 10, '2026-01-01', plt_t.u('A'));
  SELECT id INTO v_rule_tier FROM platform.commission_rule WHERE tier_code = 'gold' AND event = 'first_sale';
  INSERT INTO platform.commission_rule (scope, reseller_id, product_code, event, rate_pct, valid_from, created_by)
  VALUES ('reseller', plt_t.u('R1'), 'pro', 'first_sale', 25, '2026-01-01', plt_t.u('A')) RETURNING id INTO v_rule_res;
  PERFORM plt_t.fails('T16 commission rules do not overlap',
    $q$INSERT INTO platform.commission_rule (scope, tier_code, event, rate_pct, valid_from) VALUES ('tier', 'gold', 'first_sale', 30, '2026-06-01')$q$,
    '%commission_rule_no_overlap%');
  PERFORM plt_t.fails('T16 commission rule immutable', format($q$UPDATE platform.commission_rule SET rate_pct = 50 WHERE id = %L$q$, v_rule_tier), 'HK_PLT_IMMUTABLE_FIELD%');
  PERFORM plt_t.fails('T16 close only from today', format($q$UPDATE platform.commission_rule SET valid_to = current_date - 1 WHERE id = %L$q$, v_rule_tier), 'HK_PLT_INVALID_TRANSITION%');
  PERFORM plt_t.ok('T16 most specific rule chosen', platform.commission_rule_for(plt_t.u('R1'), 'first_sale', 'pro', current_date) = v_rule_res
                                                    AND platform.commission_rule_for(plt_t.u('R1'), 'first_sale', 'extra_pos', current_date) = v_rule_tier);
  PERFORM plt_t.fails('T16 accrual must use applicable rule',
    format($q$INSERT INTO platform.commission_entry (reseller_id, event, invoice_id, invoice_line_id, rule_id, basis_amount, rate_pct, amount) VALUES (%L, 'first_sale', %L, %L, %L, 0, 0, 1)$q$,
           plt_t.u('R1'), plt_t.u('INV1'), plt_t.u('L1'), v_rule_tier),
    'HK_PLT_COMMISSION_RULE%');
  PERFORM plt_t.fails('T16 accrual on unpaid invoice',
    format($q$INSERT INTO platform.commission_entry (reseller_id, event, invoice_id, invoice_line_id, rule_id, basis_amount, rate_pct, amount) VALUES (%L, 'first_sale', %L, %L, %L, 0, 0, 1)$q$,
           plt_t.u('R1'), plt_t.u('INV2'), plt_t.u('L2'), v_rule_tier),
    'HK_PLT_COMMISSION_BASIS%');
  PERFORM plt_t.fails('T16 accrual for unattributed reseller',
    format($q$INSERT INTO platform.commission_entry (reseller_id, event, invoice_id, invoice_line_id, rule_id, basis_amount, rate_pct, amount) VALUES (%L, 'first_sale', %L, %L, %L, 0, 0, 1)$q$,
           plt_t.u('R2'), plt_t.u('INV1'), plt_t.u('L1'), v_rule_res),
    'HK_PLT_COMMISSION_BASIS%');
  INSERT INTO platform.commission_entry (reseller_id, event, invoice_id, invoice_line_id, rule_id, basis_amount, rate_pct, amount)
  VALUES (plt_t.u('R1'), 'first_sale', plt_t.u('INV1'), plt_t.u('L1'), v_rule_res, 0, 0, 1) RETURNING id INTO v_ce;
  PERFORM plt_t.ok('T16 accrual = trunc(net x rate)', (SELECT amount = 2500000 AND basis_amount = 10000000 AND rate_pct = 25 FROM platform.commission_entry WHERE id = v_ce));
  SELECT id INTO v_w FROM platform.wallet WHERE reseller_id = plt_t.u('R1');
  PERFORM plt_t.ok('T16 accrual credits reseller wallet', (SELECT balance = 2500000 FROM platform.wallet WHERE id = v_w));
  PERFORM plt_t.fails('T16 one accrual per line',
    format($q$INSERT INTO platform.commission_entry (reseller_id, event, invoice_id, invoice_line_id, rule_id, basis_amount, rate_pct, amount) VALUES (%L, 'first_sale', %L, %L, %L, 0, 0, 1)$q$,
           plt_t.u('R1'), plt_t.u('INV1'), plt_t.u('L1'), v_rule_res),
    '%commission_one_accrual_per_line%');
  PERFORM plt_t.fails('T16 reversal above original',
    format($q$INSERT INTO platform.commission_entry (reseller_id, event, reverses_entry_id, amount) VALUES (%L, 'reversal', %L, -3000000)$q$, plt_t.u('R1'), v_ce),
    'HK_PLT_COMMISSION_REVERSAL%');
  INSERT INTO platform.commission_entry (reseller_id, event, reverses_entry_id, amount) VALUES (plt_t.u('R1'), 'reversal', v_ce, -1000000);
  INSERT INTO platform.commission_entry (reseller_id, event, reverses_entry_id, amount) VALUES (plt_t.u('R1'), 'reversal', v_ce, -1500000);
  PERFORM plt_t.fails('T16 total reversals bounded',
    format($q$INSERT INTO platform.commission_entry (reseller_id, event, reverses_entry_id, amount) VALUES (%L, 'reversal', %L, -1)$q$, plt_t.u('R1'), v_ce),
    'HK_PLT_COMMISSION_REVERSAL%');
  PERFORM plt_t.fails('T16 reversal must be negative',
    format($q$INSERT INTO platform.commission_entry (reseller_id, event, reverses_entry_id, amount) VALUES (%L, 'reversal', %L, 5)$q$, plt_t.u('R1'), v_ce),
    '%commission_entry_check%');
  PERFORM plt_t.fails('T16 adjustment needs approval',
    format($q$INSERT INTO platform.commission_entry (reseller_id, event, amount, reason) VALUES (%L, 'adjustment', 4000000, 'manual bonus for Q3 targets')$q$, plt_t.u('R1')),
    'HK_PLT_APPROVAL_REQUIRED%');
  INSERT INTO platform.commission_entry (reseller_id, event, amount, reason, approval_id)
  VALUES (plt_t.u('R1'), 'adjustment', 4000000, 'manual bonus for Q3 targets', plt_t.approve('commission.adjustment', 'reseller', plt_t.u('R1'), plt_t.u('A'), plt_t.u('F')));
  PERFORM plt_t.ok('T16 reseller wallet = net commissions', (SELECT balance = 4000000 FROM platform.wallet WHERE id = v_w));
  PERFORM plt_t.fails('T16 commission entries append-only', $q$UPDATE platform.commission_entry SET reason = 'x'$q$, '%permission denied%');

  -- تسویه
  PERFORM plt_t.fails('T16 payout wallet must be reseller''s',
    format($q$INSERT INTO platform.payout (reseller_id, wallet_id, amount, sheba, requested_by_kind, requested_by_id) VALUES (%L, %L, 1, 'IR000000000000000000000001', 'staff', %L)$q$,
           plt_t.u('R2'), v_w, plt_t.u('A')),
    'HK_PLT_PAYOUT_WALLET%');
  INSERT INTO platform.payout (id, reseller_id, wallet_id, amount, sheba, requested_by_kind, requested_by_id) VALUES
    (plt_t.u('PO1'), plt_t.u('R1'), v_w, 5000000, 'IR000000000000000000000001', 'staff', plt_t.u('A')),
    (plt_t.u('PO2'), plt_t.u('R1'), v_w, 3000000, 'IR000000000000000000000001', 'staff', plt_t.u('A'));
  PERFORM plt_t.fails('T16 payout above balance', format($q$UPDATE platform.payout SET status = 'submitted' WHERE id = %L$q$, plt_t.u('PO1')), 'HK_PLT_INSUFFICIENT_BALANCE%');
  UPDATE platform.payout SET status = 'submitted' WHERE id = plt_t.u('PO2');
  PERFORM plt_t.fails('T16 pending payouts reserve balance',
    format($q$UPDATE platform.payout SET status = 'submitted', amount = 2000000 WHERE id = %L$q$, plt_t.u('PO1')), 'HK_PLT_INSUFFICIENT_BALANCE%');
  PERFORM plt_t.fails('T16 submitted payout frozen', format($q$UPDATE platform.payout SET amount = 1 WHERE id = %L$q$, plt_t.u('PO2')), 'HK_PLT_IMMUTABLE_FIELD%');
  PERFORM plt_t.fails('T16 payout approval required', format($q$UPDATE platform.payout SET status = 'approved' WHERE id = %L$q$, plt_t.u('PO2')), 'HK_PLT_APPROVAL_REQUIRED%');
  UPDATE platform.payout SET status = 'approved', approval_id = plt_t.approve('payout.approve', 'payout', plt_t.u('PO2'), plt_t.u('A'), plt_t.u('F')) WHERE id = plt_t.u('PO2');
  PERFORM plt_t.fails('T16 taxpayer reseller e-invoice before paying',
    format($q$UPDATE platform.payout SET status = 'paid', bank_ref = 'SATNA-1' WHERE id = %L$q$, plt_t.u('PO2')), 'HK_PLT_PAYOUT_TAX_INVOICE%');
  UPDATE platform.payout SET status = 'paid', bank_ref = 'SATNA-1', reseller_invoice_taxid = 'B22222222222222222222B' WHERE id = plt_t.u('PO2');
  PERFORM plt_t.ok('T16 payout debits wallet once', (SELECT balance = 1000000 FROM platform.wallet WHERE id = v_w)
                                                  AND (SELECT wallet_entry_id IS NOT NULL AND paid_at IS NOT NULL FROM platform.payout WHERE id = plt_t.u('PO2')));
  UPDATE platform.payout SET status = 'cancelled' WHERE id = plt_t.u('PO1');
  PERFORM plt_t.fails('T16 paid payout final', format($q$UPDATE platform.payout SET status = 'failed', failure_reason = 'x' WHERE id = %L$q$, plt_t.u('PO2')), 'HK_PLT_INVALID_TRANSITION%');
  -- بازپس‌گیری کمیسیون پس از تسویه می‌تواند کیف پول نماینده را منفی کند (بدهی به پلتفرم)
  INSERT INTO platform.commission_entry (reseller_id, event, invoice_id, invoice_line_id, rule_id, basis_amount, rate_pct, amount)
  VALUES (plt_t.u('R1'), 'addon', plt_t.u('INV4'), plt_t.u('L4'), platform.commission_rule_for(plt_t.u('R1'), 'addon', 'extra_pos', current_date), 0, 0, 1)
  RETURNING id INTO v_ce;
  PERFORM plt_t.ok('T16 addon accrual 10%', (SELECT amount = 600000 FROM platform.commission_entry WHERE id = v_ce));
  INSERT INTO platform.payout (id, reseller_id, wallet_id, amount, sheba, requested_by_kind, requested_by_id)
  VALUES (plt_t.u('U1'), plt_t.u('R1'), v_w, 1600000, 'IR000000000000000000000001', 'staff', plt_t.u('A'));
  UPDATE platform.payout SET status = 'submitted' WHERE id = plt_t.u('U1');
  UPDATE platform.payout SET status = 'approved', approval_id = plt_t.approve('payout.approve', 'payout', plt_t.u('U1'), plt_t.u('A'), plt_t.u('F')) WHERE id = plt_t.u('U1');
  UPDATE platform.payout SET status = 'paid', bank_ref = 'SATNA-2', reseller_invoice_taxid = 'B33333333333333333333B' WHERE id = plt_t.u('U1');
  INSERT INTO platform.commission_entry (reseller_id, event, reverses_entry_id, amount) VALUES (plt_t.u('R1'), 'reversal', v_ce, -600000);
  PERFORM plt_t.ok('T16 clawback leaves reseller debt', (SELECT balance = -600000 FROM platform.wallet WHERE id = v_w));
  PERFORM plt_t.ok('T16 reseller wallet consistent', NOT EXISTS (SELECT 1 FROM platform.v_wallet_integrity));
  -- سهمیهٔ لایسنس
  PERFORM plt_t.fails('T16 quota purchase needs paid reseller invoice',
    format($q$INSERT INTO platform.reseller_quota_entry (reseller_id, product_code, seq, kind, delta, balance_after, invoice_id) VALUES (%L, 'onprem_pro', 0, 'purchase', 5, 0, %L)$q$, plt_t.u('R1'), plt_t.u('INV1')),
    'HK_PLT_QUOTA_SHAPE%');
  PERFORM plt_t.fails('T16 quota per license product',
    format($q$INSERT INTO platform.reseller_quota_entry (reseller_id, product_code, seq, kind, delta, balance_after, approval_id) VALUES (%L, 'pro', 0, 'adjustment', 5, 0, %L)$q$, plt_t.u('R1'), plt_t.u('PO2')),
    'HK_PLT_QUOTA_SHAPE%');
  INSERT INTO platform.reseller_quota_entry (reseller_id, product_code, seq, kind, delta, balance_after, approval_id)
  VALUES (plt_t.u('R1'), 'onprem_pro', 0, 'adjustment', 2, 0, plt_t.approve('reseller.quota_adjustment', 'reseller', plt_t.u('R1'), plt_t.u('F'), plt_t.u('A')));
  PERFORM plt_t.ok('T16 quota balance', (SELECT balance_after = 2 AND seq = 1 FROM platform.reseller_quota_entry WHERE reseller_id = plt_t.u('R1')));
  PERFORM plt_t.fails('T16 quota never negative',
    format($q$INSERT INTO platform.reseller_quota_entry (reseller_id, product_code, seq, kind, delta, balance_after, approval_id) VALUES (%L, 'onprem_pro', 0, 'adjustment', -3, 0, %L)$q$,
           plt_t.u('R1'), plt_t.approve('reseller.quota_adjustment', 'reseller', plt_t.u('R1'), plt_t.u('F'), plt_t.u('A'))),
    'HK_PLT_QUOTA_EXHAUSTED%');
END $$;

-- T17 سفارش خدمت (مهاجرت همراه، نصب On-prem)
DO $$
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('A'));
  PERFORM plt_t.fails('T17 assisted migration names the source',
    format($q$INSERT INTO platform.service_order (tenant_id, kind, number) VALUES (%L, 'assisted_migration', 'x')$q$, plt_t.u('TA')),
    '%service_order_check%');
  INSERT INTO platform.service_order (id, tenant_id, kind, product_version_id, source_system, number, created_by)
  VALUES (plt_t.u('SO1'), plt_t.u('TA'), 'assisted_migration', plt_t.u('PV4'), 'holoo', 'placeholder', plt_t.u('A'));
  PERFORM plt_t.ok('T17 service order numbered', (SELECT number = 'SO-000001' FROM platform.service_order WHERE id = plt_t.u('SO1')));
  PERFORM plt_t.fails('T17 unqualified reseller',
    format($q$UPDATE platform.service_order SET assignee_kind = 'reseller', assignee_reseller_id = %L WHERE id = %L$q$, plt_t.u('R2'), plt_t.u('SO1')),
    'HK_PLT_RESELLER_NOT_QUALIFIED%');
  UPDATE platform.service_order SET assignee_kind = 'reseller', assignee_reseller_id = plt_t.u('R1') WHERE id = plt_t.u('SO1');
  PERFORM plt_t.fails('T17 skip states', format($q$UPDATE platform.service_order SET status = 'in_progress' WHERE id = %L$q$, plt_t.u('SO1')), 'HK_PLT_INVALID_TRANSITION%');
  PERFORM plt_t.fails('T17 quote needs price', format($q$UPDATE platform.service_order SET status = 'quoted' WHERE id = %L$q$, plt_t.u('SO1')), 'HK_PLT_SERVICE_ORDER_QUOTE%');
  UPDATE platform.service_order SET status = 'quoted', quote_amount = 30000000 WHERE id = plt_t.u('SO1');
  UPDATE platform.service_order SET status = 'accepted' WHERE id = plt_t.u('SO1');
  UPDATE platform.service_order SET status = 'scheduled' WHERE id = plt_t.u('SO1');
  PERFORM plt_t.fails('T17 work needs tenant consent', format($q$UPDATE platform.service_order SET status = 'in_progress' WHERE id = %L$q$, plt_t.u('SO1')),
    '%service_order_consent%');
  UPDATE platform.service_order SET status = 'in_progress', consent_ref = plt_t.u('G1') WHERE id = plt_t.u('SO1');
  PERFORM plt_t.fails('T17 identity immutable', format($q$UPDATE platform.service_order SET kind = 'training' WHERE id = %L$q$, plt_t.u('SO1')), 'HK_PLT_IMMUTABLE_FIELD%');
  PERFORM plt_t.fails('T17 never deleted', $q$DELETE FROM platform.service_order$q$, '%permission denied%');
END $$;

-- T18 سنجش مصرف و uplink (نقش ingest)
RESET ROLE;
SET ROLE hk_platform_ingest;
DO $$
BEGIN
  INSERT INTO platform.uplink_batch (batch_id, source_kind, source_id, tenant_id, kind, item_count, payload_sha256)
  VALUES (plt_t.u('UB1'), 'cell', 'cell-02', plt_t.u('TA'), 'usage', 6, plt_t.h('ub1'));
  INSERT INTO platform.uplink_batch (batch_id, source_kind, source_id, tenant_id, kind, item_count, payload_sha256)
  VALUES (plt_t.u('UB1'), 'cell', 'cell-02', plt_t.u('TA'), 'usage', 6, plt_t.h('ub1')) ON CONFLICT (batch_id) DO NOTHING;
  PERFORM plt_t.ok('T18 duplicate batch is a no-op', (SELECT count(*) = 1 FROM platform.uplink_batch WHERE batch_id = plt_t.u('UB1')));
  PERFORM plt_t.fails('T18 same batch id with other payload',
    format($q$INSERT INTO platform.uplink_batch (batch_id, source_kind, source_id, tenant_id, kind, item_count, payload_sha256) VALUES (%L, 'cell', 'cell-02', %L, 'usage', 6, plt_t.h('other')) ON CONFLICT (batch_id) DO NOTHING$q$,
           plt_t.u('UB1'), plt_t.u('TA')),
    'HK_PLT_UPLINK_BATCH_CONFLICT%');
  PERFORM plt_t.fails('T18 batch size bounded',
    format($q$INSERT INTO platform.uplink_batch (batch_id, source_kind, source_id, kind, item_count, payload_sha256) VALUES (%L, 'cell', 'cell-02', 'usage', 6000, plt_t.h('big'))$q$, plt_t.u('UB2')),
    '%uplink_batch_item_count_check%');
  INSERT INTO platform.usage_event (tenant_id, event_id, metric, quantity, occurred_at, day, batch_id) VALUES
    (plt_t.u('TA'), '70000000-0000-7000-8000-00000000e101', 'meter.sms_parts', 10, now(), current_date, plt_t.u('UB1')),
    (plt_t.u('TA'), '70000000-0000-7000-8000-00000000e102', 'meter.sms_parts', 5, now(), current_date, plt_t.u('UB1')),
    (plt_t.u('TA'), '70000000-0000-7000-8000-00000000e103', 'limit.users', 3, now(), current_date, plt_t.u('UB1')),
    (plt_t.u('TA'), '70000000-0000-7000-8000-00000000e104', 'limit.users', 5, now(), current_date, plt_t.u('UB1')),
    (plt_t.u('TA'), '70000000-0000-7000-8000-00000000e105', 'limit.users', 4, now(), current_date, plt_t.u('UB1'));
  PERFORM plt_t.ok('T18 meter summed', (SELECT quantity = 15 AND event_count = 2 FROM platform.usage_daily WHERE tenant_id = plt_t.u('TA') AND metric = 'meter.sms_parts'));
  PERFORM plt_t.ok('T18 gauge is daily max', (SELECT quantity = 5 AND event_count = 3 FROM platform.usage_daily WHERE tenant_id = plt_t.u('TA') AND metric = 'limit.users'));
  PERFORM plt_t.fails('T18 usage idempotent per event',
    format($q$INSERT INTO platform.usage_event (tenant_id, event_id, metric, quantity, occurred_at, day, batch_id) VALUES (%L, '70000000-0000-7000-8000-00000000e101', 'meter.sms_parts', 10, now(), current_date, %L)$q$,
           plt_t.u('TA'), plt_t.u('UB1')),
    '%usage_event_pkey%');
  PERFORM plt_t.fails('T18 flags are not usage metrics',
    format($q$INSERT INTO platform.usage_event (tenant_id, event_id, metric, quantity, occurred_at, day, batch_id) VALUES (%L, gen_random_uuid(), 'module.pos', 1, now(), current_date, %L)$q$,
           plt_t.u('TA'), plt_t.u('UB1')),
    'HK_PLT_USAGE_METRIC%');
  PERFORM plt_t.fails('T18 local day near occurrence',
    format($q$INSERT INTO platform.usage_event (tenant_id, event_id, metric, quantity, occurred_at, day, batch_id) VALUES (%L, gen_random_uuid(), 'meter.sms_parts', 1, now(), current_date - 5, %L)$q$,
           plt_t.u('TA'), plt_t.u('UB1')),
    '%usage_event_check%');
  PERFORM plt_t.fails('T18 usage daily derived', format($q$UPDATE platform.usage_daily SET quantity = 0 WHERE tenant_id = %L$q$, plt_t.u('TA')), 'HK_PLT_DERIVED_COLUMN%');
  PERFORM plt_t.fails('T18 events append-only', $q$UPDATE platform.usage_event SET quantity = 0$q$, '%permission denied%');
  -- آینهٔ رضایت پشتیبانی مستأجر
  INSERT INTO platform.support_consent (tenant_id, grant_id, grantee_kind, reseller_id, access_mode, max_session_minutes, starts_at, expires_at) VALUES
    (plt_t.u('TA'), plt_t.u('G1'), 'platform_support', NULL, 'read_only', 60, now() - interval '1 hour', now() + interval '23 hours'),
    (plt_t.u('TA'), plt_t.u('G2'), 'platform_support', NULL, 'read_write', 120, now() - interval '1 hour', now() + interval '23 hours'),
    (plt_t.u('TA'), plt_t.u('G3'), 'reseller', plt_t.u('R1'), 'read_only', 60, now() - interval '1 hour', now() + interval '23 hours'),
    (plt_t.u('TA'), plt_t.u('G4'), 'platform_support', NULL, 'read_only', 60, now() - interval '3 days', now() - interval '2 days');
  PERFORM plt_t.fails('T18 consent cannot be extended',
    format($q$UPDATE platform.support_consent SET expires_at = expires_at + interval '1 day' WHERE grant_id = %L$q$, plt_t.u('G1')), 'HK_PLT_CONSENT_EXTEND%');
  PERFORM plt_t.fails('T18 consent content immutable',
    format($q$UPDATE platform.support_consent SET access_mode = 'read_write' WHERE grant_id = %L$q$, plt_t.u('G1')), 'HK_PLT_IMMUTABLE_FIELD%');
  PERFORM plt_t.fails('T18 consent window at most 7 days',
    format($q$INSERT INTO platform.support_consent (tenant_id, grant_id, grantee_kind, access_mode, max_session_minutes, starts_at, expires_at) VALUES (%L, gen_random_uuid(), 'platform_support', 'read_only', 60, now(), now() + interval '8 days')$q$, plt_t.u('TA')),
    '%support_consent_check%');
  -- لنگر ممیزی مستأجر (T24)
  INSERT INTO platform.tenant_audit_anchor (tenant_id, chain_no, seq, hash, checkpoint_id, checkpoint_at) VALUES
    (plt_t.u('TA'), 0, 10, plt_t.h('a10'), gen_random_uuid(), now());
  PERFORM plt_t.fails('T24 audit fork detected',
    format($q$INSERT INTO platform.tenant_audit_anchor (tenant_id, chain_no, seq, hash, checkpoint_id, checkpoint_at) VALUES (%L, 0, 10, plt_t.h('forged'), gen_random_uuid(), now())$q$, plt_t.u('TA')),
    'HK_PLT_AUDIT_FORK%');
  PERFORM plt_t.fails('T24 audit rollback detected',
    format($q$INSERT INTO platform.tenant_audit_anchor (tenant_id, chain_no, seq, hash, checkpoint_id, checkpoint_at) VALUES (%L, 0, 5, plt_t.h('a5'), gen_random_uuid(), now())$q$, plt_t.u('TA')),
    'HK_PLT_AUDIT_ROLLBACK%');
  INSERT INTO platform.tenant_audit_anchor (tenant_id, chain_no, seq, hash, checkpoint_id, checkpoint_at) VALUES (plt_t.u('TA'), 0, 20, plt_t.h('a20'), gen_random_uuid(), now());
  -- مرکز مهاجرت: نامزد فرهنگ و رأی مستأجرها
  INSERT INTO platform.migration_dictionary_candidate (id, source_system, dict_kind, source_text_norm, target_key)
  VALUES (plt_t.u('C1'), 'holoo', 'header_synonym', 'کد کالا', 'item.code');
  INSERT INTO platform.migration_dictionary_vote (candidate_id, tenant_id) VALUES (plt_t.u('C1'), plt_t.u('TA')), (plt_t.u('C1'), plt_t.u('TB'));
  PERFORM plt_t.ok('T22 votes counted', (SELECT distinct_tenants = 2 AND status = 'collecting' FROM platform.migration_dictionary_candidate WHERE id = plt_t.u('C1')));
  PERFORM plt_t.fails('T22 one vote per tenant',
    format($q$INSERT INTO platform.migration_dictionary_vote (candidate_id, tenant_id) VALUES (%L, %L)$q$, plt_t.u('C1'), plt_t.u('TA')),
    '%migration_dictionary_vote_pkey%');
  INSERT INTO platform.migration_job_stat (tenant_id, job_id, source_system, channel, status, rows_total, issues_by_code, source_event_at)
  VALUES (plt_t.u('TA'), plt_t.u('U1'), 'holoo', 'agent', 'running', 1000, '{"MIG_UNIT_MISSING": 3}', now());
  UPDATE platform.migration_job_stat SET status = 'queued', source_event_at = now() - interval '1 hour' WHERE job_id = plt_t.u('U1');
  PERFORM plt_t.ok('T22 stale job event ignored', (SELECT status = 'running' FROM platform.migration_job_stat WHERE job_id = plt_t.u('U1')));
  UPDATE platform.migration_job_stat SET status = 'committed', issues_by_code = '{"MIG_UNIT_MISSING": 4, "MIG_DUP_CODE": 1}', source_event_at = now() + interval '1 minute' WHERE job_id = plt_t.u('U1');
  -- آمار مؤدیان
  INSERT INTO platform.moadian_tenant_stat (tenant_id, day, sent, accepted, rejected, pending, near_deadline, signer_mode, signer_online, cert_expires_on)
  VALUES (plt_t.u('TA'), current_date, 40, 37, 1, 2, 1, 'device_agent', false, current_date + 10);
  PERFORM plt_t.fails('T26 ingest cannot read billing', $q$SELECT count(*) FROM platform.invoice$q$, '%permission denied%');
  PERFORM plt_t.fails('T26 ingest cannot write tenants', $q$UPDATE platform.tenant SET display_name = 'x'$q$, '%permission denied%');
  PERFORM plt_t.fails('T26 ingest audit actor', format($q$INSERT INTO platform.audit_log (actor_kind, actor_id, action) VALUES ('staff', %L, 'platform.x.y')$q$, plt_t.u('A')),
    'HK_PLT_AUDIT_ACTOR%');
  INSERT INTO platform.audit_log (actor_kind, actor_id, actor_label, action, tenant_id) VALUES ('cell', gen_random_uuid(), 'cell-02', 'platform.uplink.batch_received', plt_t.u('TA'));
  -- تمرین بازیابی گزارش‌شده
  PERFORM plt_t.fails('T09 successful drill needs equal control totals',
    $q$INSERT INTO platform.backup_drill (cell_id, repo, backup_label, started_at, finished_at, outcome, control_totals_match) VALUES ('cell-01', 'repo1', 'b1', now() - interval '1 hour', now(), 'succeeded', false)$q$,
    '%drill_success_requires_totals%');
  INSERT INTO platform.backup_drill (cell_id, repo, backup_label, started_at) VALUES ('cell-01', 'repo2', 'weekly-49', now() - interval '1 hour');
  UPDATE platform.backup_drill SET finished_at = now(), outcome = 'succeeded', control_totals_match = true WHERE backup_label = 'weekly-49';
  PERFORM plt_t.fails('T09 finished drill immutable', $q$UPDATE platform.backup_drill SET outcome = 'failed' WHERE backup_label = 'weekly-49'$q$, 'HK_PLT_IMMUTABLE%');
  INSERT INTO platform.cell_backup_status (cell_id, repo, last_full_at, wal_archive_age_s) VALUES ('cell-01', 'repo1', now() - interval '1 day', 40);
END $$;
RESET ROLE;
SET ROLE hk_platform_app;

DO $$
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('A'));
  PERFORM plt_t.fails('T18 app cannot write usage_daily',
    format($q$INSERT INTO platform.usage_daily (tenant_id, metric, day, quantity) VALUES (%L, 'meter.sms_parts', current_date - 1, 1)$q$, plt_t.u('TB')),
    'HK_PLT_DERIVED_COLUMN%');
  PERFORM plt_t.fails('T18 app cannot insert uplink batches',
    format($q$INSERT INTO platform.uplink_batch (batch_id, source_kind, source_id, kind, item_count, payload_sha256) VALUES (%L, 'cell', 'x', 'usage', 1, plt_t.h('x'))$q$, plt_t.u('UB2')),
    '%permission denied%');
  UPDATE platform.uplink_batch SET processed_at = now() WHERE batch_id = plt_t.u('UB1');
  PERFORM plt_t.fails('T18 batch identity immutable', format($q$UPDATE platform.uplink_batch SET item_count = 1 WHERE batch_id = %L$q$, plt_t.u('UB1')), 'HK_PLT_IMMUTABLE_FIELD%');
  PERFORM plt_t.ok('T22 top issues view', (SELECT occurrences = 4 FROM platform.v_migration_top_issues WHERE source_system = 'holoo' AND issue_code = 'MIG_UNIT_MISSING'));
  PERFORM plt_t.ok('T18 Moadian attention list', EXISTS (SELECT 1 FROM platform.v_moadian_attention WHERE tenant_id = plt_t.u('TA')));
  PERFORM plt_t.ok('T09 backup status view', (SELECT last_drill_ok AND cell_last_full_at IS NOT NULL FROM platform.v_tenant_backup_status WHERE tenant_id = plt_t.u('TB')));
  -- فرهنگ مهاجرت
  PERFORM plt_t.fails('T22 promotion below threshold',
    format($q$UPDATE platform.migration_dictionary_candidate SET status = 'approved', decided_by = %L WHERE id = %L$q$, plt_t.u('A'), plt_t.u('C1')),
    '%dictionary_threshold%');
  PERFORM plt_t.fails('T22 tenant count derived',
    format($q$UPDATE platform.migration_dictionary_candidate SET distinct_tenants = 9 WHERE id = %L$q$, plt_t.u('C1')), 'HK_PLT_DERIVED_COLUMN%');
END $$;
RESET ROLE;
SET ROLE hk_platform_ingest;
INSERT INTO platform.migration_dictionary_vote (candidate_id, tenant_id) VALUES ('70000000-0000-7000-8000-000000007501', '70000000-0000-7000-8000-000000000003');
RESET ROLE;
SET ROLE hk_platform_app;

-- T19 پشتیبانی: ورود به‌جای کاربر، تیکت، اطلاعیه؛ T22 ادامه؛ T25 درخواست داده
DO $$
DECLARE
  v uuid;
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('A'));
  PERFORM plt_t.ok('T22 eligible at threshold', (SELECT status = 'eligible' AND distinct_tenants = 3 FROM platform.migration_dictionary_candidate WHERE id = plt_t.u('C1')));
  PERFORM plt_t.as_staff(plt_t.u('S'));
  PERFORM plt_t.fails('T22 decision needs permission',
    format($q$UPDATE platform.migration_dictionary_candidate SET status = 'approved', decided_by = %L WHERE id = %L$q$, plt_t.u('S'), plt_t.u('C1')), 'HK_PLT_PERMISSION%');
  PERFORM plt_t.as_staff(plt_t.u('A'));
  UPDATE platform.migration_dictionary_candidate SET status = 'approved', decided_by = plt_t.u('A') WHERE id = plt_t.u('C1');
  PERFORM plt_t.fails('T22 dictionary release four eyes',
    format($q$INSERT INTO platform.migration_dictionary_release (version, status, entries, hksb_sha256, created_by, approved_by, published_at) VALUES (1, 'published', 1, plt_t.h('d'), %L, %L, now())$q$, plt_t.u('A'), plt_t.u('A')),
    '%dictionary_release_four_eyes%');
  INSERT INTO platform.migration_dictionary_release (version, status, entries, payload_sha256, hksb_sha256, created_by, approved_by, published_at)
  VALUES (1, 'published', 1, plt_t.h('dp'), plt_t.h('d'), plt_t.u('A'), plt_t.u('O'), now());
  PERFORM plt_t.fails('T22 profile beta needs golden dataset',
    $q$INSERT INTO platform.migration_profile_release (profile_code, version, source_system, status, hksb_sha256) VALUES ('holoo.sqlserver', '1.0.0', 'holoo', 'beta', plt_t.h('p'))$q$,
    '%profile_beta_gate%');
  PERFORM plt_t.fails('T22 real sample needs written consent',
    $q$INSERT INTO platform.migration_profile_release (profile_code, version, source_system, golden_dataset_passed, real_sample_passed) VALUES ('holoo.sqlserver', '1.0.0', 'holoo', true, true)$q$,
    '%profile_sample_consent%');
  PERFORM plt_t.fails('T22 publish needs real sample',
    format($q$INSERT INTO platform.migration_profile_release (profile_code, version, source_system, status, golden_dataset_passed, hksb_sha256, published_by, published_at) VALUES ('holoo.sqlserver', '1.0.0', 'holoo', 'published', true, plt_t.h('p'), %L, now())$q$, plt_t.u('A')),
    '%profile_published_gate%');
  INSERT INTO platform.migration_profile_release (profile_code, version, source_system, status, golden_dataset_passed, real_sample_passed, sample_consent_ref, hksb_sha256, published_by, published_at)
  VALUES ('holoo.sqlserver', '1.0.0', 'holoo', 'published', true, true, 'CONSENT-PILOT-1', plt_t.h('p'), plt_t.u('A'), now());

  -- ورود به‌جای کاربر
  PERFORM plt_t.as_staff(plt_t.u('S'));
  PERFORM plt_t.fails('T19 consent must be active',
    format($q$INSERT INTO platform.impersonation_request (tenant_id, grant_id, requester_kind, staff_id, mode, reason, ticket_ref, max_minutes) VALUES (%L, %L, 'staff', %L, 'read_only', 'customer reports wrong totals', 'T-1', 30)$q$,
           plt_t.u('TA'), plt_t.u('G4'), plt_t.u('S')),
    'HK_PLT_CONSENT_INACTIVE%');
  PERFORM plt_t.fails('T19 consent mode',
    format($q$INSERT INTO platform.impersonation_request (tenant_id, grant_id, requester_kind, staff_id, mode, target_user_id, reason, ticket_ref, max_minutes) VALUES (%L, %L, 'staff', %L, 'read_write', gen_random_uuid(), 'customer reports wrong totals', 'T-1', 30)$q$,
           plt_t.u('TA'), plt_t.u('G1'), plt_t.u('S')),
    'HK_PLT_CONSENT_MODE%');
  PERFORM plt_t.fails('T19 consent duration',
    format($q$INSERT INTO platform.impersonation_request (tenant_id, grant_id, requester_kind, staff_id, mode, reason, ticket_ref, max_minutes) VALUES (%L, %L, 'staff', %L, 'read_only', 'customer reports wrong totals', 'T-1', 90)$q$,
           plt_t.u('TA'), plt_t.u('G1'), plt_t.u('S')),
    'HK_PLT_CONSENT_DURATION%');
  PERFORM plt_t.fails('T19 consent grantee',
    format($q$INSERT INTO platform.impersonation_request (tenant_id, grant_id, requester_kind, staff_id, mode, reason, ticket_ref, max_minutes) VALUES (%L, %L, 'staff', %L, 'read_only', 'customer reports wrong totals', 'T-1', 30)$q$,
           plt_t.u('TA'), plt_t.u('G3'), plt_t.u('S')),
    'HK_PLT_CONSENT_GRANTEE%');
  PERFORM plt_t.fails('T19 reason at least 10 chars',
    format($q$INSERT INTO platform.impersonation_request (tenant_id, grant_id, requester_kind, staff_id, mode, reason, ticket_ref, max_minutes) VALUES (%L, %L, 'staff', %L, 'read_only', 'check', 'T-1', 30)$q$,
           plt_t.u('TA'), plt_t.u('G1'), plt_t.u('S')),
    '%impersonation_request_reason_check%');
  PERFORM plt_t.as_staff(plt_t.u('F'));
  PERFORM plt_t.fails('T19 impersonation permission',
    format($q$INSERT INTO platform.impersonation_request (tenant_id, grant_id, requester_kind, staff_id, mode, reason, ticket_ref, max_minutes) VALUES (%L, %L, 'staff', %L, 'read_only', 'customer reports wrong totals', 'T-1', 30)$q$,
           plt_t.u('TA'), plt_t.u('G1'), plt_t.u('F')),
    'HK_PLT_PERMISSION%');
  PERFORM plt_t.as_staff(plt_t.u('S'));
  INSERT INTO platform.impersonation_request (id, tenant_id, grant_id, requester_kind, staff_id, mode, reason, ticket_ref, max_minutes)
  VALUES (plt_t.u('IMP1'), plt_t.u('TA'), plt_t.u('G1'), 'staff', plt_t.u('S'), 'read_only', 'customer reports wrong totals', 'T-000001', 30);
  PERFORM plt_t.ok('T19 read-only auto-approved', (SELECT status = 'approved' FROM platform.impersonation_request WHERE id = plt_t.u('IMP1')));
  PERFORM plt_t.fails('T19 assertion lifetime at most 2 minutes',
    format($q$UPDATE platform.impersonation_request SET status = 'issued', assertion_jti = gen_random_uuid(), assertion_expires_at = now() + interval '5 minutes' WHERE id = %L$q$, plt_t.u('IMP1')),
    '%impersonation_assertion_ttl%');
  UPDATE platform.impersonation_request SET status = 'issued', assertion_jti = plt_t.u('IMP3'), assertion_expires_at = now() + interval '60 seconds' WHERE id = plt_t.u('IMP1');
  PERFORM plt_t.fails('T19 assertion issued once',
    format($q$UPDATE platform.impersonation_request SET assertion_jti = gen_random_uuid() WHERE id = %L$q$, plt_t.u('IMP1')), 'HK_PLT_IMMUTABLE_FIELD%');
  PERFORM plt_t.fails('T19 content immutable',
    format($q$UPDATE platform.impersonation_request SET reason = 'changed the reason text' WHERE id = %L$q$, plt_t.u('IMP1')), 'HK_PLT_IMMUTABLE_FIELD%');
END $$;

-- T19b ورود نوشتنی (تأیید دوم + کاربر هدف)، تیکت، اطلاعیه
DO $$
DECLARE
  v_ticket uuid;
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('S'));
  INSERT INTO platform.impersonation_request (id, tenant_id, grant_id, requester_kind, staff_id, mode, reason, ticket_ref, max_minutes)
  VALUES (plt_t.u('IMP2'), plt_t.u('TA'), plt_t.u('G2'), 'staff', plt_t.u('S'), 'read_write', 'fix a wrong opening balance', 'T-000002', 60);
  PERFORM plt_t.fails('T19 write impersonation cannot start approved',
    format($q$INSERT INTO platform.impersonation_request (tenant_id, grant_id, requester_kind, staff_id, mode, target_user_id, reason, ticket_ref, max_minutes, status) VALUES (%L, %L, 'staff', %L, 'read_write', gen_random_uuid(), 'fix a wrong opening balance', 'T-2', 60, 'approved')$q$,
           plt_t.u('TA'), plt_t.u('G2'), plt_t.u('S')),
    'HK_PLT_APPROVAL_REQUIRED%');
  PERFORM plt_t.fails('T19 write approval required',
    format($q$UPDATE platform.impersonation_request SET status = 'approved' WHERE id = %L$q$, plt_t.u('IMP2')), 'HK_PLT_APPROVAL_REQUIRED%');
  PERFORM plt_t.fails('T19 write needs a target user',
    format($q$UPDATE platform.impersonation_request SET status = 'approved', write_approval_id = %L WHERE id = %L$q$,
           plt_t.approve('impersonation.write', 'impersonation_request', plt_t.u('IMP2'), plt_t.u('S'), plt_t.u('A')), plt_t.u('IMP2')),
    '%impersonation_write_needs_approval%');
  INSERT INTO platform.impersonation_request (id, tenant_id, grant_id, requester_kind, staff_id, mode, target_user_id, reason, ticket_ref, max_minutes)
  VALUES (plt_t.u('U1'), plt_t.u('TA'), plt_t.u('G2'), 'staff', plt_t.u('S'), 'read_write', gen_random_uuid(), 'fix a wrong opening balance', 'T-000002', 60);
  UPDATE platform.impersonation_request SET status = 'approved',
         write_approval_id = plt_t.approve('impersonation.write', 'impersonation_request', plt_t.u('U1'), plt_t.u('S'), plt_t.u('A'))
   WHERE id = plt_t.u('U1');
  UPDATE platform.impersonation_request SET status = 'cancelled' WHERE id = plt_t.u('IMP2');

  -- تیکت
  INSERT INTO platform.ticket (id, tenant_id, opened_by_kind, opener_name, subject, category, sla_hours, number)
  VALUES (plt_t.u('TK1'), plt_t.u('TA'), 'tenant_user', 'مالک کافه', 'جمع فاکتورها اشتباه است', 'technical', 8, 'x');
  INSERT INTO platform.ticket (id, tenant_id, opened_by_kind, subject, category, assigned_level, assigned_reseller_id, number)
  VALUES (plt_t.u('TK2'), plt_t.u('TC'), 'reseller_user', 'نصب سرور جدید', 'onprem', 'l1_reseller', plt_t.u('R1'), 'x');
  PERFORM plt_t.ok('T19 ticket numbered with SLA', (SELECT number = 'T-000001' AND sla_due_at = created_at + interval '8 hours' FROM platform.ticket WHERE id = plt_t.u('TK1')));
  PERFORM plt_t.fails('T19 SLA deadline immutable', format($q$UPDATE platform.ticket SET sla_due_at = now() + interval '1 year' WHERE id = %L$q$, plt_t.u('TK1')), 'HK_PLT_IMMUTABLE_FIELD%');
  PERFORM plt_t.fails('T19 L1 tickets name a reseller',
    format($q$INSERT INTO platform.ticket (tenant_id, opened_by_kind, subject, category, assigned_level, number) VALUES (%L, 'staff', 'xyz', 'other', 'l1_reseller', 'x')$q$, plt_t.u('TA')),
    '%ticket_check%');
  PERFORM plt_t.fails('T19 tenants cannot write internal notes',
    format($q$INSERT INTO platform.ticket_message (ticket_id, seq, author_kind, visibility, body) VALUES (%L, 0, 'tenant_user', 'internal', 'x')$q$, plt_t.u('TK1')),
    '%ticket_message_check%');
  INSERT INTO platform.ticket_message (ticket_id, seq, author_kind, author_name, visibility, body) VALUES (plt_t.u('TK1'), 0, 'tenant_user', 'مالک کافه', 'public', 'سلام، جمع فاکتور ۱۲ اشتباه است');
  INSERT INTO platform.ticket_message (ticket_id, seq, author_kind, author_ref, visibility, body) VALUES (plt_t.u('TK1'), 0, 'staff', plt_t.u('S'), 'internal', 'probably rounding');
  PERFORM plt_t.ok('T19 internal note is not a first response', (SELECT first_response_at IS NULL FROM platform.ticket WHERE id = plt_t.u('TK1')));
  INSERT INTO platform.ticket_message (ticket_id, seq, author_kind, author_ref, visibility, body) VALUES (plt_t.u('TK1'), 0, 'staff', plt_t.u('S'), 'public', 'در حال بررسی هستیم');
  PERFORM plt_t.ok('T19 first response derived', (SELECT first_response_at IS NOT NULL FROM platform.ticket WHERE id = plt_t.u('TK1'))
                                                 AND (SELECT array_agg(seq ORDER BY seq) = ARRAY[1,2,3] FROM platform.ticket_message WHERE ticket_id = plt_t.u('TK1')));
  PERFORM plt_t.fails('T19 first response not settable', format($q$UPDATE platform.ticket SET first_response_at = now() - interval '1 day' WHERE id = %L$q$, plt_t.u('TK1')),
    'HK_PLT_DERIVED_COLUMN%');
  PERFORM plt_t.fails('T19 messages append-only', $q$UPDATE platform.ticket_message SET body = 'x'$q$, '%permission denied%');
  UPDATE platform.ticket SET status = 'resolved', resolved_at = now() WHERE id = plt_t.u('TK1');
  UPDATE platform.ticket SET status = 'closed', closed_at = now() WHERE id = plt_t.u('TK1');
  PERFORM plt_t.fails('T19 closed ticket takes no messages',
    format($q$INSERT INTO platform.ticket_message (ticket_id, seq, author_kind, visibility, body) VALUES (%L, 0, 'tenant_user', 'public', 'هنوز درست نشده')$q$, plt_t.u('TK1')),
    'HK_PLT_TICKET_CLOSED%');
  PERFORM plt_t.fails('T19 closed is final', format($q$UPDATE platform.ticket SET status = 'open', closed_at = NULL WHERE id = %L$q$, plt_t.u('TK1')), 'HK_PLT_INVALID_TRANSITION%');

  -- اطلاعیه
  PERFORM plt_t.as_staff(plt_t.u('A'));
  PERFORM plt_t.fails('T19 targeting keys allowlisted',
    $q$INSERT INTO platform.announcement (kind, title_fa, body_fa, targeting, starts_at, ends_at) VALUES ('banner', 'x', 'y', '{"city_secret": 1}', now(), now() + interval '1 day')$q$,
    'HK_PLT_ANNOUNCEMENT_TARGETING%');
  INSERT INTO platform.announcement (id, kind, severity, title_fa, body_fa, targeting, starts_at, ends_at, created_by) VALUES
    (plt_t.u('AN1'), 'legal_notice', 'warning', 'تغییر نرخ مالیات', 'از اول دی نرخ ارزش افزوده تغییر می‌کند', '{"plans": ["pro"], "deployments": ["saas_shared"]}', now(), now() + interval '30 days', plt_t.u('A')),
    (plt_t.u('AN2'), 'maintenance', 'info', 'به‌روزرسانی', 'ساعت ۲ بامداد سرویس به‌روز می‌شود', '{}', now(), now() + interval '1 day', plt_t.u('A'));
  UPDATE platform.announcement SET sms_broadcast = true, sms_pattern_code = 'hk-maint' WHERE id = plt_t.u('AN2');
  PERFORM plt_t.fails('T19 SMS broadcast needs approval',
    format($q$UPDATE platform.announcement SET status = 'published', published_by = %L WHERE id = %L$q$, plt_t.u('A'), plt_t.u('AN2')), 'HK_PLT_APPROVAL_REQUIRED%');
  UPDATE platform.announcement SET status = 'published', published_by = plt_t.u('A'),
         sms_approval_id = plt_t.approve('announcement.sms_broadcast', 'announcement', plt_t.u('AN2'), plt_t.u('A'), plt_t.u('O'))
   WHERE id = plt_t.u('AN2');
  UPDATE platform.announcement SET status = 'published', published_by = plt_t.u('A') WHERE id = plt_t.u('AN1');
  PERFORM plt_t.fails('T19 published announcement immutable', format($q$UPDATE platform.announcement SET body_fa = 'z' WHERE id = %L$q$, plt_t.u('AN1')), 'HK_PLT_IMMUTABLE_FIELD%');
  PERFORM plt_t.fails('T19 published end cannot be extended', format($q$UPDATE platform.announcement SET ends_at = ends_at + interval '1 day' WHERE id = %L$q$, plt_t.u('AN1')), 'HK_PLT_IMMUTABLE_FIELD%');
  UPDATE platform.announcement SET ends_at = now() + interval '10 days' WHERE id = plt_t.u('AN1');
  UPDATE platform.announcement SET status = 'withdrawn' WHERE id = plt_t.u('AN1');
  PERFORM plt_t.fails('T19 withdrawn final', format($q$UPDATE platform.announcement SET status = 'published' WHERE id = %L$q$, plt_t.u('AN1')), 'HK_PLT_INVALID_TRANSITION%');
END $$;

RESET ROLE;
SET ROLE hk_platform_ingest;
UPDATE platform.impersonation_request SET status = 'used', session_started_at = now() WHERE id = '70000000-0000-7000-8000-000000007101';
DO $$
BEGIN
  PERFORM plt_t.fails('T19 ingest cannot change request content',
    format($q$UPDATE platform.impersonation_request SET reason = 'changed by a cell' WHERE id = %L$q$, plt_t.u('IMP1')), '%permission denied%');
END $$;
RESET ROLE;
SET ROLE hk_platform_app;

-- T20 لایسنس On-prem
DO $$
DECLARE
  v_fp jsonb := plt_t.fp('server-1');
  v_fp2 jsonb := plt_t.fp('server-2');
  v_lic jsonb;
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('SL'));
  PERFORM plt_t.fails('T20 installations are on-prem only',
    format($q$INSERT INTO platform.installation (id, tenant_id, install_pubkey, fingerprint) VALUES (gen_random_uuid(), %L, decode(repeat('01',32),'hex'), %L)$q$, plt_t.u('TA'), v_fp),
    'HK_PLT_NOT_ONPREM%');
  PERFORM plt_t.fails('T20 fingerprint components allowlisted',
    format($q$INSERT INTO platform.installation (id, tenant_id, install_pubkey, fingerprint) VALUES (gen_random_uuid(), %L, decode(repeat('01',32),'hex'), %L)$q$, plt_t.u('TC'), v_fp || '{"cpu_serial": "aa"}'),
    'HK_PLT_FINGERPRINT_SHAPE%');
  PERFORM plt_t.fails('T20 fingerprint has min_match components',
    format($q$INSERT INTO platform.installation (id, tenant_id, install_pubkey, fingerprint) VALUES (gen_random_uuid(), %L, decode(repeat('01',32),'hex'), %L)$q$, plt_t.u('TC'), v_fp - 'dmi_uuid' - 'machine_id' - 'pg_sysid'),
    'HK_PLT_FINGERPRINT_SHAPE%');
  INSERT INTO platform.installation (id, tenant_id, reseller_id, install_pubkey, fingerprint, app_version)
  VALUES (plt_t.u('INST1'), plt_t.u('TC'), plt_t.u('R1'), decode(repeat('01', 32), 'hex'), v_fp, '2026.12.0'),
         (plt_t.u('INST2'), plt_t.u('TF'), plt_t.u('R2'), decode(repeat('02', 32), 'hex'), plt_t.fp('server-f'), '2026.12.0');
  PERFORM plt_t.fails('T20 activation only by license', format($q$UPDATE platform.installation SET status = 'active' WHERE id = %L$q$, plt_t.u('INST1')), 'HK_PLT_DERIVED_COLUMN%');
  -- لایسنس
  PERFORM plt_t.fails('T20 license product kind',
    format($q$INSERT INTO platform.license (tenant_id, product_version_id, license_model, edition, modules, limits, not_before, updates_until, support_until, number) VALUES (%L, %L, 'perpetual', 'pro', '{accounting}', '{}', current_date, current_date + 365, current_date + 365, 'x')$q$, plt_t.u('TC'), plt_t.u('PV1')),
    'HK_PLT_LICENSE_SHAPE%');
  PERFORM plt_t.fails('T20 perpetual has no expiry',
    format($q$INSERT INTO platform.license (tenant_id, product_version_id, license_model, edition, modules, limits, not_before, valid_until, updates_until, support_until, number) VALUES (%L, %L, 'perpetual', 'pro', '{accounting}', '{}', current_date, current_date + 10, current_date + 365, current_date + 365, 'x')$q$, plt_t.u('TC'), plt_t.u('PV3')),
    '%license_perpetual_no_expiry%');
  PERFORM plt_t.fails('T20 trial at most 60 days',
    format($q$INSERT INTO platform.license (tenant_id, product_version_id, license_model, edition, modules, limits, not_before, valid_until, updates_until, support_until, number) VALUES (%L, %L, 'trial', 'pro', '{accounting}', '{}', current_date, current_date + 90, current_date + 90, current_date + 90, 'x')$q$, plt_t.u('TC'), plt_t.u('PV3')),
    '%license_trial_short%');
  PERFORM plt_t.fails('T20 license limits allowlisted',
    format($q$INSERT INTO platform.license (tenant_id, product_version_id, license_model, edition, modules, limits, not_before, updates_until, support_until, number) VALUES (%L, %L, 'perpetual', 'pro', '{accounting}', '{"cpus": 4}', current_date, current_date + 365, current_date + 365, 'x')$q$, plt_t.u('TC'), plt_t.u('PV3')),
    'HK_PLT_LICENSE_SHAPE%');
  INSERT INTO platform.license (id, tenant_id, installation_id, product_version_id, license_model, edition, modules, limits, not_before, updates_until, support_until, reseller_id, number)
  VALUES (plt_t.u('LIC1'), plt_t.u('TC'), plt_t.u('INST1'), plt_t.u('PV3'), 'perpetual', 'pro', '{accounting,pos}', '{"users": 10, "companies": 2, "pos_devices": 3}',
          current_date, current_date + 365, current_date + 365, plt_t.u('R1'), 'x');
  PERFORM plt_t.ok('T20 license numbered', (SELECT number = 'LIC-000001' FROM platform.license WHERE id = plt_t.u('LIC1')));
  UPDATE platform.license SET status = 'pending_approval' WHERE id = plt_t.u('LIC1');
  PERFORM plt_t.fails('T20 terms frozen while pending approval', format($q$UPDATE platform.license SET limits = '{"users": 99}' WHERE id = %L$q$, plt_t.u('LIC1')), 'HK_PLT_LICENSE_FROZEN%');
  v_lic := jsonb_build_object('format', 'lic/1', 'license_id', plt_t.u('LIC1'), 'install_id', plt_t.u('INST1'), 'tenant_id', plt_t.u('TC'),
                              'license_model', 'perpetual', 'limits', '{"users": 10, "companies": 2, "pos_devices": 3}'::jsonb,
                              'updates_until', (current_date + 365)::text, 'valid_until', NULL, 'binding', jsonb_build_object('fingerprint', v_fp, 'min_match', 3));
  PERFORM plt_t.fails('T20 binding must equal installation fingerprint',
    format($q$UPDATE platform.license SET status = 'issued', binding_fingerprint = %L, binding_min_match = 3, payload = %L, payload_sha256 = plt_t.h('p'), file_sha256 = plt_t.h('f'), signature = plt_t.sig(), kid = 'license-2026a', issued_by_kind = 'staff', issued_by_id = %L WHERE id = %L$q$,
           v_fp2, v_lic, plt_t.u('SL'), plt_t.u('LIC1')),
    'HK_PLT_LICENSE_BINDING%');
  PERFORM plt_t.fails('T20 issue needs four-eyes approval',
    format($q$UPDATE platform.license SET status = 'issued', binding_fingerprint = %L, binding_min_match = 3, payload = %L, payload_sha256 = plt_t.h('p'), file_sha256 = plt_t.h('f'), signature = plt_t.sig(), kid = 'license-2026a', issued_by_kind = 'staff', issued_by_id = %L WHERE id = %L$q$,
           v_fp, v_lic, plt_t.u('SL'), plt_t.u('LIC1')),
    'HK_PLT_APPROVAL_REQUIRED%');
  PERFORM plt_t.fails('T20 signed payload equals registry',
    format($q$UPDATE platform.license SET status = 'issued', binding_fingerprint = %L, binding_min_match = 3, payload = %L, payload_sha256 = plt_t.h('p'), file_sha256 = plt_t.h('f'), signature = plt_t.sig(), kid = 'license-2026a', issued_by_kind = 'staff', issued_by_id = %L, approval_id = %L WHERE id = %L$q$,
           v_fp, jsonb_set(v_lic, '{limits,users}', '50'), plt_t.u('SL'), plt_t.approve('license.issue', 'license', plt_t.u('LIC1'), plt_t.u('SL'), plt_t.u('A')), plt_t.u('LIC1')),
    '%license_payload_matches%');
  UPDATE platform.license SET status = 'issued', binding_fingerprint = v_fp, binding_min_match = 3, payload = v_lic, payload_sha256 = plt_t.h('p1'),
         file_sha256 = plt_t.h('f1'), signature = plt_t.sig(), kid = 'license-2026a', issued_by_kind = 'staff', issued_by_id = plt_t.u('SL'),
         approval_id = plt_t.approve('license.issue', 'license', plt_t.u('LIC1'), plt_t.u('SL'), plt_t.u('A'))
   WHERE id = plt_t.u('LIC1');
  PERFORM plt_t.ok('T20 issue activates installation', (SELECT status = 'active' AND first_activated_at IS NOT NULL FROM platform.installation WHERE id = plt_t.u('INST1'))
                                                     AND (SELECT issue_seq = 1 AND issued_at IS NOT NULL FROM platform.license WHERE id = plt_t.u('LIC1')));
  PERFORM plt_t.fails('T20 issued license file immutable', format($q$UPDATE platform.license SET signature = plt_t.sig() || '\x00'::bytea WHERE id = %L$q$, plt_t.u('LIC1')),
    'HK_PLT_LICENSE_FROZEN%');
  PERFORM plt_t.fails('T20 issued license terms frozen', format($q$UPDATE platform.license SET updates_until = current_date + 900 WHERE id = %L$q$, plt_t.u('LIC1')),
    'HK_PLT_LICENSE_FROZEN%');
  -- لایسنس دوم بدون جایگزینی
  INSERT INTO platform.license (id, tenant_id, installation_id, product_version_id, license_model, edition, modules, limits, not_before, updates_until, support_until, issued_via, number)
  VALUES (plt_t.u('LIC2'), plt_t.u('TC'), plt_t.u('INST1'), plt_t.u('PV3'), 'perpetual', 'pro', '{accounting,pos}', '{"users": 10, "companies": 2, "pos_devices": 3}',
          current_date, current_date + 730, current_date + 730, 'renewal_auto', 'x');
  v_lic := jsonb_set(jsonb_set(v_lic, '{license_id}', to_jsonb(plt_t.u('LIC2')::text)), '{updates_until}', to_jsonb((current_date + 730)::text));
  PERFORM plt_t.fails('T20 one issued license per installation',
    format($q$UPDATE platform.license SET status = 'issued', binding_fingerprint = %L, binding_min_match = 3, payload = %L, payload_sha256 = plt_t.h('p'), file_sha256 = plt_t.h('f'), signature = plt_t.sig(), kid = 'license-2026a', issued_by_kind = 'system' WHERE id = %L$q$,
           v_fp, v_lic, plt_t.u('LIC2')),
    'HK_PLT_LICENSE_SUPERSEDE%');
  -- تمدید پشتیبانی با شرایط یکسان: بدون تأیید دونفره
  UPDATE platform.license SET supersedes_license_id = plt_t.u('LIC1') WHERE id = plt_t.u('LIC2');
  UPDATE platform.license SET status = 'issued', binding_fingerprint = v_fp, binding_min_match = 3, payload = v_lic, payload_sha256 = plt_t.h('p2'),
         file_sha256 = plt_t.h('f2'), signature = plt_t.sig(), kid = 'license-2026a', issued_by_kind = 'system'
   WHERE id = plt_t.u('LIC2');
  PERFORM plt_t.ok('T20 renewal supersedes', (SELECT status = 'superseded' FROM platform.license WHERE id = plt_t.u('LIC1'))
                                            AND (SELECT issue_seq = 2 FROM platform.license WHERE id = plt_t.u('LIC2')));
  PERFORM plt_t.fails('T20 supersede only by successor', format($q$UPDATE platform.license SET status = 'superseded' WHERE id = %L$q$, plt_t.u('LIC2')), 'HK_PLT_DERIVED_COLUMN%');
  PERFORM plt_t.fails('T20 perpetual never expires', format($q$UPDATE platform.license SET status = 'expired' WHERE id = %L$q$, plt_t.u('LIC2')), 'HK_PLT_INVALID_TRANSITION%');
  -- جابه‌جایی سخت‌افزار (rehost)
  UPDATE platform.installation SET fingerprint = v_fp2 WHERE id = plt_t.u('INST1');
  INSERT INTO platform.license (id, tenant_id, installation_id, product_version_id, license_model, edition, modules, limits, not_before, updates_until, support_until, supersedes_license_id, number)
  VALUES (plt_t.u('LIC3'), plt_t.u('TC'), plt_t.u('INST1'), plt_t.u('PV3'), 'perpetual', 'pro', '{accounting,pos}', '{"users": 10, "companies": 2, "pos_devices": 3}',
          current_date, current_date + 730, current_date + 730, plt_t.u('LIC2'), 'x');
  v_lic := jsonb_set(jsonb_set(v_lic, '{license_id}', to_jsonb(plt_t.u('LIC3')::text)), '{binding}', jsonb_build_object('fingerprint', v_fp2, 'min_match', 3));
  PERFORM plt_t.fails('T20 binding change must be declared as rehost',
    format($q$UPDATE platform.license SET status = 'issued', binding_fingerprint = %L, binding_min_match = 3, payload = %L, payload_sha256 = plt_t.h('p'), file_sha256 = plt_t.h('f'), signature = plt_t.sig(), kid = 'license-2026a', issued_by_kind = 'staff', issued_by_id = %L WHERE id = %L$q$,
           v_fp2, v_lic, plt_t.u('SL'), plt_t.u('LIC3')),
    'HK_PLT_LICENSE_REHOST%');
  UPDATE platform.license SET issued_via = 'rehost' WHERE id = plt_t.u('LIC3');
  UPDATE platform.license SET status = 'issued', binding_fingerprint = v_fp2, binding_min_match = 3, payload = v_lic, payload_sha256 = plt_t.h('p3'),
         file_sha256 = plt_t.h('f3'), signature = plt_t.sig(), kid = 'license-2026a', issued_by_kind = 'staff', issued_by_id = plt_t.u('SL')
   WHERE id = plt_t.u('LIC3');
  PERFORM plt_t.ok('T20 rehost revokes predecessor', (SELECT status = 'revoked' AND revoke_reason = 'rehost' FROM platform.license WHERE id = plt_t.u('LIC2'))
                                                    AND EXISTS (SELECT 1 FROM platform.license_revocation WHERE license_id = plt_t.u('LIC2') AND reason = 'rehost'));
  -- ابطال با تأیید دونفره
  PERFORM plt_t.fails('T20 revoke needs approval',
    format($q$UPDATE platform.license SET status = 'revoked', revoke_reason = 'fraud' WHERE id = %L$q$, plt_t.u('LIC3')), 'HK_PLT_APPROVAL_REQUIRED%');
  UPDATE platform.license SET status = 'revoked', revoke_reason = 'fraud',
         revoke_approval_id = plt_t.approve('license.revoke', 'license', plt_t.u('LIC3'), plt_t.u('SL'), plt_t.u('A'))
   WHERE id = plt_t.u('LIC3');
  PERFORM plt_t.fails('T20 revocation reason enum',
    format($q$INSERT INTO platform.license_revocation (license_id, reason) VALUES (%L, 'because')$q$, plt_t.u('LIC1')), '%license_revocation_reason_check%');
  -- CRL
  PERFORM plt_t.fails('T20 CRL lists every revocation',
    format($q$INSERT INTO platform.license_crl (version, entries, document, sha256, signature, kid) VALUES (1, 1, jsonb_build_object('format','hkcrl/1','version',1,'revoked', jsonb_build_array(%L)), plt_t.h('c'), plt_t.sig(), 'license-2026a')$q$,
           plt_t.u('LIC2')::text),
    'HK_PLT_CRL_INCOMPLETE%');
  PERFORM plt_t.fails('T20 CRL lists only revocations',
    format($q$INSERT INTO platform.license_crl (version, entries, document, sha256, signature, kid) VALUES (1, 3, jsonb_build_object('format','hkcrl/1','version',1,'revoked', jsonb_build_array(%L, %L, %L)), plt_t.h('c'), plt_t.sig(), 'license-2026a')$q$,
           plt_t.u('LIC2')::text, plt_t.u('LIC3')::text, plt_t.u('LIC1')::text),
    'HK_PLT_CRL_INCOMPLETE%');
  INSERT INTO platform.license_crl (version, entries, document, sha256, signature, kid)
  VALUES (1, 2, jsonb_build_object('format','hkcrl/1','version',1,'revoked', jsonb_build_array(plt_t.u('LIC2')::text, plt_t.u('LIC3')::text)), plt_t.h('c1'), plt_t.sig(), 'license-2026a');
  PERFORM plt_t.fails('T20 CRL version sequence',
    format($q$INSERT INTO platform.license_crl (version, entries, document, sha256, signature, kid) VALUES (3, 2, jsonb_build_object('format','hkcrl/1','version',3,'revoked', jsonb_build_array(%L, %L)), plt_t.h('c3'), plt_t.sig(), 'license-2026a')$q$,
           plt_t.u('LIC2')::text, plt_t.u('LIC3')::text),
    'HK_PLT_VERSION_SEQUENCE%');
  -- صدور از سهمیهٔ نماینده
  INSERT INTO platform.license (id, tenant_id, installation_id, product_version_id, license_model, edition, modules, limits, not_before, updates_until, support_until, reseller_id, issued_via, number)
  VALUES (plt_t.u('LIC4'), plt_t.u('TC'), plt_t.u('INST1'), plt_t.u('PV3'), 'perpetual', 'pro', '{accounting}', '{"users": 5}', current_date, current_date + 365, current_date + 365, plt_t.u('R1'), 'reseller_quota', 'x'),
         (plt_t.u('LIC5'), plt_t.u('TF'), plt_t.u('INST2'), plt_t.u('PV3'), 'perpetual', 'pro', '{accounting}', '{"users": 5}', current_date, current_date + 365, current_date + 365, plt_t.u('R2'), 'reseller_quota', 'x');
  UPDATE platform.license SET status = 'issued', binding_fingerprint = v_fp2, binding_min_match = 3,
         payload = jsonb_build_object('format','lic/1','license_id',plt_t.u('LIC4'),'install_id',plt_t.u('INST1'),'tenant_id',plt_t.u('TC'),'license_model','perpetual',
                                      'limits','{"users": 5}'::jsonb,'updates_until',(current_date + 365)::text,'valid_until',NULL,'binding',jsonb_build_object('fingerprint',v_fp2)),
         payload_sha256 = plt_t.h('p4'), file_sha256 = plt_t.h('f4'), signature = plt_t.sig(), kid = 'license-2026a', issued_by_kind = 'staff', issued_by_id = plt_t.u('SL')
   WHERE id = plt_t.u('LIC4');
  PERFORM plt_t.ok('T20 quota consumed', (SELECT balance_after = 1 FROM platform.reseller_quota_entry WHERE reseller_id = plt_t.u('R1') AND license_id = plt_t.u('LIC4')));
  PERFORM plt_t.fails('T20 no quota, no license',
    format($q$UPDATE platform.license SET status = 'issued', binding_fingerprint = %L, binding_min_match = 3,
              payload = jsonb_build_object('format','lic/1','license_id',%L,'install_id',%L,'tenant_id',%L,'license_model','perpetual','limits','{"users": 5}'::jsonb,'updates_until',(current_date + 365)::text,'valid_until',NULL,'binding',jsonb_build_object('fingerprint',%L::jsonb)),
              payload_sha256 = plt_t.h('p5'), file_sha256 = plt_t.h('f5'), signature = plt_t.sig(), kid = 'license-2026a', issued_by_kind = 'staff', issued_by_id = %L WHERE id = %L$q$,
           plt_t.fp('server-f'), plt_t.u('LIC5'), plt_t.u('INST2'), plt_t.u('TF'), plt_t.fp('server-f'), plt_t.u('SL'), plt_t.u('LIC5')),
    'HK_PLT_QUOTA_EXHAUSTED%');
  -- درخواست فعال‌سازی آفلاین
  PERFORM plt_t.fails('T20 activation request names its installation',
    format($q$INSERT INTO platform.license_activation (installation_id, request, request_sha256, received_via, received_by_staff) VALUES (%L, jsonb_build_object('format','actreq/1','install_id',%L,'install_pubkey','x','fingerprint','{}'::jsonb,'nonce','n'), plt_t.h('rq0'), 'panel_upload', %L)$q$,
           plt_t.u('INST1'), plt_t.u('INST2'), plt_t.u('SL')),
    '%activation_request_shape%');
  INSERT INTO platform.license_activation (id, installation_id, tenant_id, reseller_id, request, request_sha256, received_via, received_by_staff)
  VALUES (plt_t.u('ACT1'), plt_t.u('INST1'), plt_t.u('TC'), plt_t.u('R1'),
          jsonb_build_object('format','actreq/1','install_id',plt_t.u('INST1'),'install_pubkey','AQEB','fingerprint',v_fp2,'nonce','n-1'), plt_t.h('rq1'), 'panel_upload', plt_t.u('SL'));
  PERFORM plt_t.fails('T20 duplicate activation request',
    format($q$INSERT INTO platform.license_activation (installation_id, request, request_sha256, received_via) VALUES (%L, jsonb_build_object('format','actreq/1','install_id',%L,'install_pubkey','x','fingerprint','{}'::jsonb,'nonce','n'), plt_t.h('rq1'), 'phone')$q$,
           plt_t.u('INST1'), plt_t.u('INST1')),
    '%license_activation_request_sha256_key%');
  PERFORM plt_t.fails('T20 activation skips verification', format($q$UPDATE platform.license_activation SET status = 'issued', license_id = %L WHERE id = %L$q$, plt_t.u('LIC4'), plt_t.u('ACT1')),
    'HK_PLT_INVALID_TRANSITION%');
  UPDATE platform.license_activation SET status = 'verified' WHERE id = plt_t.u('ACT1');
  PERFORM plt_t.fails('T20 activation answered with live license of same installation',
    format($q$UPDATE platform.license_activation SET status = 'issued', license_id = %L WHERE id = %L$q$, plt_t.u('LIC3'), plt_t.u('ACT1')), 'HK_PLT_LICENSE_BINDING%');
  UPDATE platform.license_activation SET status = 'issued', license_id = plt_t.u('LIC4') WHERE id = plt_t.u('ACT1');
  PERFORM plt_t.fails('T20 request immutable', format($q$UPDATE platform.license_activation SET request = request || '{"x": 1}' WHERE id = %L$q$, plt_t.u('ACT1')), 'HK_PLT_IMMUTABLE_FIELD%');
  -- گزارش مصرف ماهانه و ساعت
  PERFORM plt_t.fails('T20 usage report must be signature-verified',
    format($q$INSERT INTO platform.license_usage_report (installation_id, period, report, report_sha256, signature_ok, received_via) VALUES (%L, 'jy:1405-08', '{"format":"usage/1"}', plt_t.h('u0'), false, 'panel_upload')$q$, plt_t.u('INST1')),
    '%usage_report_signed%');
  INSERT INTO platform.license_usage_report (installation_id, period, report, report_sha256, signature_ok, users_active, received_via)
  VALUES (plt_t.u('INST1'), 'jy:1405-08', '{"format":"usage/1"}', plt_t.h('u1'), true, 4, 'panel_upload');
  PERFORM plt_t.fails('T20 one report per period',
    format($q$INSERT INTO platform.license_usage_report (installation_id, period, report, report_sha256, signature_ok, received_via) VALUES (%L, 'jy:1405-08', '{"format":"usage/1"}', plt_t.h('u2'), true, 'online')$q$, plt_t.u('INST1')),
    '%license_usage_report_installation_id_period_key%');
  UPDATE platform.installation SET max_seen_at = now() WHERE id = plt_t.u('INST1');
  PERFORM plt_t.fails('T20 clock rollback detected', format($q$UPDATE platform.installation SET max_seen_at = now() - interval '3 days' WHERE id = %L$q$, plt_t.u('INST1')),
    'HK_PLT_CLOCK_ROLLBACK%');
  PERFORM plt_t.ok('T20 update eligibility view', (SELECT latest_allowed_version = '2026.12.0' FROM platform.v_installation_update_eligibility WHERE installation_id = plt_t.u('INST1')));
END $$;

-- T21 انتشار قواعد قانونی
DO $$
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('F'));
  PERFORM plt_t.fails('T21 author needs permission',
    format($q$INSERT INTO platform.rules_package (code, version, seq, covers_from, min_engine_version, changelog_fa, authored_by) VALUES ('ir.tax', '1405.1', 1, '2026-03-21', '2026.11.0', 'x', %L)$q$, plt_t.u('F')),
    'HK_PLT_PERMISSION%');
  PERFORM plt_t.as_staff(plt_t.u('T'));
  INSERT INTO platform.rules_package (id, code, version, seq, covers_from, min_engine_version, changelog_fa, authored_by)
  VALUES (plt_t.u('RP1'), 'ir.tax', '1405.1', 1, '2026-03-21', '2026.11.0', 'نرخ استاندارد ارزش افزوده ۱۴۰۵', plt_t.u('T'));
  PERFORM plt_t.fails('T21 seq strictly increasing',
    format($q$INSERT INTO platform.rules_package (code, version, seq, covers_from, min_engine_version, changelog_fa, authored_by) VALUES ('ir.tax', '1405.0', 1, '2026-03-21', '2026.11.0', 'x', %L)$q$, plt_t.u('T')),
    'HK_PLT_RULES_SEQ%');
  PERFORM plt_t.fails('T21 key owned by package code',
    format($q$INSERT INTO platform.rules_value (package_id, key, effective_from, value, source_ref, confidence) VALUES (%L, 'payroll.wage.min_daily', '2026-03-21', '{"amount": "1000", "unit": "IRR"}', 'بخشنامه', 'high')$q$, plt_t.u('RP1')),
    'HK_PLT_RULES_KEY_OWNER%');
  PERFORM plt_t.fails('T21 percent value is a decimal string',
    format($q$INSERT INTO platform.rules_value (package_id, key, effective_from, value, source_ref, confidence) VALUES (%L, 'tax.vat.standard_rate', '2026-03-21', '10', 'قانون بودجه', 'medium')$q$, plt_t.u('RP1')),
    'HK_PLT_RULES_VALUE_SHAPE%');
  PERFORM plt_t.fails('T21 money needs explicit unit',
    format($q$INSERT INTO platform.rules_value (package_id, key, effective_from, value, source_ref, confidence) VALUES (%L, 'tax.threshold.article6', '2026-03-21', '{"amount": "1000"}', 'ماده ۶', 'low')$q$, plt_t.u('RP1')),
    'HK_PLT_RULES_VALUE_SHAPE%');
  PERFORM plt_t.fails('T21 money amount is a string',
    format($q$INSERT INTO platform.rules_value (package_id, key, effective_from, value, source_ref, confidence) VALUES (%L, 'tax.threshold.article6', '2026-03-21', '{"amount": 1000, "unit": "IRR"}', 'ماده ۶', 'low')$q$, plt_t.u('RP1')),
    'HK_PLT_RULES_VALUE_SHAPE%');
  PERFORM plt_t.fails('T21 enum value allowlisted',
    format($q$INSERT INTO platform.rules_value (package_id, key, effective_from, value, source_ref, confidence) VALUES (%L, 'tax.vat.rounding', '2026-03-21', '"ceil"', 'دستورالعمل', 'high')$q$, plt_t.u('RP1')),
    'HK_PLT_RULES_VALUE_SHAPE%');
  PERFORM plt_t.fails('T21 official verification needs the document hash',
    format($q$INSERT INTO platform.rules_value (package_id, key, effective_from, value, source_ref, confidence, verified_official) VALUES (%L, 'tax.vat.rounding', '2026-03-21', '"trunc"', 'دستورالعمل', 'high', true)$q$, plt_t.u('RP1')),
    '%rules_value_check%');
  INSERT INTO platform.rules_value (package_id, key, effective_from, value, approved_on, source_ref, source_doc_sha256, confidence, verified_official) VALUES
    (plt_t.u('RP1'), 'tax.vat.standard_rate', '2026-03-21', '"10"', '2026-03-01', 'قانون بودجهٔ ۱۴۰۵', plt_t.h('budget'), 'medium', true),
    (plt_t.u('RP1'), 'tax.threshold.article6', '2026-03-21', '{"amount": "10000000000", "unit": "IRR"}', NULL, 'ماده ۶', NULL, 'low', false),
    (plt_t.u('RP1'), 'tax.vat.rounding', '2026-03-21', '"trunc"', NULL, 'دستورالعمل V7.8', NULL, 'high', false);
  PERFORM plt_t.fails('T21 value ranges do not overlap',
    format($q$INSERT INTO platform.rules_value (package_id, key, effective_from, value, source_ref, confidence) VALUES (%L, 'tax.vat.standard_rate', '2026-06-01', '"12"', 'مصوبهٔ دوم', 'low')$q$, plt_t.u('RP1')),
    '%rules_value_no_overlap%');
  PERFORM plt_t.fails('T21 review needs golden tests', format($q$UPDATE platform.rules_package SET status = 'in_review' WHERE id = %L$q$, plt_t.u('RP1')), 'HK_PLT_RULES_INCOMPLETE%');
  INSERT INTO platform.rules_golden_test (package_id, code, calculator, as_of, input, expected, signed_by) VALUES
    (plt_t.u('RP1'), 'vat-10-trunc', 'tax.vat_line', '2026-04-01', '{"base": "999"}', '{"vat": "99"}', 'حسابدار رسمی');
  UPDATE platform.rules_package SET status = 'in_review' WHERE id = plt_t.u('RP1');
  PERFORM plt_t.ok('T21 review round advanced', (SELECT review_round = 1 FROM platform.rules_package WHERE id = plt_t.u('RP1')));
  PERFORM plt_t.fails('T21 content frozen in review',
    format($q$UPDATE platform.rules_value SET value = '"9"' WHERE package_id = %L AND key = 'tax.vat.standard_rate'$q$, plt_t.u('RP1')), 'HK_PLT_RULES_FROZEN%');
  PERFORM plt_t.fails('T21 package header frozen in review',
    format($q$UPDATE platform.rules_package SET min_engine_version = '2026.1.0' WHERE id = %L$q$, plt_t.u('RP1')), 'HK_PLT_RULES_FROZEN%');
  PERFORM plt_t.fails('T21 approval needs a review', format($q$UPDATE platform.rules_package SET status = 'approved' WHERE id = %L$q$, plt_t.u('RP1')), 'HK_PLT_RULES_NOT_REVIEWED%');
  PERFORM plt_t.fails('T21 author cannot review',
    format($q$INSERT INTO platform.rules_review (package_id, round, reviewer_staff_id, qualification_role, decision) VALUES (%L, 1, %L, 'compliance_tax', 'approve')$q$, plt_t.u('RP1'), plt_t.u('T')),
    'HK_PLT_FOUR_EYES%');
  PERFORM plt_t.as_staff(plt_t.u('P'));
  PERFORM plt_t.fails('T21 reviewer must hold the qualification',
    format($q$INSERT INTO platform.rules_review (package_id, round, reviewer_staff_id, qualification_role, decision) VALUES (%L, 1, %L, 'compliance_tax', 'approve')$q$, plt_t.u('RP1'), plt_t.u('P')),
    'HK_PLT_APPROVER_NOT_ELIGIBLE%');
  PERFORM plt_t.fails('T21 qualification matches domain',
    format($q$INSERT INTO platform.rules_review (package_id, round, reviewer_staff_id, qualification_role, decision) VALUES (%L, 1, %L, 'compliance_payroll', 'approve')$q$, plt_t.u('RP1'), plt_t.u('P')),
    'HK_PLT_APPROVER_NOT_ELIGIBLE%');
  PERFORM plt_t.as_staff(plt_t.u('T2'));
  PERFORM plt_t.fails('T21 review of a past round',
    format($q$INSERT INTO platform.rules_review (package_id, round, reviewer_staff_id, qualification_role, decision) VALUES (%L, 2, %L, 'compliance_tax', 'approve')$q$, plt_t.u('RP1'), plt_t.u('T2')),
    'HK_PLT_RULES_REVIEW_STATE%');
  INSERT INTO platform.rules_review (package_id, round, reviewer_staff_id, qualification_role, decision, comment)
  VALUES (plt_t.u('RP1'), 1, plt_t.u('T2'), 'compliance_tax', 'approve', 'با متن قانون بودجه تطبیق داده شد');
  UPDATE platform.rules_package SET status = 'approved' WHERE id = plt_t.u('RP1');
  PERFORM plt_t.fails('T21 CI must run every golden test',
    format($q$INSERT INTO platform.rules_golden_ci_run (package_id, engine_version, total, passed, failed, outcome) VALUES (%L, '2026.11.0', 5, 5, 0, 'passed')$q$, plt_t.u('RP1')),
    'HK_PLT_GOLDEN_INCOMPLETE%');
  PERFORM plt_t.fails('T21 CI outcome consistent',
    format($q$INSERT INTO platform.rules_golden_ci_run (package_id, engine_version, total, passed, failed, outcome) VALUES (%L, '2026.11.0', 1, 0, 1, 'passed')$q$, plt_t.u('RP1')),
    '%golden_ci_outcome%');
  INSERT INTO platform.rules_golden_ci_run (package_id, engine_version, total, passed, failed, outcome) VALUES (plt_t.u('RP1'), '2026.11.0', 1, 1, 0, 'passed');
  PERFORM plt_t.as_staff(plt_t.u('A'));
  PERFORM plt_t.fails('T21 golden tests on every supported engine',
    format($q$UPDATE platform.rules_package SET status = 'published', published_by = %L, payload_sha256 = plt_t.h('rp'), hksb_sha256 = plt_t.h('rh'), signer_kid = 'rules-2026a' WHERE id = %L$q$, plt_t.u('A'), plt_t.u('RP1')),
    'HK_PLT_GOLDEN_NOT_PASSED%');
  INSERT INTO platform.rules_golden_ci_run (package_id, engine_version, total, passed, failed, outcome) VALUES (plt_t.u('RP1'), '2026.12.0', 1, 1, 0, 'passed');
  PERFORM plt_t.as_staff(plt_t.u('T2'));
  PERFORM plt_t.fails('T21 publisher needs permission',
    format($q$UPDATE platform.rules_package SET status = 'published', published_by = %L, payload_sha256 = plt_t.h('rp'), hksb_sha256 = plt_t.h('rh'), signer_kid = 'rules-2026a' WHERE id = %L$q$, plt_t.u('T2'), plt_t.u('RP1')),
    'HK_PLT_PERMISSION%');
  PERFORM plt_t.as_staff(plt_t.u('A'));
  UPDATE platform.rules_package SET status = 'published', published_by = plt_t.u('A'), payload_sha256 = plt_t.h('rp'), hksb_sha256 = plt_t.h('rh'), signer_kid = 'rules-2026a'
   WHERE id = plt_t.u('RP1');
  PERFORM plt_t.fails('T21 published package immutable', format($q$UPDATE platform.rules_package SET hksb_sha256 = plt_t.h('other') WHERE id = %L$q$, plt_t.u('RP1')), 'HK_PLT_RULES_FROZEN%');
  PERFORM plt_t.fails('T21 withdraw needs reason', format($q$UPDATE platform.rules_package SET status = 'withdrawn' WHERE id = %L$q$, plt_t.u('RP1')), '%rules_package_check%');
  INSERT INTO platform.rules_distribution (package_id, target_kind, target_id, status) VALUES (plt_t.u('RP1'), 'cell', 'cell-01', 'pending');
END $$;

-- T22b بستهٔ صنفی
DO $$
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('T'));
  INSERT INTO platform.industry_pack (code, name_fa, kind, introduced_in) VALUES ('cafe', 'کافه و رستوران', 'industry', '2026.11.0');
  PERFORM plt_t.fails('T22 manifest matches pack/version',
    format($q$INSERT INTO platform.industry_pack_version (pack_code, version, manifest, manifest_sha256, min_app_version, authored_by) VALUES ('cafe', '1.0.0', '{"format":"hkpack/1","pack":"retail","version":"1.0.0"}', plt_t.h('m'), '2026.11', %L)$q$, plt_t.u('T')),
    '%industry_pack_version_check%');
  INSERT INTO platform.industry_pack_version (pack_code, version, manifest, manifest_sha256, min_app_version, confidence, authored_by)
  VALUES ('cafe', '1.0.0', '{"format":"hkpack/1","pack":"cafe","version":"1.0.0"}', plt_t.h('m'), '2026.11', 'medium', plt_t.u('T'));
  UPDATE platform.industry_pack_version SET status = 'in_review' WHERE pack_code = 'cafe';
  PERFORM plt_t.fails('T22 pack frozen in review', $q$UPDATE platform.industry_pack_version SET confidence = 'high' WHERE pack_code = 'cafe'$q$, 'HK_PLT_PACK_FROZEN%');
  PERFORM plt_t.fails('T22 author cannot publish own pack',
    format($q$UPDATE platform.industry_pack_version SET status = 'published', reviewed_by = %L, gate_passed = true, hksb_sha256 = plt_t.h('h') WHERE pack_code = 'cafe'$q$, plt_t.u('T')),
    '%pack_reviewer_not_author%');
  PERFORM plt_t.as_staff(plt_t.u('T2'));
  PERFORM plt_t.fails('T22 publish needs passed gate',
    format($q$UPDATE platform.industry_pack_version SET status = 'published', reviewed_by = %L, hksb_sha256 = plt_t.h('h') WHERE pack_code = 'cafe'$q$, plt_t.u('T2')),
    '%pack_published_fields%');
  UPDATE platform.industry_pack_version SET status = 'published', reviewed_by = plt_t.u('T2'), gate_passed = true, hksb_sha256 = plt_t.h('h'),
         gate_report = '{"report_coverage_empty": true, "control_rows_zero": true}' WHERE pack_code = 'cafe';
  PERFORM plt_t.fails('T22 published pack immutable', $q$UPDATE platform.industry_pack_version SET hksb_sha256 = plt_t.h('x') WHERE pack_code = 'cafe'$q$, 'HK_PLT_PACK_FROZEN%');
  PERFORM plt_t.fails('T22 published pack not deletable', $q$DELETE FROM platform.industry_pack_version WHERE pack_code = 'cafe'$q$, 'HK_PLT_IMMUTABLE%');
END $$;

-- T25 درخواست داده
DO $$
BEGIN
  PERFORM plt_t.as_staff(plt_t.u('S'));
  INSERT INTO platform.data_request (id, tenant_id, kind, requested_via, requester_name, created_by_staff, due_by)
  VALUES (plt_t.u('DR1'), plt_t.u('TA'), 'personal_data_erasure', 'data_subject', 'مشتری کافه', plt_t.u('S'), current_date + 30);
  PERFORM plt_t.fails('T25 created by acting staff',
    format($q$INSERT INTO platform.data_request (tenant_id, kind, requested_via, requester_name, created_by_staff, due_by) VALUES (%L, 'full_export', 'tenant_owner', 'x', %L, current_date)$q$, plt_t.u('TA'), plt_t.u('A')),
    'HK_PLT_INVALID_TRANSITION%');
  PERFORM plt_t.fails('T25 skip review', format($q$UPDATE platform.data_request SET status = 'completed', result_sha256 = plt_t.h('r') WHERE id = %L$q$, plt_t.u('DR1')), 'HK_PLT_INVALID_TRANSITION%');
  UPDATE platform.data_request SET status = 'in_review' WHERE id = plt_t.u('DR1');
  INSERT INTO platform.data_request (id, tenant_id, kind, requested_via, requester_name, created_by_staff, due_by, status)
  VALUES (plt_t.u('DR2'), plt_t.u('TA'), 'full_export', 'tenant_owner', 'مالک کافه', plt_t.u('S'), current_date + 30, 'received');
  UPDATE platform.data_request SET status = 'in_review' WHERE id = plt_t.u('DR2');
  PERFORM plt_t.fails('T25 reviewer is not the creator',
    format($q$UPDATE platform.data_request SET status = 'approved', reviewer_staff_id = %L WHERE id = %L$q$, plt_t.u('S'), plt_t.u('DR2')), '%data_request_reviewer_distinct%');
  PERFORM plt_t.as_staff(plt_t.u('A'));
  PERFORM plt_t.fails('T25 erasure needs four-eyes approval',
    format($q$UPDATE platform.data_request SET status = 'approved', reviewer_staff_id = %L WHERE id = %L$q$, plt_t.u('A'), plt_t.u('DR1')), 'HK_PLT_APPROVAL_REQUIRED%');
  UPDATE platform.data_request SET status = 'approved', reviewer_staff_id = plt_t.u('A'),
         approval_id = plt_t.approve('data_request.erasure', 'data_request', plt_t.u('DR1'), plt_t.u('A'), plt_t.u('O'))
   WHERE id = plt_t.u('DR1');
  UPDATE platform.data_request SET status = 'in_progress' WHERE id = plt_t.u('DR1');
  PERFORM plt_t.fails('T25 completion needs result hash', format($q$UPDATE platform.data_request SET status = 'completed' WHERE id = %L$q$, plt_t.u('DR1')), '%data_request_check%');
  UPDATE platform.data_request SET status = 'completed', result_sha256 = plt_t.h('erasure-report') WHERE id = plt_t.u('DR1');
END $$;

-- =====================================================================
-- بخش ۴: جداسازی نماینده‌ها با RLS (hk_partner_app)
-- =====================================================================
RESET ROLE;
SET ROLE hk_partner_app;
DO $$
DECLARE
  v_w uuid;
BEGIN
  PERFORM set_config('app.reseller_id', plt_t.u('R1')::text, true);
  PERFORM set_config('app.reseller_user_id', plt_t.u('RU1')::text, true);
  PERFORM plt_t.ok('T26 partner sees own tenants only',
    (SELECT array_agg(slug ORDER BY slug) = ARRAY['cafe-a','elec-c'] FROM platform.tenant));
  PERFORM plt_t.ok('T26 partner sees own invoices only', (SELECT count(*) > 0 AND bool_and(reseller_id = plt_t.u('R1')) FROM platform.invoice));
  PERFORM plt_t.ok('T26 invoice lines through visible invoices', (SELECT bool_and(i.reseller_id = plt_t.u('R1')) FROM platform.invoice_line l JOIN platform.invoice i ON i.id = l.invoice_id));
  PERFORM plt_t.ok('T26 partner sees own wallet only', (SELECT count(*) = 1 FROM platform.wallet) AND (SELECT bool_and(reseller_id = plt_t.u('R1')) FROM platform.wallet));
  PERFORM plt_t.ok('T26 reseller row', (SELECT count(*) = 1 FROM platform.reseller));
  PERFORM plt_t.ok('T26 tier commission rules visible', (SELECT count(*) = 4 FROM platform.commission_rule));
  PERFORM plt_t.ok('T26 consent visible only for own grants', (SELECT count(*) = 1 FROM platform.support_consent));
  PERFORM plt_t.ok('T26 installations and licenses own', (SELECT count(*) = 1 FROM platform.installation) AND (SELECT bool_and(reseller_id = plt_t.u('R1')) FROM platform.license));
  PERFORM plt_t.ok('T26 tickets assigned to reseller', (SELECT array_agg(number) = ARRAY['T-000002'] FROM platform.ticket));
  PERFORM plt_t.fails('T26 partner cannot read staff', $q$SELECT count(*) FROM platform.staff$q$, '%permission denied%');
  PERFORM plt_t.fails('T26 partner cannot read approvals', $q$SELECT count(*) FROM platform.approval_request$q$, '%permission denied%');
  SELECT id INTO v_w FROM platform.wallet;
  PERFORM plt_t.fails('T26 payout for another reseller',
    format($q$INSERT INTO platform.payout (reseller_id, wallet_id, amount, sheba, requested_by_kind, requested_by_id) VALUES (%L, %L, 1, 'IR000000000000000000000001', 'reseller_user', %L)$q$,
           plt_t.u('R2'), v_w, plt_t.u('RU1')),
    'HK_PLT_PAYOUT_WALLET%');
  PERFORM plt_t.fails('T26 partner update of invisible row is a no-op then RLS on insert',
    format($q$INSERT INTO platform.service_order (tenant_id, kind, number) VALUES (%L, 'training', 'x')$q$, plt_t.u('TA')),
    '%permission denied%');
  PERFORM plt_t.fails('T26 payout requested by another user',
    format($q$INSERT INTO platform.payout (reseller_id, wallet_id, amount, sheba, requested_by_kind, requested_by_id) VALUES (%L, %L, 1, 'IR000000000000000000000001', 'reseller_user', %L)$q$,
           plt_t.u('R1'), v_w, plt_t.u('RU2')),
    'HK_PLT_PARTNER_SCOPE%');
  INSERT INTO platform.payout (id, reseller_id, wallet_id, amount, sheba, requested_by_kind, requested_by_id)
  VALUES ('70000000-0000-7000-8000-00000000f0f0', plt_t.u('R1'), v_w, 1, 'IR000000000000000000000001', 'reseller_user', plt_t.u('RU1'));
  PERFORM plt_t.fails('T26 partner cannot approve payouts',
    $q$UPDATE platform.payout SET status = 'approved' WHERE id = '70000000-0000-7000-8000-00000000f0f0'$q$, 'HK_PLT_PARTNER_SCOPE%');
  PERFORM plt_t.fails('T26 partner job kinds',
    $q$INSERT INTO platform.job (kind, payload) VALUES ('billing.house_sync', '{}')$q$, 'HK_PLT_PARTNER_SCOPE%');
  INSERT INTO platform.job (kind, payload) VALUES ('partner.report.monthly', '{}');
  PERFORM plt_t.fails('T26 partner audit actor',
    format($q$INSERT INTO platform.audit_log (actor_kind, actor_id, action, reseller_id) VALUES ('staff', %L, 'platform.x.y', %L)$q$, plt_t.u('A'), plt_t.u('R1')),
    'HK_PLT_AUDIT_ACTOR%');
  INSERT INTO platform.audit_log (actor_kind, actor_id, action, reseller_id) VALUES ('reseller_user', plt_t.u('RU1'), 'partner.payout.requested', plt_t.u('R1'));
  PERFORM plt_t.fails('T26 message on a ticket not assigned to reseller',
    format($q$INSERT INTO platform.ticket_message (ticket_id, seq, author_kind, author_ref, visibility, body) VALUES (%L, 0, 'reseller_user', %L, 'public', 'x')$q$, plt_t.u('TK1'), plt_t.u('RU1')),
    '%row-level security%');
  INSERT INTO platform.ticket_message (ticket_id, seq, author_kind, author_ref, visibility, body) VALUES (plt_t.u('TK2'), 0, 'reseller_user', plt_t.u('RU1'), 'partner', 'نصب انجام شد');
  PERFORM plt_t.fails('T26 partner cannot write internal notes',
    format($q$INSERT INTO platform.ticket_message (ticket_id, seq, author_kind, author_ref, visibility, body) VALUES (%L, 0, 'reseller_user', %L, 'internal', 'x')$q$, plt_t.u('TK2'), plt_t.u('RU1')),
    '%row-level security%');
  PERFORM plt_t.fails('T26 partner activation by acting user only',
    format($q$INSERT INTO platform.license_activation (installation_id, reseller_id, request, request_sha256, received_via, received_by_reseller_user) VALUES (%L, %L, jsonb_build_object('format','actreq/1','install_id',%L,'install_pubkey','x','fingerprint','{}'::jsonb,'nonce','p'), plt_t.h('rq-p'), 'partner_portal', %L)$q$,
           plt_t.u('INST1'), plt_t.u('R1'), plt_t.u('INST1'), plt_t.u('RU2')),
    'HK_PLT_PARTNER_SCOPE%');
  INSERT INTO platform.license_activation (installation_id, reseller_id, request, request_sha256, received_via, received_by_reseller_user)
  VALUES (plt_t.u('INST1'), plt_t.u('R1'), jsonb_build_object('format','actreq/1','install_id',plt_t.u('INST1'),'install_pubkey','x','fingerprint','{}'::jsonb,'nonce','p'), plt_t.h('rq-p'), 'partner_portal', plt_t.u('RU1'));
  PERFORM plt_t.fails('T26 partner impersonation consent grantee',
    format($q$INSERT INTO platform.impersonation_request (tenant_id, grant_id, requester_kind, reseller_user_id, reseller_id, mode, reason, ticket_ref, max_minutes) VALUES (%L, %L, 'reseller_user', %L, %L, 'read_only', 'help with the opening balance', 'T-000002', 30)$q$,
           plt_t.u('TA'), plt_t.u('G1'), plt_t.u('RU1'), plt_t.u('R1')),
    'HK_PLT_CONSENT_GRANTEE%');
  INSERT INTO platform.impersonation_request (tenant_id, grant_id, requester_kind, reseller_user_id, reseller_id, mode, reason, ticket_ref, max_minutes)
  VALUES (plt_t.u('TA'), plt_t.u('G3'), 'reseller_user', plt_t.u('RU1'), plt_t.u('R1'), 'read_only', 'help with the opening balance', 'T-000002', 30);
  INSERT INTO platform.idempotency_key (principal_kind, principal_id, key, method, path, request_sha256, expires_at, response_status)
  VALUES ('reseller_user', plt_t.u('RU1'), 'partner-key-000000001', 'POST', '/partner/v1/payouts', plt_t.h('x'), now() + interval '1 day', 201);
  PERFORM plt_t.ok('T26 idempotency keys isolated', (SELECT count(*) = 1 FROM platform.idempotency_key));
  PERFORM plt_t.fails('T26 partner cannot write keys of others',
    format($q$INSERT INTO platform.idempotency_key (principal_kind, principal_id, key, method, path, request_sha256, expires_at, response_status) VALUES ('staff', %L, 'stolen-key-000000001', 'POST', '/x', plt_t.h('x'), now() + interval '1 day', 200)$q$, plt_t.u('A')),
    '%row-level security%');
  -- بدون زمینه: هیچ سطری
  PERFORM set_config('app.reseller_id', '', true);
  PERFORM plt_t.ok('T26 no context, no rows', (SELECT count(*) = 0 FROM platform.tenant) AND (SELECT count(*) = 0 FROM platform.invoice));
  -- نمایندهٔ دوم
  PERFORM set_config('app.reseller_id', plt_t.u('R2')::text, true);
  PERFORM set_config('app.reseller_user_id', plt_t.u('RU2')::text, true);
  PERFORM plt_t.ok('T26 second reseller isolated', (SELECT array_agg(slug ORDER BY slug) = ARRAY['elec-f','shoes-b'] FROM platform.tenant)
                                                  AND (SELECT count(*) = 0 FROM platform.commission_entry) AND (SELECT count(*) = 0 FROM platform.ticket));
END $$;

-- =====================================================================
-- بخش ۵: hk_platform_readonly
-- =====================================================================
RESET ROLE;
SET ROLE hk_platform_readonly;
DO $$
BEGIN
  PERFORM plt_t.fails('T27 readonly cannot read session token hash', $q$SELECT token_hash FROM platform.staff_session$q$, '%permission denied%');
  PERFORM plt_t.fails('T27 readonly cannot read idempotent responses', $q$SELECT response_body FROM platform.idempotency_key$q$, '%permission denied%');
  PERFORM plt_t.ok('T27 readonly reads safe columns', (SELECT count(*) > 0 FROM (SELECT id, staff_id, mfa_at FROM platform.staff_session) x));
  PERFORM plt_t.ok('T27 readonly reads registry', (SELECT count(*) >= 7 FROM platform.tenant));
  PERFORM plt_t.fails('T27 readonly cannot write', $q$UPDATE platform.tenant SET display_name = 'x'$q$, '%permission denied%');
END $$;

-- =====================================================================
-- بخش ۶: postgres — lint، تغییرناپذیری برای مالک، دستکاری زنجیره، جمع‌بندی
-- =====================================================================
RESET ROLE;
DO $$
BEGIN
  PERFORM plt_t.ok('T28 security lint clean', NOT EXISTS (SELECT 1 FROM platform.security_lint()));
  PERFORM plt_t.fails('T28 audit append-only even for owner', $q$UPDATE platform.audit_log SET reason = 'x' WHERE seq = 1$q$, 'HK_PLT_IMMUTABLE%');
  PERFORM plt_t.fails('T28 audit truncate blocked even for owner', $q$TRUNCATE platform.audit_log$q$, 'HK_PLT_IMMUTABLE%');
  PERFORM plt_t.fails('T28 desired state append-only even for owner', $q$DELETE FROM platform.desired_state$q$, 'HK_PLT_IMMUTABLE%');
  PERFORM plt_t.fails('T28 wallet entries append-only even for owner', $q$UPDATE platform.wallet_entry SET amount = 1$q$, 'HK_PLT_IMMUTABLE%');
  PERFORM plt_t.fails('T28 lifecycle events append-only even for owner', $q$DELETE FROM platform.tenant_lifecycle_event$q$, 'HK_PLT_IMMUTABLE%');
  PERFORM plt_t.fails('T28 chain head advances by one', $q$UPDATE platform.audit_chain_head SET last_seq = last_seq + 2$q$, 'HK_PLT_AUDIT_HEAD%');
  PERFORM plt_t.ok('T28 audit chain verifies', NOT EXISTS (SELECT 1 FROM platform.audit_verify()));
  PERFORM plt_t.ok('T28 lifecycle seq gapless per tenant',
    NOT EXISTS (SELECT 1 FROM (SELECT tenant_id, seq, row_number() OVER (PARTITION BY tenant_id ORDER BY seq) rn FROM platform.tenant_lifecycle_event) x WHERE seq <> rn));
  PERFORM plt_t.ok('T28 every status matches the last event',
    NOT EXISTS (SELECT 1 FROM platform.tenant t JOIN LATERAL (SELECT e.to_status FROM platform.tenant_lifecycle_event e WHERE e.tenant_id = t.id ORDER BY seq DESC LIMIT 1) l ON true
                WHERE l.to_status <> t.status));
  PERFORM plt_t.ok('T28 wallets consistent', NOT EXISTS (SELECT 1 FROM platform.v_wallet_integrity));
  PERFORM plt_t.ok('T28 invoice paid_amount = settlements',
    NOT EXISTS (SELECT 1 FROM platform.invoice i WHERE i.paid_amount <> coalesce((SELECT sum(amount) FROM platform.invoice_settlement s WHERE s.invoice_id = i.id), 0)));
  PERFORM plt_t.ok('T28 verified payments are fully accounted',
    NOT EXISTS (SELECT 1 FROM platform.payment p WHERE p.state IN ('verified','partially_refunded','refunded')
                AND p.amount <> coalesce((SELECT sum(amount) FROM platform.invoice_settlement s WHERE s.payment_id = p.id), 0)
                              + coalesce((SELECT sum(amount) FROM platform.wallet_entry e WHERE e.payment_id = p.id AND e.kind IN ('topup','overpayment')), 0)));
  PERFORM plt_t.ok('T28 consumed approvals are decided by someone else',
    NOT EXISTS (SELECT 1 FROM platform.approval_request WHERE status = 'consumed' AND (decided_by IS NULL OR decided_by = requested_by)));
END $$;

-- دستکاری مستقیم (با دور زدن تریگرها) توسط راستی‌آزمای زنجیره کشف می‌شود؛ سپس rollback
BEGIN;
SET LOCAL session_replication_role = replica;
UPDATE platform.audit_log SET reason = 'tampered' WHERE seq = 2;
DO $$
BEGIN
  PERFORM plt_t.ok('T28 tamper detected', EXISTS (SELECT 1 FROM platform.audit_verify() WHERE seq = 2 AND problem = 'row_hash'));
END $$;
ROLLBACK;

SELECT 'ALL 70_platform TESTS PASSED';
